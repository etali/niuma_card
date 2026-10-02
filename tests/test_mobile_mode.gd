# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const DrawerLayout = preload("res://scenes/drawer_table_layout.gd")

## Android 横屏模式：常驻完整牌桌，复用选项/规则书/声音/录像入口，不创建桌宠收起逻辑。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_mobile_layout = true
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	check(main.mobile_mode, "移动模式开关生效")
	check(main.drawer_window == null and main.drawer_presentation != null, "移动端没有抽屉控制器，直接复用牌桌界面")
	check(main._uses_fitted_table() and main.layout.get_script() == DrawerLayout, "移动端复用正式牌桌的摆牌布局")
	check(not main.drawer_presentation._collapsed and main.drawer_presentation._handle == null,
		"移动端不显示桌宠拉手，也不会进入收起态")
	check(main.drawer_presentation._pin == null, "移动端隐藏钉住入口")
	check(main.drawer_presentation._menu != null and main.drawer_presentation._sound_button != null,
		"移动端保留齿轮选项和声音按钮")
	check(main.drawer_presentation._rulebook_button != null and main.btn_pass.get_parent() == main.drawer_presentation._footer.get_child(0),
		"移动端规则书和完成行动复用同一个底栏")
	main.drawer_presentation._open_utility(main.drawer_presentation.UTILITY_RULEBOOK)
	await process_frame
	check(main.drawer_presentation._utility.visible and main.drawer_presentation._rulebook != null,
		"移动端规则书沿用现有规则书组件")
	main.drawer_presentation.close_panels()
	main.drawer_presentation._open_utility(6)
	await process_frame
	check(main._join_panel != null and is_instance_valid(main._join_panel), "移动端局域网入口沿用现有联网面板")
	main._join_panel._on_cancel()
	await process_frame
	await _check_touch(main)
	main.queue_free()
	await process_frame
	finish()

func _screen_event(at: Vector2, down: bool, index := 0, canceled := false) -> void:
	var touch := InputEventScreenTouch.new()
	touch.index = index
	touch.position = at
	touch.pressed = down
	touch.canceled = canceled
	Input.parse_input_event(touch)
	await process_frame

func _drag_event(at: Vector2, index := 0) -> void:
	var motion := InputEventScreenDrag.new()
	motion.index = index
	motion.position = at
	Input.parse_input_event(motion)
	await process_frame

func _check_touch(main: Node) -> void:
	Input.emulate_mouse_from_touch = true
	var board: Board = main.board
	main.sfx.set_muted(true)
	main.set_foe_remote(true)
	board.input_locked = false
	main.phase = main.PHASE_ACTION
	main._actor = main.my_seat
	main.drawer_presentation.relayout()
	await create_timer(0.6).timeout
	var group: Dictionary = board.groups[0]
	var card: CardEntity = group["cards"][0]
	var old := board.rest_pos(card)
	var screen: Vector2 = board.camera.unproject_position(old + Vector3(0, 0.04, 0))
	board._reset_click_track()
	await _screen_event(screen, true)
	check(board._drag_cards.has(card), "真实触摸事件经Godot转换后从共享Board抓起牌组")
	await _screen_event(screen, false)
	await create_timer(0.3).timeout
	check(board.group_of(card) != null and board.rest_pos(card).is_equal_approx(old), "轻点触摸松手保持牌组和卡位，不误当拖放")
	board._reset_click_track()
	var down_at := board.camera.unproject_position(card.position + Vector3(0, 0.04, 0))
	await _screen_event(down_at, true)
	var hand := board._drag_cards.duplicate()
	var other_at := down_at + Vector2(120, -50)
	await _screen_event(other_at, true, 1)
	check(board._drag_cards == hand, "第二根手指不会抢走当前拖拽")
	await _screen_event(other_at, false, 1)
	check(not board._drag_cards.is_empty(), "第二根手指抬起不会结束第一根手指的动作")
	await _drag_event(other_at)
	var moved := card.position.distance_to(old) > 0.3
	check(moved, "手指移动通过共享Board每帧更新真实牌位")
	await _screen_event(other_at, false, 0, true)
	await create_timer(0.3).timeout
	check(board._drag_cards.is_empty() and board.group_of(card) != null and board.rest_pos(card).is_equal_approx(old), "系统取消触摸恢复原组，不触发买卖或误合并")
	board._reset_click_track()
	var compact_before: bool = board.group_of(card)["compact"]
	screen = board.camera.unproject_position(card.position + Vector3(0, 0.04, 0))
	await _screen_event(screen, true)
	await _screen_event(screen, false)
	await _screen_event(screen, true)
	await _screen_event(screen, false)
	await create_timer(0.3).timeout
	check(board.group_of(card)["compact"] != compact_before, "双击触摸复用原收拢/展开入口")
	var market: CardEntity = main.market_cards[0]
	screen = board.camera.unproject_position(market.position + Vector3(0, 0.04, 0))
	var hash_before := StateCodec.state_hash(main.state)
	await _screen_event(screen, true)
	await create_timer(0.6).timeout
	check(main.drawer_presentation._detail.visible and main.drawer_presentation._detail_id == market.def_id, "长按商品用共享说明组件显示价格和规则")
	await _screen_event(screen, false)
	check(StateCodec.state_hash(main.state) == hash_before, "查看说明没有购买卡牌或改变规则状态")
	var muted: bool = main.sfx.user_muted
	var sound_at: Vector2 = main.drawer_presentation._sound_button.get_global_rect().get_center()
	await _screen_event(sound_at, true)
	await _screen_event(sound_at, false)
	check(main.sfx.user_muted != muted and board._drag_cards.is_empty(), "触摸声音按钮只操作控件，不点穿牌桌")
	main.drawer_presentation._open_utility(3)
	await process_frame
	check(not main.drawer_presentation._utility_body.find_children("*", "Button", true, false).any(func(button): return "工作区" in button.text), "手机UI页没有桌面窗口比例入口")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	check(not main.drawer_presentation.panels_open(), "系统返回关闭当前面板，不触发桌宠收起")
	for size in [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(2400, 1080), Vector2i(2560, 1600)]:
		root.size = size
		await process_frame
		main.drawer_presentation.relayout()
		await process_frame
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		check(bounds.encloses(main.drawer_presentation._header.get_global_rect()) and bounds.encloses(main.drawer_presentation._footer.get_global_rect()), "横屏%s状态栏和操作栏完整可见" % size)
		check(main.drawer_presentation.content_rect().size.y > size.y * 0.5, "横屏%s保留至少一半高度给真实牌桌" % size)
		check(main.drawer_window == null and not root.transparent_bg, "横屏%s没有透明悬浮窗口" % size)
