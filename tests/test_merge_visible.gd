# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 使用实际抽屉牌桌、鼠标拾取与松手并组，检查有实体但沉到桌下的“消失”。
## 七张 / 二十张 / 四十八张覆盖低摞、超过显示层上限的高摞与飞行目标。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉组合后卡牌可见性 ===")
	for spec in [[7, "pinshaoshao", false], [20, "pinshaoshao", false],
		[48, "pinshaoshao", true], [20, "cash", false]]:
		await _pile_onto_loose(int(spec[0]), str(spec[1]), bool(spec[2]))
	await _core_onto_raised_pile()
	await _loose_onto_raised_card()
	await _buy_from_compact_pile()
	await _restored_pile_stays_above_table()
	finish()

func _boot() -> Node:
	paused = false
	root.size = Vector2i(1600, 1000)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	main.sfx.set_muted(true)
	main.drawer_window.set_process(false)
	main.board.set_process(false)
	main.board.input_locked = false
	main.drawer_presentation.set_process(false)
	return main

func _card(main: Node, id: String, at: Vector3) -> CardEntity:
	var data: Dictionary = main.state.add_card(main.my_seat, id)
	var card: CardEntity = main._spawn_entity(data, at, true)
	card.freeze = true
	return card

func _event(board: Board, point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = pressed
	board._unhandled_input(event)

func _pile_onto_loose(count: int, target_id: String, flying: bool) -> void:
	var main := await _boot()
	var board: Board = main.board
	var context := "%d张现金并入%s%s" % [count, "飞入中的" if flying else "静止", target_id]
	var source: Array = []
	for i in count:
		source.append(_card(main, "cash", Vector3(-3.7, 0.05, 3.0)))
	var pile := board.make_group(source.duplicate(), true)
	board.groups.append(pile)
	board._layout_group(pile, Vector3(-3.7, 0.05, 3.0))
	var target := _card(main, target_id, Vector3(0.4, 0.05, 3.2))
	await create_timer(0.4).timeout
	await physics_frame
	if not need(pile.has("bounded_compact_cap"), "%s：真实抽屉启用了层数上限" % context):
		await _dispose(main)
		return
	if flying:
		main._move_to(target, Vector3(1.8, 0.05, 3.2))
		await create_timer(0.10).timeout
	var top: CardEntity = source[0]
	var press_at := board.camera.unproject_position(top.global_position)
	board._reset_click_track()
	_event(board, press_at, true)
	if not need(board._drag_cards.size() == count, "%s：真实按下拾取整摞" % context):
		await _dispose(main)
		return
	var destination := target.global_position
	var delta := Vector3(destination.x - top.global_position.x,
		Board.DRAG_HEIGHT - source[-1].global_position.y, destination.z - top.global_position.z)
	for card in board._drag_cards:
		card.global_position += delta
	var expected_members := source.duplicate()
	expected_members.append(target)
	_event(board, board.camera.unproject_position(destination), false)
	await create_timer(0.5).timeout
	await physics_frame
	var group: Variant = board.group_of(target)
	check(group != null and group["cards"].size() == count + 1,
		"%s：全部成员组成同一摞" % context)
	_check_visible(main, expected_members, context)
	if group != null and target_id != "cash":
		check(group["cards"][0] == target and target.recipe_progress_text() == "%d/%d" % [count, int(CardDB.get_def(target_id)["recipe_n"])],
			"%s：核心仍在摞顶并显示配方" % context)
	if flying:
		check(not target.has_meta("dest_pos"), "%s：已取消旧飞入目标" % context)
	await _dispose(main)

func _core_onto_raised_pile() -> void:
	var main := await _boot()
	var board: Board = main.board
	var materials: Array = []
	for i in 20:
		materials.append(_card(main, "cash", Vector3(0.5, 0.8, 3.0)))
	var group := board.make_group(materials.duplicate(), true)
	board.groups.append(group)
	board._layout_group(group, Vector3(0.5, 0.8, 3.0))
	var core := _card(main, "pinshaoshao", Vector3(-3.7, 0.05, 3.0))
	await create_timer(0.4).timeout
	await physics_frame
	var original_base := board.rest_origin(group)
	board._reset_click_track()
	_event(board, board.camera.unproject_position(core.global_position), true)
	if need(core in board._drag_cards, "核心并高位资源摞：真实拾取核心"):
		core.global_position = materials[0].global_position + Vector3(0.25, 0.1, 0.0)
		_event(board, board.camera.unproject_position(core.global_position), false)
		await create_timer(0.4).timeout
		await physics_frame
		check(board.group_of(core) == group and group["cards"][0] == core,
			"核心并高位资源摞：同组且核心提到摞顶")
		check(board.rest_origin(group).is_equal_approx(original_base),
			"核心并高位资源摞：保留目标摞原支撑面和位置")
		_check_visible(main, materials + [core], "核心并高位资源摞")
	await _dispose(main)

func _loose_onto_raised_card() -> void:
	var main := await _boot()
	var board: Board = main.board
	var target := _card(main, "cash", Vector3(0.5, 0.8, 3.0))
	var source := _card(main, "cash", Vector3(-3.7, 0.05, 3.0))
	await physics_frame
	board._reset_click_track()
	_event(board, board.camera.unproject_position(source.global_position), true)
	if need(source in board._drag_cards, "散卡并高位散卡：真实拾取"):
		var support := target.global_position
		source.global_position = support + Vector3(0.25, 0.5, 0.0)
		_event(board, board.camera.unproject_position(source.global_position), false)
		await create_timer(0.4).timeout
		await physics_frame
		var group: Variant = board.group_of(target)
		check(group != null and group["cards"].has(source), "散卡并高位散卡：两张牌同组")
		check(target.global_position.is_equal_approx(support), "散卡并高位散卡：保留目标的实际高度")
		_check_visible(main, [target, source], "散卡并高位散卡")
	await _dispose(main)

func _check_visible(main: Node, members: Array, context: String) -> void:
	var board: Board = main.board
	var lowest := INF
	var retained := true
	var in_view := true
	var viewport := Rect2(Vector2.ZERO, Vector2(root.size))
	for card: CardEntity in members:
		retained = retained and is_instance_valid(card) and not card.is_queued_for_deletion() \
			and main.entities.get(card.uid) == card and card in board.cards \
			and not main.state.find_card(main.my_seat, card.uid).is_empty()
		lowest = minf(lowest, card.global_position.y - CardEntity.CARD_SIZE.y / 2.0)
		in_view = in_view and viewport.has_point(board.camera.unproject_position(card.global_position))
	check(retained, "%s：引擎、实体表和牌桌成员齐全" % context)
	check(lowest >= -0.001, "%s：每张牌底面都在桌面上方，最低%.3f" % [context, lowest])
	check(in_view, "%s：牌中心仍在当前窗口内" % context)
	var top: CardEntity = members[0]
	for card: CardEntity in members:
		if card.global_position.y > top.global_position.y:
			top = card
	var hit := board._pick_card(board.camera.unproject_position(top.global_position))
	check(hit in members, "%s：真实射线可以命中合并后的摞顶" % context)

## 通过购买接口连续付款，中间真实点击现金摞。付款后若只摘成员、不重排，
## 新队首仍在旧层上；点击会按新队序反推出负高度，下一次付款后整摞埋进桌面。
func _buy_from_compact_pile() -> void:
	var main := await _boot()
	var board: Board = main.board
	main.phase = main.PHASE_ACTION
	main._actor = main.my_seat
	var count := 17
	for i in 2:
		count += int(CardDB.get_def(main.state.market[i])["price"])
	var members: Array = []
	for i in count:
		members.append(_card(main, "cash", Vector3(-3.7, 0.05, 3.0)))
	var group := board.make_group(members.duplicate(), true)
	board.groups.append(group)
	board._layout_group(group, Vector3(-3.7, 0.05, 3.0))
	await create_timer(0.4).timeout
	var original_base := board.rest_origin(group)
	for step in 2:
		var uids: Array = []
		for card in group["cards"]:
			uids.append(card.uid)
		var result: Dictionary = await main._try_buy(0, uids)
		if not need(result["ok"], "连续购买%d：使用收拢现金摞付款成功" % (step + 1)):
			await _dispose(main)
			return
		await create_timer(0.6).timeout
		await physics_frame
		check(board.rest_origin(group).is_equal_approx(original_base),
			"连续购买%d：余牌保留原支撑面和位置" % (step + 1))
		_check_visible(main, group["cards"], "连续购买%d后的现金摞" % (step + 1))
		var top: CardEntity = group["cards"][0]
		board._reset_click_track()
		var point := board.camera.unproject_position(top.global_position)
		_event(board, point, true)
		check(board._drag_cards.size() == group["cards"].size(),
			"连续购买%d：余牌仍可真实点击拾取整摞" % (step + 1))
		_event(board, point, false)
		await create_timer(0.4).timeout
		await physics_frame
		_check_visible(main, group["cards"], "连续购买%d并点击复位后的现金摞" % (step + 1))
	check(group["cards"].size() == 17, "连续购买后保留截图中的17张现金")
	await _dispose(main)

## 旧快照只有坐标与收拢标记，缺少层数上限；重建后反推的起点可能为负。
## 冻结的牌没有物理回弹，下一次重排必须保证它们落在桌面上方。
func _restored_pile_stays_above_table() -> void:
	var main := await _boot()
	var board: Board = main.board
	var members: Array = []
	for i in 17:
		members.append(_card(main, "cash", Vector3(-3.7, 0.05, 3.0)))
	var group := board.make_group(members.duplicate(), true)
	board.groups.append(group)
	board._layout_group(group, Vector3(-3.7, 0.05, 3.0))
	await create_timer(0.4).timeout
	var snapshot = load("res://scenes/table_snapshot.gd")
	snapshot.restore(main, snapshot.capture(main))
	await physics_frame
	var top: CardEntity = members[0]
	board._reset_click_track()
	var point := board.camera.unproject_position(top.global_position)
	_event(board, point, true)
	check(board._drag_cards.size() == 17, "恢复的现金摞可以拾取全部17张")
	_event(board, point, false)
	await create_timer(0.4).timeout
	await physics_frame
	_check_visible(main, members, "恢复17张现金摞后点击复位")
	await _dispose(main)

func _dispose(main: Node) -> void:
	main.queue_free()
	for i in 3:
		await process_frame
