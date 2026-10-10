# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

const Snapshot = preload("res://scenes/table_snapshot.gd")

class RecordedSound extends Sfx:
	var events: Array = []
	func play(action: String, pitch := 1.0) -> void:
		var index := _next
		super.play(action, pitch)
		if index != _next:
			events.append({"action": action, "spec": Sfx.action(action).duplicate(true), "stream": _players[index].stream})

var main: Node
var sound: RecordedSound
var purchases: Array = []
var operations: Array = []
var pointer := Vector2.ZERO
var last_drop_world := Vector3.INF
var _traced_card: CardEntity
var _drop_samples: Array[Vector3] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 四种购牌入口：根Viewport、共享交易、取消与教程推进 ===")
	process_frame.connect(_sample_drop_position)
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "启动正式原牌桌"):
		finish()
		return
	main.drawer_presentation._learning_invitation.hide()
	sound = RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	main._card_motion.sfx = sound
	main.board.touch_mode = true
	main.board.dropped_on_market.connect(func(cards, market):
		purchases.append({"paid": cards.map(func(card): return card.uid), "def_id": market.def_id}))
	await _formal_fixture()
	var shared_buy: Dictionary = {}
	for mode in ["cash", "tag", "reverse", "area"]:
		var market: CardEntity = main.market_cards[0]
		var price := int(CardDB.get_def(market.def_id)["price"])
		var owned_before: Array = main.state.players[main.my_seat]["cards"].map(func(card): return card["uid"])
		var cash_before: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
		var market_size: int = main.state.market.size()
		var source_group: Dictionary = _cash_group()
		var cash_uids: Array = source_group["cards"].map(func(card): return card.uid)
		var compact: bool = source_group.get("compact", false)
		var cash_layout: Array = []
		for group in main.board.groups:
			if group["cards"].all(func(card): return card.draggable and card.def_id == "cash"):
				cash_layout.append({"uids": group["cards"].map(func(card): return card.uid),
					"positions": group["cards"].map(func(card): return main.board.rest_pos(card)),
					"compact": group["compact"], "origin": main.board._group_origin(group)})
		_clear_events()
		await _purchase_input(mode, market, source_group["cards"][0], mode in ["reverse", "area"])
		await settle()
		if mode in ["reverse", "area"]: _check_drop_position("正式" + mode)
		check(purchases.size() == 1 and main.state.market.size() == market_size - 1,
			"正式%s购买只走一次原dropped_on_market交易入口" % mode)
		check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash_before - price,
			"正式%s只扣价签标价的真实现金" % mode)
		var fresh: Array = main.state.players[main.my_seat]["cards"].filter(func(card): return not owned_before.has(card["uid"]))
		check(fresh.size() == 1 and fresh[0]["uid"] == market.uid and fresh[0]["def_id"] == market.def_id
			and main.entities.get(market.uid) == market and not market.is_market and market.draggable,
			"正式%s将原商品实体按引擎新UID移入手牌，不复制商品" % mode)
		var remaining: Array = cash_uids.filter(func(uid): return main.entities.has(uid))
		var rest: Variant = main.board.group_of(main.entities[remaining[0]]) if not remaining.is_empty() else null
		if mode in ["cash", "reverse"]:
			check(rest != null and rest["cards"].map(func(card): return card.uid) == remaining
				and rest["compact"] == compact and remaining.size() == cash_uids.size() - price,
				"正式%s只移除指定现金摞里的付款卡，全部余款仍成原形态的一摞" % mode)
		else:
			var preserved := true
			for pile in cash_layout:
				var left: Array = pile.uids.filter(func(uid): return main.entities.has(uid))
				if left.is_empty(): continue
				var actual: Variant = main.board.group_of(main.entities[left[0]])
				var same: bool = actual != null and actual["cards"].map(func(card): return card.uid) == left
				if actual != null:
					same = same and (left.size() < 2 or actual["compact"] == pile.compact)
					same = same and main.board._group_origin(actual).distance_to(pile.origin) < 0.02
				if not same: print("AUTO_PAYMENT_PILE ", mode, " before=", pile, " left=", left,
					" actual=", [] if actual == null else actual["cards"].map(func(card): return card.uid),
					" compact=", null if actual == null else actual["compact"],
					" origin=", Vector3.INF if actual == null else main.board._group_origin(actual))
				preserved = preserved and same
			check(preserved, "%s自动付款可以跨现金摞取钱，每摞余款都保留原顺序、形态和worldorigin" % mode)
		if mode == "reverse":
			if rest != null:
				for cash_card in rest["cards"]:
					if _plane_rect(cash_card.global_position).intersects(_plane_rect(market.global_position).grow(-0.02)):
						print("PURCHASE_REMAINDER_OVERLAP product=", market.global_position,
							" cash_uid=", cash_card.uid, " cash=", cash_card.global_position,
							" group_origin=", main.board._group_origin(rest), " compact=", rest["compact"],
							" product_rect=", _plane_rect(market.global_position), " cash_rect=", _plane_rect(cash_card.global_position))
			check(rest != null and rest["cards"].all(func(card): return not _plane_rect(card.global_position).intersects(_plane_rect(market.global_position).grow(-0.02))),
				"反拖余款保留整摞并避开新商品的松手落点，不被业务卡覆盖")
			var still := true
			for pile in cash_layout:
				if pile.positions.any(func(at): return _plane_rect(at).intersects(_plane_rect(last_drop_world))): continue
				var left: Array = pile.uids.filter(func(uid): return main.entities.has(uid))
				if left.is_empty(): continue
				var remaining_group: Variant = main.board.group_of(main.entities[left[0]])
				still = still and remaining_group != null and main.board._group_origin(remaining_group).distance_to(pile.origin) < 0.02
			check(still, "原先不与商品松手位置重叠的现金摞保持原origin，不被连带搬动")
		var buy_events: Array = sound.events.filter(func(event): return event.action == "buy")
		check(buy_events.size() == 1, "%s购买只发一声正式buy音效" % mode)
		if buy_events.size() == 1:
			if shared_buy.is_empty(): shared_buy = buy_events[0]
			else: check(buy_events[0].spec == shared_buy.spec and buy_events[0].stream == shared_buy.stream,
				"%s入口沿用原buy音色和配置" % mode)
		if mode == "tag": check(purchases.size() == 1 and purchases[0].paid.is_empty(), "点价签把空支付列表交真实引擎自动选现金")
		if mode == "reverse": check(purchases.size() == 1 and purchases[0].paid == cash_uids, "商品反拖提交目标现金整组的真实UID次序")
	await _invalid_inputs()
	await _drop_positions_and_next_purchase()
	await _single_cash_remainder()
	await _resized_price_tag()
	await _automatic_payment_protects_combos()
	await _tutorial_inputs(shared_buy)
	await dispose_drawer(main)
	await _mobile_price_tag()
	finish()

