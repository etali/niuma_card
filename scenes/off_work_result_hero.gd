# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Control

## 结算卡上的纸片舞台。全部尺寸都在 520×220 的逻辑画布内，
## 抽屉主题重排只会改变可用区域，不会打断内部的落印、欢呼和垂头动作。
const InkStamp = preload("res://scenes/ink_stamp.gd")
const EMPLOYEE: Texture2D = preload("res://assets/art/icon/work_employee.png")
const DESIGN_SIZE := Vector2(520, 220)
const INK := Color("302b24")
const PAPER := Color("fff0ca")
const GOLD := Color("e7b64d")
const COLD := Color("cad0c6")
const RUST := Color("a9473b")
const LAND_AT := 0.18

var age := 0.0
var winner := 2
var _stamp: Seal
var _unit := 1.0
var _origin := Vector2.ZERO

class Seal extends Control:
	var progress := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if progress <= 0.0: return
		var t := clampf(progress, 0.0, 1.0)
		var factor := lerpf(1.20, 1.0, t * t)
		if t >= 1.0: factor = 1.0
		draw_set_transform(size * 0.5, -0.055, Vector2.ONE * factor)
		draw_texture_rect(InkStamp.frame_texture(), Rect2(-size * 0.5, size), false)
		draw_set_transform(Vector2.ZERO)

func _init() -> void:
	name = "OffWorkResultHero"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_meta("pointer_passthrough", true)
	resized.connect(_layout_stamp)

func configure(value: int) -> void:
	winner = value
	age = 0.0
	if _stamp == null:
		_stamp = Seal.new()
		_stamp.name = "OffWorkResultSeal"
		add_child(_stamp)
	var word := "下班！" if winner == 0 else ("加班" if winner == 1 else "一起下班")
	var ink := InkStamp.canvas_material(word)
	ink.set_shader_parameter("ink", RUST if winner == 1 else INK)
	_stamp.material = ink
	_layout_stamp()
	queue_redraw()

func finish() -> void:
	age = maxf(age, 0.6)
	_update_stamp()
	queue_redraw()

func _process(delta: float) -> void:
	if not is_visible_in_tree(): return
	var previous_frame := int(age * 24.0)
	age += delta
	if previous_frame == int(age * 24.0): return
	_update_stamp()
	queue_redraw()

func _layout_stamp() -> void:
	_unit = maxf(0.0, minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y))
	_origin = (size - DESIGN_SIZE * _unit) * 0.5
	if _stamp != null:
		_stamp.position = _origin + Vector2(96, 75) * _unit
		_stamp.size = Vector2(328, 328 * InkStamp.ASPECT) * _unit
		_update_stamp()
	queue_redraw()

func _update_stamp() -> void:
	if _stamp == null: return
	_stamp.progress = clampf(age / LAND_AT, 0.0, 1.0)
	(_stamp.material as ShaderMaterial).set_shader_parameter("opacity", clampf(age / 0.14, 0.0, 1.0))
	_stamp.queue_redraw()

func _draw() -> void:
	if _unit <= 0.0: return
	draw_set_transform(_origin, 0.0, Vector2.ONE * _unit)
	if winner == 0:
		_draw_celebration()
	elif winner == 1:
		_draw_overtime()
	else:
		_draw_together()
	_draw_banner()
	draw_set_transform(Vector2.ZERO)

func _draw_banner() -> void:
	var paper := COLD if winner == 1 else PAPER
	var accent := RUST if winner == 1 else GOLD
	var points := PackedVector2Array([
		Vector2(68, 98), Vector2(444, 80), Vector2(454, 194),
		Vector2(61, 210), Vector2(70, 192), Vector2(62, 175),
	])
	var shadow := PackedVector2Array()
	for p: Vector2 in points: shadow.append(p + Vector2(6, 6))
	draw_colored_polygon(shadow, Color(INK, 0.22))
	draw_colored_polygon(points, paper)
	var border := points.duplicate()
	border.append(points[0])
	draw_polyline(border, INK, 2.5, true)
	# 两端露出的彩纸像解开的一条封条；失败时换成沉重的红色留岗条。
	draw_colored_polygon(PackedVector2Array([
		Vector2(15, 133), Vector2(66, 123), Vector2(64, 177),
		Vector2(19, 189), Vector2(31, 160),
	]), accent)
	draw_colored_polygon(PackedVector2Array([
		Vector2(449, 107), Vector2(503, 120), Vector2(487, 146),
		Vector2(500, 166), Vector2(452, 157),
	]), accent)
	# 少量印刷短线保留纸感，避免把整个面板做成另一张普通提示框。
	draw_line(Vector2(80, 194), Vector2(112, 193), Color(INK, 0.24), 2.0, true)
	draw_line(Vector2(402, 96), Vector2(434, 94), Color(INK, 0.24), 2.0, true)

