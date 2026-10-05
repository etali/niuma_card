# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 意图管道测试（engine/intent.gd 与 engine/intent_apply.gd）：七个引擎入口包成意图后，
## 走 LocalTransport 的那条路必须和直接调引擎**逐字节同构**。
##
## 这一条不碰场景层，纯引擎 —— 它要守的是联网的地基：
## 联网时裁决跑在服务器上，客户端只发意图。如果意图这条路和直接调引擎
## 结果不一样，那单机和联网就是两个游戏（README.md §「3. 文件目录结构」）。
##
## 判据分三族：
##   一、同构：同一串动作，走引擎 / 走意图，末状态哈希相等
##   二、不信任客户端：伪造 cost、冒充座位、自己推进阶段，都得被拒
##   三、JSON 往返：uid 过一趟 JSON 变 float，不归整就静默变成「不是你的卡」
##
## 变异提示（每条都实跑验证过会红）：
##   intent.gd `ints()` 直接 return a（不转 int）
##       → test_json_roundtrip 红（uid 变 float，付款报 not_cash）
##   intent_apply.gd `_attack` 改成用包里的 cost（信任客户端）
##       → test_forged_cost_rejected 红
##   intent_apply.gd `_arm` 去掉 already_armed 那一拦
##       → test_double_arm_rejected 红（弹药付两遍）
##   intent_apply.gd apply() 去掉 wrong_seat 那一拦
##       → test_impersonation_rejected 红
##   intent_apply.gd apply() 去掉 not_client_op 那一拦
##       → test_client_cannot_advance_phase 红
##   intent_apply.gd `_attack_done` 改成 _pools.erase(seat)
##       → test_attack_done_keeps_armed 红（收手后能再装一次弹）
##   local_transport.gd `submit` 失败时也 emit applied
##       → test_signals 红


func _initialize() -> void:
	print("=== 意图管道测试 ===\n")
	test_shape_validation()
	test_json_roundtrip()
	test_buy_matches_engine()
	test_pay_order_preserved()
	test_forged_cost_rejected()
	test_impersonation_rejected()
	test_client_cannot_advance_phase()
	test_double_arm_rejected()
	test_attack_done_keeps_armed()
	test_signals()
	test_full_round_same_as_engine()
	await test_attack_phase_same_as_engine()
	finish()


# ---------- 脚手架 ----------

## 固定种子的一局。两条路径要比对末状态，公共区必须一样
func _seeded_game(seed_v: int) -> GameState:
	var s := GameState.new()
	s.set_seed(seed_v)
	s.new_game()
	return s

func _pipe(s: GameState) -> LocalTransport:
	return LocalTransport.new(IntentApply.new(s))

## 状态指纹：两条路径跑完要一模一样。
## 手牌按 (uid, def_id, locked) 排序后拼串 —— uid 是引擎自增的，
## 两条路径动作次序相同就该完全一致；不排序的话 cards 的物理次序
## 也会进指纹，那是**该**进的：买卡/产出的插入位置也是行为的一部分
func _fingerprint(s: GameState) -> String:
	var parts: Array = []
	for who in [GameState.PLAYER, GameState.BOT]:
		var cs: Array = []
		for c in s.players[who]["cards"]:
			cs.append("%d:%s:%s" % [int(c["uid"]), c["def_id"], str(c["locked"])])
		parts.append("%s[%s]" % [who, ",".join(cs)])
	parts.append("market[%s]" % ",".join(s.market))
	var cb: Array = []
	for combo in s.combos:
		cb.append("%s(%s)" % [combo["owner"], str(combo["uids"])])
	parts.append("combos[%s]" % ",".join(cb))
	parts.append("r%d/first=%s/win=%s/uid=%d" % [
		s.round_num, s.draw_first, s.winner, s._uid])
	# 战报也进指纹：日志是 { round, fmt, args } 的结构化数据，
	# 意图路径不该多写或漏写任何一条（少一条 ✂ 就是少一次组合作废）
	parts.append("log%d" % s.log.size())
	return "|".join(parts)

