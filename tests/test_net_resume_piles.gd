# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 重连之后**摆放要回到断开那一刻的样子**：真端口 + 真场景。
##
## 玩家的原话：「当我启动游戏开启房间，对手断连再加入对局的时候，
## 一开始摆放并未完全恢复成断开时候的状态」。
##
## 根因是摞**没有任何一头会重发**：
##   - 重连的那一位手里是一份新进程 / 一张刚照快照摆出来的空桌。
##     快照里没有摞 —— 摞是纯表现，只活在 board.groups 里（见 Protocol.PILES），
##     还没收手的那些摞在引擎里根本不存在
##   - 留下的那一位也不发：他的 main._push_piles 是**比指纹去重**的，
##     分组没变就一条都不发 —— 而「对手重连了」在他那边不改变任何分组
## 两头都不发，那份数据就只剩服务器还有可能留着 —— 于是 NetRoom.piles
## 记一笔，_on_join 给重连进来的人回放两份（MY_PILES + FOE_PILES）。
##
## 和另外几条 net 判据的分工：
##   - test_net_piles     ：**局中**的摞可见性（我摞了 → 对面看得见）
##   - test_net_socket    ：net_transport.gd 的收发、令牌
##   - test_foe_offline   ：对手掉线/回来时的提示与拦
##   - test_host_takeover ：主机走了之后留下那位自己开服接管
##   - **这一条**         ：断开再进来时，**摞**回不回到原样
##
## 变异提示（tools/mutate_check.py 登记的那几条打在这里）：
##   1. NetRoom.handle_piles 把「记一笔」挪到 foe == 0 之后 → T3 红
##      （对手不在场时的声明没记上，而那正是最要紧的那一刻）
##   2. _on_join 不发 my_piles → T1 红（重连的人拿不回自己那些摞）
##   3. _on_join 不发 foe_piles → T2 红（拿不到对手那些摞）
##   4. reset_for_rematch 不清 piles → T4 红（新局回放上一局的 uid）
##   5. main.on_my_piles 不减半个跨度 → T5 的中点对不上（整摞往南偏）
##   6. main.on_my_piles 不跳过已在组里的 uid → T6 红（一张牌进两个组）
##   7. main.on_my_piles 不更新 _piles_fp → T7 红（恢复了但留下那位看不到）

const PORT_BASE := 47380
const A := GameState.PLAYER
const B := GameState.BOT

func _initialize() -> void:
	print("=== 重连恢复摆放测试 ===")
	CardDB.ensure_loaded()
	await _t1_my_piles_come_back()
	await _t2_foe_piles_come_back()
	await _t3_declared_while_he_was_away()
	await _t4_rematch_forgets()
	await _t5_receiver_rebuilds_the_pile()
	await _t6_combo_wins_over_replay()
	await _t7_restore_updates_the_fingerprint()
	net_stop()
	finish()

# ---------- 服务器 / 客户端（与 test_net_piles 同法，端口段错开） ----------
func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null

## 两条光秃秃的连接坐满一间房（没有场景）。前四节要的只是
## 「服务器记了什么、回放了什么」—— 场景那一半在 T5 起
func _seated_pair(seed_value: int, room_code: String) -> Array:
	var pair: Array = await net_seated_pair(PORT_BASE, seed_value, room_code)
	if pair.is_empty():
		return []
	# 这一路的判据全建立在「牌已经发下去了」上，所以多钉一道开局
	var room := _server_room()
	if not need(room != null and room.started(), "房间满座开局了"):
		return []
	return pair

## 某一侧名下的前 n 张牌 uid（**从服务器那份状态取**，两侧同一套 uid）
func _uids_of(seat: String, n: int) -> Array:
	var out: Array = []
	var room := _server_room()
	if room == null:
		return out
	for c in room.state.players[seat]["cards"]:
		if out.size() >= n:
			break
		out.append(int(c["uid"]))
	return out

## 一条消息里那几摞的 uid 名单（排过序，好比对）
func _uid_sets(msg: Dictionary) -> Array:
	var out: Array = []
	for p in (msg.get("piles", []) as Array):
		var us: Array = Intent.ints((p as Dictionary).get("uids", []))
		us.sort()
		out.append(us)
	return out

