# SPDX-License-Identifier: AGPL-3.0-only
extends BaseButton

signal shift_requested

const INTRO_HOLD := 5.0
const TURN_TIME := 0.44
const HINT_DELAY := 2.0
const HINT_DURATION := 8.0
const HINT_TEXT := "点击旋转门\n切换到「下班牌」"
var title_label: Label
var on_duty := true
var intro := false
var turning := false
var elapsed := 0.0
var face_angle := 0.0
var hint_available: Callable
var _hint_pending := false
var _hint_elapsed := 0.0
var _hint: PanelContainer
var _hint_label: Label
var _hint_layout_key: Array = []

func _ready() -> void:
	name = "ShiftSign"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	pressed.connect(func():
		_dismiss_hint()
		shift_requested.emit())
	for feedback in [mouse_entered, mouse_exited, focus_entered, focus_exited]:
		feedback.connect(queue_redraw)

func bind(title: Label, work: bool, first: bool) -> void:
	title_label = title
	on_duty = work
	intro = first
	_dismiss_hint()
	_hint_pending = first and work
	_hint_elapsed = 0.0
	turning = false
	elapsed = 0.0
	if get_parent() == null:
		title.add_child(self)
	elif get_parent() != title:
		reparent(title, false)
	title.self_modulate.a = 0.0
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tooltip_text = "切换到下班" if on_duty else "切换到上班"
	accessibility_name = tooltip_text
	set_process(intro)
	queue_redraw()

func _process(delta: float) -> void:
	if not is_visible_in_tree(): return
	var hint_delta := delta
	if intro:
		elapsed += delta
		turning = elapsed >= INTRO_HOLD
		queue_redraw()
		if elapsed < INTRO_HOLD + TURN_TIME: return
		intro = false
		turning = false
		# Count only time after the sign has finished revealing the mode.
		hint_delta = elapsed - INTRO_HOLD - TURN_TIME
	if not _hint_pending:
		set_process(false)
		return
	# A modal invitation can cover the sign; don't spend the hint's readable
	# time behind it, or while the drawer is collapsed / changing modes.
	if hint_available.is_valid() and not hint_available.call():
		if is_instance_valid(_hint): _hint.hide()
		return
	_hint_elapsed += hint_delta
	if _hint_elapsed < HINT_DELAY: return
	if _hint_elapsed >= HINT_DELAY + HINT_DURATION:
		_dismiss_hint()
		return
	_show_hint()

func _dismiss_hint() -> void:
	_hint_pending = false
	if is_instance_valid(_hint): _hint.hide()
	if not intro: set_process(false)

func _show_hint() -> void:
	if not is_instance_valid(_hint):
		_hint = PanelContainer.new()
		_hint.name = "ShiftHint"
		_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hint.z_index = 20
		_hint_label = Label.new()
		_hint_label.text = HINT_TEXT
		_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hint_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_hint_label.add_theme_font_override("font", Fonts.zh())
		_hint.add_child(_hint_label)
		# The drawer recursively themes Controls. Keep this self-themed bubble
		# under a canvas node so a relayout cannot apply UI scaling a second time.
		var hint_canvas := Node2D.new()
		hint_canvas.name = "ShiftHintCanvas"
		add_child(hint_canvas)
		hint_canvas.add_child(_hint)
	var ui_scale := title_label.get_theme_font_size("font_size") / 24.0
	var paper := Palette.get_color("world", "table_frame")
	var ink := Palette.get_color("card", "frame")
	var layout_key := [ui_scale, paper, ink, global_position, size, get_viewport_rect(),
		_hint.get_combined_minimum_size()]
	if _hint_layout_key == layout_key:
		_hint.show()
		return
	_hint_layout_key = layout_key
	var style := StyleBoxFlat.new()
	style.bg_color = paper
	style.border_color = ink
	style.set_border_width_all(maxi(1, roundi(2 * ui_scale)))
	style.set_corner_radius_all(roundi(8 * ui_scale))
	style.content_margin_left = 12 * ui_scale
	style.content_margin_right = 12 * ui_scale
	style.content_margin_top = 8 * ui_scale
	style.content_margin_bottom = 8 * ui_scale
	_hint.add_theme_stylebox_override("panel", style)
	_hint_label.add_theme_font_size_override("font_size", maxi(1, roundi(17 * ui_scale)))
	_hint_label.add_theme_color_override("font_color", Palette.readable_ink(ink, paper))
	var bounds := get_viewport_rect().grow(-8 * ui_scale)
	_hint.size = _hint.get_combined_minimum_size()
	var at := global_position + Vector2((size.x - _hint.size.x) * 0.5, size.y + 8 * ui_scale)
	at.x = clampf(at.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - _hint.size.x))
	at.y = clampf(at.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - _hint.size.y))
	_hint.global_position = at.round()
	_hint.show()

