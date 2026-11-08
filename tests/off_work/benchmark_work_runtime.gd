extends SceneTree

## Fixed-step script CPU, without rendering/physics (milliseconds, not FPS):
## godot --headless --path . --script tests/off_work/benchmark_work_runtime.gd
## Actual engine frame intervals and draw calls at 1440x900:
## godot --path . --script tests/off_work/benchmark_work_runtime.gd -- --real-window
## Optional: --frames=90 --output=/tmp/work-runtime.json
## Opt-in large tables (2000 and 4000 work cards PER SIDE; never run in parallel):
## godot --path . --script tests/off_work/benchmark_work_runtime.gd -- --large --real-window
## --large-count=2000 selects one size; smaller positive values allow harness smoke tests.
## --large-money selects a separate 2000-cash-card fixture (--large-money-count=128 for a smoke test).
## --live-bot additionally verifies the real asynchronous BOT during render phases.
## --income=8 stresses large income bursts without changing the shipped card table.
## Large mode also measures replay encoding and one isolated checkpoint per fixture.
class MeasuredState extends OffWorkState:
	var measuring := false
	var samples: Array = []
	func advance(delta: float) -> void:
		var started := Time.get_ticks_usec()
		super.advance(delta)
		if measuring: samples.append(float(Time.get_ticks_usec() - started) / 1000.0)

class Runtime extends "res://scenes/off_work_main.gd":
	var measuring := false
	var samples: Array = []
	func _process(delta: float) -> void:
		var started := Time.get_ticks_usec()
		super._process(delta)
		if measuring: samples.append(float(Time.get_ticks_usec() - started) / 1000.0)

class MeasuredReplay extends "res://engine/off_work_replay.gd":
	var measuring := false
	var samples: Array = []
	func record(host: Node, events: Array = [], force := false) -> void:
		var started := Time.get_ticks_usec()
		super.record(host, events, force)
		if measuring: samples.append(float(Time.get_ticks_usec() - started) / 1000.0)

const FIXTURES := [
	{"name": "opening200", "groups": [{"employee": 1}, {"work": 67}, {"work": 67}, {"work": 66}, {"overtime": 1}, {"coffee": 1}]},
	{"name": "work200", "groups": [{"employee": 1, "work": 200}]},
	{"name": "work500", "groups": [{"employee": 12, "work": 500, "overtime": 4}]},
]
var main: Runtime
var real_window := false
var large := false
var large_counts: Array[int] = [2000, 4000]
var large_money := false
var live_bot := false
var income := 1
var money_count := 2000
var frame_count := 90
var output_path := ""
var results: Dictionary = {}
var metrics: Dictionary = {}
var interactions: Dictionary = {}
var checkpoints: Dictionary = {}
var failures: Array[String] = []
var isolated_data_dir := ""

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	isolated_data_dir = OS.get_cache_dir().path_join("work-runtime-benchmark-%d" % OS.get_process_id())
	OS.set_environment("CARD_DATA_DIR", isolated_data_dir)
	OS.set_environment("WORK_DATA_DIR", isolated_data_dir.path_join("off_work"))
	for argument in OS.get_cmdline_user_args():
		if argument == "--real-window": real_window = true
		elif argument == "--large": large = true
		elif argument == "--large-money": large_money = true
		elif argument == "--live-bot": live_bot = true
		elif argument.begins_with("--income="): income = maxi(1, int(argument.get_slice("=", 1)))
		elif argument.begins_with("--large-money-count="):
			large_money = true
			money_count = int(argument.get_slice("=", 1))
		elif argument.begins_with("--large-count="):
			large = true
			large_counts = [int(argument.get_slice("=", 1))]
		elif argument.begins_with("--frames="): frame_count = maxi(10, int(argument.get_slice("=", 1)))
		elif argument.begins_with("--output="): output_path = argument.trim_prefix("--output=")
	_run.call_deferred()

