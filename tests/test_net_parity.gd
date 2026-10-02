# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 单机路径 vs 联网路径：同一串意图必须产出同一份状态哈希
## 运行入口见 README.md §「4.5 测试」。
##
## 本测试比较 README.md §「3. 文件目录结构」所述执行路径。分叉长什么样：
## 服务器的 `_settle()` 和 `Transport.run_settle` 各自写了一遍
## 「逐组 produce 再 finalize」的次序 —— 哪天有人在其中一处插一步、
## 或者把 finalize 提到 produce 前面，两条路径就再也合不回来了。
## 而它**不会报错**，只会在某天以「对手那边多了一张卡」的形态冒出来。
##
## 不开端口：NetRoom 是纯逻辑的（收一条意图、吐一批要广播的消息），
## 所以这里比的是**房间逻辑**和单机管道。网线本身由
## tests/test_net_socket.gd 单独验 —— 两件事分开，
## 因为「哈希不等」和「包发不出去」要查的地方完全不同。
##
## 变异提示（都实跑过，不是注释里的推测）：
##   1. net/room.gd 的 _settle 里把 finalize 挪到 produce 循环之前
##      → 「哈希一致」全红
##   2. net/room.gd 的 _settle 末尾删掉 next_round
##      → 「第二回合起点一致」红
##   3. engine/phase_machine.gd 的 check 里删掉 `seat != actor` 那条
##      → 「对方回合不能买卡」红
##   4. net/room.gd 的 handle_intent 里把 applier.apply(it, seat) 改成
##      applier.apply(it)（不传 from_seat）→ 「冒充座位被拒」红

var A := GameState.PLAYER
var B := GameState.AI

func _initialize() -> void:
	print("=== 联网/单机同构测试 ===")
	CardDB.ensure_loaded()
	_t1_no_attack()
	_t2_with_attack()
	_t3_phase_gate()
	_t4_impersonation()
	_t5_snapshot_roundtrip()
	_t6_two_rounds()
	finish()

# ---------- 判据小工具 ----------

## 数值判据：失败时把实到值印出来。harness 的 check 只收一个 bool，
## 「哈希不等」的时候光看消息不知道差在哪
func eq(got: int, want: int, msg: String) -> bool:
	var ok := got == want
	check(ok, msg if ok else "%s（实为 %d，应为 %d）" % [msg, got, want])
	return ok

## check 是 void 的，不能写 `if not check(...)`

## 两份状态一致吗。不等时把 diff 印出来 ——
## 只报「哈希不等」的话，查起来要从头手动比一遍
func same_state(a: GameState, b: GameState, msg: String) -> void:
	var ha := StateCodec.state_hash(a)
	var hb := StateCodec.state_hash(b)
	if ha == hb:
		check(true, msg)
		return
	var d: Array = StateCodec.diff(a, b)
	check(false, "%s（哈希 %s ≠ %s；差异：%s）" % [
		msg, ha.substr(0, 8), hb.substr(0, 8),
		"；".join(d) if not d.is_empty() else "只有键序不同？"])

# ---------- 两条路径的搭建 ----------

## 单机路径：GameState + IntentApply + LocalTransport，和 scenes/main.gd 一样
func _local(seed_value: int) -> Dictionary:
	var s := GameState.new()
	s.set_seed(seed_value)
	s.new_game()
	var ap := IntentApply.new(s)
	return { "state": s, "applier": ap, "pipe": LocalTransport.new(ap) }

## 联网路径：一个房间 + 两个「连接」。peer id 随便取，只要两个不同
func _room(seed_value: int) -> NetRoom:
	var r := NetRoom.new("TEST", seed_value)
	r.seat_peer(1)
	r.seat_peer(2)
	r.start_if_ready()
	return r

func _peer_of(r: NetRoom, seat: String) -> int:
	return int(r.occupants[seat])

## 房间收一条意图，返回被拒的原因（"" = 落地了）。
## 房间吐的是要广播的消息，这里只挑 rejected 出来看
func _feed(r: NetRoom, seat: String, it: Dictionary) -> String:
	var out: Array = r.handle_intent(_peer_of(r, seat), it)
	for item in out:
		var m: Dictionary = (item as Dictionary)["msg"]
		if str(m.get("t", "")) == Protocol.REJECTED:
			return str(m.get("code", "rejected"))
	return ""

