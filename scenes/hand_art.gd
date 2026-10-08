# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 系统光标与撕牌手势共享轮廓；轮廓只平滑一次，光标图片只在尺寸/姿势改变时生成。
const INK := Color(0.18, 0.16, 0.12)
const PAPER := Color(0.96, 0.92, 0.81)
const ANGRY := Color(0.72, 0.19, 0.15)
const CURSOR_LIMIT := 128 # 同时遵守桌面建议值与 Web 硬上限。
const ANGLE := -0.12
static var _outlines := {}
static var _borders := {}
static var _cursors := {}
static var _creases := [
	{"points": PackedVector2Array([Vector2(7, 26), Vector2(14, 29), Vector2(18, 25)]), "width": 1.8, "color": INK},
	{"points": PackedVector2Array([Vector2(23, 27), Vector2(23, 35)]), "width": 1.7, "color": INK},
	{"points": PackedVector2Array([Vector2(10, 49), Vector2(24, 48)]), "width": 1.7, "color": INK},
]
static var _anger_lines := [
	{"points": PackedVector2Array([Vector2(37, 12), Vector2(33, 17), Vector2(39, 18)]), "width": 2.2, "color": ANGRY},
	{"points": PackedVector2Array([Vector2(35, 25), Vector2(39, 21), Vector2(43, 25)]), "width": 2.2, "color": ANGRY},
]

static func outline(grip: bool) -> PackedVector2Array:
	if _outlines.has(grip):
		return _outlines[grip]
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(3,-1), Vector2(6,2), Vector2(7,17),
		Vector2(10,16), Vector2(14,18), Vector2(15,21), Vector2(19,20),
		Vector2(23,22), Vector2(24,25), Vector2(28,25), Vector2(31,29),
		Vector2(31,39), Vector2(27,48), Vector2(27,56), Vector2(8,57),
		Vector2(7,48), Vector2(1,42), Vector2(-5,33), Vector2(-5,29),
		Vector2(-2,27), Vector2(2,29), Vector2(5,34), Vector2(1,16), Vector2(-1,4)])
	if grip:
		points = PackedVector2Array([Vector2(-4,14),Vector2(-3,8),Vector2(1,5),Vector2(5,6),Vector2(8,12),
			Vector2(9,5),Vector2(13,3),Vector2(17,5),Vector2(19,11),Vector2(20,7),Vector2(24,7),Vector2(28,12),
			Vector2(28,20),Vector2(32,23),Vector2(32,37),Vector2(27,46),Vector2(27,56),Vector2(8,57),
			Vector2(7,47),Vector2(0,41),Vector2(-8,31),Vector2(-9,26),Vector2(-6,22),Vector2(-2,22),
			Vector2(5,28),Vector2(6,25),Vector2(2,21)])
	for iteration in 2:
		var rounded := PackedVector2Array()
		for i in points.size():
			var next := points[(i + 1) % points.size()]
			rounded.append(points[i].lerp(next, 0.2))
			rounded.append(points[i].lerp(next, 0.8))
		points = rounded
	_outlines[grip] = points
	var border := points.duplicate()
	border.append(border[0])
	_borders[grip] = border
	return points

static func draw(canvas: Control, at: Vector2, angle: float, magnification: float,
		grip: bool, angry: bool, opacity: float) -> void:
	canvas.draw_set_transform(at, angle, Vector2.ONE * magnification)
	var points := outline(grip)
	canvas.draw_colored_polygon(points, Color(PAPER, opacity))
	canvas.draw_polyline(_borders[grip], Color(INK, opacity), 2.3, true)
	for line in _creases:
		canvas.draw_polyline(line.points, Color(line.color, opacity), line.width, true)
	if angry:
		for line in _anger_lines:
			canvas.draw_polyline(line.points, Color(line.color, opacity), line.width, true)

static func cursor_scale(canvas_scale: float, native_pixel_scale: float) -> float:
	# macOS/Web 的系统光标以逻辑点计尺寸，Canvas 使用实际输出像素。
	# 以 0.05 为档避免窗口每变化一个像素就产生一套新图片。
	return snappedf(clampf(canvas_scale / maxf(native_pixel_scale, 1.0), 0.2, 1.5), 0.05)

static func cursor(mode: String, magnification: float) -> Dictionary:
	var key := "%s:%.2f" % [mode, magnification]
	if _cursors.has(key):
		return _cursors[key]
	var grip := mode == "grip"
	var angry := mode == "angry"
	var hotspot := Vector2(16, 8) * magnification
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d"><g transform="translate(%f %f) rotate(%f) scale(%f)">' % [
		CURSOR_LIMIT, CURSOR_LIMIT, hotspot.x, hotspot.y, rad_to_deg(ANGLE) if angry else 0.0, magnification]
	svg += '<polygon points="%s" fill="#%s" stroke="#%s" stroke-width="2.3"/>' % [
		_svg_points(outline(grip)), PAPER.to_html(false), INK.to_html(false)]
	for line in _creases:
		svg += _svg_line(line)
	if angry:
		for line in _anger_lines:
			svg += _svg_line(line)
	svg += '</g></svg>'
	var image := Image.new()
	if image.load_svg_from_string(svg) != OK:
		return {}
	# 只裁透明外沿，减少系统复制量并让 Web 页边缘更容易容纳整张光标。
	var extent := image.get_used_rect().end + Vector2i.ONE
	image.crop(maxi(extent.x, ceili(hotspot.x) + 1), maxi(extent.y, ceili(hotspot.y) + 1))
	var result := {"image": image, "hotspot": hotspot}
	_cursors[key] = result
	return result

static func _svg_points(points: PackedVector2Array) -> String:
	var encoded := PackedStringArray()
	for point in points:
		encoded.append("%f,%f" % [point.x, point.y])
	return " ".join(encoded)

static func _svg_line(line: Dictionary) -> String:
	return '<polyline points="%s" fill="none" stroke="#%s" stroke-width="%f"/>' % [
		_svg_points(line.points), (line.color as Color).to_html(false), float(line.width)]
