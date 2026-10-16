# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends CanvasLayer

const Mascot = preload("res://scenes/drawer_mascot.gd")
const UIButtonTheme = preload("res://scenes/ui_button_theme.gd")
const CameraFit = preload("res://scenes/drawer_camera_fit.gd")
const CameraView = preload("res://scenes/table_camera_view.gd")
const UIConfig = preload("res://engine/ui_config.gd")
const Rulebook = preload("res://scenes/rulebook.gd")
const CardConfig = preload("res://engine/card_config.gd")
const TutorialCatalog = preload("res://engine/tutorial_catalog.gd")
const TutorialProgress = preload("res://engine/tutorial_progress.gd")
const TutorialContext = preload("res://engine/tutorial_context.gd")
const ResultFx = preload("res://scenes/result_fx.gd")

# 展示顺序与动作ID分开，增加首页不会改变既有设置入口。
const UTILITY_RULEBOOK := 7
const UTILITY_REPLAY := 8
const UTILITY_CARDS := 9
## 窄屏底栏放不下角色按钮时，选项菜单里临时出现的替身入口（见 _fit_role_button）
const UTILITY_ROLE := 10
## 底栏里给即时提示至少留这么宽（逻辑像素），挤不出来就不放角色按钮
const ROLE_MESSAGE_MIN := 200.0
const UTILITY_PAGES := [
	[1, "BOT 强度"], [2, "提示记录"],
	[3, "UI"], [4, "入口大小"], [5, "存录像"], [UTILITY_REPLAY, "读入录像"], [6, "局域网对战"], [UTILITY_CARDS, "卡牌配置"],
]

## 桌面抽屉与移动端共用的镜头与界面；抽屉控制器可为空。世界节点保持单位缩放，屏幕布局和物理布局分别计算。
## 固定牌桌边界，而不是按当前牌数缩放；购牌和产出不会令所有卡突然变小。
const WORLD_RECT := Rect2(-10.8, -5.25, 21.6, 11.3)
## 初始镜头按实际牌区构图；操作边界另从屏幕反投影，避免历史空矩形缩小牌面。
const FRAMING_RECT := Rect2(-9.7, -5.15, 19.4, 11.0)
## 取景只预留静置牌摞高度；拖拽抬起另由 _clamp_visible_stack 限制，不把整桌当成高盒子。
const FRAMING_REST_HEIGHT := 0.5
const PLAYER_RECT := Rect2(-10.0, 1.2, 20.0, 4.5)
const PAD := 16.0
## 抽屉 UI 的统一设计令牌。所有设置页、按钮和菜单都从这里取值，
## 这样窗口变大时只调整一次，不会出现「入口大小很大、BOT 强度很小」的混搭。
const UI_FONT_BODY := 17
const UI_FONT_SMALL := 15
const UI_FONT_TITLE := 21
const UI_BUTTON_MIN := Vector2(112, 42)
const UI_RADIUS := 10
const PERSPECTIVE_MIN_ANGLE := 45.0
const PERSPECTIVE_MAX_ANGLE := 80.0

var _main: Node
var _header: PanelContainer
var _footer: PanelContainer
var _header_rows: VBoxContainer
var _resources: HBoxContainer
var _icon_group: HBoxContainer
var _title_row: HBoxContainer
var _mascot_state := ""
var _menu: MenuButton
var _sound_button: Button
var _handle: DrawerMascot
var _pin: Button
var _utility: PanelContainer
var _utility_title: Label
var _utility_body: VBoxContainer
var _rulebook_button: Button
## 底栏角色按钮：显示这一局本方的角色，点开向上弹出角色面板（README.md §「2.12 角色」）。
## 按钮上念短名（「牛马」「产品经理」），面板标题和列表念全名「我是XXX」：
## 底栏一行贴着窗口宽，短名让 667 宽的横屏手机也放得下全部角色
var _role_button: Button
var _role_popup: PopupPanel
var _role_detail_title: Label
var _role_detail_text: Label
var _end_tutorial_button: Button
var _tutorial_resign_visible := false
var _utility_scroll: ScrollContainer
var _ui_footer: HBoxContainer
var _ui_status: Label
var _active_utility_id := -1
var _rulebook: Control
var _learning_invitation: PanelContainer
var _invitation_layer: CanvasLayer
var _invitation_scrim: ColorRect
var _invitation_offered := false
var _learning_focus := false
var tutorial: Control
var _tutorial_context: RefCounted
var _tearing_down := false
var _palette: Control
var _bot: Control
var _detail: PanelContainer
var _detail_title: Label
var _detail_text: Label
var _detail_flavor: Label
var _detail_status: Label
var _detail_facts: GridContainer
var _detail_effect: Label
var _detail_scroll: ScrollContainer
var _detail_id := ""
var _detail_market := false
var _detail_source_signature: Array = []
var _detail_layout_signature: Array = []
var _preview_detail_source: WeakRef
var _preview_detail_card: WeakRef
var _ui_icon_cache: Dictionary = {}
var _content := Rect2()
var _last_size := Vector2.ZERO
var _viewport_pixels := Vector2.ZERO
var _ui_scale := 1.0
var _collapsed := false
var _table_ui_suspended := false
var _external_panels: Array[CanvasLayer] = []
var _learning_hidden_panels: Array[Node] = []
var _relayout_running := false
var _suspended_panels: Array[Node] = []
var perspective_angle: float
var _perspective_slider: HSlider
var _perspective_value: Label
var camera_view := CameraView.new()
var _zoom_slider: HSlider
var _zoom_value: Label
var _hover_speed_slider: HSlider
var _hover_speed_value: Label
var _screen_shake_slider: HSlider
var _screen_shake_value: Label
var _card_config_status: Label
var _card_config_path: LineEdit
var _card_config_drop: PanelContainer


func _init(config_path: String = "") -> void:
	var defaults := UIConfig.read_defaults(config_path)
	perspective_angle = defaults["perspective_angle"]
	camera_view.zoom = defaults["table_zoom"]

func _window_blocked() -> bool:
	return _main.drawer_window != null and (not _main.drawer_window.is_expanded() or _main.drawer_window.is_transitioning())

func bind(main: Node) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = main
	_ui_scale = _main.drawer_ui_scale
	scale = Vector2.ONE
	_viewport_pixels = get_viewport().get_visible_rect().size
	_last_size = _viewport_pixels
	layer = 4
	name = "DrawerPresentation"
	_main.board.table_bounds = WORLD_RECT
	_main.board.player_bounds = PLAYER_RECT
	_main.board.player_min_z = PLAYER_RECT.position.y
	_main.board.player_max_z = PLAYER_RECT.end.y
	_main.board.hover_description_enabled = false
	_build_header()
	_build_footer()
	_build_utility()
	_build_details()
	TutorialProgress.settle_returning_player()
	_build_learning_invitation()
	for panel in [_header, _footer, _detail, _main.table_hud]:
		_guard_table_panel(panel, false)
	for panel in [_utility, _main.msg_log]:
		_guard_table_panel(panel, true)
	if _main.save_notice:
		_register_external_panel(_main.save_notice)
	if _main.drawer_window != null:
		_handle = Mascot.new()
		_handle.delegate_pointer = true
		_handle.setup(_main.drawer_window.get_handle_texture())
		_handle.set_render_scale(_main.drawer_window.get_handle_scale())
		_handle.activated.connect(_main.drawer_window.activate_handle)
		_handle.pointer_pressed.connect(_main.drawer_window.handle_press)
		_handle.pointer_moved.connect(func(_p: Vector2): _main.drawer_window.handle_move())
		_handle.pointer_released.connect(_main.drawer_window.handle_release)
		_handle.hide()
		add_child(_handle)
		_handle.set_first_run_hint(not TutorialProgress.handle_opened())
		_main.drawer_window.handle_hovered.connect(_handle.set_hovered)
		_main.drawer_window.handle_size_changed.connect(_on_handle_size_changed)
		_main.drawer_window.attention_requested.connect(_handle.greet)
		_main.drawer_window.pinned_changed.connect(func(_pinned: bool): _refresh_pin_button())
	relayout()
	get_viewport().size_changed.connect(_on_size_changed)
	_main.child_entered_tree.connect(_on_main_child_entered)
	call_deferred("relayout")

## 所有 Control 保持单位变换。DPI 与窗口档位只影响实际字号和布局像素，
## 不再放大小字号字形纹理。设置页、联网、记录和录像通知共用这一套。
func _responsive_factor() -> float:
	if _main != null and (_main.mobile_mode or _main.web_mode):
		return maxf(0.55, minf(_last_size.y / 540.0, _last_size.x / 960.0))
	var logical := _last_size / maxf(_ui_scale, 1.0)
	var ratio := minf(logical.x / 1280.0, logical.y / 800.0) if logical.x > 0 else 1.0
	return _ui_scale * clampf(ratio, 0.85, 1.15)

func _px(value: float) -> float:
	return roundf(value * _responsive_factor())

func _vec(value: Vector2) -> Vector2:
	return (value * _responsive_factor()).round()

func _responsive_font(base: int) -> int:
	return maxi(12, roundi(float(base) * _responsive_factor()))

func _style(fill: Color, margin := 12, border := -1, border_color: Color = Color.MAGENTA) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = Palette.get_color("card", "frame") if border_color == Color.MAGENTA else border_color
	style.set_border_width_all(maxi(1, roundi(_px(1 if border < 0 else border))))
	style.set_corner_radius_all(roundi(_px(UI_RADIUS)))
	style.set_content_margin_all(roundi(_px(margin)))
	return style

func _label(text: String, font_size := UI_FONT_BODY) -> Label:
	var label := Label.new()
	label.text = text
	label.set_meta("drawer_font_base", font_size)
	label.add_theme_font_override("font", Fonts.zh_bold() if font_size >= UI_FONT_TITLE else Fonts.zh())
	label.add_theme_font_size_override("font_size", _responsive_font(font_size))
	label.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	return label

func _button(text: String, font_size := UI_FONT_BODY, compact := false) -> Button:
	var button := Button.new()
	button.text = text
	button.set_meta("drawer_font_base", font_size)
	button.set_meta("drawer_compact", compact)
	_apply_button_theme(button, font_size)
	return button

func _ui_icon(kind: String) -> Texture2D:
	if _ui_icon_cache.has(kind):
		return _ui_icon_cache[kind]
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var ink := Color.WHITE
	match kind:
		"gear":
			_draw_polyline(image, _gear_points(), 7, ink, true)
			_draw_circle(image, Vector2(64, 64), 23, 7, ink)
		"pin", "pin_on":
			_draw_pin(image, kind == "pin_on", ink)
		"sound_on", "sound_off":
			_draw_polyline(image, [Vector2(16, 51), Vector2(37, 51), Vector2(61, 31), Vector2(61, 97), Vector2(37, 77), Vector2(16, 77), Vector2(16, 51)], 7, ink, false)
			if kind == "sound_off":
				_draw_line(image, Vector2(73, 40), Vector2(111, 88), 7, ink)
				_draw_line(image, Vector2(111, 40), Vector2(73, 88), 7, ink)
			else:
				_draw_polyline(image, [Vector2(76, 41), Vector2(91, 51), Vector2(91, 77), Vector2(76, 87)], 7, ink, false)
				_draw_polyline(image, [Vector2(94, 29), Vector2(111, 43), Vector2(111, 85), Vector2(94, 99)], 7, ink, false)
	var texture := ImageTexture.create_from_image(image)
	_ui_icon_cache[kind] = texture
	return texture

## 用轮廓、方向和勾区分状态，避免无边框按钮只靠颜色表达是否钉住。
func _draw_pin(image: Image, pinned: bool, ink: Color) -> void:
	var head: Array[Vector2] = [Vector2(42, 17), Vector2(86, 17), Vector2(82, 44), Vector2(96, 58), Vector2(96, 69), Vector2(32, 69), Vector2(32, 58), Vector2(46, 44)]
	var stem := Vector2(64, 69)
	var tip := Vector2(64, 112)
	if pinned:
		var polygon := PackedVector2Array(head)
		for y in range(17, 70):
			for x in range(32, 97):
				if Geometry2D.is_point_in_polygon(Vector2(x, y), polygon):
					image.set_pixel(x, y, ink)
		_draw_polyline(image, [Vector2(82, 94), Vector2(93, 105), Vector2(113, 81)], 8, ink)
	else:
		var center := Vector2(64, 64)
		var angle := deg_to_rad(32.0)
		for i in head.size():
			head[i] = center + (head[i] - center).rotated(angle)
		stem = center + (stem - center).rotated(angle)
		tip = center + (tip - center).rotated(angle)
	_draw_polyline(image, head, 7, ink, true)
	_draw_line(image, stem, tip, 7, ink)

func _gear_points() -> Array[Vector2]:
	var points: Array[Vector2] = []
	for i in 32:
		var angle := -PI * 0.5 + float(i) * TAU / 32.0
		var radius := 51.0 if i % 4 in [0, 1] else 36.0
		points.append(Vector2(64, 64) + Vector2(cos(angle), sin(angle)) * radius)
	return points

