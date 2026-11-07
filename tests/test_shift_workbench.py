# SPDX-License-Identifier: AGPL-3.0-only
"""两个模式共用同一个 HTTP 服务，验证真实模拟、试玩及 CLI 到达各自的游戏。"""
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from http.server import BaseHTTPRequestHandler
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.balance.off_work_workbench import ConfigConflict, OffWorkWorkbench, config_id, report_summary
from tools.balance.storage import atomic_json, read_json

GODOT = shutil.which(os.environ.get('GODOT', 'godot')) or '/Applications/Godot.app/Contents/MacOS/Godot'


class WorkbenchTiming(unittest.TestCase):
    def test_partial_first_match_and_legacy_clocks(self):
        with tempfile.TemporaryDirectory() as temp:
            job = {'folder': Path(temp), 'meta': {'completed': 0, 'total': 2}}
            progress = {'games': 0, 'simulated_seconds': 60, 'elapsed_seconds': .5,
                        'current_match': {'number': 1, 'seconds': 60}}
            atomic_json(job['folder'] / 'progress.json', {'completed': 0, 'total': 2, 'summary': progress})
            OffWorkWorkbench._refresh_progress(job)
            self.assertEqual(job['meta']['summary'], progress)

        complete = {'games': 2, 'matches': [{'seconds': 1.25}, {'seconds': 4.5}]}
        summary = report_summary(complete, {})
        self.assertEqual(summary['simulated_seconds'], 5.75)
        self.assertNotIn('elapsed_seconds', summary)
        self.assertNotIn('simulated_seconds', report_summary({**complete, 'games': 3}, {}))


class WorkbenchLegacyMetrics(unittest.TestCase):
    def test_first_opportunity_uses_recorded_order_and_natural_ends(self):
        # A is slower; B moves first regardless of the seats in the two legs.
        profiles = {"a": {"enabled": True, "first_action_seconds": 3},
                    "b": {"enabled": True, "first_action_seconds": 1}}
        matches = [{"winner": "b", "a_seat": 1, "seconds": 8}, {"winner": "draw", "a_seat": 0, "seconds": 2},
                   {"winner": "a", "a_seat": 1, "seconds": 1}, {"winner": "timeout", "a_seat": 1, "seconds": 10}]
        source = {"games": 4, "profiles": profiles, "matches": matches, "balance_metrics": {"version": 1}}
        before = copy.deepcopy(source)
        def metric():
            return report_summary(source, {})["balance_metrics"]
        self.assertEqual(metric()["first_player_win_rate"], {"numerator": 1, "denominator": 2, "value": 50})
        self.assertEqual(metric()["version"], 1)
        self.assertEqual(source, before)
        # Equal deadlines run seat 0 first. When B is disabled only A is eligible.
        profiles["a"]["first_action_seconds"] = 1
        matches[0]["winner"] = "a"
        self.assertEqual(metric()["first_player_win_rate"]["numerator"], 0)
        profiles["b"]["enabled"] = False
        self.assertEqual(metric()["first_player_win_rate"]["numerator"], 1)
        del source["profiles"]
        self.assertNotIn("first_player_win_rate", metric())
        request = {"bot": {"bot": {"enabled": True}}, "a": {"first_action_seconds": 1},
                   "b": {"enabled": False}}
        inferred = report_summary(source, {}, request=request)["balance_metrics"]
        self.assertEqual(inferred["first_player_win_rate"]["numerator"], 1)
        matches[0]["first_seat"] = 1
        self.assertEqual(metric()["first_player_win_rate"]["denominator"], 1)

    def test_observed_counts_and_compatible_aggregate_recovery(self):
        cards = {"cards": {"work": {}, "money": {}, "coffee": {"name": "咖啡"}, "employee": {"name": "员工"}}}
        report = {"games": 3, "flow": {"upgrades": 4}, "matches": [
            {"seconds": 30, "upgrades": 1, "tool_generations": 2, "interferences": 1,
             "acquisitions": {"coffee": 2, "employee": 1}},
            {"seconds": 90, "upgrades": 3, "tool_generations": 0, "interferences": 0, "acquisitions": {}},
            {"seconds": 0}]}
        def metrics():
            return report_summary(report, cards)["balance_metrics"]
        observed = metrics()
        self.assertEqual(observed["upgrades_per_minute"]["value"], 2)
        self.assertEqual(observed["tool_generations_per_minute"]["value"], 2)
        self.assertEqual(observed["interferences_per_minute"]["value"], 1)
        distribution = observed["card_acquisitions"]
        self.assertEqual((distribution["total"],distribution["observed_games"],distribution["missing_games"]), (3, 2, 1))
        self.assertAlmostEqual(distribution["distribution"][0]["percentage"], 200/3)

        report["matches"] = [{"seconds": 30, "bilateral_interference": True},
                             {"seconds": 90, "bilateral_interference": True}, {"seconds": 0}]
        report["purchases"] = {"coffee": 3}
        unknown = metrics()
        for field in ("upgrades_per_minute", "interferences_per_minute", "tool_generations_per_minute", "card_acquisitions"):
            self.assertNotIn(field, unknown)
        report["flow"]["upgrades"] = 0
        self.assertEqual(metrics()["upgrades_per_minute"], {"numerator": 0, "denominator": 2, "value": 0})
        for row in report["matches"]: row["seconds"] = 40
        report["flow"]["upgrades"] = 4
        self.assertEqual(metrics()["upgrades_per_minute"]["value"], 2)


