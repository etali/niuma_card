# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node3D
## 独立视觉验收场景：只创建正式卡面与运动，不启动牌局或写入玩家设置。
const Motion = preload("res://scenes/card_motion.gd")
const Hands = preload("res://scenes/table_hands.gd")
const ModeSwitch = preload("res://scenes/preview_mode_switch.gd")
const ButtonTheme = preload("res://scenes/ui_button_theme.gd")
const ArtResolution = preload("res://scenes/preview_art_resolution.gd")
const OnWorkPreviewCard = preload("res://scenes/on_work_preview_card.gd")
const ComicFx = preload("res://scenes/comic_fx.gd")
const UIMotion = preload("res://scenes/ui_motion.gd")
const ResultPresentation = preload("res://scenes/result_presentation.gd")
const FX_PAGE := 2
## 特效页的按钮：调用与正式牌桌相同的组合演出，只是位置取预览台中央。
const FX_DEMOS := [
	["hit", "撕掉用户"], ["coins", "撕掉现金"], ["final", "终结一击"], ["void", "组合作废"],
	["cash", "产出资金"], ["user", "产出用户"], ["upgrade", "升级"], ["legend", "传说登场"],
	["listing", "胜利 · 上市"], ["bankrupt", "胜利 · 对手破产"], ["exodus", "胜利 · 对手跑光"], ["defeat", "失败"],
]
## 特效页台面：左边一张生产牌（产出、升级、作废都盖在它身上），右边一叠被攻击的资源牌。
const FX_CORE := Vector3(-1.9, 0.05, 0.0)
const FX_TARGET := Vector3(1.9, 0.05, 0.0)
@export var start_off_work := false
var off_work_active := false
var off_work_preview: Control
var _modes: HBoxContainer
var _layer: CanvasLayer
var _resolution_caption: Label
var _large: TextureRect
var _magnify: CheckButton
var board: Board
var drawer_presentation: Node
var table_hands: Node
var mobile_mode := false
var _attack_hl: Array = []
var _player_attack_busy := 0
var _motion: Node
var _camera: Camera3D
var _stage: Node3D
var _ids: Array = []
var _selection := 0
var _page := 0
var _cards: Array[CardEntity] = []
var _hover: CardEntity
var _generation := 0
var _uid := 990000
var _surface := Rect2()
var _sidebar: PanelContainer
var _heading: Label
var _hint: Label
var _status: Label
var _list: ScrollContainer
var _gallery: VBoxContainer
var _attack_controls: VBoxContainer
var _tabs: HBoxContainer
var _buttons: Array[Button] = []
var _resource: OptionButton
var _count: SpinBox
var _spread: CheckButton
var _play: Button
var _reset: Button
var _spacer: Control
var _scale_factor := 1.0
var _player_panel: PanelContainer
var _hover_controls: VBoxContainer
var _hover_pause: CheckButton
var _hover_slow: CheckButton
var _hover_speed_slider: HSlider
var _hover_speed_value: Label
var _hover_speed := 1.0
var _hover_original: CheckButton
var _hover_seek: HSlider
var _hover_replay: Button
var _resolution: OptionButton
var _resolution_note: Label
var _resolution_limit := 0
var _resolution_busy := false
var _resolution_generation := 0
var _resolution_cache: Dictionary = {}
var _resolution_lru: Array[int] = []
var _resolution_tasks: Dictionary = {}
var _sound: Sfx
var _fx_controls: VBoxContainer
var _fx_root: Node3D
var _fx_result: Dictionary = {}

func _exit_tree() -> void:
	_resolution_generation += 1
	for task in _resolution_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_resolution_tasks.clear()

class PreviewSurface extends Node:
	var host: Node
	func content_rect() -> Rect2:
		return host._surface
	func pointer_over_panels(pointer: Vector2) -> bool:
		return not content_rect().has_point(pointer)

func _ready() -> void:
	var window := get_window()
	var window_settings: Dictionary = UIConfig.read_json("res://data/animation_preview.json", true).preview.window
	ModeSwitch.configure_window(window, "牛马牌 · 动画预览 · 上班",
		Vector2i(window_settings.minimum_size[0], window_settings.minimum_size[1]),
		Vector2i(window_settings.size[0], window_settings.size[1]))
	_ids = OnWorkCardDB.all_cards().keys()
	# 交付每五张时可以只列本批；普通预览仍包含全部卡牌。
	var review_batch := OS.get_environment("CARD_PREVIEW_BATCH")
	if not review_batch.is_empty():
		var selected: Array[String] = []
		for id in review_batch.split(",", false):
			if _ids.has(id) and not selected.has(id):
				selected.append(id)
		if not selected.is_empty():
			_ids = selected
	board = Board.new()
	add_child(board)
	board.set_process(false)
	board.set_process_input(false)
	board.set_process_unhandled_input(false)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.position = Vector3(0, 20, 0)
	_camera.rotation_degrees.x = -90
	add_child(_camera)
	_camera.make_current()
	board.camera = _camera
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Palette.get_color("world", "table_felt")
	add_child(environment)
	_stage = Node3D.new()
	add_child(_stage)
	_sound = Sfx.new()
	add_child(_sound)
	_motion = Motion.new()
	add_child(_motion)
	_motion.bind(board, _sound)
	drawer_presentation = PreviewSurface.new()
	drawer_presentation.host = self
	add_child(drawer_presentation)
	table_hands = Hands.new()
	add_child(table_hands)
	table_hands.bind(self)
	table_hands.cursor_enabled = false
	_hover_speed = UIConfig.validated_defaults(UIConfig.read_section("defaults"))["hover_animation_speed"]
	_build_ui()
	window.size_changed.connect(_relayout)
	_relayout()
	var first_card := OS.get_environment("CARD_PREVIEW_CARD")
	show_card(first_card if _ids.has(first_card) else ("user" if _ids.has("user") else _ids[0]))
	var requested_resolution := OS.get_environment("CARD_PREVIEW_RESOLUTION")
	if not requested_resolution.is_empty():
		set_resolution(int(requested_resolution))
	if start_off_work:
		select_mode(true)
	if OS.get_environment("CARD_PREVIEW_SHOT") != "":
		_capture_preview()

