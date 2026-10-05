# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Env = preload("res://engine/bot_environment.gd")
const Plan = preload("res://engine/bot_turn_plan.gd")
var fixture: Dictionary
func _initialize() -> void:
	CardDB.ensure_loaded()
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_search_quality.json"))
	_test_partial_current()
	_test_attack_consistency()
	_test_turn_boundary()
	_test_current_financing_reply()
	_test_rollout_profile()
	_test_future_response_identity()
	_test_future_ties_keep_current()
	_test_common_layers()
	_test_completed_layer_survives_interrupt()
	_test_incumbent()
	_test_stage_incumbents()
	finish()
func _position() -> GameState:
	var s := GameState.new()
	StateCodec.restore(s,fixture.state)
	return s
func _profile() -> Dictionary:
	var p := BOTSearch.from_model("bot",1.0).resolved_parameters()
	p["_context"] = BOTActions.Context.new()
	p["reply_generation_budget"] = 4096
	p["rollout_step_budget"] = 2048
	p["future_reply_limit"] = 2
	p["_work"] = [200000]
	return p
func _test_partial_current() -> void:
	var leaf := _position()
	check(Env.replay(leaf,[Intent.create_combo("bot",[41,39,52,53,54,55,76,77])]),"录像56双996生产对照经真实规则编成")
	var full := Plan.resolve_current(leaf,"bot",_profile())
	check(full.complete and full.score == -BOTEvaluator.TERMINAL_SCORE,"完整回应识别仅1现金的生产路线会在产出前被做空击败")
	for remaining in [0,313,4000]:
		var p := _profile()
		p["_work"] = [remaining]
		p["_resumable"] = true
		var limited := Plan.resolve_current(leaf,"bot",p)
		check((limited.complete and not limited.coverage_limited and limited.score == full.score) or (not limited.complete and limited.score == null),
			"剩%d节点：完成结果注明覆盖范围，未完成结果不提交评分" % remaining)
		check(int(p._work[0]) >= 0 and int(p._work[0]) <= remaining,
			"剩%d节点按实际生成工作扣费，不再预扣固定回应额度" % remaining)
	for budget in [4000,4500]:
		var cfg := BOTSearch.from_model("bot",1.0)
		cfg.apply_override("compute_budget",budget)
		cfg.apply_override("search_fraction",1.0)
		cfg.apply_override("future_rounds",0)
		var result := Plan.choose_plan(_position(),"bot",cfg)
		var actual := _position()
		check(Env.replay(actual,result.intents),"%d总预算仍返回合法方案" % budget)
		var verified := Plan.resolve_current(actual,"bot",_profile())
		var is_loss: bool = verified.complete and verified.score == -BOTEvaluator.TERMINAL_SCORE
		check(not is_loss or not result.diagnostics.selected_evaluation_complete or result.diagnostics.score == -BOTEvaluator.TERMINAL_SCORE,
			"%d总预算不能把已知必败的末根当已完成安全评价" % budget)
		check(result.diagnostics.compute_used <= budget,"%d总预算计数未越界" % budget)
		var stats: Dictionary=result.diagnostics
		check(stats.generation_nodes>=0 and stats.current_nodes>=0 and stats.future_nodes>=0 and
			stats.generation_nodes+stats.current_nodes+stats.future_nodes==stats.expanded_nodes,
			"%d预算三阶段实际展开分账与总账一致" % budget)
func _small() -> GameState:
	var s := GameState.new()
	s.players={"bot":{"cards":[]},"player":{"cards":[]}}
	s.draw_first="bot"
	for who in s.players:
		for i in 10:s.add_card(who,"cash")
		for i in 11:s.add_card(who,"user")
	return s
func _users(s: GameState, who: String, count: int) -> Array:
	var out := []
	for c in s.players[who].cards:
		if c.def_id=="user" and not c.get("locked",false):out.append(c.uid)
	return out.slice(0,count)
func _attack_state() -> GameState:
	var s := _small()
	var attack := s.add_card("bot","chaping")
	var large := s.add_card("player","shuabuting")
	var small := s.add_card("player","yunketang")
	check(Env.replay(s,[Intent.create_combo("bot",[attack.uid]+_users(s,"bot",int(CardDB.get_def("chaping").recipe_n)))]),"差评攻击夹具合法")
	check(Env.replay(s,[Intent.create_combo("player",[large.uid]+_users(s,"player",8))]),"抗3击的大生产组合法")
	check(Env.replay(s,[Intent.create_combo("player",[small.uid]+_users(s,"player",3))]),"一击可拆的小生产组合法")
	return s
