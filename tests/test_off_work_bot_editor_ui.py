# SPDX-License-Identifier: AGPL-3.0-only
"""BOT editor behavior and saved search settings through the real experiment service."""
import copy
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
from tools.balance.off_work_workbench import OffWorkWorkbench, ConfigConflict, config_id
from tools.balance.storage import atomic_json, read_json

GODOT = shutil.which(os.environ.get('GODOT', 'godot')) or '/Applications/Godot.app/Contents/MacOS/Godot'


SEARCH_KEYS = ('search_max_depth', 'search_root_width', 'search_reply_width')


def archive_policy(store, mode):
    document = read_json(ROOT / 'data/off_work_bot.json')
    policy = document['bot']
    for key in ('owner', *SEARCH_KEYS, *document['compatibility']['algorithm_defaults']):
        policy.pop(key, None)
    policy['first_action_seconds'] = 10
    if mode != 'ratio':
        policy.pop('decision_budget_ratio', None)
        if mode == 'fixed_ms':
            policy['decision_budget_ms'] = 24
    key = config_id('bot', policy)
    record = {'id':key, 'kind':'bot', 'name':'旧策略', 'source':'manual',
              'created_at':'2026-09-01T00:00:00Z', 'data':policy}
    path = store / 'configs' / (key + '.json')
    atomic_json(path, record)
    atomic_json(store / 'catalog.json', {'cards':{}, 'bot':{'旧策略':{
        'id':key, 'source':'manual', 'created_at':record['created_at'], 'updated_at':record['created_at']}}})
    return record, path


def loaded_policy(config, archived):
    # Match the editor's default completion while retaining the archived time mode.
    policy = {**config['bot']['bot'], **config['legacy_search_defaults'],
              **config['legacy_algorithm_defaults'], **archived}
    policy.pop('owner', None)
    if 'decision_budget_ratio' not in archived:
        policy.pop('decision_budget_ratio', None)
        policy['decision_budget_ms'] = archived.get('decision_budget_ms', config['legacy_default_budget_ms'])
    else:
        policy.pop('decision_budget_ms', None)
    return policy