func select_mode(to_off: bool) -> void:
	_modes.select(to_off)
	if off_work_active == to_off: return
	var was_paused := _hover_pause.button_pressed
	off_work_active = to_off
	get_window().title = "牛马牌 · 动画预览 · " + ("下班" if off_work_active else "上班")
	_stage.visible = not off_work_active
	table_hands.visible = not off_work_active
	_tabs.visible = not off_work_active
	for item in [_resolution_caption, _resolution, _resolution_note, _gallery]:
		item.visible = not off_work_active
	if off_work_active:
		_clear_cards()
		_clear_fx()
		_set_busy(false)
		table_hands.cursor_enabled = false
		_attack_controls.hide()
		_fx_controls.hide()
		_spacer.hide()
		_list.show()
		_hover_controls.show()
		if off_work_preview == null:
			off_work_preview = preload("res://scenes/off_work_animation_preview.gd").new()
			_layer.add_child(off_work_preview)
			off_work_preview.bind(self)
		off_work_preview.paused = was_paused
		off_work_preview.activate()
	else:
		off_work_preview.deactivate()
		_hover_seek.step = 1.0 / CardArt.hover_fps()
		_large.material = null
		_magnify.disabled = false
		_hover_original.disabled = false
		set_page(_page)
		if was_paused and _page == 0: _seek_seconds(0.0)
	_sync_magnifier()
	_relayout()

func _sync_magnifier() -> void:
	var enlarged := _magnify.button_pressed and _hover_controls.visible
	if off_work_active:
		enlarged = enlarged and not off_work_preview.is_scenario_mode()
		if is_instance_valid(off_work_preview.card): off_work_preview.card.visible = not enlarged
	else:
		enlarged = enlarged and _page == 0 and not _cards.is_empty()
		if _page == 0 and not _cards.is_empty():
			_cards[0].visible = not enlarged
			if enlarged: _large.texture = _cards[0]._icon.texture
	_large.visible = enlarged

func step_frame(direction: int) -> void:
	if off_work_active:
		off_work_preview.step_frame(direction)
	else:
		_hover_seek.value = clampf(_hover_seek.value + direction * _hover_seek.step, 0.0, _hover_seek.max_value)

func _drawer_input_blocked() -> bool:
	return false

