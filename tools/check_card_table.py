#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""检查 balance.md 的配置引用与字段覆盖，不要求它复制当前卡牌数值。

C=data/cards.json，A=data/bot.json。所有显式路径必须存在；
卡牌表须覆盖全部当前卡定义及其可调字段。改数值仍通过，错字段/漏卡仍失败。
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PATH = re.compile(r"\b([CA])\.([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]*)*)")
TUNABLE_FIELDS = ("price", "weight", "recipe_res", "recipe_n", "output_res", "output_n",
                  "attack_res", "attack_n", "upgrade_from", "upgrade_dup_n", "pawn")


def documents(root):
    return {"C": json.loads((root / "data/cards.json").read_text()),
            "A": json.loads((root / "data/bot.json").read_text())}


def resolve(data, path):
    node = data
    for key in path.split("."):
        if not isinstance(node, dict) or key not in node:
            raise KeyError(path)
        node = node[key]
    return node


def validate(root=ROOT):
    root = pathlib.Path(root)
    bad = []
    try:
        configs = documents(root)
        cards = {k: v for k, v in configs["C"].items()
                 if not k.startswith("_") and isinstance(v, dict)}
        text = (root / "balance.md").read_text()
        refs = list(PATH.finditer(text))
        if not refs:
            bad.append("balance.md 没有配置字段引用")
        for match in refs:
            try:
                resolve(configs[match[1]], match[2])
            except KeyError:
                bad.append("balance.md 配置引用不存在：" + match[0])
        section = text.split("## 卡牌总表\n", 1)[1].split("\n## ", 1)[0]
        rows = {}
        for line in section.splitlines():
            if not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip("|").split("|")]
            if len(cells) < 3:
                continue
            definition = re.fullmatch(r"`C\.([A-Za-z_][A-Za-z0-9_]*)`", cells[1])
            if definition is None:
                continue
            key = definition[1]
            if key in rows:
                bad.append("卡牌定义行重复：" + key)
            rows[key] = (cells[0], line)
        for key in rows.keys() - cards.keys():
            bad.append("文档引用了不存在的卡牌：" + key)
        for key, card in cards.items():
            if key not in rows:
                bad.append("卡牌表未覆盖：" + key)
                continue
            name, line = rows[key]
            if name != card.get("name"):
                bad.append("卡牌名称与配置不一致：" + key)
            fields = TUNABLE_FIELDS if card.get("kind") != "unit" else ("res",)
            for field in fields:
                if field in card and f"`C.{key}.{field}`" not in line:
                    bad.append(f"{key} 未引用字段：C.{key}.{field}")
            if card.get("kind") != "unit" and "pawn" not in card and f"`pawn(C.{key})`" not in line:
                bad.append(key + " 未引用派生典当函数")
            # 字段必须是路径，而不是某次生成时的数字副本。
            if any(re.fullmatch(r"[-+]?\d+(?:\.\d+)?", c.strip()) for c in line.strip("|").split("|")[2:]):
                bad.append(key + " 数值列仍有具体卡牌数字")
        return bad, len(cards), len(refs)
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        return ["配置引用检查输入错误：" + str(error)], 0, 0


def main():
    bad, cards, refs = validate()
    if bad:
        print("配置引用检查失败：")
        for problem in bad:
            print("  - " + problem)
        return 1
    print(f"balance.md 配置引用有效（{cards} 张卡，{refs} 处路径；不固定卡牌数值）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
