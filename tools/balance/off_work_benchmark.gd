# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Config = preload("res://engine/off_work_config.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")
const Bot = preload("res://engine/off_work_bot.gd")
const Scripted = preload("res://tools/balance/off_work_scripted_baseline.gd")
const Scenarios = preload("res://tools/balance/off_work_benchmark_scenarios.gd")
const LEVELS := {"min":0.0, "low":0.25, "mid":0.5, "high":0.75, "max":1.0}

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var request_path := ""
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--request="): request_path = arg.trim_prefix("--request=")
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	if request_path.is_empty() or output.is_empty():
		printerr("需要 --request 和 --output")
		quit(1)
		return
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	var result: Dictionary = _evaluate(request, output.get_base_dir()) if request is Dictionary else {"error":"invalid request"}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(result, "", false, true))
	file.close()
	quit(1 if result.has("error") else 0)

func _definition() -> Dictionary:
	var config := Config.new()
	if not config.errors.is_empty(): return {"error":"current config: " + str(config.errors)}
	var legacy_config_script: Script = load("res://benchmark_legacy/engine/off_work_config.gd")
	var legacy_preferences: Script = load("res://benchmark_legacy/engine/off_work_bot_preferences.gd")
	var legacy: RefCounted = legacy_config_script.new()
	if not legacy.errors.is_empty(): return {"error":"legacy config: " + str(legacy.errors)}
	var old_policy: Dictionary = legacy.rules.bot.merged(legacy_preferences.strength_parameters(1.0, legacy.rules.bot, legacy.bot_preferences), true)
	old_policy.erase("owner")
	var profiles := {}
	for level in LEVELS:
		var policy: Dictionary = Config.merge_bot_policy(config.rules.bot,
			Preferences.strength_parameters(LEVELS[level], config.rules.bot, config.bot_preferences))
		profiles[level] = policy
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://benchmark_manifest.json"))
	for relative in manifest.files:
		if FileAccess.get_sha256("res://" + relative) != str(manifest.files[relative]):
			return {"error":"runtime snapshot changed: " + str(relative)}
	var current_document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/off_work_bot.json"))
	return {"current_profiles":profiles, "legacy_max":old_policy, "cards":config.balance_document(),
		"models":{"current":current_document.get("model", "legacy_v8"), "legacy":"baseline_v8", "script":"scripted_race_v1"},
		"legacy_bot_sha256":manifest.legacy["engine/off_work_bot.gd"].archived_sha256,
		"simulator_fingerprint":manifest.fingerprint, "godot_version":Engine.get_version_info().string}

func _evaluate(request: Dictionary, folder: String) -> Dictionary:
	var definition := _definition()
	if definition.has("error") or request.get("definition_only", false): return definition
	if not request.has_all(["a", "b", "scenario", "seed", "max_seconds"]): return {"error":"incomplete request"}
	var report := {"simulator_fingerprint":definition.simulator_fingerprint, "godot_version":definition.godot_version,
		"profiles":{"a":request.a, "b":request.b}, "matches":[]}
	if request.get("suite", "race") == "capabilities":
		report.erase("matches")
		report.trials = []
		for seat in 2:
			for side in ["a", "b"]:
				var trial := _capability_trial(request, side, seat, folder)
				if trial.has("error"): return trial
				report.trials.append(trial)
		return report
	for seat in 2:
		var game := _match(request, seat, folder)
		if game.has("error"): return game
		report.matches.append(game)
	return report

