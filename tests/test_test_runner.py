# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""真实执行统一入口，验证自动发现、零匹配、错误/超时/取消及用户数据隔离。"""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import signal
import re
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
if '--import' in sys.argv:
    pathlib.Path('imported').write_text('ready')
    config=pathlib.Path('import-mode')
    mode=config.read_text() if config.exists() else 'pass'
    if mode == 'error': print('ERROR: fixture import failure')
    if mode == 'hang': time.sleep(60)
    sys.exit(0)
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

    def test_suite_list_unions_without_duplicates_then_intersects_filter(self):
        for name in ("test_drawer_one.gd", "test_bot_two.gd", "test_engine.gd", "test_fixture.py"):
            (self.root / "tests" / name).write_text("pass")
        self.env["GODOT"] = str(self.root / "missing-godot")
        result = self.run_runner("--suite", "gd", "--suite", "drawer", "--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["tests/test_bot_two.gd", "tests/test_drawer_one.gd", "tests/test_engine.gd"])
        narrowed = self.run_runner("--suite", "gd", "drawer", "--list")
        self.assertEqual(narrowed.stdout.splitlines(), ["tests/test_drawer_one.gd"])
        self.assertFalse(self.logs.exists(), "列举无需资源导入、日志或 Godot 安装")

    def test_class_skip_is_reported_but_empty_python_file_fails(self):
        cases = {
            "skip": """import unittest
class OptionalFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls): raise unittest.SkipTest('optional asset unavailable')
    def test_fixture(self): self.fail('must be skipped')
""",
            "empty": "import unittest\n",
        }
        for name, source in cases.items():
            with self.subTest(name=name):
                (self.root / "tests/test_fixture.py").write_text(source)
                result = self.run_runner()
                report = json.loads((self.logs / "results.json").read_text())
                self.assertEqual(result.returncode, 0 if name == "skip" else 1, result.stdout + result.stderr)
                self.assertEqual(report["python"]["passed"], 0)
                self.assertEqual(report["python"]["skipped"], int(name == "skip"))
                if name == "empty":
                    self.assertEqual(report["results"][0]["reason"], "没有执行 Python 用例")

    def test_mixed_setup_skip_and_method_skip_do_not_swallow_passed_tests(self):
        for setup in ("class", "module"):
            with self.subTest(setup=setup):
                prefix = """import unittest
class OptionalFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls): raise unittest.SkipTest('optional class')
    def test_fixture(self): self.fail('must be skipped')
""" if setup == "class" else """import unittest
def setUpModule(): raise unittest.SkipTest('optional module')
class OptionalFixture(unittest.TestCase):
    def test_fixture(self): self.fail('must be skipped')
"""
                (self.root / "tests/test_skipped.py").write_text(prefix)
                (self.root / "tests/test_passing.py").write_text("""import unittest
class StandardFixture(unittest.TestCase):
    def test_pass(self): self.assertEqual(2 + 2, 4)
    @unittest.skip('optional method')
    def test_skip(self): self.fail('must be skipped')
""")
                # 一份入口显式汇集两个模块，复现同一 unittest 运行中同时有整类/模块和方法跳过。
                (self.root / "tests/test_fixture.py").write_text("""import unittest
def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite()
    for module in ('test_skipped', 'test_passing'):
        suite.addTests(loader.loadTestsFromName(module))
    return suite
""")
                result = self.run_runner("test_fixture.py")
                report = json.loads((self.logs / "results.json").read_text())
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(report["python"], {"passed": 1, "failed": 0, "skipped": 2})

    def test_resource_import_error_and_timeout_do_not_launch_tests(self):
        (self.root / "tests/test_fixture.gd").write_text("pass")
        for mode, expected in (("error", "Godot 导入报错"), ("hang", "超时")):
            with self.subTest(mode=mode):
                (self.root / "import-mode").write_text(mode)
                result = self.run_runner("--timeout", "0.3")
                report = json.loads((self.logs / "results.json").read_text())
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(expected, report["preparation"]["reason"])
                self.assertEqual(report["not_run_files"], 1)
                self.assertEqual(report["results"], [])
                self.assertTrue((self.logs / "prepare_resources.log").is_file())
                self.assertFalse((self.logs / "tests__test_fixture.gd.log").exists())

    def test_import_waits_for_build_resource_lock_with_timeout(self):
        (self.root / "tests/test_fixture.gd").write_text("pass")
        (self.root / "build").mkdir()
        with (self.root / "build/.font-transaction.lock").open("a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.run_runner("--timeout", "0.2")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("等待资源导入锁超时", result.stdout)
        self.assertFalse((self.root / "imported").exists(), "持有构建锁时不能写共享缓存")
        self.assertEqual(self.run_runner().returncode, 0, "释放构建锁后可以导入并运行")

    def test_cancelling_resource_import_retains_report_without_launching_tests(self):
        (self.root / "tests/test_fixture.gd").write_text("pass")
        (self.root / "import-mode").write_text("hang")
        process = subprocess.Popen(self.command(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "imported").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue((self.root / "imported").exists())
            process.send_signal(signal.SIGTERM)
            output = process.communicate(timeout=5)[0]
            self.assertEqual(process.returncode, 143, output)
            report = json.loads((self.logs / "results.json").read_text())
            self.assertEqual(report["preparation"]["status"], "cancelled")
            self.assertEqual(report["not_run_files"], 1)
            self.assertEqual(report["results"], [])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

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


class RuntimeRequestPathsTest(unittest.TestCase):
    def test_report_requests_keep_paths_after_project_isolation(self):
        spec = importlib.util.spec_from_file_location("test_runtime", ROOT / "tools/test_runtime.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            source = directory / "source"
            isolated = directory / "isolated"
            source.mkdir()
            isolated.mkdir()
            cards = source / "cards.json"
            cards.write_text('{"cash":{"kind":"unit"}}')
            request = source / "request.json"
            request.write_text(json.dumps({"cards_path":"cards.json", "output_path":"result.json",
                                           "progress_path":"progress.json", "options":{"pairs":1}}))
            original = request.read_bytes()
            for script in ("eval_report.gd", "bot_duel_report.gd"):
                with self.subTest(script=script):
                    args = ["-s", "tools/" + script, "--", "request.json"]
                    adjusted = runtime.preserve_project_paths(args, source, isolated)
                    snapshot = json.loads(Path(adjusted[-1]).read_text())
                    self.assertEqual(Path(snapshot["cards_path"]), cards)
                    self.assertEqual(Path(snapshot["cards_path"]).read_text(), cards.read_text())
                    self.assertEqual(Path(snapshot["output_path"]), source / "result.json")
                    self.assertEqual(Path(snapshot["progress_path"]), source / "progress.json")
                    self.assertEqual(snapshot["options"], {"pairs":1})
                    self.assertEqual(request.read_bytes(), original, "不改调用方的持久请求")
                    self.assertEqual(args[-1], "request.json", "不改调用方的命令参数")


class GodotIsolationTest(unittest.TestCase):
    def test_runner_imports_fresh_project_and_repairs_missing_texture_cache(self):
        godot = os.environ.get("CARD_TEST_REAL_GODOT") or os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")
        if not Path(godot).is_file():
            self.skipTest("需要 Godot 验证首次导入与缓存修复")
        with tempfile.TemporaryDirectory(prefix="runner-import-") as temporary:
            root = Path(temporary)
            (root / "tests").mkdir()
            (root / "tests/.gdignore").touch()
            (root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="import fixture"\n')
            (root / "icon.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>')
            (root / "tests/test_texture.gd").write_text('''extends SceneTree
const ICON = preload("res://icon.svg")
func _initialize() -> void:
    if ICON is Texture2D and ICON.get_width() == 8:
        print("=== 结果：1 通过 / 0 失败 ===")
        quit(0)
    else:
        quit(1)
''')
            original = (root / "project.godot").read_bytes()
            for missing_cache in (False, True):
                with self.subTest(missing_cache=missing_cache):
                    if missing_cache:
                        import_config = (root / "icon.svg.import").read_text()
                        cache = re.search(r'^path="res://(.+)"$', import_config, re.M)[1]
                        (root / cache).unlink()
                    logs = root / "build/results"
                    result = subprocess.run([sys.executable, str(RUNNER), "--root", str(root), "--log-dir", str(logs)],
                                            env=dict(os.environ, GODOT=godot), capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    report = json.loads((logs / "results.json").read_text())
                    self.assertEqual(report["preparation"]["status"], "passed")
                    self.assertEqual(report["gd"]["passed"], 1)
                    self.assertTrue((root / "build/.gdignore").exists())
                    self.assertEqual((root / "project.godot").read_bytes(), original)

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
