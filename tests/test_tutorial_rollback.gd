# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

const Scope = preload("res://engine/tutorial_context.gd")
const Arena = preload("res://scenes/tutorial_arena.gd")
const Snapshot = preload("res://scenes/table_snapshot.gd")

class RecordedSound extends Sfx:
	var events: Array[String] = []
	func play(action: String, _pitch := 1.0) -> void:
		if not user_muted and (not drawer_suspended or Sfx.action(action).get("notification", false)):
			events.append(action)

var main: Node
var arena: Node3D
var scope: RefCounted
var sound: RecordedSound
var results: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	var original_state: GameState = main.state
	var original_cards: Array = main.board.cards.duplicate()
	var original_hash := StateCodec.state_hash(original_state)
	sound = RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	await _start("income")
	check(arena._table_actions.get_script() == main._table_actions.get_script(), "教学买卖共用正式TableActions")
	var before := _snapshot()
	await _drag(_resource_top("cash"), arena.market_cards[1].position)
	check(arena.operation_pending and arena.state.market != before.logic.state.market,
		"买错先执行真实购买并短暂显示，随后锁住等待回滚")
	var changed_hash := StateCodec.state_hash(arena.state)
	check(arena.finish_action().get("code") == "busy" and StateCodec.state_hash(arena.state) == changed_hash,
		"回滚等待期间不能重复完成行动")
	await _rolled_back(before, "买错恢复现金、市场、UID、RNG与原牌位")
	check(sound.events.count("buy") == 1 and sound.events.count("deny_quiet") == 1
		and not sound.events.has("deny"), "错误购买只在原购买声后补一声轻提示")
	check(results.size() == 1 and not results[0].expected and results[0].rolled_back,
		"错误操作只在恢复后发出一次最终事件")

	# 引擎本身拒绝的操作也只发一声轻提示，不叠加原deny。
	before = _snapshot()
	await _drag(_resource_top("user"), arena.market_cards[0].position)
	await _rolled_back(before, "用用户付钱被规则拒绝后也恢复拿牌前的整摞")
	check(sound.events.count("deny_quiet") == 1 and not sound.events.has("deny"), "引擎拒绝不会产生两次错误音")

	results.clear()
	# 商品到货用全局随机挑空位；固定这次表现随机数，避免落点偶然紧邻素材堆。
	seed(444)
	await _drag(_resource_top("cash"), arena.market_cards[0].position)
	check(arena.operation_pending and results.is_empty(), "正确购买等待真实到货演出，不提前发accepted")
	await _wait_operation()
	check(not arena.operation_pending and arena.session.step_complete and results[-1].expected,
		"正确购买演出完成后发accepted并完成当前目标")
	await create_timer(0.65).timeout
	var bought_uid: int = _card("yunketang").uid
	var remaining_slots: Array = Snapshot.capture(main).market
	check(remaining_slots == before.visual.market.slice(1), "正式购买演出保留其余商品原槽位，不填空槽")
	_advance()
	before = _snapshot()
	await _drag(_card("yunketang"), main.board.pawn_pos)
	check(arena.operation_pending and arena.state.find_card(GameState.PLAYER, bought_uid).is_empty(),
		"错误典当先执行真实卖牌与到账")
	await _rolled_back(before, "典当回滚保留此前正确购买的业务与现金")
	check(_card("yunketang").uid == bought_uid and sound.events.count("pawn") == 1,
		"回滚只撤销典当这一手，业务UID不变且复用原典当声")

	await _expand(_resource_top("cash"))
	before = _snapshot()
	await _drag(main.board.group_of(_resource_top("cash"))["cards"][-1], _free_drop(), true)
	await _rolled_back(before, "拆错资源恢复整个原组、卡序、展开态和精确位置")
	await _expand(_resource_top("user"))
	results.clear()
	await _drag(main.board.group_of(_resource_top("user"))["cards"][-1], _free_drop())
	await _wait_operation()
	check(results[-1].expected and arena.session.step_complete, "拆出一张用户被判为正确操作")
	_advance()
	# 正式配方允许附加现金和富余用户；用第二张不相干业务核心制造真正无效的组。
	arena.state.add_card(GameState.PLAYER, "baoyue")
	arena.sync_state()
	await create_timer(0.4).timeout
	before = _snapshot()
	await _drag(_card("baoyue"), _card("yunketang").position)
	await _rolled_back(before, "业务混入不相干业务核心后回滚，保留先前正确拆牌")
	results.clear()
	await _expand(_unassigned_user())
	await _drag(_unassigned_user(), _card("yunketang").position)
	await _wait_operation()
	check(results[-1].expected and not arena.session.step_complete, "正确的第一张材料作为中间进展被接受")
	await create_timer(0.3).timeout
	before = _snapshot()
	main.btn_pass.pressed.emit()
	check(arena.operation_pending and arena.session.phase == "review", "提前结束先经过原按钮执行真实结算")
	await _rolled_back(before, "提前结束只撤销本次结算，不撤销此前部分正确组牌")
	for _i in 2:
		var next := _unassigned_user()
		await _expand(next)
		await _drag(_unassigned_user(), _card("yunketang").position)
		await _wait_operation()
	check(arena.session.step_complete, "逐张添加正确用户最终完成组牌目标")
	_advance()
	before = _snapshot()
	await _drag(_card("baoyue"), _card("yunketang").position)
	await _rolled_back(before, "加入不相干业务核心后恢复已完成配方")
	var cash_before: int = arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	main.btn_pass.pressed.emit()
	check(arena.operation_pending, "正确完成行动先播放生产，不提前发accepted")
	await _wait_operation()
	check(not arena.operation_pending and arena.session.step_complete
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before + 4,
		"正确完成行动保留真实生产结果并被接受")
	await create_timer(0.4).timeout
	before = _snapshot()
	main.btn_pass.pressed.emit()
	await _rolled_back(before, "多点一次进入下一回合会回滚抽牌、UID、随机数和阶段")

	await _check_attack_resource_recovery()
	await _check_growth_resource_exchange()
	await _start("attack")
	arena.session.run_example()
	arena.sync_state(true)
	_advance()
	arena.finish_action()
	await _wait_operation()
	check(arena.session.phase == "attack" and not arena.operation_pending, "正确完成行动进入攻击阶段")
	var target_count: int = arena.session.applier.affordable_targets(GameState.PLAYER).size()
	var pool: Dictionary = arena.session.applier.pools(GameState.PLAYER)
	check(target_count > 0 and main.attack_target_text.text.contains("可攻击目标 %d" % target_count),
		"原攻击面板按进攻方查询合法目标，与教学引擎保持一致")
	check(main.attack_pool_text.text == "现金攻击 %d    用户攻击 %d" % [pool.get(CardDB.RES_CASH, 0), pool.get(CardDB.RES_USER, 0)],
		"原攻击点数面板直接显示真实池")
	_advance()
	before = _snapshot()
	var wrong: Dictionary = {}
	for target in arena.session.applier.affordable_targets(GameState.PLAYER):
		if target.get("leader", "") != "pinshaoshao": wrong = target; break
	if need(not wrong.is_empty(), "存在当前目标以外的合法攻击靶"):
		arena._attack(arena.entities[int(wrong.uids[0])])
		check(arena.operation_pending and not main.board.attack_mode, "错误攻击期间暂时禁止再次点靶")
		await _rolled_back(before, "错误攻击恢复被移除资源、攻击池、批次锁和点靶模式")

	# 静音、重试与退出都必须能取消尚未恢复的事务，旧回调不能继续修改牌桌。
	sound.events.clear()
	sound.set_user_muted(true)
	before = _snapshot()
	arena.finish_action()
	await _rolled_back(before, "静音下提前结束攻击也会正确恢复")
	check(sound.events.is_empty(), "用户静音时回滚不发轻提示")
	sound.set_user_muted(false)
	arena.finish_action()
	check(arena.operation_pending, "为重试创建待回滚操作")
	arena.cancel_pending_operation()
	arena.session.retry()
	arena.sync_state(true)
	var retried := _snapshot()
	await create_timer(0.5).timeout
	check(_same_snapshot(retried), "重试后旧回调不会恢复上一手或上一步")
	arena.finish_action()
	check(arena.operation_pending, "为退出创建待回滚操作")
	scope.release()
	await create_timer(0.5).timeout
	check(main.state == original_state and StateCodec.state_hash(main.state) == original_hash
		and main.board.cards == original_cards, "待回滚时退出完整恢复原局，延迟回调不污染它")
	await dispose_drawer(main)
	finish()