func _capability_trial(request: Dictionary, side: String, seat: int, folder: String) -> Dictionary:
	var config := Config.new()
	if not Scenarios.configure(config, request.scenario): return {"error":"invalid capability scenario"}
	var world := OffWorkState.new(config)
	world.new_game(int(request.seed))
	if not Scenarios.prepare(world, request.scenario): return {"error":"capability setup failed"}
	var controller := _bot(world, seat, request[side], int(request.seed))
	if controller == null: return {"error":"unknown capability controller"}
	controller.start()
	var start := world.time
	var limit: float = start + float(request.max_seconds)
	var trace_path := folder.path_join("%s-seat-%d.jsonl" % [side, seat])
	var trace := FileAccess.open(trace_path, FileAccess.WRITE)
	if trace == null: return {"error":"cannot write capability trace"}
	var metrics := _metrics()
	var observed := Scenarios.observe(world, seat)
	_write(trace, {"type":"opening", "suite":"capabilities", "seed":request.seed, "seat":seat, "side":side,
		"scenario":request.scenario, "opponent":"inactive", "actual_policy":controller._policy,
		"rules":config.balance_document(), "snapshot":_snapshot(world), "events":world.drain_events()})
	var wall_start := Time.get_ticks_usec()
	while not Scenarios.achieved(request.scenario, observed) and world.time < limit and world.winner < 0:
		if world.time >= controller.next_action_time():
			var before := _snapshot(world)
			var publications := []
			var publish := func(action: Dictionary, evidence: Dictionary):
				publications.append({"action":action.duplicate(true), "diagnostics":evidence.duplicate(true)})
			controller._next_think = world.time + float(controller._policy.think_seconds)
			var action: Dictionary = controller.decide_action(-1, Callable(), true, publish)
			var diagnostics: Dictionary = controller.last_decision.duplicate(true)
			if diagnostics.get("algorithm", "") != request[side].model:
				return {"error":"capability controller algorithm mismatch"}
			var applied: bool = controller.commit_action(action, diagnostics)
			if not applied: controller.decision_serial += 1
			diagnostics.applied = applied
			_record_metrics(metrics, diagnostics, action, world, seat)
			observed = Scenarios.observe(world, seat, observed)
			_write(trace, {"type":"decision", "t":world.time, "side":side, "seat":seat,
				"snapshot":before, "action":action, "diagnostics":diagnostics, "publications":publications,
				"observed":observed, "events":world.drain_events()})
			if Scenarios.achieved(request.scenario, observed) or world.winner >= 0: break
		# Read the real completion event at its exact time, including outsource
		# completion between action ticks. This does not grant another action.
		var until := minf(limit, controller.next_action_time())
		for batch in world.outsourcing.values():
			if int(batch.owner) == seat: until = minf(until, world.time + float(batch.remaining))
		if until <= world.time: return {"error":"capability clock did not advance"}
		world.advance(until - world.time)
		observed = Scenarios.observe(world, seat, observed)
		_write(trace, {"type":"advance", "t":world.time, "observed":observed, "events":world.drain_events()})
	var result := {"seed":request.seed, "scenario":request.scenario, "side":side, "seat":seat,
		"achieved":Scenarios.achieved(request.scenario, observed), "seconds":world.time - start,
		"wall_seconds":float(Time.get_ticks_usec() - wall_start) / 1000000.0,
		"actual_policy":controller._policy.duplicate(true), "observed":observed, "decision_stats":metrics, "trace":trace_path}
	_write(trace, {"type":"ending", "result":result, "snapshot":_snapshot(world)})
	trace.close()
	return result

func _bot(world: OffWorkState, seat: int, player: Dictionary, seed_value: int) -> RefCounted:
	var controller: RefCounted
	match player.kind:
		"current": controller = Bot.new(world, seat, player.policy.duplicate(true), seed_value)
		"legacy":
			var legacy: Script = load("res://benchmark_legacy/engine/off_work_bot.gd")
			controller = legacy.new(world, seat, player.policy.duplicate(true), seed_value)
			# V8's constructor merged current compatibility defaults. Its entire
			# historical policy is explicit here; no V2 schema may rewrite it.
			controller._policy = player.policy.duplicate(true)
		"script": controller = Scripted.new(world, seat, player.policy.duplicate(true), seed_value)
	return controller

