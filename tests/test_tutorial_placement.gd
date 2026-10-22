# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/support/drawer_fixture.gd"

var main: Node
var player: Node
var arena: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌启动"): return
	var original := StateCodec.snapshot(main.state)
	# 不同表现随机数下，都不能把用户业务塞进现金的操作区域。
	for random_seed in [4, 17, 444]:
		seed(random_seed)
		await _start("income")
		if random_seed == 444:
			await _drag(_card("cash"), arena.market_cards[0].global_position)
		else:
			arena._purchase([], arena.market_cards[0])
			await _idle()
		check(_card("yunketang").position.x > 0, "首次购入云课堂靠用户侧，避免随机落在现金边：%d" % random_seed)
	await _follow_income_to_growth()
	await _start("growth")
	check(_card("yunketang").position.x > 0, "单独进入扩张课也把云课堂放在用户一侧")
	arena._purchase([], arena.market_cards.filter(func(card): return card.def_id == "pinshaoshao")[0])
	await _idle()
	_check_cash_lane(_card("pinshaoshao"))
	main.drawer_presentation.finish_tutorial()
	check(StateCodec.snapshot(main.state) == original, "教学布局调整不改变原对局")
	await dispose_drawer(main)
	finish()

func _follow_income_to_growth() -> void:
	var cloud := _card("yunketang")
	var users: Array = arena.board.group_of(_card("user"))["cards"]
	await _drag(users[0], cloud.global_position)
	if not need(player.session.current_step().get("id") == "income.settle", "真实配用户后准备结算"): return
	arena.finish_action()
	await _idle()
	var cloud_position: Vector3 = arena.board.rest_pos(cloud)
	player.find_child("ContinueBasics", true, false).pressed.emit()
	await _idle()
	check(player.session.course_id == "growth" and arena.board.rest_pos(cloud).is_equal_approx(cloud_position),
		"连续教学保留云课堂整摞的位置，不在切课时重新摆桌")
	var market: CardEntity = arena.market_cards.filter(func(card): return card.def_id == "ditui")[0]
	await _drag(_card("cash"), market.global_position)
	var recruit := _card("ditui")
	_check_cash_lane(recruit)
	for extent in [Vector2i(1280, 800), Vector2i(844, 390), Vector2i(390, 844), Vector2i(2560, 1600)]:
		root.size = extent
		main.mobile_mode = extent.x < 900
		main.drawer_presentation._ui_scale = 2.0 if extent.x == 2560 else 1.0
		await relayout_drawer(main)
		var source: Vector2 = arena.camera.unproject_position(arena.board.rest_pos(_card("cash")))
		var target: Vector2 = arena.camera.unproject_position(arena.board.rest_pos(recruit))
		var obstacle: Vector2 = arena.camera.unproject_position(arena.board.rest_pos(cloud))
		check(obstacle.x > maxf(source.x, target.x), str(extent) + "云课堂始终在现金拖动路线的另一侧")
		await _capture("growth-%dx%d" % [extent.x, extent.y])
	root.size = Vector2i(1280, 800)
	main.mobile_mode = false
	main.drawer_presentation._ui_scale = 1.0
	await relayout_drawer(main)
	if player._cue.get("gesture") == "double_click":
		arena.board.toggle_compact(player._cue["source"])
		await _idle()
	await relayout_drawer(main)
	var cash: CardEntity = player._cue["source"]
	# 故意向云课堂方向偏半张牌落下，仍应落到拉新业务的吸附区。
	await _drag(cash, recruit.global_position + Vector3(CardEntity.CARD_SIZE.x * 0.45, 0, 0))
	check(player.session.current_step().get("id") == "growth.settle" and player._notice.is_empty(),
		"略偏向云课堂的真实拖放仍配到地推，无误吸附、无回滚")
	check(arena.board.group_of(cloud)["cards"].all(func(card): return card.def_id != "cash"),
		"云课堂保持原用户配方，没有误混入现金")

func _check_cash_lane(recruit: CardEntity) -> void:
	var cloud := _card("yunketang")
	check(recruit.position.x < 0 and cloud.position.x - recruit.position.x > Board.MERGE_DIST * 2,
		"现金业务与云课堂分开摆放，两边的吸附范围不重叠")
	for card in arena.entities.values():
		if not card.draggable or card.def_id != "cash": continue
		var from := Vector2(card.position.x, card.position.z)
		var to := Vector2(recruit.position.x, recruit.position.z)
		var cloud_at := Vector2(cloud.position.x, cloud.position.z)
		var closest := Geometry2D.get_closest_point_to_segment(cloud_at, from, to)
		check(closest.distance_to(cloud_at) > Board.MERGE_DIST + CardEntity.CARD_SIZE.x,
			"现金到业务的直接拖动路线留出安全距离，不经过云课堂")

func _start(id: String) -> void:
	main.drawer_presentation.finish_tutorial()
	await process_frame
	main.drawer_presentation.start_tutorial(id)
	player = main.drawer_presentation.tutorial
	arena = player.arena
	await _idle()
	await relayout_drawer(main)

func _card(id: String) -> CardEntity:
	for card in arena.entities.values():
		if card.draggable and card.def_id == id: return card
	return null

func _idle() -> void:
	for i in 500:
		await create_timer(0.02).timeout
		if not arena.operation_pending and not arena.board.cards_moving(): return
	check(false, "教学操作与牌位演出正常结束")

func _drag(card: CardEntity, at: Vector3) -> void:
	# 通过事件坐标驱动指针，避免测试进程读取机器上的真实鼠标位置。
	arena.board.touch_mode = true
	arena.board._reset_click_track()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = player._gesture.anchor(card)
	root.push_input(down)
	await process_frame
	if not need(arena.board._drag_cards.has(card), "真实按下拿起指定材料"): return
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = arena.camera.unproject_position(Vector3(at.x, Board.DRAG_HEIGHT, at.z) - arena.board._grab_offset)
	root.push_input(motion)
	await process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = motion.position
	root.push_input(up)
	await _idle()

func _capture(id: String) -> void:
	var directory := OS.get_environment("TUTORIAL_CAPTURE_DIR")
	if directory.is_empty(): return
	await create_timer(0.7).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join(id + ".png"))
