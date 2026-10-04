# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Plan = preload("res://engine/ai_turn_plan.gd")
const Env = preload("res://engine/ai_environment.gd")
const Cap = preload("res://engine/ai_capabilities.gd")
var fixture: Dictionary

func _initialize() -> void:
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_market_denial.json"))
	var file := FileAccess.open("user://rescue_search_cards.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(fixture.cards));file.close()
	CardDB.load_from("user://rescue_search_cards.json")
	_test_shared_evaluation()
	_test_opponent_rescue()
	_test_scope_and_interrupt()
	_test_real_market_denial()
	finish()

func _profile() -> Dictionary:
	var p: Dictionary = fixture.parameters.duplicate(true)
	p["_context"] = AIActions.Context.new()
	p["_work"] = [int(p.node_budget)]
	return p

func _position() -> GameState:
	var state := GameState.new()
	StateCodec.restore(state,fixture.state)
	return state

func _small() -> GameState:
	var s := GameState.new()
	s.players = {"ai":{"cards":[]},"player":{"cards":[]}}
	s.draw_first = "ai"
	for i in 10: s.add_card("ai","cash")
	var ammo: Array = []
	for i in 6: ammo.append(s.add_card("ai","user").uid)
	ammo.push_front(s.add_card("ai","zuokong").uid)
	for i in 2: s.add_card("player","cash")
	s.add_card("player","user")
	s.add_card("player","yunketang")
	check(Env.replay(s,[Intent.create_combo("ai",ammo)]),"现金缓冲夹具使用真实做空配方")
	return s

func _small_profile() -> Dictionary:
	var p := _profile()
	p.merge({"sales":0,"financing_mode":0,"resale_mode":0,"allocation_mode":0,
		"formation_mode":0,"candidate_dedup":0,"future_rounds":0,"reply_generation_budget":512,"replies":4},true)
	return p

func _pawn_node(s: GameState) -> Dictionary:
	var core: Dictionary = s.players.player.cards.filter(func(c):return c.def_id == "yunketang")[0]
	var node := {"state":Env.copy(s),"intents":[Intent.pawn("player",[core.uid])]}
	check(Env.replay(node.state,node.intents),"单卖云课堂经真实规则保留一现金一用户")
	return node

func _test_shared_evaluation() -> void:
	var s := _small()
	var ordinary := {"state":s,"intents":[]}
	var rescue := _pawn_node(s)
	for score_only in [false,true]:
		var p := _small_profile()
		var start := int(p._work[0])
		var evaluated := Plan._evaluate_candidates([ordinary],[ordinary,rescue,rescue],"player",p,score_only)
		check(evaluated.ranked.size() == 2 and evaluated.ranked[0].score == -AIEvaluator.TERMINAL_SCORE
			and absf(evaluated.ranked[1].score) < AIEvaluator.TERMINAL_SCORE,
			"根/未来共享评价在完整普通全败之后保留真实存活补救（score_only=%s）" % score_only)
		check(evaluated.candidates == 2 and evaluated.attempted == 2 and evaluated.evaluations == 2
			and evaluated.rescue_candidates == 1 and evaluated.rescue_evaluated == 1,
			"普通和后备重复状态只评价一次，激活、尝试与完成数准确")
		check(evaluated.incomplete == 0 and evaluated.unvisited == 0 and p._work[0] == start,
			"后手真实结算不再生成对手行动，补救构造没有重复扣费")
	var p := _small_profile()
	var direct := Plan.resolve_current(rescue.state,"player",p)
	var unchanged := Plan._evaluate_candidates([rescue],[ordinary],"player",p)
	check(unchanged.rescue_candidates == 0 and unchanged.rescue_evaluated == 0 and unchanged.evaluations == direct.evaluations
		and unchanged.ranked[0].score == direct.score,"普通池存在非败完整路线时不评后备、不改变普通比较结果")
	check(Plan._rescue_after_losses([ordinary,rescue],[rescue],[{"score":-AIEvaluator.TERMINAL_SCORE}],-AIEvaluator.TERMINAL_SCORE).is_empty(),
		"未完成或未访问的普通候选不能被省略后宣称全败")
	check(Plan._rescue_after_losses([ordinary],[rescue],[{"score":-AIEvaluator.TERMINAL_SCORE+0.1}],-AIEvaluator.TERMINAL_SCORE).is_empty(),
		"只有严格败局终值触发，不将接近下界的低分当作必败")

func _test_opponent_rescue() -> void:
	var s := _small()
	var rescue := _pawn_node(s)
	var actual := Env.copy(rescue.state)
	Env.settle(actual,Plan._target_policy(_small_profile()))
	check(actual.winner == "" and actual.resource_count("player","cash") == 1 and actual.resource_count("player","user") == 1,
		"实际对手卖生产核心后能承受三点现金攻击")
	var disabled := _small_profile()
	disabled.tactical_extension = 0
	var old := Plan.resolve_current(s,"ai",disabled)
	check(old.complete and old.score == AIEvaluator.TERMINAL_SCORE,"关闭补查的常规有限回应池全部败给现金攻击")
	var full_score := 0.0
	for score_only in [false,true]:
		var p := _small_profile()
		var before := int(p._work[0])
		var result := Plan.resolve_current(s,"ai",p,score_only)
		check(result.complete and absf(result.score) < AIEvaluator.TERMINAL_SCORE and result.state.winner == "",
			"先手预测同样给予对手补救，不把实际可存活的后手判必败")
		check(result.rescue_candidates > 0 and result.rescue_evaluated > 0 and result.rescue_complete,
			"对手普通全败后才激活已生成的补救池，并提供完成性诊断")
		check(result.responses.any(func(next):return Env.key(next) == Env.key(actual)),"预测回应包含真实单张典当存活局面")
		check(before-int(p._work[0]) <= int(p.reply_generation_budget),"对手补救生成仍共用该根规定回应额度")
		if score_only: check(result.score == full_score,"只读分数短路与完整对手回应的最坏分一致")
		else: full_score = result.score
	var safe := Env.copy(s)
	for i in 4: safe.add_card("player","cash")
	var safe_result := Plan.resolve_current(safe,"ai",_small_profile())
	check(safe_result.complete and safe_result.rescue_candidates == 0 and safe_result.rescue_evaluated == 0,
		"对手常规回应能够存活时也不额外结算其补救池")

func _test_scope_and_interrupt() -> void:
	var s := _position()
	var p := _profile()
	var fast := Plan._fast_profile(p)
	var cap := int(fast.rollout_step_budget)
	var direct_p := fast.duplicate()
	direct_p["_work"] = [cap]
	direct_p["generation_budget"] = cap
	var direct := AIActions.generate_with_status(s,fixture.who,direct_p)
	var before := int(p._work[0])
	var scoped := Plan._generate_scope(s,fixture.who,fast,cap)
	check(scoped.complete and scoped.rescue.map(func(n):return Cap.signature(n.state)) == direct.rescue.map(func(n):return Cap.signature(n.state)),
		"未来局部生成返回同规格后备，不另造或遗漏交易")
	check(before-int(p._work[0]) == cap-int(direct_p._work[0]),"局部后备工作与普通工作只扣一次共享总账")
	var base := _profile()
	base.merge({"buy_beam":3,"build_beam":2,"plans":2,"generation_budget":512},true)
	for key in ["financing_mode","resale_mode","allocation_mode","formation_mode","candidate_dedup","tactical_extension"]: base[key] = 0
	var initial := int(base._work[0])
	AIActions.generate_with_status(s,fixture.who,base)
	var basic_work := initial-int(base._work[0])
	var partial_p := _profile()
	partial_p.merge({"buy_beam":3,"build_beam":2,"plans":2},true)
	var partial := Plan._generate_scope(s,fixture.who,partial_p,basic_work+1)
	check(partial.complete and not partial.rescue_complete and partial.coverage_limited,
		"基础完成但后备生成截断时仍可有限比较，并明确标记覆盖有限")
	var denied := Env.copy(s)
	check(Env.replay(denied,fixture.rescue_intents),"预算中断对照的阻断交易合法")
	var limited := _profile()
	limited._work = [0]
	var unresolved := Plan._evaluate_candidates([{"state":s,"intents":[]}],[{"state":denied,"intents":fixture.rescue_intents}],fixture.who,limited)
	check(unresolved.ranked.is_empty() and unresolved.incomplete == 1 and unresolved.rescue_candidates == 0,
		"普通评价额度不足不冒称全败、不跳过普通池试算后备")
	check(unresolved.candidates == unresolved.attempted+unresolved.unvisited and limited._work[0] == 0,
		"中断的根计数和实际预算无透支")
	var once := _profile()
	once._work = [int(once.reply_generation_budget)]
	var interrupted := Plan._evaluate_candidates([{"state":s,"intents":[]}],[{"state":denied,"intents":fixture.rescue_intents}],fixture.who,once)
	check(interrupted.ranked.size() == 1 and interrupted.ranked[0].score == -AIEvaluator.TERMINAL_SCORE
		and interrupted.rescue_candidates == 1 and interrupted.rescue_evaluated == 0 and interrupted.incomplete == 1,
		"普通全败已验证但余量不够补救回应规格时，不把未完成的补救当安全方案")
	check(interrupted.attempted == 2 and interrupted.unvisited == 0 and once._work[0] >= 0,
		"激活后补救中断仍准确记录尝试与完成，且不借用新额度")
	var rollout := Plan._rollout(Env.copy(s),1,limited)
	check(not rollout.complete and limited._work[0] == 0,"未来行动无法完成同一有限比较时不提交完整层")

func _test_real_market_denial() -> void:
	var cfg := AISearch.from_model("ai",1.0)
	# 此用例验证完整节点规格；墙钟截止另由test_ai_time_budget验证。
	cfg.apply_override("think_time_ms",300000)
	for key in fixture.parameters: cfg.apply_override(key,fixture.parameters[key])
	cfg.apply_override("future_rounds",0)
	var s := _position()
	var before := StateCodec.state_hash(s)
	var result := Plan.choose_plan(s,fixture.who,cfg)
	var d: Dictionary = result.diagnostics
	check(d.selected_evaluation_complete and d.score > -AIEvaluator.TERMINAL_SCORE and d.rescue_evaluated > 0,
		"211001第三回合完整当前搜索能从普通全败池找到市场阻断存活路线")
	check(d.rescue_available >= d.rescue_candidates and d.rescue_candidates >= d.rescue_evaluated and d.rescue_work > 0,
		"后备可用、激活、完成和生成工作分开记录")
	check(d.root_candidates == d.current_attempted+d.current_unvisited and
		d.current_attempted == d.current_complete+d.current_incomplete and d.current_complete == d.evaluated_roots,
		"完整choose普通加补救的候选总数、尝试、完成和未访问相符")
	check(d.generation_nodes+d.current_nodes+d.future_nodes == d.expanded_nodes and d.expanded_nodes <= d.profile.node_budget
		and d.future_nodes == 0,"实际三阶段费用与总预算一致，关闭未来无隐藏前推")
	var chosen := Env.copy(s)
	check(Env.replay(chosen,result.intents),"补救最终意图可在原局面逐条真实执行")
	var verified := Plan.resolve_current(chosen,fixture.who,_profile())
	check(verified.complete and verified.score == d.score and verified.responses.all(func(next):return next.winner != GameState.opponent(fixture.who)),
		"选中方案经相同完整回应重新结算仍存活，报告分数与实际规则一致")
	check(StateCodec.state_hash(s) == before,"完整补查不修改输入原局面")
	print("RESCUE_CHOOSE ",JSON.stringify({"intents":result.intents,"diagnostics":d}))