func _plot(image: Image, point: Vector2, width: int, color: Color) -> void:
	var radius := maxi(1, width / 2)
	var center := Vector2i(roundi(point.x), roundi(point.y))
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			if x * x + y * y <= radius * radius:
				var px := center.x + x
				var py := center.y + y
				if px >= 0 and py >= 0 and px < image.get_width() and py < image.get_height():
					image.set_pixel(px, py, color)

func _draw_line(image: Image, from: Vector2, to: Vector2, width: int, color: Color) -> void:
	var distance := from.distance_to(to)
	var steps := maxi(1, ceili(distance * 2.0))
	for i in steps + 1:
		_plot(image, from.lerp(to, float(i) / float(steps)), width, color)

func _draw_polyline(image: Image, points: Array[Vector2], width: int, color: Color, closed := false) -> void:
	if points.size() < 2:
		return
	for i in points.size() - 1:
		_draw_line(image, points[i], points[i + 1], width, color)
	if closed:
		_draw_line(image, points[-1], points[0], width, color)

func _draw_circle(image: Image, center: Vector2, radius: float, width: int, color: Color) -> void:
	var points: Array[Vector2] = []
	for i in 65:
		var angle := float(i) * TAU / 64.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	_draw_polyline(image, points, width, color, false)

func _install_icon_visual(button: Button, texture: Texture2D) -> void:
	var visual := TextureRect.new()
	visual.name = "IconGlyph"
	visual.texture = texture
	visual.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	visual.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visual.custom_minimum_size = Vector2.ZERO
	visual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	visual.size_flags_vertical = Control.SIZE_EXPAND_FILL
	visual.modulate = Palette.icon_color(Palette.get_color("card", "body"))
	visual.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visual.offset_left = 4.0
	visual.offset_top = 4.0
	visual.offset_right = -4.0
	visual.offset_bottom = -4.0
	button.add_child(visual)

func _apply_icon_button_theme(button: Button, minimum: Vector2) -> void:
	button.text = ""
	button.add_theme_font_override("font", Fonts.zh())
	button.add_theme_font_size_override("font_size", _responsive_font(UI_FONT_BODY))
	button.custom_minimum_size = _vec(minimum.max(Vector2(44, 44)) if _main.mobile_mode else minimum)
	button.expand_icon = true
	button.flat = true
	button.set_meta("drawer_icon_button", true)
	button.focus_mode = Control.FOCUS_ALL
	var empty := StyleBoxEmpty.new()
	button.add_theme_stylebox_override("normal", empty)
	button.add_theme_stylebox_override("hover", empty)
	button.add_theme_stylebox_override("pressed", empty)
	button.add_theme_stylebox_override("hover_pressed", empty)
	button.add_theme_stylebox_override("disabled", empty)
	button.add_theme_stylebox_override("focus", empty)
	button.add_theme_color_override("icon_normal_color", Palette.icon_color(Palette.get_color("card", "body")))
	button.add_theme_color_override("icon_hover_color", Palette.icon_color(Palette.get_color("card", "body")))
	var icon_ink := Palette.icon_color(Palette.get_color("card", "body"))
	button.add_theme_color_override("icon_normal_color", icon_ink)
	button.add_theme_color_override("icon_hover_color", icon_ink)
	button.add_theme_color_override("icon_pressed_color", icon_ink)
	button.add_theme_color_override("icon_hover_pressed_color", icon_ink)
	button.add_theme_color_override("icon_focus_color", icon_ink)
	button.add_theme_color_override("icon_disabled_color", icon_ink)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func _apply_button_theme(button: Button, base_size := UI_FONT_BODY) -> void:
	button.add_theme_font_override("font", Fonts.zh())
	button.add_theme_font_size_override("font_size", _responsive_font(base_size))
	if button.get_meta("drawer_primary", false):
		button.set_meta("ui_role", "primary")
	var margin := 5 if button.get_meta("drawer_compact", false) else 9
	var min_height := 30 if button.get_meta("drawer_compact", false) else 38
	UIButtonTheme.apply(button, _responsive_factor(), margin, UI_RADIUS)
	if not button.has_meta("drawer_min_base"):
		button.set_meta("drawer_min_base", Vector2(0, min_height))
	var base: Vector2 = button.get_meta("drawer_min_base")
	button.custom_minimum_size = _vec(base.max(Vector2(0, 44)) if _main.mobile_mode else base)

func refresh_button_roles() -> void:
	for button in [_main.btn_net, _main.btn_save, _main.btn_resign, _main.btn_pass]:
		if is_instance_valid(button):
			_apply_button_theme(button, int(button.get_meta("drawer_font_base", UI_FONT_BODY)))

func set_mascot_state(state: String) -> void:
	_mascot_state = state.to_lower()
	if is_instance_valid(_handle):
		_handle.set_state(_mascot_state)

func _apply_tree_theme(root: Control) -> void:
	if root == null or root is DrawerMascot:
		return
	root.scale = Vector2.ONE
	if not root.has_meta("drawer_min_base"):
		root.set_meta("drawer_min_base", root.custom_minimum_size)
	root.custom_minimum_size = _vec(root.get_meta("drawer_min_base"))
	var ink := Palette.get_color("card", "body")
	if root is Button:
		if root.get_meta("drawer_icon_button", false):
			_apply_icon_button_theme(root, root.get_meta("drawer_min_base", Vector2(38, 34)))
		else:
			_apply_button_theme(root, int(root.get_meta("drawer_font_base", UI_FONT_BODY)))
		if root is MenuButton or root is OptionButton:
			_style_popup(root.get_popup())
	elif root is Label:
		var default_base := UI_FONT_TITLE if root.text in ["局域网对战", "配色", "BOT 强度", "UI", "入口大小", "选项"] else UI_FONT_BODY
		var base := int(root.get_meta("drawer_font_base", default_base))
		root.add_theme_font_override("font", Fonts.zh_bold() if base >= UI_FONT_TITLE else Fonts.zh())
		root.add_theme_font_size_override("font_size", _responsive_font(base))
		var text_ink: Color = root.get_meta("drawer_ink", ink)
		if root == _main.lbl_msg:
			text_ink = Palette.readable_ink(root.get_meta("message_color", ink), Palette.get_color("world", "table_frame"))
		root.add_theme_color_override("font_color", text_ink)
		root.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
		root.add_theme_constant_override("outline_size", 0)
	elif root is RichTextLabel:
		for key in ["normal_font", "italics_font", "mono_font"]:
			root.add_theme_font_override(key, Fonts.zh())
		root.add_theme_font_override("bold_font", Fonts.zh_bold())
		for key in ["normal_font_size", "bold_font_size", "italics_font_size", "mono_font_size"]:
			root.add_theme_font_size_override(key, _responsive_font(UI_FONT_BODY))
		root.add_theme_color_override("default_color", ink)
	elif root is PanelContainer:
		root.add_theme_stylebox_override("panel", _style(root.get_meta("drawer_surface", Palette.get_color("world", "table_frame")), int(root.get_meta("drawer_margin_base", 10))))
	elif root is SpinBox:
		_apply_tree_theme(root.get_line_edit())
	elif root is LineEdit:
		root.add_theme_font_override("font", Fonts.zh())
		root.add_theme_font_size_override("font_size", _responsive_font(UI_FONT_BODY))
		root.add_theme_color_override("font_color", ink)
		root.add_theme_color_override("font_uneditable_color", ink)
		root.add_theme_color_override("caret_color", ink)
		root.add_theme_color_override("font_placeholder_color", Color(ink, 0.6))
		root.add_theme_stylebox_override("normal", _style(Palette.plate_color("plate_t3", "face"), 8))
		root.add_theme_stylebox_override("read_only", _style(Palette.plate_color("plate_t3", "face"), 8))
		root.add_theme_stylebox_override("focus", _style(Palette.plate_color("plate_cash", "face"), 8, 2))
	elif root is SpinBox:
		# 数值输入框是 SpinBox 的内部子节点，普通 get_children() 遍历不到。
		# 必须一起设真实字号，否则 BOT 页只有数字仍是默认小字和灰色底。
		_apply_tree_theme(root.get_line_edit())
	elif root is HSlider or root is VSlider:
		var track := _style(Palette.get_color("world", "background"), 2)
		root.add_theme_stylebox_override("slider", track)
		root.add_theme_stylebox_override("grabber_area", _style(Palette.plate_color("plate_cash", "band"), 2))
		root.add_theme_stylebox_override("grabber_area_highlight", _style(Palette.plate_color("plate_cash", "face"), 2))
	for key in ["separation", "h_separation", "v_separation"]:
		if root.has_theme_constant_override(key):
			var meta: String = "drawer_gap_" + str(key)
			if not root.has_meta(meta):
				root.set_meta(meta, root.get_theme_constant(key))
			root.add_theme_constant_override(key, roundi(_px(root.get_meta(meta))))
	for child in root.get_children():
		if child is Control:
			_apply_tree_theme(child)
		elif child is PopupMenu:
			_style_popup(child)

func _style_popup(popup: PopupMenu) -> void:
	popup.add_theme_font_override("font", Fonts.zh())
	popup.add_theme_font_size_override("font_size", _responsive_font(UI_FONT_BODY))
	popup.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	popup.add_theme_color_override("font_hover_color", Palette.get_color("card", "body"))
	popup.add_theme_constant_override("v_separation", roundi(_px(10)))
	popup.add_theme_constant_override("h_separation", roundi(_px(10)))
	popup.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame"), 8))
	popup.add_theme_stylebox_override("hover", _style(Palette.plate_color("plate_cash", "face"), 6))
	popup.add_theme_stylebox_override("hovered", _style(Palette.plate_color("plate_cash", "face"), 6))

func _adopt(control: Control, parent: Node) -> void:
	control.reparent(parent)
	control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	control.position = Vector2.ZERO
	control.custom_minimum_size = Vector2.ZERO
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER

func _build_header() -> void:
	var old_panel: Control = _main.lbl_round.get_parent().get_parent()
	_header = PanelContainer.new()
	_header.name = "DrawerHeader"
	_header.set_meta("drawer_margin_base", 6)
	_header.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame"), 6))
	add_child(_header)
	_header_rows = VBoxContainer.new()
	_header_rows.add_theme_constant_override("separation", 4)
	_header.add_child(_header_rows)
	var title_row := HBoxContainer.new()
	_title_row = title_row
	title_row.add_theme_constant_override("separation", 4)
	_header_rows.add_child(title_row)
	var brand := TextureRect.new()
	brand.name = "BrandMascot"
	brand.texture = load("res://assets/app_icon.png")
	brand.custom_minimum_size = Vector2(32, 32)
	brand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	brand.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.add_child(brand)
	title_row.add_child(_label("牛马牌", 24))
	_adopt(_main.lbl_round, title_row)
	_main.lbl_round.set_meta("drawer_font_base", UI_FONT_BODY)
	# 先手/阶段信息按字体实测宽度占位；资源栏只能使用剩余空间。
	_main.lbl_round.clip_text = false
	_main.lbl_round.autowrap_mode = TextServer.AUTOWRAP_OFF
	_main.lbl_round.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_main.lbl_round.add_theme_font_size_override("font_size", 17)
	_main.lbl_round.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	_icon_group = HBoxContainer.new()
	_icon_group.name = "HeaderIconGroup"
	_icon_group.add_theme_constant_override("separation", 4)
	_icon_group.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_icon_group)
	_menu = MenuButton.new()
	_menu.text = ""
	_menu.icon = null
	_install_icon_visual(_menu, _ui_icon("gear"))
	_menu.tooltip_text = "选项"
	_menu.accessibility_name = "选项"
	_menu.set_meta("drawer_compact", true)
	_menu.set_meta("drawer_min_base", Vector2(30, 30))
	_apply_icon_button_theme(_menu, Vector2(30, 30))
	var popup := _menu.get_popup()
	_style_popup(popup)
	for entry in UTILITY_PAGES:
		if _main.drawer_window == null and int(entry[0]) == 4:
			continue
		popup.add_item(str(entry[1]), int(entry[0]))
	_menu.get_popup().id_pressed.connect(_open_utility)
	_icon_group.add_child(_menu)
	_sound_button = _button("", UI_FONT_BODY, true)
	_sound_button.name = "SoundToggle"
	_sound_button.set_meta("drawer_min_base", Vector2(30, 30))
	_sound_button.toggle_mode = true
	_install_icon_visual(_sound_button, _ui_icon("sound_on"))
	_apply_icon_button_theme(_sound_button, Vector2(30, 30))
	_sound_button.pressed.connect(_toggle_sound)
	_icon_group.add_child(_sound_button)
	_main.sfx.user_muted_changed.connect(func(_muted: bool): _refresh_sound_button())
	_refresh_sound_button()
	if _main.drawer_window != null:
		_pin = _button("", UI_FONT_BODY, true)
		_pin.name = "PinToggle"
		_pin.set_meta("drawer_min_base", Vector2(30, 30))
		_pin.icon = null
		_install_icon_visual(_pin, _ui_icon("pin"))
		_pin.toggle_mode = true
		_apply_icon_button_theme(_pin, Vector2(30, 30))
		_pin.toggled.connect(func(pinned: bool):
			_main.drawer_window.set_pinned(pinned)
			_refresh_pin_button())
		_icon_group.add_child(_pin)
		_refresh_pin_button()
	_resources = HBoxContainer.new()
	_resources.add_theme_constant_override("separation", 8)
	_resources.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	title_row.add_child(_resources)
	for source in [_main.lbl_player_res, _main.lbl_bot_res]:
		var cell := PanelContainer.new()
		cell.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		cell.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "background"), 6))
		cell.set_meta("drawer_surface", Palette.get_color("world", "background"))
		cell.set_meta("drawer_margin_base", 6)
		_resources.add_child(cell)
		source.set_meta("drawer_ink", Palette.get_color("hud", "player" if source == _main.lbl_player_res else "bot"))
		_adopt(source, cell)
		source.add_theme_font_override("font", Fonts.zh_bold())
		source.add_theme_font_size_override("font_size", 16)
		source.autowrap_mode = TextServer.AUTOWRAP_OFF
		source.clip_text = true
		source.custom_minimum_size.y = 0
		source.set_meta("drawer_font_base", UI_FONT_SMALL)
		source.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		source.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 当前提示不再作为 header 第二行；它会被放进底栏的单行状态位，避免长提示把牌桌整体下压。
	_main.lbl_msg.visible = true
	old_panel.queue_free()

