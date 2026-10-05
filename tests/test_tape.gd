# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 牌局录像：随时存、能重放、重放能指出「从第几步开始不对」
## （engine/tape.gd；用户原话「增加牌局过程保存功能（随时可以保存，
## 不必等到结束），支持重放来定位bug问题」）
##
## 这个文件和 tests/test_net_replay.gd 的分工：那边钉的是
## 「状态 = f(种子, 意图序列)」这条不变量本身（录联网广播、重放到裸引擎）；
## 这边钉的是**给玩家用的那套设施** —— 中途开始录也是完整的一份、
## 存盘再读回来仍然重放得动、分叉时报得出步号。
##
## 为什么「中途」这件事要单独判：中途录的那一份不能只存种子。种子是起点，
## 而录的这一刻已经抽过几十个随机数了 —— 只存种子的话重放方从头再抽一遍，
## 公共区当场就是另外八张牌。所以 head 存的是全量快照（含 rng 位置和 uid）。
## 判据里那一节（第 2 节）先把状态推到「明显不是开局」再开录
##
## 变异提示（都实跑过，见 tools/mutate_check.py 里 engine/tape.gd 那几条）
func _initialize() -> void:
	print("=== 牌局录像测试 ===")
	if not need(not _test_data_dir.is_empty() and Tape.path_dir() == _test_data_dir.path_join("replays"),
		"所有录像读写与清理都限定在当前测试沙箱"):
		finish()
		return
	CardDB.ensure_loaded()
	_t1_record_and_replay()
	_t2_record_midgame()
	_t3_save_and_load()
	_t3b_version_gate()
	_t4_locates_divergence()
	_t5_step_to()
	_t6_rejected_not_taped()
	_t6b_normalized_at_record()
	_t6c_nested_order()
	_t7_pools_travel()
	await _t8_wired_into_scene()
	finish()

# ---------- 造一局的工具 ----------

## 一副裸引擎：{ state, applier, tape }（tape 已在录）
func _rig(seed_value: int, note := "") -> Dictionary:
	var s := GameState.new()
	s.set_seed(seed_value)
	s.new_game()
	var ap := IntentApply.new(s)
	var t := Tape.new()
	t.start(ap, note)
	return { "state": s, "applier": ap, "tape": t }

## 走一段像样的牌局：买卡、编组、装弹、攻击、产出、开新回合。
## 全程只走意图 —— 录制时在引擎上多动一根手指，重放就永远追不上
## （memory 里那条：磁带里只能有意图）
func _play(rig: Dictionary, rounds: int) -> void:
	var s: GameState = rig["state"]
	var ap: IntentApply = rig["applier"]
	for rnd in rounds:
		if s.winner != "":
			return
		for who in s.action_order():
			if s.winner != "":
				return
			var idx := _product_idx(s, who)
			if idx >= 0:
				var r: Dictionary = ap.apply(Intent.buy(who, idx), who)
				if r.get("ok", false):
					var combo := _combo_with(s, who, int(r["new_uid"]))
					if not combo.is_empty():
						ap.apply(combo, who)
			else:
				ap.apply(Intent.buy(who, 0), who)
		# 攻击段：两边各装弹、把点得起的靶都点掉
		for who in s.action_order():
			if s.winner != "":
				return
			ap.apply(Intent.arm_attacks(who))
			var guard := 0
			while not ap.pool_empty(who) and s.winner == "":
				guard += 1
				if guard > 12:
					break
				var aff: Array = ap.affordable_targets(who)
				if aff.is_empty():
					break
				ap.apply(Intent.apply_attack(who, aff[0]), who)
			ap.apply(Intent.attack_done(who), who)
		if s.winner != "":
			return
		# 结算：逐组产出 + 收尾 + 开新回合
		for i in s.combos.size():
			if s.winner != "":
				break
			ap.apply(Intent.produce(i))
		ap.apply(Intent.finalize())
		if s.winner == "":
			ap.apply(Intent.next_round())

## 公共区里第一张「现金配方的产出卡」的卡位，买不起返回 -1。
## 挑现金配方是因为开局现金多而用户少（`_game.start_cash` / `start_user`）
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

# ---------- T1：录一局，重放一局 ----------

