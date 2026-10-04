# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Plan = preload("res://engine/ai_turn_plan.gd")
const Env = preload("res://engine/ai_environment.gd")
const Actions = preload("res://engine/ai_actions.gd")
const Eval = preload("res://engine/ai_evaluation.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	var original := CardDB.CARDS.duplicate(true)
	CardDB.CARDS["probe_a"] = _product(3, 7)
	CardDB.CARDS["probe_b"] = _product(4, 8)
	CardDB.CARDS["probe_c"] = _product(7, 12)
	_test_resource_assignment()
	_test_pawn_win()
	_test_phase_and_replay()
	_test_attack_cost()
	_test_price_and_stop()
	_test_budget()
	_test_market_order()
	CardDB.CARDS = original
	finish()

func _product(need: int, output: int) -> Dictionary:
	return {"kind": "product", "tier": 7, "name": "Test", "price": 2, "weight": 0,
		"recipe_res": CardDB.RES_USER, "recipe_n": need, "output_res": CardDB.RES_CASH, "output_n": output}

func _state(users: int = 7) -> GameState:
	var s := GameState.new()
	s.set_seed(97)
	s.players = {GameState.PLAYER:{"cards":[]}, GameState.AI:{"cards":[]}}
	for who in s.players:
		for _n in 20:
			s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		for _n in users:
			s.add_card(who, CardDB.unit_id(CardDB.RES_USER))
	return s

func _test_resource_assignment() -> void:
	var s := _state()
	for id in ["probe_c", "probe_a", "probe_b"]:
		s.add_card(GameState.AI, id)
	var p := Plan.profile(1)
	p["sales"] = 0
	var nodes := Actions.generate(s, GameState.AI, p)
	var best_income := 0
	var chosen := {}
	for n in nodes:
		var end := Env.copy(n["state"])
		var before := end.resource_count(GameState.AI, CardDB.RES_CASH)
		Settle.produce(end)
		var income := end.resource_count(GameState.AI, CardDB.RES_CASH) - before
		if income > best_income:
			best_income = income
			chosen = n
	check(best_income == 15, "7单位资源能分给3+4两组产15，未被共同UID前缀误判互斥")
	if not chosen.is_empty():
		var replay := Env.copy(s)
		check(Env.replay(replay, chosen["intents"]), "生成的完整方案全部通过真实意图验证")
		check(Env.key(replay) == Env.key(chosen["state"]), "意图重放与搜索后继逐字段相同")

func _test_pawn_win() -> void:
	var s := _state(2)
	var who := GameState.AI
	while s.resource_count(who, CardDB.RES_CASH) < int(CardDB.game_rules()["win_cash"]) - 1:
		s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
	s.add_card(who, "probe_a")
	MatchSimulator.action_phase(s, who, AISearch.from_model("ai", 0))
	check(s.winner == who, "普通非传说牌也进入确定获胜典当")
	check(s.resource_count(who, CardDB.RES_USER) > 0, "冲线典当不违反用户归零护栏")

func _test_phase_and_replay() -> void:
	var s := _state()
	s.market = ["probe_a", "probe_b"]
	# AI是后手。对手已行动即使有现金和市场也不能再买一次。
	var expected := Env.copy(s)
	Env.settle(expected, Plan.greedy_target)
	var result := Plan.resolve_current(s, GameState.AI, Plan.profile(0))
	check(Env.key(result["state"]) == Env.key(expected), "后手叶子只结算，不给对手额外行动")
	s.players[GameState.AI]["cards"][0]["fired_round"] = 1
	s.players[GameState.AI]["cards"][1]["worked_round"] = 1
	var before := StateCodec.canon({"snapshot":StateCodec.snapshot(s),"players":s.players,"stats":s.stats})
	var selected := Plan.choose_plan(s, GameState.AI, AISearch.from_model("ai", 0))
	check(before == StateCodec.canon({"snapshot":StateCodec.snapshot(s),"players":s.players,"stats":s.stats}),
		"完整搜索保留真实状态、开火/工作标记、随机流和统计")
	var copy := Env.copy(s)
	check(copy.players == s.players and copy.rng_snapshot() == s.rng_snapshot(), "环境适配器保留运行时历史字段")
	var a := Env.copy(s)
	Env.replay(a, selected["intents"])
	var b := Env.copy(s)
	MatchSimulator.action_phase(b, GameState.AI, AISearch.from_model("ai",0))
	check(Env.key(a) == Env.key(b), "实际AIAgent执行已搜索的意图，最终编组不会换策略")

func _test_attack_cost() -> void:
	var s := _state()
	CardDB.CARDS["probe_attack"] = {"name":"Test attack", "kind":"attack", "price":1,"tier":9,
		"recipe_res":CardDB.RES_USER,"recipe_n":2,"attack_res":CardDB.RES_CASH,"attack_n":4}
	s.add_card(GameState.AI, "probe_attack")
	var old_cost: int = CardDB.GAME["attack_cost_per_card"]
	CardDB.GAME["attack_cost_per_card"] = 1
	var useful := Eval.capacity(s, GameState.AI)
	CardDB.GAME["attack_cost_per_card"] = 5
	var useless := Eval.capacity(s, GameState.AI)
	CardDB.GAME["attack_cost_per_card"] = old_cost
	check(useful > 0 and is_zero_approx(useless), "每卡攻击成本变化时，不足一击的攻击池不再估成产能")

func _test_price_and_stop() -> void:
	var s := _state()
	s.market = ["probe_a"]
	var p := Plan.profile(0)
	p["sales"] = 0
	CardDB.CARDS["probe_a"]["price"] = 21
	var costly := Actions.generate(s, GameState.AI, p)
	var bought := false
	for n in costly:
		for intent in n["intents"]:
			bought = bought or intent["op"] == Intent.OP_BUY
	check(not bought, "修改价格超过现金后，无非法购买候选")
	CardDB.CARDS["probe_a"]["price"] = 2
	var cheap := Actions.generate(s, GameState.AI, p)
	bought = false
	var pass_found := false
	for n in cheap:
		pass_found = pass_found or (n["intents"] as Array).is_empty()
		for intent in n["intents"]:
			bought = bought or intent["op"] == Intent.OP_BUY
	check(bought and pass_found, "价格下降后出现可购方案，仍保留显式停购")

func _test_budget() -> void:
	var previous := Plan.profile(0)
	var monotone := true
	for i in range(1, 11):
		var p := Plan.profile(i / 10.0)
		for key in ["node_budget","buy_beam","build_beam","plans","replies","sales","finalists","samples","future_rounds","target_trials"]:
			monotone = monotone and int(p[key]) >= int(previous[key])
		previous = p
	check(monotone, "总预算和主要搜索宽度随整体强度非递减，局部额度另按分配策略调整")


func _test_market_order() -> void:
	var s := GameState.new()
	s.set_seed(2)
	s.new_game()
	var cfg := AISearch.from_model("ai",0)
	var a := Env.copy(s)
	MatchSimulator.action_phase(a, GameState.PLAYER, cfg)
	s.market.reverse()
	var b := Env.copy(s)
	MatchSimulator.action_phase(b, GameState.PLAYER, cfg)
	var a_cards: Array = []
	var b_cards: Array = []
	for c in a.players[GameState.PLAYER]["cards"]:
		a_cards.append(str(c["def_id"]))
	for c in b.players[GameState.PLAYER]["cards"]:
		b_cards.append(str(c["def_id"]))
	a_cards.sort()
	b_cards.sort()
	check(a_cards == b_cards, "相同市场只改变展示顺序，仍选择同一语义购买方案")
	var chosen := Plan.choose_plan(s, GameState.AI, cfg)
	check(int(chosen["diagnostics"]["expanded_nodes"]) <= int(chosen["diagnostics"]["profile"]["node_budget"]),
		"搜索使用并遵守展开节点额度")