func _close_all(cs: Array) -> void:
	for c in cs:
		(c as NetTransport).close()
	await physics_frame

# ---------- T1 重连回来，自己那些摞还在 ----------

## 我声明了两摞 → 断开 → 拿原来那串令牌回来 → 服务器把**我自己**那两摞回放给我。
##
## 这一条钉的是 Protocol.MY_PILES 这条通道存不存在。少了它，重连的人
## 手里只有快照（牌、钱、已经收手的组合），行动阶段里摞好还没收手的那些摞
## 一条都拿不回来 —— 理牌把它们当散卡摊回资源堆，
## 玩家看到的就是「我摆了半天的阵型，重连之后没了」
func _t1_my_piles_come_back() -> void:
	print("\n-- T1 重连回来，我自己那些摞还在 --")
	var pair := await _seated_pair(7101, "RPA1")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]

	var mine := _uids_of(b.my_seat, 4)
	if not need(mine.size() == 4, "他名下有四张牌可摞（实为 %d）" % mine.size()):
		await _close_all([a, b])
		return
	var g1: Array = [mine[0], mine[1]]
	var g2: Array = [mine[2], mine[3]]
	b.send_piles([
		{ "uids": g1, "compact": true, "u": 0.2, "v": 0.3 },
		{ "uids": g2, "compact": false, "u": 0.8, "v": 0.7 },
	])
	var room := _server_room()
	if not await net_until([a, b], func(): return room.piles_of(b.my_seat).size() == 2):
		check(false, "服务器记下了他那两摞（实为 %d 摞）" % room.piles_of(b.my_seat).size())
		await _close_all([a, b])
		return
	check(true, "服务器把他声明的摞记了下来（NetRoom.piles）")

	var token := b.resume_token
	if not need(token != "", "他手里有重连令牌"):
		await _close_all([a, b])
		return
	b.close()
	await net_pump([a], 20)

	# 他拿原来那串令牌回来
	var b2 := net_client("RPA1")
	b2.resume_token = token
	var got: Array = []
	b2.my_piles.connect(func(msg: Dictionary): got.append(msg))
	if not await net_until([a, b2], func(): return b2.my_seat != ""):
		check(false, "他重连之后入座了（实为「%s」）" % b2.my_seat)
		await _close_all([a, b2])
		return
	check(b2.my_seat == B, "他坐回原座（该是 %s，实为 %s）" % [B, b2.my_seat])

	if not await net_until([a, b2], func(): return not got.is_empty()):
		check(false, "重连之后服务器回放了他自己那些摞 —— 没有这一条的话，"
			+ "他摆好的阵型在重连之后被理牌摊回资源堆")
		await _close_all([a, b2])
		return
	var sets := _uid_sets(got[-1])
	var want1 := g1.duplicate()
	want1.sort()
	var want2 := g2.duplicate()
	want2.sort()
	check(sets.size() == 2, "回放的是**两**摞（实为 %d 摞）" % sets.size())
	check(sets.has(want1) and sets.has(want2),
		"回放的名单和他断开前声明的一字不差（该是 %s，实为 %s）"
			% [str([want1, want2]), str(sets)])

	# 形态和位置也要一起回来：光有名单的话收方只能照几何自己猜，
	# 而收拢/摆在哪都是玩家亲手做的动作（同 test_net_piles T6/T7）
	var by_uids := {}
	for p in (got[-1].get("piles", []) as Array):
		var us: Array = Intent.ints((p as Dictionary).get("uids", []))
		us.sort()
		by_uids[str(us)] = p
	var p1: Dictionary = by_uids.get(str(want1), {})
	var p2: Dictionary = by_uids.get(str(want2), {})
	check(bool(p1.get("compact", false)) == true and bool(p2.get("compact", true)) == false,
		"收拢位跟着回来了（第一摞收拢=%s，第二摞收拢=%s）"
			% [str(p1.get("compact", "缺")), str(p2.get("compact", "缺"))])
	check(p1.has("u") and p1.has("v")
			and absf(float(p1["u"]) - 0.2) < 0.02 and absf(float(p1["v"]) - 0.3) < 0.02,
		"位置跟着回来了（该是 u=0.20 v=0.30，实为 u=%s v=%s）"
			% [str(p1.get("u", "缺")), str(p1.get("v", "缺"))])

	await _close_all([a, b2])

