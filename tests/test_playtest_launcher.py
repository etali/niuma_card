# SPDX-License-Identifier: AGPL-3.0-only
"""Published macOS runtime selection and interactive launch failure boundaries."""
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.balance import playtest_launcher as launcher
from tools.balance import off_work_workbench as off_work


def bundle(root):
    app = root / 'build/牛马牌.app'
    binary = app / 'Contents/MacOS/游戏 可执行文件'
    pack = app / 'Contents/Resources/牛马牌.pck'
    binary.parent.mkdir(parents=True)
    pack.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':binary.name}))
    binary.write_bytes(b'fixture runtime')
    binary.chmod(0o755)
    pack.write_bytes(b'fixture PCK')
    return app, binary, pack


class PlaytestCommand(unittest.TestCase):
    def test_macos_both_modes_use_the_declared_release_executable_with_absolute_card_paths(self):
        with tempfile.TemporaryDirectory(prefix='试玩 空格 ') as folder:
            root = Path(folder).resolve()
            app, binary, pack = bundle(root)
            relative = Path('cards/空格 $literal 卡表.json')
            with mock.patch.object(launcher.sys, 'platform', 'darwin'):
                for off in [False, True]:
                    command = launcher.playtest_command(root, '/unused/development Godot', relative, off_work=off)
                    self.assertEqual(command, [str(binary.resolve()), '--',
                        *(['--off-work-playtest'] if off else []), '--cards-config='+str(root / relative)])
                    self.assertNotIn('--path', command)
                    self.assertNotIn('--main-pack', command)
                    self.assertNotIn('--script', command)
                    self.assertEqual(command[-1].count('--cards-config='), 1)
            self.assertTrue(pack.is_file())

    def test_missing_or_invalid_app_requires_build_and_never_uses_the_development_engine(self):
        for fault in ['missing', 'plist', 'traversal', 'binary', 'not-executable', 'pack', 'empty-pack', 'two-packs']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                root = Path(folder).resolve()
                if fault != 'missing':
                    app, binary, pack = bundle(root)
                    if fault == 'plist': (app / 'Contents/Info.plist').write_bytes(b'<?xml invalid')
                    if fault == 'traversal': (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'../outside'}))
                    if fault == 'binary': binary.unlink()
                    if fault == 'not-executable': binary.chmod(0o644)
                    if fault == 'pack': pack.unlink()
                    if fault == 'empty-pack': pack.write_bytes(b'')
                    if fault == 'two-packs': pack.with_name('another.pck').write_bytes(b'other')
                with mock.patch.object(launcher.sys, 'platform', 'darwin'):
                    with self.assertRaisesRegex(ValueError, '请先构建游戏'):
                        launcher.playtest_command(root, '/available/godot', '/absolute/cards.json')

    def test_other_platforms_keep_the_source_runtime_and_absolute_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            with mock.patch.object(launcher.sys, 'platform', 'linux'), mock.patch.object(launcher, 'macos_executable') as mac:
                self.assertEqual(launcher.playtest_command(root, '/engine path/godot', 'cards/table.json', off_work=True),
                                 ['/engine path/godot', '--path', str(root), '--', '--off-work-playtest',
                                  '--cards-config='+str(root / 'cards/table.json')])
                mac.assert_not_called()


class OffWorkLaunchBoundary(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='试玩 独立快照 ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        _, self.binary, _ = bundle(self.root)
        self.lab = object.__new__(off_work.OffWorkWorkbench)
        self.lab.store = self.root / 'store'
        self.lab.engine = '/unused/godot'
        self.lab.check_request = lambda request: {'cards':request['cards']}
        platform = mock.patch.object(launcher.sys, 'platform', 'darwin')
        runtime = mock.patch.object(launcher, 'macos_executable', return_value=self.binary)
        platform.start(); runtime.start()
        self.addCleanup(platform.stop); self.addCleanup(runtime.stop)

    def test_release_launch_keeps_pid_snapshot_and_digest_handshake(self):
        process = mock.Mock(pid=1729, poll=mock.Mock(return_value=None), wait=mock.Mock(return_value=0))
        def spawn(command, **kwargs):
            self.assertEqual(command[:3], [str(self.binary), '--', '--off-work-playtest'])
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
            self.assertNotIn('env', kwargs, 'inherit the same user data policy as ordinary play')
            self.assertEqual(kwargs['cwd'], off_work.ROOT)
            path = Path(command[-1].split('=', 1)[1])
            self.assertTrue(path.is_absolute())
            self.assertEqual(off_work.read_json(path), {'test':'same cards'})
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            kwargs['stdout'].write(('WORK_PLAYTEST_READY '+digest+'\n').encode())
            kwargs['stdout'].flush()
            return process
        with mock.patch.object(off_work.subprocess, 'Popen', side_effect=spawn):
            result = self.lab.playtest({'cards':{'test':'same cards'}})
        self.assertEqual(result['pid'], 1729)
        self.assertTrue(result['ok'])
        process.terminate.assert_not_called()

    def test_wrong_or_missing_handshake_and_early_exit_never_report_success(self):
        for mode in ['exited', 'missing', 'wrong', 'ready-then-exit']:
            with self.subTest(mode=mode):
                process = mock.Mock(pid=1729, poll=mock.Mock(return_value=1 if mode == 'exited' else None),
                                    wait=mock.Mock(return_value=0))
                if mode == 'ready-then-exit': process.poll.side_effect = [None,1,1]
                def spawn(command, **kwargs):
                    path = Path(command[-1].split('=', 1)[1])
                    if mode in ['wrong', 'ready-then-exit']:
                        digest = 'wrong' if mode == 'wrong' else hashlib.sha256(path.read_bytes()).hexdigest()
                        kwargs['stdout'].write(('WORK_PLAYTEST_READY '+digest+'\n').encode())
                        kwargs['stdout'].flush()
                    return process
                with mock.patch.object(off_work.subprocess, 'Popen', side_effect=spawn), \
                        mock.patch.object(off_work, 'PLAYTEST_START_TIMEOUT', .01):
                    with self.assertRaisesRegex(ValueError, '日志见.*godot.log'):
                        self.lab.playtest({'cards':{'test':'same cards'}})
                if mode in ['missing','wrong']:
                    process.terminate.assert_called_once()
                    process.wait.assert_called_once()

    def test_spawn_failure_and_timeout_are_reported_and_reaped(self):
        with mock.patch.object(off_work.subprocess, 'Popen', side_effect=OSError('spawn failure')):
            with self.assertRaisesRegex(ValueError, '无法启动试玩游戏.*日志见'):
                self.lab.playtest({'cards':{'test':'same cards'}})
        self.assertIn('spawn failure', next((self.lab.store / 'playtests').glob('*/godot.log')).read_text())
        process = mock.Mock(poll=mock.Mock(return_value=None),
                            wait=mock.Mock(side_effect=[subprocess.TimeoutExpired('game', 2),0]))
        with mock.patch.object(off_work.subprocess, 'Popen', return_value=process), \
                mock.patch.object(off_work, 'PLAYTEST_START_TIMEOUT', 0):
            with self.assertRaisesRegex(ValueError, '确认开局'):
                self.lab.playtest({'cards':{'test':'same cards'}})
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)


if __name__ == '__main__':
    unittest.main()
