# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 只替换系统窗口写入和截图，执行真实收放Tween；旧setup(false)会跳过动画。
class AnimatedDrawer extends DrawerWindow:
	func _apply_geometry(rect: Rect2i) -> void:
		_geometry = rect

	func _capture_snapshot() -> void:
		pass

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉四边收放方向 ===")
	for screen in [Rect2i(-1920, 32, 1920, 1048), Rect2i(120, -2160, 3840, 2100)]:
		for edge in ["left", "right", "top", "bottom"]:
			_check_edge(screen, edge)
	await _check_sway()
	finish()

func _check_edge(screen: Rect2i, edge: String) -> void:
	var drawer := AnimatedDrawer.new()
	root.add_child(drawer)
	drawer.setup(false, screen)
	drawer.set_process(false)
	drawer.handle_horizontal_ratio = 0.23
	drawer.handle_vertical_ratio = 0.72
	drawer.set_anchor_edge(edge)
	drawer._window = root
	drawer._use_os_window = true
	drawer._create_transition_cover()
	var full := drawer._rect_for(true)
	var handle := drawer._rect_for(false)
	var image := Image.create(full.size.x, full.size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.BEIGE)
	drawer._snapshot = ImageTexture.create_from_image(image)
	var context := "%s @ %s" % [edge, screen.position]
	var axis := 1 if edge in ["top", "bottom"] else 0
	var orthogonal := 1 - axis
	var finish_events: Array[bool] = []
	drawer.transition_finished.connect(func(open: bool): finish_events.append(open))
	drawer.start_collapsed()
	check(drawer._geometry == handle, "%s：入口保留沿边位置" % context)
	var expected: Vector2 = {"left": Vector2.RIGHT, "right": Vector2.LEFT,
		"top": Vector2.DOWN, "bottom": Vector2.UP}[edge]
	check(drawer.get_open_direction() == expected, "%s：展开方向朝向屏幕内部" % context)
	drawer.activate_handle()
	var tween := drawer._transition_tween
	tween.pause()
	var start := drawer._geometry
	check(start.size[axis] == handle.size[axis] and start.size[orthogonal] == full.size[orthogonal],
		"%s：沿开口方向起步，另一轴直接使用完整尺寸" % context)
	tween.custom_step(DrawerWindow.EXPAND_DURATION * 0.18)
	var middle := drawer._geometry
	check(middle.size[axis] > start.size[axis] and middle.size[axis] < full.size[axis],
		"%s：展开中间帧只增长对应宽/高" % context)
	_check_frame(drawer, full, screen, axis, context + "展开")

	# 展开中反向收回，随后再次展开；每次都从当前长度连续运动。
	drawer.collapse_now()
	check(drawer._geometry == middle, "%s：中途收回第一帧不跳变" % context)
	tween = drawer._transition_tween
	tween.pause()
	tween.custom_step(DrawerWindow.COLLAPSE_DURATION * 0.18)
	var reversed := drawer._geometry
	check(reversed.size[axis] < middle.size[axis] and reversed.size[axis] > handle.size[axis],
		"%s：反向收回沿相同轴缩短" % context)
	_check_frame(drawer, full, screen, axis, context + "反向")
	drawer.expand()
	check(drawer._geometry == reversed, "%s：反向展开保持连续" % context)
	tween = drawer._transition_tween
	tween.pause()
	tween.custom_step(DrawerWindow.EXPAND_DURATION + 0.01)
	check(drawer._geometry == full and drawer.is_expanded() and not drawer.is_transitioning(),
		"%s：完整展开落到正确工作区位置" % context)
	check(not drawer._cover.visible and drawer._cover.position == Vector2.ZERO,
		"%s：展开后清除遮罩偏移" % context)

	drawer.collapse_now()
	tween = drawer._transition_tween
	tween.pause()
	paused = true
	tween.custom_step(DrawerWindow.COLLAPSE_DURATION * 0.18)
	check(drawer._geometry.size[axis] < full.size[axis] and drawer._geometry.size[axis] > handle.size[axis],
		"%s：完整窗口收回也使用正确轴" % context)
	_check_frame(drawer, full, screen, axis, context + "收起")
	tween.custom_step(DrawerWindow.COLLAPSE_DURATION)
	paused = false
	check(drawer._geometry == handle and not drawer.is_expanded() and not drawer.is_transitioning(),
		"%s：暂停时也能收回原入口位置" % context)
	check(not drawer._cover.visible and drawer._cover.position == Vector2.ZERO,
		"%s：收起后不残留快照偏移" % context)
	check(finish_events == [false, true, false], "%s：反转不产生多余完成事件" % context)
	drawer.free()
	root.disable_3d = false
	root.unfocusable = false

func _check_frame(drawer: DrawerWindow, full: Rect2i, screen: Rect2i, axis: int, context: String) -> void:
	var rect := drawer._geometry
	var orthogonal := 1 - axis
	check(rect.size[orthogonal] == full.size[orthogonal] and rect.position[orthogonal] == full.position[orthogonal],
		"%s：垂直方向不横向抽动，水平方向不纵向抽动" % context)
	var far_edge := drawer.anchor_edge in ["right", "bottom"]
	check(rect.end[axis] == full.end[axis] if far_edge else rect.position[axis] == full.position[axis],
		"%s：吸附端始终固定" % context)
	check(screen.encloses(rect), "%s：中间帧仍完整位于工作区内" % context)
	check(drawer._cover.size == Vector2(full.size) and drawer._cover.scale == Vector2.ONE,
		"%s：快照和卡面保持原始像素比例" % context)
	var texture_edge := drawer._cover.position[axis] + drawer._cover.size[axis]
	check(drawer._cover.position == Vector2.ZERO if far_edge else is_equal_approx(texture_edge, rect.size[axis]),
		"%s：画面内侧边随抽屉滑动" % context)

func _check_sway() -> void:
	root.size = Vector2i(1600, 1000)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	await create_timer(0.7).timeout
	main.drawer_window.set_process(false)
	main.board.set_process(false)
	main.drawer_presentation.set_process(false)
	var card: CardEntity = main.board.groups[0]["cards"][0]
	var original := card.global_transform
	for edge in ["top", "bottom", "left", "right"]:
		main.drawer_window.set_anchor_edge(edge)
		for open in [true, false]:
			var before: Array[Tween] = get_processed_tweens()
			main._drawer_stack_sway(open)
			var created: Array[Tween] = []
			for tween in get_processed_tweens():
				if not before.has(tween):
					tween.pause()
					created.append(tween)
			# 编译/并行测试抢占CPU时，短timer可能越过正向摆动段；直接采同一Tween时刻。
			for tween in created:
				tween.custom_step(0.05)
			var motion: Vector3 = card._visual.position
			var component := motion.z if edge in ["top", "bottom"] else motion.x
			var other := motion.x if edge in ["top", "bottom"] else motion.z
			var expected := 1.0 if edge in ["top", "left"] else -1.0
			if not open:
				expected = -expected
			check(component * expected > 0 and is_zero_approx(other),
				"%s展开%s：惯性跟随收放轴和方向" % [edge, open])
			for tween in created:
				tween.custom_step(1.0)
			check(card._visual.transform.is_equal_approx(Transform3D.IDENTITY) and card.global_transform.is_equal_approx(original),
				"%s展开%s：晃动回正且不改牌摞实际落点" % [edge, open])
	main.queue_free()
	await process_frame
