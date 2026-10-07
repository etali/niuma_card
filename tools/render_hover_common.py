#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""原 PNG 画布多帧工具共用接口；正式登记仅由汇总工具执行。"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from hover_source_art import native_icon_path

from render_hover_batch01 import (
    ROOT, FPS, path, polygon_mask, rect_mask, ellipse_mask, content,
    affine_pose, gradient_fill, painted_polygon, isolated_marks,
    detached_marks, dilate_disk, cubic, ease, stroke_path,
)

OUT = ROOT / 'build/art_generation/native_remaining'


class NativePainter:
    card = ''
    count = 36
    mode = 'loop'
    boxes = ()

    def __init__(self):
        self.original = Image.open(native_icon_path(self.card)).convert('RGBA')
        self.size = self.original.size
        self.source_hash = hashlib.sha256(self.original.tobytes()).hexdigest()
        self.allowed = rect_mask(self.size, self.boxes)
        if not self.allowed.getbbox():
            raise ValueError(f'{self.card} 必须先声明活动坐标范围')

    def frame(self, index):
        if index <= 3 or (self.mode == 'loop' and index == self.count - 1):
            return self.original.copy()
        # 新卡按 anime.md 的物理秒数绘制；不自动压缩投币/出纸等可读时长。
        canvas = self.paint(index / FPS)
        if canvas.size != self.size or canvas.mode != 'RGBA':
            raise ValueError(f'{self.card} 必须返回原生尺寸 RGBA 完整画面')
        return Image.composite(canvas, self.original, self.allowed)


def keyframe_preview(frames, directory):
    indices = list(dict.fromkeys((0, len(frames)//4, len(frames)//2,
                                 3*len(frames)//4, len(frames)-1)))
    sheet = Image.new('RGB', (400*len(indices), 425), (176,198,159))
    draw = ImageDraw.Draw(sheet)
    for k, i in enumerate(indices):
        im = Image.new('RGBA', frames[i].size, (176,198,159,255))
        im.alpha_composite(frames[i])
        im.thumbnail((390,390), Image.Resampling.LANCZOS)
        sheet.paste(im, (400*k+(400-im.width)//2, 12))
        draw.text((400*k+12,407), f'{i:02d} / {i/FPS:.2f}s', fill=(25,22,18))
    sheet.save(directory/'keyframes.png')


def render_and_record(painter, preview_webp=False):
    directory = OUT/painter.card
    folder = directory/'frames'
    folder.mkdir(parents=True, exist_ok=True)
    frames, hashes, fixed_changes = [], [], []
    old = np.asarray(painter.original)
    fixed = np.asarray(painter.allowed)==0
    for i in range(painter.count):
        frame = painter.frame(i)
        frame.save(folder/f'{i:03d}.png')
        frames.append(frame)
        hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
        fixed_changes.append(int(np.count_nonzero(np.any(np.asarray(frame)!=old,axis=2)&fixed)))
    if frames[0].tobytes()!=painter.original.tobytes():
        raise ValueError(f'{painter.card} 首帧与静止 icon 不同')
    report = {'card':painter.card, 'method':'original PNG canvas, local semantic drawing',
              'frames':painter.count, 'fps':FPS, 'size':list(painter.size),
              'edit_boxes':painter.boxes, 'play_mode':painter.mode,
              'source_rgba_sha256':painter.source_hash, 'rgba_sha256':hashes,
              'fixed_changed_pixels':fixed_changes, 'user_review':'pending'}
    if hasattr(painter, 'notes'):
        report['notes'] = painter.notes
    (directory/'drawing.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    keyframe_preview(frames,directory)
    if preview_webp:
        displayed=[]
        for frame in frames:
            im=Image.new('RGBA',frame.size,(176,198,159,255));im.alpha_composite(frame);displayed.append(im)
        displayed[0].save(directory/'preview.webp',save_all=True,append_images=displayed[1:],
                          lossless=True,duration=round(1000/FPS),loop=0)
    print(f'{painter.card}: {painter.count} native frames, {len(set(hashes))} poses, fixed pixels {max(fixed_changes)}',flush=True)
    return frames, report, directory


def run(painters):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--card',choices=[cls.card for cls in painters])
    parser.add_argument('--preview-webp',action='store_true')
    args=parser.parse_args()
    for cls in painters:
        if not args.card or cls.card==args.card:
            render_and_record(cls(),args.preview_webp)
