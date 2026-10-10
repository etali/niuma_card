# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

const Snapshot = preload("res://scenes/table_snapshot.gd")
var main: Node
var player: Control
var arena: Node3D
var checkpoint: Dictionary
var layout_checkpoint: Dictionary
var results: Array = []
var last_drag: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 首课富余用户：真实买牌、拆牌、整摞方向与落桌 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌启动"): return
	main.drawer_presentation._learning_invitation.hide()
	seed(444) # 固定正式购买到货位置，不移动卡牌来回避真实拾取。
	if not need(main.drawer_presentation.start_tutorial("income"), "开启首课"): return
	player = main.drawer_presentation.tutorial
	arena = player.arena
	arena.board.touch_mode = true
	arena.operation_finished.connect(func(result): results.append(result.duplicate(true)))
	await create_timer(0.4).timeout
	await _drag(_largest_users("cash")["cards"][0], arena.market_cards[0].global_position, "真实购买")
	if not need(await _continue_step("income.split"), "真实买牌后直接进入拆牌"): return
	var users := _largest_users()
	if users["compact"]: arena.board.toggle_compact(users["cards"][0])
	await create_timer(0.3).timeout
	await _drag(users["cards"][-1], Vector3(0, 0.05, 1.8), "真实拆1用户")
	if not need(await _continue_step("income.group"), "真实拆牌后直接进入配牌"): return
	check(_largest_users()["cards"].size() == 7 and _single_user() != null,
		"教程现场是7张用户摞和1张拆出的用户")
	checkpoint = player.session.capture_operation()
	layout_checkpoint = Snapshot.capture(main)

	# 两种重合方向应同样合法：不能只允许拖小摞，却拒绝拖大摞。
	for large_first in [true, false]:
		await _restore()
		var many := _largest_users()["cards"][0] as CardEntity
		var single := _single_user()
		await _drag(many if large_first else single, single.global_position if large_first else many.global_position,
			"7到1" if large_first else "1到7")
		var merged: bool = _largest_users()["cards"].size() == 8
		check(_accepted() and merged, "合回8张用户，方向%s同样被接受" % ("7→1" if large_first else "1→7"))
		if merged:
			await _drag(_largest_users()["cards"][0], _business().global_position, "8张到云课堂")
			check(await _continue_step("income.settle") and _business_users() == 8,
				"合回的8张整摞满足云课堂配方并保留全部富余用户")

	# 收拢/展开各测两个真实方向；不直接改Session组牌来准备富余牌。
	for compact in [false, true]:
		for reverse in [false, true]:
			await _restore()
			await _drag(_single_user(), _largest_users()["cards"][0].global_position, "矩阵准备8张")
			if not need(_accepted() and _largest_users()["cards"].size() == 8, "收展/方向用例真实合回8张"): return
			var group := _largest_users()
			if bool(group["compact"]) != compact:
				arena.board.toggle_compact(group["cards"][0])
				await create_timer(0.3).timeout
			var resource: CardEntity = group["cards"][0]
			var business := _business()
			await _drag(business if reverse else resource, resource.global_position if reverse else business.global_position,
				"%s %s" % ["收拢" if compact else "展开", "业务到8用户" if reverse else "8用户到业务"])
			check(await _continue_step("income.settle") and _business_users() == 8,
				"%s的富余用户与业务%s拖动都保留8用户" % ["收拢" if compact else "展开", "反向" if reverse else "正向"])

	await _restore()
	await _drag(_single_user(), _largest_users()["cards"][0].global_position, "准备8张")
	if need(_largest_users()["cards"].size() == 8, "落桌用例通过真实拖牌合成8张"):
		await _drag(_largest_users()["cards"][0], Vector3(-2.4, 0.05, 2.1), "8张先落空处")
		check(_accepted() and _largest_users()["cards"].size() == 8, "整摞8张先放空处只是整理位置，不回滚")
		await _drag(_largest_users()["cards"][0], _business().global_position, "落桌后8张到业务")
		check(await _continue_step("income.settle") and _business_users() == 8,
			"整摞先落空处再拖业务仍可完成配方")
	await _buff_material_first()
	main.drawer_presentation.finish_tutorial(false)
	await dispose_drawer(main)
	finish()