func _match(request: Dictionary, a_seat: int, folder: String) -> Dictionary:
	var config := Config.new()
	if not Scenarios.configure(config, request.scenario): return {"error":"invalid scenario or rules"}
	var world := OffWorkState.new(config)
	world.new_game(int(request.seed))
	if not world.last_error.is_empty() or not Scenarios.prepare(world, request.scenario): return {"error":"scenario setup: " + world.last_error}
	var trace_path := folder.path_join("seat-%d.jsonl" % a_seat)
	var trace := FileAccess.open(trace_path, FileAccess.WRITE)
	if trace == null: return {"error":"cannot write full trace"}
	var policies := {}
	var controllers: Array[RefCounted] = []
	for seat in 2:
		var side := "a" if seat == a_seat else "b"
		var bot := _bot(world, seat, request[side], int(request.seed))
		if bot == null: return {"error":"unknown controller"}
		policies[side] = bot._policy.duplicate(true)
		bot.start()
		controllers.append(bot)
	var start_time := world.time
	var limit: float = start_time + float(request.max_seconds)
	var metrics := {"a":_metrics(), "b":_metrics()}
	_write(trace, {"type":"opening", "seed":request.seed, "a_seat":a_seat, "scenario":request.scenario,
		"actual_policies":policies, "rules":config.balance_document(), "snapshot":_snapshot(world), "events":world.drain_events()})
	var wall_start := Time.get_ticks_usec()
	while world.winner < 0 and world.time < limit:
		_progress(folder, request, a_seat, world, start_time, metrics)
		for seat in 2:
			var bot: RefCounted = controllers[seat]
			if world.winner >= 0 or world.time < bot.next_action_time(): continue
			var side := "a" if seat == a_seat else "b"
			var before := _snapshot(world)
			var bot_rng: Variant = bot.get("_rng").state if bot.get_property_list().any(func(property): return property.name == "_rng") else null
			var publications := []
			var publish := func(action: Dictionary, evidence: Dictionary):
				publications.append({"action":action.duplicate(true), "diagnostics":evidence.duplicate(true)})
			# Same scheduling and commit boundary as Bot.advance, exposing the exact
			# selected command for diagnostics without applying any extra actions.
			bot._next_think = float(world.time) + float(bot._policy.think_seconds)
			var action: Dictionary = bot.decide_action(-1, Callable(), true, publish)
			var diagnostics: Dictionary = bot.last_decision.duplicate(true)
			if request[side].kind == "current" and diagnostics.get("algorithm", "") != request[side].get("model", ""):
				return {"error":"actual current algorithm differs from declared model"}
			var applied: bool = bot.commit_action(action, diagnostics)
			if not applied: bot.decision_serial += 1
			diagnostics["applied"] = applied
			var events := world.drain_events()
			_record_metrics(metrics[side], diagnostics, action, world, seat)
			_write(trace, {"type":"decision", "t":world.time, "side":side, "seat":seat,
				"snapshot":before, "bot_rng_before":bot_rng, "action":action, "diagnostics":diagnostics, "publications":publications, "events":events})
		if world.winner >= 0: break
		var next_action := minf(controllers[0].next_action_time(), controllers[1].next_action_time())
		var delta := minf(minf(limit, next_action) - world.time, 32.0 * config.number("conveyor", "interval_seconds"))
		if delta <= 0.0: return {"error":"simulation clock did not advance"}
		world.advance(delta)
		_write(trace, {"type":"advance", "t":world.time, "events":world.drain_events()})
	var outcome := "timeout"
	if world.winner >= 0:
		outcome = "draw" if world.winner == 2 else ("a" if world.winner == a_seat else "b")
	var result := {"seed":request.seed, "a_seat":a_seat, "scenario":request.scenario, "winner":outcome,
		"seconds":world.time - start_time, "start_time":start_time, "wall_seconds":float(Time.get_ticks_usec() - wall_start) / 1000000.0,
		"a_work":world.work_count(a_seat), "b_work":world.work_count(1 - a_seat),
		"a_money":world.money(a_seat), "b_money":world.money(1 - a_seat),
		"actual_policies":policies, "decision_stats":metrics, "trace":trace_path}
	_write(trace, {"type":"ending", "result":result, "snapshot":_snapshot(world)})
	trace.close()
	return result

func _progress(folder: String, request: Dictionary, seat: int, world: OffWorkState, start_time: float, metrics: Dictionary) -> void:
	var path := folder.path_join("progress.json")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify({"seed":request.seed, "a_seat":seat, "scenario":request.scenario,
		"seconds":world.time - start_time, "max_seconds":request.max_seconds,
		"a_work":world.work_count(seat), "b_work":world.work_count(1 - seat), "decision_stats":metrics}, "", false, true))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)

func _metrics() -> Dictionary:
	return {"decisions":0, "cutoffs":0, "fallbacks":0, "apply_failures":0, "over_budget":0,
		"elapsed_us":0, "max_elapsed_us":0, "max_people":0, "max_overtime":0, "largest_move":0, "actions":{}}

func _record_metrics(metrics: Dictionary, report: Dictionary, action: Dictionary, world: OffWorkState, seat: int) -> void:
	metrics.decisions += 1
	metrics.cutoffs += int(report.get("cutoff", false))
	metrics.fallbacks += int(report.get("fallback", false))
	metrics.apply_failures += int(not report.applied)
	metrics.over_budget += int(report.get("overrun", false))
	metrics.elapsed_us += int(report.get("elapsed_us", 0))
	metrics.max_elapsed_us = maxi(metrics.max_elapsed_us, int(report.get("elapsed_us", 0)))
	metrics.max_people = maxi(metrics.max_people, world.people_count(seat))
	metrics.max_overtime = maxi(metrics.max_overtime, world._owner_type(seat, "overtime").size())
	metrics.largest_move = maxi(metrics.largest_move, action.get("ids", []).size())
	metrics.actions[action.kind] = int(metrics.actions.get(action.kind, 0)) + 1

func _snapshot(world: OffWorkState) -> Dictionary:
	var fields := {}
	for key in OffWorkState.WORLD_FIELDS: fields[key] = world.get(key)
	var bytes := var_to_bytes({"world":fields, "rng":world._rng.state})
	var checksum := HashingContext.new()
	checksum.start(HashingContext.HASH_SHA256)
	checksum.update(bytes)
	return {"encoding":"godot-variant-zstd-base64", "size":bytes.size(), "sha256":checksum.finish().hex_encode(),
		"data":Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_ZSTD))}

func _write(file: FileAccess, entry: Dictionary) -> void:
	file.store_line(JSON.stringify(entry, "", false, true))
	file.flush()
