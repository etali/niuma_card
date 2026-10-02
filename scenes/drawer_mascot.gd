# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name DrawerMascot
extends Control

## 抽屉入口显示图标、招呼及对局状态；是否展开由 activated 的接收者决定。
## 透明 PNG 在自身绘制区域内整体变换；不对整个入口控件做缩放或负坐标位移。
signal activated
signal pointer_pressed
signal pointer_released
signal pointer_moved(position: Vector2)

const ENTRY_SIZE := Vector2(168, 192)
const ICON_RECT := Rect2(12, 44, 144, 144)
const HOVER_ZOOM := 1.08
const INVITATION_TEXT := "来摸一局？"
const MAX_TILT := 0.05235988 # 3 度；整张图同步左右摆动。
const MASCOT_SHADER := """
shader_type canvas_item;
uniform float face_zoom = 1.0;
uniform float face_tilt = 0.0;
void fragment() {
	vec2 center = vec2(0.50, 0.52);
	vec2 delta = UV - center;
	// 整张透明 PNG 使用同一个变换；主体、蒙层、边缘和透明区域保持相对位置一起晃动。
	float angle = face_tilt;
	mat2 turn = mat2(vec2(cos(angle), -sin(angle)), vec2(sin(angle), cos(angle)));
	vec2 sample_uv = center + turn * delta / face_zoom;
	// 旋转/放大后的采样超出纹理边界时保持透明，避免边缘采样填满入口。
	if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		COLOR = texture(TEXTURE, sample_uv);
	}
}
"""

var _icon: TextureRect
var _bubble: PanelContainer
var _greeting_label: Label
var _bubble_style: StyleBoxFlat
var _render_scale := 1.0
var _material: ShaderMaterial
var _motion: Tween
var _hovered := false
var _pressing := false
var delegate_pointer := false
var _press_pos := Vector2.ZERO
var _press_moved := false
const CLICK_DRAG_THRESHOLD := 12.0

## 交互状态和 icon 共用一套语义：入口是角色，也是当前操作状态的提示灯。
const STATE_IDLE := "idle"
const STATE_OPENING := "opening"
const STATE_HOVER := "hover"
const STATE_PRESSED := "pressed"
const STATE_DRAGGING := "dragging"
const STATE_CONNECTING := "connecting"
const STATE_WAITING := "waiting"
const STATE_FOE_ACTING := "foe_acting"
const STATE_FOE_DONE := "foe_done"
const STATE_YOUR_TURN := "your_turn"
const STATE_FOE_ATTACKING := "foe_attacking"
const STATE_YOUR_ATTACK := "your_attack"
const STATE_FOE_OFFLINE := "foe_offline"
const STATE_DISCONNECTED := "disconnected"
const STATE_RESOLVING := "resolving"
const STATE_SUCCESS := "success"
const STATE_DEFEAT := "defeat"
const STATE_DANGER := "danger"
var _state := STATE_IDLE
var _pointer_return_state := STATE_IDLE
var _visual_state := ""
var _face_zoom := 1.0:
	set(value):
		_face_zoom = value
		if _material:
			_material.set_shader_parameter("face_zoom", value)
var _face_tilt := 0.0:
	set(value):
		_face_tilt = value
		if _material:
			_material.set_shader_parameter("face_tilt", value)

func _init() -> void:
	name = "DrawerHandle"
	process_mode = Node.PROCESS_MODE_ALWAYS
	custom_minimum_size = ENTRY_SIZE
	size = ENTRY_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	accessibility_name = "牛马牌"
	tooltip_text = ""

func _ready() -> void:
	_ensure_content()
	# setup 可发生在入树之前，等最小尺寸缓存更新后再收紧入口矩形。
	call_deferred("_layout_content")
	mouse_entered.connect(func(): set_hovered(true))
	mouse_exited.connect(func(): set_hovered(false))
	visibility_changed.connect(_on_visibility_changed)
	set_state(_state)

func setup(texture: Texture2D) -> void:
	_ensure_content()
	_icon.texture = texture

