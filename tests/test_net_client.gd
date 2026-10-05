# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 联网局的**客户端那一半**：快照里的点数池、到达队列的节拍、
## 重连时把组合摆回桌上、以及场景层能不能真的装上一条 NetTransport。
##
## 和另外三条 net 判据的分工：
##   - test_net_parity  ：无端口，钉「两条驱动路径同态」
##   - test_net_replay  ：无端口，钉「状态 = f(种子, 意图)」
##   - test_net_socket  ：真端口，钉 net_transport.gd 这一个文件的收发
##   - **这一条**       ：真端口 + 真场景，钉 scenes/main.gd 上联网那几条路
##
## 为什么必须单独有这一条：在它之前，`net/` 那一层测试全绿，
## 而**没有任何一处生产代码把它接上场景层** —— scenes/main.gd 的拖拽广播与租约处理
## 当时已经标了 ✅，可那两行的判据全部走 FakeNet（一条没连上的 socket
## 加一份空 GameState），场景层从来没有对着真服务器跑过一次。
## 也就是说「联网能玩」这件事在这条判据之前一次都没被验证过。
##
## 变异提示：**四条都实跑确认过红**，并登记进 tools/mutate_check.py：
##   1. intent_apply.pools_restore 开头去掉 `_pools.clear()`
##      → T1「next_round 之后客户端也没装弹」红（服务器清空的那份在客户端留着，
##        下一回合客户端以为自己装过弹了）
##   2. net/room.gd 的 snapshot() 里去掉 `snap["pools"] = ...`
##      → T1「装弹后客户端的池子跟服务器一样」红（状态全对、池子空，
##        pool_empty 当场为真，攻击回合被整段跳过而不报错）
##   3. net_transport._drain 里 `if not Intent.is_client_op(op): return`
##      改成 `continue`（不停在服务器操作上）
##      → T2「一段结算全到齐也不会把状态推过第 0 组」红
##   4. main._respawn_all 里去掉 `_restore_my_combo_groups()`
##      → T3「重画之后我的组合还在桌上」红（状态里组合还在，桌上是散牌）
##   5. main._draw_net_table 的 `if not _net_dealt():` 改成 `if false:`
##      → T5「提示语说了在等对手」红（照空快照摆桌子）
##   6. main.begin_net_game 里不连 `net.connected` → _on_net_seated
##      → T5「第二个人进来之后桌子补摆上了」红（补发的那份 seated 没人接）
##   7. main.begin_net_game 里去掉 `_net_table_drawn = false`
##      → T5「第二个人进来之后桌子补摆上了」红（标志从单机局带着 true 进来）
##   8. main._draw_net_table 里去掉「等对手」那句 _show_message
##      → T5「提示语说了在等对手」红（不崩了，但玩家看到的画面和崩掉时一样）
##
## 5 起初报的是 MISS，而缺的不是判据 —— 是**关键字登记错了**（第七种 MISS）：
## 我原本指望「空快照没有打断 begin_net_game」那条红，但 GDScript 的运行时错误
## 只中止**出错的那个函数**，_respawn_all 抛错之后 _draw_net_table 和
## begin_net_game 都继续跑完了，输入照样锁上。真正看得见的差别在提示语上。
## 这一条也顺带改了生产代码的次序：_net_table_drawn 从 _respawn_all 的开头
## 挪到了末尾 —— 置在开头等于「摆失败了却记成摆好了」，
## 之后补发的 seated 会被当成重复的挡掉，桌子再没人摆

const PORT_BASE := 47200
const A := GameState.PLAYER
const B := GameState.BOT

func _initialize() -> void:
	print("=== 联网局客户端测试 ===")
	CardDB.ensure_loaded()
	await _t1_pools_in_snapshot()
	await _t2_inbox_paces_state()
	await _t3_combo_groups_survive_respawn()
	await _t4_scene_hosts_net()
	await _t5_lone_joiner_waits()
	await _t6_lone_host_shares_in_log()
	net_stop()
	finish()

