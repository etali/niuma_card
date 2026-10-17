#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""正式角色图实际像素：开场、终态、固定对象与落入掌心的方向。"""
import json
from pathlib import Path
import sys
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from hover_delta_codec import decode_file


class RoleIconArtTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = json.loads((ROOT / 'data/ui.json').read_text())['art']['hover']
        cls.frames = {}
        cls.stills = {}
        for name in ('geiwo', 'idea'):
            cls.stills[name] = Image.open(ROOT / f'assets/art/icon/icon_{name}.png').convert('RGBA')
            decoded = decode_file(ROOT / f'assets/art/icon/hover/{name}.hdelta')
            cls.frames[name] = [decoded['frames'][index] for index in decoded['timeline']]

    def test_real_alpha_resolution_and_timing(self):
        self.assertEqual(self.config['fps'], 12)
        for name, frames in self.frames.items():
            with self.subTest(card=name):
                self.assertEqual(self.stills[name].size, (384, 384))
                self.assertEqual(len(frames), self.config['cards'][name]['frames'])
                self.assertGreaterEqual(len(set(frames)), 12)
                for frame in frames:
                    alpha = frame[3::4]
                    self.assertEqual(max(alpha[:384]), 0, '顶边不能裁掉射线')
                    self.assertEqual(max(alpha[-384:]), 0, '底边不能裁掉脚或卡牌')
                    self.assertEqual(max(alpha[::384]), 0)
                    self.assertEqual(max(alpha[383::384]), 0)

    def test_first_four_frames_are_exact_static_icon(self):
        for name, frames in self.frames.items():
            for frame in frames[:4]:
                self.assertEqual(frame, self.stills[name].tobytes())

    def test_grab_keeps_result_and_idea_returns_to_start(self):
        self.assertEqual(self.config['cards']['geiwo']['play_mode'], 'once')
        self.assertNotEqual(self.frames['geiwo'][-1], self.frames['geiwo'][0])
        self.assertEqual(self.config['cards']['idea']['play_mode'], 'loop')
        self.assertEqual(self.frames['idea'][-1], self.frames['idea'][0])
        for frames in self.frames.values():
            self.assertEqual(len(set(frames[-3:])), 1, '末三帧必须完整停稳')

    def test_fixed_boss_body_and_upgrade_cards_do_not_shake(self):
        for name, first_fixed_row in (('geiwo', 285), ('idea', 250)):
            for frame in self.frames[name]:
                self.assertEqual(frame[first_fixed_row * 384 * 4:], self.frames[name][0][first_fixed_row * 384 * 4:])

    def test_grab_card_moves_down_left_to_the_palm(self):
        def gold_center(raw):
            points = []
            for y in range(45, 280):
                for x in range(210, 380):
                    p = (y * 384 + x) * 4
                    r, g, b, a = raw[p:p + 4]
                    if a > 240 and r > 225 and 160 < g < 240 and b < 180:
                        points.append((x, y))
            self.assertGreater(len(points), 100)
            return tuple(sum(p[i] for p in points) / len(points) for i in (0, 1))
        initial = gold_center(self.frames['geiwo'][0])
        final = gold_center(self.frames['geiwo'][-1])
        self.assertLess(final[0], initial[0] - 15)
        self.assertGreater(final[1], initial[1] + 40)


if __name__ == '__main__':
    unittest.main()