## 一整个回合，两条路径同步跑。
## act: Callable(seat, step) -> Dictionary，返回第 step 条意图，{} = 这个座位发完了。
##
## **一条一条要**，不是一次问一整批：意图之间有依赖 ——
## 编第二组时前一组已经把那几张卡锁了，`_cash_uids` 得看到锁之后的状态。
## 一次问全批的写法会把同一张现金派给两个组，第二条当场被「已参与其他组合」拒掉。
##
## **必须按座位轮流发**：联网侧有次序闸门，不轮到你的时候连买卡都会被拒。
## 早先这个测试把双方的买卡连着发，结果联网侧拒了后手那条 ——
## 十条判据全红，但没有一条是真 bug。测试自己不守次序，
## 比的就不是「同一串意图」了
func _play_round(d: Dictionary, r: NetRoom, act: Callable, attacks: bool) -> void:
	var s: GameState = d["state"]
	var order: Array = s.action_order()
	check(r.state.action_order() == order, "行动顺序一致")
	for who in order:
		var step := 0
		while step < 12:
			var it: Dictionary = act.call(who, step)
			step += 1
			if it.is_empty():
				break
			var loc: Dictionary = d["applier"].apply(it, who)
			var code := _feed(r, who, it)
			check(loc.get("ok", false) == (code == ""),
				"%s 的 %s：两条路径同样%s" % [who, str(it.get("op", "?")),
					"成功" if loc.get("ok", false) else "失败（本地 %s / 联网 %s）" % [
						loc.get("reason", ""), code]])
			check(loc.get("ok", false), "%s 的 %s 落地了（%s）" % [
				who, str(it.get("op", "?")), loc.get("reason", "")])
		# 收手。单机侧发它没有落地效果（它只推进次序），但照样过一遍裁决器 ——
		# 单机和房间都通过 IntentApply 裁决，同一意图必须得到同一结果。
		d["applier"].apply(Intent.action_done(who), who)
		check(_feed(r, who, Intent.action_done(who)) == "", "%s 收手" % who)
	# 后手收手之后房间已经自己进了攻击阶段并给先手装弹
	_room_round_tail(r, attacks)
	_local_round_tail(d, attacks)

## 单机侧：跑完一整个回合的结算段，次序**照抄 Transport**。
## 这里刻意不调 Transport.run_round —— 那样比的就是「同一份代码等于自己」。
## 要比的是次序：房间那份和这份是不是同一个次序
func _local_round_tail(d: Dictionary, attacks: bool) -> void:
	var s: GameState = d["state"]
	var ap: IntentApply = d["applier"]
	var order: Array = s.action_order()
	for who in order:
		if s.winner != "":
			break
		var arm: Dictionary = ap.apply(Intent.arm_attacks(who))
		if bool(arm.get("empty", true)):
			continue
		if attacks:
			while s.winner == "" and not ap.pool_empty(who):
				var aff: Array = ap.affordable_targets(who)
				if aff.is_empty():
					break
				ap.apply(Intent.apply_attack(who, aff[0]), who)
		ap.apply(Intent.attack_done(who), who)
	if s.winner == "":
		var n: int = ap.production_count()
		for i in n:
			ap.apply(Intent.produce(i))
	ap.apply(Intent.finalize())
	if s.winner == "":
		ap.apply(Intent.next_round())

## 联网侧的攻击段。客户端只发得起 apply_attack / attack_done，
## 其余（装弹、产出、收尾、开新回合）由房间在收到这两条之后自己驱动 ——
## 「自己驱动的那一段和 Transport 是不是同一个次序」正是要比的东西。
##
## 写成 while：房间可能在一条 attack_done 里连着跑完换手、装弹、结算、
## 开新回合（对手池子是空的时候），也可能停在「等你点选」。
## 按 order 写 for 循环会假设它一定停两次
func _room_round_tail(r: NetRoom, attacks: bool) -> void:
	var guard := 0
	while r.phase.phase == PhaseMachine.ATTACK and r.state.winner == "":
		guard += 1
		if guard > 8:
			check(false, "联网侧攻击段没收敛（转了 %d 圈）" % guard)
			return
		var who: String = r.phase.actor
		if attacks:
			while r.state.winner == "" and not r.applier.pool_empty(who):
				var aff: Array = r.applier.affordable_targets(who)
				if aff.is_empty():
					break
				if _feed(r, who, Intent.apply_attack(who, aff[0])) != "":
					break
		_feed(r, who, Intent.attack_done(who))

