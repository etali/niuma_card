# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name DrawerCameraFit
extends RefCounted

## 斜俯视镜头的纯数学拟合器。正交入口保留给旧桌面构图，抽屉使用真实透视。
## world_rect 使用 x/z 平面坐标，y_min/y_max 是卡面可能达到的高度。
## 返回的 camera_target / camera_position 可直接用于 Camera3D.look_at；根节点不需要缩放。

static func fit(viewport_size: Vector2,
		content_rect: Rect2,
		world_rect: Rect2,
		y_min: float,
		y_max: float,
		pitch_degrees: float,
		target_pixels_per_unit: float = 0.0,
		horizontal_margin_px: float = 12.0) -> Dictionary:
	var vp := Vector2(maxf(viewport_size.x, 1.0), maxf(viewport_size.y, 1.0))
	var content := Rect2(content_rect.position,
		Vector2(maxf(content_rect.size.x, 1.0), maxf(content_rect.size.y, 1.0)))
	var pitch := clampf(pitch_degrees, 1.0, 89.0)
	var rad := deg_to_rad(pitch)
	var s := sin(rad)
	var c := cos(rad)
	var y0 := minf(y_min, y_max)
	var y1 := maxf(y_min, y_max)
	var margin := clampf(horizontal_margin_px, 0.0, 16.0)
	var avail_w := maxf(content.size.x - margin * 2.0, 1.0)
	var avail_h := maxf(content.size.y - margin * 2.0, 1.0)

	# 相机 size 是整个 viewport 的纵向世界跨度（KEEP_HEIGHT）。
	# 水平约束需乘 viewport 高/内容宽，垂直约束需乘 viewport 高/内容高。
	var projected_vertical_span := world_rect.size.y * s + (y1 - y0) * c
	var size_for_vertical := projected_vertical_span * vp.y / avail_h
	var size_for_horizontal := world_rect.size.x * vp.y / avail_w
	var camera_size := maxf(maxf(size_for_vertical, size_for_horizontal), 0.001)
	var ppu := vp.y / camera_size

	# 让世界包围盒中心落在 content_rect 中心。屏幕中心仍是 viewport 中心，
	# 因此 target 需要补偿 HUD/边距造成的像素偏移。
	var vp_center := vp * 0.5
	var content_center := content.position + content.size * 0.5
	var world_center_x := world_rect.position.x + world_rect.size.x * 0.5
	var world_center_z := world_rect.position.y + world_rect.size.y * 0.5
	var world_center_y := (y0 + y1) * 0.5
	var target_x := world_center_x + (vp_center.x - content_center.x) / ppu
	var projected_center := world_center_y * c - world_center_z * s
	var target_projected_center := projected_center + (content_center.y - vp_center.y) / ppu
	var target_z := (world_center_y * c - target_projected_center) / maxf(s, 0.001)
	var target := Vector3(target_x, world_center_y, target_z)

	# 只决定相机距离，不改变投影比例；这会保持固定 pitch 的立体感。
	var distance := 24.0
	var camera_position := target + Vector3(0.0, distance * s, distance * c)
	var projected := projected_bounds(vp, camera_size, target, pitch, world_rect, y0, y1)
	return {
		"camera_size": camera_size,
		"camera_target": target,
		"camera_position": camera_position,
		"pitch_degrees": pitch,
		"pixels_per_unit": ppu,
		"projected_bounds": projected,
		"horizontal_margin_px": margin,
		"target_pixels_per_unit": target_pixels_per_unit,
	}

