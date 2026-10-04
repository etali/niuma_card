extends "res://tests/harness.gd"
const Plan=preload("res://engine/ai_turn_plan.gd")
const Env=preload("res://engine/ai_environment.gd")

func _initialize()->void:
	CardDB.load_default()
	_test_bounds_and_order()
	_test_tie_semantics()
	_test_cache_continuation()
	_test_real_layers()
	_test_exact_responses()
	_test_finalist_routes()
	_test_sample_bounds()
	finish()

func _small()->GameState:
	var s:=GameState.new();s.players={"ai":{"cards":[]},"player":{"cards":[]}}
	s.draw_first="ai";s.set_seed(2468)
	for who in s.players:
		s.add_card(who,"cash");s.add_card(who,"user")
	return s

func _candidate(s:GameState,score:float=0.0)->Dictionary:
	return {"node":{"state":s,"intents":[]},"state":s,"responses":[s],"score":score}

func _profile()->Dictionary:
	var p:=Plan.profile(0.5)
	p.merge({"buy_beam":1,"build_beam":1,"plans":1,"replies":1,"rollout_buy_beam":1,"rollout_build_beam":1,"rollout_plans":1,
		"sales":0,"candidate_dedup":0,"reply_mode":1,"reply_generation_budget":128,"rollout_step_budget":128,
		"future_reply_limit":128,"future_rounds":2,"samples":3},true)
	p["_context"]=Plan.Context.new();p["_work"]=[100000]
	return p

func _matrix(contenders:Array,rows:Array,preferred:int=-1,p:Dictionary={})->Dictionary:
	return Plan._future_layer(contenders,rows.map(func(row):return row.size()),"ai",_profile() if p.is_empty() else p,
		func(ci:int,ri:int)->Dictionary:return {"complete":true,"value":rows[ci][ri],"evaluations":1},preferred)

func _test_bounds_and_order()->void:
	var s:=_small();var contenders:=[_candidate(s,3),_candidate(s,2),_candidate(s,1)]
	var clipped:=_matrix(contenders,[[0.2,0.4],[-0.5,-0.9],[0.3,0.1]])
	check(clipped.complete and clipped.winner==0 and clipped.values==[0.2,null,0.1],"未来剪枝只提交精确冠军，不冒充已算出败者最坏值")
	check(clipped.upper_bounds==[0.2,-0.5,0.1] and clipped.value_kinds==["exact","upper_bound","exact"],"未完成候选保留上界与精确值的区别")
	check(clipped.evaluated_responses==[2,1,2] and clipped.skipped_responses==1 and clipped.evaluations==5,"剪枝工作统计对应实际计算与跳过回应")
	var terminal:=_matrix(contenders.slice(0,2),[[-1.0,0.6,0.9],[-1.0,-0.2,0.4,0.5]])
	check(terminal.values==[-1.0,-1.0] and terminal.value_kinds==["exact","exact"] and terminal.winner==0,"达到全局下界-1便得到精确最坏值，终局平分仍用当前分")
	check(terminal.evaluated_responses==[1,1] and terminal.skipped_responses==5 and terminal.lower_bound_exits==2,"-1下界退出不必继续结算不可能更坏的回应")
	var interrupted:=Plan._future_layer(contenders,[1,1,1],"ai",_profile(),
		func(ci:int,_ri:int)->Dictionary:return {"complete":ci==0,"value":0.1,"evaluations":1})
	check(not interrupted.complete and interrupted.value_kinds==["exact","incomplete","incomplete"],"局部失败不跳过其他候选，也不能伪装上界证据或共同层完成")
	# 少量独立完整矩阵：直接穷举每行最小值，覆盖冠军更换、负值、平分和下界。
	var matrices:=[[[0.2,0.4],[-0.5,-0.9],[0.3,0.1]],[[0.1,0.9],[0.8,0.9],[0.7,0.8]],
		[[-0.6,-0.2],[-0.4,-0.9],[-0.3,-0.1]],[[-1.0,0.9],[-1.0,-0.2],[-1.0,0.4]],
		[[0.2,0.7],[0.2,0.6],[0.2,0.5]]]
	for mi in matrices.size():
		var exact:Array=matrices[mi].map(func(row):return row.min())
		var winner:=exact.find(exact.max()) # contenders 当前分严格递减，未来同分原首项胜。
		for preferred in contenders.size():
			var got:=_matrix(contenders,matrices[mi],preferred)
			check(got.complete and got.winner==winner and got.values[winner]==exact[winner] and got.evaluation_order[0]==preferred,
				"矩阵%d优先%d：精确赢家/分数不依赖遍历顺序"%[mi,preferred])
	var earlier:=_matrix(contenders.slice(0,2),[[0.2,0.4],[-0.4,0.8]])
	var later:=_matrix(contenders.slice(0,2),[[0.2,0.4],[0.3,0.8]],earlier.winner)
	check(earlier.value_kinds[1]=="upper_bound" and later.value_kinds[1]=="exact" and later.winner==1,"每层重新竞争，旧层被剪候选可在新样本/深度恢复获胜")
	var rows:=[[0.1,0.2,0.3],[0.8,0.9,0.9],[0.3,0.4,0.5]]
	var ordinary:=_matrix(contenders,rows);var preferred:=_matrix(contenders,rows,1)
	check(ordinary.winner==preferred.winner and ordinary.values[1]==preferred.values[1] and preferred.evaluations<ordinary.evaluations,"先算上层冠军减少实际回应计算，保持精确冠军")
	var invalid:=_matrix(contenders,rows,99)
	check(invalid.evaluation_order==[0,1,2] and invalid.winner==ordinary.winner,"无效优先序号沿用原遍历，不漏候选")