func _label(text: String, font_size := 17) -> Label:
	var label := Label.new()
	label.text = text
	label.set_meta("font_base", font_size)
	label.add_theme_font_override("font", Fonts.zh_bold() if font_size >= 22 else Fonts.zh())
	label.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	button.add_theme_font_override("font", Fonts.zh())
	return button

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	_layer = layer
	layer.layer = 10
	add_child(layer)
	_sidebar = PanelContainer.new()
	layer.add_child(_sidebar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_sidebar.add_child(column)
	column.add_child(_label("动画预览", 24))
	_modes = ModeSwitch.new()
	column.add_child(_modes)
	_modes.mode_selected.connect(select_mode)
	_modes.select(false)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	column.add_child(_tabs)
	_tabs.add_child(_button("悬停动画", func(): set_page(0)))
	_tabs.add_child(_button("攻击撕牌", func(): set_page(1)))
	_tabs.add_child(_button("牌桌特效", func(): set_page(FX_PAGE)))
	_tabs.get_child(0).set_meta("ui_role", "primary")
	_resolution_caption = _label("插画分辨率 · 最长边", 17)
	column.add_child(_resolution_caption)
	_resolution = OptionButton.new()
	for limit in ArtResolution.LIMITS:
		_resolution.add_item(ArtResolution.option_label(Vector2i.ZERO, limit), limit)
	_resolution.item_selected.connect(func(index): set_resolution(_resolution.get_item_id(index)))
	column.add_child(_resolution)
	_resolution_note = _label("", 14)
	column.add_child(_resolution_note)
	_list = ScrollContainer.new()
	_list.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_list)
	_gallery = VBoxContainer.new()
	_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_child(_gallery)
	for id in _ids:
		var button := _button(OnWorkCardDB.card_name(id), show_card.bind(id))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_gallery.add_child(button)
		_buttons.append(button)
	_attack_controls = VBoxContainer.new()
	_attack_controls.add_theme_constant_override("separation", 12)
	column.add_child(_attack_controls)
	_attack_controls.add_child(_label("被攻击的卡牌"))
	_resource = OptionButton.new()
	_resource.add_item("现金")
	_resource.add_item("用户")
	_resource.item_selected.connect(func(_index): reset_attack())
	_attack_controls.add_child(_resource)
	_attack_controls.add_child(_label("一次撕开的张数"))
	_count = SpinBox.new()
	_count.min_value = 1
	_count.max_value = 10
	_count.step = 1
	_count.value = 5
	_count.value_changed.connect(func(_value): reset_attack())
	_attack_controls.add_child(_count)
	_spread = CheckButton.new()
	_spread.text = "先摊开放置"
	_spread.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	_spread.toggled.connect(func(_on): reset_attack())
	_attack_controls.add_child(_spread)
	_play = _button("播放撕牌", play_attack)
	_play.set_meta("ui_role", "primary")
	_attack_controls.add_child(_play)
	_reset = _button("重新摆牌", reset_attack)
	_attack_controls.add_child(_reset)
	_attack_controls.add_child(_label("也可以直接点击右侧的卡牌。\n一双手抓起整叠，同时撕开。", 15))
	_fx_controls = VBoxContainer.new()
	_fx_controls.add_theme_constant_override("separation", 6)
	column.add_child(_fx_controls)
	_fx_controls.add_child(_label("攻击、结算、升级与终局", 17))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_fx_controls.add_child(grid)
	for demo in FX_DEMOS:
		var button := _button(str(demo[1]), play_fx.bind(str(demo[0])))
		button.name = "Fx_" + str(demo[0])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(button)
	_fx_controls.add_child(_button("清空桌面", reset_fx))
	_fx_controls.add_child(_label("终局印章与封条会留在桌上，点「清空桌面」重摆。画面震动跟随游戏 UI 设置。", 14))
	_fx_controls.hide()
	_spacer = Control.new()
	_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_spacer.hide()
	column.add_child(_spacer)
	_player_panel = PanelContainer.new()
	layer.add_child(_player_panel)
	_hover_controls = VBoxContainer.new()
	_player_panel.add_child(_hover_controls)
	var actions := HFlowContainer.new()
	_hover_controls.add_child(actions)
	actions.add_child(_button("上一步", step_frame.bind(-1)))
	_hover_pause = CheckButton.new()
	_hover_pause.text = "暂停"
	_hover_pause.toggled.connect(func(on):
		if off_work_active: off_work_preview.set_paused(on)
		elif not _cards.is_empty(): _cards[0].hover_animation_paused = on)
	actions.add_child(_hover_pause)
	actions.add_child(_button("下一步", step_frame.bind(1)))
	_hover_replay = _button("重播", replay_motion)
	actions.add_child(_hover_replay)
	_hover_slow = CheckButton.new()
	_hover_slow.text = "¼ 慢放"
	_hover_slow.toggled.connect(func(_on): _apply_hover_speed())
	actions.add_child(_hover_slow)
	_hover_original = CheckButton.new()
	_hover_original.text = "原图"
	_hover_original.toggled.connect(_compare_original)
	actions.add_child(_hover_original)
	_magnify = CheckButton.new()
	_magnify.text = "放大插画"
	_magnify.toggled.connect(func(_on): _sync_magnifier())
	actions.add_child(_magnify)
	for toggle in [_hover_pause, _hover_slow, _hover_original, _magnify]:
		toggle.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	var sliders := HBoxContainer.new()
	sliders.add_theme_constant_override("separation", 8)
	_hover_controls.add_child(sliders)
	var timeline_caption := _label("时间轴（秒）", 15)
	timeline_caption.autowrap_mode = TextServer.AUTOWRAP_OFF
	sliders.add_child(timeline_caption)
	_hover_seek = HSlider.new()
	_hover_seek.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_seek.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hover_seek.min_value = 0
	_hover_seek.max_value = 1.8
	_hover_seek.step = 1.0 / CardArt.hover_fps()
	_hover_seek.accessibility_name = "动画时间轴"
	_hover_seek.drag_started.connect(func():
		if off_work_active: off_work_preview._timeline_dragging = true)
	_hover_seek.drag_ended.connect(func(changed):
		if off_work_active: off_work_preview._finish_timeline_drag(changed))
	_hover_seek.value_changed.connect(_seek_seconds)
	sliders.add_child(_hover_seek)
	var speed_caption := _label("播放速度", 15)
	speed_caption.autowrap_mode = TextServer.AUTOWRAP_OFF
	sliders.add_child(speed_caption)
	_hover_speed_slider = HSlider.new()
	_hover_speed_slider.name = "HoverAnimationSpeed"
	var speed_control := UIConfig.hover_speed_control()
	_hover_speed_slider.min_value = speed_control["min"]
	_hover_speed_slider.max_value = speed_control["max"]
	_hover_speed_slider.step = speed_control["step"]
	_hover_speed_slider.custom_minimum_size.x = 88
	_hover_speed_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hover_speed_slider.set_value_no_signal(_hover_speed)
	_hover_speed_slider.accessibility_name = "卡牌插画播放速度"
	_hover_speed_slider.value_changed.connect(set_hover_animation_speed)
	sliders.add_child(_hover_speed_slider)
	_hover_speed_value = _label("", 15)
	_hover_speed_value.name = "HoverAnimationSpeedValue"
	_hover_speed_value.autowrap_mode = TextServer.AUTOWRAP_OFF
	sliders.add_child(_hover_speed_value)
	_large = TextureRect.new()
	_large.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_large.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_large.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_large.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	layer.add_child(_large)
	_large.hide()
	_heading = _label("", 27)
	_hint = _label("", 17)
	_status = _label("", 16)
	for label in [_heading, _hint, _status]:
		label.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("surface"), Palette.get_color("world", "table_felt")))
		layer.add_child(label)
	_attack_controls.hide()

func _compare_original(on: bool) -> void:
	if off_work_active:
		off_work_preview.show_original(on)
		return
	if _cards.is_empty(): return
	var card := _cards[0]
	card.set_hover_visual(false, false)
	_hover = null
	if not on and _hover_pause.button_pressed:
		card.set_hover_visual(true, false)
		card._hover_elapsed = _hover_seek.value + 0.15
		card.seek_hover_animation(_hover_seek.value)
		_hover = card