func _toggle_sound() -> void:
	if _main == null or _main.sfx == null:
		return
	if not _main.sfx.set_user_muted(not _main.sfx.user_muted):
		_main._show_message("声音设置已临时生效，但保存失败；下次启动可能恢复原设置。", Palette.semantic("warning"))
	_refresh_sound_button()

func _refresh_sound_button() -> void:
	if not is_instance_valid(_sound_button):
		return
	var muted: bool = _main != null and _main.sfx != null and _main.sfx.user_muted
	_sound_button.set_pressed_no_signal(not muted)
	_sound_button.text = ""
	_sound_button.icon = null
	var sound_visual: TextureRect = _sound_button.find_child("IconGlyph", true, false)
	if sound_visual:
		sound_visual.texture = _ui_icon("sound_off" if muted else "sound_on")
	_sound_button.tooltip_text = "打开声音" if muted else "关闭声音"
	_sound_button.accessibility_name = _sound_button.tooltip_text
	_sound_button.set_meta("sound_muted", muted)

func _refresh_pin_button() -> void:
	if not is_instance_valid(_pin):
		return
	var pinned: bool = _main.drawer_window.is_pinned()
	_pin.set_pressed_no_signal(pinned)
	var visual: TextureRect = _pin.find_child("IconGlyph", true, false)
	if visual:
		visual.texture = _ui_icon("pin_on" if pinned else "pin")
		visual.modulate = Palette.icon_color(Palette.get_color("card", "body"))
	_pin.tooltip_text = "已钉住，点击取消" if pinned else "钉住"
	_pin.accessibility_name = _pin.tooltip_text

## 首次邀请是一生一次的模态选择：压暗整张牌桌并挡住全部桌面输入，玩家必须二选一。
## 独立画布层高于提示记录、通知和终局层；面板本身仍走原来的收起暂存与展开恢复。
func _build_learning_invitation() -> void:
	_invitation_offered = TutorialProgress.invitation_seen()
	_invitation_layer = CanvasLayer.new()
	_invitation_layer.name = "FirstPlayInvitationLayer"
	_invitation_layer.layer = 21
	add_child(_invitation_layer)
	_invitation_scrim = ColorRect.new()
	_invitation_scrim.name = "InvitationScrim"
	_invitation_scrim.color = Color(Palette.semantic("ink"), 0.5)
	_invitation_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_invitation_scrim.hide()
	_invitation_layer.add_child(_invitation_scrim)
	_learning_invitation = PanelContainer.new()
	_learning_invitation.name = "FirstPlayInvitation"
	_learning_invitation.custom_minimum_size = Vector2(420, 0)
	_learning_invitation.set_meta("drawer_surface", Palette.semantic("surface"))
	_learning_invitation.set_meta("drawer_margin_base", 20)
	_invitation_layer.add_child(_learning_invitation)
	_learning_invitation.visibility_changed.connect(func(): _invitation_scrim.visible = _learning_invitation.visible)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_learning_invitation.add_child(column)
	var mascot := ResultFx.MascotPose.new()
	mascot.set_pose("idle")
	mascot.custom_minimum_size = Vector2(72, 72)
	mascot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(mascot)
	var title := _label(TutorialCatalog.ui("hub.invitation"), UI_FONT_TITLE)
	title.name = "InvitationTitle"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var body := _label(TutorialCatalog.ui("hub.invitation_body"))
	body.name = "InvitationBody"
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(body)
	var actions := HFlowContainer.new()
	actions.alignment = FlowContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("h_separation", 12)
	actions.add_theme_constant_override("v_separation", 8)
	column.add_child(actions)
	var start := _button(TutorialCatalog.ui("hub.invitation_start"))
	start.name = "InvitationStart"
	start.set_meta("ui_role", "primary")
	start.pressed.connect(func():
		_dismiss_learning_invitation("tutorial")
		var courses := TutorialCatalog.courses()
		if not courses.is_empty():
			start_tutorial(str(courses[0]["id"])))
	actions.add_child(start)
	var skip := _button(TutorialCatalog.ui("hub.invitation_skip"))
	skip.name = "InvitationSkip"
	skip.pressed.connect(_dismiss_learning_invitation.bind("skip"))
	actions.add_child(skip)
	_learning_invitation.hide()
	_guard_table_panel(_learning_invitation, true)
	_apply_tree_theme(_learning_invitation)

func _dismiss_learning_invitation(choice: String) -> void:
	_invitation_offered = true
	_suspended_panels.erase(_learning_invitation)
	_learning_invitation.hide()
	if not TutorialProgress.dismiss_invitation(choice):
		_main._show_message(TutorialCatalog.ui("hub.save_failed"), Palette.semantic("warning"))

func _offer_learning_invitation() -> void:
	if not _invitation_offered:
		if panels_open() or not _main.can_begin_tutorial():
			return
		_invitation_offered = true
		_learning_invitation.show()
		# 键盘玩家直接按 Enter 即可跟教程；面板外的点击都被压暗层吃掉。
		_learning_invitation.find_child("InvitationStart", true, false).grab_focus.call_deferred()
	if _learning_invitation.visible:
		var viewport := get_viewport().get_visible_rect().size
		_invitation_scrim.position = Vector2.ZERO
		_invitation_scrim.size = viewport
		_learning_invitation.size = _learning_invitation.get_combined_minimum_size()
		_learning_invitation.position = ((viewport - _learning_invitation.size) * 0.5).max(Vector2.ZERO).round()

func is_learning_invitation_open() -> bool:
	return is_instance_valid(_learning_invitation) and _learning_invitation.is_visible_in_tree()

## 首次邀请选了直接开局、从没开过课程的玩家，第一次输掉单机局时在结算页补一次教程入口；只出现这一次。
func add_post_game_tutorial(body: VBoxContainer) -> void:
	if not TutorialProgress.wants_post_game_nudge():
		return
	TutorialProgress.mark_post_game_nudged()
	var learn := _button(TutorialCatalog.ui("hub.post_game_nudge"))
	learn.name = "ResultTutorial"
	learn.pressed.connect(func():
		var courses := TutorialCatalog.courses()
		if not courses.is_empty():
			start_tutorial(str(courses[0]["id"])))
	body.add_child(learn)

## 课程在原牌桌上进行；规则页仅负责选择课程，不再承载第二张牌桌。
func start_tutorial(id: String) -> bool:
	if TutorialCatalog.course(id).is_empty():
		return false
	if is_instance_valid(tutorial):
		close_panels()
		return tutorial.switch_course(id)
	var scope := TutorialContext.new()
	if not scope.begin(_main):
		return false
	set_learning_focus(true)
	close_panels()
	_learning_invitation.hide()
	_tutorial_context = scope
	tutorial = load("res://scenes/tutorial_player.gd").new()
	add_child(tutorial)
	tutorial.exited.connect(finish_tutorial)
	tutorial.progress_changed.connect(_record_tutorial_progress)
	tutorial.course_completed.connect(func(course_id: String):
		_record_tutorial_progress(course_id, TutorialCatalog.course(course_id).get("steps", []).size(), "completed"))
	tutorial.layout_requested.connect(func(): relayout.call_deferred())
	_guard_table_panel(tutorial, true)
	_record_tutorial_progress(id, 0, "started")
	tutorial.bind(self, id)
	_tutorial_resign_visible = _main.btn_resign.visible
	_main.btn_resign.hide()
	_end_tutorial_button.show()
	_refresh_role_button()
	relayout()
	return true

func finish_tutorial(show_courses := false) -> void:
	if not is_instance_valid(tutorial) and _tutorial_context == null:
		return
	var player := tutorial
	tutorial = null
	if is_instance_valid(_end_tutorial_button):
		_end_tutorial_button.hide()
	_refresh_role_button()
	if not _tearing_down:
		close_panels()
	if is_instance_valid(player):
		_suspended_panels.erase(player)
		player.process_mode = Node.PROCESS_MODE_DISABLED
		if not _tearing_down:
			player.hide()
	if _tutorial_context != null:
		_tutorial_context.release(_tearing_down)
		_tutorial_context = null
	if not _tearing_down:
		_main.btn_resign.visible = _tutorial_resign_visible
		set_learning_focus(false)
	if is_instance_valid(player):
		player.queue_free()
	if not _tearing_down and is_inside_tree() and is_instance_valid(_main) and not _main.is_queued_for_deletion():
		relayout()
		if show_courses:
			_open_utility(UTILITY_RULEBOOK)

func _record_tutorial_progress(id: String, step: int, status: String) -> void:
	if not TutorialProgress.record(id, step, status):
		_main._show_message(TutorialCatalog.ui("hub.save_failed"), Palette.semantic("warning"))

func _input(event: InputEvent) -> void:
	if is_instance_valid(tutorial) and event is InputEventKey and event.pressed \
		and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		finish_tutorial()

func _exit_tree() -> void:
	_tearing_down = true
	finish_tutorial(false)

func _layout_tutorial(available: Rect2) -> void:
	# 对话只是牌桌上的浮层，不能改变相机取景区或牌桌可操作边界。
	tutorial.place_in(available)

func _build_footer() -> void:
	_footer = PanelContainer.new()
	_footer.name = "DrawerFooter"
	_footer.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame"), 10))
	add_child(_footer)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_footer.add_child(row)
	# 存录像从底栏移到“选项”，给牌桌留下完整高度。按钮对象仍保留，
	# 这样 F5 和既有自动化测试继续复用 main._save_replay。
	_main.btn_save.hide()
	_main.btn_net.hide()
	_main.btn_net.visibility_changed.connect(func():
		if _main.btn_net.visible:
			_main.btn_net.hide())
	for source in [_main.btn_resign]:
		_adopt(source, row)
		source.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		source.custom_minimum_size = Vector2(120, 44)
		source.add_theme_font_size_override("font_size", 17)
	_adopt(_main.lbl_msg, row)
	_main.lbl_msg.set_meta("drawer_font_base", UI_FONT_SMALL)
	_main.lbl_msg.add_theme_font_size_override("font_size", _responsive_font(UI_FONT_SMALL))
	_main.lbl_msg.autowrap_mode = TextServer.AUTOWRAP_OFF
	_main.lbl_msg.clip_text = true
	_main.lbl_msg.max_lines_visible = 1
	_main.lbl_msg.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_main.lbl_msg.mouse_filter = Control.MOUSE_FILTER_PASS
	_main.lbl_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main.lbl_msg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_main.lbl_msg.custom_minimum_size = Vector2.ZERO
	_main.lbl_msg.tooltip_text = ""
	_build_role_button(row)
	_rulebook_button = _button(TutorialCatalog.ui("hub.title"))
	_rulebook_button.name = "RulebookButton"
	_rulebook_button.pressed.connect(_open_utility.bind(UTILITY_RULEBOOK))
	row.add_child(_rulebook_button)
	_end_tutorial_button = _button(TutorialCatalog.ui("hub.end_tutorial"))
	_end_tutorial_button.name = "EndTutorialButton"
	_end_tutorial_button.pressed.connect(finish_tutorial)
	row.add_child(_end_tutorial_button)
	_end_tutorial_button.hide()
	_adopt(_main.btn_pass, row)
	_main.btn_pass.size_flags_horizontal = Control.SIZE_SHRINK_END
	_main.btn_pass.custom_minimum_size = Vector2(210, 44)
	_main.btn_pass.set_meta("drawer_primary", true)
	_main.btn_pass.set_meta("drawer_font_base", UI_FONT_BODY)
	_main.btn_pass.add_theme_font_size_override("font_size", 23)
	_main.msg_log.hide()
	_main.msg_log.scale = Vector2.ONE
	_main.msg_log._frame.minimum_size_changed.connect(_position_log)

