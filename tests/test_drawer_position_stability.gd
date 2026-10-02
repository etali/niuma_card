# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 原生抽屉动画会逐帧缩小Viewport，而牌桌内容区保持展开尺寸。
## 无头测试显式驱动这些中间帧，覆盖散牌物理校正、延迟校正和后台新牌落点。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	paused = false
	root.size = Vector2i(1600, 1000)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	await settle()
	var board: Board = main.board
	var drawer: DrawerWindow = main.drawer_window
	var loose: CardEntity = board.groups[0]["cards"][0]
	board._detach_from_group(loose)
	board._stop_move(loose, false)
	loose.position = Vector3(-5, 0.05, 4)
	loose.freeze = false
	# 直接调用物理边界步骤，避免自由落体误差影响横向位移判据。
	loose.set_physics_process(false)
	await settle()
	loose.freeze = true
	var original: Vector3 = loose.position
	var group_positions := {}
	for group in board.groups:
		for card in group["cards"]:
			group_positions[card.uid] = board.rest_pos(card)
	var expanded: Vector2 = main.drawer_presentation._viewport_pixels
	var placement := board.clamp_player_position(Vector3(-4, 0.2, 3))
	for viewport in [Vector2i(850, 1000), Vector2i(252, 1000), Vector2i(1600, 288), Vector2i(252, 288)]:
		drawer._transitioning = true
		root.size = viewport
		await process_frame
		check(main.drawer_presentation._viewport_pixels == expanded, "过渡帧保持完整牌桌的构图记录")
		loose.freeze = false
		board._physics_process(1.0 / 60.0)
		loose.freeze = true
		check(Vector2(loose.position.x, loose.position.z).distance_to(Vector2(original.x, original.z)) < 0.001,
			"窗口%s时散牌不能被物理边界推走" % str(viewport))
		check(board.clamp_player_position(Vector3(-4, 0.2, 3)).is_equal_approx(placement),
			"窗口%s时后台交易/产出的落点继续使用展开牌桌" % str(viewport))
		board._playable_bounds_pending = true
		board._apply_pending_playable_bounds()
		var stable := true
		for uid in group_positions:
			stable = stable and board.rest_pos(main.entities[uid]).is_equal_approx(group_positions[uid])
		check(stable, "窗口%s时延迟边界校正不挪动整摞" % str(viewport))
	# 模拟原生收起终点：窗口先改尺寸，DrawerWindow已收起但UI通知还没到。
	drawer._transitioning = false
	drawer._expanded = false
	main.drawer_presentation._collapsed = false
	main.drawer_presentation._on_size_changed()
	check(main.drawer_presentation._viewport_pixels == expanded, "收起终点的size_changed不能覆盖展开构图尺寸")
	drawer._expanded = true
	drawer._transitioning = true
	check(board.clamp_player_position(Vector3(-4, 0.2, 3)).is_equal_approx(placement), "再次展开时仍使用上次完整构图")
	# 恢复原展开尺寸，只收放的情况下同一张牌必须留在原处。
	root.size = Vector2i(expanded)
	await process_frame
	drawer._transitioning = false
	main._on_drawer_transition_finished(true)
	await settle()
	check(loose.position.is_equal_approx(original), "重新打开抽屉后散牌留在原位置")
	# 真实调整窗口大小仍须更新投影限制，不能靠永久忽略可见区域来修复。
	root.size = Vector2i(1000, 720)
	await process_frame
	main.drawer_presentation.relayout()
	check(main.drawer_presentation._viewport_pixels == Vector2(1000, 720), "真实缩窗仍更新完整牌桌尺寸")
	var bounded: Vector3 = board.clamp_player_position(Vector3(-100, 0.05, 4))
	var screen: Vector2 = board.camera.unproject_position(bounded)
	check(main.drawer_presentation.content_rect().has_point(screen), "真实缩窗后边缘散牌仍限制在可见牌桌内")
	main.queue_free()
	await process_frame
	finish()
