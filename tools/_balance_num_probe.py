#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""在临时项目副本中验证配置引用独立于卡牌数值，且能发现字段/展示值漂移。

先确认原始输入通过，再复制本检查需要的输入文件。所有变异只写临时目录，
不会短暂改动共享的 data、文档或策略源码，因此可以与 Godot 测试并行运行。

用法：python3 tools/_balance_num_probe.py
"""
import csv
import json
import pathlib
import re
import sys
import tempfile

import check_balance_numbers as checker

ROOT = pathlib.Path(__file__).resolve().parent.parent
INPUTS = ("data/cards.json", "data/ai.json", "engine/ai_turn_strategy.gd",
          "balance.md", "README.md", "ai.md")


def json_edit(relative, path, value):
    def edit(root):
        target = root / relative
        data = json.loads(target.read_text())
        node = data
        for key in path[:-1]:
            node = node[key]
        node[path[-1]] = value
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return edit


def replace_text(relative, before, after):
    def edit(root):
        target = root / relative
        source = target.read_text()
        if source.count(before) != 1:
            raise ValueError("探针替换目标必须恰好出现一次：%s / %s" % (relative, before))
        target.write_text(source.replace(before, after))
    return edit


def parameter_row(key, column=None, value=None, action="value"):
    def edit(root):
        target = root / "ai.md"
        source = target.read_text()
        matches = [match for match in re.finditer(r"^\s*\|\s*`%s`\s*\|.*$" % re.escape(key), source, re.MULTILINE)
                   if match.start() > source.index("## 搜索参数与估值参数")]
        if len(matches) != 1:
            raise ValueError("探针参数行必须恰好出现一次：" + key)
        match = matches[0]
        row = match.group()
        if action == "delete":
            changed = ""
        elif action == "duplicate":
            changed = row + "\n" + row
        else:
            fields = row.strip().strip("|").split("|")
            fields[column] = " %s " % value
            changed = "|" + "|".join(fields) + "|"
        target.write_text(source[:match.start()] + changed + source[match.end():])
    return edit


def card_row(key, action):
    def edit(root):
        target = root / "balance.md"
        text = target.read_text()
        pattern = r"^\|[^\n]*\| `C\.%s` \|[^\n]*$" % re.escape(key)
        matches = list(re.finditer(pattern, text, re.MULTILINE))
        if len(matches) != 1:
            raise ValueError("探针卡牌行必须恰好出现一次：" + key)
        match = matches[0]
        changed = "" if action == "delete" else match[0] + "\n" + match[0]
        target.write_text(text[:match.start()] + changed + text[match.end():])
    return edit


def schema_argument(key, index, value):
    def edit(root):
        target = root / "engine/ai_turn_strategy.gd"
        source = target.read_text()
        pattern = r'^(\s*)_(int|float)\(("%s",.*)\),\s*$' % re.escape(key)
        matches = list(re.finditer(pattern, source, re.MULTILINE))
        if len(matches) != 1:
            raise ValueError("探针参数声明必须恰好出现一次：" + key)
        match = matches[0]
        args = next(csv.reader([match.group(3)], skipinitialspace=True))
        args[index] = str(value)
        rendered = [json.dumps(arg, ensure_ascii=False) if i < 3 or i == len(args) - 1 else arg
                    for i, arg in enumerate(args)]
        changed = match.group(1) + "_" + match.group(2) + "(" + ", ".join(rendered) + "),"
        target.write_text(source[:match.start()] + changed + source[match.end():])
    return edit


def probes(snapshot):
    """(变异说明, 只操作传入临时目录的函数, 必须出现的诊断片段)。"""
    card = lambda path, value: json_edit("data/cards.json", path, value)
    ai = lambda path, value: json_edit("data/ai.json", path, value)
    checks = [
        ("模拟上限展示漂移", ai(("simulation", "max_rounds"), 60), "simulation.max_rounds应是 60"),
        ("独角兽回收价展示漂移", card(("dujiaoshou", "pawn"), 25), "独角兽的回收价应是 独角兽 25"),
        ("国民应用回收价展示漂移", card(("guomin", "pawn"), 60), "国民应用的回收价应是 国民应用 60"),
        ("上市敲钟回收价展示漂移", card(("shangshi", "pawn"), 80), "上市敲钟的回收价应是 上市敲钟 80"),
        ("典当折价率展示漂移", card(("_game", "pawn_rate"), 3.0), "折价率应是"),
        ("用户典当价展示漂移", card(("_game", "pawn_user"), 2), "用户卡的价钱应是 用户卡 2"),
        ("README典当同行数字碰撞", replace_text("README.md", "用户卡 1 现金/张", "用户卡 2 现金/张"),
         "用户卡的价钱应是 用户卡 1"),
        ("卡牌字段拼写错误", replace_text("balance.md", "`C.yunketang.output_n`", "`C.yunketang.ouput_n`"),
         "配置引用不存在：C.yunketang.ouput_n"),
        ("卡牌字段退回数字", replace_text("balance.md", "`C.yunketang.output_n`", "999"),
         "yunketang 未引用字段：C.yunketang.output_n"),
        ("卡牌行缺失", card_row("yunketang", "delete"), "卡牌表未覆盖：yunketang"),
        ("卡牌行重复", card_row("yunketang", "duplicate"), "卡牌定义行重复：yunketang"),
        ("派生典当函数遗漏", replace_text("balance.md", "`pawn(C.yunketang)`", "自动计算"),
         "yunketang 未引用派生典当函数"),
        ("未注册的配置键", ai(("search", "ai", "unknown_knob"), 1), "包含未注册参数：unknown_knob"),
    ]
    schema = checker.read_parameter_schema(snapshot["engine/ai_turn_strategy.gd"])
    settings = json.loads(snapshot["data/ai.json"])["search"]["ai"]
    for key, spec in schema.items():
        raw = settings.get(key, spec["strength_points"])
        expected = checker.document_values(raw, spec)
        for index, value in enumerate(expected):
            changed = round(value + spec["step"] if value + spec["step"] <= spec["max"]
                            else value - spec["step"], 8)
            configured = list(expected)
            configured[index] = changed
            configured = [[strength, value] for strength, value in zip((0, 0.5, 1), configured)] if len(expected) == 3 else changed
            label = key + " " + ("强度%g应是" % (0, 0.5, 1)[index] if len(expected) == 3 else "默认值应是")
            checks.append(("配置漂移 " + key + "/" + str(index),
                           ai(("search", "ai", key), configured), label))
            checks.append(("文档漂移 " + key + "/" + str(index),
                           parameter_row(key, index + 1, changed), label))
        checks.append(("规格边界 " + key, schema_argument(key, 4, spec["min"] - 1),
                       "参数规格 %s 的边界或步长无效" % key))
    # 把端点换成同一行已有数字，防止裸数字查找出现假阳性。
    checks.extend([
        ("预算列互换碰撞", parameter_row("buy_beam", 1, settings["buy_beam"][1][1]),
         "buy_beam 强度0应是"),
        ("参数行缺失", parameter_row("buy_beam", action="delete"), "`buy_beam` 命中 0 行"),
        ("参数行重复", parameter_row("risk_weight", action="duplicate"), "`risk_weight` 命中 2 行"),
        ("非有限参数", ai(("search", "ai", "engine_horizon"), float("nan")),
         "search.ai.engine_horizon 配置无效：数值参数必须有限"),
        ("数值字符串", ai(("search", "ai", "engine_horizon"), "3.0"),
         "search.ai.engine_horizon 配置无效：必须是 int/float"),
        ("预算数值字符串", ai(("search", "ai", "samples"), [1, "3"]),
         "search.ai.samples 配置无效：必须是 int/float"),
        ("布尔伪装数值", ai(("search", "ai", "risk_weight"), True),
         "search.ai.risk_weight 配置无效：必须是 int/float"),
        ("预算端点数量错误", ai(("search", "ai", "samples"), [1, 3, 4]),
         "search.ai.samples 配置无效：强度范围必须有两个端点"),
        ("强度锚点乱序", ai(("search", "ai", "samples"), [[0, 1], [0.8, 2], [0.5, 2], [1, 3]]),
         "强度锚点必须在0到1间严格递增"),
        ("强度锚点缺端点", ai(("search", "ai", "samples"), [[0.1, 1], [1, 3]]),
         "强度锚点必须覆盖0到1"),
        ("配置边界独立检查", sequence(ai(("search", "ai", "engine_horizon"), 11),
                                   parameter_row("engine_horizon", 1, 11)),
         "search.ai.engine_horizon 配置无效：超出范围"),
        ("配置步长独立检查", sequence(ai(("search", "ai", "upgrade_weight"), 0.655),
                                   parameter_row("upgrade_weight", 1, 0.655)),
         "search.ai.upgrade_weight 配置无效：未对齐步长"),
        ("整数参数小数", ai(("search", "ai", "samples"), [1.5, 3]),
         "search.ai.samples 配置无效：整数参数不能含小数"),
        ("规格非法kind", replace_text("engine/ai_turn_strategy.gd", '"kind":"float"', '"kind":"text"'),
         "参数规格 engine_horizon 的 kind 与声明 helper 不匹配"),
        ("规格非法步长", replace_text("engine/ai_turn_strategy.gd", '"step":0.01', '"step":0'),
         "参数规格 engine_horizon 的边界或步长无效"),
        ("规格默认值越界", schema_argument("engine_horizon", 5, 11),
         "参数规格 engine_horizon 的默认值/端点无效：超出范围"),
        ("缺配置时fallback变更", sequence(json_delete("engine_horizon"),
                                      schema_argument("engine_horizon", 5, 3.2)),
         "engine_horizon 默认值应是 3.2"),
    ])
    return checks


def sequence(*edits):
    def edit(root):
        for operation in edits:
            operation(root)
    return edit


def json_delete(key):
    def edit(root):
        target = root / "data/ai.json"
        data = json.loads(target.read_text())
        data["search"]["ai"].pop(key, None)
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return edit


def positive_probes(snapshot):
    """合法覆盖与 fallback 必须通过，避免检查器错误禁止调参。"""
    ai = lambda key, value: json_edit("data/ai.json", ("search", "ai", key), value)
    card = lambda path, value: json_edit("data/cards.json", path, value)
    cards = json.loads(snapshot["data/cards.json"])
    return [
        ("改生产价格不改文档", card(("yunketang", "price"), cards["yunketang"]["price"] + 1)),
        ("改生产配方不改文档", card(("yunketang", "recipe_n"), cards["yunketang"]["recipe_n"] + 1)),
        ("改生产产量不改文档", card(("yunketang", "output_n"), cards["yunketang"]["output_n"] + 1)),
        ("改攻击强度不冻结旧例外", card(("heigongguan", "attack_n"), cards["heigongguan"]["attack_n"] + 1)),
        ("改公共区数量不改文档", card(("_game", "market_size"), cards["_game"]["market_size"] + 1)),
        ("改胜利线不改文档", card(("_game", "win_cash"), cards["_game"]["win_cash"] + 1)),
        ("改开局用户不改文档", card(("_game", "start_user"), cards["_game"]["start_user"] + 1)),
        ("改市场权重不改文档", card(("resou", "weight"), cards["resou"]["weight"] + 1)),
        ("移出市场不改文档", card(("resou", "weight"), 0)),
        ("改Buff倍率不改文档", card(("_game", "buff_mult", "attack_x2"), cards["_game"]["buff_mult"]["attack_x2"] + 1)),
        ("改传说升级数量不改文档", card(("shangshi", "upgrade_dup_n"), cards["shangshi"]["upgrade_dup_n"] + 1)),
        ("改路线折算不改文档", card(("_upgrade", "routes", 2, "per"), cards["_upgrade"]["routes"][2]["per"] + 1)),
        ("预算调参并同步文档", sequence(ai("buy_beam", [5, 13]),
                                    parameter_row("buy_beam", 1, 5), parameter_row("buy_beam", 2, 13),
                                    parameter_row("buy_beam", 3, 32))),
        ("系数调参并同步文档", sequence(ai("engine_horizon", 3.2), parameter_row("engine_horizon", 1, 3.2))),
        ("有显式配置时修改规格默认", schema_argument("engine_horizon", 5, 3.2)),
        ("有显式配置时修改规格预算端点", schema_argument("buy_beam", 5, 5)),
        ("无显式配置时使用fallback", sequence(json_delete("engine_horizon"),
                                          schema_argument("engine_horizon", 5, 3.2),
                                          parameter_row("engine_horizon", 1, 3.2))),
        ("标量覆盖预算两端", sequence(ai("buy_beam", 5), parameter_row("buy_beam", 1, 5),
                                    parameter_row("buy_beam", 2, 5), parameter_row("buy_beam", 3, 5))),
    ]


def main():
    baseline, _, _ = checker.validate(ROOT)
    if baseline:
        print("探针前基线未通过，未进行任何变异：\n  - " + "\n  - ".join(baseline))
        return 1
    snapshot = {path: (ROOT / path).read_text() for path in INPUTS}
    trials = probes(snapshot)
    failures = []
    positives = positive_probes(snapshot)
    with tempfile.TemporaryDirectory(prefix="balance-number-probe-") as directory:
        root = pathlib.Path(directory)
        for name, mutate, expected in [(name, mutate, None) for name, mutate in positives] + trials:
            for relative, text in snapshot.items():
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text)
            try:
                mutate(root)
                errors, _, _ = checker.validate(root)
            except (OSError, ValueError, KeyError, IndexError) as error:
                failures.append("%s：探针执行错误：%s" % (name, error))
                continue
            if expected is None:
                if errors:
                    failures.append(name + "：合法覆盖被错误拒绝：" + "；".join(errors))
            elif not errors:
                failures.append(name + "：改坏后检查仍通过")
            elif not any(expected in error for error in errors):
                failures.append("%s：诊断未指向变异点，期望「%s」，实际：%s" % (
                    name, expected, "；".join(errors)[:240]))
        for relative, text in snapshot.items():
            (root / relative).write_text(text)
        def shift_numbers(value):
            if isinstance(value, dict):
                return {key: shift_numbers(child) for key, child in value.items()}
            if isinstance(value, list):
                return [shift_numbers(child) for child in value]
            return value + 1 if isinstance(value, (int, float)) and not isinstance(value, bool) else value
        varied = shift_numbers(json.loads(snapshot["data/cards.json"]))
        (root / "data/cards.json").write_text(json.dumps(varied, ensure_ascii=False))
        errors, _, _ = checker.check_card_table.validate(root)
        if errors:
            failures.append("全卡表数字扰动后符号引用不应失效：" + "；".join(errors))
        # 恢复只发生在临时副本，证明多个负例没有给后续用例遗留状态。
        for relative, text in snapshot.items():
            (root / relative).write_text(text)
        errors, _, _ = checker.validate(root)
        if errors:
            failures.append("临时副本恢复基线后未通过：" + "；".join(errors))
    if failures:
        print("探针失败（%d/%d）：\n  - %s" % (len(failures), len(trials) + len(positives) + 1, "\n  - ".join(failures)))
        return 1
    print("探针通过：基线及 %d 个合法卡表/阈值/AI调参正例及全卡表数字扰动通过，%d 个变异均被定位；所有写入仅在临时目录"
          % (len(positives), len(trials)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