func _t1_record_and_replay() -> void:
	print("\n-- T1 从开局录，重放一遍 --")
	var rig := _rig(4321, "T1")
	var t: Tape = rig["tape"]
	_play(rig, 3)
	if not need(t.size() >= 20, "录到了足够长的意图流（%d 步）" % t.size()):
		return
	print("   录到 %d 步，跑到第 %d 回合" % [t.size(), (rig["state"] as GameState).round_num])
	var rp := Tape.replay(t)
	check(bool(rp["ok"]), Tape.verdict(rp))
	check(int(rp["played"]) == t.size(),
		"重放跑满 %d 步（实际 %d）" % [t.size(), int(rp["played"])])
	# 末态也比一遍：这一条比的是「重放出来的状态 vs 现场的状态」，
	# 一个字段都不读磁带 —— 所以它是唯一一条在「磁带上的哈希整列不可信」时
	# 仍然说得上话的判据（哈希录成空串时 replay 里 want == "" 就不比，
	# 逐步比对整段静默跳过；那一种由 T5 拿磁带上的值对着状态抓）
	check(StateCodec.state_hash(rig["state"]) == StateCodec.state_hash(rp["state"]),
		"末态逐字相同")
	check((rp["notes"] as Array).is_empty(),
		"没有额外提醒（卡表没变）：%s" % str(rp["notes"]))
	# 来路座位得**逐条录对**。
	#
	# 为什么这一条要单独判，而不能指望「重放一致」：`from_seat` 只管冒充校验，
	# 真正决定动谁的牌是意图里那个 `seat`。所以把整列 from 抹成空串之后
	# 重放**照样逐字相同** —— 客户端那几条的冒充校验被跳过（那道闸门
	# 头一个条件就是 `from_seat != ""`），而阶段推进那几条本来就要空的。
	# 抹平的代价要到「拿这份磁带查一次真的冒充」时才付：
	# 磁带上看不出这一步是谁发的（memory: vacuous-mutation-two-flavors）
	var seat_bad: Array = []
	for i in t.steps.size():
		var e: Dictionary = t.steps[i]
		var it: Dictionary = e["intent"]
		var op := str(it["op"])
		var want: String = str(it["seat"]) if Intent.is_client_op(op) else ""
		if str(e["from"]) != want:
			seat_bad.append("#%d %s 的来路录成了「%s」，应是「%s」" % [
				i, op, str(e["from"]), want])
	# 文案里那句「每一步的来路座位都录对了」得**在成败两种情形里都出现** ——
	# 变异检查按字面串认判据（tools/mutate_check.py 的锚点闸门），
	# 只写在成功那一支的话这条判据红起来时反倒认不出是它
	check(seat_bad.is_empty(),
		"每一步的来路座位都录对了（客户端那几条带座位、阶段推进那几条是空的）%s" % (
			"" if seat_bad.is_empty()
			else "—— 有 %d 步录错：%s" % [seat_bad.size(), "；".join(seat_bad.slice(0, 3))]))

# ---------- T2：中途开始录 ----------

## 「随时可以保存，不必等到结束」的那一半：录的这一刻**不是开局**。
##
## 只存种子在这一节会红：录之前已经打完两个回合，rng 早就不在起点上，
## 场上的 uid 也不从 0 数了。head 存全量快照才追得上
func _t2_record_midgame() -> void:
	print("\n-- T2 打到中途才开始录 --")
	# 先不录，闷头打两个回合
	var s := GameState.new()
	s.set_seed(777)
	s.new_game()
	var ap := IntentApply.new(s)
	var rig := { "state": s, "applier": ap }
	_play(rig, 2)
	if not need(s.winner == "", "两回合之后还没分胜负（分了就录不到中途）"):
		return
	var mid_hash := StateCodec.state_hash(s)
	var mid_round := s.round_num
	var mid_uid := s.peek_uid()
	check(mid_round > 1 and mid_uid > 0,
		"开录这一刻已经是中途了（第 %d 回合，uid 到 %d）" % [mid_round, mid_uid])
	# 此刻才开录
	var t := Tape.new()
	t.start(ap, "T2 中途")
	check(t.size() == 0, "刚开录时磁带是空的（%d 步）" % t.size())
	check(int((t.head as Dictionary).get("round_num", -1)) == mid_round,
		"开局快照记的是这一刻的回合（%d）" % mid_round)
	_play(rig, 2)
	if not need(t.size() >= 10, "中途这一段也录到了 %d 步" % t.size()):
		return
	# 重放这一份：起点是那张中途快照
	var rp := Tape.replay(t)
	check(bool(rp["ok"]), Tape.verdict(rp))
	check(StateCodec.state_hash(rig["state"]) == StateCodec.state_hash(rp["state"]),
		"中途录的这一份重放末态也逐字相同")
	# 起点真的是中途那一刻：一步都不放的重放应该等于那张快照
	var rp0 := Tape.replay(t, 0)
	check(StateCodec.state_hash(rp0["state"]) == mid_hash,
		"零步重放 = 开录那一刻的状态（否则 head 存的不是「此刻」）")