func _formal_fixture(cash_count := 24) -> void:
	main.board.cancel_pointer()
	main._invalidate_session()
	main.state = GameState.new()
	main.state.set_seed(7814)
	main.state.players = {GameState.PLAYER: {"cards": []}, GameState.BOT: {"cards": []}}
	for seat in [GameState.PLAYER, GameState.BOT]:
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
	seed(444)
	await settle()
	_clear_events()

func _invalid_inputs() -> void:
	await _formal_fixture()
	var market: CardEntity = main.market_cards[0]
	var original := StateCodec.snapshot(main.state)
	var home: Vector3 = market.global_position
	var tag_point := _tag_point(market)
	await _press(tag_point)
	await _move(tag_point + Vector2(45, 0))
	await _move(tag_point)
	await _release(tag_point)
	await settle()
	_check_no_purchase(original, "价签按下滑走再回原处也不购买")
	await _press(_tag_point(market))
	await _release(pointer, true)
	await settle()
	_check_no_purchase(original, "取消价签点击不购买")
	await _press(_card_point(market))
	await _release(pointer)
	await settle()
	_check_no_purchase(original, "单击商品卡面不会冒充价签购买")
	await _drag(market, Vector3(0, 0.05, -3.0), false)
	await settle()
	_check_no_purchase(original, "商品放到对手区域不购买")
	check(market.is_market and not market.draggable and market.global_position.distance_to(home) < 0.02,
		"对手区域松手仍是原货架商品，回到原槽位")
	for target in [main.market_cards[1].global_position, main.board.pawn_pos]:
		await _drag(market, target)
		await settle()
		_check_no_purchase(original, "商品放回市场或典当行不误购、不典当")
	var cash: CardEntity = _cash_group()["cards"][0]
	await _drag(market, cash.global_position, true)
	await settle()
	_check_no_purchase(original, "商品拖到现金后取消不购买")
	check(main.board._drag_cards.is_empty() and market.global_position.distance_to(home) < 0.02,
		"取消反拖清空原拖牌状态并恢复货架位置")
	for outside in [Vector2(1480, 700), Vector2(640, 1000), main.btn_pass.get_global_rect().get_center()]:
		main.board._reset_click_track()
		await _press(_card_point(market))
		check(main.board._drag_cards.has(market), "屏外/HUD测试也通过真实根Viewport拿起商品")
		await _move(outside)
		await _release(outside)
		await settle()
		_check_no_purchase(original, "商品落点%s在窗口外或HUD上，不被夹回玩家区自动购买" % outside)
		check(main.board._drag_cards.is_empty() and market.global_position.distance_to(home) < 0.02,
			"屏外/HUD松手清理拖动并恢复原货架")
	var cash_cards: Array = _cards("cash")
	_fixture_group([cash_cards[0]], Vector3(0, 0.05, 2.4), false)
	await settle()
	await _drag(market, cash_cards[0].global_position)
	await settle()
	_check_no_purchase(original, "目标只有1现金时不借用别处现金偷偷成交")
	_fixture_group(cash_cards.slice(0, int(CardDB.get_def(market.def_id)["price"])) + [_cards("user")[0]], Vector3(0, 0.05, 2.4), true)
	await settle()
	var mixed_user: CardEntity = _cards("user")[0]
	var cash_before: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	await _drag(market, cash_cards[0].global_position)
	await settle()
	check(purchases.size() == 1 and purchases[0].paid.is_empty() and not market.is_market
		and main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash_before - int(CardDB.get_def(market.def_id)["price"])
		and main.entities.has(mixed_user.uid) and main.board.group_of(market) != main.board.group_of(mixed_user),
		"商品落在混组附近走本方区域自动付款，不拿用户付钱也不直接并入该组")
	await _formal_fixture(1)
	original = StateCodec.snapshot(main.state)
	await _tap_tag(main.market_cards[0])
	await settle()
	check(StateCodec.snapshot(main.state) == original and _actions().count("buy") == 0 and _actions().count("deny") == 1,
		"点价签现金不足仍由原引擎拒绝，沿用一次deny提示")

