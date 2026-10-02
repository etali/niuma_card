#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""确认 mutate_check.py 的变异全都不在树里。

两种病，同一个判据抓得住，什么时候跑各自不同：

1. **变异残留**。被 Ctrl-C / kill 打断时 mutate_check 的 finally 可能没跑，
   树里会留着一条改坏的代码 —— 症状是「某个不相干的测试忽然红一条」，
   很难联想到变异脚本。每次中断过 mutate_check 就跑一次这个。

2. **锚点成孤儿**。重构动了变异目标那几行（改缩进、改表达式、把两处合并成
   一个函数），锚点就再也匹配不上。mutate_check 那边报的是 SKIP，
   而 SKIP 混在几百条 OK 里**长得不像失败** —— 那条判据从此不再被验证，
   报表上却什么都看不出来。所以**每次改完变异目标文件都要跑一次这个**，
   不是只在中断之后跑。
   实测：把 game_state.gd 的 pending_pay 改成遍历 _valid_pile_evals 之后，
   「用户配方的摞待付 0」那条的锚点连缩进带表达式一起变了，静静地废了一轮。

判据只问一句：**每条变异的原文是否还在**。
原文在 = 那一处没被替换（replace 只换第一处）。
反过来查「改后文本在不在」会大量误报：变异的改后文本常常是文件里
本来就有的句子（`if false:`、`pass`、某个函数调用），查到了也说明不了什么。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from mutate_check import MUTATIONS, ROOT

bad = 0
for mut in MUTATIONS:
    rel, old = mut[0], mut[1]
    if old not in (ROOT / rel).read_text():
        print("原文不在  %s：%s" % (rel, old.strip()[:60]))
        bad += 1
print("残留检查：%d 条异常 / %d 条变异" % (bad, len(MUTATIONS)))
sys.exit(1 if bad else 0)
