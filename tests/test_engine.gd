# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## M1 验收测试：跑通设计文档 4.3 实例演算 + 防御 Buff + 升级组合
## 运行：godot --headless -s tests/test_engine.gd


func _initialize() -> void:
	print("=== M1 规则引擎测试 ===\n")
	_with_rule_fixture(test_settle_example_4_3, {
		"yunketang": {"recipe_res": "user", "recipe_n": 4, "output_res": "cash", "output_n": 7},
		"zuokong": {"recipe_res": "user", "recipe_n": 2, "attack_res": "cash", "attack_n": 3},
		"waimai": {"recipe_res": "cash", "recipe_n": 5, "output_res": "user", "output_n": 2},
		"butie": {"recipe_res": "cash", "recipe_n": 3, "attack_res": "user", "attack_n": 4},
	})
	test_protect_buff()
	test_upgrade_combo()
	test_market_and_buy()
	test_attack_core_vs_spare()
	test_attack_protection_hint()
	test_attack_zero_cash_win()
	_with_rule_fixture(test_attack_one_combo_at_a_time, {
		"butie": {"recipe_res": "cash", "recipe_n": 3, "attack_res": "user", "attack_n": 3},
		"yunketang": {"recipe_res": "user", "recipe_n": 3, "output_res": "cash", "output_n": 7},
		"waimai": {"recipe_res": "cash", "recipe_n": 5, "output_res": "user", "output_n": 2},
	})
	test_targets_distinguish_broken_combo()
	test_eval_observables()
	finish()

## 固定算例自己的数值关系，行为仍走真实引擎；用完恢复当前用户卡表。
## 配方/攻击量可自由调节，不能要求用户卡表永远恰好符合某个历史算例。
func _with_rule_fixture(run: Callable, definitions: Dictionary) -> void:
	CardDB.ensure_loaded()
	var saved_cards := CardDB.CARDS
	var saved_game := CardDB.GAME
	CardDB.CARDS = saved_cards.duplicate(true)
	CardDB.GAME = saved_game.duplicate(true)
	CardDB.GAME["attack_cost_per_card"] = 1
	for id in definitions:
		CardDB.CARDS[id].merge(definitions[id], true)
	run.call()
	CardDB.CARDS = saved_cards
	CardDB.GAME = saved_game

func _blank_state(draw_first: String) -> GameState:
	var s := GameState.new()
	s.players = {
		GameState.PLAYER: { "cards": [] },
		GameState.BOT: { "cards": [] },
	}
	s.draw_first = draw_first
	return s

func _uids(cards: Array) -> Array:
	return cards.map(func(c): return c["uid"])

## 扫卡表挑一张「吃现金、配方量 ≤ max_n」的生产卡，取配方最大的那张
## （越大越接近攻击点数的上限，「点数刚好把配方现金清零」这一例越紧）
func _cash_recipe_product_within(max_n: int) -> String:
	var best := ""
	var best_n := 0
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") != CardDB.KIND_PRODUCT or d.get("recipe_res") != CardDB.RES_CASH:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n <= max_n and n > best_n:
			best = def_id
			best_n = n
	return best

## 扫卡表挑一张「攻击落在 res 上」的卡，取配方最小的（要发的散牌最少，牌桌好读）。
## 不写死 def_id：哪张卡打哪个币种是数值决定的 —— 本轮黑公关就从打现金翻成了打用户
func _attack_hitting(res: String) -> String:
	var best := ""
	var best_n := 999
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") != CardDB.KIND_ATTACK or d.get("attack_res") != res:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n < best_n:
			best = def_id
			best_n = n
	return best