func _resized_price_tag() -> void:
	await _formal_fixture()
	root.size = Vector2i(960, 600)
	await relayout_drawer(main)
	await settle()
	var market: CardEntity = main.market_cards[0]
	var tag: Node3D = market.get_meta("price_tag").get_ref()
	var tag_home: Vector3 = tag.global_position
	var card_home: Vector3 = market.global_position
	var before := StateCodec.snapshot(main.state)
	await _drag(market, _cash_group()["cards"][0].global_position, true)
	await settle()
	check(StateCodec.snapshot(main.state) == before and market.global_position.distance_to(card_home) < 0.02
		and tag.global_position.distance_to(tag_home) < 0.02
		and tag.hit_test(_tag_point(market), main.board.camera),
		"窗口缩放后取消商品反拖，价签回本次起点而非旧尺寸位置，纸面仍可点")
	var cash_before: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	var price := int(CardDB.get_def(market.def_id)["price"])
	await _tap_tag(market)
	await settle()
	check(not market.is_market and main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash_before - price,
		"缩放后直接点击当前价签纸面仍能购买原商品")
	root.size = Vector2i(1280, 800)
	await relayout_drawer(main)

func _drop_positions_and_next_purchase() -> void:
	var observed: Array[Vector3] = []
	for index in 2:
		await _formal_fixture()
		var market: CardEntity = main.market_cards[0]
		var cash: CardEntity = _cash_group()["cards"][0]
		if index == 1:
			# 将本用例的付款摞铺在区域中部，z=-1.2仍在自己牌区；区域外取消另有专门用例。
			_fixture_group(main.board.group_of(cash)["cards"].duplicate(), Vector3(-3, 0.05, 4), true)
			await settle()
		var cash_ids: Array = main.board.group_of(cash)["cards"].map(func(card): return card.uid)
		var offset := Vector3(0.22, 0, 0.12) if index == 0 else Vector3(-0.22, 0, -1.2)
		var origin: Vector3 = main.board._group_origin(main.board.group_of(cash))
		await _drag(market, cash.global_position + offset, false, true)
		var dropped := last_drop_world
		observed.append(dropped)
		check(_xz(dropped).distance_to(_xz(origin)) > 0.1,
			"反拖第%d处使用真实松手位置，与付款摞origin有明确偏移" % (index + 1))
		await settle()
		_check_drop_position("反拖不同松手处%d" % (index + 1))
		check(purchases.size() == 1 and purchases[0].paid == cash_ids,
			"反拖偏移%d仍指定原现金摞付款，不以自动购买绕过卡面边缘命中" % (index + 1))
		var left: Array = cash_ids.filter(func(uid): return main.entities.has(uid))
		var separated: bool = left.all(func(uid): return not _plane_rect(main.entities[uid].global_position).intersects(_plane_rect(market.global_position).grow(-0.02)))
		if not separated:
			print("OFFSET_REMAINDER_OVERLAP index=", index, " dropped=", dropped, " final=", market.global_position,
				" cash=", left.map(func(uid): return {"uid": uid, "at": main.entities[uid].global_position}))
		check(not left.is_empty() and separated,
			"反拖偏移%d的所有余款避开商品真实卡面，含z相差1.2的边缘重叠" % (index + 1))
		var next: CardEntity = main.market_cards[0]
		_clear_events()
		var next_mode := "tag" if index == 0 else "cash"
		var payment: CardEntity = _cash_group()["cards"][0]
		if next_mode == "cash":
			# 刚买到的商品留在前一摞上方；下一笔可自然使用另一摞可见现金。
			for group in main.board.groups:
				if group["cards"].size() >= int(CardDB.get_def(next.def_id)["price"]) \
					and group["cards"].all(func(card): return card.draggable and card.def_id == "cash") \
					and _xz(group["cards"][0].global_position).distance_to(_xz(dropped)) > 1.5:
					payment = group["cards"][0]
					break
		await _purchase_input(next_mode, next, payment)
		await settle()
		check(not next.is_market and _xz(next.global_position).distance_to(_xz(dropped)) > 0.1,
			"成功反拖后的%s购买继续自动选择到货位置，不沿用上一手松手点" % next_mode)
	check(observed.size() == 2 and _xz(observed[0]).distance_to(_xz(observed[1])) > 0.3,
		"两个真实反拖落点不同，不靠固定现金摞中心碰巧通过")
	await _formal_fixture()
	var target: CardEntity = main.market_cards[0]
	var home: Vector3 = target.global_position
	var one: CardEntity = _cards("cash")[0]
	_fixture_group([one], Vector3(0, 0.05, 2.4), false)
	await settle()
	var before := StateCodec.snapshot(main.state)
	await _drag(target, one.global_position)
	var rejected_drop := last_drop_world
	await settle()
	check(StateCodec.snapshot(main.state) == before and target.is_market and target.global_position.distance_to(home) < 0.02,
		"明确现金不足的反拖恢复原货架，不遗留松手处商品")
	_clear_events()
	await _tap_tag(target)
	await settle()
	check(not target.is_market and _xz(target.global_position).distance_to(_xz(rejected_drop)) > 0.1,
		"反拖不足后点同一价签可自动付款，旧失败落点不会污染到货位置")