# ---------- T3：存盘、读回来、再重放 ----------

## 落盘那一趟**必须单独判**：JSON 里没有整数类型，uid 数组读回来全是 double。
## 用 double 当字典键、和 card["uid"] 比较，都会静默不相等 —— 报出来的是
## 「包含不属于你的卡」，看着像归属校验的 bug（Intent.ints() 就是为这个存在的）。
##
## 而末态哈希**验不出**这一类走样：StateCodec 的 canon 把整值 float 印成整数
## （"%d" 而不是 "3.0"），那是故意的。所以这里除了比哈希，还要单独看类型
func _t3_save_and_load() -> void:
	print("\n-- T3 存盘 → 读回来 → 重放 --")
	var rig := _rig(2468, "T3 存盘")
	var t: Tape = rig["tape"]
	_play(rig, 3)
	if not need(t.size() >= 20, "录到了 %d 步" % t.size()):
		return
	var path := t.save("_test_tape.json")
	check(path == ProjectSettings.globalize_path("user://replays/_test_tape.json"),
		"固定测试文件名实际写入隔离目录")
	check(path != "" and FileAccess.file_exists(path), "存到了 %s" % path)
	var got := Tape.load_from(path)
	if not need(bool(got.get("ok", false)), "读回来了：%s" % str(got.get("reason", ""))):
		return
	var t2: Tape = got["tape"]
	check(t2.size() == t.size(), "步数一样（%d / %d）" % [t2.size(), t.size()])
	check(t2.table == t.table, "卡表指纹一样")
	# 读回来的 uid 必须是**整数**。这一条是「过了一趟 JSON」的真判据 ——
	# 下面那条哈希一致在 uid 全是 double 时照样绿
	var ints_ok := true
	for e in t2.steps:
		for f in ["uids", "pay_uids"]:
			for u in (e["intent"] as Dictionary).get(f, []):
				if typeof(u) != TYPE_INT:
					ints_ok = false
	check(ints_ok, "读回来的 uid 都是整数（是 double 的话会静默找不到卡）")
	var rp := Tape.replay(t2)
	check(bool(rp["ok"]), "读回来的那份也重放得动：%s" % Tape.verdict(rp))
	check(StateCodec.state_hash(rig["state"]) == StateCodec.state_hash(rp["state"]),
		"存盘再重放的末态仍然逐字相同")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(not FileAccess.file_exists(path), "清掉了测试落下的那份录像")

## 版本对不上要**拒**，不要尽力解析：格式不符时重放出来的分叉是假的
func _t3b_version_gate() -> void:
	var bad := Tape.from_dict({ "version": Tape.VERSION + 1, "head": {} })
	check(not bool(bad.get("ok", true)),
		"版本对不上的录像被拒了：%s" % str(bad.get("reason", "")))
	var no_head := Tape.from_dict({ "version": Tape.VERSION })
	check(not bool(no_head.get("ok", true)),
		"没有开局快照的录像被拒了：%s" % str(no_head.get("reason", "")))

# ---------- T4：分叉时报得出步号 ----------

