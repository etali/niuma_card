# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/support/drawer_fixture.gd"

const Progress = preload("res://engine/tutorial_progress.gd")
var main: Node
var player: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌启动"): return
	var original := StateCodec.snapshot(main.state)
	check(main.drawer_presentation.start_tutorial("reserve"), "打开保底选修")
	player = main.drawer_presentation.tutorial
	var arena: Node = player.arena
	var cash := _cards("cash")
	arena._purchase(cash, arena.market_cards[0])
	await _idle()
	check(player._cue.get("gesture") == "double_click" and player._cue["source"].def_id == "user",
		"付款归零被拒后，先在真实用户摞示范双击")
	await _capture("expand")
	arena.board.toggle_compact(player._cue["source"])
	await relayout_drawer(main)
	check(player._cue.get("gesture") == "drag" and player._cue.get("count") == 1 \
		and player._cue["source"] == arena.board.group_of(player._cue["source"])["cards"].back() \
		and player._cue["target_world"] == arena.board.pawn_pos, "展开后示范从末端取一张，落点是实际典当行")
	await _capture("pawn")
	var before := StateCodec.snapshot(arena.state)
	var source: CardEntity = player._cue["source"]
	var first_anchor: Vector2 = player._gesture.anchor(source)
	var center: Vector2 = main.drawer_presentation.content_rect().get_center()
	main.drawer_presentation.camera_view.change(1.5, center, center + Vector2(25, 15))
	check(player._gesture.anchor(source).distance_to(first_anchor) > 1, "指示位置随相机缩放平移重新投影")
	await create_timer(0.65).timeout
	check(StateCodec.snapshot(arena.state) == before and player.session.step_index == 0, "提示动画不代替玩家操作、不自动推进")
	player.set_reference_open(true)
	check(not player._gesture.active(), "查阅资料时暂停指示动画")
	player.set_reference_open(false)
	arena._pawn([source])
	check(not player._gesture.active(), "典当演出期间隐藏示意手")
	await _idle()
	check(player.session.state.resource_count(GameState.PLAYER, "cash") == 6 and not player.session.step_complete \
		and player._cue.get("target") == arena.market_cards[0] and not player._goal.text.contains("典当"),
		"典当一张后直接引导支付买包月，不再要求组织组合或继续典当")
	check(player.session.current_step()["goal"].contains("现金已经够了"), "模型目标也跟随足够支付的状态更新")
	# 第二次合法典当不改变目标，不受示例只卖一张的限制。
	arena._pawn([_cards("user").back()])
	await _idle()
	check(player.session.state.resource_count(GameState.PLAYER, "cash") == 7 \
		and player.session.state.resource_count(GameState.PLAYER, "user") == 3, "安全的第二次典当保留，未强制凑包月配方")
	var operation: Dictionary = player.session.capture_operation()
	var groups: Array = player.session._groups_for_specs([{"cash": 3}])
	player.session.preview_groups(groups)
	check(player.session.review_operation(operation, "layout")["expected"], "购牌前拆分现金合法")
	arena.apply_groups(player.session._uid_groups(groups))
	player._refresh()
	check(player._cue.get("gesture") == "drag" and player._cue["target"].def_id == "cash",
		"总额足够但每摞都不够支付时，先指引合并现金，避免反复支付不足")
	operation = player.session.capture_operation()
	player.session.preview_groups(player.session._groups_for_specs([]))
	check(player.session.review_operation(operation, "layout")["expected"], "典当后合并现金合法")
	arena._purchase(_cards("cash"), arena.market_cards[0])
	await _idle()
	check(player._awaiting_result and player.session.step_complete \
		and player.session.state.resource_count(GameState.PLAYER, "cash") == 2, "用5现金买下包月即可完成本步")
	main.drawer_presentation.finish_tutorial()
	check(StateCodec.snapshot(main.state) == original, "选修退出恢复原局")
	await _test_continuous_assets()
	await _test_early_graduation()
	await _test_context_help()
	await dispose_drawer(main)
	finish()

