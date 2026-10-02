# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Intent
extends RefCounted

## 意图 —— 「谁想做什么」的纯数据形态；合法性由 IntentApply 裁决。
##
## 为什么要有这一层：每个规则操作都要有同一份意图表示。
## 单机局由 LocalTransport 调用裁决器，联网时同一个动作先发给服务器。
## 如果联网另写一条调用路径，「至少留 1 块」这类规则就会在一条路上修好、
## 另一条路上漏掉 —— 和 _try_buy / 拖拽买牌当初收敛到 _commit_buy 是同一件事。
## 所以单机局也走这条管道，联网只是把 transport 换掉。
##
## 这个文件只管**数据**：构造、编解码、形状校验。不碰 GameState，
## 不判断合不合法（那是 IntentApply 的事）—— 分开是因为客户端要造意图、
## 服务器要认意图，两边只共享这份编解码，不共享裁决权。

# ---------- 操作码 ----------

const OP_BUY := "buy"
const OP_PAWN := "pawn"
const OP_COMBO := "create_combo"
const OP_ATTACK := "apply_attack"
const OP_ATTACK_DONE := "attack_done"
## 行动阶段收手（「完成行动」那个按钮）。
##
## 今天这一步不出场景层：`_on_action_done` 直接调 `_finish_actions`。
## 联网之后它必须是一条意图 —— 服务器要靠它才知道该换手了，
## 而「谁行动完了」不能由对方客户端说（见 engine/phase_machine.gd 文件头）。
## 它自己不改任何状态：组合是前面那几条 create_combo 建的，
## 这条只推进次序，所以裁决器里是个空操作
const OP_ACTION_DONE := "action_done"
## 认输（左下角那个按钮）。
##
## 为什么是一条意图而不是场景层自己置 winner：认输是**唯一一个凭空定胜负**的操作，
## 而胜负要两边都算数。场景层自己改的话，联网局里我这边终局面板弹了、
## 对手那边还在等我行动 —— 他要等到超时才知道我走了，而且他那份 winner 是空的，
## 接着 rematch 都开不起来（room.reset_for_rematch 之前那局得先真的结束）。
##
## 它属于 CLIENT_OPS：认输是玩家的决定，服务器不会替谁认。但它和别的客户端操作
## 有一处不同 —— **不看阶段**。买卡/编组要在行动阶段、攻击点选要在攻击阶段，
## 认输在哪一步都成立（这也是它绕过 PhaseMachine 那套的理由：
## 认输不推进次序，它直接把次序作废）
const OP_RESIGN := "resign"
## 阶段推进：客户端不能发这些，由服务器（单机局是 LocalTransport）自己驱动
const OP_ARM := "arm_attacks"
## 结算是**逐组**推进的，不是一步跑完：场景层要一组一组演出
## （scenes/main.gd 的 _run_settle 里 for combo in combos: await ...）。
## 所以 produce 带一个下标，指 Settle.ordered_production_combos(state) 的第几组；
## 全组演完再单独发一条 finalize（解锁、清组合、判胜负）
const OP_PRODUCE := "produce"
const OP_FINALIZE := "finalize"
const OP_NEXT_ROUND := "next_round"

## 客户端**可以**发起的操作。这是白名单而不是黑名单：
## 以后加新操作时，忘了登记只会导致「发不出去」，不会导致「客户端能自己推进阶段」
const CLIENT_OPS := [OP_BUY, OP_PAWN, OP_COMBO, OP_ATTACK, OP_ATTACK_DONE,
	OP_ACTION_DONE, OP_RESIGN]

## 带座位的操作。produce / finalize / next_round 不属于任何一方，seat 是空串，
## 对它们校验「座位存在吗」会把每一条阶段推进都拦掉
const SEAT_OPS := [OP_BUY, OP_PAWN, OP_COMBO, OP_ATTACK, OP_ATTACK_DONE,
	OP_ACTION_DONE, OP_ARM, OP_RESIGN]

## 每个操作码除 op/seat 之外必须带的字段。decode 用它挡掉缺字段的包
const REQUIRED_FIELDS := {
	OP_BUY: ["market_idx", "pay_uids"],
	OP_PAWN: ["uids"],
	OP_COMBO: ["uids"],
	OP_ATTACK: ["target"],
	OP_ATTACK_DONE: [],
	OP_ACTION_DONE: [],
	OP_RESIGN: [],
	OP_ARM: [],
	OP_PRODUCE: ["combo_idx"],
	OP_FINALIZE: [],
	OP_NEXT_ROUND: [],
}

# ---------- 构造 ----------

## pay_uids 的**顺序是真输入**：buy() 里是 pay.slice(0, price)，
## 付的是前 price 张。所以它不能在对端重算，必须原样传过去
static func buy(seat: String, market_idx: int, pay_uids: Array = []) -> Dictionary:
	return { "op": OP_BUY, "seat": seat,
		"market_idx": int(market_idx), "pay_uids": ints(pay_uids) }

