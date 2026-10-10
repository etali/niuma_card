# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

var main: Node
var player: Control
var arena: Node3D
var watching := false
var births: Dictionary = {}
var prior_uids: Dictionary = {}
var producers: Dictionary = {}
var sources: Dictionary = {}
var feedback: Dictionary = {}
var final_events: Array = []
var held_step := ""
var held_generation := -1
var step_stayed := true
var input_stayed_locked := true
var payment_animated := false
var watched_payments: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 原牌桌教学结算：真实产出、落地后推进、取消隔离 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌启动成功"): return
	main.drawer_presentation._learning_invitation.hide()
	var original_state: GameState = main.state
	var original_cards: Array = main.board.cards.duplicate()
	var original_snapshot := StateCodec.snapshot(original_state)
	main._flush_record_view()
	var original_tape: Dictionary = main.tape.to_dict().duplicate(true)

	await _settle_case("income", "income.settle", "income.result", {"cash": 4}, {"cash": "yunketang"})
	await _settle_case("growth", "growth.settle", "growth.refill", {"cash": 4, "user": 2},
		{"cash": "yunketang", "user": "ditui"}, 2)
	await _settle_case("buffs", "buff.stack", "buff.attack", {"cash": 16}, {"cash": "yunketang"})
	await _growth_alternative()
	await _reference_during_flight()

	# 退出在真正飞行中发生，不只是在逻辑结算后的短暂停顿里发生。
	if await _prepare("income", "income.settle", {"cash": "yunketang"}):
		_start_observing()
		main.btn_pass.pressed.emit()
		var in_flight := await _wait_for_flight()
		check(in_flight, "退出用例确实截在新现金飞行途中")
		var abandoned := _teaching_refs()
		watching = false
		main.drawer_presentation.finish_tutorial(false)
		await create_timer(2.5).timeout
		check(main.state == original_state and StateCodec.snapshot(main.state) == original_snapshot
			and main.board.cards == original_cards and main.tape.to_dict() == original_tape,
			"飞入途中退出后原局状态、卡实体及录像不受旧结算污染")
		check(final_events.is_empty() and _all_freed(abandoned), "退出取消旧产出与回调，教学实体全部释放")

	if await _prepare("income", "income.settle", {"cash": "yunketang"}):
		_start_observing()
		main.btn_pass.pressed.emit()
		check(await _wait_for_flight(), "切课用例确实截在新现金飞行途中")
		var abandoned := _teaching_refs()
		var borrowed_arena := arena
		watching = false
		check(main.drawer_presentation.start_tutorial("growth"), "产出飞行中可以切换课程")
		var next_state: GameState = arena.session.state
		var next_snapshot := StateCodec.snapshot(next_state)
		var next_cards: Array = arena.entities.values().duplicate()
		await create_timer(2.5).timeout
		check(arena == borrowed_arena and arena.session.course_id == "growth"
			and arena.session.current_step().get("id") == "growth.buy"
			and arena.session.state == next_state and StateCodec.snapshot(next_state) == next_snapshot
			and arena.entities.values() == next_cards,
			"切课复用原Arena，旧动画不会重新生成卡牌或自动推进新课程")
		check(final_events.is_empty() and _all_freed(abandoned) and not arena.operation_pending,
			"切课释放旧飞行卡且不发晚到accepted，不遗留输入锁")
		main.drawer_presentation.finish_tutorial(false)
		check(main.state == original_state and StateCodec.snapshot(main.state) == original_snapshot
			and main.tape.to_dict() == original_tape, "切课再退出仍恢复原对局与录像")
	await dispose_drawer(main)
	finish()