# ---------- 设计文档 4.3 实例演算（分池攻击） ----------
# 牌桌（每张吃几张、产几点全从卡表现读，下面只写角色）：
# 玩家先手：「云课堂+用户×配方量」（产资金）「做空报告+用户×配方量」（现金攻击池）
#           + 少量散现金、散用户
# BOT 后手：「外卖补贴+现金×配方量」（产用户）「补贴大战+现金×配方量」（用户攻击池）
#           + 少量散现金、散用户
#
# **玩家那张攻击卡这一轮换人了**：要的是「配方吃用户、打击目标是现金」那个职能，
# 卡表把它从 heigongguan 挪到了 zuokong（黑公关通稿改成吃现金、打用户）。
# 这里认的是职能不是名字，所以换回 heigongguan 第一条前提判据就红。
#
# 预期（核心按 `_game.attack_cost_per_card` 逐张计价 + **一次只打一个组合**）：
#       玩家先打。做空报告吃用户配方 → **不付弹药**，现金池直接开火；
#       第一份点数点掉外卖的一张配方现金 → 配方告破 —— 但**这一组还没打完，
#       余下的点数就得留在这儿**（见 GameState.ATTACK_LOCK），一路啃外卖的席位。
#       补贴大战因此一张没掉 → 装得上弹（付自己那份配方现金），用户池开火；
#       夹具固定选中云课堂，用户池恰好打完那一组的席位；这条路线不依赖 BOT 偏好。
#       结算：外卖整组作废、云课堂也整组作废（那 +7 没产），做空报告一张没掉。
#
# 这一例演的规则：分池、核心逐张计价、**选中一个组合就得把它打完**、
# 先攻能破坏牌型（拆掉产出组合 = 那一组白摆）。
#
# **锁把这一例的结论改了一半**，两条都要看见：
# - 原先「第二份点数转向另一个组合、顺手把补贴大战也打破」→ 现在办不到。
#   先攻不再能靠一池点数同时废掉对手的产出组合和攻击组合，攻击阶段也就剥不掉了
#   （这一例原来演的正是那个更强的结论）。
# - 反过来，锁也在替被打的一方兜着：BOT 的点数被按在云课堂一个组里，
#   玩家的做空报告毫发无伤。攻方选一个组押上全部点数，是这条规则的两面。
#
# **这一例原先还演「用户配方不付弹药」**（README.md §「2.6 组合与结算」 的不对称，recipe_pay_n 只在
# recipe_res == cash 时非零）：靠「装弹只出现一次」断言 —— 补贴大战付、做空报告不付。
# 锁把补贴大战救回了装弹那一步，于是这条不对称又能在这儿演了：
# 装弹**恰好一次**（补贴大战付，做空报告免费）。
# 余点作废挪去测试6（那边靠「保护=不可点」演，不需要掐死对手的散牌数量）。
#
# 几处刻意留的散牌（张数按卡表算，见下面 SPARE 那几个量）：
# - BOT 留散现金：补贴大战付完弹药还得剩至少 1 张
#   （付到 0 等于自尽，护栏会拦下整组，攻击池归零，这一例就全废了）。
#   玩家那一池全花在外卖的核心上，BOT 手上剩的配方 + 散牌付得起。
# - BOT 留散用户：验「玩家的现金池打不到用户」，也防清零即胜提前结束。
# - 玩家留散用户：BOT 那一池啃穿云课堂那几席之后不至于把用户打到 0
#   （这是本例避免提前终局的夹具条件，并非限制可配置攻击力）。
# - 玩家留散现金：做空报告不吃现金，这几张纯粹是防清零即胜误触发。
func test_settle_example_4_3() -> void:
	print("【测试1】4.3 实例演算：分池攻击，核心逐张计价、一次只打一个组合")
	var s := _blank_state(GameState.PLAYER)  # 玩家先手：先行动、攻击先结算
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	# 初始化处为本例安装局部语义夹具；这里从该夹具读数，用完即恢复用户卡表。
	var yun: Dictionary = CardDB.get_def("yunketang")
	# 玩家这一侧要的是「配方吃用户、打击目标是现金」那张。这一轮卡表把这个职能
	# 从 heigongguan 换到了 zuokong（黑公关通稿改成吃现金、打用户了），
	# 所以这里跟着换 —— 换回 heigongguan 的话第一条前提判据就红
	var hei_id := "zuokong"
	var hei: Dictionary = CardDB.get_def(hei_id)
	var wai: Dictionary = CardDB.get_def("waimai")
	var bu: Dictionary = CardDB.get_def("butie")
	# 散牌垫几张：判据自己的规模，只要够满足上面那几条「别提前判负」
	var spare := 2

	# 这一例成立靠三处数值咬合，咬不上就不是「余点刚好花完」那个场面了。
	#
	# 一、玩家那一池点不完外卖的席位 —— 点穿了锁就失效、余点会转去别的组，
	#     「一次只打一个组合」那一条就演不出来了
	check(int(hei["attack_n"]) / per_card <= int(wai["recipe_n"]),
		"牌桌前提：%s 的攻击量 %d 点不穿 %s 的 %d 张席位" % [
			hei["name"], int(hei["attack_n"]), wai["name"], int(wai["recipe_n"])])
	# 二、用不同规模的两组区分目标；下面的固定 picker 选择生产组，不依赖 BOT 偏好。
	var atk_seats := int(bu["attack_n"]) / per_card
	check(int(yun["recipe_n"]) > int(hei["recipe_n"]),
		"夹具前提：%s 的 %d 席比 %s 的 %d 席多，两个目标组可区分" % [
			yun["name"], int(yun["recipe_n"]), hei["name"], int(hei["recipe_n"])])
	# 三、用户池恰好打完整组；多余点数会合法转向下一组，不能再断言另一组毫发无伤。
	check(atk_seats == int(yun["recipe_n"]),
		"夹具前提：BOT 那 %d 点恰好打完 %s 的 %d 张席位" % [
			atk_seats, yun["name"], int(yun["recipe_n"])])
	# 四、玩家的用户总量要撑得住这一池，否则清零即胜当场结束、结算一步都跑不到
	check(int(yun["recipe_n"]) + int(hei["recipe_n"]) + spare > atk_seats,
		"牌桌前提：玩家用户垫得住 BOT 那 %d 点（不触发清零即胜）" % atk_seats)

	# 玩家手牌：云课堂（产资金）+ 做空报告（现金攻击池）
	var p_core1 := s.add_card(GameState.PLAYER, "yunketang")
	var p_users: Array = []
	for i in int(yun["recipe_n"]): p_users.append(s.add_card(GameState.PLAYER, "user"))
	var p_core2 := s.add_card(GameState.PLAYER, hei_id)
	var p_atk_users: Array = []
	for i in int(hei["recipe_n"]): p_atk_users.append(s.add_card(GameState.PLAYER, "user"))

	# BOT 手牌：外卖补贴（产用户）+ 补贴大战（用户攻击池）
	var a_core1 := s.add_card(GameState.BOT, "waimai")
	var a_cash1: Array = []
	for i in int(wai["recipe_n"]): a_cash1.append(s.add_card(GameState.BOT, "cash"))
	var a_core2 := s.add_card(GameState.BOT, "butie")
	var a_cash2: Array = []
	for i in int(bu["recipe_n"]): a_cash2.append(s.add_card(GameState.BOT, "cash"))
	for i in spare: s.add_card(GameState.BOT, "cash")   # 散现金：补贴大战付完弹药还得剩
	for i in spare + 1: s.add_card(GameState.BOT, "user")   # 散用户（验现金池打不到用户）
	for i in spare: s.add_card(GameState.PLAYER, "cash")  # 散现金：防自身清零即胜误触发
	for i in spare: s.add_card(GameState.PLAYER, "user")  # 见上：不留就被清零，结算跑不到

	# 编组
	var r1 := s.create_combo(GameState.PLAYER, [p_core1["uid"]] + _uids(p_users))
	check(r1["ok"], "玩家「%s+用户×%d」编组成立" % [yun["name"], int(yun["recipe_n"])])
	check(r1.get("eval", {}).get("output_n", 0) == int(yun["output_n"]),
		"%s 产出 %s+%d" % [yun["name"], CardDB.res_label(str(yun["output_res"])),
			int(yun["output_n"])])
	var r2 := s.create_combo(GameState.PLAYER, [p_core2["uid"]] + _uids(p_atk_users))
	check(r2["ok"], "玩家「%s+用户×%d」编组成立" % [hei["name"], int(hei["recipe_n"])])
	var p_pool: Dictionary = s.attack_pool(GameState.PLAYER)
	check(p_pool["cash"] == int(hei["attack_n"]) and p_pool["user"] == 0,
		"玩家攻击池：现金×%d 用户×0（分池）" % int(hei["attack_n"]))
	var r3 := s.create_combo(GameState.BOT, [a_core1["uid"]] + _uids(a_cash1))
	check(r3["ok"], "BOT「%s+现金×%d」编组成立" % [wai["name"], int(wai["recipe_n"])])
	var r4 := s.create_combo(GameState.BOT, [a_core2["uid"]] + _uids(a_cash2))
	check(r4["ok"], "BOT「%s+现金×%d」编组成立" % [bu["name"], int(bu["recipe_n"])])
	var a_pool: Dictionary = s.attack_pool(GameState.BOT)
	check(a_pool["cash"] == 0 and a_pool["user"] == int(bu["attack_n"]),
		"BOT 攻击池：现金×0 用户×%d（分池）" % int(bu["attack_n"]))

	var bot_cash_before := s.resource_count(GameState.BOT, CardDB.RES_CASH)
	var p_cash_before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var p_user_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	# 固定本例要展示的两条攻击路线，规则断言不依赖当前策略的目标偏好。
	var preferred := {GameState.PLAYER: _uids(a_cash1), GameState.BOT: _uids(p_users)}
	var picker := func(_state: GameState, attacker: String, targets: Array, _pools: Dictionary) -> Dictionary:
		for target in targets:
			for uid in target.get("uids", []):
				if preferred[attacker].has(uid):
					return target
		return targets[0] if not targets.is_empty() else {}
	for who in s.action_order():
		Settle.attack_phase(s, who, picker)
	Settle.produce(s)
	Settle.finalize(s)

	# BOT 少的现金 = 玩家那一池（逐张点，全砸在外卖一个组里）+ 补贴大战的弹药。
	# 锁把余点按在外卖组里，补贴大战一张没掉 → 装得上弹，那几张才付得出去
	var bot_loss := int(hei["attack_n"]) / per_card + int(bu["recipe_n"])
	check(s.resource_count(GameState.BOT, CardDB.RES_CASH) == bot_cash_before - bot_loss,
		"BOT 现金 %d → %d（%d 点全啃 %s 的席位 + %s 付 %d 张弹药）" % [
			bot_cash_before, s.resource_count(GameState.BOT, CardDB.RES_CASH),
			int(hei["attack_n"]), wai["name"], bu["name"], int(bu["recipe_n"])])
	# 玩家现金不增不减：做空报告吃用户配方不付弹药，BOT 打的是用户
	# 玩家现金一分没动：做空报告吃用户配方不付弹药，BOT 打的是用户，
	# 而云课堂被啃穿之后整组作废、那 +7 没产出来。
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == p_cash_before,
		"玩家现金 %d → %d（不付弹药；云课堂被啃穿，那 +%d 没产）" % [
			p_cash_before, s.resource_count(GameState.PLAYER, CardDB.RES_CASH),
			int(yun["output_n"])])
	# 玩家少的用户 = BOT 那一池，全砸在云课堂一个组里
	var p_loss := int(bu["attack_n"]) / per_card
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == p_user_before - p_loss,
		"玩家用户 %d → %d（BOT 那 %d 点全按在 %s 一个组里）" % [
			p_user_before, s.resource_count(GameState.PLAYER, CardDB.RES_USER),
			int(bu["attack_n"]), yun["name"]])
	# 锁的另一面：BOT 的点数被按在云课堂身上，做空报告那几席一张没掉。
	# 按 uid 查而不是数总量 —— 总量对不出「掉的是哪个组的」
	var atk_alive := 0
	for c in p_atk_users:
		if not s.find_card(GameState.PLAYER, c["uid"]).is_empty():
			atk_alive += 1
	check(atk_alive == int(hei["recipe_n"]),
		"%s 那 %d 席一张没掉（剩 %d，攻方一次只打一个组合）" % [
			hei["name"], int(hei["recipe_n"]), atk_alive])
	var fizzle_count := 0
	for entry in s.log:
		if "整组作废" in GameState.entry_text(entry):
			fizzle_count += 1
	# 两个产出组合都作废：BOT 的外卖（玩家啃的）+ 玩家的云课堂（BOT 啃的）。
	# 补贴大战和做空报告是攻击组合，被拆散只是不贡献点数，
	# 没有「作废」这句战报（它们没有产出可作废）——
	# 所以这个数是 2 而不是 4，两边各废掉对方一个**产出**组
	check(fizzle_count == 2, "两边的产出组合各被拆散作废（实际 %d 个）" % fizzle_count)
	check(s.resource_count(GameState.BOT, CardDB.RES_USER) == spare + 1,
		"BOT 散用户未被移除（现金攻击池不能打用户）")
	var armed := 0
	for entry in s.log:
		if "装弹" in GameState.entry_text(entry):
			armed += 1
	# 恰好一次：补贴大战吃现金配方要付，做空报告吃用户配方免费开火。
	# 这条不对称（README.md §「2.6 组合与结算」）就是靠「一次」而不是「两次」演出来的
	check(armed == 1,
		"装弹恰好一次（补贴大战付、做空报告免费，实际 %d 次）" % armed)
	# 先攻能破坏牌型 —— 但只破坏得了**一个**组合。锁把整池点数按在外卖身上，
	# 补贴大战活到了装弹，BOT 的攻击阶段照常开场。
	# 这一条原先断的是反面（「BOT 连攻击阶段那行战报都没有」），
	# 是锁把结论翻过来的，不是回归
	var fired := false
	for entry in s.log:
		if "攻击阶段" in GameState.entry_text(entry) and "对手公司" in GameState.entry_text(entry):
			fired = true
	check(fired, "BOT 的攻击阶段照常开场（先攻只废掉了产出组合，攻击组合没碰到）")

