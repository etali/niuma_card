extends SceneTree

## Fixed-step script CPU, without rendering/physics (milliseconds, not FPS):
## godot --headless --path . --script tests/benchmark_work_runtime.gd
## Actual engine frame intervals and draw calls at 1440x900:
## godot --path . --script tests/benchmark_work_runtime.gd -- --real-window
## Optional: --frames=90 --output=/tmp/work-runtime.json
class MeasuredState extends WorkState:
	var measuring := false
	var samples: Array = []
	func advance(delta: float) -> void:
		var started := Time.get_ticks_usec()
		super.advance(delta)
		if measuring: samples.append(float(Time.get_ticks_usec() - started) / 1000.0)

class Runtime extends "res://scenes/work_main.gd":
	var measuring := false
	var samples: Array = []
	func _process(delta: float) -> void:
		var started := Time.get_ticks_usec()
		super._process(delta)
		if measuring: samples.append(float(Time.get_ticks_usec() - started) / 1000.0)

const FIXTURES := [
	{"name": "opening200", "groups": [{"employee": 1}, {"work": 67}, {"work": 67}, {"work": 66}, {"overtime": 1}, {"coffee": 1}]},
	{"name": "work200", "groups": [{"employee": 1, "work": 200}]},
	{"name": "work500", "groups": [{"employee": 12, "work": 500, "overtime": 4}]},
]
var main: Runtime
var real_window := false
var frame_count := 90
var output_path := ""
var results: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", OS.get_cache_dir().path_join("work-runtime-benchmark-%d" % OS.get_process_id()))
	for argument in OS.get_cmdline_user_args():
		if argument == "--real-window": real_window = true
		elif argument.begins_with("--frames="): frame_count = maxi(10, int(argument.get_slice("=", 1)))
		elif argument.begins_with("--output="): output_path = argument.trim_prefix("--output=")
	_run.call_deferred()

func _run() -> void:
	if real_window and DisplayServer.get_name() == "headless":
		printerr("--real-window requires a rendering display, not --headless")
		quit(1)
		return
	root.size = Vector2i(1440, 900)
	main = Runtime.new()
	root.add_child(main)
	await process_frame
	main.audio.muted = true
	main.sfx.user_muted = true
	main.state = MeasuredState.new(main.state.config)
	main.board.touch_mode = true
	main.board._pointer_at = Vector2(1350, 700)
	if not real_window: main.process_mode = Node.PROCESS_MODE_DISABLED
	for fixture in FIXTURES:
		main.state.config.rules.initial.groups = fixture.groups
		main._new_game()
		main.bot.start()
		main.state.config.rules.bot.enabled = false
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
	var report := {"mode": "real_window" if real_window else "fixed_step_script_cpu", "resolution": "1440x900",
		"fixture_scope": "Each side has the listed composition; initial money is additional.",
		"note": "CPU partitions overlap: state.advance is included in main_process. Fixed-step CPU excludes renderer/physics and is not FPS.",
		"samples_per_phase": frame_count, "phases": results}
	if not output_path.is_empty():
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "  "))
	print(JSON.stringify(report))
	main.queue_free()
	await process_frame
	quit()

func _settle() -> void:
	if real_window: await create_timer(0.5).timeout
	else:
		for _index in 30: _fixed_frame()

func _measure(label: String) -> void:
	metrics = {}
	main.samples = []
	main.state.samples = []
	main.measuring = true
	main.state.measuring = true
	var last := Time.get_ticks_usec()
	for _index in frame_count:
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
	metrics.main_process_ms = main.samples
	metrics.state_advance_ms = main.state.samples
	var summary := {"cards_total": main.state.cards.size()}
	for key in metrics: summary[key] = _summary(metrics[key])
	results[label] = summary

func _fixed_frame(measure := false) -> void:
	var all := Time.get_ticks_usec()
	main._process(1.0 / 60.0)
	var started := Time.get_ticks_usec()
	main.board._process(1.0 / 60.0)
	if measure: _sample("board_process_ms", float(Time.get_ticks_usec() - started) / 1000.0)
	started = Time.get_ticks_usec()
	for card in main.board.by_uid.values() + main.board.offers_by_id.values(): card._process(1.0 / 60.0)
	if measure: _sample("card_process_ms", float(Time.get_ticks_usec() - started) / 1000.0)
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