static func pawn(seat: String, uids: Array) -> Dictionary:
	return { "op": OP_PAWN, "seat": seat, "uids": ints(uids) }

static func create_combo(seat: String, uids: Array) -> Dictionary:
	return { "op": OP_COMBO, "seat": seat, "uids": ints(uids) }

## target 传的是**引用**（kind/res/uids），不是 attack_targets() 出来的整条目标。
## cost 故意不传：那是从状态推出来的量，让客户端报 cost 等于让它自己定价。
## 对端拿 uids 去 affordable_targets() 里认领回来（见 IntentApply.resolve_target）
static func apply_attack(seat: String, target: Dictionary) -> Dictionary:
	return { "op": OP_ATTACK, "seat": seat, "target": target_ref(target) }

## 攻击回合结束：剩余点数作废。
##
## why 分两种，因为战报要说清是哪一种：
##   "forfeit"   玩家主动收手（点得起但不点了）
##   "exhausted" 剩余点数点不起任何目标（引擎判定的，不是玩家的选择）
## 合成一条是不行的：前者是决策，后者是没得选，复盘时这两件事读起来不一样
const DONE_FORFEIT := "forfeit"
const DONE_EXHAUSTED := "exhausted"

static func attack_done(seat: String, why := DONE_FORFEIT) -> Dictionary:
	return { "op": OP_ATTACK_DONE, "seat": seat, "why": str(why) }

## 行动阶段收手。不带任何参数：这条意图的全部内容就是「我这边完了」
static func action_done(seat: String) -> Dictionary:
	return { "op": OP_ACTION_DONE, "seat": seat }

## 认输。seat 是**认输的那个**（不是赢的那个）—— 和别的客户端操作一致：
## seat 恒等于「谁发的」，服务器那道冒充校验（IntentApply.apply 的 wrong_seat）
## 才认得出来。写成赢家的话这条意图就自称是对手发的，会被自己的护栏挡掉
static func resign(seat: String) -> Dictionary:
	return { "op": OP_RESIGN, "seat": seat }

static func arm_attacks(seat: String) -> Dictionary:
	return { "op": OP_ARM, "seat": seat }

## 产出结算 / 回合收尾都不属于某个座位，seat 留空。
## combo_idx 指 Settle.ordered_production_combos(state) 的第几组
static func produce(combo_idx: int) -> Dictionary:
	return { "op": OP_PRODUCE, "seat": "", "combo_idx": int(combo_idx) }

static func finalize() -> Dictionary:
	return { "op": OP_FINALIZE, "seat": "" }

static func next_round() -> Dictionary:
	return { "op": OP_NEXT_ROUND, "seat": "" }

# ---------- 攻击目标引用 ----------

## 一条目标 → 可上网的最小引用。
## leader 不传：它是 def_id，从 uids 反查得到，传了就多一个能对不上的字段
static func target_ref(target: Dictionary) -> Dictionary:
	return {
		"kind": str(target.get("kind", "")),
		"res": str(target.get("res", "")),
		"uids": ints(target.get("uids", [])),
	}

## 两个引用指不指同一个靶。uids 按**集合**比：
## combo 核心那条的 uids 是遍历组合时攒出来的，顺序不该参与判等
static func same_target(a: Dictionary, b: Dictionary) -> bool:
	if str(a.get("kind", "")) != str(b.get("kind", "")):
		return false
	if str(a.get("res", "")) != str(b.get("res", "")):
		return false
	return uid_set(a.get("uids", [])) == uid_set(b.get("uids", []))

static func uid_set(uids: Array) -> Dictionary:
	var out := {}
	for u in uids:
		out[int(u)] = true
	return out

# ---------- 编解码 ----------

## JSON 里没有整数：数字过一趟 JSON 全变 float，uid 就成了 3.0。
## 用它当 Dictionary 的键、和 card["uid"] 比较，都会静默不相等 ——
## 报出来的是「包含不属于你的卡」，看着像归属校验的 bug。
## 所以每个 uid 数组都从这里过一遍
static func ints(a) -> Array:
	var out: Array = []
	if valid_uids(a):
		for v in a:
			out.append(int(v))
	return out

## JSON 数字只能精确表达这一范围的整数；先验类型再转换，拒绝 bool、NaN 和截断。
const MAX_WIRE_INTEGER := 9007199254740991

static func valid_integer(value: Variant, minimum := -MAX_WIRE_INTEGER) -> bool:
	if not (value is int or value is float):
		return false
	return is_finite(float(value)) and value >= minimum and value <= MAX_WIRE_INTEGER \
		and float(value) == floorf(float(value))

static func valid_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func valid_uids(value: Variant) -> bool:
	if not value is Array:
		return false
	for uid in value:
		if not valid_integer(uid, 0):
			return false
	return true

