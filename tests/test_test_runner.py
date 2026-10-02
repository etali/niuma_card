# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""真实执行统一入口，验证自动发现、零匹配、错误/超时/取消及用户数据隔离。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools/test_runner.py"


class TestRunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="test-runner-fixture-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "tests").mkdir()
        (self.root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="fixture"\n')
        self.godot = self.root / "fixture-godot"
        self.godot.write_text("#!" + sys.executable + "\n" + '''
import os,pathlib,subprocess,sys,time
script=pathlib.Path(sys.argv[sys.argv.index('-s')+1])
mode=script.read_text().strip()
print('PROJECT_FILE=' + str(pathlib.Path.cwd() / 'private-source.gd'), flush=True)
print('HOME_FILE=' + str(pathlib.Path.home() / 'private-sdk'), flush=True)
user_dir=pathlib.Path.cwd() / 'card-combine-tests/fixture-log-cleanup'
user_dir.mkdir(parents=True,exist_ok=True)
(user_dir / 'preferences.json').write_text('fixture')
print('CARD_TEST_USER_DIR=' + str(user_dir), flush=True)
if mode == 'hang':
    child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'], start_new_session=True)
    pathlib.Path('child.pid').write_text(str(child.pid))
    print('fixture hanging with child',flush=True)
    time.sleep(60)
if mode == 'error': print('SCRIPT ERROR: fixture error')
print('=== 结果：3 通过 / 0 失败 ===')
''')
        self.godot.chmod(0o755)
        self.env = dict(os.environ, GODOT=str(self.godot))
        self.logs = self.root / "logs"

    def command(self, *args):
        return [sys.executable, str(RUNNER), "--root", str(self.root), "--log-dir", str(self.logs), *args]

    def run_runner(self, *args):
        return subprocess.run(self.command(*args), env=self.env, capture_output=True, text=True, timeout=15)

    def assert_private_paths_removed(self, output):
        report_text = (self.logs / "results.json").read_text()
        report = json.loads(report_text)
        logs = "\n".join(log.read_text() for log in self.logs.glob("*.log"))
        for text in (output, report_text, logs):
            self.assertNotIn(str(self.root), text)
            self.assertNotIn(str(Path.home()), text)
        for item in report["results"]:
            self.assertFalse(Path(item["log"]).is_absolute())
            self.assertTrue((self.root / item["log"]).is_file())
        self.assertIn("PROJECT_FILE=./private-source.gd", logs)
        self.assertIn("HOME_FILE=~/private-sdk", logs)
        self.assertFalse((self.root / "card-combine-tests/fixture-log-cleanup").exists(),
                         "脱敏前必须用原始路径清理，不能只留下看似不存在的相对路径")

    def test_discovers_new_python_files_and_counts_all_kinds(self):
        (self.root / "tests/test_fixture.gd").write_text("pass")
        # 同名跨语言文件必须分别记录，不能并行覆盖对方的日志。
        (self.root / "tests/test_fixture.py").write_text('''import unittest
class NewFeature(unittest.TestCase):
    def test_pass(self): self.assertEqual(2 + 2, 4)
    @unittest.skip('fixture skip')
    def test_skip(self): pass
''')
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((self.logs / "results.json").read_text())
        self.assertEqual((report["files"], report["passed_files"]), (2, 2))
        self.assert_private_paths_removed(result.stdout + result.stderr)
        self.assertEqual(report["gd"], {"passed":3,"failed":0,"skipped":0})
        self.assertEqual(report["python"], {"passed":1,"failed":0,"skipped":1})
        self.assertTrue((self.logs / "tests__test_fixture.gd.log").is_file())
        self.assertTrue((self.logs / "tests__test_fixture.py.log").is_file())
        self.assertEqual((self.root / "project.godot").read_text(), 'config_version=5\n[application]\nconfig/name="fixture"\n')

    def test_unknown_filter_fails_instead_of_zero_test_success(self):
        result = self.run_runner("missing-test")
        self.assertEqual(result.returncode, 2)
        self.assertIn("没有匹配的测试", result.stderr)

    def test_runtime_error_overrules_success_tally(self):
        (self.root / "tests/test_fixture.gd").write_text("error")
        result = self.run_runner()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("SCRIPT ERROR", (self.logs / "tests__test_fixture.gd.log").read_text())
        self.assert_private_paths_removed(result.stdout + result.stderr)

    def assert_child_stopped(self):
        pid = int((self.root / "child.pid").read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            if status.returncode != 0 or status.stdout.strip().startswith("Z"):
                return
            time.sleep(0.05)
        self.fail(f"测试遗留子进程 {pid}")

    def test_timeout_retains_log_and_stops_detached_child(self):
        (self.root / "tests/test_fixture.gd").write_text("hang")
        result = self.run_runner("--timeout", "1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("超时", result.stdout)
        self.assertIn("fixture hanging", (self.logs / "tests__test_fixture.gd.log").read_text())
        self.assert_private_paths_removed(result.stdout + result.stderr)
        self.assert_child_stopped()

    def test_cancel_retains_report_and_stops_detached_child(self):
        (self.root / "tests/test_fixture.gd").write_text("hang")
        process = subprocess.Popen(self.command(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "child.pid").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue((self.root / "child.pid").exists())
            process.send_signal(signal.SIGTERM)
            output = process.communicate(timeout=5)[0]
            self.assertEqual(process.returncode, 143, output)
            self.assertTrue((self.logs / "results.json").is_file())
            self.assert_private_paths_removed(output)
            self.assert_child_stopped()
        finally:
            if process.poll() is None:
                process.kill(); process.wait()


class GodotIsolationTest(unittest.TestCase):
    def test_finish_drains_audio_and_preserves_assertion_count_and_exit_code(self):
        godot = os.environ.get("CARD_TEST_REAL_GODOT") or os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")
        if not Path(godot).is_file():
            self.skipTest("需要 Godot 验证真实音频播放的退出生命周期")
        with tempfile.TemporaryDirectory() as temporary:
            for failing in (False, True):
                with self.subTest(failing=failing):
                    script = Path(temporary) / "audio.gd"
                    script.write_text('''extends "res://tests/harness.gd"
func _initialize() -> void:
    call_deferred("_run")
func _run() -> void:
    var sound := Sfx.new()
    root.add_child(sound)
    sound.play("buy")
    check(%s, "fixture assertion")
    finish()
''' % ("false" if failing else "true"))
                    result = subprocess.run([godot, "--headless", "--verbose", "--path", str(ROOT),
                                             "--log-file", str(Path(temporary)/"engine.log"), "-s", str(script)],
                                            env=dict(os.environ, TEST_SPEED="5"), capture_output=True, text=True, timeout=15)
                    output = result.stdout + result.stderr
                    self.assertEqual(result.returncode, int(failing), output)
                    self.assertIn("0 通过 / 1 失败" if failing else "1 通过 / 0 失败", output)
                    self.assertNotIn("SCRIPT ERROR", output)
                    self.assertNotIn("resources still in use", output)
                    self.assertNotIn("Leaked instance:", output)

    def test_runner_isolates_plain_scripts_and_python_godot_children(self):
        godot = os.environ.get("CARD_TEST_REAL_GODOT") or os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")
        if not Path(godot).is_file():
            self.skipTest("需要 Godot 验证进程启动前的用户数据隔离")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tests").mkdir()
            (root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="runner isolation fixture"\n')
            script = '''extends SceneTree
func _initialize() -> void:
    var isolated := "/card-combine-tests/" in OS.get_user_data_dir()
    print("CHILD_USER_DIR=" + OS.get_user_data_dir())
    if not isolated:
        quit(1)
        return
    var file := FileAccess.open("user://preferences.json", FileAccess.WRITE)
    file.store_string("fixture")
    file.close()
    print("=== 结果：1 通过 / 0 失败 ===")
    quit(0)
'''
            (root / "tests/test_plain.gd").write_text(script)
            (root / "tests/child.gd").write_text(script)
            (root / "tests/test_python_child.py").write_text('''import os, pathlib, subprocess, unittest
class ChildTest(unittest.TestCase):
    def test_child(self):
        r=subprocess.run([os.environ['GODOT'],'--headless','--path',str(pathlib.Path.cwd()),'-s','tests/child.gd'],capture_output=True,text=True,timeout=10)
        print(r.stdout,flush=True)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
''')
            env = dict(os.environ, GODOT=godot)
            logs = root / "logs"
            result = subprocess.run([sys.executable, str(RUNNER), "--root", str(root), "--log-dir", str(logs)],
                                    env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            paths = [line.split("=",1)[1] for log in logs.glob("*.log") for line in log.read_text().splitlines()
                     if line.startswith("CHILD_USER_DIR=")]
            self.assertEqual(len(set(paths)), 2, paths)
            self.assertTrue(all(not Path(path).expanduser().exists() for path in paths), "各子进程的用户文件均被清理")

    def test_direct_harness_process_uses_separate_user_data_and_cleans_it(self):
        godot = os.environ.get("CARD_TEST_REAL_GODOT") or os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")
        if not Path(godot).is_file():
            self.skipTest("需要 Godot 验证真实 user:// 隔离")
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "probe.gd"
            script.write_text('''extends "res://tests/harness.gd"
func _initialize() -> void:
    var path := ProjectSettings.globalize_path("user://probe.json")
    if not need("/card-combine-tests/" in path, "使用独立测试目录"):
        finish()
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string("isolated")
    file.close()
    check(FileAccess.get_file_as_string(path) == "isolated", "user文件实际可写可读")
    if Tape.path_dir() != ProjectSettings.globalize_path("user://replays"):
        check(false, "保存前确认录像目录已经隔离")
        finish()
        return
    var recording := Tape.new().save("_runner_probe.json")
    check(recording.begins_with(ProjectSettings.globalize_path("user://replays") + "/")
        and FileAccess.file_exists(recording), "录像实际保存到测试沙箱")
    finish()
''')
            env = dict(os.environ)
            env.pop("CARD_TEST_USER_DIR_NAME", None)
            result = subprocess.run([godot, "--headless", "--path", str(ROOT), "--log-file", str(Path(temporary)/"engine.log"), "-s", str(script)],
                                    env=env, capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("SCRIPT ERROR", output)
            paths = [line.split("=",1)[1] for line in output.splitlines() if line.startswith("CARD_TEST_USER_DIR=")]
            self.assertEqual(len(paths), 1, output)
            self.assertFalse(Path(paths[0]).exists(), "直接单跑正常退出也清理自己的数据")


if __name__ == "__main__":
    unittest.main()