func _test_continuous_assets() -> void:
	var session := TutorialSession.new("income")
	for id in ["income", "growth", "attack"]:
		while not session.completed:
			check(session.run_example().get("ok", false) and session.step_complete, id + "目标走真实规则达成")
			session.acknowledge()
		var next := TutorialCatalog.next_course_id(id)
		if next.is_empty(): break
		var state: GameState = session.state
		var generation := session.generation
		var records: Array = state.players[GameState.PLAYER]["cards"].duplicate(true)
		var groups: Array = session.initial_groups.duplicate(true)
		var money := state.resource_count(GameState.PLAYER, "cash")
		var round_num := state.round_num
		check(session.start(next, true) and session.state == state and session.generation == generation,
			id + "续课保留同一牌局与实体代次")
		check(records.all(func(card): return session.state.find_card(GameState.PLAYER, card["uid"]) == card) \
			and state.resource_count(GameState.PLAYER, "cash") == money and state.round_num == round_num + 1,
			id + "续课完整保留用户、现金、业务，只推进一回合")
		check(groups.all(func(group): return group in session.initial_groups), id + "续课保留既有牌摞")
	check(session.completed and session.course_id == "attack", "基础主线在第一次打断对手后毕业")

func _test_early_graduation() -> void:
	main.drawer_presentation.start_tutorial("income")
	player = main.drawer_presentation.tutorial
	for i in 3:
		player.session.run_example()
		player.arena.sync_state(true)
		player.arena.apply_groups(player.session.initial_groups)
		player._operation_finished({"expected": true})
	check(player._checkpoint() and not player._can_tap(), "首笔收入后等待明确选择，小人点击不代选")
	for extent in [Vector2i(1280, 800), Vector2i(844, 390), Vector2i(390, 844), Vector2i(2560, 1600)]:
		root.size = extent
		main.mobile_mode = extent.x < 900
		main.drawer_presentation._ui_scale = 2.0 if extent.x == 2560 else 1.0
		await relayout_drawer(main)
		var bounds := Rect2(Vector2.ZERO, Vector2(extent)).grow(1)
		check(bounds.encloses(player.find_child("StartPlaying", true, false).get_global_rect()) \
			and bounds.encloses(player.find_child("ContinueBasics", true, false).get_global_rect()),
			str(extent) + "两项选择都在窗口内")
		if not OS.get_environment("TUTORIAL_CAPTURE_DIR").is_empty():
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OS.get_environment("TUTORIAL_CAPTURE_DIR").path_join("graduation-%dx%d.png" % [extent.x, extent.y]))
	await tap_drawer_control(player.find_child("StartPlaying", true, false))
	check(main.drawer_presentation.tutorial == null and Progress.course("income").get("status") == "completed" \
		and Progress.course("growth").get("status", "") != "completed", "首课即可离开，保留已完成记录，不冒充完成后续课")
	await create_timer(0.3).timeout
	check(main.drawer_presentation.contextual_coach._pending == "first_game" \
		and not main.board.input_locked, "进入原局只给可关闭的首局提示，不锁牌桌考试")

func _cards(id: String) -> Array:
	return player.arena.entities.values().filter(func(card): return card.draggable and card.def_id == id)

func _test_context_help() -> void:
	var presentation: Node = main.drawer_presentation
	var coach: Control = presentation.contextual_coach
	check(presentation.pointer_over_panels(coach.get_global_rect().get_center()), "按需提示只在自身范围挡住牌桌输入")
	presentation.set_collapsed(true)
	check(not coach.visible, "收起抽屉时按需提示立即隐藏")
	presentation.set_collapsed(false)
	await create_timer(0.3).timeout
	await tap_drawer_control(coach.find_child("DismissContextHelp", true, false))
	Progress.request_first_game_help()
	coach.resume_after_tutorial()
	await create_timer(0.3).timeout
	check(not coach.visible and not coach._first_game, "已看过首局帮助，重练毕业不会重复显示")
	main._offer_cash_help({"code": "zero_out"})
	await create_timer(0.3).timeout
	check(coach.visible and coach._pending == "cash" and not main.board.input_locked, "正式购买归零错误触发不锁桌的现金帮助")
	coach.clear("cash")
	main._offer_cash_help({"code": "short"})
	await create_timer(0.3).timeout
	check(not coach.visible, "同类现金帮助仅出现一次")
	main.state.add_card(main.my_seat, "yunketang")
	main.state.add_card(main.my_seat, "yunketang")
	await create_timer(0.3).timeout
	check(coach.visible and coach._pending == "upgrade" and Progress.tip_seen("upgrade"), "拥有同名升级材料才显示选修提示，并记录已看过")
	coach.clear("upgrade")
	await create_timer(0.3).timeout
	check(not coach.visible, "关闭升级提示后不反复弹出")

func _idle() -> void:
	for i in 200:
		await create_timer(0.025).timeout
		if not player.arena.operation_pending: return
	check(false, "操作应在限定时间内结束")

func _capture(id: String) -> void:
	var directory := OS.get_environment("TUTORIAL_CAPTURE_DIR")
	if directory.is_empty(): return
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join(id + ".png"))