## 「支持重放来定位bug问题」的那一半：重放不一致时要说出**第几步**开始不对，
## 而不是只说「末态不一致」。分叉可能发生在三百步之前，后者没有排查价值。
##
## 怎么造一次假分叉：把磁带第 k 步的哈希改掉一个字。重放到那一步时状态是对的、
## 录的哈希是错的 —— 于是 replay 必须报 k，且 kind 是 diverged
func _t4_locates_divergence() -> void:
	print("\n-- T4 分叉报得出步号 --")
	var rig := _rig(1357, "T4")
	var t: Tape = rig["tape"]
	_play(rig, 3)
	if not need(t.size() >= 12, "录到了 %d 步" % t.size()):
		return
	var k := 7
	var real := str((t.steps[k] as Dictionary)["hash"])
	(t.steps[k] as Dictionary)["hash"] = "0" .repeat(32)
	var rp := Tape.replay(t)
	check(not bool(rp["ok"]), "改坏第 %d 步的哈希之后重放不通过了" % k)
	var f: Dictionary = rp["fault"]
	check(int(f.get("step", -1)) == k,
		"报的是第 %d 步（实为 %s）" % [k, str(f.get("step", "?"))])
	check(str(f.get("kind", "")) == "diverged",
		"报的是状态分叉（实为 %s）" % str(f.get("kind", "")))
	check(str(f.get("brief", "")) != "", "带上了那一步的摘要：%s" % str(f.get("brief", "")))
	check(int(rp["played"]) == k, "停在第 %d 步（没有把后面那些连锁一起报）" % k)
	print("   %s" % Tape.verdict(rp))
	(t.steps[k] as Dictionary)["hash"] = real
	# 落不了地的那一种：把某一步的意图换成一条注定被拒的
	# （买 0 号卡付一张不属于自己的 uid —— 归属校验必拒）
	var t2 := Tape.new()
	t2.head = t.head.duplicate(true)
	t2.head_pools = t.head_pools.duplicate(true)
	t2.table = t.table
	t2.steps = t.steps.duplicate(true)
	(t2.steps[3] as Dictionary)["intent"] = Intent.buy(GameState.PLAYER, 0, [999999])
	var rp2 := Tape.replay(t2)
	check(not bool(rp2["ok"]), "把第 3 步换成一条必被拒的意图之后重放不通过")
	check(int((rp2["fault"] as Dictionary).get("step", -1)) == 3
		and str((rp2["fault"] as Dictionary).get("kind", "")) == "rejected",
		"报的是第 3 步落不了地（实为 %s）" % str(rp2["fault"]))
	print("   %s" % Tape.verdict(rp2))

# ---------- T5：停在任意一步 ----------

## 「定位 bug」的用法：报出第 k 步不对之后，要能把状态**停在 k-1**上读一读。
## 所以 replay(t, upto) 得是真的部分重放，而不是跑完再回退
func _t5_step_to() -> void:
	print("\n-- T5 停在任意一步 --")
	var rig := _rig(9753, "T5")
	var t: Tape = rig["tape"]
	_play(rig, 3)
	if not need(t.size() >= 12, "录到了 %d 步" % t.size()):
		return
	# 每一步停一次，状态都必须等于磁带上记的那个哈希
	var bad: Array = []
	for k in range(1, mini(t.size(), 12) + 1):
		var rp := Tape.replay(t, k)
		if not bool(rp["ok"]):
			bad.append("停在 %d 步时：%s" % [k, Tape.verdict(rp)])
			continue
		if int(rp["played"]) != k:
			bad.append("要 %d 步却跑了 %d 步" % [k, int(rp["played"])])
			continue
		var want := str((t.steps[k - 1] as Dictionary)["hash"])
		if StateCodec.state_hash(rp["state"]) != want:
			bad.append("停在 %d 步的状态和磁带记的不一样" % k)
	# 「逐步停都停得准」这句在成败两种情形里都要出现，理由同 T1 那条来路判据
	check(bad.is_empty(), "逐步停都停得准%s" % ("" if bad.is_empty()
		else "—— 有 %d 处停不准：%s" % [bad.size(), "；".join(bad.slice(0, 3))]))
	# 超出磁带长度按跑完算，不越界
	var over := Tape.replay(t, t.size() + 50)
	check(int(over["played"]) == t.size(),
		"要的步数超过磁带长度时跑完就停（%d）" % int(over["played"]))
	# 目录：出了 bug 先拿眼睛扫一遍
	var lines := t.outline(0, 5)
	check(lines.size() == 5, "目录列得出 5 行（实为 %d）" % lines.size())
	check(str(lines[0]).contains("buy") or str(lines[0]).contains("create_combo"),
		"目录头一行看得出干了什么：%s" % str(lines[0]).strip_edges())

# ---------- T6：被拒的意图不进磁带 ----------

