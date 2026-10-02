# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Actions = preload("res://engine/ai_actions.gd")
const Env = preload("res://engine/ai_environment.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	test_t2_production_reachable()
	test_protect_quota()
	test_pawned_cash_usable_same_turn()
	test_upgrade_pure_cards()
	test_ai_pool_not_leaked_on_failure()
	test_market_buy_reaches_all_cards()
	test_no_parking_immunity()
	test_fired_attack_marker()
	test_worked_buff_marker()
	finish()

func test_no_parking_immunity() -> void:
	print("\n【7】停钱免疫已消除：富余卡可被逐张啃")
	var s := GameState.new()
	s.set_seed(108)
	s.new_game()
	s.players[GameState.AI]["cards"].clear()
	var core: Dictionary = CardDB.get_def("yunketang")
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	# kill / stock 是判据自己的规模，不是游戏数值：打几张、垫多少张富余。
	# 只要 stock > kill（削完还剩，才说明是「逐张啃」不是「整组清空」）
	var kill := 5
	var stock := 60
	var uids: Array = []
	uids.append(s.add_card(GameState.AI, "yunketang")["uid"])
	for i in int(core["recipe_n"]):
		uids.append(s.add_card(GameState.AI, "user")["uid"])
	for i in stock:
		uids.append(s.add_card(GameState.AI, "cash")["uid"])
	check(stock > kill, "夹具前提：富余 %d 张多于要削的 %d 张" % [stock, kill])
	check(s.create_combo(GameState.AI, uids)["ok"],
		"%s+用户×%d+现金×%d 编组成立" % [core["name"], int(core["recipe_n"]), stock])

	var pools := { "cash": kill * per_card, "user": 0 }
	var spent := 0
	while spent < kill:
		var afford: Array = []
		for t in s.attack_targets(GameState.AI):
			if GameState.target_affordable(t, pools):
				afford.append(t)
		if afford.is_empty():
			break
		var tgt: Dictionary = afford[0]
		if not s.apply_attack(GameState.PLAYER, tgt, pools)["ok"]:
			break
		spent += 1
	check(s.resource_count(GameState.AI, CardDB.RES_CASH) == stock - kill,
		"%d 点现金攻击削掉 %d 张：%d → %d" % [kill * per_card, kill, stock,
			s.resource_count(GameState.AI, CardDB.RES_CASH)])
	check(int(pools["cash"]) == 0, "攻击量全部花出去，没有作废")
	check(s.combo_intact(GameState.AI, s.combos[0]),
		"配方（用户×%d）未被碰 → 组合仍成立" % int(core["recipe_n"]))
	var before := s.resource_count(GameState.AI, CardDB.RES_CASH)
	Settle.produce(s)
	check(s.resource_count(GameState.AI, CardDB.RES_CASH) == before + int(core["output_n"]),
		"组合照常产出 %s+%d" % [CardDB.res_label(str(core["output_res"])), int(core["output_n"])])

func test_t2_production_reachable() -> void:
	print("\n【1】T2 生产模式不被升级判定抢先")
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") != CardDB.KIND_PRODUCT or d.get("tier", 0) != 2:
			continue
		var res: String = d["recipe_res"]
		var need: int = d["recipe_n"]
		var unit_id := "cash" if res == CardDB.RES_CASH else "user"
		var cards: Array = [{"uid": 0, "def_id": def_id}]
		for i in need:
			cards.append({"uid": 100 + i, "def_id": unit_id})
		var e := ComboRules.evaluate(cards)
		check(e["type"] == "production", "%s（配方 %s×%d）按配方投料判成生产" % [d["name"], res, need])
		# 再多堆一批富余资源：单张 T2 永远只会生产，不存在「资源多到自动升级」。
		# 堆的量得盖过最长升级路线（CardDB.max_upgrade_n），否则「没触发升级」
		# 可能只是因为张数还没够，判据落在「不会误判」那一侧
		var extra: int = CardDB.max_upgrade_n() + 1
		for i in extra:
			cards.append({"uid": 200 + i, "def_id": unit_id})
		check(ComboRules.evaluate(cards)["type"] == "production",
			"%s 富余投料（%s×%d）仍是生产" % [d["name"], res, need + extra])

func test_protect_quota() -> void:
	print("\n【2】防御 Buff 的保护额度 = 配方需求量")
	var s := GameState.new()
	s.set_seed(101)
	s.new_game()
	s.players[GameState.PLAYER]["cards"].clear()
	var core: Dictionary = CardDB.get_def("yunketang")
	var need := int(core["recipe_n"])
	# 富余量是判据自己的规模：多垫几张，好和配方量区分开
	var spare := 5
	var uids: Array = []
	uids.append(s.add_card(GameState.PLAYER, "yunketang")["uid"])
	uids.append(s.add_card(GameState.PLAYER, "tuisong")["uid"])     # 保护用户
	var users: Array = []
	for i in need + spare:
		var u: int = s.add_card(GameState.PLAYER, "user")["uid"]
		users.append(u)
		uids.append(u)
	check(s.create_combo(GameState.PLAYER, uids)["ok"],
		"%s+推送弹窗+用户×%d 编组成立" % [core["name"], need + spare])
	# 保护入组当回合即生效，额度仍然只覆盖配方用量。
	var prot := 0
	for u in users:
		if s.is_protected(GameState.PLAYER, u, CardDB.RES_USER):
			prot += 1
	check(prot == need, "%d 张用户里只有 %d 张（配方量）受保护，实际 %d" % [
		need + spare, need, prot])
	# 富余的那几张必须能被打
	var targets := s.attack_targets(GameState.PLAYER)
	var removable := 0
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	for t in targets:
		if t["res"] == CardDB.RES_USER:
			removable += int(t["cost"])
	check(removable == spare * per_card, "富余的 %d 张用户可被攻击，实际可扣 %d 点" % [
		spare, removable])

func test_pawned_cash_usable_same_turn() -> void:
	print("\n【3】典当所得现金当回合可用于组卡")
	var s := GameState.new()
	s.set_seed(102)
	s.new_game()
	s.players[GameState.AI]["cards"].clear()
	var core := s.add_card(GameState.AI, "ditui")
	var sale := s.add_card(GameState.AI, "dujiaoshou")
	# 留一张用户卡：典当会判 pawn_would_zero_user（用户归零=当场判负）。清空手牌后
	# AI 一个用户都没有，不发这一张的话 pawn() 直接被拒，典当根本不会发生 ——
	# 而「典当拿到现金」「locked==0」两条在没发生典当时也照样通过，测不出东西
	s.add_card(GameState.AI, "user")
	# 让地推配方可满足，否则它自己会先进废卡桶被当掉，核心就没了。
	# 张数从卡表取：这一节量的是「典当所得当回合可用」，地推吃几张现金无关
	for i in int(CardDB.get_def("ditui")["recipe_n"]):
		s.add_card(GameState.AI, "cash")
	var cash_before := s.resource_count(GameState.AI, CardDB.RES_CASH)
	check(Env.replay(s, [Intent.pawn(GameState.AI, [sale["uid"]])]), "显式典当意图成功")
	var cash_after := s.resource_count(GameState.AI, CardDB.RES_CASH)
	check(cash_after > cash_before, "典当换来现金：%d → %d" % [cash_before, cash_after])
	var locked := 0
	for c in s.players[GameState.AI]["cards"]:
		if c["locked"]:
			locked += 1
	check(locked == 0, "回收的现金不带 locked 标记，实际 %d 张带标记" % locked)
	var combo_ids: Array = [core["uid"]]
	for card in s.players[GameState.AI]["cards"]:
		if card["def_id"] == CardDB.unit_id(CardDB.RES_CASH) and combo_ids.size() <= int(CardDB.get_def("ditui")["recipe_n"]):
			combo_ids.append(card["uid"])
	check(Env.replay(s, [Intent.create_combo(GameState.AI, combo_ids)]), "刚典当的现金可立即用于组合")
	# 编出来的组合还要实际结算，确认典当所得当回合可用。
	var user_before := s.resource_count(GameState.AI, CardDB.RES_USER)
	Settle.run(s)
	for e in s.log:
		check(not ("整组作废" in GameState.entry_text(e)), "编出来的组合不该在结算时作废：%s" % GameState.entry_text(e))
	check(s.resource_count(GameState.AI, CardDB.RES_USER) > user_before,
		"组合真的产出了用户：%d → %d" % [user_before, s.resource_count(GameState.AI, CardDB.RES_USER)])

func test_upgrade_pure_cards() -> void:
	print("\n【4】升级组合只认同名卡")
	var s := GameState.new()
	s.set_seed(103)
	s.new_game()
	s.players[GameState.PLAYER]["cards"].clear()
	var c1: int = s.add_card(GameState.PLAYER, "shuabuting")["uid"]
	var c2: int = s.add_card(GameState.PLAYER, "shuabuting")["uid"]
	var us: Array = []
	var dirt := 4     # 掺进去几张脏卡，判据自己的规模
	for i in dirt:
		us.append(s.add_card(GameState.PLAYER, "user")["uid"])
	var r := s.create_combo(GameState.PLAYER, [c1, c2] + us)
	check(not r["ok"], "同名 T1×2 里混了 %d 张用户 → 不成立" % dirt)
	check(str(r.get("reason", "")).contains("不能有别的卡"),
		"拒绝理由说明是混了别的卡：%s" % r.get("reason", ""))
	# 混 Buff 也不行
	var bf: int = s.add_card(GameState.PLAYER, "liebian")["uid"]
	check(not s.create_combo(GameState.PLAYER, [c1, c2, bf])["ok"], "混一张 Buff 也不成立")
	# 干干净净两张就该放行，且一张用户都不掉
	var user_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	check(s.create_combo(GameState.PLAYER, [c1, c2])["ok"], "只放同名两张 → 成立")
	Settle.produce(s)
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == user_before,
		"升级不吃用户（%d → %d）" % [user_before, s.resource_count(GameState.PLAYER, CardDB.RES_USER)])