func _growth_alternative() -> void:
	if not await _prepare("growth", "growth.buy", {}): return
	var choices: Array = arena.market_cards.filter(func(card): return card.def_id == "pinshaoshao")
	if not need(choices.size() == 1, "扩大生意的真实市场提供拼少少"): return
	var price := int(CardDB.get_def("pinshaoshao")["price"])
	var recipe := int(CardDB.get_def("pinshaoshao")["recipe_n"])
	var cash_before: int = arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	final_events.clear()
	# 从Arena正式购买入口支付实际现金卡，不能只调用Session.buy绕过操作审查。
	arena._purchase(_owned_cards("cash"), choices[0])
	await _finish_step("growth.buy", "growth.groups")
	var advanced := await _wait_step("growth.groups")
	if not need(advanced and _owned_cards("pinshaoshao").size() == 1
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before - price,
		"购买拼少少真实扣除4现金，保留业务，直接进入双业务配牌"): return
	check(final_events.size() == 1 and final_events[0].result.get("expected", false)
		and not final_events[0].result.get("rolled_back", false) and _owned_cards("ditui").is_empty(),
		"满足增加用户目标的替代业务被接受，不回滚成示例地推扫码")
	var instruction := str(arena.session.current_step().get("instruction"))
	check(instruction.contains(CardDB.card_name("pinshaoshao"))
		and instruction.replace("\u2060", "").replace(" ", "").contains(str(recipe) + "张现金"),
		"配牌说明跟随买到的拼少少，显示真实3现金配方")
	var income: CardEntity = _owned_cards("yunketang")[0]
	var growth: CardEntity = _owned_cards("pinshaoshao")[0]
	var users: Array = _owned_cards("user").slice(0, int(CardDB.get_def("yunketang")["recipe_n"]))
	var cash: Array = _owned_cards("cash").slice(0, recipe)
	final_events.clear()
	_apply_checked_groups(income, [
		[income.uid] + users.map(func(card): return card.uid),
		[growth.uid] + cash.map(func(card): return card.uid)])
	await _finish_step("growth.groups", "growth.settle")
	if not need(await _wait_step("growth.settle"), "云课堂与拼少少按各自真实配方编组，直接进入结算"): return
	if not _watch_producers({"cash": "yunketang", "user": "pinshaoshao"}, "拼少少分支"): return
	await _settle_current("growth", "growth.settle", "growth.refill", {"cash": 4, "user": 4},
		{"cash": "yunketang", "user": "pinshaoshao"}, recipe)
	if arena.session.current_step().get("id") != "growth.refill": return
	check(arena.state.round_num == 2 and arena.session.current_step().get("instruction", "").contains("拼少少"),
		"下一回合仍为实际购买的拼少少补料，不退回地推扫码示例")
	# 拼少少实际用3现金；放4张是合法富余资源，不能再次被教学的示例张数拒绝。
	final_events.clear()
	cash = _owned_cards("cash").slice(0, 4)
	_apply_checked_groups(growth, [[growth.uid] + cash.map(func(card): return card.uid)])
	if not need(await _wait_for_finish(), "为拼少少补4现金的真实编组收到操作审查结果"): return
	var replenished: Dictionary = arena.board.group_of(growth)
	check(final_events.size() == 1 and final_events[0].result.get("expected", false)
		and not final_events[0].result.get("rolled_back", false) and arena.session.step_complete
		and replenished["cards"].filter(func(card): return card.def_id == "cash").size() == 4,
		"补4现金保留在拼少少组内并完成目标，合法富余资源不被回滚")

func _apply_checked_groups(core: CardEntity, groups: Array) -> void:
	# 捕获拿牌前状态，再让真实Board编组；落牌仍经过Arena的延迟操作审查。
	arena._pick_started(core)
	arena.apply_groups(groups)
	arena._layout_changed()

func _wait_step(id: String) -> bool:
	for attempt in 150:
		if arena.session.current_step().get("id") == id and not arena.operation_pending: return true
		await create_timer(0.025).timeout
	return false