## 找一个买得起的货位，返回 [市场下标, 价格]。找不到返回 [-1, 0]
func _affordable_slot(s: GameState, who: String) -> Array:
	var cash: int = s.resource_count(who, CardDB.RES_CASH)
	for i in s.market.size():
		var price: int = CardDB.get_def(s.market[i]).get("price", -1)
		if price > 0 and cash - price > 0:
			return [i, price]
	return [-1, 0]


# ---------- 一、形状校验 ----------

func test_shape_validation() -> void:
	var bad_op := Intent.from_dict({ "op": "rm_rf", "seat": "player" })
	check(not bad_op["ok"] and bad_op["code"] == "bad_op",
		"未知操作码被拒（%s）" % bad_op.get("code", "?"))

	var missing := Intent.from_dict({ "op": Intent.OP_BUY, "seat": "player" })
	check(not missing["ok"] and missing["code"] == "missing_field",
		"buy 缺 market_idx 被拒（%s）" % missing.get("code", "?"))

	var empty := Intent.from_dict({ "op": Intent.OP_PAWN, "seat": "player", "uids": [] })
	check(not empty["ok"] and empty["code"] == "empty_uids",
		"典当空列表被拒（%s）" % empty.get("code", "?"))

	var junk := Intent.decode("not json at all")
	check(not junk["ok"] and junk["code"] == "bad_json",
		"非 JSON 被拒（%s）" % junk.get("code", "?"))

	var bad_kind := Intent.from_dict({ "op": Intent.OP_ATTACK, "seat": "player",
		"target": { "kind": "legend", "res": "cash", "uids": [1] } })
	check(not bad_kind["ok"] and bad_kind["code"] == "bad_target",
		"未知目标类型被拒（%s）" % bad_kind.get("code", "?"))

	# 白名单方向也要验：阶段推进不在 CLIENT_OPS 里，玩家动作在
	check(Intent.is_client_op(Intent.OP_BUY) and Intent.is_client_op(Intent.OP_ATTACK),
		"买卡/点选算客户端操作")
	check(not Intent.is_client_op(Intent.OP_ARM)
			and not Intent.is_client_op(Intent.OP_PRODUCE)
			and not Intent.is_client_op(Intent.OP_NEXT_ROUND),
		"装弹/结算/换回合不算客户端操作")


# ---------- 三、JSON 往返 ----------

## uid 过一趟 JSON 会变 float，不归整就静默不相等。
## 症状是「包含不属于你的卡」/「请用现金卡支付」—— 看着像归属校验坏了
func test_json_roundtrip() -> void:
	var s := _seeded_game(4242)
	var pipe := _pipe(s)
	var slot := _affordable_slot(s, GameState.PLAYER)
	if slot[0] < 0:
		check(false, "开局找不到买得起的货位（种子 4242）")
		return
	var cash_uids: Array = s._loose_unit_uids(GameState.PLAYER, CardDB.RES_CASH)
	var pay: Array = cash_uids.slice(0, int(slot[1]))

	var wire := Intent.encode(Intent.buy(GameState.PLAYER, int(slot[0]), pay))
	var back := Intent.decode(wire)
	check(back["ok"], "买卡意图过 JSON 能解回来")
	if not back["ok"]:
		return
	var uids_are_int := true
	for u in back["intent"]["pay_uids"]:
		if typeof(u) != TYPE_INT:
			uids_are_int = false
	check(uids_are_int, "pay_uids 解回来仍是整数（%s）" % str(back["intent"]["pay_uids"]))
	check(back["intent"]["pay_uids"] == pay,
		"pay_uids 逐项相等（%s vs %s）" % [str(back["intent"]["pay_uids"]), str(pay)])

	# 真跑一遍：float 的 uid 会在 buy() 的归属校验里被判成「不是现金卡」
	var r: Dictionary = await pipe.submit(wire, GameState.PLAYER)
	check(r.get("ok", false), "过 JSON 的买卡意图能落地（%s）" % r.get("reason", ""))


# ---------- 一、同构 ----------