# ---------- 清零即胜：攻击把对方现金打到 0，当场获胜，不进结算 ----------
func test_attack_zero_cash_win() -> void:
	print("【测试7】清零即胜：现金攻击把 BOT 现金打到 0 → 立即获胜")
	var s := _blank_state(GameState.PLAYER)  # 玩家先手

	# 打现金的攻击卡（补贴大战本轮改成打用户了，balance.md §「攻击卡」）
	var atk_id := _attack_hitting(CardDB.RES_CASH)
	var atk_def: Dictionary = CardDB.get_def(atk_id)
	var atk_n := int(atk_def["recipe_n"])
	# BOT 的生产核心：吃现金、且配方量不超过攻击点数 —— 它全部身家就是那几张配方现金，
	# 核心按 `_game.attack_cost_per_card` 逐张计价，点数够把它们逐张点完就正好清零。
	# 两个数都从卡表取，谁配谁由数值决定
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var seats_killable := int(atk_def["attack_n"]) / per_card
	var a_id := _cash_recipe_product_within(seats_killable)
	check(a_id != "", "牌桌前提：卡表里有一张吃现金的生产卡，配方量 ≤ %s 能啃的 %d 席" % [
		atk_def["name"], seats_killable])
	var a_def: Dictionary = CardDB.get_def(a_id)
	var a_n := int(a_def["recipe_n"])

	var p_core := s.add_card(GameState.PLAYER, atk_id)
	var p_cash: Array = []
	for i in atk_n:
		p_cash.append(s.add_card(GameState.PLAYER, CardDB.unit_id(atk_def["recipe_res"])))
	if atk_def["recipe_res"] == CardDB.RES_CASH:
		s.add_card(GameState.PLAYER, "cash")  # 散现金：装弹付完还得剩，否则自尽护栏拦下
	s.add_card(GameState.PLAYER, "cash")  # 防自身清零即胜误触发
	s.add_card(GameState.PLAYER, "user")  # 同上

	# BOT 的现金全在生产组合里：逐张点掉配方核心 = 现金归零
	var a_core := s.add_card(GameState.BOT, a_id)
	var a_cash: Array = []
	for i in a_n: a_cash.append(s.add_card(GameState.BOT, "cash"))
	for i in 3: s.add_card(GameState.BOT, "user")  # 散用户：判据自己的规模，只防清零即胜误触发

	var r1 := s.create_combo(GameState.PLAYER, [p_core["uid"]] + _uids(p_cash))
	check(r1["ok"], "玩家「%s+%s×%d」编组成立（现金攻击池 %d）" % [
		atk_def["name"], CardDB.card_name(atk_def["recipe_res"]), atk_n,
		int(atk_def["attack_n"])])
	var r2 := s.create_combo(GameState.BOT, [a_core["uid"]] + _uids(a_cash))
	check(r2["ok"], "BOT「%s+现金×%d」编组成立（这是它全部的现金）" % [a_def["name"], a_n])

	var a_user_before := s.resource_count(GameState.BOT, CardDB.RES_USER)
	Settle.run(s)
	check(s.winner == GameState.PLAYER, "BOT 现金被清零 → 玩家立即获胜（不等回合末）")
	check(s.resource_count(GameState.BOT, CardDB.RES_USER) == a_user_before,
		"清零即胜后不再结算：BOT 的%s组合未产出用户（%d → %d）" % [
			a_def["name"], a_user_before, s.resource_count(GameState.BOT, CardDB.RES_USER)])

# ---------- 防御 Buff：推送弹窗保护用户 ----------
func test_protect_buff() -> void:
	print("【测试2】推送弹窗：附着组合的用户不可被移除")
	var s := _blank_state(GameState.BOT)  # 玩家先结算

	var p_def: Dictionary = CardDB.get_def("yunketang")
	var p_core := s.add_card(GameState.PLAYER, "yunketang")
	var p_users: Array = []
	for i in int(p_def["recipe_n"]): p_users.append(s.add_card(GameState.PLAYER, "user"))
	var p_buff := s.add_card(GameState.PLAYER, "tuisong")
	s.add_card(GameState.PLAYER, "cash")  # 防自身清零即胜误触发

	# 打用户的攻击卡。不写死 def_id：黑公关本轮从「打现金」翻成「打用户」（balance.md §「攻击卡」），
	# 而这一节要的只是「有东西在打用户」—— 卡表里谁在打用户由数值决定。
	# 配方张数也从卡表取，同理
	var a_id := _attack_hitting(CardDB.RES_USER)
	var a_def: Dictionary = CardDB.get_def(a_id)
	var a_core := s.add_card(GameState.BOT, a_id)
	var a_recipe: Array = []
	for i in int(a_def["recipe_n"]):
		a_recipe.append(s.add_card(GameState.BOT, CardDB.unit_id(a_def["recipe_res"])))
	# 吃现金配方的话还得多留 1 张散现金：装弹付完归零会被自尽护栏拦下，攻击池归零
	if a_def["recipe_res"] == CardDB.RES_CASH:
		s.add_card(GameState.BOT, "cash")
	for i in 2: s.add_card(GameState.BOT, "user")  # 防清零即胜误触发
	s.add_card(GameState.BOT, "cash")              # 同上，防自身现金归零

	var r1 := s.create_combo(GameState.PLAYER,
		[p_core["uid"], p_buff["uid"]] + _uids(p_users))
	check(r1["ok"], "玩家「%s+%s×%d+%s」编组成立" % [
		p_def["name"], CardDB.card_name(p_def["recipe_res"]),
		int(p_def["recipe_n"]), CardDB.card_name("tuisong")])
	check(r1["eval"].get("protect_user", false), "组合带用户保护标记")
	var r2 := s.create_combo(GameState.BOT, [a_core["uid"]] + _uids(a_recipe))
	check(r2["ok"], "BOT「%s」编组成立（%s×%d → 打用户 %d）" % [
		a_def["name"], CardDB.card_name(a_def["recipe_res"]),
		int(a_def["recipe_n"]), int(a_def["attack_n"])])
	check(int(s.attack_pool(GameState.BOT)[CardDB.RES_USER]) > 0,
		"BOT 手上真有打用户的点数（否则「保护住了」会因为没人开火而假通过）")

	check(s.buff_armed(GameState.PLAYER, p_buff["uid"]), "推送弹窗编组当回合立即生效")

	var users_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	Settle.run(s)
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == users_before,
		"玩家用户全部被保护，%s 移除 0 张（%d → %d）" % [
			a_def["name"], users_before,
			s.resource_count(GameState.PLAYER, CardDB.RES_USER)])

# ---------- 升级组合：同名 T1×2 → T2（纯卡面，不吃资源） ----------
func test_upgrade_combo() -> void:
	print("【测试3】升级组合：同名 T1 攒够 upgrade_dup_n 张 → T2")
	var s := _blank_state(GameState.BOT)

	# 要发几张同名卡读 T2 的 `upgrade_dup_n`：升级门槛是数值，调它不该回来改这里
	var t2: Dictionary = CardDB.get_def("xinxijianfang")
	var dup := int(t2["upgrade_dup_n"])
	var t1_id := str(t2["upgrade_from"])
	var dups: Array = []
	for i in dup: dups.append(s.add_card(GameState.PLAYER, t1_id))
	# 手上留几张资源：升级不吃资源，结算完这些必须一张不少。
	# 张数是判据自己的规模，只要「有」就够，随便留几张
	for i in 5: s.add_card(GameState.PLAYER, "user")
	for i in 3: s.add_card(GameState.PLAYER, "cash")
	var user_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var cash_before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)

	var r := s.create_combo(GameState.PLAYER, _uids(dups))
	check(r["ok"], "「%s×%d」编组成立（不需要任何资源）" % [CardDB.card_name(t1_id), dup])
	check(r["eval"].get("output_card", "") == "xinxijianfang",
		"升级目标为%s" % CardDB.card_name("xinxijianfang"))

	Settle.run(s)
	var has_t2 := false
	for c in s.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "xinxijianfang":
			has_t2 = true
	check(has_t2, "结算后玩家场上出现「%s」" % CardDB.card_name("xinxijianfang"))
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == user_before,
		"用户一张没掉（%d → %d）" % [user_before, s.resource_count(GameState.PLAYER, CardDB.RES_USER)])
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before,
		"现金一张没掉（%d → %d）" % [cash_before, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])

