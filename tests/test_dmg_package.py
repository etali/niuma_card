# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""独立 DMG 入口：用真实子进程桩验证目录结构、命令边界和失败保留旧包。"""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
try:
    import package_dmg as dmg
    import release_bundle
finally:
    sys.path.pop(0)


STUB = r'''
import json, os
from pathlib import Path
import shutil, sys

args = sys.argv[1:]
name = Path(sys.argv[0]).name
fail = os.environ.get("DMG_STUB_FAILURE", "")
with open(os.environ["DMG_STUB_CALLS"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps([name, *args], ensure_ascii=False) + "\n")
if name == "ditto":
    if fail == "copy":
        print("fixture: ditto copy failed")
        sys.exit(17)
    shutil.copytree(args[0], args[1], symlinks=True)
    if fail == "bad-copy":
        for path in (Path(args[1]) / "Contents/MacOS").iterdir():
            path.unlink()
elif args[0] == "create":
    if fail == "missing":
        sys.exit(0)
    source = Path(args[args.index("-srcfolder") + 1])
    app = source / "牛马牌.app"
    target = Path(args[args.index("-o") + 1])
    executable = app / "Contents/MacOS/游戏 主程序"
    assert sorted(path.name for path in source.iterdir()) == ["Applications", "牛马牌.app"]
    assert (source / "Applications").is_symlink()
    assert os.readlink(source / "Applications") == "/Applications"
    assert executable.stat().st_mode & 0o111
    assert os.readlink(app / "Contents/Resources/current") == "game.pck"
    assert args[args.index("-format") + 1] == "UDZO"
    assert args[args.index("-fs") + 1] == "HFS+"
    assert args[args.index("-volname") + 1] == "牛马牌"
    target.write_text(json.dumps({"app": app.name, "link": "/Applications", "format": "UDZO",
                                 "executable": True, "internal_link": "game.pck"}), encoding="utf-8")
    if fail == "create":
        print("fixture: hdiutil create failed after partial output")
        sys.exit(23)
elif args[0] == "verify":
    assert Path(args[1]).is_file()
    if fail == "verify":
        print("fixture: hdiutil verify failed")
        sys.exit(29)
else:
    raise AssertionError(args)
'''


class DMGPackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="card-dmg-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "项目 空格 中文 $符号 `反引号`"
        self.root.mkdir()
        self.app = self.root / "编译 应用.app"
        self.metadata = self.app / "Contents/Info.plist"
        self.metadata.parent.mkdir(parents=True)
        self.info = {"CFBundleExecutable": "游戏 主程序"}
        self.metadata.write_bytes(plistlib.dumps(self.info))
        binary = self.app / "Contents/MacOS/游戏 主程序"
        binary.parent.mkdir()
        binary.write_bytes(b"compiled app")
        binary.chmod(0o755)
        resources = self.app / "Contents/Resources"
        resources.mkdir()
        (resources / "game.pck").write_bytes(b"game content")
        (resources / "current").symlink_to("game.pck")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("ditto", "hdiutil"):
            tool = self.bin / name
            tool.write_text(f"#!{sys.executable}\n" + STUB, encoding="utf-8")
            tool.chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)
        self.calls = self.root / "commands.jsonl"
        self.env = {"PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
                    "DMG_STUB_CALLS": str(self.calls), "DMG_STUB_FAILURE": "", "CARD_BUILD_NO_PAUSE": "1"}
        environment = mock.patch.dict(os.environ, self.env)
        environment.start()
        self.addCleanup(environment.stop)
        platform = mock.patch.object(dmg.sys, "platform", "darwin")
        platform.start()
        self.addCleanup(platform.stop)
        self.output = self.root / "安装包 目录/牛马牌 发布.dmg"

    def commands(self):
        return [json.loads(line) for line in self.calls.read_text(encoding="utf-8").splitlines()]

    def assert_clean(self):
        self.assertFalse(list(self.output.parent.glob(".dmg-stage-*")))
        self.assertFalse(list(self.output.parent.glob(".release-previous-*")))

    def previous_output(self):
        self.output.parent.mkdir(exist_ok=True)
        self.output.write_bytes(b"previous DMG")

    def test_tool_output_is_redacted_and_keeps_failure_status(self):
        raw = f"copy failed {self.root}/private.app\n"
        captured = io.StringIO()
        completed = subprocess.CompletedProcess(["ditto"], 17, raw)
        with mock.patch.object(dmg, "ROOT", self.root), \
                mock.patch.object(dmg.subprocess, "run", return_value=completed), redirect_stdout(captured):
            with self.assertRaises(subprocess.CalledProcessError) as error:
                dmg.run_command(["ditto"])
        self.assertEqual(error.exception.returncode, 17)
        self.assertEqual(captured.getvalue(), "copy failed ./private.app\n")

    def test_success_structure_permissions_symlinks_and_special_paths(self):
        self.previous_output()
        result = dmg.package(self.app, self.output)
        self.assertEqual(result, self.output)
        self.assertEqual(json.loads(result.read_text()), {"app": "牛马牌.app", "link": "/Applications",
                         "format": "UDZO", "executable": True, "internal_link": "game.pck"})
        commands = self.commands()
        self.assertEqual([command[0:2] for command in commands],
                         [["ditto", str(self.app)], ["hdiutil", "create"], ["hdiutil", "verify"]])
        self.assertEqual((self.app / "Contents/Resources/game.pck").read_bytes(), b"game content")
        self.assert_clean()

    def test_default_output_packages_app_without_version_metadata(self):
        with mock.patch.object(dmg, "ROOT", self.root):
            result = dmg.package(self.app)
        self.assertEqual(result, self.root / "build/牛马牌.dmg")
        self.assertTrue(result.is_file())

    def test_missing_app_explains_build_prerequisite_without_running_tools(self):
        with self.assertRaisesRegex(ValueError, "请先运行 ./构建游戏.command"):
            dmg.package(self.root / "没有.app", self.output)
        self.assertFalse(self.calls.exists())

    def test_invalid_app_uses_the_shared_release_validation(self):
        (self.app / "Contents/Resources/game.pck").unlink()
        with self.assertRaisesRegex(ValueError, "PCK"):
            dmg.package(self.app, self.output)
        self.assertFalse(self.calls.exists())

    def test_legacy_version_metadata_does_not_change_name_or_appear_in_feedback(self):
        self.metadata.write_bytes(plistlib.dumps({**self.info, "CFBundleShortVersionString": "9.8.7"}))
        feedback = io.StringIO()
        with mock.patch.object(dmg, "ROOT", self.root), redirect_stdout(feedback):
            result = dmg.package(self.app)
        self.assertEqual(result, self.root / "build/牛马牌.dmg")
        self.assertNotIn("9.8.7", feedback.getvalue())
        self.assertNotIn("版本", feedback.getvalue())

    def test_invalid_outputs_do_not_touch_the_app_or_existing_directory(self):
        directory = self.root / "occupied.dmg"
        directory.mkdir()
        for output in (self.root / "wrong.zip", self.app / "inside.dmg", directory):
            with self.subTest(output=output), self.assertRaises(ValueError):
                dmg.package(self.app, output)
        self.assertTrue(directory.is_dir())
        self.assertFalse(self.calls.exists())

    def test_copy_create_and_verify_failures_preserve_existing_dmg(self):
        self.previous_output()
        for failure, code in (("copy", 17), ("create", 23), ("verify", 29)):
            with self.subTest(failure=failure), mock.patch.dict(os.environ, DMG_STUB_FAILURE=failure):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    dmg.package(self.app, self.output)
                self.assertEqual(caught.exception.returncode, code)
                self.assertEqual(self.output.read_bytes(), b"previous DMG")
                self.assert_clean()

    def test_zero_exit_without_an_image_or_with_bad_copy_is_rejected(self):
        self.previous_output()
        for failure in ("missing", "bad-copy"):
            with self.subTest(failure=failure), mock.patch.dict(os.environ, DMG_STUB_FAILURE=failure):
                with self.assertRaises(ValueError):
                    dmg.package(self.app, self.output)
                self.assertEqual(self.output.read_bytes(), b"previous DMG")
                self.assert_clean()

    def test_publication_error_rolls_back_existing_dmg(self):
        self.previous_output()
        replace = release_bundle.os.replace

        def reject_new_file(source, target):
            if Path(source).parent.name.startswith(".dmg-stage-") and Path(target) == self.output:
                raise OSError("fixture publish error")
            return replace(source, target)

        with mock.patch.object(release_bundle.os, "replace", side_effect=reject_new_file):
            with self.assertRaisesRegex(OSError, "fixture publish error"):
                dmg.package(self.app, self.output)
        self.assertEqual(self.output.read_bytes(), b"previous DMG")
        self.assert_clean()

    def test_missing_system_tools_fail_before_staging(self):
        with mock.patch.object(dmg.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "找不到 macOS 系统工具 ditto"):
                dmg.package(self.app, self.output)
        self.assertFalse(self.output.parent.exists())

    def prepare_entry(self):
        (self.root / "tools").mkdir()
        for name in ("package_dmg.py", "release_bundle.py", "project_paths.py"):
            shutil.copy2(ROOT / "tools" / name, self.root / "tools" / name)
        shutil.copy2(ROOT / "打包DMG.command", self.root / "打包DMG.command")
        return self.root / "打包DMG.command"

    @unittest.skipUnless(sys.platform == "darwin", "真实 .command 入口要求 macOS")
    def test_entry_does_not_hide_filter_or_tee_failure(self):
        command = self.prepare_entry()
        for failure in ("filter", "tee"):
            with self.subTest(failure=failure):
                if failure == "filter":
                    (self.root / "tools/project_paths.py").write_text(
                        "import sys\nsys.stdin.read()\nsys.exit(71)\n")
                else:
                    shutil.copy2(ROOT / "tools/project_paths.py", self.root / "tools/project_paths.py")
                    tool = self.bin / "tee"
                    tool.write_text("#!/bin/sh\ncat >/dev/null\nexit 72\n")
                    tool.chmod(0o755)
                # 此用例只测外层管线，工作进程稳定返回 0，避免过滤器桩影响模块导入。
                (self.root / "tools/package_dmg.py").write_text("print('fixture complete')\n")
                result = subprocess.run([str(command)], cwd=self.root, text=True,
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 71 if failure == "filter" else 72, result.stderr)

    def test_command_help_does_not_build_or_write_logs(self):
        command = self.prepare_entry()
        result = subprocess.run([str(command), "--help"], cwd=self.root, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--app", result.stdout)
        self.assertIn("--output", result.stdout)
        self.assertIn("不重新编译", result.stdout)
        self.assertIn("build/牛马牌.dmg", result.stdout)
        self.assertNotIn("应用版本", result.stdout)
        self.assertFalse((self.root / "build").exists())
        self.assertFalse(self.calls.exists())

    @unittest.skipUnless(sys.platform == "darwin", "真实 .command 入口要求 macOS")
    def test_command_failure_has_logs_real_exit_code_and_keeps_old_image(self):
        command = self.prepare_entry()
        self.previous_output()
        result = subprocess.run([str(command), "--app", self.app.name, "--output", str(self.output)],
                                cwd=self.root, env={**os.environ, "DMG_STUB_FAILURE": "verify"},
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertIn("DMG 打包失败（退出码：29）", result.stderr)
        self.assertIn("完整日志", result.stderr)
        logs = list((self.root / "build/logs").glob("dmg-*.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn("fixture: hdiutil verify failed", logs[0].read_text())
        self.assertNotIn(str(self.root), result.stdout + result.stderr + logs[0].read_text())
        self.assertEqual(self.output.read_bytes(), b"previous DMG")
        self.assertNotIn("按回车", result.stderr)
        self.assert_clean()


if __name__ == "__main__":
    unittest.main()