# ---------- 服务器 / 客户端（与 test_net_socket 同法，端口段错开） ----------
func _seated_pair(seed_value := 0, room := "TEST") -> Array:
	return await net_seated_pair(PORT_BASE, seed_value, room)

# ---------- T1 点数池要跟着快照过网 ----------

## 池子是**裁决器的成员**不是 GameState 的字段，StateCodec 看不见它。
## 少了这一段，症状是「状态全对、画面全对，攻击回合整段被跳过」——
## 而那条路径上没有任何一处会报错（客户端的 _await_foe_attack
## 就是循环判 pool_empty）
func _t1_pools_in_snapshot() -> void:
	print("\n-- T1 点数池过网 --")
	var pair := await _seated_pair(20260826, "TAAA")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	check(true, "双方都入座了")

	# 先纯粹地钉往返：snapshot → restore 不丢东西，且是**整份替换**
	var applier := IntentApply.new(GameState.new())
	applier.seed_pool_for_test(A, 7, 3)
	var snap: Dictionary = applier.pools_snapshot()
	var other := IntentApply.new(GameState.new())
	other.seed_pool_for_test(B, 99, 99)      # 先脏一份，看 restore 会不会清
	other.pools_restore(snap)
	check(int(other.pools(A)[CardDB.RES_CASH]) == 7
		and int(other.pools(A)[CardDB.RES_USER]) == 3, "池子的数值过了一趟往返")
	check(not other.armed(B), "restore 是整份替换（原来那个座位的条目没留下）")

	# 再走真服务器。**先给两边各编一个攻击组合**：装出来是空池的话
	# 服务器会当场换手、一路走到 _settle 和 next_round（见 room._arm_current），
	# 而 next_round 会把池子清空 —— 判据就永远读到 0，而且看不出是「没装」
	# 还是「装完又清了」。谁先攻由 action_order 说，所以两边都给
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		return
	_give_attack_combo(room, A)
	_give_attack_combo(room, B)
	if not await _both_action_done(a, b):
		return
	var first := a if a.my_seat == room.state.action_order()[0] else b
	var armed_on_server := func(): return _server_applier().armed(first.my_seat)
	if not await net_until([a, b], armed_on_server):
		check(false, "服务器给先手装弹了")
		return
	check(true, "服务器给先手（%s）装弹了" % first.my_seat)
	# 客户端要等到那条 arm 的广播 —— 它是服务器专属操作，压在队头等场景层来取，
	# 所以这里替场景层取一次
	net_pump_until([a, b], func(): return not first.applier().armed(first.my_seat))
	var got: Dictionary = await first.arm(first.my_seat)
	check(bool(got.get("ok", false)), "客户端取到了服务器那条 arm（%s）"
		% str(got.get("reason", "")))
	var sp: Dictionary = _server_applier().pools(first.my_seat)
	var cp: Dictionary = first.applier().pools(first.my_seat)
	check(int(cp[CardDB.RES_CASH]) == int(sp[CardDB.RES_CASH])
		and int(cp[CardDB.RES_USER]) == int(sp[CardDB.RES_USER]),
		"装弹后客户端的池子跟服务器一样（%s vs %s）" % [cp, sp])
	check(int(cp[CardDB.RES_CASH]) + int(cp[CardDB.RES_USER]) > 0,
		"而且那不是个空池（%s）—— 空池两边也「一样」，这条判据要它非空才算数" % cp)
	check(first.applier().armed(first.my_seat), "客户端这边 armed 也为真")

	# next_round 的快照必须把池子**清掉**：留着的话下一回合客户端以为装过弹了
	room.applier.pools_restore({})
	var r2: Dictionary = room._applied({ "ok": true, "op": Intent.OP_NEXT_ROUND })
	_deliver(first, r2)
	# 送进去还不算处理 —— next_round 是服务器专属操作，压在队头等场景层来取
	# （这正是 T2 那条判据说的节拍）。所以这里也得替场景层取一次
	check(first.applier().armed(first.my_seat),
		"光送到还不生效（队头压着，等场景层来取）")
	var r3: Dictionary = await first.next_round()
	check(bool(r3.get("ok", false)), "客户端取到了那条 next_round")
	check(not first.applier().armed(first.my_seat), "next_round 之后客户端也没装弹")
	a.close()
	b.close()