func _build_role_button(row: HBoxContainer) -> void:
	_role_button = _button(Roles.tag(Roles.DEFAULT))
	_role_button.name = "RoleButton"
	_role_button.pressed.connect(_show_role_popup)
	row.add_child(_role_button)
	# 用 PopupPanel 而不是 PopupMenu：菜单项只能挂原生 tooltip，角色说明要和
	# 卡牌详情、设置页一样用抽屉自己的面板与字号来排
	_role_popup = PopupPanel.new()
	_role_popup.name = "RolePopup"
	_role_button.add_child(_role_popup)
	_refresh_role_button()

## 按钮念的是**这一局**本方坐的角色。教程里牌桌换成了教学局面（双方默认角色），
## 按钮仍念玩家自己的选择 —— 教程结束回到的是那一局
func _active_role() -> String:
	if is_instance_valid(tutorial) or _main.state == null:
		return RolePref.selected()
	return _main.state.role_of(_main.my_seat)

## 联网、录像、教程中都不能换角色：联网双方固定默认角色，录像和教程不是可以重开的单机局
func _role_lock_reason() -> String:
	var info: Dictionary = _main.role_info()
	if bool(info["replay_locked"]):
		return "正在播放录像；退出录像后才能切换角色"
	if bool(info["network_locked"]):
		return "联网对局双方固定为「%s」" % Roles.role_name(Roles.DEFAULT)
	if is_instance_valid(tutorial):
		return "教程中不能切换角色"
	return ""

func _refresh_role_button() -> void:
	if not is_instance_valid(_role_button):
		return
	var role := _active_role()
	var text := Roles.tag(role)
	if _role_button.text != text:
		_role_button.text = text
	_role_button.accessibility_name = "角色：" + Roles.role_name(role)
	var lock := _role_lock_reason()
	_role_button.disabled = lock != ""
	# 只留短提示（和「选项」「钉住」这些按钮一样）；角色效果在弹出的面板里看
	_role_button.tooltip_text = lock
	if _menu != null:
		var index := _menu.get_popup().get_item_index(UTILITY_ROLE)
		if index >= 0:
			_menu.get_popup().set_item_text(index, "角色：" + text)
			_menu.get_popup().set_item_disabled(index, lock != "")

## 底栏放得下才显示角色按钮。游戏只按横屏设计，短名在 667 宽以上的横屏都放得下；
## 这里兜的是更小的横屏和 Web 被竖着拿的情况：放不下时按钮藏起来，免得把「完成行动」
## 挤出屏幕，同一个角色面板改由选项菜单里的「角色：XXX」打开。教程里按钮本来就锁着，直接不占位
func _fit_role_button(width: float) -> void:
	if not is_instance_valid(_role_button):
		return
	var spare := _footer_room(width) - _role_button.get_combined_minimum_size().x \
		- float(_role_button.get_parent().get_theme_constant("separation"))
	var fits := not is_instance_valid(tutorial) and spare >= _px(ROLE_MESSAGE_MIN)
	_role_button.visible = fits
	var popup := _menu.get_popup()
	var index := popup.get_item_index(UTILITY_ROLE)
	var fallback := not fits and not is_instance_valid(tutorial)
	if fallback and index < 0:
		popup.add_item("", UTILITY_ROLE)
	elif not fallback and index >= 0:
		popup.remove_item(index)
	_refresh_role_button()

## 底栏一行里，除角色按钮外的其他控件都按最小宽度摆下之后，留给即时提示的宽度
func _footer_room(width: float) -> float:
	var row: Container = _role_button.get_parent()
	var panel := _footer.get_theme_stylebox("panel")
	var room := width - (panel.get_minimum_size().x if panel != null else 0.0)
	var shown := 0
	for child in row.get_children():
		if not child is Control or child == _role_button or not child.visible:
			continue
		shown += 1
		if child != _main.lbl_msg:
			room -= child.get_combined_minimum_size().x
	return room - float(row.get_theme_constant("separation")) * maxi(0, shown - 1)

## 角色面板从按钮**上方**弹出：底栏贴着窗口下沿，往下弹会被裁掉或盖住按钮本身。
## 左边是角色按钮，右边是悬停（或键盘选中）那一项的效果说明，默认说明当前角色。
## 说明全由 Roles.describe 从卡表字段生成。面板、按钮、字号都走抽屉的设计令牌，
## 和设置页、卡牌详情是同一套样式。
## 窗口窄时说明改排到按钮下面；按钮一列竖着放不下（横屏手机）时改成两列
func _show_role_popup(anchor_control: Control = null) -> void:
	if anchor_control == null:
		anchor_control = _role_button
	if _role_lock_reason() != "":
		_refresh_role_button()
		return
	for child in _role_popup.get_children():
		_role_popup.remove_child(child)
		child.queue_free()
	var panel := _style(Palette.get_color("world", "table_frame"))
	_role_popup.add_theme_stylebox_override("panel", panel)
	var current := _active_role()
	var choices := GridContainer.new()
	choices.name = "RoleChoices"
	choices.add_theme_constant_override("h_separation", 8)
	choices.add_theme_constant_override("v_separation", 8)
	var group := ButtonGroup.new()
	for id in Roles.ids():
		var role_id: String = id
		var button := _button(Roles.role_name(role_id))
		button.name = "Role_" + role_id
		button.toggle_mode = true
		button.button_group = group
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.set_pressed_no_signal(role_id == current)
		button.mouse_entered.connect(_show_role_detail.bind(role_id))
		button.focus_entered.connect(_show_role_detail.bind(role_id))
		button.pressed.connect(_choose_role.bind(role_id))
		choices.add_child(button)
	var detail := VBoxContainer.new()
	detail.name = "RoleDetail"
	detail.add_theme_constant_override("separation", 8)
	_role_detail_title = _label("", UI_FONT_TITLE)
	_role_detail_title.name = "RoleDetailTitle"
	detail.add_child(_role_detail_title)
	_role_detail_text = _label("", UI_FONT_BODY)
	_role_detail_text.name = "RoleDetailText"
	_role_detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(_role_detail_text)
	var hint := _label("选中即开始新的单机局", UI_FONT_SMALL)
	hint.name = "RoleDetailHint"
	detail.add_child(hint)
	_apply_tree_theme(choices)
	_apply_tree_theme(detail)
	# 先挂进（还没弹出的）面板再量：控件不在树里时最小尺寸缓存不会随列数、宽度更新
	var staging := VBoxContainer.new()
	_role_popup.add_child(staging)
	staging.add_child(choices)
	staging.add_child(detail)

	var anchor := Rect2(anchor_control.get_screen_position(), anchor_control.get_global_rect().size)
	var window := Rect2(anchor.position - anchor_control.get_global_rect().position, get_viewport().get_visible_rect().size)
	var pad := _px(PAD)
	var gap := _px(6)
	var margin := panel.get_minimum_size()
	var spacing := _px(16)
	var room_above := anchor.position.y - window.position.y - gap - pad
	var room_below := window.end.y - anchor.end.y - gap - pad
	var room_wide := window.size.x - pad * 2.0
	# 依次试：一列并排、两列并排、一列上下、两列上下，取第一个放得下的。
	# 先找能放在按钮上方的，没有再找能放在下方的（顶栏菜单打开时），都不行取最矮的那个
	var options: Array = []
	for side in [true, false]:
		for columns in [1, 2]:
			choices.columns = columns
			var list_size := choices.get_combined_minimum_size()
			var width := minf(_px(400), room_wide - margin.x - list_size.x - spacing) if side \
				else minf(maxf(list_size.x, _px(260)), room_wide - margin.x)
			if width < _px(220):
				continue
			_size_role_detail(width, hint)
			var detail_size := detail.get_combined_minimum_size()
			var total := Vector2(list_size.x + spacing + detail_size.x, maxf(list_size.y, detail_size.y)) if side \
				else Vector2(maxf(list_size.x, detail_size.x), list_size.y + spacing + detail_size.y)
			options.append({"columns": columns, "side": side, "width": width, "size": total + margin})
	var chosen: Dictionary = {}
	for room in [room_above, room_below]:
		for option in options:
			if chosen.is_empty() and option["size"].y <= room:
				chosen = option
	if chosen.is_empty():
		for option in options:
			if chosen.is_empty() or option["size"].y < chosen["size"].y:
				chosen = option
	choices.columns = int(chosen["columns"])
	_size_role_detail(float(chosen["width"]), hint)
	var box: BoxContainer = HBoxContainer.new() if chosen["side"] else VBoxContainer.new()
	box.name = "RolePicker"
	box.add_theme_constant_override("separation", roundi(spacing))
	_role_popup.add_child(box)
	choices.reparent(box, false)
	detail.reparent(box, false)
	_role_popup.remove_child(staging)
	staging.queue_free()
	_show_role_detail(current)
	_role_popup.reset_size()
	var size := Vector2(_role_popup.size)
	var x: float = clampf(anchor.position.x + anchor.size.x - size.x, window.position.x + pad,
		maxf(window.position.x + pad, window.end.x - pad - size.x))
	var y: float = anchor.position.y - size.y - gap
	if size.y > room_above:
		# 上方放不下（顶栏的选项菜单打开时就是这样），改为贴着下沿往下弹
		y = minf(anchor.end.y + gap, maxf(window.position.y, window.end.y - size.y))
	_role_popup.popup(Rect2i(Vector2i(roundi(x), roundi(y)), Vector2i(size)))

## 说明区按最长的那个角色定高：悬停换角色时面板不跳
func _size_role_detail(width: float, hint: Label) -> void:
	var text_height := 0.0
	for id in Roles.ids():
		text_height = maxf(text_height, _wrapped_height(_role_detail_lines(id), width, _role_detail_text))
	_role_detail_text.custom_minimum_size = Vector2(width, text_height)
	_role_detail_title.custom_minimum_size.x = width
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(width, _wrapped_height(hint.text, width, hint))

func _role_detail_lines(id: String) -> String:
	return "\n".join(Roles.describe(id).map(func(line): return "· " + line))

func _show_role_detail(id: String) -> void:
	if not is_instance_valid(_role_detail_title):
		return
	_role_detail_title.text = Roles.role_name(id)
	_role_detail_text.text = _role_detail_lines(id)

## 自动换行文本在给定宽度下的高度。面板要在弹出前定好尺寸，而标签要排进容器之后才知道
## 自己会折成几行，所以按同一字体、字号和断行规则先量一遍
func _wrapped_height(text: String, width: float, label: Label) -> float:
	var font: Font = label.get_theme_font("font")
	var font_size: int = label.get_theme_font_size("font_size")
	var size := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, -1,
		TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
	var lines := maxi(1, roundi(size.y / maxf(1.0, font.get_height(font_size))))
	return size.y + float(label.get_theme_constant("line_spacing")) * lines + _px(4)

func _choose_role(role_id: String) -> void:
	_role_popup.hide()
	if role_id == _active_role():
		return
	var result: Dictionary = _main.apply_role(role_id)
	_main._show_message(str(result["reason"]), Palette.semantic("success" if result.get("ok", false) else "danger"))
	_refresh_role_button()

## 底栏只占一行，长消息可悬停读全；换主题和窗口大小后仍保持可读对比度。
func present_message(text: String, color: Color) -> void:
	var label: Label = _main.lbl_msg
	label.text = text.replace("\n", " · ")
	label.tooltip_text = text
	label.set_meta("message_color", color)
	label.add_theme_color_override("font_color", Palette.readable_ink(color, Palette.get_color("world", "table_frame")))

func _build_utility() -> void:
	_palette = _main.find_child("PalettePanel", true, false)
	_bot = _main.find_child("BOTPanel", true, false)
	_palette.hide()
	_bot.hide()
	_utility = PanelContainer.new()
	_utility.name = "DrawerUtility"
	_utility.mouse_filter = Control.MOUSE_FILTER_STOP
	_utility.z_index = 20
	_utility.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame")))
	add_child(_utility)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_utility.add_child(column)
	var head := HBoxContainer.new()
	column.add_child(head)
	_utility_title = _label("设置", UI_FONT_TITLE)
	_utility_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_utility_title)
	var close := _button("关闭")
	close.pressed.connect(close_panels)
	head.add_child(close)
	_utility_scroll = ScrollContainer.new()
	_utility_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_utility_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_utility_scroll)
	_utility_body = VBoxContainer.new()
	_utility_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_utility_scroll.add_child(_utility_body)
	_utility_body.minimum_size_changed.connect(_relayout_utility)
	_ui_footer = HBoxContainer.new()
	_ui_footer.name = "UISettingsActions"
	_ui_footer.add_theme_constant_override("separation", 8)
	column.add_child(_ui_footer)
	var save_ui := _button("保存")
	save_ui.name = "SaveUISettings"
	save_ui.pressed.connect(_save_ui_settings)
	_ui_footer.add_child(save_ui)
	var reset_ui := _button("还原默认")
	reset_ui.name = "ResetUISettings"
	reset_ui.pressed.connect(_reset_ui_settings)
	_ui_footer.add_child(reset_ui)
	_ui_status = _label("", UI_FONT_SMALL)
	_ui_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ui_footer.add_child(_ui_status)
	_ui_footer.hide()
	_utility.hide()

