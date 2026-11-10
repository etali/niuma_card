#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Summarize exact-scenario growth benchmarks; no Godot runs or verdicts.

python3 tools/off_work_growth_compare.py --directory reports/... --output reports/.../comparison.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
from collections import Counter
from pathlib import Path


WORK_INTENTS = {"assemble_work", "staff", "staff_batch", "split_work", "overtime", "overtime_batch"}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def trace_rows(path):
    trace = Path(str(path) + ".jsonl")
    if not trace.exists():
        return []
    rows = []
    with trace.open() as source:
        for line in source:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                # An in-progress final line does not invalidate preceding
                # complete events. Completed results are required separately.
                break
    return rows


def scenario_name(request):
    fixture = request.get("fixture", {})
    if not fixture:
        return f"replay{request.get('start', 0):g}"
    if fixture.get("disable_market"):
        return "self-supply-suppressed"
    if fixture.get("conveyor_pool"):
        return "self-supply-known-supply"
    return "facilities"


def version_name(path):
    for marker in ("-facilities", "-replay", "-self-supply"):
        if marker in path.stem:
            return path.stem.split(marker, 1)[0]
    return path.stem


def delay_summary(entries):
    values = [entry["delay_seconds"] for entry in entries if entry["delay_seconds"] is not None]
    return {
        "count": len(entries), "deployed": len(values), "not_deployed": len(entries) - len(values),
        "mean_seconds": statistics.mean(values) if values else None,
        "max_seconds": max(values) if values else None,
        "unapplied_max_observed_seconds": max(
            (entry["observed_seconds"] for entry in entries if entry["delay_seconds"] is None), default=None),
    }


def load_run(path):
    report = json.loads(path.read_text())
    if report.get("error") or not all(key in report for key in ("request", "sides", "final", "end_time")):
        return None
    rows = trace_rows(path)
    opening = next((row for row in rows if row.get("type") == "opening"), {})
    request = report["request"]
    owner = int(request.get("owner", 1))
    side = report["sides"][owner]
    cards = opening.get("cards")
    # Older reports did not record effective-card hashes; their opening trace
    # still contains the exact table, including all explicit fixture changes.
    table_hash = fingerprint(cards) if cards else report.get("effective_card_document_sha256")
    if table_hash is None:
        table_hash = "unknown-effective-table:" + str(path.resolve())
    fixture = request.get("fixture", {})
    conditions = {
        "effective_table_sha256": table_hash,
        "start_time": report["start_time"], "seconds": request.get("seconds", 60),
        "seed": request.get("seed", 20261110), "owner": owner,
        "strength": request.get("strength", .5), "budget_ms": report.get("budget_ms"),
        "think_seconds": report.get("actual_policy", {}).get("think_seconds"),
        "opponent": request.get("opponent", "inactive"),
        "opponent_mode": request.get("opponent_mode", "growth"),
        "opponent_think_seconds": request.get("opponent_think_seconds", 6),
        "initial_market_cleared": bool(fixture.get("clear_market", False)),
        "market_cleared_before_each_decision": bool(fixture.get("disable_market", False)),
        "godot": report.get("godot"),
    }
    events = [event for row in rows if row.get("type") == "events"
              for event in row.get("events", []) if event.get("owner") == owner]
    hires = {person for event in events if event.get("kind") == "recruitment_complete" for person in event["ids"]}
    if not hires:
        hires = {person for batch in side.get("recruitment_batches", []) for person in batch["ids"]}
    participations = sum(len(hires.intersection(event.get("participants", [])))
                         for event in events if event.get("kind") == "work_complete")
    if not events and side.get("recruitment_batches"):
        values = [batch.get("work_participations") for batch in side["recruitment_batches"]]
        participations = sum(values) if all(value is not None for value in values) else None
    work_roles = {name for name, definition in (cards or {}).get("roles", {}).items() if definition.get("can_work")}
    capacity_one = bool(work_roles) and all(cards["roles"][name].get("work_capacity") == 1 for name in work_roles)
    deployments = {}
    for row in rows:
        if row.get("type") != "decision" or row.get("owner") != owner or not row.get("applied"):
            continue
        action = row.get("action", {})
        if action.get("kind") == "move" and action.get("intent") in WORK_INTENTS:
            for person in action.get("ids", []):
                deployments.setdefault(person, float(row["time"]))
    staff_delays, overtime_delays = [], []
    for purchase in side.get("purchases", []):
        kind = purchase["type"]
        if kind not in work_roles and kind != "overtime":
            continue
        deployed = deployments.get(purchase["id"])
        # Modern summaries observe actual tasks; prefer them to reconstruction.
        if kind in work_roles and float(purchase.get("first_work", -1)) >= 0:
            deployed = float(purchase["first_work"])
        if kind == "overtime" and float(purchase.get("first_use", -1)) >= 0:
            deployed = float(purchase["first_use"])
        entry = {"id": purchase["id"], "type": kind, "at": purchase["at"], "first_work": deployed,
                 "delay_seconds": deployed - purchase["at"] if deployed is not None else None,
                 "observed_seconds": report["end_time"] - purchase["at"]}
        (overtime_delays if kind == "overtime" else staff_delays).append(entry)
    final = report["final"][owner]
    metrics = {
        "natural_work_completed": side.get("work_completed"),
        "outsource_completed": sum(event.get("amount", 0) for event in events if event.get("kind") == "outsource"),
        "remaining_work": final.get("work"), "wages": side.get("wages"), "remaining_money": final.get("money"),
        "final_work_rate": final.get("work_rate"), "peak_work_rate": side.get("max_work_rate"),
        "final_workers": final.get("workers"), "peak_workers": side.get("max_workers"),
        "recruitment_batches": len(side.get("recruitment_batches", [])), "recruited": side.get("recruited"),
        "recruited_work_participations": participations,
        "recruited_work_units": participations if capacity_one else None,
        "recruitment_spent": side.get("recruitment_spent"),
        "wages_reinvested_lower_bound": side.get("wages_reinvested_lower_bound"),
        "slack_batches": side.get("slack_batches"), "coffee_produced": side.get("coffee_produced"),
        "coffee_consumed": side.get("coffee_consumed"), "coffee_remaining": final.get("coffee"),
        "upgrades": len(side.get("upgrades", [])), "highest_upgrade_rank": side.get("max_coffee_rank"),
        "purchases_by_type": dict(Counter(purchase["type"] for purchase in side.get("purchases", []))),
        "upgrades_by_target": dict(Counter(event["to_type"] for event in side.get("upgrades", []))),
        "bought_staff_deployment": delay_summary(staff_delays), "bought_overtime_deployment": delay_summary(overtime_delays),
        "apply_failures": side.get("apply_failures"), "over_budget": side.get("over_budget"),
        "decisions": side.get("decisions"), "decision_us": side.get("decision_us"),
    }
    return {"path": str(path.resolve()), "version": version_name(path), "scenario": scenario_name(request),
            "conditions": conditions, "condition_sha256": fingerprint(conditions), "metrics": metrics,
            "engine_source_sha256": report.get("engine_source_sha256", opening.get("engine_source_sha256")),
            "source_identity_status": "recorded_at_initialization" if report.get("engine_source_sha256") else "not_recorded",
            "actual_policy": report.get("actual_policy", {}),
            "supply_conditions": request.get("supply_conditions", {
                "effective_conveyor": (cards or {}).get("rules", {}).get("conveyor"),
                "initial_market_cleared": conditions["initial_market_cleared"],
                "market_cleared_before_each_decision": conditions["market_cleared_before_each_decision"],
                "diagnostic_only": conditions["market_cleared_before_each_decision"]}),
            "details": {"staff_deployment": staff_delays, "overtime_deployment": overtime_delays}}


