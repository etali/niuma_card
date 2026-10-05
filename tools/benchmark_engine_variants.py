#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""同一PCK、固定BOT局面/节点预算，交替顺序测量不同引擎编译配置的性能。"""
import argparse
import json
import hashlib
import os
from pathlib import Path
import statistics
import subprocess
import sys
import traceback

from project_paths import ROOT, display_path, redact_paths, relative_path


def benchmark(variants, output, rounds=2):
    project = ROOT
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    packs = {}
    for label, app in variants.items():
        resources = list((Path(app) / 'Contents/Resources').glob('*.pck'))
        if len(resources) != 1:
            raise ValueError(f'{label}没有唯一PCK')
        packs[label] = hashlib.sha256(resources[0].read_bytes()).hexdigest()
    if len(set(packs.values())) != 1:
        raise ValueError('变体的游戏资源包不同，不能当作纯引擎对比')
    results = {}
    reference = None
    for arch in ['arm64', 'x86_64']:
        results[arch] = {}
        for repeat in range(rounds):
            order = list(variants.items())
            if repeat % 2:
                order.reverse()
            for label, app in order:
                report = output / f'{arch}-{label}-{repeat}.json'
                log = output / f'{arch}-{label}-{repeat}.log'
                executable = next(p for p in (Path(app) / 'Contents/MacOS').iterdir() if p.is_file())
                env = dict(os.environ, CARD_ENGINE_BENCH=relative_path(report, project))
                env.pop('CARD_SHOT', None)
                try:
                    run = subprocess.run(['arch', '-' + arch, relative_path(executable.resolve(), project), '--headless'], env=env,
                                         cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
                except subprocess.TimeoutExpired as error:
                    output_text = error.stdout or ''
                    if isinstance(output_text, bytes):
                        output_text = output_text.decode('utf-8', errors='replace')
                    log.write_text(redact_paths(output_text, root=project))
                    raise RuntimeError(f'{label}/{arch}性能测试超时；见 {display_path(log, root=ROOT)}') from None
                log.write_text(redact_paths(run.stdout, root=project))
                if run.returncode or 'ERROR:' in run.stdout or 'ENGINE_BENCH median_ms=' not in run.stdout:
                    raise RuntimeError(f'{label}/{arch}性能测试失败：{display_path(log, root=ROOT)}')
                data = json.loads(report.read_text())
                signature = (data['seeds'], data['profile'], data['samples'][0]['nodes'], data['samples'][0]['decisions'])
                if reference is None:
                    reference = signature
                if signature != reference or any((s['nodes'], s['decisions']) != reference[2:] for s in data['samples']):
                    raise RuntimeError(f'{label}/{arch}搜索工作量或决策变化，不能作同任务性能对比')
                results[arch].setdefault(label, []).extend(s['ms'] for s in data['samples'])
                print(f"BENCH {arch}/{label} run{repeat + 1}: {data['median_ms']:.3f}ms", flush=True)
    summary = {}
    for arch, variants_ in results.items():
        summary[arch] = {}
        baseline = statistics.median(variants_['baseline'])
        for label, samples in variants_.items():
            median = statistics.median(samples)
            summary[arch][label] = {'median_ms': median, 'min_ms': min(samples), 'max_ms': max(samples),
                                    'vs_baseline_percent': (median / baseline - 1) * 100, 'samples': len(samples)}
    report = {'method': '每次进程先预热3局，再测7次固定3局；重复轮次逆序；不与编译同时运行',
              'pck_sha256': next(iter(packs.values())), 'seeds': reference[0], 'profile': reference[1], 'expanded_nodes': reference[2],
              'decisions_hash': reference[3], 'summary': summary}
    (output / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', action='append', required=True, help='name=/path/to/游戏.app；需要baseline')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=2)
    args = parser.parse_args()
    try:
        variants = dict(item.split('=', 1) for item in args.variant)
        if 'baseline' not in variants or args.rounds < 1:
            parser.error('至少提供baseline且rounds>=1')
        benchmark(variants, args.output, args.rounds)
    except Exception:
        sys.exit(redact_paths(traceback.format_exc(), root=ROOT))
