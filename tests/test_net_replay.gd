# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 意图重放：录下一局的意图流，重放一遍，末态必须逐字相同
## 运行入口见 README.md §「4.5 测试」。
##
## 这条判据钉的是**状态 = f(种子, 意图序列)**：除了这两样，没有第三个输入。
## 一旦有人在引擎里读了别的东西（Time.get_ticks、OS 的什么、一个没进快照的
## 成员变量），重放就对不上 —— 而那种 bug 在单机局里根本不表现，
## 它只在「另一台机器上重算一遍」的时候炸。
##
## 顺带把「网络层有没有偷偷改状态」钉死：录的是 NetRoom 广播出去的
## applied 流（服务器认定发生了什么），重放走的是**裸引擎**（IntentApply，
## 没有房间、没有协议、没有 PhaseMachine）。两者末态相同 = 房间除了
## 转发意图之外什么都没干。房间要是偷偷补了一张卡、多清了一次组合，
## 这里立刻红。
##
## 变异提示（都实跑过）：
##   1. net/room.gd 的 _arm_current 里删掉 out.append(_applied(r)) →
##      「广播流里有 arm_attacks」红（**不是**「seq 连号」红：漏播时 seq 自增
##      也跟着不发生，剩下那些照旧连号 —— 详见 T3 第二条判据上面那段）
##   2. net/room.gd 的 handle_intent 末尾加一句 state.add_card(seat, "cash")
##      → 「重放末态一致」红（房间偷偷改了状态）
##   3. engine/intent.gd 的 ints() 改成直接返回 a → 「解出来的 uid 是整数」红
##   4. engine/state_codec.gd 的 canon 里把 TYPE_ARRAY 也排序 → 「卡序参与哈希」红
##
## 哈希**验不出** int/float 走样：canon 把整值 float 印成整数
## （"%d" 而不是 "3.0"），那是故意的 —— 不然经 JSON 还原的状态永远
## 哈希不等于经引擎组装的。代价是「哈希一致」这句话比它看起来弱：
## uid 类型要单独判（T6），不能指望末态哈希替你发现

func _initialize() -> void:
	print("=== 意图重放测试 ===")
	CardDB.ensure_loaded()
	_t1_replay()
	_t2_replay_via_json()
	_t3_seq_monotonic()
	_t4_card_order_matters()
	_t5_no_hidden_input()
	_t6_uids_are_ints()
	finish()

func eq(got: int, want: int, msg: String) -> bool:
	var ok := got == want
	check(ok, msg if ok else "%s（实为 %d，应为 %d）" % [msg, got, want])
	return ok

# ---------- 录制 ----------

