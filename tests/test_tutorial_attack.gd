# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

class RecordedSound extends Sfx:
	var events: Array[String] = []
	func play(action: String, _pitch := 1.0) -> void:
		events.append(action)

var main: Node
var player: Control
var arena: Node3D
var sound: RecordedSound
var completed: Array = []
var original: Dictionary
var original_cards: Array

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 教学攻击：正式整摞裁决、抓握撕牌、暂停与取消 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "正式牌桌启动"): return
	main.drawer_presentation._learning_invitation.hide()
	original = StateCodec.snapshot(main.state)
	original_cards = main.board.cards.duplicate()
	sound = RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	await _player_batch()
	await _loose_pile()
	await _bot_attack(false)
	await _bot_attack(false, 3)
	await _bot_attack(true)
	await _cancel_attack(false)
	await _cancel_attack(true)
	check(StateCodec.snapshot(main.state) == original and main.board.cards == original_cards,
		"全部攻击演出与取消结束后原局和原卡实体完整恢复")
	await dispose_drawer(main)
	finish()

func _prepare(course: String, target: String, arm := true) -> bool:
	if main.drawer_presentation.tutorial != null:
		main.drawer_presentation.finish_tutorial(false)
		await process_frame
	if not need(main.drawer_presentation.start_tutorial(course), "开启真实教学 " + course): return false
	player = main.drawer_presentation.tutorial
	arena = player.arena
	for attempt in 42:
		if arena.session.current_step().get("id") == target: break
		var result: Dictionary = arena.session.run_example()
		if not result.get("ok", false) or not arena.session.step_complete: break
		arena.session.acknowledge()
	if not need(arena.session.current_step().get("id") == target, "前置操作抵达 " + target): return false
	for action: Dictionary in arena.session.current_step().get("demo", []):
		if action.get("op") == "groups" or (arm and action.get("op") == "round"):
			arena.session._example_action(action)
	arena.sync_state(true)
	await create_timer(0.5).timeout
	completed.clear()
	sound.events.clear()
	arena.operation_finished.connect(func(result): completed.append({"result": result,
		"step": arena.session.current_step().get("id"), "retired_alive": arena._card_motion._tear_cards.any(func(card): return is_instance_valid(card))}))
	return true

func _target(resource: String, leader := "") -> Dictionary:
	for target: Dictionary in arena.session.applier.affordable_targets(GameState.PLAYER):
		if target.get("res") == resource and (leader == "" or target.get("leader") == leader): return target
	return {}

func _trigger(target: Dictionary) -> Array:
	var card: CardEntity = arena.entities[int(target["uids"][0])]
	var known: Dictionary = arena.entities.duplicate()
	main.board.attack_clicked.emit(card)
	var removed: Array = []
	for uid in known:
		if not arena.entities.has(uid): removed.append(known[uid])
	return removed

func _player_batch() -> void:
	if not await _prepare("attack", "attack.hit"): return
	var target := _target("cash", "pinshaoshao")
	if not need(not target.is_empty(), "真实配方现金是合法攻击目标"): return
	var batch_count: int = main.table_hands.batch_count
	var event_count: int = arena.session.events.size()
	var cards := _trigger(target)
	check(cards.size() == int(CardDB.get_def("pinshaoshao")["recipe_n"]) and cards.size() > 1,
		"一次点击真实组合摞连续扣除全部可负担配方，不再只扣一张")
	check(arena.state.winner == "" and arena.operation_pending and completed.is_empty()
		and arena.session.current_step().get("id") == "attack.hit" and not player._awaiting_result,
		"非最后一击也等待正式撕牌，动作中不推进本步")
	var hits: Array = arena.session.events.slice(event_count).filter(func(event): return event.get("op") == Intent.OP_ATTACK)
	check(hits.size() == cards.size() and main.table_hands.batch_count == batch_count + 1
		and sound.events.count("attack") == 1 and cards.all(func(card): return is_instance_valid(card) and not card._visual_retired),
		"多次真实裁决合成一次命中、一双原牌桌手和同一抓握阶段")
	var positions: Array = cards.map(func(card): return card.global_position)
	main.drawer_presentation._open_utility(main.drawer_presentation.UTILITY_RULEBOOK)
	main.drawer_presentation._rulebook.show_atlas("cards")
	var hand_time: float = main.table_hands._batches[0]["elapsed"]
	await create_timer(1.0).timeout
	var stationary := true
	for i in cards.size(): stationary = stationary and is_instance_valid(cards[i]) and cards[i].global_position.is_equal_approx(positions[i])
	check(stationary and arena.operation_pending and completed.is_empty() and not sound.events.has("attack_tear")
		and is_equal_approx(main.table_hands._batches[0]["elapsed"], hand_time) and not main.table_hands.visible,
		"抓握中打开图鉴，卡牌、双手、延迟撕牌声与步骤一起暂停")
	main.drawer_presentation.close_panels()
	check(main.table_hands.visible, "关闭图鉴恢复原双手，不创建另一套攻击视图")
	check(await _wait_torn(cards), "原卡实体真正切成两片并使用正式撕纸着色器")
	check(arena.operation_pending and completed.is_empty() and sound.events.count("attack_tear") == 1,
		"整摞同时撕开只响一声，纸片仍在桌上时不得accepted")
	await _wait_completed()
	check(completed.size() == 1 and completed[0].result.get("expected", false)
		and not completed[0].result.get("rolled_back", false) and not completed[0].retired_alive,
		"所有纸片退场后只发一次accepted，整摞不被教程回滚")

