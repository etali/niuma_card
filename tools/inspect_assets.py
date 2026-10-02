#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""扫描 test_image/ 下的素材：尺寸、通道、是否还带绿幕、主体外接框占比。"""
import os
import sys
from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test_image")


def green_ratio(im):
    """统计绿色通道大于 100，且比红蓝通道最大值高出超过 40 的像素比例。"""
    im = im.convert("RGB").resize((160, 160))
    px = im.load()
    n = 0
    for y in range(160):
        for x in range(160):
            r, g, b = px[x, y]
            if g > 100 and g - max(r, b) > 40:
                n += 1
    return n / (160 * 160)


def alpha_ratio(im):
    if im.mode not in ("RGBA", "LA"):
        return None
    a = im.convert("RGBA").resize((160, 160)).split()[-1]
    vals = list(a.getdata())
    return sum(1 for v in vals if v < 16) / len(vals)


def main():
    rows = []
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        for fn in sorted(filenames):
            if not fn.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            try:
                with Image.open(p) as im:
                    w, h = im.size
                    mode = im.mode
                    gr = green_ratio(im)
                    ar = alpha_ratio(im)
            except Exception as e:  # noqa: BLE001
                rows.append((rel, "ERR", str(e), "", ""))
                continue
            rows.append((
                rel,
                f"{w}x{h}",
                mode,
                f"green={gr:.3f}",
                "alpha_transparent=%.3f" % ar if ar is not None else "no-alpha",
            ))
    wid = max(len(r[0]) for r in rows)
    for r in rows:
        print(f"{r[0]:<{wid}}  {r[1]:>11}  {r[2]:<5}  {r[3]:<12}  {r[4]}")
    print(f"\n合计 {len(rows)} 个文件")


if __name__ == "__main__":
    sys.exit(main())
