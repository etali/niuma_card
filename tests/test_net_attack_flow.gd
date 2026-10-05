# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 联网局**攻击阶段的换手**和**对手侧编组的可见性**：真端口 + 真场景。
##
## 和另外几条 net 判据的分工：
##   - test_net_parity  ：无端口，钉「两条驱动路径同态」
##   - test_net_replay  ：无端口，钉「状态 = f(种子, 意图)」
##   - test_net_socket  ：真端口，钉 net_transport.gd 这一个文件的收发
##   - test_net_client  ：真端口 + 真场景，钉 begin_net_game 那几条路
##   - **这一条**       ：真端口 + 真场景，钉「一个攻击回合走完之后局面还往下走」
##
## 为什么必须单独有这一条：攻击阶段的推进在联网局里是**服务器**做的
## （net/room.gd 的 _advance 只认 OP_ATTACK_DONE），而结束一个攻击回合的
## 判断在**场景层**（scenes/main.gd 的 _settle_attack）。两处对不上时：
## 服务器一直等一条永远不来的 attack_done，两个客户端一起卡在
## `await pipe.arm(...)` 上直到 8 秒超时 —— 整局停在「攻击阶段…」的灰按钮上。
## 单机局看不出来，因为那边推进阶段的正是场景层自己。
##
## 现有的判据一条都盯不到这个：test_net_client 的 T1 只走到「服务器给先手装弹了」
## 就收工（它钉的是池子过网），往后那一步换手从来没有人问过。

const PORT_BASE := 47320
const A := GameState.PLAYER
const B := GameState.BOT

## 协程完成标志。**必须是成员变量，不能是局部量** —— GDScript 的 lambda
## 按**值**捕获外层局部量，`var done := false` + `func(): done = true` 里那次
## 赋值写在副本上，外层永远读到 false。
##
## 这个坑在测试里格外贵：判据会一直等一个永不为真的条件，
## 直到帧数用完报「没跑完」—— 长得和「被测代码卡住了」一模一样。
## 实测就是这么绕了一圈：探针里 lambda 内部打的「click 出」印出来了，
## 而外层的 clicked 还是 false
var _flag := false
var _flag2 := false

func _initialize() -> void:
	print("=== 联网局攻击阶段测试 ===")
	CardDB.ensure_loaded()
	await _t1_attack_turn_advances()
	await _t2_foe_sees_my_combos()
	net_stop()
	finish()

# ---------- 服务器 / 客户端（与 test_net_client 同法，端口段错开） ----------
func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null

func _server_applier() -> IntentApply:
	var room := _server_room()
	return room.applier if room != null else null
## 一份真场景 + 一条真连接，坐 A 座（第一个连上的占 SEATS[0]，见 room.free_seat）。
## 返回 [main, a, b]，b 是光秃秃的一条连接（只用来替对手发意图）
func _seated_scene(seed_value: int, room_code: String) -> Array:
	return await net_seated_scene(PORT_BASE, seed_value, room_code, A)

## 在服务器那份状态上给某座位编一个攻击组合（配方最小的那张攻击卡 + 弹药）。
## 和 test_net_client._give_attack_combo 同法 —— 那边钉的是池子过网，
## 这边钉的是换手，两条都要「先手有非空的池子」这个前提
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
	# 弹药付款是**真扣**的（arm_attacks charge=true），配方之外还得有余量
	for i in int(d.get("recipe_n", 0)) + 2:
		room.state.add_card(seat, unit)
	room.state.create_combo(seat, uids)

## 两边都把行动阶段过完。次序由服务器说（先手先发），两条都发一遍
func _both_action_done(main: Node, a: NetTransport, b: NetTransport) -> bool:
	var room := _server_room()
	if room == null:
		return false
	for seat in room.state.action_order():
		var t: NetTransport = a if str(seat) == a.my_seat else b
		_flag = false
		net_pump_until([a, b], func(): return _flag)
		var r: Dictionary = await t.submit(Intent.action_done(t.my_seat))
		_flag = true
		if not r.get("ok", false):
			check(false, "过行动阶段（%s）：%s" % [t.my_seat, r.get("reason", "")])
			return false
	return true

# ---------- T1 一个攻击回合走完，局面要往下走 ----------

