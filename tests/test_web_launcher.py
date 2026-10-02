# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""真实执行 Web 启动脚本，验证退出码和所属子进程回收；不打开浏览器/端口。"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WebLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="card-web-launcher-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        (self.root / "build/web").mkdir(parents=True)
        (self.root / "build/web/index.html").write_text("fixture")
        shutil.copy2(ROOT / "本地运行Web版.command", self.root / "web.command")
        for name, role in (("godot", "SERVER"), ("python3", "HTTP")):
            self.executable(name, f'''#!{sys.executable}
import os,pathlib,signal,time
role={role!r}
pathlib.Path(os.environ['FIXTURE_ROOT'],role+'.pid').write_text(str(os.getpid()))
if role == 'SERVER' and os.environ.get('IGNORE_TERM'):
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
code=os.environ.get(role+'_EXIT')
if code: raise SystemExit(int(code))
time.sleep(60)
''')
        for name, body in (("lsof", "exit 1"), ("open", "exit 0")):
            self.executable(name, "#!/bin/sh\n" + body + "\n")
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":/usr/bin:/bin",
                        GODOT=str(self.root / "bin/godot"), FIXTURE_ROOT=str(self.root))

    def executable(self, name, contents):
        path = self.root / "bin" / name
        path.write_text(contents)
        path.chmod(0o755)

    def start(self, **env):
        return subprocess.Popen(["bash", "web.command", "2"], cwd=self.root, env={**self.env, **env},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)

    def wait_ready(self):
        deadline = time.monotonic() + 5
        while not (self.root / "HTTP.pid").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / "HTTP.pid").exists())

    def assert_children_gone(self):
        for path in self.root.glob("*.pid"):
            pid = int(path.read_text())
            with self.assertRaises(ProcessLookupError, msg=f"{path.name} 未退出"):
                os.kill(pid, 0)

    def stop_fixture(self, process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()

    def test_signal_stops_http_and_server_even_if_server_ignores_term(self):
        process = self.start(IGNORE_TERM="1")
        try:
            self.wait_ready()
            process.terminate()
            output = process.communicate(timeout=8)[0]
            self.assertEqual(process.returncode, 143, output)
            self.assert_children_gone()
        finally:
            self.stop_fixture(process)

    def test_http_failure_stops_server_and_preserves_failure_status(self):
        process = self.start(HTTP_EXIT="23")
        try:
            output = process.communicate(timeout=8)[0]
            self.assertEqual(process.returncode, 23, output)
            self.assert_children_gone()
        finally:
            self.stop_fixture(process)

    def test_ctrl_c_and_terminal_close_stop_owned_children(self):
        for number in (signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=number):
                for path in self.root.glob("*.pid"):
                    path.unlink()
                process = self.start()
                try:
                    self.wait_ready()
                    process.send_signal(number)
                    output = process.communicate(timeout=8)[0]
                    self.assertEqual(process.returncode, 128 + number, output)
                    self.assert_children_gone()
                finally:
                    self.stop_fixture(process)

    def test_server_failure_does_not_announce_running_or_start_http(self):
        process = self.start(SERVER_EXIT="29")
        try:
            output = process.communicate(timeout=8)[0]
            self.assertEqual(process.returncode, 29, output)
            self.assertIn("专服启动失败", output)
            self.assertNotIn("Web 版本地运行中", output)
            self.assertFalse((self.root / "HTTP.pid").exists())
            self.assert_children_gone()
        finally:
            self.stop_fixture(process)


if __name__ == "__main__":
    unittest.main()