## 跑一局，返回 { room, tape }。
## tape 是**有序的完整意图流**，客户端发的和服务器自己驱动的都在里面。
##
## 怎么录服务器那半边：handle_intent 返回的消息列表里，第一条 applied
## 是刚发的这条意图本身，后面的 applied 都是房间自己驱动出来的
## （装弹 / 逐组产出 / 收尾 / 开新回合）。从 applied 的结果里能把意图**反推**回来 ——
## 反推得出来这件事本身就是个判据：说明 applied 广播里带足了「发生了什么」，
## 一个重连的客户端拿它就能追上，不必额外问服务器
func _record(seed_value: int, rounds: int) -> Dictionary:
	var r := NetRoom.new("REC", seed_value)
	r.seat_peer(1)
	r.seat_peer(2)
	r.start_if_ready()
	var tape: Array = []
	var seqs: Array = []
	# 广播里每条 applied 的 op。**这个观察点是补上来的**：见 T3 的第二条判据
	var ops: Array = []

	for rnd in rounds:
		if r.state.winner != "":
			break
		for who in r.state.action_order():
			if r.state.winner != "" or r.phase.phase != PhaseMachine.ACTION:
				break
			# 买一张产出卡，再拿它编一个产出组。
			#
			# **全程只走意图**：早先这里用 state.add_card 现发一张 ditui 当核心卡，
			# 于是重放侧没有那张卡，十条 create_combo 全报「包含不属于你的卡」。
			# 磁带里只能有意图 —— 录制时在引擎上多动一根手指，
			# 重放就永远追不上，而那是**测试的 bug**，不是引擎的
			var idx := _product_idx(r.state, who)
			if idx < 0:
				# 公共区这回合没刷出买得起的产出卡：买 0 号凑个动作，别空过
				_send(r, who, Intent.buy(who, 0), tape, seqs, ops)
			else:
				var bought: Dictionary = _send(r, who, Intent.buy(who, idx), tape, seqs, ops)
				if bought.get("ok", false):
					var combo := _combo_with(r.state, who, int(bought["new_uid"]))
					if not combo.is_empty():
						_send(r, who, combo, tape, seqs, ops)
			_send(r, who, Intent.action_done(who), tape, seqs, ops)
		# 攻击段：房间停在「等你点选」时把点得起的靶都点掉
		var guard := 0
		while r.phase.phase == PhaseMachine.ATTACK and r.state.winner == "":
			guard += 1
			if guard > 8:
				check(false, "攻击段没收敛")
				break
			var who: String = r.phase.actor
			while r.state.winner == "" and not r.applier.pool_empty(who):
				var aff: Array = r.applier.affordable_targets(who)
				if aff.is_empty():
					break
				_send(r, who, Intent.apply_attack(who, aff[0]), tape, seqs, ops)
			_send(r, who, Intent.attack_done(who), tape, seqs, ops)
	return { "room": r, "tape": tape, "seqs": seqs, "ops": ops }

## 发一条意图，把它和房间随后自己驱动的那些一起记进 tape。
## 返回这条意图自己的 applied 结果（买卡要用里面的 new_uid），被拒则返回 {}
func _send(r: NetRoom, seat: String, it: Dictionary, tape: Array, seqs: Array,
		ops: Array = []) -> Dictionary:
	var peer := int(r.occupants[seat])
	var out: Array = r.handle_intent(peer, it)
	var mine: Dictionary = {}
	var first := true
	for item in out:
		var m: Dictionary = (item as Dictionary)["msg"]
		if str(m.get("t", "")) != Protocol.APPLIED:
			continue
		seqs.append(int(m.get("seq", -1)))
		ops.append(str((m["result"] as Dictionary).get("op", "")))
		if first:
			# 第一条就是刚发的那条。**记原件**而不是反推：
			# 客户端发的意图带着 pay_uids 这种「玩家挑了哪几张」的信息，
			# 结果里没有（也不该有 —— 那是输入，不是结果）
			tape.append({ "intent": it, "from": seat })
			mine = m["result"]
			first = false
		else:
			var back := _intent_from_applied(m["result"])
			if not back.is_empty():
				tape.append({ "intent": back, "from": "" })
	return mine

## 从 applied 的结果反推意图（只反推服务器自己驱动的那几种）。
## from_seat 是空的：这几条正是「不由客户端发起」的那些
func _intent_from_applied(r: Dictionary) -> Dictionary:
	match str(r.get("op", "")):
		Intent.OP_ARM:
			return Intent.arm_attacks(str(r["seat"]))
		Intent.OP_PRODUCE:
			return Intent.produce(int(r["combo_idx"]))
		Intent.OP_FINALIZE:
			return Intent.finalize()
		Intent.OP_NEXT_ROUND:
			return Intent.next_round()
	return {}

## 公共区里第一张「现金配方的产出卡」的卡位，买不起就返回 -1。
## 挑现金配方是因为开局现金多（`_game.start_cash`）而用户少（`_game.start_user`），
## 用户配方的产出卡编不了几组就见底了
func _product_idx(s: GameState, who: String) -> int:
	var cash := s.resource_count(who, CardDB.RES_CASH)
	for i in s.market.size():
		var def: Dictionary = CardDB.get_def(s.market[i])
		if def.get("kind", "") != CardDB.KIND_PRODUCT:
			continue
		if def.get("recipe_res", "") != CardDB.RES_CASH:
			continue
		var price := int(def.get("price", -1))
		var recipe := int(def.get("recipe_n", 99))
		# 买完还得留够配方现金，而且买完不能归零（引擎的自杀护栏会拒）
		if price < 0 or cash - price - recipe <= 0:
			continue
		return i
	return -1

