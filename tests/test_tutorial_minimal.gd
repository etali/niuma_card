# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/support/drawer_fixture.gd"

const IDLE_OBSERVATION_TIME := 0.8

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌正常启动"): return
	var presentation: Node = main.drawer_presentation
	presentation.start_tutorial("income")
	await relayout_drawer(main)
	var player: Node = presentation.tutorial
	if not need(player != null and player.session != null and player.arena != null, "一句话教程正常启动"):
		presentation.finish_tutorial(false)
		await dispose_drawer(main)
		finish()
		return
	check(_count_type(player, "Label") == 1 and _count_type(player, "Button") == 1,
		"教程只显示一句话和退出按钮，没有隐藏的教程操作面板")
	check(_count_type(player, "TextureRect") == 1 and _count_type(player, "SubViewport") == 0,
		"只复用App小人和原牌桌，不创建另一套渲染视口")
	check(player.session.current_step().get("kind") == "buy", "第一句直接要求购牌")
	check(TutorialCatalog.next_course_id("income") == "growth" and TutorialCatalog.next_course_id("independent") == "", "课程配置顺序决定连续下一课，末课没有多余课程")
	var target: String = player.session.current_step().get("goal", "")
	check(player._goal.text == target, "初始只显示当前目标，不预先堆放帮助")
	var initial_step: int = player.session.step_index
	# 跨过旧的自动跳步时限，且组件本身不再注册逐帧计时。
	await create_timer(IDLE_OBSERVATION_TIME).timeout
	check(player._goal.text == target and player.session.step_index == initial_step and not player._awaiting_result,
		"初始目标长时间无操作仍保持原句，不自动换提示或推进")
	var saved_complete: bool = player.session.step_complete
	player.session.step_complete = true
	player._refresh()
	await create_timer(0.6).timeout
	check(player.session.step_index == initial_step and not player._awaiting_result,
		"普通changed即使暂时满足目标也不会自动推进")
	player.session.step_complete = saved_complete
	player.arena.finish_action()
	await create_timer(player.arena.ROLLBACK_DELAY + 0.15).timeout
	var rollback_text: String = player._goal.text
	check(rollback_text != target and rollback_text.contains(target) and not player._awaiting_result,
		"回滚只显示一句原因，不安排错误的下一步")
	await create_timer(IDLE_OBSERVATION_TIME).timeout
	check(player._goal.text == rollback_text and player.session.step_index == initial_step and not player._awaiting_result,
		"回滚原因和当前目标长时间保持原句，不自动恢复或推进")
	var cash: Array = player.arena.entities.values().filter(func(card): return card.draggable and card.def_id == "cash")
	player.arena.board.toggle_compact(cash[0])
	player._refresh()
	check(player._goal.text == rollback_text and player._notice == rollback_text,
		"展开牌摞和普通界面刷新不会清掉回滚提示")
	var bought: CardEntity = player.arena.market_cards[0]
	var purchase_results: Array = []
	var record_purchase := func(result): purchase_results.append(result)
	player.arena.operation_finished.connect(record_purchase)
	player.arena._purchase(cash, player.arena.market_cards[0])
	check(player.arena.operation_pending and purchase_results.is_empty() and not player._awaiting_result
		and bought.has_meta("fly_tw") and bought.get_meta("fly_tw").is_running(),
		"真实购买启动到货动画时仍待完成，不提前显示可确认结果")
	await tap_drawer_control(player._mascot)
	await tap_drawer_control(player._bubble)
	check(player.session.step_index == initial_step and player.arena.operation_pending
		and purchase_results.is_empty() and not player._awaiting_result,
		"到货途中真实点击小人和气泡都不能越过购牌演出")
	for attempt in 150:
		if not purchase_results.is_empty(): break
		await create_timer(0.02).timeout
	player.arena.operation_finished.disconnect(record_purchase)
	if not need(purchase_results.size() == 1 and purchase_results[0].get("expected", false)
		and not player.arena.operation_pending, "购牌完整落位后只发一次成功事件"): return
	check(player._notice.is_empty() and player._goal.text != target and not player._goal.text.contains("点我继续"),
		"成功购牌清除旧错误提示，直接显示下一项操作")
	check(not player._awaiting_result and not player.arena.board.input_locked and not main.btn_pass.disabled and not player.is_processing(),
		"普通准备完成后直接衔接，不锁桌等确认，也不注册推进计时")
	var next_goal: String = player._goal.text
	await create_timer(IDLE_OBSERVATION_TIME).timeout
	check(player.session.current_step().get("id") == "income.split" and player._goal.text == next_goal,
		"到达拆牌目标后空闲不会继续跳步")
	await relayout_drawer(main)
	await tap_drawer_control(player._bubble)
	check(player.session.current_step().get("id") == "income.split" and player._notice.is_empty()
		and player._goal.text == player.session.current_step().get("goal", ""),
		"普通操作目标不能靠点击对白越过")
	player.retry()
	check(player._notice.is_empty() and player._goal.text == player.session.current_step().get("goal", ""),
		"内部重试恢复目标，且不增添教程控制按钮")
	player.session.step_complete = true
	player._operation_finished({"expected": true, "rolled_back": false, "reason": ""})
	player.retry()
	await create_timer(0.6).timeout
	check(player.session.step_index == 0 and not player._awaiting_result,
		"重试清除旧结果确认，不会误跳过新起点")
	player.set_reference_open(true)
	var reference_text: String = player._goal.text
	await create_timer(IDLE_OBSERVATION_TIME).timeout
	check(player._goal.text == reference_text and player.session.step_index == 0
		and main.btn_pass.disabled and player.arena.board.input_locked,
		"长时间查阅时对白和步骤保持不变，并锁住原牌桌操作")
	player.set_reference_open(false)
	check(not main.btn_pass.disabled and not player.arena.board.input_locked, "关闭查看页立即恢复当前教学目标的操作")
	await _check_dialogue_layout(main, presentation, player, "income.buy")
	for example in [["upgrade", "upgrade.group"], ["cashout", "cashout.group"],
		["buffs", "buff.output"], ["tactics", "tactics.types"],
		["buffs", "buff.protect_user"], ["buffs", "buff.protect_cash"],
		["tactics", "tactics.reply"], ["tactics", "tactics.preempt"]]:
		player.switch_course(example[0])
		var steps: Array = player.session.course_data["steps"]
		for index in steps.size():
			if steps[index]["id"] == example[1]:
				player.session.step_index = index
				break
		player.session._enter_step()
		player.arena.sync_state(true)
		player._refresh()
		check(player.session.current_step().get("id") == example[1]
			and player._goal.text == player.session.current_step().get("goal") and not player._goal.text.contains("{"),
			"%s：布局使用本步真实目标，卡名与张数模板已经展开" % example[1])
		await _check_dialogue_layout(main, presentation, player, example[1])
		player._awaiting_result = true
		player._refresh()
		check(not player._goal.text.contains("{") and player._goal.text.contains("点我继续"), example[1] + "：完成说明从配置展开")
		await _check_dialogue_layout(main, presentation, player, example[1] + "结果")
	presentation.finish_tutorial(false)
	await dispose_drawer(main)
	finish()