func test_buy_matches_engine() -> void:
	var a := _seeded_game(7)
	var b := _seeded_game(7)
	check(_fingerprint(a) == _fingerprint(b), "同种子开局指纹相同")

	var slot := _affordable_slot(a, GameState.PLAYER)
	if slot[0] < 0:
		check(false, "开局找不到买得起的货位（种子 7）")
		return
	var pay_a: Array = a._loose_unit_uids(GameState.PLAYER, CardDB.RES_CASH).slice(0, int(slot[1]))
	var pay_b: Array = b._loose_unit_uids(GameState.PLAYER, CardDB.RES_CASH).slice(0, int(slot[1]))

	var direct: Dictionary = a.buy(GameState.PLAYER, int(slot[0]), pay_a)
	var pipe := _pipe(b)
	var viaint: Dictionary = await pipe.submit(
		Intent.buy(GameState.PLAYER, int(slot[0]), pay_b), GameState.PLAYER)
	check(direct["ok"] and viaint.get("ok", false),
		"两条路都买成了（引擎 %s / 意图 %s）" % [direct.get("ok"), viaint.get("ok")])
	check(direct.get("new_uid", -1) == viaint.get("new_uid", -2),
		"新卡 uid 相同（%s vs %s）" % [direct.get("new_uid"), viaint.get("new_uid")])
	check(_fingerprint(a) == _fingerprint(b),
		"买卡后指纹相同\n      引擎：%s\n      意图：%s" % [_fingerprint(a), _fingerprint(b)])

	# 失败也要同构：付完归零那条护栏，两条路要报同一个 code
	var c := _seeded_game(7)
	var pipe_c := _pipe(c)
	var all_cash: Array = c._loose_unit_uids(GameState.PLAYER, CardDB.RES_CASH)
	var slot_c := _affordable_slot(c, GameState.PLAYER)
	# 把现金压到刚好等于价格：付完归零
	var keep := int(slot_c[1])
	for i in range(keep, all_cash.size()):
		c.remove_card(GameState.PLAYER, all_cash[i])
	var zero: Dictionary = await pipe_c.submit(
		Intent.buy(GameState.PLAYER, int(slot_c[0]), []), GameState.PLAYER)
	check(not zero.get("ok", true) and zero.get("code", "") == "zero_out",
		"付完归零被拒且带 zero_out（%s）" % zero.get("code", "?"))

## pay_uids 的顺序是真输入：buy() 付的是前 price 张。
## 顺序如果在传输里被打乱（比如对端拿集合重算），付掉的就是另外几张卡
func test_pay_order_preserved() -> void:
	var s := _seeded_game(99)
	var pipe := _pipe(s)
	var slot := _affordable_slot(s, GameState.PLAYER)
	if slot[0] < 0:
		check(false, "找不到买得起的货位（种子 99）")
		return
	var price := int(slot[1])
	var cash: Array = s._loose_unit_uids(GameState.PLAYER, CardDB.RES_CASH)
	if cash.size() < price + 2:
		check(false, "现金卡不够做顺序判据（%d 张，要 %d）" % [cash.size(), price + 2])
		return
	# 故意把最后两张排到最前面：付掉的必须是这两张（加上后面凑够的）
	var reordered: Array = [cash[-1], cash[-2]]
	for u in cash:
		if u != cash[-1] and u != cash[-2]:
			reordered.append(u)
	var expect: Array = reordered.slice(0, price)
	var r: Dictionary = await pipe.submit(
		Intent.buy(GameState.PLAYER, int(slot[0]), reordered), GameState.PLAYER)
	check(r.get("ok", false), "乱序 pay_uids 也能买成（%s）" % r.get("reason", ""))
	check(r.get("removed_uids", []) == expect,
		"付掉的正是前 %d 张（%s vs %s）" % [price, str(r.get("removed_uids", [])), str(expect)])
	for u in expect:
		check(s.find_card(GameState.PLAYER, u).is_empty(),
			"uid %d 真的离场了" % u)


# ---------- 二、不信任客户端 ----------