## 磁带上只该有**落地了**的意图。把被拒的也录进去，重放到那一步就会
## 停在「第 k 步落不了地」上 —— 而那一步在录的时候本来就没落地，
## 报出来的是一次假分叉，比不报更耽误事
func _t6_rejected_not_taped() -> void:
	print("\n-- T6 被拒的意图不进磁带 --")
	var rig := _rig(1122, "T6")
	var t: Tape = rig["tape"]
	var ap: IntentApply = rig["applier"]
	var before := t.size()
	# 三条注定被拒的：不属于自己的卡、越界卡位、替别人行动
	var r1: Dictionary = ap.apply(Intent.buy(GameState.PLAYER, 0, [999999]), GameState.PLAYER)
	var r2: Dictionary = ap.apply(Intent.buy(GameState.PLAYER, 99), GameState.PLAYER)
	var r3: Dictionary = ap.apply(Intent.buy(GameState.BOT, 0), GameState.PLAYER)
	check(not r1.get("ok", true) and not r2.get("ok", true) and not r3.get("ok", true),
		"三条意图都被拒了")
	check(t.size() == before, "磁带一步没长（实为 %d 步）" % (t.size() - before))
	# 形状都不对的那种（连解码都过不去）同样不该进
	ap.apply("{不是 JSON}", GameState.PLAYER)
	ap.apply({ "op": "并不存在的操作码" }, GameState.PLAYER)
	check(t.size() == before, "形状错的也没进磁带（实为 %d 步）" % (t.size() - before))
	# 落地的那条要进
	ap.apply(Intent.buy(GameState.PLAYER, 0), GameState.PLAYER)
	check(t.size() == before + 1, "落地的那条进了磁带")
	# stop 之后就不再录
	t.stop()
	check(not t.recording(), "stop 之后 recording() 是假")
	ap.apply(Intent.buy(GameState.PLAYER, 1), GameState.PLAYER)
	check(t.size() == before + 1, "停录之后落地的意图不再进磁带")

# ---------- T6b：进磁带的是规范化后的那份 ----------

## `apply()` 收什么都行：一段 JSON 文本（联网那条路上就是文本进来的）、
## 一份 uid 全是 double 的字典（同一段 JSON 解出来就是这样）、
## 或者 Intent.buy() 拼好的那种。而**进磁带的必须只有一种形状**。
##
## 为什么不能等存盘再规范化（那是 T3 判的事）：内存里这一份也有读者 ——
## 目录、按 uid 找那一步、界面上标「哪张卡出问题」。照抄入参的话
## 磁带里躺着一段字符串或者一堆 3.0，重放**照样全绿**
## （apply 内部还会再规范化一次），红的是所有读磁带的代码。
## 这正是 memory 里那条「判据绿≠变异有效」的第二种：真正的观察点在别处
func _t6b_normalized_at_record() -> void:
	print("\n-- T6b 录进去的是规范化后的意图 --")
	var rig := _rig(3344, "T6b")
	var t: Tape = rig["tape"]
	var s: GameState = rig["state"]
	var ap: IntentApply = rig["applier"]
	# 第一条：一段 JSON **文本**
	var txt := JSON.stringify(Intent.buy(GameState.PLAYER, 0))
	if not need(ap.apply(txt, GameState.PLAYER).get("ok", false),
		"文本形式的意图落地了"):
		return
	# 第二条：uid 是 double 的字典。典当**用户**卡而不是现金卡 ——
	# 典当行不收现金（CardDB.pawn_value 对现金单位卡返回 0），
	# 拿现金去当会被引擎拒掉，这一节就测不到规范化了
	var pawn_uids: Array = _unit_uids(s, GameState.PLAYER, CardDB.RES_USER, 1)
	if not need(pawn_uids.size() == 1, "手里有张用户卡可以典当"):
		return
	var floaty := { "op": Intent.OP_PAWN, "seat": GameState.PLAYER,
		"uids": [float(pawn_uids[0])] }
	if not need(ap.apply(floaty, GameState.PLAYER).get("ok", false),
		"uid 是浮点的意图也落地了（引擎内部会规范化）"):
		return
	if not need(t.size() == 2, "两条都进了磁带（实为 %d 步）" % t.size()):
		return
	var shapes_ok := true
	var why: Array = []
	for i in t.steps.size():
		var it = (t.steps[i] as Dictionary)["intent"]
		if not (it is Dictionary):
			shapes_ok = false
			why.append("#%d 录的不是字典而是 %s" % [i, type_string(typeof(it))])
			continue
		for f in ["uids", "pay_uids"]:
			for u in (it as Dictionary).get(f, []):
				if typeof(u) != TYPE_INT:
					shapes_ok = false
					why.append("#%d 的 %s 里有个 %s" % [i, f, type_string(typeof(u))])
	check(shapes_ok, "录进去的都是规范化后的字典、uid 都是整数%s" % (
		"" if shapes_ok else "—— %s" % "；".join(why.slice(0, 3))))