# ---------- T2 重连回来，对手那些摞也在 ----------

## 症状的另一半：重连的人拿不到**对手**那些摞。
##
## 留下的那一位不会重发 —— 他的 _push_piles 比指纹去重，分组没变就一条都不发，
## 而「对手重连了」这件事在他那边不改变任何分组。于是重连这一位的 foe_piles
## 是空的，settle_layout._layout_bot_zone 只能按「第几摞 / 共几摞」现算成整行居中：
## 对手明明把组合拖到了桌角，我这边看到的是桌子正中间一排
func _t2_foe_piles_come_back() -> void:
	print("\n-- T2 重连回来，对手那些摞也在 --")
	var pair := await _seated_pair(7202, "RPA2")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]

	# 这次由**留下的那一位**（a）声明摞，掉线重连的是 b
	var his := _uids_of(a.my_seat, 3)
	if not need(his.size() == 3, "留下那位名下有三张牌（实为 %d）" % his.size()):
		await _close_all([a, b])
		return
	a.send_piles([{ "uids": his, "compact": true, "u": 0.9, "v": 0.1 }])
	var room := _server_room()
	if not await net_until([a, b], func(): return room.piles_of(a.my_seat).size() == 1):
		check(false, "服务器记下了留下那位的摞")
		await _close_all([a, b])
		return

	var token := b.resume_token
	b.close()
	await net_pump([a], 20)
	var b2 := net_client("RPA2")
	b2.resume_token = token
	var got: Array = []
	b2.foe_piles.connect(func(msg: Dictionary): got.append(msg))
	if not await net_until([a, b2], func(): return b2.my_seat != ""):
		check(false, "他重连之后入座了")
		await _close_all([a, b2])
		return

	if not await net_until([a, b2], func(): return not got.is_empty()):
		check(false, "重连之后服务器回放了**对手**那些摞 —— 留下的那一位不会重发"
			+ "（他的 _push_piles 比指纹去重），少了这一条，重连这位看到的是"
			+ "整行居中的一排，而对手明明把摞拖到了桌角")
		await _close_all([a, b2])
		return
	var want := his.duplicate()
	want.sort()
	check(_uid_sets(got[-1]) == [want],
		"回放的对手摞名单对得上（该是 %s，实为 %s）" % [str([want]), str(_uid_sets(got[-1]))])
	var p: Dictionary = (got[-1].get("piles", []) as Array)[0]
	check(p.has("u") and absf(float(p.get("u", -1.0)) - 0.9) < 0.02,
		"对手那一摞的位置也回来了（该是 u=0.90，实为 %s）" % str(p.get("u", "缺")))

	await _close_all([a, b2])

# ---------- T3 他不在场时我挪的摞 ----------