# ---------- T1：不打架的一整回合 ----------

## 最小的分叉探测：双方各买一张、各收手，然后跑完结算。
## 不打架是为了先把「产出+收尾+开新回合」那一段单独钉住
func _t1_no_attack() -> void:
	print("\n-- T1 一整回合（不攻击） --")
	var seed_value := 4242
	var d := _local(seed_value)
	var r := _room(seed_value)
	var s: GameState = d["state"]

	same_state(s, r.state, "开局两条路径状态一致")
	_play_round(d, r, func(who, step): return Intent.buy(who, 0) if step == 0 else {}, false)
	same_state(s, r.state, "一整回合跑完，哈希一致")
	eq(r.state.round_num, s.round_num, "回合数一致")
	check(r.state.round_num == 2, "第二回合起点一致（房间自己发了 next_round）")
	check(r.phase.phase == PhaseMachine.ACTION,
		"房间自己推进到了下一回合的行动阶段（现在 %s）" % r.phase.phase)

# ---------- T2：打架的一整回合 ----------

## 攻击段接进来：装弹是服务器身份提交的（客户端发不了 arm），
## 点选是客户端发的。两条路径的点靶次序相同（都取 affordable[0]）
func _t2_with_attack() -> void:
	print("\n-- T2 一整回合（含攻击） --")
	var seed_value := 777
	var d := _local(seed_value)
	var r := _room(seed_value)
	var s: GameState = d["state"]

	# 给双方各发三张核心卡。**产出组合必须在场**，否则 produce 一次都不跑，
	# 而「产出与收尾的次序」正是两条路径最容易分叉的地方
	# （第一版这个测试只编了攻击组，把 finalize 提到 produce 前面照样全绿）：
	#   zuokong   攻击：用户 → 现金攻击（最便宜的攻击卡）
	#   ditui     产出：现金 → 用户
	#   yunketang 产出：用户 → 现金
	# 三张各吃什么、吃几张都从卡表取（下面 _combo_of 的头两个参数），
	# 写死 `RES_CASH, 2` 那种的话配方一改这三条编组全被拒，
	# 而红的是「哈希一致」那条 —— 错的位置对，说法把人往协议上带
	# 两个产出组一起上，是为了让 ordered_production_combos 的**组内次序**也参与判定
	#
	# 直接发牌不走意图：买卡要看公共区刷出了什么，那是另一件事的判据。
	# 两条路径发同一张，uid 也会一致 —— _uid 是同一条计数流，
	# 而它一旦对不上，后面所有 uid 判据都跟着错位
	var cores: Dictionary = {}
	for who in [A, B]:
		cores[who] = {}
		for def_id in ["zuokong", "ditui", "yunketang"]:
			var ca: Dictionary = s.add_card(who, def_id)
			var cb: Dictionary = r.state.add_card(who, def_id)
			eq(int(cb["uid"]), int(ca["uid"]), "%s 的 %s uid 一致" % [who, def_id])
			cores[who][def_id] = int(ca["uid"])
	same_state(s, r.state, "补牌后状态一致")

	# 一个座位这一回合发三条编组意图：攻击组 + 两个产出组。
	# 每条都现取 uid —— 前一组已经把那几张锁掉了，_unit_uids 会跳过
	_play_round(d, r, func(who, step):
		match step:
			0: return _combo_of_def(s, who, "zuokong", int(cores[who]["zuokong"]))
			1: return _combo_of_def(s, who, "ditui", int(cores[who]["ditui"]))
			2: return _combo_of_def(s, who, "yunketang", int(cores[who]["yunketang"]))
		return {}, true)
	same_state(s, r.state, "含攻击+产出的一整回合，哈希一致")
	# produce 真跑过了吗：两边各两个产出组，结算完组合表清空、产出卡到账。
	# 不验这一条的话，「三条编组全被拒」也会让上面那条哈希判据绿
	check(s.combos.is_empty() and r.state.combos.is_empty(), "结算后组合表清空")
	eq(s.resource_count(A, CardDB.RES_CASH), r.state.resource_count(A, CardDB.RES_CASH),
		"先手现金一致")
	eq(s.resource_count(A, CardDB.RES_USER), r.state.resource_count(A, CardDB.RES_USER),
		"先手用户一致")