# ---------- T6c：嵌套落地时父在子前 ----------

## `landed` 是**同步**发的，所以它的回调里再落地一条意图时，两条 apply 是
## 嵌套的（外层还没 return，内层已经跑完）。磁带上父必须排在子前面 ——
## 反过来的话重放时子意图先跑，它依赖的那张卡还没出现，
## 整条磁带从这里开始全落不了地。
##
## 今天仓里**没有**这样的回调：`landed` 唯一的订阅者是 LocalTransport._on_landed，
## 它只广播不落地（广播的下游 scenes/main.gd 的 _on_intent_applied 只画画面）。
## 所以这一节是把「同步发信号」这条约定钉成判据，而不是在复现某条现有路径 ——
## 顺序错了今天一处都不红，等哪天真有回调要落地一条意图时才炸，
## 而那时炸出来的样子是「磁带从某一步起全落不了地」，回溯不到这里
func _t6c_nested_order() -> void:
	print("\n-- T6c 嵌套落地时父意图排在子意图前 --")
	var rig := _rig(5566, "T6c")
	var t: Tape = rig["tape"]
	var s: GameState = rig["state"]
	var ap: IntentApply = rig["applier"]
	# 回调里再落地一条：买成之后顺手典当一张用户卡
	# （典当行不收现金，见 T6b 里那条注释）。
	# 只做一次（`fired`），否则典当那条的 landed 会再触发一次，没完
	var fired := [false]
	var child_ok := [false]
	var on_landed := func(r: Dictionary) -> void:
		if fired[0] or str(r.get("op", "")) != Intent.OP_BUY:
			return
		fired[0] = true
		var uids: Array = _unit_uids(s, GameState.PLAYER, CardDB.RES_USER, 1)
		if uids.is_empty():
			return
		child_ok[0] = ap.apply(
			Intent.pawn(GameState.PLAYER, [int(uids[0])]), GameState.PLAYER).get("ok", false)
	ap.landed.connect(on_landed)
	var bought: Dictionary = ap.apply(Intent.buy(GameState.PLAYER, 0), GameState.PLAYER)
	ap.landed.disconnect(on_landed)
	if not need(bought.get("ok", false) and fired[0] and child_ok[0],
		"回调里那条子意图真的落地了"):
		return
	if not need(t.size() == 2, "两条都进了磁带（实为 %d 步）" % t.size()):
		return
	check(str((t.steps[0] as Dictionary)["intent"]["op"]) == Intent.OP_BUY
		and str((t.steps[1] as Dictionary)["intent"]["op"]) == Intent.OP_PAWN,
		"父意图（买）排在子意图（典当）前面，实为 %s → %s" % [
			str((t.steps[0] as Dictionary)["intent"]["op"]),
			str((t.steps[1] as Dictionary)["intent"]["op"])])
	# 顺序对了还不够：重放得动才说明顺序**是能用的**那一种
	var rp := Tape.replay(t)
	check(bool(rp["ok"]) and StateCodec.state_hash(s) == StateCodec.state_hash(rp["state"]),
		"嵌套录下来的这两步重放得动：%s" % Tape.verdict(rp))

# ---------- T7：攻击点数池跟着走 ----------