func _loose_pile() -> void:
	if not await _prepare("buffs", "buff.attack"): return
	var cash_pool: int = arena.session.applier.pools(GameState.PLAYER)[CardDB.RES_CASH]
	var user_pool: int = arena.session.applier.pools(GameState.PLAYER)[CardDB.RES_USER]
	var cash_cards := _trigger(_target("cash"))
	check(cash_pool == 6 and cash_cards.size() > 1 and cash_cards.size() <= cash_pool
		and arena.session.applier.pools(GameState.PLAYER)[CardDB.RES_USER] == user_pool,
		"闲置现金整摞沿用正式点数上限，不消耗用户攻击池")
	await _wait_completed()
	check(completed.size() == 1 and completed[0].result.get("expected", false) and arena.session.step_complete,
		"热搜增强后的整摞攻击被接受并完成本步")

func _bot_attack(wrong: bool, cash_count := 2) -> void:
	if not await _prepare("defense", "defense.protect", false): return
	if cash_count == 3:
		arena.session._example_action({"op": "groups", "groups": [{"ditui": 1, "cash": 3, "jiangjia": 1}]})
		arena.sync_state(true)
		await create_timer(0.35).timeout
	if wrong:
		# 真实移除保护卡后结束行动：对手确实打穿业务，教程随后应回滚。
		for group in arena.board.groups.duplicate():
			for card in group["cards"].duplicate():
				if card.def_id == "jiangjia": arena.board._detach_from_group(card)
		arena.session.preview_groups(arena.current_groups())
	var known: Dictionary = arena.entities.duplicate()
	var count: int = main.table_hands.batch_count
	var event_start: int = arena.session.events.size()
	var preview: GameState = arena.session._preview_state()
	var protected := {}
	var exposed: Array = []
	var spare: Array = []
	var weapon: CardEntity
	for combo in preview.combos:
		if combo["owner"] == GameState.PLAYER and combo["eval"].get("leader") == "ditui":
			protected = preview.protected_uids(GameState.PLAYER, combo, CardDB.RES_CASH)
	for target in preview.attack_targets(GameState.PLAYER):
		if target.get("res") != CardDB.RES_CASH: continue
		exposed.append_array(target["uids"])
		if target.get("kind") == "spare": spare.append_array(target["uids"])
	for card in known.values():
		if not card.draggable and card.def_id == "zuokong": weapon = card
	if not wrong:
		check(protected.size() == 2 and spare.size() == cash_count - 2 and protected.keys().all(func(uid): return known[uid]._shield_on)
			and exposed.all(func(uid): return not protected.has(uid)),
			"放%d现金时真实保护集合与护盾均只覆盖配方2张，富余现金可受击" % cash_count)
	var operation_goal: String = player._goal.text
	var operation_step: int = arena.session.step_index
	var before_positions := {}
	for uid in exposed: before_positions[uid] = known[uid].global_position
	main.btn_pass.pressed.emit()
	var removed: Array = []
	for uid in known:
		if not arena.entities.has(uid): removed.append(known[uid])
	if not need(not removed.is_empty(), "对手实际攻击玩家实体" + ("（错误结束）" if wrong else "")): return
	var attack_n := int(CardDB.get_def("zuokong")["attack_n"])
	check(removed.all(func(card): return card.draggable) and main.table_hands.batch_count > count
		and arena.operation_pending and completed.is_empty(), "对手攻击也经过同一双手，先撕真实玩家牌再结算")
	if not wrong:
		var hits: Array = arena.session.events.slice(event_start).filter(func(event): return event.get("op") == Intent.OP_ATTACK)
		var hit_ids: Array = []
		for hit in hits: hit_ids.append_array(hit["removed"])
		check(hits.size() == attack_n and hits.all(func(hit): return hit["seat"] == GameState.BOT and hit["target"]["res"] == CardDB.RES_CASH)
			and hit_ids.all(func(uid): return exposed.has(uid) and not protected.has(uid)) and spare.all(func(uid): return hit_ids.has(uid)),
			"放%d现金：%d次真实攻击都来自BOT，先打组内富余，只移除未保护的现金UID" % [cash_count, attack_n])
		# 现金配方结算时照常付款；受保护的2张应躲过攻击，再作为配方付款离场。
		var paid: Array = []
		for event in arena.session.events.slice(event_start):
			if event.get("op") == Intent.OP_PRODUCE and event.get("seat") == GameState.PLAYER:
				paid.append_array(event.get("resolution", {}).get("paid_uids", []))
		paid.sort()
		var shielded: Array = protected.keys()
		shielded.sort()
		# 演出按批移除实体：此刻只确定首批离场，命中总数以上面的真实攻击事件为准。
		check(removed.all(func(card): return hit_ids.has(card.uid)) and paid == shielded,
			"受保护2张现金躲过攻击，结算时正好作为地推扫码的配方付款")
		check(weapon != null and weapon.feedback_event == "attack" and not weapon.draggable,
			"对面真实做空报告牌发出攻击反馈")
		if spare.is_empty():
			# 只打散现金时三张同属一批，正式撕牌双手围住整批被击现金。
			var hand_bounds: Rect2 = main.table_hands._batches[-1]["bounds"].grow(2.0)
			var camera: Camera3D = main.board.camera
			check(removed.all(func(card): return hand_bounds.has_point(camera.unproject_position(before_positions[card.uid]))),
				"正式撕牌双手围住同一批被击散现金")
		print("PROTECTION cash=", cash_count, " protected=", protected.keys(), " spare=", spare,
			" hits=", hit_ids, " paid=", paid, " weapon_uid=", weapon.uid)
		await _click_control(player._mascot if cash_count == 2 else player._goal)
		check(arena.operation_pending and completed.is_empty() and not player._awaiting_result
			and arena.session.step_index == operation_step and player._goal.text == operation_goal,
			"攻击动画中真实点击对白不能跳过，也不能提前显示观察结果")
	check(await _wait_torn(removed), "对手攻击的玩家牌也真正切成两片")
	if not wrong:
		await create_timer(0.08).timeout
		check(is_instance_valid(removed[0]) and removed[0].global_position.z < before_positions[removed[0].uid].z,
			"被攻击现金纸片沿正式BOT攻击方向飘向对面，不使用玩家攻击方向")
	await _wait_completed()
	check(completed.size() == 1 and bool(completed[0].result.get("rolled_back", false)) == wrong
		and bool(completed[0].result.get("expected", false)) != wrong,
		"对手演出结束后才按教学目标接受或回滚")
	if not wrong:
		check(arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 8 - attack_n - 2
			and arena.state.resource_count(GameState.PLAYER, CardDB.RES_USER) == 8 + int(CardDB.get_def("ditui")["output_n"])
			and arena.state.winner == "",
			"只损失未受保护的现金，受保护地推扫码付2现金正常产用户且未判负")
		await _confirm_result(player._mascot if cash_count == 2 else player._goal, cash_count == 2)
	else:
		await create_timer(1.0).timeout
		await _click_control(player._goal)
		check(not player._awaiting_result and not player.is_processing() and arena.session.step_index == operation_step
			and completed.size() == 1 and not arena.session.step_complete,
			"错误结束回滚不进入观察确认，等待和点击都不能把失败当成功推进")