func test_ai_pool_not_leaked_on_failure() -> void:
	var s := GameState.new()
	s.set_seed(104)
	s.new_game()
	s.market = []
	for id in ["chaping", "yunketang"]:
		s.add_card(GameState.AI, id)
		var d := CardDB.get_def(id)
		for i in int(d["recipe_n"]):
			s.add_card(GameState.AI, CardDB.unit_id(str(d["recipe_res"])))
	var before := StateCodec.canon(StateCodec.snapshot(s))
	var profile := AISearch.from_model("ai", 0.0).resolved_parameters()
	profile.merge({"plans": 64, "sales": 0, "buy_beam": 64, "build_beam": 64}, true)
	var nodes := Actions.generate(s, GameState.AI, profile)
	var built := false
	for node in nodes:
		var candidate: GameState = node["state"]
		built = built or not candidate.combos.is_empty()
		var seen := {}
		for combo in candidate.combos:
			for uid in combo["uids"]:
				check(not seen.has(uid), "候选卡 %d 不被重复编入两个组合" % uid)
				seen[uid] = true
				check(not candidate.find_card(GameState.AI, uid).is_empty(), "组内卡 %d 真实存在" % uid)
		var replay := Env.copy(s)
		check(Env.replay(replay, node["intents"]), "每个生成候选的意图都合法")
	check(built, "生成器至少能编成一个合法组合")
	check(StateCodec.canon(StateCodec.snapshot(s)) == before, "候选探索不会吞掉原局面的卡")

