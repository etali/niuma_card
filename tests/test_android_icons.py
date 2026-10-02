# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

from pathlib import Path
import configparser
import unittest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / 'assets/android'
PRESETS = ROOT / 'export_presets.cfg'

class AndroidIconTests(unittest.TestCase):
    def test_all_layers_exist_with_expected_dimensions_and_modes(self):
        expected = {
            'icon_foreground_432.png': (432, 432),
            'icon_background_432.png': (432, 432),
            'icon_monochrome_432.png': (432, 432),
            'icon_legacy_192.png': (192, 192),
            'splash_icon_432.png': (432, 432),
        }
        for name, size in expected.items():
            with Image.open(ANDROID / name) as image:
                self.assertEqual(image.size, size, name)
                self.assertEqual(image.mode, 'RGBA', name)

    def test_adaptive_background_is_transparent_rounded_square(self):
        with Image.open(ANDROID / 'icon_background_432.png') as image:
            self.assertEqual(image.getpixel((0, 0))[3], 0)
            self.assertGreater(image.getpixel((216, 216))[3], 0)
            self.assertGreater(image.getpixel((40, 40))[3], 0)
            self.assertEqual(image.getpixel((2, 2))[3], 0)

    def test_foreground_and_splash_keep_safe_transparent_margin(self):
        for name, max_extent in [('icon_foreground_432.png', 335), ('splash_icon_432.png', 260)]:
            with Image.open(ANDROID / name) as image:
                bbox = image.getchannel('A').getbbox()
                self.assertIsNotNone(bbox, name)
                width = bbox[2] - bbox[0]
                height = bbox[3] - bbox[1]
                self.assertLessEqual(max(width, height), max_extent, name)
                self.assertGreaterEqual(bbox[0], (432 - max_extent) // 2 - 4, name)
                self.assertGreaterEqual(bbox[1], (432 - max_extent) // 2 - 4, name)

    def test_legacy_icon_has_transparent_corners_for_older_launchers(self):
        with Image.open(ANDROID / 'icon_legacy_192.png') as image:
            for point in [(0, 0), (191, 0), (0, 191), (191, 191)]:
                self.assertEqual(image.getpixel(point)[3], 0)

    def test_presets_use_adaptive_layers_and_disable_godot_splash(self):
        text = PRESETS.read_text()
        self.assertEqual(text.count('adaptive_foreground_432x432='), 2)
        self.assertEqual(text.count('splash_screen/disable_godot_boot_splash=true'), 2)
        for path in ['icon_foreground_432.png', 'icon_background_432.png', 'icon_monochrome_432.png', 'splash_icon_432.png']:
            self.assertIn(f'res://assets/android/{path}', text)

if __name__ == '__main__':
    unittest.main()
