#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""校验 build 中完整原生帧，统一接入 data/ui.json；不再次重绘或采样。"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from hover_source_art import native_icon_path

from render_hover_batch01 import install, rect_mask, ROOT
from render_hover_common import OUT

CARDS = ('touliu','xinxijianfang','baiyibutie','liulianghe','jiaolv','shanzhai',
         'liebian','tuisong','chunwan','banxiaoshi','tuanzhang','xufei',
         'dujiaoshou','guomin','shangshi','butie','heigongguan','zuokong',
         'eryouxuan','chaping','yinqing996','resou','jiangjia')


def validate(card):
    directory = OUT/card
    report = json.loads((directory/'drawing.json').read_text())
    original = Image.open(native_icon_path(card)).convert('RGBA')
    source = np.asarray(original)
    source_hash = hashlib.sha256(original.tobytes()).hexdigest()
    if source_hash != report['source_rgba_sha256']:
        raise ValueError(f'{card} 静止底稿在绘制后改变，需重新绘制')
    fixed = np.asarray(rect_mask(original.size, report['edit_boxes'])) == 0
    frames=[]
    for i in range(report['frames']):
        frame = Image.open(directory/f'frames/{i:03d}.png').convert('RGBA')
        if frame.size != original.size:
            raise ValueError(f'{card} 第 {i} 帧分辨率与原图不符')
        if hashlib.sha256(frame.tobytes()).hexdigest() != report['rgba_sha256'][i]:
            raise ValueError(f'{card} 第 {i} 帧与检查记录不符')
        if np.any(np.any(np.asarray(frame) != source, axis=2) & fixed):
            raise ValueError(f'{card} 第 {i} 帧改变了固定区像素')
        frames.append(frame)
    if any(frame.tobytes() != original.tobytes() for frame in frames[:4]):
        raise ValueError(f'{card} 首帧/原图停顿不一致')
    if report['play_mode']=='loop' and frames[-1].tobytes()!=original.tobytes():
        raise ValueError(f'{card} 回位循环没有恢复原图')
    if len({frame.tobytes() for frame in frames[-3:]}) != 1:
        raise ValueError(f'{card} 结束姿势仍在变化，没有完整落稳')
    if report['fps'] != 12 or len(set(report['rgba_sha256']))<12:
        raise ValueError(f'{card} 帧率或实际姿势数不足')
    return frames,report,directory


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--card', choices=CARDS, action='append')
    parser.add_argument('--verify-only',action='store_true')
    args=parser.parse_args()
    config_path=ROOT/'data/ui.json'
    config=json.loads(config_path.read_text())
    cards=args.card or CARDS
    # 所有候选先通过，再改正式资源与单一配置入口。
    for card in cards:
        validate(card)
    for card in cards:
        frames,report,directory=validate(card)
        if not args.verify_only:
            install(card,frames,report,directory,config)
        print(f'{card}: {len(frames)} native frames verified'+
              ('' if args.verify_only else ' and installed'),flush=True)
    if not args.verify_only:
        config_path.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':
    main()