def numeric_delta(new, old):
    output = {}
    for key in new.keys() | old.keys():
        left, right = new.get(key), old.get(key)
        if isinstance(left, dict) and isinstance(right, dict):
            output[key] = numeric_delta(left, right)
        elif isinstance(left, (int, float)) and isinstance(right, (int, float)):
            output[key] = left - right
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--baseline", default="baseline", help="Exact filename version prefix")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    runs, skipped = [], []
    for path in sorted(args.directory.glob("*.json")):
        if path.resolve() == args.output.resolve() or path.name.endswith(".request.json"):
            continue
        try:
            run = load_run(path)
        except (ValueError, KeyError, TypeError) as error:
            skipped.append({"path": str(path), "error": str(error)})
            continue
        if run:
            runs.append(run)
    baselines = {}
    for run in runs:
        if run["version"] == args.baseline:
            baselines.setdefault(run["condition_sha256"], []).append(run)
    comparisons, unpaired = [], []
    for run in runs:
        if run["version"] == args.baseline:
            continue
        matches = baselines.get(run["condition_sha256"], [])
        if len(matches) != 1:
            unpaired.append({"path": run["path"], "reason": "no unique exact-condition baseline", "matches": len(matches)})
            continue
        baseline = matches[0]
        policy_keys = run["actual_policy"].keys() | baseline["actual_policy"].keys()
        comparisons.append({"baseline": baseline["path"], "candidate": run["path"],
                            "scenario": run["scenario"], "strength": run["conditions"]["strength"],
                            "condition_sha256": run["condition_sha256"],
                            "policy_changes": {key: {"baseline": baseline["actual_policy"].get(key), "candidate": run["actual_policy"].get(key)}
                                               for key in sorted(policy_keys) if baseline["actual_policy"].get(key) != run["actual_policy"].get(key)},
                            "delta_candidate_minus_baseline": numeric_delta(run["metrics"], baseline["metrics"])})
    result = {"runs": runs, "comparisons": comparisons, "unpaired": unpaired, "skipped": skipped,
              "metric_definitions": {
                  "recruited_work_units": "Real work_complete participants belonging to recorded recruitment batches; only labelled work units when every worker role has capacity 1.",
                  "deployment": "Actual task observations, or successful recorded work-assembly commands for older traces; unused purchases remain censored, not assigned zero delay.",
                  "source_identity": "Older runs without initialization fingerprints remain unknown; current source hashes are never backfilled.",
                  "pairing": "Same effective card document, start, seed, owner, strength, budget, cadence, supply handling, opponent and Godot version; no verdict or win-rate inference."}}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("version\tscenario\tstrength\twork\thires/batches\thire-work\tcoffee/used/upgrades\tfinal-rate\tstaff-delay-max\tover-budget")
    for run in runs:
        m = run["metrics"]
        print("\t".join(map(str, [run["version"], run["scenario"], run["conditions"]["strength"],
              m["natural_work_completed"], f'{m["recruited"]}/{m["recruitment_batches"]}', m["recruited_work_units"],
              f'{m["coffee_produced"]}/{m["coffee_consumed"]}/{m["upgrades"]}', m["final_work_rate"],
              m["bought_staff_deployment"]["max_seconds"], m["over_budget"]])))
    print(f"comparisons={len(comparisons)} unpaired={len(unpaired)} skipped={len(skipped)} output={args.output}")


if __name__ == "__main__":
    main()