func _single_cash_remainder() -> void:
	var price := int(CardDB.get_def("yunketang")["price"])
	await _formal_fixture(price + 1)
	var market: CardEntity = main.market_cards[0]
	var cash: CardEntity = _cash_group()["cards"][0]
	var ids: Array = _cash_group()["cards"].map(func(card): return card.uid)
	await _drag(market, cash.global_position + Vector3(0.15, 0, 0.1), false, true)
	await settle()
	_check_drop_position("反拖付款后只余1现金")
	var left: Array = ids.filter(func(uid): return main.entities.has(uid))
	if not need(left.size() == 1 and main.state.resource_count(main.my_seat, CardDB.RES_CASH) == 1,
		"price+1现金真实反拖只支付price，原UID现金准确剩1张"): return
	var remainder: CardEntity = main.entities[left[0]]
	check(not _plane_rect(remainder.global_position).intersects(_plane_rect(market.global_position).grow(-0.02)),
		"单张余款也避开新商品，不因原摞缩小重新被压住")
	var at: Vector3 = remainder.global_position
	await create_timer(0.8).timeout
	check(_xz(remainder.global_position).distance_to(_xz(at)) < 0.03
		and not _plane_rect(remainder.global_position).intersects(_plane_rect(market.global_position).grow(-0.02)),
		"单张余款落稳后原组旧补间不会再把它拉回商品下面")

