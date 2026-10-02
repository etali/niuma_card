# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name StateCodec
extends RefCounted

## GameState ↔ 可上网的全量状态快照，外加一个状态哈希。
##
## 两个用途，形状要求正好相反，所以是两个函数不是一个：
##   - snapshot/restore：重连要把整局搬过去，**每一个影响后续判定的字段都得在**
##   - state_hash：单机路径和联网路径要能比对，**必须与字典键序无关**
##
## 为什么先做全量而不是增量：状态由同一份快照完整恢复，
## 全量序列化让 desync「结构上不存在」；增量是把 desync 的可能性重新引进来。
##
## 哈希**不含 log**：日志是 {fmt,args}，args 里带 {seat} 这种视角量，
## 而且失败原因的措辞随时会改文案 —— 拿它当同构判据会天天误报。
## 要比日志有 tests/test_log_viewpoint.gd 专门管。
## 但 log 在 snapshot 里**要在**：重连的人得能读到这局之前发生了什么

# ---------- 快照 ----------

## GameState → Dictionary（可直接 JSON.stringify）。
##
## _uid 和 rng 状态都得带：
##   _uid 不带 → 重连后新发的卡 uid 从 0 重来，和场上现有的卡撞号，
##     而 uid 是归属校验和攻击目标引用的唯一凭据，撞号是静默的错
##   rng 状态不带 → 重连后公共区刷新走另一条随机流，两端从此看到不同的牌
static func snapshot(s: GameState) -> Dictionary:
	var players := {}
	for who in s.players:
		var cards: Array = []
		for c in s.players[who]["cards"]:
			cards.append(_card_out(c))
		players[str(who)] = { "cards": cards }
	var combos: Array = []
	for combo in s.combos:
		combos.append({
			"owner": str(combo["owner"]),
			"uids": Intent.ints(combo["uids"]),
			"eval": (combo["eval"] as Dictionary).duplicate(true),
		})
	return {
		"players": players,
		"market": s.market.duplicate(),
		"combos": combos,
		"round_num": s.round_num,
		"draw_first": s.draw_first,
		"winner": s.winner,
		"win_reason": s.win_reason,
		"log": s.log.duplicate(true),
		"uid": s.peek_uid(),
		"rng": s.rng_snapshot(),
	}

## 一张卡的可上网形态。旧快照里的 armed_round 保留往返兼容，
## 新防御 Buff 不再写入它，保护规则也不读取它。
## fired_round 供共享攻击演出定位已开火的核心，网络/录像快照也要保留。
static func _card_out(c: Dictionary) -> Dictionary:
	var out := {
		"uid": int(c["uid"]),
		"def_id": str(c["def_id"]),
		"locked": bool(c.get("locked", false)),
	}
	if c.has("armed_round"):
		out["armed_round"] = int(c["armed_round"])
	if c.get("fired_round") is int or c.get("fired_round") is float:
		out["fired_round"] = int(c["fired_round"])
	return out

## Dictionary → 覆盖进一个已有的 GameState。
##
## 为什么是「覆盖进已有对象」而不是 new 一个：场景层和 IntentApply 都持有
## state 的引用，换对象要把每个持有点都改一遍（而漏掉一个就是「界面还在读旧局」）。
## 重连的语义本来也是「这一局变成那样」，不是「换一局」
static func restore(s: GameState, d: Dictionary) -> void:
	var players := {}
	var src: Dictionary = d.get("players", {})
	for who in src:
		var cards: Array = []
		for c in (src[who] as Dictionary).get("cards", []):
			cards.append(_card_out(c))
		players[str(who)] = { "cards": cards }
	s.players = players
	s.market = Array(d.get("market", [])).duplicate()
	var combos: Array = []
	for combo in d.get("combos", []):
		combos.append({
			"owner": str((combo as Dictionary).get("owner", "")),
			"uids": Intent.ints((combo as Dictionary).get("uids", [])),
			"eval": ((combo as Dictionary).get("eval", {}) as Dictionary).duplicate(true),
		})
	s.combos = combos
	s.round_num = int(d.get("round_num", 1))
	s.draw_first = str(d.get("draw_first", GameState.PLAYER))
	s.winner = str(d.get("winner", ""))
	s.win_reason = str(d.get("win_reason", ""))
	s.log = Array(d.get("log", [])).duplicate(true)
	s.set_uid(int(d.get("uid", 0)))
	s.rng_restore(d.get("rng", {}))