func _open_utility(id: int) -> void:
	if id == UTILITY_ROLE:
		_show_role_popup(_menu)
		return
	if is_instance_valid(tutorial) and id != UTILITY_RULEBOOK:
		finish_tutorial(false)
	if is_instance_valid(_learning_invitation):
		_learning_invitation.hide()
	# 旧配色入口仍能定位到合并后的 UI 页，但选项菜单只保留 UI。
	if id == 0:
		id = 3
	close_panels()
	if is_instance_valid(tutorial):
		tutorial.set_reference_open(true)
	_active_utility_id = id
	_ui_footer.visible = id in [3, 4]
	if id == UTILITY_RULEBOOK:
		_utility_title.text = TutorialCatalog.ui("hub.title")
		_utility_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_utility_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_rulebook = Rulebook.new()
		_utility_body.add_child(_rulebook)
		_rulebook.bind(self)
		_utility.show()
		_apply_tree_theme(_utility)
		_relayout_utility()
		return
	if id == UTILITY_REPLAY:
		_main.open_replay_picker()
		return
	if id == 6:
		_main._open_join_panel()
		return
	if id == 2:
		_utility_title.text = "提示记录"
		_main.msg_log.show()
		if not _main.msg_log.expanded():
			_main.msg_log._toggle_body()
		_main.msg_log.embedded = true
		_mount_frame(_main.msg_log)
		_utility.show()
		_apply_tree_theme(_utility)
		_relayout_utility()
		return
	if id == 5:
		_utility_title.text = "存录像"
		var save := _button("下载当前录像" if _main.web_mode else "保存当前对局", 18)
		save.pressed.connect(_main._save_replay)
		_utility_body.add_child(save)
		_utility.show()
		_apply_tree_theme(_utility)
		_relayout_utility()
		return
	if id == UTILITY_CARDS:
		_build_card_config_page()
		_utility.show()
		_apply_tree_theme(_utility)
		_relayout_utility()
		return
	_utility.show()
	_utility_title.text = "配色" if id == 0 else ("BOT 强度" if id == 1 else ("UI" if id == 3 else "入口大小"))
	if id < 2:
		var source: Control = _palette if id == 0 else _bot
		source.show()
		if not source._body.visible:
			source._on_toggle()
		# 原工具面板继续处理自己的保存/选色逻辑，只把可见Frame放进抽屉弹层。
		var frame: Control = source.get_node("Frame")
		var inner_header: Control = frame.get_child(0).get_child(0)
		inner_header.hide()
		_utility.set_meta("hidden_header", inner_header)
		frame.reparent(_utility_body)
		frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		frame.position = Vector2.ZERO
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_apply_tree_theme(frame)
		source.hide()
		_utility.set_meta("source", source)
		_utility.set_meta("frame", frame)
	elif id == 3:
		if _main.drawer_window != null and not _main.mobile_mode:
			var intro := _label("窗口比例 · 左右空白自动收紧", UI_FONT_BODY)
			intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_utility_body.add_child(intro)
			var ratio_row := GridContainer.new()
			ratio_row.columns = 2
			ratio_row.add_theme_constant_override("h_separation", 8)
			ratio_row.add_theme_constant_override("v_separation", 8)
			_utility_body.add_child(ratio_row)
			var ratio_group := ButtonGroup.new()
			for fraction in [0.75, 0.85, 0.92, 0.98]:
				var ratio: float = float(fraction)
				var button := _button("工作区 %d%%" % roundi(ratio * 100.0), 17)
				button.toggle_mode = true
				button.button_group = ratio_group
				button.set_pressed_no_signal(is_equal_approx(ratio, _main.drawer_window.get_size_ratio()))
				ratio_row.add_child(button)
				_bind_ratio_button(button, ratio)
		var speed_row := HBoxContainer.new()
		speed_row.add_theme_constant_override("separation", 8)
		_utility_body.add_child(speed_row)
		speed_row.add_child(_label("卡牌插画速度", UI_FONT_BODY))
		_hover_speed_value = _label("", UI_FONT_BODY)
		_hover_speed_value.name = "HoverAnimationSpeedValue"
		_hover_speed_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_hover_speed_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		speed_row.add_child(_hover_speed_value)
		var speed_control := UIConfig.hover_speed_control()
		_hover_speed_slider = HSlider.new()
		_hover_speed_slider.name = "HoverAnimationSpeed"
		_hover_speed_slider.min_value = speed_control["min"]
		_hover_speed_slider.max_value = speed_control["max"]
		_hover_speed_slider.step = speed_control["step"]
		_hover_speed_slider.custom_minimum_size = Vector2(250, 40)
		_hover_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_hover_speed_slider.tooltip_text = "调整后立即改变卡牌插画的播放速度"
		_hover_speed_slider.accessibility_name = "卡牌插画播放速度"
		_hover_speed_slider.set_value_no_signal(UIConfig.get_hover_animation_speed())
		_hover_speed_value.text = UIConfig.hover_speed_text(UIConfig.get_hover_animation_speed())
		_hover_speed_slider.value_changed.connect(set_hover_animation_speed)
		_utility_body.add_child(_hover_speed_slider)
		var shake_row := HBoxContainer.new()
		shake_row.add_theme_constant_override("separation", 8)
		_utility_body.add_child(shake_row)
		shake_row.add_child(_label("画面震动", UI_FONT_BODY))
		_screen_shake_value = _label("", UI_FONT_BODY)
		_screen_shake_value.name = "ScreenShakeValue"
		_screen_shake_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_screen_shake_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		shake_row.add_child(_screen_shake_value)
		_screen_shake_slider = HSlider.new()
		_screen_shake_slider.name = "ScreenShake"
		_screen_shake_slider.min_value = 0.0
		_screen_shake_slider.max_value = 1.0
		_screen_shake_slider.step = 0.25
		_screen_shake_slider.custom_minimum_size = Vector2(250, 40)
		_screen_shake_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_screen_shake_slider.tooltip_text = "命中、终局时镜头震动的幅度；拉到最左关闭"
		_screen_shake_slider.accessibility_name = "画面震动幅度"
		_screen_shake_slider.set_value_no_signal(UIConfig.get_screen_shake())
		_screen_shake_value.text = _screen_shake_text(UIConfig.get_screen_shake())
		_screen_shake_slider.value_changed.connect(set_screen_shake)
		_utility_body.add_child(_screen_shake_slider)
		var angle_row := HBoxContainer.new()
		angle_row.add_theme_constant_override("separation", 8)
		_utility_body.add_child(angle_row)
		angle_row.add_child(_label("透视角度", UI_FONT_BODY))
		_perspective_value = _label("%d°" % roundi(perspective_angle), UI_FONT_BODY)
		_perspective_value.name = "PerspectiveAngleValue"
		_perspective_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_perspective_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		angle_row.add_child(_perspective_value)
		_perspective_slider = HSlider.new()
		_perspective_slider.name = "PerspectiveAngle"
		_perspective_slider.min_value = PERSPECTIVE_MIN_ANGLE
		_perspective_slider.max_value = PERSPECTIVE_MAX_ANGLE
		_perspective_slider.step = 1.0
		_perspective_slider.value = perspective_angle
		_perspective_slider.custom_minimum_size = Vector2(250, 30)
		_perspective_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_perspective_slider.tooltip_text = "数值越大，越接近俯视；调整会实时生效"
		_perspective_slider.value_changed.connect(set_perspective_angle)
		_utility_body.add_child(_perspective_slider)
		var angle_limits := HBoxContainer.new()
		_utility_body.add_child(angle_limits)
		var lower := _label("45° 低视角", UI_FONT_SMALL)
		lower.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		angle_limits.add_child(lower)
		angle_limits.add_child(_label("80° 俯视", UI_FONT_SMALL))
		var zoom_row := HBoxContainer.new()
		zoom_row.add_theme_constant_override("separation", 8)
		_utility_body.add_child(zoom_row)
		zoom_row.add_child(_label("牌桌缩放", UI_FONT_BODY))
		_zoom_value = _label("%d%%" % roundi(camera_view.zoom * 100), UI_FONT_BODY)
		_zoom_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_zoom_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		zoom_row.add_child(_zoom_value)
		_zoom_slider = HSlider.new()
		_zoom_slider.name = "TableZoom"
		_zoom_slider.min_value = CameraView.MIN_ZOOM
		_zoom_slider.max_value = CameraView.MAX_ZOOM
		_zoom_slider.step = 0.05
		_zoom_slider.value = camera_view.zoom
		_zoom_slider.custom_minimum_size = Vector2(250, 40)
		_zoom_slider.value_changed.connect(set_table_zoom)
		_utility_body.add_child(_zoom_slider)
		_utility_body.add_child(_label("配色", UI_FONT_TITLE))
		_mount_palette()
	elif id == 4:
		var intro := _label("选择收起后显示的入口图标大小", 15)
		intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_utility_body.add_child(intro)
		var handle_row := GridContainer.new()
		handle_row.columns = 3
		handle_row.add_theme_constant_override("h_separation", 8)
		handle_row.add_theme_constant_override("v_separation", 8)
		_utility_body.add_child(handle_row)
		for option in [["小", 0.75], ["中", 1.0], ["大", 1.25]]:
			var label: String = str(option[0])
			var ratio: float = float(option[1])
			var button := _button("%s（%d%%）" % [label, roundi(ratio * 100.0)], 17)
			handle_row.add_child(button)
			_bind_handle_button(button, ratio)
	_apply_tree_theme(_utility)
	_relayout_utility()


## 原面板继续保留数据、复制和保存动作，只把内容放入统一选项页。
func _mount_frame(source: CanvasLayer) -> void:
	var frame: Control = source.get_node("Frame")
	var inner_header: Control = frame.get_child(0).get_child(0)
	if source == _main.msg_log:
		inner_header.hide()
		_utility.set_meta("hidden_header", inner_header)
	frame.reparent(_utility_body)
	frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	frame.position = Vector2.ZERO
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_utility.set_meta("source", source)
	_utility.set_meta("frame", frame)

func show_record_result(path: String, steps: int, failed := false) -> void:
	if _active_utility_id != 5 or not _utility.visible:
		_open_utility(5)
	var notice: SaveNotice = _main.save_notice
	if failed:
		notice.show_failed(path)
	else:
		notice.show_saved(path, steps)
	if not _utility.has_meta("source"):
		notice.set_embedded(true)
		_mount_frame(notice)
	_apply_tree_theme(_utility)
	_relayout_utility()

func show_record_download(ok: bool) -> void:
	if _active_utility_id != 5 or not _utility.visible:
		_open_utility(5)
	var status := _utility_body.get_node_or_null("DownloadStatus") as Label
	if status == null:
		status = _label("", UI_FONT_BODY)
		status.name = "DownloadStatus"
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_utility_body.add_child(status)
	status.text = "已发起录像下载，请在浏览器下载列表查看。" if ok else "浏览器下载不可用，请允许此页面下载文件后重试。"
	status.set_meta("drawer_ink", Palette.semantic("success" if ok else "danger"))
	_apply_tree_theme(_utility)
	_relayout_utility()

func _save_ui_settings() -> void:
	var values := UIConfig.read_defaults()
	values["perspective_angle"] = perspective_angle
	values["table_zoom"] = camera_view.zoom
	values["hover_animation_speed"] = UIConfig.get_hover_animation_speed()
	values["screen_shake"] = UIConfig.get_screen_shake()
	if _main.drawer_window != null:
		values["window_fraction"] = _main.drawer_window.get_size_ratio()
		values["icon_scale"] = _main.drawer_window.get_icon_scale()
	var display_saved := UIConfig.save_preferences(values)
	var palette_saved := Palette.save()
	_ui_status.text = "已保存" if display_saved and palette_saved else "保存失败"

func _reset_ui_settings() -> void:
	var defaults := UIConfig.restore_preferences()
	Palette.restore_defaults()
	_palette._sync_pickers()
	perspective_angle = defaults["perspective_angle"]
	camera_view.reset()
	camera_view.zoom = defaults["table_zoom"]
	if _main.drawer_window != null:
		_main.drawer_window.set_size_fraction(defaults["window_fraction"])
		_main.drawer_window.set_icon_scale(defaults["icon_scale"])
	# 重建显示控件回填所有读数，配色仍复用原控件与原配置。
	var page := _active_utility_id
	_open_utility(page)
	relayout()
	_ui_status.text = "已还原"