## 一局摆好的攻击场面：PLAYER 有一个攻击组合，BOT 有散卡当靶。
## 返回 [state, transport, def_id]
##
## 挑的是**吃现金**的攻击卡：下面三条判据（阶段推进权 / 重复装弹 / 收手）
## 都拿现金数量当「扣没扣款」的证据，配方吃的不是现金那几条就恒真了。
## 但**打**的是哪种资源另说 —— 点数池按 `attack_res` 分币种，
## 卡表里一张吃现金打现金的都没有（balance.md §「攻击卡」 的攻防矩阵里那一格空着），
## 所以第三个返回值把挑中的卡带出去，让读池子的那条自己查币种
func _armed_scene() -> Array:
	var s := GameState.new()
	s.set_seed(11)
	s.players = {
		GameState.PLAYER: { "cards": [] },
		GameState.BOT: { "cards": [] },
	}
	s.draw_first = GameState.PLAYER
	# 攻击组合：挑一张吃现金的攻击卡，配齐弹药 + 留够散现金（付完不能归零）
	var def_id := ""
	var need := 0
	for d_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(d_id)
		if d.get("kind") == CardDB.KIND_ATTACK and d.get("recipe_res") == CardDB.RES_CASH:
			var n := int(d.get("recipe_n", 0))
			if n >= 1 and (def_id == "" or n < need):
				def_id = d_id
				need = n
	if def_id == "":
		return []
	var core := s.add_card(GameState.PLAYER, def_id)
	var uids: Array = [core["uid"]]
	for i in need:
		uids.append(s.add_card(GameState.PLAYER, "cash")["uid"])
	for i in 5:
		s.add_card(GameState.PLAYER, "cash")
	s.add_card(GameState.PLAYER, "user")
	# 靶子：BOT 手上一堆散现金 + 用户（用户留着，不然打完就判负、后面的判据全走不到）
	for i in 6:
		s.add_card(GameState.BOT, "cash")
	for i in 4:
		s.add_card(GameState.BOT, "user")
	if not s.create_combo(GameState.PLAYER, uids)["ok"]:
		return []
	return [s, LocalTransport.new(IntentApply.new(s)), def_id]

## 伪造 cost：包里带 cost=0 也不该白拆。
## cost 根本不进协议（Intent.target_ref 只留 kind/res/uids），
## 这一条验的是「对端从状态重算」这件事真的发生了
func test_forged_cost_rejected() -> void:
	print("【伪造定价】")
	var sc := _armed_scene()
	if sc.is_empty():
		check(false, "摆不出攻击场面（卡表里没有吃现金的攻击卡？）")
		return
	var s: GameState = sc[0]
	var pipe: LocalTransport = sc[1]
	var applier: IntentApply = pipe.applier()
	var arm: Dictionary = await pipe.arm(GameState.PLAYER)
	check(arm.get("ok", false), "装弹成功（池子 %s）" % GameState.pool_text(applier.pools(GameState.PLAYER)))

	# 挑一个**点不起**的靶：把池子人为压到 1 点以下办不到（池子是引擎算的），
	# 所以换个办法 —— 先把点数打光，再拿 cost=0 的伪造包去点
	# 池子按**攻击**币种分，不是按配方币种：写死 RES_CASH 的话，
	# 挑中的卡打的是用户时这条读的是一个恒为 0 的池子，红在这儿但根在夹具
	var atk_res: String = str(CardDB.get_def(str(sc[2])).get("attack_res", ""))
	var pool_n := int(applier.pools(GameState.PLAYER)[atk_res])
	check(pool_n > 0, "%s攻击池有点数（%d）" % [CardDB.res_label(atk_res), pool_n])
	var spent := 0
	while not applier.pool_empty(GameState.PLAYER) and spent < 20:
		var av: Array = applier.affordable_targets(GameState.PLAYER)
		if av.is_empty():
			break
		var r: Dictionary = await pipe.submit(
			Intent.apply_attack(GameState.PLAYER, av[0]), GameState.PLAYER)
		if not r.get("ok", false):
			break
		spent += 1
	check(spent > 0, "点掉了 %d 个靶" % spent)

	# 池子空了，现在拿一个「自称 cost=0」的包去点还活着的靶
	var live: Array = s.attack_targets(GameState.BOT)
	if live.is_empty():
		check(false, "BOT 身上没有剩余目标可做伪造判据")
		return
	var forged: Dictionary = live[0].duplicate()
	forged["cost"] = 0
	var before: int = s.players[GameState.BOT]["cards"].size()
	var bad: Dictionary = await pipe.submit(
		Intent.apply_attack(GameState.PLAYER, forged), GameState.PLAYER)
	check(not bad.get("ok", true) and bad.get("code", "") == "short_points",
		"cost=0 的伪造包被拒（%s / %s）" % [bad.get("code", "?"), bad.get("reason", "")])
	check(s.players[GameState.BOT]["cards"].size() == before,
		"伪造包没能移走任何卡（%d → %d）" % [before, s.players[GameState.BOT]["cards"].size()])

	# 反面：不带 cost 的正常引用，在池子有点数时是认得的（否则上面那条是恒真的）
	var s2c := _armed_scene()
	var s2: GameState = s2c[0]
	var pipe2: LocalTransport = s2c[1]
	await pipe2.arm(GameState.PLAYER)
	var av2: Array = pipe2.applier().affordable_targets(GameState.PLAYER)
	check(not av2.is_empty(), "装弹后有点得起的靶（%d 个）" % av2.size())
	if not av2.is_empty():
		var ref_only := Intent.target_ref(av2[0])
		check(not ref_only.has("cost"), "目标引用里没有 cost 字段")
		var ok2: Dictionary = await pipe2.submit(
			{ "op": Intent.OP_ATTACK, "seat": GameState.PLAYER, "target": ref_only },
			GameState.PLAYER)
		check(ok2.get("ok", false), "只带 kind/res/uids 的引用能认领回目标（%s）"
			% ok2.get("reason", ""))
		check(int(ok2.get("cost", -1)) == int(av2[0]["cost"]),
			"cost 由对端重算得出（%s vs 卡面 %s）" % [ok2.get("cost"), av2[0]["cost"]])

