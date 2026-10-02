#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""历史静态配置筛查；不属于当前手动调参的 Q1–Q9。

生产卡按配方资源定线，检查单张升级产物的效率/产量、T1来源覆盖，
以及同线同档的配方—产出两维支配；还检查传说不能有正产出。
这些是局部筛查，不能证明升级在任何局面都划算，或被比较卡牌没有使用价值。

已登记违反只打印；新增违反或过期登记使检查失败。计数算法本轮未替换。
历史诊断入口：python3 tools/check_card_values.py。当前观测指标由 tools/balance/scoring.gd 计算，本文件不参与模拟评分或配置淘汰。
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# 命名例外只描述当前表的检查结果；改卡后需重审，不能当作设计目标。
# key为(目标, 来源)。这里保留本文件说明的局部比较算法。
KNOWN_TIER = {}
# 口径一「没有升级目标」的已登记项：八张 T1 里只有它没被任何 T2 认
KNOWN_ORPHAN = {
    "chunwan": "春晚冠名没有升级目标 —— 百亿补贴的来源本该是它",
}
# key为(局部支配方, 被比较方)；检查只使用配方和产出，不读取说明中的价格。
KNOWN_PARETO = {
    ("waimai", "pinshaoshao"): "拼少少这一轮从变现线翻到拉新线（换掉了百亿补贴的跨线违反），"
                               "落点撞在外卖补贴的支配下：配方 6 > 5、产出同为 2、标价 6 > 4",
}


def load():
    d = json.loads((ROOT / "data" / "cards.json").read_text())
    cards = {k: v for k, v in d.items() if not k.startswith("_") and isinstance(v, dict)}
    return cards


def name(cards, def_id):
    return cards.get(def_id, {}).get("name", def_id)


def products(cards):
    """参与结算的生产卡。传说卡不在里面（kind 是 legend，没有产出）"""
    return {k: v for k, v in cards.items() if v.get("kind") == "product"}


def line(v):
    """这张卡在哪条线上。配方资源定线：吃用户吐现金 = 变现线，反过来 = 拉新线"""
    return "变现线" if v.get("recipe_res") == "user" else "拉新线"


def rate(v):
    """此静态筛查的转化率 = 结算产出 ÷ 配方数量，不计材料和回合成本。"""
    return v["output_n"] / v["recipe_n"]


def check_legend_exception(cards, bad):
    """口径一的例外只给不参与结算的卡。

    README.md §「2.7 升级」规定传说卡不参与普通生产；正产出字段不应绕过此筛查。
    没有这一条，给传说卡加产出会**静默地**绕过整条口径一
    """
    for def_id, v in cards.items():
        if v.get("kind") != "legend":
            continue
        if int(v.get("output_n", 0)) > 0:
            bad.append(
                "口径一的传说卡例外失效：「%s」现在有产出（%d）了，"
                "不再满足本脚本跳过传说卡生产效率比较的前提"
                % (name(cards, def_id), v["output_n"])
            )


def check_tier(cards, bad, known_hits):
    """口径一：升级要更值（纵向，跨档比）。

    一条 T2 要同时满足：转化率 > 它认的那张 T1、总产出 > 它认的那张 T1。
    比的是单张产物与单张来源；没有计入实际材料数量、合成回合或未来机会成本。
    """
    prod = products(cards)
    for def_id, v in sorted(prod.items()):
        src = v.get("upgrade_from")
        if not src or src not in prod:
            continue
        s = prod[src]
        why = []
        if line(v) != line(s):
            why.append("来源跨线（%s → %s）" % (line(s), line(v)))
        if rate(v) <= rate(s):
            why.append("转化率 %.2f → %.2f 没有严格升" % (rate(s), rate(v)))
        if v["output_n"] <= s["output_n"]:
            why.append("总产出 %d → %d 没有严格升" % (s["output_n"], v["output_n"]))
        if not why:
            continue
        msg = "「%s」←「%s」：%s" % (name(cards, def_id), name(cards, src), "；".join(why))
        key = (def_id, src)
        if key in KNOWN_TIER:
            known_hits.add(key)
        else:
            bad.append("口径一（升级要更值）" + msg)