func _reference_during_flight() -> void:
	if not await _prepare("income", "income.settle", {"cash": "yunketang"}): return
	_start_observing()
	main.btn_pass.pressed.emit()
	if not need(await _wait_for_flight(), "打开图鉴前确实存在正在飞行的新现金"): return
	var p: Node = main.drawer_presentation
	p._open_utility(7)
	p._rulebook.show_atlas("cards")
	var paused_cards: Dictionary = {}
	for birth: Dictionary in births.values():
		var card: CardEntity = birth.ref.get_ref()
		paused_cards[card.uid] = {"ref": birth.ref, "position": card.global_position, "scale": card._visual.scale}
	check(p._utility.visible and p._rulebook.current_page == "cards" and player._reference_open,
		"飞行中通过正式入口打开卡牌图鉴并暂停教程")
	# 超过这一批飞牌和收摞原本需要的时间，避免只验证了暂停入口的一帧。
	await create_timer(1.5).timeout
	check(paused_cards.values().all(func(saved):
		var card: CardEntity = saved.ref.get_ref()
		return card != null and card.global_position.is_equal_approx(saved.position) \
			and card._visual.scale.is_equal_approx(saved.scale)),
		"查阅图鉴期间所有新现金的位置与飞行缩放保持不变")
	check(arena.operation_pending and final_events.is_empty()
		and arena.session.current_step().get("id") == held_step
		and int(arena.session.generation) == held_generation and not player._awaiting_result,
		"查阅期间结算仍在等待，不后台落地、不发accepted也不推进步骤")
	p.close_panels()
	check(not player._reference_open and p.tutorial == player and player.arena == arena,
		"关闭图鉴恢复同一教学现场")
	var completed := await _wait_for_finish()
	watching = false
	if not need(completed, "关闭图鉴后暂停的结算能继续完成"): return
	check(final_events.size() == 1 and final_events[0].result.get("expected", false)
		and final_events[0].flying == 0 and not final_events[0].transferring
		and births.size() == 4 and births.values().all(func(birth): return birth.moved),
		"恢复后四张现金继续飞到桌面，落位完成才发一次accepted")
	await _finish_step("income.settle", "income.result")
	for attempt in 120:
		if arena.session.current_step().get("id") == "income.result": break
		await create_timer(0.025).timeout
	check(arena.session.current_step().get("id") == "income.result",
		"查阅返回后完成演出，直接进入已有收入观察步骤，避免连续确认两次")

func _settle_case(course: String, step_id: String, next_step: String,
		expected: Dictionary, leaders: Dictionary, payment_count := 0) -> void:
	if not await _prepare(course, step_id, leaders): return
	await _settle_current(course, step_id, next_step, expected, leaders, payment_count)

func _settle_current(course: String, step_id: String, next_step: String,
		expected: Dictionary, leaders: Dictionary, payment_count := 0) -> void:
	var original_users: Array = _owned_cards("user")
	var original_cash_count := _owned_cards("cash").size()
	if payment_count > 0:
		var paid_group: Dictionary = arena.board.group_of(producers["user"])
		watched_payments = paid_group["cards"].filter(func(card): return card.def_id == "cash")
		check(watched_payments.size() == payment_count, "拉新配方确实放入%d张真实现金卡" % payment_count)
	_start_observing()
	if course == "buffs":
		var returned: Dictionary = arena.finish_action()
		check(returned.get("ok", false), "异步呈现保持finish_action同步返回真实裁决结果")
	else:
		main.btn_pass.pressed.emit()
	check(arena.operation_pending and main.btn_pass.disabled and arena.board.input_locked,
		step_id + "：原行动按钮启动真实演出并锁住重复操作")
	check(final_events.is_empty() and arena.session.current_step().get("id") == step_id,
		step_id + "：同步逻辑完成时不立即通知或跳过观察")
	check(arena.finish_action().get("code") == "busy", step_id + "：演出期间重复结算不会再发资源")
	var completed := await _wait_for_finish()
	watching = false
	if not need(completed, step_id + "：在有限时间内完成实际结算动画"): return
	check(final_events.size() == 1 and final_events[0].result.get("expected", false)
		and not final_events[0].result.get("rolled_back", false), step_id + "：落地后只发一次accepted")
	check(step_stayed and input_stayed_locked, step_id + "：动画全程保持旧步骤、场景和输入锁")
	check(final_events[0].flying == 0 and not final_events[0].transferring
		and final_events[0].step == (next_step if _automatic_step(course, step_id) else step_id)
		and final_events[0].generation == held_generation,
		step_id + "：accepted发生时所有飞入与收摞已结束，仍可看见本步结果")
	for resource: String in expected:
		var actual: Array = births.values().filter(func(birth): return birth.id == resource)
		check(actual.size() == int(expected[resource]), step_id + "：真实新增%d张%s实体" % [expected[resource], resource])
		check(actual.all(func(birth): return birth.flew and birth.near_source and birth.moved),
			step_id + "：每张" + resource + "从对应组合附近出生并实际飞向落位")
		check(feedback.get(resource, false), step_id + "：" + leaders[resource] + "播放正式生产反馈")
	check(final_events[0].counts.cash == original_cash_count + int(expected.get("cash", 0)) - payment_count
		and final_events[0].counts.user == original_users.size() + int(expected.get("user", 0)),
		step_id + "：落位实体数量与经营的净收入相符")
	check(original_users.all(func(card): return is_instance_valid(card) and arena.entities.get(card.uid) == card),
		step_id + "：原有用户实体留在桌上，未因同步整桌重建")
	if payment_count > 0:
		check(payment_animated and watched_payments.all(func(card): return not is_instance_valid(card)),
			"%d张配方现金先播放正式吸收，再释放；用户产出不是瞬间替换" % payment_count)
	await _finish_step(step_id, next_step)
	for attempt in 120:
		if arena.session.current_step().get("id") == next_step: break
		await create_timer(0.025).timeout
	check(arena.session.current_step().get("id") == next_step, step_id + "：演出完成后按课程推进策略进入" + next_step)
	if course == "buffs":
		check(int(arena.session.generation) != held_generation and _owned_cards("zuokong").size() == 1,
			"强化现金全部落位后才换到攻击场景，未吞掉16张产出的观察机会")

