# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node3D
## 独立视觉验收场景：只创建正式卡面与运动，不启动牌局或写入玩家设置。
const Motion = preload("res://scenes/card_motion.gd")
const Hands = preload("res://scenes/table_hands.gd")
const ButtonTheme = preload("res://scenes/ui_button_theme.gd")
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
var _hover_controls: VBoxContainer
var _hover_pause: CheckButton
var _hover_slow: CheckButton
var _hover_original: CheckButton
var _hover_seek: HSlider

class PreviewSurface extends Node:
	var host: Node
	func content_rect() -> Rect2:
		return host._surface
	func pointer_over_panels(pointer: Vector2) -> bool:
		return not content_rect().has_point(pointer)

func _ready() -> void:
	var window := get_window()
	window.title = "牛马牌 · 动画预览"
	window.transparent = false
	window.transparent_bg = false
	window.borderless = false
	window.always_on_top = false
	window.unresizable = false
	window.content_scale_size = Vector2i.ZERO
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.min_size = Vector2i(960, 680)
	window.size = Vector2i(1440, 960)
	_ids = CardDB.all_cards().keys()
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
	var sound := Sfx.new()
	add_child(sound)
	_motion = Motion.new()
	add_child(_motion)
	_motion.bind(board, sound)
	drawer_presentation = PreviewSurface.new()
	drawer_presentation.host = self
	add_child(drawer_presentation)
	table_hands = Hands.new()
	add_child(table_hands)
	table_hands.bind(self)
	table_hands.cursor_enabled = false
	_build_ui()
	window.size_changed.connect(_relayout)
	_relayout()
	var first_card := OS.get_environment("CARD_PREVIEW_CARD")
	show_card(first_card if _ids.has(first_card) else "user")
	if OS.get_environment("CARD_PREVIEW_SHOT") != "":
		_capture_preview()

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
	layer.layer = 10
	add_child(layer)
	_sidebar = PanelContainer.new()
	layer.add_child(_sidebar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_sidebar.add_child(column)
	column.add_child(_label("动画预览", 24))
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	column.add_child(_tabs)
	_tabs.add_child(_button("悬停动画", func(): set_page(0)))
	_tabs.add_child(_button("攻击撕牌", func(): set_page(1)))
	_tabs.get_child(0).set_meta("ui_role", "primary")
	_list = ScrollContainer.new()
	_list.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_list)
	_gallery = VBoxContainer.new()
	_gallery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_child(_gallery)
	for id in _ids:
		var button := _button(CardDB.card_name(id), show_card.bind(id))
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
	_spacer = Control.new()
	_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_spacer.hide()
	column.add_child(_spacer)
	_hover_controls = VBoxContainer.new()
	_hover_controls.add_theme_constant_override("separation", 6)
	column.add_child(_hover_controls)
	_hover_controls.add_child(_label("逐牌 · 多帧动画检查", 17))
	_hover_pause = CheckButton.new()
	_hover_pause.text = "暂停动作"
	_hover_pause.toggled.connect(func(on):
		if not _cards.is_empty(): _cards[0].hover_animation_paused = on)
	_hover_controls.add_child(_hover_pause)
	_hover_slow = CheckButton.new()
	_hover_slow.text = "慢放（¼ 速度）"
	_hover_slow.toggled.connect(func(on):
		if not _cards.is_empty(): _cards[0].hover_animation_speed = 0.25 if on else 1.0)
	_hover_controls.add_child(_hover_slow)
	_hover_original = CheckButton.new()
	_hover_original.text = "只看原图"
	_hover_original.toggled.connect(func(on):
		if _cards.is_empty() or _cards[0]._hover_frames.is_empty(): return
		var card := _cards[0]
		card.set_hover_visual(false, false)
		_hover = null
		if not on and _hover_pause.button_pressed:
			card.set_hover_visual(true, false)
			card._hover_elapsed = _hover_seek.value + 0.15
			card.seek_hover_animation(_hover_seek.value)
			_hover = card)
	_hover_controls.add_child(_hover_original)
	for toggle in [_hover_pause, _hover_slow, _hover_original]:
		toggle.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	_hover_controls.add_child(_label("拖动时间轴检查动作（秒）", 14))
	_hover_seek = HSlider.new()
	_hover_seek.min_value = 0
	_hover_seek.max_value = 1.8
	_hover_seek.step = 1.0 / CardArt.hover_fps()
	_hover_seek.value_changed.connect(func(value):
		if _cards.is_empty() or _cards[0]._hover_frames.is_empty(): return
		_hover_original.set_pressed_no_signal(false)
		_hover_pause.set_pressed_no_signal(true)
		var card := _cards[0]
		card.set_hover_visual(true, false)
		card.hover_animation_paused = true
		card._hover_elapsed = value + 0.15
		card.seek_hover_animation(value)
		_hover = card)
	_hover_controls.add_child(_hover_seek)
	_hover_controls.add_child(_button("重新播放动作", replay_motion))
	column.add_child(_label("悬停页可用 ← / → 切换卡牌。", 14))
	_heading = _label("", 27)
	_hint = _label("", 17)
	_status = _label("", 16)
	for label in [_heading, _hint, _status]:
		label.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("surface"), Palette.get_color("world", "table_felt")))
		layer.add_child(label)
	_attack_controls.hide()

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
	_scale_factor = clampf(size.x / 1440.0, 0.85, 1.8)
	var pad := 22.0 * _scale_factor
	var side_width := 285.0 * _scale_factor
	_sidebar.position = Vector2(pad, pad)
	_sidebar.size = Vector2(side_width, size.y - pad * 2)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.semantic("surface")
	style.border_color = CardArt.frame_color()
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(14 * _scale_factor)
	_sidebar.add_theme_stylebox_override("panel", style)
	_surface = Rect2(side_width + pad * 2, 125 * _scale_factor,
		size.x - side_width - pad * 3, size.y - 205 * _scale_factor)
	_heading.position = Vector2(_surface.position.x, pad + 8 * _scale_factor)
	_heading.size = Vector2(_surface.size.x, 42 * _scale_factor)
	_hint.position = _heading.position + Vector2(0, 52 * _scale_factor)
	_hint.size = Vector2(_surface.size.x, 55 * _scale_factor)
	_status.position = Vector2(_surface.position.x, _surface.end.y + 20 * _scale_factor)
	_status.size = Vector2(_surface.size.x, 55 * _scale_factor)
	_theme(_sidebar)
	for label in [_heading, _hint, _status]:
		_theme(label)
	_position_cards()

