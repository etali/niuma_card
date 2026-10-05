# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name GameState
extends RefCounted

## 回合状态机（对应设计文档第四节）
## 纯数据 + 纯函数，不依赖场景树

## 阶段（action/attack/settling/over）只归场景层管，见 scenes/main.gd 的 PHASE_*：
## 引擎这边不存 phase —— 两份记录会各说各话（真出现过 settle vs settling 这种
## 取值对不上，而引擎那份只写不读，对不上也没人发现）

## 运行时AI额度不进入状态编码、规则指纹或搜索副本。每座位每回合一份。
var ai_work_sessions: Dictionary = {}

const PLAYER := "player"
const AI := "ai"

## 典当和编组都要校验归属，报的是同一句话
const REASON_NOT_YOURS := "包含不属于你的卡"
## 引擎和场景层都要念这一句（场景层在卡飞走之前拦，引擎在动手之前拦），
## 所以放常量里而不是两边各写一遍字面量
const REASON_PAWN_ZERO_USER := "不能典当：用户会归零，那是当场判负（留着至少 1 个用户）"

## 战报里提到公司名的地方，引擎**不能**写死「你的公司」——
## 联网时服务器发的是同一份 state_snapshot，服务器没有视角，
## 同一句「XX 购入」在两个客户端要念成不同的公司名（README.md §「3. 文件目录结构」）。
##
## 座位是**字段**，不是文本里的子串：日志条目存
##   { round, fmt, args }   args 里的座位写成 { "seat": who }
## 渲染时把 seat 换成公司名，再套进 fmt 本来就有的 %s（见 render_entry）。
##
## 为什么不用「往文本里插哨兵再 replace」那种做法：那样日志是**半渲染**的
## —— 语序标点都定死了，却留着洞等字符串替换来补，既不是数据也不是展示层。
## 而哨兵不撞只是概率问题：第一版用裸的 "P"，replace 会命中文本里任何一个
## 字母 P（卡名、资源池文本、失效原因里都有），只好加定界符改成 "@P@"。
## 「必须加定界符才不撞」本身就是设计在报错，所以改成字段
const SEAT_KEY := "seat"

## 把座位包成日志参数。写日志时 args 里一律用它，不要直接放公司名
static func seat_arg(who: String) -> Dictionary:
	return { SEAT_KEY: who }

## 座位 → 界面上的公司名。措辞跟 HUD 对齐
## （scenes/main.gd 的 lbl_player_res / lbl_ai_res）
static func seat_name(who: String, my_seat: String) -> String:
	return "你的公司" if who == my_seat else "对手公司"

## 按视角把一条日志渲染成文本。
## my_seat 是「正在看这局的人」坐的座位 —— 单机局是 PLAYER，
## 联网时客户端 B 传 AI 进来，同一条日志就念成反过来的称呼。
##
## args 为空表示这条日志没有视角相关的参数，fmt 就是最终文本
## （开局提示、点选失败原因这类）。这时**不能**再套 fmt % []：
## 文本里带字面 % 会当场报错
static func render_entry(entry: Dictionary, my_seat: String) -> String:
	var fmt: String = entry.get("fmt", "")
	var args: Array = entry.get("args", [])
	if args.is_empty():
		return fmt
	var out: Array = []
	for a in args:
		if a is Dictionary and a.has(SEAT_KEY):
			out.append(seat_name(a[SEAT_KEY], my_seat))
		else:
			out.append(a)
	return fmt % out


## 座位 → { "cards": [...] }。**这里没有 "name"**：名字是视角量，
## 引擎不存（存了就会有人去读它，而它在联网局里必然是错的）
var players: Dictionary = {}
var market: Array = []          # 公共区 def_id 列表
var combos: Array = []          # {owner, uids:[], eval:{}}
var round_num := 1
var draw_first: String = PLAYER # 本回合抽卡先手（组卡后手）
var winner := ""                # "player" / "ai" / ""
var win_reason := ""
var log: Array = []
var _uid := 0

## 观测量：**只写不读**，胜负、结算、快照都不看它。给历史诊断脚本数「克制」次数用：
## 一次攻击让对手一个成立的组合变成不成立；规则依据见 README.md §「2.9 攻击」。
## 当前手动调参的 Q1–Q9 不使用这个计数，不把它解释为玩家体验分数。
##
## 为什么计数落在引擎里而不是模拟器里：攻击有三条路径 —— 无头 Settle.attack_phase、
## 联网 Transport.run_attack_phase、界面 Intent.apply_attack —— 三条都汇到 apply_attack。
## 只在模拟器埋点就只量到无头那一条，量出来的是「另一个游戏」
##
## 不进 StateCodec 是刻意的：它不参与规则，重连丢了也不影响这一局怎么打
## （联网局两端的这个数因此会各算各的，评估只跑无头局，用不着它对齐）
var stats: Dictionary = { "voided": { PLAYER: 0, AI: 0 } }

var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()

## 固定随机种子（无头模拟器/测试复现用）
func set_seed(s: int) -> void:
	_rng.seed = s

## 引擎内统一随机源（AI 决策也用，保证同种子可复现）
func next_float() -> float:
	return _rng.randf()

# ---------- 快照用的访问器（StateCodec 用，正常玩法不该碰） ----------
## _uid 和 _rng 是私有的，但重连快照必须能存取它们（见 engine/state_codec.gd）：
##   uid 不还原 → 新发的卡和场上的卡撞号，而 uid 是归属校验和攻击目标引用的
##     唯一凭据，撞号不报错，只表现为「点选打到了别的卡」
##   rng 不还原 → 两端从此走不同的随机流，公共区刷出不同的牌
## 写成方法而不是把变量改公开：这四个名字里带 snapshot/restore，
## grep 得出来谁在动这两个量（直接公开的话，将来会有人拿 _uid 当计数器用）

func peek_uid() -> int:
	return _uid

func set_uid(v: int) -> void:
	_uid = v

## RNG 的**当前位置**，不只是种子。
## 只存 seed 是不够的：seed 是起点，state 才是「已经抽到第几个数」——
## 只还原 seed 会让重连方从头再抽一遍，公共区和对手看到的对不上。
##
## 两个值都写成**字符串**：它们是 uint64，而 JSON 里的数字是 double，
## 超过 2^53 就静默丢精度（randomize() 出来的种子经常是 19 位数）。
## 丢了精度不会报错，只表现为「重连之后刷出来的牌和别人不一样」
func rng_snapshot() -> Dictionary:
	return { "seed": str(_rng.seed), "state": str(_rng.state) }

func rng_restore(d) -> void:
	if not (d is Dictionary):
		return
	if d.has("seed"):
		_rng.seed = int(str(d["seed"]))
	if d.has("state"):
		_rng.state = int(str(d["state"]))

# ---------- 开局 ----------

