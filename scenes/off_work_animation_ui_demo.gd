# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node
## Isolated adapters for the actual drawer geometry, mascot and result builder.
## Never bind a live HUD or resize the operating-system window.
const SPEC_PATH := "res://data/animation_preview.json"
const OffWorkRaceBar = preload("res://scenes/off_work_race_bar.gd")

class PreviewResultHUD extends "res://scenes/off_work_hud.gd":
	func _init() -> void:
		super("res://data/ui.json")
		hud_config = UIConfig.read_section("hud")
		_main = self
	func close_panels() -> void:
		pass
	## 放映室没有绑定牌局，失败结算的那束光落在画面下方正中，和正式牌桌没有待办堆时一样。
	func _off_work_result_focus() -> Vector2:
		return Vector2(_last_size) * Vector2(0.5, 0.72)
	func register_result_panel(panel: CanvasLayer) -> void:
		for child in panel.get_children():
			if child is Control: _apply_tree_theme(child)

## 竞速条演示用的假牌局：只提供竞速条要读的三样东西（时间、开局张数、双方剩余工作）。
class RaceState extends RefCounted:
	class Rules extends RefCounted:
		var rules := {"initial": {"groups": [{"work": 800}]}}
	var time := 0.0
	var config := Rules.new()
	var counts := [800, 800]
	func work_count(owner: int) -> int:
		return int(counts[owner])

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
var race_bar: Control
var race_state: RaceState
var _race_header: PanelContainer
## 正式 HUD 的结算面板把这个节点当牌局宿主用，会问它两件事：
## 牌桌是不是被换班藏起来了（放映室里永远没有），以及让它播结算的章声。
## 放映室的声音由预览自己的播放控制管，这里给一个不出声的替身。
var _shift_hidden := false
var audio := SilentAudio.new()

class SilentAudio extends RefCounted:
	func play(_action: String) -> void:
		pass
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
	elif id == "race_bar": _build_race()
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

## 竞速条：一条假顶栏下面挂着正式的竞速条，双方的剩余工作按排期变化
## （稳步清理、对手加速、被甩锅倒退、冲刺到下班）。
func _build_race() -> void:
	_background()
	var styles := PreviewResultHUD.new()
	add_child(styles)
	_race_header = PanelContainer.new()
	_race_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_race_header.add_theme_stylebox_override("panel", styles._style(Palette.get_color("world", "table_frame"), 10))
	var title: Label = styles._label(str(spec.race.title), int(spec.race.title_font))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_header.add_child(title)
	_layer.add_child(_race_header)
	var width := float(_viewport.size.x) * float(spec.race.width_fraction)
	_race_header.size = Vector2(width, float(spec.race.header_height))
	_race_header.position = Vector2((float(_viewport.size.x) - width) * 0.5, float(_viewport.size.y) * float(spec.race.top_fraction))
	race_state = RaceState.new()
	race_state.config.rules.initial.groups = [{"work": int(spec.race.total)}]
	race_bar = OffWorkRaceBar.new()
	_layer.add_child(race_bar)
	_sync_race()

func _sync_race() -> void:
	var keys: Array = spec.race.keys
	var previous: Dictionary = keys[0]
	var next: Dictionary = keys[keys.size() - 1]
	for index in keys.size():
		if float(keys[index].at) <= elapsed: previous = keys[index]
		if float(keys[index].at) >= elapsed:
			next = keys[index]
			break
	var span := float(next.at) - float(previous.at)
	var weight := clampf((elapsed - float(previous.at)) / span, 0.0, 1.0) if span > 0.0 else 1.0
	race_state.counts = [roundi(lerpf(float(previous.mine), float(next.mine), weight)),
		roundi(lerpf(float(previous.foe), float(next.foe), weight))]
	race_state.time = elapsed
	race_bar.sync(race_state, _race_header, float(spec.race.scale))

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
	elif race_bar != null:
		_sync_race()

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
		"race_remaining": race_state.counts.duplicate() if race_state != null else [],
		"race_cleared": [race_bar.cleared_fraction(0), race_bar.cleared_fraction(1)] if race_bar != null else [],
		"result_visible": result_hud != null and is_instance_valid(result_hud.result_layer)}
