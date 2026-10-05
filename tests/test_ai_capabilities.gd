# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Cap = preload("res://engine/ai_capabilities.gd")
const Env = preload("res://engine/ai_environment.gd")
var fixture: Dictionary
func _initialize() -> void:
	_isolate_user_data()
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_financing_endgame.json"))
	var path := "user://fixture_cards.json"
	var f := FileAccess.open(path,FileAccess.WRITE)
	f.store_string(JSON.stringify(fixture["cards"],"",false))
	f.close()
	CardDB.load_from(path)
	for strength in [0.0,0.225,0.5]:
		var p := AISearch.from_model("ai",strength).resolved_parameters()
		for key in ["financing_mode","allocation_mode","formation_mode","candidate_dedup","reply_mode","rollout_capabilities","tactical_extension","resale_mode","attack_mode"]:
			check(p[key] == AISearch.from_strength(1.0).get_knob(key),"强度%s共用%s规格" % [strength,key])
	check(AISearch.from_tier(" AI:ENHANCED ").get_knob("financing_mode")==2,"命名配置忽略大小写和两端空格")
	var cfg := AISearch.from_strength(1.0)
	# 此用例验证完整节点规格；计算额度另由test_ai_work_budget验证。
	cfg.apply_override("compute_budget",10000000)
	cfg.apply_override("search_fraction",1.0)
	var p := cfg.resolved_parameters()
	check(p.financing_mode == 2 and p.reply_mode == 1,"增强是同一实现的参数集合")
	var s := state()
	var before := StateCodec.state_hash(s)
	var old := AITurnPlan.choose_plan(s,"ai",AISearch.from_strength(0.5))
	check(Env.replay(Env.copy(s),old.intents),"默认配置使用共用评分与搜索，方案通过真实规则")
	var result := AITurnPlan.choose_plan(s,"ai",cfg)
	check(StateCodec.state_hash(s) == before,"两种搜索都不改变输入状态")
	check(result.diagnostics.compute_used <= result.diagnostics.compute_limit,"增强搜索遵守总展开额度")
	check(Env.replay(s,result.intents),"增强方案全部通过真实规则")
	var bulk := false
	for it in result.intents:
		bulk = bulk or (it.op == "pawn" and it.uids.size()>1)
	check(bulk,"增强实际决策使用批量融资")
	check(result.diagnostics.selected_evaluation_complete,"增强实际决策具有完整当前回应评价")
	# 留几张市场牌不是胜负判据：攻击也可能阻止对手融资后存活。
	# 使用同档完整回应池真实结算，验证所有已比较的回应均不能抢先兑现。
	var resolved := AITurnPlan.resolve_current(s,"ai",p)
	check(resolved.complete and not resolved.responses.is_empty(),"制胜路线完成真实对手回应比较")
	var same_round_safe := true
	var player_cannot_cashout := true
	var ai_wins := true
	for leaf in resolved.responses:
		same_round_safe = same_round_safe and leaf.winner != "player"
		if leaf.winner != "":
			ai_wins = ai_wins and leaf.winner == "ai"
			continue
		var next := Env.copy(leaf)
		next.end_round()
		next.start_round()
		player_cannot_cashout = player_cannot_cashout and AIActions.winning_pawn(next,"player").is_empty()
		ai_wins = ai_wins and Env.replay(next,AIActions.winning_pawn(next,"ai")) and next.winner == "ai"
	check(same_round_safe,"已比较的真实回应均不能在本回合击败AI")
	check(player_cannot_cashout,"所有回应结算后，玩家下一先手均不能直接典当冲线")
	check(ai_wins,"所有回应结算后，AI当轮获胜或随后合法典当达到现金胜利线")
	_test_timing(p)
	_test_modes(p)
	_test_small_space(p)
	_test_resale(p)
	finish()
func state() -> GameState:
	var s := GameState.new()
	StateCodec.restore(s,fixture.state)
	return s
func _test_timing(p: Dictionary) -> void:
	var s := state()
	s.add_card("player","shangshi",true)
	check(Cap.cashout_winner_after_round(s) == "player","下一先行动方可兑现升级产物")
	check(AITurnPlan.settled_score(s,"ai",p) == -AIEvaluator.TERMINAL_SCORE,"即时兑现金额不能被经济分覆盖")
	check(AITurnPlan.bounded_score(s,"ai",p) == -1.0,"前推末端仍检查下一行动兑现，不能在深度边界漏判")
	s.draw_first = "player"
	check(Cap.cashout_winner_after_round(s) == "","后手能典当不等于已必胜")
	check(s.winner == "","扩展评估不篡改实际winner")
	var legacy := AISearch.from_strength(0.5).resolved_parameters()
	check(absf(AITurnPlan.settled_score(s,"ai",legacy)) < AIEvaluator.TERMINAL_SCORE,"兼容评估保持原静态分")
