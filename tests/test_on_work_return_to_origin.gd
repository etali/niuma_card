# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

## 落点被拒绝（典当行不收、买不起、多付的钱）时，牌沿弧线弹回这次拖拽拎起它们的地方：
## 原来那一摞、原来的位置、原来的顺序和收拢形态。不再被直接写到己方的某个空位。
## 走根 Viewport 的真实按下、移动、松手。
var main: Node
var pointer := Vector2.ZERO

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 被拒绝的落点：弹回原位 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "启动正式牌桌"):
		finish()
		return
	main.drawer_presentation._learning_invitation.hide()
	main.sfx.set_muted(true)
	main.board.touch_mode = true
	await _pawn_refuses_a_pile()
	await _pawn_refuses_a_suffix()
	await _pawn_refuses_a_loose_card()
	await _purchase_returns_the_change()
	await _purchase_refused()
	await _shelf_card_goes_back()
	await _an_ordinary_drop_keeps_no_snapshot()
	main.queue_free()
	await process_frame
	finish()

func _fixture(cash_count: int) -> void:
	main.board.cancel_pointer()
	main._invalidate_session()
	main.state = OnWorkState.new()
	main.state.set_seed(7814)
	main.state.players = {OnWorkState.PLAYER: {"cards": []}, OnWorkState.BOT: {"cards": []}}
	for seat in [OnWorkState.PLAYER, OnWorkState.BOT]:
		for i in (cash_count if seat == main.my_seat else 10): main.state.add_card(seat, "cash")
		for i in 8: main.state.add_card(seat, "user")
	main.state.market = ["yunketang", "baoyue", "ditui", "zuokong"]
	main._rebuild_pipe()
	main._actor = main.my_seat
	main.phase = main.PHASE_ACTION
	main.board.input_locked = false
	main.btn_pass.disabled = false
	main._set_button(main.TXT_ACTION_DONE, main._on_action_done)
	main._respawn_all()
	await settle()
	main.board._reset_click_track()

## 第一摞现金。开局时现金按十张一摞码放。
func _cash_group() -> Dictionary:
	for group in main.board.groups:
		if not group["cards"].is_empty() and group["cards"].all(func(card): return card.draggable and card.def_id == "cash"):
			return group
	return {}

func _cash_piles() -> int:
	return main.board.groups.filter(func(group): return not group["cards"].is_empty() and group["cards"].all(func(card): return card.def_id == "cash")).size()

## 现在装着这张牌的那一摞。
func _pile_of(uid: int) -> Dictionary:
	for group in main.board.groups:
		if group["cards"].any(func(card): return card.uid == uid): return group
	return {}

## 一摞牌现在的样子：谁在里面、什么顺序、各自停在哪、是不是收拢着。
func _shape(group: Dictionary) -> Dictionary:
	return {"uids": group["cards"].map(func(card): return card.uid), "compact": bool(group.get("compact", false)),
		"origin": main.board._group_origin(group),
		"positions": group["cards"].map(func(card): return main.board.rest_pos(card))}

func _same_place(now: Dictionary, before: Dictionary, uids: Array) -> bool:
	if now.uids != uids or now.compact != before.compact or not (now.origin as Vector3).is_equal_approx(before.origin): return false
	for index in uids.size():
		var was: int = before.uids.find(uids[index])
		# 少了几张的摞，剩下的牌按新队列排；整摞原样回来时每一张都在原来的格子上。
		if uids.size() == before.uids.size() and not (now.positions[index] as Vector3).is_equal_approx(before.positions[was]): return false
	return true

func _card_point(card: CardEntity) -> Vector2:
	for z in [0.0, -0.6, 0.6]:
		var point: Vector2 = main.board.camera.unproject_position(card.to_global(Vector3(0, 0.05, z)))
		if main.board._pick_card(point) == card and not main.drawer_presentation.pointer_over_panels(point): return point
	return main.board.camera.unproject_position(card.global_position)

