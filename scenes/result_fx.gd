# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Materials = preload("res://scenes/effect_materials.gd")
const InkStamp = preload("res://scenes/ink_stamp.gd")

## 终局面板的小件：吉祥物的动作、标题旁的印章、胜利彩纸和失败褪色。
## 吉祥物就是用户牌的小人，印章是全游戏共用的那一枚，其余手绘；动画只改内部参数再重画，不动 scale/尺寸，
## 抽屉主题重排（会把控件 scale 归一）也打断不了它们。
const INK := Color(0.19, 0.17, 0.14)

## 结果吉祥物。idle 直接显示应用图标；cheer / slump 用的是用户牌上那个小人（同一张图，不另画角色），
## 只改它的动作：赢了原地蹦跳、手边闪动作线；输了缩着往下沉、略微发灰，头顶一朵下雨的乌云、额角一滴汗。
## 继承 TextureRect，结果面板里的类型、入场缩放动画都与原来一致。
class MascotPose extends TextureRect:
	var pose := "idle"
	## 小人那张图；cheer / slump 时与用户牌主图是同一份贴图。
	var figure: Texture2D
	var _time := 0.0

	func _init() -> void:
		name = "ResultMascot"
		expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_pose(value: String) -> void:
		pose = value
		figure = null if pose == "idle" else CardArt.res_icon_texture(CardDB.RES_USER)
		texture = load("res://assets/art/app_icon.png") if pose == "idle" or figure == null else null
		set_process(pose != "idle")
		queue_redraw()

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		# 12 fps 换一帧，与牌桌上的手绘抖线、悬停插画同一个节拍。
		var before := floorf(_time * 12.0)
		_time += delta
		if floorf(_time * 12.0) != before:
			queue_redraw()

	func _draw() -> void:
		if figure == null:
			return
		var unit := minf(size.x, size.y)
		var origin := (size - Vector2.ONE * unit) * 0.5
		var frame := floorf(_time * 12.0)
		var stroke := maxf(1.5, unit * 0.035)
		if pose == "cheer":
			# 一跳约 0.5 秒：腾空时拉长一点，落地那一帧压扁一点。
			var phase := fmod(frame, 6.0) / 6.0
			var hop := sin(phase * PI)
			var squash := Vector2(1.06, 0.92) if phase < 0.17 else Vector2(0.97, 1.04)
			_figure(origin + Vector2(0.5, 0.56 - hop * 0.08) * unit, unit * 0.92, squash, 0.0, Color.WHITE)
			if int(frame) % 2 == 0:
				for side in [-1.0, 1.0]:
					var base := origin + Vector2(0.5 + side * 0.36, 0.26 - hop * 0.08) * unit
					draw_line(base, base + Vector2(side * 0.05, -0.07) * unit, INK, stroke, true)
					draw_line(base + Vector2(side * 0.06, 0.06) * unit, base + Vector2(side * 0.12, 0.03) * unit, INK, stroke, true)
		else:
			_cloud(origin, unit, stroke, frame)
			# 乌云占了头顶，小人缩小、往下沉、微微歪着，云和头之间留出下雨的空当。
			var sway := sin(frame * 0.5) * 0.02
			_figure(origin + Vector2(0.5, 0.66) * unit, unit * 0.70, Vector2(1.0, 0.96), -0.10 + sway,
				Color(0.86, 0.86, 0.88))
			var head := origin + Vector2(0.66, 0.46 + fmod(frame, 12.0) / 12.0 * 0.04) * unit
			_sweat(head, unit * 0.05, stroke)

	## 按原图比例画用户牌小人：center 是图的中心，extent 是边长，squash 拉伸，tilt 绕脚底转。
	func _figure(center: Vector2, extent: float, squash: Vector2, tilt: float, tint: Color) -> void:
		var foot := center + Vector2(0, extent * 0.42)
		draw_set_transform(foot, tilt, squash)
		draw_texture_rect(figure, Rect2(Vector2(-extent * 0.5, -extent * 0.92), Vector2.ONE * extent), false, tint)
		draw_set_transform(Vector2.ZERO)

	func _sweat(at: Vector2, radius: float, stroke: float) -> void:
		var tip := at + Vector2(0, -radius * 2.2)
		var drop := PackedVector2Array([tip])
		for i in 9:
			var a := PI * (-0.15 + 1.3 * float(i) / 8.0)
			drop.append(at + Vector2(cos(a), sin(a)) * radius)
		draw_colored_polygon(drop, Color(0.70, 0.86, 0.95))
		drop.append(tip)
		draw_polyline(drop, INK, stroke * 0.6, true)

	## 头顶一朵乌云，墨线小雨按帧往下掉。
	func _cloud(origin: Vector2, unit: float, stroke: float, frame: float) -> void:
		var grey := Color(0.72, 0.71, 0.68)
		var puffs := [[Vector2(0.38, 0.12), 0.09], [Vector2(0.52, 0.08), 0.11], [Vector2(0.66, 0.12), 0.09],
			[Vector2(0.45, 0.16), 0.08], [Vector2(0.59, 0.16), 0.08]]
		for puff in puffs:
			draw_arc(origin + puff[0] * unit, puff[1] * unit, 0, TAU, 24, INK, stroke * 2.0, true)
		for puff in puffs:
			draw_circle(origin + puff[0] * unit, puff[1] * unit, grey)
		var fall := fmod(frame, 6.0) / 6.0
		for i in 4:
			var x := 0.39 + 0.08 * i
			var y := 0.26 + fmod(fall + 0.37 * i, 1.0) * 0.08
			draw_line(origin + Vector2(x, y) * unit, origin + Vector2(x - 0.012, y + 0.035) * unit, INK, stroke * 0.8, true)

