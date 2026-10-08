# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 同一固定局面的真实 BOT 行动与大量产出探针；不把机器相关耗时当作回归断言。
## pre→post 是渲染信号间的墙钟跨度，包含驱动同步，不能解释为 GPU 纯执行时间。
const LONG_FRAME_MS := 30.0
const FIXTURE := ["shuabuting", "user", "user", "user", "user", "user",
	"yinqing996", "yinqing996", "yinqing996"]
var _main: Node
var _seed_value := 42
var _timeout_seconds := 60.0
var _output := "res://build/turn-frames.json"
var _move_pointer := false
var _original_pointer := Vector2i.ZERO
var _sampling := false
var _reporting := false
var _stage := "startup"
var _started := 0
var _last_tick := 0
var _last_phase := "startup"
var _draw_started := 0
var _draw_phase := ""
var _phases := {}
var _long_frames: Array = []
var _transitions: Array = []
var _samples := 0
var _render_samples := 0
var _initial := {}
var _saw_bot := false
var _saw_settling := false

func _initialize() -> void:
	# harness 即使继承了 TEST_SPEED=5，此处也在首帧前恢复真实游戏时间和物理步长。
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	if not _parse_args():
		quit(2)
		return
	if _move_pointer:
		_original_pointer = DisplayServer.mouse_get_position()
	auto_accept_quit = false
	root.close_requested.connect(func(): _complete("window_closed", 1))
	_started = Time.get_ticks_usec()
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	create_timer(_timeout_seconds, true, false, true).timeout.connect(func():
		if not _reporting:
			_complete("timeout", 1))
	call_deferred("_run")

func _parse_args() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed=") and arg.trim_prefix("--seed=").is_valid_int():
			_seed_value = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--timeout=") and arg.trim_prefix("--timeout=").is_valid_float():
			_timeout_seconds = float(arg.trim_prefix("--timeout="))
		elif arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")
		elif arg == "--move-pointer":
			_move_pointer = true
		else:
			printerr("用法：profile_turn_frames.gd -- [--seed=42] [--timeout=60] [--output=build/turn-frames.json] [--move-pointer]")
			return false
	if _timeout_seconds <= 0.0 or _timeout_seconds > 300.0:
		printerr("timeout 必须大于 0 且不超过 300 秒")
		return false
	var build_dir := ProjectSettings.globalize_path("res://build").simplify_path().trim_suffix("/")
	_output = ProjectSettings.globalize_path(_output if _output.is_absolute_path() else "res://" + _output).simplify_path()
	if not _output.begins_with(build_dir + "/") or not _output.ends_with(".json"):
		printerr("output 必须是项目 build 目录内的 .json 文件")
		return false
	if DirAccess.make_dir_recursive_absolute(_output.get_base_dir()) != OK:
		printerr("无法创建输出目录")
		return false
	return true

