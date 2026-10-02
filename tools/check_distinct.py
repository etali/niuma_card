#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""对当前底板 face 色做 HSV 阈值初筛；风险仅供人工视觉验收参考。

默认读取仓库 data/ui.json，不读取旧稿图片或用户目录。
--config 可显式指定 ui.json 或 palette.json，缺少的键由默认配置补齐。
只分析 #RRGGBB 格式的 face，不分析标题带、图标、轮廓、光照或视觉感知。
"""

import argparse
import colorsys
import json
from pathlib import Path
import re
import sys

from project_paths import display_path, redact_paths


DEFAULT_CONFIG = Path(__file__).resolve().parents[1] / "data" / "ui.json"
NOTICE = "风险提示，不代表科学/感知可区分性结论"


class InputError(ValueError):
    """配置无法用于检查。"""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(1, f"输入错误: {message}\n")


def read_object(path):
    try:
        with Path(path).open(encoding="utf-8") as source:
            value = json.load(source)
    except (OSError, UnicodeError, ValueError) as exc:
        raise InputError(f"无法读取 JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise InputError(f"{path}: JSON 顶层必须是对象")
    return value


def palette_section(value, source, required=False):
    """接受完整 ui.json 或以 palette 内容为根的 palette.json。"""
    palette = value.get("palette", value)
    if not isinstance(palette, dict):
        raise InputError(f"{source}: palette 必须是对象")
    if required and "plates" not in palette:
        raise InputError(f"{source}: 缺少 palette.plates")
    if "plates" in palette and not isinstance(palette["plates"], dict):
        raise InputError(f"{source}: plates 必须是对象")
    return palette


def merge(base, override):
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def load_faces(config=None, default_config=DEFAULT_CONFIG):
    palette = palette_section(read_object(default_config), default_config, required=True)
    if config is not None:
        override = palette_section(read_object(config), config)
        palette = merge(palette, override)

    faces = {}
    for slot, entry in palette["plates"].items():
        if slot.startswith("_"):
            continue
        if not isinstance(entry, dict):
            raise InputError(f"plates.{slot}: 底板配置必须是对象")
        value = entry.get("face")
        if not isinstance(value, str) or re.fullmatch(r"#[0-9a-fA-F]{6}", value) is None:
            raise InputError(f"plates.{slot}.face: 必须是 #RRGGBB 颜色，收到 {value!r}")
        faces[slot] = tuple(int(value[index:index + 2], 16) for index in (1, 3, 5))
    if len(faces) < 2:
        raise InputError("plates 至少需要两个具有 face 色的底板槽位")
    return faces


def hsv(color):
    h, s, v = colorsys.rgb_to_hsv(*(channel / 255 for channel in color))
    return h * 360, s * 100, v * 100


def hue_dist(a, b):
    distance = abs(a - b) % 360
    return min(distance, 360 - distance)


def risk_pairs(faces):
    items = [(slot, hsv(color)) for slot, color in faces.items()]
    risks = []
    for index, (first, a) in enumerate(items):
        for second, b in items[index + 1:]:
            dh, ds, dv = hue_dist(a[0], b[0]), abs(a[1] - b[1]), abs(a[2] - b[2])
            if dh < 30 and ds < 12 and dv < 20:
                risks.append((first, second, dh, ds, dv))
    return risks


def main(argv=None):
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="显式覆盖配置：ui.json 或 palette.json")
    args = parser.parse_args(argv)
    try:
        faces = load_faces(args.config)
    except InputError as exc:
        print(redact_paths(f"输入错误: {exc}"), file=sys.stderr)
        return 1

    print(f"默认配置: {display_path(DEFAULT_CONFIG)}")
    if args.config is not None:
        print(f"显式覆盖: {display_path(args.config)}（缺键由默认配置补齐）")
    print("仅检查 palette.plates.*.face；未读取游戏中的用户配色或旧稿图片。")
    print(f"{NOTICE}。")
    print("阈值：色相差 30° / 饱和度差 12 点 / HSV 明度差 20 点；三项均低于阈值时提示风险。")
    print("\n配置中的 face 色:")
    for slot, color in faces.items():
        h, s, v = hsv(color)
        print(f"  {slot:<16} #{color[0]:02X}{color[1]:02X}{color[2]:02X}  H{h:5.1f} S{s:5.1f} V{v:5.1f}")

    risks = risk_pairs(faces)
    print("\n需人工复核的组合（HSV 三项差值均低于阈值）:")
    for first, second, dh, ds, dv in risks:
        print(f"  ! {first} vs {second}  dH={dh:5.1f} dS={ds:5.1f} dV={dv:5.1f}")
    if not risks:
        print("  无阈值风险；这不代表视觉上一定可区分。")
    print(f"\n检查 {len(faces)} 个底板槽位，提示 {len(risks)} 组风险。请结合实际界面、图标和状态进行视觉验收。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