# ---------- 公共区与购买 ----------
func test_market_and_buy() -> void:
	print("【测试4】公共区生成与购买支付")
	var s := GameState.new()
	s.new_game()
	check(s.market.size() == CardDB.game_rules()["market_size"],
		"公共区生成 %d 张卡" % CardDB.game_rules()["market_size"])
	for def_id in s.market:
		check(CardDB.get_def(def_id).get("weight", 0) > 0, "公共区不含单位卡/高阶卡：%s" % def_id)

	# 强制塞入一张已知卡测试购买。标价读卡表：这一节验的是付款这套机制
	# （照标价扣、归零拦下、拖少了拒、拖多了不多吃），不是「这张卡值几块」——
	# 标价是平衡旋钮，钉死它等于每轮调参都要来改下面这八处
	s.market[0] = "zuokong"
	var price: int = int(CardDB.get_def("zuokong")["price"])
	var cash_before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var r := s.buy(GameState.PLAYER, 0)
	check(r["ok"], "现金充足时购买成功")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before - price,
		"支付现金×%d（资金 %d → %d）" % [price, cash_before, cash_before - price])
	var has_card := false
	for c in s.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "zuokong":
			has_card = true
	check(has_card, "购买的「%s」进入玩家区域" % CardDB.card_name("zuokong"))

	# 自杀护栏：付完这笔现金归零 = 回合结束判负（见 check_victory 的 p_cash <= 0）。
	# 护栏在引擎里，玩家拖现金、BOT、无头模拟器三条路共用一份
	var cash_now := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	s.market[0] = "zuokong"
	var keep: Array = s.players[GameState.PLAYER]["cards"].duplicate(true)
	# 把现金削到刚好等于标价：付完就是 0
	var dropped := 0
	for c in keep:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_CASH) and cash_now - dropped > price:
			s.remove_card(GameState.PLAYER, c["uid"])
			dropped += 1
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == price,
		"削到手上正好 %d 块（标价 %d）" % [price, price])
	var r_zero := s.buy(GameState.PLAYER, 0)
	check(not r_zero["ok"], "付完会归零：拦下（%s）" % r_zero.get("reason", ""))
	check(r_zero.get("code", "") == "zero_out", "拒绝码 zero_out（表现层据此抖卡）")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == price, "被拦下后现金没动")
	check(s.market[0] == "zuokong", "被拦下后公共区没动")
	# 多 1 块就该放行：护栏是「归零」而不是「买不起」
	s.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
	var r_ok := s.buy(GameState.PLAYER, 0)
	check(r_ok["ok"], "留得下 1 块时放行")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 1, "买完剩 1 块，不判负")

	# 指定付款卡：拖来的那几张必须是自己的散现金
	var s2 := GameState.new()
	s2.new_game()
	s2.market[0] = "zuokong"
	var user_uid := -1
	for c in s2.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_USER):
			user_uid = c["uid"]
	check(user_uid != -1, "找到一张用户卡")
	var r_bad := s2.buy(GameState.PLAYER, 0, [user_uid])
	check(not r_bad["ok"] and r_bad.get("code", "") == "not_cash", "拖用户卡去付款：拒绝 not_cash")
	var cash_uids: Array = []
	for c in s2.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_CASH) and cash_uids.size() < price - 1:
			cash_uids.append(c["uid"])
	var r_short := s2.buy(GameState.PLAYER, 0, cash_uids)
	check(not r_short["ok"] and r_short.get("code", "") == "short",
		"只拖 %d 张去买标价 %d：拒绝 short" % [price - 1, price])
	# 多拖的只收标价那几张，剩下的原样留着（表现层据此退回）
	var over: int = price + 2
	var many: Array = []
	for c in s2.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_CASH) and many.size() < over:
			many.append(c["uid"])
	var r_many := s2.buy(GameState.PLAYER, 0, many)
	check(r_many["ok"], "拖 %d 张买标价 %d：成交" % [over, price])
	check(r_many["removed_uids"].size() == price,
		"只收走 %d 张，多付的 %d 张不吃" % [price, over - price])
	for u in r_many["removed_uids"]:
		check(u in many, "收走的是拖来的那几张里的（uid %d）" % u)

# ---------- 配方核心 vs 富余投料：同价，区别在打掉之后配方还成不成立 ----------
## 组内组外一律按 `_game.attack_cost_per_card` 计价。配方额度内的那几张打掉一张
## 配方就不再满足 → 整组作废；超出配方的富余卡打掉不影响配方与产出。
## 核心原先是「一减到底」的整体目标（cost = 额度内未保护的张数，凑不满不可点），
## 那个定价让「把牌编进组合」变成硬掩体 —— 已判为 bug，见 README.md §「2.9 攻击」
func test_attack_core_vs_spare() -> void:
	print("【测试5】配方核心 / 富余投料：同价，区别在配方破不破")
	var s := _blank_state(GameState.PLAYER)  # 玩家先手

	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var butie_n := int(CardDB.get_def("butie")["recipe_n"])
	var p_core := s.add_card(GameState.PLAYER, "butie")
	var p_cash: Array = []
	for i in butie_n: p_cash.append(s.add_card(GameState.PLAYER, "cash"))
	for i in 2: s.add_card(GameState.PLAYER, "user")  # 防自身清零即胜误触发

	# BOT：生产组合里压了「配方量 + 富余」张现金 —— 多出来的就是富余投料。
	# 配方量从卡表取，富余张数是判据自己的规模：这一节量的是「核心与富余同价、各自成靶」，
	# 外卖吃几张现金无关，硬写总数会让每轮调数值都在这儿红一次
	var waimai_n := int(CardDB.get_def("waimai")["recipe_n"])
	var spare_want := 8
	var a_core := s.add_card(GameState.BOT, "waimai")
	var a_combo_cash: Array = []
	for i in waimai_n + spare_want: a_combo_cash.append(s.add_card(GameState.BOT, "cash"))
	for i in 2: s.add_card(GameState.BOT, "user")

	check(s.create_combo(GameState.PLAYER, [p_core["uid"]] + _uids(p_cash))["ok"],
		"玩家「%s+现金×%d」编组成立" % [CardDB.card_name("butie"), butie_n])
	check(s.create_combo(GameState.BOT, [a_core["uid"]] + _uids(a_combo_cash))["ok"],
		"BOT「%s+现金×%d」编组成立" % [CardDB.card_name("waimai"), waimai_n + spare_want])

	var core_n := 0
	var core_all_one := true
	var spare_n := 0
	for t in s.attack_targets(GameState.BOT):
		if t["kind"] == "combo":
			core_n += 1
			if int(t["cost"]) != per_card:
				core_all_one = false
		elif t["kind"] == "spare":
			spare_n += 1
	check(core_n == waimai_n,
		"配方额度内 %d 张各自成靶（不是捆成一个 cost=%d 的整体），实际 %d 个" % [
			waimai_n, waimai_n, core_n])
	check(core_all_one, "每个核心靶 attack_cost_per_card %d 点" % per_card)
	check(spare_n == spare_want, "富余 %d 张各自成靶，实际 %d 个" % [spare_want, spare_n])

	# 只啃富余卡：配方没破，组合照常产出
	var s2 := _blank_state(GameState.PLAYER)
	var total_cash := waimai_n + spare_want
	var b_core := s2.add_card(GameState.BOT, "waimai")
	var b_cash: Array = []
	for i in total_cash: b_cash.append(s2.add_card(GameState.BOT, "cash"))
	for i in 2: s2.add_card(GameState.BOT, "user")
	s2.create_combo(GameState.BOT, [b_core["uid"]] + _uids(b_cash))
	# 啃几张是判据自己的规模，只要少于富余张数（啃不到核心）就够
	var kill := 3
	check(kill < spare_want, "夹具前提：只啃 %d 张，够不着 %d 张富余外的核心" % [kill, spare_want])
	var pools := { "cash": kill * per_card, "user": 0 }
	var hit := 0
	for t in s2.attack_targets(GameState.BOT):
		if t["kind"] == "spare" and hit < kill:
			s2.apply_attack(GameState.PLAYER, t, pools)
			hit += 1
	check(s2.resource_count(GameState.BOT, CardDB.RES_CASH) == total_cash - kill,
		"%d 点啃掉 %d 张富余现金：%d → %d" % [
			kill * per_card, kill, total_cash, total_cash - kill])
	check(s2.combo_intact(GameState.BOT, s2.combos[0]),
		"配方（现金×%d）仍满足 → 组合未作废" % waimai_n)
	var waimai_out := int(CardDB.get_def("waimai")["output_n"])
	var users_before := s2.resource_count(GameState.BOT, CardDB.RES_USER)
	Settle.produce(s2)
	check(s2.resource_count(GameState.BOT, CardDB.RES_USER) == users_before + waimai_out,
		"组合照常产出 用户+%d" % waimai_out)

	# 已经被打散的组合（配方不齐、结算时要作废），残余那几张同样逐张计价。
	# 这条正是被判为 bug 的那个门槛：原先残余的核心捆成一个「cost = 残余张数」的整体靶，
	# 「散卡逐张点」的路径看着像被封了 —— 那时按 README 判成「设计如此」，
	# 现在改了：组内组外同价。额度仍是 recipe_n（不随掉了几张缩水），
	# 所以残余的全在额度内、无一富余，只是各自一份 attack_cost_per_card
	var s3 := _blank_state(GameState.PLAYER)
	var shua_n := int(CardDB.get_def("shuabuting")["recipe_n"])
	var c_core := s3.add_card(GameState.BOT, "shuabuting")
	var c_users: Array = []
	for i in shua_n: c_users.append(s3.add_card(GameState.BOT, "user"))
	s3.add_card(GameState.BOT, "cash")   # 防清零即胜误触发
	s3.create_combo(GameState.BOT, [c_core["uid"]] + _uids(c_users))
	s3.remove_card(GameState.BOT, c_users[0]["uid"])   # 抽掉一张 → 配方不齐
	check(not s3.combo_intact(GameState.BOT, s3.combos[0]), "抽掉一张后配方不齐")
	var broke_n := 0
	var broke_all_one := true
	var broke_spare := 0
	for t in s3.attack_targets(GameState.BOT):
		if t["kind"] == "combo":
			broke_n += 1
			if int(t["cost"]) != per_card:
				broke_all_one = false
		elif t["kind"] == "spare":
			broke_spare += 1
	check(broke_n == shua_n - 1,
		"残余 %d 张各自成靶（实际 %d 个）" % [shua_n - 1, broke_n])
	check(broke_all_one, "残余的核心也是 attack_cost_per_card %d 点/张" % per_card)
	check(broke_spare == 0,
		"额度内的卡不因组合作废就翻成富余（富余目标 %d 个）" % broke_spare)