## 「n 张散现金 + 刚买的那张产出卡」的编组意图。凑不出返回 {}
func _combo_with(s: GameState, who: String, core_uid: int) -> Dictionary:
	var card: Dictionary = s.find_card(who, core_uid)
	if card.is_empty():
		return {}
	var n := int(CardDB.get_def(card["def_id"]).get("recipe_n", 0))
	if n <= 0:
		return {}
	var uids: Array = _unit_uids(s, who, CardDB.RES_CASH, n)
	if uids.size() < n:
		return {}
	uids.append(core_uid)
	return Intent.create_combo(who, uids)

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

# ---------- 重放 ----------

## 重放到一个**裸引擎**上：只有 GameState + IntentApply，
## 没有房间、没有协议、没有次序机。种子相同 + 意图相同 → 末态必须相同
func _replay(seed_value: int, tape: Array, via_json := false) -> Dictionary:
	var s := GameState.new()
	s.set_seed(seed_value)
	s.new_game()
	var ap := IntentApply.new(s)
	var bad: Array = []
	for i in tape.size():
		var e: Dictionary = tape[i]
		var it = e["intent"]
		if via_json:
			# 过一趟网线的形状：Dictionary → JSON 文本 → Dictionary。
			# JSON 里没有整数，uid 数组回来全是 double —— Intent.ints() 就是为这个存在的
			it = Intent.encode(it)
		var r: Dictionary = ap.apply(it, str(e["from"]))
		if not r.get("ok", false):
			bad.append("#%d %s：%s" % [i, str((e["intent"] as Dictionary).get("op", "?")),
				r.get("reason", r.get("code", ""))])
	return { "state": s, "bad": bad }

func _same_state(a: GameState, b: GameState, msg: String) -> void:
	var ha := StateCodec.state_hash(a)
	var hb := StateCodec.state_hash(b)
	if ha == hb:
		check(true, msg)
		return
	var d: Array = StateCodec.diff(a, b)
	check(false, "%s（%s ≠ %s；差异：%s）" % [msg, ha.substr(0, 8), hb.substr(0, 8),
		"；".join(d) if not d.is_empty() else "只有键序不同？"])

# ---------- T1：录一局、重放一局 ----------

func _t1_replay() -> void:
	print("\n-- T1 录制 + 重放 --")
	var seed_value := 8888
	var rec := _record(seed_value, 3)
	var room: NetRoom = rec["room"]
	var tape: Array = rec["tape"]
	if not need(tape.size() >= 10, "录到了足够长的意图流（%d 条）" % tape.size()):
		return
	print("   录到 %d 条意图，跑到第 %d 回合" % [tape.size(), room.state.round_num])

	var rp := _replay(seed_value, tape)
	check((rp["bad"] as Array).is_empty(),
		"重放全部落地" if (rp["bad"] as Array).is_empty()
			else "重放有 %d 条没落地：%s" % [(rp["bad"] as Array).size(),
				"；".join((rp["bad"] as Array).slice(0, 3))])
	_same_state(room.state, rp["state"], "重放末态一致（房间没偷偷改状态）")

# ---------- T2：过一趟 JSON 再重放 ----------