func _cash_uids(s: GameState, who: String, n: int) -> Array:
	return _unit_uids(s, who, CardDB.RES_CASH, n)

## 「n 张散 res 卡 + 一张核心卡」的编组意图。凑不齐返回 {}
## 同上，但配方币种与张数从卡表读，调用方只说「哪张核心卡」
func _combo_of_def(s: GameState, who: String, def_id: String, core: int) -> Dictionary:
	var d: Dictionary = CardDB.get_def(def_id)
	return _combo_of(s, who, str(d["recipe_res"]), int(d["recipe_n"]), core)


func _combo_of(s: GameState, who: String, res: String, n: int, core: int) -> Dictionary:
	var uids: Array = _unit_uids(s, who, res, n)
	if uids.size() < n:
		return {}
	uids.append(core)
	return Intent.create_combo(who, uids)

## 这个座位前 n 张没被锁的散资源卡 uid。
## 要连 kind 一起判：产出卡也有 res 字段（那是它产什么，不是它是什么），
## 只看 res 会把 ditui 当成一张现金拖进配方
func _unit_uids(s: GameState, who: String, res: String, n: int) -> Array:
	var out: Array = []
	for c in s.players[who]["cards"]:
		if out.size() >= n:
			break
		if bool(c.get("locked", false)):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind", "") == CardDB.KIND_UNIT and def.get("res", "") == res:
			out.append(int(c["uid"]))
	return out

# ---------- T3：次序闸门 ----------

## 联网之后「轮到谁」不能只靠界面锁住：对手是另一个进程，
## 它不受我这边按钮禁用的约束（engine/phase_machine.gd 文件头那段）
func _t3_phase_gate() -> void:
	print("\n-- T3 次序闸门 --")
	var r := _room(31337)
	var first: String = r.state.action_first()
	var second: String = GameState.opponent(first)

	check(_feed(r, second, Intent.buy(second, 0)) == "not_your_turn",
		"对方回合不能买卡")
	check(_feed(r, first, Intent.buy(first, 0)) == "",
		"轮到自己可以买卡")
	# 攻击阶段的操作在行动阶段发不出去
	check(_feed(r, first, Intent.attack_done(first)) == "wrong_phase",
		"行动阶段发不了攻击收手")
	check(_feed(r, first, Intent.action_done(first)) == "", "先手收手")
	check(_feed(r, first, Intent.buy(first, 0)) == "not_your_turn",
		"收手之后不能再买（已经换手了）")
	check(r.phase.actor == second, "换手到后手")
	check(_feed(r, second, Intent.action_done(second)) == "", "后手收手")
	# 后手收手 → 房间自己推进；此刻要么在攻击阶段，要么已经跑完回合
	check(r.phase.phase in [PhaseMachine.ATTACK, PhaseMachine.ACTION, PhaseMachine.OVER],
		"双方收手后房间自己推进了阶段（现在 %s）" % r.phase.phase)

	# 客户端发不了阶段推进
	var pid := _peer_of(r, first)
	var out: Array = r.handle_intent(pid, Intent.arm_attacks(first))
	var codes: Array = []
	for item in out:
		codes.append(str((item as Dictionary)["msg"].get("code", "")))
	check(codes.has("not_client_op"), "客户端发不了装弹（阶段推进）")

# ---------- T4：冒充座位 ----------

## 座位是**连接**自带的身份，不是包里自称的。这条一红就说明
## handle_intent 把 from_seat 漏了 —— 那时任何客户端都能替对手行动
func _t4_impersonation() -> void:
	print("\n-- T4 冒充座位 --")
	var r := _room(555)
	var first: String = r.state.action_first()
	var second: String = GameState.opponent(first)
	# 用先手的连接，发一条自称是后手的意图
	var out: Array = r.handle_intent(_peer_of(r, first), Intent.buy(second, 0))
	var codes: Array = []
	for item in out:
		codes.append(str((item as Dictionary)["msg"].get("code", "")))
	# 先被次序闸门拦下（现在轮到 first）也算拦住了，两种都接受 ——
	# 但必须是被拒，不能落地
	check(codes.has("not_your_turn") or codes.has("wrong_seat"),
		"冒充座位被拒（%s）" % str(codes))
	# 轮到 second 时，first 的连接仍然不能替它行动
	_feed(r, first, Intent.action_done(first))
	var out2: Array = r.handle_intent(_peer_of(r, first), Intent.buy(second, 0))
	var codes2: Array = []
	for item in out2:
		codes2.append(str((item as Dictionary)["msg"].get("code", "")))
	check(codes2.has("not_your_turn") or codes2.has("wrong_seat"),
		"换手之后也不能替对手行动（%s）" % str(codes2))