## 玩家把点数**花光**是攻击回合最普通的一种结束方式（另两种是清零即胜、
## 余点点不起任何目标）。三条路都得让服务器知道「我打完了」——
## 服务器的 _advance 只认 OP_ATTACK_DONE，收不到就永远不换手。
##
## 判据钉在**服务器那份 phase** 上而不是客户端的画面：客户端卡住的样子
## （灰按钮、标签还挂着）在「服务器没换手」和「换手了但画面没跟上」两种情况下
## 一模一样，而后者不是 bug。服务器的 phase.is_done(A) 是「它知道 A 打完了」
## 唯一的证人
func _t1_attack_turn_advances() -> void:
	print("\n-- T1 攻击回合走完之后要换手 --")
	var trio := await _seated_scene(20260829, "TAAA")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		return

	# 前提：先手（A，场景那一侧）有一个非空的攻击池，对手有散卡可点。
	# **只给 A**：给 B 也编一个的话 B 那一轮会卡在「等一条永远不来的
	# attack_done」上 —— 那是同一个 bug 的另一面，这条判据要的是干净的前提
	_give_attack_combo(room, A)
	if not need(room.state.action_order()[0] == A, "先攻的是场景那一侧（%s）"
			% str(room.state.action_order()[0])):
		return
	if not await _both_action_done(main, a, b):
		return
	# 服务器进攻击阶段并给先手装弹
	if not await net_until([a, b], func(): return _server_applier().armed(A)):
		check(false, "服务器给先手装弹了")
		return
	check(true, "服务器给先手（%s）装弹了" % A)
	check(not _server_applier().pool_empty(A), "而且那不是个空池（%s）"
		% _server_applier().pools(A))

	# 场景层跑它自己的攻击回合。不 await —— 它会一路挂在
	# `await attack_turn_finished` 上等玩家点选
	main._sync_entities()
	main.layout._layout_bot_zone()
	_run_attacks_bg(main)
	if not await net_until([a, b], func(): return main.board.attack_mode):
		check(false, "场景层开出了点选模式（客户端取到了那条 arm）")
		return
	check(true, "场景层开出了点选模式")

	# 点一摞对手的散卡：_attack_pile 会一路啃到点数花光（每张散卡 1 点）。
	# 走真的点选入口而不是直接调 _settle_attack —— 这条判据要连着
	# 「点完之后那个收尾函数有没有告诉服务器」一起钉
	var victim := _foe_pile_card(main)
	if not need(victim != null, "对手那边有一张点得起的散卡"):
		return
	_flag2 = false
	net_pump_until([a, b], func(): return _flag2)
	_click_bg(main, victim)
	if not await net_until([a, b], func(): return _flag2, 15000):
		check(false, "那一下点选处理完了（池子 %s）" % main.pipe.applier().pools(A))
		return
	check(main.pipe.applier().pool_empty(A), "点完之后客户端这边的池子空了（%s）"
		% main.pipe.applier().pools(A))

	# **这就是判据**：服务器不能再停在「等 A 点选」上。
	# 收不到 attack_done 的话它就一直停在那儿，两个客户端一起卡在下一条 arm
	# 上直到 8 秒超时 —— 那就是「攻击阶段卡死」的样子。
	#
	# 判的是 phase/actor 而不是 phase.is_done(A)：B 没编攻击组合，服务器给它
	# 装弹会装出空池、当场再换一次手、一路走到 _settle（见 room._arm_current），
	# 而 _settle 里的 phase.begin_settling() 会把 _done 清空。也就是说换手成功
	# 之后 is_done(A) 反而又是 false 了 —— 拿它当判据会把修好的实现判成失败。
	# 起点是确定的：上面刚等到 armed(A)，此刻服务器必然停在 ATTACK/A 上，
	# 所以这个谓词一开始为假，不会侥幸通过
	var advanced := func(): return (room.phase.phase != PhaseMachine.ATTACK
		or room.phase.actor != A)
	if not need(await net_until([a, b], advanced),
			"服务器不再停在 A 的攻击回合上（phase=%s actor=%s done_A=%s）"
				% [room.phase.phase, room.phase.actor, room.phase.is_done(A)]):
		main.queue_free()
		a.close()
		b.close()
		await physics_frame
		return
	check(true, "服务器不再停在 A 的攻击回合上（现为 phase=%s actor=%s）"
		% [room.phase.phase, room.phase.actor])

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

## 起一条后台协程跑场景层的攻击阶段。**不 await** —— 它会一路挂在
## `await attack_turn_finished` 上等玩家点选。
##
## 写成方法而不是 lambda：lambda 按值捕获，里面对标志位的赋值外层读不到
## （见 _flag 那段）
func _run_attacks_bg(main: Node) -> void:
	await main._run_attacks()

## 起一条后台协程处理那一下点选。完成时置 _flag2 —— **成员变量**，理由同上
func _click_bg(main: Node, victim: CardEntity) -> void:
	await main._on_attack_clicked(victim)
	_flag2 = true

## 对手那边一张点得起的散卡实体。取 layout 认出来的摞里的
## （_attack_pile 那条路），没有摞就随便一张单位卡
func _foe_pile_card(main: Node) -> CardEntity:
	for t in main.state.affordable_targets(main.foe_seat, main._attack_pools):
		for u in t["uids"]:
			var uid := int(u)
			if main.entities.has(uid) and is_instance_valid(main.entities[uid]):
				return main.entities[uid]
	return null

