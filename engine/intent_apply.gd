# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name IntentApply
extends RefCounted

## 意图裁决 —— 唯一一处「意图能不能落地」的判断（engine/intent.gd 与 engine/intent_apply.gd）
##
## 联网时这段代码跑在服务器上，客户端只发意图、只读结果。单机局也走同一条路，
## 只是服务器就在同一个进程里（LocalTransport）。所以这里的规矩是：
##   - **不信任 intent 里的任何派生量**。攻击目标的 cost 不从包里读，
##     从状态重算；付款的 uid 要验归属。客户端能报的只有「我选了哪几张」
##   - 判定失败要给 code，表现层拿它决定抖一下还是弹一句
##   - 状态怎么变**只走 GameState / Settle 的现有入口**，这里不自己动 players/combos
##
## 点数池归这里管（原先在 scenes/main.gd 的 _attack_pools）：
## apply_attack 是原地扣 pools 的，池子放在场景层就等于「扣多少由客户端说」。
## 装弹产出的池子存在 _pools 里，按座位索引，攻击回合结束时清掉

## 一条意图**落地了**。参数就是 apply() 的返回值（同一个 Dictionary 实例）。
##
## 为什么公告点在这里而不是只在 Transport：并非每条落地的意图都经过 submit()。
## BOTAgent 持有 applier 并逐条重放搜索计划，这些意图也必须通知表现层；原先
## **完全不可见** —— 于是 scenes/main.gd 只能靠「驱动对手的那段代码」顺手画对手，
## 而联网局里没有那段代码在跑（对手是人），对手侧就什么都不画。
##
## 所以规矩是：**意图在哪儿落地，就在哪儿公告**。谁想看都连这个信号，
## 不必关心这条意图是自己 submit 的、BOT 内部 apply 的、还是服务器推进阶段发的。
## 只在成功时发 —— 被拒的意图没有「落地」，它走 Transport.rejected
signal landed(result: Dictionary)

## 同一条意图落地了，报的是**输入**那一半：规范化后的意图 + 它的来路座位。
##
## 为什么不能只听 landed：结果里没有、也不该有玩家的选择。买卡的
## `pay_uids`（「我要用这几张现金付」）在意图里，结果里只有 `removed_uids`
## （引擎实际扣的前 price 张）—— 那是输出。拿结果反推意图，反推出来的
## 是「引擎当时做了什么」而不是「玩家当时要求什么」，重放到分叉点之后
## 就再也追不上（tests/test_net_replay.gd 的 _send 为此专门记原件）。
##
## from_seat 也得报：它不在意图里（意图里的 seat 是包里自称的那个），
## 而阶段推进那几条**必须**以空 from_seat 落地，否则 apply 里
## 「客户端不能自己推进阶段」当场拒掉。录磁带的人要把它一起存下来。
##
## 谁听这个信号：engine/tape.gd（存档 / 重放）。它比 landed 晚加，
## 所以是两个信号而不是给 landed 加参数 —— 后者要改掉每一处 connect
signal landed_intent(intent: Dictionary, result: Dictionary, from_seat: String)

var state: GameState

## seat -> {cash: n, user: m}。只有装过弹的座位才有条目
var _pools: Dictionary = {}

func _init(s: GameState) -> void:
	state = s

# ---------- 查询（表现层读这些，不要自己存一份池子） ----------

## 这个座位现在的点数池。没装弹时返回空池而不是报错 ——
## HUD 在攻击阶段之外也会念它
func pools(seat: String) -> Dictionary:
	return _pools.get(seat, { CardDB.RES_CASH: 0, CardDB.RES_USER: 0 })

func armed(seat: String) -> bool:
	return _pools.has(seat)

## 直接把某座位的点数池摆成指定值，**只给测试和调试钩子用**。
## 正常路径一律走 OP_ARM（装弹要真扣配方现金）—— 这个口子绕开了扣款，
## 用它是为了让「点一摞扣几张」这类判据不必先凑出一套能装弹的阵型
func seed_pool_for_test(seat: String, cash: int, user: int) -> void:
	_pools[seat] = { CardDB.RES_CASH: cash, CardDB.RES_USER: user }

func pool_empty(seat: String) -> bool:
	var p := pools(seat)
	return int(p[CardDB.RES_CASH]) <= 0 and int(p[CardDB.RES_USER]) <= 0

# ---------- 池子的快照（联网 / 重连用） ----------

