# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 工作区比例给出最大外框，只裁牌区两侧空白；真实窗口变窄后仍须完整显示。
const Drawer = preload("res://scenes/drawer_window.gd")
const CASES := [
	{"screen": Rect2i(-1920, 32, 1920, 1048), "dpi": 1.0},
	{"screen": Rect2i(120, -2028, 3456, 2028), "dpi": 2.0},
	{"screen": Rect2i(-3840, -40, 3840, 1080), "dpi": 1.0},
	{"screen": Rect2i(-1280, 48, 1280, 1024), "dpi": 1.0},
]
const RATIOS := [0.75, 0.98]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉横向裁剪与完整内容 ===")
	_check_window_geometry()
	for item in CASES:
		for ratio in RATIOS:
			await _check_scene(item["screen"], float(item["dpi"]), float(ratio))
	finish()

func _requested(screen: Rect2i, ratio: float) -> Vector2i:
	return Vector2i(roundi(screen.size.x * ratio), roundi(screen.size.y * ratio))

func _check_window_geometry() -> void:
	for item in CASES:
		var screen: Rect2i = item["screen"]
		var dpi: float = item["dpi"]
		var drawer := Drawer.new()
		root.add_child(drawer)
		drawer.animations_enabled = false
		drawer.set_process(false)
		drawer.set_display_scale(dpi)
		drawer.setup(false, screen)
		for ratio in RATIOS:
			var requested := _requested(screen, float(ratio))
			drawer.set_size_fraction(float(ratio))
			var expanded := drawer.get_expanded_size()
			var tag := "%dx%d@%.0fx/%d%%" % [screen.size.x, screen.size.y, dpi, roundi(ratio * 100)]
			check(expanded.y == requested.y, tag + " 保留比例档位的完整高度")
			check(expanded.x <= requested.x and expanded.x > 0, tag + " 只收窄，不放大原请求宽度")
			check(expanded.x <= floori(expanded.y * 1.65), tag + " 展开外框宽高比不超过1.65")
			if screen.size.x > screen.size.y * 2:
				check(expanded.x < requested.x * 0.6, tag + " 超宽屏实质去除两侧空白")
			if screen.size.x <= screen.size.y * 1.65:
				check(expanded == requested, tag + " 原本窄的窗口尺寸保持不变")
			for edge in ["left", "right", "top", "bottom"]:
				drawer.anchor_edge = edge
				drawer.handle_horizontal_ratio = 0.31
				drawer.handle_vertical_ratio = 0.67
				drawer.expand()
				drawer.set_size_fraction(float(ratio))
				var open_rect: Rect2i = drawer._geometry
				check(open_rect.size == expanded and screen.encloses(open_rect), tag + " " + edge + " 展开留在当前工作区")
				check(_on_edge(open_rect, screen, edge), tag + " " + edge + " 裁剪后仍贴住吸附边")
				drawer.collapse_now()
				var peek: Rect2i = drawer._geometry
				check(peek.size == Vector2i(roundi(126 * dpi), roundi(144 * dpi)), tag + " " + edge + " 入口大小不受展开裁剪影响")
				check(screen.encloses(peek) and _on_edge(peek, screen, edge), tag + " " + edge + " 入口完整且保持吸附")
				drawer.expand()
				check(drawer._geometry == open_rect, tag + " " + edge + " 再展开恢复相同裁剪窗口")
				drawer.collapse_now()
				check(drawer._geometry == peek, tag + " " + edge + " 再收起恢复原入口位置")
		# 固定像素尺寸走同样的裁剪约束，不能绕过最大宽高比。
		drawer.set_expanded_size(screen.size)
		var fixed := drawer.get_expanded_size()
		check(drawer.get_size_ratio() == 0.0 and fixed.y == screen.size.y,
			"%s 固定尺寸退出比例模式，同时保持请求高度" % screen.size)
		if screen.size.x > screen.size.y * 1.65:
			check(fixed.x < screen.size.x and fixed.x <= floori(screen.size.y * 1.65),
				"%s 固定宽屏也裁剪横向空白" % screen.size)
		else:
			check(fixed == screen.size, "%s 固定窄屏保持完整请求尺寸" % screen.size)
		drawer.free()

