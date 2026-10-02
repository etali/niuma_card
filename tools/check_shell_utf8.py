#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""扫 shell 脚本里「`$VAR` 紧跟全角字符」这一种写法，要求写成 `${VAR}`。

为什么值得单开一条检查：macOS 自带的是 bash 3.2，它认变量名时**不认 UTF-8**，
于是 `"$APP_NAME）"` 里那个「）」的首字节被吃进变量名，变量变成 `APP_NAME\xef`。
后果分两种，都不是「报错说哪儿写错了」：

  - 脚本带 set -u：`unbound variable`，脚本当场死。而中文提示语基本都出现在
    **出错分支**里（「还没构建过（…）」「找不到 Godot：…（…）」），
    所以这个 bug 只在第一次真出错的时候现形 —— 平时全绿
  - 脚本没有 set -u：变量展开成空，**整段地址被吞掉**，而那一句的全部价值
    就是把地址打给人看

启动脚本的报错提示曾出现过这类问题，静态检查可覆盖平时不执行的出错分支。

用法：python3 tools/check_shell_utf8.py     （tools/run_tests.sh 会调）
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 扫哪些：仓库根上的 .command 和 tools 里的 .sh
TARGETS = sorted(ROOT.glob('*.command')) + sorted(ROOT.glob('tools/*.sh'))

# $VAR / $1 后面紧跟一个非 ASCII 字符。${VAR} 和 $(...) 都不算
PAT = re.compile(r'\$(?!\{|\()([A-Za-z_][A-Za-z0-9_]*|\d)([^\x00-\x7f])')

bad = []
scanned = 0
for f in TARGETS:
    for i, line in enumerate(f.read_text(encoding='utf-8').splitlines(), 1):
        stripped = line.lstrip()
        # 注释可能是在解释错误写法，不算违规。
        if stripped.startswith('#'):
            continue
        scanned += 1
        for m in PAT.finditer(line):
            bad.append((f.relative_to(ROOT), i, m.group(1), m.group(2),
                        line.strip()))

if bad:
    print("shell 里有 $VAR 紧跟全角字符（bash 3.2 会把它吃进变量名）：")
    for rel, i, var, ch, text in bad:
        print("  %s:%d  $%s 紧跟「%s」→ 改成 ${%s}" % (rel, i, var, ch, var))
        print("      %s" % text)
    sys.exit(1)

print("shell 全角相邻检查：%d 个文件 / %d 行，0 处" % (len(TARGETS), scanned))
