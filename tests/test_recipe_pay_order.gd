# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 配方付款的归零护栏，以及它和结算次序的关系（README.md §「2.6 组合与结算」）
##
## 起因是一份实测：春晚冠名（吃现金、产用户）手上的现金恰好等于它那份配方，
## 结算后现金一分没动、用户 0 —— 整摞牌白摞一回合，战报只有一句「整组作废」。
##
## 护栏本身是对的，不能拆：`check_victory` 里现金归零就判负，而 `finalize`
## 每回合无条件调它。付掉最后 10 块换 5 个用户，换完当场就输了，
## 那不是玩家想要的结果 —— 买卡的 zero_out、典当的 pawn_would_zero_user
## 是同一条原则的另外两处落点。
##
## 真正的毛病在**次序**：护栏念的是「此刻手上的全部现金」，而进账的组合也在
## 同一次 produce 里。按编组次序结算的话，同样两摞牌只因为玩家先摞了哪一摞，
## 一摞会活一摞会废 —— 收益在队列后面排着，付款那摞先撞上护栏。
## 所以 `Settle.ordered_production_combos` 在每个座位内部再分两拨：
## 不吃现金的先结，吃现金的后结。
##
## 这一组判据盯六条边界，各自对应一条会静默退化的实现错法：
##   1. 护栏还在      —— 拆掉它，玩家能付到归零，下一句就是判负
##   2. 差 1 块就能过   —— 写成 `< 0` 而不是 `<= 0`，归零局照样成立
##   3. 进账排在付款前 —— 去掉分拨，编组次序决定谁死，且**只在混摞时现形**
##   4. 下标是稳的     —— 排序键要是掺了当前现金，结到一半 combo_idx 就错位，
##                      而 combo_idx 是过网线的东西（Intent.produce）
##   5. AI 预判累计    —— 只问 resource_count 的话，本回合已编的组占掉的钱看不见，
##                      AI 会连编两组吃现金的、后结那组必废（下面 T6 的原始现象）
##   6. 累计不误伤     —— 修 5 的时候容易过头，把「有进账兜着」的组也一起挡掉
##
## 变异提示（每条都实跑验证过会红）：
##   settle.gd 的 `- need <= 0` 改成 `- need < 0`                → 第 2 组红
##   ordered_production_combos 去掉 `for pays_cash in [false, true]` 分拨 → 第 3 组红

const CardDB = preload("res://engine/card_db.gd")
const GameState = preload("res://engine/game_state.gd")
const Settle = preload("res://engine/settle.gd")
const Actions = preload("res://engine/ai_actions.gd")
const Env = preload("res://engine/ai_environment.gd")

func _initialize() -> void:
	print("=== 配方付款护栏与结算次序 测试 ===\n")
	CardDB.ensure_loaded()
	_t1_zero_out_refused()
	_t2_one_spare_cash_passes()
	_t3_income_settles_before_payment()
	_t4_order_stable_across_recompute()
	_t5_income_counted_in_warning()
	_t6_ai_predict_accumulates()
	_t7_ai_predict_counts_income()
	finish()


## 空桌子起一局：只留我们要的牌，开局那份 `_game.start_cash` 会盖掉所有判据
func _bare() -> GameState:
	var s := GameState.new()
	s.new_game()
	s.players[GameState.PLAYER]["cards"] = []
	return s


