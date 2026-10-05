#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""把底板母版抠成「只剩黑框架」的透明母版，打包为单张多通道遮罩。

母版（test_image/底板/底板母版.png）的构成很干净：
  透明外围 → 圆角黑边框 → 上方标题带填充（灰 153）→ 一条黑分隔线 → 下方卡面填充（灰 196）
框架之外没有任何内部元素（图标框、墨团都是运行时画的）。

所以九张底板其实是同一套几何、只有填充色不同 —— 抠掉两种填充色，剩下的黑框架
就是九张牌共用的母版。颜色全部交给配置，运行时上色。

输出 assets/art/plate/plate_master.png，四个通道各自是一张覆盖率图：
  R = 卡面填充覆盖率      G = 标题带填充覆盖率
  B = 框架墨覆盖率        A = 整卡轮廓（圆角外为 0）
着色时 color = face*R + band*G + ink*B，内部不透明像素上 R+G+B ≈ 1。
拆成覆盖率而不是直接存黑白图，是为了保住圆角和框线的抗锯齿：
二值化会让边框在缩到屏上 113px 时出现锯齿。

用法：python3 tools/build_plate_master.py [--dry]
"""

import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "test_image", "底板", "底板母版.png")
OUT_DIR = os.path.join(ROOT, "assets", "art", "plate")
OUT = os.path.join(OUT_DIR, "plate_master.png")
UI_JSON = os.path.join(ROOT, "data", "ui.json")

# 成品尺寸，与 build_art.py 打的九张底板一致（1200×1600，3:4）
DST_W, DST_H = 1200, 1600

# 母版里两种填充灰与框架墨的实测亮度（各区域众数）。
# 分类靠阈值，抗锯齿像素靠覆盖率反解。
# 框线是手绘的，墨色在 #111111~#161616 间抖动，取众数 #141414 当锚点：
# 比它更暗的像素覆盖率会被夹到 1，反正 1 就是纯框架色，差这一点看不出来
BAND_LUM = 153.0
FACE_LUM = 196.0
INK_LUM = 20.0

ALPHA_ON = 128      # 低于此视为完全透明（母版外围是硬边，只有圆角有过渡）
DARK_MAX = 80       # 平均亮度低于此算框架墨

# 填充区噪点死区。素材填充是手绘的，像素在众数上下抖 ±6 左右；
# 不设死区的话「比众数暗」的那一半会被当成墨覆盖率（b>0），而「比众数亮」的
# 那一半被夹到 b=0，两边不对称，于是平均覆盖率小于 1、卡面整体渲得偏暗。
# 实测这一项值约 1.1/255（标题带）。填充色本来就该由配置决定、是平的，
# 所以离填充亮度这么近的抖动一律算满覆盖率，不进墨通道
FILL_DEADBAND = 8.0
BAND_MAX = 175      # 介于 DARK_MAX 与此之间算标题带填充


def lum(p):
    return (p[0] + p[1] + p[2]) / 3.0


def find_separator(px, w, h):
    """找标题带下方那条横贯全宽的黑分隔线，返回 (顶, 底) 行号。

    判据是「这一行几乎全是墨」：分隔线是唯一横穿整卡的黑线，
    圆角边框在同一行只占两侧十几个像素。
    """
    rows = []
    for y in range(int(h * 0.05), int(h * 0.30)):
        dark = sum(1 for x in range(0, w, 4) if px[x, y][3] >= ALPHA_ON
                   and lum(px[x, y]) < DARK_MAX)
        if dark > (w // 4) * 0.8:
            rows.append(y)
    if not rows:
        raise SystemExit("找不到标题带分隔线，母版结构可能变了")
    return rows[0], rows[-1]


def measure_band(px, w, h, sep_top):
    """量标题带的几何：中心 y 与高度，都折算成占卡高的比例。

    上沿取边框内侧第一行标题带填充，下沿就是分隔线顶。
    存比例而不是像素，卡牌 mesh 尺寸变了不用改。
    """
    cx = w // 2
    top = None
    for y in range(0, sep_top):
        p = px[cx, y]
        if p[3] >= ALPHA_ON and DARK_MAX <= lum(p) < BAND_MAX:
            top = y
            break
    if top is None:
        raise SystemExit("找不到标题带上沿")
    return (top + sep_top) / 2.0 / h, (sep_top - top) / float(h)


def decompose(im, sep_top, sep_bot):
    """按像素反解三张覆盖率图。

    墨覆盖率 b 由「这个像素比它该有的填充色暗多少」反解，
    于是框线的抗锯齿边缘会得到 0<b<1 的中间值，缩放后仍然平滑。
    """
    w, h = im.size
    px = im.load()
    out = Image.new("RGBA", (w, h))
    op = out.load()
    sep_mid = (sep_top + sep_bot) / 2.0
    for y in range(h):
        # 分隔线本身归给下方卡面：它整条都是墨，填充色取哪边都不影响结果
        in_band = y < sep_mid
        fill = BAND_LUM if in_band else FACE_LUM
        span = fill - INK_LUM
        for x in range(w):
            p = px[x, y]
            a = p[3]
            if a < 1:
                op[x, y] = (0, 0, 0, 0)
                continue
            # 死区只把「贴着填充亮度的抖动」压成满覆盖率，斜率不动：
            # 若把整条斜坡按 (span - 死区) 重标定，框线抗锯齿边会一起变浅、
            # 框架看着变细（实测轮廓差异从 0.28% 涨到 0.52%）。
            # 故死区外仍用原斜率 d/span，只在 d<=死区 处截断
            d = fill - lum(p)
            b = 0.0 if d <= FILL_DEADBAND else d / span
            b = 0.0 if b < 0.0 else (1.0 if b > 1.0 else b)
            fillcov = 1.0 - b
            r = fillcov if not in_band else 0.0
            g = fillcov if in_band else 0.0
            op[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)
    return out


def main():
    dry = "--dry" in sys.argv
    if not os.path.exists(SRC):
        raise SystemExit("母版缺失：%s" % SRC)
    im = Image.open(SRC).convert("RGBA")
    w, h = im.size
    px = im.load()
    sep_top, sep_bot = find_separator(px, w, h)
    band_cy, band_frac = measure_band(px, w, h, sep_top)
    print("母版 %dx%d  分隔线 y=%d~%d" % (w, h, sep_top, sep_bot))
    print("标题带 cy=%.6f frac=%.6f" % (band_cy, band_frac))

    mask = decompose(im, sep_top, sep_bot)
    # 先反解再缩放：覆盖率图按线性插值缩放是对的，
    # 反过来先缩放会把填充色和框线混成中间灰，分类阈值就失效了
    mask = mask.resize((DST_W, DST_H), Image.LANCZOS)

    # 自检：内部不透明处三通道之和应该接近 1
    mp = mask.load()
    bad = 0
    for y in range(0, DST_H, 7):
        for x in range(0, DST_W, 7):
            p = mp[x, y]
            if p[3] < 250:
                continue
            s = (p[0] + p[1] + p[2]) / 255.0
            if abs(s - 1.0) > 0.06:
                bad += 1
    print("自检：三通道和偏离 1 的采样点 %d 个" % bad)

    if dry:
        print("--dry，不写文件")
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    mask.save(OUT)
    print("→ %s (%dx%d)" % (os.path.relpath(OUT, ROOT), DST_W, DST_H))

    # 把实测几何写进 ui.art：九张牌共用母版后，标题带位置只有这一份
    if os.path.exists(UI_JSON):
        with open(UI_JSON, encoding="utf-8") as f:
            man = json.load(f)
        man.setdefault("art", {}).setdefault("misc", {})["plate_master"] = {
            "file": "plate/plate_master.png",
            "band_cy": round(band_cy, 6),
            "band_frac": round(band_frac, 6),
        }
        with open(UI_JSON, "w", encoding="utf-8") as f:
            json.dump(man, f, ensure_ascii=False, indent=2, sort_keys=False)
            f.write("\n")
        print("→ ui.art.misc.plate_master 已更新")


if __name__ == "__main__":
    main()
