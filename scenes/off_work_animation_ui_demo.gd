# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node
## Isolated adapters for the actual drawer geometry, mascot and result builder.
## Never bind a live HUD or resize the operating-system window.
const SPEC_PATH := "res://data/animation_preview.json"

class PreviewResultHUD extends "res://scenes/off_work_hud.gd":
	func _init() -> void:
		super("res://data/ui.json")
		hud_config = UIConfig.read_section("hud")
		_main = self
	func close_panels() -> void:
		pass
	func register_result_panel(panel: CanvasLayer) -> void:
		for child in panel.get_children():
			if child is Control: _apply_tree_theme(child)

class PreviewDrawer extends DrawerWindow:
	var elapsed := 0.0
	var from_extent := 0.0
	var to_extent := 0.0
	var span := 0.0
	func _init() -> void:
		super("res://data/ui.json")
	func _announce_handle() -> void:
		pass
	func _start_transition(expanded: bool) -> void:
		_transition_target = expanded
		_transitioning = true
		if expanded: _expanded = true
		from_extent = float(_geometry.size[_transition_axis()])
		to_extent = float(_rect_for(expanded).size[_transition_axis()])
		span = EXPAND_DURATION if expanded else COLLAPSE_DURATION
		elapsed = 0.0
		_animate_extent(from_extent)
	func advance(delta: float) -> void:
		if not _transitioning: return
		elapsed = minf(span, elapsed + delta)
		# Identical curve and geometry function to DrawerWindow's native tween.
		_animate_extent(float(Tween.interpolate_value(from_extent, to_extent - from_extent,
			elapsed, span, Tween.TRANS_CUBIC, Tween.EASE_OUT)))
		if elapsed >= span: _finish_transition(_transition_target)

var spec: Dictionary = UIConfig.read_json(SPEC_PATH, true)["ui_demo"]
var scenario_id := ""
var elapsed := 0.0
var drawer: PreviewDrawer
var mascot: DrawerMascot
var result_hud: PreviewResultHUD
var clip: Control
var content: PanelContainer
var _layer: CanvasLayer
var _events_seen: Dictionary = {}
var _viewport: SubViewport

func configure(id: String, viewport: SubViewport) -> void:
	scenario_id = id
	_viewport = viewport
	set_process(false)
	_layer = CanvasLayer.new()
	_layer.layer = 8
	add_child(_layer)
	if id == "drawer": _build_drawer()
	elif id == "drawer_mascot": _build_mascot()
	else:
		result_hud = PreviewResultHUD.new()
		add_child(result_hud)
		result_hud.host = self
		result_hud._last_size = Vector2(viewport.size)

func reveal_result(winner: int, work_left: int = 0) -> void:
	if result_hud == null or is_instance_valid(result_hud.result_layer): return
	result_hud.show_result(winner, work_left, func(): pass)
	# The preview transport owns replay. The original result button is visual here.
	for button in result_hud.result_layer.find_children("*", "Button", true, false):
		button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.focus_mode = Control.FOCUS_NONE

func _background() -> void:
	var background := ColorRect.new()
	background.color = Palette.get_color("world", "background").darkened(0.13)
	background.size = Vector2(_viewport.size)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(background)

func _new_mascot(scale_value: float) -> DrawerMascot:
	var node := DrawerMascot.new()
	_layer.add_child(node)
	node.setup(load("res://assets/art/app_icon.png"))
	node.set_render_scale(scale_value)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.focus_mode = Control.FOCUS_NONE
	node.set_process(false)
	return node

func _build_mascot() -> void:
	_background()
	mascot = _new_mascot(float(spec.mascot.render_scale))
	mascot.position = (Vector2(_viewport.size) - mascot.size) * 0.5
	advance(0.0)

func _build_drawer() -> void:
	_background()
	drawer = PreviewDrawer.new()
	add_child(drawer)
	var margin := int(spec.drawer.screen_margin)
	drawer.setup(false, Rect2i(Vector2i(margin, margin), _viewport.size - Vector2i.ONE * margin * 2))
	drawer._size_fraction = float(spec.drawer.size_fraction)
	drawer.set_process(false)
	drawer.set_process_input(false)
	drawer.set_process_unhandled_input(false)
	drawer._finish_transition(bool(spec.drawer.start_expanded))
	clip = Control.new()
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(clip)
	content = PanelContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(content)
	# Use the same styles and labels without constructing or saving a live HUD.
	var styles := PreviewResultHUD.new()
	add_child(styles)
	content.add_theme_stylebox_override("panel", styles._style(Palette.get_color("world", "table_frame"), int(spec.drawer.content_margin)))
	var column := VBoxContainer.new()
	content.add_child(column)
	column.add_child(styles._label(str(spec.drawer.title), int(spec.drawer.title_font)))
	var body: Label = styles._label(str(spec.drawer.body), int(spec.drawer.body_font))
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(body)
	mascot = _new_mascot(float(spec.drawer.icon_scale))
	mascot.set_state(DrawerMascot.STATE_OPENING)
	mascot.greet()
	_sync_drawer()

func advance(delta: float) -> void:
	elapsed += delta
	if drawer != null:
		for event in [["open_at", true], ["close_at", false], ["reopen_at", true]]:
			if elapsed >= float(spec.drawer[event[0]]) and not _events_seen.has(event[0]):
				_events_seen[event[0]] = true
				drawer._start_transition(event[1])
		drawer.advance(delta)
		_sync_drawer()
	elif mascot != null:
		for index in spec.mascot.events.size():
			var event: Dictionary = spec.mascot.events[index]
			if elapsed >= float(event.at) and not _events_seen.has(index):
				_events_seen[index] = true
				mascot.set_first_run_hint(bool(event.get("first_hint", false)))
				mascot.set_state(str(event.state))
				mascot.set_hovered(str(event.state) == "hover")
				if str(event.state) == "opening": mascot.greet()
				mascot.set_process(false)
		mascot._process(delta)

func _sync_drawer() -> void:
	clip.position = Vector2(drawer._geometry.position)
	clip.size = Vector2(drawer._geometry.size)
	content.size = Vector2(drawer._rect_for(true).size)
	clip.visible = drawer._expanded or drawer._transitioning
	mascot.visible = not clip.visible
	mascot.position = Vector2(drawer._rect_for(false).position)

func snapshot() -> Dictionary:
	return {"elapsed": elapsed, "id": scenario_id,
		"drawer_geometry": drawer._geometry if drawer != null else Rect2i(),
		"drawer_transitioning": drawer._transitioning if drawer != null else false,
		"mascot_state": mascot.state() if mascot != null else "",
		"mascot_tilt": mascot._face_tilt if mascot != null else 0.0,
		"result_visible": result_hud != null and is_instance_valid(result_hud.result_layer)}
