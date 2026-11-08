# SPDX-License-Identifier: AGPL-3.0-only
"""Current built-ins must not overwrite independently saved older defaults."""
import copy
from http.server import BaseHTTPRequestHandler
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.balance.off_work_workbench import OffWorkWorkbench, ConfigConflict
from tools.balance.storage import read_json

GODOT = shutil.which(os.environ.get('GODOT', 'godot'))


@unittest.skipUnless(GODOT, '需要 Godot')
class BuiltinNames(unittest.TestCase):
    def test_current_defaults_run_without_overwriting_old_same_names(self):
        with tempfile.TemporaryDirectory() as folder, OffWorkWorkbench(
                GODOT, 0, handler=BaseHTTPRequestHandler, store=Path(folder)) as lab:
            config = lab.configuration()
            old_cards = copy.deepcopy(config['cards'])
            old_cards['cards']['employee']['price'] += 1
            old_bot = {**config['default_profiles']['balance']['a'],
                       'think_seconds':2.8, 'decision_budget_ratio':.5}
            old = lab._save_candidates([
                {'slot':'cards', 'kind':'cards', 'name':'项目默认', 'data':old_cards},
                {'slot':'q', 'kind':'bot', 'name':'标准策略', 'data':old_bot}],
                'experiment', {}, config['legacy_default_budget_ms'])
            catalog = copy.deepcopy(lab.catalog)
            archives = {path:path.read_bytes() for path in (Path(folder) / 'configs').glob('*.json')}
            bootstrap = lab.bootstrap()
            self.assertEqual(bootstrap['default_names']['cards'], '项目默认（新版）')
            self.assertEqual(bootstrap['default_names']['q'], '标准策略（新版）')
            self.assertEqual(lab.catalog, catalog, 'opening the editor is read-only')
            names = bootstrap['default_names']
            request = {'kind':'balance', 'cards':bootstrap['cards'], 'card_name':names['cards'],
                       'a':bootstrap['default_profiles']['balance']['a'], 'a_name':names['q'],
                       'pairs':1, 'seed':42, 'max_seconds':.01}
            try:
                submitted = lab.start_job(request)
                snapshot = read_json(Path(folder) / submitted['id'] / 'request.json')
                self.assertEqual(snapshot['card_name'], names['cards'])
                self.assertEqual(snapshot['a_name'], names['q'])
                for kind, name in [('cards','项目默认'), ('bot','标准策略')]:
                    self.assertEqual(lab.catalog[kind][name], catalog[kind][name])
                for path, contents in archives.items():
                    self.assertEqual(path.read_bytes(), contents)
                count = len(lab.library)
                self.assertEqual(lab.bootstrap()['default_names']['cards'], names['cards'])
                self.assertEqual(lab.bootstrap()['default_names']['q'], names['q'])
                self.assertEqual(lab.start_job(request)['configs'], submitted['configs'])
                self.assertEqual(len(lab.library), count)
                # Explicitly typing/selecting the old name still requires review.
                with self.assertRaises(ConfigConflict) as conflict:
                    lab.save_config('bot', {'name':'标准策略', 'data':{**old_bot, 'think_seconds':3.2}})
                self.assertEqual(conflict.exception.payload['code'], 'name_conflict')
                self.assertEqual(conflict.exception.payload['conflicts'][0]['current_id'], old['q']['id'])
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and lab.job_info(submitted['id'])['status'] == 'running':
                    time.sleep(.02)
                self.assertEqual(lab.job_info(submitted['id'])['status'], 'done')
            finally:
                lab.close_jobs()

    def test_successive_releases_keep_old_versions_and_reuse_identical_contents(self):
        with tempfile.TemporaryDirectory() as folder, OffWorkWorkbench(
                GODOT, 0, handler=BaseHTTPRequestHandler, store=Path(folder)) as lab:
            config = lab.configuration()
            self.assertEqual(lab.bootstrap()['default_names']['cards'], '项目默认')
            for version, name in enumerate(['项目默认', '项目默认（新版）', '项目默认（新版 2）'], 1):
                data = copy.deepcopy(config['cards'])
                data['cards']['employee']['price'] += version
                lab._save_candidates([{'slot':'cards','kind':'cards','name':name,'data':data}],
                                     'experiment', {}, config['legacy_default_budget_ms'])
            self.assertEqual(lab.bootstrap()['default_names']['cards'], '项目默认（新版 3）')
            lab._save_candidates([{'slot':'cards','kind':'cards','name':'我的已存卡表','data':config['cards']}],
                                 'experiment', {}, config['legacy_default_budget_ms'])
            self.assertEqual(lab.bootstrap()['default_names']['cards'], '我的已存卡表')
            self.assertEqual(len(lab.catalog['cards']), 4)


if __name__ == '__main__':
    unittest.main()
