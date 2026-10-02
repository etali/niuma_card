#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""Compare a frozen project with this project; run Godot jobs strictly in sequence.

Only the independent probe is copied into the frozen project's tools directory.
Engine/configuration sources are hashed before and after and must remain unchanged.
The measured job is the real eval_report entry point, not the instrumented probe.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import statistics
import subprocess
import sys
import time
import traceback

from project_paths import display_path, redact_paths, relative_path


ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "tools/ai_equivalence_probe.gd"


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def fingerprint(project):
    files = sorted((project / "engine").glob("*.gd"))
    files += [project / "data/cards.json", project / "data/ai.json",
              project / "tools/eval_report.gd", project / "tools/balance/scoring.gd"]
    return {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def first_difference(a, b, path="payload"):
    if type(a) is not type(b):
        return f"{path}: type {type(a).__name__} != {type(b).__name__}"
    if isinstance(a, dict):
        if a.keys() != b.keys():
            return f"{path}: keys {set(a) ^ set(b)}"
        for key in a:
            difference = first_difference(a[key], b[key], f"{path}.{key}")
            if difference:
                return difference
    elif isinstance(a, list):
        if len(a) != len(b):
            return f"{path}: length {len(a)} != {len(b)}"
        for index, (left, right) in enumerate(zip(a, b)):
            difference = first_difference(left, right, f"{path}[{index}]")
            if difference:
                return difference
    elif a != b:
        return f"{path}: {a!r} != {b!r}"
    return None


def run_godot(godot, project, script, arguments, log, timeout):
    project = Path(project).resolve()
    script = Path(script)
    script = script if script.is_absolute() else project / script
    executable = relative_path(Path(godot).resolve(), project) if os.path.dirname(godot) else godot
    arguments = [relative_path(arg, project) if isinstance(arg, Path) else str(arg) for arg in arguments]
    cmd = [executable, "--headless", "--path", ".", "-s", relative_path(script, project), "--", *arguments]
    # /usr/bin/time reports per-process peak RSS; getrusage's cumulative max cannot.
    timed = ["/usr/bin/time", "-l" if sys.platform == "darwin" else "-v", *cmd]
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.perf_counter()
    with subprocess.Popen(timed, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True, cwd=project) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Stop our entire time/Godot process group; never leave a benchmark child running.
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            log.write_text(redact_paths(stdout + stderr, root=project))
            raise RuntimeError(f"Godot timed out after {timeout}s; see {display_path(log, root=ROOT)}") from None
        completed = subprocess.CompletedProcess(timed, process.returncode, stdout, stderr)
    wall = time.perf_counter() - started
    usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    output = completed.stdout + completed.stderr
    log.write_text(redact_paths(output, root=project))
    if completed.returncode or "SCRIPT ERROR:" in output or "\nERROR:" in output:
        raise RuntimeError(redact_paths(
            f"Godot failed ({completed.returncode}); see {display_path(log, root=ROOT)}\n{output[-3000:]}", root=project))
    if sys.platform == "darwin":
        match = re.search(r"(\d+)\s+maximum resident set size", completed.stderr)
        peak_bytes = int(match.group(1)) if match else None
    else:
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", completed.stderr)
        peak_bytes = int(match.group(1)) * 1024 if match else None
    return {"wall_seconds": wall, "user_seconds": usage_after.ru_utime - usage_before.ru_utime,
            "system_seconds": usage_after.ru_stime - usage_before.ru_stime,
            "peak_rss_bytes": peak_bytes, "log": display_path(log, root=ROOT)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--current", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--equivalence-only", action="store_true")
    args = parser.parse_args()
    if args.repetitions < 3 and not args.equivalence_only:
        parser.error("正式基准至少重复 3 次")
    if args.warmups < 0:
        parser.error("warmups must be non-negative")
    projects = {"baseline": args.baseline.resolve(), "optimized": args.current.resolve()}
    args.output.mkdir(parents=True, exist_ok=True)
    args.output = args.output.resolve()
    source_before = {label: fingerprint(project) for label, project in projects.items()}
    if source_before["baseline"]["data/cards.json"] != source_before["optimized"]["data/cards.json"]:
        raise RuntimeError("卡表不同，不能作为等价性能对照")
    for project in projects.values():
        target = project / "tools/ai_equivalence_probe.gd"
        if target.resolve() != PROBE.resolve():
            shutil.copyfile(PROBE, target)
    report = {"projects": {k: display_path(v, root=ROOT) for k, v in projects.items()}, "sources": source_before,
              "protocol": {"seed": 1001, "pairs": 1, "max_rounds": 4, "strength": 1,
                           "repetitions": args.repetitions, "warmups": args.warmups},
              "equivalence": {}, "measurements": []}
    for mode in ["cases", "games"]:
        outputs = {}
        for label, project in projects.items():
            output = args.output / f"{label}-{mode}.json"
            timing = run_godot(args.godot, project, "tools/ai_equivalence_probe.gd", [mode, output],
                               args.output / f"{label}-{mode}.log", args.timeout)
            result = read(output)
            if result["failures"]:
                raise RuntimeError(f"{label} probe failures: {result['failures']}")
            outputs[label] = result["payload"]
            report["equivalence"][f"{label}-{mode}"] = timing
            print(f"{label} {mode}: {timing['wall_seconds']:.3f}s", flush=True)
        difference = first_difference(outputs["baseline"], outputs["optimized"])
        if difference:
            raise RuntimeError(f"{mode} equivalence mismatch: {difference}")
        report["equivalence"][mode + "_identical"] = True
        save(args.output / "summary.json", report)
    # Freeze real pre-action positions from the baseline trajectory. Both engines receive
    # exactly the same snapshots; building positions and process startup are outside timers.
    starts = [event["round_start"] for event in read(args.output / "baseline-games.json")["payload"][0]["trace"]
              if "round_start" in event]
    positions = []
    for name, state, strength in [("opening-low", starts[0], 0), ("opening-mid", starts[0], .45),
                                  ("opening-full", starts[0], 1), ("later-full", starts[min(1, len(starts)-1)], 1)]:
        snapshot = {key: state[key] for key in ["players", "market", "combos", "winner", "win_reason", "uid", "rng", "stats"]}
        snapshot.update(round_num=state["round"], draw_first=state["first"], log=[])
        positions.append({"name": name, "seat": "ai", "strength": strength, "snapshot": snapshot})
    decision_input = args.output / "fixed-decisions-input.json"
    save(decision_input, {"schema": "ai-fixed-decisions-v1", "positions": positions,
                          "warmups": max(1, args.warmups), "repetitions": args.repetitions})
    decisions = {}
    report["decision_timings"] = {}
    for label, project in projects.items():
        output = args.output / f"{label}-decisions.json"
        run_godot(args.godot, project, str(ROOT / "tools/ai_decision_probe.gd"), ["fixed", decision_input, output],
                  args.output / f"{label}-decisions.log", args.timeout)
        decisions[label] = read(output)
        report["decision_timings"][label] = decisions[label]["timings"]
        print(f"{label} fixed decisions complete", flush=True)
    difference = first_difference(decisions["baseline"]["payload"], decisions["optimized"]["payload"])
    if difference:
        raise RuntimeError(f"Fixed-decision mismatch: {difference}")
    report["equivalence"]["fixed_decisions_identical"] = True
    save(args.output / "summary.json", report)
    if not args.equivalence_only:
        reference = None
        for iteration in range(-args.warmups, args.repetitions):
            for label, project in projects.items():
                tag = f"{label}-{'warmup' if iteration < 0 else 'sample'}-{abs(iteration)}"
                output = args.output / (tag + ".json")
                request = args.output / (tag + "-request.json")
                save(request, {"schema": "manual-balance-request-v1",
                               "cards_path": relative_path(projects["baseline"] / "data/cards.json", project),
                               "output_path": relative_path(output, project),
                               "progress_path": relative_path(args.output / (tag + "-progress.json"), project),
                               "options": {"pairs": 1, "max_rounds": 4, "seed_start": 1001,
                                           "model": "ai", "strength": 1, "ai_parameters": {}}})
                timing = run_godot(args.godot, project, "tools/eval_report.gd", [request],
                                   args.output / (tag + ".log"), args.timeout)
                result = read(output)
                if result.get("status") != "complete":
                    raise RuntimeError(f"Incomplete benchmark: {display_path(output, root=ROOT)}")
                comparable = {"games": result["games"], "metrics": result["metrics"],
                              "parameters": result["meta"]["ai_parameters"]}
                if reference is None:
                    reference = comparable
                difference = first_difference(reference, comparable)
                if difference:
                    raise RuntimeError(f"Benchmark trajectory/metric mismatch: {tag}: {difference}")
                timing.update(label=label, iteration=iteration, warmup=iteration < 0,
                              engine_seconds=result["meta"]["elapsed_seconds"])
                report["measurements"].append(timing)
                save(args.output / "summary.json", report)
                print(f"{tag}: engine={timing['engine_seconds']:.6f}s wall={timing['wall_seconds']:.3f}s rss={timing['peak_rss_bytes']}", flush=True)
        report["summary"] = {}
        for label in projects:
            rows = [row for row in report["measurements"] if row["label"] == label and not row["warmup"]]
            report["summary"][label] = {key: {"median": statistics.median(row[key] for row in rows),
                                                       "max": max(row[key] for row in rows)}
                                        for key in ["wall_seconds", "engine_seconds", "peak_rss_bytes"]}
        report["summary"]["engine_speedup"] = (report["summary"]["baseline"]["engine_seconds"]["median"] /
                                                report["summary"]["optimized"]["engine_seconds"]["median"])
    source_after = {label: fingerprint(project) for label, project in projects.items()}
    if source_after != source_before:
        raise RuntimeError("测量期间引擎/配置源码改变，结果无效；请冻结后重跑")
    report["sources_unchanged"] = True
    save(args.output / "summary.json", report)
    print(f"全部等价检查通过；结果 {display_path(args.output / 'summary.json', root=ROOT)}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(redact_paths(traceback.format_exc(), root=ROOT))
