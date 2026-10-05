#!/usr/bin/env python3
"""Use the HTML workbench's exact duel jobs, paired statistics and saved reports.

Example: python3 tools/check_bot_strength.py --a 1 --b .5 --pairs 40 \
    --seed-start 80001 --jobs 4 --store reports/bot-strength-validation
Exploration requires --no-gate; a short or statistically inconclusive run never passes.
"""
from __future__ import annotations

import argparse
import json
import os
from collections import deque
import subprocess
import tempfile
import time
from pathlib import Path

from manual_balance import ROOT, Workbench, atomic_json, digest, engine_fingerprint


def acceptance(summary, minimum_score=.65, minimum_pairs=30):
    interval = summary.get('a_score_pair_bootstrap_95', [])
    checks = {
        'enough_seed_pairs': summary.get('completed_seed_pairs', 0) >= minimum_pairs,
        'substantial_advantage': (summary.get('a_score_rate') or 0) >= minimum_score,
        'paired_interval_above_even': len(interval) == 2 and interval[0] > .5,
    }
    return {'passed': all(checks.values()), 'checks': checks,
            'minimum_score': minimum_score, 'minimum_pairs': minimum_pairs}


def godot_report_version(godot):
    """Query the selected runtime using the same version field stored by duel reports."""
    with tempfile.TemporaryDirectory(prefix='bot-strength-runtime-') as temporary:
        folder = Path(temporary)
        script, output = folder / 'version.gd', folder / 'version.txt'
        script.write_text('extends SceneTree\n'
                          'func _initialize() -> void:\n'
                          '\tvar file := FileAccess.open(OS.get_cmdline_user_args()[0], FileAccess.WRITE)\n'
                          '\tif file == null:\n\t\tquit(2)\n\t\treturn\n'
                          '\tfile.store_string(Engine.get_version_info()["string"])\n'
                          '\tfile.close()\n\tquit(0)\n', encoding='utf-8')
        result = subprocess.run([godot, '--headless', '--path', str(ROOT), '--log-file',
                                 str(folder / 'godot.log'), '-s', str(script), '--', str(output)],
                                cwd=ROOT, capture_output=True, text=True, timeout=45, check=True)
        version = output.read_text(encoding='utf-8').strip() if output.is_file() else ''
        if not version or 'SCRIPT ERROR:' in result.stdout + result.stderr:
            raise ValueError('无法读取实际 Godot 版本，不能复用旧对战结果')
        return version


