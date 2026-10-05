#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""读取实际 macOS App/PCK 的体积与文件清单，检查发布包没有混入开发资源。"""
import argparse
import json
import re
from pathlib import Path
import struct
import subprocess

DEVELOPMENT_PREFIXES = ('tests/', 'tools/', 'build/', 'ref_image/', 'test_image/',
                        'sounds/', 'reports/', 'tmp/', 'assets/art/plate/')


def pck_files(path):
    # Godot 的未加密独立PCK目录（core/io/file_access_pack.cpp，V2/V3/V4）。
    with Path(path).open('rb') as stream:
        magic, version, major, minor, patch, flags = struct.unpack('<6I', stream.read(24))
        if magic != 0x43504447 or version not in (2, 3, 4) or flags & 1:
            raise ValueError('只支持未加密的 Godot V2/V3/V4 PCK')
        base, = struct.unpack('<Q', stream.read(8))
        if version >= 3:
            directory, = struct.unpack('<Q', stream.read(8))
            stream.seek(directory)
        else:
            stream.read(64)
        count, = struct.unpack('<I', stream.read(4))
        entries = []
        for _ in range(count):
            length, = struct.unpack('<I', stream.read(4))
            name = stream.read(length).decode('utf-8').rstrip('\0').removeprefix('res://')
            offset, size = struct.unpack('<QQ', stream.read(16))
            stream.read(16)  # MD5
            entry_flags, = struct.unpack('<I', stream.read(4))
            entries.append({'path': name, 'bytes': size, 'offset': base + offset})
        return entries


def audit(app, *, require_clean=True):
    app = Path(app)
    binaries = [p for p in (app / 'Contents/MacOS').iterdir() if p.is_file()]
    packs = list((app / 'Contents/Resources').glob('*.pck'))
    if len(binaries) != 1 or len(packs) != 1:
        raise ValueError('App 中未找到唯一的游戏可执行文件与PCK')
    entries = pck_files(packs[0])
    unwanted = [e['path'] for e in entries if e['path'].startswith(DEVELOPMENT_PREFIXES)]
    required = {'project.binary', 'scenes/main.tscn.remap', 'data/cards.json', 'data/ui.json',
                'data/bot.json', 'assets/art/art_manifest.json', 'shaders/card_face.gdshader',
                'scenes/debug_shot.gdc', 'assets/fonts/NotoSansSC.ttf.import'}
    names = {entry['path'] for entry in entries}
    missing = sorted(required - names)
    broken_remaps = []
    with packs[0].open('rb') as stream:
        for entry in entries:
            if not entry['path'].endswith(('.remap', '.import')):
                continue
            stream.seek(entry['offset'])
            text = stream.read(entry['bytes']).decode('utf-8')
            for target in re.findall(r'^path(?:\.[^=]+)?="res://([^"\n]+)"', text, re.M):
                if target not in names:
                    broken_remaps.append({'source': entry['path'], 'target': target})
    if require_clean and (unwanted or missing or broken_remaps):
        raise ValueError(f'发布资源检查失败：多余={unwanted}，缺少={missing}，无效重定向={broken_remaps}')
    return {'app_bytes': sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),
            'binary_bytes': binaries[0].stat().st_size, 'pck_bytes': packs[0].stat().st_size,
            'architectures': subprocess.check_output(['lipo', '-archs', str(binaries[0])], text=True).split(),
            'development_entries': unwanted, 'missing_entries': missing, 'broken_remaps': broken_remaps, 'pck_files': entries}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    result = audit(args.app, require_clean=not args.baseline)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('架构：' + ', '.join(result['architectures']))
    for key in ['app_bytes', 'binary_bytes', 'pck_bytes']:
        print(f'{key}: {result[key]} bytes ({result[key] / 1048576:.3f} MiB)')
    print(f"文件 {len(result['pck_files'])} 个；开发文件 {len(result['development_entries'])} 个")
