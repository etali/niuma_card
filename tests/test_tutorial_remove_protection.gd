# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

var main: Node
var player: Control
var arena: Node3D
var results: Array = []
var last_drag: Array = []
var lesson_users: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 取消保护：真实尾段拆牌、归还用户与排列顺序 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌启动"):
		finish()
		return
	var original_state: GameState = main.state
	var original_hash := StateCodec.state_hash(original_state)
	var original_cards: Array = main.board.cards.duplicate()
	main.drawer_presentation._learning_invitation.hide()
	if need(main.drawer_presentation.start_tutorial("buffs"), "开启强化教学"):
		player = main.drawer_presentation.tutorial
		arena = player.arena
		arena.board.touch_mode = true
		arena.operation_finished.connect(func(result): results.append(result.duplicate(true)))
		await _buff_tail_then_return_users()
		await _users_before_buff()
		await _users_first_then_buff()
	main.drawer_presentation.finish_tutorial(false)
	await create_timer(0.6).timeout
	check(main.state == original_state and StateCodec.state_hash(main.state) == original_hash
		and main.board.cards == original_cards, "退出后原牌局、实体与分组未被练习和延迟回调污染")
	await dispose_drawer(main)
	finish()

func _buff_tail_then_return_users() -> void:
	if not await _prepare_remove(false): return
	var core := _card("yunketang")
	var buff := _card("tuisong")
	await _expand(core)
	var expected: Array = [buff.uid] + lesson_users
	await _drag(buff, _free_drop(), "推送处拖出尾段")
	check(last_drag == expected, "真实Board从推送处拿起推送及后续4用户，而非仅拿起Buff")
	check(_accepted() and _business_users() == 0 and _same_group(expected),
		"推送和4用户落到空处被接受，不回滚为原保护组")
	_check_intermediate("核心尚缺用户时不判定取消保护完成")
	if not _accepted(): return
	await _drag(arena.entities[lesson_users[0]], core.global_position, "尾段中的4用户归还云课堂")
	check(last_drag == lesson_users, "再次真实拾取只带走推送下方4用户，推送留在原处")
	_check_completed("先移出Buff尾段再归还用户")

func _users_before_buff() -> void:
	if not await _prepare_remove(true): return
	var buff := _card("tuisong")
	var members: Array = arena.board.group_of(buff)["cards"]
	check(members[-1] == buff and members.slice(1, 5).map(func(card): return card.uid) == lesson_users,
		"另一真实排列保留云课堂、4用户、推送的顺序")
	await _drag(buff, _free_drop(), "用户在前时仅移出末尾推送")
	check(last_drag == [buff.uid], "展开列末尾的推送按原Board机制只拿起一张")
	_check_completed("用户在Buff前时直接取消保护")

func _users_first_then_buff() -> void:
	if not await _prepare_remove(false): return
	await _expand(_card("yunketang"))
	await _drag(arena.entities[lesson_users[0]], _free_drop(), "先把推送下方4用户移开")
	check(last_drag == lesson_users and _accepted() and _same_group(lesson_users),
		"先拆用户也保留为合法中间操作，4用户没有被撤回")
	_check_intermediate("只剩云课堂和推送时仍等待恢复有效业务")
	if not _accepted(): return
	await _drag(_card("tuisong"), _free_drop(), "再把推送移到另一空处")
	check(last_drag == [_card("tuisong").uid] and _accepted(), "移出剩余推送不会撤销前一手已拆出的用户")
	_check_intermediate("移除推送但业务仍缺用户时继续等待")
	if not _accepted(): return
	await _drag(arena.entities[lesson_users[0]], _card("yunketang").global_position, "最后将4用户整摞放回业务")
	_check_completed("先拆用户再拆Buff最后归还用户")

## 只准备上一步的桌面。第四张用户/推送入组、继续、展开及拆牌均由根Viewport真实输入完成。
func _prepare_remove(buff_last: bool) -> bool:
	arena.cancel_pending_operation()
	player._reset_step_feedback()
	player.session.start("buffs")
	for index in player.session.course_data["steps"].size():
		if player.session.course_data["steps"][index]["id"] == "buff.spare":
			player.session.step_index = index
			break
	player.session._enter_step()
	arena.sync_state(true)
	arena.set_transition_busy(false)
	await create_timer(0.4).timeout
	var users := _cards("user")
	lesson_users = users.slice(0, 4).map(func(card): return card.uid)
	var core := _card("yunketang")
	var buff := _card("tuisong")
	var initial: Array = [core] + users.slice(0, 4) if buff_last else [core, buff] + users.slice(0, 3)
	var loose: CardEntity = buff if buff_last else users[3]
	_fixture_group(initial, Vector3(-1.8, 0.05, 1.4), not buff_last)
	_fixture_group([loose], Vector3(1.5, 0.05, 1.5), false)
	_fixture_group(users.slice(4), Vector3(4.6, 0.05, 2.0), true)
	_fixture_group(_cards("cash"), Vector3(-4.6, 0.05, 2.0), true)
	player.session.preview_groups(arena.current_groups())
	arena._sync_main()
	player._refresh()
	await create_timer(0.5).timeout
	if not need(not player.session.step_complete, "上一步只铺前置牌，等待真实补入资源/Buff"): return false
	await _drag(loose, core.global_position, "真实完成配方保护与富余对照")
	if not need(_accepted() and player.session.step_complete and player._awaiting_result,
		"完成保护对照后保留真实牌局，等待点击进入取消保护"): return false
	await tap_drawer_control(player._goal)
	await create_timer(0.4).timeout
	return need(player.session.current_step().get("id") == "buff.remove" and not player.session.step_complete
		and not arena.board.input_locked, "点击对白进入取消保护，沿用刚才的4用户业务现场")