class OffWorkBotEditorUi(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), '网页行为测试需要 Node.js')
    def test_editor_events_and_comparison_navigation(self):
        result = subprocess.run([shutil.which('node'), '--test', str(ROOT / 'tests/test_off_work_bot_editor_ui.cjs')],
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(Path(GODOT).is_file(), '需要 Godot')
    def test_saved_search_settings_reach_the_real_simulator(self):
        with tempfile.TemporaryDirectory(prefix='work-bot-editor-') as folder:
            store = Path(folder)
            with OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=store) as lab:
                try:
                    config = lab.configuration()
                    policy = copy.deepcopy(config['default_profiles']['bot']['a'])
                    policy.update(search_max_depth=8, search_root_width=5, search_reply_width=3,
                                  first_action_seconds=10)
                    # Keep this transport regression brief while validating with the
                    # real engine. Search execution itself has dedicated BOT tests.
                    saved = lab.save_config('bot', {'name':'编辑后的搜索参数', 'data':policy})
                    self.assertEqual(saved['data'], policy)
                    self.assertEqual(lab.library_info(saved['id'])['data'], policy)
                    for kind, same_profiles in (('bot', False), ('bot', True), ('balance', True)):
                        with self.subTest(kind=kind, same_profiles=same_profiles):
                            other = copy.deepcopy(policy)
                            if not same_profiles:
                                other['search_max_depth'] = 2
                            request = {'kind':kind, 'cards':config['cards'], 'a':policy,
                                       'a_name':saved['name'], 'card_name':'编辑器卡表',
                                       'pairs':1, 'seed':42, 'max_seconds':0.01}
                            if kind == 'bot':
                                request.update(b=other, b_name='相同参数的另一名字' if same_profiles else '另一份搜索参数')
                            submitted = lab.start_job(request)
                            snapshot = read_json(store / submitted['id'] / 'request.json')
                            self.assertEqual(snapshot['a'], policy)
                            self.assertEqual(snapshot['b'], other if kind == 'bot' else policy)
                            self.assertEqual(submitted['configs']['a'], saved['id'])
                            expected_names = {'card_name':'编辑器卡表', 'a_name':saved['name'],
                                              'b_name':saved['name'] if same_profiles else '另一份搜索参数'}
                            for field, name in expected_names.items():
                                self.assertEqual(submitted[field], name)
                                self.assertEqual(submitted[field], snapshot[field])
                            if same_profiles:
                                self.assertEqual(submitted['configs']['a'], submitted['configs']['b'])
                                self.assertNotIn('相同参数的另一名字', lab.catalog['bot'])
                            deadline = time.monotonic() + 15
                            info = lab.job_info(submitted['id'])
                            while info['status'] == 'running' and time.monotonic() < deadline:
                                time.sleep(0.02)
                                info = lab.job_info(submitted['id'])
                            self.assertEqual(info['status'], 'done', info)
                            for field in expected_names:
                                self.assertEqual(submitted[field], info[field])
                            self.assertEqual(info['result']['games'], 2)
                            self.assertEqual(info['result']['profiles']['a'], policy)
                            self.assertEqual(info['result']['profiles']['b'], snapshot['b'])
                finally:
                    lab.close_jobs()


    @unittest.skipUnless(Path(GODOT).is_file(), '需要 Godot')
    def test_old_search_defaults_do_not_allow_unchanged_saves(self):
        for mode in ('ratio', 'fixed_ms', 'unrecorded_12ms'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                store = Path(folder)
                archived, path = archive_policy(store, mode)
                original = path.read_bytes()
                with OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=store) as lab:
                    hydrated = loaded_policy(lab.configuration(), archived['data'])
                    catalog = copy.deepcopy(lab.catalog)
                    for name in ('旧策略', '换一个名字'):
                        with self.subTest(name=name), self.assertRaises(ConfigConflict) as conflict:
                            lab.save_config('bot', {'name':name, 'data':hydrated})
                        self.assertEqual(conflict.exception.payload['code'], 'unchanged_config')
                        self.assertEqual(conflict.exception.payload['existing']['id'], archived['id'])
                        self.assertEqual(lab.catalog, catalog)
                        self.assertEqual(len(lab.library), 1)
                    changed = {**hydrated, 'search_max_depth':hydrated['search_max_depth'] + 1}
                    with self.assertRaises(ConfigConflict) as conflict:
                        lab.save_config('bot', {'name':'旧策略', 'data':changed})
                    self.assertEqual(conflict.exception.payload['code'], 'name_conflict')
                    self.assertEqual(conflict.exception.payload['conflicts'][0]['current_id'], archived['id'])
                    saved = lab.save_config('bot', {'name':'旧策略', 'data':changed, 'overwrite_id':archived['id']})
                    self.assertEqual(saved['data'], changed)
                    self.assertNotEqual(saved['id'], archived['id'])
                    self.assertEqual(path.read_bytes(), original)
                    self.assertEqual(lab.library_info(archived['id'])['data'], archived['data'])

    @unittest.skipUnless(Path(GODOT).is_file(), '需要 Godot')
    def test_experiments_reuse_old_name_and_preserve_archived_references(self):
        for mode in ('ratio', 'fixed_ms', 'unrecorded_12ms'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                store = Path(folder)
                archived, path = archive_policy(store, mode)
                original = path.read_bytes()
                old_job = 'a' * 32
                old_request = {'kind':'bot', 'cards':read_json(ROOT / 'data/off_work_cards.json'),
                               'a':archived['data'], 'b':archived['data'], 'pairs':1}
                references = {'a':archived['id'], 'b':archived['id']}
                atomic_json(store / old_job / 'request.json', old_request)
                atomic_json(store / old_job / 'result.json', {'games':2, 'timeouts':2})
                atomic_json(store / old_job / 'job.json', {'status':'done', 'configs':references})
                with OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=store) as lab:
                    try:
                        config = lab.configuration()
                        hydrated = loaded_policy(config, archived['data'])
                        request = {'kind':'balance', 'cards':config['cards'], 'a':hydrated,
                                   'a_name':'从历史载入', 'pairs':1, 'seed':42, 'max_seconds':0.01}
                        submitted = lab.start_job(request)
                        self.assertEqual((submitted['a_name'], submitted['b_name']), ('旧策略', '旧策略'))
                        snapshot = read_json(store / submitted['id'] / 'request.json')
                        info = lab.job_info(submitted['id'])
                        for field in ('card_name', 'a_name', 'b_name'):
                            self.assertEqual(submitted[field], snapshot[field])
                            self.assertEqual(submitted[field], info[field])
                        saved_id = submitted['configs']['a']
                        self.assertNotEqual(saved_id, archived['id'])
                        self.assertEqual(saved_id, submitted['configs']['b'])
                        saved = lab.library_info(saved_id)
                        self.assertEqual((saved['name'], saved['data']), ('旧策略', hydrated))
                        self.assertEqual(set(lab.catalog['bot']), {'旧策略'})
                        self.assertEqual(lab.start_job(request)['configs'], submitted['configs'])
                        with self.assertRaises(ConfigConflict) as conflict:
                            lab.save_config('bot', {'name':'别名', 'data':hydrated})
                        self.assertEqual(conflict.exception.payload['code'], 'unchanged_config')
                        self.assertEqual(lab.job_info(old_job)['configs'], references)
                        self.assertEqual(read_json(store / old_job / 'request.json'), old_request)
                        self.assertEqual(path.read_bytes(), original)
                        self.assertEqual(lab.library_info(archived['id'])['data'], archived['data'])
                    finally:
                        lab.close_jobs()

    @unittest.skipUnless(Path(GODOT).is_file(), '需要 Godot')
    def test_historical_policy_identity_uses_compatibility_defaults_not_current_tuning(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Path(folder)
            archived, _ = archive_policy(store, 'ratio')
            bot = read_json(ROOT / 'data/off_work_bot.json')
            bot['bot']['search_max_depth'] = 9
            bot['bot']['material_batch_limit'] = 64
            bot['bot']['tree_cash_log_weight'] = 5
            document = store / 'tuned_bot.json'
            atomic_json(document, bot)
            with mock.patch('tools.balance.off_work_workbench.DEFAULT_BOT', document), OffWorkWorkbench(
                    GODOT, 0, handler=BaseHTTPRequestHandler, store=store) as lab:
                config = lab.configuration()
                self.assertEqual(config['legacy_search_defaults'], {
                    'search_max_depth':4, 'search_root_width':3, 'search_reply_width':2})
                historical = loaded_policy(config, archived['data'])
                self.assertEqual(historical['search_max_depth'], 4)
                self.assertEqual(historical['material_batch_limit'], 16)
                self.assertEqual(historical['tree_cash_log_weight'], 2)
                current = {**historical, 'search_max_depth':9, 'material_batch_limit':64,
                           'tree_cash_log_weight':5}
                with self.assertRaises(ConfigConflict) as conflict:
                    lab.save_config('bot', {'name':'旧策略', 'data':current})
                self.assertEqual(conflict.exception.payload['code'], 'name_conflict')
                with self.assertRaises(ConfigConflict) as conflict:
                    lab.save_config('bot', {'name':'新名字', 'data':historical})
                self.assertEqual(conflict.exception.payload['code'], 'unchanged_config')


if __name__ == '__main__':
    unittest.main()