func _seek_seconds(value: float) -> void:
	if off_work_active:
		off_work_preview._timeline_changed(value)
		return
	if _cards.is_empty(): return
	_hover_original.set_pressed_no_signal(false)
	_hover_pause.set_pressed_no_signal(true)
	var card := _cards[0]
	card.set_hover_visual(true, false)
	card.hover_animation_paused = true
	card._hover_elapsed = value + 0.15
	card.seek_hover_animation(value)
	_hover = card

func _theme(node: Node) -> void:
	if node is Label:
		node.add_theme_font_size_override("font_size", roundi(float(node.get_meta("font_base", 17)) * _scale_factor))
	elif node is Button:
		node.add_theme_font_override("font", Fonts.zh())
		node.add_theme_font_size_override("font_size", roundi(17 * _scale_factor))
		if not node is CheckButton:
			ButtonTheme.apply(node, _scale_factor, 8, 8)
	elif node is SpinBox:
		node.add_theme_font_override("font", Fonts.zh())
		node.add_theme_font_size_override("font_size", roundi(18 * _scale_factor))
		_theme(node.get_line_edit())
	elif node is LineEdit:
		node.add_theme_font_override("font", Fonts.zh())
		node.add_theme_font_size_override("font_size", roundi(18 * _scale_factor))
		node.add_theme_color_override("font_color", Palette.get_color("card", "body"))
		var field := StyleBoxFlat.new()
		field.bg_color = Palette.semantic("surface")
		field.border_color = CardArt.frame_color()
		field.set_border_width_all(1)
		field.set_corner_radius_all(6)
		field.set_content_margin_all(8 * _scale_factor)
		node.add_theme_stylebox_override("normal", field)
	for child in node.get_children():
		_theme(child)

func _relayout() -> void:
	if _sidebar == null:
		return
	var size := get_viewport().get_visible_rect().size
	_scale_factor = clampf(minf(size.x / 1440.0, size.y / 960.0), 0.8, 1.8)
	var pad := 22.0 * _scale_factor
	var side_width := 315.0 * _scale_factor
	_sidebar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_sidebar.offset_left = pad
	_sidebar.offset_top = pad
	_sidebar.offset_bottom = -pad
	_sidebar.offset_right = pad + side_width
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.semantic("surface")
	style.border_color = CardArt.frame_color()
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(14 * _scale_factor)
	_sidebar.add_theme_stylebox_override("panel", style)
	_theme(_sidebar)
	_theme(_player_panel)
	_player_panel.visible = _hover_controls.visible
	_player_panel.add_theme_stylebox_override("panel", style)
	var left := pad + maxf(_sidebar.get_combined_minimum_size().x, side_width) + pad
	var width := size.x - left - pad
	var player_height := 108.0 * _scale_factor
	_player_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_player_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_player_panel.offset_left = left
	_player_panel.offset_right = -pad
	_player_panel.offset_top = -pad - player_height
	_player_panel.offset_bottom = -pad
	var bottom := size.y - pad - player_height if _player_panel.visible else size.y - pad
	var top := 125.0 * _scale_factor
	_surface = Rect2(left, top, width, maxf(1, bottom - 64 * _scale_factor - top))
	_heading.position = Vector2(_surface.position.x, pad + 8 * _scale_factor)
	_heading.size = Vector2(_surface.size.x, 42 * _scale_factor)
	_hint.position = _heading.position + Vector2(0, 52 * _scale_factor)
	_hint.size = Vector2(_surface.size.x, 55 * _scale_factor)
	_status.position = Vector2(_surface.position.x, _surface.end.y + 20 * _scale_factor)
	_status.size = Vector2(_surface.size.x, 55 * _scale_factor)
	_large.position = _surface.position
	_large.size = _surface.size
	if is_instance_valid(off_work_preview):
		off_work_preview.position = _surface.position
		off_work_preview.size = _surface.size
	for label in [_heading, _hint, _status]:
		_theme(label)
	_position_cards()

func _position_cards() -> void:
	var card_framing := maxf(2.8, 1.95 * get_viewport().get_visible_rect().size.y / maxf(1, _surface.size.y))
	if off_work_active and is_instance_valid(off_work_preview) and is_instance_valid(off_work_preview.card):
		_camera.size = card_framing
		var center := _camera.project_ray_origin(_surface.get_center())
		off_work_preview.card.position = Vector3(center.x, 0.05, center.z)
		return
	_camera.size = maxf(4.8, (1.35 * _cards.size() + 1.0) * get_viewport().get_visible_rect().size.y / _surface.size.x) \
		if _page == 1 and _spread.button_pressed else 4.8
	if _page == 0 and not _cards.is_empty() and _cards[0].hover_animation_duration > 0.0:
		_camera.size = card_framing
	if _page == FX_PAGE:
		_camera.size = 7.0
	var ray := _camera.project_ray_origin(_surface.get_center())
	for i in _cards.size():
		var card := _cards[i]
		if not is_instance_valid(card) or card._visual_retired:
			continue
		var offset := float(i) - float(_cards.size() - 1) * 0.5
		var spread := (_page == 1 and _spread.button_pressed) or _page == FX_PAGE
		card.global_position = Vector3(ray.x, 0.05, ray.z) + \
			(Vector3(offset * (2.5 if _page == FX_PAGE else 1.35), 0, 0) if spread else Vector3(offset * 0.035, i * 0.024, offset * 0.04))

func _clear_cards() -> void:
	_generation += 1
	_resolution_generation += 1
	_set_resolution_busy(false)
	_resolution_cache.clear()
	_resolution_lru.clear()
	if is_instance_valid(_hover):
		_hover.set_hover_visual(false, false)
	_hover = null
	_attack_hl.clear()
	table_hands.clear()
	for card in _stage.get_children():
		if card is CardEntity:
			board.unregister_card(card)
			card.collision_layer = 0
			card.collision_mask = 0
			card.queue_free()
	_cards.clear()

