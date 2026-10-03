# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 拖拽落手的「原地不动」与「凑满风铃只在结果变了时才响」回归测试
##
## 三个原始缺陷：
## 1. 单击把摞好的组合拎起来原地放下，整摞会往近边挪一截（_layout_group 拿队首坐标
##    当组起点，而收拢态队首的层间偏移不是 0，每次重排都多推 COMPACT_GAP.z*(n-1)）
## 2. 一组已凑满的牌，按住其中一部分再松手放回原处：源组被抽空成「不成立」、
##    放回去又「成立」，被当成一次新凑满多响一声，而玩家动作前后结果并没有变
## 3. 反过来也有吞声的：两张同名 T2 从散卡并成升级组是实打实的新凑满，
##    make_group 按最终牌面预评估直接把 was_valid 置真，风铃一次都不响


func _initialize() -> void:
	print("=== 拖拽落手 / 凑满风铃测试 ===")
	var main: Node = await boot_main()
	var board: Board = main.board

	await _t1_compact_drop_in_place(main, board)
	await _t2_subset_no_reding(main, board)
	await _t3_new_combo_dings(main, board)
	await _t4_pickup_ding_deferred(main, board)

	await _t5_upgrade_target_dings(main, board)

	finish()

# ---------- 1. 收拢摞原地拎起放下不挪位 ----------

func _t1_compact_drop_in_place(main: Node, board: Board) -> void:
	print("--- 1. 收拢摞原地拎起放下 ---")
	var uid := 9200
	var members: Array = []
	# 6 张用户卡 + 一张核心：够长才看得出 COMPACT_GAP.z*(n-1) 的累积漂移
	var core: CardEntity = main._spawn_entity(
		{ "uid": uid, "def_id": "yunketang" }, Vector3(-6.0, 0.05, 4.0), true)
	members.append(core)
	for i in 6:
		uid += 1
		members.append(main._spawn_entity(
			{ "uid": uid, "def_id": "user" }, Vector3(-6.0, 0.05, 4.0), true))
	isolate(board, members)
	for c in members:
		board._detach_from_group(c)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	check(board.toggle_compact(core), "收拢这一摞")
	await settle()

	var n: int = g["cards"].size()
	var start: Vector3 = core.global_position
	print("       收拢后摞顶 x/z：%.3f / %.3f（%d 张）" % [start.x, start.z, n])

	# 原地拎起放下 ×3：鼠标不动，每张牌落手前回到拎起前的 x/z
	var drift := 0.0
	for round_i in 3:
		var before := {}
		for c in board.groups[board.groups.find(board.group_of(core))]["cards"]:
			before[c] = c.global_position
		board._on_card_clicked(core)
		check(board._drag_cards.size() == n,
			"第 %d 次：整摞一起拎起（%d/%d）" % [round_i + 1, board._drag_cards.size(), n])
		# 鼠标没动 = 每张牌停在原来的 x/z，只被抬到拖拽高度
		for i in board._drag_cards.size():
			var c: CardEntity = board._drag_cards[i]
			var p: Vector3 = before[c]
			p.y = Board.DRAG_HEIGHT + board._drag_offsets[i].y
			c.global_position = p
		board._end_drag()
		await settle()
		var ng: Variant = board.group_of(core)
		check(ng != null and ng.get("compact", false),
			"第 %d 次：落桌后仍是收拢态" % [round_i + 1])
		var d := Vector2(core.global_position.x - start.x, core.global_position.z - start.z).length()
		drift = maxf(drift, d)
		print("       第 %d 次落手后摞顶 x/z：%.3f / %.3f（位移 %.3f）" % [
			round_i + 1, core.global_position.x, core.global_position.z, d])

	# 旧实现每次推 COMPACT_GAP.z*(n-1) = 0.05*6 = 0.30，三次就是 0.90
	check(drift < 0.02, "三次原地拎起放下累计位移 < 0.02（实际 %.3f）" % drift)

	# 结算/理牌会把收拢摞抬到其它牌上；原地放回不能把它吸回桌面。
	var lifted_origin := Vector3(start.x, 0.82, start.z)
	var lifted_group: Variant = board.group_of(core)
	if lifted_group != null:
		board._layout_group(lifted_group, lifted_origin)
	await settle()
	var lifted_y: float = core.global_position.y
	board._on_card_clicked(core)
	for i in board._drag_cards.size():
		var c: CardEntity = board._drag_cards[i]
		c.global_position = Vector3(c.global_position.x, Board.DRAG_HEIGHT + board._drag_offsets[i].y, c.global_position.z)
	board._end_drag()
	await settle()
	check(absf(core.global_position.y - lifted_y) < 0.02,
		"被抬高的收拢摞原地放回仍保持高度（%.3f → %.3f）" % [lifted_y, core.global_position.y])
	# 按住期间曾经移出点击阈值、最后又回到原处：必须按快照恢复，不重新排层。
	var before_roundtrip: Array = members.map(func(c): return c.global_position)
	board._on_card_clicked(core)
	for c in board._drag_cards:
		c.global_position += Vector3(0.5, 0.0, 0.3)
	for i in board._drag_cards.size():
		board._drag_cards[i].global_position = before_roundtrip[i]
	board._end_drag()
	await settle()
	var roundtrip_same := true
	for i in members.size():
		roundtrip_same = roundtrip_same and members[i].global_position.is_equal_approx(before_roundtrip[i])
	check(roundtrip_same, "高摞拖远后回到原处松手仍按快照复位")
	park(board, members)