func _test_modes(p: Dictionary) -> void:
	var same := state()
	var other := Env.copy(same)
	for who in other.players:
		for c in other.players[who].cards: c.uid += 1000
	check(Cap.signature(same) == Cap.signature(other),"等价UID置换被合并")
	other.players.ai.cards[0].locked = true
	check(Cap.signature(same) != Cap.signature(other),"不同锁定状态不会被误合并")
	check(AITurnPlan._fast_profile(p).financing_mode == 2,"增强前推保留融资能力")
	var off := p.duplicate()
	off.rollout_capabilities = 0
	check(AITurnPlan._fast_profile(off).financing_mode == 0,"前推动作能力可独立关闭")
	var tiny := AISearch.from_strength(1.0)
	tiny.apply_override("compute_budget",100)
	tiny.apply_override("search_fraction",1.0)
	var action := AITurnPlan.choose_plan(state(),"ai",tiny)
	check(action.diagnostics.compute_used<=85 and Env.replay(state(),action.intents),"极小预算仍返回合法方案")

func _test_small_space(parameters: Dictionary) -> void:
	var s := GameState.new()
	s.players = {"ai":{"cards":[]},"player":{"cards":[]}}
	for who in ["ai","player"]:
		for i in 5: s.add_card(who,"cash")
		for i in 4: s.add_card(who,"user")
	s.add_card("ai","yunketang")
	s.add_card("ai","pinshaoshao")
	var p := parameters.duplicate()
	p["_context"] = AIActions.Context.new()
	p.financing_beam = 512
	p.financing_choices = 64
	p.buy_beam = 64
	var holdings := Cap.purchases(s,"ai",p)
	var actual := {}
	for h in holdings:
		actual[Cap.signature(h.state)] = true
		check(Env.replay(Env.copy(s),h.intents),"小空间融资方案可真实执行")
	var reference := {}
	var users := []
	var products := []
	for c in s.players.ai.cards:
		if c.def_id == "user": users.append(c.uid)
		elif c.def_id != "cash": products.append(c.uid)
	for count in 4:
		for mask in 4:
			var sold: Array = users.slice(0,count)
			for bit in 2:
				if mask & (1<<bit): sold.append(products[bit])
			var next := Env.copy(s)
			if not sold.is_empty(): next.pawn("ai",sold)
			reference[Cap.signature(next)] = true
	check(actual == reference and actual.size()==16,"小局面联合融资覆盖全部16种数量组合，对照独立穷举")
	var paid := state()
	var roots := AIActions.generate(paid,"ai",AISearch.from_strength(0.5).resolved_parameters())
	var leaf := Env.copy(roots[0].state)
	var old := AISearch.from_strength(0.5).resolved_parameters()
	var enhanced := parameters.duplicate()
	var r0 := AITurnPlan.resolve_current(leaf,"ai",old)
	var r1 := AITurnPlan.resolve_current(leaf,"ai",enhanced)
	check(r0.responses.size()>1 and r1.responses.size()>1,"回应局面保留到后续比较入口")

func _test_resale(parameters: Dictionary) -> void:
	CardDB.CARDS["resale_a"] = {"kind":"product","tier":1,"price":4,"pawn":2,"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":1}
	CardDB.CARDS["resale_b"] = {"kind":"product","tier":1,"price":3,"pawn":1,"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":1}
	var s := GameState.new()
	s.players = {"ai":{"cards":[]},"player":{"cards":[]}}
	for who in s.players:
		for i in 6: s.add_card(who,"cash")
		for i in 2: s.add_card(who,"user")
	s.market = ["resale_a","resale_b"]
	var p := parameters.duplicate()
	var nodes := Cap.resale_transactions([{"state":s,"intents":[]}],"ai",p)
	var found := false
	for node in nodes:
		if node.intents.size()!=3: continue
		if node.intents[0].op=="buy" and node.intents[1].op=="pawn" and node.intents[2].op=="buy":
			found = found or (node.state.market.is_empty() and Env.replay(Env.copy(s),node.intents))
	check(found,"原现金不够买两张，可先买再卖第一张周转购买第二张")