## 两边都把行动阶段过完。先手是谁由服务器说，所以两个都发一遍 action_done
func _both_action_done(a: NetTransport, b: NetTransport) -> bool:
	for c in [a, b]:
		var t: NetTransport = c
		var done := false
		var pump := func():
			await net_pump([a, b])
			return done
		# submit 是协程且自己泵帧，但它只泵自己 —— 服务器得有人摇。
		# 起一个并行的泵：submit 挂在 await 上时这个循环还在跑
		net_pump_until([a, b], func(): return done)
		var r: Dictionary = await t.submit(Intent.action_done(t.my_seat))
		done = true
		if not r.get("ok", false) and str(r.get("code", "")) != "not_your_turn":
			check(false, "过行动阶段（%s）：%s" % [t.my_seat, r.get("reason", "")])
			return false
	check(true, "两边都过完了行动阶段")
	return true

## 起一个后台泵：submit 挂在自己的 _next_frame 上时没人摇服务器，
## 回音永远不来（8 秒超时）。这个协程和 submit 并行跑，直到 done 为真

## 在服务器那份状态上给某座位编一个攻击组合（配方最小的那张攻击卡 + 弹药）。
## 直接改服务器的 state 而不是让客户端出牌：这条判据钉的是「池子过不过网」，
## 不是「怎么编出攻击组合」（那由 test_ammo_arming 盯着）
func _give_attack_combo(room: NetRoom, seat: String) -> void:
	var def_id := ""
	var best := 999
	for id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(id)
		if d.get("kind") != CardDB.KIND_ATTACK:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n < best:
			best = n
			def_id = str(id)
	if def_id == "":
		return
	var d: Dictionary = CardDB.get_def(def_id)
	var uids: Array = [room.state.add_card(seat, def_id)["uid"]]
	var unit := "cash" if str(d.get("recipe_res")) == CardDB.RES_CASH else "user"
	for i in int(d.get("recipe_n", 0)):
		uids.append(room.state.add_card(seat, unit)["uid"])
	# 弹药付款是**真扣**的（arm_attacks charge=true），配方之外还得有余量，
	# 不然 _attack_recipe_payable 会判付不起、那一组不进池子
	for i in int(d.get("recipe_n", 0)) + 2:
		room.state.add_card(seat, unit)
	room.state.create_combo(seat, uids)

func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null

func _server_applier() -> IntentApply:
	var room := _server_room()
	return room.applier if room != null else null

## 把服务器造好的一条广播直接喂给客户端（跳过 socket）。
## 用在「服务器某一步之后客户端该变成什么样」这种判据上 ——
## 真要走 socket 的话得先把局面推到那一步，而那不是这条判据要钉的东西。
##
## 取的是 `out["msg"]`：房间里那些 _all / _to 拼出来的是 **{to, msg}**
## 一条（net/room.gd 的 _all）。这里原先按 out["all"] 取，取到空数组 ——
## **一条都没送出去而判据是绿的**：紧跟着那句「送到了还没生效」
## 在「压在队头」和「根本没到」这两种情况下都成立。
## 这种绿是最贵的一种（memory: green-mutation-means-no-observer 的同一形状），
## 所以下面那句 next_round 的返回值必须判 ok —— 它是「真的送到了」的唯一证人
func _deliver(c: NetTransport, out: Dictionary) -> void:
	if out.has("msg"):
		c._on_text(JSON.stringify(out["msg"]))
		return
	for m in (out.get("all", []) as Array):
		c._on_text(JSON.stringify(m))

