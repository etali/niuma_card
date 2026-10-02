#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""实测 test_image/底板/ 中历史位图的卡面色、标题带色和几何，供外观校对。"""
import colorsys
import os
from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test_image", "底板")


def hexof(c):
    return "#%02X%02X%02X" % c[:3]


def hsv(c):
    h, s, v = colorsys.rgb_to_hsv(c[0] / 255, c[1] / 255, c[2] / 255)
    return int(h * 360), int(s * 100), int(v * 100)


def dominant(im, box):
    """取区域内出现最多的颜色（量化到 8 级避免颗粒噪声）。"""
    crop = im.crop(box).convert("RGB")
    from collections import Counter
    c = Counter()
    px = crop.load()
    w, h = crop.size
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            c[(r // 8 * 8, g // 8 * 8, b // 8 * 8)] += 1
    return c.most_common(1)[0][0]


def contrast(c1, c2):
    def lin(c):
        out = []
        for v in c[:3]:
            v /= 255
            out.append(v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
        return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]
    l1, l2 = lin(c1), lin(c2)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def band_geometry(im):
    """沿中轴向下扫，找标题带下沿那条深色分隔线的 y 范围。"""
    g = im.convert("RGB")
    w, h = g.size
    x = w // 2
    px = g.load()
    a = im.convert("RGBA").load()
    rows = []
    for y in range(h):
        if a[x, y][3] < 128:
            rows.append(None)
            continue
        r, gg, b = px[x, y]
        rows.append(max(r, gg, b))
    dark = [y for y, v in enumerate(rows) if v is not None and v < 90]
    # 分隔线 = 第一段位于画面上部 1/3 的连续深色带（跳过最顶部的外描边）
    segs = []
    cur = []
    for y in dark:
        if cur and y != cur[-1] + 1:
            segs.append(cur)
            cur = []
        cur.append(y)
    if cur:
        segs.append(cur)
    return [(s[0], s[-1]) for s in segs if len(s) > 4][:3]


def main():
    files = sorted(os.listdir(ROOT))
    print(f"{'文件':<16} {'尺寸':>11} {'卡面':>9} {'HSV':>14} {'标题带':>9} {'HSV':>14} "
          f"{'暗字对比':>8} {'亮字对比':>8}  建议墨色")
    for fn in files:
        if not fn.endswith(".png"):
            continue
        im = Image.open(os.path.join(ROOT, fn))
        w, h = im.size
        # 卡面取样：中央空白区（标题带以下、墨团以上）
        face = dominant(im, (int(w * 0.30), int(h * 0.28), int(w * 0.70), int(h * 0.42)))
        # 标题带取样：顶部 8%~13% 高度处
        band = dominant(im, (int(w * 0.25), int(h * 0.08), int(w * 0.75), int(h * 0.13)))
        c_dark = contrast(face, (0x22, 0x22, 0x22))
        c_light = contrast(face, (0xF5, 0xF5, 0xF5))
        ink = "#222222" if c_dark >= c_light else "#F5F5F5"
        print(f"{fn:<16} {f'{w}x{h}':>11} {hexof(face):>9} {str(hsv(face)):>14} "
              f"{hexof(band):>9} {str(hsv(band)):>14} {c_dark:>8.1f} {c_light:>8.1f}  {ink}")
    print("\n分隔线/描边扫描（中轴 y 区间，深色段）:")
    for fn in files:
        if not fn.endswith(".png"):
            continue
        im = Image.open(os.path.join(ROOT, fn))
        print(f"  {fn:<16} {band_geometry(im)}  高={im.size[1]}")


if __name__ == "__main__":
    main()
