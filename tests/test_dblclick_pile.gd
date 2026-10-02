# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 双击收拢/摊开的可靠性 + AI 摞牌覆盖全部手牌
##
## 三个原始缺陷：
## 1. 双击有时候不摞牌。第一击已经走完「按下-拎起-松手」，_layout_group 起了
##    0.18s 归位补间；第二击时牌正悬在半空往下落，71° 俯角下每高出桌面 Δ，
##    射线打到它的位置就往 +z 偏 Δ×0.345，摊开态每张只露 0.52 宽的标题带，
##    这点偏移足够让射线擦过牌沿打空 → picked = null → 双击整个白点
## 2. 就算射线打中了，toggle_compact 先 _core_first 把核心卡换到队首，
##    而 _layout_group 拿队首坐标反推组起点——核心卡此刻还在飞，
##    读到的是中间值，整摞落到一个说不清的地方；来回双击还会一路爬
## 3. AI 没编进组合的核心/Buff 卡不在任何摞里，_layout_ai_zone 不管它们,
##    只能留在 _free_spot 随手找的空位上，跟摞好的组合互相压边


func _initialize() -> void:
	print("=== 双击收拢 / AI 摞牌覆盖测试 ===")
	var main: Node = await boot_main()
	var board: Board = main.board

	await _t1_toggle_keeps_origin(main, board)
	await _t2_dbl_target_fallback(main, board)
	await _t3_toggle_midflight(main, board)
	await _t4_ai_bench_pile(main)
	await _t5_toggle_after_clamp(main, board)

	finish()

# ---------- 1. 来回双击不挪窝 ----------

func _t1_toggle_keeps_origin(main: Node, board: Board) -> void:
	print("--- 1. 反复双击收拢/摊开，整摞不挪窝 ---")
	var members := make_stack(main, board, 9400, "yunketang", 5)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var core: CardEntity = members[0]
	var origin: Vector3 = board._group_origin(g)
	print("       初始组起点 x/z：%.3f / %.3f（%d 张）" % [origin.x, origin.z, members.size()])

	var drift := 0.0
	for round_i in 4:
		check(board.toggle_compact(core), "第 %d 次双击：收拢" % [round_i + 1])
		await settle()
		var g1: Variant = board.group_of(core)
		check(g1 != null and g1.get("compact", false), "第 %d 次：已是收拢态" % [round_i + 1])
		var o1: Vector3 = board._group_origin(g1)
		drift = maxf(drift, Vector2(o1.x - origin.x, o1.z - origin.z).length())

		check(board.toggle_compact(core), "第 %d 次双击：摊开" % [round_i + 1])
		await settle()
		var g2: Variant = board.group_of(core)
		check(g2 != null and not g2.get("compact", false), "第 %d 次：已是摊开态" % [round_i + 1])
		var o2: Vector3 = board._group_origin(g2)
		drift = maxf(drift, Vector2(o2.x - origin.x, o2.z - origin.z).length())
		print("       第 %d 轮后组起点 x/z：%.3f / %.3f" % [round_i + 1, o2.x, o2.z])

	# 旧实现：核心卡不在队首时，收拢那一下按核心卡的摊开槽位定位整摞，
	# 每来回一次就往 +z 爬 STACK_GAP.z × 核心卡的原 index
	check(drift < 0.02, "四轮来回双击累计位移 < 0.02（实际 %.3f）" % drift)
	park(board, members)

# ---------- 2. 第二击射线打空时的兜底 ----------

func _t2_dbl_target_fallback(main: Node, board: Board) -> void:
	print("--- 2. 第二击射线打空，仍按第一击的牌切换 ---")
	var members := make_stack(main, board, 9500, "ditui", 3)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var core: CardEntity = members[0]

	# 第一击记下这张牌（_unhandled_input 在非双击分支里做的事）
	board._last_press_card = core
	# 第二击射线打空：picked = null
	check(board._dbl_target(null) == core, "射线打空 → 回退到第一击拾到的牌")
	check(board.toggle_compact(board._dbl_target(null)), "兜底目标能正常收拢")
	await settle()
	check(board.group_of(core).get("compact", false), "确实收拢了（不再是双击白点）")

	# 第二击的射线打偏、打到**另一组**的牌上：该切的仍是玩家第一击点的那一摞。
	# 牌在半空往下落的这 0.18s 里，射线落点会往 +z 偏，正好偏到邻摞是很常见的
	var nb := make_stack(main, board, 9550, "chaping", 3, members)
	var g2: Dictionary = board.make_group(nb.duplicate())
	board.groups.append(g2)
	nb[0].global_position = Vector3(-2.0, 0.05, 3.0)
	board._layout_group(g2)
	await settle()
	board._last_press_card = core
	check(board._dbl_target(nb[0]) == core,
		"射线偏到邻摞 → 仍按第一击那张（不去切玩家没点的摞）")

	# 第一击那张已经不在任何组里（比如被结算吃掉/拖走了）：退回射线结果
	var other: CardEntity = main._spawn_entity(
		{ "uid": 9599, "def_id": "cash" }, Vector3(-3.0, 0.05, 3.0), true)
	board._detach_from_group(other)
	board._last_press_card = other
	check(board._dbl_target(core) == core,
		"第一击那张已散出组 → 用射线结果（组里那张）")
	park(board, nb)

	# 两边都不在组里：不该崩，交给 toggle_compact 拒掉
	board._last_press_card = other
	check(board._dbl_target(other) == other, "两张都是散卡 → 原样返回")
	check(not board.toggle_compact(other), "散卡没有「摞」可言，toggle_compact 拒掉")
	park(board, members + [other])