func _confirm_result(control: Control, reference: bool) -> void:
	var course: String = arena.session.course_id
	var step: int = arena.session.step_index
	var state := StateCodec.snapshot(arena.state)
	var cards: Dictionary = arena.entities.duplicate()
	var events: Array = arena.session.events.duplicate(true)
	var accepted := completed.size()
	var result_goal: String = arena.session.current_step().get("completion_goal", "")
	check(player._awaiting_result and not player.is_processing() and player._can_tap()
		and not result_goal.is_empty() and player._goal.text == TutorialCatalog.ui("coach.tap_continue", {"goal": result_goal})
		and arena.board.input_locked and main.btn_pass.disabled,
		"真实攻击与生产都演完后才显示配置结果，锁住牌桌等待点击确认")
	# 跨过旧自动推进的0.45秒；对白不再处理idle，也不能留下SceneTreeTimer偷偷推进。
	await create_timer(1.0).timeout
	check(player._awaiting_result and arena.session.course_id == course and arena.session.step_index == step
		and StateCodec.snapshot(arena.state) == state and arena.entities.size() == cards.size()
		and cards.keys().all(func(uid): return arena.entities.get(uid) == cards[uid])
		and arena.session.events == events and completed.size() == accepted,
		"结果空闲后仍是同一步、同批实体与资源，没有计时处理、额外事件或自动换场")
	if reference:
		main.drawer_presentation._open_utility(main.drawer_presentation.UTILITY_RULEBOOK)
		main.drawer_presentation._rulebook.show_atlas("cards")
		await create_timer(1.0).timeout
		main.drawer_presentation.close_panels()
		check(player._awaiting_result and player._can_tap() and arena.session.step_index == step
			and arena.board.input_locked and main.btn_pass.disabled and StateCodec.snapshot(arena.state) == state,
			"查阅真实图鉴再返回仍等待观察确认，不解锁操作或自动继续")
		var position_before: Vector2 = player.position
		await _drag_mascot()
		check(player.position.distance_to(position_before) > 1 and player._awaiting_result
			and arena.session.step_index == step and arena.session.events == events,
			"观察期间仍能拖小人挪开对白，拖动不算确认")
	await _click_control(control)
	check(arena.session.course_id == course and arena.session.step_index == step + 1 and not player._awaiting_result,
		("小人" if control == player._mascot else "气泡") + "真实点击只确认一次并进入下一步")
	var next_state := StateCodec.snapshot(arena.state)
	await _click_control(control)
	check(arena.session.step_index == step + 1 and StateCodec.snapshot(arena.state) == next_state,
		"重复点击不会跳过下一项尚未完成的操作")