## 开一局。**同一个对象调第二次也必须是干净的一局** ——
## 单机局的「再战一局」是换一个 GameState，所以第一版只清了 players 就够；
## 但联网的 rematch 不能换对象（场景层、IntentApply、NetTransport 三处都
## 持着这一份的引用，换对象要挨个改，漏一处就是「界面还在读上一局」，
## 和 StateCodec.restore 选择「覆盖进已有对象」是同一个理由）。
##
## 于是这里必须自己复位。少清哪一个的症状各不相同，而且都不报错：
##   winner/win_reason —— 最狠的一个：IntentApply 和 PhaseMachine 开头都有
##     「这局已经结束了」那道护栏，带着上一局的 winner 进新局 =
##     每一条意图都被静默拒掉，桌子摆得好好的但一步也走不了
##   round_num  —— 新局从「第 7 回合」开始，战报和 HUD 全串
##   combos     —— 上一局的组合带着**上一局的 uid** 进新局，而 uid 是重新发号的
##                （见下面 _uid 那段）：结算时按 uid 找卡，找到的是另外几张
##   market     —— 开局前那一瞬的公共区是上一局的残牌（start_round 会刷掉，
##                但 new_game 到 start_round 之间读它的人看到的是旧的）
##
## **_uid 和 _rng 故意不清**：
##   _uid 接着发号，新局的卡不会和上一局撞号。撞号在联网局里是静默的错 ——
##     拖拽租约、攻击目标、保护名单全按 uid 认卡（scenes/main.gd 的
##     _reset_session_flags 里 _drag_lease 那段说的就是这件事）
##   _rng 接着走，rematch 才是**另一副牌**。清成同一个种子的话
##     「再来一局」会逐张复现上一局的公共区，那不是再来一局，是重播
##
## first: 抽卡先手。留空 = 沿用当前值（单机局照旧从 PLAYER 开）。
## 联网 rematch 传对手，让先手在局间轮换（net/room.gd 的 reset_for_rematch）
func new_game(first := "") -> void:
	ai_work_sessions.clear()
	players = {
		PLAYER: { "cards": [] },
		AI: { "cards": [] },
	}
	combos.clear()
	market.clear()
	log.clear()
	round_num = 1
	winner = ""
	win_reason = ""
	if first != "":
		draw_first = first
	var rules: Dictionary = CardDB.game_rules()
	for who in [PLAYER, AI]:
		for i in rules["start_cash"]:
			add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		for i in rules["start_user"]:
			add_card(who, CardDB.unit_id(CardDB.RES_USER))
	# 初始资源由 cards.json 的 _game 段配置（之后没有自动补给，资源只能靠组合产出）
	log_msg("开局！双方各有 %s×%d + %s×%d。没有回合补给，全靠经营。公共区每回合刷新，先到 %d %s者胜。" % [
		CardDB.card_label(CardDB.RES_CASH), rules["start_cash"],
		CardDB.card_label(CardDB.RES_USER), rules["start_user"],
		rules["win_cash"], CardDB.res_label(CardDB.RES_CASH)])
	start_round()

func add_card(who: String, def_id: String, locked := false) -> Dictionary:
	var card := {
		"uid": _uid, "def_id": def_id, "locked": locked,
	}
	_uid += 1
	players[who]["cards"].append(card)
	return card

func remove_card(who: String, uid: int) -> bool:
	var cards: Array = players[who]["cards"]
	for i in cards.size():
		if cards[i]["uid"] == uid:
			cards.remove_at(i)
			return true
	return false

func find_card(who: String, uid: int) -> Dictionary:
	for c in players[who]["cards"]:
		if c["uid"] == uid:
			return c
	return {}

# ---------- 资源统计 ----------

## 资源总量 = 单位卡数量（传说卡没有折算面值，唯一用途是典当变现）
func resource_count(who: String, res: String) -> int:
	var n := 0
	for c in players[who]["cards"]:
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == res:
			n += 1
	return n

# ---------- 抽卡阶段 ----------

func start_round() -> void:
	# 公共区重新生成（无回合配给：资源只能靠组合产出）
	log_msg("—— 第 %d 回合 —— 公共区刷新" % round_num)
	# 公共区重新生成
	market.clear()
	var pool := CardDB.market_pool()
	var total := CardDB.total_weight()
	for i in CardDB.game_rules()["market_size"]:
		market.append(_weighted_pick(pool, total))

func _weighted_pick(pool: Array, total: int) -> String:
	var roll := _rng.randi_range(1, total)
	var acc := 0
	for e in pool:
		acc += e["weight"]
		if roll <= acc:
			return e["def_id"]
	return pool[-1]["def_id"]

## 实体不能重复投入；购买、典当和编组共用同一道检查，并在任何状态变动前执行。
static func validate_unique_uids(uids: Array, duplicate_reason := "同一张卡不能重复使用") -> Dictionary:
	if not Intent.valid_uids(uids):
		return Intent.err("bad_uids", "卡牌编号必须是非负整数")
	var seen := {}
	for uid in uids:
		if seen.has(int(uid)):
			return Intent.err("duplicate_uid", duplicate_reason)
		seen[int(uid)] = true
	return {}

## 购买：支付现金卡（移出游戏），卡牌进入己方区域。
## 唯一的购买入口 —— 玩家拖现金摞、AI 决策、无头模拟器都走这里，
## 否则「至少留 1 块」这类规则只在其中一条路上生效，另几条路玩的是另一个游戏。
##
## pay_uids —— 指定用哪几张现金付（玩家拖来的那一摞，多付的部分原样退回）；
##   空 = 自动挑未被组合锁的现金卡（AI / 模拟器）
## 失败时带 code，供表现层决定要不要抖一下：
##   bad_idx / unbuyable / not_cash / short / zero_out
func buy(who: String, market_idx: int, pay_uids: Array = []) -> Dictionary:
	var issue := validate_unique_uids(pay_uids)
	if not issue.is_empty():
		return issue
	if market_idx < 0 or market_idx >= market.size():
		return { "ok": false, "code": "bad_idx", "reason": "无效的公共区卡位" }
	var def_id: String = market[market_idx]
	var price: int = CardDB.get_def(def_id).get("price", -1)
	if price < 0:
		return { "ok": false, "code": "unbuyable", "reason": "该卡不可购买" }
	var pay: Array
	if pay_uids.is_empty():
		pay = _loose_unit_uids(who, CardDB.RES_CASH)
		if pay.size() < price:
			return { "ok": false, "code": "short",
				"reason": "现金不足（需要 %d，现有 %d）" % [price, pay.size()] }
	else:
		# 拖来的必须全是自己的、未被组合锁的现金卡
		var loose := {}
		for u in _loose_unit_uids(who, CardDB.RES_CASH):
			loose[u] = true
		for u in pay_uids:
			if not loose.has(u):
				return { "ok": false, "code": "not_cash", "reason": "请用现金卡支付" }
		if pay_uids.size() < price:
			return { "ok": false, "code": "short",
				"reason": "现金不够：%d/%d" % [pay_uids.size(), price] }
		pay = pay_uids
	# 自杀护栏：付完这笔钱现金归零 = 当场判负（见 check_victory）。
	# 玩家、AI 和无头模拟共用此检查；AI 候选也必须通过真实购买接口。
	if resource_count(who, CardDB.RES_CASH) - price <= 0:
		return { "ok": false, "code": "zero_out",
			"reason": "不能买：付完资金会归零，回合结束就判负（至少留 1 块）" }
	var removed: Array = pay.slice(0, price)
	for u in removed:
		remove_card(who, u)
	market.remove_at(market_idx)
	var new_card := add_card(who, def_id)
	log_fmt("%s 购入「%s」（支付现金×%d）",
		[seat_arg(who), CardDB.card_name(def_id), price])
	# market_idx / def_id 回传给表现层：那一格已经从 market 里删掉了，
	# 光看结果没法知道该摘哪个市场实体。def_id 虽然能用 new_uid 去 find_card
	# 反查，但摆放要用它决定往哪个锚点落，直接给省一次反查
	return { "ok": true, "removed_uids": removed, "new_uid": new_card["uid"],
		"market_idx": market_idx, "def_id": def_id }

## 未被组合锁定的单位卡 uid 列表
func _loose_unit_uids(who: String, res: String) -> Array:
	var locked_uids := {}
	for combo in combos:
		if combo["owner"] == who:
			for u in combo["uids"]:
				locked_uids[u] = true
	var out: Array = []
	for c in players[who]["cards"]:
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == res \
			and not locked_uids.has(c["uid"]):
			out.append(c["uid"])
	return out

## 这一笔典当会送走几个用户（用户单位卡 1 张 = 1 个用户）。
## 单独拿出来是因为「会不会把自己当到归零」这条要在两个地方问：
## 典当动作自己要拦（下面 pawn()），场景层拖到典当行时也要先问一次
## —— 它得在卡还没飞走的时候就拦下并把卡放回去。原先场景层自己数了一遍
func pawn_users_lost(who: String, uids: Array) -> int:
	var n := 0
	for u in uids:
		var c := find_card(who, u)
		if c.is_empty():
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == CardDB.RES_USER:
			n += 1
	return n