def reusable_run(run, sides, rounds, fingerprint, cards_hash, godot_version):
    options, result = run.get('options', {}), run.get('result', {})
    return (run.get('kind') == 'bot-duel' and run.get('status') == 'complete'
            and result.get('status') == 'complete'
            and run.get('engine_fingerprint') == fingerprint
            and options.get('pairs') == 1 and options.get('max_rounds') == rounds
            and digest(run.get('cards')) == cards_hash
            and result.get('godot') == godot_version
            and all(options.get(side) == {**sides[side], 'model': 'bot'} for side in sides))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--a', type=float, default=1.)
    parser.add_argument('--b', type=float, default=.5)
    parser.add_argument('--a-parameters', type=Path, help='仅探索：覆盖 A 的参数 JSON 对象')
    parser.add_argument('--b-parameters', type=Path, help='仅探索：覆盖 B 的参数 JSON 对象')
    parser.add_argument('--pairs', type=int, default=40)
    parser.add_argument('--seed-start', type=int, default=80001)
    parser.add_argument('--rounds', type=int, default=80)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--minimum-score', type=float, default=.65)
    parser.add_argument('--minimum-pairs', type=int, default=30)
    parser.add_argument('--no-gate', action='store_true')
    parser.add_argument('--resume', action='store_true', help='复用同目录、同引擎及参数下已完成的种子对')
    parser.add_argument('--record-decisions', action='store_true', help='逐条保存局面、实际参数与搜索结果，供败局诊断')
    parser.add_argument('--godot')
    args = parser.parse_args()
    if min(args.pairs, args.jobs, args.rounds, args.seed_start, args.minimum_pairs) < 1:
        parser.error('次数、并发、回合、种子和验收样本数必须为正整数')
    if not 0 <= args.b <= args.a <= 1 or not .5 < args.minimum_score <= 1:
        parser.error('需要 0 ≤ B ≤ A ≤ 1，验收得分率在 (0.5, 1]')
    if not args.no_gate and (args.a == args.b or args.a_parameters or args.b_parameters):
        parser.error('自定义参数或同强度对照须使用 --no-gate；强度验收使用滑钮原始映射')
    godot = args.godot or os.environ.get('GODOT', '/Applications/Godot.app/Contents/MacOS/Godot')
    if args.record_decisions:
        os.environ['CARD_BOT_DUEL_TRACE'] = '1'
    store = args.store.resolve()
    workbench = Workbench(store, godot)
    paths, active = [], {}
    pending = deque(range(args.seed_start, args.seed_start + args.pairs))
    started = time.monotonic()
    next_update = 0.
    try:
        sides = {}
        for side in ('a', 'b'):
            strength = getattr(args, side)
            sides[side] = {'strength': strength, 'bot_parameters': workbench.profile(strength)['parameters']}
            path = getattr(args, side + '_parameters')
            if path:
                overrides = json.loads(path.read_text())
                if not isinstance(overrides, dict):
                    raise ValueError('参数覆盖必须为 JSON 对象')
                sides[side]['bot_parameters'].update(overrides)
        if args.resume:
            recovered = set()
            fingerprint = engine_fingerprint()
            cards_hash = digest(workbench.config('default')['cards'])
            godot_version = godot_report_version(godot)
            for run in workbench.runs():
                options = run.get('options', {})
                seed = options.get('seed_start')
                if (seed not in pending or seed in recovered
                        or not reusable_run(run, sides, args.rounds, fingerprint, cards_hash, godot_version)):
                    continue
                recovered.add(seed)
                paths.append(store / 'runs' / run['id'] / 'result.json')
            pending = deque(seed for seed in pending if seed not in recovered)
        while pending or active:
            while pending and len(active) < args.jobs:
                seed = pending.popleft()
                run = workbench.start_duel({'config_id': 'default', 'options': {
                    'pairs': 1, 'max_rounds': args.rounds, 'seed_start': seed, **sides}})
                active[run['id']] = seed
            for rid in list(active):
                run = workbench.run(rid)
                if run['status'] == 'complete':
                    paths.append(store / 'runs' / rid / 'result.json')
                    del active[rid]
                elif run['status'] in ('error', 'cancelled'):
                    raise RuntimeError(f"seed {active[rid]}: {run.get('error', run['status'])}")
            if time.monotonic() >= next_update:
                progress = [workbench.run(rid).get('progress', {}) for rid in active]
                completed = 2 * len(paths) + sum(p.get('completed', 0) for p in progress)
                print(f'{completed}/{args.pairs*2} games; {len(paths)}/{args.pairs} pairs; '
                      f'{time.monotonic()-started:.0f}s; running seeds {list(active.values())}', flush=True)
                next_update = time.monotonic() + 30
            if pending or active:
                time.sleep(.2)
        output = store / 'comparison.json'
        subprocess.run([godot, '--headless', '--path', str(ROOT), '-s',
                        'tools/bot_duel_merge.gd', '--', str(output), *map(str, paths)],
                       cwd=ROOT, check=True)
        report = json.loads(output.read_text())
        gate = acceptance(report['summary'], args.minimum_score, args.minimum_pairs)
        gate['exploratory'] = args.no_gate
        gate['comparison'] = str(output.relative_to(store))
        atomic_json(store / 'acceptance.json', gate)
        print(json.dumps({'summary': report['summary'], 'acceptance': gate}, ensure_ascii=False, indent=2))
        return 0 if args.no_gate or gate['passed'] else 1
    finally:
        workbench.close()


if __name__ == '__main__':
    raise SystemExit(main())