func _real_settle(s: GameState,cfg: BOTSearch) -> void:
	for who in s.action_order():
		if s.winner=="":Settle.attack_phase(s,who,Plan.target_picker(cfg))
	if s.winner=="":Settle.produce(s)
	Settle.finalize(s)
func _test_attack_consistency() -> void:
	var initial := _attack_state()
	for strength in [0.5,1.0]:
		var cfg := BOTSearch.from_model("bot",strength)
		var predicted := Env.copy(initial)
		var actual := Env.copy(initial)
		Env.settle(predicted,Plan._target_policy(cfg.resolved_parameters()))
		_real_settle(actual,cfg)
		check(Env.key(predicted)==Env.key(actual),"强度%s内部攻防预测与实战选靶完全一致" % strength)
		check(actual.resource_count("player","cash")==18,"强度%s能选择拆掉云课堂而非徒打抗拆刷不停" % strength)
	# 第二方也攻击：双方必须各自有预算，不共用先手消耗后的余额。
	var attack_need := int(CardDB.get_def("chaping").recipe_n)
	for i in attack_need:initial.add_card("player","user")
	var second := initial.add_card("player","chaping")
	check(Env.replay(initial,[Intent.create_combo("player",[second.uid]+_users(initial,"player",attack_need))]),"双方攻击夹具合法")
	var own := initial.add_card("bot","yunketang")
	check(Env.replay(initial,[Intent.create_combo("bot",[own.uid]+_users(initial,"bot",3))]),"先手也有可攻击生产组")
	var cfg := BOTSearch.from_model("bot",1.0)
	cfg.apply_override("target_trials",2)
	var predicted := Env.copy(initial)
	var actual := Env.copy(initial)
	Env.settle(predicted,Plan._target_policy(cfg.resolved_parameters()))
	_real_settle(actual,cfg)
	check(Env.key(predicted)==Env.key(actual),"很小选靶预算下双方仍各自独立，与实战两阶段一致")
func _test_turn_boundary() -> void:
	var s := _small()
	var p := _profile()
	p._work=[0]
	var after_second := Plan.resolve_current(s,"player",p)
	check(after_second.complete and after_second.evaluations==1,"后手行动结束不再凭空生成先手额外回应")
	var after_first := Plan.resolve_current(s,"bot",p)
	check(not after_first.complete,"先手确实需要回应，额度不足不能伪装后手已行动")
	s.winner="bot"
	check(Plan.resolve_current(s,"bot",p).score==BOTEvaluator.TERMINAL_SCORE,"真实终局胜利不依赖剩余搜索额度")
	check(Plan.bounded_score(s,"player",p)==-1.0,"未来样本真实失败始终为-1")
	var live := _small()
	check(absf(Plan.bounded_score(live,"bot",_profile()))<1.0,"非终局分不会与真实胜负混为一谈")
func _candidate(s: GameState, baseline := false) -> Dictionary:
	return {"node":{"state":s,"intents":[]},"state":s,"responses":[s],"score":0.0,"baseline":baseline}
func _test_current_financing_reply() -> void:
	var data: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_seed101002.json"))
	var leaf:=GameState.new()
	StateCodec.restore(leaf,data.first_before)
	check(Env.replay(leaf,data.first_unsafe_intents),"101002先手买生产牌后仅剩4现金的历史方案合法")
	var actual:=Env.copy(leaf)
	check(Env.replay(actual,data.actual_reply_intents),"实际强度0的单用户融资与做空热搜回应合法")
	var p:=BOTSearch.from_model("bot",0.5).resolved_parameters()
	p["rollout_capabilities"] = 0 # 明确验证未来能力开关，不依赖强度关闭它。
	p["_context"]=BOTActions.Context.new();p["_work"]=[10000]
	p["_compute"]=Plan.Work.new(2000000)
	Env.settle(actual,Plan._target_policy(p))
	check(actual.winner=="bot","实际融资回应在首回合清空先手现金")
	var resolved:=Plan.resolve_current(leaf,"player",p)
	check(p.rollout_capabilities==0 and Plan._fast_profile(p).sales==0,"夹具关闭未来扩展，未来局部规格仍可限制典当")
	check(resolved.complete and resolved.score==-BOTEvaluator.TERMINAL_SCORE,
		"当前回应不受未来扩展开关影响，明确识别同一个融资击杀")
	var found:=false
	for response in resolved.responses:
		if Env.key(response)==Env.key(actual):found=true
	check(found,"当前已评价回应包含实际强度0逐UID相同的击杀结果")
	check(int(p._work[0])>=0 and p._compute.used>0 and p._compute.used<=p._compute.limit,
		"补齐当前典当能力仍遵守实际计算与节点硬上限")
