# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Cap = preload("res://engine/bot_capabilities.gd")
const Env = preload("res://engine/bot_environment.gd")
var fixture: Dictionary

func _initialize() -> void:
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_operating_finance.json"))
	var path := "user://operating_cards.json"
	var f := FileAccess.open(path,FileAccess.WRITE)
	f.store_string(JSON.stringify(fixture.cards))
	f.close()
	CardDB.load_from(path)
	_test_operating_cash()
	_test_cash_production()
	_test_partial_generation()
	_test_purchase_prefixes()
	_test_changed_threat()
	_test_no_trade_survival()
	_test_user_output_value()
	_test_staged_trading()
	finish()

func _state(step: String) -> GameState:
	var s := GameState.new()
	StateCodec.restore(s,fixture.positions[step])
	return s

func _profile() -> Dictionary:
	var p := BOTSearch.from_model("bot",1.0).resolved_parameters()
	p["_context"] = BOTActions.Context.new()
	p["_work"] = [int(p.node_budget)]
	return p

func _cash_buffer(s: GameState) -> bool:
	if s.resource_count("bot","cash") != 4 or s.resource_count("bot","user") != 7: return false
	var inventory := {}
	for c in s.players.bot.cards:
		if CardDB.get_def(c.def_id).kind != CardDB.KIND_UNIT: inventory[c.def_id] = int(inventory.get(c.def_id,0))+1
	return inventory == {"shuabuting":1,"yinqing996":1}

func _production(s: GameState, output: int) -> bool:
	for c in s.combos:
		if c.owner == "bot" and c.eval.get("output_res","") == "cash" and int(c.eval.get("output_n",0)) == output: return true
	return false

func _test_operating_cash() -> void:
	var s := _state("56")
	var before := StateCodec.state_hash(s)
	var holdings := Cap.purchases(s,"bot",_profile())
	check(holdings.any(func(n): return _cash_buffer(n.state) and n.intents.size() == 1),
		"112步录像：仅卖一张倍率牌、保4现金与生产能力的停购融资不被前2名裁掉")
	var p := _profile()
	var generated := BOTActions.generate_with_status(s,"bot",p)
	check(generated.baseline_complete,"112步录像：先完成基础运营候选")
	var baseline_limit := mini(int(p.plans),16)+mini(int(p.build_beam),8)+1
	var expansion_layers := 2 if int(p.financing_mode) > 1 else 1
	check(generated.nodes.size() <= expansion_layers*(int(p.plans)+2*int(p.tactical_extension))+generated.baseline.size() and generated.baseline.size() <= baseline_limit,
		"各层增强宽度与有限基础候选并集有界，不因保留较低层方案无限增加根数")
	check(generated.nodes.any(func(n):return _cash_buffer(n.state) and _production(n.state,16)),
		"112步录像：强度1完整根保留4现金与16现金生产方案")
	check(generated.baseline.any(func(n):return _production(n.state,32) and n.intents.all(func(i):return i.op == "create_combo")),
		"原持牌完整32现金运营方案直接进入基础比较，不只保留空过或交易中间态")
	var included := true
	var legal := true
	for node in generated.baseline:
		included = included and generated.nodes.has(node) and node.get("baseline",false)
	for node in generated.nodes:
		var replayed := Env.copy(s)
		legal = legal and Env.replay(replayed,node.intents) and Env.key(replayed) == Env.key(node.state)
	check(included,"基础候选与扩展根使用同一节点，不在上层合并后被再次裁掉或重复评价")
	check(legal,"全部候选是经真实规则可完整重放的方案")
	check(StateCodec.state_hash(s) == before,"候选生成不改变真实状态")
	check(int(p._work[0]) >= 0,"基础与增强生成共同遵守总预算")

func _test_cash_production() -> void:
	var s := _state("46")
	var p := _profile()
	var generated := BOTActions.generate_with_status(s,"bot",p)
	var candidate: Dictionary = {}
	for node in generated.nodes:
		if _production(node.state,32):
			candidate = node
			break
	check(not candidate.is_empty(),"第三回合先形成刷不停与两张996的完整32现金生产方案")
	if candidate.is_empty(): return
	var produced := Env.copy(candidate.state)
	var cash_before := produced.resource_count("bot","cash")
	Env.settle(produced,BOTPlan.target_picker(BOTSearch.from_model("bot",1.0)))
	check(produced.resource_count("bot","cash") == cash_before+32,"候选通过真实结算兑现32现金")
	var skipped := Env.copy(s)
	check(Env.replay(skipped,fixture.recorded_intents["46"]),"录像原交易后空过路线仍合法可作对照")
	Env.settle(skipped,BOTPlan.target_picker(BOTSearch.from_model("bot",1.0)))
	check(BOTEvaluator.score(produced,"bot",p) > BOTEvaluator.score(skipped,"bot",p),
		"同档统一评分承认真正生产的32现金收益，不能把空过视为同分")

