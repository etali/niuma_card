# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Control

## 下班终局的牌桌灯光与一次性纸屑。采样保留透明桌面，隐藏时演出时钟停住。
const SHADER := """
shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount = 0.0;
uniform float celebration = 0.0;
uniform float burst = 0.0;
uniform vec2 focus = vec2(0.5, 0.72);
void fragment() {
    vec4 c = textureLod(screen_tex, SCREEN_UV, 0.0);
    vec2 p = (SCREEN_UV - focus) * vec2(1.35, 1.0);
    float pool = 1.0 - smoothstep(0.12, 0.57, length(p));
    float grey = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    vec3 cold = mix(c.rgb, vec3(grey) * vec3(0.75, 0.83, 0.94), 0.78);
    cold *= mix(0.30, 0.95, pool);
    float ray = pow(max(0.0, sin(atan(p.y, p.x) * 15.0)), 7.0);
    vec3 warm = c.rgb * vec3(1.07, 1.01, 0.86) + vec3(0.12, 0.075, 0.015) * pool;
    warm += vec3(0.21, 0.14, 0.035) * ray * burst;
    COLOR = vec4(mix(c.rgb, mix(cold, warm, celebration), amount), c.a);
}
"""

class PaperBurst extends Control:
	var age := 0.0
	var pieces: Array[Dictionary] = []

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_meta("pointer_passthrough", true)

	func seed_pieces() -> void:
		# 自己的随机源，不推进牌局、供牌或 BOT 的随机序列。
		var rng := RandomNumberGenerator.new()
		rng.seed = 41821
		for i in 84:
			pieces.append({"side": float(i % 2), "vx": rng.randf_range(0.12, 0.48),
				"vy": rng.randf_range(-0.60, -0.22), "spin": rng.randf_range(-6.0, 6.0),
				"delay": rng.randf_range(0.0, 0.32), "width": rng.randf_range(5.0, 11.0),
				"color": i % 4})

	func _draw() -> void:
		var colors := [Color("e5b846"), Color("fff1ce"), Color("c77958"), Color("a6bd91")]
		var unit := clampf(size.x / 1300.0, 0.65, 1.5)
		for piece in pieces:
			var t := age - 1.60 - float(piece.delay)
			if t < 0.0 or t > 3.2: continue
			var side := float(piece.side)
			var at := Vector2(size.x * (0.12 + side * 0.76 + (1.0 - side * 2.0) * float(piece.vx) * t),
				size.y * (0.48 + float(piece.vy) * t + 0.23 * t * t))
			if not Rect2(Vector2.ZERO, size).has_point(at): continue
			var tint: Color = colors[int(piece.color)]
			tint.a = 1.0 - smoothstep(2.3, 3.2, t)
			draw_set_transform(at, t * float(piece.spin), Vector2.ONE)
			var paper := Rect2(Vector2(-5, -3) * unit, Vector2(float(piece.width), 6) * unit)
			draw_rect(paper, tint)
			draw_rect(paper, Color(0.15, 0.12, 0.09, tint.a), false, unit, true)
		draw_set_transform(Vector2.ZERO)

var winner := 2
var age := 0.0
var _shade: ColorRect
var _paper: PaperBurst
var _focus := Callable()
var _last_size := Vector2.ZERO

func _init() -> void:
	name = "OffWorkResultBackdrop"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_meta("pointer_passthrough", true)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func configure(value: int, focus_point: Callable) -> void:
	winner = value
	_focus = focus_point
	_shade = ColorRect.new()
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shader := Shader.new()
	shader.code = SHADER
	var shade := ShaderMaterial.new()
	shade.shader = shader
	shade.set_shader_parameter("celebration", 0.0 if winner == 1 else 1.0)
	_shade.material = shade
	add_child(_shade)
	_paper = PaperBurst.new()
	_paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_paper)
	if winner == 0: _paper.seed_pieces()
	_update_visuals()

func _process(delta: float) -> void:
	if not is_visible_in_tree() or _shade == null: return
	age += delta
	_update_visuals()

func _update_visuals() -> void:
	if _shade == null: return
	var shade := _shade.material as ShaderMaterial
	var strength := smoothstep(0.12, 1.55, age)
	shade.set_shader_parameter("amount", strength * (0.24 if winner == 2 else 1.0))
	shade.set_shader_parameter("burst", (1.0 - smoothstep(1.9, 3.5, age)) * smoothstep(1.5, 1.8, age))
	var area := get_viewport_rect().size
	if area != _last_size and area.x > 0 and area.y > 0:
		_last_size = area
		var point: Vector2 = _focus.call() if _focus.is_valid() else area * Vector2(0.5, 0.72)
		shade.set_shader_parameter("focus", point / area)
	_paper.age = age
	_paper.queue_redraw()

func finish() -> void:
	age = maxf(age, 4.8)
	_update_visuals()

func refresh_focus() -> void:
	# 同一帧倒带或重开可能已移除这层，丢弃上一轮布局的延迟刷新。
	if not is_inside_tree() or is_queued_for_deletion(): return
	_last_size = Vector2.ZERO
	_update_visuals()