func _run() -> void:
	if real_window and DisplayServer.get_name() == "headless":
		printerr("--real-window requires a rendering display, not --headless")
		quit(1)
		return
	if large and large_counts.any(func(count): return count < 1 or count > 4000):
		printerr("--large-count must be between 1 and 4000 work cards per side")
		quit(1)
		return
	if large_money and (money_count < 2 or money_count > 4000):
		printerr("--large-money-count must be between 2 and 4000 cash cards per side")
		quit(1)
		return
	root.size = Vector2i(1440, 900)
	main = Runtime.new()
	root.add_child(main)
	await process_frame
	main.audio.muted = true
	main.sfx.user_muted = true
	main.state = MeasuredState.new(main.state.config)
	main.replay = MeasuredReplay.new()
	# No search worker competes with renderer/state measurements. The recorder
	# remains real, including full snapshots on production and user actions.
	main.state.config.rules.bot.enabled = live_bot
	main.state.config.cards.work.income = income
	main.board.touch_mode = true
	main.board._pointer_at = Vector2(1350, 700)
	# Fixed frames below never yield while measuring. Only prevent automatic
	# main updates; child can_process() must retain its real production meaning.
	if not real_window: main.set_process(false)
	if large:
		for count in large_counts: await _large_fixture(count)
	if large_money: await _money_fixture()
	if not large and not large_money:
		await _quick_fixtures()
	if live_bot and int(main.bot.decision_serial) == 0:
		failures.append("live BOT did not submit any decision during the fixture")
	var report := {"mode": "real_window" if real_window else "fixed_step_script_cpu", "resolution": str(root.size),
		"suite": "large" if large or large_money else "quick", "large_counts": large_counts if large else [],
		"large_money_count": money_count if large_money else 0,
		"fixture_scope": "Each side has the listed composition; initial money is additional. Replay recording is enabled.",
		"live_bot": live_bot,
		"income_per_work": income,
		"note": "CPU partitions overlap: state.advance and replay.record are included in main_process. Fixed-step CPU excludes renderer/physics and is not FPS. Checkpoints run separately, outside frame phases.",
		"samples_per_phase": frame_count, "phases": results, "interactions": interactions,
		"checkpoints": checkpoints, "isolated_data_dir": isolated_data_dir, "failures": failures}
	if not output_path.is_empty():
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "  "))
		else: failures.append("Cannot write report: " + output_path)
	print(JSON.stringify(report))
	main.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _quick_fixtures() -> void:
	for fixture in FIXTURES:
		main.state.config.rules.initial.groups = fixture.groups
		await main._new_game()
		main.bot.start()
		await _settle()
		await _measure(str(fixture.name) + "_steady")
		if str(fixture.name) == "opening200": continue
		var gid := int(main.state.cards[main.state.group_people(1)[0]].group)
		var group: Dictionary = main.board.group_of(main.board.by_uid[main.state.group_people(gid)[0]])
		main.board.toggle_compact(group.cards[0])
		await _settle()
		await _measure(str(fixture.name) + "_expanded")
		main.board.toggle_compact(group.cards[-1])
		await _settle()
		var rate: float = main.state.group_work_rate(gid)
		if rate > 0.0:
			var remaining: float = (1.0 - main.state.group_work_progress(gid)) / rate
			main.state.advance(maxf(0.0, remaining - 0.1))
			main.state.drain_events()
			main.board.sync_state(main.state)
			await _measure(str(fixture.name) + "_settlement")
		main.board.begin_side_extract(main.state.group_people(gid).slice(0, 1), Vector2(900, 650))
		await _measure(str(fixture.name) + "_dragging")
		main.board.cancel_pointer()
		main.board.sync_state(main.state)

func _large_fixture(count: int) -> void:
	var label := "work%d" % count
	main.state.config.rules.initial.groups = [{"employee": 12}, {"work": count}, {"overtime": 4}]
	main.state.config.validate()
	if not main.state.config.errors.is_empty():
		failures.append(label + " invalid fixture: " + str(main.state.config.errors))
		return
	var started := Time.get_ticks_usec()
	if not await main._new_game():
		failures.append(label + " initialization failed: " + main.state.last_error)
		return
	interactions[label + "_initialize_ms"] = _elapsed(started)
	await process_frame
	await _settle()
	await _measure(label + "_idle_pre_action")
	# Move only the small personnel/tool piles; the full work pile stays intact.
	# Each side really owns count independent work UIDs, not a quantity proxy.
	for owner in main.state.config.rules.simulation.owners:
		var work_ids := _owned_ids(int(owner), "work")
		var members := _owned_ids(int(owner), "employee") + _owned_ids(int(owner), "overtime")
		if work_ids.is_empty() or main.state.move_cards(members, int(main.state.cards[work_ids[0]].group)) < 0:
			failures.append(label + " production setup failed: " + main.state.last_error)
			return
	await main.board.sync_state(main.state)
	await _settle()
	await _measure(label + "_production_pre_action")
	main.bot.start()
	await _measure(label + "_production")
	var local_owner := int(main.board._settings.local_owner)
	var work_ids := _owned_ids(local_owner, "work")
	if work_ids.is_empty():
		failures.append(label + " work exhausted before interaction phases; use more cards or fewer frames")
		return
	var gid := int(main.state.cards[work_ids[0]].group)
	var rate: float = main.state.group_work_rate(gid)
	if rate > 0.0:
		var remaining: float = (1.0 - main.state.group_work_progress(gid)) / rate
		main.state.advance(maxf(0.0, remaining - 0.05))
		# Keep the events: the next measured frame must record and present them.
		await _measure(label + "_settlement")
	await _settle()
	await _drag_and_split(label, "work")
	_measure_checkpoint(label)

