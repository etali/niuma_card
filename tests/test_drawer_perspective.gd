# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const CameraFit = preload("res://scenes/drawer_camera_fit.gd")

## 真实 Camera3D 投影验证：不是只改俯仰角的正交镜头，也不缩放卡牌模拟透视。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var world := Rect2(-10.8, -5.25, 21.6, 11.3)
	var cases := [
		{"size": Vector2i(1280, 800), "dpi": 1.0},
		{"size": Vector2i(1920, 1200), "dpi": 1.0},
		{"size": Vector2i(2800, 1100), "dpi": 1.0},
		{"size": Vector2i(3840, 2400), "dpi": 2.0},
	]
	var scene := Node3D.new()
	root.add_child(scene)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.current = true
	for item in cases:
		var size: Vector2i = item["size"]
		var dpi: float = item["dpi"]
		root.size = size
		root.content_scale_size = Vector2i.ZERO
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		await process_frame
		var vp := Vector2(size)
		var content := Rect2(16 * dpi, 90 * dpi, vp.x - 32 * dpi, vp.y - 175 * dpi)
		var fitted := CameraFit.fit_perspective(vp, content, world, 0.0, 1.7, 60.0, 44.0, 8 * dpi)
		CameraFit.apply(camera, fitted)
		var tag := "%dx%d@%.0f" % [size.x, size.y, dpi]
		check(camera.projection == Camera3D.PROJECTION_PERSPECTIVE, "%s真正启用透视投影" % tag)
		check(scene.scale == Vector3.ONE and camera.scale == Vector3.ONE, "%s世界及相机不靠缩放变形" % tag)
		for x in [world.position.x, world.end.x]:
			for z in [world.position.y, world.end.y]:
				for y in [0.0, 1.7]:
					var vertex := Vector3(x, y, z)
					var pixel := camera.unproject_position(vertex)
					check(content.grow(0.1).has_point(pixel), "%s牌桌八角含拖拽高度在内容区%s" % [tag, vertex])
					check(pixel.distance_to(CameraFit.project_point(vp, fitted, vertex)) < 0.1,
						"%s纯数学拟合与真实引擎透视一致%s" % [tag, vertex])
		# 远侧梯形较宽的空地也能真正放牌，同时多张牌、抬起高度不越屏。
		var near_side := Vector3.ZERO
		var far_side := Vector3.ZERO
		for height in [0.05, 1.2]:
			for z in [1.5, 4.8]:
				for side in [-1.0, 1.0]:
					var at := CameraFit.clamp_anchor_to_screen(camera, content, Vector3(side * 10000.0, height, z),
						[Vector3.ZERO, Vector3(0.02, 0.2, 0.3)], Vector3(1.2, 0.08, 1.6), 0.08)
					var edge := INF
					for offset in [Vector3.ZERO, Vector3(0.02, 0.2, 0.3)]:
						for dx in [-0.6, 0.6]:
							for dz in [-0.8, 0.8]:
								var pixel := camera.unproject_position(at + offset + Vector3(dx, 0.04, dz))
								check(content.grow(0.1).has_point(pixel), "%s整摞贴边z%.1f高度%.2f完整卡角在框" % [tag, z, height])
								edge = minf(edge, absf(pixel.x - (content.position.x if side < 0.0 else content.end.x)))
					check(edge < 20.0 * dpi, "%s透视左右可放到描边边距内" % tag)
					if height == 0.05 and side > 0.0:
						if z == 1.5:
							far_side = at
						else:
							near_side = at
		check(far_side.x > near_side.x + 0.1, "%s远处额外左右桌面可放牌，未被内接矩形丢弃" % tag)
		for request in [Vector3(-10000, 0.05, 10000), Vector3(10000, 1.2, -10000), Vector3(10000, 1.2, 10000)]:
			var pile_offsets := [Vector3.ZERO, Vector3(0.05, -0.1, 0.9), Vector3(-0.05, 0.2, 1.8)]
			var anchor := CameraFit.clamp_anchor_to_screen(camera, content, request, pile_offsets, Vector3(1.2, 0.08, 1.6), 0.08)
			for offset in pile_offsets:
				for dx in [-0.6, 0.6]:
					for dz in [-0.8, 0.8]:
						var pixel := camera.unproject_position(anchor + offset + Vector3(dx, 0.04, dz))
						check(content.grow(0.1).has_point(pixel), "%s透视极限上下角放整摞也不越屏" % tag)
		var near_width := _width(camera, 4.8)
		var far_width := _width(camera, -4.2)
		check(near_width > far_width * 1.12, "%s近处牌宽至少比远处大12%%，有真实纵深" % tag)
		var card_back := camera.unproject_position(Vector3(0.6, 0.1, 1.2)).x - camera.unproject_position(Vector3(-0.6, 0.1, 1.2)).x
		var card_front := camera.unproject_position(Vector3(0.6, 0.1, 2.8)).x - camera.unproject_position(Vector3(-0.6, 0.1, 2.8)).x
		check(card_front > card_back, "%s同张卡近边比远边宽，平行边具有消失点" % tag)
	scene.queue_free()
	await process_frame
	finish()

func _width(camera: Camera3D, z: float) -> float:
	return camera.unproject_position(Vector3(0.6, 0.1, z)).distance_to(
		camera.unproject_position(Vector3(-0.6, 0.1, z)))