func _position_cards() -> void:
	_camera.size = maxf(4.8, (1.35 * _cards.size() + 1.0) * get_viewport().get_visible_rect().size.y / _surface.size.x) \
		if _page == 1 and _spread.button_pressed else 4.8
	if _page == 0 and not _cards.is_empty() and not _cards[0]._hover_frames.is_empty():
		_camera.size = 2.8
	var ray := _camera.project_ray_origin(_surface.get_center())
	for i in _cards.size():
		var card := _cards[i]
		if not is_instance_valid(card) or card._visual_retired:
			continue
		var offset := float(i) - float(_cards.size() - 1) * 0.5
		card.global_position = Vector3(ray.x, 0.05, ray.z) + \
			(Vector3(offset * 1.35, 0, 0) if _page == 1 and _spread.button_pressed else Vector3(offset * 0.035, i * 0.024, offset * 0.04))

func _clear_cards() -> void:
	_generation += 1
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
	var card := CardEntity.new()
	_uid += 1
	card.setup(_uid, id)
	_stage.add_child(card)
	card.freeze = true
	board.register_card(card)
	_cards.append(card)

func set_page(page: int) -> void:
	if _player_attack_busy != 0:
		return
	_page = page
	board.attack_mode = page == 1
	table_hands.cursor_enabled = page == 1
	_list.visible = page == 0
	_attack_controls.visible = page == 1
	_spacer.visible = page == 1
	for i in _tabs.get_child_count():
		_tabs.get_child(i).set_meta("ui_role", "primary" if i == page else "tool")
	if page == 0:
		show_card(_ids[_selection])
	else:
		reset_attack()

