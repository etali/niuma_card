# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Actions=preload("res://engine/bot_actions.gd")
const Env=preload("res://engine/bot_environment.gd")
const Cap=preload("res://engine/bot_capabilities.gd")
const Plan=preload("res://engine/bot_turn_plan.gd")
func profile(mode:int,budget:int)->Dictionary:
	var p:=BOTSearch.from_model("bot",1.0).resolved_parameters()
	p.merge({"financing_mode":mode,"generation_budget":budget,"buy_beam":16,"build_beam":16,"plans":16},true)
	p["_work"]=[budget];p["_context"]=BOTActions.Context.new()
	return p
func keys(nodes:Array)->Dictionary:
	var out:={}
	for node in nodes:out[Cap.signature(node.state)]=true
	return out
func _initialize()->void:
	CardDB.load_default()
	var fixture:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_financing_layers.json"))
	var state:=GameState.new();StateCodec.restore(state,fixture.state)
	var before:=StateCodec.state_hash(state)
	var lower_profile:=profile(1,2048)
	var lower:=Actions.generate_with_status(state,"bot",lower_profile)
	check(lower.complete,"有限低融资层已完整生成，作为高融资层必须保留的真实对照")
	var p:=profile(2,2048)
	var generated:=Actions.generate_with_status(state,"bot",p)
	var lower_keys:=keys(lower.nodes);var actual_keys:=keys(generated.nodes)
	check(lower_keys.keys().all(func(k):return actual_keys.has(k)),"高融资层不挤掉低融资层任何已保留完整动作")
	var prefix_preserved:=true
	for i in lower.nodes.size():prefix_preserved=prefix_preserved and Cap.signature(lower.nodes[i].state)==Cap.signature(generated.nodes[i].state)
	check(prefix_preserved,"已完成低层保持在评价顺序前缀，不能先评价高层后因总预算漏掉低层")
	check(keys(lower.baseline)==keys(generated.baseline),"层1并入候选不会冒充原始基础层或改变基础保护语义")
	check(generated.nodes.all(func(n):return bool(n.get("baseline",false))==generated.baseline.has(n)),"baseline标记只属于原基础节点且引用最终并集中的同一对象")
	check(generated.nodes.size()<=2*(int(p.plans)+2*int(p.tactical_extension))+generated.baseline.size(),"两层有限扩展只追加各自普通宽度与两类攻击代表及有限基础池")
	check(actual_keys.size()==generated.nodes.size(),"层间相同状态只按现有语义签名保留一次")
	check(generated.baseline.all(func(n):return int(n.generation_stage)==0) and generated.nodes.all(func(n):return int(n.generation_stage)>=0 and int(n.generation_stage)<=2),"节点保留最早生成阶段序号，基础仍为0")
	check(generated.nodes.slice(0,lower.nodes.size()).all(func(n):return int(n.generation_stage)<=1),"低层前缀不被重新标成高层")
	check(generated.baseline_complete and not generated.complete,"基础与层1完成、层2受限不谎报所有层完整")
	check(generated.generation_stages.size()==2 and generated.generation_stages[0].complete and not generated.generation_stages[1].complete,"诊断区分已完成的低层与受限高层")
	var paid:=0
	for stage in generated.generation_stages:paid+=int(stage.work)
	var basic_cost:=2048-int(lower_profile._work[0])-int(lower.generation_stages[0].work)
	check(paid+basic_cost==2048-int(p._work[0]) and int(p._work[0])>=0,"各层与基础共享同一总账，诊断工作量可精确相加且不透支")
	var actual:=Env.copy(state)
	check(Env.replay(actual,fixture.reply_intents),"真实反击卖一张拼少少、购买做空报告并以6用户编组合法")
	var matched:Dictionary={}
	for node in generated.nodes:
		if Cap.signature(node.state)==Cap.signature(actual):matched=node;break
	check(not matched.is_empty(),"161003：扩大融资模式后仍看见实际当回合清空现金的反击")
	if not matched.is_empty():
		var settled:=Env.copy(matched.state);Env.settle(settled,Plan._target_policy(p))
		check(settled.winner=="bot" and settled.resource_count("player","cash")==0 and Plan.settled_score(settled,"player",p)==-1000000.0,"保留回应按真实规则结算为当前致死，而非静态预测或加分偏好")
	check(generated.nodes.all(func(n):return Env.replay(Env.copy(state),n.intents)),"逐级并集所有动作完整合法，无UID或融资前缀错配")
	check(StateCodec.state_hash(state)==before,"逐级候选生成不修改真实起点")
	var reply_profile:=profile(2,2048)
	reply_profile.merge({"replies":16,"reply_generation_budget":2048},true)
	var resolved:=Plan.resolve_current(state,"player",reply_profile)
	check(resolved.complete and resolved.score==-1000000.0 and resolved.state.winner=="bot", "实际当前回应入口识别当回合现金清零，不只是在独立候选生成中存在")
	check(resolved.coverage_limited and int(reply_profile._work[0])>=0,"高层覆盖受限仍如实报告，完整低层提供的真实致死可参与评价")
	var wide_profile:=profile(2,8192)
	var wide:=Actions.generate_with_status(state,"bot",wide_profile)
	check(wide.complete and wide.generation_stages.all(func(s):return s.complete),"充分额度下两层均完整而非永久标为受限")
	check(lower_keys.keys().all(func(k):return keys(wide.nodes).has(k)),"充分额度后高融资层同样保留完整低层空间")
	var tiny:=Actions.generate_with_status(state,"bot",profile(2,1))
	check(not tiny.baseline_complete and not tiny.complete,"基础也未完成的极小预算不得借用高层标记当完整")
	finish()