## 这一笔典当会不会把用户当到归零（归零 = 当场判负）。
## 纯判定，不动状态：pawn() 用它拦，场景层也用它 —— 场景层必须在卡飞走之前问，
## 拿 pawn() 的返回值当判定就等于先当掉再问，卡已经回不来了
func pawn_would_zero_user(who: String, uids: Array) -> bool:
	return resource_count(who, CardDB.RES_USER) - pawn_users_lost(who, uids) <= 0

## 典当：回收非现金卡，转化为现金（典当行）
func pawn(who: String, uids: Array) -> Dictionary:
	var issue := validate_unique_uids(uids)
	if not issue.is_empty():
		return issue
	if uids.is_empty():
		return { "ok": false, "reason": "没有可回收的卡" }
	# 自杀护栏：用户归零 = 当场判负，不许靠典当把自己当死。
	# 这条是硬规则，所以在引擎里 —— 原先只有玩家侧（scenes/main.gd）拦着，
	# 合法性由环境统一决定，AI超参数不能允许典当清零。
	if pawn_would_zero_user(who, uids):
		return { "ok": false, "reason": REASON_PAWN_ZERO_USER }
	var total := 0
	for u in uids:
		var c := find_card(who, u)
		if c.is_empty():
			return { "ok": false, "reason": REASON_NOT_YOURS }
		var v := CardDB.pawn_value(c["def_id"])
		if v <= 0:
			var def := CardDB.get_def(c["def_id"])
			var reason := "这张卡出售价格为 0，无法出售"
			if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == CardDB.RES_CASH:
				reason = "典当行不收%s卡" % CardDB.card_label(CardDB.RES_CASH)
			return { "ok": false, "reason": reason }
		total += v
	for u in uids:
		remove_card(who, u)
	# locked 的语义是「本回合已编入组合」，回收所得是自由资金：
	# 标 locked 会让 AI 的组卡器（按 locked 播种候选池）看不见自己刚典当来的钱
	for i in total:
		add_card(who, CardDB.unit_id(CardDB.RES_CASH), false)
	log_fmt("%s 典当 %d 张卡，回收 %s×%d",
		[seat_arg(who), uids.size(), CardDB.card_label(CardDB.RES_CASH), total])
	check_victory()   # 典当变现可能直接冲过胜利线（传说卡=胜利筹码）
	# uids 回传是给表现层用的：典当掉的卡在状态里已经没了，
	# 光看结果没法知道该让哪几个实体飞出去。buy 早就回传 removed_uids，
	# 这里补齐同一件事（表现层只认结果，不许去翻发出去的那条意图 ——
	# 联网侧收到的广播里只有结果）
	return { "ok": true, "total": total, "uids": uids.duplicate() }

# ---------- 组卡阶段 ----------

func create_combo(who: String, uids: Array) -> Dictionary:
	var issue := validate_unique_uids(uids, ComboRules.REASON_DUPLICATE_CARD)
	if not issue.is_empty():
		return issue
	# 校验归属与占用
	for u in uids:
		if find_card(who, u).is_empty():
			return { "ok": false, "reason": REASON_NOT_YOURS }
	for combo in combos:
		for u in uids:
			if combo["uids"].has(u):
				return { "ok": false, "reason": "该卡本回合已参与其他组合" }
	var cards: Array = []
	for u in uids:
		cards.append(find_card(who, u))
	var eval := ComboRules.evaluate(cards)
	if not eval["valid"]:
		return { "ok": false, "reason": eval["reason"] }
	# 这里不设归零护栏，但**不是**因为编不出自杀局：现金配方就是第三条吃资源的路
	# （买卡的 zero_out、典当的 pawn_would_zero_user 是前两条），
	# 而它的护栏在 `Settle._pay_recipe`，晚整整一个回合才响。
	#
	# 不提前到这里拦，是因为编组这一刻算不出结算那一刻的现金：中间还会有别的组
	# 进账、买卡、典当、以及对手来打。这里拦就成了误拒。
	# 完成行动前的预检通过Settle.check_action_completion模拟整桌的执行顺序，
	# 无风险才提交组合；组卡本身仍允许修改中间阵型。
	combos.append({ "owner": who, "uids": uids.duplicate(), "eval": eval, "order": combos.size() })
	for u in uids:
		find_card(who, u)["locked"] = true
	log_fmt("%s 编成组合「%s」（%s）", [
		seat_arg(who),
		CardDB.card_name(eval["leader"]),
		_combo_desc(eval),
	])
	# uids 同上：表现层要知道这一组是哪几张才能把它们收拢摆好
	return { "ok": true, "eval": eval, "uids": uids.duplicate() }

func _combo_desc(eval: Dictionary) -> String:
	match eval["type"]:
		"production":
			# 产出说的是资源总量涨了多少 → 计量名（资金）
			return "产出 %s+%d" % [CardDB.res_label(eval["output_res"]), eval["output_n"]]
		"attack":
			# 攻击移走的是具体的牌 → 卡名（现金）
			return "攻击：移除对方%s×%d" % [CardDB.card_label(eval["attack_res"]), eval["attack_n"]]
		"upgrade":
			if eval["output_card"] != "":
				return "升级为「%s」" % CardDB.card_name(eval["output_card"])
			return "%s+%d" % [CardDB.res_label(CardDB.RES_CASH), eval["output_n"]]
	return ""

# ---------- 结算与收尾 ----------

## 行动先手方（= 本回合先手）：先买卡组卡、攻击先结算、产出先结算
func action_first() -> String:
	return draw_first

## 另一方。原先 14 处各写一遍 `PLAYER if who == AI else AI`，
## 三层（引擎/场景/工具）都有 —— 只有两方，这个派生本该只有一处
static func opponent(who: String) -> String:
	return PLAYER if who == AI else AI

## 本回合的行动次序 [先手, 后手]。买卡组卡、攻击、产出结算都按这个序走，
## 原先五处各自 `action_first()` + 手写后手（引擎两处、场景一处、模拟器一处、平衡工具一处）。
## 返回数组而不是两个值：调用方一律 `for who in state.action_order()`，
## 想只要先手就 `[0]` —— 那五处里有三处本来就是拿来 for 的
func action_order() -> Array:
	var first := action_first()
	return [first, opponent(first)]

# ---------- 攻击阶段：点数池 + 点选目标（设计文档 4.3） ----------

## 攻击池：who 所有完好攻击组合的点数，按攻击资源分池加总（eval.attack_n 已含热搜翻倍）
## 现金攻击的点只能打现金目标，用户攻击的点只能打用户目标，不交叉
## 返回 {RES_CASH: n, RES_USER: m}（键是资源名，不是卡的 def_id）
## 纯读：现在能打出多少点，不动状态。HUD、提示条、测试都念这个。
## 付不起弹药的攻击组合按 0 点算，读数和实际开火一致
func attack_pool(who: String) -> Dictionary:
	return _attack_pool(who, false)

## 攻击阶段开场调**一次**：扣掉各攻击组合的配方现金（README.md §「2.9 攻击」的装弹规则），返回实际点数池。
## 付不起的组合贡献 0 点并落一条战报 —— 由此产生一条本来就该有的互动：
## 先手方可以在自己的攻击阶段打掉后手方组合的核心，让那一组既不开火也不付款
##
## 和 attack_pool 分成两个名字而不是加个 charge 参数：一个名字叫 pool 的取值器
## 顺手把钱花掉，是任何一处「显示一下点数」的调用都会重复扣款的陷阱
func arm_attacks(who: String) -> Dictionary:
	return _attack_pool(who, true)