func _test_rollout_profile() -> void:
	var p := _profile()
	p.merge({"rollout_plans":1,"replies":8},true)
	var fast := Plan._fast_profile(p)
	check(fast.plans==1 and fast.replies==1,"未来自己的方案与对方回应共用局部方案宽度")
	var repeated := Plan._fast_profile(fast)
	check(repeated.replies==fast.replies and repeated.plans==fast.plans,
		"嵌套未来回应不会重新放大局部宽度")
	check(p.replies==8 and p.plans!=fast.plans,"创建未来局部规格不修改当前回合参数")
	# 启动提示不再是硬门槛：实际总账能完成就完成，不够则不能提交分数。
	for spec in [p,fast]:
		spec["_work"]=[200000]
		spec["_resumable"]=true
		spec["_compute"]=Plan.Work.new(0)
		var stopped := Plan.resolve_current(_small(),"bot",spec)
		check(not stopped.complete and stopped.score==null and spec._compute.used==0,
			"当前与未来回应均不得绕过零计算额度")
		var meter = Plan.Work.new(2000000)
		spec["_compute"]=meter.scope(1000000,"test_reply")
		var reply := Plan.resolve_current(_small(),"bot",spec)
		check(reply.complete and not reply.coverage_limited,"足量实际总账完成规定宽度的回应")
		check(meter.used==spec._compute.used and meter.used>0 and spec._compute.used<=spec._compute.limit,
			"当前与未来回应共享父账，实际工作只扣一次且不越界")
	check(fast.replies < p.replies,"未来回应保持配置推导的较小覆盖宽度")
func _test_future_response_identity() -> void:
	var s := _small()
	s.set_seed(4321)
	var same := Env.copy(s)
	var different := Env.copy(s)
	different.add_card("bot","cash")
	var candidate := _candidate(s)
	var p := _profile()
	candidate.responses=[s,same,different]
	var responses := Plan._future_responses(candidate,p)
	check(responses.size()==2 and responses[0]==s and responses[1]==different,"精确去重后分配独立回应名额，重复项不吞掉较后回应")
	var changed_rng := Env.copy(s)
	changed_rng.next_float()
	candidate.responses=[s,changed_rng]
	check(Env.key(s)==Env.key(changed_rng) and Plan._future_responses(candidate,p).size()==2,
		"牌面相同但随机流位置不同的回应不得合并")
	var changed_market := Env.copy(s)
	changed_market.market=["zuokong"]
	candidate.responses=[s,changed_market]
	check(Plan._future_responses(candidate,p).size()==2,"不同市场的回应不得合并")
	var changed_uid := Env.copy(s)
	changed_uid.set_uid(s.peek_uid()+1)
	candidate.responses=[s,changed_uid]
	check(Plan._future_responses(candidate,p).size()==2,"新牌编号状态不同的回应不得合并")
	var changed_card := Env.copy(s)
	changed_card.players.bot.cards[0]["fired_round"]=s.round_num
	candidate.responses=[s,changed_card]
	check(Plan._future_responses(candidate,p).size()==2,"运行时卡牌标记不同的回应不得合并")
	var won := Env.copy(s);won.winner="bot"
	var lost := Env.copy(s);lost.winner="player"
	var winner := _candidate(won)
	winner.responses=[won,Env.copy(won)]
	var loser := _candidate(lost)
	loser.responses=[lost,Env.copy(lost)]
	p.future_rounds=1;p.samples=1
	var result := Plan._deepen(s,"bot",[winner,loser],p)
	check(result.response_counts==[1,1] and result.evaluations==2,"前推诊断记录实际独立回应数，不把重复状态当额外覆盖")
	check(result.best==winner and result.trace[0].values==[1.0,-1.0],"完全重复回应合并后共同层最坏值与胜负选择不变")
