# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

class RecordedSound extends Sfx:
	var actions: Array[String] = []
	func play(action_name: String, _pitch := 1.0) -> void:
		actions.append(action_name)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	await _visible_pawn_and_handoff()
	await _ai_waits_before_buy()
	await _rapid_buy()
	await _resign_midflight()
	finish()

func _fixture() -> Node:
	var main := await boot_main()
	main.set_foe_remote(true)
	main.state.players[main.foe_seat]["cards"].clear()
	main.state.combos.clear()
	main.state.market = ["pinshaoshao"]
	for i in 12:
		main.state.add_card(main.foe_seat, "cash")
	for i in 3:
		main.state.add_card(main.foe_seat, "user")
	for i in 2:
		main.state.add_card(main.foe_seat, "yinqing996")
	main.state.draw_first = main.foe_seat
	main._actor = main.foe_seat
	main.board.input_locked = true
	main._respawn_all()
	await settle()
	var sound := RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	return main

func _sell(main: Node) -> Dictionary:
	var sold: Array = []
	var known := {}
	for card in main.state.players[main.foe_seat]["cards"]:
		known[card["uid"]] = true
		if card["def_id"] == "yinqing996":
			sold.append(main.entities[card["uid"]])
	var result: Dictionary = await main.pipe.submit(Intent.pawn(main.foe_seat, sold.map(func(card): return card.uid)))
	check(result.get("ok", false) and result.get("total", 0) == 6, "真实管道典当两张996得到六张现金")
	var fresh: Array = []
	for card in main.state.players[main.foe_seat]["cards"]:
		if not known.has(card["uid"]):
			fresh.append(main.entities[card["uid"]])
	return {"sold": sold, "fresh": fresh}

func _visible_pawn_and_handoff() -> void:
	var main := await _fixture()
	main._run_foe_action()
	var batch := await _sell(main)
	var counter: Vector3 = main._pawn_position() + Vector3(0, 0.8, 0)
	var old_distance: float = batch.sold[0].position.distance_to(counter)
	check(batch.sold.all(func(card): return (not card._face_down and card._visual.scale == Vector3.ONE
		and card.get_meta("dest_pos", Vector3.INF) == counter)), "卖出的牌保留完整正面，目标是典当行绝对坐标")
	check(batch.fresh.size() == 6 and batch.fresh.all(func(card): return not card.visible),
		"现金实体即时按裁决登记，但柜台收牌前尚未飞出")
	check(main.lbl_msg.text.contains(CardDB.card_name("yinqing996")) and main.lbl_msg.text.contains("×2")
		and main.lbl_msg.text.contains("+6"), "提示说明卖掉的卡、数量和所得现金")
	check(main.sfx.actions.count("pawn") == 1, "真实典当播放一次对应音效")
	check(main._ai_beat(AIAgent.STEP_PAWN) is Signal, "AI典当节拍等待真实动画完成信号")
	await main.pipe.submit(Intent.action_done(main.foe_seat))
	await create_timer(0.25).timeout
	check(main._actor == main.foe_seat and main.board.input_locked
		and not main.sfx.actions.has("foe_action_done"), "远端提前收手也要等典当展示结束再交回玩家并提醒")
	check(is_instance_valid(batch.sold[0]) and batch.sold[0].position.distance_to(counter) < old_distance
		and batch.sold[0]._visual.scale.is_equal_approx(Vector3.ONE), "运送途中牌面正常大小且朝柜台前进")
	check(batch.fresh.all(func(card): return not card.visible), "送牌过程中不会提前显示回款")
	if main._table_actions.pawn_busy():
		await main._table_actions.pawn_finished
	await process_frame
	await settle()
	check(batch.sold.all(func(card): return not is_instance_valid(card)), "柜台收下的实体在演完后离场")
	check(batch.fresh.all(func(card): return (card.visible and card.position.z < 0
		and card._visual.scale.is_equal_approx(Vector3.ONE))), "全部回款落到对手区并恢复原尺寸")
	check(main._actor == main.my_seat and main.sfx.actions.count("foe_action_done") == 1
		and main.sfx.actions[-1] == "foe_action_done", "到账后交回玩家，完成提醒只在最后播放一次")
	check(main._ai_beat(AIAgent.STEP_PAWN) == null, "没有动画时AI节拍不返回永远等不到的信号")
	await _dispose(main)

