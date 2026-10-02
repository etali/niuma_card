#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""禁止代码和文档里出现 `文件:行号` 这类引用 —— 一律写「文件名 + 函数名」。

**这个脚本是从 _check_doc_lines.py 翻过来的**，那份的活是「验行号指得对不对」。
翻的理由写在它自己的 docstring 里：balance.md 三处把 `recipe_pay_n` 那道闸指在
`combo_rules.gd:139`，实际在 140，从写下那天起就偏一行，而它一路报「异常 0 条」——
它只查越界，不查指错。而全仓扫一遍发现的不是「个别偏了」：

  31 处带文件名的引用，**没有一处指得准**。
  最狠的三种：
    · tests/test_foe_drag.gd 指 `net_transport.gd:49` —— 那是**空行**
    · tests/test_buff_output_x2.gd 指 `settle.gd:110` —— 那个路径**根本不存在**
      （真货在 engine/settle.gd，靠基名 rglob 才碰对）
    · tests/test_attack_dbl.gd 说「下面第 124 行」，而 124 在**上面**，
      真正问那件事的是再往下十来行

行号会漂，函数名不会 —— 函数改名了 grep 一下就找回来，行号错了什么线索都不留，
而读注释的人会当真。这就是「行号引用」比「不精确」严重的地方：它主动骗人。

**只拦人写的引用，不拦运行时生成的位置。** Godot 报错里的
`core/object/object.cpp:2536`、检查脚本自己印的 `balance.md:412 的折价率应是…`，
那些是程序当场算出来的，越具体越好。所以匹配限定在**注释和文档正文**里，
且只认仓里真有的那些扩展名。
"""
import re
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# `文件.扩展名:行号`。扩展名限定成仓里真会被引的那几种：
# 放宽到任意扩展名就会撞上 Godot 报错里的 .cpp/.h（那是运行时生成的位置，合法）
LINE_REF = re.compile(
    r'\b([A-Za-z_][\w/]*\.(?:gd|py|md|sh|json|tscn|cfg))[:：](\d+)')
# 「第 N 行」。指文档表格的第几项也算 —— 有人插一行就错位，和代码行号一样脆
NTH_LINE = re.compile(r'第 ?\d+ ?行')
# 光秃秃的 `:58`，不带文件名 —— 「本文件 :58 那段」这种写法。
# 上面那条要求文件名打头，接不住它：实测 engine/combo_rules.gd 里
# 就有一句「本文件 :58 那段」，而 58 行是 `evaluate()` 开头的字典字面量，
# 真正说的那段 Buff 扫描在三十行开外，写下来那天大概是对的
#
# **冒号前面必须是空白或开括号/顿号**，这是和端口、比例、时间分开的唯一线索：
# `ws://[::1]:8910`、`3:4 → 1200×1600`、`9:00` 的冒号前紧贴着字母或数字，
# 而「本文件 :58」「（:285 这道闸」的冒号前是空白或括号。
# 不加这条前视就会把文档里的连接地址和画幅比例误报成行号引用。
BARE_LINE = re.compile(r'(?<=[\s(（、,，])([:：]\d+)')
# GitHub 式的 `#L120`（贴链接时最容易带进来的形状）
GH_LINE = re.compile(r'#L\d+(?:-L?\d+)?')

SCAN_EXT = {'.gd', '.py', '.md', '.sh'}
SKIP_DIRS = {'.godot', '.git', 'addons', 'build'}  # 编译缓存里的第三方源码不属于项目注释
# 这份脚本自己要在 docstring 里举反例（`combo_rules.gd:139` 那些），
# 不跳过的话它永远拦下自己
SKIP_FILES = {'tools/check_no_line_refs.py'}


def prose_lines(path: Path, lines: list) -> list:
    """哪些行是注释 / 文档正文（而不是会跑的代码）。返回 [(行号, 内容)]。

    只在这些地方拦。代码里出现 `x.gd:12` 的样子基本只有两种：
    拼字符串（那是运行时位置，合法）、或者字典键 —— 都不该拦。

    **python 的多行 docstring 要跟状态**，不能只看「这一行以什么开头」：
    第一版就是那么写的，于是 _check_doc_lines.py 那句 `combo_rules.gd:139`
    整个漏掉了 —— 它在 docstring 第 7 行上，前面既没有 `#` 也没有三引号。
    而那句恰好是**全仓最后一处**行号引用，「0 处」于是看着像扫干净了
    """
    if path.suffix == '.md':
        return list(enumerate(lines, 1))
    out = []
    in_doc = ''          # 当前把哪种三引号当作未闭合（'' = 不在块里）
    for i, line in enumerate(lines, 1):
        s = line.lstrip()
        if in_doc:
            out.append((i, line))
            if in_doc in line:
                in_doc = ''
            continue
        if s.startswith('#'):
            out.append((i, line))
            continue
        for q in ('"""', "'''"):
            if s.startswith(q):
                out.append((i, line))
                # 同一行里再出现一次就是单行 docstring，没进块
                if s.count(q) < 2:
                    in_doc = q
                break
    return out


