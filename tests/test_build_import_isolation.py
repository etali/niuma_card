# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""真实Godot导入回归：build中的引擎源码不能作为游戏资源或全局脚本类导入。"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get('GODOT', '/Applications/Godot.app/Contents/MacOS/Godot')


@unittest.skipUnless(Path(GODOT).is_file(), '需要Godot进行实际资源导入验证')
class BuildImportIsolationTest(unittest.TestCase):
    def test_stale_engine_resources_removed_and_future_build_files_ignored(self):
        with tempfile.TemporaryDirectory(prefix='card-import-isolation-') as tmp:
            root = Path(tmp)
            (root / 'tools').mkdir()
            (root / 'assets/fonts').mkdir(parents=True)
            engine = root / 'build/slim-engine/source/fixture'
            engine.mkdir(parents=True)
            (root / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Import isolation test"\n')
            (root / 'runtime.gd').write_text('class_name RuntimeMustRemain\nextends RefCounted\n')
            (engine / 'engine.gd').write_text('class_name EngineMustNotLeak\nextends RefCounted\n')
            svg = '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>'
            (engine / 'old.svg').write_text(svg)
            (root / 'runtime.svg').write_text(svg)
            shutil.copy2(ROOT / 'assets/fonts/NotoSansSC.ttf', root / 'assets/fonts/NotoSansSC.ttf')
            for name in ('font_subset.sh', 'godot_build.sh', 'project_paths.py'):
                shutil.copy2(ROOT / 'tools' / name, root / 'tools' / name)

            # 复现以前已经被扫描到的缓存，不能只测首次干净导入。
            first = subprocess.run([GODOT, '--headless', '--path', tmp, '--import'],
                                   capture_output=True, text=True, timeout=45)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            classes = root / '.godot/global_script_class_cache.cfg'
            self.assertIn('EngineMustNotLeak', classes.read_text())
            self.assertTrue((engine / 'old.svg.import').exists())
            (engine / 'new.svg').write_text(svg)
            (engine / 'invalid.glsl').write_text('not a standalone Godot shader\n')

            # 走标准构建/发布共用的真实导入函数，它必须先恢复.gdignore再启动Godot。
            command = 'set -e\nsource tools/font_subset.sh\nFONT=assets/fonts/NotoSansSC.ttf\nfont_import_resources\n'
            fixed = subprocess.run(['/bin/bash', '-c', command], cwd=root,
                                   env=dict(os.environ, GODOT=GODOT), capture_output=True, text=True, timeout=45)
            self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
            self.assertNotIn('ERROR:', fixed.stdout + fixed.stderr)
            self.assertTrue((root / 'build/.gdignore').is_file())
            self.assertNotIn('EngineMustNotLeak', classes.read_text())
            self.assertIn('RuntimeMustRemain', classes.read_text())
            self.assertFalse((engine / 'new.svg.import').exists())
            self.assertFalse((engine / 'invalid.glsl.import').exists())
            self.assertTrue((root / 'runtime.svg.import').exists())
            self.assertIn('.fontdata', (root / 'assets/fonts/NotoSansSC.ttf.import').read_text())
            for cache in (root / '.godot/editor').glob('filesystem_cache*'):
                self.assertNotIn('res://build/', cache.read_text(errors='replace'))
            # 不删除用户已下载的源码或已有的编译缓存。
            self.assertTrue((engine / 'engine.gd').is_file())
            self.assertTrue((engine / 'old.svg.import').is_file())

    def test_ignore_marker_is_versioned_but_build_outputs_stay_ignored(self):
        self.assertTrue((ROOT / 'build/.gdignore').is_file())
        for relative, ignored in [('build/.gdignore', False), ('build/slim-engine/source/example.glsl', True),
                                  ('build/牛马牌.app/Contents/Resources/牛马牌.pck', True)]:
            result = subprocess.run(['git', 'check-ignore', '-q', '--no-index', relative], cwd=ROOT)
            self.assertEqual(result.returncode == 0, ignored, relative)


if __name__ == '__main__':
    unittest.main()
