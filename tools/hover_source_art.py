#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""原坐标制作工具的高清源入口；正式 384 图只能用于游戏显示。"""
from __future__ import annotations

import datetime
import json
import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def runtime_config() -> dict:
    return json.loads((ROOT / 'data/ui.json').read_text())


def uses_compact_art(config: dict | None = None) -> bool:
    hover = (config if config is not None else runtime_config())['art'].get('hover', {})
    return int(hover.get('max_dimension', 0)) > 0 or any(
        card.get('codec') == 'hdelta-v1' for card in hover.get('cards', {}).values())


def _source_pointer() -> tuple[Path, dict]:
    pointer = ROOT / 'build/art_generation/hover_runtime_source.json'
    if not pointer.is_file():
        raise FileNotFoundError(
            '当前正式 icon 已压缩，不能供原生坐标绘制。请恢复高清制作源，并在 '
            f'{pointer} 登记 ui 和 art；不要将 384 图放大后代替原稿。')
    source = json.loads(pointer.read_text())
    if not Path(source.get('art', '')).is_dir() or not Path(source.get('ui', '')).is_file():
        raise FileNotFoundError(f'高清制作源路径失效：{pointer}；请恢复归档后再绘制。')
    return pointer, source


def native_icon_path(card: str) -> Path:
    """只读原稿；压缩项目不得回退到 assets 下的低分辨率图。"""
    compact = uses_compact_art()
    path = (Path(_source_pointer()[1]['art']) if compact else ROOT / 'assets/art') / f'icon/icon_{card}.png'
    if not path.is_file():
        raise FileNotFoundError(f'{card} 高清原稿不存在：{path}')
    if compact:
        limit = int(runtime_config()['art']['hover'].get('max_dimension', 384))
        with Image.open(path) as image:
            if max(image.size) <= limit:
                raise ValueError(f'{card} 制作源只有 {image.size}，不能用于原生坐标绘制：{path}')
    return path


def native_icon_write_path(card: str) -> Path:
    """修改静止原稿前复制可编辑制作源；绝不覆盖首次压缩前的归档。"""
    if not uses_compact_art():
        return native_icon_path(card)
    pointer, source = _source_pointer()
    writable_root = (ROOT / 'build/art_generation/native_editable').resolve()
    current = Path(source['art']).resolve()
    if not source.get('editable') or not current.is_relative_to(writable_root):
        native_icon_path(card)  # 在创建副本前拒绝缺失或被误指向小图的源。
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        target = writable_root / stamp
        target.mkdir(parents=True, exist_ok=False)
        shutil.copytree(current, target / 'art')
        shutil.copy2(source['ui'], target / 'ui.json')
        source = {**source, 'art': str(target / 'art'), 'ui': str(target / 'ui.json'),
                  'editable': True, 'copied_from_art': str(current)}
        pointer.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
    return native_icon_path(card)


def merge_native_source(card: str, source_ui: Path, source_art: Path) -> None:
    """将已校验候选并入可重新打包的高清全库，保留最初归档不变。

    打包工具在正式素材替换前调用；源合并失败会中止安装，避免只有正式
    差分包变新而高清制作源仍停在旧动作。相同全库输入不重复复制。
    """
    source_ui, source_art = source_ui.resolve(), source_art.resolve()
    _, pointer = _source_pointer()
    if source_ui == Path(pointer['ui']).resolve() and source_art == Path(pointer['art']).resolve():
        return
    incoming = json.loads(source_ui.read_text())
    entry = incoming['art']['hover']['cards'][card]
    paths = entry.get('files', [])
    static = f'icon/icon_{card}.png'
    prefix = f'icon/hover/{card}/'
    if not paths or paths[0] != static:
        raise ValueError(f'{card} 合并制作源必须以静止原稿开场')
    for relative in set(paths):
        path = source_art / relative
        if (relative != static and not relative.startswith(prefix)) or not path.resolve().is_relative_to(source_art):
            raise ValueError(f'{card} 制作源存在跨卡或越界路径：{relative}')
        if not path.is_file():
            raise FileNotFoundError(f'{card} 最新原生帧缺失：{path}')
    # 首次写入先复制完整全库；之后所有改动只落在可编辑副本。
    native_icon_write_path(card)
    _, pointer = _source_pointer()
    target_art, target_ui = Path(pointer['art']), Path(pointer['ui'])
    full_config = json.loads(target_ui.read_text())
    previous = full_config['art']['hover']['cards'].get(card, {}).get('files', [])
    for relative in set(paths):
        origin, target = source_art / relative, target_art / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if origin.resolve() != target.resolve():
            staging = Path(str(target) + '.staging')
            shutil.copy2(origin, staging)
            staging.replace(target)
        origin_import, target_import = Path(str(origin) + '.import'), Path(str(target) + '.import')
        if origin_import.is_file() and origin_import.resolve() != target_import.resolve():
            shutil.copy2(origin_import, target_import)
        elif not origin_import.is_file():
            target_import.unlink(missing_ok=True)
    full_config['art']['hover']['cards'][card] = entry
    staging_ui = target_ui.with_suffix('.json.staging')
    staging_ui.write_text(json.dumps(full_config, ensure_ascii=False, indent=2) + '\n')
    staging_ui.replace(target_ui)
    for relative in set(previous) - set(paths):
        old = target_art / relative
        if relative.startswith(prefix) and old.resolve().is_relative_to(target_art.resolve()):
            old.unlink(missing_ok=True)
            Path(str(old) + '.import').unlink(missing_ok=True)