func _check_attack_resource_recovery() -> void:
	await _start("attack")
	await _expand(_resource_top("cash"))
	var before := _snapshot()
	await _drag(_loose_resource("cash"), _card("yunketang").position)
	check(arena.operation_pending and _core_resource_count("yunketang", "cash") == 1,
		"攻击配牌时单张错现金先实际叠入云课堂，再等待本手回滚")
	await _rolled_back(before, "空云课堂放入错类型现金会撤销，不误判为配方进展")

	await _start("attack")
	var cash_pile := _resource_top("cash")
	check(main.board.group_of(cash_pile)["cards"].size() == 10, "复现截图的十现金整摞")
	before = _snapshot()
	await _drag(cash_pile, _card("yunketang").position)
	check(arena.operation_pending and _core_resource_count("yunketang", "cash") == 10,
		"十现金错配也先呈现真实叠牌，再锁住等待回滚")
	await _rolled_back(before, "整摞十现金不能代替云课堂所需用户，牌位与组态完整撤销")

	await _start("attack")
	await _expand(_resource_top("user"))
	await _accepted_drag(_loose_resource("user"), _card("yunketang").position,
		"云课堂先放一张正确用户保留为中间进展")
	await _expand(_resource_top("cash"))
	before = _snapshot()
	await _drag(_loose_resource("cash"), _card("yunketang").position)
	await _rolled_back(before, "云课堂已有一张正确用户时再放现金，只撤销错现金这一手")
	check(_core_resource_count("yunketang", "user") == 1 and _core_resource_count("yunketang", "cash") == 0,
		"错误回滚保留此前做对的用户，不重新开始整步")

	await _start("attack")
	# 旧版本已经放行的截图坏局面：不重演错误判定，仅用既有编组入口恢复现场。
	# 后面的每次修正仍经过真实按下、拖动、释放和 Arena 审查。
	var cash_ids: Array = []
	var user_ids: Array = []
	for record in arena.state.players[GameState.PLAYER]["cards"]:
		if record["def_id"] == "cash": cash_ids.append(record["uid"])
		if record["def_id"] == "user": user_ids.append(record["uid"])
	arena.apply_groups([
		{"uids": [_card("yunketang").uid] + cash_ids.slice(0, 10), "at": Vector3(3.5, 0.05, 2.0)},
		{"uids": [_card("zuokong").uid] + user_ids, "at": Vector3(-3.5, 0.05, 2.0)}
	])
	arena.session.preview_groups(arena.current_groups())
	await create_timer(0.35).timeout
	check(not arena.session.step_complete and _core_resource_count("yunketang", "cash") == 10
		and _core_resource_count("zuokong", "user") == 10, "恢复截图：做空占十用户、云课堂错配十现金，目标尚未完成")
	await _expand(_card("yunketang"))
	for index in 10:
		var source := _core_resource_top("yunketang", "cash")
		var target := _loose_resource("cash")
		await _accepted_drag(source, target.position, "从错误云课堂逐张移走第%d张现金应允许修正" % (index + 1))
		check(_core_resource_count("yunketang", "cash") == 9 - index
			and _core_resource_count("zuokong", "user") == 10,
			"修正第%d张现金后只改变本手，保留另一摞十用户" % (index + 1))
		var loose_cash := _loose_resource("cash")
		var cash_group: Variant = main.board.group_of(loose_cash)
		if cash_group != null and not cash_group.get("compact", false):
			main.board.toggle_compact(loose_cash)
			await create_timer(0.25).timeout
	check(_core_resource_count("yunketang", "cash") == 0 and not arena.session.step_complete,
		"最后一张错现金也能拆走，剩裸核心不会被错误回滚")

	await _expand(_card("zuokong"))
	for index in 4:
		var source := _core_resource_top("zuokong", "user")
		var spare := _loose_resource("user")
		await _accepted_drag(source, _free_drop() if spare == null else spare.position,
			"从合法十用户做空摞拆出第%d张富余用户应允许" % (index + 1))
		check(_core_resource_count("zuokong", "user") == 9 - index,
			"拆富余用户保留做空所需的六张配方下限")
	for index in 3:
		await _expand(_loose_resource("user"))
		await _accepted_drag(_loose_resource("user"), _card("yunketang").position,
			"把拆出的第%d张用户移给云课堂，允许逐手调整资源分配" % (index + 1))
	check(arena.session.step_complete and _core_resource_count("zuokong", "user") == 6
		and _core_resource_count("yunketang", "user") == 3
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 11
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_USER) == 10,
		"截图坏局面可通过真实拆牌重配修好：六用户攻击、三用户赚钱，资源不增不减")
	await _expand(_loose_resource("cash"))
	await _accepted_drag(_loose_resource("cash"), _card("yunketang").position,
		"已经凑齐真实配方后仍允许附加现金，不把纠错限制变成新玩法规则")