func _attack_pool(who: String, charge: bool) -> Dictionary:
	var pools := { CardDB.RES_CASH: 0, CardDB.RES_USER: 0 }
	for combo in combos:
		if combo["owner"] != who:
			continue
		if combo["eval"].get("type") != "attack":
			continue
		if not combo_intact(who, combo):
			continue
		if not _attack_recipe_payable(who, combo, charge):
			continue
		if charge:
			_mark_fired(who, combo)
			# 组里的 Buff 同样记一笔：attack_x2 翻的就是下面那个 attack_n，
			# 它和攻击卡是同一套装备，不该只保护其中一半
			mark_buff_worked(who, combo)
		var res: String = combo["eval"].get("attack_res", CardDB.RES_CASH)
		pools[res] += int(combo["eval"]["attack_n"])
	return pools

## 攻击组合的弹药付不付得起。charge=true 时真扣并落战报。
## 拦法和生产侧的 Settle._pay_recipe 一致，只是这里落战报后继续算别的组
func _attack_recipe_payable(who: String, combo: Dictionary, charge: bool) -> bool:
	var need := int(combo["eval"].get("recipe_pay_n", 0))
	if need <= 0:
		return true
	var payment := recipe_payment_check(who, combo)
	var pay: Array = payment["paid_uids"]
	var short: bool = payment.get("code", "") == "short_recipe"
	var suicide: bool = payment.get("code", "") == "resource_zero"
	if not charge:
		return not short and not suicide

	var leader_name := CardDB.card_name(combo["eval"].get("leader", ""))
	if short:
		log_fmt("✂ %s 的攻击组合「%s」弹药不足（需要 %s×%d，组里只剩 %d），这回合不开火", [
			seat_arg(who), leader_name,
			CardDB.card_label(CardDB.RES_CASH), need, pay.size()])
		return false
	if suicide:
		log_fmt("✂ %s 的攻击组合「%s」开火会让资金归零，这回合不开火",
			[seat_arg(who), leader_name])
		return false
	for u in pay:
		remove_card(who, u)
	log_fmt("⚔ %s「%s」装弹 −%s%d",
		[seat_arg(who), leader_name, CardDB.res_label(CardDB.RES_CASH), need])
	return true

## 组合当前还在场上的卡（按原顺序）
func combo_survivors(who: String, combo: Dictionary) -> Array:
	var out: Array = []
	for u in combo["uids"]:
		var c := find_card(who, u)
		if not c.is_empty():
			out.append(c)
	return out

## 齐整检查：组合此刻是否仍然成立（= 配方是否还满足）
## 判定口径是「重新评估存活的卡」而不是「一张都不能少」——
## 超出配方的富余投料被啃掉几张，配方还满着，产出就不该作废；
## 真要废掉整组，得咬穿配方需要的那几张（它们正好是防御 Buff 的保护额度）
func combo_intact(who: String, combo: Dictionary) -> bool:
	return combo_intact_without(who, combo, {})

## AI 的拆组收益预判共用齐整检查，不另写配方/裂变/升级规则，也不修改实局。
func combo_intact_without(who: String, combo: Dictionary, removed: Dictionary) -> bool:
	var alive := combo_survivors(who, combo)
	if not removed.is_empty():
		alive = alive.filter(func(c): return not removed.has(c["uid"]))
	if alive.size() < combo["uids"].size():
		var eval := ComboRules.evaluate(alive)
		if not eval["valid"]:
			return false
		# 类型/产物都不能变（例如富余卡被啃到升级判定翻转成另一种产物）
		if eval["type"] != combo["eval"].get("type", ""):
			return false
		if eval.get("output_card", "") != combo["eval"].get("output_card", ""):
			return false
	return true

## 防御 Buff 的保护额度：只护得住「配方真正需要的那几张」
## 额度 = 核心卡的配方需求量；升级组合是纯卡面合成、里面一张单位卡都没有，额度 0
## 允许超量投料，但超出配方的富余单位卡不在保护范围内——
## 否则一张 6 块的防御卡就能把全部身家停进一个组合，整条攻击线失效
##
## 裂变补满的组，配方真正占用的席位只有 1 张（其余全是富余）。
## 不按实际张数算的话，一张裂变会把组里全部 7 张用户一起纳入保护额度，
## 富余投料跟着免疫 —— 那正是「把身家塞进一个组合就免疫」的老病
static func protect_quota(eval: Dictionary) -> int:
	if eval.get("type") == "upgrade":
		return 0
	if eval.get("filled_by_fission", false):
		return 1
	return int(CardDB.get_def(eval.get("leader", "")).get("recipe_n", 0))

## 把场景层现搭的 `piles` 逐摞解成 `[{cards, eval}]`，只留**成立**的那些。
##
## 三个读 piles 的读数（pending_pay / pending_cash_income / user_deployment）
## 原先各抄一遍这七行：取 uids → find_card → 空的跳过 → evaluate → 不成立跳过。
## 三份口径必须一致 —— 「待付」和「预收」算的是同一批摞，一处多算一摞不成立的
## 就会让 HUD 上两个数对不上账，而那种不一致没有判据盯着（各自的判据只看自己那个数）。
##
## `cards` 一起返回是因为 user_deployment 还要数摞里真有几张用户卡；
## 另两个只用 eval
func _valid_pile_evals(who: String, piles: Array) -> Array:
	var out: Array = []
	for p in piles:
		var cards: Array = []
		for u in p.get("uids", []):
			var c := find_card(who, u)
			if not c.is_empty():
				cards.append(c)
		if cards.is_empty():
			continue
		var eval := ComboRules.evaluate(cards)
		if not bool(eval["valid"]):
			continue
		out.append({ "cards": cards, "eval": eval })
	return out

## 这一回合这些摞一共要掏多少现金（scenes/main.gd 的 _update_hud 中的「本回合待付」）。
##
## 输入 `[{uids: Array}]`，由场景层从 `board.groups` 现搭（见 main.gd `_core_piles`）。
## **不读 self.combos**，因为行动阶段那个数组是空的 —— `Settle.finalize` 每回合
## 清一次，玩家读 HUD 的整个阶段里它都没内容（组合要到 `_on_action_done`
## 才注册）。而「我这回合要付多少」正是行动阶段最该看见的数
##
## 只算**成立**的摞：不成立的摞结算时整组作废、一分钱不付（README.md §「2.6 组合与结算」），
## 把它的配方钱记进待付是在预告一笔不会发生的支出。
##
## 也**不扣掉「付不起会被拒」的那些**：`Settle._pay_recipe` 在付完归零时拒付，
## 那时这一摞作废。但待付的用途正是让玩家在结算前发现「要付 12 而我只有 10」——
## 先把付不起的减掉，读数会退回一个付得起的数字，那条警报就永远不响了
func pending_pay(who: String, piles: Array) -> int:
	var total := 0
	for pe in _valid_pile_evals(who, piles):
		total += int((pe["eval"] as Dictionary).get("recipe_pay_n", 0))
	return total

## 这一回合**先于付款到账**的现金（HUD 的归零预警要用）。
##
## 只数「不吃现金、产出现金」的摞：`Settle.ordered_production_combos` 把这拨
## 排在吃现金的前面，所以付款护栏看到的现金是「现在的 + 这笔」。
## 不含这笔的话，「进账 7、待付 10、手上 5」会被报成必废，而它其实付得起
func pending_cash_income(who: String, piles: Array) -> int:
	var total := 0
	for pe in _valid_pile_evals(who, piles):
		var eval: Dictionary = pe["eval"]
		if int(eval.get("recipe_pay_n", 0)) > 0:
			continue
		if str(eval.get("output_res", "")) == CardDB.RES_CASH:
			total += int(eval.get("output_n", 0))
	return total

## 这一回合**已经编好的组合**一共要掏多少现金（攻击弹药 + 生产配方）。
##
## 和 `pending_pay` 是一对，差别只在数据源，而这个差别是刚需：
## `pending_pay` 读场景层现搭的 `piles`，因为它服务行动阶段的 HUD，
## 那时 `self.combos` 还是空的（`Settle.finalize` 每回合清一次）。
## 这一个读 `self.combos`，因为它服务**编组当中**的决策 —— AI 在
## `build_combos` 里一轮轮往 `combos` 里塞，它要问的正是
## 「前面几组已经把钱占掉多少了」。
##
## 攻击和生产一起算：两边掏的是同一个钱包（`arm_attacks` 在攻击阶段扣、
## `Settle._pay_recipe` 在结算阶段扣），而护栏念的是扣到那一步时的余额
func committed_pay(who: String) -> int:
	var total := 0
	for combo in combos:
		if combo["owner"] != who:
			continue
		total += int(combo["eval"].get("recipe_pay_n", 0))
	return total