## 冒充：连接身份是 BOT，包里自称 player
func test_impersonation_rejected() -> void:
	print("【冒充座位】")
	var s := _seeded_game(3)
	var pipe := _pipe(s)
	var slot := _affordable_slot(s, GameState.PLAYER)
	var fake: Dictionary = await pipe.submit(
		Intent.buy(GameState.PLAYER, int(slot[0]), []), GameState.BOT)
	check(not fake.get("ok", true) and fake.get("code", "") == "wrong_seat",
		"BOT 的连接不能替 PLAYER 买卡（%s）" % fake.get("code", "?"))

	# from_seat 为空 = 服务器自己提交，同一个包要能过（否则上面那条可能只是「包本身坏」）
	var ok: Dictionary = await pipe.submit(Intent.buy(GameState.PLAYER, int(slot[0]), []))
	check(ok.get("ok", false), "同一个包由服务器提交则放行（%s）" % ok.get("reason", ""))

	var nobody: Dictionary = await pipe.submit(
		Intent.buy("spectator", 0, []), "spectator")
	check(not nobody.get("ok", true) and nobody.get("code", "") == "bad_seat",
		"不存在的座位被拒（%s）" % nobody.get("code", "?"))

## 客户端不能自己推进阶段：装弹会真扣配方现金，
## 让客户端发得起 arm 等于让它自己决定什么时候开火
func test_client_cannot_advance_phase() -> void:
	print("【阶段推进权】")
	var sc := _armed_scene()
	if sc.is_empty():
		check(false, "摆不出攻击场面")
		return
	var s: GameState = sc[0]
	var pipe: LocalTransport = sc[1]
	var cash0 := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	for op in [Intent.arm_attacks(GameState.PLAYER), Intent.produce(0),
			Intent.finalize(), Intent.next_round()]:
		var r: Dictionary = await pipe.submit(op, GameState.PLAYER)
		check(not r.get("ok", true) and r.get("code", "") == "not_client_op",
			"客户端发 %s 被拒（%s）" % [op["op"], r.get("code", "?")])
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash0,
		"被拒的装弹一分钱没扣（%d → %d）" % [
			cash0, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])
	check(s.round_num == 1, "被拒的换回合没推进回合数（%d）" % s.round_num)

## 重复装弹要拦：arm_attacks 是真扣款的
func test_double_arm_rejected() -> void:
	print("【重复装弹】")
	var sc := _armed_scene()
	if sc.is_empty():
		check(false, "摆不出攻击场面")
		return
	var s: GameState = sc[0]
	var pipe: LocalTransport = sc[1]
	var cash0 := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var r1: Dictionary = await pipe.arm(GameState.PLAYER)
	var cash1 := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	check(r1.get("ok", false) and cash1 < cash0,
		"第一次装弹扣了弹药钱（%d → %d）" % [cash0, cash1])
	var r2: Dictionary = await pipe.arm(GameState.PLAYER)
	check(not r2.get("ok", true) and r2.get("code", "") == "already_armed",
		"第二次装弹被拒（%s）" % r2.get("code", "?"))
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash1,
		"第二次装弹没有再扣款（%d → %d）" % [
			cash1, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])