## 不修改状态的边界校验，网络与录像共用。等待入座时允许空桌，开局后必须有双方。
static func snapshot_issue(value: Variant) -> String:
	if not value is Dictionary:
		return "snapshot 不是一个对象"
	var d: Dictionary = value
	for field in ["players", "market", "combos", "round_num", "draw_first", "winner", "win_reason", "log", "uid", "rng"]:
		if not d.has(field):
			return "快照缺少 %s" % field
	var issue := Intent.field_types(d, ["draw_first", "winner", "win_reason"], ["round_num", "uid"])
	if issue != "": return issue
	if not Intent.valid_integer(d["round_num"], 1) or not Intent.valid_integer(d["uid"], 0):
		return "快照回合或下一张卡编号无效"
	if d["draw_first"] not in [GameState.PLAYER, GameState.AI] or d["winner"] not in ["", GameState.PLAYER, GameState.AI]:
		return "快照座位无效"
	if not d["players"] is Dictionary or not d["market"] is Array or not d["combos"] is Array or not d["log"] is Array:
		return "快照卡牌、市场、组合或日志格式错误"
	var players: Dictionary = d["players"]
	if not players.is_empty() and (players.size() != 2 or not players.has(GameState.PLAYER) or not players.has(GameState.AI)):
		return "快照缺少双方卡牌"
	if players.is_empty() and (not d["market"].is_empty() or not d["combos"].is_empty()):
		return "空桌不能包含市场或组合"
	var seen := {}
	for seat in players:
		var player: Variant = players[seat]
		if not player is Dictionary or not player.get("cards") is Array:
			return "快照玩家卡牌格式错误"
		for card in player["cards"]:
			if not card is Dictionary or not card.has("uid") or not card.get("def_id") is String:
				return "快照卡牌格式错误"
			issue = Intent.field_types(card, ["def_id"], ["uid", "armed_round", "fired_round"], [], ["locked"])
			if issue != "": return issue
			if not Intent.valid_integer(card["uid"], 0) or int(card["uid"]) >= int(d["uid"]) or seen.has(int(card["uid"])):
				return "快照卡牌编号重复或超出范围"
			if CardDB.get_def(card["def_id"]).is_empty(): return "快照存在未知卡牌"
			seen[int(card["uid"])] = true
	for id in d["market"]:
		if not id is String or CardDB.get_def(id).is_empty(): return "快照存在未知市场卡牌"
	for combo in d["combos"]:
		issue = combo_issue(combo)
		if issue != "": return issue
		if not players.has(combo["owner"]): return "组合座位不在快照中"
	for entry in d["log"]:
		issue = log_issue(entry)
		if issue != "": return issue
	if not d["rng"] is Dictionary: return "随机状态格式错误"
	for field in ["seed", "state"]:
		var text: Variant = d["rng"].get(field)
		if not text is String or not text.is_valid_int(): return "随机状态必须使用整数字符串"
		var digits: String = text.trim_prefix("-").trim_prefix("+").lstrip("0")
		if digits.length() > 19 or (digits.length() == 19 and digits > ("9223372036854775808" if text.begins_with("-") else "9223372036854775807")):
			return "随机状态超出范围"
	return pools_issue(d.get("pools", {}))