## 上一条比的是「同一份 Dictionary 再跑一遍」。这一条把意图**编码成文本**
## 再解回来 —— 那才是真的过了网线。JSON 没有整数类型，uid 数组回来是 double，
## 少了 Intent.ints() 这层，uid 比较会静默失配（找不到卡，报「不属于你」）
func _t2_replay_via_json() -> void:
	print("\n-- T2 过 JSON 再重放 --")
	var seed_value := 31415
	var rec := _record(seed_value, 3)
	var room: NetRoom = rec["room"]
	var rp := _replay(seed_value, rec["tape"], true)
	check((rp["bad"] as Array).is_empty(),
		"过 JSON 后全部落地" if (rp["bad"] as Array).is_empty()
			else "过 JSON 后有 %d 条没落地：%s" % [(rp["bad"] as Array).size(),
				"；".join((rp["bad"] as Array).slice(0, 3))])
	_same_state(room.state, rp["state"], "过 JSON 再重放，末态一致")

# ---------- T3：seq 连号 ----------

## 客户端靠 seq 判「我漏包了吗」。跳号不报错，只表现为
## 「对手那边的卡对不上，但双方都觉得自己是对的」
func _t3_seq_monotonic() -> void:
	print("\n-- T3 seq 连号 --")
	var rec := _record(2718, 2)
	var seqs: Array = rec["seqs"]
	if not need(seqs.size() >= 8, "录到了足够多的 applied（%d 条）" % seqs.size()):
		return
	var ok := true
	for i in seqs.size():
		if int(seqs[i]) != i + 1:
			check(false, "seq 第 %d 条应为 %d，实为 %d" % [i, i + 1, int(seqs[i])])
			ok = false
			break
	check(ok, "applied 的 seq 从 1 开始逐条 +1（共 %d 条）" % seqs.size())
	eq(int(rec["room"].seq), seqs.size(), "房间的 seq 计数和广播条数一致")

	# 房间自己驱动的那四种，每种都得**真的出现在广播里**。
	#
	# 这条判据是补上来的，补的原因是"连号"对漏播是瞎的：`_arm_current` 里
	# 删掉 `out.append(_applied(r))`，seq 自增也跟着不发生（两件事都在 _applied 里），
	# 于是剩下的那些**照旧 1..N-1 连号**，连号和 `room.seq == 条数` 两条一起绿。
	# 而漏播的后果是重连方装完弹发现自己没弹药。
	#
	# 光靠末态哈希也抓不到：这条录制里的组合全是产出组（`_combo_with` 只编产出组），
	# arm_attacks 没有攻击组可扣，状态效果本来就是零
	# （memory: combo-type-is-test-coverage 的同一形状）。
	# 所以量的不是状态，是**广播流里有没有这一条**
	var ops: Array = rec["ops"]
	for op in [Intent.OP_ARM, Intent.OP_PRODUCE, Intent.OP_FINALIZE, Intent.OP_NEXT_ROUND]:
		check(ops.has(op), "广播流里有房间自己驱动的 %s（共 %d 条 applied）" % [op, ops.size()])

# ---------- T4：卡序参与哈希 ----------

## 卡的**次序**是玩法量：付款取 pay.slice(0, price)，防御名额取前 N 张。
## 所以哈希里数组必须保序 —— canon 只排字典的键，不排数组。
## 这条判据一红就说明有人把数组也排序了（「反正集合相等就行」）
func _t4_card_order_matters() -> void:
	print("\n-- T4 卡序参与哈希 --")
	var s := GameState.new()
	s.set_seed(1234)
	s.new_game()
	var h0 := StateCodec.state_hash(s)
	var cards: Array = s.players[GameState.PLAYER]["cards"]
	if not need(cards.size() >= 3, "开局手牌够换序"):
		return
	# 换两张同名卡的位置：集合不变、次序变了
	var tmp = cards[0]
	cards[0] = cards[2]
	cards[2] = tmp
	check(StateCodec.state_hash(s) != h0, "换了卡序哈希就变（数组保序）")
	# 换回来必须回到原哈希（说明哈希只看内容，不带上「动过手」的痕迹）
	tmp = cards[0]
	cards[0] = cards[2]
	cards[2] = tmp
	check(StateCodec.state_hash(s) == h0, "换回来哈希也回来")

	# 字典键序**不该**影响哈希：同一份状态经引擎组装和经 JSON 还原，
	# 键的插入次序不同（canon 排键就是为这个）
	var d := StateCodec.snapshot(s)
	var back := GameState.new()
	StateCodec.restore(back, JSON.parse_string(JSON.stringify(d)))
	check(StateCodec.state_hash(back) == h0, "过 JSON 还原后哈希不变（键序不参与）")