## 收手后 armed 仍为真：否则同一回合能再装一次弹
func test_attack_done_keeps_armed() -> void:
	print("【收手】")
	var sc := _armed_scene()
	if sc.is_empty():
		check(false, "摆不出攻击场面")
		return
	var s: GameState = sc[0]
	var pipe: LocalTransport = sc[1]
	var applier: IntentApply = pipe.applier()
	await pipe.arm(GameState.PLAYER)
	var log0: int = s.log.size()
	var done: Dictionary = await pipe.attack_done(GameState.PLAYER)
	check(done.get("ok", false) and bool(done.get("forfeited", false)),
		"收手成功且记了余点作废")
	check(s.log.size() == log0 + 1, "余点作废写了一条战报（%d → %d）" % [log0, s.log.size()])
	check(applier.pool_empty(GameState.PLAYER), "收手后池子清零")
	check(applier.armed(GameState.PLAYER), "收手后仍算装过弹")
	var cash := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var again: Dictionary = await pipe.arm(GameState.PLAYER)
	check(not again.get("ok", true) and again.get("code", "") == "already_armed",
		"收手后不能重新装弹（%s）" % again.get("code", "?"))
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash,
		"收手后的装弹尝试没扣款")
	# 池子清零后不该还点得起东西
	check(applier.affordable_targets(GameState.PLAYER).is_empty(),
		"清零的池子点不起任何靶")

## 信号：落地走 applied，被拒走 rejected，不能串台
func test_signals() -> void:
	print("【信号】")
	var s := _seeded_game(21)
	var pipe := _pipe(s)
	var got_ok: Array = []
	var got_bad: Array = []
	pipe.applied.connect(func(r): got_ok.append(r))
	pipe.rejected.connect(func(r): got_bad.append(r))

	var slot := _affordable_slot(s, GameState.PLAYER)
	await pipe.submit(Intent.buy(GameState.PLAYER, int(slot[0]), []), GameState.PLAYER)
	check(got_ok.size() == 1 and got_bad.is_empty(),
		"成功只发 applied（ok %d / bad %d）" % [got_ok.size(), got_bad.size()])
	check(int(got_ok[0].get("seq", -1)) == 1, "第一条落地的 seq = 1（%s）" % got_ok[0].get("seq"))

	await pipe.submit(Intent.buy(GameState.PLAYER, 999, []), GameState.PLAYER)
	check(got_ok.size() == 1 and got_bad.size() == 1,
		"失败只发 rejected（ok %d / bad %d）" % [got_ok.size(), got_bad.size()])
	check(got_bad[0].get("code", "") == "bad_idx",
		"rejected 带 code（%s）" % got_bad[0].get("code", "?"))
	check(pipe.seq == 1, "被拒的意图不涨 seq（%d）" % pipe.seq)


# ---------- 一、同构（整回合） ----------