func _fixture_group(cards: Array, at: Vector3, compact: bool) -> void:
	if cards.is_empty(): return
	arena._syncing_state = true
	for card in cards: arena.board._detach_from_group(card)
	var group: Dictionary = arena.board.make_group(cards, compact)
	arena.board.groups.append(group)
	arena.board._layout_group(group, at)
	arena._syncing_state = false

func _cards(id: String) -> Array:
	return arena.entities.values().filter(func(card): return card.draggable and card.def_id == id)

func _card(id: String) -> CardEntity:
	var cards := _cards(id)
	return null if cards.is_empty() else cards[0]

func _business_users() -> int:
	var group: Variant = arena.board.group_of(_card("yunketang"))
	return 0 if group == null else group["cards"].filter(func(card): return card.def_id == "user").size()

func _same_group(uids: Array) -> bool:
	var group: Variant = arena.board.group_of(arena.entities[uids[0]])
	return group != null and group["cards"].map(func(card): return card.uid) == uids

func _accepted() -> bool:
	return results.size() == 1 and results[0].get("expected", false) and not results[0].get("rolled_back", false)

func _check_intermediate(label: String) -> void:
	check(player.session.current_step().get("id") == "buff.remove" and not player.session.step_complete
		and not player._awaiting_result and not arena.operation_pending and not arena.board.input_locked, label)

func _check_completed(label: String) -> void:
	var core_group: Variant = arena.board.group_of(_card("yunketang"))
	var user_ids: Array = [] if core_group == null else core_group["cards"].filter(func(card): return card.def_id == "user").map(func(card): return card.uid)
	check(_accepted() and user_ids == lesson_users and _business_users() == 4
		and not core_group["cards"].has(_card("tuisong")), label + "：保留原4用户和业务，只有推送独立在外")
	check(player.session.step_complete and player._awaiting_result and arena.board.input_locked
		and player.session.current_step().get("id") == "buff.remove", label + "：有效无保护业务完成目标，留现场等待点击")
	var preview: GameState = player.session._preview_state()
	check(preview.combos.size() == 1 and preview.protected_uids(GameState.PLAYER, preview.combos[0], CardDB.RES_USER).is_empty(),
		label + "：真实规则仍认可云课堂配方，用户已不受推送保护")

func _free_drop() -> Vector3:
	return arena.layout._free_spot(Vector3(1.3, 0.05, 2.0), GameState.PLAYER)

func _visible_point(card: CardEntity) -> Vector2:
	for z in [-0.65, -0.4, 0.0, 0.4, 0.65]:
		for x in [0.0, -0.4, 0.4]:
			var point: Vector2 = arena.camera.unproject_position(card.to_global(Vector3(x, 0.05, z)))
			if arena.board._pick_card(point) == card and not main.drawer_presentation.pointer_over_panels(point): return point
	return Vector2.INF

func _expand(card: CardEntity) -> void:
	var point := _visible_point(card)
	if not need(point != Vector2.INF, "展开操作能真实拾取原业务摞"): return
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.double_click = true
	press.position = point
	press.global_position = point
	root.push_input(press)
	await process_frame
	press.pressed = false
	press.double_click = false
	root.push_input(press)
	await create_timer(0.4).timeout
	check(not arena.board.group_of(card)["compact"], "根Viewport双击展开，沿用正式Board收展行为")

func _drag(card: CardEntity, target: Vector3, label: String) -> void:
	results.clear()
	last_drag.clear()
	arena.board._reset_click_track()
	var point := _visible_point(card)
	if not need(point != Vector2.INF, label + "：卡牌可见且未被小人遮挡"): return
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	root.push_input(press)
	await process_frame
	last_drag = arena.board._drag_cards.map(func(member): return member.uid)
	check(not last_drag.is_empty() and last_drag[0] == card.uid, label + "：根Viewport真实拾取指定卡牌及尾段")
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
	await create_timer(0.9).timeout
	print("REMOVE_PROTECTION ", label, " picked=", last_drag, " results=", results,
		" groups=", arena.current_groups(), " completed=", player.session.step_complete)