# ---------- 3. 归位补间还在飞的时候双击 ----------

func _t3_toggle_midflight(main: Node, board: Board) -> void:
	print("--- 3. 上一次重排的补间还在飞时双击 ---")
	# 核心卡故意放在队尾：收拢时 _core_first 会把它换到队首，
	# 而它此刻正被补间往队尾的摊开槽位送——这是缺陷 2 的触发条件
	var members: Array = []
	for i in 4:
		members.append(main._spawn_entity(
			{ "uid": 9600 + i, "def_id": "cash" }, Vector3(-6.0, 0.05, 2.0), true))
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9610, "def_id": "ditui" }, Vector3(-6.0, 0.05, 2.0), true)
	members.append(core)
	isolate(board, members)
	for c in members:
		board._detach_from_group(c)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	check(g["cards"][g["cards"].size() - 1] == core, "核心卡在摊开态队尾")
	var origin: Vector3 = board._group_origin(g)

	# 重排一次，立刻双击：补间刚起步，一帧都不等
	board._layout_group(g)
	check(board.toggle_compact(core), "补间在飞时双击收拢")
	await settle()
	var g1: Variant = board.group_of(core)
	check(g1.get("compact", false), "收拢成功")
	check(g1["cards"][0] == core, "核心卡换到了摞顶")
	var o1: Vector3 = board._group_origin(g1)
	var d := Vector2(o1.x - origin.x, o1.z - origin.z).length()
	print("       组起点位移 %.3f（%.3f/%.3f → %.3f/%.3f）" % [
		d, origin.x, origin.z, o1.x, o1.z])
	# 旧实现：拿飞行中的核心卡坐标当锚点，整摞落到 STACK_GAP.z*4 = 2.08 之外
	check(d < 0.02, "收拢后组起点不动（实际 %.3f）" % d)
	park(board, members)

# ---------- 4. AI 摞牌覆盖全部手牌 ----------

