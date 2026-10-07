#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""检查仓库素材是否覆盖当前卡表，并核对 data/ui.json 的 art 段中的文件引用。

用法：python3 tools/check_art_assets.py

必需素材缺失、损坏、尺寸不符，或展示配置无法解析、必需引用悬空时返回非零。
桌面和 Buff 光环允许程序化绘制，可选位图缺失只提示，不阻止构建。
旧 plate_master.png 引用仅作 legacy 兼容，不再是卡牌运行依赖。
桌宠源图可为非方形；正式导出图 assets/app_icon.png 必须是 1024×1024 RGBA。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath

# 支持命令行运行与通过 tests 动态载入此检查器。
try:
    from tools.hover_delta_codec import decode_file as decode_hover_delta
except ModuleNotFoundError:
    from hover_delta_codec import decode_file as decode_hover_delta

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("缺少 Pillow：请安装 pillow 后再运行 tools/check_art_assets.py") from exc


ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "assets" / "art"
CARDS_JSON = ROOT / "data" / "cards.json"
UI_JSON = ROOT / "data" / "ui.json"

# 固定整卡与覆盖素材的验收尺寸；卡牌图标由当前 cards.json 动态枚举。
REQUIRED_RASTER = {
    "table/pawnshop.png": (1200, 1600),
    "table/card_back.png": (1200, 1600),
    "table/badge_base.png": (1024, 1024),
    "overlay/overlay_shield.png": (1024, 1024),
    "overlay/overlay_void_stamp.png": (1024, 1024),
}

# CardArt.table_texture() 对所有牌桌素材都接受 png/jpg。
# 缺少这些位图不等于视觉功能缺失：桌面/光环可以由程序绘制。
OPTIONAL_RASTER = (
    ("table/table_felt.png", "table/table_felt.jpg"),
    ("table/zone_tray.png", "table/zone_tray.jpg"),
    ("table/market_slot.png", "table/market_slot.jpg"),
    ("overlay/overlay_buff_glow.png",),
)
OPTIONAL_PATHS = {name for alternatives in OPTIONAL_RASTER for name in alternatives}

# 旧母版仅作参考保留，不要求存在，也不自动删除用户源图。
LEGACY_RASTER = {"plate/plate_master.png"}


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def load_object(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"无法读取 JSON：{rel(path)}（{exc}）") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{rel(path)} 顶层必须是对象")
    return data


def load_card_ids() -> list[str]:
    data = load_object(CARDS_JSON)
    ids = []
    for card_id, value in data.items():
        if card_id.startswith("_"):
            continue
        if not isinstance(value, dict):
            raise ValueError(f"{rel(CARDS_JSON)} 中的卡牌 {card_id} 必须是对象")
        if not card_id or any(char in card_id for char in "/\\\0"):
            raise ValueError(f"{rel(CARDS_JSON)} 中的卡牌 ID 无法用作图标名：{card_id!r}")
        ids.append(card_id)
    if not ids:
        raise ValueError(f"{rel(CARDS_JSON)} 中没有卡牌定义，无法核对图标")
    return ids


def inspect_image(path: Path) -> tuple[tuple[int, int], str]:
    with Image.open(path) as image:
        # 实际解码，使截断/损坏文件在检查阶段暴露。
        image.load()
        return image.size, image.mode


def check_one(path: Path, expected_size: tuple[int, int] | None,
              errors: list[str], label: str = "必需") -> bool:
    if not path.is_file():
        errors.append(f"{label}缺失：{rel(path)}")
        return False
    try:
        size, mode = inspect_image(path)
    except (OSError, ValueError, SyntaxError) as exc:
        errors.append(f"{label}无法读取：{rel(path)}（{exc}）")
        return False
    if expected_size is not None and size != expected_size:
        errors.append(
            f"{label}尺寸不符：{rel(path)}（实际 {size[0]}×{size[1]}，"
            f"应为 {expected_size[0]}×{expected_size[1]}）")
        return False
    print(f"  OK   {rel(path)}  {size[0]}×{size[1]} {mode}")
    return True


def check_app_icon(errors: list[str], warnings: list[str]) -> None:
    check_one(ART / "app_icon.png", None, errors, label="桌宠源图")
    export = ROOT / "assets" / "app_icon.png"
    if check_one(export, (1024, 1024), errors, label="应用导出图"):
        with Image.open(export) as image:
            if image.mode != "RGBA":
                errors.append(f"应用导出图必须保留透明通道：{rel(export)}（{image.mode}）")