## 已经编好的组合里，**先于付款到账**的那笔现金。
##
## 口径和 `pending_cash_income` 相同（不吃现金、产出现金的生产组），
## 依据也一样 —— `Settle.ordered_production_combos` 把这一拨排在吃现金的前面。
## 只有数据源不同（`self.combos` 而不是 piles），理由见 `committed_pay`
##
## 多出来的那道 `type != "production"` 是冗余的：`output_res` 只有生产分支会设
## （ComboRules.evaluate，攻击设的是 attack_res、升级设 output_card），
## 所以 `output_res == 现金` 本身就蕴含生产。留着当明示，别照它去补另一处
func committed_cash_income(who: String) -> int:
	var total := 0
	for combo in combos:
		if combo["owner"] != who:
			continue
		var eval: Dictionary = combo["eval"]
		if eval.get("type") != "production":
			continue
		if int(eval.get("recipe_pay_n", 0)) > 0:
			continue
		if str(eval.get("output_res", "")) == CardDB.RES_CASH:
			total += int(eval.get("output_n", 0))
	return total

## 用户卡的席位部署情况（scenes/main.gd 的 _update_hud 中的「在岗 / 闲置」，对应 M13a 席位部署率）。
## 返回 {on_duty, idle}，两者相加 = 用户总量。
##
## 在岗的判据是**占着配方席位**，不是「在某个摞里」：一摞 7 张用户而配方只要 4 张，
## 富余那 3 张既不产出也拖不走，它们是闲置的最坏形态 —— 记成在岗的话
## 「闲置用户是发不了电的资本」这条读数就把最该警报的情形算成了健康。
## 额度口径和防御 Buff 的保护额度同源（protect_quota）：两处说的是同一批席位
func user_deployment(who: String, piles: Array) -> Dictionary:
	var total := resource_count(who, CardDB.RES_USER)
	var on_duty := 0
	for pe in _valid_pile_evals(who, piles):
		var cards: Array = pe["cards"]
		var eval: Dictionary = pe["eval"]
		if str(eval.get("recipe_res", "")) != CardDB.RES_USER:
			continue      # 现金配方的摞不占用户席位；升级组 recipe_res 是空串
		# 席位数按额度取，再和摞里真有的用户数取小：裂变补满的摞额度是 1，
		# 而那一摞可能只放了 1 张用户（额度 1、实有 1）；反过来
		# 一摞用户不够的组合根本不成立，走不到这里
		var seats := protect_quota(eval)
		var have := 0
		for c in cards:
			var def: Dictionary = CardDB.get_def(c["def_id"])
			if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == CardDB.RES_USER:
				have += 1
		on_duty += mini(seats, have)
	on_duty = mini(on_duty, total)   # 摞里的牌万一和手里的对不上，别报出「在岗 > 总量」
	return { "on_duty": on_duty, "idle": total - on_duty }

## 生产、攻击装弹和完成行动预检共用的配方付款护栏。只检查，不扣牌或写战报。
func recipe_payment_check(who: String, combo: Dictionary) -> Dictionary:
	var need := int(combo["eval"].get("recipe_pay_n", 0))
	var pay := recipe_pay_uids(who, combo)
	if need <= 0:
		return {"ok": true, "paid_uids": pay}
	var resource := str(combo["eval"].get("recipe_res", CardDB.RES_CASH))
	if pay.size() < need:
		return {"ok": false, "code": "short_recipe", "paid_uids": pay,
			"reason": "付不起配方（需要 %s×%d，组里只剩 %d）" % [CardDB.card_label(resource), need, pay.size()]}
	if resource_count(who, resource) - need <= 0:
		return {"ok": false, "code": "resource_zero", "resource": resource, "paid_uids": pay,
			"reason": "付掉 %s×%d 会让%s归零" % [CardDB.card_label(resource), need, CardDB.res_label(resource)]}
	return {"ok": true, "paid_uids": pay}

## 这一组结算时要被吃掉的现金卡 uid（按 uids 顺序取前 recipe_pay_n 张）。
## 扣款（Settle._pay_recipe）和消耗动画（scenes/main.gd）念的是同一份名单，
## 各数一遍的话动画吸走的和引擎吃掉的会是不同的牌
func recipe_pay_uids(who: String, combo: Dictionary) -> Array:
	var out: Array = []
	var need := int(combo["eval"].get("recipe_pay_n", 0))
	if need <= 0:
		return out
	var resource := str(combo["eval"].get("recipe_res", CardDB.RES_CASH))
	for u in combo["uids"]:
		if out.size() >= need:
			break
		var c := find_card(who, u)
		if c.is_empty():
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == resource:
			out.append(u)
	return out

## 攻击卡「刚开过火」：这一组真打出点数的回合号，记在组里每张攻击卡的**卡实例**上。
##
## 记在卡上而不是组合上：组合跨不过回合
## （`Settle.finalize` 每回合 `combos.clear()`），记在组合上等于每回合失忆。
##
## 每次都覆写，保留最近一次开火的回合，供后续状态观察使用。
##
## 只在 `charge=true` 时写：`attack_pool` 那条纯读路径（HUD、提示条）
## 一走就盖一个回合号的话，光把鼠标停在点数上都算开过火了
func _mark_fired(who: String, combo: Dictionary) -> void:
	for u in combo["uids"]:
		var c := find_card(who, u)
		if c.is_empty():
			continue
		if CardDB.get_def(c["def_id"]).get("kind") != CardDB.KIND_ATTACK:
			continue
		c["fired_round"] = round_num

## 这张攻击卡是不是上一回合（或本回合）刚开过火。
## 运行时开火历史供状态观察与搜索副本保留，不改变典当合法性。
func attack_just_fired(who: String, uid: int) -> bool:
	var c := find_card(who, uid)
	if c.is_empty() or not c.has("fired_round"):
		return false
	return round_num - int(c["fired_round"]) <= 1

## Buff 卡「刚立过功」：它所在的那一组这一回合真开了火 / 真产出了，
## 回合号记在 Buff 卡的**卡实例**上。写法和 `_mark_fired` 对称（每次覆写、记在卡上）。
##
## 为什么要单记一笔而不是问「它现在在不在组合里」：`Settle.finalize` 每回合
## `combos.clear()`，而 AI 的典当（`match_simulator` 的 action_phase）跑在重建组合**之前** ——
## 那一刻所有 Buff 在 `_pawn_candidate` 眼里都是无主散卡，和废牌一模一样
##
## 不带下划线（`_mark_fired` 带）：攻击那一路的调用方就在本文件里，
## 而这个还要给 `Settle._resolve_combo` 调 —— 生产/升级组合的「真结算了」
## 只有那边知道（齐整检查、配方付款都在那儿）。settle.gd 对 state 一向只调公开方法
func mark_buff_worked(who: String, combo: Dictionary) -> void:
	for u in combo["uids"]:
		var c := find_card(who, u)
		if c.is_empty():
			continue
		if CardDB.get_def(c["def_id"]).get("kind") != CardDB.KIND_BUFF:
			continue
		c["worked_round"] = round_num

