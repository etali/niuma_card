# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""隔离的素材目录验收：验证缺失引用会失败，程序化可替代位图不会阻断。"""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "check_art_assets.py"
SPEC = importlib.util.spec_from_file_location("check_art_assets", SCRIPT)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class ArtAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.art = self.root / "assets" / "art"
        self.cards_path = self.root / "data" / "cards.json"
        self.manifest_path = self.art / "art_manifest.json"
        for key, value in (("ROOT", self.root), ("ART", self.art),
                           ("CARDS_JSON", self.cards_path)):
            replacement = patch.object(checker, key, value)
            replacement.start()
            self.addCleanup(replacement.stop)
        self.cards = {"_comment": "fixture", "cash": {}, "new_card": {}}
        self.write_json(self.cards_path, self.cards)
        # 两张卡的配置足以验证数量来自当前卡表，不依赖某次发布的总数。
        icons = {}
        for card_id in ("cash", "new_card"):
            name = f"icon/icon_{card_id}.png"
            self.write_image(name, (1024, 1024))
            icons[card_id] = {"file": name}
        misc = {}
        for name, size in checker.REQUIRED_RASTER.items():
            self.write_image(name, size)
            misc[Path(name).stem] = {"file": name}
        self.manifest = {"icons": icons, "misc": misc}
        self.write_json(self.manifest_path, self.manifest)
        self.write_image("app_icon.png", (48, 40))
        self.export_icon = self.root / "assets" / "app_icon.png"
        with Image.new("RGBA", (1024, 1024), (100, 80, 60, 255)) as image:
            image.save(self.export_icon)

    @staticmethod
    def write_json(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def write_image(self, name, size):
        path = self.art / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with Image.new("RGBA", size, (100, 80, 60, 255)) as image:
            image.save(path)

    def run_check(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = checker.main([])
        return status, output.getvalue()

    def test_dynamic_cards_optional_gaps_and_separate_export_icon(self):
        original_icon = (self.art / "app_icon.png").read_bytes()
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("配置中发现 2 张", output)
        self.assertIn("assets/art/app_icon.png  48×40 RGBA", output)
        self.assertIn("assets/app_icon.png  1024×1024 RGBA", output)
        self.assertIn("OK（使用程序化设计）", output)
        self.assertNotIn("预期为", output)
        self.assertEqual((self.art / "app_icon.png").read_bytes(), original_icon)

    def test_export_icon_is_required_with_size_and_alpha(self):
        for mode, size, message in ((None, None, "应用导出图缺失"),
                                    ("RGBA", (48, 40), "应用导出图尺寸不符"),
                                    ("RGB", (1024, 1024), "应用导出图必须保留透明通道")):
            with self.subTest(mode=mode, size=size):
                self.export_icon.unlink(missing_ok=True)
                if mode:
                    with Image.new(mode, size) as image:
                        image.save(self.export_icon)
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn(message, output)

    def test_added_card_needs_a_matching_icon(self):
        self.cards["future_card"] = {}
        self.write_json(self.cards_path, self.cards)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("icon_future_card.png", output)

    def test_manifest_parse_and_reference_failures(self):
        cases = [
            ("{", "无法读取 JSON"),
            ("[]", "顶层必须是对象"),
            (json.dumps({"icons": [], "misc": {}}), "manifest.icons 必须是对象"),
            (json.dumps({"icons": {}, "misc": {"bad": {"file": ""}}}),
             "必须是非空路径字符串"),
            (json.dumps({"icons": {}, "misc": {"bad": {"file": "../outside.png"}}}),
             "必须是 assets/art 内的相对路径"),
            (json.dumps({"icons": {}, "misc": {"bad": {"file": "table/missing.png"}}}),
             "manifest 引用缺失"),
        ]
        for content, message in cases:
            with self.subTest(message=message):
                self.manifest_path.write_text(content, encoding="utf-8")
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn(message, output)

    def test_optional_manifest_reference_stays_a_warning(self):
        self.manifest["misc"]["glow"] = {"file": "overlay/overlay_buff_glow.png"}
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("manifest 引用缺失", output)
        self.assertIn("可由程序绘制", output)

    def test_card_frame_does_not_require_a_master_texture(self):
        # 即使以后误把母版加回必需表，这个独立的缺文件场景也必须仍然通过。
        master = self.art / "plate/plate_master.png"
        master.unlink(missing_ok=True)
        self.manifest["misc"].pop("plate_master", None)
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertFalse(master.exists())

    def test_legacy_master_reference_neither_blocks_nor_changes_source(self):
        master = self.art / "plate/plate_master.png"
        self.manifest["misc"]["plate_master"] = {"file": "plate/plate_master.png"}
        self.write_json(self.manifest_path, self.manifest)
        for retained in (False, True):
            with self.subTest(retained=retained):
                if retained:
                    master.parent.mkdir(parents=True, exist_ok=True)
                    # 历史素材不再解码或验尺寸；只保留原样，不触发出图或清理。
                    master.write_bytes(b"legacy source left untouched")
                else:
                    master.unlink(missing_ok=True)
                before = master.read_bytes() if retained else None
                status, output = self.run_check()
                self.assertEqual(status, 0, output)
                self.assertIn("legacy兼容项", output)
                self.assertEqual(master.read_bytes() if master.exists() else None, before)

    def test_required_raster_is_decoded_and_sized(self):
        path = self.art / "icon/icon_cash.png"
        for damaged in (True, False):
            with self.subTest(damaged=damaged):
                if damaged:
                    path.write_bytes(b"not an image")
                else:
                    self.write_image("icon/icon_cash.png", (12, 12))
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn("无法读取" if damaged else "尺寸不符", output)

    def test_unreadable_or_empty_card_config_fails(self):
        for data in ({}, {"cash": "invalid"}):
            with self.subTest(data=data):
                self.write_json(self.cards_path, data)
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn("cards.json", output)


if __name__ == "__main__":
    unittest.main()
