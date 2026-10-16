#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.
"""生成全游戏共用那枚章的两张贴图（长方形双框办公章）。

- assets/art/overlay/stamp_frame.png：章框，1024×379。A 通道是框的形状（外粗内细两道圆角框，
  边缘毛糙），R 通道是边缘积墨的浓度（贴边一圈更浓）。白色，游戏里按印泥色着色。
- assets/art/overlay/stamp_grain.png：印泥纹理，512×512，四方连续。R 通道是印泥浓淡
  （大片轻重、细麻点、几块没沾上墨），G 通道是毛边噪声（字的边缘按它取阈值）。

字不在贴图里：章上的字由游戏按 ui.json 的 fx.stamps 现排，再用同一张印泥纹理压出麻点和毛边。
可单独重跑，结果固定（种子写死）。需要 Pillow 与 numpy。
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "art" / "overlay"
FRAME_SIZE = (1024, 379)
GRAIN_SIZE = 512
SEED = 20261016


def tile_noise(size: int, cell: float, rng: np.random.Generator) -> np.ndarray:
    """四方连续的平滑噪声：周期网格平铺 3×3 后双三次放大，取中间一块。"""
    grid = max(2, int(round(size / cell)))
    base = rng.random((grid, grid))
    tiled = np.tile(base, (3, 3))
    img = Image.fromarray((tiled * 255).astype(np.uint8)).resize((size * 3, size * 3), Image.BICUBIC)
    arr = np.asarray(img, dtype=np.float32) / 255.0
    return arr[size:size * 2, size:size * 2]


def frame(rng: np.random.Generator) -> Image.Image:
    w, h = FRAME_SIZE
    k = w / 1000.0
    shape = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(shape)
    draw.rounded_rectangle([16 * k, 16 * k, w - 16 * k, h - 16 * k], radius=34 * k, outline=255, width=round(30 * k))
    draw.rounded_rectangle([62 * k, 62 * k, w - 62 * k, h - 62 * k], radius=12 * k, outline=255, width=round(9 * k))
    soft = np.asarray(shape.filter(ImageFilter.GaussianBlur(2.2 * k)), dtype=np.float32) / 255.0
    # 毛边：按细噪声扰动阈值。噪声不必四方连续，取框大小的一块即可。
    edge = tile_noise(GRAIN_SIZE * 2, 7 * k, rng)[:h, :w] * 0.6 + tile_noise(GRAIN_SIZE * 2, 3 * k, rng)[:h, :w] * 0.4
    thr = 0.5 + (edge - 0.5) * 0.55
    alpha = np.clip((soft - thr) / 0.08 + 0.5, 0.0, 1.0)
    inner = np.asarray(Image.fromarray((alpha * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(5 * k)),
        dtype=np.float32) / 255.0
    rim = np.clip(alpha - inner, 0.0, 1.0)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[:, :, 0] = (np.clip(rim * 2.0, 0.0, 1.0) * 255).astype(np.uint8)
    rgba[:, :, 1] = 255
    rgba[:, :, 2] = 255
    rgba[:, :, 3] = (alpha * 255).astype(np.uint8)
    return Image.fromarray(rgba)


def grain(rng: np.random.Generator) -> Image.Image:
    """一块纹理铺满章的整个宽度（章高只用到其中 0.37）。噪声尺度与选定样稿相同：
    样稿按 1000px 宽的章取 160 / 55 / 4 / 7 / 3 像素一格，这里纹理 512px 对应同一宽度。"""
    s = GRAIN_SIZE / 1000.0
    wear = 0.7
    low = tile_noise(GRAIN_SIZE, 160 * s, rng)
    fine = tile_noise(GRAIN_SIZE, max(1.5, 4 * s), rng)
    blot = tile_noise(GRAIN_SIZE, 55 * s, rng)
    density = 0.80 + 0.22 * low
    density *= 1.0 - 0.65 * np.clip((fine - (0.80 - 0.10 * wear)) / 0.06, 0.0, 1.0)
    density *= 1.0 - 0.55 * np.clip((blot - (0.80 - 0.06 * wear)) / 0.07, 0.0, 1.0)
    edge = tile_noise(GRAIN_SIZE, max(1.5, 7 * s), rng) * 0.6 + tile_noise(GRAIN_SIZE, max(1.5, 3 * s), rng) * 0.4
    rgba = np.zeros((GRAIN_SIZE, GRAIN_SIZE, 4), dtype=np.uint8)
    rgba[:, :, 0] = (np.clip(density, 0.0, 1.0) * 255).astype(np.uint8)
    rgba[:, :, 1] = (np.clip(edge, 0.0, 1.0) * 255).astype(np.uint8)
    rgba[:, :, 3] = 255
    return Image.fromarray(rgba)


def main() -> None:
    rng = np.random.default_rng(SEED)
    OUT.mkdir(parents=True, exist_ok=True)
    frame(rng).save(OUT / "stamp_frame.png", optimize=True)
    grain(rng).save(OUT / "stamp_grain.png", optimize=True)
    for name in ("stamp_frame.png", "stamp_grain.png"):
        print(f"写出 {(OUT / name).relative_to(ROOT)}")


if __name__ == "__main__":
    main()
