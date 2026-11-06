# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Control
## 正式卡面、角色状态及独立演出共用的动画查看器，不创建BOT或玩家存档。
const SETTINGS := "res://data/animation_preview.json"
const SCENARIO_SCRIPT := "res://scenes/work_animation_scenario.gd"
const PreviewCard = preload("res://scenes/work_animation_preview_card.gd")
const ButtonTheme = preload("res://scenes/ui_button_theme.gd")

var spec: Dictionary
var card: WorkCard
var selected_id := ""
var ids: Array = []
var entries: Array = []
var selected_entry_id := ""
var scenario: Node3D
var paused := false
var speed := 1.0
var _scene: Node3D
var viewer: Node
var _catalog: VBoxContainer
var _large: TextureRect
var _heading: Label
var _description: Label
var _frame_status: Label
var _play: Button
var _timeline: HSlider
var _speed_label: Label
var _original: CheckButton
var _buttons: Dictionary = {}
var _navigation_scroll: ScrollContainer
var _scenario_panel: TextureRect
var _scenario_viewport: SubViewport
var _entry_by_id: Dictionary = {}
var _pending_frame := -1
var _restore_time := 0.0
var _pending_time := -1.0
var _restore_paused := false
var _loading_elapsed := 0.0
var _timeline_dragging := false
var _scrub_frame := -1
var _render_window_started_usec := 0
var _render_window_started_frame := 0
var _measured_render_fps := 0

func bind(host: Node) -> void:
	viewer = host
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	spec = UIConfig.read_json(SETTINGS, true)["preview"]
	WorkCardDB.configure(WorkConfig.new())
	ids = spec.cards.duplicate()
	_load_entries()
	process_priority = 10
	_navigation_scroll = host._list
	_catalog = VBoxContainer.new()
	_catalog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_navigation_scroll.add_child(_catalog)
	_build_catalog()
	_heading = host._heading
	_description = host._hint
	_frame_status = host._status
	_speed_label = host._hover_speed_value
	_play = host._hover_pause
	_original = host._hover_original
	_timeline = host._hover_seek
	_large = host._large
	_scene = Node3D.new()
	host.add_child(_scene)
	_build_scenario_view()
	var requested := OS.get_environment("WORK_PREVIEW_ANIMATION")
	if requested.is_empty(): requested = OS.get_environment("WORK_PREVIEW_CARD")
	selected_entry_id = requested if _entry_by_id.has(requested) else str(spec.default_card)
	if not OS.get_environment("WORK_PREVIEW_SHOT").is_empty():
		_capture.call_deferred()

func activate() -> void:
	show()
	_catalog.show()
	set_process(true)
	set_process_input(true)
	apply_speed(viewer._hover_speed * (0.25 if viewer._hover_slow.button_pressed else 1.0))
	show_entry(selected_entry_id)

func deactivate() -> void:
	hide()
	_catalog.hide()
	set_process(false)
	set_process_input(false)
	_scenario_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_clear_scenario()
	_clear_card()

func _v2i(value: Array) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1]))

func _load_entries() -> void:
	for id in ids:
		entries.append({"id": str(id), "card": str(id), "name": WorkCardDB.card_name(str(id)),
			"description": str(WorkCardDB.get_def(str(id)).description), "category": "卡牌动作", "mode": "card"})
	for state: Dictionary in spec.get("states", []):
		var entry := state.duplicate(true)
		entry.mode = "card"
		entries.append(entry)
	var catalog: Dictionary = UIConfig.read_json(SETTINGS, true)["scenarios"]
	for item: Dictionary in catalog.scenarios:
		var entry := item.duplicate(true)
		entry.mode = "scenario"
		entries.append(entry)
	for entry: Dictionary in entries:
		assert(not _entry_by_id.has(str(entry.id)), "重复动画入口：" + str(entry.id))
		_entry_by_id[str(entry.id)] = entry

func _build_catalog() -> void:
	var categories: Array = spec.categories.duplicate()
	for entry: Dictionary in entries:
		if not categories.has(str(entry.category)): categories.append(str(entry.category))
	for category in categories:
		var members: Array = entries.filter(func(entry): return str(entry.category) == str(category))
		if members.is_empty(): continue
		_catalog.add_child(viewer._label(str(category), 15))
		for entry: Dictionary in members:
			var button: Button = viewer._button(str(entry.name), show_entry.bind(str(entry.id)))
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.clip_text = true
			button.tooltip_text = str(entry.name) + "\n" + str(entry.description)
			button.custom_minimum_size.y = float(spec.layout.sidebar_button_height)
			_catalog.add_child(button)
			_buttons[str(entry.id)] = button