## 最要紧的一条：同一局、同一串动作，走 Settle.run 和走意图管道，
## 末状态**和战报**都必须一模一样。
##
## 这条不成立，联网就是另一个游戏 —— 而这正是 README.md §「3. 文件目录结构」要防的分叉。
## 战报也进指纹：攻击阶段的表头、余点作废那两句都是引擎写的，
## 意图路径不该多写或漏写（那两句现在落在 IntentApply 里，就是为了对上）
func test_full_round_same_as_engine() -> void:
	print("【整回合同构】")
	# 双方都编好组合再结算：只有两边都有组合，攻击阶段和产出结算才都真的跑
	var a := _seeded_game(1234)
	var b := _seeded_game(1234)
	_seed_cores(a)
	_seed_cores(b)
	_build_both_sides(a)
	_build_both_sides(b)
	check(_fingerprint(a) == _fingerprint(b),
		"编组后两局指纹相同\n      A：%s\n      B：%s" % [_fingerprint(a), _fingerprint(b)])
	check(not a.combos.is_empty(), "编出了组合（%d 组）" % a.combos.size())

	# A：老路子
	Settle.run(a)
	a.end_round()
	a.start_round()

	# B：意图管道
	var pipe := _pipe(b)
	await pipe.run_round()
	await pipe.next_round()

	check(_fingerprint(a) == _fingerprint(b),
		"整回合走完指纹相同\n      引擎：%s\n      意图：%s" % [_fingerprint(a), _fingerprint(b)])
	# 战报逐条比。上面的指纹只带条数，这里比内容 —— 条数相同而措辞不同是会发生的
	var same_log := a.log.size() == b.log.size()
	var first_diff := ""
	if same_log:
		for i in a.log.size():
			var ta := GameState.entry_text(a.log[i])
			var tb := GameState.entry_text(b.log[i])
			if ta != tb:
				same_log = false
				first_diff = "\n      第 %d 条\n        引擎：%s\n        意图：%s" % [i, ta, tb]
				break
	check(same_log, "战报逐条相同（引擎 %d 条 / 意图 %d 条）%s" % [
		a.log.size(), b.log.size(), first_diff])
	check(a.round_num == b.round_num and a.round_num == 2,
		"两条路都进了第 2 回合（引擎 %d / 意图 %d）" % [a.round_num, b.round_num])

	# 再跑一回合：池子必须在 next_round 里清掉，否则第二回合装弹会被
	# already_armed 拦掉，攻击阶段整段不跑（指纹会在这一步分叉）
	_build_both_sides(a)
	_build_both_sides(b)
	Settle.run(a)
	await pipe.run_round()
	check(_fingerprint(a) == _fingerprint(b),
		"第二回合也同构（换回合清了池子）\n      引擎：%s\n      意图：%s" % [
			_fingerprint(a), _fingerprint(b)])

## 上面那一局 组合构建 只编出生产组合（实测 4 组全是 production），
## 攻击阶段整段不跑 —— 而攻击阶段正是意图路径改动最大的地方：
## 表头战报和「余点作废」那两句现在落在 IntentApply 里，就是为了和
## Settle.attack_phase 对上。它们**必须**有一条同构判据盖住，
## 否则改动最大的那段代码恰好是没比过的那段
func test_attack_phase_same_as_engine() -> void:
	print("【攻击阶段同构】")
	var a := _attack_scene(555)
	var b := _attack_scene(555)
	check(not a.is_empty() and not b.is_empty(), "摆出了双方都有攻击组合的场面")
	if a.is_empty() or b.is_empty():
		return
	var sa: GameState = a[0]
	var sb: GameState = b[0]
	check(_fingerprint(sa) == _fingerprint(sb), "两局起点指纹相同")
	var atk_n := 0
	for c in sa.combos:
		if c["eval"].get("type") == "attack":
			atk_n += 1
	check(atk_n >= 2, "双方各有攻击组合（共 %d 组）" % atk_n)

	var n0: int = sa.log.size()
	Settle.run(sa)
	var pipe: LocalTransport = b[1]
	await pipe.run_round()

	# 攻击真的发生了：得有 ⚔ 开头的战报，否则这条判据和上面那条一样是空跑
	var atk_lines := 0
	for i in range(n0, sa.log.size()):
		if GameState.entry_text(sa.log[i]).begins_with("⚔"):
			atk_lines += 1
	check(atk_lines > 0, "结算里真的打了（%d 条 ⚔ 战报）" % atk_lines)

	check(_fingerprint(sa) == _fingerprint(sb),
		"攻击阶段走完指纹相同\n      引擎：%s\n      意图：%s" % [
			_fingerprint(sa), _fingerprint(sb)])
	var same_log := sa.log.size() == sb.log.size()
	var diff := ""
	if same_log:
		for i in sa.log.size():
			var ta := GameState.entry_text(sa.log[i])
			var tb := GameState.entry_text(sb.log[i])
			if ta != tb:
				same_log = false
				diff = "\n      第 %d 条\n        引擎：%s\n        意图：%s" % [i, ta, tb]
				break
	check(same_log, "攻击战报逐条相同（引擎 %d 条 / 意图 %d 条）%s" % [
		sa.log.size(), sb.log.size(), diff])

