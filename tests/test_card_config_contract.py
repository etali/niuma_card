# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""共享导入样例同时执行 Python 与 Godot 适配器，防止跨语言校验漂移。"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('contract_workbench', ROOT / 'tools/manual_balance.py')
WORKBENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKBENCH)


class CardConfigContractTest(unittest.TestCase):
    def test_shared_import_contract(self):
        base = json.loads((ROOT / 'data/cards.json').read_text())
        cases = json.loads((ROOT / 'tests/fixtures/card_config_contract.json').read_text())
        python_results = []
        for case in cases:
            candidate = copy.deepcopy(base)
            for change in case['changes']:
                target = candidate
                for key in change['path'][:-1]:
                    target = target[key]
                if change.get('remove'):
                    del target[change['path'][-1]]
                else:
                    target[change['path'][-1]] = change['value']
            try:
                WORKBENCH.validate_cards(candidate, base)
                accepted = True
            except ValueError:
                accepted = False
            with self.subTest(case=case['name']):
                self.assertEqual(accepted, case['ok'])
            python_results.append({'name': case['name'], 'ok': accepted})
        godot = os.environ.get('GODOT') or shutil.which('godot') or '/Applications/Godot.app/Contents/MacOS/Godot'
        if not Path(godot).is_file():
            self.skipTest('Godot 不可用，跨语言运行需设置 GODOT')
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'contract.json'
            run = subprocess.run([godot, '--headless', '--path', str(ROOT), '--script',
                                  'res://tests/test_card_config_contract.gd', '--',
                                  '--contract-output=' + str(output)], capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertNotIn('SCRIPT ERROR', run.stdout + run.stderr)
            self.assertEqual(json.loads(output.read_text()), python_results)