func _test_partial_generation() -> void:
	var s := _state("56")
	var p := _profile()
	p.generation_budget = 200
	var partial := BOTActions.generate_with_status(s,"bot",p)
	check(partial.baseline_complete and not partial.complete,"有限扩展到限与基础运营未完成分别报告")
	check(partial.nodes.any(func(n):return _cash_buffer(n.state) and _production(n.state,16)),
		"增强交易耗尽局部额度时，已完成的保现金生产方案仍可供搜索比较")
	var tiny := _profile()
	tiny["_work"] = [1]
	var interrupted := BOTActions.generate_with_status(s,"bot",tiny)
	check(not interrupted.baseline_complete and not interrupted.complete,"基础阶段总预算中断不会标成完整候选池")
	check(interrupted.nodes.all(func(n):return Env.replay(Env.copy(s),n.intents)),"极小预算的回退仍遵守真实动作合法性")

func _test_purchase_prefixes() -> void:
	var s := GameState.new()
	s.players = {"bot":{"cards":[]},"player":{"cards":[]}}
	for who in s.players:
		for n in 7: s.add_card(who,"cash")
		for n in 4: s.add_card(who,"user")
	var core := s.add_card("bot","yunketang")
	s.market = ["ditui","baoyue","ditui"]
	var users: Array = s.players.bot.cards.filter(func(c):return c.def_id == "user").map(func(c):return c.uid)
	var sources: Array = [{"state":s,"intents":[]}]
	for ids in [users.slice(0,2),[core.uid]]:
		var next := Env.copy(s)
		var intent := Intent.pawn("bot",ids)
		check(Env.replay(next,[intent]),"购买前缀对照使用真实融资来源")
		sources.append({"state":next,"intents":[intent]})
	var reference := {}
	var valid_count := 0
	for source in sources:
		for mask in range(1,8):
			var next := Env.copy(source.state)
			var bought := 0
			var valid := true
			for index in 3:
				if not mask & (1 << index): continue
				if not Env.replay(next,[Intent.buy("bot",index-bought)]):
					valid = false
					break
				bought += 1
			if valid:
				reference[Cap.signature(next)] = true
				valid_count += 1
	var p := _profile()
	p.financing_choices = 64
	var before := int(p._work[0])
	var actual := {}
	for node in Cap._financed_purchases(sources,"bot",p): actual[Cap.signature(node.state)] = true
	check(actual == reference,"共享购买前缀覆盖独立穷举的全部合法子集，重复市场卡位不买错牌")
	check(before-int(p._work[0]) == valid_count,"每个合法购买子集仅展开一次buy，不重复计费执行公共前缀")

func _test_changed_threat() -> void:
	var s := _state("46")
	var p := _profile()
	p["_opponent_features"] = BOTEvaluator.features(s,"player",p)
	check(Env.replay(s,[Intent.pawn("bot",[40])]),"出售已有攻击核心以改变双方威胁关系")
	check(p._opponent_features.total != BOTEvaluator.features(s,"player",p).total,
		"自己出售攻击牌后对方安全估值随之改变")
	check(BOTActions._score(s,"bot",p) == BOTEvaluator.score(s,"bot",p),
		"候选评分不复用自己行动前已经失效的对方特征")

func _test_no_trade_survival() -> void:
	CardDB.load_default()
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_seed101002.json"))
	var s := GameState.new()
	StateCodec.restore(s,data.second_before)
	var before := StateCodec.state_hash(s)
	for strength in [0.0,0.5,1.0]:
		var p := BOTSearch.from_model("bot",strength).resolved_parameters()
		p["_work"] = [int(p.node_budget)]
		var generated := BOTActions.generate_with_status(s,"bot",p)
		check(generated.baseline_complete and generated.baseline.any(func(n):return n.intents.is_empty()),
			"强度%.1f：面对已成6现金攻击，合法空过保留到最终基础池" % strength)
		check(generated.nodes.any(func(n):return n.intents.is_empty()),
			"强度%.1f：停购不再被最终plans静态排名截断" % strength)
	var cfg := BOTSearch.from_model("bot",0.5)
	var chosen := BOTPlan.choose_plan(s,"bot",cfg)
	var leaf := Env.copy(s)
	check(Env.replay(leaf,chosen.intents),"种子101002：实际最终计划通过真实裁决")
	var resolved := BOTTurnPlan.resolve_current(leaf,"bot",cfg.resolved_parameters())
	check(resolved.complete and resolved.state.winner != "player" and resolved.state.resource_count("bot","cash") > 0,
		"种子101002：默认强度真正选择扛住6现金攻击，不能买包月与996后剩2现金必死")
	var skipped := Env.copy(s)
	Env.settle(skipped,BOTPlan.target_picker(cfg))
	check(skipped.winner == "" and skipped.resource_count("bot","cash") == 6,
		"独立规则对照：原12现金空过可在6现金攻击后存活")
	check(StateCodec.state_hash(s) == before,"保留运营、最终选择与真实回应均不修改输入")

