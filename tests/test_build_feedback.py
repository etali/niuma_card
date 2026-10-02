# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""真实运行构建入口，覆盖失败可见、日志、退出码和交互终端不闪退。"""
import errno
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildFeedbackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="card-build-feedback-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "tools").mkdir()
        (self.root / "bin").mkdir()
        shutil.copy2(ROOT / "构建游戏.command", self.root / "构建游戏.command")
        shutil.copy2(ROOT / "tools/project_paths.py", self.root / "tools/project_paths.py")
        (self.root / "bin/python3").symlink_to(sys.executable)
        (self.root / "tools/slim_engine.py").write_text(
            'import os, sys, pathlib\n'
            'assert pathlib.Path("build/.gdignore").is_file(), "引擎扫描之前必须隔离build"\n'
            'print("fixture build stdout", flush=True)\n'
            'print(os.environ.get("BUILD_MESSAGE", "compiler detail"), file=sys.stderr, flush=True)\n'
            'sys.exit(int(os.environ.get("BUILD_EXIT", "17")))\n')
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin")
        for key in ["CI", "CARD_BUILD_NO_PAUSE", "CARD_BUILD_WORKER"]:
            self.env.pop(key, None)

    def run_build(self, **env):
        return subprocess.run(["/bin/bash", "构建游戏.command", "--slim-engine"],
                              cwd=self.root, env={**self.env, **env}, capture_output=True,
                              text=True, timeout=10)

    def test_failure_is_visible_logged_and_keeps_real_exit_status(self):
        result = self.run_build(BUILD_EXIT="47", BUILD_MESSAGE="精简构建失败：Apple Clang 15，要求16")
        self.assertEqual(result.returncode, 47)
        self.assertIn("构建失败（退出码：47）", result.stderr)
        self.assertIn("Apple Clang 15", result.stderr)
        self.assertIn("本次构建未完成", result.stderr)
        logs = list((self.root / "build/logs").glob("*.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn(str(logs[0].relative_to(self.root)), result.stderr)
        self.assertIn("fixture build stdout", logs[0].read_text())
        self.assertIn("Apple Clang 15", logs[0].read_text())
        self.assertNotIn("按回车", result.stderr)  # 非交互脚本不会无限等输入

    def test_console_and_persistent_log_hide_project_and_home_paths(self):
        message = f"ERROR: {self.root}/engine/game.gd; SDK {Path.home()}/Library/sdk"
        result = self.run_build(BUILD_EXIT="19", BUILD_MESSAGE=message)
        self.assertEqual(result.returncode, 19)
        log = next((self.root / "build/logs").glob("*.log")).read_text()
        for output in (result.stdout, result.stderr, log):
            self.assertNotIn(str(self.root), output)
            self.assertNotIn(str(Path.home()), output)
            self.assertIn("./engine/game.gd", output)
            self.assertIn("~/Library/sdk", output)

    def test_filter_and_tee_failure_cannot_report_success(self):
        for failing in ("filter", "tee"):
            with self.subTest(failing=failing):
                if failing == "filter":
                    tool = self.root / "tools/project_paths.py"
                    tool.write_text("import sys\nsys.stdin.read()\nsys.exit(71)\n")
                else:
                    shutil.copy2(ROOT / "tools/project_paths.py", self.root / "tools/project_paths.py")
                    tool = self.root / "bin/tee"
                    tool.write_text("#!/bin/sh\ncat >/dev/null\nexit 72\n")
                    tool.chmod(0o755)
                result = self.run_build(BUILD_EXIT="0")
                self.assertEqual(result.returncode, 71 if failing == "filter" else 72, result.stderr)

    def test_android_install_entry_redacts_paths_and_checks_all_pipeline_statuses(self):
        shutil.copy2(ROOT / "安装安卓构建环境.command", self.root / "安装安卓构建环境.command")
        installer = self.root / "tools/install_android_dependencies.py"
        installer.write_text(
            "import os, pathlib, sys\n"
            "print(str(pathlib.Path.cwd() / 'fixture-sdk'), flush=True)\n"
            "sys.exit(int(os.environ.get('FIXTURE_INSTALL_EXIT', '0')))\n")
        for failure, code in (("installer", 47), ("filter", 71), ("tee", 72)):
            with self.subTest(failure=failure):
                shutil.copy2(ROOT / "tools/project_paths.py", self.root / "tools/project_paths.py")
                if failure == "filter":
                    (self.root / "tools/project_paths.py").write_text(
                        "import sys\nsys.stdin.read()\nsys.exit(71)\n")
                elif failure == "tee":
                    tee = self.root / "bin/tee"
                    tee.write_text("#!/bin/sh\ncat >/dev/null\nexit 72\n")
                    tee.chmod(0o755)
                result = subprocess.run(["bash", "安装安卓构建环境.command"], cwd=self.root,
                                        env=dict(self.env, FIXTURE_INSTALL_EXIT="47" if failure == "installer" else "0"),
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertNotIn(str(self.root), result.stdout + result.stderr)
                self.assertIn("Android 环境安装未完成", result.stderr)
                if failure == "installer":
                    log = next((self.root / "build/logs").glob("android-install-*.log")).read_text()
                    self.assertIn("./fixture-sdk", log)
                    self.assertNotIn(str(self.root), log)

    def test_checked_godot_uses_raw_error_for_status_and_redacts_display(self):
        shutil.copy2(ROOT / "tools/godot_build.sh", self.root / "tools/godot_build.sh")
        fixture = self.root / "engine.py"
        fixture.write_text(f"print('ERROR: ' + {str(self.root)!r} + '/fixture.gd')\n")
        result = subprocess.run(["bash", "-c", 'source tools/godot_build.sh; godot_checked engine.py'],
                                cwd=self.root, env=dict(self.env, GODOT=sys.executable),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ERROR: ./fixture.gd", result.stdout)
        self.assertNotIn(str(self.root), result.stdout + result.stderr)

    def test_first_cause_remains_visible_after_repeated_secondary_errors(self):
        message = 'ERROR: first import cause\n' + 'ERROR: repeated dialog parenting error\n' * 25
        result = self.run_build(BUILD_MESSAGE=message)
        self.assertIn('首个错误及上下文', result.stderr)
        self.assertIn('ERROR: first import cause', result.stderr)
        self.assertIn('完整日志', result.stderr)

    def test_success_keeps_zero_and_has_no_failure_notice(self):
        result = self.run_build(BUILD_EXIT="0", BUILD_MESSAGE="构建完成")
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("构建失败", result.stderr)
        self.assertEqual(len(list((self.root / "build/logs").glob("*.log"))), 1)

    def test_zero_exit_with_engine_error_is_still_failure(self):
        result = self.run_build(BUILD_EXIT="0", BUILD_MESSAGE="SCRIPT ERROR: fixture export failed")
        self.assertEqual(result.returncode, 1)
        self.assertIn("日志含有引擎错误", result.stderr)
        self.assertIn("SCRIPT ERROR: fixture export failed", result.stderr)

    def test_invalid_arguments_are_explained(self):
        result = subprocess.run(["/bin/bash", "构建游戏.command", "--invalid"], cwd=self.root,
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("未知参数：--invalid", result.stderr)
        self.assertIn("完整日志", result.stderr)

    def test_interactive_terminal_keeps_error_visible_until_enter(self):
        primary, secondary = pty.openpty()
        process = subprocess.Popen(["/bin/bash", "构建游戏.command", "--slim-engine"],
                                   cwd=self.root, env=self.env, stdin=secondary,
                                   stdout=secondary, stderr=secondary)
        os.close(secondary)
        try:
            output = b""
            deadline = time.monotonic() + 10
            prompt = "按回车键退出".encode()
            while prompt not in output and time.monotonic() < deadline:
                if select.select([primary], [], [], 0.1)[0]:
                    try:
                        output += os.read(primary, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
            self.assertIn(prompt, output)
            self.assertIn("构建失败（退出码：17）".encode(), output)
            self.assertIsNone(process.poll(), "没有按回车前构建窗口不能直接退出")
            os.write(primary, b"\n")
            self.assertEqual(process.wait(timeout=5), 17)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(primary)

    def test_help_does_not_build_or_write_logs(self):
        result = subprocess.run(["/bin/bash", "构建游戏.command", "--help"], cwd=self.root,
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("标准构建", result.stdout)
        self.assertFalse((self.root / "build").exists())


if __name__ == "__main__":
    unittest.main()
