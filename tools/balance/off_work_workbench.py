#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""《下班》本地 BOT 对战与调参工作台。"""
from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import re
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from .storage import read_json, atomic_json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

WEB = Path(__file__).resolve().parent
ROOT = WEB.parents[1]
DEFAULT_CARDS = ROOT / "data/off_work_cards.json"
DEFAULT_BOT = ROOT / "data/off_work_bot.json"
REPORTS = ROOT / "reports/balance_lab"
PLAYTEST_START_TIMEOUT = 30
DEFAULT_OPTIONS = {"seed": 1001, "pairs": 3, "max_seconds": 600}


def timestamp(seconds=None):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat() if seconds is not None else datetime.now(timezone.utc).isoformat()


def canonical(value):
    # JSON's 1 and 1.0 describe the same parameter and must share a saved version.
    if isinstance(value, dict):
        return {key: canonical(item) for key, item in value.items()}
    if isinstance(value, list):
        return [canonical(item) for item in value]
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def display_name(value, fallback):
    if value is None:
        return fallback
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 120:
        raise ValueError("配置名称和标签须为 1 到 120 个字符")
    return value.strip()


class ConfigConflict(ValueError):
    def __init__(self, payload):
        super().__init__(payload["error"])
        self.payload = payload


def canonical_kind(kind):
    return "bot" if kind == "ai" else kind


def normalize_job(record):
    if "kind" in record:
        record["kind"] = canonical_kind(record["kind"])
    if "ai" in record:
        record.setdefault("bot", record.pop("ai"))
    if record.get("label") in ("AI PK", "AI 对战"):
        record["label"] = record["label"].replace("AI", "BOT")
    return record