func _formed(users:int,core_index:int=0)->Dictionary:
	var s:=GameState.new();s.players={"ai":{"cards":[]},"player":{"cards":[]}}
	s.add_card("ai","cash")
	var ids:=[]
	for _i in 8:ids.append(s.add_card("ai","user")["uid"])
	var cores:=[s.add_card("ai","baoyue")["uid"],s.add_card("ai","baoyue")["uid"]]
	var intents:=[Intent.create_combo("ai",[cores[core_index]]+ids.slice(0,users))]
	var applied:=Env.replay(s,intents)
	assert(applied)
	var out:=_candidate(s);out.node.intents=intents
	return out

func _test_tie_semantics()->void:
	var tied:=[_candidate(_small()),_candidate(_small()),_candidate(_small())]
	var same:=[[0.2,0.4],[0.2,0.4],[0.2,0.4]]
	var p:=_profile();p.formation_mode=0
	var equal:=_matrix(tied,same,2,p)
	check(equal.winner==0 and equal.skipped_responses==0,"严格未来平分不剪枝，比较器双方均不优先时原ci小者胜")
	tied[1].score=1.0
	check(_matrix(tied,same,2,p).winner==1,"未来同分按当前分优先，不把上层冠军当默认平分赢家")
	p.formation_mode=1
	var heavy:=_formed(8);var lean:=_formed(4)
	check(_matrix([heavy,lean],same.slice(0,2),0,p).winner==1,"未来及当前同分仍用真实编组简洁度破平局")
	var later_core:=_formed(4,1);var first_core:=_formed(4,0)
	var lexical_first := 0 if StateCodec.canon(later_core.node.intents) < StateCodec.canon(first_core.node.intents) else 1
	check(_matrix([later_core,first_core],same.slice(0,2),1-lexical_first,p).winner==lexical_first,"简洁度也相同时沿用原动作key顺序，不受preferred影响")

func _test_cache_continuation()->void:
	var s:=_small();var before:=StateCodec.canon([Env.key(s),s.rng_snapshot()]);var seed_base:=1007922
	var pending:={};var full:=Plan._future_continuation(s,0,2,1,2,seed_base,{},pending,_profile())
	var reference:=Env.copy(s);reference.set_seed(seed_base+104729)
	var reference_done:=Plan._rollout(reference,2,_profile())
	check(full.complete and full.evaluations==2 and full.state.round_num==s.round_num+2,"缓存缺depth1时真正补推两回合，不误报深度")
	check(reference_done.complete and Env.key(reference)==Env.key(full.state) and reference.rng_snapshot()==full.state.rng_snapshot(),"缓存缺层补推与同种子直接完整推进逐状态一致")
	check(pending[str([0,2,1,1])].round_num==s.round_num+1 and pending[str([0,2,1,2])].round_num==s.round_num+2,"较深续推不原地污染较浅缓存")
	check(StateCodec.canon([Env.key(s),s.rng_snapshot()])==before,"补推不修改原回应或其随机状态")
	var cache:=pending.duplicate();var deeper:={}
	var reused:=Plan._future_continuation(s,0,2,1,3,seed_base,cache,deeper,_profile())
	check(reused.complete and reused.evaluations==1 and reused.state.round_num==s.round_num+3 and cache[str([0,2,1,2])].round_num==s.round_num+2,"命中最近深度只补缺失一回合，旧缓存保持不变")
	var other:=Plan._future_continuation(s,0,2,2,2,seed_base,cache,{},_profile())
	check(other.complete and other.evaluations==2 and other.state.rng_snapshot().seed==str(seed_base+2*104729),"不同样本不能串用缓存，缺起点重设正确样本seed")
	var exhausted:=_profile();exhausted._work=[0]
	var failed:=Plan._future_continuation(s,0,2,1,3,seed_base,cache,{},exhausted)
	check(not failed.complete and exhausted._work[0]==0,"缺层预算不足不能伪造完成或补赠额度")

