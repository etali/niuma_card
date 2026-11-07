#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""云课堂样板：在原 PNG 的限定画布区域内绘制完整连续帧。

默认只输出 build 下的样板，不修改原 icon 或运行时配置。
金币与帽穗直接采样唯一原稿，遮住的电脑在原画布内补画；没有部件文件、
重新生成的整图、逐帧对齐、调色、混帧或运行时变形。
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter
from hover_source_art import native_icon_path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "build/art_generation/cloud_local_canvas/frames"
FPS = 12
FRAME_COUNT = 42
COIN_CENTER = (975, 675)
COIN_TRAVEL = 196
SLOT_EDGE = 907
TASSEL_PIVOT = (231, 407)
SOURCE_RGBA_SHA256 = "f7495524dd24cbc174b485187f0ffea8cf6a3e4d69137cc09e970f1132fc02b2"
# 动作开始前确定的活动范围，不依据生成结果移动、扩大或重新对齐。
EDIT_BOXES = ((836, 566, 1080, 794), (179, 407, 276, 602),
              (386, 530, 462, 573), (434, 447, 493, 507),
              (749, 449, 815, 513), (765, 553, 840, 598),
              (735, 660, 803, 719), (389, 627, 467, 683),
              (1049,535,1130,605),(1074,596,1163,641))
# 原射线的外侧端点、从灯泡向外的方向及原有线宽。
RAYS = ((411, 550, -0.95, -0.31, 15), (455, 471, -0.75, -0.66, 16),
        (791, 475, 0.75, -0.66, 16), (816, 574, 0.96, -0.27, 15),
        (779, 694, 0.81, 0.58, 14), (415, 658, -0.91, 0.41, 14))


