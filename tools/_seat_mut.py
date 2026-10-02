#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""座位映射的变异检查（一次性核对，不进 run_tests）。

把 main.gd / settle_layout.gd 里的座位引用逐个改回硬编码常量，
确认 test_seat_map.gd 每次都能报红。全 MISS 说明判据没被测过。
"""
import re
import shutil
import subprocess
import sys

GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
TEST = "tests/test_seat_map.gd"

# (文件, 变异前, 变异后, 说明)
MUTS = [
    ("scenes/main.gd", "my_seat", "GameState.PLAYER", "我方座位 → 硬编码 PLAYER"),
    ("scenes/main.gd", "foe_seat", "GameState.AI", "对手座位 → 硬编码 AI"),
    ("scenes/settle_layout.gd", "_main.my_seat", "GameState.PLAYER", "落点我方 → 硬编码"),
    ("scenes/settle_layout.gd", "_main.foe_seat", "GameState.AI", "落点对手 → 硬编码"),
]


def run_test() -> tuple[int, str]:
    """跑一遍测试。超时必须有：变异可能让 main.tscn 加载失败，
    测试跑不到 finish() 就永远不 quit（实测挂了 35 分钟）。
    挂住也算 KILLED —— 变异确实被发现了，只是以最难看的方式"""
    try:
        r = subprocess.run([GODOT, "--headless", "-s", TEST],
                           capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 124, "（超时：测试没跑到 finish，多半是变异让脚本加载失败）"


## 不参与变异的行：注释、座位声明、以及 set_seats 自己的赋值。
## set_seats 里那两句是**定义** my_seat 的地方，把它改成常量等于删掉这个机制，
## 而且 `GameState.PLAYER = mine` 是给常量赋值 —— 脚本直接编译不过，
## 测的就不是「漏了一处硬编码」而是「文件坏了」
SKIP_PREFIX = ("#", "var my_seat", "var foe_seat", "my_seat = mine", "foe_seat = foe")


def sites(path: str, needle: str) -> list[int]:
    out = []
    for i, line in enumerate(open(path).read().splitlines(), 1):
        s = line.strip()
        if s.startswith(SKIP_PREFIX):
            continue
        if needle in line:
            out.append(i)
    return out


def mutate_line(path: str, lineno: int, old: str, new: str) -> bool:
    lines = open(path).read().splitlines(keepends=True)
    if old not in lines[lineno - 1]:
        return False
    lines[lineno - 1] = lines[lineno - 1].replace(old, new)
    open(path, "w").writelines(lines)
    return True


def main() -> int:
    code, out = run_test()
    if code != 0:
        print("基线就是红的，先修基线：")
        print(out)
        return 1
    print("基线绿 ✓\n", flush=True)

    killed = missed = 0
    for path, old, new, label in MUTS:
        backup = f"/tmp/_seatmut_{path.replace('/', '_')}"
        shutil.copy(path, backup)
        for ln in sites(path, old):
            shutil.copy(backup, path)
            if not mutate_line(path, ln, old, new):
                continue
            c, o = run_test()
            if c == 124:
                tag = "HANG  "
                killed += 1
            elif c != 0:
                tag = "KILLED"
                killed += 1
            else:
                tag = "MISS  "
                missed += 1
                m = re.search(r"结果：(\d+) 通过 / (\d+) 失败", o)
                tag += f" ({m.group(0) if m else '没跑出结果行'})"
            print(f"  [{tag}] {path}:{ln}  {label}", flush=True)
        shutil.copy(backup, path)

    print(f"\n杀死 {killed} / 漏过 {missed}")
    return 1 if missed else 0


if __name__ == "__main__":
    sys.exit(main())
