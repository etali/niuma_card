#!/usr/bin/env python3
"""高清制作源与正式小图隔离；所有夹具均在 build，禁止改动真实归档。"""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import hover_source_art as source
import render_hover_batch01 as batch
from hover_delta_codec import encode_frames, decode_bytes


class SourceArtTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'build', prefix='source-art-test-')
        self.root = Path(self.temp.name)
        self.config = {'art': {'hover': {'max_dimension': 16, 'cards': {
            'sample': {'codec': 'hdelta-v1', 'file': 'icon/hover/sample.hdelta', 'frames': 7}}}}}
        (self.root / 'data').mkdir()
        (self.root / 'data/ui.json').write_text(json.dumps(self.config))
        self.archive = self.root / 'build/art_generation/native_before_test'
        self.original_path = self.archive / 'art/icon/icon_sample.png'
        self.original_path.parent.mkdir(parents=True)
        self.original = Image.new('RGBA', (32, 31), (250, 200, 100, 255))
        self.original.save(self.original_path)
        self.archive_ui = self.archive / 'ui.json'
        old_frame = self.original.copy()
        old_frame.putpixel((2, 3), (50, 60, 70, 255))
        old_path = self.archive / 'art/icon/hover/sample/004.png'
        old_path.parent.mkdir(parents=True)
        old_frame.save(old_path)
        self.original.save(self.archive / 'art/icon/icon_other.png')
        native = {'art': {'hover': {'cards': {
            'sample': {'files': ['icon/icon_sample.png'] * 4 + ['icon/hover/sample/004.png'] * 3,
                       'frames': 7, 'frame_size': [32, 31], 'play_mode': 'once'},
            'other': {'files': ['icon/icon_other.png'] * 7, 'frames': 7,
                      'frame_size': [32, 31], 'play_mode': 'loop'}}}}}
        self.archive_ui.write_text(json.dumps(native))
        self.pointer = self.root / 'build/art_generation/hover_runtime_source.json'
        self.pointer.write_text(json.dumps({'art': str(self.archive / 'art'), 'ui': str(self.archive_ui)}))
        self.patches = [patch.object(source, 'ROOT', self.root), patch.object(batch, 'ROOT', self.root)]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def test_compact_reads_native_and_missing_source_does_not_fall_back(self):
        self.assertEqual(source.native_icon_path('sample'), self.original_path)
        self.pointer.unlink()
        low = self.root / 'assets/art/icon/icon_sample.png'
        low.parent.mkdir(parents=True)
        Image.new('RGBA', (16, 16)).save(low)
        with self.assertRaisesRegex(FileNotFoundError, '不能供原生坐标绘制'):
            source.native_icon_path('sample')

    def test_reject_small_image_misregistered_as_native(self):
        Image.new('RGBA', (16, 16)).save(self.original_path)
        with self.assertRaisesRegex(ValueError, '不能用于原生坐标绘制'):
            source.native_icon_path('sample')

    def test_write_creates_editable_copy_and_keeps_backup_unchanged(self):
        before = self.original_path.read_bytes()
        target = source.native_icon_write_path('sample')
        self.assertNotEqual(target, self.original_path)
        Image.new('RGBA', (32, 31), (10, 20, 30, 255)).save(target)
        self.assertEqual(self.original_path.read_bytes(), before)
        self.assertEqual(source.native_icon_path('sample'), target)
        self.assertEqual(source.native_icon_write_path('sample'), target)
        self.assertTrue(json.loads(self.pointer.read_text())['editable'])

    def test_legacy_uses_original_assets(self):
        config = {'art': {'hover': {'cards': {'sample': {'files': ['icon/icon_sample.png']}}}}}
        (self.root / 'data/ui.json').write_text(json.dumps(config))
        target = self.root / 'assets/art/icon/icon_sample.png'
        target.parent.mkdir(parents=True)
        self.original.save(target)
        self.assertEqual(source.native_icon_path('sample'), target)
        self.assertEqual(source.native_icon_write_path('sample'), target)

    def test_compact_install_stages_native_then_uses_pack_and_refreshes_config(self):
        changed = self.original.copy()
        changed.putpixel((2, 3), (0, 1, 2, 255))
        frames = [self.original] * 4 + [changed] * 3
        report = {'rgba_sha256': [hashlib.sha256(frame.tobytes()).hexdigest() for frame in frames],
                  'play_mode': 'once'}
        candidate = self.root / 'build/candidate'
        latest = json.loads(json.dumps(self.config))
        latest['art']['hover']['cards']['sample']['frames'] = 7
        latest['art']['hover']['cards']['other'] = {'codec': 'hdelta-v1', 'frames': 12}
        def simulate_pack(*args, **kwargs):
            (self.root / 'data/ui.json').write_text(json.dumps(latest))
        with patch.object(batch.subprocess, 'run', side_effect=simulate_pack) as command:
            batch.install('sample', frames, report, candidate, self.config)
        args = command.call_args.args[0]
        self.assertIn('--install', args)
        self.assertIn('--source-ui', args)
        self.assertIn('--source-art', args)
        self.assertEqual(self.config, latest)
        staged = json.loads((candidate / 'runtime_source/ui.json').read_text())
        entry = staged['art']['hover']['cards']['sample']
        self.assertEqual(len(entry['files']), 7)
        self.assertEqual(len(set(entry['files'])), 2)
        self.assertEqual(staged['art']['hover']['cards'].keys(), {'sample'})
        self.assertFalse((self.root / 'assets/art/icon/hover/sample').exists())
        with Image.open(candidate / 'runtime_source/art/icon/icon_sample.png') as image:
            self.assertEqual(image.size, (32, 31))

    def test_bad_native_first_frame_rejected_before_pack(self):
        bad = Image.new('RGBA', self.original.size)
        report = {'rgba_sha256': [hashlib.sha256(bad.tobytes()).hexdigest()], 'play_mode': 'once'}
        with patch.object(batch.subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, '静止原稿'):
                batch.install('sample', [bad], report, self.root / 'build/candidate', self.config)
            command.assert_not_called()

    def test_merge_keeps_latest_action_for_full_repack_without_touching_archive(self):
        archive_before = {str(p.relative_to(self.archive)): p.read_bytes()
                          for p in self.archive.rglob('*') if p.is_file()}
        previous = json.loads(self.archive_ui.read_text())
        changed = self.original.copy()
        changed.putpixel((2, 3), (0, 1, 2, 255))
        frames = [self.original] * 4 + [changed] * 3
        report = {'rgba_sha256': [hashlib.sha256(frame.tobytes()).hexdigest() for frame in frames],
                  'play_mode': 'once'}
        candidate = self.root / 'build/candidate'
        with patch.object(batch.subprocess, 'run'):
            batch.install('sample', frames, report, candidate, self.config)
        source.merge_native_source('sample', candidate / 'runtime_source/ui.json',
                                   candidate / 'runtime_source/art')
        pointer = json.loads(self.pointer.read_text())
        merged = json.loads(Path(pointer['ui']).read_text())
        self.assertEqual(merged['art']['hover']['cards']['other'], previous['art']['hover']['cards']['other'])
        entry = merged['art']['hover']['cards']['sample']
        reread = []
        for path in entry['files']:
            with Image.open(Path(pointer['art']) / path) as image:
                reread.append(image.convert('RGBA').tobytes())
        encoded = encode_frames(reread, 32, 31)
        decoded = decode_bytes(encoded)
        restored = [decoded['frames'][index] for index in decoded['timeline']]
        self.assertEqual(restored, [frame.tobytes() for frame in frames])
        self.assertEqual({str(p.relative_to(self.archive)): p.read_bytes()
                          for p in self.archive.rglob('*') if p.is_file()}, archive_before)
        before_pointer = self.pointer.read_bytes()
        source.merge_native_source('sample', Path(pointer['ui']), Path(pointer['art']))
        self.assertEqual(self.pointer.read_bytes(), before_pointer)

    def test_missing_merge_frame_preserves_pointer_and_archive(self):
        candidate = self.root / 'build/broken'
        candidate.mkdir()
        config = json.loads(self.archive_ui.read_text())
        (candidate / 'ui.json').write_text(json.dumps(config))
        pointer_before = self.pointer.read_bytes()
        with self.assertRaises(FileNotFoundError):
            source.merge_native_source('sample', candidate / 'ui.json', candidate / 'art')
        self.assertEqual(self.pointer.read_bytes(), pointer_before)


if __name__ == '__main__':
    unittest.main()
