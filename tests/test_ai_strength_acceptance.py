#!/usr/bin/env python3
import copy
import contextlib
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'tools'))
import check_ai_strength as strength
from check_ai_strength import acceptance


class AcceptanceTest(unittest.TestCase):
    def test_small_or_inconclusive_samples_do_not_certify_strength(self):
        good = {'completed_seed_pairs':40,'a_score_rate':.75,'a_score_pair_bootstrap_95':[.65,.85]}
        self.assertTrue(acceptance(good)['passed'])
        for patch in [{'completed_seed_pairs':4}, {'a_score_rate':.60},
                      {'a_score_pair_bootstrap_95':[.5,.9]}, {'a_score_pair_bootstrap_95':[]}]:
            with self.subTest(patch=patch):
                self.assertFalse(acceptance({**good,**patch})['passed'])


class ResumeIdentityTest(unittest.TestCase):
    def setUp(self):
        self.cards = {'_game': {'win_cash': 100}, 'core': {'output_n': 4, 'price': 3},
                      '_comment': '完整卡表，包括说明'}
        self.sides = {side: {'strength': value, 'ai_parameters': {'plans': 16}}
                      for side, value in [('a', 1.), ('b', .5)]}
        self.version = '4.7.1-stable (official)'
        self.run = {'id': 'old', 'kind': 'ai-duel', 'status': 'complete',
                    'engine_fingerprint': 'engine', 'cards': copy.deepcopy(self.cards),
                    'options': {'pairs': 1, 'max_rounds': 80, 'seed_start': 80001,
                                **{side: {**spec, 'model': 'ai'} for side, spec in self.sides.items()}},
                    'result': {'status': 'complete', 'godot': self.version}}

    def reusable(self, run):
        return strength.reusable_run(run, self.sides, 80, 'engine',
                                     strength.digest(self.cards), self.version)

    def test_matching_identity_ignores_json_key_order(self):
        run = copy.deepcopy(self.run)
        run['cards'] = dict(reversed(list(run['cards'].items())))
        self.assertTrue(self.reusable(run))

    def test_any_card_table_content_change_rejects_reuse(self):
        for field, value in [('core', {'output_n': 5, 'price': 3}),
                             ('_game', {'win_cash': 101}), ('_comment', '新的说明'),
                             ('extra', {'price': 1})]:
            with self.subTest(field=field):
                run = copy.deepcopy(self.run)
                run['cards'][field] = value
                self.assertFalse(self.reusable(run))
        run = copy.deepcopy(self.run)
        del run['cards']
        self.assertFalse(self.reusable(run))

    def test_old_or_missing_actual_runtime_version_rejects_reuse(self):
        for version in ['4.7-stable (official)', '4.7.1-stable (custom_build)', '', None]:
            with self.subTest(version=version):
                run = copy.deepcopy(self.run)
                run['result']['godot'] = version
                self.assertFalse(self.reusable(run))
        run = copy.deepcopy(self.run)
        del run['result']['godot']
        self.assertFalse(self.reusable(run))

    def test_original_resume_guards_remain_required(self):
        changes = [('status', 'cancelled'), ('kind', 'balance'), ('engine_fingerprint', 'old')]
        for key, value in changes:
            with self.subTest(key=key):
                run = copy.deepcopy(self.run)
                run[key] = value
                self.assertFalse(self.reusable(run))
        for key, value in [('pairs', 2), ('max_rounds', 81)]:
            with self.subTest(key=key):
                run = copy.deepcopy(self.run)
                run['options'][key] = value
                self.assertFalse(self.reusable(run))
        run = copy.deepcopy(self.run)
        run['options']['a']['ai_parameters']['plans'] = 17
        self.assertFalse(self.reusable(run))
        run = copy.deepcopy(self.run)
        run['result']['status'] = 'running'
        self.assertFalse(self.reusable(run))

    def test_selected_runtime_is_queried_using_report_version_api(self):
        def query(command, **kwargs):
            self.assertEqual(command[0], '/runtime with spaces/Godot')
            script = pathlib.Path(command[command.index('-s') + 1])
            self.assertIn('Engine.get_version_info()["string"]', script.read_text())
            pathlib.Path(command[-1]).write_text(self.version)
            self.assertEqual(kwargs['timeout'], 45)
            self.assertTrue(kwargs['check'])
            return subprocess.CompletedProcess(command, 0, '', '')

        with mock.patch.object(strength.subprocess, 'run', side_effect=query) as execute:
            self.assertEqual(strength.godot_report_version('/runtime with spaces/Godot'), self.version)
        execute.assert_called_once()

    def test_unreadable_runtime_version_fails_closed(self):
        with mock.patch.object(strength.subprocess, 'run',
                               return_value=subprocess.CompletedProcess([], 0, '', '')):
            with self.assertRaisesRegex(ValueError, '不能复用旧对战结果'):
                strength.godot_report_version('godot')
        with mock.patch.object(strength.subprocess, 'run',
                               side_effect=subprocess.CalledProcessError(2, ['godot'])):
            with self.assertRaises(subprocess.CalledProcessError):
                strength.godot_report_version('godot')

    def test_resume_restarts_the_only_pair_when_cards_or_runtime_changed(self):
        # 全部请求种子都已存在时也要核对身份，不能依赖混合新旧分片时 merge 才发现。
        for changed in [None, 'cards', 'godot']:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as folder:
                old = copy.deepcopy(self.run)
                if changed == 'cards': old['cards']['core']['output_n'] += 1
                if changed == 'godot': old['result']['godot'] = 'old runtime'
                workbench = mock.Mock()
                workbench.profile.return_value = {'parameters': {'plans': 16}}
                workbench.config.return_value = {'cards': self.cards}
                workbench.runs.return_value = [old]
                workbench.start_duel.return_value = {'id': 'new'}
                workbench.run.return_value = {'status': 'complete'}

                def merge(command, **_kwargs):
                    output = pathlib.Path(command[command.index('--') + 1])
                    output.write_text(json.dumps({'summary': {'completed_seed_pairs': 1,
                        'a_score_rate': 1, 'a_score_pair_bootstrap_95': []}}))
                    return subprocess.CompletedProcess(command, 0)

                argv = ['check_ai_strength.py', '--store', folder, '--pairs', '1',
                        '--resume', '--no-gate', '--godot', 'selected-godot']
                with mock.patch.object(sys, 'argv', argv), \
                        mock.patch.object(strength, 'Workbench', return_value=workbench), \
                        mock.patch.object(strength, 'engine_fingerprint', return_value='engine'), \
                        mock.patch.object(strength, 'godot_report_version', return_value=self.version) as runtime, \
                        mock.patch.object(strength.subprocess, 'run', side_effect=merge), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(strength.main(), 0)
                runtime.assert_called_once_with('selected-godot')
                self.assertEqual(workbench.start_duel.call_count, int(changed is not None))
                workbench.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