func _on_edge(rect: Rect2i, screen: Rect2i, edge: String) -> bool:
	match edge:
		"left": return rect.position.x == screen.position.x
		"right": return rect.end.x == screen.end.x
		"top": return rect.position.y == screen.position.y
		"bottom": return rect.end.y == screen.end.y
	return false

func _check_scene(screen: Rect2i, dpi: float, ratio: float) -> void:
	paused = false
	var requested := _requested(screen, ratio)
	root.size = requested
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = dpi
	root.add_child(main)
	main.sfx.set_muted(true)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window._screen_rect = screen
	main.drawer_window.set_size_fraction(ratio)
	main.drawer_window.pin()
	await settle()
	await _layout(main)
	var camera: Camera3D = main.board.camera
	var before_camera := camera.global_position
	var before_width := _card_width(camera)
	var original_tray_crop := {}
	for name in ["PlayerZoneTray", "FoeZoneTray"]:
		original_tray_crop[name] = _horizontal_crop(_geometry_rect(camera, main.get_node(name)), float(root.size.x))
	var expanded: Vector2i = main.drawer_window.get_expanded_size()
	# headless 不会改系统窗口；按最终原生窗口尺寸真正重排，避免只测虚拟几何。
	root.size = expanded
	await _layout(main)
	var tag := "%dx%d@%.0fx/%d%%→%dx%d" % [screen.size.x, screen.size.y, dpi, roundi(ratio * 100), expanded.x, expanded.y]
	var after_width := _card_width(camera)
	check(absf(after_width / before_width - 1.0) < 0.04,
		tag + " 去掉左右空白后牌面投影宽度变化小于4%")
	check(camera.global_position.distance_to(before_camera) < 0.7,
		tag + " 裁剪保持原纵向相机构图")
	check(main.scale.is_equal_approx(Vector3.ONE) and camera.scale.is_equal_approx(Vector3.ONE),
		tag + " 世界与相机维持单位缩放")
	_check_complete_content(main, tag, original_tray_crop, expanded.x < requested.x)
	var footer: Control = main.drawer_presentation._footer
	var header: Control = main.drawer_presentation._header
	var expected_header := header.get_global_rect()
	var expected_footer := footer.get_global_rect()
	main.drawer_window.collapse_now()
	main.drawer_window.pin()
	root.size = main.drawer_window.get_expanded_size()
	await _layout(main)
	check(header.get_global_rect().is_equal_approx(expected_header) and footer.get_global_rect().is_equal_approx(expected_footer),
		tag + " 收起再展开恢复同一顶部和底部布局")
	_check_complete_content(main, tag + " 重新展开", original_tray_crop, expanded.x < requested.x)
	main.queue_free()
	_booted = null
	for i in 3:
		await process_frame

func _layout(main: Node) -> void:
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await settle()
	for i in 3:
		await process_frame

func _card_width(camera: Camera3D) -> float:
	return camera.unproject_position(Vector3(CardEntity.CARD_SIZE.x * 0.5, 0.05, 2.1)).distance_to(
		camera.unproject_position(Vector3(-CardEntity.CARD_SIZE.x * 0.5, 0.05, 2.1)))