func _automatic_payment_protects_combos() -> void:
	var production_n := int(CardDB.get_def("ditui")["recipe_n"]) + 1
	var attack_n := int(CardDB.get_def("heigongguan")["recipe_n"]) + 1
	var price := int(CardDB.get_def("yunketang")["price"])
	for mode in ["tag", "area"]:
		for enough in [true, false]:
			var idle_n := price + 2 if enough else price - 1
			await _formal_fixture(production_n + attack_n + idle_n)
			var money := _cards("cash")
			var production_record: Dictionary = main.state.add_card(main.my_seat, "ditui")
			var attack_record: Dictionary = main.state.add_card(main.my_seat, "heigongguan")
			var production: CardEntity = main._spawn_entity(production_record, Vector3(-3, 0.05, 1.6), true)
			var attack: CardEntity = main._spawn_entity(attack_record, Vector3(0, 0.05, 1.6), true)
			var protected: Array = money.slice(0, production_n + attack_n)
			_fixture_group([production] + money.slice(0, production_n), Vector3(-3, 0.05, 1.6), true)
			_fixture_group([attack] + money.slice(production_n, production_n + attack_n), Vector3(0, 0.05, 1.6), true)
			_fixture_group(money.slice(production_n + attack_n), Vector3(3, 0.05, 1.6), true)
			await settle()
			var initial := StateCodec.snapshot(main.state)
			var visual := Snapshot.capture(main)
			var protected_ids: Array = protected.map(func(card): return card.uid)
			var protected_positions: Array = protected.map(func(card): return main.board.rest_pos(card))
			var market: CardEntity = main.market_cards[0]
			_clear_events()
			await _purchase_input(mode, market, _cash_group()["cards"][0])
			await settle()
			check(protected_ids.all(func(uid): return main.entities.has(uid)) and protected.all(func(card): return main.board.group_of(card) != null)
				and main.board.group_of(production)["cards"].size() == production_n + 1
				and main.board.group_of(attack)["cards"].size() == attack_n + 1,
				"%s自动付款避开有效生产/攻击组合，包括组内富余现金" % mode)
			var unchanged := true
			for i in protected.size():
				if not is_instance_valid(protected[i]) or main.board.rest_pos(protected[i]).distance_to(protected_positions[i]) > 0.02: unchanged = false
			check(unchanged and main.board.group_of(production)["compact"] and main.board.group_of(attack)["compact"],
				"%s自动付款不移动、不展开已有有效组合" % mode)
			if enough:
				check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == production_n + attack_n + 2
					and main.entities.get(market.uid) == market and not market.is_market and _actions().count("buy") == 1,
					"%s仅用闲置现金自动购买，保留两张闲置余款" % mode)
			else:
				check(StateCodec.snapshot(main.state) == initial and StateCodec.canon(Snapshot.capture(main)) == StateCodec.canon(visual)
					and _actions().count("buy") == 0 and _actions().count("deny") == 1,
					"%s闲置现金不足整手拒绝，不拆有效组合凑钱且所有牌原位" % mode)