## **最要紧的那一刻**：对手已经掉线了，而我还在挪我的摞。
##
## 他回来时该看到的是我**现在**这份摆放，不是他掉线那一瞬间那份。
## handle_piles 里「记一笔」必须在 `foe == 0 就 return` 之**前** ——
## 挪到后面的话对手不在场时的声明全部丢掉，症状恰好就是玩家报的那句
## 「一开始摆放并未完全恢复成断开时候的状态」：恢复出来的是**更早**的一份
func _t3_declared_while_he_was_away() -> void:
	print("\n-- T3 他不在场时我挪的摞，他回来要看得到 --")
	var pair := await _seated_pair(7303, "RPA3")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]

	var his := _uids_of(a.my_seat, 4)
	if not need(his.size() == 4, "留下那位名下有四张牌（实为 %d）" % his.size()):
		await _close_all([a, b])
		return
	# 掉线**之前**那一份：一摞两张
	a.send_piles([{ "uids": [his[0], his[1]], "compact": false, "u": 0.3, "v": 0.3 }])
	var room := _server_room()
	if not await net_until([a, b], func(): return room.piles_of(a.my_seat).size() == 1):
		check(false, "掉线前那一份记上了")
		await _close_all([a, b])
		return

	var token := b.resume_token
	b.close()
	await net_pump([a], 20)

	# 他**不在场**的这段时间里，我又摞了一摞、还挪了地方
	a.send_piles([
		{ "uids": [his[0], his[1]], "compact": true, "u": 0.75, "v": 0.6 },
		{ "uids": [his[2], his[3]], "compact": false, "u": 0.1, "v": 0.9 },
	])
	if not await net_until([a], func(): return room.piles_of(a.my_seat).size() == 2):
		check(false, "对手不在场时的声明也记上了（实为 %d 摞）—— handle_piles 里"
			% room.piles_of(a.my_seat).size()
			+ "那句「记一笔」在 foe == 0 的判断之后的话，这一段全丢")
		await _close_all([a])
		return
	check(true, "对手不在场时的声明照样记（记那一下在 foe == 0 之前）")

	# 他回来 → 拿到的该是**新**那份
	var b2 := net_client("RPA3")
	b2.resume_token = token
	var got: Array = []
	b2.foe_piles.connect(func(msg: Dictionary): got.append(msg))
	if not await net_until([a, b2], func(): return not got.is_empty()):
		check(false, "他回来之后收到了对手那份摞")
		await _close_all([a, b2])
		return
	var sets := _uid_sets(got[-1])
	check(sets.size() == 2,
		"他回来看到的是**我现在**这两摞，不是他掉线那一瞬那一摞（实为 %d 摞）"
			% sets.size())
	var p0: Dictionary = {}
	for p in (got[-1].get("piles", []) as Array):
		var us: Array = Intent.ints((p as Dictionary).get("uids", []))
		if us.has(int(his[0])):
			p0 = p
	check(absf(float(p0.get("u", -1.0)) - 0.75) < 0.02,
		"位置也是新那份（该是 u=0.75，实为 %s）—— 拿到 0.30 就是记在了"
			% str(p0.get("u", "缺")) + "他掉线之前")
	check(bool(p0.get("compact", false)) == true,
		"形态也是新那份（该是收拢，实为 %s）" % str(p0.get("compact", "缺")))

	await _close_all([a, b2])

# ---------- T4 新局不继承上一局的摞 ----------

## rematch 之后服务器记着的摞要清掉：新局是一手新牌，上一局那些 uid 一个都不在场上。
##
## 不清的话双方在新局一开始就各收到一份回放，里面全是查不着的 uid。
## 收方虽然会静默跳过（逐个查 state），但那份垃圾会一直留在服务器里
func _t4_rematch_forgets() -> void:
	print("\n-- T4 新局不继承上一局的摞 --")
	var pair := await _seated_pair(7404, "RPA4")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]

	var his := _uids_of(a.my_seat, 2)
	a.send_piles([{ "uids": his, "compact": true, "u": 0.5, "v": 0.5 }])
	var room := _server_room()
	if not await net_until([a, b], func(): return room.piles_of(a.my_seat).size() == 1):
		check(false, "先记上一摞")
		await _close_all([a, b])
		return

	room.reset_for_rematch()
	check(room.piles_of(a.my_seat).is_empty() and room.piles_of(b.my_seat).is_empty(),
		"新局把记着的摞清了（实为 %d / %d 摞）—— 不清的话新局一开始就回放"
			% [room.piles_of(a.my_seat).size(), room.piles_of(b.my_seat).size()]
		+ "一份全是查不着的 uid 的名单")

	await _close_all([a, b])

# ---------- 收方那一半：真场景 ----------

## 一份真场景 + 一条真连接坐 A 座，b 是光秃秃的一条连接（替对手收发）。
## 和 test_net_piles._seated_scene 同法
func _seated_scene(seed_value: int, room_code: String) -> Array:
	return await net_seated_scene(PORT_BASE, seed_value, room_code, A)

## 场景那一侧名下的前 n 张现金卡实体（同 test_net_piles._my_cash）
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

