# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""完整帧的实际像素验收，防止原图接续跳变、低清放大和固定人物漂移。"""
import hashlib
import json
import sys
import unittest
from pathlib import Path

from PIL import Image
from hover_source_archive import native_art_context

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "assets" / "art"
sys.path.insert(0, str(ROOT / "tools"))
from hover_delta_codec import decode_file


class RuntimeHoverFramesTest(unittest.TestCase):
    """正式素材验收始终运行，不依赖未提交的高清源稿或制作报告。"""
    @classmethod
    def setUpClass(cls):
        cls.art = ROOT / "assets/art"
        cls.hover = json.loads((ROOT / "data/ui.json").read_text())["art"]["hover"]

    def test_all_formal_cards_use_384_lossless_delta_and_preserve_endpoints(self):
        definitions = json.loads((ROOT / "data/cards.json").read_text())
        ids = {key for key in definitions if not key.startswith("_")}
        self.assertEqual(set(self.hover["cards"]), ids)
        self.assertEqual(len(ids), 31)
        self.assertEqual(self.hover["fps"], 12)
        self.assertFalse(list((self.art / "icon/hover").rglob("*.png")), "正式目录不能残留已替代的完整 PNG 帧")
        for card in sorted(ids):
            with self.subTest(card=card):
                config = self.hover["cards"][card]
                self.assertEqual(config["codec"], "hdelta-v1")
                self.assertNotIn("files", config)
                self.assertEqual(config["file"], f"icon/hover/{card}.hdelta")
                self.assertGreaterEqual(config["frames"], 24)
                original = Image.open(self.art / f"icon/icon_{card}.png").convert("RGBA")
                self.assertEqual(max(original.size), 384)
                self.assertEqual(config["frame_size"], list(original.size))
                decoded = decode_file(self.art / config["file"])
                self.assertEqual((decoded["width"], decoded["height"]), original.size)
                timeline, frames = decoded["timeline"], decoded["frames"]
                self.assertEqual(len(timeline), config["frames"])
                self.assertGreaterEqual(len(frames), 12)
                for raw in frames:
                    self.assertEqual(len(raw), original.width * original.height * 4)
                    self.assertEqual(min(raw[3::4]), 0)
                for index in timeline[:4]:
                    self.assertEqual(frames[index], original.tobytes())
                if config["play_mode"] == "loop":
                    self.assertEqual(frames[timeline[-1]], original.tobytes())
                else:
                    self.assertNotEqual(frames[timeline[-1]], original.tobytes())
                    self.assertEqual(len(set(timeline[-3:])), 1)
                settings = dict(line.split("=", 1) for line in
                                (self.art / f"icon/icon_{card}.png.import").read_text().splitlines()
                                if "=" in line)
                self.assertEqual(settings["compress/mode"], "0")
                self.assertEqual(settings["process/fix_alpha_border"], "false")
                self.assertEqual(settings["mipmaps/generate"], "true")

    def test_formal_frames_match_available_godot_resize_receipt(self):
        receipt = ROOT / "build/art_generation/runtime_hover_384/verification.json"
        if not receipt.is_file():
            self.skipTest("本地 Godot 缩小报告未归档；独立正式素材验收仍必须通过")
        records = json.loads(receipt.read_text())["cards"]
        self.assertEqual({record["card"] for record in records}, set(self.hover["cards"]))
        for record in records:
            with self.subTest(card=record["card"]):
                config = self.hover["cards"][record["card"]]
                path = self.art / config["file"]
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), record["pack_sha256"])
                decoded = decode_file(path)
                hashes = [hashlib.sha256(raw).hexdigest() for raw in decoded["frames"]]
                self.assertEqual([hashes[index] for index in decoded["timeline"]], record["rgba_sha256"])


class NativeHoverFramesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ART
        source_ui, ART = native_art_context()
        cls.hover = json.loads(source_ui.read_text())["art"]["hover"]

    def frames(self, card_id):
        entry = self.hover["cards"][card_id]
        return [Image.open(ART / path).convert("RGBA") for path in entry["files"]]

    def test_all_current_cards_use_native_sequences_without_old_atlases(self):
        definitions=json.loads((ROOT/'data/cards.json').read_text())
        ids={key for key in definitions if not key.startswith('_')}
        self.assertEqual(set(self.hover['cards']),ids)
        self.assertEqual(len(ids),31)
        for card_id in ids:
            with self.subTest(card=card_id):
                config=self.hover['cards'][card_id]
                original=Image.open(ART/f'icon/icon_{card_id}.png').convert('RGBA')
                self.assertIn('files',config)
                self.assertNotIn('file',config)
                self.assertEqual(len(config['files']),config['frames'])
                self.assertEqual(config['frame_size'],list(original.size))
                self.assertGreaterEqual(config['frames'],24)
                self.assertGreaterEqual(len(set(config['files'])),12)
                self.assertFalse((ART/f'icon/hover/{card_id}.png').exists())
                for filename in config['files'][:4]:
                    self.assertEqual(Image.open(ART/filename).convert('RGBA').tobytes(),original.tobytes())
                final=Image.open(ART/config['files'][-1]).convert('RGBA')
                self.assertEqual(final.size,original.size)
                if config['play_mode']=='loop':
                    self.assertEqual(final.tobytes(),original.tobytes())
                else:
                    self.assertNotEqual(final.tobytes(),original.tobytes())
                    for filename in config['files'][-3:]:
                        self.assertEqual(Image.open(ART/filename).convert('RGBA').tobytes(),final.tobytes())
                reference=dict(line.split('=',1) for line in
                               (ART/f'icon/icon_{card_id}.png.import').read_text().splitlines()
                               if line.startswith(('compress/','mipmaps/','process/')))
                for filename in set(config['files']):
                    actual=dict(line.split('=',1) for line in
                                (ART/(filename+'.import')).read_text().splitlines()
                                if line.startswith(('compress/','mipmaps/','process/')))
                    self.assertEqual(actual,reference)

    def test_native_size_transparency_and_original_endpoints(self):
        self.assertEqual(self.hover["fps"], 12)
        for card_id, count in (("cash", 24), ("user", 36)):
            with self.subTest(card_id=card_id):
                entry = self.hover["cards"][card_id]
                original = Image.open(ART / f"icon/icon_{card_id}.png").convert("RGBA")
                frames = self.frames(card_id)
                self.assertEqual(len(frames), count)
                self.assertEqual(entry["frames"], count)
                for frame in frames:
                    self.assertEqual(frame.size, original.size)
                    self.assertEqual(frame.getchannel("A").getextrema()[0], 0)
                self.assertEqual(frames[0].tobytes(), original.tobytes())
                self.assertEqual(frames[-1].tobytes(), original.tobytes())
                self.assertGreaterEqual(len({frame.tobytes() for frame in frames}), 12)

    def test_user_fixed_pixels_and_original_colors(self):
        original = Image.open(ART / "icon/icon_user.png").convert("RGBA")
        # 右上方手与头的接触处属于活动区；固定区覆盖眼嘴、其余头身、左臂和双脚。
        regions = ((0, 0, 580, 1024), (0, 740, 1024, 1024),
                   (580, 0, 1024, 160), (295, 250, 650, 550), (425, 586, 575, 755))
        for index, frame in enumerate(self.frames("user")):
            for region in regions:
                with self.subTest(frame=index, region=region):
                    self.assertEqual(frame.crop(region).tobytes(), original.crop(region).tobytes())
            # 只有原来的平涂与边缘抗锯齿，不能把人重新绘成渐变或更粗的墨线。
            opaque_colors = {p[:3] for p in frame.get_flattened_data() if p[3] == 255}
            self.assertIn((246, 235, 208), opaque_colors)
            self.assertIn((48, 41, 31), opaque_colors)
            self.assertEqual(frame.getpixel((500, 300)), original.getpixel((500, 300)))

    def test_user_right_hand_contacts_upper_right_head(self):
        original = Image.open(ART / "icon/icon_user.png").convert("RGBA")
        contact = self.frames("user")[12]
        # 在右上接触区新增手的墨线，脸、左手不动；不是左手挠头或整幅图晃动。
        box = (685, 180, 745, 235)
        before = list(original.crop(box).get_flattened_data())
        after = list(contact.crop(box).get_flattened_data())
        changed_to_ink = sum(a[:3] == (48, 41, 31) and b[:3] != a[:3]
                             for b, a in zip(before, after))
        self.assertGreater(changed_to_ink, 50)

    def test_same_import_color_alpha_and_minification_settings(self):
        settings = ("compress/mode", "mipmaps/generate", "process/fix_alpha_border",
                    "process/premult_alpha", "process/size_limit")
        for card_id in ("cash", "user", "yunketang"):
            original_path = ART / f"icon/icon_{card_id}.png.import"
            reference = dict(line.split("=", 1) for line in original_path.read_text().splitlines()
                             if "=" in line and line.split("=", 1)[0] in settings)
            for filename in set(self.hover["cards"][card_id]["files"]):
                imported = ART / (filename + ".import")
                actual = dict(line.split("=", 1) for line in imported.read_text().splitlines()
                              if "=" in line and line.split("=", 1)[0] in settings)
                with self.subTest(frame=filename):
                    self.assertEqual(actual, reference)

    def test_cloud_complete_native_sample_and_fixed_regions(self):
        entry = self.hover["cards"]["yunketang"]
        frames = self.frames("yunketang")
        original = Image.open(ART / "icon/icon_yunketang.png").convert("RGBA")
        self.assertEqual(entry["play_mode"], "once")
        self.assertEqual(len(frames), 42)
        self.assertEqual(entry["frame_size"], [1254, 1254])
        self.assertEqual(frames[0].tobytes(), original.tobytes())
        self.assertGreaterEqual(len({frame.tobytes() for frame in frames}), 30)
        # 实际固定画面：帽身及上边框、完整键盘和底座、灯泡本体、左侧及外侧留白。
        regions = ((0, 0, 1254, 407), (0, 815, 1254, 1254),
                   (470, 435, 755, 834), (0, 407, 179, 815), (1163, 407, 1254, 815))
        for index, frame in enumerate(frames):
            self.assertEqual(frame.size, original.size)
            for region in regions:
                with self.subTest(frame=index, fixed_region=region):
                    self.assertEqual(frame.crop(region).tobytes(), original.crop(region).tobytes())

    def test_cloud_consumes_same_coin_horizontally_without_ghosts(self):
        frames = self.frames("yunketang")
        original = frames[0]
        def gold_pixels(frame):
            return sum(a > 240 and r > 220 and 165 < g < 235 and b < g * .8
                       for r,g,b,a in frame.crop((860,575,1080,780)).get_flattened_data())
        counts = [gold_pixels(frame) for frame in frames[:16]]
        self.assertGreater(counts[0], 10000)
        self.assertTrue(all(b <= a for a,b in zip(counts, counts[1:])), counts)
        self.assertEqual(gold_pixels(frames[-1]), 0)
        # 两个相邻阶段保持原币的像素与高度，只有横向位置和孔缘遮挡变化。
        for index, shift in ((6,31),(9,98)):
            self.assertEqual(frames[index].getpixel((1015-shift,700)), original.getpixel((1015,700)))
        final = frames[-1]
        # 金币移开后，电脑边框接续且不透底；外侧空白恢复透明。
        for y in range(580,780):
            self.assertGreaterEqual(final.getpixel((1020,y))[3], 248)
            center = round(990 + (982-990)*((y-568)/(794-568)))
            self.assertLess(max(final.getpixel((center,y))[:3]), 85)
        self.assertEqual(final.getpixel((1060,675))[3], 0)
        for box in ((1049,535,1130,605),(1074,596,1163,641)):
            self.assertEqual(final.crop(box).getchannel("A").getextrema(), (0,0))

    def test_cloud_tassel_moves_from_fixed_connection_and_returns(self):
        frames = self.frames("yunketang")
        original = frames[0]
        box = (179,407,276,602)
        self.assertNotEqual(frames[25].crop(box).tobytes(), original.crop(box).tobytes())
        self.assertNotEqual(frames[31].crop(box).tobytes(), original.crop(box).tobytes())
        self.assertEqual(frames[-1].crop(box).tobytes(), original.crop(box).tobytes())
        for frame in frames:
            self.assertEqual(frame.getpixel((231,406)), original.getpixel((231,406)))


if __name__ == "__main__":
    unittest.main()