def project_sources():
    # 在进入目录前排除编译缓存，不能先rglob整棵引擎源码再过滤。
    for directory, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            path = Path(directory) / name
            if path.suffix in SCAN_EXT:
                yield path


def scan():
    hits = []
    for p in project_sources():
        rel = p.relative_to(ROOT).as_posix()
        if rel in SKIP_FILES:
            continue
        try:
            lines = p.read_text(encoding='utf-8').splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in prose_lines(p, lines):
            for name, num in LINE_REF.findall(line):
                hits.append((rel, i, '%s:%s' % (name, num), line.strip()))
            for pat in (NTH_LINE, BARE_LINE, GH_LINE):
                for m in pat.findall(line):
                    hits.append((rel, i, m, line.strip()))
    return hits


## 自测夹具：`(文本, 该不该抓)`。**这一份是这个脚本能被变异盯住的唯一办法。**
##
## 全仓扫完现在是 0 处 —— 于是把正则改弱、把 docstring 跟丢，扫出来照样 0 处、
## 照样退出 0，「判据被掏空而它自己看不见」（同一个病在 test_config_complete
## 的扒取范围上犯过一次，见 mutate_check.py 48b）。夹具把每条模式各钉一个例子，
## 改弱任何一条当场有人喊
SELFTEST = [
    ('# 见 engine/settle.gd:123 那段', True),          # 文件名 + 行号
    ('# 见下面第 42 行', True),                        # 第 N 行
    ('# 本文件 :77 那段', True),                       # 裸冒号 + 数字
    ('# 见 https://x/a/b.gd#L120', True),              # GitHub 式
    ('# 端口 ws://[::1]:8910、比例 3:4、时间 9:00', False),  # 冒号前贴着字母数字
    ('# 搬过位置的那个函数见 card_db.gd 的 pawn_of()', False),  # 正确写法
]


def selftest() -> list:
    """夹具逐条过一遍匹配，返回不符合预期的说法。

    只验**匹配本身**（不含 prose_lines 的取舍）：那部分由 SELFTEST_DOC 管
    """
    bad = []
    for text, want in SELFTEST:
        got = bool(LINE_REF.search(text)) or any(
            p.search(text) for p in (NTH_LINE, BARE_LINE, GH_LINE))
        if got != want:
            bad.append('夹具「%s」应%s被拦，实际%s' % (
                text, '' if want else '不', '拦下了' if got else '放过了'))
    return bad


## 取舍 prose 的自测：python 的多行 docstring **续行**也算正文。
## 这条单独钉，因为第一版就漏在这儿：`is_prose()` 只看「这一行以什么开头」，
## 于是 docstring 第 7 行上那句 `combo_rules.gd:139` 整个没被看见 ——
## 而那恰好是全仓最后一处，「0 处」于是看着像扫干净了
SELFTEST_DOC = [
    '"""头一行',
    '',
    '续行里写了 engine/settle.gd:123',
    '"""',
    'var x = 1  # 这行是代码，里面的 a.gd:9 不该拦',
]


def selftest_doc() -> list:
    got = [i for i, _ in prose_lines(Path('x.py'), SELFTEST_DOC)]
    if got != [1, 2, 3, 4]:
        return ['docstring 取舍：应取 1~4 行为正文，实际取 %s' % got]
    return []


def main():
    bad = selftest() + selftest_doc()
    if bad:
        # 前缀和下面的失败行一致，mutate_check 才认得出「红了」
        print('行号引用检查自身的夹具就没过（%d 条），先修它：' % len(bad))
        for b in bad:
            print('  - %s' % b)
        return 1
    hits = scan()
    if hits:
        # 失败行前缀 `  - ` 和 check_balance_numbers 对齐：
        # tools/mutate_check.py 靠它认出「python 判据红了」（见那边 _fail_lines）
        print('注释和文档里不许写行号引用（%d 处），改成「文件名 + 函数名」：'
              % len(hits))
        for rel, i, ref, ctx in hits:
            # 「写了行号引用」这几个字必须落在**这一行**里，不能只写在表头：
            # mutate_check 的捕获判定只在 `  - ` 开头的失败行里找关键字
            # （见那边 _fail_lines），写表头的话登记进来永远是 MISS
            print('  - %s:%d 写了行号引用「%s」，改成函数名 → %s'
                  % (rel, i, ref, ctx[:70]))
        return 1
    n_files = sum(1 for _ in project_sources())
    # 夹具条数也印出来：只印「0 处」的话，正则被改成永不匹配时
    # 这一行长得和扫干净了一模一样
    print('行号引用检查：%d 个文件，0 处（夹具 %d 条已过）'
          % (n_files, len(SELFTEST) + 1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