func _test_user_output_value() -> void:
	var original_price := CardDB.pawn_user()
	for price in [1,2]:
		CardDB.GAME["pawn_user"] = price
		var s := GameState.new()
		s.players = {"bot":{"cards":[]},"player":{"cards":[]}}
		for who in s.players:
			for n in 8: s.add_card(who,"cash")
			s.add_card(who,"user")
		var core := s.add_card("bot","waimai")
		s.add_card("bot","xinxijianfang")
		var cfg := BOTSearch.from_model("bot",0.5).resolved_parameters()
		var options := BOTActions._core_options(s,"bot",core,{},cfg)
		check(options.size() == 1,"用户产出对照只有一条无Buff外卖配方")
		if options.is_empty(): continue
		var richer := Env.copy(s)
		for n in 6: richer.add_card("bot","user")
		var richer_options := BOTActions._core_options(richer,"bot",richer.find_card("bot",int(core.uid)),{},cfg)
		check(richer_options.size() == 1 and richer_options[0].merit == options[0].merit,
			"典当单价%d：免费增加用户不压低同一产出候选的排序价值" % price)
		var produced := Env.copy(s)
		var original_users: Array = s.players.bot.cards.filter(func(c):return c.def_id == "user").map(func(c):return c.uid)
		check(Env.replay(produced,[Intent.create_combo("bot",options[0].uids)]),"用户产出候选通过真实编组裁决")
		Settle.produce(produced)
		var growth: Array = produced.players.bot.cards.filter(func(c):return c.def_id == "user" and not original_users.has(c.uid)).map(func(c):return c.uid)
		check(growth.size() == 6 and Env.replay(produced,[Intent.pawn("bot",growth)]),
			"外卖真实扣4现金产6用户，新增用户全部能合法典当")
		check(produced.resource_count("bot","cash")-s.resource_count("bot","cash") == options[0].merit,
			"典当单价%d：生产候选净价值等于实际生产后典当的现金净增量" % price)
	CardDB.GAME["pawn_user"] = original_price

func _test_staged_trading() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_financing_endgame.json"))
	var f := FileAccess.open("user://staged_trading_cards.json",FileAccess.WRITE)
	f.store_string(JSON.stringify(data.cards))
	f.close()
	CardDB.load_from("user://staged_trading_cards.json")
	var s := GameState.new()
	StateCodec.restore(s,data.state)
	var before := StateCodec.state_hash(s)
	var p := _profile()
	p.merge({"generation_budget":16000,"buy_beam":20,"build_beam":12,"plans":16},true)
	var result := BOTActions.generate_with_status(s,"bot",p)
	var used := int(p.node_budget)-int(p._work[0])
	check(result.baseline_complete and not result.complete and result.generation_stages[0].complete,
		"较低融资层已完成编组，高层继续受限时明确报告有限覆盖而非假装完整")
	check(used <= int(p.generation_budget) and int(p._work[0]) >= 0,
		"交易与编组逐次共用生成和搜索总额度，没有补发工作次数")
	var ipo: Dictionary = {}
	for node in result.nodes:
		if node.state.combos.any(func(c):return c.owner == "bot" and c.eval.get("output_card","") == "shangshi"):
			ipo = node
			break
	check(not ipo.is_empty(),"16000生成额度也能把已买齐的材料编成上市，而非采购耗尽后只剩基础路线")
	if not ipo.is_empty():
		var produced := Env.copy(s)
		check(Env.replay(produced,ipo.intents) and Env.key(produced) == Env.key(ipo.state),
			"有限交易后保留的上市方案按完整真实意图可重放")
		Settle.produce(produced)
		check(produced.players.bot.cards.any(func(c):return c.def_id == "shangshi"),
			"阶段额度保留的材料组经实际结算产出上市敲钟")
	check(StateCodec.state_hash(s) == before,"阶段额度分配不改真实输入局面")
