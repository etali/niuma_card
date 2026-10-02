# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""发布安装事务：新产物替换失败时，已发布文件和 App 整组恢复。"""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_bundle", ROOT / "tools/release_bundle.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class ReleasePublicationTest(unittest.TestCase):
    def test_cli_replaces_fixed_archive_names_with_new_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "build"
            for content in ("previous", "new"):
                stage = root / content
                web = stage / "web"
                web.mkdir(parents=True)
                for name in ("index.html", "index.js", "index.wasm", "index.pck"):
                    (web / name).write_text(content)
                (web / "index.wasm.br").write_text("precompressed")
                app = stage / "牛马牌.app/Contents"
                (app / "MacOS").mkdir(parents=True)
                (app / "Resources").mkdir()
                (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "game"}))
                (app / "MacOS/game").write_text(content)
                (app / "MacOS/game").chmod(0o755)
                (app / "Resources/game.pck").write_text(content)
                (stage / "cards.json").write_text(content)
                result = subprocess.run([sys.executable, str(ROOT / "tools/release_bundle.py"),
                                         str(stage), str(output)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual({path.name for path in output.glob("*.zip")},
                                 {"牛马牌_web.zip", "牛马牌_mac.zip"})
                with zipfile.ZipFile(output / "牛马牌_web.zip") as archive:
                    self.assertEqual(archive.read("index.html"), content.encode())
                    self.assertNotIn("index.wasm.br", archive.namelist())
                with zipfile.ZipFile(output / "牛马牌_mac.zip") as archive:
                    self.assertEqual(archive.read("牛马牌.app/Contents/MacOS/game"), content.encode())
                    self.assertEqual(archive.read("cards.json"), content.encode())
                self.assertFalse(list(output.glob(".release-previous-*")))

    def test_midway_rename_failure_restores_all_previous_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, output = root / "stage", root / "build"
            stage.mkdir(); output.mkdir()
            for folder, text in ((stage, "new"), (output, "previous")):
                (folder / "web").mkdir()
                (folder / "web/index.html").write_text(text)
                (folder / "release.zip").write_text(text)
            replace = bundle.os.replace
            def fail(source, target):
                if Path(source) == stage / "release.zip":
                    raise OSError("fixture publication failure")
                return replace(source, target)
            with mock.patch.object(bundle.os, "replace", side_effect=fail):
                with self.assertRaisesRegex(OSError, "fixture publication"):
                    bundle.publish(stage, output, ["web", "release.zip"])
            self.assertEqual((output / "web/index.html").read_text(), "previous")
            self.assertEqual((output / "release.zip").read_text(), "previous")
            self.assertEqual((stage / "web/index.html").read_text(), "new")
            self.assertFalse(list(output.glob(".release-previous-*")))


if __name__ == "__main__":
    unittest.main()