func _prepare(course: String, target: String, leaders: Dictionary) -> bool:
	watching = false
	if main.drawer_presentation.tutorial != null:
		main.drawer_presentation.finish_tutorial(false)
		await process_frame
	if not need(main.drawer_presentation.start_tutorial(course), "开始结算课程 " + course): return false
	player = main.drawer_presentation.tutorial
	arena = player.arena
	# 仅用已有课程计划准备前置局面；待测这一步的round操作必须走原按钮。
	for attempt in 42:
		if arena.session.current_step().get("id") == target: break
		var prepared: Dictionary = arena.session.run_example()
		if not prepared.get("ok", false) or not arena.session.step_complete: break
		arena.session.acknowledge()
	if not need(arena.session.current_step().get("id") == target, "前置真实规则抵达 " + target): return false
	for action: Dictionary in arena.session.current_step().get("demo", []):
		if action.get("op") == "groups": arena.session._example_action(action)
	arena.sync_state(true)
	player._refresh()
	await create_timer(0.5).timeout
	if not _watch_producers(leaders, target): return false
	if not arena.child_entered_tree.is_connected(_child_entered): arena.child_entered_tree.connect(_child_entered)
	if not arena.operation_finished.is_connected(_operation_finished): arena.operation_finished.connect(_operation_finished)
	watched_payments = []
	return true

func _watch_producers(leaders: Dictionary, target: String) -> bool:
	producers = {}
	sources = {}
	for resource: String in leaders:
		var cards := _owned_cards(str(leaders[resource]))
		if not need(cards.size() == 1, target + "：桌上存在真实业务 " + leaders[resource]): return false
		var core: CardEntity = cards[0]
		producers[resource] = core
		var group: Variant = arena.board.group_of(core)
		if not need(group != null and group["cards"].size() > 1, target + "：业务已与配方组成真实牌组"): return false
		var center := Vector3.ZERO
		for card: CardEntity in group["cards"]: center += card.global_position
		sources[resource] = center / float(group["cards"].size())
	return true

func _start_observing() -> void:
	prior_uids = {}
	for uid in arena.entities: prior_uids[uid] = true
	births = {}
	feedback = {}
	final_events = []
	held_step = str(arena.session.current_step().get("id"))
	held_generation = int(arena.session.generation)
	step_stayed = true
	input_stayed_locked = true
	payment_animated = false
	watching = true

func _child_entered(child: Node) -> void:
	if watching and child is CardEntity and child.draggable and not prior_uids.has(child.uid):
		# spawn_card先入树，随后正式CardMotion设置出生位置与补间；同帧末观察。
		_record_birth.call_deferred(weakref(child))

func _record_birth(reference: WeakRef) -> void:
	var card: CardEntity = reference.get_ref()
	if not watching or card == null or prior_uids.has(card.uid): return
	var origin: Vector3 = sources.get(card.def_id, Vector3.INF)
	var tween: Tween = card.get_meta("fly_tw") if card.has_meta("fly_tw") else null
	births[card.uid] = {"id": card.def_id, "ref": reference, "at": card.global_position,
		"flew": card.has_meta("dest_pos") and tween != null and tween.is_valid() and tween.is_running(),
		"near_source": Vector2(card.global_position.x, card.global_position.z).distance_to(Vector2(origin.x, origin.z)) < 1.8,
		"moved": false}