func _tutorial_inputs(shared_buy: Dictionary) -> void:
	await _formal_fixture()
	var original_state: GameState = main.state
	var original := StateCodec.snapshot(main.state)
	var original_cards: Array = main.board.cards.duplicate()
	check(main.drawer_presentation.start_tutorial("income"), "新购买入口在原牌桌开启首课")
	var player: Node = main.drawer_presentation.tutorial
	var arena: Node = player.arena
	main.board.touch_mode = true
	arena.operation_finished.connect(func(result): operations.append(result.duplicate(true)))
	for mode in ["tag", "reverse", "area"]:
		player.retry()
		await settle()
		player.session.preview_groups(arena.current_groups())
		var before: Dictionary = player.session.capture_operation()
		var visual := Snapshot.capture(main)
		_clear_events()
		await _purchase_input(mode, main.market_cards[1], _cash_group()["cards"][0])
		check(arena.operation_pending, "教程%s错买先真实执行并进入延迟单手回滚" % mode)
		await _wait_tutorial_operation(arena)
		if StateCodec.canon(player.session.capture_operation()) != StateCodec.canon(before):
			for key in before:
				if player.session.capture_operation().get(key) != before[key]: print("ROLLBACK_LOGIC ", mode, " ", key, " before=", before[key], " after=", player.session.capture_operation().get(key))
		if StateCodec.canon(Snapshot.capture(main)) != StateCodec.canon(visual): print("ROLLBACK_VISUAL ", mode, " before=", visual, " after=", Snapshot.capture(main))
		check(operations.size() == 1 and operations[0].get("rolled_back", false)
			and StateCodec.canon(player.session.capture_operation()) == StateCodec.canon(before)
			and StateCodec.canon(Snapshot.capture(main)) == StateCodec.canon(visual),
			"教程%s错买恢复金额、商品、UID、原牌位和当前步骤" % mode)
		check(_actions().count("buy") == 1 and _actions().count("deny_quiet") == 1,
			"教程%s错买沿用buy后只补一次轻提示" % mode)
		_clear_events()
		var market: CardEntity = main.market_cards[0]
		var old_cash: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
		var price := int(CardDB.get_def(market.def_id)["price"])
		await _purchase_input(mode, market, _cash_group()["cards"][0], mode in ["reverse", "area"])
		check(arena.operation_pending and operations.is_empty()
			and player.session.current_step().get("id") == "income.buy",
			"教程%s正确购买仍等原到货动画，不提前跳过购牌目标" % mode)
		await _wait_tutorial_operation(arena)
		if mode in ["reverse", "area"]: _check_drop_position("教程" + mode)
		check(operations.size() == 1 and operations[0].get("expected", false)
			and player.session.current_step().get("id") == "income.split"
			and not player._awaiting_result and not arena.board.input_locked,
			"教程%s到货后直接进入拆牌，无额外点击且不重复交易" % mode)
		check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == old_cash - price
			and main.entities.get(market.uid) == market and market.draggable and not market.is_market,
			"教程%s沿用真实付款与原商品实体" % mode)
		var sounds: Array = sound.events.filter(func(event): return event.action == "buy")
		check(sounds.size() == 1 and sounds[0].spec == shared_buy.get("spec") and sounds[0].stream == shared_buy.get("stream")
			and arena.sfx == main.sfx and arena._table_actions.get_script() == main._table_actions.get_script(),
			"教程%s和正式购买共用TableActions、音源及唯一buy事件" % mode)
	main.drawer_presentation.finish_tutorial(false)
	await create_timer(0.6).timeout
	check(main.state == original_state and StateCodec.snapshot(main.state) == original and main.board.cards == original_cards,
		"新购买交互退出后完整恢复正式局，不留下异步交易")

