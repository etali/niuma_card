# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""隔离的素材目录验收：验证缺失引用会失败，程序化可替代位图不会阻断。"""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "check_art_assets.py"
sys.path.insert(0, str(SCRIPT.parent))
from hover_delta_codec import encode_frames

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
        self.manifest_path = self.root / "data" / "ui.json"
        for key, value in (("ROOT", self.root), ("ART", self.art),
                           ("CARDS_JSON", self.cards_path), ("UI_JSON", self.manifest_path)):
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

    def write_json(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        if path == self.manifest_path:
            data = {"defaults": {"icon_scale": 0.75}, "art": data}
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

    def test_hover_atlas_reference_is_checked(self):
        entry = {"file": "icon/hover/missing.png", "cell_size": [32, 32],
                 "content_size": [24, 24], "columns": 4, "frames": 16}
        self.manifest["hover"] = {"fps": 12, "cards": {"new_card": entry}}
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("动作图集缺失", output)
        target = self.art / entry["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        with Image.new("RGBA", (128, 128), (0, 0, 0, 0)) as image:
            image.save(target)
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        entry["file"] = "../outside.png"
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("ui.art.hover.cards.new_card.file 必须是 assets/art 内的相对路径", output)

    def test_native_frames_require_full_resolution_and_original_first_frame(self):
        source = self.art / "icon/icon_cash.png"
        target = self.art / "icon/hover/native.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        with Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)) as image:
            image.putpixel((512, 512), (100, 80, 60, 255))
            image.save(source)
            image.putpixel((500, 500), (100, 80, 60, 255))
            image.save(target)
        entry = {"files": ["icon/icon_cash.png", "icon/hover/native.png"],
                 "frames": 2, "frame_size": [1024, 1024], "play_mode": "once"}
        self.manifest["hover"] = {"fps": 12, "cards": {"cash": entry}}
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        entry["files"][0] = entry["files"][1]
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("第一帧必须与静止 icon 的原生 RGBA 一致", output)
        entry["files"][0] = "icon/icon_cash.png"
        with Image.new("RGBA", (256, 256), (0, 0, 0, 0)) as image:
            image.save(target)
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("完整动作帧尺寸不符", output)
        entry["frames"] = 3
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("完整帧路径数量、帧数与原生尺寸不一致", output)

    def test_hover_atlas_layout_and_speed_are_checked(self):
        entry = {"file": "icon/hover/test.png", "cell_size": [32, 32],
                 "content_size": [24, 24], "columns": 4, "frames": 16}
        self.manifest["hover"] = {"fps": 12, "cards": {"new_card": entry}}
        target = self.art / entry["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        with Image.new("RGBA", (64, 64), (0, 0, 0, 0)) as image:
            image.save(target)
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("动作图集尺寸不符", output)
        self.manifest["hover"]["fps"] = 0
        entry["cell_size"] = [0, 32]
        self.write_json(self.manifest_path, self.manifest)
        status, output = self.run_check()
        self.assertEqual(status, 1, output)
        self.assertIn("fps 必须为正数", output)
        self.assertIn("帧尺寸、列数、帧数必须为正整数", output)

    def write_delta_fixture(self, size=(384, 352), play_mode="once"):
        source = self.art / "icon/icon_cash.png"
        with Image.new("RGBA", size, (0, 0, 0, 0)) as image:
            image.putpixel((10, 10), (100, 80, 60, 255))
            image.save(source)
            first = image.tobytes()
            image.putpixel((11, 10), (100, 80, 60, 255))
            second = image.tobytes()
        entry = {"codec": "hdelta-v1", "file": "icon/hover/cash.hdelta",
                 "frame_size": list(size), "frames": 8, "play_mode": play_mode}
        timeline = [first] * 4 + [second] * 4
        target = self.art / entry["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(encode_frames(timeline, *size))
        self.manifest["hover"] = {"fps": 12, "cards": {"cash": entry}}
        self.write_json(self.manifest_path, self.manifest)
        return entry, target, first, second

    def test_delta_small_frames_decode_with_original_start_and_aspect_ratio(self):
        entry, target, first, second = self.write_delta_fixture()
        status, output = self.run_check()
        self.assertEqual(status, 0, output)
        self.assertIn("384×352 RGBA，8 帧 / 2 个无损姿势", output)
        decoded = checker.decode_hover_delta(target)
        self.assertEqual(decoded["frames"], [first, second])
        self.assertEqual(decoded["timeline"], [0] * 4 + [1] * 4)

    def test_delta_metadata_path_and_codec_are_checked(self):
        entry, target, first, second = self.write_delta_fixture()
        good = dict(entry)
        for changes, message in (
            ({"codec": "future-v2"}, ".codec 不支持"),
            ({"files": []}, "不能同时登记 files"),
            ({"file": ""}, "必须是非空路径字符串"),
            ({"file": "../outside.hdelta"}, "必须是 assets/art 内的相对路径"),
            ({"file": "icon/hover/cash.png"}, "必须使用 .hdelta 扩展名"),
            ({"file": "icon/hover/missing.hdelta"}, "差分动画缺失"),
            ({"frame_size": [385, 352]}, "差分帧尺寸必须为 1～384"),
            ({"frame_size": [384, True]}, "差分帧尺寸必须为 1～384"),
            ({"frames": 0}, "帧数必须为正整数"),
            ({"frames": 9}, "登记的帧尺寸或帧数不一致"),
            ({"frame_size": [384, 351]}, "登记的帧尺寸或帧数不一致"),
        ):
            with self.subTest(changes=changes):
                entry.clear()
                entry.update(good | changes)
                self.write_json(self.manifest_path, self.manifest)
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn(message, output)

    def test_delta_corruption_is_rejected(self):
        entry, target, first, second = self.write_delta_fixture()
        valid = target.read_bytes()
        for corrupted in (b"bad", valid[:-1], valid + b"trailing"):
            with self.subTest(length=len(corrupted)):
                target.write_bytes(corrupted)
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn("差分动画无法解码", output)

    def test_delta_start_pause_terminal_and_loop_are_checked(self):
        entry, target, first, second = self.write_delta_fixture()
        for frames, mode, message in (
            ([second] * 8, "once", "第一帧必须与静止 icon 的 RGBA 一致"),
            ([first] * 3 + [second] * 5, "once", "前四帧必须保持静止 icon"),
            ([first] * 4 + [second] * 3 + [first], "once", "最后三帧必须保持完整终态"),
            ([first] * 4 + [second] * 4, "loop", "循环动画末帧必须恢复静止 icon"),
        ):
            with self.subTest(message=message):
                entry["play_mode"] = mode
                self.write_json(self.manifest_path, self.manifest)
                target.write_bytes(encode_frames(frames, *entry["frame_size"]))
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn(message, output)
        target.write_bytes(encode_frames([first] * 4 + [second] + [first] * 3,
                                        *entry["frame_size"]))
        status, output = self.run_check()
        self.assertEqual(status, 0, output)

    def test_manifest_parse_and_reference_failures(self):
        cases = [
            ("{", "无法读取 JSON"),
            ("[]", "顶层必须是对象"),
            (json.dumps({"art": []}), "ui.art 必须是对象"),
            (json.dumps({"art": {"icons": [], "misc": {}}}), "ui.art.icons 必须是对象"),
            (json.dumps({"art": {"icons": {}, "misc": {"bad": {"file": ""}}}}),
             "必须是非空路径字符串"),
            (json.dumps({"art": {"icons": {}, "misc": {"bad": {"file": "../outside.png"}}}}),
             "必须是 assets/art 内的相对路径"),
            (json.dumps({"art": {"icons": {}, "misc": {"bad": {"file": "table/missing.png"}}}}),
             "ui.art 引用缺失"),
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
        self.assertIn("ui.art 引用缺失", output)
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

    def test_asset_builder_preserves_other_ui_settings(self):
        spec = importlib.util.spec_from_file_location("build_art", SCRIPT.with_name("build_art.py"))
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        original = {"defaults": {"table_zoom": 1.7}, "palette": {"ink": "#123456"},
                    "sfx": {"custom": True}, "art": self.manifest}
        self.manifest_path.write_text(json.dumps(original), encoding="utf-8")
        source = self.root / "source"
        source.mkdir()
        with patch.object(builder, "ROOT", str(self.root)), \
             patch.object(builder, "SRC", str(source)), \
             patch.object(builder, "OUT", str(self.art)), \
             patch.object(builder, "MISC_MAP", {}), \
             patch.object(builder, "build_app_icon", return_value=True), \
             patch.object(builder, "load_name_to_id", return_value={}), \
             patch("sys.argv", ["build_art.py"]), contextlib.redirect_stdout(io.StringIO()):
            builder.main()
        self.assertEqual(json.loads(self.manifest_path.read_text()), original)
        self.assertFalse((self.art / "art_manifest.json").exists())

    def test_unreadable_or_empty_card_config_fails(self):
        for data in ({}, {"cash": "invalid"}):
            with self.subTest(data=data):
                self.write_json(self.cards_path, data)
                status, output = self.run_check()
                self.assertEqual(status, 1, output)
                self.assertIn("cards.json", output)


if __name__ == "__main__":
    unittest.main()