func _check_growth_resource_exchange() -> void:
	await _start("growth")
	await _accepted_drag(_resource_top("cash"), arena.market_cards[0].position, "真实购买地推后进入双业务资源交换回归")
	await create_timer(0.4).timeout
	_advance()
	var cash_ids: Array = []
	var user_ids: Array = []
	for record in arena.state.players[GameState.PLAYER]["cards"]:
		if record["def_id"] == "cash": cash_ids.append(record["uid"])
		if record["def_id"] == "user": user_ids.append(record["uid"])
	arena.apply_groups([
		{"uids": [_card("yunketang").uid] + cash_ids, "at": Vector3(3.5, 0.05, 2.0)},
		{"uids": [_card("ditui").uid] + user_ids, "at": Vector3(-3.5, 0.05, 2.0)}
	])
	arena.session.preview_groups(arena.current_groups())
	await create_timer(0.35).timeout
	check(not arena.session.step_complete and _core_resource_count("yunketang", "cash") == 9
		and _core_resource_count("ditui", "user") == 8, "恢复双业务错配：云课堂现金、地推用户，不能交叉冒充配方进展")
	# 真实牌桌按列尾拆牌：先把要换出的用户放在桌上，避免后来追加的现金压住它们。
	await _expand(_card("ditui"))
	for index in 3:
		var spare := _loose_resource("user")
		await _accepted_drag(_core_resource_top("ditui", "user"), _free_drop() if spare == null else spare.position,
			"从地推错组取出第%d张用户备用，允许降低错配" % (index + 1))
	await _expand(_card("yunketang"))
	for index in 2:
		await _accepted_drag(_core_resource_top("yunketang", "cash"), _card("ditui").position,
			"把第%d张现金直接从云课堂错组移给需要现金的地推" % (index + 1))
	for index in 3:
		await _expand(_loose_resource("user"))
		await _accepted_drag(_loose_resource("user"), _card("yunketang").position,
			"把第%d张备用用户移给云课堂，完成真实资源交换" % (index + 1))
	check(arena.session.step_complete and _core_resource_count("yunketang", "user") == 3
		and _core_resource_count("ditui", "cash") == 2 and _core_resource_count("yunketang", "cash") == 7
		and _core_resource_count("ditui", "user") == 5,
		"交换错配后两组真实配方均成立，合法富余资源不要求强行拆净")
	check(arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_ids.size()
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_USER) == user_ids.size(),
		"交换错配不重置整步、不新增或丢弃任何资源")