func _check_complete_content(main: Node, tag: String, original_tray_crop: Dictionary, was_cropped: bool) -> void:
	var camera: Camera3D = main.board.camera
	var content: Rect2 = main.drawer_presentation.content_rect()
	var window := Rect2(Vector2.ZERO, Vector2(root.size))
	var cards_inside := true
	var unit_scale := true
	for card: CardEntity in main.board.cards:
		if not is_instance_valid(card) or not card.visible:
			continue
		cards_inside = cards_inside and content.grow(1).encloses(_face_rect(camera,
			card.global_position + Vector3.UP * CardEntity.HOVER_LIFT))
		unit_scale = unit_scale and card.scale.is_equal_approx(Vector3.ONE)
	check(cards_inside, tag + " 市场与双方开局牌悬浮后四角完整可见")
	check(unit_scale, tag + " 全部卡牌保持单位缩放")
	var shadow_inside := true
	for contact: Dictionary in TableLighting.contact_footprints(main.board.cards):
		for x in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var point: Vector3 = contact["center"] + Vector3(contact["size"].x * x, 0, contact["size"].y * z)
				shadow_inside = shadow_inside and content.grow(1).has_point(camera.unproject_position(point))
	check(shadow_inside, tag + " 牌摞接触阴影的完整平面不裁剪")
	var facility_inside := true
	for geometry: GeometryInstance3D in main.get_node("MarketFacility").find_children("*", "GeometryInstance3D", true, false):
		facility_inside = facility_inside and content.grow(1).encloses(_geometry_rect(camera, geometry))
	check(facility_inside, tag + " 典当行卡面、设施徽标及文字完整可见")
	for control: Control in [main.drawer_presentation._header, main.drawer_presentation._footer]:
		check(window.grow(1).encloses(control.get_global_rect()), tag + " " + control.name + " 完整留在窗口内")
		var children_inside := true
		for child: Control in control.find_children("*", "Control", true, false):
			if child.is_visible_in_tree():
				children_inside = children_inside and window.grow(1).encloses(child.get_global_rect())
		check(children_inside, tag + " " + control.name + " 内部控件不越出窗口")
	var offsets: Array = [Vector3.ZERO, Vector3(0, 0.315, 0.35)]
	for side in [-1.0, 1.0]:
		var target: Vector3 = main.board.screen_position_clamper.call(Vector3(side * 1000.0, Board.DRAG_HEIGHT, 1000.0), offsets)
		var held_inside := true
		for offset: Vector3 in offsets:
			held_inside = held_inside and content.grow(1).encloses(_face_rect(camera, target + offset))
		check(held_inside, tag + " 边缘抬起整摞保持完整可见")
	# 窄屏的21单位装饰托盘原本会超出19.4单位取景；本次只限宽，不能新增裁切。
	for name in ["PlayerZoneTray", "FoeZoneTray"]:
		var tray: GeometryInstance3D = main.get_node(name)
		var tray_rect := _geometry_rect(camera, tray)
		if was_cropped:
			check(window.grow(1).encloses(tray_rect), tag + " " + name + " 裁窄后托盘外框完整")
		else:
			var cropped := _horizontal_crop(tray_rect, float(root.size.x))
			check(absf(cropped - float(original_tray_crop[name])) <= 1.0, tag + " " + name + " 未裁宽时保留原托盘构图")

func _horizontal_crop(rect: Rect2, width: float) -> float:
	return maxf(0.0, -rect.position.x) + maxf(0.0, rect.end.x - width)

func _face_rect(camera: Camera3D, at: Vector3) -> Rect2:
	var result := Rect2()
	var first := true
	for x in [-CardEntity.CARD_SIZE.x * 0.5, CardEntity.CARD_SIZE.x * 0.5]:
		for z in [-CardEntity.CARD_SIZE.z * 0.5, CardEntity.CARD_SIZE.z * 0.5]:
			var point := camera.unproject_position(at + Vector3(x, CardEntity.Y_OVERLAY, z))
			result = Rect2(point, Vector2.ZERO) if first else result.expand(point)
			first = false
	return result

func _geometry_rect(camera: Camera3D, geometry: GeometryInstance3D) -> Rect2:
	var aabb := geometry.get_aabb()
	var result := Rect2()
	var first := true
	for x in [aabb.position.x, aabb.end.x]:
		for y in [aabb.position.y, aabb.end.y]:
			for z in [aabb.position.z, aabb.end.z]:
				var point := camera.unproject_position(geometry.to_global(Vector3(x, y, z)))
				result = Rect2(point, Vector2.ZERO) if first else result.expand(point)
				first = false
	return result
