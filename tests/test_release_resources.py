# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""发布预设排除开发内容，同时保留动态读取的卡表、插画、音效、着色器和字体。"""
import configparser
import importlib.util
import json
from pathlib import Path
import re
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_audit', ROOT / 'tools/release_audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class ReleaseResourcesTest(unittest.TestCase):
    def test_all_presets_exclude_dev_and_include_runtime_json(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read(ROOT / 'export_presets.cfg', encoding='utf-8')
        presets = [name for name in config.sections() if re.fullmatch(r'preset\.\d+', name)]
        self.assertTrue(presets, '至少有一个真实导出目标，不能空循环通过')
        platforms = {config.get(name, 'platform').strip('"') for name in presets}
        self.assertTrue({'macOS', 'Web', 'Android'}.issubset(platforms))
        for name in presets:
            with self.subTest(preset=config.get(name, 'name')):
                # 每个目标各自必须有完整过滤器；不能只数全文件里出现几次字符串。
                excludes = config.get(name, 'exclude_filter').strip('"')
                parts = {x.strip() for x in excludes.split(',')}
                for prefix in audit.DEVELOPMENT_PREFIXES:
                    self.assertIn(prefix + '*', parts)
                includes = config.get(name, 'include_filter').strip('"')
                parts = {x.strip() for x in includes.split(',')}
                self.assertNotIn('*.json', parts)
                self.assertIn('data/*.json', parts)
                self.assertNotIn('assets/art/art_manifest.json', parts)
                self.assertFalse((ROOT / 'assets/art/art_manifest.json').exists())
                if config.get(name, 'platform') == '"macOS"':
                    self.assertEqual(config.get(name + '.options', 'binary_format/architecture'), '"universal"')

    def test_game_scripts_do_not_depend_on_excluded_directories(self):
        probe = 'preload("res://tools/helper.gd")'
        self.assertEqual(re.findall(r'res://([^"\s)]+)', probe), ['tools/helper.gd'])
        for folder in ['scenes', 'engine', 'net']:
            for path in (ROOT / folder).glob('*.gd'):
                text = '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('#'))
                refs = re.findall(r'res://([^"\s)]+)', text)
                for ref in refs:
                    self.assertFalse(ref.startswith(audit.DEVELOPMENT_PREFIXES), f'{path}: {ref}')
        self.assertTrue((ROOT / 'scenes/debug_shot.gd').exists())
        self.assertIn('res://scenes/debug_shot.gd', (ROOT / 'scenes/main.gd').read_text())

    def test_reader_lists_actual_pack_directory_v2_v3_v4(self):
        with tempfile.TemporaryDirectory() as tmp:
            for version in [2, 3, 4]:
                path = Path(tmp) / 'fixture.pck'
                name = b'data/cards.json\0'
                header = struct.pack('<6IQ', 0x43504447, version, 4, 7, 1, 0, 4096)
                header += struct.pack('<Q', 40) if version >= 3 else bytes(64)
                directory = struct.pack('<II', 1, len(name)) + name + struct.pack('<QQ', 12, 22) + bytes(16) + struct.pack('<I', 0)
                path.write_bytes(header + directory)
                self.assertEqual(audit.pck_files(path), [{'path': 'data/cards.json', 'bytes': 22, 'offset': 4108}])

    def test_real_pack_audit_when_clean_build_available(self):
        app = ROOT / 'build/牛马牌.app'
        if not app.exists() or not (ROOT / 'build/size-study/resources-clean.json').exists():
            self.skipTest('未构建清理后的App，无须为测试触发导出')
        report = audit.audit(app)
        self.assertEqual(set(report['architectures']), {'arm64', 'x86_64'})
        self.assertEqual(report['development_entries'], [])
        self.assertEqual(report['missing_entries'], [])


if __name__ == '__main__':
    unittest.main()