# ---------- T2 一整段结算到齐时状态不许跑过演出 ----------

## 服务器的 _settle 是**一口气**返回 produce×n + finalize + next_round 的，
## 这一串会在同一次 poll 里全部到达。收到就合上的话客户端的状态
## 在场景层演第 0 组之前就跳到下一回合了：_resolve_combo_visual(0)
## 去取第 0 组时 state.combos 已经被 finalize 清空，下标越界，
## 崩在结算演出的第一行 —— 而服务器那边一切正常
func _t2_inbox_paces_state() -> void:
	print("\n-- T2 到达队列的节拍 --")
	var c := NetTransport.new("ws://127.0.0.1:1", "TBBB")   # 不连，只用它的收包逻辑
	c.my_seat = A
	c.foe_seat = B
	# 造三条服务器专属操作，模拟「一整段同时到达」
	var room := NetRoom.new("T2", 20260826)
	# 三条快照都取**推进之后**那一份，好让「客户端合上了就跳过节拍」这件事
	# 在回合数上看得见：服务器这边先把回合推掉，再拼这一串
	var seg: Array = []
	room.state.new_game()
	var core := room.state.add_card(A, "yunketang")
	var uids: Array = [core["uid"]]
	for card in room.state.players[A]["cards"]:
		if card["def_id"] == "user" and uids.size() <= int(CardDB.get_def("yunketang")["recipe_n"]):
			uids.append(card["uid"])
	room.state.create_combo(A, uids)
	seg.append(Protocol.applied(room.applier.apply(Intent.produce(0)), 1, room.snapshot()))
	seg.append(Protocol.applied({ "ok": true, "op": Intent.OP_FINALIZE, "seat": A },
		2, room.snapshot()))
	room.state.round_num += 1        # next_round 在服务器那边已经发生了
	seg.append(Protocol.applied({ "ok": true, "op": Intent.OP_NEXT_ROUND, "seat": A },
		3, room.snapshot()))
	var round_before: int = c.state().round_num
	for m in seg:
		c._on_text(JSON.stringify(m))
	check(c._inbox.size() == 3, "三条服务器操作都排在队里（%d）" % c._inbox.size())
	check(c.state().round_num == round_before,
		"一段结算全到齐也不会把状态推过第 0 组（回合还是 %d）" % c.state().round_num)
	# 场景层来取一条，才推进一步
	var r1: Dictionary = await c.produce(0)
	check(bool(r1.get("ok", false)) and c._inbox.size() == 2,
		"取一条就只推进一条（队里还剩 %d）" % c._inbox.size())
	# 客户端操作不占节拍：它们没有演出要对齐，压在队头就是 submit 卡死
	var foe := Protocol.applied({ "ok": true, "op": Intent.OP_BUY, "seat": B,
		"new_uid": -1 }, 99, room.snapshot())
	c._inbox.append(foe)
	c._drain()
	# 三条：finalize、next_round、还有刚塞进去的对手买牌。
	# **一条都不许动** —— 队头是服务器操作，drain 就停在那里。
	# 「客户端操作不占节拍」说的是它在**队头**时不停，不是允许它插队：
	# 插队就是「对手的买牌画面出现在上一回合的结算动画中间」
	check(c._inbox.size() == 3,
		"队头压着服务器操作时，后面的客户端操作不许被 drain 提前吃掉（%d）"
			% c._inbox.size())
	check(str((c._inbox[0]["result"] as Dictionary)["op"]) == Intent.OP_FINALIZE,
		"队头还是那条 finalize")
	c.close()

# ---------- T3 重画桌子时组合要摆回去 ----------