## 固定视角与 FOV，求能容纳全部卡牌高度的最近相机距离。
## 在相机 right/up 平面平移光轴来对齐 HUD 下的内容区，而不是缩放牌桌。
## 对每个角点求允许的相机偏移区间；交集存在就代表八个角均在画面内。
static func fit_perspective(viewport_size: Vector2,
		content_rect: Rect2,
		world_rect: Rect2,
		y_min: float,
		y_max: float,
		pitch_degrees: float = 60.0,
		fov_degrees: float = 44.0,
		margin_px: float = 8.0) -> Dictionary:
	var vp := Vector2(maxf(viewport_size.x, 1.0), maxf(viewport_size.y, 1.0))
	var margin := clampf(margin_px, 0.0, minf(content_rect.size.x, content_rect.size.y) * 0.2)
	var content := content_rect.grow(-margin)
	var pitch := clampf(pitch_degrees, 20.0, 85.0)
	var fov := clampf(fov_degrees, 20.0, 70.0)
	var rad := deg_to_rad(pitch)
	var back := Vector3(0.0, sin(rad), cos(rad))
	var up := Vector3(0.0, cos(rad), -sin(rad))
	var center := Vector3(world_rect.get_center().x, (y_min + y_max) * 0.5, world_rect.get_center().y)
	var focal := vp.y * 0.5 / tan(deg_to_rad(fov) * 0.5)
	var slopes := Vector4((content.position.x - vp.x * 0.5) / focal,
		(content.end.x - vp.x * 0.5) / focal,
		(vp.y * 0.5 - content.end.y) / focal,
		(vp.y * 0.5 - content.position.y) / focal)
	var vertices: Array[Vector3] = []
	var closest := 0.1
	for x in [world_rect.position.x, world_rect.end.x]:
		for z in [world_rect.position.y, world_rect.end.y]:
			for y in [minf(y_min, y_max), maxf(y_min, y_max)]:
				var delta := Vector3(x, y, z) - center
				var vertex := Vector3(delta.x, delta.dot(up), delta.dot(back))
				vertices.append(vertex)
				closest = maxf(closest, vertex.z + 0.1)
	var low := closest
	var high := maxf(closest * 2.0, 16.0)
	while not _perspective_offsets(vertices, slopes, high).get("fits", false):
		high *= 2.0
	for i in 48:
		var mid := (low + high) * 0.5
		if _perspective_offsets(vertices, slopes, mid)["fits"]:
			high = mid
		else:
			low = mid
	var distance := high + 0.0001
	var offsets := _perspective_offsets(vertices, slopes, distance)
	var optical_target := center + Vector3.RIGHT * float(offsets["right"]) + up * float(offsets["up"])
	var result := {
		"projection": Camera3D.PROJECTION_PERSPECTIVE,
		"camera_target": optical_target,
		"camera_position": optical_target + back * distance,
		"distance": distance,
		"pitch_degrees": pitch,
		"fov": fov,
		"focal_pixels": focal,
		"pixels_per_unit": focal / distance,
		"horizontal_margin_px": margin,
	}
	var bounds := Rect2()
	var first := true
	for x in [world_rect.position.x, world_rect.end.x]:
		for z in [world_rect.position.y, world_rect.end.y]:
			for y in [minf(y_min, y_max), maxf(y_min, y_max)]:
				var pixel := project_point(vp, result, Vector3(x, y, z))
				bounds = Rect2(pixel, Vector2.ZERO) if first else bounds.expand(pixel)
				first = false
	result["projected_bounds"] = bounds
	return result

static func _perspective_offsets(vertices: Array[Vector3], slopes: Vector4, distance: float) -> Dictionary:
	var min_right := -INF
	var max_right := INF
	var min_up := -INF
	var max_up := INF
	for vertex in vertices:
		var depth := distance - vertex.z
		min_right = maxf(min_right, vertex.x - slopes.y * depth)
		max_right = minf(max_right, vertex.x - slopes.x * depth)
		min_up = maxf(min_up, vertex.y - slopes.w * depth)
		max_up = minf(max_up, vertex.y - slopes.z * depth)
	return {"fits": min_right <= max_right and min_up <= max_up,
		"right": (min_right + max_right) * 0.5, "up": (min_up + max_up) * 0.5}

static func apply(camera: Camera3D, fit_result: Dictionary) -> void:
	if camera == null:
		return
	camera.projection = int(fit_result.get("projection", Camera3D.PROJECTION_ORTHOGONAL))
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = float(fit_result.get("camera_size", camera.size))
	camera.fov = float(fit_result.get("fov", camera.fov))
	camera.position = fit_result.get("camera_position", camera.position)
	camera.look_at(fit_result.get("camera_target", Vector3.ZERO), Vector3.UP)


static func project_point(viewport_size: Vector2,
		fit_result: Dictionary,
		point: Vector3) -> Vector2:
	var vp := Vector2(maxf(viewport_size.x, 1.0), maxf(viewport_size.y, 1.0))
	if int(fit_result.get("projection", Camera3D.PROJECTION_ORTHOGONAL)) == Camera3D.PROJECTION_PERSPECTIVE:
		var rad := deg_to_rad(float(fit_result["pitch_degrees"]))
		var delta: Vector3 = point - (fit_result["camera_position"] as Vector3)
		var depth := -delta.dot(Vector3(0.0, sin(rad), cos(rad)))
		var focal := float(fit_result["focal_pixels"])
		return vp * 0.5 + Vector2(delta.x, -delta.dot(Vector3(0.0, cos(rad), -sin(rad)))) * focal / depth
	var target: Vector3 = fit_result.get("camera_target", Vector3.ZERO)
	var ppu := float(fit_result.get("pixels_per_unit", 1.0))
	var rad := deg_to_rad(float(fit_result.get("pitch_degrees", 62.0)))
	var projected := point.y * cos(rad) - point.z * sin(rad)
	var target_projected := target.y * cos(rad) - target.z * sin(rad)
	var center := vp * 0.5
	return Vector2(center.x + (point.x - target.x) * ppu,
		center.y - (projected - target_projected) * ppu)