func _test_real_layers()->void:
	var s:=_small();var won:=Env.copy(s);won.winner="ai"
	var extra:=Env.copy(s);extra.add_card("ai","cash")
	var live:=_candidate(s);live.responses=[s,extra]
	var contenders:=[live,_candidate(won,1)]
	var p:=_profile();var done:=Plan._deepen(s,"ai",contenders,p)
	check(done.complete_layers==6 and done.best==contenders[1] and done.value==1.0,"真实小状态共同层保持已知精确终局冠军，完成两回合三样本")
	var uses_prior:=true
	for i in range(1,done.trace.size()):uses_prior=uses_prior and done.trace[i].evaluation_order[0]==done.trace[i-1].winner
	check(uses_prior and done.trace[0].evaluation_order==[0,1],"首层沿原序，后续只用上一完整层冠军调整次序")
	check(done.trace.any(func(layer):return layer.skipped_responses>0 and layer.value_kinds[0]=="upper_bound"),"真实前推触发上界剪枝，未算败者保持上界标签")
	var stable:=[_candidate(s,1),_candidate(Env.copy(s),0)]
	var one_p:=_profile();one_p.future_rounds=1;one_p.samples=1
	var one:=Plan._deepen(s,"ai",stable,one_p)
	var used:=100000-int(one_p._work[0]);var limited:=_profile();limited._work=[used+128]
	var partial:=Plan._deepen(s,"ai",stable,limited)
	check(one.complete_layers==1 and partial.incomplete and partial.complete_layers>=1 and partial.complete_layers<6,"真实额度可在完整层之后中断新层")
	var last:Dictionary=partial.trace.back()
	check(partial.best==stable[last.winner] and partial.value==last.values[last.winner] and partial.depth==last.depth and partial.samples==last.samples,"失败层不提交局部冠军、分数或深度，回退最后完整层")
	var zero:=_profile();zero._work=[0]
	var first_partial:=Plan._deepen(s,"ai",[_candidate(won),_candidate(s)],zero)
	check(first_partial.incomplete and first_partial.complete_layers==0 and not first_partial.has("best"),"只完成首候选不能提交伪共同层")

func _test_exact_responses()->void:
	var s:=_small();var extra:=Env.copy(s);extra.add_card("ai","cash")
	var candidate:=_candidate(s);candidate.responses=[s,Env.copy(s),extra]
	var p:=_profile();p.future_reply_limit=2
	var replies:=Plan._future_responses(candidate,p)
	check(replies.size()==2 and Env.key(replies[1])==Env.key(extra),"先按完整状态去重，重复状态不吞掉独立回应额度")
	var rng:=Env.copy(s);rng.set_seed(999)
	var ordered:=Env.copy(s);ordered.players.ai.cards.reverse()
	var marked:=Env.copy(s);marked.players.ai.cards[0]["worked_round"]=s.round_num
	candidate.responses=[s,Env.copy(s),rng,ordered,marked];p.future_reply_limit=128
	var all:=Plan._future_responses(candidate,p)
	check(all.size()==4 and all.has(rng) and all.has(ordered) and all.has(marked),"RNG、UID/牌序及运行时字段不同的回应不得按持牌数量误去重")

func _route(label:String,stage:int,cards:Array,score:float,who:String="player")->Dictionary:
	var s:=_small()
	for id in cards:s.add_card(who,id)
	var c:=_candidate(s,score);c.node.merge({"label":label,"generation_stage":stage})
	return c
func _labels(rows:Array)->Array:
	return rows.map(func(c):return c.node.label)

