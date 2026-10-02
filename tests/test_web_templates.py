# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""Web 模板的损坏缓存、下载失败与失败后重试；不访问网络或用户模板目录。"""
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("web_templates", ROOT / "tools/install_web_templates.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def template_bytes(value=b"fixture"):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        for name in installer.REQUIRED:
            archive.writestr(name, value)
    return data.getvalue()


class WebTemplatesTest(unittest.TestCase):
    def test_incomplete_download_keeps_existing_files_then_retry_repairs_all(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "templates"
            target.mkdir()
            originals = {name: template_bytes(b"old") for name in installer.NAMES}
            originals["web_nothreads_release.zip"] = b""
            for name, content in originals.items():
                (target / name).write_bytes(content)
            source = root / "download.tpz"
            with zipfile.ZipFile(source, "w") as archive:
                for name in installer.NAMES[:2]:
                    archive.writestr("templates/" + name, template_bytes(b"new"))
            with self.assertRaises(KeyError):
                installer.ensure_templates(target, source.as_uri())
            self.assertEqual({name: (target / name).read_bytes() for name in originals}, originals)
            self.assertFalse(list(target.glob(".web-templates-*")))
            with zipfile.ZipFile(source, "w") as archive:
                for name in installer.NAMES:
                    archive.writestr("templates/" + name, template_bytes(b"new"))
            installer.ensure_templates(target, source.as_uri())
            self.assertTrue(all(installer.valid_template(target / name) for name in installer.NAMES))
            self.assertTrue(all((target / name).read_bytes() == template_bytes(b"new") for name in installer.NAMES))
            # 完整缓存不再要求网络可用。
            installer.ensure_templates(target, (root / "absent.tpz").as_uri())

    def test_corrupt_nested_zip_is_rejected_before_any_template_is_published(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "download.tpz"
            with zipfile.ZipFile(source, "w") as archive:
                for i, name in enumerate(installer.NAMES):
                    archive.writestr("templates/" + name, b"bad zip" if i == 2 else template_bytes())
            with self.assertRaises(ValueError):
                installer.ensure_templates(root / "installed", source.as_uri())
            self.assertFalse(list((root / "installed").glob("*.zip")))
            self.assertFalse(list((root / "installed").glob(".web-templates-*")))

    def test_download_failure_is_nonzero_and_does_not_leave_ready_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run([sys.executable, str(ROOT / "tools/install_web_templates.py"),
                                     str(root / "installed"), (root / "missing.tpz").as_uri()],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Web 模板安装失败", result.stderr)
            self.assertFalse(list((root / "installed").glob("*.zip")))
            self.assertFalse(list((root / "installed").glob(".web-templates-*")))


if __name__ == "__main__":
    unittest.main()