## board.groups 是**桌面的实况**，只由拖拽产生 —— 重画一遍桌子就没了。
## 重连那条路（照服务器快照摆桌子）必须把 state.combos 里我这一侧的
## 变回摞，否则状态里组合还在、桌上是散牌，而且下一次 _register_player_combos
## 会把它们当成没编过、重发 create_combo 被引擎以「卡已在别的组合里」拒掉
func _t3_combo_groups_survive_respawn() -> void:
	print("\n-- T3 重画之后组合还在 --")
	var main: Node = await boot_main()
	var made: int = await _make_two_player_combos(main)
	if not need(made >= 1, "先编出至少一个组合（编了 %d 个）" % made):
		return
	var before: int = main.board.groups.size()
	var combos_mine := _my_combo_count(main)
	check(combos_mine >= 1, "引擎收下了 %d 个组合" % combos_mine)

	main._respawn_all()
	await settle()
	# **不数 groups 的总数**：board.groups 里还有理牌摆出来的散卡摞
	# （_tidy_player_idle / _layout_bot_idle 也往里 append），
	# 数总数的判据会被那些摞的数量变化牵着走 —— 而那和这条判据要钉的事无关。
	# 逐个组合去认「桌上有没有一摞正好是它」
	var found := 0
	var placed: Array = []
	for combo in main.state.combos:
		if str(combo["owner"]) != main.my_seat:
			continue
		var g: Variant = _group_for(main, combo["uids"])
		if g != null:
			found += 1
			placed.append(_group_center(g))
	check(found == combos_mine,
		"重画之后我的组合还在桌上（认出 %d / %d 个）" % [found, combos_mine])
	check(before >= 1 and main.board.groups.size() >= 1, "重画前后都不是空桌")

	# 两组不许精确重叠：_free_spot 逐组现查的话第二组会挑中第一组刚被搬到的点
	# （那儿在它眼里是空的 —— 第一组的牌此刻还读在 _rand_pos 撒出来的旧坐标上）
	if placed.size() >= 2:
		check(placed[0].distance_to(placed[1]) > 0.5,
			"两个组合没摞在一起（相距 %.2f）" % placed[0].distance_to(placed[1]))
	main.queue_free()
	await physics_frame

func _my_combo_count(main: Node) -> int:
	var n := 0
	for combo in main.state.combos:
		if str(combo["owner"]) == main.my_seat and (combo["uids"] as Array).size() >= 2:
			n += 1
	return n

## 桌上有没有一摞正好由这些 uid 组成。**要求完全相等**而不是包含：
## 包含的话「组合被理牌当成散卡拆进了一个更大的现金摞」也算通过 ——
## 那正是这条判据要抓的 bug
func _group_for(main: Node, uids: Array) -> Variant:
	var want := {}
	for u in uids:
		want[int(u)] = true
	for g in main.board.groups:
		var got := {}
		for c in (g["cards"] as Array):
			got[int((c as CardEntity).uid)] = true
		if got == want:
			return g
	return null

func _group_center(g: Dictionary) -> Vector3:
	var sum := Vector3.ZERO
	var cs: Array = g["cards"]
	for c in cs:
		sum += (c as Node3D).global_position
	return sum / maxf(1.0, float(cs.size()))

## 给玩家这一侧现造两个生产组合：直接 add_card 凑齐配方再 create_combo。
## 不去翻手里现有的牌 —— 那样成不成得看发牌，判据不能靠随机数碰上才成立
func _make_two_player_combos(main: Node) -> int:
	var state: GameState = main.state
	# 前面几节可能已经把胜利线顶过去了；winner 一旦定下来 create_combo 之后的
	# 结算护栏会挡掉一切（见 test_arrivals T6 那段说明）。这里只是造前提
	state.winner = ""
	state.win_reason = ""
	var made := 0
	for def_id in _two_producers():
		var d: Dictionary = CardDB.get_def(def_id)
		var uids: Array = [state.add_card(main.my_seat, def_id)["uid"]]
		var unit := "cash" if str(d.get("recipe_res")) == CardDB.RES_CASH else "user"
		for i in int(d.get("recipe_n", 0)):
			uids.append(state.add_card(main.my_seat, unit)["uid"])
		main._sync_entities()
		await settle()
		var r: Dictionary = state.create_combo(main.my_seat, uids)
		if not r.get("ok", false):
			continue
		made += 1
		_register_group(main, uids)
	return made