static func projected_bounds(viewport_size: Vector2,
		camera_size: float,
		target: Vector3,
		pitch_degrees: float,
		world_rect: Rect2,
		y_min: float,
		y_max: float) -> Rect2:
	var result := Rect2()
	var first := true
	for x in [world_rect.position.x, world_rect.end.x]:
		for z in [world_rect.position.y, world_rect.end.y]:
			for y in [minf(y_min, y_max), maxf(y_min, y_max)]:
				var p := project_point(viewport_size, {
					"camera_target": target,
					"pixels_per_unit": viewport_size.y / maxf(camera_size, 0.001),
					"pitch_degrees": pitch_degrees,
				}, Vector3(x, y, z))
				if first:
					result = Rect2(p, Vector2.ZERO)
					first = false
				else:
					result = result.expand(p)
	return result

## 透视桌面的可放置区是梯形。按每张牌的实际高度、前后位置求约束，
## 使远侧左右空地同样能放牌；整摞只移动锚点，不改变比例或成员间距。
## 抽屉相机固定无 yaw/roll，先夹 z 后夹 x 可精确解这组投影视锥不等式。
static func clamp_anchor_to_screen(camera: Camera3D, screen: Rect2,
		at: Vector3, offsets: Array, card_size: Vector3,
		world_padding: float = 0.0, layout_viewport := Vector2.ZERO, overview: Dictionary = {}) -> Vector3:
	if camera == null or camera.projection != Camera3D.PROJECTION_PERSPECTIVE or not screen.has_area():
		return at
	# 抽屉动画只裁切窗口，并未改变牌桌构图。调用方可提供与screen同一帧的
	# 完整视口，避免当前小窗口与旧内容区混算，把静置牌或后台产出推离原位。
	var vp := layout_viewport if layout_viewport.x > 0 and layout_viewport.y > 0 else camera.get_viewport().get_visible_rect().size
	var focal := vp.y * 0.5 / tan(deg_to_rad(float(overview.get("fov", camera.fov))) * 0.5)
	var center := vp * 0.5
	var origin: Vector3 = overview.get("camera_position", camera.global_position)
	var back := camera.global_transform.basis.z
	var up := camera.global_transform.basis.y
	var top_slope := (center.y - screen.position.y) / focal
	var bottom_slope := (center.y - screen.end.y) / focal
	var left_slope := (screen.position.x - center.x) / focal
	var right_slope := (screen.end.x - center.x) / focal
	var half := Vector2(card_size.x, card_size.z) * 0.5 + Vector2.ONE * world_padding
	var members := offsets if not offsets.is_empty() else [Vector3.ZERO]
	var north := -INF
	var south := INF
	for member: Vector3 in members:
		# 卡面上缘和底缘共享其落桌高度；薄卡厚度也计入可见外轮廓。
		for y in [at.y + member.y, at.y + member.y + card_size.y * 0.5]:
			var height_from_camera: float = y - origin.y
			var top_z := origin.z - (up.y + top_slope * back.y) * height_from_camera / (up.z + top_slope * back.z)
			var bottom_z := origin.z - (up.y + bottom_slope * back.y) * height_from_camera / (up.z + bottom_slope * back.z)
			north = maxf(north, top_z + half.y - member.z)
			south = minf(south, bottom_z - half.y - member.z)
	at.z = clampf(at.z, north, south) if north <= south else (north + south) * 0.5
	var left := -INF
	var right := INF
	for member: Vector3 in members:
		for z in [at.z + member.z - half.y, at.z + member.z + half.y]:
			for y in [at.y + member.y, at.y + member.y + card_size.y * 0.5]:
				var depth := -(Vector3(0.0, y, z) - origin).dot(back)
				left = maxf(left, origin.x + left_slope * depth + half.x - member.x)
				right = minf(right, origin.x + right_slope * depth - half.x - member.x)
	at.x = clampf(at.x, left, right) if left <= right else (left + right) * 0.5
	return at
