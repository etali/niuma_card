#!/usr/bin/env python3
"""Immutable paired-seat off-work BOT evaluation against frozen and scripted opponents.

No replay or future market sequence is supplied to a player. Exploration and
holdout use disjoint declared seeds. The statistical gate is the existing
12-pair / 60% / paired-bootstrap lower bound > 50% gate, without timeout credit.
The separate capabilities suite compares real objective completion times against
an uncontested scripted reference; those trials never enter race win rates.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

from off_work_check_bot_strength import same_profile, summarize

ROOT = Path(__file__).resolve().parents[1]
LEGACY_FILES = ["off_work_bot.gd", "off_work_bot_planner.gd", "off_work_bot_reply.gd",
                "off_work_bot_tree.gd", "off_work_config.gd", "off_work_bot_preferences.gd", "config_data.gd"]
RUNNER = "tools/balance/off_work_benchmark.gd"
SCRIPTED = "tools/balance/off_work_scripted_baseline.gd"
SCENARIOS = "tools/balance/off_work_benchmark_scenarios.gd"
RUNTIME_FILES = ["project.godot", ".godot/global_script_class_cache.cfg", RUNNER, SCRIPTED, SCENARIOS,
                 "tools/off_work_benchmark_bot.py", "tools/off_work_check_bot_strength.py"]
LEVELS = {"min": 0.0, "low": .25, "mid": .5, "high": .75, "max": 1.0}
COMPARISONS = {
    "legacy-native": ("current:max", "legacy:max", "default"),
    "legacy-2s": ("current:max:2s", "legacy:max", "default"),
    "script-growth": ("current:max", "script:growth", "default"),
    "script-overtime": ("current:max", "script:overtime", "default"),
    "min:low": ("current:low", "current:min", "default"),
    "low:mid": ("current:mid", "current:low", "default"),
    "mid:high": ("current:high", "current:mid", "default"),
    "high:max": ("current:max", "current:high", "default"),
}
CAPABILITIES = {
    "production": ("current:max", "script:production", "production"),
    "overtime": ("current:max", "script:overtime", "overtime"),
    "recovery": ("current:max", "script:recovery", "recovery"),
    "outsource": ("current:max", "script:outsource", "outsource"),
}
CAPABILITY_GOALS = {"production": "第19名员工使19份工作一批完工，批量编组无旧10人上限；19人实际参与生产不晚于参考脚本",
                    "overtime": "7 overtime cards installed in staffed production groups",
                    "recovery": "all 18 strikers actually back in production",
                    "outsource": "a real 48-document outsource batch completed with no work left"}
_running = set()
_lock = threading.Lock()
_stopping = threading.Event()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temp.replace(path)


def legacy_source(name, text):
    """Namespace/config-source changes only; all action/search expressions stay frozen."""
    text = re.sub(r"^class_name \w+\s*\n", "", text, flags=re.M)
    for filename in LEGACY_FILES:
        text = text.replace("res://engine/" + filename, "res://benchmark_legacy/engine/" + filename)
    if name == "config_data.gd":
        text = text.replace("res://data/", "res://benchmark_legacy/data/")
    if name == "off_work_bot.gd":
        # V8 expected these compatibility defaults on the live config. V2 may
        # remove them; resolve that constructor dependency from frozen V8 too.
        text = text.replace("state.config.bot_algorithm_defaults", "Config.new().bot_algorithm_defaults")
        text = text.replace("state.config.rules.bot if policy.is_empty()", "Config.new().rules.bot if policy.is_empty()")
    # Planner/tree also merge a base policy internally. That base must be
    # frozen even when every V8 action parameter is explicitly overridden.
    needs_base = "game.config.rules.bot" in text
    text = text.replace("game.config.rules.bot", "_legacy_base_policy")
    if needs_base or re.search(r"\bOffWorkConfig\b", text):
        text = re.sub(r"\bOffWorkConfig\b", "LegacyConfig", text)
        declaration = 'const LegacyConfig = preload("res://benchmark_legacy/engine/off_work_config.gd")\n'
        if needs_base:
            # Load once, outside timed searches. Parsing the JSON at every
            # planner node would unfairly consume the frozen BOT's budget.
            declaration += 'static var _legacy_base_policy: Dictionary = LegacyConfig.new().rules.bot\n'
        text = text.replace("extends RefCounted\n", 'extends RefCounted\n' + declaration, 1)
    if re.search(r"\bOffWorkBot\b", text):
        raise ValueError(f"Unisolated legacy BOT class reference in {name}")
    # OffWorkState deliberately remains the current shared rules implementation.
    for dependency in re.findall(r'(?:preload|load)\("(res://[^\"]+)"\)', text):
        if dependency.startswith("res://engine/off_work_bot") or dependency == "res://engine/off_work_config.gd":
            raise ValueError(f"Unisolated legacy dependency: {dependency}")
    return text


def snapshot_runtime(destination, baseline, root=ROOT):
    destination.mkdir(parents=True)
    sources = [root / relative for relative in RUNTIME_FILES]
    sources += [path for directory in ("engine", "data") for path in (root / directory).rglob("*") if path.is_file()]
    before_sources = {str(path): digest(path) for path in sources}
    for relative in RUNTIME_FILES:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
    for directory in ("engine", "data"):
        shutil.copytree(root / directory, destination / directory)
    after_sources = [root / relative for relative in RUNTIME_FILES]
    after_sources += [path for directory in ("engine", "data") for path in (root / directory).rglob("*") if path.is_file()]
    if set(sources) != set(after_sources):
        raise ValueError("Product files changed while freezing runtime")
    if any(digest(path) != before_sources[str(path)] or digest(destination / path.relative_to(root)) != before_sources[str(path)] for path in sources):
        raise ValueError("Product source changed while freezing runtime; prepare a new empty run after integration")
    archived = json.loads((baseline / "manifest.json").read_text())
    provenance = {}
    selected = ["engine/" + name for name in LEGACY_FILES] + ["data/off_work_bot.json", "data/off_work_cards.json"]
    for relative in selected:
        source = baseline / relative
        before = digest(source)
        if archived.get(relative) != before:
            raise ValueError("Frozen baseline checksum mismatch: " + relative)
        target = destination / "benchmark_legacy" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix == ".gd":
            target.write_text(legacy_source(source.name, source.read_text()))
        else:
            shutil.copy2(source, target)
        provenance[relative] = {"archived_sha256": before, "isolated_sha256": digest(target)}
    manifest = {p.relative_to(destination).as_posix(): digest(p)
                for p in sorted(destination.rglob("*")) if p.is_file()}
    fingerprint = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    record = {"fingerprint": fingerprint, "files": manifest, "legacy": provenance,
              "legacy_source": str(baseline), "legacy_manifest_sha256": digest(baseline / "manifest.json"),
              "legacy_transform": "remove class_name; redirect frozen Config/Bot dependencies and all constructor/planner/tree base policy sources; retain current OffWorkState"}
    write_json(destination / "benchmark_manifest.json", record)
    return record


def run_request(godot, runtime, folder, request, timeout):
    folder.mkdir(parents=True, exist_ok=False)
    source, target = folder / "request.json", folder / "result.json"
    write_json(source, request)
    env = os.environ.copy()
    env["CARD_DATA_DIR"] = str(folder / "player-data")
    env["WORK_DATA_DIR"] = str(folder / "player-data" / "off_work")
    with (folder / "engine.log").open("w") as log:
        with _lock:
            if _stopping.is_set(): raise RuntimeError("benchmark cancelled before process launch")
            process = subprocess.Popen([godot, "--headless", "--path", str(runtime), "--script", "res://" + RUNNER,
                                        "--", "--request=" + str(source), "--output=" + str(target)],
                                       cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            _running.add(process)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            failure = {"error": "wall_timeout", "wall_timeout_seconds": timeout, "request": request}
            write_json(folder / "failure.json", failure)
            raise RuntimeError("wall_timeout: " + str(folder))
        finally:
            with _lock:
                _running.discard(process)
    text = (folder / "engine.log").read_text()
    if code or "SCRIPT ERROR:" in text or not target.exists():
        write_json(folder / "failure.json", {"error": "engine_failure", "exit_code": code,
                   "result_exists": target.exists(),
                   "script_errors": [line for line in text.splitlines() if "SCRIPT ERROR:" in line][:20],
                   "note": "A result file cannot count as valid when the engine reported script errors; the full log and any result are retained."})
        raise RuntimeError("engine_failure: " + str(folder))
    result = json.loads(target.read_text())
    if result.get("error"):
        write_json(folder / "failure.json", {"error": "runner_error", "detail": result["error"]})
        raise RuntimeError(result["error"])
    return result


def validate_report(report, request, definition):
    if report.get("simulator_fingerprint") != definition["simulator_fingerprint"] or report.get("godot_version") != definition["godot_version"]:
        raise ValueError("Mixed runtime or Godot version")
    if not same_profile(report.get("profiles"), {key: request[key] for key in ("a", "b")}):
        raise ValueError("Requested player definitions differ from actual report")
    if request.get("suite") == "capabilities":
        trials = report.get("trials", [])
        if len(trials) != 4 or {(t.get("side"), t.get("seat")) for t in trials} != {(side, seat) for side in ("a", "b") for seat in (0, 1)}:
            raise ValueError("Incomplete independent capability trials")
        for trial in trials:
            if trial.get("seed") != request["seed"] or trial.get("scenario") != request["scenario"]:
                raise ValueError("Capability seed or scenario mismatch")
            if not same_profile(trial["actual_policy"], request[trial["side"]]["policy"]):
                raise ValueError("Capability controller changed its declared policy")
        return
    matches = report.get("matches", [])
    if len(matches) != 2 or {g.get("a_seat") for g in matches} != {0, 1}:
        raise ValueError("Incomplete swapped-seat pair")
    for game in matches:
        if game.get("seed") != request["seed"] or game.get("scenario") != request["scenario"]:
            raise ValueError("Seed or scenario mismatch")
        for side in ("a", "b"):
            if not same_profile(game["actual_policies"][side], request[side]["policy"]):
                raise ValueError("The instantiated BOT changed its frozen policy")


def summarize_capabilities(reports):
    """No wins/CI: each side is run independently, against the same real rules."""
    for key in ("simulator_fingerprint", "godot_version", "profiles"):
        if len({json.dumps(report.get(key), sort_keys=True) for report in reports}) > 1:
            raise ValueError("Cannot aggregate mixed capability " + key)
    rows = []
    seeds = set()
    for report in reports:
        trials = report["trials"]
        seed = trials[0]["seed"]
        if seed in seeds:
            raise ValueError("Repeated capability seed")
        seeds.add(seed)
        for seat in (0, 1):
            current = next(t for t in trials if t["side"] == "a" and t["seat"] == seat)
            reference = next(t for t in trials if t["side"] == "b" and t["seat"] == seat)
            passed = (current["achieved"] and reference["achieved"] and
                      current["seconds"] <= reference["seconds"] + 1e-7 and
                      all(t["decision_stats"]["apply_failures"] == 0 and t["decision_stats"]["over_budget"] == 0
                          for t in (current, reference)))
            rows.append({"seed": seed, "seat": seat, "current_achieved": current["achieved"],
                         "reference_achieved": reference["achieved"], "current_seconds": current["seconds"],
                         "reference_seconds": reference["seconds"], "current_observed": current["observed"],
                         "reference_observed": reference["observed"], "passed": bool(passed)})
    rows.sort(key=lambda row: (row["seed"], row["seat"]))
    return {"seed_pairs": len(reports), "independent_trials": len(rows) * 2, "cases": rows,
            "passed": bool(rows) and all(row["passed"] for row in rows),
            "note": "Capability only: achieve the declared objective no later than the uncontested scripted reference on both seats; never pooled with race scores."}


def player(name, definition):
    parts = name.split(":")
    kind, mode = parts[:2]
    if kind == "script":
        return {"kind": kind, "mode": mode, "model": "scripted_race_v1", "policy": {"algorithm": "scripted_race_v1", "mode": mode,
                "enabled": True, "think_seconds": 2.0, "first_action_seconds": 0.0}}
    policy = dict(definition["legacy_max"] if kind == "legacy" else definition["current_profiles"][mode])
    if parts[-1] == "2s":
        policy["think_seconds"] = 2.0
    return {"kind": kind, "mode": mode, "model": definition.get("models", {}).get(kind, "baseline_v8" if kind == "legacy" else "race_search_v2"), "policy": policy}


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="race comparisons: " + ", ".join(COMPARISONS) +
                                     "; capability comparisons: " + ", ".join(CAPABILITIES))
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, default=ROOT / "reports/off-work-bot-refactor/baseline-v8")
    parser.add_argument("--phase", choices=["exploration", "holdout"], required=True)
    parser.add_argument("--suite", choices=["race", "capabilities"], default="race")
    parser.add_argument("--pairs", type=int, help="Default: 12 for race, 1 for capabilities")
    parser.add_argument("--seed-start", type=int, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--max-seconds", type=float, default=600)
    parser.add_argument("--wall-timeout", type=float, default=3600)
    parser.add_argument("--minimum-pairs", type=int, default=12)
    parser.add_argument("--comparisons", help="Comma-separated names from the selected suite; defaults to all")
    parser.add_argument("--exploration", type=Path, nargs="*", default=[])
    parser.add_argument("--prepare-only", action="store_true", help="Freeze and validate policy definitions without playing matches")
    parser.add_argument("--godot", default=os.environ.get("GODOT", shutil.which("godot")))
    args = parser.parse_args()
    if args.pairs is None: args.pairs = 12 if args.suite == "race" else 1
    if not args.godot or min(args.pairs, args.seed_start, args.jobs, args.max_seconds, args.wall_timeout, args.minimum_pairs) <= 0:
        parser.error("Godot and positive counts/times are required")
    if not all(math.isfinite(value) for value in (args.max_seconds, args.wall_timeout)) or args.seed_start + args.pairs - 1 > 9007199254740991:
        parser.error("Times must be finite and seeds must be exactly representable JSON integers")
    catalogue = COMPARISONS if args.suite == "race" else CAPABILITIES
    names = args.comparisons.split(",") if args.comparisons else list(catalogue)
    if len(names) != len(set(names)) or any(name not in catalogue for name in names):
        parser.error("Comparisons must be distinct supported names")
    excluded = set()
    for directory in args.exploration:
        prior = json.loads((directory / "definition.json").read_text())
        excluded.update(prior["seeds"])
    seeds = list(range(args.seed_start, args.seed_start + args.pairs))
    if args.phase == "holdout" and (not args.exploration or excluded.intersection(seeds)):
        parser.error("Holdout requires recorded exploration and disjoint seed ranges")
    store = args.store.resolve()
    store.mkdir(parents=True, exist_ok=True)
    if any(store.iterdir()):
        parser.error("Store must be empty; prior games cannot be selectively reused")
    runtime = store / "runtime"
    manifest = snapshot_runtime(runtime, args.baseline.resolve())
    defaults = run_request(args.godot, runtime, store / "definition", {"definition_only": True}, args.wall_timeout)
    comparisons = {name: {"a": player(catalogue[name][0], defaults), "b": player(catalogue[name][1], defaults),
                          "scenario": catalogue[name][2], "suite": args.suite} for name in names}
    definition = {"phase": args.phase, "suite": args.suite, "seeds": seeds, "comparisons": comparisons,
                  "command": sys.argv,
                  "max_seconds": args.max_seconds, "wall_timeout_seconds": args.wall_timeout, "jobs": args.jobs,
                  "minimum_pairs": max(12, args.minimum_pairs) if args.suite == "race" else 1,
                  "exploration_directories": [str(p.resolve()) for p in args.exploration],
                  "machine": {"os": platform.system(), "architecture": platform.machine(), "logical_cpus": os.cpu_count()},
                  "excluded_exploration_seeds": sorted(excluded), "runtime": manifest, "definition": defaults,
                  "gate": ("Each declared normal-opening comparison: >=12 paired seeds, score>=0.60, paired bootstrap 95% lower>0.50, zero timeouts/errors" if args.suite == "race" else
                           "Independent uncontested trials on both seats: every objective achieved no later than the scripted reference, zero illegal actions or budget overruns; no win-rate claim"),
                  "capability_goals": CAPABILITY_GOALS if args.suite == "capabilities" else {},
                  "diagnostics": "All requests, all seat games, all decisions/publications, compressed public state snapshots and events are retained"}
    write_json(store / "definition.json", definition)
    if args.prepare_only:
        print("PREPARED " + str(store / "definition.json"))
        return 0
    reports = {name: [] for name in names}
    failures = []
    started = time.monotonic()
    pool = ThreadPoolExecutor(max_workers=args.jobs)
    pending = {}
    try:
        for seed in seeds:
            for name, comparison in comparisons.items():
                request = {**comparison, "seed": seed, "max_seconds": args.max_seconds}
                future = pool.submit(run_request, args.godot, runtime, store / name.replace(":", "-") / str(seed), request, args.wall_timeout)
                pending[future] = (name, request)
        for future in as_completed(pending):
            name, request = pending[future]
            try:
                report = future.result()
                validate_report(report, request, defaults)
                reports[name].append(report)
            except Exception as error:
                failures.append({"comparison": name, "seed": request["seed"], "error": str(error)})
            summaries = {key: (summarize(value, args.minimum_pairs) if args.suite == "race" else summarize_capabilities(value)) for key, value in reports.items()}
            complete = sum(len(value) for value in reports.values()) + len(failures) == len(pending)
            summary = {"phase": args.phase, "suite": args.suite, "acceptance_scope": args.suite,
                       "status": "complete" if complete else "running", "failures": failures,
                       "wall_timeouts":sum("wall_timeout" in entry["error"] for entry in failures),
                       "elapsed_seconds": time.monotonic() - started, args.suite: summaries,
                       "completed_pairs": sum(len(value) for value in reports.values()), "expected_pairs": len(pending),
                       "passed": complete and args.phase == "holdout" and not failures and all(value["passed"] for value in summaries.values())}
            write_json(store / "summary.json", summary)
            print(json.dumps({"comparison": name, "seed": request["seed"], "completed_pairs": summary["completed_pairs"],
                              "failed_pairs": len(failures), **summaries[name]}, ensure_ascii=False), flush=True)
    except BaseException as error:
        _stopping.set()
        write_json(store / "interruption.json", {"reason": type(error).__name__, "detail": str(error),
                   "elapsed_seconds": time.monotonic() - started,
                   "unfinished": [{"comparison": name, "seed": request["seed"]}
                                  for future, (name, request) in pending.items() if not future.done()],
                   "note": "All request folders, partial engine logs and partial per-decision traces are retained; this run cannot be accepted as complete."})
        for future in pending: future.cancel()
        with _lock:
            for process in list(_running):
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
    return 0 if not failures and (args.phase == "exploration" or summary["passed"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
