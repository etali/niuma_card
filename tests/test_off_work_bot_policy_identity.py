"""Compare policies across real JSON transport without rounding runtime data."""
import copy
from http.server import BaseHTTPRequestHandler
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.balance.off_work_workbench import OffWorkWorkbench, ConfigConflict, bot_policy_signature

GODOT = shutil.which(os.environ.get("GODOT", "godot"))


class PolicyIdentity(unittest.TestCase):
    def test_numerical_noise_and_meaningful_execution_changes(self):
        policy = {"think_seconds": 6.0, "decision_budget_ratio": 700 / 6000}
        before = copy.deepcopy(policy)
        transported = {**policy, "decision_budget_ratio": math.nextafter(policy["decision_budget_ratio"], math.inf)}
        self.assertEqual(bot_policy_signature(policy), bot_policy_signature(transported))
        for changed in ({**policy, "think_seconds": 6.000001},
                        {**policy, "decision_budget_ratio": policy["decision_budget_ratio"] + .001}):
            self.assertNotEqual(bot_policy_signature(policy), bot_policy_signature(changed))
        # Decimal signature rounding alone would collapse these two values,
        # although the actual engine grants 499 ms versus 500 ms.
        self.assertNotEqual(bot_policy_signature({"think_seconds": 1., "decision_budget_ratio": .4999999999899994}),
                            bot_policy_signature({"think_seconds": 1., "decision_budget_ratio": .49999999999}))
        # A long imported clock magnifies a ratio ULP beyond a microsecond.
        long = {"think_seconds": 1e10, "decision_budget_ratio": .5}
        self.assertNotEqual(bot_policy_signature(long),
                            bot_policy_signature({**long, "decision_budget_ratio": math.nextafter(.5, math.inf)}))
        self.assertEqual(policy, before)

    @unittest.skipUnless(GODOT, "需要 Godot")
    def test_all_101_strengths_survive_real_engine_json_roundtrip(self):
        script = '''extends SceneTree
const Preferences=preload("res://engine/off_work_bot_preferences.gd")
func _initialize():
\tvar config:=OffWorkConfig.new()
\tvar rows:=[]
\tfor index in 101:
\t\tvar policy:=Preferences.strength_parameters(index/100.0,config.rules.bot,config.bot_preferences)
\t\tvar before:=JSON.stringify(policy,"",true,true)
\t\tvar parsed:Dictionary=JSON.parse_string(before)
\t\trows.append({"before":before,"after":JSON.stringify(parsed,"",true,true),"budget_before":OffWorkConfig.decision_budget_ms(policy),"budget_after":OffWorkConfig.decision_budget_ms(parsed)})
\tvar file:=FileAccess.open(OS.get_environment("IDENTITY_OUTPUT"),FileAccess.WRITE)
\tfile.store_string(JSON.stringify({"rows":rows,"fractional_budget":OffWorkConfig.decision_budget_ms({"think_seconds":1.0,"decision_budget_ratio":0.4999999})},"",true,true))
\tquit()
'''
        with tempfile.TemporaryDirectory(prefix="off-work-identity-") as folder:
            source, output = Path(folder) / "probe.gd", Path(folder) / "result.json"
            source.write_text(script)
            process = subprocess.run([GODOT, "--headless", "--path", str(ROOT), "--script", str(source)],
                                     env=dict(os.environ, IDENTITY_OUTPUT=str(output)), capture_output=True, text=True, timeout=20)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            self.assertNotIn("SCRIPT ERROR", process.stdout + process.stderr)
            result = json.loads(output.read_text())
            rows = result["rows"]
        self.assertEqual(len(rows), 101)
        self.assertEqual(result["fractional_budget"], 499)
        # JSON parsing previously moved this 21.6 s profile from 292 to 291 ms.
        self.assertEqual(rows[5]["budget_before"], 292)
        self.assertEqual(rows[5]["budget_after"], 292)
        changed = 0
        for index, row in enumerate(rows):
            before, after = json.loads(row["before"]), json.loads(row["after"])
            changed += before != after
            with self.subTest(strength=index / 100):
                self.assertEqual(bot_policy_signature(before), bot_policy_signature(after))
                self.assertEqual(row["budget_before"], row["budget_after"])
        # This is a real transport regression, not 101 already-identical pairs.
        self.assertGreater(changed, 0)

    @unittest.skipUnless(GODOT, "需要 Godot")
    def test_saved_name_and_original_precision_survive_transport(self):
        with tempfile.TemporaryDirectory() as folder, OffWorkWorkbench(
                GODOT, 0, handler=BaseHTTPRequestHandler, store=Path(folder)) as lab:
            policy = {key: value for key, value in lab.configuration()["bot"]["bot"].items() if key != "owner"}
            policy["decision_budget_ratio"] = .12345678901234566
            record = lab._save_candidates(
                [{"slot": "config", "kind": "bot", "name": "精确策略", "data": policy}],
                "manual", {}, 12, manual=True)["config"]
            path = Path(folder) / "configs" / (record["id"] + ".json")
            original = path.read_bytes()
            self.assertEqual(record["data"]["decision_budget_ratio"], policy["decision_budget_ratio"])
            transported = {**policy, "decision_budget_ratio": math.nextafter(policy["decision_budget_ratio"], math.inf)}
            with self.assertRaises(ConfigConflict) as unchanged:
                lab.save_config("bot", {"name": "精确策略", "data": transported})
            self.assertEqual(unchanged.exception.payload["code"], "unchanged_config")
            self.assertEqual(unchanged.exception.payload["existing"]["id"], record["id"])
            changed = {**policy, "decision_budget_ratio": policy["decision_budget_ratio"] + .001}
            with self.assertRaises(ConfigConflict) as conflict:
                lab.save_config("bot", {"name": "精确策略", "data": changed})
            self.assertEqual(conflict.exception.payload["code"], "name_conflict")
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(len(lab.library), 1)

    @unittest.skipUnless(GODOT, "需要 Godot")
    def test_batch_reuses_one_snapshot_without_rewriting_either_input(self):
        with tempfile.TemporaryDirectory() as folder, OffWorkWorkbench(
                GODOT, 0, handler=BaseHTTPRequestHandler, store=Path(folder)) as lab:
            policy = {key: value for key, value in lab.configuration()["bot"]["bot"].items() if key != "owner"}
            policy["decision_budget_ratio"] = .12345678901234566
            other = {**policy, "decision_budget_ratio": math.nextafter(policy["decision_budget_ratio"], math.inf)}
            candidates = [{"slot": "a", "kind": "bot", "name": "同一策略", "data": policy},
                          {"slot": "b", "kind": "bot", "name": "同一策略", "data": other}]
            original = copy.deepcopy(candidates)
            saved = lab._save_candidates(candidates, "experiment", {}, 12)
            self.assertEqual(saved["a"]["id"], saved["b"]["id"])
            self.assertEqual(len(lab.library), 1)
            self.assertEqual(saved["a"]["data"]["decision_budget_ratio"], policy["decision_budget_ratio"])
            self.assertEqual(candidates, original)
            # The in-process content lookup retains the immutable original ID.
            key = saved["a"]["id"]
            self.assertEqual(lab._content_id("bot", other), key)


if __name__ == "__main__":
    unittest.main()
