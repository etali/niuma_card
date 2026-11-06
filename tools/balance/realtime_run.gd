# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

## One process per experiment. Both seats use the live bot and state command path.
const SAFE_INTEGER := 9007199254740991
const PROGRESS_INTERVAL_USEC := 300000
const SAMPLE_LIMIT_PER_SEAT := 12
const Config = preload("res://engine/work_config.gd")
const BotPreferences = preload("res://engine/work_bot_preferences.gd")
const State = preload("res://engine/work_state.gd")
const Bot = preload("res://engine/work_bot.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var request_path := ""
	var output_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--request="):
			request_path = arg.trim_prefix("--request=")
		elif arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
	if request_path.is_empty() or output_path.is_empty():
		printerr("需要 --request=<请求路径> --output=<报告路径>")
		quit(1)
		return
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	var result := {"error": "请求必须为有效 JSON 对象"}
	if request is Dictionary:
		result = _evaluate(request, output_path.get_base_dir().path_join("progress.json"))
	if not _write_json(output_path, result):
		printerr("无法写入报告：" + output_path)
		quit(1)
		return
	quit(1 if result.has("error") else 0)

func _write_json(path: String, data: Dictionary) -> bool:
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null: return false
	var ok := file.store_string(JSON.stringify(data, "", false, true))
	file.close()
	return ok and DirAccess.rename_absolute(tmp, path) == OK

func _positive_integer(value: Variant) -> bool:
	return (value is int or value is float) and value > 0 and value <= SAFE_INTEGER and value == floor(value)

func _evaluate(request: Dictionary, progress_path: String) -> Dictionary:
	# Store recovery validates many historical snapshots in one headless process.
	# Each entry follows the same normalization and validation as a manual import.
	if request.has("validate_cards_batch"):
		var entries: Variant = request.validate_cards_batch
		if not entries is Array: return {"error": "批量卡表校验需要数组"}
		var items := {}
		for entry in entries:
			if not entry is Dictionary or not entry.get("id") is String:
				return {"error": "批量校验缺少快照 ID"}
			items[entry.id] = _evaluate({"cards": entry.get("cards"), "validate_only": true}, "")
		return {"items": items}
	for flag in ["presets_only", "validate_only", "profiles_only"]:
		if request.has(flag) and not request[flag] is bool: return {"error": "%s 必须是布尔值" % flag}
	var bot_document: Variant = request.get("bot", request.get("ai"))
	if (request.has("bot") or request.has("ai")) and not bot_document is Dictionary:
		return {"error": "bot 必须是完整 off_work_bot.json 对象"}
	var presets_only: bool = request.get("presets_only", false)
	if not presets_only and not request.get("cards") is Dictionary:
		return {"error": "缺少完整 cards.json 对象"}
	var config := Config.new(request.get("cards"), bot_document)
	if not config.errors.is_empty():
		return {"error": "\n".join(config.errors)}
	if presets_only:
		var settings: Dictionary = config.bot_preferences
		var presets := {}
		for key in settings.presets:
			presets[key] = BotPreferences.strength_parameters(settings.presets[key], config.rules.bot, settings)
		var standard: Dictionary = config.rules.bot.duplicate()
		standard.erase("owner")
		return {"presets": presets, "standard_profile": standard, "cards": config.balance_document(),
			"bot": {"bot": config.rules.bot, "preferences": settings},
			"legacy_default_budget_ms": Config.LEGACY_DECISION_BUDGET_MS}
	if request.get("validate_only", false):
		return {"ok": true, "cards": config.balance_document()}
	var profiles := {}
	var baseline: Dictionary = config.rules.bot
	for name in ["a", "b"]:
		var overrides: Variant = request.get(name)
		if not overrides is Dictionary:
			return {"error": "%s 必须是 BOT 策略对象" % name}
		for key in overrides:
			if key == "owner" or (not baseline.has(key) and key not in ["decision_budget_ratio", "decision_budget_ms"]):
				return {"error": "%s 中不能覆盖策略字段 %s" % [name, key]}
		# A complete pre-budget strategy is an archived policy. Partial CLI
		# overrides (including {}) inherit the current document's budget mode.
		if baseline.has("decision_budget_ratio") and not overrides.has("decision_budget_ratio") and not overrides.has("decision_budget_ms"):
			var complete := baseline.keys().all(func(key): return key in ["owner", "decision_budget_ratio", "decision_budget_ms"] or overrides.has(key))
			if complete:
				overrides = overrides.merged({"decision_budget_ms": Config.LEGACY_DECISION_BUDGET_MS})
		var policy: Dictionary = Config.merge_bot_policy(baseline, overrides)
		config.rules.bot = policy
		if not config.validate():
			return {"error": "%s 策略无效\n%s" % [name, "\n".join(config.errors)]}
		for knob in config.bot_preferences.knobs:
			if not overrides.has(knob.key) or knob.kind == "bool": continue
			var value: float = policy[knob.key]
			if value < float(knob.min) or value > float(knob.max):
				return {"error": "%s.%s 必须在 %s 到 %s 之间" % [name, knob.key, knob.min, knob.max]}
		profiles[name] = policy
	config.rules.bot = baseline
	for policy in profiles.values(): policy.erase("owner")
	if request.get("profiles_only", false):
		return {"profiles": profiles, "cards": config.balance_document(), "legacy_default_budget_ms": Config.LEGACY_DECISION_BUDGET_MS}
	if not _positive_integer(request.get("pairs")) or not _positive_integer(request.get("seed")):
		return {"error": "pairs 和 seed 必须是可精确表示的正整数"}
	var pairs := int(request.pairs)
	var first_seed := int(request.seed)
	if pairs * 2 > SAFE_INTEGER or first_seed + pairs - 1 > SAFE_INTEGER:
		return {"error": "局数或种子超出可精确表示的范围"}
	var limit: Variant = request.get("max_seconds")
	if not (limit is int or limit is float) or not is_finite(float(limit)) or limit <= 0 or limit > SAFE_INTEGER:
		return {"error": "max_seconds 必须为正且有限的秒数"}
	var report := {"games": 0, "a_wins": 0, "b_wins": 0, "draws": 0, "timeouts": 0,
		"flow": {"work_done": 0, "outsource_done": 0, "work_transferred": 0, "work_income": 0,
			"upgrades": 0, "dismissed": 0, "dismiss_income": 0},
		"purchases": {}, "market_offers": {}, "matches": [], "profiles": profiles,
		"decision_stats": {}, "decision_samples": [],
		"simulator_fingerprint": _simulator_fingerprint(), "godot_version": Engine.get_version_info().string,
		"simulated_seconds": 0.0}
	for side in ["a", "b"]:
		report.decision_stats[side] = []
		for seat in 2:
			report.decision_stats[side].append({"budget_ms": Config.decision_budget_ms(profiles[side]), "count": 0, "cutoffs": 0, "fallbacks": 0,
				"over_budget": 0, "apply_failures": 0, "sum_elapsed_us": 0, "max_elapsed_us": 0,
				"searched": 0, "max_search_depth": 0, "sum_search_nodes": 0, "discarded_late": 0,
				"action_counts": {}, "sample_count": 0})
	for kind in config.cards:
		if config.cards[kind].purchasable:
			report.market_offers[kind] = 0
	var metrics := BalanceMetrics.new(config.cards)
	var started_usec := Time.get_ticks_usec()
	for offset in pairs:
		var match_seed := first_seed + offset
		for a_seat in 2:
			var current := {"number": int(report.games) + 1, "seed": match_seed, "a_seat": a_seat,
				"seconds": 0.0, "max_seconds": float(limit)}
			var publish := func(seconds: float) -> bool:
				current.seconds = seconds
				return _write_progress(progress_path, pairs * 2, report, started_usec, current)
			var game := _match(config, profiles, match_seed, a_seat, float(limit), report, publish)
			if game.has("error"): return game
			report.matches.append(game)
			match game.winner:
				"a": report.a_wins += 1
				"b": report.b_wins += 1
				"draw": report.draws += 1
				"timeout": report.timeouts += 1
			report.simulated_seconds += float(game.seconds)
			report.games += 1
			report["balance_metrics"] = metrics.add_game(game, report)
			if not _write_progress(progress_path, pairs * 2, report, started_usec):
				return {"error": "无法写入实验进度"}
	report["elapsed_seconds"] = float(Time.get_ticks_usec() - started_usec) / 1000000.0
	report["mean_seconds"] = report.simulated_seconds / int(report.games)
	return report

## Keep timing metadata out of gameplay. A checkpoint reuses the most recent
## completed metrics, even while a subsequent match is being calculated.
func _write_progress(path: String, total: int, report: Dictionary, started_usec: int, current := {}) -> bool:
	var summary := {"games": report.games, "a_wins": report.a_wins, "b_wins": report.b_wins,
		"draws": report.draws, "timeouts": report.timeouts, "simulated_seconds": report.simulated_seconds,
		"elapsed_seconds": float(Time.get_ticks_usec() - started_usec) / 1000000.0,
		"simulator_fingerprint": report.simulator_fingerprint, "godot_version": report.godot_version,
		"decision_stats": report.decision_stats}
	if report.has("balance_metrics"): summary.balance_metrics = report.balance_metrics
	if not current.is_empty():
		summary.current_match = current
		summary.simulated_seconds += float(current.seconds)
	return _write_json(path, {"total": total, "completed": report.games, "summary": summary,
		"decision_samples": report.decision_samples})

func _simulator_fingerprint() -> String:
	var parts := PackedStringArray()
	for script in [get_script(), State, Config, Config.ConfigData]:
		var path: String = script.resource_path
		parts.append(path + ":" + FileAccess.get_sha256(path))
	for file in DirAccess.get_files_at("res://engine"):
		if file.begins_with("work_bot") and file.ends_with(".gd"):
			var path := "res://engine/".path_join(file)
			parts.append(path + ":" + FileAccess.get_sha256(path))
	return "\n".join(parts).sha256_text()

## Updated once per completed match. Rate numerators are sums of individual
## match rates, so each positive-duration match contributes one observation.
class BalanceMetrics:
	var first_wins := 0
	var finished_with_first := 0
	var finished_seconds := 0.0
	var timed_games := 0
	var upgrade_rates := 0.0
	var generation_rates := 0.0
	var interference_rates := 0.0
	var acquired := {}
	var acquired_total := 0
	var labels := {}

	func _init(card_definitions: Dictionary) -> void:
		for kind in card_definitions:
			if kind not in ["work", "money"]:
				acquired[kind] = 0
				labels[kind] = card_definitions[kind].name

	func add_game(game: Dictionary, report: Dictionary) -> Dictionary:
		if game.first_seat in [0, 1] and game.winner != "timeout":
			finished_with_first += 1
			var first_side := "a" if game.first_seat == game.a_seat else "b"
			first_wins += int(game.winner == first_side)
		var seconds: float = game.seconds
		if game.winner != "timeout": finished_seconds += seconds
		if seconds > 0:
			timed_games += 1
			upgrade_rates += game.upgrades * 60.0 / seconds
			generation_rates += game.tool_generations * 60.0 / seconds
			interference_rates += game.interferences * 60.0 / seconds
		for kind in game.acquisitions:
			if acquired.has(kind):
				acquired[kind] += game.acquisitions[kind]
				acquired_total += game.acquisitions[kind]
		var rows := []
		for kind in acquired:
			rows.append({"id":kind, "label":labels[kind], "count":acquired[kind],
				"percentage":100.0 * acquired[kind] / acquired_total if acquired_total > 0 else null})
		return {"version":2,
			"first_player_win_rate":_metric(first_wins, finished_with_first),
			"mean_finish_seconds":_metric(finished_seconds, report.games - report.timeouts, 1.0),
			"timeout_rate":_metric(report.timeouts, report.games),
			"purchase_coverage":_metric(report.purchases.size(), report.market_offers.size()),
			"upgrades_per_minute":_metric(upgrade_rates, timed_games, 1.0),
			"tool_generations_per_minute":_metric(generation_rates, timed_games, 1.0),
			"interferences_per_minute":_metric(interference_rates, timed_games, 1.0),
			"card_acquisitions":{"observed_games":report.games, "missing_games":0, "total":acquired_total, "distribution":rows}}

	static func _metric(numerator: Variant, denominator: int, scale := 100.0) -> Dictionary:
		return {"numerator": numerator, "denominator": denominator,
			"value": float(numerator) / denominator * scale if denominator > 0 else null}

func _match(config: RefCounted, profiles: Dictionary, match_seed: int, a_seat: int,
		limit: float, report: Dictionary, publish: Callable) -> Dictionary:
	var state := State.new(config)
	state.new_game(match_seed)
	if not state.last_error.is_empty(): return {"error": state.last_error}
	for offer in state.offers:
		report.market_offers[offer.type] += 1
	var game := {"first_seat":-1, "upgrades":0, "tool_generations":0, "interferences":0, "acquisitions":{}}
	var bots := []
	for seat in 2:
		var policy: Dictionary = profiles.a if seat == a_seat else profiles.b
		var bot := Bot.new(state, seat, policy, match_seed)
		bot.start()
		bots.append(bot)
	# WorkState.advance settles all intermediate production, market and tool events.
	# Only bot deadlines require returning to this driver. A tie on action time is
	# resolved in seat order for both legs; market and bot RNG streams follow seats.
	# A disabled or delayed bot may have no upcoming action. Bound a batch by
	# market arrivals so events and progress can still be drained in long matches.
	var batch_seconds: float = 32.0 * config.number("conveyor", "interval_seconds")
	var next_progress_usec := 0
	while state.winner < 0 and state.time < limit:
		if Time.get_ticks_usec() >= next_progress_usec:
			if not publish.call(state.time): return {"error": "无法写入实验进度"}
			next_progress_usec = Time.get_ticks_usec() + PROGRESS_INTERVAL_USEC
		for seat in 2:
			var bot: RefCounted = bots[seat]
			var before_decision: int = bot.decision_serial
			bot.advance(0.0)
			if int(bot.decision_serial) != before_decision:
				if game.first_seat == -1: game.first_seat = seat
				var side := "a" if seat == a_seat else "b"
				_record_decision(report, side, seat, match_seed, state.time, bot.last_decision)
		var next_action := minf(bots[0].next_action_time(), bots[1].next_action_time())
		var deadline := minf(limit, next_action)
		var delta := minf(batch_seconds, deadline - state.time)
		var before := state.time
		state.advance(delta)
		_collect_events(state.drain_events(), report, game)
		if state.winner < 0 and state.time <= before:
			return {"error": "对局时间无法推进，请检查模拟精度和规则时长"}
	var outcome := "timeout"
	if state.winner >= 0:
		if state.winner == config.integer("simulation", "tie_winner"): outcome = "draw"
		else: outcome = "a" if state.winner == a_seat else "b"
	return game.merged({"seed": match_seed, "a_seat": a_seat, "winner": outcome, "seconds": state.time,
		"a_work": state.work_count(a_seat), "b_work": state.work_count(1 - a_seat),
		"a_money": state.money(a_seat), "b_money": state.money(1 - a_seat)})

func _record_decision(report: Dictionary, side: String, seat: int, seed_value: int,
		game_seconds: float, decision: Dictionary) -> void:
	var stats: Dictionary = report.decision_stats[side][seat]
	var kind: String = decision.kind
	var elapsed: int = decision.elapsed_us
	var overdue: bool = elapsed > float(decision.budget_ms) * 1000.0
	var first_of_kind: bool = not stats.action_counts.has(kind)
	stats.action_counts[kind] = int(stats.action_counts.get(kind, 0)) + 1
	stats.count += 1
	stats.sum_elapsed_us += elapsed
	stats.max_elapsed_us = maxi(stats.max_elapsed_us, elapsed)
	stats.cutoffs += int(decision.cutoff)
	stats.fallbacks += int(decision.fallback)
	stats.over_budget += int(overdue)
	stats.apply_failures += int(not decision.applied)
	var depth := int(decision.get("search_depth", 0))
	stats.searched += int(depth > 0)
	stats.max_search_depth = maxi(stats.max_search_depth, depth)
	stats.sum_search_nodes += int(decision.get("search_nodes", 0))
	var discarded_late: bool = decision.get("discarded_late", false)
	stats.discarded_late += int(discarded_late)
	# Reserve extra samples for the first cutoff, fallback and overrun even
	# if they occur after a long sequence of successful decisions.
	var first_exception: bool = (decision.cutoff and stats.cutoffs == 1) or (decision.fallback and stats.fallbacks == 1) or (overdue and stats.over_budget == 1) or (discarded_late and stats.discarded_late == 1)
	if not first_exception and (stats.sample_count >= SAMPLE_LIMIT_PER_SEAT or (stats.count > 3 and not first_of_kind)):
		return
	stats.sample_count += 1
	report.decision_samples.append({"side": side, "seat": seat, "seed": seed_value, "seconds": game_seconds,
		"kind": kind, "reason": decision.get("reason"), "budget_ms": decision.budget_ms, "elapsed_us": elapsed,
		"cutoff": decision.cutoff, "fallback": decision.fallback, "over_budget": overdue, "applied": decision.applied,
		"evaluated": decision.get("evaluated"), "depth": decision.get("depth"), "shop_reason": decision.get("shop_reason"),
		"search_depth": depth, "search_nodes": decision.get("search_nodes", 0), "discarded_late": discarded_late,
		"principal_variation": decision.get("principal_variation", []),
		"candidates": decision.get("candidates", []).slice(0, 5)})

## Include the final settlement even when it ends the game at this timestamp.
static func _collect_events(events: Array, report: Dictionary, game: Dictionary) -> void:
	for event in events:
		match event.kind:
			"work_complete":
				report.flow.work_done += event.ids.size()
				report.flow.work_income += int(event.amount)
			"outsource":
				report.flow.outsource_done += event.ids.size()
			"transfer":
				report.flow.work_transferred += event.ids.size()
				if not event.ids.is_empty(): game.interferences += 1
			"meeting_start", "strike":
				if not event.targets.is_empty(): game.interferences += 1
			"coffee_upgrade":
				report.flow.upgrades += 1
				game.upgrades += 1
				_acquire(game.acquisitions, event.to_type, 1)
			"slack_complete":
				if not event.coffee_ids.is_empty():
					game.tool_generations += 1
					_acquire(game.acquisitions, "coffee", event.coffee_ids.size())
			"fire":
				report.flow.dismissed += 1
				report.flow.dismiss_income += int(event.amount)
			"buy":
				var kind := str(event.card_type)
				report.purchases[kind] = int(report.purchases.get(kind, 0)) + 1
				_acquire(game.acquisitions, kind, 1)
			"conveyor":
				report.market_offers[event.card_type] += 1


static func _acquire(counts: Dictionary, kind: String, amount: int) -> void:
	counts[kind] = int(counts.get(kind, 0)) + amount