func _money_fixture() -> void:
	var label := "money%d" % money_count
	main.state.config.rules.initial.money = money_count
	main.state.config.rules.initial.groups = [{"employee": 1, "work": 50}]
	main.state.config.validate()
	if not main.state.config.errors.is_empty():
		failures.append(label + " invalid fixture: " + str(main.state.config.errors))
		return
	var started := Time.get_ticks_usec()
	if not await main._new_game():
		failures.append(label + " initialization failed: " + main.state.last_error)
		return
	interactions[label + "_initialize_ms"] = _elapsed(started)
	main.bot.start()
	await process_frame
	await _settle()
	await _measure(label + "_steady")
	await _drag_and_split(label, "money")
	_measure_checkpoint(label)

func _drag_and_split(label: String, kind: String) -> void:
	var local_owner := int(main.board._settings.local_owner)
	var ids := _owned_ids(local_owner, kind)
	if ids.size() < 2:
		failures.append(label + " needs at least two remaining cards for split measurement")
		return
	var points := _empty_table_points()
	if points.size() < 2:
		failures.append(label + " cannot find two empty in-bounds drop points")
		return
	var started := Time.get_ticks_usec()
	var began: bool = main.board.begin_side_extract(ids, points[0])
	interactions[label + "_drag_begin_ms"] = _elapsed(started)
	if not began:
		failures.append(label + " whole-pile drag failed to begin")
		return
	await _measure(label + "_dragging", points)
	started = Time.get_ticks_usec()
	main.board.cancel_pointer()
	interactions[label + "_drag_cancel_ms"] = _elapsed(started)
	await main.board.sync_state(main.state)
	await _settle()
	ids = _owned_ids(local_owner, kind)
	var extracted := ids.slice(0, ids.size() / 2)
	var source_gid := int(main.state.cards[extracted[0]].group)
	var before_cards: int = main.state.cards.size()
	started = Time.get_ticks_usec()
	began = main.board.begin_side_extract(extracted, points[0])
	interactions[label + "_split_begin_ms"] = _elapsed(started)
	if not began:
		failures.append(label + " half-pile extraction failed to begin")
		return
	# Native release commits the real UI→state move (no direct state substitute).
	started = Time.get_ticks_usec()
	main.board.release_pointer(points[1])
	interactions[label + "_split_release_ms"] = _elapsed(started)
	# The normal signal queues this callback. Flush that same callback so the
	# fixed-step harness measures its cost and validates the committed state;
	# the already queued callback becomes a no-op, just as after a normal flush.
	started = Time.get_ticks_usec()
	main.board._commit_drop()
	interactions[label + "_split_commit_ms"] = _elapsed(started)
	var destination := int(main.state.cards[extracted[0]].group)
	var intact: bool = extracted.all(func(uid): return main.state.cards.has(uid) and int(main.state.cards[uid].group) == destination)
	if destination == source_gid or not intact or main.state.cards.size() != before_cards or main.board.is_dragging():
		failures.append(label + " native split did not preserve and separate all selected cards")
	await _measure(label + "_after_split")

func _measure_checkpoint(label: String) -> void:
	var session = preload("res://engine/off_work_session.gd")
	var slots = preload("res://engine/shift_slot.gd")
	var started := Time.get_ticks_usec()
	var saved: bool = session.save_session(main)
	var elapsed := _elapsed(started)
	var checkpoint := FileAccess.open(slots.path(slots.OFF_WORK), FileAccess.READ)
	checkpoints[label] = {"save_ms": elapsed, "ok": saved, "bytes": checkpoint.get_length() if checkpoint != null else 0,
		"replay_frames": main.replay.frames.size(), "replay": _replay_volume(0)}
	if not saved: failures.append(label + " isolated checkpoint failed")

func _owned_ids(owner: int, kind: String) -> Array:
	var ids: Array = []
	for uid in main.state.cards:
		var card: Dictionary = main.state.cards[uid]
		if int(card.owner) == owner and str(card.type) == kind: ids.append(uid)
	return ids