# ---------- 2. 已凑满的组里按住子集再放回原处：不重复响 ----------

func _t2_subset_no_reding(main: Node, board: Board) -> void:
	print("--- 2. 已凑满组里按住子集再放回 ---")
	# 地推扫码：全卡表里配方最小的生产卡，凑满所需的组最小可控。
	# 张数从卡表取 —— 这一节量的是「按住子集再放回不重复响」，
	# 配方是几张无关，硬写的话每轮调数值都要来改一次
	var ditui_n := int(CardDB.get_def("ditui")["recipe_n"])
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9300, "def_id": "ditui" }, Vector3(-6.0, 0.05, 3.0), true)
	var members: Array = [core]
	for i in ditui_n:
		members.append(main._spawn_entity(
			{ "uid": 9301 + i, "def_id": "cash" }, Vector3(-6.0, 0.05, 3.0), true))
	var group_n := ditui_n + 1
	isolate(board, members)
	for c in members:
		board._detach_from_group(c)

	var dings := [0]
	var cb := func(): dings[0] += 1
	board.group_completed.connect(cb)
	var g: Dictionary = board.make_group(members.duplicate(), false, false)
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	check(g["was_valid"], "%d 张牌凑满配方（地推扫码 + 现金×%d）" % [group_n, ditui_n])
	check(dings[0] == 1, "第一次凑满响一声（实际 %d）" % dings[0])

	# 按住摊开态队尾那张（子集 = 它自己），原地松手放回同一组
	dings[0] = 0
	var pick: CardEntity = g["cards"][g["cards"].size() - 1]
	var at: Vector3 = pick.global_position
	board._on_card_clicked(pick)
	check(board._drag_cards.size() == 1, "按住摊开态队尾一张 = 只拎它")
	check(board.group_of(core) != null, "源组还在桌上（只被抽走一张）")
	check(dings[0] == 0, "按下的瞬间不响（实际 %d）" % dings[0])
	pick.global_position = Vector3(at.x, Board.DRAG_HEIGHT, at.z)
	board._end_drag()
	await settle()

	var ng: Variant = board.group_of(core)
	check(ng != null and ng["cards"].size() == group_n,
		"松手后 %d 张牌还在同一组" % group_n)
	check(ng != null and ng.get("was_valid", false), "组仍是凑满状态")
	check(dings[0] == 0, "结果没变 → 一声都不响（实际 %d）" % dings[0])
	board.group_completed.disconnect(cb)
	park(board, members)

