extends SceneTree

const Preview = preload("res://scenes/work_animation_preview.tscn")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func wait_frames(card: WorkCard) -> bool:
	var start := Time.get_ticks_msec()
	while not card.illustration_ready() and Time.get_ticks_msec() - start < 15000:
		await process_frame
	return card.illustration_ready()

func check_shader_sync(preview: Control, label: String) -> void:
	var production: ShaderMaterial = preview.card._icon.material_override
	var enlarged: ShaderMaterial = preview._large.material
	check(production != null and enlarged != null, label + ": both surfaces use continuous materials")
	if production == null or enlarged == null: return
	var shared := ["motion_seconds", "art_texture", "motion_tint", "motion_duration", "motion_region_count",
		"motion_shapes", "motion_pivots", "motion_moves", "motion_extras"]
	var equal := true
	for key in shared:
		equal = equal and production.get_shader_parameter(key) == enlarged.get_shader_parameter(key)
	check(equal, label + ": same master, exact time, tint and local motion configuration")

func _run() -> void:
	var viewer := Preview.instantiate()
	root.add_child(viewer)
	var preview: Control = viewer.work_preview
	await process_frame
	check(preview.ids.size() == 14 and preview.ids.size() == WorkCardDB.all_cards().size(), "all fourteen formal card types are listed")
	check(preview.spec.states.size() == 5 and preview.entries.size() >= 19, "all five personnel strike states accompany the fourteen base motions")
	check(preview.entries.all(func(entry): return preview._buttons.has(str(entry.id))), "every registered animation has a navigation button")
	check(preview.card is WorkCard and preview.card is CardEntity, "preview uses the production card and original frame")
	check(preview.find_children("*", "WorkState", true, false).is_empty(), "no match state is started")
	check(preview.find_children("*", "WorkBot", true, false).is_empty(), "no opponent is started")
	preview.show_card("money")
	check(preview.card.record.activity == "idle", "viewing art never simulates a task")
	check(preview.card.freeze and not preview.card.draggable, "preview card cannot fall away or start gameplay dragging")
	check(CardArt.source_art_id("money", WorkCardDB) == "cash", "money resolves the original cash art")
	var ready: bool = await wait_frames(preview.card)
	check(ready, "original cash master is ready for continuous animation")
	if ready:
		preview.seek_frame(7)
		check(preview.paused and preview.card.hover_animation_paused, "scrubbing pauses both controls and production player")
		check(preview.card._hover_frame == 7, "scrubbing lands on the requested exact time sample")
		check(preview._large.texture == preview.card._icon.texture, "large illustration uses the exact displayed card texture")
		check_shader_sync(preview, "cash scrub")
		preview.step_frame(1)
		check(preview.card._hover_frame == 8, "next advances one time sample")
		preview.step_frame(-1)
		check(preview.card._hover_frame == 7, "previous rewinds one time sample")
		await create_timer(0.25).timeout
		check(preview.card._hover_frame == 7, "paused time remains still across process ticks")
		var time_before: float = preview.card._hover_elapsed
		preview.set_speed(0.5)
		check(is_equal_approx(preview.speed, 0.5) and is_equal_approx(preview.card.hover_animation_speed, 0.5), "speed uses the production playback multiplier")
		check(is_equal_approx(time_before, preview.card._hover_elapsed), "speed changes preserve animation position")
		preview.show_original(true)
		check(preview.card._hover_frame == 0 and preview._original.button_pressed, "original view uses the exact master at zero motion time")
		preview.show_original(false)
		check(preview.card._hover_frame == 7 and preview.paused, "returning from original restores sample and paused state")
		preview.replay()
		check(not preview.paused and is_zero_approx(preview.card._hover_elapsed), "replay restarts and unpauses the production player")
		await create_timer(0.65).timeout
		check(preview.card._hover_frame > 0, "production animation progresses without a match")
		preview.set_paused(true)
		var retained: int = preview.card._hover_frame
		preview._play.button_pressed = false
		check(not preview.paused and preview.card._hover_frame == retained, "play button resumes without resetting pose")
		preview.set_paused(true)
	var former: WorkCard = preview.card
	preview.show_card("employee")
	check(not is_instance_valid(former), "switching card releases the previous production instance")
	check(preview.card.def_id == "employee" and preview.card.label.text == WorkCardDB.card_name("employee"), "card selection follows real definitions")
	check(preview.paused and preview.card.hover_animation_paused, "changing cards preserves pause preference")
	check(is_equal_approx(preview.card.hover_animation_speed, preview.speed), "changing cards preserves preview speed")
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_RIGHT
	preview._play.grab_focus()
	Input.parse_input_event(event)
	await process_frame
	check(preview.selected_id == "grinder", "arrow key selects next listed card")
	event.keycode = KEY_LEFT
	Input.parse_input_event(event)
	await process_frame
	check(preview.selected_id == "employee", "arrow key selects previous listed card")
	preview.show_card("unknown")
	check(preview.selected_id == "employee", "unknown card cannot break the viewer")
	for id in preview.ids:
		preview.show_card(str(id))
		check(preview.card.uses_continuous_animation(), "%s uses a configured continuous motion" % id)
		var loaded: bool = await wait_frames(preview.card)
		check(loaded, "%s is ready without loading discrete animation frames" % id)
		if not loaded: continue
		var master: Texture2D = preview.card._icon.texture
		var middle: int = floori(float(preview.card.illustration_sample_count()) / 2.0)
		preview.seek_frame(middle)
		check(preview.card._hover_frame == middle, "%s timeline seeks a time sample" % id)
		check(preview._large.texture == master and preview.card._icon.texture == master, "%s normal and large images retain exactly one master" % id)
		check_shader_sync(preview, "%s seek" % id)
		preview.step_frame(1)
		check(preview.card._hover_frame == middle + 1, "%s advances one sample" % id)
		check(preview.card._icon.texture == master, "%s does not replace its master between samples" % id)
		check(preview.card._hover_frames.is_empty(), "%s never requests old GPT-pose sequences" % id)
	for entry: Dictionary in preview.spec.states:
		preview._buttons[str(entry.id)].pressed.emit()
		check(preview.selected_entry_id == str(entry.id) and preview.card.type == str(entry.card), "state navigation selects the requested real personnel card")
		check(preview.card.record.activity == "striking" and preview.card._strike_participant, "state preview enters the real strike activity")
		check(preview.card.illustration_profile() == "striking/" + str(entry.card), "state preview selects the production dance profile")
		check(await wait_frames(preview.card), "state illustration is ready")
		preview._seek_time(0.231)
		check_shader_sync(preview, "strike state " + str(entry.card))
		check(preview._large.material.get_meta("work_motion_kind") == preview.card.illustration_profile(), "large strike image uses the activity profile rather than the ordinary portrait")
		var card_pose: Transform3D = preview.card._visual.transform
		preview.step_frame(1)
		check(preview.card._visual.transform == card_pose, "state stepping leaves the original card frame fixed")
		preview.show_original(true)
		check(is_zero_approx(preview.card.illustration_time()), "state original comparison retains zero-time source")
		preview.show_original(false)
		check(preview.card.illustration_time() > 0.2 and preview.card._strike_participant, "state comparison restores the dance without falling back to idle")
	preview.show_card("employee")
	preview._seek_time(0.123456)
	check(absf(preview.card.illustration_time() - 0.123456) < 0.000001, "arbitrary seek keeps sub-sample precision")
	preview.show_original(true)
	check(is_zero_approx(preview.card.illustration_time()), "original comparison stops at the neutral master")
	preview.show_original(false)
	check(absf(preview.card.illustration_time() - 0.123456) < 0.000001, "leaving original comparison restores exact continuous time")
	check_shader_sync(preview, "precise restore")
	preview.set_paused(false)
	var substep_before: float = preview.card.illustration_time()
	preview.card._process(1.0 / 240.0)
	preview._sync_view()
	check(preview.card.illustration_time() > substep_before and preview.card.illustration_time() < substep_before + 1.0 / 60.0, "continuous motion advances at sub-sample deltas")
	check_shader_sync(preview, "sub-sample playback")
	preview.set_paused(true)
	preview.card._icon.modulate = Color(0.7, 0.8, 0.9, 0.4)
	preview._sync_view()
	check(preview._large.material.get_shader_parameter("motion_tint") == preview.card._icon.modulate, "large preview preserves production dimming and transparency")
	preview.card._icon.modulate = Color.WHITE
	preview._sync_view()
	check(preview._frame_status.text.contains("采样") and preview._frame_status.text.contains("渲染"), "UI distinguishes time sampling from measured rendering rate")
	var scenarios: Array = preview.entries.filter(func(entry): return str(entry.mode) == "scenario")
	check(FileAccess.file_exists(preview.SETTINGS) and not scenarios.is_empty(), "the standalone viewer includes its scenario catalog")
	var catalog: Dictionary = UIConfig.read_json(preview.SETTINGS, true)["scenarios"]
	check(scenarios.size() == catalog.scenarios.size() and preview.entries.size() == preview.ids.size() + preview.spec.states.size() + catalog.scenarios.size(), "all catalog scenes are listed alongside every base card and character state")
	if not scenarios.is_empty():
		await _check_scenario_controls(preview, scenarios)
		preview.show_card("employee")
		await wait_frames(preview.card)
	root.size = Vector2i(int(preview.spec.window.minimum_size[0]), int(preview.spec.window.minimum_size[1]))
	await process_frame
	await process_frame
	check(preview._large.get_global_rect().end.x <= root.size.x, "art viewport stays within minimum window width")
	check(preview._timeline.get_global_rect().end.y <= root.size.y, "timeline stays within minimum window height")
	check(viewer._hover_speed_slider.get_global_rect().end.x <= root.size.x, "speed controls stay within minimum window width")
	if not scenarios.is_empty():
		preview.show_entry(str(scenarios[-1].id))
		await process_frame
		await process_frame
		check(preview._scenario_panel.get_global_rect().end.x <= root.size.x and preview._scenario_panel.get_global_rect().end.y <= root.size.y, "wide scenario stage stays within the minimum window")
		check(preview._scenario_viewport.size == Vector2i(preview.spec.layout.scenario_viewport_size[0], preview.spec.layout.scenario_viewport_size[1]) and preview._scenario_viewport.size_2d_override == Vector2i.ZERO, "resizing the viewer preserves shared camera, effect and HUD pixel coordinates")
		check(preview._timeline.get_global_rect().end.y <= root.size.y and viewer._hover_speed_slider.get_global_rect().end.x <= root.size.x, "scenario playback controls remain usable at minimum size")
		var scenario_capture := OS.get_environment("WORK_PREVIEW_TEST_SCENARIO_SHOT")
		if not scenario_capture.is_empty():
			var started := Time.get_ticks_msec()
			while not preview.scenario.is_ready() and Time.get_ticks_msec() - started < 15000: await process_frame
			preview._seek_time(0.5)
			await process_frame
			await process_frame
			RenderingServer.force_draw(false)
			check(root.get_texture().get_image().save_png(scenario_capture) == OK, "minimum-window scenario screenshot is saved")
		preview.show_card("employee")
		await wait_frames(preview.card)
		await process_frame
		await process_frame
	var capture := OS.get_environment("WORK_PREVIEW_TEST_SHOT")
	if not capture.is_empty():
		RenderingServer.force_draw(false)
		check(root.get_texture().get_image().save_png(capture) == OK, "minimum-window screenshot is saved")
	var data_dir := OS.get_environment("WORK_DATA_DIR")
	if not data_dir.is_empty():
		check(not DirAccess.dir_exists_absolute(data_dir), "standalone preview does not create settings or player-data files")
	viewer.queue_free()
	await process_frame
	if failures.is_empty():
		print("WORK_ANIMATION_PREVIEW PASS (", checks, " checks)")
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _check_scenario_controls(preview: Control, scenarios: Array) -> void:
	var selected: Dictionary = scenarios[0]
	preview._buttons[str(selected.id)].pressed.emit()
	check(preview.is_scenario_mode() and preview.selected_entry_id == str(selected.id), "scenario navigation selects a complete production scene")
	check(not is_instance_valid(preview.card) and preview._scenario_panel.visible, "scenario mode replaces both single-card panels with one wide stage")
	check(preview._original.disabled, "still-master comparison is unavailable for complete scenarios")
	check(is_instance_valid(preview.scenario), "scenario navigation constructs a real runner")
	if not is_instance_valid(preview.scenario): return
	var started := Time.get_ticks_msec()
	while not preview.scenario.is_ready() and Time.get_ticks_msec() - started < 15000: await process_frame
	check(preview.scenario.is_ready(), "the scenario and its real card art become ready")
	preview.set_process(false)
	preview._seek_time(0.3)
	check(preview.paused and absf(float(preview.scenario.time()) - 0.3) < 0.000001, "scenario timeline seeks its exact time and pauses")
	check(preview._measured_render_fps == 0 and preview._render_rate_text() == "测量中", "seeking resets render-rate measurement so rebuilding is excluded")
	var frozen: Dictionary = preview.scenario.snapshot().duplicate(true)
	await create_timer(0.05).timeout
	check(preview.scenario.snapshot() == frozen, "scenario paused state remains unchanged across real frames")
	preview.step_frame(1)
	check(absf(float(preview.scenario.time()) - (0.3 + 1.0 / 60.0)) < 0.000001, "scenario next-step advances one configured sample")
	preview.step_frame(-1)
	check(absf(float(preview.scenario.time()) - 0.3) < 0.000001, "scenario previous-step rebuilds the earlier moment")
	preview.set_speed(0.5)
	preview.set_paused(false)
	preview._process(0.2)
	check(absf(float(preview.scenario.time()) - 0.4) < 0.000001, "scenario playback uses the shared speed setting")
	preview.set_paused(true)
	preview._timeline.drag_started.emit()
	preview._timeline.value = 2.0
	preview._timeline.value = 3.0
	preview._process(0.1)
	check(absf(float(preview.scenario.time()) - 0.4) < 0.000001, "dragging a scenario timeline does not repeatedly rebuild the scene")
	check(is_equal_approx(preview._timeline.value, 3.0) and preview._frame_status.text.begins_with("3.00"), "scenario scrubbing shows the latest requested time immediately")
	preview._timeline.drag_ended.emit(true)
	check(absf(float(preview.scenario.time()) - 3.0) < 0.000001, "releasing the timeline performs one seek to the selected time")
	preview.replay()
	check(not preview.paused and is_zero_approx(float(preview.scenario.time())), "scenario replay restarts the actual event sequence")
	preview.set_paused(true)
	preview.show_original(true)
	check(not preview._original.button_pressed and preview.is_scenario_mode(), "programmatic original comparison cannot replace a scenario")
	var old: Node3D = preview.scenario
	preview.show_entry(str(scenarios[-1].id))
	check(not is_instance_valid(old), "selecting another scenario frees its predecessor")
	check(preview.paused and preview._scenario_panel.visible, "scenario switching preserves pause state and wide stage")
	preview.show_card("employee")
	check(not is_instance_valid(preview.scenario) and not preview.is_scenario_mode(), "returning to a card releases the entire scenario")
	check(not preview._original.disabled and not preview._scenario_panel.visible, "returning to a card restores its original comparison and two views")
	preview.set_process(true)