func _event(pressed: bool, at: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	pointer = at
	root.push_input(event)
	await process_frame

func _move(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.position = at
	event.global_position = at
	event.relative = at - pointer
	pointer = at
	root.push_input(event)
	await process_frame

## 真实拖拽：按在这张牌上，拖到 target 上方，松手。返回松手那一帧这张牌的位置。
## hold_flight 为真时，这张牌一开始往回飞就把那条补间停住，交给 _flight 一步一步推：
## 判据不靠实时帧率，机器忙的时候也是同一条轨迹。
func _drag(card: CardEntity, target: Vector3, hold_flight := false) -> Vector3:
	main.board._reset_click_track()
	await _event(true, _card_point(card))
	if not need(main.board._drag_cards.has(card), "按下后这张牌在手上"): return Vector3.INF
	var point: Vector2 = main.board.pointer_for_landing(target)
	await _move(point)
	# Where it is let go: where the held card comes down, which is where it is in the picture.
	var held: Vector3 = main.board.held_landing_point(card)
	if not hold_flight:
		await _event(false, point)
		return held
	# 放慢到几乎不动再松手：裁决晚一两帧回来也好，这一程都还停在起点附近。
	Engine.time_scale = 0.02
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = point
	release.global_position = point
	pointer = point
	root.push_input(release)
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		var record: Variant = main.board._move_tw.get(card)
		if record != null and is_instance_valid(record["tw"]) and record["tw"].is_running():
			record["tw"].pause()
			break
		await process_frame
	Engine.time_scale = 1.0
	return held

## 把停住的那一程一步一步推完，每一步记一次位置。
func _flight(card: CardEntity) -> Array:
	var samples: Array = [card.global_position]
	var record: Variant = main.board._move_tw.get(card)
	if not need(record != null and is_instance_valid(record["tw"]), "这张牌有一程往回飞的补间"): return samples
	var tween: Tween = record["tw"]
	for step in 60:
		if not tween.is_valid() or not tween.custom_step(Board.RETURN_TIME / 40.0): break
		if not is_instance_valid(card): break
		samples.append(card.global_position)
	if is_instance_valid(card): samples.append(card.global_position)
	return samples

## 这一程是飞回去的，不是被直接写过去的：从松手处出发，一步一步到终点，中途抬离桌面。
func _check_arc(samples: Array, held: Vector3, home: Vector3, label: String) -> void:
	var first: Vector3 = samples[0]
	var last: Vector3 = samples[-1]
	check(Vector2(first.x - held.x, first.z - held.z).length() < 0.35 and Vector2(first.x - home.x, first.z - home.z).length() > 1.0,
		label + "：被拒绝的那一刻牌还在松手的地方，没有被直接写回去")
	var widest := 0.0
	var peak := -INF
	for index in range(1, samples.size()):
		widest = maxf(widest, (samples[index] as Vector3).distance_to(samples[index - 1]))
		peak = maxf(peak, (samples[index] as Vector3).y)
	var span := Vector2(home.x - first.x, home.z - first.z).length()
	check(samples.size() > 20 and widest < span * 0.2, label + "：一路飞回去，没有哪一步跳一大截（%d 步）" % samples.size())
	check(peak > maxf(first.y, home.y) + 0.2, label + "：走的是一条抬起再落下的弧线")
	check(Vector2(last.x - home.x, last.z - home.z).length() < 0.02, label + "：落在原来的位置")

func _pawn_refuses_a_pile() -> void:
	await _fixture(12)
	var group := _cash_group()
	var before := _shape(group)
	var piles := _cash_piles()
	var top: CardEntity = group["cards"][0]
	var home: Vector3 = before.positions[0]
	check(before.compact and before.uids.size() == 10, "夹具：第一摞是收拢着的十张现金")
	var held := await _drag(top, main.board.pawn_pos, true)
	check(main.lbl_msg.text.contains("不收现金卡"), "典当行拒收现金：%s" % main.lbl_msg.text)
	check(main.state.resource_count(main.my_seat, OnWorkCardDB.RES_CASH) == 12, "一张都没少")
	_check_arc(await _flight(top), held, home, "整摞被典当行拒收")
	await settle()
	var after := _pile_of(top.uid)
	check(is_same(after, group) and _same_place(_shape(after), before, before.uids),
		"回到的是原来那一摞：同样的牌、同样的顺序、同样的位置，仍然收拢着")
	check(_cash_piles() == piles, "没有在别处另起一摞")

func _pawn_refuses_a_suffix() -> void:
	await _fixture(6)
	var group := _cash_group()
	if group.get("compact", false):
		main.board.toggle_compact(group["cards"][0])
		await settle()
	var before := _shape(group)
	check(not before.compact, "夹具：六张现金摊开")
	var grabbed: CardEntity = group["cards"][3]
	var home: Vector3 = before.positions[3]
	var held := await _drag(grabbed, main.board.pawn_pos, true)
	check(main.lbl_msg.text.contains("不收现金卡"), "后三张也被拒收")
	_check_arc(await _flight(grabbed), held, home, "后半摞被拒收")
	await settle()
	check(is_same(_pile_of(grabbed.uid), group) and _same_place(_shape(group), before, before.uids),
		"后三张接回原摞的后面，前三张没动，仍然摊开")

func _pawn_refuses_a_loose_card() -> void:
	await _fixture(4)
	var group := _cash_group()
	var loose: CardEntity = group["cards"][0]
	for card in group["cards"].duplicate(): main.board._detach_from_group(card)
	var others: Array = main.board.cards.filter(func(card): return card.def_id == "cash" and card.draggable and card != loose)
	var spot: Vector3 = main.layout._free_spot(Vector3(4.0, 0.05, 4.2), main.my_seat)
	main.board._stop_move(loose, false)
	loose.global_position = Vector3(spot.x, 0.05, spot.z)
	loose.freeze = true
	for index in others.size():
		main.board._stop_move(others[index], false)
		others[index].global_position = Vector3(-6.0 + 1.6 * index, 0.05, 5.4)
		others[index].freeze = true
	await process_frame
	var home := loose.global_position
	var held := await _drag(loose, main.board.pawn_pos, true)
	check(main.board.group_of(loose) == null, "散卡被拒收后仍是散卡")
	check(loose.freeze, "飞回去的途中不交给物理")
	_check_arc(await _flight(loose), held, home, "一张散卡被拒收")
	await process_frame
	check(not loose.freeze, "落定之后和平常松手一样交还物理")

func _purchase_returns_the_change() -> void:
	await _fixture(24)
	var group := _cash_group()
	var before := _shape(group)
	var market: CardEntity = main.market_cards[0]
	var price := int(OnWorkCardDB.get_def(market.def_id)["price"])
	var top: CardEntity = group["cards"][0]
	await _drag(top, market.global_position)
	await settle()
	check(main.state.resource_count(main.my_seat, OnWorkCardDB.RES_CASH) == 24 - price, "买成了，只付了价钱那么多")
	var left: Array = before.uids.filter(func(uid): return not main.state.find_card(main.my_seat, uid).is_empty())
	var after := _pile_of(left[0])
	check(left.size() == before.uids.size() - price and not after.is_empty() and _same_place(_shape(after), before, left),
		"没花掉的钱回到原来那一摞的位置，顺序不变，仍然收拢着")

func _purchase_refused() -> void:
	await _fixture(3)
	var group := _cash_group()
	var before := _shape(group)
	var market: CardEntity = main.market_cards.filter(func(card): return int(OnWorkCardDB.get_def(card.def_id)["price"]) > 3)[0]
	var top: CardEntity = group["cards"][0]
	var home: Vector3 = before.positions[0]
	var held := await _drag(top, market.global_position, true)
	check(main.state.resource_count(main.my_seat, OnWorkCardDB.RES_CASH) == 3 and main.market_cards.has(market), "钱不够，没买成")
	_check_arc(await _flight(top), held, home, "买不起")
	await settle()
	check(is_same(_pile_of(top.uid), group) and _same_place(_shape(group), before, before.uids), "三张钱原样回到原来那一摞")

func _shelf_card_goes_back() -> void:
	await _fixture(2)
	var market: CardEntity = main.market_cards.filter(func(card): return int(OnWorkCardDB.get_def(card.def_id)["price"]) > 2)[0]
	var shelf := market.global_position
	var tag: Node3D = market.get_meta("price_tag").get_ref()
	var tag_rest := tag.global_position
	var drop: Vector3 = main.layout._free_spot(Vector3(1.5, 0.05, 4.0), main.my_seat)
	var held := await _drag(market, drop, true)
	check(market.is_market and main.market_cards.has(market), "买不起，商品还是货架上的商品")
	check(tag.global_position.is_equal_approx(tag_rest), "价签松手时已经回到货架上，在那儿等商品飞回来")
	_check_arc(await _flight(market), held, shelf, "反拖商品没买成")
	check(tag.global_position.is_equal_approx(tag_rest), "商品飞回来的一路上价签没有动")
	check(market.freeze and not market.draggable, "回到货架后仍是不能拿走的商品")

func _an_ordinary_drop_keeps_no_snapshot() -> void:
	await _fixture(5)
	var group := _cash_group()
	var top: CardEntity = group["cards"][0]
	# 空地：离别的牌摞远过吸附距离。原先取的那一点离用户摞只有 1.54（吸附距离 1.6），
	# 靠拖拽时牌被画面夹取顺带推开 0.26 才没并进去。
	var spot: Vector3 = main.layout._free_spot(Vector3(-2.0, 0.05, 4.4), main.my_seat)
	for other in main.board.groups:
		if is_same(other, group): continue
		for member in other["cards"]:
			need(Vector2(member.global_position.x - spot.x, member.global_position.z - spot.z).length() > Board.MERGE_DIST + 0.3, "夹具：落点离别的牌摞远过吸附距离")
	await _drag(top, spot)
	await settle()
	check(main.board._return_snap.is_empty(), "落在桌面上的普通拖拽不留起点快照")
	var cards: Array = _cash_group()["cards"].duplicate()
	check(not main.board.return_to_origin(cards), "之后再退这些牌，不会被送回早就过时的起点")