## 配方最小的那张生产卡（同 test_net_piles._smallest_producer）。
## 挑最小的是为了少加几张牌
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

## board.groups 里 uid 集合等于 want 的那一摞，找不着返回 {}
func _group_with(main: Node, want: Array) -> Dictionary:
	var sorted_want := want.duplicate()
	sorted_want.sort()
	for g in main.board.groups:
		var us: Array = []
		for c in (g as Dictionary)["cards"]:
			if is_instance_valid(c):
				us.append(int(c.uid))
		us.sort()
		if us == sorted_want:
			return g
	return {}

## 这几个 uid 里，有几个同时挂在**两个以上**的 board.groups 条目里。
##
## 一张牌进两个组是回放这条路上最隐蔽的一种坏法：两个组各自重排它，
## 牌在两处之间来回跳，而 group_of 只返回先找到的那个 —— 拖拽、双击收拢、
## 结算取位全都会看到不一样的答案。T5/T6 各拿它盯一种成因
## （T5：没从理牌摞里摘出来就编新组；T6：组合那一摞被回放又编了一遍）
##
## 参数收 **uid 而不是实体**，而且每次都现查 main.entities ——
## 这一条踩过：_respawn_all 是**重新造实体**（同一个 uid 换一个新对象），
## 重画之前抓在手里的那几个引用之后谁也不认，而它们
## `is_instance_valid` 仍然为 true（queue_free 是延迟的）。
## 拿旧引用去 `g["cards"].has(c)` 永远是 false —— 判据恒过，
## 一条真变异（漏掉 _detach_from_group）从两个测试底下溜了过去
func _dupes_among(main: Node, uids: Array) -> int:
	var dupes := 0
	for u in uids:
		var c: Variant = main.entities.get(int(u))
		if c == null or not is_instance_valid(c):
			continue
		var n := 0
		for g in main.board.groups:
			if (g as Dictionary)["cards"].has(c):
				n += 1
		if n > 1:
			dupes += 1
	return dupes

## my_pile_lists 里 uid 集合等于 want 的那一条，找不着返回 {}
func _decl_of(main: Node, want: Array) -> Dictionary:
	var sorted_want := want.duplicate()
	sorted_want.sort()
	for rec in main.my_pile_lists():
		var us: Array = Intent.ints((rec as Dictionary).get("uids", []))
		us.sort()
		if us == sorted_want:
			return rec
	return {}

## 「重连」那一下在收方看起来是什么样：照快照重画整桌。
## board.groups 被 _respawn_all → _restore_my_combo_groups 清空并只按
## state.combos 重建 —— 还没收手的摞在这一刻**消失**，那正是要修的病
func _redraw_as_if_rejoined(main: Node) -> void:
	main._respawn_all()

# ---------- T5 回放到了，摞就照原样立回来 ----------