# ---------- 保护：被降价促销保护的现金不可点，攻击无处可去 ----------
func test_attack_protection_hint() -> void:
	print("【测试6】补贴大战打在被降价促销保护的现金上：组合不可点，余点作废")
	var s := _blank_state(GameState.PLAYER)  # 玩家先手

	# 打现金的攻击卡：这一节演的是「被降价促销护住的现金点不动」，
	# 所以攻击必须落在现金上 —— 补贴大战本轮已改成打用户（balance.md §「攻击卡」），不能再当主角
	var atk_id := _attack_hitting(CardDB.RES_CASH)
	var atk_def: Dictionary = CardDB.get_def(atk_id)
	var atk_n := int(atk_def["recipe_n"])
	var p_core := s.add_card(GameState.PLAYER, atk_id)
	var p_cash: Array = []
	for i in atk_n:
		p_cash.append(s.add_card(GameState.PLAYER, CardDB.unit_id(atk_def["recipe_res"])))
	if atk_def["recipe_res"] == CardDB.RES_CASH:
		s.add_card(GameState.PLAYER, "cash")  # 散现金：装弹付完还得剩，否则自尽护栏拦下
	s.add_card(GameState.PLAYER, "cash")  # 防自身清零即胜误触发
	s.add_card(GameState.PLAYER, "user")  # 同上

	# BOT：外卖补贴 + 配方现金 + 降价促销（防御卡在组合中即永久保护组内现金）
	var waimai_n := int(CardDB.get_def("waimai")["recipe_n"])
	var a_core := s.add_card(GameState.BOT, "waimai")
	var a_cash: Array = []
	for i in waimai_n: a_cash.append(s.add_card(GameState.BOT, "cash"))
	var a_buff := s.add_card(GameState.BOT, "jiangjia")
	s.add_card(GameState.BOT, "user")  # 防清零即胜误触发

	var r1 := s.create_combo(GameState.PLAYER, [p_core["uid"]] + _uids(p_cash))
	check(r1["ok"], "玩家「%s+%s×%d」编组成立" % [
		atk_def["name"], CardDB.card_name(atk_def["recipe_res"]), atk_n])
	var r2 := s.create_combo(GameState.BOT, [a_core["uid"], a_buff["uid"]] + _uids(a_cash))
	check(r2["ok"], "BOT「外卖补贴+现金×%d+降价促销」编组成立" % waimai_n)
	check(r2["eval"].get("protect_cash", false), "BOT 组合带现金保护标记")

	check(s.buff_armed(GameState.BOT, a_buff["uid"]), "降价促销编组当回合立即生效")
	# 用 affordable_targets 而不是 attack_targets：BOT 那张散用户也是个目标，
	# 只是玩家手里是现金池、点不起它。这一条问的是「现金池有没有靶子」
	check(s.affordable_targets(GameState.BOT, s.attack_pool(GameState.PLAYER)).is_empty(),
		"BOT 那 %d 张现金全被保护 → 玩家现金池一个可点目标都没有" % waimai_n)

	Settle.run(s)
	check(s.resource_count(GameState.BOT, CardDB.RES_CASH) == waimai_n,
		"被保护的现金一张不少（仍为 %d）" % waimai_n)
	var hint := false
	for entry in s.log:
		if "点不起任何目标" in GameState.entry_text(entry):
			hint = true
	check(hint, "战报说明「点不起任何目标，余点作废」（保护=不可点）")

# ---------- 一次只打一个组合：选中了就得打完，余点才能转下一组 ----------

