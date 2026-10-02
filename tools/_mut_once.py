#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""改坏一处 → 跑一个测试 → 必定复原。用法：
    python3 tools/_mut_once.py <文件> <原文> <改成> <测试.gd>
复原在 finally 里，且退出前比对 md5 确认回到原样。
"""
import hashlib
import os
import pathlib
import subprocess
import sys

GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"

# 时间加速，同 tools/run_tests.sh。TEST_SPEED=1 可覆盖
os.environ.setdefault("TEST_SPEED", "5")


def main():
    path, old, new, test = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    p = pathlib.Path(path)
    src = p.read_text(encoding="utf-8")
    before = hashlib.md5(src.encode()).hexdigest()
    if src.count(old) != 1:
        raise SystemExit("原文命中 %d 次，必须恰好 1 次" % src.count(old))
    try:
        p.write_text(src.replace(old, new), encoding="utf-8")
        r = subprocess.run([GODOT, "--headless", "-s", test],
                           capture_output=True, text=True)
        out = r.stdout + r.stderr
        fails = [l.strip() for l in out.splitlines() if "[FAIL]" in l]
        print("exit=%d  失败 %d 条" % (r.returncode, len(fails)))
        for l in fails[:8]:
            print("   ", l)
        print("结论：", "判据有效（改坏就报）" if fails else "!!! 改坏了却没报 —— 判据没盖到 !!!")
    finally:
        p.write_text(src, encoding="utf-8")
        after = hashlib.md5(p.read_text(encoding="utf-8").encode()).hexdigest()
        print("复原：", "ok" if after == before else "!!! 失败 !!!", before[:8], after[:8])


if __name__ == "__main__":
    main()