func test_market_buy_reaches_all_cards() -> void:
	for id in CardDB.all_cards():
		var d := CardDB.get_def(id)
		var price := int(d.get("price", -1))
		if price < 0:
			continue
		var s := GameState.new()
		s.players = {GameState.PLAYER: {"cards": []}, GameState.AI: {"cards": []}}
		for who in [GameState.PLAYER, GameState.AI]:
			s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
			s.add_card(who, CardDB.unit_id(CardDB.RES_USER))
		for i in price:
			s.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_CASH))
		s.market = [id]
		check(Env.replay(s, [Intent.buy(GameState.AI, 0)]), "标价付款且留一现金可购买 %s" % id)
		check(s.resource_count(GameState.AI, CardDB.RES_CASH) == 1, "购买 %s 只扣标价" % id)

func test_fired_attack_marker() -> void:
	check(_attack_mark_run(true), "真实开火后，标记跨结算保留到下一回合")
	check(not _attack_mark_run(false), "未开火的卡不会获得 fired_round 标记")

func _attack_mark_run(fire: bool) -> bool:
	var s := GameState.new()
	s.players = {
		GameState.PLAYER: { "cards": [] },
		GameState.AI: { "cards": [] },
	}
	s.draw_first = GameState.PLAYER
	var adef: Dictionary = CardDB.get_def("zuokong")
	var need := int(adef["recipe_n"])
	var atk := s.add_card(GameState.AI, "zuokong")
	var feed: Array = []
	# 比 recipe_n 多一张：弹药吃掉配方量之后还得剩下，否则撞上 arm_attacks 的归零护栏
	# （付完 ≤ 0 就整组不开火 —— 那样 fired_round 根本不会记上，这一节就白验了）
	# 喂的资源按卡表的 recipe_res 取，不写死币种：写死的话配方一改这组就编不成，
	# 而红的是下游那几条（「真打出 N 点」「fired_round 记上了」），指不到根上
	var a_unit := CardDB.unit_id(str(adef["recipe_res"]))
	for i in need + 1:
		feed.append(s.add_card(GameState.AI, a_unit)["uid"])
	# 两种资源**各留至少 1 个**：check_victory 见 a_cash <= 0 或 a_user <= 0
	# 就判玩家赢，而 IntentApply 开头有「这局已经结束了」那道护栏 ——
	# 少哪一种，典当都会被 game_over 拒掉，于是两支都「牌还在」，
	# 反向控制变成一句空话（下面对手那两张同理，注释在那儿）。
	# 配方吃掉的那一种上面已经多喂了一张，这里补的是另一种
	if a_unit == CardDB.unit_id(CardDB.RES_USER):
		s.add_card(GameState.AI, "cash")   # 补一现金，避免无关的清零胜利
	else:
		s.add_card(GameState.AI, "user")
	# 对手留一点现金：keep_attack_opp_cash 那道闸门要对手现金低于它才放行，
	# 反向控制那一支靠它成立。
	# 用户也得给一张：check_victory 见 p_user <= 0 就判 AI 赢，而 IntentApply 开头
	# 有「这局已经结束了」那道护栏 —— 少这一张，典当会被 game_over 拒掉，
	# 于是两支都「牌还在」，反向控制变成一句空话（第一版就栽在这儿）
	s.add_card(GameState.PLAYER, "cash")
	s.add_card(GameState.PLAYER, "user")

	var in_combo: Array = [atk["uid"]]
	for i in need:
		in_combo.append(feed[i])
	check(s.create_combo(GameState.AI, in_combo)["ok"],
		"夹具：%s + %s×%d 编成攻击组合（fire=%s）" % [
			adef["name"], CardDB.card_name(a_unit), need, fire])
	if fire:
		var pool: Dictionary = s.arm_attacks(GameState.AI)
		check(int(pool[CardDB.RES_CASH]) == int(adef["attack_n"]),
			"夹具：真打出 %d 点（实际 %d）" % [int(adef["attack_n"]),
				int(pool[CardDB.RES_CASH])])
		check(s.attack_just_fired(GameState.AI, atk["uid"]),
			"夹具：fired_round 记上了")

	# 一个回合过去：finalize 清空 combos，救急跑在重建组合之前
	Settle.finalize(s)
	s.round_num += 1
	check(s.combos.is_empty(), "夹具：finalize 清空了 combos")
	return s.attack_just_fired(GameState.AI, atk["uid"])