## 规则（见 GameState.ATTACK_LOCK）：**选中一个组合就得把它打完**。
## 用户给的算例：A 组露的用户比手上的点数少、B 组露的正好等于手上的点数 ——
## 打 A 必然把 A 啃光，余点才能转去 B；打 B 就是一口气打完，A 一张也碰不到。
## 拆着打（A 花一部分、B 花一部分）不允许。
## 初始化处用局部固定夹具保证三个量的关系，用户调卡不会改变这个规则场景。
##
## 为什么这一节摆在引擎测试里而不是场景测试里：原先这条规则**根本不在引擎里**，
## 它是 scenes/main.gd 两条驱动各自的副产品（`_attack_pile` 按界面上的一摞连点、
## `_drive_bot_attack` 自己按 batch 分组）。无头的 Settle.attack_phase、
## 联网的 Transport.run_attack_phase、以及任何直接发 Intent.apply_attack 的
## 客户端都各打各的 —— 同一份阵型能打出 A 花 1 点 B 花 2 点的结果
func test_attack_one_combo_at_a_time() -> void:
	var n := _lock_nums()
	var a: int = int(n["a"])
	var b: int = int(n["b"])
	var pts: int = int(n["pts"])
	print("【测试8】一次只打一个组合：选中了就得打完（A %d 席 / B %d 席 / %d 点）" % [a, b, pts])

	# 算例成立要三个量对得上，对不上就先红在这儿，不必去猜下面哪条断言为什么变了
	check(a > 0 and a < pts, "牌桌前提：A 的 %d 席少于手上的 %d 点（打完 A 还有余点）" % [a, pts])
	check(b == pts, "牌桌前提：B 的 %d 席正好吃满 %d 点（打 B 就是一口气打完）" % [b, pts])

	# A / B 的「席位数」是被攻击方**露在外面能被点的用户张数**，不是配方量：
	# A 组核心吃现金（外卖补贴），组里那几张用户全算富余（kind=spare）；
	# B 组核心吃用户（云课堂），那几张是配方核心（kind=combo）。
	# 两种靶都在锁的管辖内（见 GameState.batch_locks），正好一并验掉
	var s := _lock_table()
	var a_users: Array = _combo_user_uids(s, 0)
	var b_users: Array = _combo_user_uids(s, 1)
	check(a_users.size() == a, "A 组露 %d 张用户（实际 %d）" % [a, a_users.size()])
	check(b_users.size() == b, "B 组露 %d 张用户（实际 %d）" % [b, b_users.size()])
	var batches := {}
	for t in s.attack_targets(GameState.BOT):
		batches[GameState.target_batch(t)] = true
	check(batches.size() >= 3,
		"A / B / 散卡各自成一批（实际 %d 批：%s）" % [batches.size(), str(batches.keys())])

	# ---- 打 A：2 点花在 A，剩 1 点转去 B ----
	# picker 只在「引擎给的候选里」挑，所以它挑不到被锁排除的靶 ——
	# 这一段量的就是引擎给出的候选面
	var spent: Array = []
	Settle.attack_phase(s, GameState.PLAYER, _picker_prefer(a_users, spent))
	check(spent.size() == pts, "%d 点全花掉了（打了 %d 下）" % [pts, spent.size()])
	check(_alive(s, a_users) == 0, "A 组 %d 张用户被打光（剩 %d）" % [a, _alive(s, a_users)])
	check(_alive(s, b_users) == b - (pts - a),
		"余下的 %d 点转去了 B（B 剩 %d 张，应为 %d）" % [
			pts - a, _alive(s, b_users), b - (pts - a)])

	# ---- 打 B：3 点全花在 B，A 一张也碰不到 ----
	var s2 := _lock_table()
	var a2: Array = _combo_user_uids(s2, 0)
	var b2: Array = _combo_user_uids(s2, 1)
	var spent2: Array = []
	Settle.attack_phase(s2, GameState.PLAYER, _picker_prefer(b2, spent2))
	check(spent2.size() == pts, "%d 点全花掉了（打了 %d 下）" % [pts, spent2.size()])
	check(_alive(s2, b2) == 0, "B 组 %d 张用户被打光（剩 %d）" % [b, _alive(s2, b2)])
	check(_alive(s2, a2) == a, "A 组一张也没掉（剩 %d，应为 %d）" % [_alive(s2, a2), a])

	# ---- 拆着打：直接发 apply_attack 也拆不动 ----
	# 光靠 affordable_targets 过滤挡不住这条 —— 那只是「推荐给谁」，
	# 联网客户端手写一条意图就绕过去了。护栏必须在 apply_attack 里
	var s3 := _lock_table()
	var a3: Array = _combo_user_uids(s3, 0)
	var b3: Array = _combo_user_uids(s3, 1)
	var p3 := { CardDB.RES_CASH: 0, CardDB.RES_USER: pts * int(n["per_card"]) }
	check(_hit(s3, a3[0], p3)["ok"], "先打 A 的第 1 张：成立")
	check(GameState.attack_lock(p3) != "", "打完这一下，池子里记下了「在打 A」（%s）" % [
		GameState.attack_lock(p3)])
	var lock3 := GameState.attack_lock(p3)
	var narrowed: Array = s3.affordable_targets(GameState.BOT, p3)
	var only_a := true
	for t in narrowed:
		if GameState.target_batch(t) != lock3:
			only_a = false
	check(not narrowed.is_empty() and only_a,
		"候选面收窄到 A 这一组（%d 个靶，全在 %s 里）" % [narrowed.size(), lock3])
	var bad: Dictionary = _hit(s3, b3[0], p3)
	check(not bad["ok"], "A 还没打完就去打 B：被拒")
	check("得先打完" in str(bad.get("reason", "")),
		"拒绝理由说清了是哪条规则（「%s」）" % str(bad.get("reason", "")))
	check(_alive(s3, b3) == b, "被拒的那一下没扣掉 B 的牌（B 剩 %d）" % _alive(s3, b3))
	check(int(p3[CardDB.RES_USER]) == (pts - 1) * int(n["per_card"]),
		"被拒的那一下也没扣点数（剩 %d 点）" % int(p3[CardDB.RES_USER]))
	# A 打完 → 锁自然失效，余点转 B
	for i in range(1, a):
		check(_hit(s3, a3[i], p3)["ok"], "A 的第 %d 张也打掉" % (i + 1))
	check(_hit(s3, b3[0], p3)["ok"], "A 打空后余点转 B：成立")
	check(int(p3[CardDB.RES_USER]) == 0, "%d 点刚好花完（剩 %d）" % [
		pts * int(n["per_card"]), int(p3[CardDB.RES_USER])])

	# ---- 散卡不上锁：先削一张散卡、再拿余点拆组合，一直是允许的打法 ----
	var s4 := _lock_table()
	var b4: Array = _combo_user_uids(s4, 1)
	var loose: Array = _loose_user_uids(s4)
	check(loose.size() >= 1, "桌上有散用户卡（%d 张）" % loose.size())
	var p4 := { CardDB.RES_CASH: 0, CardDB.RES_USER: pts * int(n["per_card"]) }
	check(_hit(s4, loose[0], p4)["ok"], "先削一张散卡：成立")
	check(GameState.attack_lock(p4) == "",
		"散卡不上锁（池子里的锁为「%s」，应为空）" % GameState.attack_lock(p4))
	check(_hit(s4, b4[0], p4)["ok"], "余点接着拆组合：成立")

	# ---- 锁着的时候连散卡也不许打：那也是绕开「先打完 A」 ----
	var s5 := _lock_table()
	var a5: Array = _combo_user_uids(s5, 0)
	var loose5: Array = _loose_user_uids(s5)
	var p5 := { CardDB.RES_CASH: 0, CardDB.RES_USER: pts * int(n["per_card"]) }
	check(_hit(s5, a5[0], p5)["ok"], "打 A 的第 1 张：成立")
	var dodge: Dictionary = _hit(s5, loose5[0], p5)
	check(not dodge["ok"], "A 还没打完就拐去啃散卡：被拒（%s）" % str(dodge.get("reason", "")))

	# ---- 锁跟着攻击回合一起结束：收手后不该留在池子里 ----
	# 留着的话下一回合装完弹，第一击会被上一回合的锁挡掉 ——
	# 而那一组可能早就不在桌上了，玩家看到的是「谁也点不了」
	var s6 := _lock_table()
	var ia := IntentApply.new(s6)
	ia.seed_pool_for_test(GameState.PLAYER, 0, pts * int(n["per_card"]))
	var a6: Array = _combo_user_uids(s6, 0)
	var hit6: Dictionary = ia.apply(Intent.apply_attack(GameState.PLAYER,
		_target_of(s6, a6[0])), GameState.PLAYER)
	check(hit6.get("ok", false), "走裁决器打 A 的第 1 张：成立")
	check(GameState.attack_lock(ia.pools(GameState.PLAYER)) != "",
		"裁决器的池子里也记下了锁")
	ia.apply(Intent.attack_done(GameState.PLAYER), GameState.PLAYER)
	check(GameState.attack_lock(ia.pools(GameState.PLAYER)) == "",
		"收手后锁被清掉（实际「%s」）" % GameState.attack_lock(ia.pools(GameState.PLAYER)))

	# ---- 锁要跟着池子上网：接手方 / 重连的客户端算出的候选面得和服务器一样 ----
	var ia2 := IntentApply.new(s6)
	ia2.seed_pool_for_test(GameState.PLAYER, 0, pts * int(n["per_card"]))
	var p_lock: Dictionary = ia2.pools(GameState.PLAYER)
	p_lock[GameState.ATTACK_LOCK] = "combo_0"
	var snap: Dictionary = ia2.pools_snapshot()
	var ia3 := IntentApply.new(s6)
	ia3.pools_restore(snap)
	check(GameState.attack_lock(ia3.pools(GameState.PLAYER)) == "combo_0",
		"锁过了一趟 pools_snapshot / pools_restore（实际「%s」）" % [
			GameState.attack_lock(ia3.pools(GameState.PLAYER))])

## 算例里的三个量，全从卡表推：
## - pts：手上的用户攻击点数换成「能点几张」= 补贴大战的 attack_n / attack_cost_per_card
## - b：B 组露的席位 = 云课堂的 recipe_n（配方核心，逐张成靶）
## - a：A 组露的席位，取 pts - 1 —— 比点数少一张，A 打光后正好剩一张的余点转去 B。
##   这一张余点是算例的关键：它把「打完 A 才能转组」和「转组之后确实能打」一起演掉
func _lock_nums() -> Dictionary:
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var pts := int(CardDB.get_def("butie")["attack_n"]) / per_card
	return {
		"per_card": per_card,
		"pts": pts,
		"a": pts - 1,
		"b": int(CardDB.get_def("yunketang")["recipe_n"]),
	}

