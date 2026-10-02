#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""启动实际发布App验证两种架构的画面和WebSocket连接，日志/截图保存在build下。"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

from release_audit import audit
from project_paths import display_path, redact_paths, relative_path

ROOT = Path(__file__).resolve().parents[1]


def validate_log(name, result, log):
    log.write_text(redact_paths(result.stdout, ROOT))
    if result.returncode or any(text in result.stdout for text in ('ERROR:', 'Crash', 'Segmentation')):
        raise RuntimeError(f'{name} 验证失败，退出码 {result.returncode}，日志 {display_path(log, ROOT)}')


def run_logged(command, name, log, **kwargs):
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, **kwargs)
    except subprocess.TimeoutExpired as error:
        text = error.stdout or ""
        if isinstance(text, bytes):
            text = text.decode(errors="replace")
        log.write_text(redact_paths(text, ROOT))
        raise RuntimeError(f"{name} 验证超时，日志 {display_path(log, ROOT)}") from None
    validate_log(name, result, log)
    return result


def verify(app, output, arches):
    app, output = Path(app).resolve(), Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    pack = audit(app)
    executable = next(p for p in (app / 'Contents/MacOS').iterdir() if p.is_file())
    cases = [('purchase', 'rulebook:1:0:3'), ('upgrade', 'rulebook:2:1:6'),
             ('pawn', 'rulebook:4:0:4'), ('buffs', 'rulebook:5:0:4'),
             ('result', 'rulebook:0:0:6'), ('attack', 'atkpile:3'),
             ('drawer', 'drawercheck:loose'),
             ('drag-loose', 'dragoverflow:loose'), ('drag-group', 'dragoverflow:group'),
             ('actionguard', 'actionguard:deny')]
    checked = []
    for arch in arches:
        if arch not in pack['architectures']:
            raise RuntimeError(f'App缺少要求的{arch}架构')
        prefix = ['arch', '-' + arch, str(executable)]
        run_logged(prefix + ['--headless', '--version'], arch + ' version', output / f'{arch}-version.log', timeout=20)
        for name, action in cases:
            screenshot = output / f'{arch}-{name}.png'
            env = dict(os.environ, CARD_SEED='9271', CARD_DRAWER_SIZE='1600x1000',
                       CARD_SHOT=f'{screenshot},0.7,{action}')
            result = run_logged(prefix, arch + ' ' + name, output / f'{arch}-{name}.log', env=env, timeout=65)
            if not screenshot.exists() or 'CARD_SHOT ->' not in result.stdout:
                raise RuntimeError(f'{arch}/{name} 没有完成截图')
            if name.startswith('drag-') and 'DRAG_OVERFLOW follows=true tail_outside=true merged=true landed_visible=true' not in result.stdout:
                raise RuntimeError(f'{arch}展开牌组拖拽或底部合并失败')
            if name == 'actionguard' and 'ACTION_GUARD denied=true unchanged=true deny_sound=true' not in result.stdout:
                raise RuntimeError(f'{arch}完成行动消耗护栏未生效')
            checked.append(arch + '/' + name)
            print('PASS', checked[-1], flush=True)
        checked.append(arch + '/network')
        network(prefix, output, arch)
        print('PASS', checked[-1], flush=True)
    report = {'app': relative_path(app, ROOT), 'architectures': arches, 'checks': checked,
              'app_bytes': pack['app_bytes'], 'binary_bytes': pack['binary_bytes'], 'pck_bytes': pack['pck_bytes']}
    (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


def network(prefix, output, arch):
    with socket.socket() as socket_:
        socket_.bind(('127.0.0.1', 0))
        port = socket_.getsockname()[1]
    processes = []
    env = dict(os.environ)
    env.pop('CARD_SHOT', None)
    try:
        for name, args in [('host', ['--host', f'--port={port}', '--room=RELEASECHECK']),
                           ('client', [f'--server=ws://127.0.0.1:{port}', '--room=RELEASECHECK'])]:
            process = subprocess.Popen(prefix + ['--headless', '--quit-after', '900', '--', *args],
                                       env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            processes.append((name, process))
            if name == 'host':
                time.sleep(0.8)
        for name, process in processes:
            try:
                text = process.communicate(timeout=40)[0]
            except subprocess.TimeoutExpired as error:
                text = error.stdout or ""
                if isinstance(text, bytes):
                    text = text.decode(errors="replace")
                log = output / f'{arch}-network-{name}.log'
                log.write_text(redact_paths(text, ROOT))
                raise RuntimeError(f'{arch} network {name} 验证超时，日志 {display_path(log, ROOT)}') from None
            result = subprocess.CompletedProcess(prefix, process.returncode, stdout=text)
            validate_log(arch + ' network ' + name, result, output / f'{arch}-network-{name}.log')
            if '已入座' not in text:
                raise RuntimeError(f'{arch} {name}未成功联网入座')
    finally:
        for _, process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?', default=ROOT / 'build/牛马牌.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/release-check')
    parser.add_argument('--arch', choices=['arm64', 'x86_64', 'universal'], default='universal')
    args = parser.parse_args()
    try:
        verify(args.app, args.output, ['arm64', 'x86_64'] if args.arch == 'universal' else [args.arch])
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(redact_paths(f'发布验证失败：{error}', ROOT), file=sys.stderr)
        sys.exit(1)