func _build_scenario_view() -> void:
	_scenario_panel = TextureRect.new()
	_scenario_panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scenario_panel.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_scenario_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scenario_panel)
	_scenario_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scenario_viewport = SubViewport.new()
	_scenario_viewport.size = _v2i(spec.layout.scenario_viewport_size)
	_scenario_viewport.own_world_3d = true
	_scenario_viewport.transparent_bg = true
	_scenario_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_scenario_panel.add_child(_scenario_viewport)
	_scenario_panel.texture = _scenario_viewport.get_texture()
	_scenario_panel.hide()

func show_card(id: String) -> void:
	if ids.has(id): show_entry(id)

func show_animation(id: String) -> void:
	show_entry(id)

func show_entry(id: String) -> void:
	if not _entry_by_id.has(id): return
	_clear_card()
	_clear_scenario()
	selected_id = id
	selected_entry_id = id
	_pending_frame = -1
	_pending_time = -1.0
	_timeline_dragging = false
	_scrub_frame = -1
	_loading_elapsed = 0.0
	_original.set_pressed_no_signal(false)
	var entry: Dictionary = _entry_by_id[id]
	var scenario_mode: bool = str(entry.mode) == "scenario"
	_scenario_panel.visible = scenario_mode
	_scenario_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if scenario_mode else SubViewport.UPDATE_DISABLED
	_original.disabled = scenario_mode
	viewer._magnify.disabled = scenario_mode
	_heading.text = str(entry.name)
	_description.text = str(entry.description)
	if scenario_mode:
		var script = load(SCENARIO_SCRIPT)
		if script != null:
			scenario = script.new()
			_scenario_viewport.add_child(scenario)
			scenario.load_scenario(id)
			_timeline.step = 1.0 / float(spec.playback.scenario_sample_fps)
			_timeline.max_value = scenario.duration()
		else:
			_frame_status.text = "演出载入失败，请检查场景登记"
	else:
		var kind := str(entry.card)
		var activity := str(entry.get("activity", "idle"))
		card = PreviewCard.new()
		_scene.add_child(card)
		card.configure({"id": entries.find(entry), "type": kind, "owner": 0, "group": -1,
			"status": "striking" if activity == "striking" else "ready", "activity": activity,
			"paused": activity == "striking", "progress": 0.0}, WorkCardDB.get_def(kind))
		card.freeze = true
		card.draggable = false
		card.position.y = float(spec.layout.card_height)
		card.hover_animation_speed = speed
		card.set_hover_visual(true, false)
		_large.material = card.make_illustration_preview_material()
		_timeline.step = 1.0 / card.illustration_sample_fps()
		_timeline.max_value = card.illustration_duration()
	_timeline.set_value_no_signal(0)
	set_paused(paused)
	viewer._position_cards()
	viewer._sync_magnifier()
	for key in _buttons:
		_buttons[key].set_meta("ui_role", "primary" if key == id else "tool")
		ButtonTheme.apply(_buttons[key], viewer._scale_factor, 8, 8)
	_scroll_to_selection.call_deferred(id)
	_reset_render_measurement()
	_sync_view()

func _scroll_to_selection(id: String) -> void:
	# Initial programmatic selections can precede the ScrollContainer's first
	# layout pass; wait for its content height before revealing a state/event.
	for frame in 2:
		if not is_inside_tree(): return
		await get_tree().process_frame
	if is_inside_tree() and selected_entry_id == id and _buttons.has(id):
		_navigation_scroll.ensure_control_visible(_buttons[id])

func _clear_card() -> void:
	if is_instance_valid(card):
		_scene.remove_child(card)
		card.free()
	card = null
	if is_instance_valid(_large):
		_large.texture = null
		_large.material = null

func _clear_scenario() -> void:
	if is_instance_valid(scenario):
		_scenario_viewport.remove_child(scenario)
		scenario.free()
	scenario = null