## 摆一张「A 组 a 席 / B 组 b 席」的桌子（张数见 _lock_nums）。
##
## 双方都留足够的散牌防清零即胜误触发：那条判定在**每一次移除后**都跑一遍，
## 一旦提前判出胜负，Settle.attack_phase 的循环当场就断，后面几下全成了空转
## （判据会读到「点数没花完」，而原因跟锁毫无关系）
func _lock_table() -> GameState:
	var s := _blank_state(GameState.PLAYER)
	# 玩家：补贴大战 + 现金×配方量 → 3 点用户攻击。多备现金，
	# 免得装弹时撞上 _attack_recipe_payable 的「开火会让资金归零」护栏
	var atk_n := int(CardDB.get_def("butie")["recipe_n"])
	var p_core := s.add_card(GameState.PLAYER, "butie")
	var p_cash: Array = []
	for i in atk_n: p_cash.append(s.add_card(GameState.PLAYER, "cash"))
	# 下面几摞散牌是判据自己的规模：只要「够厚」，具体几张不影响这一节量的东西
	for i in 6: s.add_card(GameState.PLAYER, "cash")
	for i in 2: s.add_card(GameState.PLAYER, "user")
	s.create_combo(GameState.PLAYER, [p_core["uid"]] + _uids(p_cash))

	# BOT 的 A 组：外卖补贴（吃现金）+ 现金×配方量 + 用户×a。
	# 那几张用户不是配方料 → 全算富余（kind=spare），就是算例里的「A 含 a 张用户」
	var n := _lock_nums()
	var waimai_n := int(CardDB.get_def("waimai")["recipe_n"])
	var a_core := s.add_card(GameState.BOT, "waimai")
	var a_ids: Array = [a_core["uid"]]
	for i in waimai_n: a_ids.append(s.add_card(GameState.BOT, "cash")["uid"])
	for i in int(n["a"]): a_ids.append(s.add_card(GameState.BOT, "user")["uid"])
	s.create_combo(GameState.BOT, a_ids)

	# BOT 的 B 组：云课堂（吃用户×配方量）+ 用户×配方量 → 那几张是配方核心（kind=combo）
	var b_core := s.add_card(GameState.BOT, "yunketang")
	var b_ids: Array = [b_core["uid"]]
	for i in int(n["b"]): b_ids.append(s.add_card(GameState.BOT, "user")["uid"])
	s.create_combo(GameState.BOT, b_ids)

	# 散牌：吊命 + 给「散卡不上锁」那两段用
	for i in 4: s.add_card(GameState.BOT, "user")
	for i in 4: s.add_card(GameState.BOT, "cash")
	return s

## 第 idx 个 BOT 组合里的用户卡 uid，按 attack_targets 给出的顺序
func _combo_user_uids(s: GameState, idx: int) -> Array:
	var bot_combos: Array = s.combos.filter(func(c): return c["owner"] == GameState.BOT)
	if idx >= bot_combos.size():
		return []
	var out: Array = []
	for u in bot_combos[idx]["uids"]:
		var c := s.find_card(GameState.BOT, u)
		if c.is_empty():
			continue
		if CardDB.get_def(c["def_id"]).get("res", "") == CardDB.RES_USER:
			out.append(u)
	return out

## 不在任何组合里的 BOT 用户卡
func _loose_user_uids(s: GameState) -> Array:
	var inside := {}
	for combo in s.combos:
		if combo["owner"] != GameState.BOT:
			continue
		for u in combo["uids"]:
			inside[u] = true
	var out: Array = []
	for c in s.players[GameState.BOT]["cards"]:
		if inside.has(c["uid"]):
			continue
		if CardDB.get_def(c["def_id"]).get("res", "") == CardDB.RES_USER:
			out.append(c["uid"])
	return out

## uid 对应的攻击目标（attack_targets 里那一条）
func _target_of(s: GameState, uid: int) -> Dictionary:
	for t in s.attack_targets(GameState.BOT):
		if t["uids"].has(uid):
			return t
	return {}

## 直接点一张：绕开选靶，专测 apply_attack 那道护栏
func _hit(s: GameState, uid: int, pools: Dictionary) -> Dictionary:
	var t := _target_of(s, uid)
	if t.is_empty():
		return { "ok": false, "reason": "靶不在场上（uid %d）" % uid }
	return s.apply_attack(GameState.PLAYER, t, pools)

## 还活着几张
func _alive(s: GameState, uids: Array) -> int:
	var n := 0
	for u in uids:
		if not s.find_card(GameState.BOT, u).is_empty():
			n += 1
	return n

## 造一个「优先打 want 里那几张、否则随便挑第一个」的 picker，
## 顺手把每次挑中的靶记进 spent（用来数一共打了几下）
func _picker_prefer(want: Array, spent: Array) -> Callable:
	return func(_s: GameState, _who: String, targets: Array, _pools: Dictionary) -> Dictionary:
		var pick := {}
		for t in targets:
			for u in t["uids"]:
				if want.has(u):
					pick = t
					break
			if not pick.is_empty():
				break
		if pick.is_empty() and not targets.is_empty():
			pick = targets[0]
		if not pick.is_empty():
			spent.append(pick)
		return pick

## 【测试9】已经打破的组不再是首选：BOT 第一下该挑还活着的那个组
##
## 为什么单独测这一条：「一次只打一个组合」（GameState.ATTACK_LOCK）之后，
## 攻击目标继续携带完好/已破状态，实际攻击只影响选中的组合。
func test_targets_distinguish_broken_combo() -> void:
	print("【测试9】环境区分已破与完好的组合目标")
	var s := _blank_state(GameState.PLAYER)
	# 两边的散牌都是判据自己的规模：只为吊命（防清零即胜提前结束），几张都不影响选靶
	for i in 4: s.add_card(GameState.PLAYER, "cash")
	for i in 4: s.add_card(GameState.PLAYER, "user")

	# 尸体组：刷不停（吃用户）—— 席位最多的那张。建组后抽掉一张核心，
	# protect_quota 冻在 recipe_n 不会缩，剩下的核心因此是 intact=false 的「已破组」
	var dead_n := int(CardDB.get_def("shuabuting")["recipe_n"])
	var dead_core := s.add_card(GameState.BOT, "shuabuting")
	var dead_ids: Array = [dead_core["uid"]]
	for i in dead_n: dead_ids.append(s.add_card(GameState.BOT, "user")["uid"])
	s.create_combo(GameState.BOT, dead_ids)
	s.remove_card(GameState.BOT, dead_ids[1])   # 抽走一张核心 → 这一组作废
	var dead_rest: Array = dead_ids.slice(2)

	# 活组：云课堂（吃用户）—— 席位比尸体少，靠 intact 那一支才赢得过
	var live_n := int(CardDB.get_def("yunketang")["recipe_n"])
	var live_core := s.add_card(GameState.BOT, "yunketang")
	var live_ids: Array = [live_core["uid"]]
	for i in live_n: live_ids.append(s.add_card(GameState.BOT, "user")["uid"])
	s.create_combo(GameState.BOT, live_ids)
	for i in 3: s.add_card(GameState.BOT, "cash")

	# 先确认牌桌真是「一具尸体 + 一个活组」，而且尸体的席位更多 ——
	# 不然这一条测的就不是它想测的东西了
	var broken: Array = []
	var intact: Array = []
	for t in s.attack_targets(GameState.BOT):
		if str(t["kind"]) != "combo":
			continue
		if bool(t.get("intact", true)):
			intact.append(t)
		else:
			broken.append(t)
	check(not broken.is_empty(), "牌桌上有已破组的核心（%d 个靶）" % broken.size())
	check(not intact.is_empty(), "牌桌上有还成立的组（%d 个靶）" % intact.size())
	check(dead_n > live_n,
		"尸体的席位更多（%d > %d）—— 降价一去它就该反超" % [dead_n, live_n])

	# 点数只要够点得动任何一个靶就行（这一节量的是「挑谁」，不是「打几张」），
	# 所以按 attack_cost_per_card 给足一整组的量
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var pools := { CardDB.RES_CASH: 0, CardDB.RES_USER: dead_n * per_card }
	# 环境明确区分已破与完好目标；不把某版选靶偏好当作游戏规则。
	var live_target: Dictionary = intact[0]
	check(s.apply_attack(GameState.PLAYER, live_target, pools)["ok"], "完好组合目标仍可合法攻击")
	check(not s.combo_intact(GameState.BOT, s.combos[1]), "点掉完好组合的一张核心后环境报告配方被拆散")
	for uid in dead_rest:
		check(not s.find_card(GameState.BOT, uid).is_empty(), "攻击另一个组不移除已破组合的剩余席位")