func _rapid_buy() -> void:
	var main := await _fixture()
	var batch := await _sell(main)
	var paid: Array = batch.fresh.slice(0, 4).map(func(card): return card.uid)
	var bought: Dictionary = await main.pipe.submit(Intent.buy(main.foe_seat, 0, paid))
	check(bought.get("ok", false), "网络连续购买可以消费已裁决到账、仍在动画中的现金")
	if main._table_actions.pawn_busy():
		await main._table_actions.pawn_finished
	await settle()
	var cash := 0
	var aligned := true
	for record in main.state.players[main.foe_seat]["cards"]:
		var card: CardEntity = main.entities.get(record["uid"])
		if record["def_id"] != "cash":
			continue
		cash += int(card != null and card.visible)
		var at: Vector3 = main.layout._ai_flight.get(record["uid"], {}).get("at", card.position)
		aligned = aligned and card.position.is_equal_approx(at) and card._visual.scale.is_equal_approx(Vector3.ONE)
	check(cash == 14 and cash == main.state.resource_count(main.foe_seat, CardDB.RES_CASH),
		"连续消费后现金无丢失或重复，实体与实际余额相同")
	check(paid.all(func(uid): return not main.entities.has(uid)), "已消费的回款不会被延迟动画重新生成")
	check(aligned, "后续买牌接管剩余现金落点，旧回款动画不拉回旧位置")
	await _dispose(main)

func _ai_waits_before_buy() -> void:
	var main := await _fixture()
	var uids: Array = []
	for card in main.state.players[main.foe_seat]["cards"]:
		if card["def_id"] == "yinqing996":
			uids.append(card["uid"])
	var agent := AIAgent.new(main.pipe, main.foe_seat)
	# 固定已选计划，只检查真实驱动的呈现节拍，不把搜索偏好引入场景测试。
	agent._plan = {"intents": [Intent.pawn(main.foe_seat, uids), Intent.buy(main.foe_seat, 0)]}
	var done := [false]
	_drive(agent, main, done)
	check(main._table_actions.pawn_busy() and main.state.market.size() == 1,
		"真实AIAgent落地典当后暂停计划，没有立刻买掉商品")
	await create_timer(0.25).timeout
	check(main.state.market.size() == 1,
		"卖牌仍在前往柜台时，后续购买不会盖掉典当提示和动画")
	var deadline := Time.get_ticks_msec() + 5000
	while not done[0] and Time.get_ticks_msec() < deadline:
		await process_frame
	check(done[0] and main.state.market.is_empty(),
		"到账完成后真实AI计划继续购买并正常结束")
	check(main.state.players[main.foe_seat]["cards"].any(func(card): return card["def_id"] == "pinshaoshao"),
		"典当等待不吞掉后续购买意图")
	await _dispose(main)

func _drive(agent: AIAgent, main: Node, done: Array) -> void:
	await agent.run_action_phase(main._ai_beat)
	done[0] = true

func _resign_midflight() -> void:
	var main := await _fixture()
	main._run_foe_action()
	var batch := await _sell(main)
	await main.pipe.submit(Intent.resign(main.foe_seat))
	await process_frame
	check(main.phase == PhaseMachine.OVER and not main._table_actions.pawn_busy(),
		"认输立即中断典当并唤醒正在等待的行动流程")
	check(batch.sold.all(func(card): return not is_instance_valid(card)), "中断不会遗留已经注销的卖牌实体")
	check(batch.fresh.all(func(card): return (card.visible and card._visual.scale.is_equal_approx(Vector3.ONE)
		and card.position.z < 0)), "中断将已到账现金收束到牌桌，不留下隐藏或缩小的现金")
	await create_timer(1.8).timeout
	check(main.board.input_locked and main._actor == main.foe_seat
		and not main.sfx.actions.has("foe_action_done"), "旧典当结束不会在认输后重开操作或误发完成提醒")
	check(main.entities.size() == main.state.players[main.my_seat]["cards"].size()
		+ main.state.players[main.foe_seat]["cards"].size(), "中断后迟到回调不多生卡或漏卡")
	await _dispose(main)

func _dispose(main: Node) -> void:
	main._invalidate_session()
	main.queue_free()
	_booted = null
	await process_frame
	await process_frame
