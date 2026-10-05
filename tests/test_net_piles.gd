# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 联网局里**摞分组的可见性**：真端口 + 真场景。
##
## 钉的那件事：我在行动阶段把牌摞起来，对手当场就该看见那是一摞。
##
## 为什么必须有这一条 —— 摞是**表现状态**，引擎里不存在：
## 玩家侧的摞存在 board.groups（一个装 CardEntity 的数组），
## 要到收手那一刻才由 main._register_player_combos 变成 create_combo。
## 而对手区的形态是收方**重建**出来的（settle_layout._bot_piles 按
## state.combos + 闲置资源分堆）。两件事合起来的后果是：
## 我摞了半天，对面看见的是牌被拖过去、然后**弹回资源堆** ——
## 因为在他那份 state 里那几张牌确实还是散卡。
##
## 拖拽广播盯不到这个：它只在手里拿着的那几十帧有效，
## 松手之后就归布局说话了（scenes/board.gd 的表现分组）。
## 所以这里要的是一条独立的分组通道（Protocol.PILES），而这条判据
## 从**发送端的 board.groups** 一路走到**接收端的 _bot_piles()**。
##
## 和另外几条 net 判据的分工：
##   - test_protocol       ：无端口，钉信封的往返（piles 的 uid 掰不掰回 int）
##   - test_net_socket     ：真端口，钉 net_transport.gd 的收发
##   - test_net_client     ：真端口 + 真场景，钉 begin_net_game 那几条路
##   - test_net_attack_flow：真端口 + 真场景，钉攻击回合的换手
##   - **这一条**          ：真端口 + 真场景，钉「摞了对面看得见」
##
## 变异提示（tools/mutate_check.py 登记的那几条打在这里）：
##   1. main._push_piles 里的指纹比较改成永远相等 → T1 收不到分组
##   2. Protocol.pile_lists 不掰 int → T2 的 _bot_pile_of_uid 查不着（float 键）
##   3. settle_layout._declared_piles 不剔 claimed → T3 同一张牌摆两次
##   4. _collect_idle_units 忽略 extra_grouped → T2 那几张同时躺在资源堆里
##   5. is_front_pile 不认 bot_group_ → T4 声明摞掉到后行的资源席位上
##   6. 指纹不带位置 / 收方不认位置 → T7 两头各钉一条
##   7. 收方无条件 core_first_order → T8 摊开的摞两个视角次序不一样

const PORT_BASE := 47340
const A := GameState.PLAYER
const B := GameState.BOT

## 后台协程的完成标志。**必须是成员变量** —— GDScript 的 lambda 按值捕获
## 外层局部量，`var done := false` + `func(): done = true` 那次赋值写在副本上，
## 外层永远读到 false（test_net_attack_flow 的同一条注释里有实测经过）
var _flag := false

func _initialize() -> void:
	print("=== 联网局摞分组测试 ===")
	CardDB.ensure_loaded()
	await _t1_my_pile_reaches_the_foe()
	await _t2_declared_pile_becomes_a_foe_pile()
	await _t3_combo_wins_over_declaration()
	await _t4_declared_pile_sits_in_the_front_row()
	await _t5_stale_uids_are_ignored()
	await _t6_compact_matches_both_ways()
	await _t7_position_matches_both_ways()
	await _t8_order_matches_both_ways()
	net_stop()
	finish()

# ---------- 服务器 / 客户端（与 test_net_client 同法，端口段错开） ----------
func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null

## 一份真场景 + 一条真连接坐 A 座，b 是光秃秃的一条连接（替对手收发）。
## 和 test_net_attack_flow._seated_scene 同法
func _seated_scene(seed_value: int, room_code: String) -> Array:
	return await net_seated_scene(PORT_BASE, seed_value, room_code, A)

## 场景那一侧（A 座）名下的前 n 张现金卡实体
func _my_cash(main: Node, n: int) -> Array:
	var out: Array = []
	for c in main.state.players[main.my_seat]["cards"]:
		if out.size() >= n:
			break
		var d: Dictionary = CardDB.get_def(c["def_id"])
		if d.get("kind") != CardDB.KIND_UNIT or d.get("res") != CardDB.RES_CASH:
			continue
		if main.entities.has(c["uid"]) and is_instance_valid(main.entities[c["uid"]]):
			out.append(main.entities[c["uid"]])
	return out

## 对手（B 座）名下的前 n 张现金卡 uid。**从服务器那份状态取** ——
## 对手的牌在我这边也有实体（照快照摆的），uid 两侧同一套
func _foe_cash_uids(main: Node, n: int) -> Array:
	var out: Array = []
	for c in main.state.players[main.foe_seat]["cards"]:
		if out.size() >= n:
			break
		var d: Dictionary = CardDB.get_def(c["def_id"])
		if d.get("kind") == CardDB.KIND_UNIT and d.get("res") == CardDB.RES_CASH:
			out.append(int(c["uid"]))
	return out

## 配方最小的那张生产卡。挑最小的是为了少加几张牌 ——
## 加的每一张都要有实体才进得了摞（见 _declared_piles 的过滤）
func _smallest_producer() -> String:
	var out := ""
	var best := 999
	for id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(id)
		if d.get("kind") != CardDB.KIND_PRODUCT:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n < best:
			best = n
			out = str(id)
	return out

## 对手区当前的摞：key → uid 数组
func _foe_piles_now(main: Node) -> Dictionary:
	var out := {}
	for p in main.layout._bot_piles():
		out[str(p["key"])] = (p["cards"] as Array).map(
			func(e: CardEntity) -> int: return int(e.uid))
	return out