func show_card(id: String) -> void:
	if _player_attack_busy != 0:
		return
	_selection = _ids.find(id)
	if _selection < 0:
		_selection = 0
	_clear_cards()
	_spawn(_ids[_selection])
	_hover_pause.set_pressed_no_signal(false)
	_hover_slow.set_pressed_no_signal(false)
	_hover_original.set_pressed_no_signal(false)
	_hover_seek.set_value_no_signal(0)
	if not _cards[0]._hover_frames.is_empty():
		_hover_seek.max_value = _cards[0].hover_animation_duration
	_hover_controls.visible = _page == 0 and not _cards[0]._hover_frames.is_empty()
	_heading.text = "%s · %d / %d" % [CardDB.card_name(_ids[_selection]), _selection + 1, _ids.size()]
	_hint.text = "上一版动作图集 · %d 帧 · %d fps · 鼠标悬停播放。" % [_cards[0]._hover_frames.size(), int(CardArt.hover_fps())]
	for i in _buttons.size():
		_buttons[i].set_meta("ui_role", "primary" if i == _selection else "tool")
		ButtonTheme.apply(_buttons[i], _scale_factor, 8, 8)
	_list.ensure_control_visible(_buttons[_selection])
	_relayout()

func replay_motion() -> void:
	if _cards.is_empty() or _cards[0]._hover_frames.is_empty(): return
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
	_heading.text = "攻击撕牌 · %s × %d" % [CardDB.card_name(id), _cards.size()]
	_hint.text = "指向卡牌时手会生气；点击卡牌或“播放撕牌”查看整批效果。"
	_status.text = "准备就绪 · 一次抓成一叠，一次撕开。"
	_relayout()

func _set_busy(busy: bool) -> void:
	_player_attack_busy = 1 if busy else 0
	_play.disabled = busy
	_reset.disabled = busy
	_resource.disabled = busy
	_count.editable = not busy
	_spread.disabled = busy
	for button in _tabs.get_children():
		button.disabled = busy

func play_attack() -> void:
	if _page != 1 or _player_attack_busy != 0:
		return
	if _cards.is_empty() or not is_instance_valid(_cards[0]):
		reset_attack()
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
	if board == null or _player_attack_busy != 0:
		return
	_update_hover(get_viewport().get_mouse_position())

func _update_hover(pointer: Vector2) -> void:
	if _page == 0 and not _cards.is_empty() and not _cards[0]._hover_frames.is_empty():
		if _hover_original.button_pressed:
			_status.text = "原图对照 · 原静止插画"
			return
		if _hover_pause.button_pressed:
			_status.text = "动作已暂停 · %.2f 秒 · 可拖动时间轴" % _hover_seek.value
			return
	var card: CardEntity = board._pick_card(pointer) if _surface.has_point(pointer) else null
	if card != _hover:
		if is_instance_valid(_hover):
			_hover.set_hover_visual(false, false)
		_hover = card
		if _hover != null:
			_hover.set_hover_visual(true, false)
	if _page == 0:
		if not _cards.is_empty() and not _cards[0]._hover_frames.is_empty():
			_status.text = "多帧动画 · 12 fps · %s" % ("¼ 速度" if _hover_slow.button_pressed else "正常速度") if _hover != null else "静止原图 · 把鼠标放到卡面上播放"
			if _hover != null:
				_hover_seek.set_value_no_signal(_hover.hover_animation_time())
		else:
			_status.text = "当前卡牌没有登记动作图集"

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
		and _page == 1 and _player_attack_busy == 0 and _surface.has_point(event.position):
		if _attack_hl.has(board._pick_card(event.position)):
			play_attack()
			get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and _page == 0:
		if event.keycode in [KEY_LEFT, KEY_RIGHT]:
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
		await get_tree().physics_frame
		get_window().grab_focus()
		get_viewport().warp_mouse(_camera.unproject_position(_cards[0].global_position))
		await get_tree().create_timer(0.75).timeout
		if spec.size() > 2 and not _cards[0]._hover_frames.is_empty():
			_cards[0].set_hover_visual(true, false)
			_cards[0].hover_animation_paused = true
			_cards[0].seek_hover_animation(float(spec[2]))
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(spec[0])
	get_tree().quit()