@unittest.skipUnless(Path(GODOT).is_file(), '需要 Godot')
class ShiftWorkbench(unittest.TestCase):
    def test_legacy_policy_gets_budget_only_in_new_experiment_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            old = read_json(ROOT / 'data/off_work_bot.json')['bot']
            old.pop('owner')
            old.pop('decision_budget_ratio')
            old.update(think_seconds=4.9, buy_chance=.48)
            old_id = config_id('ai', old)
            snapshot = {'kind':'ai', 'data':old, 'id':old_id, 'name':'旧偏低',
                        'source':'manual', 'created_at':'2026-09-01T00:00:00+00:00'}
            path = folder/'configs'/(old_id + '.json')
            atomic_json(path, snapshot)
            with OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=folder) as lab:
                try:
                    submitted = lab.start_job({'kind':'balance', 'cards':read_json(ROOT/'data/off_work_cards.json'),
                                               'a':old, 'a_name':'从脚本载入', 'pairs':1, 'seed':16, 'max_seconds':1})
                    new_id = submitted['configs']['a']
                    self.assertNotEqual(new_id, old_id)
                    self.assertEqual(submitted['configs']['b'], new_id)
                    new_policy = lab.library_info(new_id)
                    self.assertEqual(new_policy['name'], '旧偏低')
                    self.assertEqual(new_policy['data'], {**old, 'decision_budget_ms':12})
                    self.assertEqual(read_json(path), snapshot)
                    relative = {**old, 'decision_budget_ratio':.5}
                    with self.assertRaises(ConfigConflict) as conflict:
                        lab.save_config('bot', {'name':'旧偏低', 'data':relative})
                    self.assertEqual(conflict.exception.payload['code'], 'name_conflict')
                    saved = lab.save_config('bot', {'name':'旧偏低','data':relative,'overwrite_id':new_id})
                    self.assertEqual(saved['data'], relative)
                    self.assertEqual(lab.library_info(new_id)['data']['decision_budget_ms'], 12)
                    self.assertEqual(read_json(path), snapshot)
                finally:
                    lab.close_jobs()

    def test_bulk_restore_keeps_healthy_snapshots_and_recovers_repaired_one(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Path(temp)
            clean = read_json(ROOT / 'data/off_work_cards.json')
            legacy = copy.deepcopy(clean)
            legacy['rules']['simulation']['work_income'] = legacy['cards']['work'].pop('income')
            repaired = copy.deepcopy(clean)
            repaired['cards']['work']['income'] += 1
            def snapshot(cards, name):
                return {'id': config_id('cards', cards), 'kind': 'cards', 'name': name,
                        'source': 'manual', 'created_at': '2026-10-01', 'data': cards}
            def write(record):
                atomic_json(store/'configs'/(record['id'] + '.json'), record)
            old, target, repair = snapshot(legacy, '旧卡表'), snapshot(clean, '已有快照'), snapshot(repaired, '待修复')
            for r in (old, target):
                write(r)
            write({**repair, 'data': {'rules': {}, 'cards': {}, 'roles': {}}})
            def entry(r):
                return {'id': r['id'], 'created_at': r['created_at'], 'updated_at': r['created_at'], 'source': 'manual'}
            atomic_json(store/'catalog.json', {'cards': {'旧卡表': entry(old), '待修复': entry(repair)}, 'bot': {}})
            with OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=store) as lab:
                listed = lab.library_info()
                self.assertEqual([r['id'] for r in listed['cards']], [target['id']])
                self.assertEqual(lab.library_info(old['id'])['data'], clean)
                self.assertTrue(any(repair['id'] in warning for warning in listed['warnings']))
                self.assertEqual(read_json(store/'configs'/(target['id']+'.json')), target)
                self.assertEqual(read_json(store/'catalog.json')['cards']['待修复']['id'], repair['id'])
            write(repair)
            with OffWorkWorkbench(GODOT, 0, handler=BaseHTTPRequestHandler, store=store) as lab:
                listed = lab.library_info()
                self.assertFalse(listed['warnings'])
                self.assertEqual({r['name'] for r in listed['cards']}, {'旧卡表', '待修复'})
                self.assertEqual(lab.library_info(repair['id'])['data'], repaired)
            self.assertEqual(read_json(store/'configs'/(old['id']+'.json')), old)

    def test_both_engines_from_one_service(self):
        with tempfile.TemporaryDirectory(prefix='shift-workbench-') as temp:
            temp = Path(temp)
            # 原生试玩也启动真实场景，只改显示驱动并隔离玩家偏好。
            engine = temp / 'godot'
            engine.write_text('#!/bin/sh\nexec '+shlex.quote(GODOT)+' --headless "$@"\n')
            engine.chmod(0o755)
            store = temp / 'store'
            off_store = store / 'off-work'
            # A real pre-rename store: immutable profile, name index and experiment.
            legacy_bot = read_json(ROOT / 'data/off_work_bot.json')
            profile = {k:v for k,v in legacy_bot['bot'].items() if k != 'owner'}
            old_key = config_id('ai', profile)
            old_job = 'a' * 32
            legacy_snapshot = off_store / 'configs' / (old_key + '.json')
            created = '2026-10-01T00:00:00+00:00'
            saved = {'id':old_key, 'kind':'ai', 'data':profile, 'name':'原策略', 'created_at':created, 'source':'manual'}
            atomic_json(legacy_snapshot, saved)
            atomic_json(off_store/'catalog.json', {'cards':{}, 'ai':{'原策略':{
                'id':old_key, 'source':'manual', 'created_at':created, 'updated_at':created}}})
            old_request = {'kind':'ai', 'ai':legacy_bot, 'label':'AI PK', 'a':profile, 'b':profile,
                           'cards':read_json(ROOT/'data/off_work_cards.json'), 'pairs':1}
            atomic_json(off_store/old_job/'request.json', old_request)
            atomic_json(off_store/old_job/'result.json', {'games':2, 'timeouts':2})
            env = {**os.environ, 'CARD_DATA_DIR':str(temp/'on-player'), 'WORK_DATA_DIR':str(temp/'off-player')}
            command = [sys.executable, str(ROOT/'tools/manual_balance.py'), '--port', '0', '--store', str(store),
                       '--godot', str(engine)]
            with (temp/'service.log').open('w+') as log, subprocess.Popen(command, env=env, stdout=log, stderr=log) as service:
                try:
                    address = off_store / 'service.json'
                    deadline = time.monotonic() + 45
                    while not address.is_file() and service.poll() is None and time.monotonic() < deadline:
                        time.sleep(.1)
                    self.assertTrue(address.is_file(), (temp/'service.log').read_text())
                    url = json.loads(address.read_text())['url'].removesuffix('/off-work/')
                    token = ''
                    def api(path, body=None):
                        data = None if body is None else json.dumps(body).encode()
                        headers = {'Content-Type':'application/json', 'X-Balance-Token':token}
                        with urlopen(Request(url+path, data=data, headers=headers), timeout=45) as response:
                            return json.load(response)

                    for path, mode in [('/', '上班'),('/off-work/', '下班')]:
                        with urlopen(url+path) as response:
                            html = response.read().decode()
                        self.assertIn('aria-current="page">'+mode+'</a>', html)
                        self.assertIn('href="/mode-nav.css"', html)
                    bootstrap = api('/api/bootstrap')
                    token = bootstrap['token']
                    options = {**bootstrap['default_options'], 'pairs':1, 'max_rounds':1, 'strength':0,
                               'bot_parameters':api('/api/profile', {'strength':0})['parameters']}
                    run = api('/api/run', {'config_id':'default', 'options':options})
                    deadline = time.monotonic() + 60
                    while run['status'] in ('queued','running') and time.monotonic() < deadline:
                        time.sleep(.2)
                        run = api('/api/run/'+run['id'])
                    self.assertEqual(run['status'], 'complete', run.get('error'))
                    self.assertEqual(len(run['result']['games']), 2)
                    off = api('/off-work/api/config')
                    self.assertIn('bot', off)
                    self.assertNotIn('ai', off)
                    initial = api('/off-work/api/bootstrap')
                    self.assertEqual([r['id'] for r in initial['history']['items']], [old_job])
                    self.assertEqual(initial['default_profiles']['balance']['a'], initial['default_profiles']['balance']['b'])
                    self.assertNotEqual(initial['default_profiles']['bot']['a'], initial['default_profiles']['bot']['b'])
                    self.assertEqual(initial['library'], api('/off-work/api/library'))
                    default_id = initial['project_cards_id']
                    note_url = '/off-work/api/notes/' + default_id
                    self.assertEqual(api(note_url)['text'], '')
                    api('/off-work/api/notes', {'id': default_id, 'text': '默认卡表试玩记录'})
                    self.assertEqual(api(note_url)['text'], '默认卡表试玩记录')
                    history = api('/off-work/api/jobs/'+old_job)
                    self.assertEqual((history['kind'], history['label']), ('bot','BOT PK'))
                    self.assertNotIn('simulator_fingerprint', history['summary'])
                    self.assertNotIn('elapsed_seconds', history['summary'])
                    self.assertNotIn('simulated_seconds', history['summary'])
                    self.assertEqual(history['request']['bot'], legacy_bot)
                    self.assertEqual(history['configs']['a'], old_key)
                    self.assertEqual(read_json(off_store/old_job/'request.json'), old_request)
                    self.assertEqual(read_json(legacy_snapshot), saved)
                    library = api('/off-work/api/library')
                    self.assertEqual([item['id'] for item in library['bot']], [old_key])
                    self.assertNotIn('ai', library)
                    self.assertEqual(api('/off-work/api/library/'+old_key)['kind'], 'bot')
                    for mode in ('bot','ai','balance'):
                        command = [sys.executable, str(ROOT/'tools/balance/off_work_cli.py'), '--url', url,
                                   '--kind', mode, '--cards', str(ROOT/'data/off_work_cards.json'), '--name','默认卡表',
                                   '--seed','42','--pairs','1','--max-seconds','2']
                        if mode == 'ai':
                            command += ['--a', str(legacy_snapshot)]
                        proc = subprocess.run(command, capture_output=True, text=True, timeout=45)
                        self.assertEqual(proc.returncode, 0, proc.stderr+proc.stdout)
                        result = json.loads(proc.stdout)
                        self.assertEqual(result['games'], 2)
                        link = urlsplit(result['experiment_url'])
                        self.assertEqual(link.path, '/off-work/')
                        self.assertEqual(link.netloc, urlsplit(url).netloc)
                        self.assertEqual(parse_qs(link.query), {'run':[result['id']], 'cards':[result['configs']['cards']]})
                        self.assertIsNone(result['cards_snapshot_path'])  # this test uses --store
                        self.assertEqual(result['kind'], 'balance' if mode == 'balance' else 'bot')
                        self.assertEqual(result['simulated_seconds'], 4.0)
                        self.assertGreater(result['elapsed_seconds'], 0)
                        self.assertTrue(result['simulator_fingerprint'])
                        metrics = result['balance_metrics']
                        self.assertEqual(metrics['version'], 2)
                        self.assertIsNone(metrics['first_player_win_rate']['value'])  # both legs hit the time limit
                        self.assertEqual(metrics['card_acquisitions']['observed_games'], 2)
                        for key in ('upgrades_per_minute', 'tool_generations_per_minute', 'interferences_per_minute'):
                            self.assertEqual(metrics[key]['denominator'], 2)
                        detail = api('/off-work/api/jobs/' + result['id'])
                        self.assertEqual(detail['result']['balance_metrics'], metrics)
                        history = api('/off-work/api/history?kind=' + mode)['items']
                        self.assertEqual(next(j['summary']['balance_metrics'] for j in history if j['id'] == result['id']),
                                         metrics)
                        if mode == 'balance':
                            self.assertEqual(result['configs']['a'], result['configs']['b'])
                        else:
                            self.assertNotEqual(result['configs']['a'], result['configs']['b'])
                        if mode == 'ai': self.assertEqual(result['configs']['a'], old_key)
                        self.assertIn(result['id'], [j['id'] for j in api('/off-work/api/history?kind='+mode)['items']])
                    # A balance run may mirror a single custom side, while older callers
                    # who explicitly submit two different profiles keep both unchanged.
                    body = {'kind': 'balance', 'cards': off['cards'], 'pairs': 1, 'seed': 55,
                            'max_seconds': 2, 'b': {'buy_chance': .19}, 'b_name': '自定义 B'}
                    single = api('/off-work/api/run', body)
                    self.assertEqual(single['configs']['a'], single['configs']['b'])
                    used = api('/off-work/api/jobs/' + single['id'])['request']
                    self.assertEqual(used['a']['buy_chance'], .19)
                    self.assertEqual(used['a_name'], used['b_name'])
                    distinct = api('/off-work/api/run', {**body, 'a': profile})
                    self.assertNotEqual(distinct['configs']['a'], distinct['configs']['b'])
                    used = api('/off-work/api/jobs/' + distinct['id'])['request']
                    self.assertEqual(used['a'], profile)
                    self.assertEqual(used['b']['buy_chance'], .19)
                    def conflict(kind, body, code):
                        with self.assertRaises(HTTPError) as error:
                            api('/off-work/api/library/'+kind, body)
                        self.assertEqual(error.exception.code, 409)
                        payload = json.load(error.exception)
                        self.assertEqual(payload['code'], code)
                        return payload
                    self.assertEqual(conflict('bot', {'name':'仅改名','data':profile},
                                              'unchanged_config')['existing']['id'], old_key)
                    edit = {'name':'原策略', 'data':{**profile, 'buy_chance':0.51}}
                    overwrite = conflict('ai', edit, 'name_conflict')['conflicts'][0]['current_id']
                    self.assertEqual(overwrite, old_key)
                    updated = api('/off-work/api/library/bot', {**edit,'overwrite_id':overwrite})
                    self.assertTrue(updated['id'].startswith('bot_'))
                    self.assertEqual(api('/off-work/api/library/'+old_key)['data'], profile)
                    self.assertNotIn('ai', read_json(off_store/'catalog.json'))
                    for path, body in [('/api/play', {'config_id':'default'}),
                                       ('/off-work/api/playtest', {'cards':off['cards']})]:
                        play = api(path, body)
                        try:
                            self.assertTrue(play.get('ok') or play.get('started'))
                        finally:
                            # 试玩会建立独立进程组，隔离 Godot 包装器和实际引擎一起收尾。
                            os.killpg(play['pid'], signal.SIGTERM)
                finally:
                    service.terminate()
                    service.wait(timeout=20)
