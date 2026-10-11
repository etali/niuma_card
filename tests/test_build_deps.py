# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""构建依赖询问：Y 安装后继续，N 终止构建，非交互不等待输入。"""
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_deps  # noqa: E402


class FakeTty(io.StringIO):
    def __init__(self, answers):
        super().__init__(answers)
        self.prompts = []

    def write(self, text):
        self.prompts.append(text)
        return len(text)

    def close(self):
        pass


class BuildDepsTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        for key in ("CI", "CARD_BUILD_NO_PAUSE", "CARD_BUILD_ASSUME_YES"):
            os.environ.pop(key, None)
        self.installed = []

    def group(self, required=True):
        return build_deps.Missing("测试依赖", ["dep"], lambda: self.installed.append("dep"),
                                  "./安装构建环境.command", required=required)

    def answer(self, text):
        tty = FakeTty(text)
        return mock.patch.object(build_deps, "_tty", return_value=tty), tty

    def test_yes_installs(self):
        patch, tty = self.answer("y\n")
        with patch, mock.patch("sys.stdout", io.StringIO()):
            build_deps.resolve(self.group())
        self.assertEqual(self.installed, ["dep"])
        self.assertIn("[Y/N]", "".join(tty.prompts))

    def test_no_aborts_with_declined_code(self):
        patch, _ = self.answer("N\n")
        with patch, mock.patch("sys.stdout", io.StringIO()):
            with self.assertRaises(build_deps.DependencyError) as caught:
                build_deps.resolve(self.group())
        self.assertEqual(caught.exception.code, build_deps.DECLINED)
        self.assertIn("已终止构建", str(caught.exception))
        self.assertEqual(self.installed, [])

    def test_invalid_answer_asks_again(self):
        patch, tty = self.answer("maybe\nY\n")
        with patch, mock.patch("sys.stdout", io.StringIO()):
            build_deps.resolve(self.group())
        self.assertEqual(self.installed, ["dep"])
        self.assertIn("请输入 Y 或 N", "".join(tty.prompts))

    def test_eof_counts_as_no(self):
        patch, _ = self.answer("")
        with patch, mock.patch("sys.stdout", io.StringIO()):
            with self.assertRaises(build_deps.DependencyError):
                build_deps.resolve(self.group())

    def test_optional_no_continues(self):
        patch, _ = self.answer("n\n")
        with patch, mock.patch("sys.stdout", io.StringIO()):
            build_deps.resolve(self.group(required=False))
        self.assertEqual(self.installed, [])

    def test_non_interactive_never_waits(self):
        os.environ["CARD_BUILD_NO_PAUSE"] = "1"
        with mock.patch("builtins.open", side_effect=AssertionError("不应打开终端")), \
                mock.patch("sys.stdout", io.StringIO()):
            with self.assertRaises(build_deps.DependencyError) as caught:
                build_deps.resolve(self.group())
            build_deps.resolve(self.group(required=False))
        self.assertEqual(caught.exception.code, 1)
        self.assertIn("CARD_BUILD_ASSUME_YES", str(caught.exception))
        self.assertEqual(self.installed, [])

    def test_real_terminal_open_works_on_non_seekable_device(self):
        # 回归：open("/dev/tty", "r+") 在不可 seek 的终端上抛 UnsupportedOperation，被误判为非交互。
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory) / "tty"
            os.mkfifo(fifo)
            with mock.patch.object(build_deps, "TTY_PATH", str(fifo)):
                tty = build_deps._tty()
            self.assertIsNotNone(tty)
            with tty:
                tty.write("y\n")
                tty.flush()
                self.assertEqual(tty.readline(), "y\n")

    def test_assume_yes_installs_without_terminal(self):
        os.environ["CARD_BUILD_ASSUME_YES"] = "1"
        with mock.patch.object(build_deps, "_tty", side_effect=AssertionError("不应询问")), \
                mock.patch("sys.stdout", io.StringIO()):
            build_deps.resolve(self.group())
        self.assertEqual(self.installed, ["dep"])

    def test_shared_installer_runs_once_and_rechecks(self):
        calls = []
        install = lambda: calls.append(1)
        groups = [build_deps.Missing("Pillow", ["Pillow"], install, "x"),
                  build_deps.Missing("fonttools", ["fonttools"], install, "x", required=False)]
        os.environ["CARD_BUILD_ASSUME_YES"] = "1"
        with mock.patch.object(build_deps, "collect", side_effect=[groups, []]), \
                mock.patch("sys.stdout", io.StringIO()):
            build_deps.ensure("macos", Path("godot"))
        self.assertEqual(calls, [1])

    def test_still_missing_after_install_fails(self):
        group = self.group()
        os.environ["CARD_BUILD_ASSUME_YES"] = "1"
        with mock.patch.object(build_deps, "collect", return_value=[group]), \
                mock.patch("sys.stdout", io.StringIO()):
            with self.assertRaisesRegex(build_deps.DependencyError, "安装后仍缺少"):
                build_deps.ensure("macos", Path("godot"))


if __name__ == "__main__":
    unittest.main()
