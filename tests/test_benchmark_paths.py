# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""基准工具使用各自项目的相对路径，报告/日志不保留本机目录前缀。"""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import bot_equivalence_benchmark as equivalence
import benchmark_engine_variants as variants
from project_paths import display_path


class BenchmarkPathsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='benchmark-paths-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.current = self.root / 'current'
        self.baseline = self.root / 'baseline'
        self.output = self.root / 'results'
        self.output.mkdir()
        for module in (equivalence, variants):
            patcher = mock.patch.object(module, 'ROOT', self.current)
            patcher.start()
            self.addCleanup(patcher.stop)
        for project in (self.current, self.baseline):
            (project / 'tools').mkdir(parents=True)
            (project / 'data').mkdir()
            (project / 'data/cards.json').write_text('{"fixture": true}')
        self.probe = self.current / 'tools/bot_equivalence_probe.gd'
        self.probe.write_text('# probe fixture\n')

    def process(self, stdout, stderr='', returncode=0):
        process = mock.MagicMock()
        process.__enter__.return_value = process
        process.communicate.return_value = (stdout, stderr)
        process.returncode = returncode
        return process

    def usage_output(self):
        if sys.platform == 'darwin':
            return '4096 maximum resident set size\n'
        return 'Maximum resident set size (kbytes): 4\n'

    def test_godot_call_is_relative_and_rss_survives_redaction(self):
        log = self.output / 'run.log'
        stdout = f'project={self.baseline}\nhome={Path.home()}/fixture\n'
        with mock.patch.object(equivalence.subprocess, 'Popen', return_value=self.process(stdout, self.usage_output())) as launch:
            result = equivalence.run_godot('/usr/local/bin/godot', self.baseline, self.probe,
                                           ['cases', self.output / 'result.json'], log, 5)
        command = launch.call_args.args[0]
        self.assertEqual(launch.call_args.kwargs['cwd'], self.baseline)
        self.assertEqual(command[command.index('--path') + 1], '.')
        script = command[command.index('-s') + 1]
        self.assertFalse(Path(script).is_absolute())
        self.assertEqual((self.baseline / script).resolve(), self.probe)
        argument = command[-1]
        self.assertEqual((self.baseline / argument).resolve(), self.output / 'result.json')
        self.assertFalse(Path(argument).is_absolute())
        self.assertEqual(result['peak_rss_bytes'], 4096)
        self.assertEqual(result['log'], display_path(log, root=self.current))
        self.assertNotIn(str(self.baseline), log.read_text())
        self.assertNotIn(str(Path.home()), log.read_text())

    def test_godot_failure_and_timeout_keep_only_redacted_logs(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                log = self.output / f'failure-{timeout}.log'
                leaked = f'SCRIPT ERROR: {self.baseline}/tools/failure.gd\n'
                process = self.process(leaked, returncode=1)
                if timeout:
                    process.communicate.side_effect = [subprocess.TimeoutExpired(['godot'], 5), (leaked, '')]
                with mock.patch.object(equivalence.subprocess, 'Popen', return_value=process), \
                        mock.patch.object(equivalence.os, 'killpg') as kill:
                    with self.assertRaises(RuntimeError) as caught:
                        equivalence.run_godot('godot', self.baseline, 'tools/test.gd', [], log, 5)
                    self.assertEqual(kill.call_count, int(timeout))
                self.assertNotIn(str(self.baseline), log.read_text())
                self.assertNotIn(str(self.baseline), str(caught.exception))
                self.assertIn(display_path(log, root=self.current), str(caught.exception))

    def test_equivalence_requests_resolve_for_each_project_and_preserve_metrics(self):
        state = dict(players={}, market=[], combos={}, winner='', win_reason='', uid=1,
                     rng=1, stats={}, round=1, first='bot')
        requests = []

        def launch(command, **kwargs):
            project = Path(kwargs['cwd'])
            self.assertIn(project, (self.current, self.baseline))
            args = command[command.index('--') + 1:]
            self.assertTrue(all(not Path(arg).is_absolute() for arg in args))
            script = Path(command[command.index('-s') + 1]).name
            if script == 'bot_equivalence_probe.gd':
                payload = [{'trace': [{'round_start': state}]}] if args[0] == 'games' else []
                (project / args[1]).write_text(json.dumps({'failures': [], 'payload': payload}))
            elif script == 'bot_decision_probe.gd':
                data = json.loads((project / args[1]).read_text())
                self.assertEqual(len(data['positions']), 4)
                (project / args[2]).write_text(json.dumps({'payload': [], 'timings': []}))
            else:
                self.assertEqual(script, 'eval_report.gd')
                request = json.loads((project / args[0]).read_text())
                for key in ('cards_path', 'output_path', 'progress_path'):
                    self.assertFalse(Path(request[key]).is_absolute())
                cards = (project / request['cards_path']).resolve()
                self.assertEqual(cards, self.baseline / 'data/cards.json')
                self.assertEqual(json.loads(cards.read_text()), {'fixture': True})
                output = (project / request['output_path']).resolve()
                progress = (project / request['progress_path']).resolve()
                self.assertEqual(output.parent, self.output)
                self.assertEqual(progress.parent, self.output)
                self.assertEqual(request['options'], dict(pairs=1, max_rounds=4, seed_start=1001,
                                                         model='bot', strength=1, bot_parameters={}))
                result = {'status': 'complete', 'games': ['same-game'], 'metrics': {'score': 7},
                          'meta': {'bot_parameters': {'budget': 42}, 'elapsed_seconds': 2.0}}
                output.write_text(json.dumps(result))
                progress.write_text('{}')
                requests.append((project, request))
            return self.process(f'loaded {project}/data/cards.json\n', self.usage_output())

        argv = ['benchmark', '--baseline', str(self.baseline), '--current', str(self.current),
                '--output', str(self.output), '--godot', 'godot', '--warmups', '0', '--repetitions', '3']
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(equivalence, 'PROBE', self.probe), \
                mock.patch.object(equivalence, 'fingerprint', return_value={'data/cards.json': 'same'}), \
                mock.patch.object(equivalence.subprocess, 'Popen', side_effect=launch), \
                contextlib.redirect_stdout(io.StringIO()) as printed:
            equivalence.main()
        report = json.loads((self.output / 'summary.json').read_text())
        self.assertEqual(len(requests), 6)
        self.assertEqual(report['projects'], {'baseline': display_path(self.baseline, root=self.current),
                                             'optimized': display_path(self.current, root=self.current)})
        self.assertTrue(report['sources_unchanged'])
        self.assertEqual(report['summary']['engine_speedup'], 1.0)
        self.assertEqual(report['summary']['baseline']['peak_rss_bytes']['median'], 4096)
        self.assertTrue(all(row['engine_seconds'] == 2.0 for row in report['measurements']))
        self.assertNotIn(str(self.output), printed.getvalue())
        for path in self.output.glob('*.log'):
            self.assertNotIn(str(self.current), path.read_text())
            self.assertNotIn(str(self.baseline), path.read_text())

    def apps(self):
        result = {}
        for label in ('baseline', 'optimized'):
            app = self.current / f'{label}.app'
            for directory in ('MacOS', 'Resources'):
                (app / 'Contents' / directory).mkdir(parents=True)
            (app / 'Contents/Resources/game.pck').write_bytes(b'same-pck')
            (app / 'Contents/MacOS/game').write_text('fixture')
            result[label] = app
        return result

    def test_engine_variants_use_relative_output_without_changing_samples(self):
        apps = self.apps()
        order = []

        def run(command, **kwargs):
            self.assertEqual(kwargs['cwd'], self.current)
            self.assertFalse(Path(command[2]).is_absolute())
            self.assertTrue((self.current / command[2]).is_file())
            value = kwargs['env']['CARD_ENGINE_BENCH']
            self.assertFalse(Path(value).is_absolute())
            self.assertNotIn('CARD_SHOT', kwargs['env'])
            report = (self.current / value).resolve()
            self.assertEqual(report.parent, self.output)
            label = 'optimized' if 'optimized' in report.name else 'baseline'
            order.append(label)
            ms = 8 if label == 'optimized' else 10
            report.write_text(json.dumps({'seeds': [9271], 'profile': {'budget': 42}, 'median_ms': ms,
                                         'samples': [dict(nodes=42, decisions='same', ms=ms)] * 2}))
            return subprocess.CompletedProcess(command, 0, f'{self.current}/game\nENGINE_BENCH median_ms={ms}\n')

        with mock.patch.object(variants, 'ROOT', self.current), \
                mock.patch.object(variants.subprocess, 'run', side_effect=run), \
                mock.patch.dict(os.environ, {'CARD_SHOT': 'fixture'}), contextlib.redirect_stdout(io.StringIO()):
            report = variants.benchmark(apps, self.output, rounds=2)
        self.assertEqual(order, ['baseline', 'optimized', 'optimized', 'baseline'] * 2)
        for arch in ('arm64', 'x86_64'):
            self.assertEqual(report['summary'][arch]['baseline']['samples'], 4)
            self.assertAlmostEqual(report['summary'][arch]['optimized']['vs_baseline_percent'], -20)
        for log in self.output.glob('*.log'):
            self.assertNotIn(str(self.current), log.read_text())

    def test_engine_variant_failure_and_timeout_redact_saved_logs(self):
        apps = self.apps()
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                leaked = f'ERROR: {self.current}/fixture\n'
                response = subprocess.CompletedProcess(['arch'], 1, leaked)
                side_effect = subprocess.TimeoutExpired(['arch'], 120, output=leaked.encode()) if timeout else None
                with mock.patch.object(variants, 'ROOT', self.current), \
                        mock.patch.object(variants.subprocess, 'run', return_value=response, side_effect=side_effect):
                    with self.assertRaises(RuntimeError) as caught:
                        variants.benchmark(apps, self.output, rounds=1)
                log = self.output / 'arm64-baseline-0.log'
                self.assertNotIn(str(self.current), log.read_text())
                self.assertNotIn(str(self.output), str(caught.exception))
                self.assertIn(display_path(log, root=self.current), str(caught.exception))

    def test_cli_errors_do_not_restore_absolute_paths_in_tracebacks(self):
        commands = [
            ['tools/bot_equivalence_benchmark.py', '--baseline', str(ROOT / 'missing-benchmark-fixture'),
             '--output', str(self.output)],
            ['tools/benchmark_engine_variants.py', '--variant', f'baseline={ROOT / "missing-benchmark-fixture.app"}',
             '--output', str(self.output)],
        ]
        for arguments in commands:
            with self.subTest(tool=arguments[0]):
                result = subprocess.run([sys.executable, *arguments], cwd=ROOT,
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Traceback', result.stderr)
                self.assertNotIn(str(ROOT), result.stderr)
                self.assertNotIn(str(Path.home()), result.stderr)


if __name__ == '__main__':
    unittest.main()