func is_scenario_mode() -> bool:
	return str(_entry_by_id.get(selected_entry_id, {}).get("mode", "card")) == "scenario"

func set_speed(value: float) -> void:
	viewer.set_hover_animation_speed(value)

func apply_speed(value: float) -> void:
	speed = value
	if is_instance_valid(card): card.hover_animation_speed = speed
	_speed_label.text = UIConfig.hover_speed_text(speed)

func set_paused(value: bool) -> void:
	paused = value
	if is_instance_valid(card): card.hover_animation_paused = paused
	_play.set_pressed_no_signal(paused)

func toggle_play() -> void:
	if _original.button_pressed and not is_scenario_mode():
		_original.set_pressed_no_signal(false)
		_seek_time(_restore_time)
	set_paused(not paused)

func _timeline_changed(value: float) -> void:
	# A long scene is rebuilt once on release. Replaying it for every mouse
	# movement would stall the controls; the requested time still updates live.
	if is_scenario_mode() and _timeline_dragging:
		_scrub_frame = roundi(value * float(spec.playback.scenario_sample_fps))
		set_paused(true)
		_sync_view()
	else:
		_seek_time(value)

func _finish_timeline_drag(_value_changed: bool) -> void:
	_timeline_dragging = false
	if _scrub_frame < 0: return
	var frame := _scrub_frame
	_scrub_frame = -1
	seek_frame(frame)

func seek_frame(index: int) -> void:
	if is_scenario_mode():
		if not is_instance_valid(scenario): return
		_pending_frame = clampi(index, 0, roundi(_timeline.max_value * float(spec.playback.scenario_sample_fps)))
		_seek_time(float(_pending_frame) / float(spec.playback.scenario_sample_fps))
		return
	if not is_instance_valid(card): return
	_pending_frame = clampi(index, 0, card.illustration_sample_count() - 1)
	_seek_time(float(_pending_frame) / card.illustration_sample_fps())

func _seek_time(seconds: float) -> void:
	_original.set_pressed_no_signal(false)
	set_paused(true)
	if is_scenario_mode():
		if is_instance_valid(scenario): scenario.seek(clampf(seconds, 0.0, float(scenario.duration())))
		_reset_render_measurement()
		_pending_frame = -1
		_pending_time = -1.0
		_sync_view()
		return
	if not is_instance_valid(card): return
	_pending_time = clampf(seconds, 0.0, card.illustration_duration())
	_apply_pending_frame()
	_reset_render_measurement()
	_sync_view()

func _apply_pending_frame() -> void:
	if not is_instance_valid(card) or _pending_time < 0.0 or not card.illustration_ready(): return
	if not card.uses_continuous_animation():
		card._hover_elapsed = _pending_time + float(spec.playback.hover_lead_in_seconds)
	card.seek_hover_animation(_pending_time)
	_pending_frame = -1
	_pending_time = -1.0

func step_frame(direction: int) -> void:
	var index := 0
	if is_scenario_mode():
		if not is_instance_valid(scenario): return
		index = roundi(float(scenario.time()) * float(spec.playback.scenario_sample_fps))
	else:
		if not is_instance_valid(card): return
		index = _pending_frame if _pending_frame >= 0 else card._hover_frame
	seek_frame(index + direction)

func replay() -> void:
	seek_frame(0)
	if is_instance_valid(card) and not card.uses_continuous_animation(): card._hover_elapsed = 0.0
	set_paused(false)

func show_original(on: bool) -> void:
	if is_scenario_mode() or not is_instance_valid(card):
		_original.set_pressed_no_signal(false)
		return
	if on:
		_restore_time = card.illustration_time()
		_restore_paused = paused
		_seek_time(0.0)
		_original.set_pressed_no_signal(true)
	else:
		_seek_time(_restore_time)
		set_paused(_restore_paused)

func _process(delta: float) -> void:
	_loading_elapsed += delta
	if is_scenario_mode():
		if is_instance_valid(scenario) and scenario.is_ready() and not paused:
			if float(scenario.time()) >= float(scenario.duration()):
				if bool(_entry_by_id[selected_entry_id].get("loop", false)): scenario.seek(0.0)
				else: set_paused(true)
			if not paused: scenario.advance(delta * speed)
		_sync_view()
		return
	if not is_instance_valid(card): return
	_apply_pending_frame()
	_sync_view()