# ---------- 3. 真凑满不能被吞：两张散的同名 T2 并成升级组 ----------

func _t3_new_combo_dings(main: Node, board: Board) -> void:
	print("--- 3. 两张同名 T2 并成升级组 ---")
	var a: CardEntity = main._spawn_entity(
		{ "uid": 9400, "def_id": "tuanzhang" }, Vector3(-6.0, 0.05, 2.0), true)
	var b: CardEntity = main._spawn_entity(
		{ "uid": 9401, "def_id": "tuanzhang" }, Vector3(-4.4, 0.05, 2.0), true)
	isolate(board, [a, b])
	board._detach_from_group(a)
	board._detach_from_group(b)
	await physics_frame
	check(board.group_of(a) == null and board.group_of(b) == null, "两张同名 T2 都是散卡")

	var dings := [0]
	var stacks: Array = []
	var cb := func(): dings[0] += 1
	var cb2 := func(completed): stacks.append(completed)
	board.group_completed.connect(cb)
	board.card_stacked.connect(cb2)

	# 把 a 拖到 b 上：走单卡 try_merge → 散卡成组那条分支
	board._on_card_clicked(a)
	check(board._drag_cards.size() == 1, "拎起一张散卡")
	a.global_position = Vector3(b.global_position.x + 0.2, Board.DRAG_HEIGHT, b.global_position.z)
	board._end_drag()
	await settle()

	var g: Variant = board.group_of(a)
	check(g != null and g["cards"].size() == 2, "两张并成一组")
	check(g != null and g.get("was_valid", false), "这一组当即凑满（团长帝国×2 → 独角兽）")
	check(dings[0] == 1, "真凑满响一声（实际 %d）" % dings[0])
	check(stacks.size() == 1 and stacks[0] == true,
		"card_stacked 带 completed=true（凑满音由 group_completed 播）")
	board.group_completed.disconnect(cb)
	board.card_stacked.disconnect(cb2)
	park(board, [a, b])

# ---------- 4. 抽走一张反而让剩下的凑满：这一声压到落手时结算 ----------

func _t4_pickup_ding_deferred(main: Node, board: Board) -> void:
	print("--- 4. 抽走一张让剩下的凑满 ---")
	# 升级组里多塞一张用户卡 → 不成立；把用户卡抽掉，剩下的同名两张才成立
	var a: CardEntity = main._spawn_entity(
		{ "uid": 9500, "def_id": "tuanzhang" }, Vector3(-6.0, 0.05, 1.0), true)
	var b: CardEntity = main._spawn_entity(
		{ "uid": 9501, "def_id": "tuanzhang" }, Vector3(-6.0, 0.05, 1.0), true)
	var u: CardEntity = main._spawn_entity(
		{ "uid": 9502, "def_id": "user" }, Vector3(-6.0, 0.05, 1.0), true)
	var members: Array = [a, b, u]
	isolate(board, members)
	for c in members:
		board._detach_from_group(c)
	var g: Dictionary = board.make_group(members.duplicate(), false, false)
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	check(not g.get("was_valid", false), "多一张用户卡 → 升级组不成立")
	check(g["cards"][g["cards"].size() - 1] == u, "用户卡在摊开态队尾（拎它 = 只拎它）")

	var dings := [0]
	var cb := func(): dings[0] += 1
	board.group_completed.connect(cb)

	# 4a. 抽走用户卡放到远处：剩下的两张凑满，风铃在落手时补上
	board._on_card_clicked(u)
	check(board._drag_cards.size() == 1, "只拎起用户卡")
	check(dings[0] == 0, "按下的瞬间不响（压到落手结算，实际 %d）" % dings[0])
	u.global_position = Vector3(-1.5, Board.DRAG_HEIGHT, 1.0)
	board._end_drag()
	await settle()
	var g2: Variant = board.group_of(a)
	check(g2 != null and g2["cards"].size() == 2, "桌上剩两张同名 T2 一组")
	check(g2 != null and g2.get("was_valid", false), "剩下的两张凑满了")
	check(dings[0] == 1, "落手时补响一声（实际 %d）" % dings[0])

	# 4b. 把用户卡拖回这一组：又变不成立，不该有任何响
	dings[0] = 0
	board._on_card_clicked(u)
	u.global_position = Vector3(a.global_position.x + 0.2, Board.DRAG_HEIGHT, a.global_position.z)
	board._end_drag()
	await settle()
	var g3: Variant = board.group_of(u)
	check(g3 != null and g3["cards"].size() == 3, "用户卡并回三张一组")
	check(g3 != null and not g3.get("was_valid", false), "三张又不成立")
	check(dings[0] == 0, "拖回去不响（实际 %d）" % dings[0])
	board.group_completed.disconnect(cb)
	park(board, members)