func _draw_celebration() -> void:
	var landed := smoothstep(0.0, LAND_AT, age)
	for i: int in 13:
		var angle := PI + float(i) / 12.0 * PI
		var direction := Vector2(cos(angle), sin(angle))
		var start := Vector2(260, 115) + direction * Vector2(136, 58)
		var end := Vector2(260, 115) + direction * Vector2(224, 98) * landed
		if landed > 0.75:
			draw_line(start, end, Color(GOLD, 0.75), 4.0 if i % 2 == 0 else 2.0, true)
	for i: int in 3:
		var phase := age * 2.6 + float(i) * 1.4
		var hop := maxf(0.0, sin(phase)) * (9.0 if i == 1 else 5.0)
		var at := Vector2(194 + i * 66, 87 - hop)
		_draw_employee(at, 82.0 if i == 1 else 68.0, sin(phase) * 0.055, Color.WHITE)
	_draw_star(Vector2(100, 56), 13.0, GOLD)
	_draw_star(Vector2(416, 48), 17.0, GOLD)
	_draw_star(Vector2(452, 77), 8.0, PAPER)
	for i: int in 7:
		var x := 76.0 + float(i) * 61.0
		var y := 28.0 + float(i % 3) * 12.0 + sin(age * 1.5 + i) * 2.0
		_draw_paper(Vector2(x, y), Vector2(10, 5), float(i) * 0.8 + age * 0.1,
			GOLD if i % 2 == 0 else RUST)

func _draw_overtime() -> void:
	# 冷灯只照着没走的小人，文件从两边挤进来；所有悲惨姿态都留在画面内。
	draw_colored_polygon(PackedVector2Array([
		Vector2(253, 12), Vector2(282, 12), Vector2(329, 101), Vector2(203, 101),
	]), Color(0.89, 0.91, 0.77, 0.23))
	draw_line(Vector2(270, 0), Vector2(270, 15), INK, 3.0, true)
	draw_colored_polygon(PackedVector2Array([
		Vector2(251, 13), Vector2(283, 13), Vector2(295, 28), Vector2(239, 28),
	]), INK)
	draw_line(Vector2(244, 29), Vector2(290, 29), PAPER, 3.0, true)
	_draw_employee(Vector2(270, 94), 66.0, -0.17 + sin(age * 1.2) * 0.008, Color(0.75, 0.80, 0.79), true)
	for side: int in [-1, 1]:
		var x := 260.0 + float(side) * 112.0
		for sheet: int in 5:
			var at := Vector2(x + float(sheet) * float(side) * 2.0, 92.0 - float(sheet) * 8.0)
			_draw_paper(at, Vector2(66, 28), float(side) * 0.065, COLD.darkened(float(sheet) * 0.022))
			draw_line(at + Vector2(-22, -5), at + Vector2(17, -5), Color(INK, 0.3), 1.5, true)
			draw_line(at + Vector2(-22, 1), at + Vector2(6, 1), Color(INK, 0.3), 1.5, true)
	# 两根短短的垂线比不停抖动更有疲惫感。
	draw_line(Vector2(304, 48), Vector2(304, 62), Color(INK, 0.55), 2.0, true)
	draw_line(Vector2(312, 51), Vector2(312, 68), Color(INK, 0.4), 2.0, true)

func _draw_together() -> void:
	for i: int in 2:
		var at := Vector2(226 + i * 68, 91 + sin(age * 1.8 + i) * 2.0)
		_draw_employee(at, 78.0, -0.04 if i == 0 else 0.04, Color.WHITE)
	_draw_star(Vector2(134, 57), 10.0, GOLD)
	_draw_star(Vector2(382, 54), 10.0, GOLD)

func _draw_employee(foot: Vector2, extent: float, tilt: float, tint: Color, tired := false) -> void:
	draw_set_transform(_origin + foot * _unit, tilt, Vector2.ONE * _unit)
	draw_texture_rect(EMPLOYEE, Rect2(Vector2(-extent * 0.5, -extent), Vector2.ONE * extent), false, tint)
	if tired:
		# 原员工图保持完整，只把原来的笑嘴盖成同色纸面，再补一条下垂的嘴。
		# 坐标取自 384px 原图，跟着整个人物的倾斜和缩放走。
		var pixel := extent / 384.0
		var top := Vector2(-extent * 0.5, -extent)
		var mouth := top + Vector2(194, 179) * pixel
		var patch := PackedVector2Array()
		for i: int in 24:
			var angle := float(i) * TAU / 24.0
			patch.append(mouth + Vector2(cos(angle) * 34, sin(angle) * 17) * pixel)
		draw_colored_polygon(patch, Color(248.0 / 255.0, 235.0 / 255.0, 207.0 / 255.0) * tint)
		draw_arc(top + Vector2(194, 185) * pixel, 13.0 * pixel, PI, TAU, 12, INK, maxf(0.9, 5.0 * pixel), true)
		draw_line(top + Vector2(149, 126) * pixel, top + Vector2(166, 131) * pixel, INK, maxf(0.8, 4.0 * pixel), true)
		draw_line(top + Vector2(220, 130) * pixel, top + Vector2(236, 126) * pixel, INK, maxf(0.8, 4.0 * pixel), true)
	draw_set_transform(_origin, 0.0, Vector2.ONE * _unit)

func _draw_paper(at: Vector2, extent: Vector2, tilt: float, fill: Color) -> void:
	draw_set_transform(_origin + at * _unit, tilt, Vector2.ONE * _unit)
	var box := Rect2(-extent * 0.5, extent)
	draw_rect(box, fill)
	draw_rect(box, INK, false, 1.5, true)
	draw_set_transform(_origin, 0.0, Vector2.ONE * _unit)

func _draw_star(at: Vector2, radius: float, fill: Color) -> void:
	var points := PackedVector2Array()
	for i: int in 8:
		var angle := float(i) * TAU / 8.0
		points.append(at + Vector2(cos(angle), sin(angle)) * radius * (1.0 if i % 2 == 0 else 0.32))
	draw_colored_polygon(points, fill)
	points.append(points[0])
	draw_polyline(points, INK, 1.8, true)