# ---------- T2 对手编成的组合要能看见 ----------

## 编组是**行动阶段末尾**才变成引擎状态的（_register_player_combos 在
## 「完成行动」里逐组发 create_combo）。在那之前桌面上的摞纯属表现层
## （board.groups），不过网 —— 所以对手侧看得见的时刻是「我点了完成行动」。
##
## 这一条钉的是那一刻**真的看得见**：create_combo 落地 → 对手侧
## _render_foe_combo → _layout_bot_zone 把那一组摆成一摞。
## 少了这条链的任何一环，症状都是「对手编了组，我这边什么都没变」
func _t2_foe_sees_my_combos() -> void:
	print("\n-- T2 对手编成的组合看得见 --")
	var trio := await _seated_scene(20260829, "TBBB")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		return

	# B（对手）在服务器那边凑一个生产组合的料，然后**以 B 的身份发 create_combo**。
	# 走真的 submit 而不是直接改状态：这条判据要的是「意图落地之后我这边画得出来」
	var uids := _seed_producer(room, B)
	if not need(uids.size() >= 2, "给对手凑了一组生产料（%d 张）" % uids.size()):
		return
	# 行动阶段的 actor 得是 B 才发得出（PhaseMachine.check）
	if room.state.action_order()[0] != B:
		_flag = false
		net_pump_until([a, b], func(): return _flag)
		var ra: Dictionary = await a.submit(Intent.action_done(A))
		_flag = true
		if not need(bool(ra.get("ok", false)), "A 先过了行动阶段：%s"
				% ra.get("reason", "")):
			return
	# 我这边要先有那几张牌的实体 —— 它们是直接加到服务器状态上的，
	# 客户端要等一条带快照的广播才知道。先发一条无害的意图把快照带过来
	var before := _foe_combo_piles(main)
	_flag = false
	net_pump_until([a, b], func(): return _flag)
	var r: Dictionary = await b.submit(Intent.create_combo(B, uids))
	_flag = true
	if not need(bool(r.get("ok", false)), "对手编成了一组（%s）" % r.get("reason", "")):
		return
	await net_pump([a, b], 4)
	main._sync_entities()
	await settle()
	await net_pump([a, b], 2)

	# 引擎那一侧：组合过了网
	var mine_view := 0
	for combo in main.state.combos:
		if str(combo["owner"]) == main.foe_seat:
			mine_view += 1
	check(mine_view >= 1, "对手那一组到了我这份状态里（%d 组）" % mine_view)

	# 画面那一侧：**这才是「看得见」**。_bot_piles 认出一摞正好由那几个 uid 组成
	var after := _foe_combo_piles(main)
	check(after > before, "对手区多出了一摞组合（%d → %d）" % [before, after])
	check(_pile_for(main, uids), "而且那一摞正好是他刚编的那几张")

	main.queue_free()
	a.close()
	b.close()
	await physics_frame

## 对手区现在有几摞组合（settle_layout._bot_piles 的前半段）
func _foe_combo_piles(main: Node) -> int:
	var n := 0
	for p in main.layout._bot_piles():
		if (p["key"] as String).begins_with("bot_combo_"):
			n += 1
	return n

## 对手区有没有一摞正好由这些 uid 组成。**要求完全相等**而不是包含：
## 包含的话「那几张被理牌当散卡拆进了一个更大的现金摞」也算通过
func _pile_for(main: Node, uids: Array) -> bool:
	var want := {}
	for u in uids:
		want[int(u)] = true
	for p in main.layout._bot_piles():
		var got := {}
		for c in (p["cards"] as Array):
			got[int((c as CardEntity).uid)] = true
		if got == want:
			return true
	return false

## 给某座位在服务器状态上凑一组生产料（配方最小的那张生产卡 + 单位卡），
## 返回该发 create_combo 的 uid 列表。**不在这里 create_combo** ——
## 那一步要走真的意图管道
func _seed_producer(room: NetRoom, seat: String) -> Array:
	var def_id := ""
	var best := 999
	for id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(id)
		if d.get("kind") != CardDB.KIND_PRODUCT:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n < best:
			best = n
			def_id = str(id)
	if def_id == "":
		return []
	var d: Dictionary = CardDB.get_def(def_id)
	var uids: Array = [room.state.add_card(seat, def_id)["uid"]]
	var unit := "cash" if str(d.get("recipe_res")) == CardDB.RES_CASH else "user"
	for i in int(d.get("recipe_n", 0)):
		uids.append(room.state.add_card(seat, unit)["uid"])
	return uids