## 发 n 张单位卡，返回 uid 列表。锁着发 —— 调用方紧接着就 create_combo
func _units(s: GameState, res: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(int(s.add_card(GameState.PLAYER, CardDB.unit_id(res), true)["uid"]))
	return out


## 同上但**不锁**：给 候选生成器 用。
## 它的候选池只收没锁的卡（`if not c["locked"]`），锁着发就是个空池子
func _free_units(s: GameState, res: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(int(s.add_card(GameState.PLAYER, CardDB.unit_id(res))["uid"]))
	return out


## 摞一组：核心卡 + 刚好一份配方的单位卡。
## 张数和币种一律读卡表 —— 这一组判据量的是「付款次序」，
## 谁吃几张是数值旋钮，写死在调用处等于每轮调参都要来改七个地方
func _pile(s: GameState, core: String) -> Dictionary:
	var d: Dictionary = CardDB.get_def(core)
	var core_uid := int(s.add_card(GameState.PLAYER, core, true)["uid"])
	var uids: Array = [core_uid] + _units(s, str(d["recipe_res"]), int(d["recipe_n"]))
	return s.create_combo(GameState.PLAYER, uids)


## 这一摞核心卡吃几张（= 它的 recipe_n）
func _need(core: String) -> int:
	return int(CardDB.get_def(core)["recipe_n"])


## 这一摞核心卡产几点（= 它的 output_n）
func _out(core: String) -> int:
	return int(CardDB.get_def(core)["output_n"])


func _cash(s: GameState) -> int:
	return s.resource_count(GameState.PLAYER, CardDB.RES_CASH)


func _user(s: GameState) -> int:
	return s.resource_count(GameState.PLAYER, CardDB.RES_USER)


# ---------- T1：付完归零 → 拒付 ----------

## 手上的现金正好等于配方要的张数：整组作废，现金原封不动。
## 这是报上来的那个现象，也是护栏该有的行为 —— 付了就判负
func _t1_zero_out_refused() -> void:
	print("\n-- T1 付完归零，整组作废 --")
	var s := _bare()
	var r := _pile(s, "chunwan")
	check(bool(r["ok"]), "编组这一步不拦（编组时算不出结算时的现金）")
	var need := _need("chunwan")
	Settle.run(s)
	check(_cash(s) == need, "现金没被扣走（还是 %d，实拿到 %d）" % [need, _cash(s)])
	check(_user(s) == 0, "用户没产出（0，实拿到 %d）" % _user(s))
	# 战报要说清是「归零」而不是「付不起」：两条拦法的说明不一样，
	# 混了的话玩家会去凑更多现金卡进摞里，而那正好是反方向
	var said := false
	for e in s.log:
		if s.render_entry(e, GameState.PLAYER).contains("会让资金归零"):
			said = true
	check(said, "战报说明了是「会让资金归零」")


# ---------- T2：多 1 块就成立 ----------

## 同样的摞，组外多 1 块现金：付得动，产出到账。
## 边界卡在这 1 块上 —— 护栏写成 `< 0` 的话 T1 会过，这一条照样过，
## 所以两条都要
func _t2_one_spare_cash_passes() -> void:
	print("\n-- T2 组外多 1 块，付得动 --")
	var s := _bare()
	var r := _pile(s, "chunwan")
	check(bool(r["ok"]), "编组成功")
	var need := _need("chunwan")
	_units(s, CardDB.RES_CASH, 1)   # 组外的散钱，不在摞里
	check(_cash(s) == need + 1, "结算前手上 %d" % (need + 1))
	Settle.run(s)
	check(_cash(s) == 1, "付掉 %d 之后剩 1（实拿到 %d）" % [need, _cash(s)])
	check(_user(s) == _out("chunwan"),
		"%d 用户到账（实拿到 %d）" % [_out("chunwan"), _user(s)])
	check(s.winner == "", "没判负（留了 1 块，现金没归零）")


# ---------- T3：进账先结，付款后结 ----------

## 混摞：付款摞（春晚，吃现金）+ 进账摞（云课堂，吃用户产现金），
## 而且**故意先摞付款那摞**。分拨之前付款摞 order 更小、先撞护栏作废；
## 分拨之后进账先落地，「开局 + 进账」付掉那份配方还剩着，两摞都活。
##
## 这一条是整个修法的判据。它只在混摞时现形 —— T1/T2 单摞跑，
## 去掉分拨照样全绿
func _t3_income_settles_before_payment() -> void:
	print("\n-- T3 同一回合里进账排在付款前 --")
	var s := _bare()
	var pay := _pile(s, "chunwan")
	var earn := _pile(s, "yunketang")
	check(bool(pay["ok"]) and bool(earn["ok"]), "两摞都编成了")
	var need := _need("chunwan")
	check(_cash(s) == need, "结算前手上 %d（不够独立付这一摞）" % need)

	# 先看次序本身：付款的排在最后
	var ordered: Array = Settle.ordered_production_combos(s)
	check(ordered.size() == 2, "两组都在结算表里")
	check(int(ordered[0]["eval"].get("recipe_pay_n", 0)) == 0,
		"第一组不吃现金（实际吃 %d）" % int(ordered[0]["eval"].get("recipe_pay_n", 0)))
	check(int(ordered[1]["eval"].get("recipe_pay_n", 0)) == need,
		"第二组吃 %d 现金（实际吃 %d）" % [
			need, int(ordered[1]["eval"].get("recipe_pay_n", 0))])
	check(str(ordered[1]["eval"]["leader"]) == "chunwan",
		"先编的付款摞被排到了后面（编组次序不再决定生死）")

	Settle.run(s)
	# 现金：开局 + 云课堂产出 − 春晚配方。
	# 用户：云课堂配方里那几张（席位不是成本，一张不扣）+ 春晚产出
	var cash_want := need + _out("yunketang") - need
	var user_want := _need("yunketang") + _out("chunwan")
	check(_cash(s) == cash_want, "现金 %d+%d−%d=%d（实拿到 %d）" % [
		need, _out("yunketang"), need, cash_want, _cash(s)])
	check(_user(s) == user_want, "用户 %d+%d=%d（实拿到 %d）" % [
		_need("yunketang"), _out("chunwan"), user_want, _user(s)])
	var voided := false
	for e in s.log:
		if s.render_entry(e, GameState.PLAYER).contains("整组作废"):
			voided = true
	check(not voided, "没有任何一摞作废")


# ---------- T4：下标跨重算不动 ----------

## `IntentApply._produce` 每结一组都重算一次这张表，下标取自表里第几个,
## 而这个下标是过网线的（`Intent.produce(combo_idx)`）。
## 排序键要是掺了「当前现金」，第一组结完现金就变了、表跟着重排，
## 第二次的下标 1 会指到别的组上 —— 于是同一串意图两端结出不同局面
func _t4_order_stable_across_recompute() -> void:
	print("\n-- T4 逐组结算时下标不会错位 --")
	var s := _bare()
	_pile(s, "chunwan")
	_pile(s, "yunketang")

	var before: Array = []
	for c in Settle.ordered_production_combos(s):
		before.append(str(c["eval"]["leader"]))
	# 结掉第 0 组（进账那组），现金涨一笔云课堂的产出
	var cash_after := _need("chunwan") + _out("yunketang")
	Settle._resolve_combo(s, Settle.ordered_production_combos(s)[0])
	check(_cash(s) == cash_after, "第一组结完现金变成 %d（实 %d）" % [cash_after, _cash(s)])
	var after: Array = []
	for c in Settle.ordered_production_combos(s):
		after.append(str(c["eval"]["leader"]))
	check(before == after, "现金变了，结算次序不变（%s → %s）" % [before, after])


# ---------- T5：预警要把先到账的进账算进去 ----------

## HUD 的归零预警念的是 `现金 + pending_cash_income − pending_pay <= 0`。
## 进账那一项不能少：混摞时进账先落地（T3），少了它「有进账兜着、手上不够付」
## 会被报成必废，而它其实付得起 —— 一条会误报的警报等于没有警报。
##
## 反过来，进账那一项也不能算宽：吃现金的摞哪怕产出现金也不算（它自己就是
## 后结那一拨），否则预警会拿一笔还没到手的钱去证明自己付得起
func _t5_income_counted_in_warning() -> void:
	print("\n-- T5 归零预警把先到账的进账算进去 --")
	var s := _bare()
	var who := GameState.PLAYER

	# 进账摞：云课堂（吃用户产现金），一分钱不付
	var yun := int(s.add_card(who, "yunketang", true)["uid"])
	var us := _units(s, CardDB.RES_USER, _need("yunketang"))
	var earn_pile := { "uids": [yun] + us }
	check(s.pending_cash_income(who, [earn_pile]) == _out("yunketang"),
		"进账摞记 %d（实 %d）" % [
			_out("yunketang"), s.pending_cash_income(who, [earn_pile])])
	check(s.pending_pay(who, [earn_pile]) == 0, "进账摞待付 0（用户配方不掏钱）")

	# 付款摞：春晚（吃现金产用户），产出是用户，不该被记成进账
	var cw := int(s.add_card(who, "chunwan", true)["uid"])
	var cs := _units(s, CardDB.RES_CASH, _need("chunwan"))
	var pay_pile := { "uids": [cw] + cs }
	check(s.pending_cash_income(who, [pay_pile]) == 0,
		"付款摞不记进账（产出是用户；实 %d）" % s.pending_cash_income(who, [pay_pile]))

	# 哨兵：`pending_cash_income` 里那句「吃现金的摞直接跳过」现在**跑不到** ——
	# 全表没有一张「现金配方且产现金」的卡（现金配方全产用户，用户配方全产现金）。
	# 所以上面那条判据其实是被 output_res 挡住的，不是被那句跳过挡住的。
	# 哪天加了这么一张牌，那句跳过就变成活代码（它自己排在后结那一拨，
	# 不能拿自己还没到手的产出去证明自己付得起），这条哨兵会在那一刻红，
	# 提醒来人给它补一条真判据 —— 而不是让它悄悄变成没人测的分支
	var cash_to_cash: Array = []
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if str(d.get("recipe_res", "")) == CardDB.RES_CASH \
				and str(d.get("output_res", "")) == CardDB.RES_CASH:
			cash_to_cash.append(def_id)
	check(cash_to_cash.is_empty(),
		"全表没有「现金配方且产现金」的卡（有了就要给 pending_cash_income 的跳过补判据：%s）"
			% [cash_to_cash])
	check(s.pending_pay(who, [pay_pile]) == _need("chunwan"),
		"付款摞待付 %d（实 %d）" % [_need("chunwan"), s.pending_pay(who, [pay_pile])])

	# 两摞一起：手上 + 进账 − 待付 > 0 → 不该报警。
	# 这一条就是「少算进账会误报」的形状，且 T3 已经实测过它真付得动
	var piles: Array = [earn_pile, pay_pile]
	var cash := s.resource_count(who, CardDB.RES_CASH)
	check(cash == _need("chunwan"), "手上 %d（实 %d）" % [_need("chunwan"), cash])
	check(cash + s.pending_cash_income(who, piles) - s.pending_pay(who, piles) > 0,
		"混摞：算上进账之后不该报归零")
	check(cash - s.pending_pay(who, piles) <= 0,
		"而不算进账就会报 —— 少这一项正是误报的来源")


# ---------- 候选付款：累计待付与先到收入 ----------

func _t6_ai_predict_accumulates() -> void:
	var s := _bare()
	s.market = []
	for id in ["waimai", "ditui"]:
		s.add_card(GameState.PLAYER, id)
	var cash0 := _need("waimai") + _need("ditui")
	_free_units(s, CardDB.RES_CASH, cash0)
	_free_units(s, CardDB.RES_USER, 1)
	var built := false
	for node in _candidates(s):
		var candidate: GameState = node["state"]
		built = built or not candidate.combos.is_empty()
		check(candidate.committed_pay(GameState.PLAYER) < cash0,
			"累计待付不吞掉最后一张现金")
		var replay := Env.copy(s)
		check(Env.replay(replay, node["intents"]), "累计付款候选可回放")
		Settle.produce(replay)
		var voided := false
		for entry in replay.log:
			voided = voided or GameState.entry_text(entry).contains("整组作废")
		check(not voided, "累计付款候选没有整组作废")
	check(built, "预判仍保留至少一个能生产的候选")

func _t7_ai_predict_counts_income() -> void:
	var s := _bare()
	s.market = []
	for id in ["yunketang", "chunwan"]:
		s.add_card(GameState.PLAYER, id)
	var cash0 := _need("chunwan")
	var user0 := _need("yunketang")
	_free_units(s, CardDB.RES_CASH, cash0)
	_free_units(s, CardDB.RES_USER, user0)
	var found := false
	for node in _candidates(s):
		var candidate: GameState = node["state"]
		var leaders: Array = []
		for combo in candidate.combos:
			leaders.append(combo["eval"].get("leader", ""))
		if not (leaders.has("yunketang") and leaders.has("chunwan")):
			continue
		found = true
		var replay := Env.copy(s)
		check(Env.replay(replay, node["intents"]), "先收入后付款的两组候选可回放")
		Settle.produce(replay)
		check(_cash(replay) == cash0 + _out("yunketang") - _need("chunwan"),
			"先到账的现金能支付后结算配方")
		check(_user(replay) == user0 + _out("chunwan"), "两组候选实际完成生产")
	check(found, "生成器保留有进账兜底的付款组合")

func _candidates(s: GameState) -> Array:
	var profile := AISearch.from_model("ai", 0.0).resolved_parameters()
	profile.merge({"plans": 64, "sales": 0, "buy_beam": 64, "build_beam": 64}, true)
	return Actions.generate(s, GameState.PLAYER, profile)