## 挑两个配方最小的生产卡。**两个不同的 def_id**：同一个会撞上升级
## （重复卡合成会吃掉配方卡，剩一张就不成摞了，见 _restore_my_combo_groups 里
## 那句 `cs.size() < 2`），于是第二组根本建不起来，判据变成只测一组
func _two_producers() -> Array:
	var by_n: Array = []
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") != CardDB.KIND_PRODUCT:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1:
			by_n.append([n, def_id])
	by_n.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	var out: Array = []
	for pair in by_n:
		out.append(str(pair[1]))
		if out.size() >= 2:
			break
	return out

## 把刚编好的一组也变成桌面上的摞 —— 模拟拖拽那条路的副产物。
## 不做的话 _respawn_all 之前 board.groups 是空的，判据就变成
## 「0 个变 N 个」而不是「N 个还是 N 个」
func _register_group(main: Node, uids: Array) -> void:
	var cs: Array = []
	for u in uids:
		if main.entities.has(u):
			cs.append(main.entities[u])
	if cs.size() >= 2:
		main.board.groups.append(main.board.make_group(cs, true, true))

# ---------- T4 场景层真的能装一条 NetTransport ----------

## 这一条钉的是 begin_net_game：**四样东西一次换齐**。
## 少换一样都不报错，症状各不相同（见那个函数的注释）
func _t4_scene_hosts_net() -> void:
	print("\n-- T4 场景层装上网络管道 --")
	var pair := await _seated_pair(20260826, "TCCC")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	check(true, "双方都入座了")
	var main: Node = await boot_main()
	main.begin_net_game(a)
	await net_pump([a, b], 4)

	check(main.pipe == a, "pipe 换成了网络那条")
	check(main.state == a.state(), "state 换成了服务器那份")
	check(main.my_seat == a.my_seat, "座位跟着连接（%s）" % main.my_seat)
	check(not main._foe_is_bot(), "对手标成了人")
	check(a.applied.is_connected(main._on_intent_applied), "applied 接上了")
	check(a.phase_changed.is_connected(main._on_net_phase), "phase 接上了")
	check(main.entities.size() > 0, "照服务器那份快照把桌子摆出来了（%d 张）"
		% main.entities.size())

	# 阶段：只认第一条 action，往后一律不认（服务器比客户端的演出快一整段）
	main._net_phase_seen = false
	main._on_net_phase(PhaseMachine.ACTION, a.my_seat)
	check(main._net_phase_seen, "第一条 action 开了行动阶段")
	var locked_before: bool = main.board.input_locked
	main._on_net_phase(PhaseMachine.ACTION, a.my_seat)
	check(main.board.input_locked == locked_before, "第二条 action 不再开一次")

	# 断线要把理由说出来，并且把界面锁掉
	main._on_net_down("table_mismatch", "两边卡表不一样")
	check(main.board.input_locked, "断线之后输入锁上了")
	check(main.btn_pass.disabled, "断线之后按钮灰了")

	# 「再战一局」要把座位改回单机那一对，不然桌子左右不镜像
	main._reset_session_flags()
	check(main.my_seat == GameState.PLAYER and main.foe_seat == GameState.BOT,
		"重开之后座位回到单机那一对（%s/%s）" % [main.my_seat, main.foe_seat])
	check(not main._net_phase_seen, "重开之后 phase 标记清了")

	a.close()
	b.close()
	main.queue_free()
	await physics_frame