func _run() -> void:
	BOTSearch.set_pref_strength(0.5)
	BOTSearch.set_override("sales", 0)
	_sampling = true
	_last_tick = Time.get_ticks_usec()
	# CARD_SEED 控制发牌，全局 seed 同时固定视觉随机位置。环境只改当前进程且立即恢复。
	var had_seed := OS.has_environment("CARD_SEED")
	var previous_seed := OS.get_environment("CARD_SEED")
	OS.set_environment("CARD_SEED", str(_seed_value))
	seed(_seed_value)
	_main = load("res://scenes/main.tscn").instantiate()
	_main.force_drawer_layout = true
	_main.drawer_ui_scale = 1.0
	root.add_child(_main)
	_booted = _main
	if had_seed:
		OS.set_environment("CARD_SEED", previous_seed)
	else:
		OS.unset_environment("CARD_SEED")
	if _main.state == null or _main.board == null or _main.drawer_window == null:
		_complete("scene_initialization_failed", 1)
		return
	_main.drawer_window.activate_handle()
	_main.drawer_window.pin()
	_main.drawer_window.set_process(false)
	_main.get_window().grab_focus()
	await create_timer(1.5, true, false, true).timeout
	if _reporting:
		return
	_set_stage("fixture")
	var group: Array = []
	for id in FIXTURE:
		var record: Dictionary = _main.state.add_card(_main.my_seat, id)
		group.append(_main._spawn_entity(record, Vector3(-3, 0.3, 3.2), true))
	_main.board.groups.append(_main.board.make_group(group, true))
	_main.board.refresh_group(_main.board.groups.back())
	_main.state.add_card(_main.foe_seat, "shuabuting")
	_main._sync_entities()
	await create_timer(0.6, true, false, true).timeout
	if _reporting:
		return
	if _main._actor != _main.my_seat or _main.phase != PhaseMachine.ACTION or _main.board.input_locked:
		_complete("fixture_not_ready_for_player_action", 1)
		return
	_initial = _context()
	_initial["fixture_state_hash"] = StateCodec.state_hash(_main.state)
	_initial["fixture_entities"] = _main.entities.size()
	_initial["fixture_core_piles"] = _main._core_piles()
	_set_stage("idle")
	await create_timer(2.0, true, false, true).timeout
	if _reporting:
		return
	_set_stage("turn")
	_main._on_action_done()
	while not _reporting and _main.state.round_num < 2 and _main.state.winner == "":
		await process_frame
	if _reporting:
		return
	_set_stage("after_turn")
	await create_timer(1.0, true, false, true).timeout
	if not _reporting:
		_complete("completed" if _saw_bot and _saw_settling else "required_phase_missing",
			0 if _saw_bot and _saw_settling else 1)

func _phase() -> String:
	if _stage != "turn" or not is_instance_valid(_main):
		return _stage
	if _main._thinking:
		return "bot_thinking"
	if _main.phase == PhaseMachine.SETTLING:
		return "settling"
	if _main.phase == PhaseMachine.ACTION and _main._actor == _main.foe_seat:
		return "bot_action"
	return str(_main.phase) + "/" + str(_main._actor)

func _set_stage(stage: String) -> void:
	_stage = stage
	_last_phase = _phase()
	_transitions.append({"at_ms": (Time.get_ticks_usec() - _started) / 1000.0, "phase": _last_phase})

func _process(_delta: float) -> bool:
	if not _sampling:
		return false
	var now := Time.get_ticks_usec()
	_sample_interval(now)
	var phase := _phase()
	_saw_bot = _saw_bot or phase == "bot_thinking" or phase == "bot_action"
	_saw_settling = _saw_settling or phase == "settling"
	if phase != _last_phase:
		_transitions.append({"at_ms": (now - _started) / 1000.0, "phase": phase})
	_last_phase = phase
	if _move_pointer and is_instance_valid(_main) and _main.drawer_presentation != null:
		var area: Rect2 = _main.drawer_presentation.content_rect()
		var progress := float(_samples % 180) / 180.0
		_main.get_viewport().warp_mouse(Vector2(lerpf(area.position.x + 20, area.end.x - 20, progress), area.position.y + area.size.y * 0.4))
	return false

func _sample_interval(now: int) -> void:
	if _last_tick > 0:
		_record(_last_phase, "frame_interval", (now - _last_tick) / 1000.0)
		_samples += 1
	_last_tick = now

func _on_pre_draw() -> void:
	if _sampling:
		_draw_started = Time.get_ticks_usec()
		_draw_phase = _phase()

func _on_post_draw() -> void:
	if _sampling and _draw_started > 0:
		_record(_draw_phase, "render_pre_post", (Time.get_ticks_usec() - _draw_started) / 1000.0)
		_render_samples += 1
	_draw_started = 0