## 这张 Buff 是不是上一回合（或本回合）刚立过功（所在组开火了或产出了）。
##
## AI 的典当挑选念这个。缘由和 `attack_just_fired` 一字不差：**这一张已经验证过能用**
## —— 配方凑齐了、组也成立、效果真结算过了。卖掉它等于把上回合攒的那一整套推倒重来。
##
## 实测（录像 20260912_161516）：AI 第 8 步花 8 块买热搜包年，第 10 步贴进山寨围剿，
## attack_x2 把攻击 4 翻成 8、真打出 8 次；第 24 步组合散开，第 26 步现金 4 低于
## 救急线 6，`_pawn_candidate` 从桶 0（Buff）挑走了它，收 4 块 —— 净亏 4 块加一个翻倍。
## 同一局里山寨围剿靠 `attack_just_fired` 活下来了：AI 保住了枪，卖掉了瞄准镜
func buff_just_worked(who: String, uid: int) -> bool:
	var c := find_card(who, uid)
	if c.is_empty() or not c.has("worked_round"):
		return false
	return round_num - int(c["worked_round"]) <= 1

## 防御 Buff 无需等待回合：有效组合入组时即生效。
## 保留这个查询接口供场景临时牌摞和 AI 使用；它只判断卡是否为防御 Buff，
## 不要求 create_combo 已注册。有效组合、资源种类和配方额度由 protected_uids 判定。
## 旧存档的 armed_round 不再参与保护规则。
func buff_armed(who: String, uid: int) -> bool:
	var c := find_card(who, uid)
	if c.is_empty():
		return false
	var def: Dictionary = CardDB.get_def(c["def_id"])
	return def.get("kind") == CardDB.KIND_BUFF and str(def.get("buff_type", "")) in [
		CardDB.protect_key(CardDB.RES_USER), CardDB.protect_key(CardDB.RES_CASH)]

## 组合内某资源实际受保护的 uid 集合：按 uids 顺序取前 quota 张
func protected_uids(who: String, combo: Dictionary, res: String) -> Dictionary:
	var out := {}
	var key := CardDB.protect_key(res)
	if not combo["eval"].get("valid", false) or not combo["eval"].get(key, false):
		return out
	if not combo_intact(who, combo):
		return out
	# Buff 必须仍在这一组里；历史保护标记不能让已经离组的 Buff 继续生效。
	if not _has_protect_buff(who, combo, res):
		return out
	# 裂变只补配方，不取消防御；其保护额度仍由 protect_quota 限为 1 张。
	var quota := protect_quota(combo["eval"])
	if quota <= 0:
		return out
	for u in combo["uids"]:
		if out.size() >= quota:
			break
		var c := find_card(who, u)
		if c.is_empty():
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == res:
			out[u] = true
	return out

## 组里有没有一张仍存在且护这种资源的防御 Buff
func _has_protect_buff(who: String, combo: Dictionary, res: String) -> bool:
	var want := CardDB.protect_key(res)
	for u in combo["uids"]:
		var c := find_card(who, u)
		if c.is_empty():
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_BUFF:
			continue
		if str(def.get("buff_type", "")) != want:
			continue
		if buff_armed(who, u):
			return true
	return false

## 某张卡当前是否被保护：所在组合完好、组内有对应防御 Buff，且该卡在保护额度之内
func is_protected(who: String, uid: int, res: String) -> bool:
	for combo in combos:
		if combo["owner"] != who or not combo["uids"].has(uid):
			continue
		if protected_uids(who, combo, res).has(uid):
			return true
	return false

## 点选目标列表：返回 [{kind, uids, cost, leader, res, batch}]
##   kind = "combo"/"card"/"spare"，uids = [uid]，
##   cost = `_game.attack_cost_per_card`（每张一份，组内组外同价），
##   res = "cash"/"user"
##
## batch —— 「这些靶在界面上是同一摞」。核心改成逐张计价之后，啃穿一个 7 席组
## 是 7 条意图而不是 1 条；驱动方不知道这 7 条是一件事的话，就会演成
## 7 次瞄准 + 7 声 + 7 朵爆花（实测 AI 打玩家 6323ms，玩家点同一个组 936ms ——
## 玩家那边 _attack_pile 早就是「一摞攒成一批」了）。
## 这个键让两侧对「一批」有同一个口径：一个组合一批、场上散卡按资源一批，
## 正好对上界面上收拢的那几摞（settle_layout 的 ai_combo_%d / ai_cash / ai_user）。
##
## 它同时是**规则单位**：「选中一摞就得把它打完才能转下一摞」这条由
## attack_lock 按 batch 锁（见 affordable_targets / apply_attack）。所以组合的
## batch 不带资源后缀 —— 界面上一个组合就是一摞，摞里可能既有现金卡又有用户卡
## （`_attack_pile` 一次点击就会把两种都啃掉）。按 (组,资源) 分批的话，
## 同一摞的第二种资源会被自己的锁挡住
## 不进 Intent.target_ref，所以不参与判等、也不上网：锁在服务器侧按 uids 反查
## 所有单位卡一律按 `_game.attack_cost_per_card` 逐张独立计价、逐张独立可点，
## 区别只在打掉之后配方还成不成立：
## - kind="combo"（配方核心）：核心少一张配方就不再满足 → 整组作废
##   （富余料能顶上的话不破，口径归 combo_intact 判，不在这里预判）
## - kind="spare"（超出配方的富余卡）：打掉不影响配方与产出
## - kind="card"（场上散单位卡）
##
## 核心原先是「一减到底」的整体靶（cost = 未保护核心张数，凑不满不可点）。
## 那个定价让「把卡编进组」变成硬掩体：单张攻击卡的点数够不到大组的整份核心，
## 那个 cost 就是碰不到的，余点也永远凑不满下一个组 —— 两条都是 bug。
## 现在组内组外同价，掩体改由防御 Buff 提供（受保护的核心卡照旧不进列表）
## 传说卡不可被攻击（胜利筹码只能被典当变现）；核心卡/Buff 卡（含裂变鬼才）不可点
func attack_targets(victim: String) -> Array:
	var out: Array = []
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var combo_of_uid := {}
	for combo in combos:
		if combo["owner"] != victim:
			continue
		for u in combo["uids"]:
			combo_of_uid[u] = combo
	for ci in combos.size():
		var combo: Dictionary = combos[ci]
		if combo["owner"] != victim:
			continue
		var quota := protect_quota(combo["eval"])
		for res in [CardDB.RES_CASH, CardDB.RES_USER]:
			# 该资源是不是这个组合的配方料；不是的话组内这种卡全算富余
			var recipe_res := _combo_recipe_res(combo["eval"])
			var need: int = quota if res == recipe_res else 0
			var core: Array = []
			var spare: Array = []
			var seen := 0
			for u in combo["uids"]:
				var c := find_card(victim, u)
				if c.is_empty():
					continue
				var def: Dictionary = CardDB.get_def(c["def_id"])
				if def.get("kind") != CardDB.KIND_UNIT or def.get("res") != res:
					continue
				seen += 1
				if seen <= need:
					if not is_protected(victim, u, res):
						core.append(u)
				else:
					spare.append(u)
			# 配方核心也按 attack_cost_per_card 逐张独立计价、逐张独立可点。
			# 原先这里把整份核心捆成一个 cost=core.size() 的整体靶，
			# 于是单张用户攻击面对席位多的组时一张也碰不到（「组合后的用户牌打不掉」），
			# 而且打完一个小组后的余点凑不满下一个组的整份核心 → 直接作废
			# （「消耗不完应当能继续打其他组合」）。两条症状是同一个门槛
			#
			# intact：这张核心所在的组此刻还成不成立。已经被打破的组，
			# 剩下的核心卡只是普通资源了 —— 「废掉整组」这份收益已经领过，
			# 再点一张不会让它更废。选靶的人（AI / 界面引导）靠这个字段
			# 把余点转去下一个还活着的组，而不是继续锤一具尸体。
			# 不进 Intent.target_ref，所以不参与判等、也不上网
			var still := combo_intact(victim, combo)
			var batch := "combo_%d" % ci
			for u in core:
				out.append({
					"kind": "combo", "uids": [u], "cost": per_card,
					"leader": combo["eval"].get("leader", ""), "res": res,
					"intact": still, "batch": batch,
				})
			for u in spare:
				out.append({
					"kind": "spare", "uids": [u], "cost": per_card,
					"leader": combo["eval"].get("leader", ""), "res": res,
					"batch": batch,
				})
	for c in players[victim]["cards"]:
		if combo_of_uid.has(c["uid"]):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT:
			# 散卡按资源归一批：界面上它们本来就摞成「现金堆 / 用户堆」，
			# 点一摞是一次攻击（_attack_pile），所以撕也该是一批
			out.append({ "kind": "card", "uids": [c["uid"]], "cost": per_card,
				"leader": c["def_id"], "res": def.get("res", CardDB.RES_CASH),
				"batch": "loose_%s" % def.get("res", CardDB.RES_CASH) })
		# 传说卡不可被攻击：不进目标列表
	return out