func _click_control(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	root.push_input(press)
	await process_frame
	press.pressed = false
	root.push_input(press)
	await process_frame

func _drag_mascot() -> void:
	var source: Vector2 = player._mascot.get_global_rect().get_center()
	var destination := source + Vector2(-45, -30)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = source
	press.global_position = source
	root.push_input(press)
	await process_frame
	var move := InputEventMouseMotion.new()
	move.button_mask = MOUSE_BUTTON_MASK_LEFT
	move.position = destination
	move.global_position = destination
	root.push_input(move)
	await process_frame
	press.pressed = false
	press.position = destination
	press.global_position = destination
	root.push_input(press)
	await process_frame

func _cancel_attack(switching: bool) -> void:
	if not await _prepare("attack", "attack.hit"): return
	var cards := _trigger(_target("cash", "pinshaoshao"))
	var refs: Array = cards.map(func(card): return weakref(card))
	var sound_count: int = sound.events.size()
	if switching:
		main.drawer_presentation.start_tutorial("income")
	else:
		main.drawer_presentation.finish_tutorial(false)
	var expected := StateCodec.snapshot(main.state)
	await create_timer(1.3).timeout
	check(refs.all(func(ref): return ref.get_ref() == null) and completed.is_empty()
		and main.table_hands._batches.is_empty() and main.table_hands.process_mode == Node.PROCESS_MODE_ALWAYS,
		"抓握期间" + ("切课" if switching else "退出") + "清理纸片、双手与旧回调")
	check(StateCodec.snapshot(main.state) == expected and sound.events.size() == sound_count,
		"取消后无晚到撕牌声，也不会污染新课程或恢复后的原局")
	if switching: main.drawer_presentation.finish_tutorial(false)
	await process_frame

func _wait_torn(cards: Array) -> bool:
	for attempt in 60:
		if cards.all(func(card): return is_instance_valid(card) and _halves(card) == 2): return true
		if cards.any(func(card): return not is_instance_valid(card)): return false
		await create_timer(0.015).timeout
	return false

func _halves(card: CardEntity) -> int:
	var count := 0
	for node in card.get_children():
		if not node is Node3D or node.get_child_count() == 0: continue
		var mesh := node.get_child(0) as MeshInstance3D
		if mesh != null and mesh.material_override is ShaderMaterial \
			and mesh.material_override.shader.resource_path.ends_with("card_tear.gdshader"): count += 1
	return count

func _wait_completed() -> void:
	for attempt in 600:
		if not completed.is_empty(): return
		await create_timer(0.02).timeout