func _empty_table_points() -> Array[Vector2]:
	var found: Array[Vector2] = []
	var bounds: Rect2 = main.board.player_bounds.grow(-maxf(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z))
	for row in range(1, 8):
		for column in range(1, 10):
			var world := Vector3(lerpf(bounds.position.x, bounds.end.x, column / 10.0), Board.DRAG_HEIGHT,
				lerpf(bounds.position.y, bounds.end.y, row / 8.0))
			var at: Vector2 = main.board.camera.unproject_position(world)
			if not Rect2(Vector2(24, 24), Vector2(root.size) - Vector2(48, 48)).has_point(at): continue
			if main.board._nearest_group(world, []) != null or main.board._nearest_loose_card(world, []) != null: continue
			if found.is_empty(): found.append(at)
			elif found[0].distance_to(at) >= 140.0:
				found.append(at)
				return found
	return found

func _elapsed(started: int) -> float:
	return float(Time.get_ticks_usec() - started) / 1000.0

func _replay_volume(first: int) -> Dictionary:
	var raw := 0
	var encoded := 0
	for index in range(first, main.replay.frames.size()):
		var frame: Dictionary = main.replay.frames[index]
		raw += int(frame.size)
		encoded += str(frame.data).length()
	return {"frames": main.replay.frames.size() - first, "raw_bytes": raw, "base64_bytes": encoded}

func _settle() -> void:
	if real_window: await create_timer(0.5).timeout
	else:
		for _index in 30: _fixed_frame()

func _measure(label: String, pointer_path: Array[Vector2] = []) -> void:
	metrics = {}
	main.samples = []
	main.state.samples = []
	main.replay.samples = []
	var first_frame: int = main.replay.frames.size()
	main.measuring = true
	main.state.measuring = true
	main.replay.measuring = true
	var last := Time.get_ticks_usec()
	for index in frame_count:
		if pointer_path.size() == 2:
			main.board._pointer_at = pointer_path[0].lerp(pointer_path[1], float(index) / maxf(1.0, frame_count - 1.0))
		if real_window:
			await process_frame
			var now := Time.get_ticks_usec()
			_sample("frame_interval_ms", float(now - last) / 1000.0)
			last = now
			_sample("draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			_sample("physics_process_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		else: _fixed_frame(true)
	main.measuring = false
	main.state.measuring = false
	main.replay.measuring = false
	metrics.main_process_ms = main.samples
	metrics.state_advance_ms = main.state.samples
	metrics.replay_record_ms = main.replay.samples
	var summary := {"cards_total": main.state.cards.size(), "viewport_size": str(root.size), "replay_added": _replay_volume(first_frame),
		"replay_frames_total": main.replay.frames.size()}
	if live_bot:
		summary["bot_decisions_total"] = int(main.bot.decision_serial)
		summary["bot_last_action"] = str(main.bot.last_decision.get("kind", ""))
	for key in metrics: summary[key] = _summary(metrics[key])
	results[label] = summary
	print("WORK_RUNTIME_PHASE ", label, " ", JSON.stringify(summary))

func _fixed_frame(measure := false) -> void:
	var all := Time.get_ticks_usec()
	main._process(1.0 / 60.0)
	var started := Time.get_ticks_usec()
	main.board._process(1.0 / 60.0)
	if measure: _sample("board_process_ms", float(Time.get_ticks_usec() - started) / 1000.0)
	started = Time.get_ticks_usec()
	var active := 0
	for card in main.board.by_uid.values() + main.board.offers_by_id.values():
		if card.is_processing() and card.can_process():
			active += 1
			card._process(1.0 / 60.0)
	if measure: _sample("card_process_ms", float(Time.get_ticks_usec() - started) / 1000.0)
	if measure: _sample("active_card_processes", active)
	main.conveyor._process(1.0 / 60.0)
	main.effects._process(1.0 / 60.0)
	for tween in get_processed_tweens():
		if tween.is_valid(): tween.custom_step(1.0 / 60.0)
	if measure: _sample("script_total_ms", float(Time.get_ticks_usec() - all) / 1000.0)

func _sample(key: String, value: float) -> void:
	if not metrics.has(key): metrics[key] = []
	metrics[key].append(value)

func _summary(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	values.sort()
	return {"count": values.size(), "median": values[values.size() / 2],
		"p95": values[mini(values.size() - 1, floori(values.size() * 0.95))], "max": values[-1]}
