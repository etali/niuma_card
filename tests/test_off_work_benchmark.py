# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
from pathlib import Path
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("benchmark", TOOLS / "off_work_benchmark_bot.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BenchmarkTests(unittest.TestCase):
    def test_legacy_config_and_planner_are_separate_but_rules_are_shared(self):
        source = '''class_name OffWorkBot
extends RefCounted
const Planner = preload("res://engine/off_work_bot_planner.gd")
func test(world: OffWorkState):
    return OffWorkConfig.merge_bot_policy({}, {})
'''
        isolated = module.legacy_source("off_work_bot.gd", source)
        self.assertNotIn("class_name", isolated)
        self.assertIn('preload("res://benchmark_legacy/engine/off_work_bot_planner.gd")', isolated)
        self.assertIn("LegacyConfig.merge_bot_policy", isolated)
        self.assertIn("world: OffWorkState", isolated)
        self.assertNotIn("OffWorkConfig.", isolated)

    def test_unexpected_global_bot_reference_cannot_silently_use_new_code(self):
        with self.assertRaises(ValueError):
            module.legacy_source("off_work_bot_tree.gd", "extends RefCounted\nvar bot = OffWorkBot.new()\n")

    def test_legacy_constructor_does_not_read_new_compatibility_defaults(self):
        source = "extends RefCounted\nvar policy = state.config.rules.bot if policy.is_empty() else state.config.bot_algorithm_defaults.merged(policy, true)\n"
        isolated = module.legacy_source("off_work_bot.gd", source)
        self.assertNotIn("state.config.rules.bot", isolated)
        self.assertNotIn("state.config.bot_algorithm_defaults", isolated)
        self.assertIn("Config.new().bot_algorithm_defaults", isolated)

    def test_legacy_internal_search_base_is_also_frozen(self):
        source = "extends RefCounted\nvar policy = OffWorkConfig.merge_bot_policy(game.config.rules.bot, settings)\n"
        isolated = module.legacy_source("off_work_bot_planner.gd", source)
        self.assertNotIn("game.config.rules.bot", isolated)
        self.assertIn("LegacyConfig.merge_bot_policy(_legacy_base_policy, settings)", isolated)
        self.assertIn("static var _legacy_base_policy: Dictionary = LegacyConfig.new().rules.bot", isolated)

    def test_same_cadence_only_changes_new_action_interval(self):
        definition = {"current_profiles":{"max":{"think_seconds":.9,"decision_budget_ratio":.8,"search_max_depth":6}},
                      "legacy_max":{"think_seconds":2.0,"desired_people":10,"buy_chance":.9,"material_batch_limit":16}}
        current = module.player("current:max:2s", definition)
        old = module.player("legacy:max", definition)
        self.assertEqual(current["policy"], {"think_seconds":2.0,"decision_budget_ratio":.8,"search_max_depth":6})
        self.assertEqual(old["policy"], definition["legacy_max"])
        self.assertEqual(definition["current_profiles"]["max"]["think_seconds"], .9)

    def test_actual_policy_or_seat_mismatch_is_rejected(self):
        request = {"a":{"policy":{"think_seconds":2.0}}, "b":{"policy":{"think_seconds":2.0}}, "seed":19,"scenario":"default"}
        definition = {"simulator_fingerprint":"frozen", "godot_version":"test"}
        result = {**definition, "profiles":{key:request[key] for key in ("a","b")}, "matches":[
            {"seed":19,"a_seat":seat,"scenario":"default","actual_policies":{"a":{"think_seconds":2.0},"b":{"think_seconds":2.0}}} for seat in (0,1)]}
        module.validate_report(result, request, definition)
        result["matches"][1]["actual_policies"]["b"]["think_seconds"] = 2.8
        with self.assertRaises(ValueError): module.validate_report(result, request, definition)

    def test_acceptance_keeps_existing_minimum_and_timeout_gate(self):
        reports = [{"matches":[{"winner":"a","a_work":0,"b_work":10,"seed":seed,"a_seat":seat} for seat in (0,1)]} for seed in range(1,13)]
        self.assertTrue(module.summarize(reports)["passed"])
        self.assertFalse(module.summarize(reports[:2], minimum_pairs=1)["passed"])
        reports[-1]["matches"][-1]["winner"] = "timeout"
        self.assertFalse(module.summarize(reports)["passed"])

    def test_race_catalogue_contains_only_normal_openings(self):
        self.assertTrue(all(case[2] == "default" for case in module.COMPARISONS.values()))
        self.assertEqual(set(module.CAPABILITIES), {"production", "overtime", "recovery", "outsource"})
        self.assertEqual(module.CAPABILITIES["production"], ("current:max", "script:production", "production"))
        self.assertEqual(module.COMPARISONS["script-growth"][1], "script:growth")

    def test_capability_goal_and_reference_timing_are_both_required(self):
        trials = [{"seed":71,"side":side,"seat":seat,"achieved":True,"seconds":10,
                   "observed":{"remaining_work":0},"decision_stats":{"apply_failures":0,"over_budget":0}}
                  for seat in (0,1) for side in ("a","b")]
        self.assertTrue(module.summarize_capabilities([{"trials":trials}])["passed"])
        trials[0]["seconds"] = 12
        self.assertFalse(module.summarize_capabilities([{"trials":trials}])["passed"])
        trials[0]["seconds"] = 10
        trials[0]["achieved"] = False
        self.assertFalse(module.summarize_capabilities([{"trials":trials}])["passed"])
        trials[0]["achieved"] = True
        trials[1]["achieved"] = False
        self.assertFalse(module.summarize_capabilities([{"trials":trials}])["passed"])
        self.assertNotIn("higher_score_rate", module.summarize_capabilities([{"trials":trials}]))


if __name__ == "__main__": unittest.main()