def ease(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def cubic(points, steps=80):
    a, b, c, d = points
    return [((1-t)**3*a[0] + 3*(1-t)**2*t*b[0] + 3*(1-t)*t*t*c[0] + t**3*d[0],
             (1-t)**3*a[1] + 3*(1-t)**2*t*b[1] + 3*(1-t)*t*t*c[1] + t**3*d[1])
            for t in (i / steps for i in range(steps + 1))]


def coin_mask(size):
    """在原画坐标标注现有金币轮廓，只用于画布采样，不输出独立素材。"""
    segments = (((975, 579), (1027, 578), (1067, 617), (1073, 666)),
                ((1073, 666), (1080, 713), (1044, 760), (998, 772)),
                ((998, 772), (946, 785), (896, 754), (882, 712)),
                ((882, 712), (864, 665), (889, 607), (936, 586)),
                ((936, 586), (949, 582), (961, 579), (975, 579)))
    points = [p for segment in segments for p in cubic(segment)]
    mask = Image.new("L", (size[0] * 4, size[1] * 4))
    ImageDraw.Draw(mask).polygon([(round(x*4), round(y*4)) for x,y in points], fill=255)
    return mask.resize(size, Image.Resampling.LANCZOS)


def mix(a, b, weight):
    return tuple(round(x + (y-x)*weight) for x, y in zip(a, b))


def repair_covered_computer(source, mask):
    """只补画金币挡住的电脑区域：屏幕、右边框、外侧透明背景和投币口。"""
    result = source.copy()
    pixels, old, allowed = result.load(), source.load(), mask.load()
    for y in range(566, 794):
        inner = 990.0 + (982.0 - 990.0) * ((y-568) / (794-568))
        outer = 1033.5 + (1027.0 - 1033.5) * ((y-568) / (794-568))
        for x in range(836, 1080):
            if allowed[x, y] == 0:
                continue
            color = mix(old[960,568],old[960,794],(y-575)/205)
            if x > inner:
                color = mix(old[1010,568],old[1005,794],(y-575)/205)
            inner_ink = mix(old[992,565],old[984,800],(y-575)/205)
            outer_ink = mix(old[1034,565],old[1028,800],(y-575)/205)
            color = mix(color,inner_ink,max(0,min(1,8.3-abs(x-inner))))
            color = mix(color,outer_ink,max(0,min(1,9.3-abs(x-outer))))
            color = color[:3]+(round(color[3]*max(0,min(1,outer+9.3-x))),)
            if color[3] == 0:
                color = (0,0,0,0)
            pixels[x,y] = color

    # 沿原可见孔缘接续完整的右边框，不引入另一处投币口。
    edge = cubic(((920,568),(920,620),(916,715),(915,748)))
    edge += cubic(((915,748),(915,765),(908,766.5),(898,766.5)))
    edge += ((865,766.5),)
    stroke_path(result,edge,14.5,(31,25,20,254))
    capsule(result,(894,582),(890,737),26,(32,26,20,254))
    # 只有原金币区域允许此补画，其他投币口和屏幕像素仍取唯一原稿。
    return Image.composite(result, source, mask)


def capsule(canvas, start, end, width, color):
    stroke_path(canvas,(start,end),width,color)


def stroke_path(canvas, points, width, color):
    x0 = math.floor(min(x for x,y in points) - width/2 - 2)
    y0 = math.floor(min(y for x,y in points) - width/2 - 2)
    x1 = math.ceil(max(x for x,y in points) + width/2 + 2)
    y1 = math.ceil(max(y for x,y in points) + width/2 + 2)
    scale = 4
    coverage = Image.new("L", ((x1-x0)*scale, (y1-y0)*scale))
    draw = ImageDraw.Draw(coverage)
    scaled = [((x-x0)*scale,(y-y0)*scale) for x,y in points]
    radius = width*scale/2
    draw.line(scaled, fill=255, width=round(width*scale))
    for x,y in scaled:
        draw.ellipse((x-radius,y-radius,x+radius,y+radius), fill=255)
    coverage = coverage.resize((x1-x0,y1-y0), Image.Resampling.LANCZOS)
    # 原稿填充 alpha 接近 254，不通过叠加变深；绘制覆盖按笔刷覆盖率进行。
    canvas.paste(color,(x0,y0,x1,y1),coverage)


class CloudPainter:
    def __init__(self):
        self.original = Image.open(native_icon_path('yunketang')).convert("RGBA")
        if (self.original.size != (1254,1254) or
                hashlib.sha256(self.original.tobytes()).hexdigest() != SOURCE_RGBA_SHA256):
            raise ValueError("云课堂原稿已变化，需要重新核对画布活动范围与接触位置")
        self.cash_mask = coin_mask(self.original.size)
        # 露底绘制范围包括原币的抗锯齿边缘及缺失线条接续处，不能留下旧币轮廓。
        self.repair_mask = self.cash_mask.filter(ImageFilter.MaxFilter(17))
        bridge = ImageDraw.Draw(self.repair_mask)
        bridge.rectangle((974,567,1000,792),fill=255)
        bridge.rectangle((1016,571,1044,785),fill=255)
        bridge.rectangle((875,738,930,777),fill=255)
        self.repaired = repair_covered_computer(self.original, self.repair_mask)
        self.edit_mask = Image.new("L", self.original.size)
        draw = ImageDraw.Draw(self.edit_mask)
        for x0,y0,x1,y1 in EDIT_BOXES:
            draw.rectangle((x0,y0,x1-1,y1-1),fill=255)
        self.tassel_mask = Image.new("L", self.original.size)
        draw = ImageDraw.Draw(self.tassel_mask)
        draw.rectangle((212,407,248,450),fill=255)
        draw.rectangle((184,451,263,600),fill=255)

    def frame(self, index):
        t = index/FPS
        if t <= .25:
            return self.original.copy()
        canvas = self.repaired.copy()
        deposit = ease((t-.25)/1.0)
        offset = round(COIN_TRAVEL * deposit)
        # 直接采样原稿金币的整数坐标，不缩放、翻转或重新调色。
        source_pixels, pixels = self.original.load(), canvas.load()
        mask = self.cash_mask.load()
        for y in range(575,780):
            for x in range(max(SLOT_EDGE,836),1080):
                from_x = x + offset
                if from_x >= 1080:
                    continue
                alpha = mask[from_x,y]/255
                if alpha:
                    pixels[x,y] = mix(pixels[x,y], source_pixels[from_x,y], alpha)
        # 金币旁的两条原有动势线随投币收起，终态不留下悬空的动势线。
        for box, start, end, radius in (
                ((1049,535,1130,605),(1067,581),(1113,552),10),
                ((1074,596,1163,641),(1084,628),(1141,614),10)):
            x0,y0,x1,y1=box
            vx,vy=end[0]-start[0],end[1]-start[1]
            length=math.hypot(vx,vy)
            ux,uy=vx/length,vy/length
            remaining=length*(1-deposit)
            cap_radius=radius*min(1,remaining/radius)
            cap=(start[0]+ux*remaining,start[1]+uy*remaining)
            for y in range(y0,y1):
                for x in range(x0,x1):
                    old=source_pixels[x,y]
                    along=(x-start[0])*ux+(y-start[1])*uy
                    coverage=1.0 if along<remaining and remaining>=radius else \
                        max(0,min(1,cap_radius+.5-math.hypot(x-cap[0],y-cap[1])))
                    alpha=round(old[3]*coverage) if remaining else 0
                    pixels[x,y]=old[:3]+(alpha,) if alpha else (0,0,0,0)
        for i,(x,y,dx,dy,width) in enumerate(RAYS):
            extension = 12 * ease((t-1.25-i*.065)/.13)
            if extension:
                color = self.original.getpixel((x,y))
                capsule(canvas, (x,y), (x+dx*extension,y+dy*extension), width, color)
        if 1.75 < t < 3.10:
            u = (t-1.75)/1.35
            angle = .085 * math.sin(4*math.pi*u) * math.sin(math.pi*u)
            c,s = math.cos(angle),math.sin(angle)
            px,py = TASSEL_PIVOT
            # 每个姿态都直接从唯一原稿采样，不逐帧变换上一帧，避免累积模糊。
            transform = (c,s,px-c*px-s*py,-s,c,py+s*px-c*py)
            content = self.original.copy()
            content.putalpha(Image.composite(self.original.getchannel("A"),
                                             Image.new("L", self.original.size),self.tassel_mask))
            moved = content.transform(self.original.size, Image.Transform.AFFINE,transform,
                                      resample=Image.Resampling.BICUBIC)
            canvas.paste((0,0,0,0), mask=self.tassel_mask)
            canvas.alpha_composite(moved)
        # 活动范围在绘制开始前确定。锁住画布像素，不是事后修复生成结果。
        return Image.composite(canvas,self.original,self.edit_mask)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out",type=Path,default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    painter = CloudPainter()
    hashes=[]
    for index in range(FRAME_COUNT):
        frame = painter.frame(index)
        frame.save(args.out/f"{index:03d}.png")
        hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
    report = {"card":"yunketang","method":"original PNG canvas, local pose drawing",
              "frames":FRAME_COUNT,"fps":FPS,"size":painter.original.size,
              "edit_boxes":EDIT_BOXES,"play_mode":"once","rgba_sha256":hashes}
    (args.out.parent/"drawing.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(f"yunketang: {FRAME_COUNT} complete native frames; {len(set(hashes))} unique poses at {FPS} fps")


if __name__ == "__main__":
    main()
