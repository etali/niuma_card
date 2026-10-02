# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""当前配色初筛的输入契约与退出状态。"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
SCRIPT = ROOT / "tools" / "check_distinct.py"
SPEC = importlib.util.spec_from_file_location("check_distinct", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class CheckDistinctTests(unittest.TestCase):
    def write_config(self, directory, value):
        path = Path(directory) / "palette.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_default_comes_from_current_ui_json(self):
        palette = json.loads((ROOT / "data" / "ui.json").read_text(encoding="utf-8"))
        expected = {
            slot: tuple(int(entry["face"][i:i + 2], 16) for i in (1, 3, 5))
            for slot, entry in palette["palette"]["plates"].items()
            if not slot.startswith("_")
        }
        self.assertEqual(CHECK.load_faces(), expected)

    def test_both_override_shapes_merge_missing_keys_and_only_use_face(self):
        baseline = CHECK.load_faces()
        override = {"plates": {"plate_cash": {"face": "#010203"},
                               "plate_user": {"band": "not-analyzed"}}}
        with tempfile.TemporaryDirectory() as directory:
            for document in (override, {"palette": override, "defaults": {}}):
                with self.subTest(document=document):
                    path = self.write_config(directory, document)
                    expected = dict(baseline, plate_cash=(1, 2, 3))
                    self.assertEqual(CHECK.load_faces(path), expected)

    def test_risks_are_advisory_even_from_another_working_directory(self):
        baseline = CHECK.load_faces()
        override = {"plates": {slot: {"face": "#123456"} for slot in baseline}}
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_config(directory, override)
            result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(path)],
                                    cwd=directory, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(CHECK.NOTICE, result.stdout)
        count = len(baseline) * (len(baseline) - 1) // 2
        self.assertIn(f"提示 {count} 组风险", result.stdout)

    def test_invalid_input_exits_one(self):
        invalid_values = [[], {"palette": None}, {"plates": []},
                          {"plates": {"plate_cash": None}},
                          {"plates": {"plate_cash": {"face": "bad"}}}]
        with tempfile.TemporaryDirectory() as directory:
            for value in invalid_values:
                with self.subTest(value=value):
                    path = self.write_config(directory, value)
                    result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(path)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("输入错误", result.stderr)
            path.write_text("{", encoding="utf-8")
            self.assertRaises(CHECK.InputError, CHECK.load_faces, path)
            self.assertRaises(CHECK.InputError, CHECK.load_faces, path.with_name("missing.json"))

    def test_hue_wrap_and_any_sufficient_difference_passes_threshold(self):
        self.assertEqual(CHECK.hue_dist(359, 1), 2)
        self.assertEqual(CHECK.risk_pairs({"red": (255, 0, 0), "green": (0, 255, 0)}), [])
        self.assertEqual(CHECK.risk_pairs({"red": (255, 0, 0), "pink": (255, 128, 128)}), [])
        self.assertEqual(CHECK.risk_pairs({"red": (255, 0, 0), "dark": (128, 0, 0)}), [])
        self.assertEqual(len(CHECK.risk_pairs({"a": (255, 0, 0), "b": (255, 0, 0)})), 1)


if __name__ == "__main__":
    unittest.main()