## 点数池的可上网形态。
##
## 为什么它不在 StateCodec 里：池子**不在 GameState 上**，它是裁决器的成员
## （见文件头那段：apply_attack 原地扣池，池子放在场景层就等于「扣多少由客户端说」）。
## 而 StateCodec.snapshot 只认 GameState —— 于是联网局有一个洞：
## 服务器装完弹广播了全量状态，客户端那份状态**对**，可它的裁决器池子是空的。
## 症状是 pool_empty(seat) 当场为真 —— 攻击回合被整段跳过，
## 一条错都不报（客户端的 _await_foe_attack 就是循环判它）
##
## 也不能塞进 state_hash：装弹这件事在 Settle.attack_phase 那条无头路径上
## 是个**局部变量**（settle.gd 的 `var pools`），它跑完根本不落在任何地方。
## 把池子并进状态哈希，两条路径会在攻击阶段之后必然不等 ——
## 那是同构判据最不该出现的假红
func pools_snapshot() -> Dictionary:
	var out := {}
	for seat in _pools:
		var p: Dictionary = _pools[seat]
		out[str(seat)] = {
			CardDB.RES_CASH: int(p[CardDB.RES_CASH]),
			CardDB.RES_USER: int(p[CardDB.RES_USER]),
			# 「这一摞打到一半了」也得过去：它和点数一样是攻击回合的中途状态
			# （见 GameState.ATTACK_LOCK）。少了它，接手方 / 重连的客户端算出的
			# 可选靶比服务器宽 —— 界面会把「其实点不了的别的摞」标红，
			# 点下去被服务器打回来
			GameState.ATTACK_LOCK: GameState.attack_lock(p),
		}
	return out

## 覆盖进池子。**整份替换**，不是合并：装过弹的座位有条目、没装的没有，
## 而 armed() 判的就是「有没有条目」（重复装弹要靠它拦）。
## 合并的话服务器 next_round 清空的那一份在客户端会留着 ——
## 下一回合客户端以为自己已经装过弹了
func pools_restore(d: Dictionary) -> void:
	_pools.clear()
	for seat in d:
		var p: Dictionary = d[seat]
		_pools[str(seat)] = {
			CardDB.RES_CASH: int(p.get(CardDB.RES_CASH, 0)),
			CardDB.RES_USER: int(p.get(CardDB.RES_USER, 0)),
			GameState.ATTACK_LOCK: str(p.get(GameState.ATTACK_LOCK, "")),
		}

## 这个座位现在点得起对手身上的哪些靶
func affordable_targets(seat: String) -> Array:
	return state.affordable_targets(GameState.opponent(seat), pools(seat))

# ---------- 落地 ----------

## 主入口：意图（Dictionary 或 JSON 文本）→ 结果。
## 返回 { ok: true, op, seat, ... }（其余字段照抄引擎入口的返回值）
## 或 { ok: false, code, reason }
##
## 成功的结果会**同步**发一遍 landed（见那个信号的说明）。同步是有意的：
## 回调里看到的状态就是这条意图刚落地后的状态，中间没有别的意图插进来。
## 代价是回调不能 await —— 表现层的处理函数因此都是同步的画面更新，
## 需要 await 的节奏留在驱动那一侧（scenes/main.gd 的 _foe_action）
func apply(intent, from_seat := "") -> Dictionary:
	var dec: Dictionary = _shape(intent)
	var r: Dictionary = dec if not dec["ok"] else _decide(dec["intent"], from_seat)
	if r.get("ok", false):
		# 先报**意图**再报结果。landed 是同步发的，所以它的回调里再落地一条
		# 意图时两条 apply 是嵌套的（外层还没 return，内层已经跑完），
		# 子意图的 landed_intent 就排在本条**之后** —— 换个顺序的话磁带里
		# 子意图排在父意图前面，重放时子意图先跑，它依赖的那张卡还没出现，
		# 整条磁带从这里开始全落不了地。
		#
		# 今天没有这样的回调（landed 唯一的订阅者是 LocalTransport._on_landed，
		# 只广播不落地），所以顺序错了一处都不红 ——
		# tests/test_tape.gd 的 T6c 为此专门造一个这样的回调
		landed_intent.emit(dec["intent"], r, from_seat)
		landed.emit(r)
	return r

## 意图的**形状**：Dictionary / JSON 文本 → { ok, intent } 或 { ok=false, code, reason }。
## 从 _decide 里拆出来只为了让 apply() 拿得到那份**规范化后的意图** ——
## landed_intent 要报的是它，不是入参（入参可能是一段 JSON 文本，
## 也可能是一份 uid 全是 double 的字典，两种都不能直接进磁带）
func _shape(intent) -> Dictionary:
	if intent is String:
		return Intent.decode(intent)
	if intent is Dictionary:
		return Intent.from_dict(intent)
	return Intent.err("bad_type", "意图既不是文本也不是对象")

