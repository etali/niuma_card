extends SceneTree
## Measures the production runner without replacing its methods. A simulation
## step is timed, then a real engine frame is yielded. CPU time and frame wall
## interval are separate measurements; a headless interval is never called FPS.
const Runner = preload("res://scenes/work_animation_scenario.gd")
var samples: Array = []

func _initialize() -> void:
	_run.call_deferred()

func distribution(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in ordered: total += float(value)
	var middle := ordered.size() / 2
	var median := float(ordered[middle]) if ordered.size() % 2 == 1 else (float(ordered[middle - 1]) + float(ordered[middle])) * 0.5
	return {"count": ordered.size(), "total": total, "median": median,
		"p95": ordered[int(floor(0.95 * float(ordered.size() - 1)))],
		"p99": ordered[int(floor(0.99 * float(ordered.size() - 1)))], "max": ordered[-1]}

func summary(rows: Array) -> Dictionary:
	return {"steps": rows.size(),
		"advance_cpu_ms": distribution(rows.map(func(row): return row.advance_cpu_ms)),
		"frame_wall_ms": distribution(rows.map(func(row): return row.frame_wall_ms))}

func _run() -> void:
	var options := {"scenario": "huge_stack_extract", "out": "res://reports/benchmark-animation-runtime.json", "step-fps": "60"}
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--") or not argument.contains("="): continue
		var parts := argument.trim_prefix("--").split("=", true, 1)
		options[parts[0]] = parts[1]
	var fps := float(options["step-fps"])
	if fps <= 0.0:
		printerr("--step-fps must be positive")
		quit(1)
		return
	var path := str(options.out)
	if not path.is_absolute_path() and not path.begins_with("res://") and not path.begins_with("user://"): path = "res://" + path
	path = ProjectSettings.globalize_path(path)
	root.size = Vector2i(1280, 720)
	var host := SubViewportContainer.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.stretch = true
	root.add_child(host)
	var viewport := SubViewport.new()
	viewport.size = root.size
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(viewport)
	var runner := Runner.new()
	viewport.add_child(runner)
	var build_start := Time.get_ticks_usec()
	runner.load_scenario(str(options.scenario))
	var build_ms := float(Time.get_ticks_usec() - build_start) / 1000.0
	if runner.entry.is_empty():
		printerr("Unknown scenario: ", options.scenario)
		quit(1)
		return
	await process_frame
	var started := Time.get_ticks_usec()
	var drawn_at_start := Engine.get_frames_drawn()
	var initial_cards := runner.state.cards.size() if runner.state != null else 0
	var step := 1.0 / fps
	while runner.time() < runner.duration() - 0.0000001:
		var at := runner.time()
		var frame_start := Time.get_ticks_usec()
		runner.advance(minf(step, runner.duration() - at))
		var cpu_ms := float(Time.get_ticks_usec() - frame_start) / 1000.0
		var row := {"from_seconds": at, "to_seconds": runner.time(), "action_index": runner._action_index - 1,
			"advance_cpu_ms": cpu_ms, "logical_cards": runner.state.cards.size() if runner.state != null else 0,
			"owned_tweens": runner._owned_tweens.size()}
		await process_frame
		row["frame_wall_ms"] = float(Time.get_ticks_usec() - frame_start) / 1000.0
		samples.append(row)
	var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var phases: Array = []
	var actions: Array = runner.entry.get("actions", [])
	for index in range(-1, actions.size()):
		var rows := samples.filter(func(row): return int(row.action_index) == index)
		if rows.is_empty(): continue
		var phase := summary(rows)
		phase["from_seconds"] = 0.0 if index < 0 else float(actions[index].at)
		phase["to_seconds"] = runner.duration() if index + 1 >= actions.size() else float(actions[index + 1].at)
		phase["action"] = "initial" if index < 0 else str(actions[index].kind)
		phases.append(phase)
	var result := {"scenario": runner.selected_id, "name": runner.entry.name, "engine": Engine.get_version_info().string,
		"display_server": DisplayServer.get_name(), "viewport_size": [viewport.size.x, viewport.size.y],
		"measurement": "Fixed simulation step followed by one engine frame; advance_cpu_ms excludes rendering. Headless frame_wall_ms is not rendered FPS.",
		"step_seconds": step, "simulation_seconds": runner.time(), "build_cpu_ms": build_ms, "playback_wall_ms": wall_ms,
		"initial_logical_cards": initial_cards, "summary": summary(samples), "phases": phases, "samples": samples}
	if DisplayServer.get_name() != "headless": result["rendered_frame_count"] = Engine.get_frames_drawn() - drawn_at_start
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("Cannot write benchmark output: ", path, " error=", FileAccess.get_open_error())
		quit(1)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	var cpu: Dictionary = result.summary.advance_cpu_ms
	print("ANIMATION_RUNTIME ", result.scenario, " steps=", samples.size(), " simulation_s=", result.simulation_seconds,
		" CPU median_ms=", cpu.median, " p95_ms=", cpu.p95, " max_ms=", cpu.max, " output=", path)
	for phase in phases:
		print("PHASE %.2f-%.2f %s CPU median=%.3fms p95=%.3fms max=%.3fms" % [phase.from_seconds, phase.to_seconds,
			phase.action, phase.advance_cpu_ms.median, phase.advance_cpu_ms.p95, phase.advance_cpu_ms.max])
	host.queue_free()
	await process_frame
	quit()