## 历史诊断使用的两个观测量（当前手动调参 Q1–Q9 不依赖它们）：
##   state.stats.voided       克制次数：一次攻击让对手一个**本来成立**的组变不成立
##   state.sealed_combos(who) 成型：此刻无解的生产组合
##
## 为什么要盯着：两个量都是「只写不读」的观测量，规则一条都不依赖它们。
## 于是它们坏掉的方式是**静默**的 —— 评估报告照样打印，数字照样是个数字，
## 只是不再对应真实事件。这里直接构造攻击和保护场景，核对它们各自的定义。
##
## 用 _lock_table() 那张牌桌：BOT 的 B 组核心吃用户（云课堂），点得到；
## A 组核心吃现金、组里的用户全是富余（kind=spare），打富余**不该**算克制
func test_eval_observables() -> void:
	print("【测试10】评估观测量：克制只认「本来成立的组刚被打破」，成型只认无解生产组")
	var n := _lock_nums()
	var per_card := int(n["per_card"])
	var s := _lock_table()

	check(int(s.stats["voided"][GameState.PLAYER]) == 0
			and int(s.stats["voided"][GameState.BOT]) == 0,
		"开局两边的克制计数都是 0")

	# ---- 打富余料：配方不破，不算克制 ----
	var spare: Array = []
	for t in s.attack_targets(GameState.BOT):
		if str(t["kind"]) == "spare":
			spare.append(t)
	check(not spare.is_empty(), "牌桌上有富余靶（%d 个）" % spare.size())
	var p1 := { CardDB.RES_CASH: 0, CardDB.RES_USER: per_card }
	var r1: Dictionary = s.apply_attack(GameState.PLAYER, spare[0], p1)
	check(r1["ok"], "打掉一张富余料：成立（%s）" % r1.get("reason", ""))
	check(not bool(r1["voided"]), "回执里 voided=false —— 富余料顶上，配方未破")
	check(int(s.stats["voided"][GameState.PLAYER]) == 0, "克制计数没动（仍是 0）")

	# ---- 打核心、但富余料顶上：配方没破，也不算克制 ----
	# 这一例和上一例的区别很要紧：上面打的是 kind=spare（配方压根没动），
	# 这里打的是 kind=combo 的**核心**，只是组里多备了一张同资源的富余料顶上来。
	# 少了这一例，「voided = broke and was_intact」里的 `broke` 就没有判据盯着 ——
	# 改成 `voided = was_intact` 全套照旧全绿（实测过）
	var s_fill := _blank_state(GameState.PLAYER)
	var fdef: Dictionary = CardDB.get_def("yunketang")
	var fcore := s_fill.add_card(GameState.BOT, "yunketang")
	var fusers: Array = []
	for i in int(fdef["recipe_n"]) + 1:   # 多备一张 → 打掉一张核心还够配方
		fusers.append(s_fill.add_card(GameState.BOT, "user")["uid"])
	for i in 3: s_fill.add_card(GameState.BOT, "cash")
	for i in 3: s_fill.add_card(GameState.PLAYER, "cash")
	var fmade := s_fill.create_combo(GameState.BOT, [fcore["uid"]] + fusers)
	check(fmade["ok"], "「%s+用户×%d」编组成立（多备一张富余）（%s）" % [
		fdef["name"], int(fdef["recipe_n"]) + 1, fmade.get("reason", "")])
	var fcores: Array = []
	for t in s_fill.attack_targets(GameState.BOT):
		if str(t["kind"]) == "combo":
			fcores.append(t)
	check(fcores.size() == int(fdef["recipe_n"]),
		"露出 %d 张核心靶（实际 %d）" % [int(fdef["recipe_n"]), fcores.size()])
	var pf := { CardDB.RES_CASH: 0, CardDB.RES_USER: per_card }
	var rf: Dictionary = s_fill.apply_attack(GameState.PLAYER, fcores[0], pf)
	check(rf["ok"], "打掉一张核心：成立（%s）" % rf.get("reason", ""))
	check(bool(fcores[0].get("intact", false)),
		"这一下打的是**本来成立**的组（intact=true）")
	check(not bool(rf["voided"]),
		"但富余料顶上、配方没破 → voided=false（不是克制）")
	check(int(s_fill.stats["voided"][GameState.PLAYER]) == 0,
		"克制计数没动（实际 %d）" % int(s_fill.stats["voided"][GameState.PLAYER]))

	# ---- 打核心到破：算一次克制，且只算一次 ----
	# B 组核心吃用户，`protect_quota` 覆盖整份配方 → 每一张都是 kind=combo。
	# 第一张就把配方打破（没有富余用户顶上），后面几张打的是「早已告破」的组
	var s2 := _lock_table()
	var b2: Array = _combo_user_uids(s2, 1)
	check(b2.size() >= 2, "B 组至少 2 张核心（实际 %d）—— 才测得出「只算一次」" % b2.size())
	var p2 := { CardDB.RES_CASH: 0, CardDB.RES_USER: b2.size() * per_card }
	var r2: Dictionary = _hit(s2, b2[0], p2)
	check(r2["ok"], "打 B 组第 1 张核心：成立（%s）" % r2.get("reason", ""))
	check(bool(r2["voided"]), "回执里 voided=true —— 这一下把成立的组打成不成立")
	check(int(s2.stats["voided"][GameState.PLAYER]) == 1, "克制计数 +1（现在是 %d）" % [
		int(s2.stats["voided"][GameState.PLAYER])])
	var r3: Dictionary = _hit(s2, b2[1], p2)
	check(r3["ok"], "接着打第 2 张核心：成立（%s）" % r3.get("reason", ""))
	check(not bool(r3["voided"]),
		"回执里 voided=false —— 组早就破了，不该再刷一次爽点")
	check(int(s2.stats["voided"][GameState.PLAYER]) == 1,
		"克制计数仍是 1（实际 %d）" % int(s2.stats["voided"][GameState.PLAYER]))
	# 计数记在**攻击方**名下，才能区分是哪一方造成组合失效。
	check(int(s2.stats["voided"][GameState.BOT]) == 0, "记的是攻击方（BOT 那边仍是 0）")

	# ---- 成型：点得到核心的组不算，罩住的才算 ----
	var s3 := _lock_table()
	check(s3.sealed_combos(GameState.BOT).is_empty(),
		"B 组的核心露在外面 → BOT 此刻没有成型的组（实际 %d 个）" % [
			s3.sealed_combos(GameState.BOT).size()])
	# 一个**核心被罩住的攻击组合**：按字面「有效组合 + 核心点不到」它满足，
	# 但 sealed_combos 专门观察受保护的生产能力，攻击组合不算成型。
	# 这一条是「只认生产组合」那道过滤器的判据：
	# 去掉那道过滤，这里当场变红
	var s_atk := _blank_state(GameState.PLAYER)
	var atk_def: Dictionary = CardDB.get_def("butie")
	var atk_core := s_atk.add_card(GameState.BOT, "butie")
	var atk_pay: Array = []
	for i in int(atk_def["recipe_n"]):
		atk_pay.append(s_atk.add_card(GameState.BOT, CardDB.unit_id(atk_def["recipe_res"]))["uid"])
	# 补贴大战吃现金 → 要护现金的那张 Buff（降价促销）
	var atk_buff := s_atk.add_card(GameState.BOT, "jiangjia")
	for i in 4: s_atk.add_card(GameState.BOT, "cash")
	for i in 3: s_atk.add_card(GameState.PLAYER, "cash")
	var atk_made := s_atk.create_combo(GameState.BOT,
		[atk_core["uid"], atk_buff["uid"]] + atk_pay)
	check(atk_made["ok"], "「%s+现金×%d+降价促销」编组成立（%s）" % [
		atk_def["name"], int(atk_def["recipe_n"]), atk_made.get("reason", "")])
	check(str(atk_made["eval"].get("type", "")) == "attack", "它是攻击组合")
	var atk_cores: Array = []
	for t in s_atk.attack_targets(GameState.BOT):
		if str(t["kind"]) == "combo":
			atk_cores.append(t)
	check(atk_cores.is_empty(),
		"它的核心被 Buff 罩住了，一个都点不到（实际 %d 个靶）" % atk_cores.size())
	check(s_atk.sealed_combos(GameState.BOT).is_empty(),
		"但它不算成型 —— 只认生产组合（实际 %d 个）" % s_atk.sealed_combos(GameState.BOT).size())

	# ---- 罩住核心的生产组：这才算成型 ----
	# 云课堂（吃用户）+ 用户×配方量 + 推送弹窗（护用户）。
	# Buff 入组当回合即保护；被罩住核心的生产组合当回合就算成型。
	var s5 := _blank_state(GameState.PLAYER)
	var def: Dictionary = CardDB.get_def("yunketang")
	var core := s5.add_card(GameState.BOT, "yunketang")
	var users: Array = []
	for i in int(def["recipe_n"]):
		users.append(s5.add_card(GameState.BOT, "user")["uid"])
	var buff := s5.add_card(GameState.BOT, "tuisong")
	for i in 3: s5.add_card(GameState.BOT, "cash")     # 防清零即胜提前结束
	for i in 3: s5.add_card(GameState.PLAYER, "cash")
	var made := s5.create_combo(GameState.BOT, [core["uid"], buff["uid"]] + users)
	check(made["ok"], "「%s+用户×%d+推送弹窗」编组成立（%s）" % [
		def["name"], int(def["recipe_n"]), made.get("reason", "")])
	check(s5.buff_armed(GameState.BOT, buff["uid"]), "推送弹窗入组当回合立即保护")
	var sealed: Array = s5.sealed_combos(GameState.BOT)
	check(sealed.size() == 1, "核心被罩住 → 这一组成型（实际 %d 个）" % sealed.size())
	check(sealed.size() == 1 and sealed[0]["eval"].get("type") == "production",
		"记下的是生产组合")
