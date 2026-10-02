# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 对手掉线这条路：提示挂上去、摘下来，掉线期间**打不到他的牌**。
##
## 为什么要真开端口：掉线是**连接**这一层的事件，NetRoom 里没有它 ——
## drop_peer 由服务器在收到 WebSocket 断开时调，而那一刻要判「房间空了没」
## 才决定回收房间还是广播 foe_left。假连接测不到这个分叉。
##
## 判据分三段，对着用户那句话逐条来：
##   「需要在对方牌区提示『对手断开』」        → T1
##   「如果本回合是自己行为则继续行动」        → T2（我自己那半边照常）
##   「但针对对手的行为需要被阻止」            → T2（打他的牌被拦）
##   「直到对手重新上线，进入房间」            → T3（提示摘掉、拦解除）

const PORT_BASE := 47380
const A := GameState.PLAYER
const B := GameState.AI

## 协程完成标志。**必须是成员变量** —— GDScript 的 lambda 按值捕获外层局部量
## （test_net_attack_flow 的 _flag 那段注释里有实测经过）
var _flag := false
var _flag2 := false

func _initialize() -> void:
	print("=== 对手掉线测试 ===")
	CardDB.ensure_loaded()
	await _t1_notice_appears()
	await _t2_my_half_lives_his_half_blocked()
	await _t3_notice_clears_when_he_returns()
	net_stop()
	finish()

# ---------- 服务器 / 客户端（与 test_net_piles 同法，端口段错开） ----------
func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null

func _server_applier() -> IntentApply:
	var room := _server_room()
	return room.applier if room != null else null
## 一份真场景坐 A 座 + 一条光秃秃的连接替对手收发（同 test_net_piles）
func _seated_scene(room_code := "TEST", seed_value := 0) -> Array:
	return await net_seated_scene(PORT_BASE, seed_value, room_code)

## 场景里那句「对手断开」还在不在。找的是**牌区那个 Label3D**，
## 不是 HUD 那行提示：提示语会被下一条消息顶掉，而这一句要一直挂着
func _notice_on(main: Node) -> bool:
	return main._foe_offline_lbl != null \
		and is_instance_valid(main._foe_offline_lbl)

# ---------- T1：提示挂上去 ----------

func _t1_notice_appears() -> void:
	print("\n[T1] 对手掉线 → 牌区挂出「对手断开」")
	var trio := await _seated_scene("OFFL1")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	check(not _notice_on(main), "开局时牌区没有掉线提示")
	check(main._foe_online, "开局时对手在线")

	b.close()
	if not await net_until([a], func(): return _notice_on(main), 10000):
		check(false, "对手掉线之后牌区挂出了提示")
		main.queue_free()
		return
	check(true, "对手掉线 → 牌区挂出「对手断开」")
	check(str(main._foe_offline_lbl.text) == "对手断开",
		"提示的字是「对手断开」（实为「%s」）" % str(main._foe_offline_lbl.text))
	check(not main._foe_online, "掉线之后 _foe_online 为假")
	# 房间**不能**被回收：座位令牌留在那儿才回得来（net/room.gd 的 drop_peer）
	check(_srv.rooms.has("OFFL1"),
		"对手掉线之后房间还留着 —— 回收掉的话他拿令牌也坐不回原位")
	main.queue_free()
	await net_pump([a], 2)

# ---------- T2：我这半边照常，打他的牌被拦 ----------