func set_screen_shake(value: float) -> void:
	UIConfig.set_screen_shake(value)
	var current := UIConfig.get_screen_shake()
	if is_instance_valid(_screen_shake_slider):
		_screen_shake_slider.set_value_no_signal(current)
	if is_instance_valid(_screen_shake_value):
		_screen_shake_value.text = _screen_shake_text(current)
	if is_instance_valid(_ui_status):
		_ui_status.text = "已生效，尚未保存"

static func _screen_shake_text(value: float) -> String:
	return "关闭" if value <= 0.0 else "%d%%" % roundi(value * 100.0)

func set_hover_animation_speed(value: float) -> void:
	UIConfig.set_hover_animation_speed(value)
	var current := UIConfig.get_hover_animation_speed()
	if is_instance_valid(_hover_speed_slider):
		_hover_speed_slider.set_value_no_signal(current)
	if is_instance_valid(_hover_speed_value):
		_hover_speed_value.text = UIConfig.hover_speed_text(current)
	if is_instance_valid(_ui_status):
		_ui_status.text = "已生效，尚未保存"

func _mount_palette() -> void:
	_palette.show()
	if not _palette._body.visible:
		_palette._on_toggle()
	_palette.set_embedded(true)
	var frame: Control = _palette.get_node("Frame")
	var inner_header: Control = frame.get_child(0).get_child(0)
	inner_header.hide()
	_utility.set_meta("hidden_header", inner_header)
	frame.reparent(_utility_body)
	frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	frame.position = Vector2.ZERO
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette.hide()
	_utility.set_meta("source", _palette)
	_utility.set_meta("frame", frame)

## 保存当前运行期间的视角选择；与窗口比例共用同一次镜头/可拖放范围重算。
func set_perspective_angle(value: float) -> void:
	perspective_angle = clampf(roundf(value), PERSPECTIVE_MIN_ANGLE, PERSPECTIVE_MAX_ANGLE)
	if is_instance_valid(_perspective_slider):
		_perspective_slider.set_value_no_signal(perspective_angle)
	if is_instance_valid(_perspective_value):
		_perspective_value.text = "%d°" % roundi(perspective_angle)
	relayout()

func set_table_zoom(value: float) -> void:
	camera_view.change(value, content_rect().get_center(), content_rect().get_center())
	_sync_zoom_controls()

func move_table_view(value: float, previous: Vector2, current: Vector2) -> void:
	camera_view.change(value, previous, current)
	_detail.hide()
	_sync_zoom_controls()

func reset_table_view() -> void:
	camera_view.reset()
	_sync_zoom_controls()

func _sync_zoom_controls() -> void:
	if is_instance_valid(_zoom_slider):
		_zoom_slider.set_value_no_signal(camera_view.zoom)
	if is_instance_valid(_zoom_value):
		_zoom_value.text = "%d%%" % roundi(camera_view.zoom * 100)

func _bind_ratio_button(button: Button, ratio: float) -> void:
	button.pressed.connect(func():
		_main.drawer_window.set_size_fraction(ratio)
		relayout())

func _bind_handle_button(button: Button, ratio: float) -> void:
	button.pressed.connect(func(): _set_handle_size_ratio(ratio))

func _set_handle_size_ratio(ratio: float) -> void:
	if _main == null or _main.drawer_window == null:
		return
	var drawer: Node = _main.drawer_window
	# 优先使用窗口控制器提供的尺寸接口；旧版本回退到公开属性，保证设置面板可用。
	if drawer.has_method("set_icon_scale"):
		drawer.call("set_icon_scale", ratio)
	else:
		drawer.collapsed_size = Vector2i(roundi(168.0 * ratio), roundi(192.0 * ratio))
	if _collapsed:
		relayout()

func _on_handle_size_changed(_size: Vector2i) -> void:
	if _handle:
		_handle.set_render_scale(_main.drawer_window.get_handle_scale())
		_handle.queue_redraw()

func close_panels() -> void:
	hide_preview_card_detail()
	if _role_popup != null and _role_popup.visible:
		_role_popup.hide()
	# 显式关闭同时取消展开恢复，避免收起期间关闭的旧页复活。
	_suspended_panels.erase(_utility)
	_suspended_panels.erase(_main.msg_log)
	_active_utility_id = -1
	_ui_footer.hide()
	_ui_status.text = ""
	_rulebook = null
	if _utility_scroll:
		_utility_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		_utility_scroll.scroll_vertical = 0
	if _utility_body:
		_utility_body.size_flags_vertical = Control.SIZE_FILL
	_perspective_slider = null
	_perspective_value = null
	if _utility and _utility.has_meta("hidden_header"):
		var inner_header: Control = _utility.get_meta("hidden_header")
		inner_header.show()
		_utility.remove_meta("hidden_header")
	if _utility and _utility.has_meta("source"):
		var source: Node = _utility.get_meta("source")
		var frame: Control = _utility.get_meta("frame")
		frame.reparent(source)
		if source == _palette:
			_palette.set_embedded(false)
		elif source == _main.msg_log:
			_main.msg_log.embedded = false
		elif source == _main.save_notice:
			_main.save_notice.set_embedded(false)
		source.call("hide")
		_utility.remove_meta("source")
		_utility.remove_meta("frame")
	for child in _utility_body.get_children() if _utility_body else []:
		_utility_body.remove_child(child)
		child.queue_free()
	if _utility:
		_utility.hide()
	if _main.msg_log:
		_main.msg_log.hide()
	if is_instance_valid(tutorial):
		tutorial.set_reference_open(false)

func panels_open() -> bool:
	return (_utility != null and _utility.visible) or (_menu != null and _menu.get_popup().visible) \
		or (_role_popup != null and _role_popup.visible) \
		or (_main.msg_log != null and _main.msg_log.visible and _main.msg_log.expanded())

## 这些工具页均为非模态；只能在自己的可见矩形内挡住牌桌输入。
func pointer_over_panels(point: Vector2) -> bool:
	if is_instance_valid(tutorial) and tutorial.is_visible_in_tree() \
		and tutorial.get_global_rect().has_point(point):
		return true
	# 首次邀请是模态的：压暗层铺满视口，任何位置都不能悬停或操作牌桌。
	if is_learning_invitation_open():
		return true
	if _utility.visible and _utility.get_global_rect().has_point(point):
		return true
	if _header.visible and _header.get_global_rect().has_point(point):
		return true
	if _footer.visible and _footer.get_global_rect().has_point(point):
		return true
	if _main.msg_log.visible and _main.msg_log._frame.get_global_rect().has_point(point):
		return true
	for panel in _external_panels:
		if not is_instance_valid(panel) or not panel.visible:
			continue
		for child in panel.get_children():
			if child is CenterContainer:
				for frame in child.get_children():
					if frame is Control and frame.is_visible_in_tree() and frame.get_global_rect().has_point(point):
						return true
			elif child is Control and child.is_visible_in_tree() and not child.get_meta("pointer_passthrough", false) \
				and child.get_global_rect().has_point(point):
				return true
	return false

func _close_native_popups(node: Node) -> void:
	for child in node.get_children():
		if child is Window and child.visible:
			child.hide()
		_close_native_popups(child)

## 收起时隐藏工具页和终局提示，不清除输入、不取消联网；展开后还原原来的页。
func suspend_panels() -> void:
	_table_ui_suspended = true
	# 隐藏祖先画布，后台攻击/回合刷新仍可更新子控件的真实可见状态。
	# 这样收起期间新出现的攻击提示不会渲染，展开也不会恢复过期状态。
	_main.table_hud.hide()
	_detail.hide()
	_close_native_popups(_main)
	for panel in [_utility, _main.msg_log, _learning_invitation, tutorial] + _external_panels:
		if is_instance_valid(panel) and panel.visible:
			_suspend_panel(panel)

func _suspend_panel(panel: Node) -> void:
	if not _suspended_panels.has(panel):
		_suspended_panels.append(panel)
	panel.hide()

func resume_panels() -> void:
	if _collapsed or _window_blocked():
		return
	_table_ui_suspended = false
	_main.table_hud.show()
	for panel in _suspended_panels:
		if is_instance_valid(panel) and not panel.is_queued_for_deletion():
			panel.show()
	_suspended_panels.clear()

## 每次 show 都在当前调用栈检查，而不是等下一帧才补藏，防止晚到通知闪在入口上。
func _table_panels_blocked() -> bool:
	return _table_ui_suspended or _collapsed or _window_blocked()

func _guard_table_panel(panel: Node, restore_on_expand: bool) -> void:
	var callback := _on_table_panel_visibility_changed.bind(panel, restore_on_expand)
	if not panel.visibility_changed.is_connected(callback):
		panel.visibility_changed.connect(callback)
	_on_table_panel_visibility_changed(panel, restore_on_expand)

func _on_table_panel_visibility_changed(panel: Node, restore_on_expand: bool) -> void:
	if not is_instance_valid(panel) or panel.is_queued_for_deletion() or not panel.visible:
		return
	if panel is CanvasLayer and _external_panels.has(panel) and _learning_hides_panel(panel):
		if not _learning_hidden_panels.has(panel):
			_learning_hidden_panels.append(panel)
		panel.hide()
		return
	# 上下横条是展开画面的一部分；工具弹层仍等过渡完成后再恢复。
	if panel in [_header, _footer] and not _collapsed and _main.drawer_window != null and _main.drawer_window.is_expanded():
		return
	if _table_panels_blocked():
		if restore_on_expand:
			_suspend_panel(panel)
		else:
			panel.hide()

func _relayout_utility() -> void:
	if not is_instance_valid(_utility_body) or not _utility.visible:
		return
	var body := _utility_body.get_combined_minimum_size()
	var available := _content.size
	var desired: Vector2
	if _active_utility_id == UTILITY_RULEBOOK:
		var wide: bool = is_instance_valid(_rulebook) and _rulebook.current_page in ["cards", "upgrades"]
		# 选课只需一列；图鉴保留完整展示空间。小屏字号有下限，窄栏也保留相应宽度。
		desired = available if wide else Vector2(minf(maxf(_px(420), 360.0), available.x),
			available.y if _main.mobile_mode else minf(_px(660), available.y))
	else:
		desired = Vector2(minf(maxf(_px(380), body.x + _px(28)), available.x),
			minf(body.y + _px(82) + (_ui_footer.get_combined_minimum_size().y + _px(10) if _ui_footer.visible else 0.0), available.y))
	_utility.size = desired
	# 起点始终贴内容区右上角；上下各有 8px 缝隙，长内容由内部滚动承载。
	_utility.position = Vector2(_content.end.x - desired.x, _content.position.y)

func _position_log() -> void:
	if _main.msg_log == null or not _main.msg_log.visible or _main.msg_log.embedded:
		return
	if not _main.msg_log.expanded():
		_main.msg_log.hide()
		return
	var frame: Control = _main.msg_log._frame
	var extent := frame.get_combined_minimum_size()
	frame.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	frame.position = Vector2(maxf(_px(PAD), _last_size.x - extent.x - _px(PAD)),
		maxf(_content.position.y, _footer.position.y - extent.y - _px(10)))
	frame.size = extent

func _on_main_child_entered(child: Node) -> void:
	if child is JoinPanel or child is SaveNotice:
		# 入树即限制可见性；等 _ready 建好内容后再同步主题，无需等到下一帧。
		_guard_table_panel(child, true)
		if child.is_node_ready():
			_register_external_panel(child)
		else:
			child.ready.connect(_register_external_panel.bind(child), CONNECT_ONE_SHOT)

## 胜负层使用与工具页相同的展示管理，但保留终局自己的牌桌输入锁。
func register_result_panel(panel: CanvasLayer) -> void:
	_detail.hide()
	_register_external_panel(panel)

func _register_external_panel(panel: CanvasLayer) -> void:
	if not is_instance_valid(panel) or panel.is_queued_for_deletion():
		return
	if not _external_panels.has(panel):
		_external_panels.append(panel)
		panel.tree_exiting.connect(_unregister_external_panel.bind(panel), CONNECT_ONE_SHOT)
	_guard_table_panel(panel, true)
	_theme_external_panel(panel)

func _unregister_external_panel(panel: CanvasLayer) -> void:
	_external_panels.erase(panel)
	_suspended_panels.erase(panel)
	_learning_hidden_panels.erase(panel)

func _theme_external_panel(panel: CanvasLayer) -> void:
	# 局域网、录像通知和胜负层保留各自信号与业务锁，统一实际像素字号。
	# 居中容器跟随展开窗口尺寸，不用旧窗口的锚点或整体缩放。
	panel.scale = Vector2.ONE
	for child in panel.get_children():
		if child is Control:
			var control := child as Control
			_apply_tree_theme(control)
			if control is CenterContainer:
				if control.use_top_left:
					# 终局面板围绕窗口中心排版，内容换行或增加联机按钮不会挤偏中心。
					control.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
				else:
					control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
					control.position = Vector2.ZERO
					control.size = _last_size
			elif panel is SaveNotice:
				control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
				var extent := control.get_combined_minimum_size()
				control.position = Vector2(maxf(_px(PAD), _last_size.x - extent.x - _px(PAD)),
					maxf(_content.position.y, _footer.position.y - extent.y - _px(10)))