## DPI 和玩家选择共同决定真实绘制像素；保持 Control.scale 为 1，
## 气泡文字直接以目标字号栅格化，不把低分辨率字形再放大。
func set_render_scale(value: float) -> void:
	_render_scale = clampf(value, 0.25, 4.0)
	scale = Vector2.ONE
	_ensure_content()
	_layout_content()

func get_render_scale() -> float:
	return _render_scale

func get_icon_hit_rect() -> Rect2:
	return Rect2(ICON_RECT.position * _render_scale, ICON_RECT.size * _render_scale)

func _layout_content() -> void:
	custom_minimum_size = ENTRY_SIZE * _render_scale
	size = custom_minimum_size
	_icon.position = ICON_RECT.position * _render_scale
	_icon.size = ICON_RECT.size * _render_scale
	_icon.scale = Vector2.ONE
	_bubble.position = Vector2(12, 4) * _render_scale
	_bubble.custom_minimum_size = Vector2(144, 34) * _render_scale
	_bubble.scale = Vector2.ONE
	_bubble_style.set_border_width_all(maxi(1, roundi(2.0 * _render_scale)))
	_bubble_style.set_corner_radius_all(maxi(1, roundi(12.0 * _render_scale)))
	_bubble_style.content_margin_left = roundf(9.0 * _render_scale)
	_bubble_style.content_margin_right = roundf(9.0 * _render_scale)
	_bubble_style.content_margin_top = roundf(5.0 * _render_scale)
	_bubble_style.content_margin_bottom = roundf(5.0 * _render_scale)
	_greeting_label.add_theme_font_size_override("font_size", maxi(1, roundi(19.0 * _render_scale)))
	# 子标签的最小尺寸变更会延迟传给容器；同步更新后再收紧一次，
	# 防止缩小DPI时气泡一直被旧字号的最小宽度撑住。
	_bubble.size = _bubble.custom_minimum_size
	call_deferred("_fit_bubble_size")

func _fit_bubble_size() -> void:
	_bubble.size = _bubble.custom_minimum_size

func _ensure_content() -> void:
	if _icon != null:
		return
	_icon = TextureRect.new()
	_icon.name = "Icon"
	_icon.position = ICON_RECT.position
	_icon.size = ICON_RECT.size
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var shader := Shader.new()
	shader.code = MASCOT_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	_icon.material = _material
	add_child(_icon)

	_bubble = PanelContainer.new()
	_bubble.name = "Greeting"
	_bubble.position = Vector2(12, 4)
	_bubble.size = Vector2(144, 34)
	_bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	_bubble_style = style
	style.bg_color = Palette.get_color("world", "table_frame")
	style.border_color = Palette.get_color("card", "frame")
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	_bubble.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	_greeting_label = label
	label.text = ""
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", Fonts.zh_bold())
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble.add_child(label)
	_bubble.modulate.a = 0.0
	add_child(_bubble)
	_layout_content()

func set_state(state: String) -> void:
	var next := state.to_lower()
	if next not in [STATE_IDLE, STATE_OPENING, STATE_HOVER, STATE_PRESSED, STATE_DRAGGING, STATE_CONNECTING, STATE_WAITING, STATE_FOE_ACTING, STATE_FOE_DONE, STATE_YOUR_TURN, STATE_FOE_ATTACKING, STATE_YOUR_ATTACK, STATE_FOE_OFFLINE, STATE_DISCONNECTED, STATE_RESOLVING, STATE_SUCCESS, STATE_DEFEAT, STATE_DANGER]:
		next = STATE_IDLE
	if _pressing and next not in [STATE_PRESSED, STATE_DRAGGING]:
		_pointer_return_state = next
		return
	_state = next
	if not is_inside_tree() or not is_visible_in_tree():
		return
	if _visual_state == next:
		return
	_visual_state = next
	_ensure_content()
	_refresh_copy()
	_apply_pointer_pose()