## 标题旁的印章：与牌上的「到账 / 作废」、牌桌上的「上市 / 查封」是同一枚（ink_stamp.gd 的 2D 用法：
## 同一个着色器、同一张框、同一盒印泥），只是大小随标题字号变。slam 从 0 到 1 是从高处砸下来的过程。
class ResultStamp extends Control:
	var text := "":
		set(value):
			text = value
			_stamp_material = null
			queue_redraw()
	var slam := 0.0:
		set(value):
			slam = value
			queue_redraw()
	var _stamp_material: ShaderMaterial
	var _tilt := 0.0

	func _init() -> void:
		name = "ResultStamp"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tilt = Materials.rng().randf_range(InkStamp.TILT_MIN, InkStamp.TILT_MAX)

	## 跟着标题字走：标题居中且字号随抽屉缩放变化，章始终贴在字的右边。
	func _process(_delta: float) -> void:
		var title := get_parent() as Label
		if title == null or not is_visible_in_tree():
			return
		var title_size := title.get_theme_font_size("font_size")
		var text_width := title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, title_size).x
		var width := float(title_size) * InkStamp.PANEL_PER_TITLE
		var wanted := Vector2(width, width * InkStamp.ASPECT)
		if not wanted.is_equal_approx(size):
			size = wanted
			queue_redraw()
		position = Vector2(title.size.x * 0.5 + text_width * 0.5 + title_size * 0.3, (title.size.y - size.y) * 0.5)

	func _draw() -> void:
		if slam <= 0.0 or text.is_empty():
			return
		if _stamp_material == null:
			_stamp_material = InkStamp.canvas_material(text)
			material = _stamp_material
		var t := clampf(slam, 0.0, 1.0)
		# 前 70% 落下（放大→原大），后 30% 落定后的一点回弹；与牌桌上砸章同一套倍数。
		var scale_factor := lerpf(InkStamp.SLAM_SCALE, 1.0, smoothstep(0.0, 0.7, t)) \
			+ sin(clampf((t - 0.7) / 0.3, 0.0, 1.0) * PI) * (InkStamp.BOUNCE - 1.0)
		_stamp_material.set_shader_parameter("opacity", clampf(t * 3.0, 0.0, 1.0))
		draw_set_transform(size * 0.5, deg_to_rad(_tilt), Vector2.ONE * scale_factor)
		draw_texture_rect(InkStamp.frame_texture(), Rect2(-size * 0.5, size), false)
		draw_set_transform(Vector2.ZERO)

