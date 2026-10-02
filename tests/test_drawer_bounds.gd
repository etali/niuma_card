# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 抽屉安全落点回归：验证初始资源的左右语义，以及密集产出时整组仍留在
## player_bounds 内。测试使用真实 CardEntity / Board / SettleLayout 路径。

func _initialize() -> void:
	var main: Node = await boot_main()
	var pb := Rect2(-12.5, 0.0, 25.0, 6.5)
	main.board.player_bounds = pb
	var half_x := CardEntity.CARD_SIZE.x * 0.5
	var half_z := CardEntity.CARD_SIZE.z * 0.5
	var xmin := pb.position.x + half_x
	var xmax := pb.end.x - half_x
	var zmin := pb.position.y + half_z
	var zmax := pb.end.y - half_z

	var cash_origins: Array = []
	var user_origins: Array = []
	for g in main.board.groups:
		if g["cards"].is_empty():
			continue
		var def := CardDB.get_def(g["cards"][0].def_id)
		if def.get("kind") != CardDB.KIND_UNIT:
			continue
		var at: Vector3 = main.board.rest_origin(g)
		if def.get("res") == CardDB.RES_CASH:
			cash_origins.append(at.x)
		elif def.get("res") == CardDB.RES_USER:
			user_origins.append(at.x)
	check(not cash_origins.is_empty() and not user_origins.is_empty(),
		"开局现金/用户资源都生成了独立牌组")
	if not cash_origins.is_empty() and not user_origins.is_empty():
		check(absf(cash_origins[0] - user_origins[0]) > 0.5,
			"开局现金与用户资源牌组不精确重叠")

	var cards: Array = []
	for i in 200:
		var e := CardEntity.new()
		e.setup(120000 + i, "cash")
		e.draggable = true
		main.add_child(e)
		main.board.register_card(e)
		main.entities[e.uid] = e
		cards.append(e)
	main.layout._group_pile(cards, main.layout.PLAYER_PILE_CASH_ANCHOR)
	var users: Array = []
	for i in 200:
		var e := CardEntity.new()
		e.setup(130000 + i, "user")
		e.draggable = true
		main.add_child(e)
		main.board.register_card(e)
		main.entities[e.uid] = e
		users.append(e)
	main.layout._group_pile(users, main.layout.PLAYER_PILE_USER_ANCHOR)
	for i in 30:
		await physics_frame
	var all_inside := true
	for e in cards + users:
		var at: Vector3 = e.global_position
		all_inside = all_inside and at.x >= xmin and at.x <= xmax and at.z >= zmin and at.z <= zmax
	check(all_inside, "200 张现金 + 200 张用户资源牌均在 player_bounds 内")

	var cash_groups: Array = []
	var user_groups: Array = []
	for g in main.board.groups:
		var members: Array = g["cards"]
		if members.is_empty():
			continue
		if members.any(func(c): return cards.has(c)):
			cash_groups.append(g)
		if members.any(func(c): return users.has(c)):
			user_groups.append(g)
	check(not cash_groups.is_empty() and not user_groups.is_empty(),
		"密集资源各自建立了真实牌组")
	var origins: Array = []
	var cash_region := true
	var user_region := true
	for g in cash_groups:
		var at: Vector3 = main.board.rest_origin(g)
		origins.append(Vector2(at.x, at.z))
		cash_region = cash_region and at.x < -0.5
	for g in user_groups:
		var at: Vector3 = main.board.rest_origin(g)
		origins.append(Vector2(at.x, at.z))
		user_region = user_region and at.x > 0.5
	check(cash_region and user_region, "现金与用户资源使用左右独立子区域")
	var unique_slots := true
	for i in origins.size():
		for j in range(i + 1, origins.size()):
			if origins[i].distance_to(origins[j]) < 0.05:
				unique_slots = false
	check(unique_slots, "密集资源牌组的摞锚点没有重复占位")
	main.queue_free()
	finish()