## 真正的裁决。拆出来只为了让 apply() 有一个统一的出口发 landed ——
## 底下有十几条 return，在每条上面都补一行 emit 迟早会漏掉一条
func _decide(it: Dictionary, from_seat := "") -> Dictionary:
	var op: String = it["op"]
	var seat: String = it["seat"]

	# 冒充别人：from_seat 是连接自带的身份（谁连进来的），
	# seat 是包里自称的。联网时前者由服务器按连接认定，客户端伪造不了
	if from_seat != "" and Intent.is_client_op(op) and seat != from_seat:
		return Intent.err("wrong_seat", "不能替别的座位行动")
	# 客户端不能自己推进阶段。from_seat 为空 = 服务器自己驱动，放行
	if from_seat != "" and not Intent.is_client_op(op):
		return Intent.err("not_client_op", "阶段推进不由客户端发起")
	if Intent.SEAT_OPS.has(op) and not state.players.has(seat):
		return Intent.err("bad_seat", "没有这个座位：%s" % seat)
	# 已分胜负后只放 finalize 过：无头的 Settle.run 在任一攻击阶段打出胜负后
	# 仍然要收尾（解锁、清组合），拦掉它会让 locked 挂到下一局
	if state.winner != "" and op != Intent.OP_FINALIZE:
		return Intent.err("game_over", "这局已经结束了")

	match op:
		Intent.OP_BUY:
			return _tag(op, seat, state.buy(seat, it["market_idx"], it["pay_uids"]))
		Intent.OP_PAWN:
			return _tag(op, seat, state.pawn(seat, it["uids"]))
		Intent.OP_COMBO:
			return _tag(op, seat, state.create_combo(seat, it["uids"]))
		Intent.OP_RESIGN:
			# 不看阶段（见 Intent.OP_RESIGN）。上面那条 game_over 护栏已经
			# 挡掉了「结束后再认」，所以这里到得了就是真能认
			return _tag(op, seat, state.resign(seat))
		Intent.OP_ARM:
			return _arm(seat)
		Intent.OP_ATTACK:
			return _attack(seat, it["target"])
		Intent.OP_ATTACK_DONE:
			return _attack_done(seat, it.get("why", Intent.DONE_FORFEIT))
		Intent.OP_ACTION_DONE:
			# 状态不变 —— 组合是前面那几条 create_combo 建的。
			# 这条意图的收信人是**次序**（PhaseMachine.mark_done），不是 GameState。
			# 那为什么还要过裁决器：它得走同一套冒充校验和 seq 编号，
			# 不然「谁行动完了」就成了唯一一件绕过管道的玩家输入
			return { "ok": true, "op": Intent.OP_ACTION_DONE, "seat": seat }
		Intent.OP_PRODUCE:
			return _produce(it["combo_idx"])
		Intent.OP_FINALIZE:
			return _finalize()
		Intent.OP_NEXT_ROUND:
			return _next_round()
	return Intent.err("bad_op", "没接上的操作码：%s" % op)

## 引擎入口返回的是 {ok, ...}，补上 op/seat 让调用方不必自己记发的是哪条。
## 失败时补一个 code：pawn/create_combo 只给 reason，表现层要统一按 code 分支
func _tag(op: String, seat: String, r: Dictionary) -> Dictionary:
	r["op"] = op
	r["seat"] = seat
	if not r.get("ok", false) and not r.has("code"):
		r["code"] = "rejected"
	return r

# ---------- 攻击阶段 ----------

## 装弹一次。重复装弹是**必须**拦的：arm_attacks 会真扣配方现金
## （game_state.gd 的 _attack_recipe_payable，charge=true），
## 发两次就等于付两次弹药钱
func _arm(seat: String) -> Dictionary:
	if _pools.has(seat):
		return Intent.err("already_armed", "这个座位这回合已经装弹了")
	var p: Dictionary = state.arm_attacks(seat)
	_pools[seat] = p
	# 攻击阶段的表头战报落在这里，而不是留给驱动方（场景层 / Settle）自己写。
	# 两个驱动各写一遍就会飘 —— 无头局和界面局的战报本该逐字相同，
	# 那是 tests/test_intent.gd 的同构判据在比的东西
	var empty := int(p[CardDB.RES_CASH]) <= 0 and int(p[CardDB.RES_USER]) <= 0
	if not empty:
		state.log_fmt("—— %s 的攻击阶段：%s攻击×%d %s攻击×%d ——", [
			GameState.seat_arg(seat),
			CardDB.card_label(CardDB.RES_CASH), p[CardDB.RES_CASH],
			CardDB.card_label(CardDB.RES_USER), p[CardDB.RES_USER]])
	return { "ok": true, "op": Intent.OP_ARM, "seat": seat,
		"pools": p.duplicate(), "empty": empty }