## 带参数的日志稍后会执行格式化；数量和类型必须先验证，避免损坏快照在绘制时才报错。
static func log_issue(value: Variant) -> String:
	if not value is Dictionary or not value.get("fmt") is String or not value.get("args", []) is Array:
		return "快照日志格式错误"
	if value.has("round") and not Intent.valid_integer(value["round"], 1): return "日志回合无效"
	var args: Array = value.get("args", [])
	for arg in args:
		if arg is Dictionary:
			if arg.size() != 1 or arg.get("seat") not in [GameState.PLAYER, GameState.AI]: return "日志座位无效"
		elif not arg is String and not Intent.valid_number(arg):
			return "日志参数格式错误"
	# 无参数日志按纯文本显示，其中的百分号不参与格式化。
	if args.is_empty(): return ""
	var fmt: String = value["fmt"]
	var count := 0
	var i := 0
	while i < fmt.length():
		if fmt[i] != "%":
			i += 1
			continue
		i += 1
		if i < fmt.length() and fmt[i] == "%":
			i += 1
			continue
		# 游戏生成的日志只使用这三种无修饰占位符，拒绝其他格式控制字符。
		if i >= fmt.length() or fmt[i] not in ["s", "d", "f"] or count >= args.size(): return "日志格式占位符无效"
		if fmt[i] != "s" and not Intent.valid_number(args[count]): return "日志数值参数类型错误"
		count += 1
		i += 1
	return "" if count == args.size() else "日志参数数量不匹配"

static func pools_issue(value: Variant) -> String:
	if not value is Dictionary: return "攻击点数必须是对象"
	for seat in value:
		if seat not in [GameState.PLAYER, GameState.AI] or not value[seat] is Dictionary:
			return "攻击点数座位或格式无效"
		var pool: Dictionary = value[seat]
		for res in [CardDB.RES_CASH, CardDB.RES_USER]:
			if not Intent.valid_integer(pool.get(res, 0), 0): return "攻击点数必须是非负整数"
		if pool.has(GameState.ATTACK_LOCK) and not pool[GameState.ATTACK_LOCK] is String:
			return "攻击批次必须是文本"
	return ""

static func combo_issue(value: Variant) -> String:
	if not value is Dictionary or not value.get("owner") is String or not value.get("uids") is Array:
		return "组合格式错误"
	if value["owner"] not in [GameState.PLAYER, GameState.AI]: return "组合座位无效"
	var issue := Intent.field_types(value, ["owner"], ["order"], ["uids"])
	if issue != "": return issue
	if not GameState.validate_unique_uids(value["uids"]).is_empty(): return "组合含重复卡牌编号"
	return eval_issue(value.get("eval"))

static func eval_issue(value: Variant) -> String:
	if not value is Dictionary: return "组合效果必须是对象"
	var issue := Intent.field_types(value,
		["type", "leader", "reason", "output_res", "output_card", "attack_res", "recipe_res"],
		["output_n", "attack_n", "recipe_pay_n"], [],
		["valid", "protect_user", "protect_cash", "filled_by_fission"])
	if issue != "": return issue
	if value.get("type") not in ["production", "upgrade", "attack"] or not value.get("leader") is String:
		return "组合效果类型或核心缺失"
	if CardDB.get_def(value["leader"]).is_empty(): return "组合核心未知"
	for field in ["output_n", "attack_n", "recipe_pay_n"]:
		if value.has(field) and not Intent.valid_integer(value[field], 0): return "组合效果数量无效"
	match value["type"]:
		"production":
			if value.get("output_res") not in [CardDB.RES_CASH, CardDB.RES_USER] or not value.has("output_n"): return "产出效果不完整"
		"attack":
			if value.get("attack_res") not in [CardDB.RES_CASH, CardDB.RES_USER] or not value.has("attack_n"): return "攻击效果不完整"
		"upgrade":
			if not value.get("output_card") is String or CardDB.get_def(value["output_card"]).is_empty(): return "升级效果不完整"
	return ""

# ---------- 状态哈希 ----------

## 「两条路径跑出同一份状态吗」的判据
## （tests/test_net_parity.gd 比较单机与联网的状态哈希）。
##
## 卡的**顺序参与哈希**，这不是偷懒：付款取 pay.slice(0, price)、
## 保护配额按 uids 顺序取前 quota 张 —— 顺序是玩法的一部分，
## 两端顺序不同就是真的分叉了，不该被哈希抹平。
## 字典键序则**不**参与（见 _canon）：那个只反映谁先写的字段
static func state_hash(s: GameState) -> String:
	return canon_hash(_hash_payload(s))