func _wait_tutorial_operation(arena: Node) -> void:
	for i in 250:
		if not arena.operation_pending and not operations.is_empty(): break
		await create_timer(0.025).timeout
	await settle()

func _mobile_price_tag() -> void:
	root.size = Vector2i(960, 540)
	main = load("res://scenes/main.tscn").instantiate()
	main.force_mobile_layout = true
	root.add_child(main)
	_booted = main
	await settle()
	check(main.mobile_mode and main.get_node_or_null("TableTouchInput") != null,
		"真实移动布局创建原TableTouchInput，长按不另接输入处理器")
	main.drawer_presentation._learning_invitation.hide()
	sound = RecordedSound.new()
	main.add_child(sound)
	# 上一场fixture销毁前会保存静音；此处明确开启声音再核验轻触购买只响一次。
	sound.set_user_muted(false)
	main.sfx = sound
	main._card_motion.sfx = sound
	await _formal_fixture()
	var previous_emulation := Input.emulate_mouse_from_touch
	Input.emulate_mouse_from_touch = true
	for tutorial in [false, true]:
		var arena: Node = null
		if tutorial:
			check(main.drawer_presentation.start_tutorial("income"), "移动牌桌开启首课，保留原长按输入")
			arena = main.drawer_presentation.tutorial.arena
			arena.operation_finished.connect(func(result): operations.append(result.duplicate(true)))
			await settle()
		var market: CardEntity = main.market_cards[0]
		var tag: Node3D = market.get_meta("price_tag").get_ref()
		var point := _tag_point(market)
		check(tag.hit_test(point, main.board.camera) and main.board._pick_card(point) == null,
			"长按测试命中卡牌外扩价签纸面，不能靠卡面射线误过")
		var before := StateCodec.snapshot(main.state)
		_clear_events()
		await _touch(point, true)
		await create_timer(0.6).timeout
		check(main.drawer_presentation._detail.visible and main.drawer_presentation._detail_id == market.def_id
			and main.board._press_snap.is_empty() and main.board._drag_cards.is_empty(),
			"%s长按价签走共享说明并取消待购买点击" % ("教程" if tutorial else "正式局"))
		await _touch(point, false)
		await settle()
		check(StateCodec.snapshot(main.state) == before and market.is_market and _actions().count("buy") == 0,
			"%s价签长按松手只保留详情，不购买" % ("教程" if tutorial else "正式局"))
		var cash_before: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
		var price := int(CardDB.get_def(market.def_id)["price"])
		_clear_events()
		await _touch(_tag_point(market), true)
		await _touch(pointer, false)
		if tutorial: await _wait_tutorial_operation(arena)
		else: await settle()
		check(not market.is_market and main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash_before - price
			and _actions().count("buy") == 1,
			"%s随后正常轻触价签仍购买一次，长按取消不会永久阻止短点" % ("教程" if tutorial else "正式局"))
		if tutorial:
			check(arena.session.current_step().get("id") == "income.split", "移动端轻触购买等到货后直接进入拆牌")
			main.drawer_presentation.finish_tutorial(false)
	Input.emulate_mouse_from_touch = previous_emulation
	await dispose_drawer(main)