func set_turn(angle: float) -> void:
	intro = false
	_dismiss_hint()
	set_process(false)
	face_angle = angle
	turning = not is_zero_approx(angle)
	queue_redraw()

# Local units are relative to the plate's half-height. Project all its layers
# around the same vertical pin; the brass edge remains visible at a quarter turn.
func _project(x: float, y: float, z: float, angle: float, unit: float) -> Vector2:
	var depth := z * cos(angle) - x * sin(angle)
	var perspective := 10.0 / (10.0 - depth)
	return size * 0.5 + unit * perspective * Vector2(x * cos(angle) + z * sin(angle), y)

func _rim(half_width: float, half_height: float, z: float, angle: float, unit: float) -> PackedVector2Array:
	var cut := 0.15 * half_height
	var points := PackedVector2Array()
	for local in [Vector2(-half_width + cut, -half_height), Vector2(half_width - cut, -half_height),
			Vector2(half_width, -half_height + cut), Vector2(half_width, half_height - cut),
			Vector2(half_width - cut, half_height), Vector2(-half_width + cut, half_height),
			Vector2(-half_width, half_height - cut), Vector2(-half_width, -half_height + cut)]:
		points.append(_project(local.x, local.y, z, angle, unit))
	return points

func _gradient(points: PackedVector2Array, top: Color, bottom: Color) -> void:
	draw_polygon(points, PackedColorArray([top, top, top, bottom, bottom, bottom, bottom, top]))

func _outline(points: PackedVector2Array, color: Color, weight: float) -> void:
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, color, weight, true)