## 声明摞（bot_group_*）的 key 列表
func _group_keys(piles: Dictionary) -> Array:
	var out: Array = []
	for k in piles:
		if str(k).begins_with("bot_group_"):
			out.append(str(k))
	out.sort()
	return out

# ---------- T1 我摞起来的牌要发出去 ----------

## 发送端那一半：board.groups 变了 → 一条 piles 上线 → 对手收到。
##
## 摞用 board.make_group 造（和 test_dblclick_pile 同法）：那是 board 自己的
## 编组入口，摞的字典形状由它说 —— 手写一个 {cards: [...]} 的话，
## 「board 换了组的内部形状」这类改动在这条判据里会静默通过，
## 而 main.my_pile_lists 正是读那个形状
func _t1_my_pile_reaches_the_foe() -> void:
	print("\n-- T1 我摞的牌，对手收得到 --")
	var trio := await _seated_scene(4242, "PAAA")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# 对手那一侧收到的分组记下来。b 是光秃秃的连接，没有场景 ——
	# 所以直接听它的信号，收到什么就是对面场景会拿到什么
	var got: Array = []
	b.foe_piles.connect(func(msg: Dictionary): got.append(msg))

	# 开局桌上本来就有摞（那两片资源牌是分好组摊开的），所以判的是
	# **多出来的那一摞**，不是「一共几摞」。等第一条广播先落地，
	# 拿它当基线 —— 开局那一份分组本身也是要发出去的
	if not await net_until([a, b], func(): return not got.is_empty()):
		check(false, "开局那份分组先发了出去")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var base: int = (got[-1].get("piles", []) as Array).size()
	check(base > 0, "开局那份分组里就有摞（%d 摞）" % base)

	var cards := _my_cash(main, 3)
	if not need(cards.size() == 3, "手里有三张现金卡可摞（实为 %d）" % cards.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var want: Array = cards.map(func(e: CardEntity) -> int: return int(e.uid))
	want.sort()

	# 这三张可能已经在开局的某个组里（资源牌是分好组的）：先摘出来，
	# 否则 make_group 之后它们同时属于两个组
	for c in cards:
		main.board._detach_from_group(c)
	var n0 := got.size()
	var g: Dictionary = main.board.make_group(cards.duplicate())
	main.board.groups.append(g)
	# _push_piles 挂在 _process 上：摇几帧让它比出指纹变化并发出去
	await net_until([a, b], func(): return got.size() > n0)

	if not need(got.size() > n0, "摞好之后又发了一条（还是 %d 条）" % got.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	check(true, "摞好之后对手又收到一条分组广播")
	var piles: Array = got[-1].get("piles", [])
	# 找那一摞：uid 集合完全相等才算。「包含」的话，那三张被并进
	# 一个更大的现金摞也会算通过 —— 而那正是这个 bug 的症状之一
	var found: Array = []
	for p in piles:
		var us: Array = (p as Dictionary).get("uids", []).duplicate()
		us.sort()
		if us == want:
			found = us
	check(found == want, "广播里有一摞正好是我摞的那三张（收到 %s，摞的是 %s）"
		% [str(piles), str(want)])
	# 每一摞都是 { uids, compact } 的形状（Protocol.pile_lists 归一化过）——
	# 收方直接读 g["uids"]，形状漂了的话它读到的是空名单
	var shaped := true
	for p in piles:
		if not (p is Dictionary) or not (p as Dictionary).has("uids") \
				or not (p as Dictionary).has("compact"):
			shaped = false
	check(shaped, "每一摞都带 uids 和 compact（收到 %s）" % str(piles))
	# uid 过一趟 JSON 会变 double，而收方拿它当字典键 —— 这里当场验类型
	var all_int := true
	for p in piles:
		for u in (p as Dictionary).get("uids", []):
			if typeof(u) != TYPE_INT:
				all_int = false
	check(all_int, "收到的 uid 都是 int 而不是 float")

	# 刚 make_group 出来的摞是摊开的（make_group 的 compact 默认 false）
	var mine: Dictionary = {}
	for p in piles:
		var us: Array = (p as Dictionary).get("uids", []).duplicate()
		us.sort()
		if us == want:
			mine = p
	check(not bool(mine.get("compact", true)),
		"刚摞出来那一摞报的是摊开（compact=%s）" % str(mine.get("compact", null)))

	# 分组**没变**的时候不该反复发：_push_piles 每帧都会算一遍
	var n1 := got.size()
	await net_pump([a, b], 30)
	check(got.size() == n1, "分组没变就不再发（30 帧后仍是 %d 条）" % got.size())

	# **双击收拢要发出去**。这一条是个 bug 修回来的：收拢/摊开只翻 g["compact"]，
	# uid 名单一个字都不变 —— 指纹不带 compact 的话这一下的指纹和上一份完全相同，
	# 一条都不发，对手那边什么反应都没有。而这是玩家最直观的一个动作
	main.board.toggle_compact(cards[0])
	check(bool(g.get("compact", false)), "双击之后我这边这一摞是收拢的")
	if not await net_until([a, b], func(): return got.size() > n1):
		check(false, "收拢之后发了一条（还是 %d 条）" % got.size())
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	check(true, "收拢之后又发了一条广播")
	var c_state: Variant = null
	for p in got[-1].get("piles", []):
		var us: Array = (p as Dictionary).get("uids", []).duplicate()
		us.sort()
		if us == want:
			c_state = bool((p as Dictionary).get("compact", false))
	check(c_state == true, "广播里那一摞报的是收拢（compact=%s）" % str(c_state))

	# 再双击回来：**摊开也要发**。收拢那一下顺手 _core_first 重排了名单，
	# 所以光靠「名单变了」也能把收拢发出去 —— 而摊开**不重排**
	# （toggle_compact 只在收拢时调 _core_first），名单彻底不变。
	# 只钉收拢的话这一条会漏：收拢看得见、摊开看不见
	var n2 := got.size()
	main.board.toggle_compact(cards[0])
	check(not bool(g.get("compact", true)), "再双击之后我这边这一摞摊开了")
	if not await net_until([a, b], func(): return got.size() > n2):
		check(false, "摊开之后发了一条（还是 %d 条）" % got.size())
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	check(true, "摊开之后又发了一条广播")
	var s_state: Variant = null
	for p in got[-1].get("piles", []):
		var us: Array = (p as Dictionary).get("uids", []).duplicate()
		us.sort()
		if us == want:
			s_state = bool((p as Dictionary).get("compact", false))
	check(s_state == false, "广播里那一摞报的是摊开（compact=%s）" % str(s_state))

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T2 对手摞起来的牌，我这边摆成一摞 ----------

## 接收端那一半，也是这个 bug 玩家真正看得见的那一面：
## 对手声明的分组要变成对手区的一摞，而且那几张**不能同时**还躺在资源堆里。
##
## 走真的 send_piles → 服务器转发 → main.on_foe_piles，不是直接给
## main.foe_piles 赋值：那样测的就只是 _bot_piles 一个函数，
## 而这条 bug 的一半在「有没有人把这件事发出来 / 转过来」
func _t2_declared_pile_becomes_a_foe_pile() -> void:
	print("\n-- T2 对手摞的牌，我这边摆成一摞 --")
	var trio := await _seated_scene(515, "PBBB")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	var before := _foe_piles_now(main)
	check(_group_keys(before).is_empty(), "一开始对手区没有声明摞（%s）"
		% str(_group_keys(before)))

	var uids := _foe_cash_uids(main, 3)
	if not need(uids.size() == 3, "对手名下有三张现金卡（实为 %d）" % uids.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return

	b.send_piles([uids])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "分组到了我这边（main.foe_piles=%s）" % str(main.foe_piles))
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	check(true, "分组到了我这边")

	var piles := _foe_piles_now(main)
	var keys := _group_keys(piles)
	if not need(keys.size() == 1, "对手区多出正好一摞声明摞（实为 %s）" % str(keys)):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var got: Array = Array(piles[keys[0]])
	got.sort()
	var want := uids.duplicate()
	want.sort()
	check(got == want, "那一摞正好是他声明的那几张（摞里 %s，声明的 %s）"
		% [str(got), str(want)])

	# **这一条是 bug 的正脸**：不剔的话这几张同时还在 bot_cash_0 里，
	# 两处布局抢着摆同一张牌，后摆的赢 —— 玩家看见的就是「摞了一下又弹回去」
	var in_res: Array = []
	for k in piles:
		if str(k).begins_with("bot_group_"):
			continue
		for u in piles[k]:
			if want.has(int(u)):
				in_res.append(int(u))
	check(in_res.is_empty(), "那几张不再躺在资源摞里（重复出现的：%s）" % str(in_res))

	# 点选要认得这一摞：收拢摞在攻击阶段是按 key 整摞点的（main._attack_pile）
	var mapped := 0
	for u in want:
		if str(main.layout._bot_pile_of_uid.get(u, "")).begins_with("bot_group_"):
			mapped += 1
	check(mapped == want.size(), "摞里每张都登记到了这一摞的 key（%d/%d）"
		% [mapped, want.size()])

	# 撤销分组（发一份空名单）之后要回到资源摞
	b.send_piles([])
	await net_until([a, b], func(): return main.foe_piles.is_empty())
	var after := _foe_piles_now(main)
	check(_group_keys(after).is_empty(), "撤销分组之后声明摞没了（%s）"
		% str(_group_keys(after)))
	var back := 0
	for k in after:
		for u in after[k]:
			if want.has(int(u)):
				back += 1
	check(back == want.size(), "那几张回到了资源摞（%d/%d）" % [back, want.size()])

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T3 编成了的组合压过声明 ----------

## 同一批牌既在 state.combos 里、又在对手声明的分组里时，组合说话。
##
## 这不是假想的顺序问题：对手收手那一刻 _register_player_combos 把他的摞
## 变成真组合，而他那边的分组广播还是上一份（摞没变，指纹没变，不重发）——
## 于是这一瞬间两份表述**必然**同时存在。剔不掉的话同一张牌被摆两次
func _t3_combo_wins_over_declaration() -> void:
	print("\n-- T3 组合压过声明 --")
	var trio := await _seated_scene(909, "PCCC")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# 一份能过 ComboRules 的料：配方最小的生产卡 + 它要的单位卡。
	# 光三张现金卡编不成组合（create_combo 走 ComboRules.evaluate，
	# 没核心卡直接 invalid）—— 那样这一条测的就成了「编组失败时怎样」
	var core_id := _smallest_producer()
	if not need(core_id != "", "找得到一张生产卡"):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var d: Dictionary = CardDB.get_def(core_id)
	var uids: Array = [int(main.state.add_card(main.foe_seat, core_id)["uid"])]
	var unit := "cash" if str(d.get("recipe_res")) == CardDB.RES_CASH else "user"
	for i in int(d.get("recipe_n", 0)):
		uids.append(int(main.state.add_card(main.foe_seat, unit)["uid"]))
	# 新加的牌要有实体，否则 _bot_piles 会把它们整批跳过（那一条过滤在 T5 里钉着）
	main._sync_entities()
	await net_pump([a, b], 10)

	# 先声明，再把同一批牌在**我这份状态**里编成组合。
	# 直接改 main.state 而不是走服务器：这一条钉的是 _bot_piles 的取舍，
	# 而「组合怎么过网」由 test_net_attack_flow 的 T2 钉着
	b.send_piles([uids])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "分组到了我这边")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var made: Dictionary = main.state.create_combo(main.foe_seat, uids.duplicate())
	if not need(made.get("ok", false), "这几张编成了组合（%s）"
			% made.get("reason", "")):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return

	var piles := _foe_piles_now(main)
	check(_group_keys(piles).is_empty(),
		"这几张已经编成组合了，就不再当声明摞（声明摞：%s）" % str(_group_keys(piles)))
	var combo_keys: Array = []
	for k in piles:
		if str(k).begins_with("bot_combo_"):
			combo_keys.append(str(k))
	check(combo_keys.size() == 1, "它们现在是一个组合摞（实为 %s）" % str(combo_keys))
	# 一张牌只该出现在一摞里 —— 整个对手区扫一遍
	var seen := {}
	var dup: Array = []
	for k in piles:
		for u in piles[k]:
			if seen.has(int(u)):
				dup.append(int(u))
			seen[int(u)] = true
	check(dup.is_empty(), "对手区没有一张牌被摆进两摞（重复的：%s）" % str(dup))

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T4 声明摞坐前行 ----------

## 声明摞和组合同属「对手自己摆出来的分组」，该坐前行。
## 掉到后行的话它会摆在资源摞的固定席位上，两片牌互相压边 ——
## 而那三个席位的 x 是按 key 前缀挑的（_layout_bot_zone 后半段）
func _t4_declared_pile_sits_in_the_front_row() -> void:
	print("\n-- T4 声明摞坐前行 --")
	var trio := await _seated_scene(1717, "PDDD")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# is_front_pile 是静态的，但 settle_layout.gd 没有 class_name（见文件头
	# 那句「全局可见的是 CardEntity/Board/CardArt」），所以从实例上调
	var L = main.layout
	check(L.is_front_pile("bot_combo_0"), "组合摞算前行")
	check(L.is_front_pile("bot_group_0"), "声明摞算前行")
	check(not L.is_front_pile("bot_cash_0"), "现金摞不算前行")
	check(not L.is_front_pile("bot_user_0"), "用户摞不算前行")
	check(not L.is_front_pile("bot_bench_0"), "备牌摞不算前行")

	var uids := _foe_cash_uids(main, 4)
	if not need(uids.size() == 4, "对手名下有四张现金卡（实为 %d）" % uids.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	b.send_piles([uids])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "分组到了我这边")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	await net_pump([a, b], 30)   # 让布局跑完补间

	# 前行 z = BOT_ROW_Z[0] = -4.1，后行 = BOT_ROW_Z[1] = -6.5 —— **越负越靠北**
	# （BOT 区北缘是 -7.6）。所以前行的牌 z 要比后行席位**大**。
	# 判相对关系而不是钉死坐标：组合摊开时每张沿 +z 长（见 combo_spread_step），
	# 钉死会把「摊开了」判成失败
	var zs: Array = []
	for u in uids:
		if main.entities.has(u) and is_instance_valid(main.entities[u]):
			zs.append(main.layout._rest_pos(main.entities[u]).z)
	if not need(zs.size() == uids.size(), "四张牌都还在场上（%d）" % zs.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var back_z: float = main.layout._bot_back_z(uids.size())
	var front := true
	for z in zs:
		if z < back_z + 0.01:
			front = false
	check(front, "声明摞摆在前行（摞的 z=%s 都该大于后行席位 z=%.2f）"
		% [str(zs), back_z])

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T5 名单里的脏 uid 不添乱 ----------

## 收方逐个 uid 查自己那份 state，查不着的静默跳过。三种来源：
## 牌刚被打掉（分组还是上一份）、发方编造 uid、以及**别人的牌** ——
## 转发这一层不校验归属（见 room.handle_piles），所以校验必须在这儿
func _t5_stale_uids_are_ignored() -> void:
	print("\n-- T5 名单里的脏 uid 不添乱 --")
	var trio := await _seated_scene(2323, "PEEE")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	var foe := _foe_cash_uids(main, 2)
	var mine: Array = []
	for e in _my_cash(main, 1):
		mine.append(int(e.uid))
	if not need(foe.size() == 2 and mine.size() == 1,
			"取到对手两张 + 我一张（%d / %d）" % [foe.size(), mine.size()]):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return

	# 一份掺了假的名单：两张真的 + 一个不存在的 uid + 一张**我的**牌
	b.send_piles([[foe[0], 999999, mine[0], foe[1]]])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "分组到了我这边")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return

	var piles := _foe_piles_now(main)
	var keys := _group_keys(piles)
	if not need(keys.size() == 1, "还是摆出了一摞（实为 %s）" % str(keys)):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var got: Array = Array(piles[keys[0]])
	got.sort()
	var want := foe.duplicate()
	want.sort()
	check(got == want, "摞里只剩对手真有的那两张（摞里 %s，期望 %s）"
		% [str(got), str(want)])
	# 我的牌**没被搬到对手区**：那是「改一个客户端就能把对手的牌摆到自己区」
	check(not main.layout._bot_pile_of_uid.has(mine[0]),
		"我的牌没被对手的名单收走（uid %d）" % mine[0])

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T6 收拢/摊开一一对应 ----------

## 这一摞在屏幕上是**收拢**还是**摊开**：看它的 z 跨度。
##
## 判跨度而不是钉坐标：收拢是 Board.COMPACT_GAP.z（0.05）一张，
## 摊开至少是标题带那条线（combo_band_step，实测 0.266）—— 差着五倍以上，
## 中间没有第三种形态。钉坐标的话「整片挪了一下」会被判成失败
func _z_span(main: Node, uids: Array) -> float:
	var lo := INF
	var hi := -INF
	for u in uids:
		if not main.entities.has(int(u)) or not is_instance_valid(main.entities[int(u)]):
			continue
		var z: float = main.layout._rest_pos(main.entities[int(u)]).z
		lo = minf(lo, z)
		hi = maxf(hi, z)
	return 0.0 if lo == INF else hi - lo

## 接收端那一半的收拢/摊开：对手说收拢我就摆收拢，说摊开我就摆摊开。
##
## 为什么单独一条而不是并进 T2：T2 钉的是「那几张牌进了同一摞」——
## 收拢和摊开在它眼里完全一样（两种形态下 _bot_pile_of_uid 都指向那一摞）。
## 而玩家双击时唯一看得见的反馈**就是**形态变了，这件事得有自己的判据。
##
## 这一条钉的其实是两个 bug 合起来的那个症状：
##   1. 发送端不发（指纹不带 compact）→ T1 后半段钉住
##   2. 收方不认（照几何自己猜）→ 这里钉住
## 只修一个的话玩家看到的还是「双击了，对面没反应」
func _t6_compact_matches_both_ways() -> void:
	print("\n-- T6 收拢/摊开一一对应 --")
	var trio := await _seated_scene(3131, "PFFF")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# 五张：按前行那份预算（combo_spread_step，实测 0.80）摊不开
	# —— 于是「照几何猜」必然猜成收拢，而对手说的是摊开。
	# 三张的话几何自己也会摊开，这一条就测不出收方认不认 compact 了
	var uids := _foe_cash_uids(main, 5)
	if not need(uids.size() == 5, "对手名下有五张现金卡（实为 %d）" % uids.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	check(main.layout.combo_spread_step(uids.size()) == 0.0,
		"这么多张按前行那份预算是摊不开的（所以几何会猜收拢）")

	# 指纹认不认这一位，**直接问指纹**：位置和形态在同一条指纹里，
	# 而双击收拢会同时改两样（摞短了，中点也就挪了）—— 于是「指纹不看
	# compact」这个漏能被位置那一位替着遮住：照旧发得出去，但发的理由错了。
	# 名单和位置都钉住、只翻这一位，问的就是这一位本身
	var same_pos := { "uids": uids, "u": 0.4, "v": 0.4 }
	var as_spread: Dictionary = same_pos.duplicate()
	as_spread["compact"] = false
	var as_compact: Dictionary = same_pos.duplicate()
	as_compact["compact"] = true
	check(main._piles_fingerprint([as_spread]) != main._piles_fingerprint([as_compact]),
		"指纹看得见收拢这一位（摊开 %s vs 收拢 %s）"
		% [main._piles_fingerprint([as_spread]), main._piles_fingerprint([as_compact])])

	# 摊开：明说 compact=false
	b.send_piles([{ "uids": uids, "compact": false }])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "分组到了我这边")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	await net_pump([a, b], 30)   # 让归位补间跑完
	var spread_span := _z_span(main, uids)
	var band: float = main.layout.combo_band_step()
	check(spread_span >= band - 0.0001,
		"他说摊开，我这边就摆成摊开（z 跨度 %.3f，至少要 %.3f）" % [spread_span, band])

	# 收拢：同一批牌，只翻 compact
	b.send_piles([{ "uids": uids, "compact": true }])
	if not await net_until([a, b], func():
			for g in main.foe_piles:
				if bool((g as Dictionary).get("compact", false)):
					return true
			return false):
		check(false, "收拢那一份到了我这边（foe_piles=%s）" % str(main.foe_piles))
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	await net_pump([a, b], 30)
	var compact_span := _z_span(main, uids)
	var want_span: float = Board.compact_offset(uids.size(), 0).z
	check(absf(compact_span - want_span) < 0.01,
		"他说收拢，我这边就摆成收拢（z 跨度 %.3f，收拢该是 %.3f）"
		% [compact_span, want_span])
	# 两种形态**真的不一样**。分别对着各自的期望值判过了，但那两条都可能
	# 因为「_rest_pos 一直返回同一个数」而同时为真 —— 这一条把它们对起来
	check(spread_span > compact_span + 0.1,
		"摊开确实比收拢长（摊开 %.3f > 收拢 %.3f）" % [spread_span, compact_span])

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T7 位置一一对应 ----------

## 一摞牌摆在哪儿，两边也该一一对应。
##
## 这一条钉的病：对手把一个组合拖到桌子左边还是右边，我这边看到的都是
## **同一个格子** —— 因为落点由收方的 _layout_bot_zone 按「第几摞 / 共几摞」
## 现算成整行居中（那边的 x0/pitch），发方压根没说过位置。
## 和 T6 是同一个形状的两个字段：形态和位置都是玩家亲手做的动作，
## 不是布局的自由度。
##
## 两头各钉一条，理由同 T6（只修一头的话症状还在）：
##   1. 发送端不发（my_pile_lists 不带 u/v，或者指纹不带位置 → 挪了不广播）
##   2. 收方不认（_layout_bot_zone 照旧现算格子）
##
## 位置判的是**相对关系**，不钉死坐标：一摞牌落在哪儿要过归一化、钳位、
## 摊开预算好几道，钉死等于把这几道的实现细节抄进判据里。
## 而这个 bug 的形状恰好是「两个不同的位置画成同一个点」——
## 那用「左边那份和右边那份不一样，且左右次序对得上」就能钉死
func _t7_position_matches_both_ways() -> void:
	print("\n-- T7 位置一一对应 --")
	var trio := await _seated_scene(5252, "PGGG")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# ---- 发送端：我挪了摞，广播里的位置要跟着变 ----
	var got: Array = []
	b.foe_piles.connect(func(msg: Dictionary): got.append(msg))
	if not await net_until([a, b], func(): return not got.is_empty()):
		check(false, "开局那份分组先发了出去")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return

	var cards := _my_cash(main, 3)
	if not need(cards.size() == 3, "手里有三张现金卡可摞（实为 %d）" % cards.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var want: Array = cards.map(func(e: CardEntity) -> int: return int(e.uid))
	want.sort()
	for c in cards:
		main.board._detach_from_group(c)
	var g: Dictionary = main.board.make_group(cards.duplicate())
	main.board.groups.append(g)
	if not await net_until([a, b], func(): return _pile_uv(got, want) != null):
		check(false, "摞好之后广播里带上了位置（收到 %s）"
			% str(got[-1].get("piles", []) if not got.is_empty() else []))
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var uv_left: Variant = _pile_uv(got, want)
	check(uv_left != null, "广播里那一摞带着位置（u/v）—— 不带的话收方只能现算格子")

	# 往右挪：整摞搬到玩家区右边，位置该重新播一次。
	# **直接写坐标**而不是模拟拖拽：这条判据问的是「位置进没进广播」，
	# 拖拽那条通道自己有判据（test_foe_drag）
	var n0 := got.size()
	_move_group(main, g, 6.0)
	if not await net_until([a, b], func():
			var uv: Variant = _pile_uv(got, want)
			return uv != null and absf((uv as Vector2).x - (uv_left as Vector2).x) > 0.05):
		check(false, "挪到右边之后又播了一条（%d → %d 条，位置 %s → %s）"
			% [n0, got.size(), str(uv_left), str(_pile_uv(got, want))])
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var uv_right: Variant = _pile_uv(got, want)
	# 这一条是「指纹不带位置」那个变异的观察点：名单和形态都没变，
	# 只有位置变了 —— 指纹不带位置的话这一下一条都不发
	check((uv_right as Vector2).x > (uv_left as Vector2).x,
		"往右挪 → 广播里的 u 变大（%.3f → %.3f）"
		% [(uv_left as Vector2).x, (uv_right as Vector2).x])

	# ---- 接收端：对手说的位置，我这边就摆在那儿 ----
	# 同一批牌、同一个形态，只换位置发两次，看我这边摆出来的 x 跟着换。
	# 用对手的牌（_foe_cash_uids）—— 上面那半段用的是我自己的牌
	var foe := _foe_cash_uids(main, 3)
	if not need(foe.size() == 3, "对手名下有三张现金卡（实为 %d）" % foe.size()):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return

	b.send_piles([{ "uids": foe, "compact": true, "u": 0.15, "v": 0.5 }])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "带位置的分组到了我这边")
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	await net_pump([a, b], 40)   # 让归位补间跑完
	var x_l := _pile_x(main, foe)

	b.send_piles([{ "uids": foe, "compact": true, "u": 0.85, "v": 0.5 }])
	if not await net_until([a, b], func():
			for p in main.foe_piles:
				if absf(float((p as Dictionary).get("u", -1.0)) - 0.85) < 0.01:
					return true
			return false):
		check(false, "第二份位置到了我这边（foe_piles=%s）" % str(main.foe_piles))
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	await net_pump([a, b], 40)
	var x_r := _pile_x(main, foe)

	# **核心那条**：两个不同的 u 摆出两个不同的 x。收方不认位置的话
	# 两次都是整行居中那一个格子，这里两个数完全相同
	check(absf(x_r - x_l) > 1.0,
		"他把摞挪到别处，我这边也跟着挪（u=0.15 → x=%.2f，u=0.85 → x=%.2f）"
			% [x_l, x_r]
		+ " —— 两个数一样就是收方在按「第几摞」现算格子")
	check(x_r > x_l, "u 大的摆得更靠右（%.2f > %.2f）—— 反了的话对手往右挪，"
		% [x_r, x_l] + "我看到的是往左")

	# 位置**不能**把牌摆出对手半区：他那边可以贴着自己镜头那条边摆，
	# 镜像过来就是贴着我这边的北缘（_pile_anchor_at 的钳位）
	b.send_piles([{ "uids": foe, "compact": true, "u": 0.5, "v": 1.0 }])
	await net_pump([a, b], 40)
	var zs: Array = []
	for u in foe:
		if main.entities.has(int(u)) and is_instance_valid(main.entities[int(u)]):
			zs.append(main.layout._rest_pos(main.entities[int(u)]).z)
	var inside := true
	for z in zs:
		if z < main.layout.BOT_FAR_Z_MIN - 0.01 or z > main.layout.BOT_FAR_Z_MAX + 0.01:
			inside = false
	check(inside, "贴边的位置也钳在对手半区里（z=%s 要落在 [%.1f, %.1f]）"
		% [str(zs), main.layout.BOT_FAR_Z_MIN, main.layout.BOT_FAR_Z_MAX])

	# 锚点是整摞的**中点**，不是某一端。同一个位置、只换形态发两次，
	# 摆出来的中点该重合 —— 而两端的跨度不一样（收拢 0.05/张、摊开 0.52/张）。
	#
	# 拿端点当锚点的话这两次会差半个摞长：玩家双击收拢时那一摞在对手屏幕上
	# 平移一下，而收拢是**原地**的动作。z 取桌子中间（v=0.5）留出摊开的余量，
	# 免得钳位把两次都按到同一条边上、把这条判据变成空转
	b.send_piles([{ "uids": foe, "compact": true, "u": 0.5, "v": 0.5 }])
	await net_pump([a, b], 40)
	var mid_c := _pile_z_mid(main, foe)
	b.send_piles([{ "uids": foe, "compact": false, "u": 0.5, "v": 0.5 }])
	await net_pump([a, b], 40)
	var mid_s := _pile_z_mid(main, foe)
	# 先确认这两次形态真的不一样，否则下面那条是空转
	check(_z_span(main, foe) > Board.compact_offset(foe.size(), 0).z + 0.1,
		"这两次的形态真的不一样（摊开跨度 %.3f > 收拢 %.3f）"
		% [_z_span(main, foe), Board.compact_offset(foe.size(), 0).z])
	check(absf(mid_s - mid_c) < 0.2,
		"收拢和摊开摆在同一个中点（收拢 %.2f / 摊开 %.2f）—— 拿摞的某一端"
			% [mid_c, mid_s]
		+ "当锚点的话，双击一下那一摞会在对手屏幕上平移半个摞长")

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

# ---------- T8 次序一一对应 ----------

## 一摞里的牌**按什么次序**排，两边也该一一对应。
##
## 这一条钉的病，玩家的原话是「从对方视角看一个组合里面牌的顺序不同，
## 并且提起组合后，首张牌居然还会变化」。两句是同一个根因的两面：
## 收方（_declared_piles / _bot_piles）无条件跑一遍 Board.core_first_order。
##
##   1. 次序不一样：发方的规矩是**只有收拢才提核心卡**
##      （board.toggle_compact → _core_first）。摊开态队首是露得最少的那张
##      （Board._top_index 摊开取队尾），把核心卡挪过去反而看不清。
##      收方无条件重排 → 摊开的摞在两个视角里次序不同，
##      而 uids 里带着的**就是**他屏幕上的次序
##   2. 首张牌会变：收方那圈过滤会剔掉租出去的 uid（is_drag_leased），
##      无条件重排是在**剩下这个子集**上算的 —— 他从摞里拎起几张，
##      我这边余下那几张的次序重算一次，首张牌当场换人。
##      照发方的次序摆就没有这个洞：剔掉几张，余下的相对次序不变
##
## 料要挑得能看出次序：一摞全是现金卡的话 core_first_order 是恒等变换
## （全是 KIND_UNIT，都进 rest），次序怎么排都一样 —— T6 那五张现金卡
## 正是这种情况，所以这条判据不能挂在那儿。这里要一张核心卡 + 几张单位卡，
## 且核心卡**不在队首**：那样「照原样」和「提到队首」才是两个不同的答案
func _t8_order_matches_both_ways() -> void:
	print("\n-- T8 次序一一对应 --")
	var trio := await _seated_scene(6363, "PHHH")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# 核心卡夹在中间：uids = [单位, 核心, 单位, 单位]。
	# 「照原样」头一张是单位卡，「提到队首」头一张是核心卡
	var core_id := _smallest_producer()
	if not need(core_id != "", "找得到一张生产卡"):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	var d: Dictionary = CardDB.get_def(core_id)
	var unit := "cash" if str(d.get("recipe_res")) == CardDB.RES_CASH else "user"
	var units: Array = []
	for i in 3:
		units.append(int(main.state.add_card(main.foe_seat, unit)["uid"]))
	var core_uid := int(main.state.add_card(main.foe_seat, core_id)["uid"])
	var uids: Array = [units[0], core_uid, units[1], units[2]]
	# 新加的牌要有实体，否则 _bot_piles 整批跳过（那条过滤在 T5 里钉着）
	main._sync_entities()
	await net_pump([a, b], 10)

	await _t8_spread_keeps_order(main, a, b, uids, core_uid)
	await _t8_compact_lifts_core(main, a, b, uids, core_uid)
	await _t8_head_survives_a_lease(main, a, b, uids)

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

## 摊开：照他说的次序摆，一个字都不动。
## 核心卡夹在中间发过来，我这边看到的头一张就该还是那张单位卡
func _t8_spread_keeps_order(main: Node, a: NetTransport, b: NetTransport,
		uids: Array, core_uid: int) -> void:
	b.send_piles([{ "uids": uids, "compact": false }])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "摊开那一份到了我这边")
		return
	await net_pump([a, b], 10)
	var got := _t8_pile_order(main, uids)
	check(got == uids,
		"摊开的摞照他说的次序摆（他说 %s，我这边 %s）—— 收方无条件"
			% [str(uids), str(got)]
		+ "core_first_order 的话，同一摞牌在两个视角里次序不一样")
	check(not got.is_empty() and int(got[0]) != core_uid,
		"摊开态首张牌不是核心卡（实为 %s，核心卡是 %d）—— 摊开态队首露得最少，"
			% [str(got[0]) if not got.is_empty() else "空", core_uid]
		+ "把核心卡挪过去等于把它藏起来")

