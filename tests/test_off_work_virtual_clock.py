# SPDX-License-Identifier: AGPL-3.0-only
"""从实验脚本入口验证换座、真实规则及虚拟钟。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GODOT = shutil.which(os.environ.get("GODOT", "godot")) or "/Applications/Godot.app/Contents/MacOS/Godot"


@unittest.skipUnless(Path(GODOT).is_file(), "需要 Godot")
class OffWorkVirtualClock(unittest.TestCase):
    def setUp(self):
        self.cards = json.loads((ROOT / "data/off_work_cards.json").read_text())
        self.cards["rules"]["initial"] = {"money": 0, "groups": [{"work": 2}, {"employee": 1}]}
        self.cards["cards"]["work"]["work_seconds"] = 3600
        self.cards["rules"]["conveyor"]["interval_seconds"] = 900
        self.profile = {"think_seconds": 30, "decision_budget_ms": 12, "evaluation_max_seconds": 7200}

    def simulate(self, a, b, limit):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            request = {"cards": self.cards, "a": a, "b": b, "pairs": 1, "seed": 42, "max_seconds": limit}
            (folder / "request.json").write_text(json.dumps(request))
            proc = subprocess.run([
                GODOT, "--headless", "--path", str(ROOT), "--script", "res://tools/balance/off_work_run.gd",
                "--", f"--request={folder / 'request.json'}", f"--output={folder / 'result.json'}",
            ], timeout=20, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads((folder / "result.json").read_text())
            progress = json.loads((folder / "progress.json").read_text())
            self.assertEqual(progress["completed"], result["games"])
            self.assertEqual(progress["summary"]["balance_metrics"], result["balance_metrics"])
            self.assertEqual(progress["summary"]["simulated_seconds"], result["simulated_seconds"])
            self.assertLessEqual(progress["summary"]["elapsed_seconds"], result["elapsed_seconds"])
            self.assertEqual(progress["summary"]["decision_stats"], result["decision_stats"])
            self.assertEqual(progress["decision_samples"], result["decision_samples"])
            self.assertNotIn("current_match", progress["summary"])
            self.assertRegex(result["simulator_fingerprint"], r"^[0-9a-f]{64}$")
            return result

    def test_four_virtual_hours_settle_at_the_deadline_and_repeat(self):
        late = {**self.profile, "first_action_seconds": 4000}
        result = self.simulate(self.profile, late, 7200)
        self.assertEqual(result["simulated_seconds"], 14400)
        self.assertEqual([(m["a_seat"], m["seed"], m["winner"]) for m in result["matches"]],
                         [(0, 42, "a"), (1, 42, "a")])
        self.assertEqual([m["first_seat"] for m in result["matches"]], [0, 1])
        self.assertEqual(result["balance_metrics"]["first_player_win_rate"]["value"], 100)
        self.assertEqual(result["flow"]["work_done"], 4)
        self.assertEqual(result["balance_metrics"]["mean_finish_seconds"]["value"], 7200)
        for side in ["a", "b"]:
            for stats in result["decision_stats"][side]:
                self.assertGreater(stats["count"], 0)
                self.assertEqual(stats["count"], sum(stats["action_counts"].values()))
                self.assertLessEqual(stats["sample_count"], 15)
        self.assertEqual({(s["side"], s["seat"]) for s in result["decision_samples"]},
                         {("a", 0), ("b", 1), ("a", 1), ("b", 0)})
        for sample in result["decision_samples"]:
            self.assertGreater(sample["budget_ms"], 0)
            self.assertEqual(sample["over_budget"], sample["elapsed_us"] > sample["budget_ms"] * 1000)
            self.assertTrue(sample["reason"])
            self.assertLessEqual(len(sample["candidates"]), 5)
        repeat = self.simulate(self.profile, late, 7200)
        for key in result:
            if key not in ("elapsed_seconds", "decision_stats", "decision_samples"):
                self.assertEqual(repeat[key], result[key], key)
        def uninterrupted(run):
            return all(not s["cutoffs"] and not s["over_budget"]
                       for seats in run["decision_stats"].values() for s in seats)
        if uninterrupted(result) and uninterrupted(repeat):
            for side in ("a", "b"):
                for seat in (0, 1):
                    self.assertEqual(result["decision_stats"][side][seat]["action_counts"],
                                     repeat["decision_stats"][side][seat]["action_counts"])
            def choices(run):
                return [{key:value for key,value in sample.items() if key != "elapsed_us"}
                        for sample in run["decision_samples"]]
            self.assertEqual(choices(result), choices(repeat))

    def test_slow_work_and_market_settle_at_the_same_instant(self):
        self.cards["rules"]["initial"]["groups"] = [{"employee": 1, "work": 2}]
        self.cards["cards"]["work"]["work_seconds"] = 2000000
        self.cards["rules"]["conveyor"]["interval_seconds"] = 4000000
        disabled = {"enabled": False}
        result = self.simulate(disabled, disabled, 10000000)
        self.assertEqual(result["draws"], 2)
        self.assertEqual(result["simulated_seconds"], 8000000)
        self.assertEqual(result["flow"]["work_done"], 8)
        openings = self.cards["rules"]["conveyor"]["slots"] * 2
        self.assertEqual(sum(result["market_offers"].values()), openings + 2)
        self.assertEqual([m["first_seat"] for m in result["matches"]], [-1, -1])
        self.assertIsNone(result["balance_metrics"]["first_player_win_rate"]["value"])

    def test_first_opportunity_includes_wait(self):
        self.cards["rules"]["initial"]["groups"] = [{"work":1, "employee":1}]
        self.cards["cards"]["work"]["work_seconds"] = 1
        result = self.simulate(self.profile, {**self.profile, "first_action_seconds":2}, 3)
        self.assertEqual(result["draws"], 2)
        self.assertEqual([m["first_seat"] for m in result["matches"]], [0, 1])
        self.assertTrue(all(s["kind"] == "wait" for s in result["decision_samples"]))
        self.assertEqual(result["balance_metrics"]["first_player_win_rate"],
                         {"value":0, "numerator":0, "denominator":2})
        cards = result["balance_metrics"]["card_acquisitions"]
        self.assertEqual(cards["total"], 0)
        self.assertTrue(all(row["percentage"] is None for row in cards["distribution"]))

    def test_coffee_batches_and_card_quantities_follow_real_events(self):
        self.cards["rules"]["initial"]["groups"] = [{"work":2}, {"leader":2, "slack":1}]
        self.cards["rules"]["slack"].update(seconds=5, coffee_per_person=3)
        disabled = {"enabled":False}
        result = self.simulate(disabled, disabled, 10)
        for match in result["matches"]:
            self.assertEqual((match["tool_generations"], match["acquisitions"]), (4, {"coffee":24}))
        metrics = result["balance_metrics"]
        self.assertEqual(metrics["version"], 2)
        self.assertEqual(metrics["tool_generations_per_minute"]["value"], 24)
        distribution = metrics["card_acquisitions"]
        self.assertEqual(distribution["total"], 48)
        rows = {r["id"]: r for r in distribution["distribution"]}
        self.assertEqual(set(rows), set(self.cards["cards"]) - {"work","money"})
        self.assertEqual((rows["coffee"]["count"], rows["coffee"]["percentage"]), (48, 100))
        self.assertEqual(rows["leader"]["count"], 0)

    def test_multicup_promotion_counts_one_upgrade_and_one_promoted_card(self):
        self.cards["rules"]["initial"]["groups"] = [{"work":2}, {"workaholic":1, "coffee":4}]
        disabled = {"enabled":False}
        result = self.simulate(disabled, disabled, 5)
        for match in result["matches"]:
            self.assertEqual((match["upgrades"], match["tool_generations"], match["acquisitions"]),
                             (2, 0, {"work_emperor":2}))
        self.assertEqual(result["balance_metrics"]["upgrades_per_minute"]["value"], 24)

    def test_each_side_reports_its_resolved_budget(self):
        relative = {"think_seconds": 2.8, "decision_budget_ratio": .7}
        fixed = {"think_seconds": .2, "decision_budget_ms": 7}
        result = self.simulate(relative, fixed, .3)
        self.assertNotIn("decision_budget_ms", result["profiles"]["a"])
        self.assertNotIn("decision_budget_ratio", result["profiles"]["b"])
        for side, expected in [("a", 1960), ("b", 7)]:
            for stats in result["decision_stats"][side]:
                self.assertEqual(stats["budget_ms"], expected)
                self.assertLessEqual(stats["searched"], stats["count"])
            samples = [s for s in result["decision_samples"] if s["side"] == side]
            self.assertTrue(samples)
            self.assertTrue(all(s["budget_ms"] == expected for s in samples))
            for sample in samples:
                self.assertGreaterEqual(sample["search_nodes"], sample["search_depth"])
                if sample["search_depth"] == 0:
                    self.assertFalse(sample["root_complete"])
                    # A completed root prefix may publish one usable command
                    # before every root candidate has been evaluated.
                    self.assertLessEqual(len(sample["principal_variation"]), 1)
                else:
                    self.assertTrue(sample["root_complete"])
                    self.assertLessEqual(len(sample["principal_variation"]), sample["search_depth"])

    def test_shorter_than_epsilon_timeout_with_no_bot_deadline(self):
        disabled = {"enabled": False}
        limit = self.cards["rules"]["simulation"]["epsilon"] / 2
        result = self.simulate(disabled, disabled, limit)
        self.assertEqual(result["simulated_seconds"], 2 * limit)
        self.assertEqual(result["timeouts"], 2)
        self.assertEqual(result["flow"]["work_done"], 0)
        self.assertIsNone(result["balance_metrics"]["mean_finish_seconds"]["value"])


if __name__ == "__main__":
    unittest.main()
