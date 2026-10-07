# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""高清制作像素用例的源稿入口；正式差分验收不依赖本地归档。"""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def native_art_context():
    """返回 (ui_path, art_path)，没有本地高清源稿时仅跳过制作坐标回归。"""
    current_ui = ROOT / "data/ui.json"
    current = json.loads(current_ui.read_text())
    if all("files" in cfg for cfg in current["art"]["hover"]["cards"].values()):
        return current_ui, ROOT / "assets/art"
    pointer = ROOT / "build/art_generation/hover_runtime_source.json"
    if not pointer.is_file():
        raise unittest.SkipTest("高清制作源稿仅保存在本地 build；正式 384 差分素材由独立用例强制验收")
    archive = json.loads(pointer.read_text())
    ui_path, art_path = Path(archive["ui"]), Path(archive["art"])
    if not ui_path.is_file() or not art_path.is_dir():
        raise unittest.SkipTest("本地高清制作归档不可用；正式 384 差分素材由独立用例强制验收")
    source = json.loads(ui_path.read_text())
    if not all("files" in cfg for cfg in source["art"]["hover"]["cards"].values()):
        raise AssertionError("高清制作归档配置必须引用完整原生 PNG")
    return ui_path, art_path