func _t4_ai_bench_pile(main: Node) -> void:
	print("--- 4. AI 没编进组合的牌也要进摞 ---")
	# 直接塞两张编不进组合的牌：一张 Buff（没有可贴的组合）、一张缺料的生产卡
	var uid := 9700
	for def_id in ["jiangjia", "yunketang"]:
		var c: Dictionary = main.state.add_card(GameState.AI, def_id)
		main._spawn_entity(c, Vector3(6.0, 0.05, -6.0), false)
		uid += 1
	main.layout._layout_ai_zone()
	# _layout_ai_zone 的补间是 0.3s，等它跑完再量间距（TRANS_BACK 中途会过冲）
	await create_timer(0.45).timeout
	for i in 4:
		await physics_frame

	var loose: Array = []
	for c in main.state.players[GameState.AI]["cards"]:
		if not main.layout._ai_pile_of_uid.has(c["uid"]):
			loose.append(CardDB.card_name(c["def_id"]))
	check(loose.is_empty(), "AI 每张牌都登记进了某个摞（游离：%s）" % [
		"无" if loose.is_empty() else ", ".join(loose)])

	# 备牌摞按卡面分：**不同的卡各占一摞**，同一张卡的几份才收拢在一起。
	#
	# 这一段原先要求的是反的（「备牌摞是收拢摆放」，拿 jiangjia + yunketang
	# 两张**不同**的卡量相邻 z 间距 == COMPACT_GAP.z）—— 那正是报上来的
	# 「AI 整理后把组合牌都摞在一块儿看不清」：几种互不相同的核心卡收成一摞，
	# 只露得出最上面那一张，侧边那个 ×N 说得出有几张、说不出是哪几张。
	# 资源摞收拢是对的（20 张现金张张一样），备牌摞不是一回事
	var benches := {}
	for key in main.layout._ai_pile_uids:
		if str(key).begins_with("ai_bench"):
			benches[str(key)] = main.layout._ai_pile_uids[key]
	check(not benches.is_empty(), "存在备牌摞 ai_bench_*")
	# 两张不同的卡 → 两摞，各自一个席位
	var defs_per_pile: Array = []
	for key in benches:
		var ds := {}
		for u in benches[key]:
			if main.entities.has(u) and is_instance_valid(main.entities[u]):
				ds[main.entities[u].def_id] = true
		defs_per_pile.append(ds.size())
	var mixed: int = 0
	for d in defs_per_pile:
		if int(d) > 1:
			mixed += 1
	check(mixed == 0,
		"每一摞备牌只装同一张卡（%d 摞里有 %d 摞混装）" % [benches.size(), mixed])
	check(benches.size() == 2,
		"两张不同的卡分成了两摞（实为 %d 摞）" % benches.size())
	# 两摞之间不许互相盖住 —— 分了摞却摆在同一个 x 的话，屏幕上还是一张
	var bxs: Array = []
	for key in benches:
		var arr: Array = benches[key]
		if not arr.is_empty() and main.entities.has(arr[0]):
			bxs.append(main.entities[arr[0]].position.x)
	bxs.sort()
	var min_dx := INF
	for i in range(1, bxs.size()):
		min_dx = minf(min_dx, absf(float(bxs[i]) - float(bxs[i - 1])))
	check(bxs.size() < 2 or min_dx >= CardEntity.CARD_SIZE.x - 0.02,
		"两摞备牌横向不互相盖住（最近的两摞相距 %.2f ≥ %.2f）" % [
			min_dx, CardEntity.CARD_SIZE.x])

	# 同一张卡的几份仍然收拢成一摞、带台阶：这是资源摞那条口径，没变
	var same: Dictionary = main.state.add_card(GameState.AI, "jiangjia")
	main._spawn_entity(same, Vector3(6.0, 0.05, -6.0), false)
	main.layout._layout_ai_zone()
	await create_timer(0.45).timeout
	for i in 4:
		await physics_frame
	var twin: Array = []
	for key in main.layout._ai_pile_uids:
		var arr2: Array = main.layout._ai_pile_uids[key]
		if not str(key).begins_with("ai_bench") or arr2.size() < 2:
			continue
		twin = arr2
	check(twin.size() == 2, "同一张卡的两份收在一摞里（实为 %d 张）" % twin.size())
	if twin.size() >= 2:
		var e0: CardEntity = main.entities[twin[0]]
		var e1: CardEntity = main.entities[twin[1]]
		var dz: float = absf(e0.position.z - e1.position.z)
		check(absf(dz - Board.COMPACT_GAP.z) < 0.01,
			"同卡那一摞是收拢摆放（相邻 z 间距 %.3f ≈ %.3f）" % [dz, Board.COMPACT_GAP.z])
		check(e0.position.y > e1.position.y, "摞顶那张在上面（y 更大）")

# ---------- 5. 队首那张自己也在飞的时候双击 ----------

## _layout_group 里 base.z 会被钳回桌面边界，这一钳会让队首那张也动起来
## （平时队首的目标就是它自己的现位置，不动）。趁这条补间在飞时双击：
## 不 snap 到补间终点就会拿飞行中的中间坐标当组起点，整摞落在半路上
func _t5_toggle_after_clamp(main: Node, board: Board) -> void:
	print("--- 5. 长牌列被钳回边界、补间在飞时双击 ---")
	var members := make_stack(main, board, 9800, "yunketang", 8)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	# 摆到近边外侧：8 张摊开跨度 7×0.52 = 3.64，起点 4.0 会被钳到 max_z - span
	members[0].global_position = Vector3(-6.0, 0.05, 4.0)
	var span: float = Board.STACK_GAP.z * (members.size() - 1)
	var want_z: float = board.player_max_z - span
	board._layout_group(g)   # 这一下把整列往 -z 钳，队首那张也跟着飞
	check(absf(board._move_tw[members[0]]["to"].z - want_z) < 0.01,
		"队首被钳到 %.3f（补间终点 %.3f）" % [want_z, board._move_tw[members[0]]["to"].z])
	# 一帧都不等，趁补间在飞时双击
	check(board.toggle_compact(members[0]), "补间在飞时双击收拢")
	await settle()
	var o: Vector3 = board._group_origin(board.group_of(members[0]))
	print("       收拢后组起点 z：%.3f（应为钳后的 %.3f）" % [o.z, want_z])
	check(absf(o.z - want_z) < 0.02,
		"组起点落在钳后的位置，不是补间半路（实际 %.3f / 期望 %.3f）" % [o.z, want_z])
	park(board, members)