def config_id(kind, data):
    serialized = json.dumps(canonical(data), ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return kind + "_" + hashlib.sha256(serialized.encode()).hexdigest()


def runner_args(engine, folder):
    return [engine, "--headless", "--path", str(ROOT), "--script", "res://tools/balance/off_work_run.gd",
            "--", f"--request={folder / 'request.json'}", f"--output={folder / 'result.json'}"]


def result(folder, code):
    path = folder / "result.json"
    data = read_json(path) if path.is_file() else {}
    if not isinstance(data, dict):
        raise ValueError("实验报告必须是 JSON 对象")
    if code or "error" in data or not data:
        message = data.get("error")
        if not message:
            with (folder / "godot.log").open("rb") as log:
                log.seek(max(0, log.seek(0, os.SEEK_END) - 2000))
                message = log.read().decode("utf-8", errors="replace").strip()
        raise ValueError(message or f"Godot 未能生成报告（退出码 {code}）")
    return data


def count(value):
    if type(value) in (int, float) and 0 <= value <= 2**53 - 1 and int(value) == value:
        return int(value)
    return None


def measure(numerator, denominator, scale=100):
    return {"numerator": numerator, "denominator": denominator,
            "value": numerator / denominator * scale if denominator else None}


def legacy_balance_metrics(report, card_document):
    """Reconstruct only quantities observed in this report and its own card snapshot."""
    metrics = {"version": 1}
    games = count(report.get("games"))
    if games is None:
        counts = [count(report.get(field)) for field in ("a_wins", "b_wins", "draws", "timeouts")]
        if None not in counts:
            games = sum(counts)
    rows = report.get("matches")
    matches = rows if isinstance(rows, list) else []
    valid = [row for row in matches if isinstance(row, dict) and row.get("winner") in ("a", "b", "draw", "timeout")]
    complete = isinstance(rows, list) and len(valid) == len(rows) and games in (None, len(rows))

    def outcome_count(field, outcome):
        value = count(report.get(field))
        if value is None and complete:
            return sum(row["winner"] == outcome for row in valid)
        return value

    if games is None and complete:
        games = len(valid)
    timeouts = outcome_count("timeouts", "timeout")
    if games is not None and timeouts is not None and timeouts <= games:
        metrics["timeout_rate"] = measure(timeouts, games)
        finished = [row for row in valid if row["winner"] != "timeout"]
        if (len(finished) == games - timeouts and
                all(type(row.get("seconds")) in (float, int) and 0 <= row["seconds"] <= 2**53 - 1 for row in finished)):
            metrics["mean_finish_seconds"] = measure(sum(row["seconds"] for row in finished), len(finished), 1)
        elif timeouts == 0:
            seconds = report.get("simulated_seconds")
            if type(seconds) in (int, float) and 0 <= seconds <= games * (2**53 - 1):
                metrics["mean_finish_seconds"] = measure(seconds, games, 1)

    a_wins = outcome_count("a_wins", "a")
    b_wins = outcome_count("b_wins", "b")
    winners = [row for row in valid if row["winner"] in ("a", "b")]
    if (a_wins is not None and b_wins is not None and len(winners) == a_wins + b_wins
            and sum(row["winner"] == "a" for row in winners) == a_wins
            and all(count(row.get("a_seat")) in (0, 1) for row in winners)):
        seat0 = sum(row["a_seat"] == (0 if row["winner"] == "a" else 1) for row in winners)
        metrics["seat0_win_rate"] = measure(seat0, len(winners))

    cards = card_document.get("cards")
    purchases = report.get("purchases")
    if (isinstance(cards, dict) and cards and all(isinstance(card, dict) for card in cards.values())
            and isinstance(purchases, dict) and all(count(amount) is not None for amount in purchases.values())):
        available = [kind for kind, card in cards.items() if card.get("purchasable") is True]
        metrics["purchase_coverage"] = measure(sum(purchases.get(kind, 0) > 0 for kind in available), len(available))
    return metrics


def first_delays(report, request):
    """Use the actual policy when recorded, otherwise its own frozen request."""
    profiles = report.get("profiles")
    if not isinstance(profiles, dict):
        request = request or {}
        document = request.get("bot", request.get("ai", {}))
        base = document.get("bot", {}) if isinstance(document, dict) else {}
        profiles = {side: {**base, **request[side]} for side in ("a", "b")
                    if isinstance(base, dict) and isinstance(request.get(side), dict)}
    delays = []
    for side in ("a", "b"):
        policy = profiles.get(side)
        if not isinstance(policy, dict) or type(policy.get("enabled")) is not bool:
            return None
        if not policy["enabled"]:
            delays.append(float("inf"))
            continue
        delay = policy.get("first_action_seconds")
        if type(delay) not in (int, float) or not 0 <= delay <= 2**53 - 1:
            return None
        delays.append(delay)
    return delays


def first_seat(row, delays):
    if "first_seat" in row:
        value = row["first_seat"]
        return int(value) if type(value) in (int, float) and value in (-1, 0, 1) else None
    a_seat, seconds = count(row.get("a_seat")), row.get("seconds")
    if delays is None or a_seat not in (0, 1) or type(seconds) not in (int, float) or not 0 <= seconds <= 2**53 - 1:
        return None
    # Settlement and the time limit end a game before BOTs get another turn at
    # that timestamp. For a simultaneous opportunity the scheduler visits seat 0 first.
    if min(delays) >= seconds:
        return -1
    if delays[0] == delays[1]:
        return 0
    return a_seat if delays[0] < delays[1] else 1 - a_seat


def observed_legacy_metrics(report, cards, request):
    """Only backfill new measures when the old observations prove their value."""
    rows = report.get("matches")
    if not isinstance(rows, list) or count(report.get("games")) != len(rows) or not all(isinstance(r, dict) for r in rows):
        return {}
    result = {}
    delays = first_delays(report, request)
    wins = games = 0
    observed = False
    for row in rows:
        first = first_seat(row, delays)
        if first is None or row.get("winner") not in ("a", "b", "draw", "timeout"):
            continue
        observed = True
        if first == -1 or row["winner"] == "timeout":
            continue
        a_seat = count(row.get("a_seat"))
        if row["winner"] != "draw" and a_seat not in (0, 1):
            continue
        games += 1
        if (row["winner"] == "a" and first == a_seat) or (row["winner"] == "b" and first != a_seat):
            wins += 1
    if observed:
        result["first_player_win_rate"] = measure(wins, games)

    if all(type(row.get("seconds")) in (int, float) and 0 <= row["seconds"] <= 2**53 - 1 for row in rows):
        timed = [row for row in rows if row["seconds"] > 0]
        for key in ("upgrades", "tool_generations", "interferences"):
            if timed and all(count(row.get(key)) is not None for row in timed):
                result[key + "_per_minute"] = measure(sum(row[key] * 60 / row["seconds"] for row in timed), len(timed), 1)
        total = count(report["flow"].get("upgrades")) if isinstance(report.get("flow"), dict) else None
        if "upgrades_per_minute" not in result and timed and total is not None:
            # For nonnegative counts, a zero total proves every count was zero.
            # With identical positive durations the aggregate yields the exact mean.
            if total == 0 or (len(timed) == len(rows) and all(r["seconds"] == timed[0]["seconds"] for r in timed)):
                result["upgrades_per_minute"] = measure(total * 60 / timed[0]["seconds"], len(timed), 1)

    definitions = cards.get("cards", {})
    if isinstance(definitions, dict) and definitions and all(isinstance(c, dict) for c in definitions.values()):
        acquired = {key: 0 for key in definitions if key not in ("work", "money")}
        samples = 0
        for row in rows:
            counts = row.get("acquisitions")
            if isinstance(counts, dict) and all(count(n) is not None for n in counts.values()):
                samples += 1
                for key in acquired:
                    acquired[key] += int(counts.get(key, 0))
        if samples:
            total = sum(acquired.values())
            distribution = [{"id": key, "label": definitions[key].get("name", key), "count": n,
                             "percentage": 100 * n / total if total else None} for key, n in acquired.items()]
            result["card_acquisitions"] = {"total": total, "observed_games": samples,
                                           "missing_games": len(rows) - samples, "distribution": distribution}
    return result


def report_summary(report, card_document, cached=None, request=None):
    summary = {key: value for key, value in report.items() if key not in ("matches", "profiles", "decision_samples")}
    # Older reports may only have per-match game clocks. Never infer compute time
    # from file timestamps: they also include startup, recovery and copied files.
    games = count(report.get("games"))
    matches = report.get("matches")
    if ("simulated_seconds" not in summary and games is not None
            and isinstance(matches, list) and len(matches) == games):
        seconds = [row.get("seconds") if isinstance(row, dict) else None for row in matches]
        if all(type(value) in (int, float) and 0 <= value <= 2**53 - 1 for value in seconds):
            summary["simulated_seconds"] = sum(seconds)
    if "balance_metrics" not in summary:
        if isinstance(cached, dict) and cached.get("version") == 1:
            summary["balance_metrics"] = cached
        else:
            summary["balance_metrics"] = legacy_balance_metrics(report, card_document)
    metrics = summary["balance_metrics"]
    if isinstance(metrics, dict) and metrics.get("version") == 1:
        # Keep the original metric version and old measures for archived comparisons.
        summary["balance_metrics"] = {**observed_legacy_metrics(report, card_document, request), **metrics}
    return summary


class OffWorkWorkbench(ThreadingHTTPServer):
    def __init__(self, engine, port, *, handler, store=None):
        super().__init__(("127.0.0.1", port), handler)
        self.engine = engine
        self.store = store if store is not None else REPORTS
        self.jobs = {}
        self.library = {}
        self.library_aliases = {}
        self.catalog = {"cards": {}, "bot": {}}
        self.warnings = []
        self.lock = threading.RLock()
        self._config_cache = None
        self.closing = False
        try:
            self._load_saved_data()
        except Exception:
            self.server_close()
            raise

    def check_request(self, request):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            atomic_json(folder / "request.json", request)
            with (folder / "godot.log").open("wb") as log:
                proc = subprocess.run(runner_args(self.engine, folder), stdout=log,
                                      stderr=subprocess.STDOUT, timeout=15)
            return result(folder, proc.returncode)

    def configuration(self, bot=None):
        if bot is None:
            bot = read_json(DEFAULT_BOT)
        cards = read_json(DEFAULT_CARDS)
        # Resolve presets in the game engine once per pair of project documents.
        # Refreshing the page and repeated CLI runs can reuse this read-only data.
        cached = self._config_cache
        if cached and cards == cached[0] and bot == cached[1]:
            return cached[2]
        config = self.check_request({"presets_only": True, "cards": cards, "bot": bot})
        standard = config.pop("standard_profile")
        lower = standard
        if "low" in config["presets"]:
            lower = {k: v for k, v in standard.items() if k not in ("decision_budget_ms", "decision_budget_ratio")}
            lower.update(config["presets"]["low"])
        config.update(project_cards_id=config_id("cards", config["cards"]), default_options=DEFAULT_OPTIONS,
                      default_profiles={"balance": {"a": standard, "b": standard},
                                        "bot": {"a": standard, "b": lower}})
        self._config_cache = (cards, bot, config)
        return config

    def bootstrap(self):
        config = self.configuration()
        with self.lock:
            return {**config, "library": self.library_info(), "history": self.history(None)}

    def playtest(self, body):
        if set(body) != {"cards"} or not isinstance(body["cards"], dict):
            raise ValueError("试玩需要完整的 cards 对象")
        cards = self.check_request({"cards": body["cards"], "validate_only": True})["cards"]
        key = uuid.uuid4().hex
        folder = (self.store / "playtests" / key).resolve()
        path = folder / "cards.json"
        atomic_json(path, cards)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        marker = ("WORK_PLAYTEST_READY " + digest).encode()
        log_path = folder / "godot.log"
        command = [self.engine, "--path", str(ROOT), "--", "--off-work-playtest", "--cards-config=" + str(path)]
        with log_path.open("wb") as log:
            proc = subprocess.Popen(command, cwd=ROOT, start_new_session=True, stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + PLAYTEST_START_TIMEOUT
            with log_path.open("rb") as output:
                partial = b""
                while time.monotonic() < deadline:
                    code = proc.poll()
                    if code is not None:
                        raise ValueError(f"试玩游戏在开局前退出（状态码 {code}）。日志见 {log_path}")
                    lines = (partial + output.read(65536)).split(b"\n")
                    partial = lines.pop()[-len(marker):]
                    if marker in lines:
                        # The main scene has opened the selected snapshot and dealt the first game.
                        if proc.poll() is not None:
                            raise ValueError(f"试玩游戏在开局后退出。日志见 {log_path}")
                        threading.Thread(target=proc.wait, daemon=True).start()
                        return {"ok": True, "id": key, "pid": proc.pid}
                    time.sleep(0.05)
            raise ValueError(f"试玩游戏未能在 {PLAYTEST_START_TIMEOUT} 秒内确认开局。日志见 {log_path}")
        except (ValueError, OSError):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            raise

    def _save_config(self, kind, data, name, source, created_at=None):
        """Immutable content snapshot; names point to snapshots in catalog.json."""
        data = canonical(data)
        key = self._content_id(kind, data)
        if key in self.library:
            return self.library[key]
        record = {"id": key, "kind": kind, "name": name, "created_at": created_at or timestamp(),
                  "source": source, "data": data}
        atomic_json(self.store / "configs" / (key + ".json"), record)
        self.library[key] = record
        return record

    def _content_id(self, kind, data):
        # Re-saving a historical strategy must retain its published ID and name.
        key = config_id(kind, data)
        return self.library_aliases.get(key, key)

    def _catalog_record(self, kind, name, catalog=None):
        entry = (self.catalog if catalog is None else catalog)[kind][name]
        return {**self.library[entry["id"]], **entry, "name": name}

    def _add_legacy_name(self, record):
        kind = record["kind"]
        if any(entry["id"] == record["id"] for entry in self.catalog[kind].values()):
            return
        name = record["name"]
        suffix = 2
        while name in self.catalog[kind]:
            name = record["name"][:100] + "（旧版%d）" % suffix
            suffix += 1
        self.catalog[kind][name] = {"id": record["id"], "created_at": record["created_at"],
                                    "updated_at": record["created_at"], "source": record["source"]}

    def _load_catalog(self):
        path = self.store / "catalog.json"
        if not path.is_file():
            for record in sorted(self.library.values(), key=lambda item: (item["created_at"], item["id"]), reverse=True):
                self._add_legacy_name(record)
        else:
            catalog = read_json(path)
            for kind in ("cards", "bot"):
                entries = catalog.get(kind, catalog.get("ai") if kind == "bot" else None)
                if not isinstance(entries, dict):
                    raise ValueError("配置名称索引损坏：" + str(path))
                for name, entry in entries.items():
                    key = self.library_aliases.get(entry["id"], entry["id"])
                    if key not in self.library:
                        self.warnings.append("名称索引缺少可用配置快照：" + name)
                    self.catalog[kind][name] = {**entry, "id": key}

    def _save_candidates(self, candidates, source, overwrites, legacy_budget, manual=False):
        """Preflight the whole experiment before atomically changing any name."""
        if not isinstance(overwrites, dict) or any(not isinstance(value, str) for value in overwrites.values()):
            raise ValueError("覆盖确认必须使用当前配置 ID")
        draft = {kind: dict(entries) for kind, entries in self.catalog.items()}
        plans, conflicts, names, targets = [], [], {}, {}
        compatibility = self.configuration() if any(c["kind"] == "bot" for c in candidates) else {}
        policy_defaults = {**compatibility.get("legacy_search_defaults", {}),
                           **compatibility.get("legacy_algorithm_defaults", {})}

        def effective_bot_id(policy):
            normalized = {**policy_defaults, **policy}
            if "decision_budget_ms" not in normalized and "decision_budget_ratio" not in normalized:
                normalized["decision_budget_ms"] = legacy_budget
            return config_id("bot", normalized)

        # Hash effective historical policies once, using engine compatibility
        # defaults rather than the user's current tuning values. Only names
        # still present in the transactional draft participate in deduplication.
        bot_ids = {}
        for key, record in self.library.items():
            if not policy_defaults or record["kind"] != "bot":
                continue
            try:
                bot_ids[key] = effective_bot_id(record["data"])
            except (ValueError, TypeError, RecursionError):
                # A broken unrelated archive cannot identify a valid policy.
                continue
        for candidate in candidates:
            slot, kind, name, data = (candidate[key] for key in ("slot", "kind", "name", "data"))
            key = self._content_id(kind, data)
            # Enrich a reused old policy in a new immutable snapshot for this
            # experiment. Prior snapshots and their experiment references stay
            # addressable, while the catalog keeps the original strategy name.
            legacy_id = None
            if kind == "bot":
                effective_id = effective_bot_id(data)
                bot_ids[key] = effective_id
                legacy_name = next((label for label, entry in draft[kind].items()
                                    if bot_ids.get(entry["id"]) == effective_id), None)
                if legacy_name is not None:
                    legacy_id = draft[kind][legacy_name]["id"]
                    if manual:
                        raise ConfigConflict({"code": "unchanged_config", "error": "参数未变化，已有配置「%s」。" % legacy_name,
                                              "existing": {"id": legacy_id, "name": legacy_name, "kind": kind}})
                    name = legacy_name
            identity = (kind, name)
            if identity in names and names[identity] != key:
                raise ConfigConflict({"code": "batch_name_conflict", "error": "同一实验中的同类配置使用了相同名称但参数不同，请分别命名。"})
            names[identity] = key
            existing_name = next((label for label, entry in draft[kind].items() if entry["id"] == key), None)
            if existing_name is not None:
                if manual:
                    raise ConfigConflict({"code": "unchanged_config", "error": "参数未变化，已有配置「%s」，请修改参数后保存。" % existing_name,
                                          "existing": {"id": key, "name": existing_name, "kind": kind}})
                identity = (kind, existing_name)
                if identity in targets and targets[identity] != key:
                    raise ConfigConflict({"code": "batch_name_conflict", "error": "同一实验中的配置复用了相同名称但参数不同，请分别命名。"})
                targets[identity] = key
                plans.append({**candidate, "name": existing_name, "id": key})
                continue
            if identity in targets and targets[identity] != key:
                raise ConfigConflict({"code": "batch_name_conflict", "error": "同一实验中的配置复用了相同名称但参数不同，请分别命名。"})
            targets[identity] = key
            current = draft[kind].get(name)
            confirmed = overwrites.get(slot)
            if current is not None and current["id"] != legacy_id and self.library_aliases.get(confirmed, confirmed) != current["id"]:
                conflicts.append({"slot": slot, "kind": kind, "name": name,
                                  "current_id": current["id"], "incoming_id": key})
            created_at = current["created_at"] if current else timestamp()
            draft[kind][name] = {"id": key, "created_at": created_at, "updated_at": timestamp(), "source": source}
            plans.append({**candidate, "name": name, "id": key})
        if conflicts:
            raise ConfigConflict({"code": "name_conflict", "error": "已有同名配置且参数不同，请确认是否覆盖。", "conflicts": conflicts})
        for plan in plans:
            self._save_config(plan["kind"], plan["data"], plan["name"], source)
        atomic_json(self.store / "catalog.json", draft)
        self.catalog = draft
        return {plan["slot"]: {**self.library[plan["id"]], **draft[plan["kind"]][plan["name"]],
                              "name": plan["name"]} for plan in plans}

    def save_config(self, kind, body):
        if not {"name", "data"}.issubset(body) or set(body) - {"name", "data", "overwrite_id"} or not isinstance(body["data"], dict):
            raise ValueError("保存配置需要名称 name 和完整对象 data")
        if not isinstance(body["name"], str):
            raise ValueError("配置名称必须是文本")
        name = display_name(body["name"], "")
        cards = read_json(DEFAULT_CARDS)
        bot = read_json(DEFAULT_BOT)
        if kind == "cards":
            data = self.check_request({"cards": body["data"], "bot": bot, "validate_only": True})["cards"]
        else:
            checked = self.check_request({"cards": cards, "bot": bot, "a": body["data"], "b": {},
                                          "profiles_only": True})
            data = checked["profiles"]["a"]
        with self.lock:
            candidates = [{"slot": "config", "kind": kind, "data": data, "name": name}]
            overwrites = {"config": body["overwrite_id"]} if "overwrite_id" in body else {}
            legacy_budget = checked["legacy_default_budget_ms"] if kind == "bot" else None
            return self._save_candidates(candidates, "manual", overwrites, legacy_budget, manual=True)["config"]

    def library_info(self, key=None):
        with self.lock:
            if key is not None:
                key = self.library_aliases.get(key, key)
                if key not in self.library:
                    raise KeyError(key)
                for kind, entries in self.catalog.items():
                    for name, entry in entries.items():
                        if entry["id"] == key:
                            return self._catalog_record(kind, name)
                return self.library[key]
            records = [self._catalog_record(kind, name) for kind, entries in self.catalog.items()
                       for name, entry in entries.items() if entry["id"] in self.library]
            records.sort(key=lambda record: record["updated_at"], reverse=True)
            result = {kind: [{k: v for k, v in record.items() if k != "data"}
                             for record in records if record["kind"] == kind] for kind in ("cards", "bot")}
            result["warnings"] = self.warnings
            return result

    def notes(self, key, body=None):
        if not isinstance(key, str) or not re.fullmatch(r"cards_[a-f0-9]{64}", key):
            raise ValueError("备注需要有效的卡表快照 ID")
        with self.lock:
            key = self.library_aliases.get(key, key)
            if key not in self.library and key != self.configuration()["project_cards_id"]:
                raise KeyError(key)
            path = self.store / "notes" / (key + ".json")
            if body is None:
                return read_json(path) if path.is_file() else {"id": key, "text": ""}
            text = body.get("text")
            if not isinstance(text, str) or len(text) > 10000:
                raise ValueError("试玩备注必须是 10000 字以内的文本")
            note = {"id": key, "text": text, "updated_at": timestamp()}
            atomic_json(path, note)
            return note

    def _experiment_configs(self, request, names, source, created_at, report=None):
        base = request.get("bot", {}).get("bot", {})
        if not base:
            # Old archives that did not snapshot a bot document predate decision deadlines.
            base = {key: value for key, value in read_json(DEFAULT_BOT)["bot"].items()
                    if key not in ("decision_budget_ms", "decision_budget_ratio")}
        references = {}
        documents = {"cards": request["cards"]}
        for side in ("a", "b"):
            policy = (report or {}).get("profiles", {}).get(side)
            if not isinstance(policy, dict):
                overrides = request.get(side, {})
                policy = {**base, **overrides}
                if "decision_budget_ratio" in overrides and "decision_budget_ms" not in overrides:
                    policy.pop("decision_budget_ms", None)
                if "decision_budget_ms" in overrides and "decision_budget_ratio" not in overrides:
                    policy.pop("decision_budget_ratio", None)
            documents[side] = {key: value for key, value in policy.items() if key != "owner"}
        for key, data in documents.items():
            kind = "cards" if key == "cards" else "bot"
            record = self._save_config(kind, data, names[key], source, created_at)
            self._add_legacy_name(record)
            references[key] = record["id"]
        return references

    def _validate_snapshots(self, batch):
        snapshots = [{"id": record["id"], "cards": record["data"]} for record in batch]
        checked = self.check_request({"validate_cards_batch": snapshots})["items"]
        for record in batch:
            key = record["id"]
            item = checked[key]
            if not isinstance(item, dict) or not isinstance(item.get("cards"), dict):
                detail = item.get("error", "校验结果缺少卡表") if isinstance(item, dict) else "校验结果无效"
                self.warnings.append(f"无法载入配置 {key}.json：{detail}")
                del self.library[key]
            elif item["cards"] != record["data"]:
                # All immutable snapshots are already indexed. Reuse an existing
                # normalized target without overwriting its original metadata.
                del self.library[key]
                normalized = self._save_config("cards", item["cards"], record["name"], record["source"], record["created_at"])
                self.library_aliases[key] = normalized["id"]

    def _load_saved_data(self):
        self.store.mkdir(parents=True, exist_ok=True)
        cards = []
        for path in (self.store / "configs").glob("*.json"):
            try:
                record = read_json(path)
                record["kind"] = canonical_kind(record.get("kind"))
                if (record.get("id") != path.stem or record.get("kind") not in ("cards", "bot")
                        or not isinstance(record.get("data"), dict)
                        or not all(isinstance(record.get(key), str) for key in ("name", "source", "created_at"))):
                    raise ValueError("记录结构无效")
                if record["kind"] == "cards":
                    # Isolate non-finite values before serializing a whole batch.
                    json.dumps(record["data"], allow_nan=False)
                    cards.append((record, path.stat().st_size))
                elif record["id"].startswith("ai_"):
                    self.library_aliases[config_id("bot", record["data"])] = record["id"]
                self.library[record["id"]] = record
            except (OSError, ValueError, TypeError, AttributeError, KeyError, RecursionError) as exc:
                self.warnings.append("无法载入配置 " + path.name + "：" + str(exc))

        # Amortize headless engine startup across snapshots. Bound each request
        # by both card count and on-disk size for long-running tuning archives.
        batch, size = [], 0
        for record, file_size in cards:
            if batch and (len(batch) >= 64 or size + file_size > 2_000_000):
                self._validate_snapshots(batch)
                batch, size = [], 0
            batch.append(record)
            size += file_size
        if batch:
            self._validate_snapshots(batch)
        self._load_catalog()
        normalized_cards = {}
        for folder in self.store.iterdir():
            if not folder.is_dir() or not re.fullmatch(r"[a-f0-9]{32}", folder.name):
                continue
            request_path = folder / "request.json"
            if not request_path.is_file():
                continue
            created_at = timestamp(request_path.stat().st_mtime)
            request = {}
            meta = {"id": folder.name, "created_at": created_at, "kind": "legacy", "label": "旧实验",
                    "experiment_id": folder.name, "status": "running", "total": 0, "completed": 0,
                    "card_name": "旧实验卡表", "a_name": "旧实验策略 A", "b_name": "旧实验策略 B"}
            job = {"proc": None, "folder": folder, "request": request, "meta": meta}
            self.jobs[folder.name] = job
            try:
                request = read_json(request_path)
                if not isinstance(request, dict) or not isinstance(request.get("cards"), dict):
                    raise ValueError("旧实验缺少完整卡表")
                normalize_job(request)
                job["request"] = request
                meta["total"] = int(request.get("pairs", 0)) * 2
                for key in ("kind", "label", "experiment_id", "card_name", "a_name", "b_name"):
                    if key in request: meta[key] = request[key]
                meta_path = folder / "job.json"
                if meta_path.is_file():
                    try:
                        saved_meta = read_json(meta_path)
                        if not isinstance(saved_meta, dict): raise ValueError("记录结构无效")
                        meta.update(normalize_job(saved_meta))
                    except (ValueError, TypeError) as exc:
                        self.warnings.append("已重新读取实验 " + folder.name + " 的原始记录：" + str(exc))
                if "kind" not in request:
                    meta["kind"] = "legacy"
                if meta["status"] == "running":
                    self._finish_job(job, None)
                elif meta["status"] != "done":
                    self._refresh_progress(job)
                report = {}
                if meta["status"] == "done":
                    report = result(folder, 0)
                    cached = meta.get("summary", {}).get("balance_metrics")
                    meta["summary"] = report_summary(report, request["cards"], cached, request)
                if meta.get("configs"):
                    meta["configs"] = {side: self.library_aliases.get(key, key) for side, key in meta["configs"].items()}
                if not meta.get("configs") or any(key not in self.library for key in meta["configs"].values()):
                    encoded = json.dumps(canonical(request["cards"]), ensure_ascii=False, sort_keys=True)
                    if encoded not in normalized_cards:
                        checked = self.check_request({"cards": request["cards"], "validate_only": True,
                                                      **({"bot": request["bot"]} if isinstance(request.get("bot"), dict) else {})})
                        normalized_cards[encoded] = checked["cards"]
                    library_request = {**request, "cards": normalized_cards[encoded]}
                    names = {"cards": meta["card_name"], "a": meta["a_name"], "b": meta["b_name"]}
                    meta["configs"] = self._experiment_configs(library_request, names, "legacy", meta["created_at"], report)
            except (OSError, ValueError, TypeError, AttributeError, KeyError, subprocess.SubprocessError) as exc:
                meta.update(status="error", error="无法完整恢复实验记录：" + str(exc))
            self._persist_job(job)
        atomic_json(self.store / "catalog.json", self.catalog)

    def _persist_job(self, job):
        atomic_json(job["folder"] / "job.json", job["meta"])

    @staticmethod
    def _refresh_progress(job):
        meta = job["meta"]
        try:
            progress = read_json(job["folder"] / "progress.json")
        except (OSError, ValueError):
            return
        if not isinstance(progress, dict):
            return
        completed = count(progress.get("completed"))
        if completed is None or not meta["completed"] <= completed <= meta["total"]:
            return
        meta["completed"] = completed
        summary = progress.get("summary")
        if isinstance(summary, dict) and count(summary.get("games")) == completed:
            meta["summary"] = summary
            if isinstance(progress.get("decision_samples"), list):
                job["decision_samples"] = progress["decision_samples"]

    def _finish_job(self, job, code):
        meta = job["meta"]
        if meta["status"] != "running":
            return
        self._refresh_progress(job)
        try:
            report = result(job["folder"], code or 0)
            meta.update(status="done", completed=meta["total"],
                        summary=report_summary(report, job["request"]["cards"], request=job["request"]))
        except (ValueError, OSError) as exc:
            message = str(exc) if code is not None else "服务中断，实验没有完成；原始请求、进度和日志已保留"
            try:
                failure = read_json(job["folder"] / "result.json")
                message = failure.get("error", message)
            except (OSError, ValueError, AttributeError):
                pass
            meta.update(status="error", error=message)
        meta["finished_at"] = timestamp()
        self._persist_job(job)

    def _watch_job(self, job):
        code = job["proc"].wait()
        with self.lock:
            self._finish_job(job, code)

    def start_job(self, body):
        body = dict(body)
        body["kind"] = canonical_kind(body.get("kind", "bot"))
        kind = body["kind"]
        if kind not in ("bot", "balance"):
            raise ValueError("实验 kind 必须为 bot 或 balance")
        required = {"cards", "seed", "pairs", "max_seconds"}
        optional = {"kind", "a", "b", "label", "experiment_id", "card_name", "a_name", "b_name", "overwrites"}
        if not required.issubset(body) or set(body) - required - optional:
            raise ValueError("对战需要完整的卡表、种子、种子对数和时间上限")
        if not all(isinstance(body[k], dict) for k in ("cards", "a", "b") if k in body):
            raise ValueError("卡表与双方策略必须是 JSON 对象")
        pairs, seed = body["pairs"], body["seed"]
        if type(pairs) is not int or type(seed) is not int or min(pairs, seed) < 1 or max(2 * pairs, seed + pairs - 1) > 2**53 - 1:
            raise ValueError("种子与种子对数须为正整数，末种子和总局数须在网页安全整数范围内")
        if type(body["max_seconds"]) not in (int, float) or not 0 < body["max_seconds"] <= 2**53 - 1:
            raise ValueError("单局时限须为正秒数")
        experiment_id = body.get("experiment_id", uuid.uuid4().hex)
        if not isinstance(experiment_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", experiment_id):
            raise ValueError("experiment_id 须为 1 到 80 个字母、数字、横线或下划线")
        names = {"cards": display_name(body.get("card_name"), "实验卡表"),
                 "a": display_name(body.get("a_name"), "实验策略 A"),
                 "b": display_name(body.get("b_name"), "实验策略 B")}
        label = display_name(body.get("label"), "BOT 对战" if body.get("kind", "bot") == "bot" else "平衡实验")
        bot = read_json(DEFAULT_BOT)
        if "a" not in body or "b" not in body:
            if kind == "balance" and ("a" in body or "b" in body):
                # Mirror a single explicitly chosen policy. Legacy requests with
                # two distinct policies must retain both exactly as submitted.
                selected = "a" if "a" in body else "b"
                policy = body[selected]
                names["a"] = names["b"] = names[selected]
                body.update(a=policy, b=policy)
            else:
                defaults = self.configuration(bot)["default_profiles"][kind]
                body = {**defaults, **body}
        checked = self.check_request({"cards": body["cards"], "bot": bot, "a": body["a"], "b": body["b"],
                                      "profiles_only": True})
        request = {**body, "cards": checked["cards"], "bot": bot,
                   "a": checked["profiles"]["a"], "b": checked["profiles"]["b"],
                   "kind": body.get("kind", "bot"), "label": label, "experiment_id": experiment_id,
                   "card_name": names["cards"], "a_name": names["a"], "b_name": names["b"]}
        with self.lock:
            if self.closing:
                raise ValueError("服务正在关闭")
            if sum(job["proc"] is not None and job["proc"].poll() is None for job in self.jobs.values()) >= 4:
                raise ValueError("已有四项模拟在运行，请等待或停止一项后重试")
            candidates = [{"slot": slot, "kind": "cards" if slot == "cards" else "bot",
                           "name": names[slot], "data": request[slot]} for slot in ("cards", "a", "b")]
            saved = self._save_candidates(candidates, "experiment", body.get("overwrites", {}), checked["legacy_default_budget_ms"])
            names = {slot: record["name"] for slot, record in saved.items()}
            request.update(card_name=names["cards"], a_name=names["a"], b_name=names["b"])
            request.pop("overwrites", None)
            key = uuid.uuid4().hex
            folder = self.store / key
            folder.mkdir(parents=True)
            meta = {"id": key, "created_at": timestamp(), "kind": body.get("kind", "bot"), "label": label,
                    "experiment_id": experiment_id, "status": "running", "total": pairs * 2, "completed": 0,
                    "card_name": names["cards"], "a_name": names["a"], "b_name": names["b"]}
            meta["configs"] = {slot: record["id"] for slot, record in saved.items()}
            atomic_json(folder / "request.json", request)
            job = {"proc": None, "folder": folder, "request": request, "meta": meta}
            self.jobs[key] = job
            self._persist_job(job)
            try:
                with (folder / "godot.log").open("wb") as log:
                    job["proc"] = subprocess.Popen(runner_args(self.engine, folder), stdout=log, stderr=subprocess.STDOUT)
            except OSError as exc:
                meta.update(status="error", error=str(exc), finished_at=timestamp())
                self._persist_job(job)
            else:
                threading.Thread(target=self._watch_job, args=(job,), daemon=True).start()
        # A submitted snapshot may already be catalogued under another name.
        # Return resolved names so the editor and history identify the same versions.
        return {"id": key, "configs": meta["configs"], "card_name": meta["card_name"],
                "a_name": meta["a_name"], "b_name": meta["b_name"]}

    def stop_job(self, job):
        proc = job["proc"]
        if proc is not None and proc.poll() is None and job["meta"]["status"] == "running":
            job["meta"].update(status="cancelled", finished_at=timestamp())
            self._persist_job(job)
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            self._refresh_progress(job)
            self._persist_job(job)
        elif proc is not None:
            self._finish_job(job, proc.poll())

    def _job_info(self, job, detail):
        if job["proc"] is not None and job["proc"].poll() is not None:
            self._finish_job(job, job["proc"].returncode)
        if job["meta"]["status"] == "running":
            self._refresh_progress(job)
        info = dict(job["meta"])
        for field in ("seed", "pairs", "max_seconds"):
            if field in job["request"]:
                info[field] = job["request"][field]
        if detail:
            info["request"] = job["request"]
            if info["status"] == "done":
                info["result"] = read_json(job["folder"] / "result.json")
                info["result"].update(info["summary"])
                metrics = info["summary"].get("balance_metrics")
                rows = info["result"].get("matches")
                if isinstance(metrics, dict) and metrics.get("version") == 1 and isinstance(rows, list):
                    delays = first_delays(info["result"], job["request"])
                    for row in rows:
                        if isinstance(row, dict) and "first_seat" not in row:
                            seat = first_seat(row, delays)
                            if seat is not None: row["first_seat"] = seat
            elif info.get("summary"):
                info["result"] = dict(info["summary"])
                if "decision_samples" in job:
                    info["result"]["decision_samples"] = job["decision_samples"]
        return info

    def job_info(self, key, cancel=False):
        with self.lock:
            job = self.jobs[key]
            if cancel:
                self.stop_job(job)
            return self._job_info(job, True)

    def history(self, kind):
        kind = canonical_kind(kind)
        if kind not in (None, "bot", "balance"):
            raise ValueError("历史 kind 必须为 bot 或 balance")
        with self.lock:
            jobs = sorted(self.jobs.values(), key=lambda job: job["meta"]["created_at"], reverse=True)
            return {"items": [self._job_info(job, False) for job in jobs
                              if kind is None or job["meta"]["kind"] in (kind, "legacy")],
                    "warnings": self.warnings}

    def close_jobs(self):
        with self.lock:
            self.closing = True
            for job in self.jobs.values():
                self.stop_job(job)


class OffWorkRoutes:
    def handle_api(self):
        self.guard()
        url = urlsplit(self.path)
        path = url.path
        if self.command == "GET":
            note = re.fullmatch(r"/api/notes/(cards_[a-f0-9]{64})", path)
            if note:
                self.reply(self.server.notes(note[1]))
                return
            if path == "/api/library":
                self.reply(self.server.library_info())
                return
            record = re.fullmatch(r"/api/library/((?:cards|bot|ai)_[a-f0-9]{64})", path)
            if record:
                self.reply(self.server.library_info(record[1]))
                return
            if path == "/api/history":
                self.reply(self.server.history(parse_qs(url.query).get("kind", [None])[0]))
                return
            if path in ("/api/config", "/api/bootstrap"):
                self.reply(self.server.bootstrap() if path == "/api/bootstrap" else self.server.configuration())
                return
            static_files = {"/": "off_work_workbench.html", "/lab.js": "off_work_workbench.js", "/lab.css": "off_work_workbench.css"}
            if path in static_files:
                asset = WEB / static_files[path]
                self.reply(asset.read_bytes(), mime=mimetypes.guess_type(asset.name)[0] + "; charset=utf-8")
                return
        job = re.fullmatch(r"/api/jobs/([a-f0-9]{32})", path)
        if job and self.command in ("GET", "DELETE"):
            self.reply(self.server.job_info(job[1], self.command == "DELETE"))
            return
        library_save = re.fullmatch(r"/api/library/(cards|bot|ai)", path)
        if self.command == "POST" and (path in ("/api/run", "/api/validate", "/api/playtest", "/api/notes") or library_save):
            size = int(self.headers.get("Content-Length", 0))
            if not 0 < size <= 1_000_000 or self.headers.get_content_type() != "application/json":
                raise ValueError("需要 1 MB 以内的 JSON 请求")
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError("请求必须是 JSON 对象")
            if path == "/api/notes":
                self.reply(self.server.notes(body.get("id"), body))
                return
            if library_save:
                self.reply(self.server.save_config(canonical_kind(library_save[1]), body))
                return
            if not isinstance(body.get("cards"), dict):
                raise ValueError("缺少完整卡表")
            if path == "/api/validate":
                self.reply(self.server.check_request({"cards": body["cards"], "validate_only": True}))
            elif path == "/api/playtest":
                self.reply(self.server.playtest(body))
            else:
                self.reply(self.server.start_job(body), 202)
            return
        self.reply({"error": "没有这个页面或接口"}, 404)

    def serve_realtime(self):
        try:
            self.handle_api()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except PermissionError as exc:
            self.reply({"error": str(exc)}, 403)
        except ConfigConflict as exc:
            self.reply(exc.payload, 409)
        except KeyError:
            self.reply({"error": "找不到该任务或配置"}, 404)
        except (UnicodeError, ValueError, RecursionError) as exc:
            self.reply({"error": str(exc)}, 400)
        except (OSError, subprocess.SubprocessError) as exc:
            self.reply({"error": str(exc)}, 500)