# 合法升级组的产物变化也要报凑满；使用录像中的八张 T1。
func _t5_upgrade_target_dings(main: Node, board: Board) -> void:
	var ids := ["yunketang", "pinshaoshao", "baoyue", "yunketang", "shuabuting", "yunketang", "shuabuting", "chunwan"]
	for sizes in [[4, 2, 2], [4, 4]]:
		var members: Array = []
		for i in ids.size():
			members.append(main._spawn_entity({"uid": 9600 + i, "def_id": ids[i]}, Vector3(-6, 0.05, 2), true))
		isolate(board, members)
		for c in members:
			board._detach_from_group(c)
		var offset := 0
		var piles: Array = []
		for size in sizes:
			var g := board.make_group(members.slice(offset, offset + size))
			board.groups.append(g)
			board._layout_group(g, Vector3(-6 + piles.size() * 3, 0.05, 2))
			piles.append(g)
			offset += size
		await settle()
		var dings := [0]
		var cb := func(): dings[0] += 1
		board.group_completed.connect(cb)
		for i in range(1, piles.size()):
			var pick: CardEntity = piles[i]["cards"][0]
			board._on_card_clicked(pick)
			pick.global_position = members[0].global_position + Vector3(0.2, Board.DRAG_HEIGHT, 0)
			board._end_drag()
			await settle()
			check(dings[0] == i, "%s 第 %d 次合并只响一次（实际 %d）" % [sizes, i, dings[0]])
		var final_group: Dictionary = board.group_of(members[0])
		check(final_group["upgrade_target"] == "shangshi", "%s 八张 T1 合成上市敲钟" % [sizes])
		dings[0] = 0
		board.refresh_group(final_group)
		board.toggle_compact(members[0])
		await settle()
		board._on_card_clicked(members[0])
		members[0].global_position = Vector3(-2, Board.DRAG_HEIGHT, 4)
		board._end_drag()
		await settle()
		check(dings[0] == 0, "刷新、收拢、整摞移动不重复响")
		board.toggle_compact(members[0])
		await settle()
		# 拿走后两张时源组暂时变成国民应用；原样放回不应响。
		board._on_card_clicked(members[6])
		check(dings[0] == 0, "拎起时的升级目标变化延迟到落手")
		members[6].global_position = members[0].global_position + Vector3(0.2, Board.DRAG_HEIGHT, 0)
		board._end_drag()
		await settle()
		check(dings[0] == 0, "八张拆出两张再放回不重复响")
		board._on_card_clicked(members[6])
		members[6].global_position = Vector3(-6, Board.DRAG_HEIGHT, 1)
		board._end_drag()
		await settle()
		check(dings[0] == 1, "八张拆成六张与两张，留下的升级目标改变只补响一次")
		check(board.group_of(members[0])["upgrade_target"] == "guomin", "六张剩余组合升级为国民应用")
		board.group_completed.disconnect(cb)
		park(board, members)