## 拦截这一条**必须在一个真装好弹的攻击回合里判**。
##
## 头一版是「摆好 phase/attack_mode 两个量就点」，它通过了 ——
## 可注册的变异（把 `if _foe_gone()` 改成 `if false`）**没被抓住**：
## 那时池子是空的，点下去本来就会被「点数不够」挡掉，
## 牌数不变和拦不拦没有关系。判据过了，钉的却是别的事
##
## 所以前提要一路搭到底（同 test_net_attack_flow._t1）：给先手编一个攻击组合 →
## 两边过完行动阶段 → 服务器装弹 → 场景层开出点选模式。
## 到这一步「点一下就真会掉牌」才成立，拦不住才看得出来
func _t2_my_half_lives_his_half_blocked() -> void:
	print("\n[T2] 掉线期间：自己那半边照常，打他的牌被拦")
	var trio := await _seated_scene("OFFL2", 20260829)
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		return

	_give_attack_combo(room, A)
	if not need(room.state.action_order()[0] == A,
			"先攻的是场景那一侧（%s）" % str(room.state.action_order()[0])):
		main.queue_free()
		return
	if not await _both_action_done(main, a, b):
		main.queue_free()
		return
	if not await net_until([a, b], func(): return _server_applier().armed(A), 10000):
		check(false, "服务器给先手装弹了")
		main.queue_free()
		return
	main._sync_entities()
	main.layout._layout_ai_zone()
	_run_attacks_bg(main)
	if not await net_until([a, b], func(): return main.board.attack_mode, 10000):
		check(false, "场景层开出了点选模式")
		main.queue_free()
		return
	# 靶要在**掉线之前**挑好：affordable_targets 要读池子，
	# 而这一刻它非空 —— 这就是「点一下真会掉牌」那个前提
	var victim := _foe_pile_card(main)
	if not need(victim != null, "对手那边有一张点得起的散卡（拦截要有靶子才测得到）"):
		main.queue_free()
		return

	# 掉线**之前**先记一笔。input_locked 在攻击阶段整段本来就是真
	# （见 _run_attacks），所以判「掉线之后它为假」判的是别人的事 ——
	# 要判的是**掉线这件事有没有动它**
	var locked_before: bool = main.board.input_locked
	var before: int = main.state.players[main.foe_seat]["cards"].size()
	b.close()
	if not await net_until([a], func(): return _notice_on(main), 10000):
		check(false, "对手掉线之后牌区挂出了提示")
		main.queue_free()
		return
	check(main._foe_gone(), "_foe_gone() 为真 —— 这个量是拦与不拦的唯一判据")
	check(not main.pipe.applier().pool_empty(A),
		"此刻池子非空（%s）—— 前提就是「点一下真会掉牌」，"
			% main.pipe.applier().pools(A)
		+ "空池的话这条判据钉的是「点数不够」，不是掉线拦截")

	await main._on_attack_clicked(victim)
	await net_pump([a], 10)
	var after: int = main.state.players[main.foe_seat]["cards"].size()
	check(after == before,
		"掉线期间点他的牌一张都没掉（%d → %d）—— 拦不住的话服务器会照常裁决，"
			% [before, after]
		+ "而他回来时拿的是结果快照，牌少了一批，中间那段演出一眼没看见")

	# 我自己那半边**不该**因为他掉线而被锁：拦的是针对他的行为，不是整局
	check(main.board.input_locked == locked_before,
		"他掉线没有动我这边的输入锁（掉线前 %s，之后 %s）—— "
			% [locked_before, main.board.input_locked]
		+ "锁上等于把整局停掉，而买卡/编组/典当只动我自己的牌")
	main.queue_free()
	await net_pump([a], 2)

## 在服务器那份状态上给某座位编一个攻击组合（同 test_net_attack_flow）
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
	# 弹药付款是真扣的（arm_attacks charge=true），配方之外还得有余量
	for i in int(d.get("recipe_n", 0)) + 2:
		room.state.add_card(seat, unit)
	room.state.create_combo(seat, uids)

## 两边都把行动阶段过完（同 test_net_attack_flow）
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

## 后台跑场景层的攻击阶段。**不 await** —— 它会挂在 attack_turn_finished 上
func _run_attacks_bg(main: Node) -> void:
	await main._run_attacks()

## 对手那边一张点得起的散卡实体（同 test_net_attack_flow）
func _foe_pile_card(main: Node) -> CardEntity:
	for t in main.state.affordable_targets(main.foe_seat, main._attack_pools):
		for u in t["uids"]:
			var uid := int(u)
			if main.entities.has(uid) and is_instance_valid(main.entities[uid]):
				return main.entities[uid]
	return null

# ---------- T3：他回来，提示摘掉 ----------

func _t3_notice_clears_when_he_returns() -> void:
	print("\n[T3] 对手重新进房间 → 提示摘掉、拦解除")
	var trio := await _seated_scene("OFFL3")
	if trio.is_empty():
		return
	var main: Node = trio[0]
	var a: NetTransport = trio[1]
	var b: NetTransport = trio[2]

	var his_token := b.resume_token
	check(his_token != "", "对手手里有重连令牌（服务器在 seated 里给的）")
	b.close()
	if not await net_until([a], func(): return _notice_on(main), 10000):
		check(false, "对手掉线之后牌区挂出了提示")
		main.queue_free()
		return

	# 他拿原来那串令牌回来 —— 「重新上线，进入房间」
	var b2 := net_client("OFFL3")
	b2.resume_token = his_token
	if not await net_until([a, b2], func(): return b2.my_seat != "", 10000):
		check(false, "对手重连之后入座了（实为「%s」）" % b2.my_seat)
		main.queue_free()
		return
	check(b2.my_seat == B,
		"他坐回**原来那个**座位（该是 %s，实为 %s）—— 令牌就是为这个" % [B, b2.my_seat])

	if not await net_until([a, b2], func(): return not _notice_on(main), 10000):
		check(false, "他回来之后提示摘掉了 —— 没有 foe_back 的话这一句永久挂着，"
			+ "而他明明已经在动了")
		main.queue_free()
		return
	check(true, "他回来 → 牌区那句「对手断开」摘掉了")
	check(main._foe_online, "他回来之后 _foe_online 回到真")
	check(not main._foe_gone(), "他回来之后拦解除（_foe_gone() 为假）")
	main.queue_free()
	await net_pump([a, b2], 2)
