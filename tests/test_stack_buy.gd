# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 堆叠购买测试
## 购买：拖现金堆到公共区卡上 → 扣标价现金，多付的保持堆叠退回


func _initialize() -> void:
	print("=== 堆叠购买 测试 ===")
	var main: Node = await boot_main()
	# 两次购买都要有余款，固定货架避免随机抽到高价卡耗尽第二次付款夹具。
	main.state.market = ["yunketang", "ditui", "baoyue", "tuisong", "yunketang", "ditui", "baoyue", "tuisong"]
	main._respawn_all()
	await create_timer(0.5).timeout

	var state: GameState = main.state
	var board: Board = main.board
	var price: int = CardDB.get_def(state.market[0]).get("price", 1)
	var cash0: int = state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	print("       公共区[0] = %s，标价 %d；玩家现金 %d" % [CardDB.card_name(state.market[0]), price, cash0])

	# --- 堆叠购买：拖 price+2 张现金到公共区卡上 ---
	var dragged: Array = []
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "cash" and dragged.size() < price + 2:
			dragged.append(main.entities[c["uid"]])
	check(dragged.size() == price + 2, "备好 %d 张现金" % (price + 2))
	var market_card: CardEntity = main.market_cards[0]
	check(not market_card.draggable, "商品成交前不是可自由编组的己方卡")
	# 模拟现金已被玩家拖离原摞；商品反拖付款的原地现金另有真实输入测试。
	for card in dragged: board._detach_from_group(card)
	await main._on_dropped_on_market(dragged, market_card)
	await create_timer(0.5).timeout
	for i in 10:
		await physics_frame

	check(state.market.size() == CardDB.game_rules()["market_size"] - 1, "公共区减少一张")
	check(state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash0 - price,
		"只扣标价现金 %d → %d" % [cash0, cash0 - price])
	check(main.entities.has(market_card.uid) and not market_card.is_market and market_card.draggable,
		"买到的卡已归玩家且恢复可拖动")

	# 多付的 2 张：保持堆叠退回
	var excess: Array = dragged.slice(price)
	var stacked := false
	for g in board.groups:
		var all_in := true
		for c in excess:
			if not g["cards"].has(c):
				all_in = false
		if all_in and g["cards"].size() == excess.size():
			stacked = true
	check(stacked, "多付的 %d 张现金以堆叠状态退回" % excess.size())

	# --- 收拢态的现金摞买卡：付掉一部分，剩下的还是同一摞（不摊开） ---
	# 走完整链路：_on_card_clicked → _process → _end_drag，因为 last_drag_compact
	# 是在 _end_drag 里落下的，直接调 _on_dropped_on_market 测不到这一段
	# 挑最便宜的一张，保证买得起且有多付的余量
	var t_idx := 0
	for i in state.market.size():
		if CardDB.get_def(state.market[i]).get("price", 99) \
			< CardDB.get_def(state.market[t_idx]).get("price", 99):
			t_idx = i
	var price3: int = CardDB.get_def(state.market[t_idx]).get("price", 1)
	var pile: Array = []
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "cash" and pile.size() < price3 + 3:
			pile.append(main.entities[c["uid"]])
	# 从已有现金摞中取出这一手付款，重新摆成收拢摞。
	for e in pile:
		for g in board.groups.duplicate():
			if g["cards"].has(e):
				board._detach_from_group(e)
	if pile.size() == price3 + 3:
		# 摆在玩家区现金摞的位置，让 _layout_group 自己沿 z 铺开（别手动摆成一叠：
		# 挤在一处的散卡会被理牌/合并逻辑重新收编）
		pile[0].global_position = Vector3(-4.0, 0.05, 4.2)
		var cg: Dictionary = board.make_group(pile.duplicate())
		board.groups.append(cg)
		board._layout_group(cg)
		await physics_frame
		check(board.toggle_compact(pile[0]), "现金摞可以双击收拢")
		await create_timer(0.3).timeout
		# 拎起整摞（收拢态点哪张都是整摞走）
		board._on_card_clicked(pile[0])
		check(board._drag_compact, "拎起收拢的现金摞时记着收拢态")
		# 落到公共区卡上：直接把牌摆到货架卡跟前，走 _end_drag 的购买分支
		var target: CardEntity = main.market_cards[t_idx]
		var tp := target.global_position
		for c in board._drag_cards:
			c.global_position = Vector3(tp.x, Board.DRAG_HEIGHT, tp.z)
		var cash_b: int = state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
		board._end_drag()
		check(board.last_drag_compact, "购买时把收拢态交给接收方（last_drag_compact）")
		await create_timer(0.5).timeout
		for i in 10:
			await physics_frame
		check(state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_b - price3,
			"扣掉标价 %d 现金（%d → %d）" % [price3, cash_b, cash_b - price3])
		# 多付的 3 张：退回后仍是收拢的一摞
		var rest: Array = []
		for c in pile:
			if is_instance_valid(c) and main.entities.has(c.uid):
				rest.append(c)
		var rg: Variant = null
		for c in rest:
			var gg: Variant = board.group_of(c)
			if gg != null:
				rg = gg
				break
		check(rg != null, "多付的现金退回后重新成摞（剩 %d 张）" % rest.size())
		if rg != null:
			check(rg.get("compact", false), "退回的现金摞保持收拢态（不因买卡摊开）")
			var zmin := INF
			var zmax := -INF
			for c in rg["cards"]:
				zmin = minf(zmin, c.global_position.z)
				zmax = maxf(zmax, c.global_position.z)
			check(zmax - zmin <= CardEntity.CARD_SIZE.z,
				"退回后占地仍是一张卡（z 跨度 %.2f）" % (zmax - zmin))
	else:
		check(false, "备好 %d 张现金做收拢摞（实际 %d）" % [price3 + 3, pile.size()])

	# --- 非现金支付被拒 ---
	var market_before: int = state.market.size()
	var user_card: CardEntity = null
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "user":
			user_card = main.entities[c["uid"]]
			break
	await main._on_dropped_on_market([user_card], main.market_cards[0])
	await create_timer(0.2).timeout
	check(state.market.size() == market_before, "用户卡支付被拒，公共区不变")

	# --- 现金不足被拒 ---
	var price2: int = CardDB.get_def(state.market[0]).get("price", 1)
	if price2 >= 2:
		var one_cash: Array = []
		for c in state.players[GameState.PLAYER]["cards"]:
			if c["def_id"] == "cash":
				one_cash.append(main.entities[c["uid"]])
				break
		await main._on_dropped_on_market(one_cash, main.market_cards[0])
		await create_timer(0.2).timeout
		check(state.market.size() == market_before, "现金不足被拒（1/%d）" % price2)

	# --- 配方进度由牌面承担：拖拽途中没有浮动提示 ---
	var prod: Dictionary = state.add_card(GameState.PLAYER, "shuabuting")
	var e_prod: CardEntity = main._spawn_entity(prod, Vector3(-6, 0.3, 4.5), true)
	await physics_frame
	check(is_instance_valid(e_prod), "核心卡照常落桌（提示删除不影响生成）")
	check(not board.has_method("recipe_hint_text"), "拖拽提示文案构建器已移除")

	finish()
