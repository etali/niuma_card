# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""两个生产入口的字体生命周期回归；所有导入、导出均在临时项目中运行。"""
import hashlib
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ("构建游戏.command", "打包发布.command")
FONT = Path("assets/fonts/NotoSansSC.ttf")
FONTDATA = Path(".godot/imported/NotoSansSC.ttf-original.fontdata")
MD5 = FONTDATA.with_suffix(".md5")
IMPORT_TEXT = '[remap]\npath="res://.godot/imported/NotoSansSC.ttf-original.fontdata"\n'


class FontSubsetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="card-font-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("tools", "assets/fonts", "assets/art", ".godot/imported", "bin", "templates", "data", "scratch"):
            (self.root / name).mkdir(parents=True)
        for name in SCRIPTS:
            shutil.copy2(ROOT / name, self.root / name)
        shutil.copy2(ROOT / "tools/font_subset.sh", self.root / "tools/font_subset.sh")
        for tool in ("build_art.py", "ensure_app_icon.py", "build_android_icons.py", "godot_build.sh", "project_paths.py", "release_bundle.py", "install_web_templates.py"):
            shutil.copy2(ROOT / "tools" / tool, self.root / "tools" / tool)
        (self.root / "tools/check_art_assets.py").write_text("pass\n")
        from PIL import Image
        Image.new("RGBA", (20, 24), (60, 30, 20, 255)).save(self.root / "assets/art/app_icon.png")
        for name in ("web_release.zip", "web_debug.zip", "web_nothreads_release.zip", "web_nothreads_debug.zip"):
            with zipfile.ZipFile(self.root / "templates" / name, "w") as archive:
                for required in ("godot.html", "godot.js", "godot.wasm"):
                    archive.writestr(required, b"fixture")
        (self.root / "data/cards.json").write_text('{"name": "牛马牌"}')
        (self.root / FONT).write_bytes(b"full-variable-font-wght-100-900")
        (self.root / (str(FONT) + ".import")).write_text(IMPORT_TEXT)
        (self.root / FONTDATA).write_bytes(b"full-cache")
        (self.root / MD5).write_bytes(b"full-md5")
        (self.root / "bin/python3").symlink_to(sys.executable)
        self.write_executable("pyftsubset", '''
import os, pathlib, signal, sys
out = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--output-file="))
pathlib.Path(out).write_bytes(b"subset-font")
mode = os.environ.get("SUBSET_MODE", "")
if mode == "fail":
    sys.exit(21)
if mode == "term":
    os.kill(os.getppid(), signal.SIGTERM)
''')
        self.godot = self.write_executable("godot", '''
import hashlib, json, os, pathlib, plistlib, sys
root = pathlib.Path.cwd()
font = root / "assets/fonts/NotoSansSC.ttf"
full = font.read_bytes().startswith(b"full-") or hashlib.sha256(font.read_bytes()).hexdigest() == os.environ.get("FULL_FONT_SHA")
kind = "import" if "--import" in sys.argv else "export"
events = root / "events.jsonl"
previous = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
number = sum(event["kind"] == kind for event in previous) + 1
with events.open("a") as stream:
    stream.write(json.dumps({"kind": kind, "number": number, "full": full}) + "\\n")
if kind == "import":
    if not (root / "build/.gdignore").is_file():
        print("ERROR: 引擎缓存未与资源导入隔离", file=sys.stderr)
        sys.exit(33)
    if os.environ.get("IMPORT_FAIL") == str(number):
        print("import failed", file=sys.stderr)
        sys.exit(31)
    if os.environ.get("IMPORT_ERROR") == str(number):
        print("ERROR: fixture import failure", file=sys.stderr)
        sys.exit(0)
    if os.environ.get("IMPORT_MISSING") == str(number):
        sys.exit(0)
    config = '[remap]\\npath="res://.godot/imported/NotoSansSC.ttf-original.fontdata"\\n'
    font.with_suffix(".ttf.import").write_text(config)
    prefix = root / ".godot/imported/NotoSansSC.ttf-original"
    pathlib.Path(str(prefix) + ".fontdata").write_bytes(b"full-cache" if full else b"subset-cache")
    pathlib.Path(str(prefix) + ".md5").write_bytes(b"full-md5" if full else b"subset-md5")
else:
    if os.environ.get("WEIGHT_REPORT"):
        from fontTools.ttLib import TTFont
        from fontTools.pens.recordingPen import RecordingPen
        variable = TTFont(font)
        axes = {axis.axisTag: [axis.minValue, axis.maxValue] for axis in variable["fvar"].axes}
        outlines = []
        for weight in (400, 600):
            pen = RecordingPen()
            variable.getGlyphSet(location={"wght": weight})[variable.getBestCmap()[ord("A")]].draw(pen)
            outlines.append(pen.value)
        pathlib.Path(os.environ["WEIGHT_REPORT"]).write_text(json.dumps({"axes": axes, "outlines": outlines, "bytes": font.stat().st_size}))
    # 模拟导出改动导入配置并留下新的子集缓存，恢复必须成组处理。
    font.with_suffix(".ttf.import").write_text("export changed the import config")
    (root / ".godot/imported/NotoSansSC.ttf-export.fontdata").write_bytes(b"export cache")
    if os.environ.get("EXPORT_FAIL") == str(number):
        sys.exit(47)
    if os.environ.get("EXPORT_ERROR") == str(number):
        print("SCRIPT ERROR: fixture export failure", file=sys.stderr)
        sys.exit(0)
    if os.environ.get("EXPORT_MISSING") == str(number):
        sys.exit(0)
    output = pathlib.Path(sys.argv[-1])
    if output.suffix == ".app":
        output.mkdir(parents=True, exist_ok=True)
        (output / "Contents/MacOS").mkdir(parents=True)
        (output / "Contents/Resources").mkdir(parents=True)
        (output / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable":"game"}))
        binary = output / "Contents/MacOS/game"
        binary.write_text("fixture app")
        binary.chmod(0o755)
        (output / "Contents/Resources/game.pck").write_bytes(b"pck")
    else:
        output.write_text("web")
        output.with_suffix(".pck").write_bytes(b"pck")
        output.with_suffix(".js").write_text("fixture js")
        output.with_suffix(".wasm").write_bytes(b"wasm")
''')
        self.env = os.environ.copy()
        self.env.update({
            "GODOT": str(self.godot),
            "TPL_DIR": str(self.root / "templates"),
            "TMPDIR": str(self.root / "scratch"),
            "PATH": str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        })

    def write_executable(self, name, body):
        path = self.root / "bin" / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)
        return path

    def run_script(self, name, **env):
        return subprocess.run(["/bin/bash", name], cwd=self.root,
                              env={**self.env, **env}, text=True, capture_output=True, timeout=30)

    def events(self):
        path = self.root / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_restored(self):
        self.assertEqual((self.root / FONT).read_bytes(), b"full-variable-font-wght-100-900")
        self.assertEqual((self.root / (str(FONT) + ".import")).read_text(), IMPORT_TEXT)
        self.assertEqual((self.root / FONTDATA).read_bytes(), b"full-cache")
        self.assertEqual((self.root / MD5).read_bytes(), b"full-md5")
        self.assertEqual(sorted(path.name for path in (self.root / ".godot/imported").iterdir()),
                         sorted((FONTDATA.name, MD5.name)))
        self.assertFalse(list((self.root / "scratch").iterdir()))
        self.assertFalse((self.root / (str(FONT) + ".orig")).exists())

    def test_both_build_entrypoints_restore_the_complete_font_group(self):
        for name in SCRIPTS:
            with self.subTest(script=name):
                result = self.run_script(name)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_restored()
        exports = [event for event in self.events() if event["kind"] == "export"]
        self.assertEqual(len(exports), 3)
        self.assertTrue(all(not event["full"] for event in exports))

    def test_subset_collects_runtime_text_but_not_development_text(self):
        (self.root / "scenes").mkdir()
        (self.root / "tests").mkdir()
        (self.root / "scenes/runtime.gd").write_text('var label = "甲"')
        (self.root / "tests/fixture.gd").write_text('var label = "龘"')
        (self.root / "tools/fixture.gd").write_text('var label = "靐"')
        script = (self.root / "bin/pyftsubset").read_text()
        script += '\npathlib.Path("subset-unicodes.txt").write_text(next(a for a in sys.argv if a.startswith("--unicodes=")))\n'
        (self.root / "bin/pyftsubset").write_text(script)
        result = self.run_script(SCRIPTS[0])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        chars = (self.root / "subset-unicodes.txt").read_text()
        self.assertIn("U+7532", chars)
        self.assertNotIn("U+9F98", chars)
        self.assertNotIn("U+9750", chars)
        self.assert_restored()

    def test_subset_failure_restores_and_stops_before_export(self):
        result = self.run_script(SCRIPTS[0], SUBSET_MODE="fail")
        self.assertEqual(result.returncode, 21, result.stdout + result.stderr)
        self.assert_restored()
        self.assertEqual([event["kind"] for event in self.events()], ["import"])

    def test_term_during_subset_restores_and_propagates_signal_status(self):
        result = self.run_script(SCRIPTS[1], SUBSET_MODE="term")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assert_restored()
        self.assertEqual([event["kind"] for event in self.events()], ["import"])

    def test_export_failure_restores_config_and_discards_export_cache(self):
        result = self.run_script(SCRIPTS[1], EXPORT_FAIL="2")
        self.assertEqual(result.returncode, 47, result.stdout + result.stderr)
        self.assert_restored()
        self.assertEqual(len([event for event in self.events() if event["kind"] == "export"]), 2)

    def test_both_entrypoints_reject_zero_exit_export_errors_and_keep_previous_app(self):
        for name in SCRIPTS:
            with self.subTest(script=name):
                previous = self.root / "build/牛马牌.app/previous"
                previous.parent.mkdir(parents=True, exist_ok=True)
                previous.write_text("previous successful build")
                events = self.root / "events.jsonl"
                events.unlink(missing_ok=True)
                result = self.run_script(name, EXPORT_ERROR="1")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("SCRIPT ERROR: fixture export failure", result.stdout + result.stderr)
                self.assertEqual(previous.read_text(), "previous successful build")
                self.assertNotIn("发布包就绪", result.stdout)
                self.assertFalse(list((self.root / "build").glob(".export-stage.*")))
                self.assert_restored()

    def test_release_rejects_missing_artifact_even_without_engine_error(self):
        result = self.run_script(SCRIPTS[1], EXPORT_MISSING="2")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("发布包就绪", result.stdout)
        self.assertFalse(list((self.root / "build").glob("牛马牌*zip")))
        self.assert_restored()

    def test_release_replaces_complete_outputs_without_stale_files(self):
        stale = self.root / "build/web/obsolete-debug.txt"
        stale.parent.mkdir(parents=True)
        stale.write_text("previous build debug data")
        old_app = self.root / "build/牛马牌.app/obsolete"
        old_app.parent.mkdir()
        old_app.write_text("old app resource")
        result = self.run_script(SCRIPTS[1])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(stale.exists())
        self.assertFalse(old_app.exists())
        with zipfile.ZipFile(self.root / "build/牛马牌_web.zip") as archive:
            self.assertIn("index.html", archive.namelist())
            self.assertIn("index.wasm", archive.namelist())
            self.assertNotIn("obsolete-debug.txt", archive.namelist())
        self.assertFalse(list((self.root / "build").glob(".export-stage.*")))
        self.assert_restored()

    def test_game_release_preserves_checked_in_source_art(self):
        source = self.root / "assets/art/app_icon.png"
        original = source.read_bytes()
        for failure in ("1", ""):
            with self.subTest(export_failure=failure):
                (self.root / "events.jsonl").unlink(missing_ok=True)
                result = self.run_script(SCRIPTS[1], EXPORT_FAIL=failure)
                self.assertEqual(result.returncode, 47 if failure else 0, result.stdout + result.stderr)
                self.assertEqual(source.read_bytes(), original)

    def start_font_transaction(self, name):
        script = '''set -e
source tools/font_subset.sh
FONT=assets/fonts/NotoSansSC.ttf
subset_font
: > "$CASE.ready"
while [ ! -f "$CASE.restore" ]; do sleep 0.02; done
restore_font
: > "$CASE.restored"
while [ ! -f "$CASE.finish" ]; do sleep 0.02; done
'''
        return subprocess.Popen(["bash", "-c", script], cwd=self.root,
                                env={**self.env, "CASE": name}, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)

    def wait_for_file(self, name):
        deadline = time.monotonic() + 8
        while not (self.root / name).exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / name).exists(), name)

    def release_transaction(self, name):
        for suffix in ("restore", "finish"):
            (self.root / (name + "." + suffix)).touch()

    def stop_transactions(self, processes):
        for name in ("A", "B"):
            self.release_transaction(name)
        for process in processes:
            try:
                process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_overlapping_transactions_wait_until_publication_finishes(self):
        processes = []
        try:
            first = self.start_font_transaction("A")
            processes.append(first)
            self.wait_for_file("A.ready")
            second = self.start_font_transaction("B")
            processes.append(second)
            time.sleep(0.2)
            self.assertFalse((self.root / "B.ready").exists(), "B 必须在备份字体前等 A")
            (self.root / "A.restore").touch()
            self.wait_for_file("A.restored")
            time.sleep(0.2)
            self.assertFalse((self.root / "B.ready").exists(), "恢复字体后、发布结束前仍持锁")
            (self.root / "A.finish").touch()
            out = first.communicate(timeout=8)[0]
            self.assertEqual(first.returncode, 0, out)
            self.wait_for_file("B.ready")
            self.release_transaction("B")
            out = second.communicate(timeout=8)[0]
            self.assertEqual(second.returncode, 0, out)
            self.assert_restored()
            self.assertTrue(all(event["full"] for event in self.events()), "两个事务都从完整字体开始")
        finally:
            self.stop_transactions(processes)

    def test_cancelled_lock_owner_restores_font_and_unblocks_waiter(self):
        processes = []
        try:
            first = self.start_font_transaction("A")
            processes.append(first)
            self.wait_for_file("A.ready")
            second = self.start_font_transaction("B")
            processes.append(second)
            first.send_signal(signal.SIGHUP)
            out = first.communicate(timeout=8)[0]
            self.assertEqual(first.returncode, 129, out)
            self.wait_for_file("B.ready")
            self.release_transaction("B")
            out = second.communicate(timeout=8)[0]
            self.assertEqual(second.returncode, 0, out)
            self.assert_restored()
        finally:
            self.stop_transactions(processes)

    def test_cancelled_waiter_does_not_release_or_change_owners_font(self):
        processes = []
        try:
            first = self.start_font_transaction("A")
            processes.append(first)
            self.wait_for_file("A.ready")
            second = self.start_font_transaction("B")
            processes.append(second)
            time.sleep(0.2)
            second.terminate()
            out = second.communicate(timeout=8)[0]
            self.assertEqual(second.returncode, 143, out)
            self.assertEqual((self.root / FONT).read_bytes(), b"subset-font")
            self.release_transaction("A")
            out = first.communicate(timeout=8)[0]
            self.assertEqual(first.returncode, 0, out)
            self.assert_restored()
        finally:
            self.stop_transactions(processes)

    def test_import_failure_is_not_ignored(self):
        result = self.run_script(SCRIPTS[0], IMPORT_FAIL="2")
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assert_restored()
        self.assertFalse(any(event["kind"] == "export" for event in self.events()))

    def test_zero_exit_with_godot_error_is_not_ignored(self):
        result = self.run_script(SCRIPTS[1], IMPORT_ERROR="2")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ERROR: fixture", result.stderr + result.stdout)
        self.assert_restored()
        self.assertFalse(any(event["kind"] == "export" for event in self.events()))

    def test_missing_fontdata_after_import_stops_export(self):
        result = self.run_script(SCRIPTS[0], IMPORT_MISSING="2")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("fontdata", result.stderr)
        self.assert_restored()
        self.assertFalse(any(event["kind"] == "export" for event in self.events()))

    def test_old_missing_cache_is_repaired_before_snapshot(self):
        (self.root / FONTDATA).unlink()
        (self.root / MD5).unlink()
        result = self.run_script(SCRIPTS[0])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_restored()
        self.assertTrue(self.events()[0]["full"])

    def test_initial_import_failure_never_subsets(self):
        result = self.run_script(SCRIPTS[0], IMPORT_FAIL="1")
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assert_restored()
        self.assertEqual(len(self.events()), 1)

    @unittest.skipUnless(shutil.which("pyftsubset") and importlib.util.find_spec("fontTools"),
                         "需要 fonttools 检验真实 variable font 子集")
    def test_real_subset_keeps_distinct_400_and_600_outlines(self):
        original = (ROOT / FONT).read_bytes()
        (self.root / FONT).write_bytes(original)
        (self.root / "bin/pyftsubset").unlink()
        (self.root / "bin/pyftsubset").symlink_to(shutil.which("pyftsubset"))
        report = self.root / "weights.json"
        result = self.run_script(SCRIPTS[0], FULL_FONT_SHA=hashlib.sha256(original).hexdigest(),
                                 WEIGHT_REPORT=str(report))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / FONT).read_bytes(), original)
        self.assertEqual((self.root / FONTDATA).read_bytes(), b"full-cache")
        self.assertEqual((self.root / (str(FONT) + ".import")).read_text(), IMPORT_TEXT)
        metrics = json.loads(report.read_text())
        self.assertEqual(metrics["axes"]["wght"], [100.0, 900.0])
        self.assertNotEqual(metrics["outlines"][0], metrics["outlines"][1])
        self.assertLess(metrics["bytes"], len(original))
        self.assertFalse(list((self.root / "scratch").iterdir()))

    def test_without_fonttools_export_uses_full_font(self):
        (self.root / "bin/pyftsubset").unlink()
        # 此场景没有字体事务；fake export 不应改动字体导入配置。
        script = self.godot.read_text().replace('font.with_suffix(".ttf.import").write_text("export changed the import config")', 'pass')
        script = script.replace('(root / ".godot/imported/NotoSansSC.ttf-export.fontdata").write_bytes(b"export cache")', 'pass')
        self.godot.write_text(script)
        result = self.run_script(SCRIPTS[0])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_restored()
        self.assertTrue(all(event["full"] for event in self.events()))


if __name__ == "__main__":
    unittest.main()
