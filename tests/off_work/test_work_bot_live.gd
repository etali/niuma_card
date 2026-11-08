# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Live = preload("res://engine/off_work_bot_live.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":20},{"employee":1}]
	config.rules.bot.first_action_seconds = 0.15
	config.rules.bot.think_seconds = 1.0
	config.rules.bot.decision_budget_ratio = 0.5
	var state := OffWorkState.new(config)
	state.new_game(17)
	var bot := OffWorkBot.new(state, 1)
	bot.start()
	var driver := Live.new()
	var revision := state.revision
	var market_rng := state._rng.state
	driver.tick(bot, 0.01)
	check(driver._task >= 0 and bot.decision_serial == 0, "start planning before the action, without playing early")
	var until := Time.get_ticks_usec() + 2000000
	while driver._task >= 0 and not WorkerThreadPool.is_task_completed(driver._task) and Time.get_ticks_usec() < until:
		await process_frame
	driver.tick(bot, 0.01)
	check(state.revision == revision and state._rng.state == market_rng and state.time == 0.0, "worker simulates only a frozen private table")
	check(driver._ready != null and not driver._ready.latest().is_empty(), "completed plan is retained until the game clock is due")
	state.advance(0.15)
	driver.tick(bot, 0.0)
	check(bot.decision_serial == 1 and not bot.last_decision.get("live_fallback",false), "action point commits the real background result exactly once")

	# A future, sampled offer can match a real arrival's ID and type by chance.
	# No such synthetic observation may appear as a root action on the actual table.
	var stale := Live.Search.new()
	stale.world = state.fork_for_bot(57,true)
	stale.bot_id = bot.get_instance_id()
	stale.due = state.time
	stale.policy_hash = hash(bot._policy)
	stale.visible_offer_end = state._next_offer
	stale.visible_card_end = state._next_card
	stale.visible_group_end = state._next_group
	var offer := state._make_offer("employee")
	state.offers[0] = offer
	stale.worker = OffWorkBot.new(stale.world,1)
	stale.deadline = Time.get_ticks_usec() + 100000
	var obsolete := {"kind":"buy","offer":offer.id,"card_type":"employee"}
	stale.publish(obsolete,{"kind":"buy"})
	check(not stale.still_legal(state,obsolete), "ignore an offer first seen in a sample even when the real deal matches")
	driver._ready = stale
	bot._next_think = state.time
	driver.tick(bot,0.0)
	check(bot.decision_serial == 2 and bot.last_decision.live_fallback, "a stale plan gets a current-state fallback at the same action point")

	# Hold a pool task deterministically. The frame must complete and provide a
	# fallback before we release the worker, even if the table is closed.
	var gate := Semaphore.new()
	var held := Live.Search.new()
	held.bot_id = bot.get_instance_id()
	held.due = state.time
	held.policy_hash = hash(bot._policy)
	driver._search = held
	driver._task = WorkerThreadPool.add_task(gate.wait)
	bot._next_think = state.time
	driver.tick(bot,0.0)
	check(bot.decision_serial == 3 and bot.last_decision.live_fallback and held.control.is_cancelled(), "late work never blocks an action or mutates the table")
	driver.close(self)
	check(driver._task < 0, "closing a table detaches a running cancelled search without joining the render frame")
	gate.post()
	for frame in 3: await process_frame
	# The worker has already published a full three-ply result but has not
	# finished the deeper layer. Commit that publication without joining it.
	var latch := Semaphore.new()
	var deep := Live.Search.new()
	deep.bot_id = bot.get_instance_id()
	deep.due = state.time
	deep.policy_hash = hash(bot._policy)
	deep.world = state.fork_for_bot(71, true)
	deep.worker = OffWorkBot.new(deep.world, 1)
	deep.deadline = Time.get_ticks_usec() + 100000
	deep.publish({"kind":"wait"},{"kind":"wait", "search_depth":3})
	driver._search = deep
	driver._task = WorkerThreadPool.add_task(latch.wait)
	bot._next_think = state.time
	driver.tick(bot,0.0)
	check(bot.decision_serial == 4 and bot.last_decision.get("search_depth",0) == 3, "use the last completed depth even when a worker is still busy")
	driver.close(self)
	latch.post()
	for frame in 3: await process_frame
	await _large_recording()
	for failure in failures: printerr("FAIL " + failure)
	print("WORK_BOT_LIVE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func _large_recording() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":1050},{"employee":1}]
	config.rules.initial.money = 0
	config.rules.bot.first_action_seconds = 0.55
	config.rules.bot.think_seconds = 2.0
	# This fixture exercises the large snapshot path inside its launch window.
	config.rules.bot.decision_budget_ratio = 0.5
	var state := OffWorkState.new(config)
	state.new_game(415)
	var bot := OffWorkBot.new(state,0)
	bot.start()
	var driver := Live.new()
	driver.bind_config(config)
	driver.tick(bot,0.02)
	check(driver.needs_keyframe and driver._task < 0, "a large live table asks for a coherent frame without a render-thread copy")
	var world := {}
	for key in OffWorkState.WORLD_FIELDS: world[key] = state.get(key)
	var layout := {}
	for key in preload("res://engine/off_work_session.gd").BOARD_FIELDS: layout[key] = {}
	var raw := var_to_bytes({"world":world,"layout":layout,"events":[],"rng":state._rng.state})
	var frame := {"t":state.time, "size":raw.size(), "data":Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD))}
	driver.tick(bot,0.02,frame)
	check(not driver.needs_keyframe and driver._task >= 0, "a recorded large table starts the actual background search")
	var observed_rng := state._rng.state
	var until := Time.get_ticks_usec() + 1500000
	while driver._task >= 0 and Time.get_ticks_usec() < until:
		await process_frame
		driver._collect()
	check(driver._ready != null and not driver._ready.latest().is_empty(), "large-table search publishes a playable result")
	if driver._ready != null:
		check(driver._ready.world._bot_branch and driver._ready.world._rng.seed == bot._rng.state,
			"recording replay uses its own hypothetical market stream")
	check(is_zero_approx(state.time) and state._rng.state == observed_rng, "decoding an observation cannot advance the live clock or market")
	driver.close(self)