# ---------- T5 一个人先进房：seated 带的是空局 ----------

## 先进房那位的**第一份 seated 里 players 是空字典** —— 房间是 NetRoom._init 建的，
## 而 new_game() 在 start_if_ready() 里，要等满座才跑。
##
## 这一条和 T4 的差别只有一个字：T4 是 `_seated_pair`（**两个人都坐下之后**
## 才 begin_net_game），所以它走的永远是「快照里有牌」那一支。
## 真人开局走的是这一支：点连接的那一刻对面还没来。
## 于是 _respawn_all 第一行读 state.players[my_seat] —— 空字典上取键抛脚本错误，
## 而它跑在 joined 信号的回调里：**错误不会让调用方失败**，
## 只是把 begin_net_game 剩下的部分静默丢掉（锁输入、灰按钮、提示语全不执行）。
## 玩家看到的是「点了连接，桌子空了，没有任何提示」——报上来的话就是「好像没连上」。
##
## 判据分两半，缺一半都测不到这个 bug：
##   前半 —— 一个人的时候不崩、而且**说了在等人**（不是一片沉默）
##   后半 —— 第二个人进来之后桌子**补摆上了**（补发的那份 seated 有人接）
## 只有前半的话，「永远不摆桌子」也能全绿；只有后半的话，
## 一个人时崩掉但第二份 seated 照样能把桌子摆出来（错误只吃掉一条回调），
## 于是「点了连接一片沉默」这个真症状溜过去了
func _t5_lone_joiner_waits() -> void:
	print("\n-- T5 一个人先进房：空快照不能崩，也不能一片沉默 --")
	if not net_boot(PORT_BASE, 20260826):
		return
	var a := net_client("TDDD")
	if not await net_until([a], func(): return a.my_seat != ""):
		check(false, "一个人也能入座（实为 %s）" % a.my_seat)
		return
	check(true, "一个人也能入座（%s）" % a.my_seat)

	# 这就是那份空局。**判据要直接钉住它**：将来服务器改成「进房就发牌」的话
	# 这一条会红，而红了正说明下面那几条在测的局面已经不存在了
	check(a.state().players.is_empty(),
		"这时候快照里 players 是空的（实为 %d 个座位）" % a.state().players.size())

	var main: Node = await boot_main()
	var log_before: int = main.msg_log.total()
	main.begin_net_game(a)
	await net_pump([a], 4)
	check(main.msg_log.total() == log_before + 1, "首次客户端入座只写一条等待详情")
	_check_waiting_connection_info(main, "TDDD", a.url, _port)

	check(main.board.input_locked, "空快照没有打断 begin_net_game（输入锁上了）")
	check(main.btn_pass.disabled, "按钮灰着（还轮不到自己动）")
	check(main.entities.is_empty(), "牌还没发，桌上是空的（实为 %d 张）"
		% main.entities.size())
	# **这一条才是「照空快照摆桌子」的观察点**，上面那三条不是 ——
	# GDScript 的运行时错误只中止**出错的那个函数**，_respawn_all 在
	# state.players[my_seat] 上抛错之后，_draw_net_table 和 begin_net_game
	# 都会继续跑完（于是输入照样锁上、按钮照样灰）。实跑变异确认过：
	# 把 `if not _net_dealt():` 改成 `if false:`，上面三条全绿，只有这一条红。
	#
	# 判「在等对手」而不是判非空：走错分支那一版说的是「等服务器发牌」——
	# 非空，但那句话对着一张永远不会来牌的空桌说，正是「好像没连上」的现场
	check(main.lbl_msg.text.contains("等对手"),
		"提示语说了在等对手（实为「%s」）" % main.lbl_msg.text)

	# 第二个人进来 → 服务器 start_if_ready → 给所有人补发 seated（net/server.gd 的
	# _on_join）→ 客户端 NetTransport 再 emit 一次 connected → main 补摆桌子
	var b := net_client("TDDD")
	if not await net_until([a, b], func(): return b.my_seat != ""):
		check(false, "第二个人入座了（实为 %s）" % b.my_seat)
		return
	if not await net_until([a, b], func(): return main.entities.size() > 0):
		check(false, "第二个人进来之后桌子补摆上了（实为 %d 张）" % main.entities.size())
		a.close()
		b.close()
		main.queue_free()
		return
	check(true, "第二个人进来之后桌子补摆上了（%d 张）" % main.entities.size())

	var room: NetRoom = _srv.rooms["TDDD"]
	check(StateCodec.state_hash(main.state) == StateCodec.state_hash(room.state),
		"补摆用的是服务器那份局面")
	check(main.entities.size() == main.state.players[main.my_seat]["cards"].size()
		+ main.state.players[main.foe_seat]["cards"].size(),
		"两边的牌都摆上了（%d 张）" % main.entities.size())

	# 阶段那条广播和补发的 seated 是同一帧到的，先后没有保证。
	# 不管谁先，最后都要开出行动阶段来 —— 卡在灰按钮上是「连上了但动不了」
	if not await net_until([a, b], func(): return not main.board.input_locked):
		check(false, "补摆之后行动阶段开出来了（输入还锁着）")
	else:
		check(true, "补摆之后行动阶段开出来了")

	a.close()
	b.close()
	main.queue_free()
	await physics_frame