func _spawn(id: String) -> void:
	var card := OnWorkPreviewCard.new()
	_uid += 1
	card.setup(_uid, id)
	_stage.add_child(card)
	card.freeze = true
	board.register_card(card)
	_cards.append(card)

func set_page(page: int) -> void:
	if off_work_active: return
	if _player_attack_busy != 0:
		return
	_page = page
	board.attack_mode = page == 1
	table_hands.cursor_enabled = page == 1
	_list.visible = page == 0
	_attack_controls.visible = page == 1
	_fx_controls.visible = page == FX_PAGE
	_spacer.visible = page != 0
	for i in _tabs.get_child_count():
		_tabs.get_child(i).set_meta("ui_role", "primary" if i == page else "tool")
	if page != FX_PAGE:
		_clear_fx()
	if page == 0:
		show_card(_ids[_selection])
	elif page == FX_PAGE:
		reset_fx()
	else:
		reset_attack()

## 特效页：一张生产牌和一叠被攻击的资源牌，按钮直接调正式牌桌用的演出。
func reset_fx() -> void:
	if _page != FX_PAGE:
		return
	_clear_cards()
	_clear_fx()
	_fx_root = Node3D.new()
	_fx_root.name = "FxStage"
	add_child(_fx_root)
	_heading.text = "牌桌特效"
	_hint.text = "按左侧按钮播放；调用的是对局里同一套演出。"
	_status.text = ""
	_relayout()
	_fx_place("yunketang", FX_CORE)
	_fx_place(OnWorkCardDB.unit_id(OnWorkCardDB.RES_USER), FX_TARGET)

func _fx_center() -> Vector3:
	var ray := _camera.project_ray_origin(_surface.get_center())
	return Vector3(ray.x, 0.0, ray.z)

## 台面上的牌不进 _cards：它们由特效页自己摆，撕掉了就补一张。
func _fx_place(id: String, offset: Vector3, count := 1) -> Array:
	var made: Array = []
	for i in count:
		var card := OnWorkPreviewCard.new()
		_uid += 1
		card.setup(_uid, id)
		_fx_root.add_child(card)
		card.freeze = true
		card.collision_layer = 0
		card.collision_mask = 0
		card.global_position = _fx_center() + offset + Vector3(0.03 * i, 0.024 * i, 0.04 * i)
		made.append(card)
	return made

func _fx_cards(id: String) -> Array:
	return _fx_root.get_children().filter(func(node): return node is CardEntity and node.def_id == id \
		and not node._visual_retired and not node.is_queued_for_deletion())

func _clear_fx() -> void:
	ResultPresentation.close(_fx_result)
	if is_instance_valid(_fx_root):
		_fx_root.queue_free()
	_fx_root = null
	_camera.h_offset = 0.0
	_camera.v_offset = 0.0

func play_fx(kind: String) -> void:
	if _page != FX_PAGE or not is_instance_valid(_fx_root):
		return
	ResultPresentation.close(_fx_result)
	var config := ComicFx.rules()
	_status.text = ""
	var core: CardEntity = null
	for card in _fx_cards("yunketang"):
		core = card
	if core == null:
		core = _fx_place("yunketang", FX_CORE)[0]
	match kind:
		"hit", "coins", "final":
			_fx_attack(OnWorkCardDB.RES_CASH if kind == "coins" else OnWorkCardDB.RES_USER, kind == "final", 3)
		"void":
			_sound.play("combo_broken")
			core.set_void_stamp(true)
			_motion.delayed_call(func() -> void:
				if is_instance_valid(core): core.set_void_stamp(false), 1.4)
		"cash", "user":
			var cash := kind == "cash"
			var color := Palette.semantic("cash" if cash else "user")
			var source := ComicFx.production(_fx_root, _camera, core, core.global_position, cash,
				int(OnWorkCardDB.get_def("yunketang").get("output_n", 3)), _sound)
			UIMotion.play(_fx_root, "production", source, color, 12, "coin" if cash else "user")
		"upgrade", "legend":
			_sound.play("upgrade")
			UIMotion.play(_fx_root, "upgrade", core.global_position + Vector3.UP * 0.6, Palette.plate_color("plate_t3", "band"))
			UIMotion.play(_fx_root, "celebrate", core.global_position + Vector3.UP * 0.6, Color.WHITE, 24 if kind == "legend" else 16, "spark")
			ComicFx.upgrade(_fx_root, _camera, core, core.global_position, kind == "legend", _sound)
		_:
			_show_fx_result(kind, _fx_center() + Vector3(0, 0.55, 0))

## 撕一叠：真实的抓握、顿帧、折痕与裂口、撕开、纸屑，和对局里同一条链。
func _fx_attack(res: String, final: bool, count: int) -> void:
	var unit := OnWorkCardDB.unit_id(res)
	for old in _fx_root.get_children():
		if old is CardEntity and old.def_id != "yunketang" and old.def_id != unit:
			old.queue_free()
	var targets := _fx_cards(unit)
	if targets.size() < count:
		targets.append_array(_fx_place(unit, FX_TARGET + Vector3(0, 0.024 * targets.size(), 0), count - targets.size()))
	var at := Vector3.ZERO
	for card in targets:
		at += card.global_position
	at /= float(targets.size())
	var hold := ComicFx.hitstop("final" if final else "hit")
	_sound.play("attack")
	_motion.tear_batch(targets, table_hands, Vector3(0, 4, -2), hold, func() -> void:
		ComicFx.hit(_fx_root, _camera, targets, at, "final" if final else "hit", res, Vector3(1.0, 0.0, -0.8), hold))
	var scrap := CardArt.face_color(unit)
	_motion.delayed_call(func() -> void:
		if is_instance_valid(_fx_root):
			UIMotion.play(_fx_root, "attack", at + Vector3(0, 0.5, 0), scrap, 14), Motion.BATCH_GRIP + hold)
	_motion.delayed_call(func() -> void:
		if is_instance_valid(_fx_root) and _fx_cards(unit).is_empty():
			_fx_place(unit, FX_TARGET), Motion.BATCH_DURATION + hold + 0.3)

