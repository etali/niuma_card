# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Env=preload("res://engine/ai_environment.gd")
const Plan=preload("res://engine/ai_turn_plan.gd")
const Flow=preload("res://engine/round_flow.gd")
func _initialize()->void:
	CardDB.ensure_loaded()
	await _test_sequences()
	_test_baseline_incumbent()
	_test_invalidations()
	finish()
func _users(s:GameState,who:String,n:int)->Array:
	var out:=[]
	for c in s.players[who].cards:
		if c.def_id=="user" and not c.get("locked",false):out.append(c.uid)
	return out.slice(0,n)
func _state(count:int)->GameState:
	var s:=GameState.new();s.set_seed(1)
	s.players={"ai":{"cards":[]},"player":{"cards":[]}};s.draw_first="ai"
	for who in ["ai","player"]:
		for i in 10:s.add_card(who,"cash")
		for i in 6 if who=="ai" else 10+count:s.add_card(who,"user")
	var attack:=s.add_card("ai","chaping")
	check(Env.replay(s,[Intent.create_combo("ai",[attack.uid]+_users(s,"ai",6))]),"三点用户攻击经共享规则成立")
	var padded:=s.add_card("player","xinxijianfang")
	check(Env.replay(s,[Intent.create_combo("player",[padded.uid]+_users(s,"player",10))]),"茧房真实超配10用户，三击不能拆掉")
	for id in ["yunketang","baoyue","shuabuting","jiaolv","xufei"].slice(0,count):
		var core:=s.add_card("player",id);var buff:=s.add_card("player","liebian")
		check(Env.replay(s,[Intent.create_combo("player",[core.uid,buff.uid]+_users(s,"player",1))]),"裂变让另一个生产组只需一用户")
	return s
func _test_sequences()->void:
	for count in [3,4,5]:
		var initial:=_state(count)
		var cfg:=AISearch.from_model("ai",1.0)
		var p:=cfg.resolved_parameters();p["_context"]=AIActions.Context.new()
		var probe:=Env.copy(initial);var pools:=probe.arm_attacks("ai");var budget:=[64]
		var searched:=Plan._attack_sequence(probe,"ai",pools,p,budget,3)
		check(searched.targets.size()==3,"递归返回全部三击，而非只有首击")
		check(budget[0]>=0 and budget[0]<=64,"完整基线与深化共用额度，不透支试算")
		var actual:=Env.copy(initial)
		Env.settle(actual,Plan.target_picker(cfg))
		check(Plan.settled_score(actual,"ai",p)==searched.score,"实际执行完整续打后所得评分与搜索预测完全一致")
		check(actual.resource_count("player","cash")== ({3:28,4:32,5:38}[count]),"余点继续拆小生产组，不改打无法拆散的大组")
		var transported:=Env.copy(initial)
		var transport:=LocalTransport.new(IntentApply.new(transported))
		var flow=Flow.new(func():return transport)
		var result:Dictionary=await flow.run_round(Plan.target_picker(cfg))
		check(result.ok and Env.key(transported)==Env.key(actual),"RoundFlow逐个Intent执行与搜索/无头结算状态一致")
func _test_invalidations()->void:
	for changed in ["state","targets"]:
		var s:=_state(4);var pools:=s.arm_attacks("ai")
		var p:=AISearch.from_model("ai",1.0).resolved_parameters();p["_context"]=AIActions.Context.new()
		var budget:=[64];var plan:={}
		var first:=Plan._choose_target(s,"ai",s.affordable_targets("player",pools),pools,p,budget,plan)
		check(budget[0]==0 and plan.targets.size()==2,"首击之后仍保存已评估的两击，虽试算额度已归零")
		check(s.apply_attack("ai",first,pools).ok,"缓存首击仍通过真实攻击校验")
		s.check_victory()
		if changed=="state":s.add_card("player","cash")
		var targets:=s.affordable_targets("player",pools)
		if changed=="targets":targets=targets.filter(func(t):return t!=plan.targets[0])
		var greedy:=Plan.greedy_target(s,"ai",targets,pools,p)
		var picked:=Plan._choose_target(s,"ai",targets,pools,p,budget,plan)
		check(plan.is_empty() and picked==greedy and targets.has(picked),"%s变化使旧续打失效，预算耗尽时回到合法统一fallback" % changed)
		check(budget[0]==0,"失效fallback不虚增或透支攻击预算")

func _test_baseline_incumbent()->void:
	for count in [4,5]:
		for trials in [36,64]:
			var initial:=_state(count)
			var cfg:=AISearch.from_model("ai",1.0)
			cfg.apply_override("target_trials",trials)
			var p:=cfg.resolved_parameters();p["_context"]=AIActions.Context.new()
			var probe:=Env.copy(initial);var pools:=probe.arm_attacks("ai");var budget:=[trials]
			var baseline:=Plan._attack_baseline(probe,"ai",pools,p,budget)
			var baseline_used:int=trials-int(budget[0])
			check(baseline_used>0 and baseline_used<=trials,"完整低深度基线真正扣除共享攻击预算")
			var searched:=Plan._attack_sequence(probe,"ai",pools,p,budget,3,baseline)
			check(int(budget[0])>=0 and int(budget[0])<=trials-baseline_used,"深化只能花基线剩余额度")
			check(float(searched.score)>=float(baseline.score),"有限深化保留已经完成的更好整段路线")
			var actual:=Env.copy(initial);Env.settle(actual,Plan.target_picker(cfg))
			cfg.apply_override("attack_mode",0)
			var reference:=Env.copy(initial);Env.settle(reference,Plan.target_picker(cfg))
			check(Plan.settled_score(actual,"ai",p)>=Plan.settled_score(reference,"ai",p),"%d组/%d次真实完整攻击不丢失低深度模式的后续改进" % [count,trials])
			check(actual.resource_count("player","cash")==({4:32,5:38}[count]),"仍按真实生产规则拆掉有收益的三个小组")