func _record(phase: String, metric: String, ms: float) -> void:
	if not _phases.has(phase):
		_phases[phase] = {"frame_interval": [], "render_pre_post": []}
	_phases[phase][metric].append(ms)
	if ms > LONG_FRAME_MS:
		_long_frames.append({"phase": phase, "metric": metric, "ms": ms,
			"at_ms": (Time.get_ticks_usec() - _started) / 1000.0,
			"frame": Engine.get_process_frames(), "context": _context(),
			"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0})

func _context() -> Dictionary:
	var result := {"window_pixels": [root.size.x, root.size.y],
		"viewport_pixels": [root.get_visible_rect().size.x, root.get_visible_rect().size.y],
		"content_scale_factor": root.content_scale_factor, "focused": root.has_focus(),
		"screen_scale": DisplayServer.screen_get_scale(root.current_screen) if DisplayServer.get_name() != "headless" else 1.0,
		"mouse_mode": Input.mouse_mode, "cursor_visible": Input.mouse_mode in [Input.MOUSE_MODE_VISIBLE, Input.MOUSE_MODE_CONFINED]}
	var warmup = load("res://scenes/table_render_warmup.gd")
	result["render_warmup_completed"] = warmup._completed
	if is_instance_valid(_main) and _main.state != null:
		result.merge({"round": _main.state.round_num, "winner": _main.state.winner,
			"entities": _main.entities.size(), "phase": _main.phase, "actor": _main._actor,
			"drawer_ui_scale": _main.drawer_ui_scale})
		if is_instance_valid(_main.table_hands):
			var native_key: Variant = _main.table_hands.get("_cursor_key")
			result["cursor_key"] = str(native_key) if native_key != null else ""
			result["cursor_pointing"] = _main.table_hands.get("_pointing")
	return result

func _summary(values: Array) -> Dictionary:
	if values.is_empty():
		return {"n": 0, "p50_ms": null, "p95_ms": null, "max_ms": null, "over_30ms": 0}
	var ordered := values.duplicate()
	ordered.sort()
	return {"n": ordered.size(), "p50_ms": ordered[int((ordered.size() - 1) * 0.5)],
		"p95_ms": ordered[int((ordered.size() - 1) * 0.95)], "max_ms": ordered.back(),
		"over_30ms": ordered.filter(func(value): return value > LONG_FRAME_MS).size()}

func _complete(status: String, exit_code: int) -> void:
	if _reporting:
		return
	_reporting = true
	_sampling = false
	RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)
	RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	var summary := {}
	for phase in _phases:
		summary[phase] = {}
		for metric in _phases[phase]:
			summary[phase][metric] = _summary(_phases[phase][metric])
	var report := {"schema": "turn-frames-v1", "status": status, "exit_code": exit_code,
		"seed": _seed_value, "test_speed": Engine.time_scale, "physics_ticks": Engine.physics_ticks_per_second,
		"timeout_seconds": _timeout_seconds, "elapsed_ms": (Time.get_ticks_usec() - _started) / 1000.0,
		"move_pointer": _move_pointer, "godot": Engine.get_version_info()["string"],
		"adapter": RenderingServer.get_video_adapter_name(), "display_server": DisplayServer.get_name(),
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"rendering_measurement_valid": DisplayServer.get_name() != "headless" and _render_samples > 0,
		"render_metric": "RenderingServer frame_pre_draw to frame_post_draw wall-clock; includes driver synchronization",
		"fixture": FIXTURE, "bot_strength": 0.5, "bot_sales": 0,
		"observed_bot": _saw_bot, "observed_settling": _saw_settling,
		"initial": _initial, "final": _context(), "phases": summary,
		"samples": _samples, "render_samples": _render_samples,
		"transitions": _transitions, "long_frames": _long_frames, "raw_ms": _phases}
	var released := _main
	if is_instance_valid(_main):
		_main._invalidate_session()
		_main.queue_free()
	_main = null
	_booted = null
	paused = false
	await process_frame
	await process_frame
	if _move_pointer:
		DisplayServer.warp_mouse(_original_pointer)
	report["cleanup"] = {"scene_released": not is_instance_valid(released), "cursor": _context()}
	var file := FileAccess.open(_output, FileAccess.WRITE)
	if file == null:
		printerr("无法写入帧性能报告：", FileAccess.get_open_error())
		exit_code = 1
	else:
		file.store_string(JSON.stringify(report, "  ") + "\n")
		file.close()
		print("FRAME_REPORT ", ProjectSettings.localize_path(_output), " status=", status,
			" samples=", _samples, " render_samples=", _render_samples, " exit_code=", exit_code)
	check(exit_code == 0, "探针完成 BOT 行动与结算；状态=" + status)
	finish()