func _build_card_config_page() -> void:
	_utility_title.text = "卡牌配置"
	var intro := _label("单机和 BOT 对局可使用自定义 cards.json；联网时强制使用默认配置。选择后从下一局生效。", UI_FONT_BODY)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_utility_body.add_child(intro)
	var info: Dictionary = _main.card_config_info()
	_card_config_status = _label("", UI_FONT_SMALL)
	_card_config_status.name = "CardConfigStatus"
	_card_config_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_utility_body.add_child(_card_config_status)
	_card_config_path = LineEdit.new()
	_card_config_path.name = "CardConfigPath"
	_card_config_path.editable = false
	_card_config_path.text = _card_config_display_path(str(info["selected"]))
	_card_config_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_utility_body.add_child(_card_config_path)
	_card_config_drop = PanelContainer.new()
	_card_config_drop.name = "CardConfigDropZone"
	_card_config_drop.custom_minimum_size = Vector2(0, 92)
	_card_config_drop.mouse_filter = Control.MOUSE_FILTER_PASS
	_card_config_drop.tooltip_text = "把 cards.json 拖到这里"
	var drop_style := StyleBoxFlat.new()
	drop_style.bg_color = Color(Palette.get_color("world", "background"), 0.72)
	drop_style.border_color = Palette.get_color("card", "frame")
	drop_style.set_border_width_all(2)
	drop_style.set_corner_radius_all(10)
	drop_style.set_content_margin_all(12)
	_card_config_drop.add_theme_stylebox_override("panel", drop_style)
	var drop_label := _label("把 cards.json 拖到这里\n也可以点击下面的按钮选择文件", UI_FONT_BODY)
	if _main.web_mode:
		drop_label.text = "点击下面的按钮，从设备导入 cards.json。\n浏览器会保存所选配置，下次打开仍可使用。"
	drop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drop_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	drop_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_config_drop.add_child(drop_label)
	_utility_body.add_child(_card_config_drop)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	_utility_body.add_child(buttons)
	var choose := _button("选择 cards.json")
	var restore := _button("使用默认")
	var apply := _button("应用并重开")
	buttons.add_child(choose)
	buttons.add_child(restore)
	buttons.add_child(apply)
	var locked := bool(info["network_locked"])
	var launch_locked := bool(info.get("launch_locked", false))
	var replay_locked := bool(info.get("replay_locked", false))
	choose.disabled = locked or launch_locked or replay_locked
	restore.disabled = locked or launch_locked or replay_locked
	apply.disabled = locked or replay_locked
	_card_config_drop.mouse_filter = Control.MOUSE_FILTER_IGNORE if locked or launch_locked or replay_locked else Control.MOUSE_FILTER_PASS
	if replay_locked:
		_card_config_status.text = "正在播放录像；请先点击“退出录像”，再修改卡牌配置。"
	elif locked:
		_card_config_status.text = "联网期间已锁定为默认 cards.json"
	elif launch_locked:
		_card_config_status.text = "本次启动使用指定卡表（重开继续生效，不改变已保存的选择）：%s" % str(info["active"])
	elif bool(info["pending"]):
		_card_config_status.text = "已选择自定义配置；点击“应用并重开”后从下一局生效"
	else:
		_card_config_status.text = "当前生效：%s" % _card_config_display_path(str(info["active"]))
	choose.pressed.connect(func(): _open_card_config_file_dialog(_card_config_status, _card_config_path))
	restore.pressed.connect(func():
		var result: Dictionary = _main.clear_card_config()
		_card_config_status.text = str(result["reason"])
		_card_config_path.text = "默认 cards.json"
	)
	apply.pressed.connect(func():
		var result: Dictionary = _main.apply_selected_card_config()
		_card_config_status.text = str(result["reason"])
		if result.get("ok", false):
			close_panels()
	)

func is_card_config_page_open() -> bool:
	return _utility.visible and _active_utility_id == UTILITY_CARDS

func handle_card_config_files(files: PackedStringArray) -> bool:
	if not is_card_config_page_open():
		return false
	if files.is_empty():
		return true
	var selected := ""
	for path in files:
		if str(path).get_file().to_lower() == "cards.json":
			selected = str(path)
			break
		if str(path).get_extension().to_lower() == "json" and selected.is_empty():
			selected = str(path)
	if selected.is_empty():
		_card_config_status.text = "请拖入 .json 文件，建议文件名为 cards.json"
		return true
	var result: Dictionary = _main.choose_card_config(selected)
	_card_config_status.text = str(result["reason"])
	if result.get("ok", false):
		_card_config_path.text = str(result["path"])
	return true

func _open_card_config_file_dialog(status: Label, path: LineEdit) -> void:
	if _main.web_mode:
		_main.web_files.request_json(func(imported: Dictionary):
			if not is_instance_valid(status) or not is_instance_valid(path) or imported.get("cancelled", false):
				return
			if not imported.get("ok", false):
				status.text = str(imported.get("reason", "读取文件失败"))
				return
			var selected: Dictionary = _main.choose_card_config(imported["path"])
			status.text = str(selected["reason"])
			if selected.get("ok", false):
				path.text = str(imported["name"]))
		return
	var dialog := FileDialog.new()
	dialog.name = "CardConfigFileDialog"
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.add_filter("*.json", "cards.json")
	dialog.title = "选择 cards.json"
	dialog.file_selected.connect(func(selected: String):
		var result: Dictionary = _main.choose_card_config(selected)
		status.text = str(result["reason"])
		if result.get("ok", false):
			path.text = str(result["path"])
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	_main.add_child(dialog)
	dialog.popup_centered_ratio(0.72)

func _card_config_display_path(path: String) -> String:
	if path.is_empty() or (_main.web_mode and path == CardConfig.DEFAULT_PATH):
		return "默认 cards.json"
	return path.get_file() if _main.web_mode else path

func _build_details() -> void:
	_detail = PanelContainer.new()
	_detail.z_index = 15
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame")))
	add_child(_detail)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 7)
	_detail.add_child(column)
	_detail_title = _label("", 17)
	_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_detail_title)
	_detail_flavor = _label("", 13)
	_detail_flavor.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_detail_flavor)
	_detail_status = _label("", 14)
	_detail_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_detail_status)
	_detail_facts = GridContainer.new()
	_detail_facts.columns = 2
	_detail_facts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_facts.add_theme_constant_override("h_separation", 16)
	_detail_facts.add_theme_constant_override("v_separation", 5)
	column.add_child(_detail_facts)
	var separator := HSeparator.new()
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(separator)
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_detail_scroll)
	_detail_text = _label("", 13)
	_detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_scroll.add_child(_detail_text)
	_detail.hide()

func _process(_delta: float) -> void:
	if not is_instance_valid(_main) or _main.is_queued_for_deletion():
		return
	# 主场景等待玩家时会暂停；入口仍须更新状态，并在后台流程接续时释放暂停。
	_main._refresh_mascot_state()
	_main._refresh_drawer_pause()
	for panel in _external_panels:
		if not is_instance_valid(panel):
			continue
		if panel.visible and not bool(panel.get_meta("drawer_was_visible", false)):
			_theme_external_panel(panel)
		panel.set_meta("drawer_was_visible", panel.visible)
	if _collapsed or _window_blocked():
		return
	_offer_learning_invitation()
	if Vector2(get_viewport().get_visible_rect().size) != _viewport_pixels:
		relayout()
	if _utility.visible and _utility.has_meta("source") and _utility.get_meta("source") == _bot:
		_utility_title.text = "BOT 强度 · %s" % _bot._slider_val.text
	if _preview_detail_source != null:
		var source: Control = _preview_detail_source.get_ref()
		var preview: CardEntity = _preview_detail_card.get_ref() if _preview_detail_card != null else null
		var pointer := get_viewport().get_mouse_position()
		if is_instance_valid(source) and is_instance_valid(preview) and _preview_contains_pointer(source, pointer):
			show_card_detail(preview, pointer)
			return
		hide_preview_card_detail()
	if _main.mobile_mode:
		return
	var pointer := get_viewport().get_mouse_position()
	if pointer_over_panels(pointer) or not _main.board._drag_cards.is_empty():
		_detail.hide()
		return
	var mouse := get_viewport().get_mouse_position()
	if not content_rect().has_point(mouse):
		_detail.hide()
		return
	var card: CardEntity = _main.board._pick_card(mouse)
	if card == null:
		if _main.facility_contains_pointer(mouse):
			show_facility_detail(mouse)
		else:
			_detail.hide()
		return
	show_card_detail(card, mouse)

func _detail_fact(key: String, value: String) -> void:
	var caption := _label(key, 14)
	var content := _label(value, 14)
	content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 保存设计像素；主题刷新会再乘 DPI，不能把已缩放的宽度当成基准。
	content.set_meta("drawer_min_base", Vector2(145, 0))
	content.custom_minimum_size.x = _px(145)
	_detail_facts.add_child(caption)
	_detail_facts.add_child(content)

## 图鉴只提供正式卡牌实体；内容、效果、布局均复用桌面的悬停说明。
func show_preview_card_detail(card: CardEntity, mouse: Vector2, source: Control) -> void:
	if not is_instance_valid(card) or not is_instance_valid(source) or not source.is_visible_in_tree():
		return
	_preview_detail_source = weakref(source)
	_preview_detail_card = weakref(card)
	_detail.z_index = _utility.z_index + 1
	show_card_detail(card, mouse)

func hide_preview_card_detail(source: Control = null) -> void:
	if _preview_detail_source == null:
		return
	if source != null and _preview_detail_source.get_ref() != source:
		return
	_preview_detail_source = null
	_preview_detail_card = null
	_detail.z_index = 15
	_detail.hide()

func _preview_contains_pointer(source: Control, pointer: Vector2) -> bool:
	if not source.is_visible_in_tree() or not source.get_global_rect().has_point(pointer):
		return false
	var ancestor := source.get_parent()
	while ancestor != null:
		if ancestor is Control and ancestor.clip_contents and not ancestor.get_global_rect().has_point(pointer):
			return false
		ancestor = ancestor.get_parent()
	return true

func show_card_detail(card: CardEntity, mouse: Vector2) -> void:
	var id := card.def_id
	var def: Dictionary = CardDB.get_def(id)
	# 升级说明会遍历可合成路线，只在卡表/规则改变时重建；配置导入后同名卡也刷新。
	# 本方的牌按本方角色念数（HR 的云课堂要 2 个用户），同名牌在双方手里说明不同，角色修正也进签名
	var mods: Dictionary = _main.board.card_mods(card)
	var source_signature: Array = [CardDB.CARDS.hash(), CardDB.GAME.hash(), CardDB.UPGRADE.hash(), mods.hash()]
	if id != _detail_id or card.is_market != _detail_market or source_signature != _detail_source_signature:
		_detail_id = id
		_detail_market = card.is_market
		_detail_source_signature = source_signature
		_detail_title.text = CardDB.card_name(id)
		_detail_flavor.text = str(def.get("flavor", ""))
		_detail_effect = null
		for child in _detail_facts.get_children():
			_detail_facts.remove_child(child)
			child.queue_free()
		if card.is_market:
			_detail_fact("购买", "%d 资金" % int(def.get("price", 0)))
		if def.get("kind", "") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]:
			_detail_fact("配方", "%s × %d" % [CardDB.card_label(str(def.recipe_res)), ComboRules.recipe_need(def, mods)])
			if def.kind == CardDB.KIND_PRODUCT:
				_detail_fact("产出", "每回合 %s + %d" % [CardDB.res_label(str(def.output_res)),
					ComboRules.scaled_output(int(def.output_n), str(def.output_res), mods)])
			else:
				_detail_fact("攻击", "移除对方%s × %d" % [CardDB.card_label(str(def.attack_res)), int(def.attack_n)])
			_detail_effect = _detail_facts.get_child(_detail_facts.get_child_count() - 1)
		var pawn := CardDB.pawn_value(id)
		if pawn > 0:
			_detail_fact("典当", "资金 + %d" % pawn)
		_detail_scroll.scroll_vertical = 0
		var notes: String = _main.board.describe_def(id, mods)
		if def.get("kind", "") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]:
			notes = "\n".join(notes.split("\n").slice(2))
		_detail_text.text = notes.replace("\n→ ", " → ").replace("\n张数须精确\n不能夹杂其他牌", "\n须精确张数，不混入其他牌")
	if _detail_effect != null:
		var value := card.effect_value()
		_detail_effect.text = "每回合 %s + %d" % [CardDB.res_label(str(def.output_res)), value] if def.kind == CardDB.KIND_PRODUCT else "移除对方%s × %d" % [CardDB.card_label(str(def.attack_res)), value]
	# 进度属于当前实体，不能沿用同名卡另一组的状态。
	_detail_status.text = "购入后拖入理牌区组合" if card.is_market else card.recipe_status_text()
	_detail_status.visible = _detail_status.text != ""
	_detail_flavor.visible = _detail_flavor.text != ""
	_place_detail(mouse)

