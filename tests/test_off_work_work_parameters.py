# SPDX-License-Identifier: AGPL-3.0-only
"""Opening work, shared clocks and recruitment cross persistence/launch boundaries."""
import copy
import hashlib
from http.server import BaseHTTPRequestHandler
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.balance import off_work_workbench as workbench
from tools.balance.storage import read_json

GODOT = shutil.which(os.environ.get("GODOT", "godot"))


@unittest.skipUnless(GODOT, "需要 Godot")
class WorkParameters(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="off-work-work-parameters-")
        self.addCleanup(folder.cleanup)
        self.store = Path(folder.name)
        runtime = mock.patch('tools.balance.playtest_launcher.macos_executable',
                             return_value=self.store / '牛马牌.app/Contents/MacOS/牛马牌')
        runtime.start()
        self.addCleanup(runtime.stop)
        self.lab = workbench.OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=self.store)
        self.addCleanup(self.lab.server_close)
        self.addCleanup(self.lab.close_jobs)
        self.config = self.lab.configuration()

    def configured_cards(self):
        cards = copy.deepcopy(self.config["cards"])
        cards["cards"]["work"]["work_seconds"] = 7.5
        cards["rules"]["initial"]["groups"][0]["work"] = 73
        cards["rules"]["recruitment"].update(cost_per_employee=7, seconds=3.5)
        return cards

    def assert_parameters(self, cards, seconds=7.5):
        self.assertEqual(cards["cards"]["work"]["work_seconds"], seconds)
        self.assertEqual(sum(group.get("work", 0) for group in cards["rules"]["initial"]["groups"]), 73)
        self.assertTrue(all("work_seconds" not in role for role in cards["roles"].values()))
        self.assertEqual(cards["rules"]["recruitment"], {"cost_per_employee": 7, "seconds": 3.5})

    def test_saved_evaluation_and_playtest_use_one_parameter_document(self):
        cards = self.configured_cards()
        saved = self.lab.save_config("cards", {"name": "统一工时与招聘", "data": cards})
        self.assert_parameters(saved["data"])
        self.assertEqual(self.lab.library_info(saved["id"])["data"], saved["data"])
        policy = {**self.config["default_profiles"]["balance"]["a"], "first_action_seconds": 10}
        for kind in ("balance", "bot"):
            result = self.lab.start_job({"kind": kind, "cards": cards, "card_name": "统一工时与招聘",
                                         "a": policy, "b": policy, "a_name": "延后行动", "b_name": "延后行动",
                                         "pairs": 1, "seed": 71403, "max_seconds": 0.01})
            request = read_json(self.store / result["id"] / "request.json")
            self.assert_parameters(request["cards"])
            self.assertEqual(request["cards"], saved["data"])
            deadline = time.monotonic() + 15
            while self.lab.job_info(result["id"])["status"] == "running" and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual(self.lab.job_info(result["id"])["status"], "done")
            report = read_json(self.store / result["id"] / "result.json")
            self.assertEqual(len(report["matches"]), 2)
            for match in report["matches"]:
                self.assertEqual((match["a_work"], match["b_work"]), (73, 73),
                                 "each real engine seat receives the edited opening workload before acting")
                self.assertEqual(match["first_seat"], -1)
        launches = []
        actual_popen = subprocess.Popen

        def spawn(command, *args, **kwargs):
            if "--off-work-playtest" not in command:
                return actual_popen(command, *args, **kwargs)
            path = Path(next(arg.split("=", 1)[1] for arg in command if arg.startswith("--cards-config=")))
            launches.append(read_json(path))
            marker = "WORK_PLAYTEST_READY " + hashlib.sha256(path.read_bytes()).hexdigest()
            kwargs["stdout"].write((marker + "\n").encode())
            kwargs["stdout"].flush()
            return mock.Mock(pid=123456, poll=mock.Mock(return_value=None), wait=mock.Mock(return_value=0))

        with mock.patch.object(workbench.subprocess, "Popen", side_effect=spawn):
            self.assertTrue(self.lab.playtest({"cards": cards})["ok"])
        self.assertEqual(launches, [saved["data"]])

    def test_legacy_personnel_times_migrate_without_reappearing_in_saved_cards(self):
        for use_shared in (False, True):
            legacy = self.configured_cards()
            for role in legacy["roles"].values():
                role["work_seconds"] = 2
            legacy["roles"]["employee"]["work_seconds"] = 12.5
            if not use_shared:
                del legacy["cards"]["work"]["work_seconds"]
            original = copy.deepcopy(legacy)
            expected = 7.5 if use_shared else 12.5
            checked = self.lab.check_request({"cards": legacy, "validate_only": True})["cards"]
            self.assert_parameters(checked, expected)
            saved = self.lab.save_config("cards", {"name": "旧工时迁移" + str(use_shared), "data": legacy})
            self.assertEqual(saved["data"], checked)
            self.assertEqual(legacy, original)

    def test_invalid_work_and_recruitment_settings_do_not_persist(self):
        for field, values in (("work_seconds", [0, -1, float("nan"), float("inf")]),
                              ("cost_per_employee", [0, 1.5, 4]), ("seconds", [0, -1])):
            for value in values:
                with self.subTest(field=field, value=value):
                    cards = self.configured_cards()
                    target = cards["cards"]["work"] if field == "work_seconds" else cards["rules"]["recruitment"]
                    target[field] = value
                    with self.assertRaises(ValueError):
                        self.lab.save_config("cards", {"name": "无效参数", "data": cards})
                    self.assertEqual(self.lab.library, {})
                    self.assertFalse(list((self.store / "configs").glob("*.json")))

    def test_invalid_opening_work_does_not_persist(self):
        for amount in (0, -1, 1.5, float("nan"), float("inf"), 4096):
            with self.subTest(amount=amount):
                cards = self.configured_cards()
                cards["rules"]["initial"]["groups"][0]["work"] = amount
                with self.assertRaises(ValueError):
                    self.lab.save_config("cards", {"name": "无效起始工作", "data": cards})
                self.assertEqual(self.lab.library, {})
                self.assertFalse(list((self.store / "configs").glob("*.json")))


if __name__ == "__main__":
    unittest.main()