## 字段存在时才校验；必填字段仍由各消息的 REQUIRED 表定义。
static func field_types(d: Dictionary, strings: Array = [], integers: Array = [],
		uid_arrays: Array = [], booleans: Array = []) -> String:
	for key in strings:
		if d.has(key) and not d[key] is String:
			return "%s 必须是文本" % key
	for key in integers:
		if d.has(key) and not valid_integer(d[key]):
			return "%s 必须是可精确表示的整数" % key
	for key in uid_arrays:
		if d.has(key) and not valid_uids(d[key]):
			return "%s 必须是非负整数编号数组" % key
	for key in booleans:
		if d.has(key) and not d[key] is bool:
			return "%s 必须是布尔值" % key
	return ""

static func encode(intent: Dictionary) -> String:
	return JSON.stringify(intent)

## 解码 + 形状校验。返回 { ok, intent } 或 { ok=false, code, reason }。
##
## 这里只认形状，不认合法性：座位对不对、这张卡是不是你的、点数够不够，
## 全归 IntentApply。分开是因为形状错说明**发包的代码**有 bug（或是伪造包），
## 合法性错说明**玩家**这一步走不了 —— 前者要拒包，后者要给玩家看原因
## 实例版 JSON 而不是 JSON.parse_string()：同 Protocol.decode 的理由 ——
## 后者解不开时自己打一条引擎 ERROR 加一屏回溯，而这里的入参来自网络
static func decode(text: String) -> Dictionary:
	var j := JSON.new()
	if j.parse(text) != OK:
		return err("bad_json", "不是合法 JSON（第 %d 行：%s）" % [
			j.get_error_line(), j.get_error_message()])
	if not (j.data is Dictionary):
		return err("bad_json", "意图不是一个 JSON 对象")
	return from_dict(j.data)

## 已经是 Dictionary 的入口（本地 transport 不必绕一趟字符串）。
## 注意这里仍然**重建**而不是原样放行：本地路径也要过同一套字段校验，
## 否则「只有联网时才会报的形状错」就成了必然
static func from_dict(d: Dictionary) -> Dictionary:
	var issue := field_types(d, ["op", "seat", "why"], ["market_idx", "combo_idx"], ["uids", "pay_uids"])
	if issue != "":
		return err("bad_field", issue)
	var op := str(d.get("op", ""))
	if not REQUIRED_FIELDS.has(op):
		return err("bad_op", "未知操作码：%s" % op)
	for f in REQUIRED_FIELDS[op]:
		if not d.has(f):
			return err("missing_field", "%s 缺字段 %s" % [op, f])
	var seat := str(d.get("seat", ""))
	var out := { "op": op, "seat": seat }
	match op:
		OP_BUY:
			out["market_idx"] = int(d["market_idx"])
			out["pay_uids"] = ints(d["pay_uids"])
		OP_PRODUCE:
			out["combo_idx"] = int(d["combo_idx"])
		OP_ATTACK_DONE:
			# why 缺省按「主动收手」算：老包 / 手写包不带这个字段时
			# 不该整条被拒，只是战报少一点信息
			var why := str(d.get("why", DONE_FORFEIT))
			if not why in [DONE_FORFEIT, DONE_EXHAUSTED]:
				return err("bad_why", "未知的收手原因：%s" % why)
			out["why"] = why
		OP_PAWN, OP_COMBO:
			out["uids"] = ints(d["uids"])
			if out["uids"].is_empty():
				return err("empty_uids", "%s 的卡列表是空的" % op)
		OP_ATTACK:
			if not (d["target"] is Dictionary):
				return err("bad_target", "target 不是一个对象")
			issue = field_types(d["target"], ["kind", "res"], [], ["uids"])
			if issue != "":
				return err("bad_target", issue)
			var t := target_ref(d["target"])
			if t["uids"].is_empty():
				return err("bad_target", "target 没有 uids")
			if not t["kind"] in ["combo", "spare", "card"]:
				return err("bad_target", "未知目标类型：%s" % t["kind"])
			out["target"] = t
	return { "ok": true, "intent": out }

static func err(code: String, reason: String) -> Dictionary:
	return { "ok": false, "code": code, "reason": reason }

## 客户端发得起这个操作码吗（阶段推进只能由服务器发）
static func is_client_op(op: String) -> bool:
	return CLIENT_OPS.has(op)

## 给日志/调试用的一行摘要。不进协议
static func brief(intent: Dictionary) -> String:
	var op := str(intent.get("op", "?"))
	var seat := str(intent.get("seat", ""))
	match op:
		OP_BUY:
			return "%s buy #%d pay%s" % [seat, int(intent.get("market_idx", -1)),
				str(intent.get("pay_uids", []))]
		OP_PAWN, OP_COMBO:
			return "%s %s %s" % [seat, op, str(intent.get("uids", []))]
		OP_ATTACK:
			var t: Dictionary = intent.get("target", {})
			return "%s attack %s/%s %s" % [seat, t.get("kind", "?"),
				t.get("res", "?"), str(t.get("uids", []))]
		_:
			return "%s %s" % [seat, op] if seat != "" else op
