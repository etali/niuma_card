# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Env = preload("res://engine/bot_environment.gd")
const Cap = preload("res://engine/bot_capabilities.gd")
var fixture: Dictionary

func _initialize() -> void:
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_market_denial.json"))
	var file := FileAccess.open("user://rescue_cards.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(fixture.cards))
	file.close()
	CardDB.load_from("user://rescue_cards.json")
	_test_market_denial()
	_test_single_sales_and_limits()
	_test_locked_representative()
	_test_generation_contract()
	finish()

func _state() -> GameState:
	var state := GameState.new()
	StateCodec.restore(state,fixture.state)
	return state

func _profile() -> Dictionary:
	var p := BOTSearch.from_model("bot",1.0).resolved_parameters()
	p.merge({"buy_beam":3,"build_beam":2,"plans":2,"generation_budget":512},true)
	p["_context"] = BOTActions.Context.new()
	p["_work"] = [512]
	return p

func _test_market_denial() -> void:
	var state := _state()
	var before := StateCodec.state_hash(state)
	var who: String = fixture.who
	var p := _profile()
	var generated := BOTActions._rescue_transactions(state,who,p)
	var expected := Env.copy(state)
	check(Env.replay(expected,fixture.rescue_intents),"市场阻断的一次购买通过正式付款规则")
	var matched: Dictionary = {}
	for node in generated.nodes:
		if Env.key(node.state) == Env.key(expected): matched = node
	check(not matched.is_empty(),"独立后备保留自己暂不能使用、但能买走对方杀招的单次购买")
	if not matched.is_empty():
		var attack: Dictionary = {}
		for card in matched.state.players[who].cards:
			if card.def_id == fixture.expected.denied_card: attack = card
		check(not attack.is_empty() and BOTActions.recipe_options(matched.state,who,attack,p).is_empty(),
			"该阻断购买无需自己能编成配方，也不由攻击能力摘要筛除")
		check(not matched.state.market.has(fixture.expected.denied_card) and
			matched.state.resource_count(who,"cash") == fixture.expected.rescue_cash_after_buy and
			matched.state.resource_count(who,"user") == fixture.expected.rescue_users_after_buy,
			"阻断后的市场与现金用户均为真实购买结果")
		check(matched.rank == BOTEvaluator.score(matched.state,who,p) and not matched.baseline and matched.generation_stage == 1,
			"后备不抬高排序分、不冒充基础节点或终局")
	var signatures := {}
	var legal := true
	for node in generated.nodes:
		signatures[Cap.signature(node.state)] = true
		var replayed := Env.copy(state)
		legal = legal and node.intents.size() == 1 and Env.replay(replayed,node.intents) and \
			Env.key(replayed) == Env.key(node.state) and BOTActions._payable_plan(node.state,who)
	check(legal,"所有后备只有一个可重放交易，并通过正式行动完成检查")
	check(signatures.size() == generated.nodes.size(),"重复市场卡位与等价交易只保留一个后备状态")
	check(generated.complete and generated.work == 512-int(p._work[0]),"后备完整度与同一总预算实际扣费一致")
	check(StateCodec.state_hash(state) == before,"后备枚举不修改原始局面")

func _test_single_sales_and_limits() -> void:
	var state := _state()
	var who: String = fixture.who
	var p := _profile()
	var generated := BOTActions._rescue_transactions(state,who,p)
	var expected := {}
	for card in state.players[who].cards:
		var d := CardDB.get_def(card.def_id)
		if CardDB.pawn_value(card.def_id) > 0 and not (d.kind == CardDB.KIND_UNIT and d.get("res") == CardDB.RES_CASH):
			expected[card.def_id] = true
	var sold := {}
	for node in generated.nodes:
		var intent: Dictionary = node.intents[0]
		if intent.op != "pawn": continue
		check(intent.uids.size() == 1,"每条典当后备仅出售一个卡种的一张牌")
		var card := state.find_card(who,int(intent.uids[0]))
		sold[card.def_id] = true
		check(node.state.resource_count(who,"cash") == state.resource_count(who,"cash")+CardDB.pawn_value(card.def_id),
			"单张典当真实增加现金缓冲，不自动继续购牌")
	check(sold == expected,"所有可典当非现金卡种均有单张代表，包括用户")
	var market_kinds := {}
	for id in state.market: market_kinds[id] = true
	check(generated.nodes.size() <= market_kinds.size()+expected.size() and generated.work == market_kinds.size()+expected.size(),
		"后备最多为市场卡种数加可典当卡种数，不按购物子集指数展开")
	var limited := _profile()
	limited["_generation_work"] = [1]
	var partial := BOTActions._rescue_transactions(state,who,limited)
	check(not partial.complete and partial.work == 1 and limited._generation_work[0] == 0 and limited._work[0] == 511,
		"局部生成额度和总额度同时扣费，到限不透支且标记未完成")
	var tiny := GameState.new()
	tiny.players = {"bot":{"cards":[]},"player":{"cards":[]}}
	for seat in tiny.players:
		tiny.add_card(seat,"cash")
		tiny.add_card(seat,"user")
	tiny.market = [fixture.expected.denied_card]
	var impossible := BOTActions._rescue_transactions(tiny,"bot",_profile())
	check(impossible.complete and impossible.nodes.is_empty(),"真实规则排除买不起的牌及会把最后用户当掉的交易")

func _test_locked_representative() -> void:
	var state := GameState.new()
	state.players = {"bot":{"cards":[]},"player":{"cards":[]}}
	for seat in state.players:
		for n in 10: state.add_card(seat,"cash")
		for n in 10: state.add_card(seat,"user")
	var core := state.add_card("bot","shuabuting")
	var loose := state.add_card("bot","shuabuting")
	var units: Array = []
	for card in state.players.bot.cards:
		if card.def_id == "user": units.append(card.uid)
	var required := int(CardDB.get_def("shuabuting").recipe_n)
	check(Env.replay(state,[Intent.create_combo("bot",[core.uid]+units.slice(0,required))]),
		"同种已入组与自由卡的对照通过真实编组规则")
	var generated := BOTActions._rescue_transactions(state,"bot",_profile())
	check(generated.nodes.any(func(n):return n.intents[0].op == "pawn" and n.intents[0].uids == [loose.uid]),
		"同种单张典当优先使用自由卡，不无故拆掉已有组合")
	state.remove_card("bot",int(loose.uid))
	var locked := BOTActions._rescue_transactions(state,"bot",_profile())
	check(locked.nodes.any(func(n):return n.intents[0].op == "pawn" and n.intents[0].uids == [core.uid]),
		"只有已入组牌时仍交真实典当规则，不另加不可典当限制")

func _test_generation_contract() -> void:
	var state := _state()
	var who: String = fixture.who
	var p := _profile()
	var result := BOTActions.generate_with_status(state,who,p)
	check(result.baseline_complete and result.rescue_complete and not result.rescue.is_empty(),
		"先完成基础运营与交易，再在同一预算内预留后备交易")
	check(result.rescue.all(func(n):return not result.nodes.has(n) and not result.baseline.has(n)),
		"后备独立返回，不混入普通排名、基础保护或普通截断池")
	var baseline := _profile()
	for key in ["financing_mode","resale_mode","allocation_mode","formation_mode","candidate_dedup","tactical_extension"]:
		baseline[key] = 0
	var basic := BOTActions.generate_with_status(state,who,baseline)
	check(result.baseline.map(func(n):return Cap.signature(n.state)) == basic.nodes.map(func(n):return Cap.signature(n.state)),
		"预留后备发生在基础完成以后，基础方案与次序不变")
	var ordinary_work := 512-int(baseline._work[0])
	var stage_work := 0
	for stage in result.generation_stages: stage_work += int(stage.work)
	check(ordinary_work+int(result.rescue_work)+stage_work == 512-int(p._work[0]),
		"基础、后备和扩展扣费相加等于实际总扣费，无额外预算")
	var default_profile := BOTSearch.from_model("bot",0.5).resolved_parameters()
	default_profile["tactical_extension"] = 0
	default_profile["_work"] = [int(default_profile.node_budget)]
	var default_result := BOTActions.generate_with_status(state,who,default_profile)
	check(default_result.rescue.is_empty() and default_result.rescue_work == 0,
		"明确关闭战术后备，不新增生成工作")
	var interrupted := _profile()
	interrupted["_work"] = [1]
	var incomplete := BOTActions.generate_with_status(state,who,interrupted)
	check(not incomplete.baseline_complete and incomplete.rescue.is_empty() and not incomplete.rescue_complete,
		"基础尚未完成时不挪用预算生成后备，不误报后备完成")

	var winning := _state()
	while winning.resource_count(who,"cash") < int(CardDB.game_rules().win_cash)-1:
		winning.add_card(who,"cash")
	var immediate_profile := _profile()
	var immediate := BOTActions.generate_with_status(winning,who,immediate_profile)
	check(immediate.nodes.size() == 1 and immediate.nodes[0].state.winner == who and immediate.rescue.is_empty() and immediate.rescue_work == 0,
		"已能合法典当冲线时直接获胜，不构造多余后备")
	check(BOTActions._rescue_transactions(immediate.nodes[0].state,who,_profile()).nodes.is_empty(),
		"终局不产生未实际落地的后备意图")