## 组合的配方消耗哪种资源（升级组合是纯卡面合成，不吃资源）
func _combo_recipe_res(eval: Dictionary) -> String:
	if eval.get("type") == "upgrade":
		return ""
	return str(CardDB.get_def(eval.get("leader", "")).get("recipe_res", ""))

## 目标可负担性：该目标用现有点数池点不点得起
static func target_affordable(target: Dictionary, pools: Dictionary) -> bool:
	return int(target["cost"]) <= int(pools[target["res"]])

## 「这一组打到一半了」—— 记在点数池里的 batch 名（见 attack_targets 的 batch）。
##
## 规则：**选中一个组合就得把它打完，余点才能转下一个**。3 点用户攻击面对
## 「A 组 2 席 / B 组 3 席」时，打 A 必然花掉 2 点、剩 1 点可以再去 B；
## 打 B 就是 3 点打完、A 一点也碰不到。不允许 A 花 1 点、B 花 2 点这种拆着打。
## 上锁的只有组合里的靶，散卡不上锁（见 batch_locks）。
##
## 为什么锁存在 pools 里而不是裁决器（IntentApply）上：这条规则必须对**所有**
## 驱动路径成立，而无头的 `Settle.attack_phase` 根本不经过裁决器（它自己拿着
## 一个局部的 pools 直接调 affordable_targets / apply_attack）。放在裁决器上，
## 无头局和界面局会在同一份阵型上打出不同结果 —— 那正是 tests/test_intent.gd
## 的同构判据在比的东西。锁和池子的生命期也完全一致（一个攻击回合），
## 于是联网局的 pools_snapshot 顺带就把它带过去了，不必再开一条同步路
##
## 键名带前缀是为了和资源键（cash/user）明确分开：pools 只有 pools_snapshot
## 一处按显式键抄写，别处都是整份 duplicate，多一个键不影响
const ATTACK_LOCK := "_lock_batch"

static func attack_lock(pools: Dictionary) -> String:
	return str(pools.get(ATTACK_LOCK, ""))

## 靶属于哪一摞。空 batch（理论上不该有）当作「自己独一摞」，
## 不会误锁到别人身上
static func target_batch(target: Dictionary) -> String:
	return str(target.get("batch", ""))

## 这一击要不要上锁。只有**组合里的靶**上锁（配方核心 kind="combo"、
## 富余投料 kind="spare"）——规则说的是「选中一个组合就得把它打完」，
## 散卡堆不是组合。先削一张散卡、再拿余点去拆组合是一直允许的打法，
## 顺手锁上会把它一起收走，那超出了这条规则要管的范围
##
## 反过来「锁着的时候不许打别处」是不分靶种的：锁在 A 组身上时，
## 拐去啃散卡也等于绕开了「先打完 A」（见 apply_attack 那道护栏）
static func batch_locks(target: Dictionary) -> bool:
	return str(target.get("kind", "")) in ["combo", "spare"]

## victim 身上这个点数池点得起的靶。攻击阶段每点一次都要重算一遍
## （池子在变，靶也在变），无头的 Settle.attack_phase 和场景层的
## _attack_turn 原先各有一份逐字节同构的实现
##
## **锁在这里生效**：打到一半的那一摞里还有点得起的靶，就只返回那一摞的
## —— 选靶的人（AI / 界面高亮 / 无头模拟器）因此天然接着啃同一摞，
## 不必各自记住「我刚才在打谁」。那一摞打空了（或剩下的点数点不起它了），
## 锁自然失效，整张桌子重新可选
func affordable_targets(victim: String, pools: Dictionary) -> Array:
	var out: Array = []
	for t in attack_targets(victim):
		if target_affordable(t, pools):
			out.append(t)
	var lock := attack_lock(pools)
	if lock == "":
		return out
	var same: Array = []
	for t in out:
		if target_batch(t) == lock:
			same.append(t)
	return same if not same.is_empty() else out

## 「成型」：`who` 手上此刻无解的生产组合 —— 对手花多少点都没法让它作废。
## 返回 combos 里的那些字典本身（调用方要 uids 就自己取）。
##
## 判定是「这个组的零件一个都不在对手的 `attack_targets` 里」。**不自己重算保护逻辑**，
## 直接读 `attack_targets` 的输出：那是点选真正用的那一份，重算一遍就是两份定义
##
## 只认生产组合。按字面「有效组合 + 核心为空」会把升级组合全算进来 ——
## 升级是纯卡面合成，`protect_quota` 对它返回 0，核心天然为空，每次升级都会记成一次成型。
## 攻击组合也不算：此历史诊断专门观察受保护的生产能力，只有生产组合进入结果。
## 保护规则见 README.md §「2.8 Buff」；它不属于当前手动调参的 Q1–Q9。
##
## 只在 `combos` 还在的时候有意义（`Settle.finalize` 会清空它），
## 所以采集方得停在结算之前 —— 见 engine/match_simulator.gd 的 before_settle
func sealed_combos(who: String) -> Array:
	var vulnerable := {}
	for t in attack_targets(who):
		if t.get("kind") == "combo":
			for u in t["uids"]:
				vulnerable[u] = true
	var out: Array = []
	for combo in combos:
		if combo["owner"] != who or combo["eval"].get("type") != "production":
			continue
		var sealed := true
		for u in combo["uids"]:
			if vulnerable.has(u):
				sealed = false
				break
		if sealed:
			out.append(combo)
	return out

## 点数池写成一行给玩家看：「现金×5 用户×3」。
## 战报、提示条、点数不够的报错都念这个池子，各写一遍会飘
static func pool_text(pools: Dictionary) -> String:
	return "%s×%d %s×%d" % [
		CardDB.card_label(CardDB.RES_CASH), int(pools.get(CardDB.RES_CASH, 0)),
		CardDB.card_label(CardDB.RES_USER), int(pools.get(CardDB.RES_USER, 0)),
	]

