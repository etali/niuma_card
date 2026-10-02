# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 典当设施与商品同排后，落点按最近目标分流；不能由典当检测的执行次序抢走购买。
## 走 Board 的真实拾取/松手信号，仅断开经济处理器以便逐个检查路由。
var _probe_uid := 88000

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 购牌区设施拖放边界 ===")
	var main := await boot_main()
	await _check_mode(main, "横屏")
	main.queue_free()
	await process_frame
	_booted = null

	var drawer: Node = load("res://scenes/main.tscn").instantiate()
	drawer.force_drawer_layout = true
	root.add_child(drawer)
	_booted = drawer
	await settle()
	_assert_booted(drawer)
	await _check_mode(drawer, "抽屉")
	drawer.queue_free()
	_booted = null
	await process_frame
	await process_frame
	finish()

func _check_mode(main: Node, mode: String) -> void:
	main.sfx.set_muted(true)
	var board: Board = main.board
	if not need(not main.market_cards.is_empty(), "%s：有可购买的市场牌" % mode):
		return
	var market_handler := Callable(main, "_on_dropped_on_market")
	var pawn_handler := Callable(main, "_on_dropped_on_pawn")
	board.dropped_on_market.disconnect(market_handler)
	board.dropped_on_pawn.disconnect(pawn_handler)

	var last: CardEntity = main.market_cards[main.market_cards.size() - 1]
	var original := last.global_position
	var pawn := board.pawn_pos
	check(pawn != Vector3.INF, "%s：典当位置来自实际牌桌配置" % mode)
	var market_hit := _drop_at(main, last.global_position)
	check(market_hit.market == last and market_hit.pawn == 0,
		"%s：拖到最后一张商品中心只发购买信号" % mode)
	var pawn_hit := _drop_at(main, pawn)
	check(pawn_hit.market == null and pawn_hit.pawn == 1,
		"%s：拖到典当牌中心只发典当信号" % mode)

	# 固定重叠夹具：由实际典当位置确定方向，商品与设施中心距 2.2。
	# 两个点都落在两种命中圈内，因此任何“固定先典当/先购买”实现都会有一条失败。
	var toward_market := Vector3(original.x - pawn.x, 0.0, original.z - pawn.z).normalized()
	if toward_market.is_zero_approx():
		toward_market = Vector3.LEFT
	last.global_position = pawn + toward_market * 2.2
	var near_market := last.global_position.lerp(pawn, 0.46)
	var near_pawn := last.global_position.lerp(pawn, 0.54)
	check(_flat_distance(near_market, pawn) < Board.PAWN_RADIUS
		and board._market_card_near(near_market) == last,
		"%s：靠商品的边界点同时命中商品和典当圈" % mode)
	check(_flat_distance(near_pawn, pawn) < Board.PAWN_RADIUS
		and board._market_card_near(near_pawn) == last,
		"%s：靠典当的边界点同时命中商品和典当圈" % mode)
	var overlap_market := _drop_at(main, near_market)
	check(overlap_market.market == last and overlap_market.pawn == 0,
		"%s：重叠区靠近商品时购买，不被先判的典当截走" % mode)
	var overlap_pawn := _drop_at(main, near_pawn)
	check(overlap_pawn.market == null and overlap_pawn.pawn == 1,
		"%s：重叠区靠近设施时典当，不被商品截走" % mode)
	last.global_position = original

	# 空地测试先问实际命中状态，保证测到的是空白而不是另一个商品的容错范围。
	var blank := pawn + Vector3(0.0, 0.0, 3.5)
	check(board._market_card_near(blank) == null
		and _flat_distance(blank, pawn) > Board.PAWN_RADIUS,
		"%s：空地夹具不在任何交易目标范围" % mode)
	var blank_hit := _drop_at(main, blank)
	check(blank_hit.market == null and blank_hit.pawn == 0 and blank_hit.table == 1,
		"%s：拖到空地只落桌，不发购买或典当信号" % mode)

	# 真正买走最后一张商品，再向原槽位拖拽；设施和装饰槽不能冒充商品。
	var idx: int = main.market_cards.find(last)
	var bought: Dictionary = await main._try_buy(idx)
	if need(bought.get("ok", false), "%s：最后一张商品真实成交" % mode):
		await settle()
		check(not last.is_market and not main.market_cards.has(last),
			"%s：成交牌已退出市场注册" % mode)
		var sold_hit := _drop_at(main, original)
		check(sold_hit.market == null and sold_hit.pawn == 0 and sold_hit.table == 1,
			"%s：已售空槽不触发购买或典当" % mode)

	# 真实摘牌竞态：持牌期间卡被离场逻辑注销，稍后的松手必须为空操作。
	var removed := _new_probe(main)
	board._on_card_clicked(removed)
	check(board._drag_cards.has(removed), "%s：竞态夹具先进入真实拖拽" % mode)
	board.unregister_card(removed)
	removed.free()
	var after_remove := {"market": 0, "pawn": 0, "table": 0}
	var buy_cb := func(_cards: Array, _target: CardEntity): after_remove.market += 1
	var pawn_cb := func(_cards: Array): after_remove.pawn += 1
	var table_cb := func(): after_remove.table += 1
	board.dropped_on_market.connect(buy_cb)
	board.dropped_on_pawn.connect(pawn_cb)
	board.card_dropped_table.connect(table_cb)
	board._end_drag()
	check(board._drag_cards.is_empty() and after_remove == {"market": 0, "pawn": 0, "table": 0},
		"%s：在手牌已注销后的松手不崩溃、不触发交易" % mode)
	board.dropped_on_market.disconnect(buy_cb)
	board.dropped_on_pawn.disconnect(pawn_cb)
	board.card_dropped_table.disconnect(table_cb)
	board.dropped_on_market.connect(market_handler)
	board.dropped_on_pawn.connect(pawn_handler)

func _new_probe(main: Node) -> CardEntity:
	_probe_uid += 1
	var probe := CardEntity.new()
	probe.setup(_probe_uid, "cash")
	probe.position = Vector3(0.0, 0.05, 3.0)
	probe.freeze = true
	main.add_child(probe)
	main.board.register_card(probe)
	return probe

func _drop_at(main: Node, at: Vector3) -> Dictionary:
	var board: Board = main.board
	var probe := _new_probe(main)
	var hits := {"market": null, "pawn": 0, "table": 0}
	var buy_cb := func(dragged: Array, target: CardEntity):
		hits.market = target
		check(dragged.size() == 1 and dragged[0] == probe,
			"购买信号携带本次拖拽的牌")
	var pawn_cb := func(dragged: Array):
		hits.pawn += 1
		check(dragged.size() == 1 and dragged[0] == probe,
			"典当信号携带本次拖拽的牌")
	var table_cb := func(): hits.table += 1
	board.dropped_on_market.connect(buy_cb)
	board.dropped_on_pawn.connect(pawn_cb)
	board.card_dropped_table.connect(table_cb)
	board._on_card_clicked(probe)
	check(board._drag_cards.has(probe) and probe.dragging, "拾取后进入真实拖拽状态")
	probe.global_position = Vector3(at.x, Board.DRAG_HEIGHT, at.z)
	board._end_drag()
	check(board._drag_cards.is_empty() and not probe.dragging, "松手后清理拖拽状态")
	board.dropped_on_market.disconnect(buy_cb)
	board.dropped_on_pawn.disconnect(pawn_cb)
	board.card_dropped_table.disconnect(table_cb)
	board.unregister_card(probe)
	probe.free()
	return hits

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