func _refresh_copy() -> void:
	var copy := _state_copy()
	_greeting_label.text = copy.text
	_bubble_style.bg_color = copy.surface
	_bubble_style.border_color = copy.accent
	_greeting_label.add_theme_color_override("font_color", Palette.readable_ink(copy.ink, copy.surface))
	# 状态仅由自绘气泡展示，禁用系统悬停小字，避免叠出第二份提示。
	tooltip_text = ""
	accessibility_name = str(copy.text) if not str(copy.text).is_empty() else "牛马牌"
	_bubble.visible = not str(copy.text).is_empty()
	if not _bubble.visible:
		_bubble.modulate.a = 0.0

## 悬停是叠加在业务状态上的反馈，不参与对局文案状态切换。
func _apply_pointer_pose() -> void:
	if _state in [STATE_PRESSED, STATE_DRAGGING]:
		var tween := _new_motion()
		tween.tween_property(self, "_face_zoom", 0.95 if _state == STATE_PRESSED else 1.0, 0.10)
		tween.parallel().tween_property(self, "_face_tilt", MAX_TILT * 0.4 if _state == STATE_DRAGGING else 0.0, 0.10)
		tween.parallel().tween_property(_bubble, "modulate:a", 0.0, 0.08)
	elif _hovered:
		_animate_greeting(2, false)
	elif _state == STATE_SUCCESS:
		_animate_greeting(1, true)
	else:
		_return_to_rest()

func _has_status() -> bool:
	return _state not in [STATE_IDLE, STATE_OPENING, STATE_HOVER, STATE_PRESSED, STATE_DRAGGING]

func _rest_zoom() -> float:
	return 1.03 if _has_status() and _state not in [STATE_DANGER, STATE_DEFEAT] else 1.0

func state() -> String:
	return _state

func _state_copy() -> Dictionary:
	var ink := Palette.get_color("card", "body")
	var copy := {"text": "", "surface": Palette.get_color("world", "table_frame"), "accent": Palette.get_color("card", "frame"), "ink": ink}
	if _state == STATE_OPENING:
		copy["text"] = INVITATION_TEXT if _hovered else ""
	elif _state == STATE_CONNECTING:
		copy = {"text": "正在连接…", "surface": Palette.semantic("info", copy.surface), "accent": Palette.semantic("info", copy.accent), "ink": ink}
	elif _state == STATE_WAITING:
		copy = {"text": "等对手加入…", "surface": Palette.semantic("info", copy.surface), "accent": Palette.semantic("info", copy.accent), "ink": ink}
	elif _state == STATE_FOE_ACTING:
		copy = {"text": "等待对手行动", "surface": Palette.semantic("info", copy.surface), "accent": Palette.semantic("info", copy.accent), "ink": ink}
	elif _state == STATE_FOE_DONE:
		copy = {"text": "等待你行动", "surface": Palette.semantic("success", copy.surface), "accent": Palette.semantic("success", copy.accent), "ink": ink}
	elif _state == STATE_YOUR_TURN:
		copy = {"text": "轮到你行动", "surface": Palette.semantic("focus", copy.surface), "accent": Palette.semantic("focus", copy.accent), "ink": ink}
	elif _state == STATE_FOE_ATTACKING:
		copy = {"text": "对手攻击中…", "surface": Palette.semantic("info", copy.surface), "accent": Palette.semantic("danger", copy.accent), "ink": ink}
	elif _state == STATE_YOUR_ATTACK:
		copy = {"text": "轮到你攻击", "surface": Palette.semantic("focus", copy.surface), "accent": Palette.semantic("focus", copy.accent), "ink": ink}
	elif _state in [STATE_FOE_OFFLINE, STATE_DISCONNECTED]:
		copy = {"text": "对手已断开" if _state == STATE_FOE_OFFLINE else "连接已断开", "surface": Palette.semantic("muted", copy.surface), "accent": Palette.semantic("danger", copy.accent), "ink": ink}
	elif _state == STATE_RESOLVING:
		copy = {"text": "结算中…", "surface": Palette.semantic("focus", copy.surface), "accent": Palette.semantic("focus", copy.accent), "ink": ink}
	elif _state == STATE_SUCCESS:
		copy = {"text": "做得漂亮！", "surface": Palette.semantic("success", copy.surface), "accent": Palette.semantic("success", copy.accent), "ink": ink}
	elif _state == STATE_DEFEAT:
		copy = {"text": "这局结束了", "surface": Palette.semantic("muted", copy.surface), "accent": Palette.semantic("danger", copy.accent), "ink": ink}
	elif _state == STATE_DANGER:
		copy = {"text": "注意这一步", "surface": Palette.semantic("danger", copy.surface), "accent": Palette.semantic("danger", copy.accent), "ink": Color.WHITE}
	return copy