## 胜利彩纸：底板四色的小纸片带墨边，从屏幕顶上撒下来；撒完一轮就停，不吃鼠标。
class Confetti extends Control:
	var pieces: Array[Dictionary] = []
	var _spawned := 0
	var _elapsed := 0.0
	const COUNT := 72
	const SPAWN_TIME := 1.4

	func _init() -> void:
		name = "ResultConfetti"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_elapsed += delta
		var area := get_viewport_rect().size
		var colors := [Palette.plate_color("plate_cash", "band"), Palette.plate_color("plate_user", "band"),
			Palette.plate_color("plate_t1_money", "band"), Palette.plate_color("plate_buff_up", "band"),
			Palette.plate_color("plate_attack", "band")]
		while _spawned < COUNT and _spawned < int(_elapsed / SPAWN_TIME * COUNT) + 1:
			_spawned += 1
			pieces.append({"at": Vector2(Materials.rng().randf() * area.x, -20.0 - Materials.rng().randf() * 40.0),
				"speed": Materials.rng().randf_range(110.0, 230.0), "sway": Materials.rng().randf_range(14.0, 34.0), "phase": Materials.rng().randf() * TAU,
				"spin": Materials.rng().randf_range(-5.0, 5.0), "angle": Materials.rng().randf() * TAU,
				"size": Vector2(Materials.rng().randf_range(8.0, 15.0), Materials.rng().randf_range(5.0, 9.0)) * clampf(area.x / 1100.0, 0.8, 2.0),
				"color": colors[Materials.rng().randi() % colors.size()]})
		for piece in pieces:
			piece["at"] += Vector2(cos(_elapsed * 3.0 + piece["phase"]) * piece["sway"] * delta, piece["speed"] * delta)
			piece["angle"] += piece["spin"] * delta
		pieces = pieces.filter(func(piece): return piece["at"].y < area.y + 30.0)
		queue_redraw()
		if _spawned >= COUNT and pieces.is_empty():
			set_process(false)

	func _draw() -> void:
		for piece in pieces:
			var half: Vector2 = piece["size"] * 0.5
			draw_set_transform(piece["at"], piece["angle"], Vector2.ONE)
			draw_rect(Rect2(-half, half * 2.0), piece["color"])
			draw_rect(Rect2(-half, half * 2.0), INK, false, 1.5, true)
		draw_set_transform(Vector2.ZERO)

## 失败褪色：读取已经画好的牌桌与顶栏，按 amount 退成偏冷的灰；透明窗口的空白处保持透明。
class Desaturate extends ColorRect:
	const SHADER := """
shader_type canvas_item;
uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;
uniform float amount = 0.0;
void fragment() {
	vec4 c = textureLod(screen, SCREEN_UV, 0.0);
	float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	vec3 grey = vec3(g) * vec3(0.95, 0.97, 1.0);
	COLOR = vec4(mix(c.rgb, grey, amount) * (1.0 - amount * 0.12), c.a);
}
"""
	static var _shader: Shader

	func _init() -> void:
		name = "ResultDesaturate"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# 非抽屉模式会整体缩放结果层；留足边距，缩小后仍盖满窗口。
		offset_left = -4000
		offset_top = -4000
		offset_right = 4000
		offset_bottom = 4000
		if _shader == null:
			_shader = Shader.new()
			_shader.code = SHADER
		var shade := ShaderMaterial.new()
		shade.shader = _shader
		material = shade

	func set_amount(value: float) -> void:
		(material as ShaderMaterial).set_shader_parameter("amount", value)