## 双方各有一个攻击组合 + 一个生产组合的场面。
## 手摆而不是让 当前行动策略 编：它的攻击组合要看落后程度和对手阵型
## （旧策略的领先差 / 运气门），对称的开局它一个都不编
func _attack_scene(seed_v: int) -> Array:
	var s := GameState.new()
	s.set_seed(seed_v)
	s.new_game()
	var atk := _cheapest(CardDB.KIND_ATTACK, CardDB.RES_CASH)
	var prod := _cheapest(CardDB.KIND_PRODUCT, CardDB.RES_CASH)
	if atk == "" or prod == "":
		return []
	for who in [GameState.PLAYER, GameState.BOT]:
		# 弹药和配方都吃现金，先把现金铺够（付完还得剩，否则整组不生效）
		for i in 20:
			s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		var a_core := s.add_card(who, atk)
		var a_uids: Array = [a_core["uid"]]
		for i in int(CardDB.get_def(atk).get("recipe_n", 0)):
			a_uids.append(s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))["uid"])
		if not s.create_combo(who, a_uids)["ok"]:
			return []
		var p_core := s.add_card(who, prod)
		var p_uids: Array = [p_core["uid"]]
		for i in int(CardDB.get_def(prod).get("recipe_n", 0)):
			p_uids.append(s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))["uid"])
		if not s.create_combo(who, p_uids)["ok"]:
			return []
	return [s, LocalTransport.new(IntentApply.new(s))]

## 卡表里 recipe_n 最小的那张（kind + 配方资源给定）。
## 不写死 def_id：数值一轮一改，写死会让这个文件跟着 cards.json 漂
func _cheapest(kind: String, res: String) -> String:
	var best := ""
	var best_n := 999
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") != kind or d.get("recipe_res") != res:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n < best_n:
			best = def_id
			best_n = n
	return best

## 双方各自用 BOT 的组卡器编组。用 当前行动策略 而不是手摆牌桌：
## 它会编出攻击组合和生产组合的混合场面，比手摆的更接近真实局。
##
## 得先发核心卡：开局手上只有单位卡（现金/用户），一张核心都没有，
## 组合构建 一个组合也编不出来 —— 那样「整回合同构」比的是
## 两个什么都没发生的回合，恒真。第一版就是这样，靠「编出了组合 %d 组」
## 那条判据露出来的
func _build_both_sides(s: GameState) -> void:
	for who in s.action_order():
		var cores: Array = s.players[who]["cards"].duplicate()
		for card in cores:
			var d := CardDB.get_def(str(card["def_id"]))
			if not d.get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]:
				continue
			var uids: Array = [card["uid"]]
			for unit in s.players[who]["cards"]:
				if not unit.get("locked", false) and unit["def_id"] == CardDB.unit_id(str(d["recipe_res"])) and uids.size() <= int(d["recipe_n"]):
					uids.append(unit["uid"])
			if uids.size() == int(d["recipe_n"]) + 1:
				check(s.create_combo(who, uids)["ok"], "显式混合组合夹具可编组")

func _seed_cores(s: GameState) -> void:
	var picks: Array = []
	for spec in [[CardDB.KIND_PRODUCT, CardDB.RES_CASH], [CardDB.KIND_PRODUCT, CardDB.RES_USER],
			[CardDB.KIND_ATTACK, CardDB.RES_CASH]]:
		var best := ""
		var best_n := 999
		for def_id in CardDB.all_cards():
			var d: Dictionary = CardDB.get_def(def_id)
			if d.get("kind") != spec[0] or d.get("recipe_res") != spec[1]:
				continue
			var n := int(d.get("recipe_n", 0))
			if n >= 1 and n < best_n:
				best = def_id
				best_n = n
		if best != "":
			picks.append(best)
	# 两边发**同一套**：指纹要能比，双方的牌面必须对称
	for who in [GameState.PLAYER, GameState.BOT]:
		for def_id in picks:
			s.add_card(who, def_id)
		# 多发些单位卡：配方吃现金，攻击组合还要付弹药，
		# 开局那点现金（`_game.start_cash`）拿去编生产组合后就不够了
		for i in 8:
			s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		for i in 6:
			s.add_card(who, CardDB.unit_id(CardDB.RES_USER))