func test_worked_buff_marker() -> void:
	check(_buff_mark_run(true), "参与开火的 Buff 标记跨结算保留")
	check(not _buff_mark_run(false), "未工作的 Buff 不会获得 worked_round 标记")
	_t_produced_buff_marked()

func _t_produced_buff_marked() -> void:
	# 挑一张吃现金配方的生产卡，好让「付不起」这一支造得出来
	var pdef_id := ""
	for id in CardDB.CARDS:
		var d: Dictionary = CardDB.CARDS[id]
		if d.get("kind") == CardDB.KIND_PRODUCT and d.get("recipe_res") == CardDB.RES_CASH:
			pdef_id = str(id)
			break
	if not need(pdef_id != "", "卡表里有吃现金配方的生产卡（生产侧判据的前提）"):
		return

	for pay in [true, false]:
		var s := GameState.new()
		s.players = {
			GameState.PLAYER: { "cards": [] },
			GameState.AI: { "cards": [] },
		}
		s.draw_first = GameState.PLAYER
		var pdef: Dictionary = CardDB.get_def(pdef_id)
		var need_n := int(pdef["recipe_n"])
		var core := s.add_card(GameState.AI, pdef_id)
		var buff := s.add_card(GameState.AI, "yinqing996")   # output_x2
		var feed: Array = []
		# pay=true 时多喂一张；pay=false 时**刚好喂 recipe_n**。
		# 「少喂」造不出作废那一支 —— 配方不足的组合压根编不成
		# （combo_rules 那道判定在 create_combo 里就拦了，第一版栽在这儿）。
		# 真正走得到的作废路径是归零护栏：付完自己资金归零就整组作废
		# （Settle._pay_recipe，和 buy 的 zero_out 同一条原则）
		var n := need_n + 1 if pay else need_n
		for i in n:
			feed.append(s.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_CASH))["uid"])
		s.add_card(GameState.AI, "user")
		s.add_card(GameState.PLAYER, "cash")
		s.add_card(GameState.PLAYER, "user")

		var uids: Array = [core["uid"]]
		for f in feed:
			uids.append(f)
		uids.append(buff["uid"])
		if not need(s.create_combo(GameState.AI, uids)["ok"],
			"夹具：%s + 现金×%d + 996引擎 编成生产组合（付得起=%s）" % [
				pdef["name"], n, pay]):
			continue
		Settle.run(s)
		if pay:
			check(s.buff_just_worked(GameState.AI, buff["uid"]),
				"生产组合真结算了 → 组里的 Buff 记上立过功")
		else:
			check(not s.buff_just_worked(GameState.AI, buff["uid"]),
				"配方付不起整组作废 → Buff 不算立过功（没白占一回合保护）")

