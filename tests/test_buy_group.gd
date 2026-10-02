# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 回归测试：支付的现金卡在牌组中时，购买不能留下悬空引用（购买后卡死的 bug）


func _initialize() -> void:
	print("=== 购买支付组内现金 测试 ===")
	var main: Node = await boot_main()

	var state: GameState = main.state
	var board: Board = main.board
	var price: int = CardDB.get_def(state.market[0]).get("price", 1)
	print("       公共区[0] = %s，标价 %d" % [CardDB.card_name(state.market[0]), price])

	# 把现金卡堆成一个牌组（比标价多 2 张，购买后组应剩余 2 张）
	var target_n := mini(price + 2, 15)
	var group_cards: Array = []
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_CASH) and group_cards.size() < target_n:
			group_cards.append(main.entities[c["uid"]])
	check(group_cards.size() == target_n, "堆好 %d 张现金的牌组" % target_n)
	# 这些现金已被回合开始的理牌分进纯资源摞，先摘出来再建购买组
	for e in group_cards:
		board._detach_from_group(e)
	var g = { "cards": group_cards, "label": null }
	board.groups.append(g)
	board.refresh_group(g)

	# 购买：支付会消耗这个组里的现金卡（实体被 fly_out + queue_free）。
	# 指定用组内这几张付 —— 不传的话引擎自己挑散着的现金，
	# 挑中哪几张不保证是这个组的，下面「组内剩余」就量不到该量的东西
	var pay_uids: Array = []
	for e in group_cards:
		pay_uids.append(e.uid)
	var r: Dictionary = await main._try_buy(0, pay_uids)
	check(r["ok"], "购买成功")
	await create_timer(0.3).timeout
	for i in 10:
		await physics_frame

	# 组里不能再有悬空引用；被支付的卡应从组中移除，余牌保留
	var stale := 0
	var total_in_groups := 0
	for g2 in board.groups:
		for c in g2["cards"]:
			total_in_groups += 1
			if not is_instance_valid(c):
				stale += 1
	check(stale == 0, "牌组无悬空引用（%d 张组内卡均有效）" % total_in_groups)
	check(g["cards"].size() == target_n - price, "支付后组内剩余 %d 张现金" % (target_n - price))

	# 拖拽吸附扫描不崩（复现卡死现场：_process 每帧调用 _nearest_group）
	var hit: Variant = board._nearest_group(Vector3(0, 0.2, 3.0), [])
	check(true, "拖拽吸附扫描无崩溃（hit=%s）" % [hit != null])

	finish()