func _check_dialogue_layout(main: Node, presentation: Node, player: Node, step_id: String) -> void:
	for extent in [Vector2i(1280, 800), Vector2i(844, 390), Vector2i(390, 844), Vector2i(2560, 1600)]:
		main.mobile_mode = extent.x < 900
		presentation._ui_scale = 2.0 if extent.x == 2560 else 1.0
		root.size = extent
		await relayout_drawer(main)
		var screen := Rect2(Vector2.ZERO, Vector2(extent)).grow(1)
		var contained: bool = (player.get_global_rect().grow(1).encloses(player._bubble.get_global_rect())
			and player._bubble.get_global_rect().encloses(player._goal.get_global_rect())
			and player._bubble.get_global_rect().encloses(player._close.get_global_rect())
			and player._goal.get_minimum_size().y <= player._goal.size.y + 1
			and screen.encloses(player.get_global_rect()))
		if not contained:
			print("DIALOGUE_LAYOUT ", step_id, " ", extent, " player=", player.get_global_rect(),
				" bubble=", player._bubble.get_global_rect(), " goal=", player._goal.get_global_rect(),
				" goal_min=", player._goal.get_minimum_size(), " close=", player._close.get_global_rect(),
				" text=", player._goal.text)
		check(contained,
			"%s %s：气泡容纳完整目标与退出按钮，整个浮层在屏幕内" % [step_id, extent])

func _count_type(node: Node, type_name: String) -> int:
	var total := 1 if node.is_class(type_name) else 0
	for child in node.get_children(): total += _count_type(child, type_name)
	return total
