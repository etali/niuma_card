# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""应用导出图保留桌宠比例、透明空间、源文件与可重复构建。"""
import configparser
import hashlib
import importlib.util
from pathlib import Path
import unittest
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_art", ROOT / "tools/build_art.py")
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)


class AppIconTest(unittest.TestCase):
    @staticmethod
    def read_config(name):
        config = configparser.ConfigParser(interpolation=None)
        # project.godot 的 config_version 位于首个 section 之前。
        config.read_string("[header]\n" + (ROOT / name).read_text(encoding="utf-8"))
        return config

    def test_boot_splash_does_not_show_engine_logo(self):
        config = self.read_config("project.godot")
        self.assertFalse(config.getboolean("application", "boot_splash/show_image"))
        self.assertEqual(config.get("application", "boot_splash/bg_color"), "Color(0, 0, 0, 0)")

    def test_macos_window_is_transparent_before_scene_initialization(self):
        config = self.read_config("project.godot")
        self.assertTrue(config.getboolean("display", "window/per_pixel_transparency/allowed"))
        self.assertTrue(config.getboolean("display", "window/size/transparent.macos"))
        self.assertTrue(config.getboolean("display", "window/size/borderless.macos"))
        self.assertFalse(config.getboolean("display", "window/size/resizable.macos"))
        self.assertTrue(config.getboolean("display", "window/size/always_on_top.macos"))
        self.assertEqual(config.get("rendering", "environment/defaults/default_clear_color"),
                         "Color(0, 0, 0, 0)")

    def test_runtime_and_macos_export_use_game_icon(self):
        project = self.read_config("project.godot")
        presets = self.read_config("export_presets.cfg")
        icon = project.get("application", "config/icon").strip('"')
        self.assertEqual(icon, "res://assets/app_icon.png")
        self.assertTrue((ROOT / icon.removeprefix("res://")).is_file())
        macos = [section for section in presets.sections()
                 if presets.get(section, "platform", fallback="") == '"macOS"']
        self.assertTrue(macos, "必须保留 macOS 导出预设")
        for section in macos:
            self.assertEqual(presets.get(section + ".options", "application/icon").strip('"'), icon)

    def test_padding_preserves_alpha_shape_and_source(self):
        source = Image.new("RGBA", (60, 40), (0, 0, 0, 0))
        # 非正方形、不居中的 alpha 主体，检测裁剪/拉伸及居中策略。
        source.paste((210, 80, 40, 255), (6, 4, 54, 36))
        before = source.tobytes()
        icon = art.normalize_app_icon(source, 600)
        self.assertEqual(icon.size, (600, 600))
        self.assertEqual(source.tobytes(), before)
        mask = icon.getchannel("A").point(lambda a: 255 if a >= 128 else 0)
        self.assertEqual(mask.getbbox(), (60, 140, 540, 460))
        self.assertEqual(icon.getpixel((300, 300)), (210, 80, 40, 255))
        self.assertEqual(icon.getpixel((300, 10))[3], 0)
        self.assertAlmostEqual(sum(icon.getchannel("A").tobytes()) / (255 * 600 * 600),
                               (48 * 32) / (60 * 60), delta=0.002)

    def test_repository_icon_is_exact_normalized_source(self):
        source_path = ROOT / "assets/art/app_icon.png"
        self.assertTrue(source_path.is_file(), "仓库必须包含桌宠源图")
        before = hashlib.sha256(source_path.read_bytes()).digest()
        with Image.open(source_path) as source:
            expected = art.normalize_app_icon(source)
        with Image.open(ROOT / "assets/app_icon.png") as icon:
            actual = icon.convert("RGBA")
            self.assertEqual(icon.size, (1024, 1024))
            self.assertEqual(icon.mode, "RGBA")
            self.assertIsNone(ImageChops.difference(expected, actual).getbbox())
            for size in (16, 32, 64):
                alpha = actual.resize((size, size), Image.Resampling.LANCZOS).getchannel("A")
                self.assertGreater(max(alpha.tobytes()), 240)
                self.assertGreater(sum(alpha.tobytes()) / (255 * size * size), 0.15)
        self.assertEqual(hashlib.sha256(source_path.read_bytes()).digest(), before)

    def test_both_entrypoints_use_shared_gate_before_font_transaction(self):
        for name in ("构建游戏.command", "打包发布.command"):
            code = (ROOT / name).read_text()
            self.assertIn("python3 tools/ensure_app_icon.py", code)
            self.assertLess(code.index("ensure_app_icon || exit 1"), code.index("\nsubset_font"))


if __name__ == "__main__":
    unittest.main()