# ---------- T5：快照往返 ----------

## 重连要靠它（scenes/main.gd 的 _offer_reconnect / _on_net_down）。uid / rng 缺失会导致新卡撞号、两端刷出不同的牌。
## 旧 armed_round 仅保留快照兼容，不能再延迟保护。
func _t5_snapshot_roundtrip() -> void:
	print("\n-- T5 快照往返 --")
	var s := GameState.new()
	s.set_seed(90210)
	s.new_game()
	# 造一点状态：买一张、编一组，验证锁定标记与组合完整往返
	s.buy(A, 0)
	var uids := _cash_uids(s, A, 3)
	var core: Dictionary = s.add_card(A, "ditui")
	uids.append(int(core["uid"]))
	s.create_combo(A, uids)

	var text := JSON.stringify(StateCodec.snapshot(s))
	var back := GameState.new()
	StateCodec.restore(back, JSON.parse_string(text))
	same_state(s, back, "过一趟 JSON 再还原，哈希一致")
	eq(back.peek_uid(), s.peek_uid(), "uid 计数器一起还原")
	check(back.combos.size() == s.combos.size(), "组合一起还原")

	# 还原之后继续跑，随机流要接上（不接上的话公共区会刷出不同的牌）
	s.round_num += 1
	back.round_num += 1
	s.start_round()
	back.start_round()
	check(s.market == back.market, "还原后随机流接上（公共区一致）")

	# 旧快照可能保留当时的装机回合，但它不能再影响当前保护规则。
	for legacy in [false, true]:
		var s2 := GameState.new()
		s2.players = {A: {"cards": []}, B: {"cards": []}}
		s2.round_num = 3
		var shield_core := s2.add_card(A, "yunketang")
		var card := s2.add_card(A, "tuisong")
		var recipe: Array = []
		for i in int(CardDB.get_def(shield_core["def_id"])["recipe_n"]):
			recipe.append(s2.add_card(A, CardDB.unit_id(CardDB.RES_USER))["uid"])
		check(s2.create_combo(A, [shield_core["uid"], card["uid"]] + recipe)["ok"],
			"保护快照夹具编组成立（旧字段=%s）" % legacy)
		if legacy:
			card["armed_round"] = s2.round_num + 7
		var b2 := GameState.new()
		StateCodec.restore(b2, JSON.parse_string(JSON.stringify(StateCodec.snapshot(s2))))
		var got := b2.find_card(A, int(card["uid"]))
		if legacy:
			eq(int(got.get("armed_round", -1)), int(card["armed_round"]), "旧 armed_round 跟着快照走")
		else:
			check(not got.has("armed_round"), "新快照不新增装机回合")
		check(b2.buff_armed(A, int(card["uid"])) and b2.is_protected(A, recipe[0], CardDB.RES_USER),
			"快照恢复当回合立即保护，不受旧装机回合影响（旧字段=%s）" % legacy)
		check(b2.attack_targets(A).is_empty(), "快照恢复后保护用户不可攻击（旧字段=%s）" % legacy)

# ---------- T6：连着跑两回合 ----------

## 一回合对得上可能是巧合（很多量在第一回合还是初值）。
## 两回合能把 next_round 的次序、装弹扣款、组合解锁都带进来
func _t6_two_rounds() -> void:
	print("\n-- T6 连跑两回合 --")
	var seed_value := 20260826
	var d := _local(seed_value)
	var r := _room(seed_value)
	var s: GameState = d["state"]

	for rnd in 2:
		if s.winner != "" or r.state.winner != "":
			break
		_play_round(d, r, func(who, step): return Intent.buy(who, 0) if step == 0 else {}, true)
		same_state(s, r.state, "第 %d 回合末哈希一致" % (rnd + 1))

	eq(r.state.round_num, s.round_num, "两回合后回合数一致")
	check(r.seq > 0, "房间给意图编了序号（seq=%d）" % r.seq)