func _test_common_layers() -> void:
	var won := _small();won.winner="bot"
	var lost := _small();lost.winner="player"
	var p := _profile();p.future_rounds=2;p.samples=3
	var first := _candidate(lost,true)
	var second := _candidate(won)
	var result := Plan._deepen(_small(),"bot",[first,second],p)
	check(result.complete_layers==6 and result.depth==2 and result.samples==3,"诊断只记录实际完成的共同深度/样本层")
	check(result.best==second,"每层所有候选都完成后才采用较优未来方案")
	for layer in result.trace:
		check(layer.candidates==2 and layer.values[1]==1.0 and layer.value_kinds[1]=="exact"
			and ((layer.value_kinds[0]=="exact" and layer.values[0]==-1.0) or (layer.value_kinds[0]=="upper_bound" and layer.values[0]==null and layer.upper_bounds[0]>=-1.0 and layer.upper_bounds[0]<1.0)),"终局冠军保持精确共同标度，败者只提交精确分或严格不利上界")
	p=_profile();p._work=[0];p.future_rounds=2;p.samples=3
	var interrupted := Plan._deepen(_small(),"bot",[_candidate(won),_candidate(_small())],p)
	check(interrupted.incomplete and interrupted.complete_layers==0 and not interrupted.has("best"),"只完成首候选不能覆盖此前完整决策")
func _test_future_ties_keep_current() -> void:
	var initial:=GameState.new();initial.set_seed(1)
	initial.players={"bot":{"cards":[]},"player":{"cards":[]}}
	initial.draw_first="player"
	for i in 12:initial.add_card("bot","cash")
	for i in 3:initial.add_card("bot","user")
	initial.add_card("player","cash")
	for i in 6:initial.add_card("player","user")
	var attack:=initial.add_card("player","zuokong")
	var buff:=initial.add_card("player","resou")
	initial.add_card("player","resou")
	initial.market=["yunketang","yinqing996"]
	check(Env.replay(initial,[Intent.create_combo("player",[attack.uid,buff.uid]+_users(initial,"player",6))]),
		"前推平分夹具的当前攻击只编入一张热搜")
	var safe:=Env.copy(initial)
	var safe_intents:=[Intent.buy("bot",0)]
	check(Env.replay(safe,safe_intents),"保现金方案合法购入云课堂")
	var core: Dictionary=safe.players.bot.cards[-1]
	var combo:=Intent.create_combo("bot",[core.uid]+_users(safe,"bot",3))
	safe_intents.append(combo)
	check(Env.replay(safe,[combo]),"保现金方案合法编成生产组合")
	var bad:=Env.copy(initial)
	var bad_intents:=[Intent.buy("bot",0),Intent.buy("bot",0)]
	check(Env.replay(bad,bad_intents),"多买996且停编的危险对照也能合法执行")
	var p:=_profile()
	p.rollout_capabilities=0;p.future_rounds=1;p.samples=1;p.future_reply_limit=1
	var live:=Env.copy(safe);Env.settle(live,Plan._target_policy(p))
	var lost:=Env.copy(bad);Env.settle(lost,Plan._target_policy(p))
	check(live.winner=="" and live.resource_count("bot","cash")==6 and lost.winner=="player",
		"真实当前结算区分仍有6现金与已经归零失败")
	var a:={"node":{"state":safe,"intents":safe_intents},"state":live,"responses":[live],"score":Plan.settled_score(live,"bot",p)}
	var b:={"node":{"state":bad,"intents":bad_intents},"state":lost,"responses":[lost],"score":Plan.settled_score(lost,"bot",p)}
	check(BOTActions.Capabilities.compare_nodes({"node":b.node,"value":-1.0},{"node":a.node,"value":-1.0},"bot","value",p),
		"仅按复杂度破未来平手确实会偏向立即失败的停编方案")
	var result:=Plan._deepen(initial,"bot",[a,b],p)
	check(result.complete_layers==1 and result.trace[0].values==[-1.0,-1.0],
		"真实轻量前推把仍存活方案也预测为下一回合失败")
	check(result.best==a,"未来严格同分先保留更好的完整当前结论，不退回已验证立即失败")
func _test_completed_layer_survives_interrupt() -> void:
	var a := _candidate(_small(),true)
	var other := _small()
	other.add_card("bot","cash")
	var b := _candidate(other)
	var p := BOTSearch.from_model("bot",0.5).resolved_parameters()
	p.merge({"buy_beam":1,"build_beam":1,"plans":1,"replies":1,"rollout_buy_beam":1,"rollout_build_beam":1,"rollout_plans":1,
		"sales":0,"reply_generation_budget":256,"rollout_step_budget":128,"future_reply_limit":1,"future_rounds":1,"samples":1},true)
	p["_context"]=BOTActions.Context.new()
	p["_work"]=[100000]
	var first := Plan._deepen(_small(),"bot",[a,b],p)
	var used := 100000-int(p._work[0])
	check(first.complete_layers==1 and used>0,"真实非终局共同前推能完成一层并统计展开工作")
	p["_work"]=[used+256]
	p.future_rounds=3;p.samples=3
	var partial := Plan._deepen(_small(),"bot",[a,b],p)
	check(partial.incomplete and partial.complete_layers>=1,"更深的真实前推被预算打断时已存在完整共同层")
	if not partial.trace.is_empty():
		var last: Dictionary=partial.trace[-1]
		check(partial.best==[a,b][last.winner] and partial.depth==last.depth and partial.samples==last.samples,
			"中断层不能覆盖最后完整层的选择、样本数和深度")