func _buff_mark_run(fire: bool) -> bool:
	var s := GameState.new()
	s.players = {
		GameState.PLAYER: { "cards": [] },
		GameState.AI: { "cards": [] },
	}
	s.draw_first = GameState.PLAYER
	# 用 shanzhai（吃用户配方）+ resou（attack_x2），就是录像里那一对
	var adef: Dictionary = CardDB.get_def("shanzhai")
	var need := int(adef["recipe_n"])
	var atk := s.add_card(GameState.AI, "shanzhai")
	var buff := s.add_card(GameState.AI, "resou")
	var a_unit := CardDB.unit_id(str(adef["recipe_res"]))
	var feed: Array = []
	for i in need + 1:
		feed.append(s.add_card(GameState.AI, a_unit)["uid"])
	if a_unit == CardDB.unit_id(CardDB.RES_USER):
		s.add_card(GameState.AI, "cash")
	else:
		s.add_card(GameState.AI, "user")
	s.add_card(GameState.PLAYER, "cash")
	s.add_card(GameState.PLAYER, "user")

	var in_combo: Array = [atk["uid"]]
	for i in need:
		in_combo.append(feed[i])
	in_combo.append(buff["uid"])
	check(s.create_combo(GameState.AI, in_combo)["ok"],
		"夹具：%s + %s×%d + %s 编成攻击组合（fire=%s）" % [
			adef["name"], CardDB.card_name(a_unit), need,
			CardDB.card_name("resou"), fire])
	if fire:
		var pool: Dictionary = s.arm_attacks(GameState.AI)
		# 翻倍是这条判据的前提：没翻倍说明 Buff 压根没被算进这一组，
		# 那「立过功」保护的就不是我们以为的那张卡
		var want := int(adef["attack_n"]) * CardDB.buff_mult("attack_x2")
		check(int(pool[CardDB.RES_USER]) == want,
			"夹具：attack_x2 生效，真打出 %d 点（%d 的倍数，实际 %d）" % [
				want, int(adef["attack_n"]), int(pool[CardDB.RES_USER])])
		check(s.buff_just_worked(GameState.AI, buff["uid"]),
			"夹具：worked_round 记上了")

	Settle.finalize(s)
	s.round_num += 1
	check(s.combos.is_empty(), "夹具：finalize 清空了 combos")
	return s.buff_just_worked(GameState.AI, buff["uid"])