## 终局：按胜因造一份真实终局读数，弹出正式结果面板，并在桌上补终局的那一笔。
func _show_fx_result(kind: String, at: Vector3) -> void:
	var state := OnWorkState.new()
	state.new_game()
	var me := OnWorkState.PLAYER
	var foe := OnWorkState.BOT
	var win_cash := int(OnWorkCardDB.game_rules()["win_cash"])
	match kind:
		"listing":
			_set_resource(state, me, OnWorkCardDB.RES_CASH, win_cash)
		"bankrupt":
			_set_resource(state, foe, OnWorkCardDB.RES_CASH, 0)
		"exodus":
			_set_resource(state, foe, OnWorkCardDB.RES_USER, 0)
		_:
			_set_resource(state, me, OnWorkCardDB.RES_CASH, maxi(1, win_cash - 3))
			_set_resource(state, foe, OnWorkCardDB.RES_CASH, win_cash)
	state.round_num = 9
	state.check_victory()
	var stats := {me: {OnWorkCardDB.RES_CASH: 46, OnWorkCardDB.RES_USER: 12, "torn": 9}}
	var finale := ResultPresentation.finale_for(state, me, stats)
	_fx_result = ResultPresentation.create(self, state, me, _sound, func(): ResultPresentation.close(_fx_result),
		"关闭", false, false, finale)
	ResultPresentation.present(_fx_result, null)
	ComicFx.finale(_fx_root, _camera, str(finale.get("kind", "")), {"winner_cash": at + FX_CORE,
		"loser_cash": at + FX_TARGET, "loser_user": at + FX_TARGET}, state.winner != me, _sound)
	_status.text = "%s · %s" % [finale.get("stamp", ""), state.win_reason]

static func _set_resource(state: OnWorkState, seat: String, res: String, count: int) -> void:
	var unit := OnWorkCardDB.unit_id(res)
	state.players[seat]["cards"] = state.players[seat]["cards"].filter(func(card): return card["def_id"] != unit)
	for i in count:
		state.add_card(seat, unit)

func show_card(id: String) -> void:
	if _player_attack_busy != 0:
		return
	_selection = _ids.find(id)
	if _selection < 0:
		_selection = 0
	_clear_cards()
	_spawn(_ids[_selection])
	_hover_pause.set_pressed_no_signal(false)
	_apply_hover_speed()
	_hover_original.set_pressed_no_signal(false)
	_hover_seek.set_value_no_signal(0)
	_hover_seek.max_value = _cards[0].hover_animation_duration
	_hover_controls.visible = _page == 0 and _cards[0].hover_animation_duration > 0.0
	_heading.text = "%s · %d / %d" % [OnWorkCardDB.card_name(_ids[_selection]), _selection + 1, _ids.size()]
	var config := CardArt.hover_config(_ids[_selection])
	var kind := "完整帧动画" if config.has("files") or config.get("codec", "") == "hdelta-v1" else "待修复图集"
	_hint.text = "%s · %d 帧 · %d fps · 鼠标悬停播放。" % [kind, int(config.get("frames", 0)), int(CardArt.hover_fps())]
	for i in _buttons.size():
		_buttons[i].set_meta("ui_role", "primary" if i == _selection else "tool")
		ButtonTheme.apply(_buttons[i], _scale_factor, 8, 8)
	_list.ensure_control_visible(_buttons[_selection])
	_relayout()
	set_resolution(_resolution_limit)

func set_hover_animation_speed(value: float) -> void:
	_hover_speed = UIConfig.validated_defaults({"hover_animation_speed": value})["hover_animation_speed"]
	_hover_speed_slider.set_value_no_signal(_hover_speed)
	_apply_hover_speed()

func _apply_hover_speed() -> void:
	if off_work_active:
		off_work_preview.apply_speed(_hover_speed * (0.25 if _hover_slow.button_pressed else 1.0))
		return
	_hover_speed_value.text = UIConfig.hover_speed_text(_hover_speed)
	if _page == 0:
		for card in _cards:
			card.hover_animation_speed = _hover_speed * (0.25 if _hover_slow.button_pressed else 1.0)