def check_icons(card_ids: list[str], errors: list[str], warnings: list[str]) -> None:
    icon_dir = ART / "icon"
    print(f"卡牌图标：配置中发现 {len(card_ids)} 张")
    expected_names = {f"icon_{card_id}.png" for card_id in card_ids}
    actual_names = {path.name for path in icon_dir.glob("icon_*.png")}
    extras = sorted(actual_names - expected_names)
    if extras:
        warnings.append("素材目录存在未被 cards.json 引用的图标：" + ", ".join(extras))
    # 正式小图与差分帧共享尺寸；旧 PNG 序列和旧线稿仍保留兼容检查。
    try:
        art = load_object(UI_JSON).get("art", {})
        illustrated = art.get("illustrations", {})
        animations = art.get("hover", {}).get("cards", {})
    except (ValueError, OSError, AttributeError):
        illustrated = {}
        animations = {}
    if not isinstance(illustrated, dict):
        illustrated = {}
    for card_id in card_ids:
        config = animations.get(card_id, {}) if isinstance(animations, dict) else {}
        size = config.get("frame_size") if isinstance(config, dict) and config.get("codec") == "hdelta-v1" else None
        expected = (None if card_id in illustrated else (1024, 1024))
        if isinstance(size, list) and len(size) == 2 and all(type(n) is int and n > 0 for n in size):
            expected = tuple(size)
        check_one(icon_dir / f"icon_{card_id}.png", expected, errors,
                  label=f"卡牌图标 {card_id}")


def check_delta_animation(name: str, entry: dict, manifest: dict,
                          errors: list[str]) -> int:
    """解码正式差分素材，校验显示顺序、静止起点和稳定终态。"""
    label = f"ui.art.hover.cards.{name}"
    if entry.get("codec") != "hdelta-v1":
        errors.append(f"{label}.codec 不支持：{entry.get('codec')!r}")
        return 0
    if "files" in entry:
        errors.append(f"{label} 差分动画不能同时登记 files")
        return 0
    filename = entry.get("file")
    if not isinstance(filename, str) or not filename.strip():
        errors.append(f"{label}.file 必须是非空路径字符串")
        return 0
    relative = PurePosixPath(filename)
    if (relative.is_absolute() or ".." in relative.parts or "\\" in filename
            or ":" in filename or "\0" in filename):
        errors.append(f"{label}.file 必须是 assets/art 内的相对路径")
        return 0
    if relative.suffix != ".hdelta":
        errors.append(f"{label}.file 差分素材必须使用 .hdelta 扩展名")
        return 0
    size, count = entry.get("frame_size"), entry.get("frames")
    if (not isinstance(size, list) or len(size) != 2
            or not all(type(n) is int and 0 < n <= 384 for n in size)
            or type(count) is not int or count <= 0):
        errors.append(f"{label} 差分帧尺寸必须为 1～384 的整数，帧数必须为正整数")
        return 0
    target = ART / filename
    if not target.is_file():
        errors.append(f"差分动画缺失：{rel(target)}")
        return 0
    try:
        decoded = decode_hover_delta(target)
    except (OSError, ValueError) as exc:
        errors.append(f"差分动画无法解码：{rel(target)}（{exc}）")
        return 0
    timeline, frames = decoded["timeline"], decoded["frames"]
    if (decoded["width"], decoded["height"]) != tuple(size) or len(timeline) != count:
        errors.append(f"{label} 差分文件与登记的帧尺寸或帧数不一致")
        return 0
    if (not frames or any(len(raw) != size[0] * size[1] * 4 for raw in frames)
            or any(type(index) is not int or not 0 <= index < len(frames) for index in timeline)):
        errors.append(f"{label} 差分帧 RGBA 长度或显示索引不合法")
        return 0
    if any(min(raw[3::4]) != 0 for raw in frames):
        errors.append(f"{label} 必须保留 RGBA 透明底")
    icons = manifest.get("icons", {})
    still_entry = icons.get(name, {}) if isinstance(icons, dict) else {}
    still_filename = still_entry.get("file", f"icon/icon_{name}.png") if isinstance(still_entry, dict) else f"icon/icon_{name}.png"
    if (not isinstance(still_filename, str) or not still_filename
            or PurePosixPath(still_filename).is_absolute()
            or ".." in PurePosixPath(still_filename).parts
            or any(char in still_filename for char in "\\:\0")):
        errors.append(f"{label} 静止 icon 必须是 assets/art 内的相对路径")
        return 0
    still_path = ART / still_filename
    try:
        with Image.open(still_path) as still:
            if still.size != tuple(size) or still.convert("RGBA").tobytes() != frames[timeline[0]]:
                errors.append(f"{label} 第一帧必须与静止 icon 的 RGBA 一致")
    except (OSError, ValueError, SyntaxError) as exc:
        errors.append(f"{label} 静止 icon 无法读取（{exc}）")
    if len(timeline) >= 4 and any(frames[index] != frames[timeline[0]] for index in timeline[:4]):
        errors.append(f"{label} 前四帧必须保持静止 icon")
    if (entry.get("play_mode", "loop") == "once" and len(timeline) >= 3
            and any(frames[index] != frames[timeline[-1]] for index in timeline[-3:])):
        errors.append(f"{label} 最后三帧必须保持完整终态")
    if entry.get("play_mode", "loop") == "loop" and frames[timeline[-1]] != frames[timeline[0]]:
        errors.append(f"{label} 循环动画末帧必须恢复静止 icon")
    print(f"  OK   {rel(target)}  {size[0]}×{size[1]} RGBA，{len(timeline)} 帧 / {len(frames)} 个无损姿势")
    return 1