def check_orphan(cards, bad, known_hits):
    """旧口径：检查T1是否被其他生产卡的upgrade_from引用。

    不查询ComboRules实际路线，所以未被引用不等于不能直接合成传说。
    """
    prod = products(cards)
    claimed = {v.get("upgrade_from") for v in prod.values() if v.get("upgrade_from")}
    for def_id, v in sorted(prod.items()):
        if int(v.get("tier", 0)) != 1 or def_id in claimed:
            continue
        msg = "「%s」（%s）没有任何 T2 认它当来源" % (name(cards, def_id), line(v))
        if def_id in KNOWN_ORPHAN:
            known_hits.add(def_id)
        else:
            bad.append("口径一（升级要更值）" + msg)


def check_pareto(cards, bad, known_hits):
    """同线同档的配方—产出局部支配；维度为（−recipe_n, output_n）。

    当前未比较output_res、价格、典当、权重与升级出口。既有诊断中的
    “废卡”是旧口径用语，不能解释成任何局面都无用；本轮保持判定和输出兼容。
    """
    prod = products(cards)
    groups = {}
    for def_id, v in prod.items():
        groups.setdefault((line(v), int(v["tier"])), []).append(def_id)
    for key in sorted(groups):
        ids = sorted(groups[key])
        for a in ids:
            for b in ids:
                if a == b:
                    continue
                va, vb = prod[a], prod[b]
                # a 支配 b：两维都不差，且至少一维严格更好
                ge = va["recipe_n"] <= vb["recipe_n"] and va["output_n"] >= vb["output_n"]
                gt = va["recipe_n"] < vb["recipe_n"] or va["output_n"] > vb["output_n"]
                if ge and gt:
                    if (a, b) in KNOWN_PARETO:
                        known_hits.add((a, b))
                        continue
                    bad.append(
                        "口径二（同类要有取舍）%s T%d：「%s」（配方 %d / 产出 %d）"
                        "严格支配「%s」（配方 %d / 产出 %d）—— 后者是废卡"
                        % (key[0], key[1], name(cards, a), va["recipe_n"], va["output_n"],
                           name(cards, b), vb["recipe_n"], vb["output_n"])
                    )


def main():
    cards = load()
    bad = []
    known_hits = set()
    check_legend_exception(cards, bad)
    check_tier(cards, bad, known_hits)
    check_orphan(cards, bad, known_hits)
    check_pareto(cards, bad, known_hits)

    # 登记表里写着、实际已经不违反了，需要同步删除登记并核对本文件的局部比较口径。
    stale = []
    for key, why in KNOWN_TIER.items():
        if key not in known_hits:
            stale.append("「%s」←「%s」已经不违反了（登记的理由：%s）"
                         % (name(cards, key[0]), name(cards, key[1]), why))
    for def_id, why in KNOWN_ORPHAN.items():
        if def_id not in known_hits:
            stale.append("「%s」已经有升级目标了（登记的理由：%s）"
                         % (name(cards, def_id), why))
    for key, why in KNOWN_PARETO.items():
        if key not in known_hits:
            stale.append("「%s」已经不支配「%s」了（登记的理由：%s）"
                         % (name(cards, key[0]), name(cards, key[1]), why))
    if stale:
        bad.append("登记表过期（改好了就把它从 tools/check_card_values.py 的表里删掉，"
                   "同时核对本脚本的局部筛查说明）：")
        bad.extend("  " + s for s in stale)

    n_known = len(KNOWN_TIER) + len(KNOWN_ORPHAN) + len(KNOWN_PARETO)
    if bad:
        print("历史静态筛查：新增违反 %d 处（已登记 %d 处）：" % (len(bad), n_known))
        for b in bad:
            print("  - " + b)
        return 1
    print("历史静态筛查：零新增违反（%d 张生产卡；已登记 %d 处待复核，口径见本脚本说明）"
          % (len(products(cards)), n_known))
    return 0


if __name__ == "__main__":
    sys.exit(main())