## 哈希前的那份纯数据。判据红了的时候拿它 diff ——
## 只有哈希的话，「两端不一样」查不出是哪儿不一样
static func _hash_payload(s: GameState) -> Dictionary:
	var d := snapshot(s)
	d.erase("log")   # 见文件头：日志是视角量 + 文案会改
	# 开火历史只用于表现，不改变后续合法动作；沿用旧录像的规则哈希口径。
	for player in d["players"].values():
		for card in player["cards"]:
			card.erase("fired_round")
	return d

## 两个状态哪儿不一样。返回人读的行，空数组 = 一致。
## 给测试失败时用：光比哈希只能知道「不等」
static func diff(a: GameState, b: GameState) -> Array:
	var pa := _hash_payload(a)
	var pb := _hash_payload(b)
	var out: Array = []
	for k in pa:
		var sa := canon(pa[k])
		var sb := canon(pb.get(k, null))
		if sa != sb:
			out.append("%s: %s ≠ %s" % [k, sa.substr(0, 200), sb.substr(0, 200)])
	return out

## 任意纯数据 → 规范化文本 → md5。
## 卡表握手（net/server.gd 的 _on_join）和状态比对共用这一条，两处口径不会飘
static func canon_hash(v) -> String:
	return canon(v).md5_text()

## 规范化：字典按键排序，数组保序。
##
## 不能直接 JSON.stringify 的原因：Godot 的 Dictionary 记插入序，
## 同一份状态从不同路径攒出来（引擎直接改 / 过一趟 JSON 再 restore）
## 键序会不同，哈希就不等 —— 那是假分叉，会把真判据淹掉。
##
## 浮点单独走 %.10f：JSON 往返后 3 和 3.0 的 str() 不一样
## （uid 那类整数已经在 Intent.ints 里收过一遍，这里兜住剩下的）
static func canon(v) -> String:
	match typeof(v):
		TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))
			var parts: Array = []
			for k in keys:
				parts.append("%s=%s" % [str(k), canon((v as Dictionary)[k])])
			return "{" + ",".join(parts) + "}"
		TYPE_ARRAY:
			var items: Array = []
			for e in v:
				items.append(canon(e))
			return "[" + ",".join(items) + "]"
		TYPE_FLOAT:
			# 整值浮点写成整数：JSON 往返会把 3 变成 3.0，
			# 两端一个走引擎、一个走网络时会因此哈希不等
			if v == floor(v) and abs(v) < 1e15:
				return str(int(v))
			return "%.10f" % v
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_NIL:
			return "null"
		_:
			return str(v)

# ---------- 卡表握手 ----------

## 卡表哈希：net/server.gd 在握手时比较，不一致直接拒连。
##
## 历史上，可执行文件旁的旧 cards.json 曾被优先读取，造成规则来源不一致。
## 当前联网固定使用内置卡表，并通过完整规则指纹验证双方规则。
## 联网会把它放大成「两个人在玩不同的游戏」：价格、权重、产出全不一样，
## 而且**不会报错**，只表现为「对手那边怎么比我便宜」。
##
## AI 超参数不改变合法动作及其结果，因此不属于游戏规则指纹。
static func table_hash() -> String:
	return canon_hash(rules_snapshot())

## 网络指纹和录像规则证据共用同一份完整规则载荷。
static func rules_snapshot() -> Dictionary:
	CardDB.ensure_loaded()
	return {"cards": CardDB.all_cards().duplicate(true), "game": CardDB.game_rules().duplicate(true),
		"upgrade": CardDB.upgrade_rules().duplicate(true)}

## 只供带完整规则配置的旧录像迁移；网络握手不可接受缺少升级规则的旧指纹。
static func legacy_table_hash() -> String:
	CardDB.ensure_loaded()
	return canon_hash({"cards": CardDB.all_cards(), "game": CardDB.game_rules()})
