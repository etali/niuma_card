# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1920, 1200)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	await create_timer(0.6).timeout
	var drawer: DrawerWindow = main.drawer_window
	var presentation: CanvasLayer = main.drawer_presentation
	var handle: DrawerMascot = presentation._handle
	check(handle != null and handle.size == DrawerMascot.ENTRY_SIZE * drawer.get_handle_scale(), "完整大图标使用独立入口组件")
	drawer.start_collapsed()
	check(paused and not drawer.is_expanded(), "启动入口时牌局已暂停")
	check(handle.visible and handle.position == Vector2.ZERO, "入口位于小窗口原点，不沿用大窗口中心导致裁切")
	drawer._update_hover(drawer._geometry.get_center(), Time.get_ticks_msec())
	await create_timer(0.35, true, false, true).timeout
	drawer._tick_at(Time.get_ticks_msec() + 60000)
	check(not drawer.is_expanded(), "悬停一分钟也不会展开游戏")
	check(handle._face_zoom > 1.0, "暂停时悬停仍可放大图标内部牛马")
	handle.activated.emit()
	check(drawer.is_expanded() and not paused, "点击图标展开并恢复牌局")
	check(not handle.visible, "展开后隐藏入口，不残留遮挡")
	presentation._pin.button_pressed = true
	check(drawer.is_pinned(), "唯一钉住按钮能保持窗口展开")
	drawer._update_hover(Vector2i(-100, -100), Time.get_ticks_msec())
	drawer._tick_at(Time.get_ticks_msec() + 60000)
	check(drawer.is_expanded(), "钉住后鼠标离开保持展开")
	presentation._pin.button_pressed = false
	drawer._tick_at(Time.get_ticks_msec() + 700)
	check(not drawer.is_expanded(), "取消钉住后离开自动收起")
	drawer.activate_handle()
	await process_frame
	var first: CardEntity = main.market_cards.front()
	var last: CardEntity = main.market_cards.back()
	var camera: Camera3D = main.board.camera
	var left := camera.unproject_position(first.to_global(Vector3(-0.6, 0.04, 0)))
	var right := camera.unproject_position(last.to_global(Vector3(0.6, 0.04, 0)))
	check((right.x - left.x) / root.size.x >= 0.66, "八张市场卡横向使用至少三分之二窗口")
	var edge := camera.unproject_position(first.to_global(Vector3(0.6, 0.04, 0)))
	check(edge.x - left.x >= 90.0, "1920窗口的卡牌宽度至少90px")
	check(main.market_cards.size() == 8, "大卡布局没有隐藏任何市场卡")
	check(main.layout is DrawerTableLayout, "抽屉使用紧凑物理布局而非对原牌桌做缩放")
	main.queue_free()
	await process_frame
	finish()
