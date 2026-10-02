# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const DrawerCameraFit = preload("res://scenes/drawer_camera_fit.gd")

## 纯数学测试：不同屏幕比例与俯仰角下，世界包围盒每个角点都落在 content_rect 内。
func _initialize() -> void:
	var world := Rect2(-10.8, -5.25, 21.6, 11.3)
	var cases := [
		{"vp": Vector2(1920, 1200), "content": Rect2(24, 124, 1872, 980)},
		{"vp": Vector2(3000, 1600), "content": Rect2(24, 100, 2952, 1460)},
		{"vp": Vector2(1280, 800), "content": Rect2(16, 104, 1248, 640)},
	]
	for pitch in [60.0, 62.0, 66.0, 68.0]:
		for item in cases:
			var vp: Vector2 = item["vp"]
			var content: Rect2 = item["content"]
			var result := DrawerCameraFit.fit(vp, content, world, 0.05, 1.5, pitch, 0.0, 16.0)
			check(float(result["camera_size"]) > 0.0, "镜头 size 有效 %.0fx%.0f pitch%.0f" % [vp.x, vp.y, pitch])
			var bounds: Rect2 = result["projected_bounds"]
			check(bounds.position.x >= content.position.x - 0.1 and bounds.end.x <= content.end.x + 0.1,
				"投影横向完整落入内容区 %.0fx%.0f pitch%.0f" % [vp.x, vp.y, pitch])
			check(bounds.position.y >= content.position.y - 0.1 and bounds.end.y <= content.end.y + 0.1,
				"投影纵向完整落入内容区 %.0fx%.0f pitch%.0f" % [vp.x, vp.y, pitch])
			var corners := [
				Vector3(world.position.x, 0.05, world.position.y),
				Vector3(world.end.x, 0.05, world.position.y),
				Vector3(world.position.x, 1.5, world.end.y),
				Vector3(world.end.x, 1.5, world.end.y),
			]
			for corner in corners:
				var p := DrawerCameraFit.project_point(vp, result, corner)
				check(content.grow(0.1).has_point(p), "角点在内容区内 %s" % str(corner))
			check(absf(float(result["camera_target"].y) - 0.775) < 0.001, "镜头目标高度取 y 范围中心")
			check(float(result["horizontal_margin_px"]) <= 16.0, "水平边距不超过16px")
	finish()