## 走完整条链：我在真场景里摞一摞 → 服务器记下 → 桌子重画（摞没了）
## → 服务器那份回放进来 → 摞照原样立回来，**位置和形态都对**。
##
## 位置那一条是个坑：声明里的锚点是整摞 z 向的**中点**（my_pile_lists），
## 而 board._layout_group 要的是**起点**。不减这半个跨度的话每摞往南偏
## 半个摞长，长摞还会被 clamp 按在近边上。判据取的是**往返**：
## 回放进来之后再算一遍 my_pile_lists，u/v 该和当初声明的那对数重合
func _t5_receiver_rebuilds_the_pile() -> void:
	print("\n-- T5 回放到了，摞照原样立回来 --")
	var trio := await _seated_scene(7505, "RPA5")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	var cards := _my_cash(main, 3)
	if not need(cards.size() == 3, "手里有三张现金卡可摞（实为 %d）" % cards.size()):
		main.queue_free()
		await _close_all([a, b])
		return
	var want: Array = cards.map(func(e: CardEntity) -> int: return int(e.uid))
	for c in cards:
		main.board._detach_from_group(c)
	var g: Dictionary = main.board.make_group(cards.duplicate())
	main.board.groups.append(g)
	# 摆到一个不会被 clamp 咬到的地方（v=0.4 → z≈2.4，摊开三张跨度约 1.04）
	main.board._layout_group(g, main.my_pile_point(0.7, 0.4)
		- Vector3(0.0, 0.0, Board.z_span(g) / 2.0))
	await net_pump([a, b], 4)

	# 我这边声明出去的那对数 —— 判据的基线
	var decl: Dictionary = _decl_of(main, want)
	if not need(decl.has("u") and decl.has("v"),
			"摞好之后 my_pile_lists 带上了位置（实为 %s）" % str(decl)):
		main.queue_free()
		await _close_all([a, b])
		return
	var u0 := float(decl["u"])
	var v0 := float(decl["v"])

	# 服务器记上了没有（_push_piles 挂在 _process 上，摇几帧）
	var room := _server_room()
	if not await net_until([a, b], func(): return not room.piles_of(main.my_seat).is_empty()):
		check(false, "服务器记下了我这一摞")
		main.queue_free()
		await _close_all([a, b])
		return

	# 「重连」：桌子照快照重画 —— 摞在这一刻没了
	_redraw_as_if_rejoined(main)
	check(_group_with(main, want).is_empty(),
		"重画之后那一摞确实没了（这是要修的病，也是下面那条判据的前提）"
		+ " —— 还在的话下面那条是空转")

	# 服务器把它回放回来
	a.my_piles.emit(Protocol.my_piles(room.piles_of(main.my_seat)))
	await net_pump([a, b], 4)
	var back: Dictionary = _group_with(main, want)
	if not need(not back.is_empty(),
			"回放进来之后那一摞立回来了（board.groups 里 %d 摞）"
				% main.board.groups.size()):
		main.queue_free()
		await _close_all([a, b])
		return
	check(true, "重连之后我摆好的摞回到了桌上")

	# 立回来的那几张要**从理牌摞里摘出来**。回放到达这一刻它们并不是散的：
	# _respawn_all 末尾的 _tidy_player_idle 已经把散资源并成了现金堆，
	# 而 board.make_group 只造一个新字典、不碰旧组 —— 不摘的话同一张牌
	# 同时挂在现金堆和这一摞里。上面那几条位置判据抓不到它
	# （新组最后排的，牌的落点是对的），坏处要等玩家去动它才现形
	check(_dupes_among(main, want) == 0,
		"没有牌同时属于两个组（%d 张重复）—— 编新组之前要先 _detach_from_group，"
			% _dupes_among(main, want)
		+ "不然它还挂在理牌那堆现金卡里：两个组各自重排它，牌来回跳")

	# 位置往返：回放之后再算一遍，该和当初那对数重合
	var again: Dictionary = _decl_of(main, want)
	check(again.has("u") and again.has("v"),
		"立回来的摞照样报得出位置（实为 %s）" % str(again))
	check(absf(float(again.get("u", -9.0)) - u0) < 0.02,
		"横向回到原处（u 该是 %.3f，实为 %s）" % [u0, str(again.get("u", "缺"))])
	# 这一条盯的是那半个跨度：不减的话整摞往南偏半个摞长，v 大出一截
	check(absf(float(again.get("v", -9.0)) - v0) < 0.03,
		"纵向回到原处（v 该是 %.3f，实为 %s）—— 差半个摞长就是没把「中点」"
			% [v0, str(again.get("v", "缺"))]
		+ "换算回「起点」（my_pile_lists 报的是中点，_layout_group 要的是起点）")

	main.queue_free()
	await _close_all([a, b])

# ---------- T6 组合压过回放 ----------

