#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""核对配置变量引用、README数值展示与AI参数表。

balance.md 只保存字段引用，由 check_card_table 检查字段存在性和覆盖。
README 中明确展示的值仍与卡表核对；AI参数表按有效配置核对，不强迫复制fallback。
手动调参的11项观测值由 tools/balance/scoring.gd 定义，不依赖阈值配置。

锚点缺失或重复同样失败，避免正文重写后检查静默失效。validate(root)
允许探针在临时目录验证，不需要改写工作区配置。
"""
import csv
import json
import math
import pathlib
import re
import sys

import check_card_table

ROOT = pathlib.Path(__file__).resolve().parent.parent

def _round_half_up(x):
    """正数与 Godot roundi 一致。"""
    return math.floor(x + 0.5)


def pawn_value(def_id, cards, game):
    """独立复刻 CardDB.pawn_value 的公式，数值始终来自卡表。"""
    card = cards[def_id]
    if "pawn" in card:
        return int(card["pawn"])
    if card.get("kind") == "unit":
        return int(game["pawn_user"]) if card.get("res") == "user" else 0
    rate = float(game["pawn_rate"])
    price = int(card.get("price", -1))
    if price > 0:
        return max(1, _round_half_up(price / rate))
    source = card.get("upgrade_from", "")
    if source in cards:
        count = max(2, int(card.get("upgrade_dup_n", 2)))
        return max(1, _round_half_up(int(cards[source]["price"]) * count / rate))
    return 0


def facts(data, cards):
    """README仍展示的规则事实，按当前配置推导。"""
    game = data["_game"]
    counts = {int(c["upgrade_dup_n"]) for c in cards.values()
              if c.get("tier") == 2 and "upgrade_dup_n" in c}
    out = {"pawn_rate_s": "÷%g" % float(game["pawn_rate"]),
           "pawn_user": game["pawn_user"],
           "t2_dup_n": next(iter(counts)) if len(counts) == 1 else -1}
    for key in ("dujiaoshou", "guomin", "shangshi"):
        out["pawn_" + key] = pawn_value(key, cards, game)
    return out


def readme_checks(f):
    wants = [
        ("用户卡的价钱", "用户卡 %d 现金/张" % f["pawn_user"]),
        ("可购卡的折价率", "标价 %s" % f["pawn_rate_s"]),
        ("T2 的折价率", "下级材料购牌价之和 %s" % f["pawn_rate_s"]),
        ("T2 的升级张数", "同名下级卡×%d" % f["t2_dup_n"]),
    ]
    for label, key in (("独角兽", "dujiaoshou"), ("国民应用", "guomin"), ("上市敲钟", "shangshi")):
        wants.append((label + "的回收价", "%s %d" % (label, f["pawn_" + key])))
    return [("**典当行**", 1, wants)]


def _present(line, want):
    """数字不能被同一行中更长的数字蒙混，其余按上下文片段匹配。"""
    if isinstance(want, bool):
        raise TypeError("期望值不接受 bool")
    if isinstance(want, (int, float)):
        return re.search(r"(?<![\d.])%s(?![\d.])" % re.escape("%g" % want), line) is not None
    return str(want) in line


def _number(value, allow_text=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) and not (allow_text and isinstance(value, str)):
        raise ValueError("必须是 int/float 数值，不能是布尔值或字符串")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("数值参数必须有限")
    return number


def _same_number(actual, expected):
    """仅 Markdown 单元格允许用字符串表示数值。"""
    try:
        return math.isclose(_number(actual, allow_text=True), _number(expected), rel_tol=0.0, abs_tol=1e-9)
    except (TypeError, ValueError):
        return False


def _value_problem(value, spec):
    try:
        number = _number(value)
    except (TypeError, ValueError) as error:
        return str(error)
    if not spec["min"] <= number <= spec["max"]:
        return "超出范围 [%g, %g]" % (spec["min"], spec["max"])
    if spec["kind"] == "int" and number != int(number):
        return "整数参数不能含小数"
    # 自动推导的只读曲线保留原始精度，运行时使用时才量化。
    if spec.get("read_only"):
        return None
    steps = (number - spec["min"]) / spec["step"]
    if not math.isclose(steps, round(steps), rel_tol=0.0, abs_tol=1e-7):
        return "未对齐步长 %g（起点 %g）" % (spec["step"], spec["min"])
    return None


def read_parameter_schema(source):
    """读取注册规格及 helper 的 kind/min/max/step/default，拒绝不支持的格式。"""
    constants = dict(re.findall(
        r"^const\s+([A-Za-z_][A-Za-z_0-9]*)\s*(?::\s*(?:int|float)\s*)?:?=\s*([^\n#]+)",
        source, re.MULTILINE))

    def number(token, seen=()):
        token = token.strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", token):
            if token not in constants:
                raise ValueError("未定义的数值常量：" + token)
            if token in seen:
                raise ValueError("数值常量循环引用：" + " -> ".join((*seen, token)))
            return number(constants[token], (*seen, token))
        try:
            return _number(token, allow_text=True)
        except ValueError as error:
            raise ValueError("不支持的数值声明：" + token) from error

    section = source.split("func parameter_schema()", 1)[1].split("\nfunc ", 1)[0]
    calls = re.findall(r"^\s*_(int|float)\((.*)\),\s*$", section, re.MULTILINE)
    if not calls or len(calls) != len(re.findall(r"\b_(?:int|float)\(", section)):
        raise ValueError("parameter_schema 中有不能解析的参数声明")
    targets_match = re.search(r"const STRENGTH_TARGETS := (\{.*?\})\n", source, re.DOTALL)
    # 只替换字典值位置的常量引用，不执行 GDScript，也不改动键名。
    targets_text = re.sub(
        r'(:\s*)([A-Za-z_][A-Za-z_0-9]*)(?=\s*[,}])',
        lambda match: match[1] + json.dumps(number(match[2])),
        targets_match[1]) if targets_match else "{}"
    targets = json.loads(targets_text)
    targets = {key: _number(value) for key, value in targets.items()}
    schema = {}
    for helper, arguments in calls:
        values = next(csv.reader([arguments], skipinitialspace=True))
        if len(values) != (8 if helper == "int" else 7):
            raise ValueError("参数声明的字段数不正确：" + arguments)
        key = values[0]
        if key in schema:
            raise ValueError("参数规格键重复：" + key)
        names = ["lower", "upper", "weak", "strong"] if helper == "int" else ["lower", "upper", "value"]
        bindings = {name: number(value) for name, value in zip(names, values[3:-1])}
        body = source.split("func _" + helper + "(", 1)[1].split("\nfunc ", 1)[0]
        kind_match = re.search(r'"kind"\s*:\s*"([^"\n]+)"', body)
        if kind_match is None or kind_match[1] not in ("int", "float") or kind_match[1] != helper:
            raise ValueError("参数规格 %s 的 kind 与声明 helper 不匹配" % key)
        spec = {"kind": kind_match[1]}
        for field in ("min", "max", "step", "default"):
            match = re.search(r'"%s"\s*:\s*([A-Za-z_][A-Za-z_0-9]*|[-+0-9.eE]+)' % field, body)
            if match is None:
                raise ValueError("参数规格 %s 缺少可解析的 %s" % (key, field))
            token = match[1]
            spec[field] = bindings[token] if token in bindings else number(token)
        if helper == "int":
            spec["strength_target"] = targets.get(key)
            spec["strength_points"] = [[0, bindings["weak"]], [0.5, bindings["strong"]],
                                       [1, targets.get(key, bindings["strong"])]]
        else:
            spec["strength_points"] = [[s, bindings["value"]] for s in (0, 0.5, 1)]
        override = re.search(
            r'\n\tif key == "' + re.escape(key) + r'":\n(.*?)(?=\n\t[^\t]|\Z)',
            body, re.DOTALL)
        if override:
            for field in ("min", "max", "step", "default"):
                assignment = re.search(r'spec\["' + field + r'"\]\s*=\s*([^\n#]+)', override[1])
                if assignment:
                    spec[field] = number(assignment[1])
            spec["read_only"] = bool(re.search(r'spec\["read_only"\]\s*=\s*true\b', override[1]))
            if 'spec["strength_points"]' in override[1]:
                # 当前只读计算比例由数值常量和三次曲线生成；格式变更须明确报错。
                minimum = re.search(r'var minimum := float\((\w+)\)/(\w+)', override[1])
                count = re.search(r'for index in range\((\d+)\):', override[1])
                divisor = re.search(r'var s := index/([0-9.]+)', override[1])
                if not (spec["read_only"] and minimum and count and divisor
                        and 'points.append([s,minimum+(1.0-minimum)*s*s*s])' in override[1]):
                    raise ValueError("不支持的参数强度曲线：" + key)
                low = number(minimum[1]) / number(minimum[2])
                positions = [i / number(divisor[1]) for i in range(int(count[1]))]
                if not positions or positions[0] != 0 or positions[-1] != 1:
                    raise ValueError("参数强度曲线必须覆盖0到1：" + key)
                spec["strength_points"] = [[s, low + (1 - low) * s ** 3] for s in positions]
        if spec["min"] > spec["max"] or spec["step"] <= 0:
            raise ValueError("参数规格 %s 的边界或步长无效" % key)
        if spec["kind"] == "int" and any(spec[field] != int(spec[field]) for field in ("min", "max", "step")):
            raise ValueError("参数规格 %s 的整数边界和步长必须是整数" % key)
        spec["defaults"] = [point[1] for point in spec["strength_points"]]
        for value in [spec["default"]] + spec["defaults"]:
            problem = _value_problem(value, spec)
            if problem:
                raise ValueError("参数规格 %s 的默认值/端点无效：%s" % (key, problem))
        schema[key] = spec
    return schema


def configuration_points(raw, spec):
    """校验标量、旧两端数组或新强度锚点，返回有序锚点与问题列表。"""
    problems = []
    if not isinstance(raw, list):
        points = [[0, raw], [1, raw]]
    elif raw and isinstance(raw[0], list):
        points = raw
        previous = -1
        for point in points:
            if not isinstance(point, list) or len(point) != 2:
                return [], ["强度锚点必须为[位置,数值]"]
            try:
                position = _number(point[0])
            except (TypeError, ValueError):
                return [], ["强度锚点位置必须为有限数值"]
            if position < 0 or position > 1 or position <= previous:
                problems.append("强度锚点必须在0到1间严格递增")
            previous = position
        if points[0][0] != 0 or points[-1][0] != 1:
            problems.append("强度锚点必须覆盖0到1")
    elif len(raw) == 2:
        points = [[0, raw[0]], [0.5, raw[1]], [1, spec.get("strength_target") if spec.get("strength_target") is not None else raw[1]]]
    else:
        return [], ["强度范围必须有两个端点，或提供[位置,数值]锚点"]
    for _, value in points:
        problem = _value_problem(value, spec)
        if problem:
            problems.append(problem)
    return points, problems


def document_values(raw, spec):
    """整数参数文档展示0/0.5/1三锚点，固定评估系数展示默认强度0.5。"""
    points, problems = configuration_points(raw, spec)
    if problems:
        raise ValueError("；".join(problems))
    values = []
    for strength in ((0, 0.5, 1) if spec["kind"] == "int" or spec.get("read_only") else (0.5,)):
        value = points[-1][1]
        for left, right in zip(points, points[1:]):
            if strength < right[0]:
                value = left[1] + (right[1] - left[1]) * (strength - left[0]) / (right[0] - left[0])
                break
        # Godot在输出前按schema步长量化，两端数组的中点也必须一致。
        value = spec["min"] + _round_half_up((value - spec["min"]) / spec["step"]) * spec["step"]
        values.append(value)
    return values

def check_ai_tables(root, ai_config, bad):
    """校验合法配置及其文档值；显式配置允许覆盖规格默认值。"""
    schema = read_parameter_schema((root / "engine" / "ai_turn_strategy.gd").read_text())
    configured = ai_config["search"]["ai"]
    lines = (root / "ai.md").read_text().splitlines()
    headers = [i for i, line in enumerate(lines)
               if re.match(r"^\|\s*参数\s*\|\s*强度\s*0\s*\|\s*强度\s*0\.5\s*\|\s*强度\s*1\s*\|", line)]
    if len(headers) != 1:
        raise ValueError("ai.md 强度参数表表头命中 %d 行，应为 1 行" % len(headers))
    table_start = headers[0]
    count = 0
    unknown = set(configured) - set(schema) - {"profile_version"}
    unknown = {key for key in unknown if not key.startswith("_")}
    if unknown:
        bad.append("data/ai.json.search.ai 包含未注册参数：%s" % "、".join(sorted(unknown)))
    for key, spec in schema.items():
        raw = configured.get(key, spec["strength_points"])
        _, problems = configuration_points(raw, spec)
        if problems:
            bad.append("data/ai.json.search.ai.%s 配置无效：%s" % (key, "；".join(problems)))
            continue
        expected = document_values(raw, spec)
        hits = [(i, line) for i, line in enumerate(lines, 1)
                if i > table_start and re.match(r"^\s*\|\s*`%s`\s*\|" % re.escape(key), line)]
        if len(hits) != 1:
            bad.append("ai.md 参数表 `%s` 命中 %d 行，应为 1 行" % (key, len(hits)))
            continue
        number, line = hits[0]
        columns = [part.strip().strip("`") for part in line.strip().strip("|").split("|")]
        for index, value in enumerate(expected, 1):
            label = "强度%g" % (0, 0.5, 1)[index - 1] if len(expected) == 3 else "默认值"
            if len(columns) <= index or not _same_number(columns[index], value):
                bad.append("ai.md:%d 的 %s %s应是 %g（第%d列）" % (
                    number, key, label, value, index + 1))
            else:
                count += 1
    return count, len(schema)


def validate(root=ROOT):
    """返回 (错误列表, 已核对数值数, 已核对锚点数)，不写入任何文件。"""
    root = pathlib.Path(root)
    bad = []
    try:
        data = json.loads((root / "data" / "cards.json").read_text())
        cards = {key: card for key, card in data.items() if not key.startswith("_")}
        ai_config = json.loads((root / "data" / "ai.json").read_text())
        f = facts(data, cards)
        reference_errors, card_count, reference_count = check_card_table.validate(root)
        bad.extend(reference_errors)
        n_ok = 0
        tables = [("README.md", readme_checks(f))]
        for doc, table in tables:
            lines = (root / doc).read_text().splitlines()
            for anchor, want_n, wants in table:
                hits = [(i, line) for i, line in enumerate(lines, 1) if anchor in line]
                if len(hits) != want_n:
                    bad.append("%s 里锚点「%s」命中 %d 行，应为 %d 行" % (doc, anchor, len(hits), want_n))
                    continue
                for number, line in hits:
                    for label, want in wants:
                        if not _present(line, want):
                            bad.append("%s:%d 的%s应是 %s" % (doc, number, label, want))
                        else:
                            n_ok += 1
        ai_ok, ai_anchors = check_ai_tables(root, ai_config, bad)
        limit_anchor = "无头模拟上限："
        limit_lines = [(i, line) for i, line in enumerate((root / "ai.md").read_text().splitlines(), 1)
                       if limit_anchor in line]
        if len(limit_lines) != 1:
            bad.append("ai.md 里锚点「%s」命中 %d 行，应为 1 行" % (limit_anchor, len(limit_lines)))
        else:
            number, line = limit_lines[0]
            limit = ai_config["simulation"]["max_rounds"]
            if not re.search(r"`simulation\.max_rounds\s*=\s*%s`" % re.escape(str(limit)), line):
                bad.append("ai.md:%d 的 simulation.max_rounds应是 %s" % (number, limit))
            else:
                ai_ok += 1
        return bad, n_ok + ai_ok + reference_count, sum(len(table) for _, table in tables) + ai_anchors + 1 + card_count
    except (OSError, ValueError, KeyError, IndexError, TypeError, ZeroDivisionError) as error:
        bad.append("检查输入或参数规格无效：%s" % error)
        return bad, 0, 0


def main():
    bad, references, anchors = validate()
    if bad:
        print("文档引用、数值或评估器参照不一致（%d 处）：" % len(bad))
        for problem in bad:
            print("  - " + problem)
        return 1
    print("balance.md 引用、README/AI 展示值及评估器参照通过"
          "（%d 处引用，%d 条锚点）" % (references, anchors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