## 使用操作系统触摸入口，由Godot生成原Board的鼠标事件，覆盖TouchInput长按和取消链。
func _touch(at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = at
	event.pressed = pressed
	pointer = at
	Input.parse_input_event(event)
	await process_frame

func _check_no_purchase(snapshot: Dictionary, label: String) -> void:
	check(StateCodec.snapshot(main.state) == snapshot and purchases.is_empty() and _actions().count("buy") == 0, label)

func _cards(id: String) -> Array:
	return main.entities.values().filter(func(card): return card.draggable and card.def_id == id)

func _cash_group() -> Dictionary:
	for group in main.board.groups:
		if not group["cards"].is_empty() and group["cards"].all(func(card): return card.draggable and card.def_id == "cash"):
			return group
	return {}

func _fixture_group(cards: Array, at: Vector3, compact: bool) -> void:
	for card in cards: main.board._detach_from_group(card)
	var group: Dictionary = main.board.make_group(cards, compact)
	main.board.groups.append(group)
	main.board._layout_group(group, at)

func _clear_events() -> void:
	purchases.clear()
	operations.clear()
	sound.events.clear()
	main.board._reset_click_track()

func _actions() -> Array:
	return sound.events.map(func(event): return event.action)

func _tag_point(card: CardEntity) -> Vector2:
	var tag: Node3D = card.get_meta("price_tag").get_ref()
	var point: Vector2 = main.board.camera.unproject_position(tag._paper.global_position)
	check(not main.drawer_presentation.pointer_over_panels(point), "真实价签纸面可见，未被UI遮挡")
	return point

func _card_point(card: CardEntity) -> Vector2:
	for z in [0.0, -0.6, 0.6]:
		var point: Vector2 = main.board.camera.unproject_position(card.to_global(Vector3(0, 0.05, z)))
		if main.board._pick_card(point) == card and not main.drawer_presentation.pointer_over_panels(point): return point
	return main.board.camera.unproject_position(card.global_position)

func _purchase_input(mode: String, market: CardEntity, cash: CardEntity, track_drop := false) -> void:
	if mode == "tag": await _tap_tag(market)
	elif mode == "reverse": await _drag(market, cash.global_position, false, track_drop)
	elif mode == "area": await _drag(market, main.layout._free_spot(Vector3(1.5, 0.05, 4.0), main.my_seat), false, track_drop)
	else: await _drag(cash, market.global_position)

func _tap_tag(market: CardEntity) -> void:
	var point := _tag_point(market)
	await _press(point)
	check(main.board._drag_cards.is_empty(), "按价签不会拿起或拆开任何牌")
	await _release(point)

func _drag(card: CardEntity, target: Vector3, canceled := false, track_drop := false) -> void:
	main.board._reset_click_track()
	await _press(_card_point(card))
	check(main.board._drag_cards.has(card), "真实根Viewport按下通过原Board拿起指定卡牌")
	if card.is_market:
		check(not card.draggable, "反拖仍是市场商品，没有提前改为玩家拥有的卡")
	var point: Vector2 = main.board.camera.unproject_position(Vector3(target.x, Board.DRAG_HEIGHT, target.z) - main.board._grab_offset)
	await _move(point)
	if card.is_market:
		last_drop_world = card.global_position
		if track_drop:
			_traced_card = card
			_drop_samples = [last_drop_world]
	await _release(point, canceled)
	if track_drop: _sample_drop_position()

func _sample_drop_position() -> void:
	if is_instance_valid(_traced_card): _drop_samples.append(_traced_card.global_position)

func _check_drop_position(label: String) -> void:
	var target := last_drop_world
	var card := _traced_card
	_traced_card = null
	check(is_instance_valid(card) and not card.is_market and _xz(card.global_position).distance_to(_xz(target)) < 0.02,
		label + "成交最终x/z等于真实松手位置，不重新随机挑落点")
	check(_drop_samples.size() > 2 and _drop_samples.all(func(point): return _xz(point).distance_to(_xz(target)) < 0.02),
		label + "付款和到货动画始终留在松手x/z，不先回货架再飞来")
	if is_instance_valid(card) and _xz(card.global_position).distance_to(_xz(target)) >= 0.02:
		print("PURCHASE_DROP ", label, " dropped=", target, " final=", card.global_position, " frames=", _drop_samples)
	_drop_samples.clear()

func _xz(at: Vector3) -> Vector2:
	return Vector2(at.x, at.z)

func _plane_rect(at: Vector3) -> Rect2:
	var size := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z)
	return Rect2(_xz(at) - size * 0.5, size)

func _press(at: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
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

func _release(at: Vector2, canceled := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = at
	event.global_position = at
	event.canceled = canceled
	pointer = at
	root.push_input(event)
	await process_frame