## 池子在裁决器身上（IntentApply._pools），既不在 GameState 里也不在
## state_hash 里。从**攻击回合中途**存的那份要是漏了它，重放时
## `_attack` 第一条护栏（没装弹）当场拒掉这一步。
##
## 这一节故意把开录点放在「装完弹、还没打完」那一刻 ——
## 联网那边同一个洞的症状是攻击段被整段跳过、一条错都不报
## （见 IntentApply.pools_snapshot 的说明）
func _t7_pools_travel() -> void:
	print("\n-- T7 攻击点数池跟着走 --")
	var s := GameState.new()
	s.set_seed(3344)
	s.new_game()
	var ap := IntentApply.new(s)
	var rig := { "state": s, "applier": ap }
	# 先打一个回合把组合摆上桌（有靶才点得起来），再装弹
	_play(rig, 1)
	if not need(s.winner == "", "一回合之后还没分胜负"):
		return
	var who: String = GameState.PLAYER
	# 点数直接摆上去，不走 OP_ARM：这一节判的是「池子跟不跟着磁带走」，
	# 不是「怎么装出点数来」。走 OP_ARM 得先凑一套攻击组合
	# （_play 只编产出组，装出来的池子是 0×0 —— 那样这一节判的就成了
	# 「空池子也能重放」，一个洞都堵不住）。
	# seed_pool_for_test 正是引擎给这种情形留的口子
	ap.seed_pool_for_test(who, 6, 0)
	if not need(ap.armed(who) and not ap.pool_empty(who),
			"摆上点数了：%s" % GameState.pool_text(ap.pools(who))):
		return
	# 此刻开录：池子里有点数，攻击还没打完
	var t := Tape.new()
	t.start(ap, "T7 攻击中途")
	check(not (t.head_pools as Dictionary).is_empty(),
		"开局快照里带了点数池：%s" % str(t.head_pools))
	# 录一次点选
	var aff: Array = ap.affordable_targets(who)
	if not need(not aff.is_empty(), "有点得起的靶（%d 个）" % aff.size()):
		return
	var hit: Dictionary = ap.apply(Intent.apply_attack(who, aff[0]), who)
	if not need(hit.get("ok", false),
			"点掉了一个靶：%s" % str(hit.get("reason", ""))):
		return
	check(t.size() == 1, "录到了这一步（%d 步）" % t.size())
	var rp := Tape.replay(t)
	check(bool(rp["ok"]), "带着池子重放得动：%s" % Tape.verdict(rp))
	# 池子确实是从磁带里来的：把 head_pools 清空，同一份磁带就该在第 0 步被拒
	var t2 := Tape.new()
	t2.head = t.head.duplicate(true)
	t2.head_pools = {}
	t2.table = t.table
	t2.steps = t.steps.duplicate(true)
	var rp2 := Tape.replay(t2)
	check(not bool(rp2["ok"]) and int((rp2["fault"] as Dictionary).get("step", -1)) == 0,
		"抹掉池子之后第 0 步就落不了地（%s）—— 池子是真的在起作用" % Tape.verdict(rp2))

# ---------- T8：界面局真的在录 ----------