## 只准备当前卡的变体。后台缩放、逐帧上传，旧请求不能覆盖新的选择。
func set_resolution(limit: int) -> void:
	if not limit in ArtResolution.LIMITS or _player_attack_busy != 0:
		return
	_resolution_limit = limit
	_resolution.select(ArtResolution.LIMITS.find(limit))
	_resolution_generation += 1
	var generation := _resolution_generation
	if _cards.is_empty():
		return
	for card in _cards:
		if not card.has_meta("resolution_resume_process"):
			card.set_meta("resolution_resume_process", card.is_processing())
		card.set_process(false)
	_set_resolution_busy(true)
	_update_resolution_note("准备中")
	var first := _cards[0]
	var source_size := Vector2i(first._hover_original.get_size())
	# 正式素材已缩至 384；更高档位不造出假高清，也不提前加载整段动作。
	if ArtResolution.target_size(source_size, limit) == source_size:
		_finish_resolution({}, generation)
		return
	if _resolution_cache.has(limit):
		_touch_resolution(limit)
		_finish_resolution(_resolution_cache[limit], generation)
		return
	var sources: Array = [first._hover_original]
	if first.hover_animation_duration > 0.0:
		CardArt.request_hover_frames(first.def_id, first.get_instance_id())
		var deadline := Time.get_ticks_msec() + 30000
		while CardArt.hover_frames(first.def_id).is_empty():
			await get_tree().process_frame
			if not is_inside_tree() or generation != _resolution_generation:
				return
			if Time.get_ticks_msec() >= deadline:
				_finish_resolution({}, generation)
				_resolution_note.text = "动作帧尚未就绪，请重新选择分辨率。"
				return
		sources.append_array(CardArt.hover_frames(first.def_id))
	var unique: Dictionary = {}
	for texture in sources:
		if texture != null:
			unique[texture] = true
	var mapping: Dictionary = {}
	var completed := 0
	for texture: Texture2D in unique:
		if not is_inside_tree() or generation != _resolution_generation:
			return
		var size := Vector2i(texture.get_width(), texture.get_height())
		if ArtResolution.target_size(size, limit) == size:
			mapping[texture] = texture
		else:
			# get_image/upload 留在主线程；重采样与 mipmap 在后台完成。
			var result := {"image": texture.get_image()}
			var task := WorkerThreadPool.add_task(func():
				result.image = ArtResolution.resize_image(result.image, limit))
			_resolution_tasks[task] = true
			while not WorkerThreadPool.is_task_completed(task):
				await get_tree().process_frame
				if not is_inside_tree():
					return
			WorkerThreadPool.wait_for_task_completion(task)
			_resolution_tasks.erase(task)
			if not is_inside_tree() or generation != _resolution_generation:
				return
			mapping[texture] = ImageTexture.create_from_image(result.image)
		completed += 1
		_update_resolution_note("准备中 %d / %d" % [completed, unique.size()])
		await get_tree().process_frame
	if not is_inside_tree() or generation != _resolution_generation:
		return
	_resolution_cache[limit] = mapping
	_touch_resolution(limit)
	_finish_resolution(mapping, generation)

func _touch_resolution(limit: int) -> void:
	_resolution_lru.erase(limit)
	_resolution_lru.append(limit)
	# 留最近两档方便来回比较；换牌时清空，避免累积整套高清动画。
	while _resolution_lru.size() > 1 and (_resolution_lru.size() > 2 or _resolution_cache_bytes() > 134217728):
		_resolution_cache.erase(_resolution_lru.pop_front())

func _resolution_cache_bytes() -> int:
	var textures: Dictionary = {}
	var bytes := 0
	for mapping in _resolution_cache.values():
		for original in mapping:
			var texture: Texture2D = mapping[original]
			if texture == original or textures.has(texture):
				continue
			textures[texture] = true
			bytes += int(texture.get_width() * texture.get_height() * 4.0 * 4.0 / 3.0)
	return bytes

func _finish_resolution(mapping: Dictionary, generation: int) -> void:
	if generation != _resolution_generation:
		return
	for card in _cards:
		card.set_preview_textures(mapping)
		card.set_process(bool(card.get_meta("resolution_resume_process", false)))
		card.remove_meta("resolution_resume_process")
	_set_resolution_busy(false)
	_update_resolution_note()

func _set_resolution_busy(busy: bool) -> void:
	_resolution_busy = busy
	for toggle in [_hover_pause, _hover_slow, _hover_original]:
		toggle.disabled = busy
	_hover_seek.editable = not busy
	_hover_replay.disabled = busy
	_play.disabled = busy or _player_attack_busy != 0

func _update_resolution_note(progress := "") -> void:
	if _cards.is_empty():
		return
	var texture: Texture2D = _cards[0]._hover_original
	var source := Vector2i(texture.get_width(), texture.get_height())
	var target := ArtResolution.target_size(source, _resolution_limit)
	for index in _resolution.item_count:
		var limit := _resolution.get_item_id(index)
		_resolution.set_item_text(index, ArtResolution.option_label(source, limit))
	_resolution_note.text = "%d × %d · %s" % [target.x, target.y,
		progress if not progress.is_empty() else "正式原图" if target == source else "预览缩小"]
	if _resolution_limit > maxi(source.x, source.y):
		_resolution_note.text += "\n高于源图的档位不放大。"

func replay_motion() -> void:
	if off_work_active:
		off_work_preview.replay()
		return
	if _cards.is_empty() or _cards[0].hover_animation_duration <= 0.0: return
	_hover_original.set_pressed_no_signal(false)
	_hover_pause.set_pressed_no_signal(false)
	_hover_seek.set_value_no_signal(0.0)
	var card := _cards[0]
	card.set_hover_visual(false, false)
	card.set_hover_visual(true, false)
	card.hover_animation_paused = false
	_hover = card

func reset_attack() -> void:
	if _page != 1 or _player_attack_busy != 0:
		return
	_clear_cards()
	_hover_controls.hide()
	var id := "cash" if _resource.selected == 0 else "user"
	for i in int(_count.value):
		_spawn(id)
	_attack_hl.append_array(_cards)
	_heading.text = "攻击撕牌 · %s × %d" % [OnWorkCardDB.card_name(id), _cards.size()]
	_hint.text = "指向卡牌时手会生气；点击卡牌或“播放撕牌”查看整批效果。"
	_status.text = "准备就绪 · 一次抓成一叠，一次撕开。"
	_relayout()
	set_resolution(_resolution_limit)

