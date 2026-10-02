#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""隔离项目保持调用方相对文件参数的读写语义。"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from test_runtime import preserve_project_paths


class RuntimePathsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='runtime 路径 ')
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name).resolve()
        self.root, self.runtime = base / '原 项目', base / '隔离'
        self.root.mkdir(); self.runtime.mkdir()
        (self.root / 'data').mkdir()
        (self.root / 'data/cards.json').write_text('{"fixture":true}')
        (self.root / 'reports').mkdir()

    def remap(self, args):
        return preserve_project_paths(args, self.root, self.runtime)

    def test_eval_request_copy_keeps_original_relative_and_text_unchanged(self):
        request = dict(cards_path='data/cards.json', output_path='reports/结果.json',
                       progress_path='reports/进度.json', text='data/cards.json')
        source = self.root / 'request.json'
        source.write_text(json.dumps(request))
        before = source.read_bytes()
        original = ['--path', '.', '--log-file', 'reports/引擎.log', '-s',
                    'tools/eval_report.gd', '--', 'request.json']
        remapped = self.remap(original)
        self.assertEqual(original[-1], 'request.json')
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(Path(remapped[-1]).parent, self.runtime)
        copied = json.loads(Path(remapped[-1]).read_text())
        self.assertEqual(copied['text'], request['text'])
        self.assertTrue(json.loads(Path(copied['cards_path']).read_text())['fixture'])
        for key in ('output_path', 'progress_path'):
            Path(copied[key]).write_text('result')
            self.assertEqual((self.root / request[key]).read_text(), 'result')
        self.assertEqual(remapped[remapped.index('--log-file') + 1], str(self.root / 'reports/引擎.log'))

    def test_metadata_request_and_resource_paths_remain_valid(self):
        source = self.root / 'request.json'
        source.write_text(json.dumps(dict(action='metadata', output_path='reports/profile.json',
                                         cards_path='res://data/cards.json', progress_path='user://progress.json')))
        args = self.remap(['-s', 'tools/eval_report.gd', '--', 'request.json'])
        request = json.loads(Path(args[-1]).read_text())
        self.assertEqual(request['output_path'], str(self.root / 'reports/profile.json'))
        self.assertEqual(request['cards_path'], 'res://data/cards.json')
        self.assertEqual(request['progress_path'], 'user://progress.json')

    def test_play_card_argument_and_benchmark_input_output_resolve_at_original_root(self):
        play = self.remap(['--path', '.', '--', '--cards-config=data/cards.json'])
        self.assertEqual(play[-1], '--cards-config=' + str(self.root / 'data/cards.json'))
        (self.root / 'input-without-extension').write_text('{}')
        args = self.remap(['-s', '../external/ai_decision_probe.gd', '--', 'fixed',
                           'input-without-extension', 'reports/new.json', '40', '1.0', 'ai:1'])
        self.assertEqual(args[1], str(self.root.parent / 'external/ai_decision_probe.gd'))
        self.assertEqual(args[3], 'fixed')
        self.assertEqual(args[4:6], [str(self.root / 'input-without-extension'), str(self.root / 'reports/new.json')])
        self.assertEqual(args[-3:], ['40', '1.0', 'ai:1'])

    def test_invalid_request_is_left_for_engine_validation(self):
        source = self.root / 'request.json'; source.write_text('{invalid')
        args = self.remap(['-s', 'tools/eval_report.gd', '--', 'request.json'])
        self.assertEqual(args[-1], str(source))
        self.assertFalse((self.runtime / 'eval-request.json').exists())


if __name__ == '__main__':
    unittest.main()