func _buff_material_first() -> void:
	check(main.drawer_presentation.start_tutorial("buffs"), "从原牌桌进入强化教学")
	player = main.drawer_presentation.tutorial
	arena = player.arena
	for attempt in 42:
		if arena.session.current_step().get("id") == "buff.protect_user": break
		var result: Dictionary = arena.session.run_example()
		if not result.get("ok", false) or not arena.session.step_complete: break
		arena.session.acknowledge()
	if not need(arena.session.current_step().get("id") == "buff.protect_user", "前置抵达用户保护课"): return
	arena.sync_state(true)
	await create_timer(0.5).timeout
	var buff: CardEntity
	for card in arena.entities.values():
		if card.draggable and card.def_id == "tuisong": buff = card
	if not need(buff != null and _largest_users()["cards"].size() == 4, "现场提供4用户与推送弹窗"): return
	await _drag(_largest_users()["cards"][0], buff.global_position, "4用户先拖到推送")
	var material: Variant = arena.board.group_of(buff)
	if not need(_accepted() and material != null and material["cards"].size() == 5,
		"先叠4用户与推送是合法中间准备，不要求业务必须先入组"): return
	await _drag(material["cards"][0], _business().global_position, "用户推送整摞拖到云课堂")
	var group: Variant = arena.board.group_of(_business())
	check(_accepted() and _business_users() == 4 and group != null and group["cards"].has(buff),
		"4用户与推送整摞进入云课堂，目标仍等待真实完成行动")
	var preview: GameState = arena.session._preview_state()
	var protected := {}
	for combo in preview.combos:
		if combo["owner"] == GameState.PLAYER and combo["eval"].get("leader") == "yunketang":
			protected = preview.protected_uids(GameState.PLAYER, combo, CardDB.RES_USER)
	var event_start: int = arena.session.events.size()
	results.clear()
	var point: Vector2 = main.btn_pass.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	root.push_input(press)
	await process_frame
	press.pressed = false
	root.push_input(press)
	for attempt in 600:
		if not results.is_empty(): break
		await create_timer(0.02).timeout
	var hits: Array = arena.session.events.slice(event_start).filter(func(event): return event.get("op") == Intent.OP_ATTACK)
	check(_accepted() and hits.size() == 1 and hits[0]["seat"] == GameState.BOT
		and hits[0]["target"]["kind"] == "spare" and hits[0]["removed"].size() == 1
		and not protected.has(hits[0]["removed"][0]),
		"点击原完成按钮后只有BOT攻击未受保护的第4张用户，没有我方自攻或目标回滚")
	check(protected.size() == 3 and protected.keys().all(func(uid): return arena.entities.has(uid))
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_USER) == 3
		and arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 16,
		"真实先备料路径保住3张配方用户，云课堂照常产4现金")

func _restore() -> void:
	arena.cancel_pending_operation()
	player._reset_step_feedback()
	player.session.restore_operation(checkpoint)
	arena.sync_state(true, layout_checkpoint)
	await create_timer(0.5).timeout
	results.clear()

func _largest_users(id := "user") -> Dictionary:
	var largest := {"cards": []}
	for group in arena.board.groups:
		if group["cards"].all(func(card): return card.def_id == id) and group["cards"].size() > largest["cards"].size(): largest = group
	return largest

func _single_user() -> CardEntity:
	for card in arena.entities.values():
		if not card.draggable or card.def_id != "user": continue
		var group: Variant = arena.board.group_of(card)
		if group == null or group["cards"].size() == 1: return card
	return null

func _business() -> CardEntity:
	for card in arena.entities.values():
		if card.draggable and card.def_id == "yunketang": return card
	return null

func _business_users() -> int:
	var group: Variant = arena.board.group_of(_business())
	return 0 if group == null else group["cards"].filter(func(card): return card.def_id == "user").size()

func _accepted() -> bool:
	return not results.is_empty() and results[-1].get("expected", false) and not results[-1].get("rolled_back", false)

func _visible_point(card: CardEntity) -> Vector2:
	for z in [-0.65, -0.4, 0.0, 0.4, 0.65]:
		for x in [0.0, -0.4, 0.4]:
			var point: Vector2 = arena.camera.unproject_position(card.to_global(Vector3(x, 0.05, z)))
			if arena.board._pick_card(point) == card and not main.drawer_presentation.pointer_over_panels(point): return point
	return arena.camera.unproject_position(card.global_position)

func _drag(card: CardEntity, target: Vector3, label: String) -> void:
	results.clear()
	arena.board._reset_click_track()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = _visible_point(card)
	press.global_position = press.position
	root.push_input(press)
	await process_frame
	last_drag = arena.board._drag_cards.map(func(member): return member.uid)
	check(not last_drag.is_empty(), label + "：根Viewport按下真实卡牌")
	var before: Dictionary = arena._operation_before.duplicate(true)
	var split: int = arena._split_uid
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = arena.camera.unproject_position(Vector3(target.x, Board.DRAG_HEIGHT, target.z) - arena.board._grab_offset)
	motion.global_position = motion.position
	root.push_input(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = motion.position
	release.global_position = motion.position
	root.push_input(release)
	await process_frame
	var after: Dictionary = arena.session.capture_operation()
	print("SURPLUS ", label, " picked=", last_drag.size(), " before_step=", before.get("step", -1),
		" after_step=", after["step_index"], " split_candidate=", split,
		" before_groups=", before.get("logic", {}).get("groups", []), " after_groups=", after["groups"],
		" pending_reason=", arena._pending_rollback.get("reason", ""))
	await create_timer(0.9).timeout
	print("SURPLUS_FINAL ", label, " step=", arena.session.current_step().get("id"), " results=", results)

func _wait_step(id: String) -> bool:
	for attempt in 100:
		if arena.session.current_step().get("id") == id and not arena.operation_pending: return true
		await create_timer(0.025).timeout
	return false

func _continue_step(id: String) -> bool:
	return await _wait_step(id) and not player._awaiting_result and not arena.board.input_locked