## 上面七节全在裸引擎上跑，**一条都验不到接线**：scenes/main.gd 忘了
## tape.start 的话它们照样全绿，而玩家按下 F5 存出来的是一份 0 步的空录像
## （文件本身完全正常 —— 看着像「这一局什么都没发生」）。
##
## 重开一局那一条尤其要判：那时 applier 换了新的一个，录像还连在旧的上面
## 就再也录不到东西了，而这件事在界面上一点表现都没有
func _t8_wired_into_scene() -> void:
	print("\n-- T8 界面局真的在录 --")
	var main: Node = await boot_main()
	await settle()
	var t: Tape = main.tape
	check(t.recording(), "开局就在录了（不必等玩家按键）")
	check(not (t.head as Dictionary).is_empty(), "开局快照在位")
	var before := t.size()
	# 走一条真意图：从场景层的管道发，不碰引擎
	var r: Dictionary = await main.pipe.submit(
		Intent.buy(main.my_seat, 0), main.my_seat)
	if not need(r.get("ok", false), "买到了 0 号卡：%s" % str(r.get("reason", ""))):
		return
	check(t.size() > before, "这一步进了录像（%d → %d 步）" % [before, t.size()])
	# 存出去：路径要真落地
	var path := t.save("_test_scene_tape.json")
	check(path != "" and FileAccess.file_exists(path), "按 F5 那条路存得下来：%s" % path)
	var got := Tape.load_from(path)
	check(bool(got.get("ok", false)), "存出来的能读回去：%s" % str(got.get("reason", "")))
	if bool(got.get("ok", false)):
		var rp := Tape.replay(got["tape"])
		check(bool(rp["ok"]), "界面局的录像重放得动：%s" % Tape.verdict(rp))
		check(StateCodec.state_hash(main.state) == StateCodec.state_hash(rp["state"]),
			"重放末态 = 界面此刻的状态")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# 存完还在录（「随时可以保存，不必等到结束」—— 存档不该是终点）
	check(t.recording(), "存完之后还在录")
	var after_save := t.size()
	var r2: Dictionary = await main.pipe.submit(
		Intent.buy(main.my_seat, 1), main.my_seat)
	if r2.get("ok", false):
		check(t.size() > after_save, "存档之后的动作继续进录像")
	# 重开一局：录像得跟着换到新的裁决器上。
	# 走**真的**重开路径 —— _on_restart 头一句 _teardown_for_new_game 判的是
	# 「终局面板在不在」（防当帧二次进入），面板不立起来它直接返回，
	# 一句都不执行（那样这一节测的就成了「什么都没发生时录像没变」）
	var old_applier: IntentApply = main.pipe.applier()
	main.state.winner = main.my_seat
	main._show_game_over()
	main._on_restart()
	await settle()
	var t2: Tape = main.tape
	check(main.pipe.applier() != old_applier, "重开一局换了裁决器（前提）")
	check(t2.recording(), "重开之后还在录")
	check(t2.size() == 0, "新的一局从 0 步开始（实为 %d 步）" % t2.size())
	var n0 := t2.size()
	var r3: Dictionary = await main.pipe.submit(
		Intent.buy(main.my_seat, 0), main.my_seat)
	if not need(r3.get("ok", false), "第二局买得到卡：%s" % str(r3.get("reason", ""))):
		return
	check(t2.size() > n0,
		"第二局的动作也录得到（录像没有留在上一局的裁决器上）")
	var rp2 := Tape.replay(t2)
	check(bool(rp2["ok"]) and StateCodec.state_hash(main.state)
			== StateCodec.state_hash(rp2["state"]),
		"第二局的录像也重放得动：%s" % Tape.verdict(rp2))

	# 玩家**看得见**的那个入口。原先只有 F5，用户找不到（原话
	# 「对局保存入口在哪儿？找不到」）—— 而上面每一条都照旧全绿：
	# 它们走的是 tape.save() 和 pipe，谁也不看画面上有没有这颗按钮。
	# 这一条按类型和文案在树里找，并**发 pressed 信号**驱动（不直接调
	# _save_replay：那样把 connect 那一行删掉这条还是绿的）
	var btn: Button = main.btn_save
	if not need(btn != null and btn.is_inside_tree(),
		"存录像按钮在场景树里（玩家点得到，不是只有 F5）"):
		return
	check(btn.visible and not btn.disabled, "按钮可见且可点（局中随时能存）")
	check(btn.text.strip_edges() != "", "按钮上有文案（现在是「%s」）" % btn.text)
	check(btn.tooltip_text.find("F5") >= 0,
		"提示里说了另一条路 F5（现在是「%s」）" % btn.tooltip_text)
	# 和左下角另外两颗不许重叠：三颗都是 BOTTOM_LEFT 锚点、靠 position 错开
	for other in [main.btn_net, main.btn_resign]:
		if other != null:
			check(absf(btn.position.y - (other as Button).position.y) >= 44.0,
				"和「%s」错开（y=%.0f / %.0f，按钮高 44）"
					% [(other as Button).text, btn.position.y,
						(other as Button).position.y])
	var n_before := t2.size()
	var files_before := _tape_files()
	btn.emit_signal("pressed")
	await settle()
	var files_after := _tape_files()
	check(files_after.size() == files_before.size() + 1,
		"点一下真存出一份（录像目录 %d → %d 份）"
			% [files_before.size(), files_after.size()])
	for f in files_after:
		if not files_before.has(f):
			DirAccess.remove_absolute(Tape.path_dir().path_join(f))
	check(t2.recording() and t2.size() == n_before,
		"点按钮不打断这一局（还在录，步数没变）")


## 录像目录里现有的文件名。用来判「点一下多出一份」——
## 比对文件名集合而不是数个数：这样删的时候能只删新出来那份
func _tape_files() -> Array:
	var out: Array = []
	var d := DirAccess.open(Tape.path_dir())
	if d == null:
		return out
	for f in d.get_files():
		out.append(f)
	return out