func _test_finalist_routes()->void:
	var rows:=[_route("top",2,["baoyue","baoyue"],10),_route("same",2,["baoyue","baoyue"],9),
		_route("stage1",1,["yunketang"],8),_route("stage0",0,["baoyue","baoyue"],7),_route("attack",2,["butie"],6)]
	var names:=_labels(rows);var scores:=rows.map(func(c):return c.score)
	var picked:=Plan._finalists(rows,4,{"candidate_dedup":1},"player")
	check(_labels(picked)==["top","stage1","stage0","attack"],"先保护当前冠军与较低累计阶段最佳，再优先新经营路线")
	check(_labels(Plan._finalists(rows,2,{"candidate_dedup":1},"player"))==["top","stage0"],"名额不足仍按既有阶段优先级保留")
	check(_labels(rows)==names and rows.map(func(c):return c.score)==scores and _labels(picked)==_labels(rows.filter(func(c):return picked.has(c))),"普通候选池与当前分不变，输出仍按原评分排序")
	var expected:=[[],["top"],["top","stage0"],["top","stage1","stage0"],["top","same","stage1","stage0"],["top","same","stage1","stage0","attack"]]
	for limit in expected.size():
		check(_labels(Plan._finalists(rows,limit,{"candidate_dedup":0},"player"))==expected[limit],"关闭能力limit%d沿原冠军/阶段/评分选择次序"%limit)
	check(_labels(Plan._finalists(rows,4))==expected[4],"两参调用不隐式启用分道")
	var routes:=[_route("double",0,["baoyue","baoyue"],5),_route("variant",0,["baoyue","baoyue"],4),_route("cloud",0,["yunketang"],3),_route("another",0,["baoyue","baoyue"],2),_route("attack",0,["butie"],1)]
	routes[1].node.state.add_card("player","cash");routes[1].node.state.add_card("player","user")
	check(_labels(Plan._finalists(routes,3,{"candidate_dedup":1},"player"))==["double","cloud","attack"],"资源余量变化不造新持牌道，有限名额优先不同经营路线")
	check(_labels(Plan._finalists(routes,4,{"candidate_dedup":1},"player"))==["double","variant","cloud","attack"],"不同路线用完后补回同道变体，不把分道当等价删除")
	check(_labels(Plan._finalists([routes[0],routes[1],routes[3]],2,{"candidate_dedup":1},"player"))==["double","variant"],"只有同道候选时仍填足名额")
	var counts:=[_route("one",0,["baoyue"],3),_route("same",0,["baoyue"],2),_route("two",0,["baoyue","baoyue"],1)]
	check(_labels(Plan._finalists(counts,2,{"candidate_dedup":1},"player"))==["one","two"],"非单位牌数量差异属于不同经营构成")
	var opposite:=[_route("one",0,["baoyue"],3,"ai"),_route("same",0,["baoyue"],2,"ai"),_route("other",0,["yunketang"],1,"ai")]
	check(_labels(Plan._finalists(opposite,2,{"candidate_dedup":1},"ai"))==["one","other"],"持牌分道读取实际行动方")
	check(Plan._finalists([],4,{"candidate_dedup":1}).is_empty() and Plan._finalists(rows,-1,{"candidate_dedup":1}).is_empty(),"空输入和非正名额安全返回")
	var bounded:=true
	for limit in range(1,8):
		var selected:=Plan._finalists(rows,limit,{"candidate_dedup":1},"player")
		bounded=bounded and selected.size()==mini(limit,rows.size()) and selected.all(func(c):return rows.has(c))
	check(bounded,"各种名额不超上限、不造候选或丢失可填席位")

func _test_sample_bounds() -> void:
	for rows in [[-1.0,-1.0,-1.0],[0.2,-0.4,0.6],[1.0,1.0,1.0],[-0.8,-0.9,0.3]]:
		var exact := 0.0
		for v in rows: exact += v
		exact /= float(rows.size())
		for cutoff in [-INF,-1.0,-0.5,0.0,0.5,1.0]:
			var result := Plan._sample_mean(rows.size(),cutoff,func(si: int)->Dictionary:return {"complete":true,"value":rows[si],"evaluations":1})
			check(result.complete and ((result.bounded and result.value==null and result.upper_bound<cutoff and exact<=result.upper_bound) or (not result.bounded and result.value==exact)),"样本均值界仅在严格不足冠军时剪枝，保留精确分/上界区别")
	var tied := Plan._sample_mean(3,1.0/3.0,func(si: int)->Dictionary:return {"complete":true,"value":[-1.0,1.0,1.0][si],"evaluations":1})
	check(not tied.bounded and tied.value==1.0/3.0 and tied.evaluations==3,"均值上界等于冠军时不得剪枝")
	var failed := Plan._sample_mean(3,-INF,func(si: int)->Dictionary:return {"complete":si==0,"value":0.0,"evaluations":1})
	check(not failed.complete and failed.evaluations==2,"未完成样本不得提交均值或上界")
	var s := _small();var candidates := [_candidate(s,2),_candidate(s,1)]
	var callback := func(ci: int,ri: int)->Dictionary:return {"complete":true,"value":[[0.4,0.5],[-0.1,-0.8]][ci][ri],"evaluations":1}
	var order := Plan._future_layer(candidates,[2,2],"ai",_profile(),callback,0,[1,1])
	check(order.complete and order.winner==0 and order.values[0]==0.4 and order.response_orders==[[1,0],[1,0]] and order.evaluations==3,"优先上层风险见证回应保留原ri身份与精确赢家并减少计算")
