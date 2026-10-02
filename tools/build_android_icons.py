#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""从统一应用图标生成 Android 自适应图标和安全区启动图。"""
from __future__ import annotations

import io
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/app_icon.png"
OUT = ROOT / "assets/android"
BG = (111, 135, 106, 255)


def crop_alpha(image: Image.Image) -> Image.Image:
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    return image.crop(bbox) if bbox else image


def centered(image: Image.Image, canvas: int, content: int, background=(0, 0, 0, 0)) -> Image.Image:
    image = crop_alpha(image)
    image.thumbnail((content, content), Image.Resampling.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), background)
    out.paste(image, ((canvas - image.width) // 2, (canvas - image.height) // 2), image)
    return out


def save(image: Image.Image, path: Path) -> None:
    encoded = io.BytesIO()
    image.save(encoded, "PNG", optimize=True)
    data = encoded.getvalue()
    if path.is_file() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def main() -> int:
    if not SOURCE.is_file():
        raise SystemExit(f"缺少统一应用图标：{SOURCE}")
    with Image.open(SOURCE) as source:
        source = source.convert("RGBA")
    # Android adaptive icon 的前景必须留足安全区，避免圆形/水滴/圆角方形 mask 裁掉角色。
    foreground = centered(source, 432, 315)
    save(foreground, OUT / "icon_foreground_432.png")
    background = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    ImageDraw.Draw(background).rounded_rectangle((2, 2, 430, 430), radius=76, fill=BG)
    save(background, OUT / "icon_background_432.png")
    monochrome = centered(source, 432, 270)
    alpha = monochrome.getchannel("A")
    white = Image.new("RGBA", monochrome.size, (255, 255, 255, 0))
    white.putalpha(alpha)
    save(white, OUT / "icon_monochrome_432.png")
    # 旧版/厂商桌面可能忽略 adaptive-icon XML；legacy 图标自身也做透明圆形安全底。
    legacy = Image.new("RGBA", (192, 192), (0, 0, 0, 0))
    ImageDraw.Draw(legacy).rounded_rectangle((2, 2, 190, 190), radius=34, fill=BG)
    legacy_foreground = centered(source, 192, 148)
    legacy.alpha_composite(legacy_foreground)
    save(legacy, OUT / "icon_legacy_192.png")
    # 启动画面图标更小，四周保留更大的安全边距；系统启动界面不会裁掉上下左右。
    save(centered(source, 432, 215), OUT / "splash_icon_432.png")
    print(f"Android 图标已生成：{OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