func _observe() -> void:
	if not watching: return
	if arena.operation_pending:
		step_stayed = step_stayed and arena.session.current_step().get("id") == held_step \
			and int(arena.session.generation) == held_generation and not player._awaiting_result
		input_stayed_locked = input_stayed_locked and arena.board.input_locked and main.btn_pass.disabled
	for resource in producers:
		var card: CardEntity = producers[resource]
		if is_instance_valid(card) and card.feedback_event == "produce": feedback[resource] = true
	for birth: Dictionary in births.values():
		var card: CardEntity = birth.ref.get_ref()
		if card != null and card.global_position.distance_to(birth.at) > 0.1: birth.moved = true
	if not watched_payments.is_empty() and arena._card_motion.transferring():
		payment_animated = payment_animated or watched_payments.any(func(card): return is_instance_valid(card))

func _operation_finished(result: Dictionary) -> void:
	# 也保留取消之后的晚到事件，不能用watching开关把污染隐藏掉。
	_observe()
	final_events.append({"result": result.duplicate(true), "step": arena.session.current_step().get("id"),
		"generation": int(arena.session.generation), "flying": _flying_count(),
		"transferring": arena._card_motion.transferring(),
		"counts": {"cash": _owned_cards("cash").size(), "user": _owned_cards("user").size()}})

func _wait_for_finish() -> bool:
	for attempt in 500:
		_observe()
		if not final_events.is_empty(): return true
		await create_timer(0.02).timeout
	return false

func _wait_for_flight() -> bool:
	for attempt in 250:
		_observe()
		if births.size() > 0 and _flying_count(true) > 0 and arena.operation_pending: return true
		if not final_events.is_empty(): return false
		await create_timer(0.02).timeout
	return false

func _flying_count(new_only := false) -> int:
	var count := 0
	for card: CardEntity in arena.entities.values():
		if new_only and prior_uids.has(card.uid): continue
		var tween: Tween = card.get_meta("fly_tw") if card.has_meta("fly_tw") else null
		if tween != null and tween.is_valid() and tween.is_running(): count += 1
	return count

func _owned_cards(id: String) -> Array:
	return arena.entities.values().filter(func(card): return card.draggable and card.def_id == id)

func _teaching_refs() -> Array:
	return arena.entities.values().map(func(card): return weakref(card))

func _all_freed(references: Array) -> bool:
	return references.all(func(reference): return reference.get_ref() == null)

func _automatic_step(course: String, step_id: String) -> bool:
	for step in TutorialCatalog.course(course)["steps"]:
		if step["id"] == step_id: return step.get("advance", "confirm") == "operation"
	return false

func _finish_step(step_id: String, next_step: String) -> void:
	if _automatic_step(arena.session.course_id, step_id):
		if not need(await _wait_step(next_step), step_id + "：操作及演出结束直接进入" + next_step): return
		var snapshot := StateCodec.snapshot(arena.state)
		var cards: Array = arena.entities.values().duplicate()
		await create_timer(0.8).timeout
		check(not player._awaiting_result and arena.session.current_step()["id"] == next_step
			and StateCodec.snapshot(arena.state) == snapshot and arena.entities.values() == cards,
			step_id + "：只衔接一次，空闲保留新目标和真实牌桌，不再自行跳步")
		if step_id == "income.settle":
			check(player._reading_step() and player._goal.text == "点我继续教程：扩大生意",
				"收入结算直接停在已有跨课阅读提示，保持指定文案且无需双重确认")
		return
	for attempt in 200:
		if player._awaiting_result and not arena.operation_pending: break
		await create_timer(0.02).timeout
	var snapshot := StateCodec.snapshot(arena.state)
	var cards: Array = arena.entities.values().duplicate()
	await create_timer(0.8).timeout
	check(player._awaiting_result and arena.session.current_step().get("id") == step_id
		and StateCodec.snapshot(arena.state) == snapshot and arena.entities.values() == cards,
		step_id + "：演出结束后结果和牌实体保留，必须点击继续")
	await relayout_drawer(main)
	await tap_drawer_control(player._bubble)
