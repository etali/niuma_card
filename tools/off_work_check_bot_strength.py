#!/usr/bin/env python3
"""Evaluate the exact off-work strength presets with paired seats and held-out seeds.

Results use the real workbench simulator and full default card table. Timeouts
are reported separately and never credited as wins. A small exploratory run
cannot pass the statistical acceptance gate. Existing reports are not reused.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import math
import os
from pathlib import Path
import random
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
LEVELS = [('min', 0), ('low', .25), ('mid', .5), ('high', .75), ('max', 1)]


def snapshot_runtime(destination):
    """Freeze scripts, configuration and the class registry used by this run."""
    destination.mkdir(parents=True)
    for relative in ("project.godot", ".godot/global_script_class_cache.cfg", "tools/balance/off_work_run.gd"):
        source=ROOT/relative; target=destination/relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source,target)
    for directory in ("engine", "data"):
        shutil.copytree(ROOT/directory,destination/directory)
    return destination


def run_request(godot, folder, request, expected=None, runtime=None):
    folder.mkdir(parents=True, exist_ok=False)
    source, target = folder / 'request.json', folder / 'result.json'
    source.write_text(json.dumps(request, ensure_ascii=False))
    with (folder / 'engine.log').open('w') as log:
        process = subprocess.run([godot, '--headless', '--path', str(runtime or ROOT), '--script',
                                  'res://tools/balance/off_work_run.gd', '--',
                                  '--request=' + str(source), '--output=' + str(target)],
                                 cwd=runtime or ROOT, stdout=log, stderr=subprocess.STDOUT)
    text = (folder / 'engine.log').read_text()
    if process.returncode or 'SCRIPT ERROR:' in text or not target.exists():
        raise RuntimeError('Simulation failed: ' + str(folder))
    result = json.loads(target.read_text())
    if 'error' in result:
        raise RuntimeError(result['error'])
    if expected is not None:
        validate_report(result, request, expected)
    return result


def same_profile(actual, requested):
    """Allow only floating JSON round-trip noise; all discrete values stay exact."""
    if isinstance(actual,dict) and isinstance(requested,dict):
        return actual.keys()==requested.keys() and all(same_profile(actual[k],requested[k]) for k in actual)
    if isinstance(actual,list) and isinstance(requested,list):
        return len(actual)==len(requested) and all(same_profile(a,b) for a,b in zip(actual,requested))
    if type(actual) is float and type(requested) is float:
        return math.isfinite(actual) and math.isfinite(requested) and (actual==requested or
            abs(actual-requested)<=2*max(math.ulp(actual),math.ulp(requested)))
    if type(actual) in (int,float) and type(requested) in (int,float):
        return actual==requested
    return type(actual) is type(requested) and actual==requested


def validate_report(result, request, expected):
    for key in ('simulator_fingerprint', 'godot_version'):
        if result.get(key) != expected[key]:
            raise ValueError('Inconsistent ' + key)
    if not same_profile(result.get('profiles'),{side:request[side] for side in ('a','b')}):
        raise ValueError('Actual profiles differ from frozen requested profiles')
    matches=result.get('matches',[])
    if len(matches)!=2 or {g.get('a_seat') for g in matches}!={0,1} or any(g.get('seed')!=request['seed'] for g in matches):
        raise ValueError('Incomplete or mismatched seat pair')


def summarize(reports, minimum_pairs=12):
    seen_seeds=set()
    for report in reports:
        matches=report.get('matches',[])
        if len(matches)!=2 or {game.get('a_seat') for game in matches}!={0,1}:
            raise ValueError('Each seed must contain both swapped-seat games exactly once')
        seed=matches[0].get('seed')
        if type(seed) not in (int,float) or not math.isfinite(seed) or seed<=0 or seed!=int(seed):
            raise ValueError('A pair must carry its original positive integer seed')
        if any(game.get('seed')!=seed or game.get('winner') not in ('a','b','draw','timeout') for game in matches):
            raise ValueError('Incomplete or mismatched seat-pair outcomes')
        if seed in seen_seeds:raise ValueError('Duplicate seed pair cannot increase the independent sample count')
        seen_seeds.add(seed)
    # Futures finish in nondeterministic order; seed order fixes the bootstrap
    # population before applying the reproducible resampling stream.
    reports=sorted(reports,key=lambda report:report["matches"][0].get("seed",0))
    for key in ('simulator_fingerprint','godot_version','profiles'):
        variants={json.dumps(r.get(key),sort_keys=True) for r in reports}
        if len(variants)>1: raise ValueError('Cannot aggregate mixed '+key)
    minimum_pairs=max(12,minimum_pairs)
    games = [game for report in reports for game in report['matches']]
    wins = sum(game['winner'] == 'a' for game in games)
    losses = sum(game['winner'] == 'b' for game in games)
    draws = sum(game['winner'] == 'draw' for game in games)
    timeouts = sum(game['winner'] == 'timeout' for game in games)
    # Cluster at seed pair: swapping seats is not an independent sample.
    paired = [(sum(g['winner'] == 'a' for g in r['matches']) +
               .5 * sum(g['winner'] == 'draw' for g in r['matches'])) / 2 for r in reports]
    rng = random.Random(170713)
    boot = sorted(sum(rng.choices(paired, k=len(paired))) / len(paired)
                  for _ in range(10000)) if paired else []
    interval = [boot[249], boot[9749]] if boot else [0, 1]
    score = (wins + .5 * draws) / len(games) if games else 0
    return {'seed_pairs':len(reports), 'games':len(games), 'higher_wins':wins,
            'lower_wins':losses, 'draws':draws, 'timeouts':timeouts,
            'higher_score_rate':score, 'paired_bootstrap_95':interval,
            'mean_remaining_work_advantage':sum(g['b_work']-g['a_work'] for g in games)/max(1,len(games)),
            'passed':len(reports) >= minimum_pairs and not timeouts and score >= .6 and interval[0] > .5,
            'minimum_pairs':minimum_pairs,
            'note':'Timeouts count as no higher-side win and block acceptance; they are not drawn outcomes.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=12)
    parser.add_argument('--seed-start', type=int, default=93001)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--max-seconds', type=float, default=600)
    parser.add_argument('--minimum-pairs', type=int, default=12)
    parser.add_argument('--phase', choices=['exploration','holdout'], default='holdout')
    parser.add_argument('--edges', default='min:low,low:mid,mid:high,high:max')
    parser.add_argument('--exploration', type=Path, nargs='*', default=[], help='Prior exploration directories; holdout seeds must be disjoint')
    parser.add_argument('--profile-overrides',type=Path,help='Exploration-only per-level parameter overrides; exact profiles are recorded')
    parser.add_argument('--godot', default=os.environ.get('GODOT', shutil.which('godot')))
    args = parser.parse_args()
    if min(args.pairs,args.seed_start,args.jobs,args.minimum_pairs,args.max_seconds) <= 0:
        parser.error('counts, seed and duration must be positive')
    names = dict(LEVELS)
    for percent in range(101):
        names[f'{percent/100:.2f}']=percent/100
        names[str(percent/100)]=percent/100
    edges = [edge.split(':') for edge in args.edges.split(',')]
    if any(len(e)!=2 or e[0] not in names or e[1] not in names or names[e[0]]>=names[e[1]] for e in edges):
        parser.error('edges must contain lower:higher preset names')
    store=args.store.resolve();store.mkdir(parents=True,exist_ok=True)
    if any(store.iterdir()): parser.error('store must be empty; immutable runs cannot silently reuse another curve')
    explored_seeds=set()
    for prior in args.exploration:
        definition=json.loads((prior/'definition.json').read_text())
        explored_seeds.update(definition['seeds'] if 'seeds' in definition else range(definition['seed_start'],definition['seed_start']+definition['pairs']))
    chosen_seeds=set(range(args.seed_start,args.seed_start+args.pairs))
    if args.phase=='holdout' and (not args.exploration or chosen_seeds & explored_seeds):
        parser.error('Holdout requires recorded exploration directories and disjoint seed ranges')
    runtime=snapshot_runtime(store/'runtime')
    defaults=run_request(args.godot,store/'definition',{'presets_only':True},runtime=runtime)
    profiles={key:{**defaults['standard_profile'],**defaults['strength_profiles'][f'{value:.2f}']} for key,value in names.items()}
    expected={key:defaults[key] for key in ('simulator_fingerprint','godot_version')}
    profiles={key:profiles[key] for edge in edges for key in edge}
    if args.profile_overrides:
        if args.phase!='exploration':parser.error('Profile overrides are exploratory; holdout must validate the installed mapping')
        overrides=json.loads(args.profile_overrides.read_text())
        for key,value in overrides.items():
            if key in profiles:profiles[key].update(value)
    (store/'definition.json').write_text(json.dumps({'phase':args.phase,'levels':LEVELS,'profiles':profiles,
        'cards':defaults['cards'],'seed_start':args.seed_start,'pairs':args.pairs,'max_seconds':args.max_seconds,'jobs':args.jobs,
        'profile_validation':{'float_json_roundtrip_max_ulps':2,'integers_and_other_types':'exact'},
        'exploration_directories':[str(p.resolve()) for p in args.exploration], 'excluded_exploration_seeds':sorted(explored_seeds),
        'runtime':expected,'runtime_snapshot':str(runtime),'edges':edges,'profile_overrides':str(args.profile_overrides.resolve()) if args.profile_overrides else None},ensure_ascii=False,indent=2))
    reports={':'.join(e):[] for e in edges}; started=time.monotonic()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        pending={}
        for seed in range(args.seed_start,args.seed_start+args.pairs):
            for lower,higher in edges:
                edge=lower+':'+higher
                request={'cards':defaults['cards'],'a':profiles[higher],'b':profiles[lower],
                         'pairs':1,'seed':seed,'max_seconds':args.max_seconds}
                pending[pool.submit(run_request,args.godot,store/edge.replace(':','-')/str(seed),request,expected,runtime)]=edge
        for future in as_completed(pending):
            edge=pending[future]
            try:
                reports[edge].append(future.result())
            except Exception as error:
                (store/'summary.json').write_text(json.dumps({'passed':False,'status':'failed','error':str(error)},ensure_ascii=False,indent=2))
                for task in pending:task.cancel()
                raise
            summary={key:summarize(value,args.minimum_pairs) for key,value in reports.items()}
            payload={'phase':args.phase,'elapsed_seconds':round(time.monotonic()-started,2),
                     'completed_pairs':sum(len(v) for v in reports.values()),'total_pairs':args.pairs*len(edges),
                     'comparisons':summary,'status':'complete' if all(len(v)==args.pairs for v in reports.values()) else 'running',
                     'runtime':expected,'passed':args.phase=='holdout' and all(len(v)==args.pairs for v in reports.values()) and all(v['passed'] for v in summary.values())}
            (store/'summary.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2))
            print(json.dumps({'edge':edge,**summary[edge]},ensure_ascii=False),flush=True)
    print('REPORT '+str(store/'summary.json'),flush=True)
    return 0 if args.phase=='exploration' or payload['passed'] else 1

if __name__=='__main__':
    raise SystemExit(main())