## 收拢：这一侧要提核心卡。规矩和发方逐字相同 —— 他那边收拢时
## board._core_first 也会把核心卡挪到队首，摞顶露的就该是它
func _t8_compact_lifts_core(main: Node, a: NetTransport, b: NetTransport,
		uids: Array, core_uid: int) -> void:
	b.send_piles([{ "uids": uids, "compact": true }])
	if not await net_until([a, b], func():
			for g in main.foe_piles:
				if bool((g as Dictionary).get("compact", false)):
					return true
			return false):
		check(false, "收拢那一份到了我这边（foe_piles=%s）" % str(main.foe_piles))
		return
	await net_pump([a, b], 10)
	var got := _t8_pile_order(main, uids)
	check(not got.is_empty() and int(got[0]) == core_uid,
		"收拢态核心卡在摞顶（次序 %s，核心卡是 %d）—— 收拢只露得出最上面"
			% [str(got), core_uid]
		+ "那一张，露的得是说明得了阵型的那张核心卡")
	# 集合没变：提核心卡是**重排**，不是筛选
	var sorted_got := got.duplicate()
	sorted_got.sort()
	var sorted_want := uids.duplicate()
	sorted_want.sort()
	check(sorted_got == sorted_want,
		"提核心卡只换次序，不丢牌（%s vs %s）" % [str(sorted_got), str(sorted_want)])

