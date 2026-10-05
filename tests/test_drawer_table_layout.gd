# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const DrawerTableLayout = preload("res://scenes/drawer_table_layout.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉紧凑物理布局 ===")
	var main: Node = await boot_main()
	if not need(main != null, "场景启动"):
		finish()
		return
	var layout := DrawerTableLayout.new()
	main.add_child(layout)
	layout.bind(main)
	main.layout = layout
	check(layout.DRAWER_WORLD_RECT == Rect2(-10.8, -5.25, 21.6, 11.3), "抽屉世界边界紧凑")
	check(layout.DRAWER_PLAYER_RECT == Rect2(-10.0, 1.2, 20.0, 4.5), "玩家区边界紧凑")
	check(layout.DRAWER_FOE_RECT == Rect2(-10.0, -4.8, 20.0, 2.6), "对手区边界紧凑")
	# 压力场景：40 个独立对手核心、400 张玩家资源，检验所有 UID 都留在紧凑世界边界内。
	var next_uid := 910000
	for i in 40:
		var e := CardEntity.new()
		e.setup(next_uid + i, "yunketang")
		e.draggable = true
		main.add_child(e)
		layout.entities[next_uid + i] = e
		main.state.players[main.foe_seat]["cards"].append({"uid": next_uid + i, "def_id": "yunketang"})
		main.state.combos.append({"owner": main.foe_seat, "uids": [next_uid + i]})
	for i in 400:
		var e2 := CardEntity.new()
		var uid2 := next_uid + 1000 + i
		e2.setup(uid2, "cash" if i % 2 == 0 else "user")
		e2.draggable = true
		main.add_child(e2)
		layout.entities[uid2] = e2
		main.state.players[main.my_seat]["cards"].append({"uid": uid2, "def_id": e2.def_id})
	layout._layout_bot_zone()
	await settle()
	var stress_ok := true
	for uid in layout.entities:
		var ce: CardEntity = layout.entities[uid]
		if not is_instance_valid(ce) or ce.is_market:
			continue
		var at2 := ce.global_position
		stress_ok = stress_ok and at2.x >= -10.0 and at2.x <= 10.0 and at2.z >= -5.25 and at2.z <= 6.05
	check(stress_ok, "40个对手核心与400张资源均未越紧凑世界边界")
	var known := {}
	layout._stack_settled(known)
	await settle()
	var all_resources := true
	for rec3 in main.state.players[main.my_seat]["cards"]:
		if not layout.entities.has(rec3["uid"]):
			continue
		var ce3: CardEntity = layout.entities[rec3["uid"]]
		var at3 := ce3.global_position
		all_resources = all_resources and at3.x >= -10.0 and at3.x <= 10.0 and at3.z >= 1.2 and at3.z <= 5.7
	check(all_resources, "结算到货后资源UID仍完整留在玩家区")
	layout._layout_bot_zone()
	await settle()
	var foe_ok := true
	for rec in main.state.players[main.foe_seat]["cards"]:
		if not layout.entities.has(rec["uid"]):
			continue
		var e: CardEntity = layout.entities[rec["uid"]]
		if not is_instance_valid(e):
			continue
		var at := e.global_position
		foe_ok = foe_ok and at.x >= -9.5 and at.x <= 9.5 and at.z >= -4.0 and at.z <= -2.2
	check(foe_ok, "对手牌完整落在紧凑对手区")
	layout._tidy_player_idle()
	await settle()
	var player_ok := true
	for rec in main.state.players[main.my_seat]["cards"]:
		if not layout.entities.has(rec["uid"]):
			continue
		var e: CardEntity = layout.entities[rec["uid"]]
		if not is_instance_valid(e):
			continue
		var def := CardDB.get_def(rec["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT:
			continue
		var at := e.global_position
		player_ok = player_ok and at.x >= -9.5 and at.x <= 9.5 and at.z >= 2.05 and at.z <= 4.8
	check(player_ok, "玩家资源卡完整落在紧凑玩家区")
	main.queue_free()
	finish()
