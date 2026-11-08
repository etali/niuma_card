# SPDX-License-Identifier: AGPL-3.0-only
"""Card-weight persistence and launch boundaries through the real workbench/engine."""
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
class OffWorkCardWeights(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="off-work-card-weights-")
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.runtime = self.folder / "牛马牌.app/Contents/MacOS/牛马牌"
        runtime = mock.patch('tools.balance.playtest_launcher.macos_executable', return_value=self.runtime)
        runtime.start()
        self.addCleanup(runtime.stop)
        self.store = self.folder / "store"
        environment = mock.patch.dict(os.environ, {
            "CARD_DATA_DIR": str(self.folder / "player-data"),
            "WORK_DATA_DIR": str(self.folder / "player-data" / "off_work"),
            "WORK_UI_TEST": "1",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.lab = workbench.OffWorkWorkbench(
            GODOT, 0, handler=BaseHTTPRequestHandler, store=self.store)
        self.addCleanup(self.lab.server_close)
        self.addCleanup(self.lab.close_jobs)
        self.config = self.lab.configuration()

    def cards(self, **weights):
        cards = copy.deepcopy(self.config["cards"])
        cards["rules"]["conveyor"]["pool"] = {
            name: weights.get(name, 0)
            for name, card in cards["cards"].items() if card["purchasable"]
        }
        return cards

    def request(self, cards, kind="balance"):
        policy = copy.deepcopy(self.config["default_profiles"]["balance"]["a"])
        # Execute the real simulator and opening draw, without a timed BOT search.
        policy["first_action_seconds"] = 10
        return {"kind": kind, "cards": cards, "a": policy, "b": policy,
                "card_name": "权重试验卡表", "a_name": "稍后行动", "b_name": "稍后行动",
                "pairs": 1, "seed": 67103, "max_seconds": 0.01}

    def files(self):
        return {str(path.relative_to(self.store)): path.read_bytes()
                for path in self.store.rglob("*") if path.is_file()}

    def wait_for_job(self, key):
        deadline = time.monotonic() + 15
        info = self.lab.job_info(key)
        while info["status"] == "running" and time.monotonic() < deadline:
            time.sleep(0.02)
            info = self.lab.job_info(key)
        self.assertEqual(info["status"], "done", info)
        log = (self.store / key / "godot.log").read_text()
        self.assertNotIn("SCRIPT ERROR", log)
        self.assertNotIn("ERROR:", log)
        return info

    def assert_weight_only(self, cards, pool):
        conveyor = cards["rules"]["conveyor"]
        self.assertEqual(conveyor["pool"], pool)
        self.assertNotIn("employee_every", conveyor)
        self.assertNotIn("opening", conveyor)

    def test_fractional_and_zero_weights_survive_save_and_reopen(self):
        cards = self.cards(employee=0.125, coffee=1.75)
        original = copy.deepcopy(cards)
        pool = cards["rules"]["conveyor"]["pool"]
        saved = self.lab.save_config("cards", {"name": "小数与零权重", "data": cards})
        self.assert_weight_only(saved["data"], pool)
        self.assertEqual(cards, original)
        self.assertEqual(self.lab.library_info(saved["id"])["data"], saved["data"])
        path = self.store / "configs" / (saved["id"] + ".json")
        before = path.read_bytes()
        self.assertEqual(read_json(path)["data"], saved["data"])
        with workbench.OffWorkWorkbench(
                GODOT, 0, handler=BaseHTTPRequestHandler, store=self.store) as reopened:
            self.assertEqual(reopened.library_info(saved["id"])["data"], saved["data"])
            self.assertEqual(reopened.warnings, [])
        self.assertEqual(path.read_bytes(), before)

    def test_weight_snapshot_reaches_both_real_evaluation_modes(self):
        # A single nonzero fractional weight gives an exact observable outcome:
        # all actual opening offers must be coffee, including formerly forced slots.
        cards = self.cards(coffee=0.375)
        pool = cards["rules"]["conveyor"]["pool"]
        saved = self.lab.save_config("cards", {"name": "权重试验卡表", "data": cards})
        for kind in ("balance", "bot"):
            with self.subTest(kind=kind):
                submitted = self.lab.start_job(self.request(cards, kind))
                self.assertEqual(submitted["configs"]["cards"], saved["id"])
                snapshot = read_json(self.store / submitted["id"] / "request.json")
                self.assertEqual(snapshot["cards"], saved["data"])
                self.assert_weight_only(snapshot["cards"], pool)
                result = self.wait_for_job(submitted["id"])["result"]
                self.assertEqual(result["games"], 2)
                self.assertEqual(result["market_offers"]["coffee"],
                                 int(cards["rules"]["conveyor"]["slots"]) * 2)
                self.assertTrue(all(count == 0 for name, count in result["market_offers"].items()
                                    if name != "coffee"), result["market_offers"])
                self.assertEqual(result["decision_samples"], [])

    def test_playtest_exports_the_same_validated_cards_without_opening_a_window(self):
        cards = self.cards(employee=0.125, coffee=1.75)
        saved = self.lab.save_config("cards", {"name": "试玩权重", "data": cards})
        launches = []
        real_popen = subprocess.Popen

        def spawn(command, *args, **kwargs):
            if "--off-work-playtest" not in command:
                # check_request's headless Godot validation must remain real.
                return real_popen(command, *args, **kwargs)
            path = Path(next(arg.split("=", 1)[1] for arg in command
                             if arg.startswith("--cards-config=")))
            launches.append((command, path, read_json(path)))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            kwargs["stdout"].write(("WORK_PLAYTEST_READY " + digest + "\n").encode())
            kwargs["stdout"].flush()
            # Only process creation/startup observation is simulated. No game is spawned.
            return mock.Mock(pid=123456, poll=mock.Mock(return_value=None),
                             wait=mock.Mock(return_value=0))

        with mock.patch.object(workbench.subprocess, "Popen", side_effect=spawn):
            started = self.lab.playtest({"cards": cards})
        self.assertTrue(started["ok"])
        self.assertEqual(len(launches), 1)
        command, path, exported = launches[0]
        self.assertEqual(command[0], str(self.runtime) if sys.platform == 'darwin' else GODOT)
        if sys.platform == 'darwin':
            self.assertNotIn('--path', command)
            self.assertNotIn('--main-pack', command)
        else:
            self.assertEqual(command[command.index("--path") + 1], str(ROOT))
        self.assertEqual(path, (self.store / "playtests" / started["id"] / "cards.json").resolve())
        self.assertEqual(exported, saved["data"])
        self.assertEqual(self.lab.check_request({"cards": exported, "validate_only": True})["cards"],
                         saved["data"])

    def test_invalid_weights_reject_all_write_paths_without_persisting(self):
        valid = self.cards(employee=1)
        self.lab.save_config("cards", {"name": "保留的原卡表", "data": valid})
        before = self.files()
        library = copy.deepcopy(self.lab.library)
        catalog = copy.deepcopy(self.lab.catalog)
        real_popen = subprocess.Popen

        def no_game_window(command, *args, **kwargs):
            if "--off-work-playtest" in command:
                self.fail("无效权重不能到达试玩进程启动")
            return real_popen(command, *args, **kwargs)

        for name, weights in (("全零", {}), ("负数", {"employee": -0.125, "coffee": 1}),
                              ("NaN", {"employee": float("nan")}),
                              ("正无穷", {"employee": float("inf")}),
                              ("负无穷", {"employee": -float("inf")})):
            invalid = self.cards(**weights)
            actions = {
                "save": lambda: self.lab.save_config("cards", {"name": "无效权重", "data": invalid}),
                "evaluation": lambda: self.lab.start_job(self.request(invalid)),
                "playtest": lambda: self.lab.playtest({"cards": invalid}),
            }
            for operation, action in actions.items():
                with self.subTest(weight=name, operation=operation), \
                        mock.patch.object(workbench.subprocess, "Popen", side_effect=no_game_window):
                    with self.assertRaises(ValueError) as rejected:
                        action()
                    self.assertNotIsInstance(rejected.exception, workbench.ConfigConflict)
                    self.assertEqual(self.files(), before)
                    self.assertEqual(self.lab.library, library)
                    self.assertEqual(self.lab.catalog, catalog)
                    self.assertEqual(self.lab.jobs, {})

    def test_legacy_forced_offer_fields_are_removed_by_actual_engine_normalization(self):
        legacy = self.cards(coffee=0.375)
        conveyor = legacy["rules"]["conveyor"]
        conveyor.update(employee_every=1, opening=["employee"] * int(conveyor["slots"]))
        original = copy.deepcopy(legacy)
        normalized = self.lab.check_request({"cards": legacy, "validate_only": True})["cards"]
        self.assert_weight_only(normalized, conveyor["pool"])
        saved = self.lab.save_config("cards", {"name": "导入旧卡表", "data": legacy})
        self.assertEqual(saved["data"], normalized)
        self.assertEqual(read_json(self.store / "configs" / (saved["id"] + ".json"))["data"], normalized)
        self.assertEqual(legacy, original)
        submitted = self.lab.start_job(self.request(legacy))
        snapshot = read_json(self.store / submitted["id"] / "request.json")
        self.assertEqual(snapshot["cards"], normalized)
        result = self.wait_for_job(submitted["id"])["result"]
        self.assertEqual(result["market_offers"]["coffee"], int(conveyor["slots"]) * 2)
        self.assertEqual(result["market_offers"]["employee"], 0)


if __name__ == "__main__":
    unittest.main()