func _accepted_drag(card: CardEntity, at: Vector3, message: String) -> void:
	var count := results.size()
	await _drag(card, at)
	await _wait_operation()
	check(not arena.operation_pending and results.size() == count + 1 and results[-1].get("expected", false)
		and not results[-1].get("rolled_back", false), message)

func _core_resource_count(core_id: String, res: String) -> int:
	var group: Variant = main.board.group_of(_card(core_id))
	return 0 if group == null else group["cards"].filter(func(card): return card.def_id == res).size()

func _core_resource_top(core_id: String, res: String) -> CardEntity:
	var group: Variant = main.board.group_of(_card(core_id))
	if group != null:
		for index in range(group["cards"].size() - 1, -1, -1):
			var card: CardEntity = group["cards"][index]
			if card.def_id == res: return card
	return null

func _loose_resource(res: String) -> CardEntity:
	for card in arena.entities.values():
		if not card.draggable or card.def_id != res: continue
		var group: Variant = main.board.group_of(card)
		if group == null: return card
		if group["cards"].all(func(member): return member.def_id == res):
			return group["cards"][Board._top_index(group)]
	return null

func _start(course: String) -> void:
	if scope != null and scope.active:
		scope.release()
		await process_frame
	scope = Scope.new()
	if not need(scope.begin(main), "原牌桌开始课程 " + course): return
	arena = Arena.new()
	main.add_child(arena)
	arena.configure_on_table(main, TutorialSession.new(course))
	arena.operation_finished.connect(func(result): results.append(result))
	main.board.touch_mode = true
	await create_timer(0.45).timeout
	results.clear()
	sound.events.clear()