# ---------- T5：没有第三个输入 ----------

## 同一个种子、同一串意图，跑两遍必须一样。
## 这条最朴素，但它是「引擎里没有偷偷读时钟/读全局」的唯一保障 ——
## 引擎里一旦有人用了 randf()（而不是 state 自己那条 rng），
## 两遍就会不一样，而单机局永远看不出来
func _t5_no_hidden_input() -> void:
	print("\n-- T5 跑两遍一样 --")
	var seed_value := 1618
	var a := _record(seed_value, 3)
	var b := _record(seed_value, 3)
	_same_state(a["room"].state, b["room"].state, "同种子同意图，两遍末态相同")
	eq(int(b["room"].seq), int(a["room"].seq), "两遍的 applied 条数相同")
	eq((b["tape"] as Array).size(), (a["tape"] as Array).size(), "两遍录到的意图条数相同")

	# 不同种子必须不一样（否则上面那条判据可能只是「状态根本没在动」）
	var c := _record(seed_value + 1, 3)
	check(StateCodec.state_hash(c["room"].state) != StateCodec.state_hash(a["room"].state),
		"换种子末态就不同（判据不是恒真）")

# ---------- T6：解出来的 uid 必须是整数 ----------

## 为什么单独判类型，而不靠末态哈希：canon 把整值 float 印成整数
## （见文件头），所以 uid 从 3 变成 3.0 **不会**让哈希变。
## GDScript 里 3 == 3.0 也是真，find_card 照样找得到 ——
## 于是这条 bug 能一路潜到「拿 uid 当字典键」的地方才炸
## （uid_set 用 int(u) 建键，某天有人不过它就直接 has(uid)）。
##
## 这条判据看的是 Intent.from_dict 的**出口类型**，一眼定生死
func _t6_uids_are_ints() -> void:
	print("\n-- T6 解出来的 uid 是整数 --")
	var raw := '{"op":"create_combo","seat":"player","uids":[3,7,11]}'
	var dec: Dictionary = Intent.decode(raw)
	if not need(dec.get("ok", false), "编组意图解得开"):
		return
	var uids: Array = dec["intent"]["uids"]
	var all_int := true
	for u in uids:
		if typeof(u) != TYPE_INT:
			all_int = false
			break
	check(all_int, "create_combo 的 uids 全是 int（实为 %s）" % [
		[typeof(uids[0]), typeof(uids[1]), typeof(uids[2])]])

	# 典当和买卡的 uid 数组走同一条路，一起判 —— 漏一条就等于这条判据没测那条
	var pawn: Dictionary = Intent.decode('{"op":"pawn","seat":"ai","uids":[2,5]}')
	check(pawn.get("ok", false) and typeof((pawn["intent"]["uids"] as Array)[0]) == TYPE_INT,
		"pawn 的 uids 是 int")
	var buy: Dictionary = Intent.decode(
		'{"op":"buy","seat":"ai","market_idx":1,"pay_uids":[4,9]}')
	check(buy.get("ok", false) and typeof((buy["intent"]["pay_uids"] as Array)[0]) == TYPE_INT,
		"buy 的 pay_uids 是 int")
	check(buy.get("ok", false) and typeof(buy["intent"]["market_idx"]) == TYPE_INT,
		"buy 的 market_idx 是 int")
	# 攻击目标里的 uids 也一样（target_ref 自己也调 ints）
	var atk: Dictionary = Intent.decode(
		'{"op":"apply_attack","seat":"player","target":{"kind":"combo","res":"cash","uids":[6]}}')
	check(atk.get("ok", false)
			and typeof(((atk["intent"]["target"] as Dictionary)["uids"] as Array)[0]) == TYPE_INT,
		"apply_attack 目标里的 uids 是 int")
