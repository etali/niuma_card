#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""用合成定义复现Q5的比较维度缺口，不改卡表，也不改检查算法。

用法：python3 tools/audit_balance_metrics.py
引擎采集器Q1/Q2/Q4反例见同名 .gd 工具。
"""
from copy import deepcopy

from check_card_values import check_pareto


def main():
    # 这是反例用的虚构定义，不是任何真实卡牌的推荐数值。
    common = dict(kind="product", tier=1, recipe_res="cash", output_res="user")
    cards = {
        "expensive": dict(common, name="昂贵高产", price=100, recipe_n=2, output_n=5),
        "affordable": dict(common, name="便宜可买", price=1, recipe_n=3, output_n=4),
    }
    bad = []
    check_pareto(cards, bad, set())
    print("Q5: price_expensive=%d price_affordable=%d flagged_as_dominated=%s" % (
        cards["expensive"]["price"], cards["affordable"]["price"], bool(bad)))
    print("  局面若只能购买后者，局部配方—产出支配就不能证明后者无用。")
    different_outputs = deepcopy(cards)
    different_outputs["expensive"]["output_res"] = "cash"
    changed = []
    check_pareto(different_outputs, changed, set())
    print("Q5: different_output_resources=true comparison_unchanged=%s" % (bad == changed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