func _set_busy(busy: bool) -> void:
	_player_attack_busy = 1 if busy else 0
	_play.disabled = busy
	_reset.disabled = busy
	_resource.disabled = busy
	_count.editable = not busy
	_spread.disabled = busy
	_resolution.disabled = busy
	for button in _tabs.get_children():
		button.disabled = busy

func play_attack() -> void:
	if _page != 1 or _player_attack_busy != 0 or _resolution_busy:
		return
	if _cards.is_empty() or not is_instance_valid(_cards[0]):
		reset_attack()
		var waiting_generation := _generation
		while _resolution_busy:
			await get_tree().process_frame
			if not is_inside_tree() or waiting_generation != _generation or _page != 1:
				return
	var generation := _generation
	var count := _cards.size()
	_set_busy(true)
	_attack_hl.clear()
	_hover = null
	_status.text = "一双手正在撕开 %d 张牌……" % count
	var duration: float = _motion.tear_batch(_cards, table_hands)
	await get_tree().create_timer(duration).timeout
	if not is_inside_tree() or generation != _generation:
		return
	_cards.clear()
	_motion.transferring()
	_set_busy(false)
	_status.text = "已一次撕开 %d 张牌。点击“播放撕牌”可再看一次。" % count

func _process(_delta: float) -> void:
	if off_work_active or board == null or _player_attack_busy != 0:
		return
	_update_hover(get_viewport().get_mouse_position())
	_sync_magnifier()

func _update_hover(pointer: Vector2) -> void:
	if _resolution_busy:
		_status.text = "正在准备当前分辨率 · 动作进度已保留"
		return
	if _page == 0 and not _cards.is_empty():
		if _hover_original.button_pressed:
			_status.text = "原图对照 · 原静止插画"
			return
		if _hover_pause.button_pressed:
			_status.text = "动作已暂停 · %.2f 秒 · 可拖动时间轴" % _hover_seek.value
			return
	var card: CardEntity = null
	if _surface.has_point(pointer):
		card = _cards[0] if _page == 0 and _large.visible and not _cards.is_empty() else board._pick_card(pointer)
	# 操作侧栏时继续保留当前动作，便于暂停、切换分辨率对照同一帧。
	if _page == 0 and is_instance_valid(_hover) and (_sidebar.get_global_rect().has_point(pointer) or _player_panel.get_global_rect().has_point(pointer)):
		card = _hover
	if card != _hover:
		if is_instance_valid(_hover):
			_hover.set_hover_visual(false, false)
		_hover = card
		if _hover != null:
			_hover.set_hover_visual(true, false)
	if _page == 0:
		if not _cards.is_empty() and _cards[0].hover_animation_duration > 0.0:
			_status.text = "静止原图 · 把鼠标放到卡面上播放"
			if _hover != null:
				if _hover._hover_frames.is_empty():
					_status.text = "正在后台准备动作帧 · 保持静止原图"
				else:
					_status.text = "多帧动画 · 基准 %d fps · 当前 %s%s" % [int(CardArt.hover_fps()),
						UIConfig.hover_speed_text(_hover.hover_animation_speed), " · ¼ 慢放" if _hover_slow.button_pressed else ""]
					_hover_seek.set_value_no_signal(_hover.hover_animation_time())
		else:
			_status.text = "当前卡牌没有登记动作图集"

func _unhandled_input(event: InputEvent) -> void:
	if off_work_active: return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
		and _page == 1 and _player_attack_busy == 0 and _surface.has_point(event.position):
		if _attack_hl.has(board._pick_card(event.position)):
			play_attack()
			get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if off_work_active: return
	if event is InputEventKey and event.pressed and not event.echo and _page == 0:
		if event.keycode in [KEY_A, KEY_D]:
			step_frame(1 if event.keycode == KEY_D else -1)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_SPACE:
			_hover_pause.button_pressed = not _hover_pause.button_pressed
			get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_LEFT, KEY_RIGHT]:
			var step := 1 if event.keycode == KEY_RIGHT else -1
			show_card(_ids[posmod(_selection + step, _ids.size())])
			get_viewport().set_input_as_handled()

## 独立窗口抓拍同一套效果，便于自动检查真实导出包。
func _capture_preview() -> void:
	await get_tree().create_timer(0.5).timeout
	var spec := OS.get_environment("CARD_PREVIEW_SHOT").split(",")
	if spec.size() > 1 and spec[1] in ["tear", "ready"]:
		set_page(1)
		if spec.size() > 2:
			_count.value = clampi(int(spec[2]), 1, 10)
		while _resolution_busy:
			await get_tree().process_frame
		await get_tree().physics_frame
		get_window().grab_focus()
		get_viewport().warp_mouse(_camera.unproject_position(_cards.back().global_position))
		if spec[1] == "tear":
			play_attack()
			await get_tree().create_timer(0.32).timeout
		else:
			await get_tree().create_timer(0.3).timeout
	else:
		if spec.size() > 1:
			show_card(spec[1])
		while _resolution_busy:
			await get_tree().process_frame
		await get_tree().physics_frame
		get_window().grab_focus()
		get_viewport().warp_mouse(_camera.unproject_position(_cards[0].global_position))
		await get_tree().create_timer(0.75).timeout
		for attempt in 180:
			if not _cards[0]._hover_frames.is_empty():
				break
			await get_tree().process_frame
		if spec.size() > 2 and not _cards[0]._hover_frames.is_empty():
			_cards[0].set_hover_visual(true, false)
			_cards[0].hover_animation_paused = true
			var time := float(spec[2])
			_hover_pause.set_pressed_no_signal(true)
			_hover_seek.set_value_no_signal(time)
			_cards[0]._hover_elapsed = time + 0.15
			_cards[0].seek_hover_animation(time)
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(spec[0])
	get_tree().quit()
