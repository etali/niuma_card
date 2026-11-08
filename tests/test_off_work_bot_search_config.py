# SPDX-License-Identifier: AGPL-3.0-only
"""真实实验入口的搜索配置与历史预算兼容。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GODOT = shutil.which(os.environ.get("GODOT", "godot"))
SEARCH_DEFAULTS = {"search_max_depth": 4, "search_root_width": 6, "search_reply_width": 3}


@unittest.skipUnless(GODOT, "需要 Godot")
class OffWorkBotSearchConfig(unittest.TestCase):
    def setUp(self):
        self.cards = json.loads((ROOT / "data/off_work_cards.json").read_text())
        self.policy = json.loads((ROOT / "data/off_work_bot.json").read_text())["bot"]
        self.policy.pop("owner")

    def profiles(self, a, b, bot=None):
        with tempfile.TemporaryDirectory(prefix="work-search-config-") as folder:
            request, result = Path(folder) / "request.json", Path(folder) / "result.json"
            payload = {"cards": self.cards, "a": a, "b": b, "profiles_only": True}
            if bot is not None:
                payload["bot"] = bot
            request.write_text(json.dumps(payload))
            process = subprocess.run([
                GODOT, "--headless", "--path", str(ROOT), "--script", "res://tools/balance/off_work_run.gd",
                "--", f"--request={request}", f"--output={result}",
            ], capture_output=True, text=True, timeout=15)
            self.assertTrue(result.exists(), process.stdout + process.stderr)
            return process.returncode, json.loads(result.read_text())

    def test_pre_search_pre_budget_complete_profile_retains_twelve_ms(self):
        old = {key: value for key, value in self.policy.items()
               if key not in SEARCH_DEFAULTS and key != "decision_budget_ratio"}
        status, result = self.profiles(old, {})
        self.assertEqual(status, 0, result)
        archived, partial = result["profiles"]["a"], result["profiles"]["b"]
        self.assertEqual(archived["decision_budget_ms"], 12)
        self.assertNotIn("decision_budget_ratio", archived)
        self.assertEqual(partial["decision_budget_ratio"], self.policy["decision_budget_ratio"])
        self.assertNotIn("decision_budget_ms", partial)
        for policy in (archived, partial):
            self.assertEqual({key: policy[key] for key in SEARCH_DEFAULTS}, SEARCH_DEFAULTS)

    def test_search_overrides_preserve_fixed_budget(self):
        status, result = self.profiles(
            {"decision_budget_ms": 7, "search_max_depth": 5, "search_root_width": 8, "search_reply_width": 6},
            {"search_max_depth": 1},
        )
        self.assertEqual(status, 0, result)
        fixed = result["profiles"]["a"]
        self.assertEqual([fixed[key] for key in SEARCH_DEFAULTS], [5, 8, 6])
        self.assertEqual(fixed["decision_budget_ms"], 7)
        self.assertNotIn("decision_budget_ratio", fixed)
        self.assertEqual(result["profiles"]["b"]["search_max_depth"], 1)
        self.assertEqual(result["profiles"]["b"]["decision_budget_ratio"], self.policy["decision_budget_ratio"])

    def test_experiment_entry_rejects_search_values_outside_bounds(self):
        status, result = self.profiles({"search_max_depth": 17}, {})
        self.assertNotEqual(status, 0)
        self.assertIn("search_max_depth", result["error"])

    def test_algorithm_overrides_reach_actual_experiment_profiles(self):
        overrides = {"evaluation_max_seconds": 3600, "decision_publish_reserve_ratio": .3,
                     "decision_publish_reserve_us": 2000, "live_snapshot_card_limit": 64,
                     "live_snapshot_group_limit": 32, "live_fallback_budget_us": 1700}
        status, result = self.profiles(overrides, {})
        self.assertEqual(status, 0, result)
        for key, value in overrides.items():
            self.assertEqual(result['profiles']['a'][key], value)
            self.assertEqual(result['profiles']['b'][key], self.policy[key])

    def test_archived_policy_keeps_algorithm_defaults_but_partial_cli_uses_current(self):
        document = json.loads((ROOT / 'data/off_work_bot.json').read_text())
        old = {key: value for key, value in self.policy.items()
               if key not in document['compatibility']['algorithm_defaults'] and key not in SEARCH_DEFAULTS}
        document['bot']['live_snapshot_card_limit'] = 64
        document['bot']['evaluation_max_seconds'] = 3600
        document['bot']['search_max_depth'] = 9
        status, result = self.profiles(old, {}, document)
        self.assertEqual(status, 0, result)
        self.assertEqual(result['profiles']['a']['live_snapshot_card_limit'], 2048)
        self.assertEqual(result['profiles']['a']['evaluation_max_seconds'], 1800)
        self.assertEqual(result['profiles']['a']['search_max_depth'], 4)
        self.assertEqual(result['profiles']['b']['live_snapshot_card_limit'], 64)
        self.assertEqual(result['profiles']['b']['evaluation_max_seconds'], 3600)
        self.assertEqual(result['profiles']['b']['search_max_depth'], 9)

    def test_invalid_algorithm_override_is_rejected_by_experiment(self):
        status, result = self.profiles({'evaluation_max_seconds': 0}, {})
        self.assertNotEqual(status, 0)
        self.assertIn('evaluation_max_seconds', result['error'])


    def test_obsolete_heuristics_cannot_be_reintroduced_as_live_overrides(self):
        for key, value in {"buy_chance": 1, "desired_people": 20, "material_batch_limit": 64,
                           "purchase_priority": ["employee"], "planner_cash_value_cap": .4}.items():
            with self.subTest(key=key):
                status, result = self.profiles({key: value}, {})
                self.assertNotEqual(status, 0)
                self.assertIn(key, result["error"])

if __name__ == "__main__":
    unittest.main()