## 执行一次点选：校验点数 → 扣池 → 移除卡牌 → 写战报
## pools 为攻击方当前点数池（原地扣减）；返回 {ok, cost, removed, reason}
func apply_attack(attacker: String, target: Dictionary, pools: Dictionary) -> Dictionary:
	var victim := opponent(attacker)
	if not target_affordable(target, pools):
		return { "ok": false, "reason": "点数不够（需要 %d 点（%s攻击））" % [
			target["cost"], CardDB.card_label(target["res"])] }
	# 打到一半的那一摞得先打完（见 ATTACK_LOCK）。只在**那一摞还点得起**时拦：
	# 打空了就该放开，否则余点会卡在一具空壳上，谁也打不了。
	# 光靠 affordable_targets 过滤不够 —— 那只是「推荐给谁」，
	# 联网客户端直接发一条 Intent.apply_attack 就绕过去了，规则得落在这里
	var lock := attack_lock(pools)
	if lock != "" and target_batch(target) != lock:
		for t in attack_targets(victim):
			if target_batch(t) == lock and target_affordable(t, pools):
				return { "ok": false, "reason": "得先打完手上这一摞（%s）" % [
					CardDB.card_name(t["leader"])] }
	var pool_res: String = target["res"]
	var removed: Array = []
	for u in target["uids"]:
		if remove_card(victim, u):
			removed.append(u)
	if removed.is_empty():
		return { "ok": false, "reason": "目标已不在场上" }
	pools[pool_res] -= int(target["cost"])
	# 这一组开打了：锁上它（见 ATTACK_LOCK）。写在扣池之后 ——
	# 上面每一条 return 都是「这一击没发生」，没发生就不该改变「在打谁」。
	# 打散卡则把锁清掉：能走到这儿说明上一把锁已经放开（护栏放行了），
	# 留着一个失效的锁名只会让 pools 里多一句假话
	if batch_locks(target):
		pools[ATTACK_LOCK] = target_batch(target)
	else:
		pools.erase(ATTACK_LOCK)
	# 两个座位都当参数传，不在这里拼成名字：谁念「你的公司」看视角
	var aseat := seat_arg(attacker)
	var vseat := seat_arg(victim)
	# 攻击池和被移除的目标都是按卡算的 → 卡名
	var pool_name := "%s攻击" % CardDB.card_label(pool_res)
	var res_name := CardDB.card_label(target["res"])
	# 这一击有没有构成「克制」：本来成立的组被这一击打成不成立。
	# 只有 combo 这一支可能置真 —— spare 是富余料（配方不动），散卡不在组里
	var voided := false
	match target["kind"]:
		"combo":
			# 「整组作废」这句留给结算阶段的 ✂ 战报，避免同一件事在战报里出现两次。
			# 核心改成逐张计价之后「配方告破」不再是必然，得分三种说法：
			# 富余料顶上 → 还成立；这一点啃穿了 → 刚破；组早就破了 → 别再报一次告破
			# （下同一个组的第 2、3 张核心时就是这种情况）
			var was_intact: bool = target.get("intact", true)
			var broke := _combo_broken_by(victim, target["uids"])
			var how := "富余料顶上，配方未破"
			if broke:
				how = "配方告破" if was_intact else "配方早已告破"
			# 「刚破」才算克制。组早就破了（打同一组的第 2、3 张核心）不重复计数，
			# 否则一个组能刷出好几次「爽点」
			voided = broke and was_intact
			log_fmt("⚔ %s 从 %s 的组合「%s」里点掉 %d 张配方%s（%s，%s -%d 点）", [
				aseat, vseat, CardDB.card_name(target["leader"]), removed.size(), res_name,
				how, pool_name, target["cost"]])
		"spare":
			log_fmt("⚔ %s 从 %s 的「%s」旁抽走 %d 张富余%s（配方未破，%s -%d 点）", [
				aseat, vseat, CardDB.card_name(target["leader"]), removed.size(), res_name,
				pool_name, target["cost"]])
		_:
			log_fmt("⚔ %s 点拆 %s 的散卡「%s」（%s -%d 点）", [
				aseat, vseat, CardDB.card_name(target["leader"]), pool_name, target["cost"]])
	if voided:
		stats["voided"][attacker] = int(stats["voided"].get(attacker, 0)) + 1
	return { "ok": true, "cost": target["cost"], "removed": removed, "voided": voided }

## 刚移除的这批 uid 有没有把它们所在的组合打破。
## 战报要分「配方告破」和「富余料顶上」两种说法，口径必须和结算阶段
## 那条 ✂ 一致 —— 所以现调 combo_intact，不在 apply_attack 里另算一遍配方
func _combo_broken_by(victim: String, uids: Array) -> bool:
	for combo in combos:
		if combo["owner"] != victim:
			continue
		var hit := false
		for u in uids:
			if combo["uids"].has(u):
				hit = true
				break
		if hit and not combo_intact(victim, combo):
			return true
	return false

## 结算后的胜负检查
func check_victory() -> bool:
	if winner != "":
		return true   # 已分胜负（防重复战报）
	var p_cash := resource_count(PLAYER, CardDB.RES_CASH)
	var a_cash := resource_count(AI, CardDB.RES_CASH)
	var p_user := resource_count(PLAYER, CardDB.RES_USER)
	var a_user := resource_count(AI, CardDB.RES_USER)
	var win_cash: int = CardDB.game_rules()["win_cash"]
	if p_cash >= win_cash or a_cash <= 0 or a_user <= 0:
		winner = PLAYER
		if p_cash >= win_cash:
			win_reason = "你攒到了 %d 资金。数字是真的，过程就不复盘了。" % win_cash
		elif a_cash <= 0:
			win_reason = "对手的钱被你耗光了。它大概也没想到还能这么打。"
		else:
			win_reason = "对手的用户跑光了。你赢在了对手更离谱。"
	elif a_cash >= win_cash or p_cash <= 0 or p_user <= 0:
		winner = AI
		if a_cash >= win_cash:
			win_reason = "对手先攒到 %d 资金。它甚至没怎么为难你。" % win_cash
		elif p_cash <= 0:
			win_reason = "你的钱一分不剩。花的时候是不是没数过？"
		else:
			win_reason = "你的用户一个不剩。他们走得比你想的干脆。"
	if winner != "":
		log_msg("🏁 " + win_reason)
		return true
	return false

## 认输：对手直接判胜。
##
## 唯一一个**不看牌面**的胜负来源 —— check_victory 那三条（攒够资金 / 钱耗光 /
## 用户跑光）都是从资源数推出来的，这条是从玩家的决定来的。所以它自己写 winner，
## 不复用 check_victory：那个函数问的是「牌面到没到线」，认输时牌面通常好得很。
##
## 也不做「已经结束了就报错」那道判断：那是裁决器的事（IntentApply.apply 开头那条
## game_over 护栏管所有操作）。这里只留一个防重复战报的短路，和 check_victory 同款
func resign(who: String) -> Dictionary:
	if winner != "":
		return { "ok": false, "code": "game_over", "reason": "这局已经结束了" }
	if not players.has(who):
		return { "ok": false, "code": "bad_seat", "reason": "没有这个座位：%s" % who }
	winner = opponent(who)
	# 这里**故意**没写成 check_victory 那样的 log_msg("🏁 " + win_reason)。
	# 那个写法把战报和面板文案绑成同一个字符串，而这两者的视角要求不一样：
	#
	#   战报 —— 要说清是**谁**认的（认输不动任何资源，前后两行之间看不出
	#     发生过什么，这一行是复盘时唯一的线索）。所以走 log_fmt + seat_arg，
	#     由 render_entry 按各自的 my_seat 念成「你的公司」/「对手公司」
	#   win_reason —— 只能是**视角中立**的。它是一个裸字符串，
	#     state_codec 原样传给对端（`snapshot()` 存、`restore()` 读，两边都只是搬），
	#     谁都不会再翻译它一次。
	#     写「对手认输了」的话，认输的那个人自己看到的也是这句
	#
	# 「谁赢了」这件事面板不靠这行字说：标题那里比的是 winner == my_seat
	# （scenes/main.gd 的 _show_game_over），两边各自都对
	log_fmt("🏳 %s 认输了", [seat_arg(who)])
	win_reason = "这局是认输结束的。牌还在桌上，人已经不想打了。"
	return { "ok": true, "winner": winner, "seat": who }

## 回合收尾：先手轮换
func end_round() -> void:
	draw_first = opponent(draw_first)
	round_num += 1

## 战报条目 → 文本，用 PLAYER 视角。
## 只给「不关心视角」的调用方用：测试里 grep 关键词、无头模拟器打印摘要。
## 界面必须走 render_entry 并传自己的 my_seat（scenes/main.gd 的 _render_log）
static func entry_text(entry: Dictionary) -> String:
	return render_entry(entry, PLAYER)

## 写一条不含公司名的战报。文本已是最终形态，渲染时原样返回
func log_msg(text: String) -> void:
	log.append({ "round": round_num, "fmt": text, "args": [] })

## 写一条含公司名的战报。座位用 seat_arg(who) 放进 args，**不要**先拼成文本：
## 谁念「你的公司」是视角决定的，引擎这边还不知道谁在看（见 render_entry）
func log_fmt(fmt: String, args: Array) -> void:
	log.append({ "round": round_num, "fmt": fmt, "args": args })