func _render_rate_text() -> String:
	# Count completed render frames after the most recent seek, so a long
	# deterministic rebuild never contaminates the displayed playback rate.
	if not _selected_ready():
		_reset_render_measurement()
		return "测量中"
	var elapsed := float(Time.get_ticks_usec() - _render_window_started_usec) / 1000000.0
	if elapsed >= float(spec.playback.render_measurement_warmup_seconds):
		_measured_render_fps = roundi(float(Engine.get_frames_drawn() - _render_window_started_frame) / elapsed)
		_render_window_started_usec = Time.get_ticks_usec()
		_render_window_started_frame = Engine.get_frames_drawn()
	return "%d fps" % _measured_render_fps if _measured_render_fps > 0 else "测量中"

func _reset_render_measurement() -> void:
	_render_window_started_usec = Time.get_ticks_usec()
	_render_window_started_frame = Engine.get_frames_drawn()
	_measured_render_fps = 0

func _sync_view() -> void:
	if is_scenario_mode():
		if not is_instance_valid(scenario): return
		var shown_time := float(scenario.time())
		if _timeline_dragging and _scrub_frame >= 0:
			shown_time = float(_scrub_frame) / float(spec.playback.scenario_sample_fps)
		_timeline.set_value_no_signal(shown_time)
		if not scenario.is_ready():
			_frame_status.text = "正在载入演出…" if _loading_elapsed < float(spec.playback.load_timeout_seconds) else "演出载入失败，请检查素材登记"
			return
		_frame_status.text = "%.2f / %.2f 秒\n采样 %d Hz · 渲染 %s" % [
			shown_time, float(scenario.duration()), float(spec.playback.scenario_sample_fps), _render_rate_text()]
		return
	if not is_instance_valid(card) or card._icon == null: return
	_large.texture = card._icon.texture
	if _large.material is ShaderMaterial:
		card.sync_illustration_preview_material(_large.material)
	_timeline.set_value_no_signal(card.illustration_time())
	var count := card.illustration_sample_count()
	if count <= 0:
		_frame_status.text = "静止原图"
	elif not card.illustration_ready():
		_frame_status.text = "等待动作"
	else:
		_frame_status.text = "%.2f / %.2f 秒\n采样 %d Hz · 渲染 %s" % [
			card.illustration_time(), card.illustration_duration(), card.illustration_sample_fps(), _render_rate_text()]

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	var entry_ids: Array = entries.map(func(entry): return str(entry.id))
	match event.keycode:
		KEY_LEFT: show_entry(str(entry_ids[posmod(entry_ids.find(selected_entry_id) - 1, entry_ids.size())]))
		KEY_RIGHT: show_entry(str(entry_ids[posmod(entry_ids.find(selected_entry_id) + 1, entry_ids.size())]))
		KEY_SPACE: toggle_play()
		KEY_A: step_frame(-1)
		KEY_D: step_frame(1)
		KEY_HOME: seek_frame(0)
		_: return
	get_viewport().set_input_as_handled()

func _capture() -> void:
	while not _selected_ready() and _loading_elapsed < float(spec.playback.load_timeout_seconds):
		await get_tree().process_frame
	var frame := OS.get_environment("WORK_PREVIEW_FRAME")
	if not frame.is_empty(): seek_frame(int(frame))
	# A seek can block for many simulated steps. Its old process delta must not
	# consume the screenshot delay before the new viewport has rendered.
	await get_tree().process_frame
	await get_tree().process_frame
	_reset_render_measurement()
	var until_usec := Time.get_ticks_usec() + int(float(spec.playback.capture_delay_seconds) * 1000000.0)
	while Time.get_ticks_usec() < until_usec: await get_tree().process_frame
	RenderingServer.force_draw(false)
	var error := get_viewport().get_texture().get_image().save_png(OS.get_environment("WORK_PREVIEW_SHOT"))
	var verified := error == OK and _selected_ready()
	print("WORK_ANIMATION_PREVIEW_CAPTURE ", verified, " animation=", selected_entry_id, " sample=", roundi(_timeline.value / _timeline.step))
	get_tree().quit(0 if verified else 1)

func _selected_ready() -> bool:
	return bool(scenario.is_ready()) if is_instance_valid(scenario) else (is_instance_valid(card) and card.illustration_ready())