## 他从摞里拎起一张：我这边余下那几张的**次序不变**，首张牌不换人。
##
## 拎起来的那张走拖拽租约（main.is_drag_leased），收方那圈过滤会把它剔掉。
## 无条件重排是在剩下的子集上算的 —— 剔掉的恰好是队首时，
## 重排会从余下的牌里挑出一个新队首，玩家看到的是「他一提起来，
## 我这边这摞的头一张换了」
func _t8_head_survives_a_lease(main: Node, a: NetTransport, b: NetTransport,
		uids: Array) -> void:
	b.send_piles([{ "uids": uids, "compact": false }])
	if not await net_until([a, b], func(): return not main.foe_piles.is_empty()):
		check(false, "摊开那一份回到了我这边")
		return
	await net_pump([a, b], 10)
	var before := _t8_pile_order(main, uids)
	if not need(before.size() == uids.size(),
			"租约之前整摞都在（%s）" % str(before)):
		return
	# 他把队首那张拎起来。租约由拖拽通道开（同 _declared_piles 读的那一份）
	b.send_drag(Protocol.DRAG_PICKUP, [int(uids[0])], 0.5, 0.5)
	if not await net_until([a, b], func(): return main.is_drag_leased(int(uids[0]))):
		check(false, "拎起那一张的租约到了我这边")
		return
	await net_pump([a, b], 10)
	var after := _t8_pile_order(main, uids)
	# 余下的相对次序：把拎走那张从原名单里剔掉，剩下的该逐个对得上
	var want: Array = uids.slice(1)
	check(after == want,
		"拎走一张之后，余下的次序不变（该是 %s，实为 %s）—— 在子集上重排的话"
			% [str(want), str(after)]
		+ "首张牌会当场换人，而他那边一个字都没改")
	b.send_drag(Protocol.DRAG_CANCEL, [int(uids[0])], 0.5, 0.5)
	await net_pump([a, b], 6)