func show_facility_detail(mouse: Vector2) -> void:
	if _detail_id != "@pawnshop":
		_detail_id = "@pawnshop"
		_detail_market = false
		_detail_effect = null
		_detail_title.text = "典当行 · 公共设施"
		_detail_flavor.text = ""
		_detail_status.text = ""
		_detail_flavor.hide()
		_detail_status.hide()
		for child in _detail_facts.get_children():
			_detail_facts.remove_child(child)
			child.queue_free()
		_detail_text.text = "不需购买，拖入非现金卡换现金。\n现金卡不收；至少保留一个用户。"
	_place_detail(mouse)

func _place_detail(mouse: Vector2) -> void:
	# 跟随鼠标只改位置。内容、可用空间、缩放或配色改变时才刷新主题与文字排版。
	var signature: Array = [_detail_id, _detail_market, _last_size, _content.size,
		_responsive_factor(), Palette.get_color("world", "table_frame"),
		Palette.get_color("card", "body"), Palette.get_color("card", "frame"), Palette.semantic("pending")]
	for label in [_detail_title, _detail_flavor, _detail_status, _detail_text]:
		signature.append(label.text)
		signature.append(label.visible)
	for label in _detail_facts.get_children():
		signature.append(label.text)
	if signature != _detail_layout_signature:
		_detail_layout_signature = signature
		_apply_tree_theme(_detail)
		_fit_detail_content()
	_detail.show()
	_main.board._hide_desc()
	var extent := _detail.get_combined_minimum_size()
	_detail.size = extent
	var at := mouse + _vec(Vector2(14, 10))
	if at.x + extent.x > _last_size.x - _px(PAD):
		at.x = mouse.x - extent.x - _px(14)
	at.x = clampf(at.x, _px(PAD), maxf(_px(PAD), _last_size.x - extent.x - _px(PAD)))
	at.y = clampf(at.y, _content.position.y, maxf(_content.position.y, _content.position.y + _content.size.y - extent.y))
	_detail.position = at

## 使用当前字号测量最长一行，短说明收窄；长说明只在窗口允许的上限处换行。
## 每次从文字重新计算，避免悬停长卡后再看资源卡仍沿用上一张的宽度。
func _fit_detail_content() -> void:
	var style := _detail.get_theme_stylebox("panel")
	var max_width := minf(_px(300), _last_size.x / 3.0)
	var limit := maxf(1.0, max_width - style.get_minimum_size().x)
	var natural := 0.0
	for label in [_detail_title, _detail_flavor, _detail_status, _detail_text]:
		var font: Font = label.get_theme_font("font")
		var font_size: int = label.get_theme_font_size("font_size")
		for line in label.text.split("\n"):
			natural = maxf(natural, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var width := minf(ceilf(natural), limit)
	for label in [_detail_title, _detail_flavor, _detail_status, _detail_text]:
		label.custom_minimum_size = Vector2(width, 0.0)
		label.size = Vector2(width, 0.0)
		# 换宽度后立即刷新排版结果，避免首帧用上一张卡的换行高度撑大面板。
		label.get_minimum_size()
		label.update_minimum_size()
		label.reset_size()
	_detail_flavor.modulate = Color(1,1,1,0.68)
	_detail_status.modulate = Palette.semantic("pending")
	var above := _detail_title.get_combined_minimum_size().y + _detail_facts.get_combined_minimum_size().y
	if _detail_flavor.visible:
		above += _detail_flavor.get_combined_minimum_size().y
	if _detail_status.visible:
		above += _detail_status.get_combined_minimum_size().y
	var available := maxf(_px(28), _content.size.y - above - style.get_minimum_size().y - _px(55))
	_detail_scroll.custom_minimum_size = Vector2(width, minf(_detail_text.get_combined_minimum_size().y, available))
	_detail.reset_size()

func _on_size_changed() -> void:
	if not is_inside_tree():
		return
	if not _collapsed and not _window_blocked():
		relayout()

func set_learning_focus(value: bool) -> void:
	_learning_focus = value
	if value:
		for panel in _external_panels:
			if is_instance_valid(panel) and panel.visible and _learning_hides_panel(panel):
				if not _learning_hidden_panels.has(panel):
					_learning_hidden_panels.append(panel)
				panel.hide()
	else:
		var hidden := _learning_hidden_panels.duplicate()
		_learning_hidden_panels.clear()
		for panel in hidden:
			if is_instance_valid(panel) and not panel.is_queued_for_deletion():
				panel.show()
	_header.visible = not _collapsed
	_footer.visible = not _collapsed
	_main.table_hud.visible = not _table_panels_blocked()
	_detail.hide()
	relayout.call_deferred()

func _learning_hides_panel(panel: Node) -> bool:
	# 原局的通知暂存，当前教学的结果仍走同一套主题、收放和注销管理。
	return _learning_focus and not (is_instance_valid(_main._tutorial_arena)
		and _main._tutorial_arena.is_ancestor_of(panel))

func set_collapsed(collapsed: bool) -> void:
	_collapsed = collapsed
	_table_ui_suspended = collapsed
	_header.visible = not collapsed
	_footer.visible = not collapsed
	_detail.hide()
	_main._refresh_mascot_state()
	if is_instance_valid(_handle):
		_handle.visible = collapsed
		_handle.position = Vector2.ZERO
		if not collapsed and _handle.has_first_run_hint():
			_handle.set_first_run_hint(false)
			TutorialProgress.mark_handle_opened()
	if collapsed:
		suspend_panels()
	else:
		resume_panels()

func content_rect() -> Rect2:
	return _content

func relayout() -> void:
	if not is_inside_tree():
		return
	if _main == null or _window_blocked() or _collapsed or _relayout_running:
		return
	# 原生窗口先发size_changed、再发收放完成信号，UI的_collapsed可能仍是旧值。
	# 入口尺寸不属于牌桌构图，不能先写入缓存再因窗口太小return。
	var viewport_size := get_viewport().get_visible_rect().size
	var w := viewport_size.x
	var h := viewport_size.y
	if w < 300 or h < 300:
		return
	_viewport_pixels = viewport_size
	_last_size = _viewport_pixels
	_relayout_running = true
	scale = Vector2.ONE
	_apply_tree_theme(_header)
	_refresh_sound_button()
	_refresh_pin_button()
	_apply_tree_theme(_footer)
	_apply_tree_theme(_utility)
	if is_instance_valid(tutorial):
		_apply_tree_theme(tutorial)
	_style_popup(_menu.get_popup())
	_main.msg_log.scale = Vector2.ONE
	_apply_tree_theme(_main.msg_log._frame)
	var pad := _px(PAD)
	_fit_header_width(w - pad * 2.0)
	_header.position = Vector2(roundf((w - _header.size.x) * 0.5), pad)
	var header_h := _header.size.y
	_fit_role_button(w - pad * 2)
	var footer_h := maxf(_px(60), _footer.get_combined_minimum_size().y)
	_footer.position = Vector2(pad, h - footer_h - pad)
	_footer.size = Vector2(w - pad * 2, footer_h)
	_content = Rect2(pad, header_h + pad + _px(8), w - pad * 2, h - header_h - footer_h - pad * 2 - _px(16))
	if is_instance_valid(tutorial):
		_layout_tutorial(_content)
	for panel in _external_panels:
		if is_instance_valid(panel):
			_theme_external_panel(panel)
	var fit := CameraFit.fit_perspective(_viewport_pixels, content_rect(), FRAMING_RECT, 0.0, FRAMING_REST_HEIGHT, perspective_angle, 44.0, 8.0 * _ui_scale)
	CameraFit.apply(_main.board.camera, fit)
	camera_view.overview = fit
	_sync_playable_bounds()
	camera_view.configure(_main.board.camera, fit, content_rect(), FRAMING_RECT)

	_relayout_utility()
	_position_log()
	_relayout_running = false

## 资源卡只取容纳文字所需的宽度。空余屏幕宽度留在栏外，不拉长两块背景。
func _fit_header_width(available: float) -> void:
	if not is_instance_valid(_resources):
		return
	var header_style: StyleBox = _header.get_theme_stylebox("panel")
	var gap := _title_row.get_theme_constant("separation")
	var fixed_width := header_style.get_minimum_size().x + gap * (_title_row.get_child_count() - 1)
	for control in _title_row.get_children():
		if control != _resources and control is Control:
			fixed_width += control.get_combined_minimum_size().x
	var wanted := 0.0
	for source: Label in [_main.lbl_player_res, _main.lbl_bot_res]:
		var cell: Control = source.get_parent()
		var font := source.get_theme_font("font")
		var text_width := font.get_string_size(source.text, HORIZONTAL_ALIGNMENT_LEFT, -1, source.get_theme_font_size("font_size")).x
		var style: StyleBox = cell.get_theme_stylebox("panel")
		wanted = maxf(wanted, text_width + style.get_minimum_size().x + _px(16))
	var resources_gap := _resources.get_theme_constant("separation")
	var width := minf(ceilf(wanted), maxf(1.0, (available - fixed_width - resources_gap) * 0.5))
	for cell: Control in _resources.get_children():
		cell.custom_minimum_size.x = width
		cell.size.x = width
	_resources.custom_minimum_size.x = width * 2 + resources_gap
	_header.custom_minimum_size = Vector2.ZERO
	_header.size = Vector2(fixed_width + width * 2 + resources_gap, _header.get_combined_minimum_size().y)

## 主场景先生成完整读数；首行只显示余额，细目仍在对应标签的悬停提示内。
## 不把长括号折成第二行，待付归零的警告也保留在紧凑读数上。
func compact_header_resources() -> void:
	_refresh_role_button()
	if _main.state == null:
		return
	_main.lbl_round.tooltip_text = _main.lbl_round.text
	_main.lbl_round.text = _main.lbl_round.text.replace("行动阶段", "行动").replace("攻击阶段", "攻击")
	for item in [[_main.lbl_player_res, _main.my_seat, _main.company_label(_main.my_seat)],
			[_main.lbl_bot_res, _main.foe_seat, _main.company_label(_main.foe_seat)]]:
		var label: Label = item[0]
		var seat: String = item[1]
		var full := label.text
		label.tooltip_text = full
		label.text = "%s · %s%d · %s%d%s" % [item[2],
			CardDB.res_label(CardDB.RES_CASH), _main.state.resource_count(seat, CardDB.RES_CASH),
			CardDB.res_label(CardDB.RES_USER), _main.state.resource_count(seat, CardDB.RES_USER),
			" ⚠" if "⚠" in full else ""]
	if _last_size.x > 300.0:
		_fit_header_width(_last_size.x - _px(PAD * 2))
		_header.position.x = roundf((_last_size.x - _header.size.x) * 0.5)

## 相机的构图范围与可操作边界分开。固定初始构图保持牌大小稳定，
## 再反投影实际可见空地，避免多余宽高比留白成为不可用的牌桌。
func _world_rect_at_height(screen: Rect2, height: float) -> Rect2:
	var camera: Camera3D = _main.board.camera
	var corners: Array[Vector2] = []
	for point in [screen.position, Vector2(screen.end.x, screen.position.y), screen.end,
		Vector2(screen.position.x, screen.end.y)]:
		var origin := camera.project_ray_origin(point)
		var ray := camera.project_ray_normal(point)
		if absf(ray.y) < 0.00001:
			return Rect2()
		var world := origin + ray * ((height - origin.y) / ray.y)
		corners.append(Vector2(world.x, world.z))
	# 这里只给 Board 的旧矩形布局一个粗筛范围；精确的左右梯形边界
	# 由 _clamp_visible_stack 按每张牌当前位置求解，不能取全桌最窄宽度。
	var bounds := Rect2(corners[0], Vector2.ZERO)
	for corner in corners:
		bounds = bounds.expand(corner)
	return bounds

func _clamp_visible_stack(at: Vector3, offsets: Array) -> Vector3:
	return CameraFit.clamp_anchor_to_screen(_main.board.camera, _content.grow(-_px(3)),
		at, offsets, CardEntity.CARD_SIZE, Board.BOUNDS_PAD, _viewport_pixels, camera_view.overview)

func _sync_playable_bounds() -> void:
	var screen := _content.grow(-_px(3))
	# 粗筛矩形覆盖落桌和抬起时的全部可见范围；最终边界由每张卡的
	# 实际高度精确求解。取交集会在高俯角下留下不可用的底部空白。
	var rest := _world_rect_at_height(screen, 0.0)
	var held := _world_rect_at_height(screen, Board.DRAG_HEIGHT + 0.5)
	if not rest.has_area() or not held.has_area():
		return
	var table := rest.merge(held)
	_main.board.screen_position_clamper = _clamp_visible_stack
	var north := maxf(PLAYER_RECT.position.y, table.position.y)
	var player := Rect2(table.position.x, north, table.size.x, maxf(table.end.y - north, 0.0))
	_main.board.set_playable_bounds(table, player)
	_main.board.player_min_z = north
	_main.board.player_max_z = player.end.y
