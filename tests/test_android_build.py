# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""Android 发布回归：仅发布通过签名验证的完整导出，失败保留旧包。"""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
signing_spec = importlib.util.spec_from_file_location("android_signing", ROOT / "tools/android_signing.py")
signing = importlib.util.module_from_spec(signing_spec)
signing_spec.loader.exec_module(signing)
build_spec = importlib.util.spec_from_file_location("android_build", ROOT / "tools/android_build.py")
build = importlib.util.module_from_spec(build_spec)
with mock.patch.dict(sys.modules, {"android_signing": signing}):
    build_spec.loader.exec_module(build)


class AndroidBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="card android build with spaces ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.godot = self.root / "Godot With Spaces"
        self.godot.touch()
        self.key = self.root / "existing release.keystore"
        self.key.write_bytes(b"existing release identity")
        self.presets = self.root / "export_presets.cfg"
        self.presets.write_text(
            '[preset.2]\nname="Android"\nplatform="Android"\n\n'
            '[preset.2.options]\npackage/signed=true\n'
            f'keystore/release={json.dumps(str(self.key))}\n'
            'keystore/release_user="existing-alias"\n'
            'keystore/release_password="fixture-private-password"\n',
            encoding="utf-8",
        )
        (self.root / "build").mkdir()
        self.output = self.root / "build/牛马牌.apk"
        self.old_package = b"previous verified APK"
        self.new_package = b"new export awaiting signature verification"
        self.output.write_bytes(self.old_package)
        self.exports = []
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self.env = {name: value for name, value in os.environ.items()
                    if not name.startswith("GODOT_ANDROID_KEYSTORE_")}

    def run_build(self, *, args=(), export_status=0, export_log="Export complete\n",
                  artifact=True, verify_error=None, verify_effect=None):
        def run(command, **kwargs):
            if "--headless" not in command:
                self.assertEqual(command, [sys.executable, "tools/build_android_icons.py"])
                return subprocess.CompletedProcess(command, 0, "Icons ready\n")
            self.assertTrue((self.root / "build/.gdignore").is_file())
            self.assertFalse(Path(command[-1]).is_absolute())
            self.assertEqual(command[command.index("--path") + 1], ".")
            pending = kwargs["cwd"] / command[-1]
            self.assertNotEqual(pending, self.output)
            self.assertEqual(pending.parent.parent, self.root / "build")
            self.assertEqual(self.output.read_bytes(), self.old_package)
            if artifact:
                pending.write_bytes(self.new_package)
            self.exports.append((command, kwargs, pending))
            return subprocess.CompletedProcess(command, export_status, export_log)

        with mock.patch.object(build, "ROOT", self.root), \
                mock.patch.object(build, "PRESETS", self.presets), \
                mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(sys, "argv", ["android_build.py", "--godot", str(self.godot), *args]), \
                mock.patch.object(build.subprocess, "run", side_effect=run), \
                mock.patch.object(build, "verify_apk", return_value="Verified\n",
                                  side_effect=verify_error or verify_effect) as verify, \
                contextlib.redirect_stdout(self.stdout), contextlib.redirect_stderr(self.stderr):
            status = build.main()
        return status, verify

    def assert_no_pending_artifact(self):
        self.assertEqual(list((self.root / "build").glob("android-export-*")), [])
        for _, _, pending in self.exports:
            self.assertFalse(pending.exists())

    def test_failed_export_preserves_previous_apk_and_removes_partial_output(self):
        status, verify = self.run_build(export_status=7, export_log="Release signing failed\n")
        self.assertEqual(status, 7)
        self.assertEqual(self.output.read_bytes(), self.old_package)
        verify.assert_not_called()
        self.assert_no_pending_artifact()
        self.assertIn("Release signing failed", next((self.root / "build/logs").glob("*.log")).read_text())

    def test_export_and_signature_diagnostics_hide_paths_but_keep_failure(self):
        status, _ = self.run_build(export_log=f"Export {self.root}/source.gd\n",
                                  verify_error=build.SigningError(f"bad signature {self.root}/private.apk"))
        self.assertNotEqual(status, 0)
        text = self.stdout.getvalue() + self.stderr.getvalue()
        text += next((self.root / "build/logs").glob("*.log")).read_text()
        self.assertNotIn(str(self.root), text)
        self.assertIn("./source.gd", text)
        self.assertIn("./private.apk", text)
        self.assertEqual(self.output.read_bytes(), self.old_package)

    def test_android_waits_for_shared_font_transaction_before_export(self):
        results, errors = [], []
        def worker():
            try:
                results.append(self.run_build())
            except BaseException as error:
                errors.append(error)
        with (self.root / "build/.font-transaction.lock").open("a+b") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX)
            thread = threading.Thread(target=worker, daemon=True)
            thread.start()
            try:
                time.sleep(0.2)
                self.assertTrue(thread.is_alive(), "Android 等待正在使用资源的构建")
                self.assertEqual(self.exports, [], "未获锁前不能导出")
            finally:
                fcntl.flock(owner, fcntl.LOCK_UN)
                thread.join(timeout=5)
            self.assertFalse(thread.is_alive(), "持锁方退出后 Android 应继续构建")
        self.assertEqual(errors, [])
        self.assertEqual(results[0][0], 0)
        self.assertEqual(len(self.exports), 1)
        self.assertEqual(self.output.read_bytes(), self.new_package)

    def test_engine_error_with_zero_exit_preserves_previous_apk(self):
        for error in ("ERROR: export failed", "SCRIPT ERROR: script parse failed"):
            with self.subTest(error=error):
                status, verify = self.run_build(export_log=f"Export started\n{error}\n")
                self.assertNotEqual(status, 0)
                self.assertEqual(self.output.read_bytes(), self.old_package)
                verify.assert_not_called()
                self.assert_no_pending_artifact()

    def test_signature_verification_failure_preserves_previous_apk(self):
        status, verify = self.run_build(verify_error=build.SigningError("fixture invalid signature"))
        self.assertNotEqual(status, 0)
        verify.assert_called_once()
        self.assertEqual(self.output.read_bytes(), self.old_package)
        self.assert_no_pending_artifact()
        log = next((self.root / "build/logs").glob("*.log")).read_text()
        self.assertIn("fixture invalid signature", log)
        self.assertIn("fixture invalid signature", self.stderr.getvalue())

    def test_success_replaces_apk_only_after_verification_and_passes_signing_environment(self):
        def verify_pending(godot, pending, env):
            self.assertEqual(godot, self.godot)
            self.assertEqual(self.output.read_bytes(), self.old_package)
            self.assertEqual(pending.read_bytes(), self.new_package)
            self.assertEqual(env["GODOT_ANDROID_KEYSTORE_RELEASE_PATH"], str(self.key))
            self.assertEqual(env["GODOT_ANDROID_KEYSTORE_RELEASE_USER"], "existing-alias")
            self.assertEqual(env["GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"], "fixture-private-password")
            return "Verified\n"

        status, verify = self.run_build(verify_effect=verify_pending)
        self.assertEqual(status, 0)
        verify.assert_called_once()
        self.assertEqual(self.output.read_bytes(), self.new_package)
        command, kwargs, _ = self.exports[0]
        self.assertIn("--export-release", command)
        self.assertEqual(command[-2], "Android")
        self.assertEqual(kwargs["env"]["GODOT_ANDROID_KEYSTORE_RELEASE_PATH"], str(self.key))
        self.assertEqual(kwargs["env"]["GODOT_ANDROID_KEYSTORE_RELEASE_USER"], "existing-alias")
        self.assertEqual(kwargs["env"]["GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"], "fixture-private-password")
        self.assertNotIn("fixture-private-password", " ".join(command))
        self.assertNotIn("fixture-private-password", self.stdout.getvalue() + self.stderr.getvalue())
        self.assert_no_pending_artifact()

    def test_success_without_an_output_keeps_previous_apk(self):
        status, verify = self.run_build(artifact=False)
        self.assertNotEqual(status, 0)
        self.assertEqual(self.output.read_bytes(), self.old_package)
        verify.assert_not_called()
        self.assert_no_pending_artifact()

    def test_debug_does_not_prepare_release_credentials(self):
        # 即使项目没有任何发布凭据，debug 也不能顺带创建发布身份。
        self.presets.write_text('[preset.2]\nname="Android"\nplatform="Android"\n', encoding="utf-8")
        with mock.patch.object(build, "prepare_release_signing", side_effect=AssertionError("debug 不应准备 release 签名")) as prepare:
            status, verify = self.run_build(args=("--debug",))
        self.assertEqual(status, 0)
        prepare.assert_not_called()
        verify.assert_called_once()
        self.assertEqual(self.output.read_bytes(), self.old_package)
        self.assertEqual((self.root / "build/牛马牌-debug.apk").read_bytes(), self.new_package)
        self.assertFalse((self.root / ".android-signing").exists())
        command, kwargs, _ = self.exports[0]
        self.assertIn("--export-debug", command)
        for variable in ("GODOT_ANDROID_KEYSTORE_RELEASE_PATH", "GODOT_ANDROID_KEYSTORE_RELEASE_USER", "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"):
            self.assertNotIn(variable, kwargs["env"])
        self.assert_no_pending_artifact()


if __name__ == "__main__":
    unittest.main()