func set_hovered(hovered: bool) -> void:
	if _hovered == hovered:
		return
	_hovered = hovered
	if not is_inside_tree() or not is_visible_in_tree() or _state in [STATE_PRESSED, STATE_DRAGGING]:
		return
	_refresh_copy()
	if hovered:
		_animate_greeting(2, false)
	else:
		_return_to_rest()

func greet() -> void:
	# 启动招呼仅播放图标动画；邀请文字仍必须有鼠标悬停。
	if not is_inside_tree() or not is_visible_in_tree() or _state != STATE_OPENING:
		return
	_animate_greeting(3, true)

func _new_motion() -> Tween:
	if _motion and _motion.is_valid():
		_motion.kill()
	_motion = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_motion.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return _motion

func _animate_greeting(waves: int, return_after: bool) -> void:
	_ensure_content()
	var tween := _new_motion()
	tween.tween_property(self, "_face_zoom", HOVER_ZOOM, 0.18)
	tween.parallel().tween_property(_bubble, "modulate:a", 1.0 if _bubble.visible else 0.0, 0.14)
	tween.parallel().tween_property(self, "_face_tilt", 0.0, 0.14)
	for i in waves:
		tween.tween_property(self, "_face_tilt", -MAX_TILT, 0.13)
		tween.tween_property(self, "_face_tilt", MAX_TILT, 0.22)
		tween.tween_property(self, "_face_tilt", -MAX_TILT * 0.55, 0.16)
		tween.tween_property(self, "_face_tilt", 0.0, 0.13)
	if return_after:
		tween.tween_callback(func():
			if not _hovered:
				_return_to_rest())

func _return_to_rest() -> void:
	var tween := _new_motion()
	tween.tween_property(self, "_face_zoom", _rest_zoom(), 0.18)
	tween.parallel().tween_property(self, "_face_tilt", 0.0, 0.18)
	tween.parallel().tween_property(_bubble, "modulate:a", 1.0 if _has_status() else 0.0, 0.14)

func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		set_state(_state)
		return
	if _motion and _motion.is_valid():
		_motion.kill()
	_hovered = false
	_pressing = false
	_press_moved = false
	if _state in [STATE_PRESSED, STATE_DRAGGING]:
		_state = _pointer_return_state
	if _state == STATE_HOVER:
		_state = STATE_IDLE
	_visual_state = ""
	_face_zoom = 1.0
	_face_tilt = 0.0
	_bubble.modulate.a = 0.0

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			if not get_icon_hit_rect().has_point(event.position):
				return
			_pressing = true
			_pointer_return_state = _state
			set_state(STATE_PRESSED)
			_press_pos = event.position
			_press_moved = false
			pointer_pressed.emit()
			accept_event()
		else:
			if _pressing and not _press_moved and not delegate_pointer:
				activated.emit()
			pointer_released.emit()
			_pressing = false
			set_state(_pointer_return_state)
			accept_event()
	elif event is InputEventMouseMotion and _pressing:
		if event.position.distance_to(_press_pos) >= CLICK_DRAG_THRESHOLD * _render_scale:
			if not _press_moved:
				set_state(STATE_DRAGGING)
			_press_moved = true
			pointer_moved.emit(event.position)
	elif event is InputEventKey:
		if event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_SPACE]:
			activated.emit()
			accept_event()