func _draw() -> void:
	if not is_instance_valid(title_label) or size.x < 4 or size.y < 4: return
	var font_size := title_label.get_theme_font_size("font_size")
	var font := title_label.get_theme_font("font")
	var unit := minf(minf(size.y * 0.41, font_size * 0.86), (size.x - 2.0) * 0.36)
	var half_w := minf((size.x - 2.0) * 0.49 / unit, 2.15)
	var angle := face_angle
	var word := "上班" if on_duty else "下班"
	if intro:
		var phase := smoothstep(INTRO_HOLD, INTRO_HOLD + TURN_TIME, elapsed)
		if phase < 0.5: word = "牛马牌"
		angle = PI * (phase if phase < 0.5 else phase - 1.0)

	var ink := Palette.get_color("card", "frame")
	var paper := Palette.get_color("world", "table_frame")
	var brass := Palette.semantic("cash").lerp(paper, 0.40)
	var pale_brass := brass.lerp(paper, 0.72)
	var patina := brass.lerp(ink, 0.60)
	var enamel := Palette.get_color("card", "back_face") if on_duty else Palette.semantic("danger")
	enamel = enamel.lerp(ink, 0.34 if on_duty else 0.46)
	if is_hovered() or has_focus(): enamel = enamel.lightened(0.09)
	var tilt := absf(sin(angle))
	var front := _rim(half_w, 1.0, 0.12, angle, unit)
	var back := _rim(half_w, 1.0, -0.12, angle, unit)
	var center := size * 0.5

	# Short fixed collars show where the spindle enters the top and bottom.
	for end in [-1.0, 1.0]:
		var collar := Rect2(center + Vector2(-0.15, end * 1.03 - 0.095) * unit,
			Vector2(0.3, 0.19) * unit)
		draw_rect(collar, patina)
		draw_rect(Rect2(collar.position + Vector2(unit * 0.05, 0),
			Vector2(unit * 0.07, collar.size.y)), pale_brass)

	var shadow := back.duplicate()
	for i in shadow.size(): shadow[i] += Vector2(0.025, 0.085) * unit
	if tilt < 0.99: draw_colored_polygon(shadow, Color(ink, 0.22))
	# Front and rear lips have physical separation. At the handoff (+90/-90)
	# both faces present exactly the same narrow bevel to the viewer.
	for i in front.size():
		var j := (i + 1) % front.size()
		var edge := PackedVector2Array([back[i], back[j], front[j], front[i]])
		var normal := (back[j] - back[i]).orthogonal().normalized()
		if normal.dot(front[i] - back[i]) >= -0.01: continue
		var glint := clampf(0.46 + normal.dot(Vector2(-0.5, -0.86)) * 0.34, 0.0, 1.0)
		var side := patina.lerp(brass, glint)
		draw_colored_polygon(edge, side)
		# A brass spine sits between two darker lips. It is still legible when
		# viewed edge-on, where neither of the enamel faces can catch the light.
		var edge_width := absf(normal.dot(front[i] - back[i]))
		if edge_width > 1.4:
			var spine := PackedVector2Array([back[i].lerp(front[i], 0.23), back[j].lerp(front[j], 0.23),
				back[j].lerp(front[j], 0.48), back[i].lerp(front[i], 0.48)])
			draw_colored_polygon(spine, side.lerp(pale_brass, 0.58))
		draw_line(back[i], back[j], ink, maxf(0.7, unit * 0.045), true)

	if absf(cos(angle)) < 0.035: return
	_gradient(front, pale_brass, brass.lerp(ink, 0.22))
	_outline(front, ink, maxf(0.8, unit * 0.055))
	var face := _rim(half_w - 0.10, 0.89, 0.125, angle, unit)
	var highlight := pow(maxf(0.0, cos(angle + 0.40)), 4.0)
	_gradient(face, enamel.lerp(paper, 0.12 * highlight), enamel.darkened(0.16 + tilt * 0.12))
	# A soft, oblique reflection travels over the glaze as the sign turns.
	var sweep := clampf(-0.32 * half_w + sin(angle) * 0.62, -half_w + 0.72, half_w - 0.62)
	var sheen := PackedVector2Array()
	var colors := PackedColorArray()
	for strip in [[0.32, -0.87, 0.0], [0.60, -0.87, 0.085],
			[-0.28, 0.87, 0.043], [-0.63, 0.87, 0.0]]:
		sheen.append(_project(sweep + strip[0], strip[1], 0.126, angle, unit))
		colors.append(Color(paper, strip[2] * highlight))
	draw_polygon(sheen, colors)
	# The letterpress and studs share the tangent plane of the enamel face.
	var origin := _project(0, 0, 0.13, angle, unit)
	var letter_basis := Transform2D(
		(_project(0.01, 0, 0.13, angle, unit) - origin) / (unit * 0.01),
		(_project(0, 1, 0.13, angle, unit) - origin) / unit, origin)
	draw_set_transform_matrix(letter_basis)
	var lettering := paper.lerp(Color.WHITE, 0.32)
	var label_size := maxi(1, floori(minf(unit * 1.45, (half_w - 0.31) * unit * 2.0 / word.length())))
	var baseline := (font.get_ascent(label_size) - font.get_descent(label_size)) * 0.5 - unit * 0.05
	var width := font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x
	var start := Vector2(-width * 0.5, baseline)
	draw_string(font, start + Vector2(0, 0.055 * unit), word, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, ink)
	draw_string(font, start, word, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, lettering)
	for end in [-1.0, 1.0]:
		var at := Vector2(end * (half_w - 0.19), 0.0) * unit
		draw_circle(at, unit * 0.069, patina, true, -1.0, true)
		draw_circle(at - Vector2(0.014, 0.014) * unit, unit * 0.036, pale_brass, true, -1.0, true)