## 本机主机的未发牌分支曾把分享IP、端口和房间码直接放进底栏。
## 用真实监听与首次入座验证资料仍可找到，同时不从状态或tooltip泄漏。
func _t6_lone_host_shares_in_log() -> void:
	print("\n-- T6 首次主机入座：等候摘要与可复制连接资料分离 --")
	var main: Node = await boot_main()
	var hosted: Dictionary = main.start_local_host()
	if not need(hosted.get("ok", false), "初次主机真实开房成功"):
		main.queue_free()
		return
	var a := NetTransport.new(str(hosted["url"]), "TFIRST")
	var opened: Dictionary = a.connect_to_server()
	if not need(opened.get("ok", false), "主机连接自己的真实监听地址"):
		main.stop_local_host()
		main.queue_free()
		return
	if not await net_until([a], func(): return a.my_seat != ""):
		check(false, "首次主机入座成功")
		a.close()
		main.stop_local_host()
		main.queue_free()
		return
	check(a.state().players.is_empty(), "此时仅主机入座，服务器尚未发牌")
	var log_before: int = main.msg_log.total()
	main.begin_net_game(a)
	await net_pump([a], 3)
	check(not main._net_table_drawn and main.entities.is_empty(), "未发牌主机保持等待空桌")
	check(main.msg_log.total() == log_before + 1, "首次主机入座只记一条完整连接说明")
	_check_waiting_connection_info(main, "TFIRST", main._host_where_text(), int(hosted["port"]))
	check(main.msg_log._body.selection_enabled and main.msg_log._body.shortcut_keys_enabled,
		"提示记录中的主机分享资料可选择并复制")
	main._reset_session_flags()
	main.queue_free()
	await physics_frame


func _check_waiting_connection_info(main: Node, room: String, address: String, port: int) -> void:
	var recorded: String = main.msg_log.plain_text()
	check(recorded.contains(room) and recorded.contains(address), "等待记录包含当前房间码和完整真实地址")
	check(not recorded.contains("断线前连接地址"), "首次入座说明不会误称为断线后的地址")
	for text in [main.lbl_msg.text, main.lbl_msg.tooltip_text]:
		check(text.contains("等对手") and text.contains("连接说明见「提示记录」")
			and not text.contains("重连说明"), "初次等候状态与tooltip使用连接说明指引")
		check(not text.contains("ws://") and not text.contains(room)
			and not text.contains(str(port)), "初次等候底栏与tooltip均不包含IP、端口、房间码")