func _test_incumbent() -> void:
	var ranked := []
	for i in 6:
		var s := _small()
		var node := _candidate(s,i==5)
		node.score=6-i
		ranked.append(node)
	var finalists := Plan._finalists(ranked,4)
	check(finalists.size()==4 and finalists[0]==ranked[0] and finalists.has(ranked[5]),"固定深化名额内同时保留当前冠军与基础最佳运营方案")

func _stage_candidates(stages: Array) -> Array:
	var ranked: Array = []
	for i in stages.size():
		var candidate := _candidate(_small(),int(stages[i])==0)
		candidate["node"]["generation_stage"] = int(stages[i])
		candidate["score"] = float(stages.size()-i)
		ranked.append(candidate)
	return ranked

func _test_stage_incumbents() -> void:
	var ranked := _stage_candidates([2,2,2,2,1,0,1])
	var selected := Plan._finalists(ranked,4)
	check(selected==[ranked[0],ranked[1],ranked[4],ranked[5]],
		"新增多个高分mode2根后，固定四名额仍保留已完成当前评价的mode1累计最佳与基础最佳")
	check(Plan._finalists(ranked,1)==[ranked[0]],"只有一个名额时优先全局当前最佳")
	check(Plan._finalists(ranked,2)==[ranked[0],ranked[5]],"只有两个名额时优先全局与基础最佳")
	check(Plan._finalists(ranked,3)==[ranked[0],ranked[4],ranked[5]],"第三个名额用于中间累计层最佳")
	check(Plan._finalists(ranked,20)==ranked,"名额充足时保持全部当前评分顺序，不重复追加保护代表")
	check(Plan._finalists([],4).is_empty() and Plan._finalists(ranked,0).is_empty(),"空候选与零名额不制造额外入围节点")
	var nested := _stage_candidates([2,0,1,2,1])
	check(Plan._finalists(nested,4)==nested.slice(0,4),"基础已是mode1累计最佳时共用同一代表，不硬保较差的mode1专属节点")
	var single := _stage_candidates([1,1,1,1,0,1])
	check(Plan._finalists(single,4)==[single[0],single[1],single[2],single[4]],"单层扩展保持旧版基础最佳替换末位的结果和顺序")
	for candidate in single: candidate["node"].erase("generation_stage")
	check(Plan._finalists(single,4)==[single[0],single[1],single[2],single[4]],"缺少阶段元数据的旧节点仍按基础标记兼容")
	var basic := _stage_candidates([0,0,0,0,0])
	check(Plan._finalists(basic,3)==basic.slice(0,3),"仅基础层时不改变原有高分入围顺序")
	var gaps := _stage_candidates([4,4,2,0])
	check(Plan._finalists(gaps,3)==[gaps[0],gaps[2],gaps[3]],"保护按通用阶段序号工作，不硬编码融资模式或强度")
	var p := BOTSearch.from_model("bot",0.5).resolved_parameters()
	p.merge({"buy_beam":1,"build_beam":1,"plans":1,"replies":1,"rollout_buy_beam":1,"rollout_build_beam":1,"rollout_plans":1,
		"sales":0,"reply_generation_budget":256,"rollout_step_budget":128,"future_reply_limit":1,"future_rounds":1,"samples":1},true)
	p["_context"]=BOTActions.Context.new();p["_work"]=[100000]
	var one := Plan._deepen(_small(),"bot",[selected[0]],p)
	var one_used := 100000-int(p["_work"][0])
	p["_work"]=[100000]
	var shared := Plan._deepen(_small(),"bot",selected,p)
	check(one.complete_layers==1 and shared.complete_layers==1 and shared.evaluations==selected.size(),
		"阶段保护仍只在固定四名额内完成同一未来层，不额外深化保护节点")
	check(one_used>0 and 100000-int(p["_work"][0])==one_used*selected.size(),
		"同局面四候选仍逐个扣除相同真实前推工作，阶段保护不增加或回补共享额度")