## 我这边把这几张牌摆成的那一摞，**当前次序**（uid 数组）。
## 只认这几张里出现的：租出去的那张会被 _bot_piles 剔掉，那正是要看的
func _t8_pile_order(main: Node, uids: Array) -> Array:
	var want := {}
	for u in uids:
		want[int(u)] = true
	for p in main.layout._bot_piles():
		var got: Array = []
		for e in (p["cards"] as Array):
			if want.has(int(e.uid)):
				got.append(int(e.uid))
		if not got.is_empty():
			return got
	return []

## 广播里那一摞（uid 集合等于 want）的位置，没带位置返回 null。
## 从**最后一条**广播里找：位置会连着播几条（拖动途中），要的是最终那一份
func _pile_uv(got: Array, want: Array) -> Variant:
	if got.is_empty():
		return null
	for p in (got[-1].get("piles", []) as Array):
		var us: Array = (p as Dictionary).get("uids", []).duplicate()
		us.sort()
		if us != want:
			continue
		if not (p as Dictionary).has("u") or not (p as Dictionary).has("v"):
			return null
		return Vector2(float((p as Dictionary)["u"]), float((p as Dictionary)["v"]))
	return null

## 我这边把这几张牌摆成的那一摞，z 向的中点（最南 + 最北 的一半）。
## 取**两端的中点**而不是平均值：摊开态每张等距、平均值等于中点，
## 但收拢态的偏移不是等距的（compact_offset 逐张递减），
## 平均值会偏向密的那一头 —— 而发送端发的正是两端的中点
func _pile_z_mid(main: Node, uids: Array) -> float:
	var lo := INF
	var hi := -INF
	for u in uids:
		if not main.entities.has(int(u)) or not is_instance_valid(main.entities[int(u)]):
			continue
		var z: float = main.layout._rest_pos(main.entities[int(u)]).z
		lo = minf(lo, z)
		hi = maxf(hi, z)
	return 0.0 if lo == INF else (lo + hi) / 2.0

## 我这边把这几张牌摆在哪（x 的平均值）。取平均而不是某一张：
## 收拢和摊开时「哪张在摞顶」不一样，平均值和形态无关
func _pile_x(main: Node, uids: Array) -> float:
	var sum := 0.0
	var n := 0
	for u in uids:
		if main.entities.has(int(u)) and is_instance_valid(main.entities[int(u)]):
			sum += main.layout._rest_pos(main.entities[int(u)]).x
			n += 1
	return sum / float(n) if n > 0 else 0.0

## 把一整摞搬到 x = to_x（保持组内相对位置）。**直接写坐标，还要掐掉补间** ——
## board._move_to 排的补间会逐帧盖掉这里写的位置，而 my_pile_lists 读的是
## 静止位（rest_pos 在补间跑着时返回**终点**），不掐的话读到的还是老地方
func _move_group(main: Node, g: Dictionary, to_x: float) -> void:
	var base: float = main.board.rest_origin(g).x
	for c in g["cards"]:
		if not is_instance_valid(c):
			continue
		main.board._stop_move(c)
		c.global_position.x += to_x - base