## 同一张牌既在组合里、又在声明摞里时，**以组合为准**。
##
## 这种数据真会出现：收手那一瞬间掉线 —— 引擎已经收下了 create_combo，
## 而服务器手里还留着收手前那份声明摞。次序上 _restore_my_combo_groups 先跑
## （它按 state.combos 建的组是权威的），所以回放这一步必须跳过已经在组里的 uid。
## 不跳的话一张牌同时进两个组，board 的记账彻底乱掉（group_of 只返回先找到的那个，
## 而两个组都会各自重排它 —— 牌在两处之间来回跳）
func _t6_combo_wins_over_replay() -> void:
	print("\n-- T6 同一张牌：组合压过回放 --")
	var trio := await _seated_scene(7606, "RPA6")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	# 一份能过 ComboRules 的料：配方最小的生产卡 + 它要的单位卡。
	# 光几张现金卡编不成组合（create_combo 走 ComboRules.evaluate，
	# 没核心卡直接 invalid）—— 那样这一条测的就成了「编组失败时怎样」
	var core_id := _smallest_producer()
	if not need(core_id != "", "找得到一张生产卡"):
		main.queue_free()
		await _close_all([a, b])
		return
	var cd: Dictionary = CardDB.get_def(core_id)
	var uids: Array = [int(main.state.add_card(main.my_seat, core_id)["uid"])]
	var unit := "cash" if str(cd.get("recipe_res")) == CardDB.RES_CASH else "user"
	for i in int(cd.get("recipe_n", 0)):
		uids.append(int(main.state.add_card(main.my_seat, unit)["uid"]))
	main._sync_entities()
	await net_pump([a, b], 6)
	var made: Dictionary = main.state.create_combo(main.my_seat, uids.duplicate())
	if not need(made.get("ok", false),
			"这几张编成了组合（%s）" % made.get("reason", "")):
		main.queue_free()
		await _close_all([a, b])
		return
	# 这里**不预先抓实体引用**：下一句 _respawn_all 会把它们全部重造
	# （同 uid 换新对象），抓在手里的那几个之后谁也不认。判据一律走 uid，
	# 由 _dupes_among 现查 main.entities（见那里的说明）
	_redraw_as_if_rejoined(main)
	var n_before: int = main.board.groups.size()
	var by_combo: Dictionary = _group_with(main, uids)
	if not need(not by_combo.is_empty(),
			"重画之后组合那一摞在（_restore_my_combo_groups 建的）"):
		main.queue_free()
		await _close_all([a, b])
		return

	# 服务器手里那份声明摞里**也有**这几张（收手那一瞬掉线的形状）
	a.my_piles.emit(Protocol.my_piles(
		[{ "uids": uids, "compact": false, "u": 0.2, "v": 0.2 }]))
	await net_pump([a, b], 4)
	check(main.board.groups.size() == n_before,
		"回放没有多建一摞（%d → %d 摞）—— 一张牌进两个组的话 board 的记账"
			% [n_before, main.board.groups.size()]
		+ "会乱掉：两个组各自重排它，牌在两处之间来回跳")
	# 每张牌只属于一个组
	var dupes := _dupes_among(main, uids)
	check(dupes == 0, "没有牌同时属于两个组（%d 张重复）" % dupes)

	main.queue_free()
	await _close_all([a, b])

# ---------- T7 恢复之后要让对面也看见 ----------