func _snapshot() -> Dictionary:
	arena.session.preview_groups(arena.current_groups())
	return {"logic": arena.session.capture_operation(), "visual": Snapshot.capture(main),
		"transform": main.board.camera.transform, "fov": main.board.camera.fov,
		"zoom": main.drawer_presentation.camera_view.zoom, "offset": main.drawer_presentation.camera_view.offset}

func _same_snapshot(before: Dictionary) -> bool:
	return StateCodec.canon(arena.session.capture_operation()) == StateCodec.canon(before.logic) \
		and StateCodec.canon(Snapshot.capture(main)) == StateCodec.canon(before.visual) \
		and main.board.camera.transform.is_equal_approx(before.transform) \
		and is_equal_approx(main.board.camera.fov, before.fov) \
		and is_equal_approx(main.drawer_presentation.camera_view.zoom, before.zoom) \
		and main.drawer_presentation.camera_view.offset.is_equal_approx(before.offset)

func _rolled_back(before: Dictionary, message: String) -> void:
	# 与正式攻击/生产共用演出后，整手会等纸片、到账与回滚全部结束。
	await _wait_operation()
	check(not arena.operation_pending and _same_snapshot(before), message)
	check(not results.is_empty() and results[-1].rolled_back and not results[-1].reason.is_empty(), "回滚最终事件带当前目标说明")

func _wait_operation() -> void:
	for attempt in 250:
		if not arena.operation_pending: return
		await create_timer(0.02).timeout
	check(false, "操作演出与回滚在有限时间内发出最终事件")

func _advance() -> void:
	arena.session.acknowledge()
	arena.sync_state()

func _card(id: String) -> CardEntity:
	for card in arena.entities.values():
		if card.draggable and card.def_id == id: return card
	return null

func _resource_top(id: String) -> CardEntity:
	var card := _card(id)
	var group: Variant = main.board.group_of(card)
	return group["cards"][0] if group != null else card

func _unassigned_user() -> CardEntity:
	var used: Variant = main.board.group_of(_card("yunketang"))
	for group in main.board.groups:
		if not is_same(group, used) and not group["cards"].is_empty() and group["cards"][-1].def_id == "user":
			return group["cards"][-1]
	for card in arena.entities.values():
		if card.draggable and card.def_id == "user" and main.board.group_of(card) == null: return card
	return null

func _expand(card: CardEntity) -> void:
	var group: Variant = main.board.group_of(card)
	if group != null and group.get("compact", false):
		main.board.toggle_compact(card)
		await create_timer(0.25).timeout

func _free_drop() -> Vector3:
	return arena.layout._free_spot(Vector3(0, 0.05, 4), GameState.PLAYER)

func _drag(card: CardEntity, at: Vector3, immediate_followup := false) -> void:
	sound.events.clear()
	main.board._reset_click_track()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = main.board.camera.unproject_position(card.global_position)
	root.push_input(down)
	await process_frame
	check(main.board._drag_cards.has(card), "根Viewport真实按下在拆组前捕获这一手")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = main.board.camera.unproject_position(Vector3(at.x, Board.DRAG_HEIGHT, at.z) - main.board._grab_offset)
	root.push_input(motion)
	await process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = motion.position
	root.push_input(up)
	if immediate_followup:
		var epoch: int = arena._operation_epoch
		check(arena._refresh_queued and arena.operation_pending and main.board.input_locked,
			"落牌同帧立即锁住输入，延迟审查前没有空窗")
		main.board._reset_click_track()
		var again := InputEventMouseButton.new()
		again.button_index = MOUSE_BUTTON_LEFT
		again.pressed = true
		again.position = main.board.camera.unproject_position(_card("yunketang").global_position)
		root.push_input(again)
		check(main.board._drag_cards.is_empty() and arena._operation_epoch == epoch,
			"同帧第二次按下不能抬牌或覆盖上一手快照")
		again.pressed = false
		root.push_input(again)
	await process_frame
