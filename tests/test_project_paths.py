# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""输出路径不携带本机用户名，机器使用的相对路径仍可定位原文件。"""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("project_paths", Path(__file__).resolve().parents[1] / "tools/project_paths.py")
paths = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paths)


class ProjectPathsTests(unittest.TestCase):
    def test_relative_paths_resolve_inside_and_outside_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "project"
            root.mkdir()
            for target in (root / "build/report.json", Path(directory) / "other/cards.json"):
                self.assertEqual((root / paths.relative_path(target, root)).resolve(), target.resolve())

    def test_display_uses_project_or_home_relative_path(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            root = home / "project"
            with patch.object(paths.Path, "home", return_value=home):
                self.assertEqual(paths.display_path(root / "build/results.json", root), "build/results.json")
                self.assertEqual(paths.display_path(home / "Library/SDK", root), "~/Library/SDK")
                self.assertEqual(paths.display_path(root, root), ".")

    def test_redaction_preserves_text_and_directory_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "private-user"
            root = home / "project"
            with patch.object(paths.Path, "home", return_value=home):
                source = f'File "{root}/tools/job.py", line 7\nSDK: {home}/Library/SDK\nroot={root}\n{root}-copy/data.json\n'
                expected = 'File "./tools/job.py", line 7\nSDK: ~/Library/SDK\nroot=.\n~/project-copy/data.json\n'
                self.assertEqual(paths.redact_paths(source, root), expected)
                self.assertEqual(paths.redact_paths(f"项目：{root}；用户目录：{home}。", root), "项目：.；用户目录：~。")
                self.assertEqual(paths.redact_paths(str(home) + "-other/file", root), str(home) + "-other/file")

    def test_sanitizing_log_preserves_permissions_and_other_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "failed.log"
            log.write_text(f"ERROR: could not read {root}/cards.json\n", encoding="utf-8")
            log.chmod(0o600)
            paths.sanitize_file(log, root)
            self.assertEqual(log.read_text(), "ERROR: could not read ./cards.json\n")
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