## 恢复完，`_piles_fp` 要**等于此刻实况的指纹**。
##
## 那个量是 _push_piles 的去重基准（只在指纹变了时才广播）。恢复这一下改了
## board.groups 却不经过 _push_piles，所以要顺手把基准对齐。两种错法：
##   - 不更新 → 基准还是掉线前那份旧值。恢复完的实况恰好和它相等
##     （摞就是照那份立起来的），于是往后**一条都不发**：留下的那一位
##     看到的永远是我掉线前那份摆放
##   - 清空 → 下一帧无条件发一条，内容和服务器手里那份一模一样，纯冗余
##
## 判据分三层：先直接比「基准 == 实况」，再看这一刻**不白发广播**
## （回放照原样立起来的那一份，服务器手里就是它），最后看反方向 ——
## 恢复之后我真的挪一下，对面收不收得到。
##
## 「不白发」那一条有个前提，写在下面 _pump 那句注释里：**要先摇几帧**。
## 重画之后理牌把散资源并成了现金堆/用户堆，摞的次序和锚点跟掉线前那份并不一致
## （指纹带次序），所以重画后本来就该有一条广播 —— 那是理牌的差异，不是冗余。
## 摇过之后基准落在重画后那份实况上（真重连的人也是这样，
## 「桌子摆出来」到「MY_PILES 到达」之间隔着几十帧），
## 这时候才轮到回放那一下，而它该是静默的
func _t7_restore_updates_the_fingerprint() -> void:
	print("\n-- T7 恢复完，去重基准要对齐实况 --")
	var trio := await _seated_scene(7707, "RPA7")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	var cards := _my_cash(main, 3)
	if not need(cards.size() == 3, "手里有三张现金卡可摞（实为 %d）" % cards.size()):
		main.queue_free()
		await _close_all([a, b])
		return
	var want: Array = cards.map(func(e: CardEntity) -> int: return int(e.uid))
	for c in cards:
		main.board._detach_from_group(c)
	var g: Dictionary = main.board.make_group(cards.duplicate())
	main.board.groups.append(g)
	main.board._layout_group(g, main.my_pile_point(0.5, 0.4)
		- Vector3(0.0, 0.0, Board.z_span(g) / 2.0))
	var room := _server_room()
	if not await net_until([a, b], func(): return not room.piles_of(main.my_seat).is_empty()):
		check(false, "服务器记下了我这一摞")
		main.queue_free()
		await _close_all([a, b])
		return
	var replay: Array = room.piles_of(main.my_seat)

	# 「重连」：桌子重画
	_redraw_as_if_rejoined(main)
	var got: Array = []
	b.foe_piles.connect(func(msg: Dictionary): got.append(msg))
	# **摇几帧再回放** —— 这一段不是凑数，它决定这条判据是真的还是空转。
	# 真重连的人在「桌子摆出来」和「MY_PILES 到达」之间跑了几十帧 _process，
	# 于是 _piles_fp 早已落在**重画之后**那份实况上（理牌摞，没有我的摞）。
	# 不摇的话基准还是掉线前那个旧值，而它恰好等于回放之后的实况
	# （摞就是照那份立起来的）—— 下面那两条判据于是对「不更新基准」这种坏法
	# 一视同仁地放行。摇过之后基准和回放后的实况**不相等**，两条判据才有牙
	await net_pump([a, b], 12)
	got.clear()
	a.my_piles.emit(Protocol.my_piles(replay))
	var back: Dictionary = _group_with(main, want)
	if not need(not back.is_empty(),
			"那一摞立回来了（这是下面两条判据的前提）"):
		main.queue_free()
		await _close_all([a, b])
		return

	# 第一层：基准 == 实况。
	# 不更新的话它还是掉线前那份旧值（≠ 此刻实况，因为理牌重排过）；
	# 清空的话它是空串
	check(main._piles_fp == main._piles_fingerprint(main.my_pile_lists()),
		"恢复完，去重基准对齐了此刻的实况 —— 不对齐的话 _push_piles 会拿"
		+ "一个错的基准去比：往后要么一条都不发（留下那位永远看着我掉线前"
		+ "那份摆放），要么白发一条")
	check(main._piles_fp != "",
		"基准不是空串 —— 清空等于让下一帧无条件发一条，内容和服务器手里那份一样")
	# 症状那一层：回放**照原样**立起来的这一刻，没有任何新东西要告诉对面
	# （服务器手里那份就是它）。基准没对齐的话这里会漏出一条纯冗余的广播 ——
	# 两种坏法都漏：旧值 ≠ 实况、空串更是无条件发
	await net_pump([a, b], 12)
	check(got.is_empty(),
		"回放照原样立起来之后不白发广播（实为 %d 条）—— 这一份对面早就有了"
			% got.size()
		+ "（服务器就是照他那份回放的）")
	got.clear()
	main.board._layout_group(back, main.my_pile_point(0.15, 0.4)
		- Vector3(0.0, 0.0, Board.z_span(back) / 2.0))
	if not await net_until([a, b], func(): return not got.is_empty()):
		check(false, "恢复之后再挪一下，对面收得到 —— 指纹没跟着更新的话它和"
			+ "掉线前那份旧值相等，_push_piles 一条都不发，"
			+ "留下的那一位看到的还是我掉线前那份摆放")
		main.queue_free()
		await _close_all([a, b])
		return
	check(true, "恢复之后再挪一下，对面立刻收得到（指纹照回放那份更新了）")

	main.queue_free()
	await _close_all([a, b])
