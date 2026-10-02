# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""发布验证报告只保留可定位的相对路径，错误和超时日志仍保留原始诊断。"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
try:
    import verify_release as verify
finally:
    sys.path.pop(0)


class VerifyReleasePrivacyTest(unittest.TestCase):
    def test_failed_and_timed_out_logs_hide_paths_without_suppressing_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            log = root / "failure.log"
            raw = f"ERROR: {root}/script.gd SDK {Path.home()}/Library/sdk\n"
            with mock.patch.object(verify, "ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "验证失败"):
                    verify.validate_log("fixture", subprocess.CompletedProcess([], 0, raw), log)
                self.assertEqual(log.read_text(), "ERROR: ./script.gd SDK ~/Library/sdk\n")
                with mock.patch.object(verify.subprocess, "run", side_effect=subprocess.TimeoutExpired([], 1, raw.encode())):
                    with self.assertRaisesRegex(RuntimeError, "验证超时"):
                        verify.run_logged(["fixture"], "fixture", log, timeout=1)
                self.assertEqual(log.read_text(), "ERROR: ./script.gd SDK ~/Library/sdk\n")

    def test_report_uses_project_relative_app_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / "build/game.app"
            binary = app / "Contents/MacOS/game"
            binary.parent.mkdir(parents=True)
            binary.touch()
            pack = {"architectures": [], "app_bytes": 1, "binary_bytes": 1, "pck_bytes": 0}
            with mock.patch.object(verify, "ROOT", root), mock.patch.object(verify, "audit", return_value=pack):
                report = verify.verify(app, root / "report", [])
            self.assertEqual(report["app"], "build/game.app")
            self.assertNotIn(str(root), (root / "report/result.json").read_text())
            self.assertEqual(json.loads((root / "report/result.json").read_text()), report)


if __name__ == "__main__":
    unittest.main()
