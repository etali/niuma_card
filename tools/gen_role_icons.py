#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""生成两张角色专属卡的图标与悬停动画：「给我」（傲慢伸手的小人）与 Idea（灯泡）。

画风对齐现有手绘图标：深褐粗描边、奶油底色、暖黄点缀、透明底，384×384。
先在 4 倍画布上画，再缩小抗锯齿；描边带轻微抖动，避免一眼看出是几何图形。

每张图都是一个「姿势」函数：pose=0 是静止图，动画只是同一张画在不同 pose 下的重画。
抖动的随机序列每帧相同，所以线条不会逐帧乱跳；静止 icon 直接取第 0 帧写出，
保证「差分首帧与静止小图逐像素一致」（tests/test_card_hover_animation.gd、
tools/check_art_assets.py 都核这一条）。动画是循环播放：前四帧和最后一帧都是静止图。

固定随机种子，重跑结果逐像素一致。用法：python3 tools/gen_role_icons.py
写出后要把 data/ui.json 里 art.hover.cards 的 frames 对上 FRAMES（脚本会打印）。
"""

import math
import pathlib
import random
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from hover_delta_codec import encode_frames  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "art" / "icon"
SIZE = 384
SCALE = 4
INK = (48, 41, 31, 255)
CREAM = (246, 235, 208, 255)
YELLOW = (255, 221, 127, 255)
AMBER = (253, 205, 119, 255)
SHINE = (255, 248, 226, 255)
BRIGHT = (255, 238, 160, 255)
STROKE = 11
## 帧数：4 帧静止 + 动作 + 末尾回到静止。12 fps 下约 2 秒
FRAMES = 24
HOLD = 4


class Pen:
    """4 倍画布上的手绘笔：坐标按 384 画布给，内部放大并加抖动"""

    def __init__(self, seed):
        self.image = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
        self.draw = ImageDraw.Draw(self.image)
        self.rng = random.Random(seed)

    def _jitter(self, points, amount):
        # 低频抖动：相邻点的偏移相关，线条是「手抖」而不是「毛刺」
        out = []
        dx = dy = 0.0
        for x, y in points:
            dx = dx * 0.7 + self.rng.uniform(-amount, amount) * 0.3
            dy = dy * 0.7 + self.rng.uniform(-amount, amount) * 0.3
            out.append(((x + dx) * SCALE, (y + dy) * SCALE))
        return out

    def fill(self, points, color, jitter=0.6):
        self.draw.polygon(self._jitter(points, jitter), fill=color)

    def line(self, points, width=STROKE, color=INK, closed=False, jitter=0.8):
        pts = self._jitter(points, jitter)
        if closed:
            pts = pts + [pts[0]]
        w = width * SCALE
        self.draw.line(pts, fill=color, width=int(w), joint="curve")
        r = w / 2
        ends = pts if closed else [pts[0], pts[-1]]
        for x, y in ends:
            self.draw.ellipse((x - r, y - r, x + r, y + r), fill=color)
        # 折点补圆，粗线在急转弯处不露缺口
        for x, y in pts[1:-1]:
            self.draw.ellipse((x - r * 0.98, y - r * 0.98, x + r * 0.98, y + r * 0.98), fill=color)

    def shape(self, points, fill, width=STROKE):
        self.fill(points, fill)
        self.line(points, width=width, closed=True)

    def disc(self, cx, cy, radius, color):
        # 不抖动、不消耗随机数：只在动作帧出现的光晕不能改变其余线条的抖动
        self.draw.ellipse(((cx - radius) * SCALE, (cy - radius) * SCALE,
                           (cx + radius) * SCALE, (cy + radius) * SCALE), fill=color)

    def result(self):
        return self.image.resize((SIZE, SIZE), Image.LANCZOS)


def ellipse(cx, cy, rx, ry, start=0.0, end=360.0, steps=72, tilt=0.0):
    pts = []
    for i in range(steps + 1):
        a = math.radians(start + (end - start) * i / steps)
        x, y = rx * math.cos(a), ry * math.sin(a)
        t = math.radians(tilt)
        pts.append((cx + x * math.cos(t) - y * math.sin(t), cy + x * math.sin(t) + y * math.cos(t)))
    return pts if end - start < 360 else pts[:-1]


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(4))


def grab_icon(pose=0.0):
    """给我：仰着下巴、半眯着眼、一手叉腰一手伸出掌心要东西的小人。
    pose 0→1：手指往掌心勾（「拿来」），手臂微抬，强调线往外跳"""
    pen = Pen(20261016)
    curl = pose
    # 身体（先画，头压在上面）
    body = ellipse(150, 262, 50, 58)
    pen.shape(body, CREAM)
    # 领带：老板的记号
    pen.shape([(150, 214), (162, 226), (156, 280), (150, 292), (144, 280), (138, 226)], AMBER, width=7)
    pen.line([(140, 214), (160, 214)], width=7)
    # 腿
    pen.line([(132, 312), (124, 350)])
    pen.line([(168, 312), (176, 350)])
    pen.line([(112, 351), (126, 350)])
    pen.line([(174, 350), (190, 352)])
    # 叉腰的那只手：「<」形
    pen.line([(104, 240), (78, 268), (106, 292)])
    # 伸出去的那只手：手臂 + 朝上摊开的掌心；勾手指时整只手抬一点
    lift = -6 * curl
    pen.line([(196, 246), (262, 228 + lift)])
    palm = ellipse(292, 222 + lift, 30, 15, tilt=-14)
    pen.shape(palm, CREAM, width=9)
    for x0, y0, x1, y1 in [(278, 210, 272, 188), (292, 207, 290, 182), (306, 205, 308, 182), (318, 210, 326, 192)]:
        # 指尖朝掌心收：长度缩短、往左下（掌心方向）弯
        tip_x = x0 + (x1 - x0) * (1 - 0.55 * curl) - 10 * curl
        tip_y = y0 + (y1 - y0) * (1 - 0.55 * curl)
        pen.line([(x0, y0 + lift), (tip_x, tip_y + lift)], width=9)
    pen.line([(266, 226 + lift), (252, 206 + lift)], width=9)  # 拇指
    # 头：微微后仰（整张脸往右上偏），勾手指时下巴再抬一点
    tilt = -8 - 4 * curl
    head = ellipse(150, 128, 82, 80, tilt=tilt)
    pen.shape(head, CREAM)
    # 半眯的眼：平眼线 + 压下来的眼皮
    for ex in (128, 186):
        pen.line([(ex - 16, 112), (ex + 16, 106)], width=9)
        pen.line([(ex - 14, 98), (ex, 92), (ex + 16, 92)], width=6)
    # 翘起的鼻子和斜着的冷笑
    pen.line([(160, 122), (170, 136), (158, 140)], width=7)
    pen.line([(134, 162), (160, 166), (184, 154)], width=8)
    # 要东西的强调线：沿各自方向往外跳
    for x0, y0, x1, y1 in [(330, 150, 342, 128), (348, 170, 370, 160), (316, 140, 318, 118)]:
        dx, dy = x1 - x0, y1 - y0
        k = 0.45 * curl
        pen.line([(x0 + dx * k, y0 + dy * k), (x1 + dx * k, y1 + dy * k)], width=8)
    return pen.result()


def idea_icon(pose=0.0):
    """Idea：灯泡。pose 0→1：灯泡亮起来，光芒变长、外圈泛光"""
    pen = Pen(20261017)
    glow = pose
    cx, cy, r = 192, 160, 92
    if glow > 0:
        pen.disc(cx, cy, r + 34 * glow, (255, 236, 150, round(110 * glow)))
    # 光芒（压在灯泡下面），左右对称
    for angle in (-160, -125, -90, -55, -20, 20, 160):
        a = math.radians(angle)
        r0, r1 = r + 20, r + 46 + 14 * glow
        pen.line([(cx + r0 * math.cos(a), cy + r0 * math.sin(a)),
                  (cx + r1 * math.cos(a), cy + r1 * math.sin(a))], width=10)
    # 玻璃泡 + 收口
    bulb = ellipse(cx, cy, r, r, start=140, end=400, steps=80)
    bulb += [(cx + 40, 266), (cx - 40, 266)]
    pen.shape(bulb, mix(YELLOW, BRIGHT, glow))
    # 高光
    pen.line(ellipse(cx, cy, r - 28, r - 28, start=200, end=250, steps=12), width=12, color=SHINE, jitter=0.3)
    # 灯丝：亮起来时变成暖橙
    pen.line([(cx - 32, 266), (cx - 26, 204), (cx - 14, 218), (cx, 194), (cx + 14, 218), (cx + 26, 204), (cx + 32, 266)],
             width=7, color=mix(INK, (214, 120, 40, 255), glow))
    # 螺口
    for y in (266, 288, 310):
        pen.shape([(cx - 46, y), (cx + 46, y), (cx + 42, y + 22), (cx - 42, y + 22)], CREAM, width=9)
    pen.shape(ellipse(cx, 334, 22, 12, start=0, end=180, steps=20), INK, width=7)
    return pen.result()


def poses(beats):
    """循环动画的姿势序列：HOLD 帧静止 → beats 个起落 → 最后一帧回到静止"""
    moving = FRAMES - HOLD - 1
    out = [0.0] * HOLD
    for i in range(moving):
        out.append(abs(math.sin(math.pi * beats * (i + 1) / (moving + 1))))
    out.append(0.0)
    return out


def write(name, draw, beats):
    frames = [draw(p) for p in poses(beats)]
    still = frames[0]
    still.save(OUT / f"icon_{name}.png")
    raws = [frame.tobytes() for frame in frames]
    (OUT / "hover" / f"{name}.hdelta").write_bytes(encode_frames(raws, SIZE, SIZE))
    print(f"wrote icon_{name}.png + hover/{name}.hdelta：{len(frames)} 帧，{len(set(raws))} 个姿势")


if __name__ == "__main__":
    write("geiwo", grab_icon, beats=2)
    write("idea", idea_icon, beats=1)