## 一次点选。
##
## 目标从**状态**里认领，不用包里那份：包里只带 kind/res/uids，
## cost 由 attack_targets() 现算。否则客户端报个 cost=0 就能白拆一整组
func _attack(seat: String, ref: Dictionary) -> Dictionary:
	if not _pools.has(seat):
		return Intent.err("not_armed", "还没装弹，不能点选")
	var pool: Dictionary = _pools[seat]
	var victim := GameState.opponent(seat)
	var found := {}
	for t in state.attack_targets(victim):
		if Intent.same_target(Intent.target_ref(t), ref):
			found = t
			break
	# 「靶不在了」和「点不起」要分开报：前者是状态已经变了（对手的组合刚被拆），
	# 后者是这一步不合法。表现层对前者该重画目标列表，对后者只该抖一下
	if found.is_empty():
		return Intent.err("no_target", "目标已不在场上")
	if not GameState.target_affordable(found, pool):
		return Intent.err("short_points", "点数不够（需要 %d 点（%s攻击），现有 %s）" % [
			int(found["cost"]), CardDB.card_label(found["res"]),
			GameState.pool_text(pool)])
	var r: Dictionary = state.apply_attack(seat, found, pool)
	if not r.get("ok", false):
		return _tag(Intent.OP_ATTACK, seat, r)
	state.check_victory()   # 清零即胜：打到 0 当场结束
	r["op"] = Intent.OP_ATTACK
	r["seat"] = seat
	r["target"] = found
	r["pools"] = pool.duplicate()
	return r

## 攻击回合结束：剩余点数作废。池子留着但清零 —— 删掉会让 armed() 变回 false，
## 那样同一回合还能再装一次弹（而装弹是真扣款的）
##
## exhausted 那句的措辞和 Settle.attack_phase 原来那条**逐字一致**：
## 两条驱动路径（无头 Settle / 界面场景）跑出来的战报要能对上，
## 那是 tests/test_intent.gd 的同构判据在比的东西
func _attack_done(seat: String, why := Intent.DONE_FORFEIT) -> Dictionary:
	if not _pools.has(seat):
		return Intent.err("not_armed", "这个座位没在攻击阶段")
	var pool: Dictionary = _pools[seat]
	var had := not pool_empty(seat)
	if had:
		if why == Intent.DONE_EXHAUSTED:
			state.log_fmt("%s 剩余点数（%s）点不起任何目标，余点作废", [
				GameState.seat_arg(seat), GameState.pool_text(pool)])
		else:
			state.log_fmt("%s 收手，余点作废（%s）", [
				GameState.seat_arg(seat), GameState.pool_text(pool)])
	pool[CardDB.RES_CASH] = 0
	pool[CardDB.RES_USER] = 0
	# 「在打哪一摞」跟着这一回合一起结束：池子清零后它已经没有作用，
	# 但留着会被 pools_snapshot 抄给接手方，读起来像「还有一摞打到一半」
	pool.erase(GameState.ATTACK_LOCK)
	return { "ok": true, "op": Intent.OP_ATTACK_DONE, "seat": seat,
		"why": why, "forfeited": had }

# ---------- 结算与收尾 ----------

## 结算第 combo_idx 组。下标取自 Settle.ordered_production_combos(state)，
## 每次重算 —— 组合列表在 finalize 之前不变，所以下标是稳的
func _produce(combo_idx: int) -> Dictionary:
	var ordered: Array = Settle.ordered_production_combos(state)
	if combo_idx < 0 or combo_idx >= ordered.size():
		return Intent.err("bad_combo_idx", "没有第 %d 组产出组合" % combo_idx)
	var combo: Dictionary = ordered[combo_idx]
	var resolution := Settle._resolve_combo(state, combo)
	return { "ok": true, "op": Intent.OP_PRODUCE, "seat": combo["owner"],
		"combo_idx": combo_idx, "combo": combo, "resolution": resolution }

## 本回合有几组要结算。场景层拿它当循环上界，不用自己去调 Settle
func production_count() -> int:
	return Settle.ordered_production_combos(state).size()

func _finalize() -> Dictionary:
	Settle.finalize(state)
	return { "ok": true, "op": Intent.OP_FINALIZE, "seat": "",
		"winner": state.winner }

## 回合收尾 + 开新回合。池子在这里清掉：下一回合要能重新装弹
func _next_round() -> Dictionary:
	_pools.clear()
	state.end_round()
	state.start_round()
	return { "ok": true, "op": Intent.OP_NEXT_ROUND, "seat": "",
		"round": state.round_num, "draw_first": state.draw_first }
