#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""把已验收完整帧按 Godot 预览规则缩小并无损打包；高清底稿仅归档 build。

默认先创建不可覆盖的备份，再输出 build/art_generation/runtime_hover_<limit>。
--install 在全库还原验证通过后替换正式 PNG/配置，移除被替代的整帧 PNG。
可指定 --source-ui / --source-art 从已有高清制作归档重新打包。
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

from PIL import Image
from hover_delta_codec import encode_frames, decode_bytes
from hover_source_art import merge_native_source

ROOT = Path(__file__).resolve().parents[1]


def file_bytes(directory):
    return sum(p.stat().st_size for p in directory.rglob('*') if p.is_file())


def backup_current() -> tuple[Path, Path]:
    current = json.loads((ROOT/'data/ui.json').read_text())
    if not all('files' in c for c in current['art']['hover']['cards'].values()):
        raise ValueError('正式资源已打包，请提供 --source-ui 和 --source-art 指向高清制作归档')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    target = ROOT/'build/art_generation'/f'native_before_384_delta_{stamp}'
    target.mkdir(parents=True, exist_ok=False)
    shutil.copy2(ROOT/'data/ui.json', target/'ui.json')
    shutil.copytree(ROOT/'assets/art/icon', target/'art/icon')
    manifest = {str(p.relative_to(target/'art')): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (target/'art').rglob('*.png')}
    (target/'source_hashes.json').write_text(json.dumps(manifest, indent=2)+'\n')
    (target/'before_sizes.json').write_text(json.dumps({
        'assets_bytes': file_bytes(ROOT/'assets'),
        'app_bytes': file_bytes(ROOT/'build/牛马牌.app'),
        'hover_png_bytes': sum(p.stat().st_size for p in (ROOT/'assets/art/icon/hover').rglob('*.png'))
    }, indent=2)+'\n')
    (ROOT/'build/art_generation/hover_runtime_source.json').write_text(json.dumps({
        'ui': str(target/'ui.json'), 'art': str(target/'art')}, indent=2)+'\n')
    print(f'高清源图已归档：{target.relative_to(ROOT)}', flush=True)
    return target/'ui.json', target/'art'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-ui', type=Path)
    parser.add_argument('--source-art', type=Path)
    parser.add_argument('--limit', type=int, default=384)
    parser.add_argument('--card', action='append', help='只重新打包指定牌，可重复传入')
    parser.add_argument('--godot', default='/Applications/Godot.app/Contents/MacOS/Godot')
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    if not 16 <= args.limit <= 1024:
        parser.error('limit 必须在 16 到 1024 之间')
    if bool(args.source_ui) != bool(args.source_art):
        parser.error('--source-ui 和 --source-art 必须同时指定')
    source_ui, source_art = ((args.source_ui.resolve(), args.source_art.resolve())
                             if args.source_ui else backup_current())
    source = json.loads(source_ui.read_text())
    configs = source['art']['hover']['cards']
    if args.card:
        unknown = set(args.card) - set(configs)
        if unknown:
            parser.error('未登记的卡牌：'+', '.join(sorted(unknown)))
        configs = {key: configs[key] for key in dict.fromkeys(args.card)}
    stage = ROOT/'build/art_generation'/f'runtime_hover_{args.limit}'
    stage.mkdir(parents=True, exist_ok=True)
    paths = sorted({p for cfg in configs.values() for p in cfg['files']})
    job = {'limit': args.limit, 'files': []}
    for path in paths:
        origin = source_art/path
        preset = Path(str(origin)+'.import')
        fix = not preset.exists() or 'process/fix_alpha_border=false' not in preset.read_text()
        job['files'].append({'source': str(origin), 'target': str(stage/'resized'/path),
                             'fix_alpha_border': fix})
    job_path = stage/'resize_job.json'
    job_path.write_text(json.dumps(job, ensure_ascii=False, indent=2)+'\n')
    log = subprocess.run([args.godot, '--headless', '--path', str(ROOT), '--script',
                          'tools/resize_hover_art.gd', '--', str(job_path)],
                         cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (stage/'resize.log').write_text(log.stdout)
    if log.returncode or 'SCRIPT ERROR:' in log.stdout or re.search(r'^ERROR:', log.stdout, re.M):
        raise RuntimeError(f'Godot 缩放失败：{stage / "resize.log"}\n{log.stdout[-3000:]}')
    print(log.stdout.strip(), flush=True)
    # 重做一张牌时保留当前 UI、配色和其他卡牌，不用归档配置覆盖它们。
    updated = json.loads((ROOT/'data/ui.json').read_text())
    reports = []
    for card, cfg in configs.items():
        images = {}
        for path in dict.fromkeys(cfg['files']):
            with Image.open(stage/'resized'/path) as im:
                images[path] = (im.size, im.convert('RGBA').tobytes())
        size = images[cfg['files'][0]][0]
        if any(item[0] != size for item in images.values()):
            raise ValueError(f'{card} 帧尺寸不一致')
        ordered = [images[p][1] for p in cfg['files']]
        encoded = encode_frames(ordered, *size)
        decoded = decode_bytes(encoded)
        for i, reference in enumerate(decoded['timeline']):
            if decoded['frames'][reference] != ordered[i]:
                raise ValueError(f'{card} 第{i}帧差分还原不一致')
        static_path = f'icon/icon_{card}.png'
        if ordered[0] != images[static_path][1] or any(raw != ordered[0] for raw in ordered[:4]):
            raise ValueError(f'{card} 首帧未保持静止图')
        path = f'icon/hover/{card}.hdelta'
        target = stage/'packed'/path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(encoded)
        new = {k: v for k, v in cfg.items() if k not in ('files', 'file', 'frame_size')}
        new.update(codec='hdelta-v1', file=path, frame_size=list(size))
        updated['art']['hover']['cards'][card] = new
        report = {'card': card, 'frames': len(ordered), 'unique_frames': len(decoded['frames']),
                  'source_ui': str(source_ui), 'source_art': str(source_art),
                  'frame_size': list(size), 'packed_bytes': len(encoded),
                  'source_png_bytes': sum((source_art/p).stat().st_size for p in images),
                  'resized_png_bytes': sum((stage/'resized'/p).stat().st_size for p in images),
                  'rgba_sha256': [hashlib.sha256(raw).hexdigest() for raw in ordered],
                  'pack_sha256': hashlib.sha256(encoded).hexdigest()}
        reports.append(report)
        print(f'{card}: {len(ordered)} 帧，{size[0]}×{size[1]}，{len(encoded):,} bytes，逐像素还原通过', flush=True)
    updated['art']['hover']['max_dimension'] = args.limit
    updated['art']['hover']['cache_bytes'] = 96 * 1024 * 1024
    updated['art']['hover']['_说明'] = f'12fps；最长边{args.limit}；hdelta-v1无损帧间差分；首帧复用静止图，后台解码并生成mipmap。'
    (stage/'ui.json').write_text(json.dumps(updated, ensure_ascii=False, indent=2)+'\n')
    receipt = stage/'verification.json'
    known_reports = {r['card']: r for r in json.loads(receipt.read_text())['cards']} if receipt.exists() else {}
    known_reports.update({r['card']: r for r in reports})
    combined = sorted(known_reports.values(), key=lambda r: r['card'])
    report = {'source_ui': str(source_ui), 'source_art': str(source_art), 'limit': args.limit,
              'cards': combined, 'packed_bytes': sum(r['packed_bytes'] for r in combined),
              'frames': sum(r['frames'] for r in combined), 'rgba_verified': True}
    (stage/'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    if args.install:
        # 所有卡牌完整验证后才替换；旧文件已在高清归档中，可随时重新制作。
        # 先登记最新高清全库；失败则停止，不留下只有正式动画更新的状态。
        for card in configs:
            merge_native_source(card, source_ui, source_art)
        for card in configs:
            static_path = f'icon/icon_{card}.png'
            target = ROOT/'assets/art'/static_path
            shutil.copy2(stage/'resized'/static_path, target)
            preset = Path(str(target)+'.import')
            body = preset.read_text().replace('process/fix_alpha_border=true', 'process/fix_alpha_border=false')
            preset.write_text(body)
            delta_path = f'icon/hover/{card}.hdelta'
            shutil.copy2(stage/'packed'/delta_path, ROOT/'assets/art'/delta_path)
        (ROOT/'data/ui.json').write_text(json.dumps(updated, ensure_ascii=False, indent=2)+'\n')
        old_paths = {p for cfg in configs.values() for p in cfg['files'] if p.startswith('icon/hover/')}
        for path in old_paths:
            target = ROOT/'assets/art'/path
            target.unlink(missing_ok=True)
            Path(str(target)+'.import').unlink(missing_ok=True)
        for directory in (ROOT/'assets/art/icon/hover').iterdir():
            if directory.is_dir() and not any(directory.iterdir()):
                directory.rmdir()
        print('已接入正式384静止图与差分动画，高清源图保留在build。', flush=True)
    print(f'差分动画总计 {report["packed_bytes"] / 1e6:.2f} MB，{report["frames"]}帧全部还原一致。', flush=True)


if __name__ == '__main__':
    main()