def check_manifest(errors: list[str], warnings: list[str]) -> None:
    path = UI_JSON
    try:
        manifest = load_object(path).get("art")
    except ValueError as exc:
        errors.append(str(exc))
        return

    if not isinstance(manifest, dict):
        errors.append("ui.art 必须是对象")
        return

    count = 0
    for section_name in ("icons", "misc", "illustrations"):
        if section_name == "illustrations" and section_name not in manifest:
            continue
        section = manifest.get(section_name)
        if not isinstance(section, dict):
            errors.append(f"ui.art.{section_name} 必须是对象")
            continue
        for name, entry in section.items():
            if name.startswith("_"):
                continue
            label = f"ui.art.{section_name}.{name}"
            filename = entry.get("file") if isinstance(entry, dict) else None
            if not isinstance(filename, str) or not filename.strip():
                errors.append(f"{label}.file 必须是非空路径字符串")
                continue
            relative = PurePosixPath(filename)
            if (relative.is_absolute() or ".." in relative.parts
                    or "\\" in filename or ":" in filename or "\0" in filename):
                errors.append(f"{label}.file 必须是 assets/art 内的相对路径：{filename!r}")
                continue
            count += 1
            target = ART / filename
            if filename in LEGACY_RASTER:
                state = "仍保留" if target.is_file() else "已缺失"
                warnings.append(
                    f"legacy兼容项：{label}.file → {rel(target)}（{state}；"
                    "卡牌框架由 shaders/ 代码生成，不要求此位图且不修改源图）")
                continue
            if not target.is_file():
                message = f"ui.art 引用缺失：{label}.file → {rel(target)}"
                if filename in OPTIONAL_PATHS:
                    warnings.append(message + "（可选位图，可由程序绘制）")
                else:
                    errors.append(message)
            elif section_name == "illustrations":
                if name not in load_card_ids():
                    errors.append(f"{label} 不是当前卡表中的卡牌")
                if check_one(target, None, errors, label="情景插画"):
                    with Image.open(target) as illustration:
                        if illustration.mode != "RGBA" or illustration.getchannel("A").getextrema()[0] != 0:
                            errors.append(f"{label} 必须为保留透明底的 RGBA 插画")
    hover = manifest.get("hover", {})
    if not isinstance(hover, dict):
        errors.append("ui.art.hover 必须是对象")
        hover = {}
    fps = hover.get("fps", 12)
    if not isinstance(fps, (int, float)) or fps <= 0:
        errors.append("ui.art.hover.fps 必须为正数")
    animations = hover.get("cards", {})
    if not isinstance(animations, dict):
        errors.append("ui.art.hover.cards 必须是对象")
        animations = {}
    for name, entry in animations.items():
        label = f"ui.art.hover.cards.{name}"
        if not isinstance(entry, dict):
            errors.append(f"{label} 必须是对象")
            continue
        if entry.get("play_mode", "loop") not in ("loop", "once"):
            errors.append(f"{label}.play_mode 必须是 loop 或 once")
        if "codec" in entry:
            count += check_delta_animation(name, entry, manifest, errors)
            continue
        if "files" in entry:
            files, size, frames = entry["files"], entry.get("frame_size"), entry.get("frames")
            if (not isinstance(files, list) or not files
                    or not all(isinstance(file, str) and file for file in files)
                    or not isinstance(frames, int) or frames != len(files)
                    or not isinstance(size, list) or len(size) != 2
                    or not all(isinstance(n, int) and n > 0 for n in size)):
                errors.append(f"{label} 的完整帧路径数量、帧数与原生尺寸不一致")
                continue
            valid_paths = True
            for filename in dict.fromkeys(str(file) for file in files):
                relative = PurePosixPath(filename)
                if (relative.is_absolute() or ".." in relative.parts or "\\" in filename
                        or ":" in filename or "\0" in filename or not filename):
                    errors.append(f"{label}.files 必须是 assets/art 内的相对路径")
                    valid_paths = False
                    continue
                target = ART / filename
                if not check_one(target, tuple(size), errors, label="完整动作帧"):
                    valid_paths = False
                    continue
                with Image.open(target) as image:
                    if image.mode != "RGBA" or image.getchannel("A").getextrema()[0] != 0:
                        errors.append(f"{label} 必须保留 RGBA 透明底")
            if valid_paths:
                still_entry = manifest.get("icons", {}).get(name, {})
                still_path = ART / still_entry.get("file", f"icon/icon_{name}.png")
                if still_path.is_file():
                    with Image.open(still_path) as still, Image.open(ART / files[0]) as first:
                        if still.size != tuple(size) or still.convert("RGBA").tobytes() != first.convert("RGBA").tobytes():
                            errors.append(f"{label} 第一帧必须与静止 icon 的原生 RGBA 一致")
            count += len(set(files))
            continue
        filename = entry.get("file", "")
        if not isinstance(filename, str) or not filename.strip():
            errors.append(f"{label}.file 必须是非空路径字符串")
            continue
        relative = PurePosixPath(filename)
        if (relative.is_absolute() or ".." in relative.parts or "\\" in filename
                or ":" in filename or "\0" in filename):
            errors.append(f"{label}.file 必须是 assets/art 内的相对路径")
            continue
        cell, content = entry.get("cell_size"), entry.get("content_size")
        columns, frames = entry.get("columns"), entry.get("frames")
        sizes_ok = all(isinstance(size, list) and len(size) == 2
                       and all(isinstance(n, int) and n > 0 for n in size)
                       for size in (cell, content))
        if (not sizes_ok or not isinstance(columns, int) or columns <= 0
                or not isinstance(frames, int) or frames <= 0):
            errors.append(f"{label} 的帧尺寸、列数、帧数必须为正整数")
            continue
        if any(content[i] > cell[i] for i in range(2)):
            errors.append(f"{label}.content_size 不能大于 cell_size")
        count += 1
        target = ART / filename
        expected = (cell[0] * columns, cell[1] * ((frames + columns - 1) // columns))
        if not check_one(target, expected, errors, label="动作图集"):
            continue
        with Image.open(target) as atlas:
            if atlas.mode != "RGBA" or atlas.getchannel("A").getextrema()[0] != 0:
                errors.append(f"{label} 必须保留 RGBA 透明底")
    print(f"ui.art：已核对 {count} 个文件引用")


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    errors: list[str] = []
    warnings: list[str] = []

    print(f"检查素材目录：{rel(ART)}")
    check_app_icon(errors, warnings)
    try:
        card_ids = load_card_ids()
    except ValueError as exc:
        errors.append(str(exc))
    else:
        check_icons(card_ids, errors, warnings)

    print("必需的整卡/覆盖素材：")
    for filename, size in REQUIRED_RASTER.items():
        check_one(ART / filename, size, errors)
    check_manifest(errors, warnings)

    print("可替换外观（默认程序化实现已完成）：")
    for alternatives in OPTIONAL_RASTER:
        found = [ART / name for name in alternatives if (ART / name).is_file()]
        if found:
            for path in found:
                check_one(path, None, errors, label="可选")
        else:
            names = " 或 ".join(rel(ART / name) for name in alternatives)
            print(f"  OK（使用程序化设计）  {names}")

    if warnings:
        print(f"\n警告（{len(warnings)}）：")
        for warning in warnings:
            print(f"  - {warning}")
    if errors:
        print(f"\n失败（{len(errors)}）：")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("\n必需素材与 ui.art 引用检查通过；默认程序化桌面与光环无需补位图。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
