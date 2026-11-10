# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")

func _initialize() -> void:
	_universal_availability_and_cancellation()
	_every_root_uses_the_same_continuation()
	_partial_seeds_keep_unseen_roots()
	_paid_recruitment_can_be_deployed_by_ordinary_actions()
	_old_plan_is_an_option_after_new_spending()
	_event_wait_preserves_earlier_choices()
	_production_wait_ignores_unrelated_market_ticks()
	_joint_seed_replays_the_opponent()
	_every_root_replays_the_same_saved_suffix()
	_paid_opponent_dispatch_keeps_its_clock()
	_paid_opponent_returns_after_a_later_strike()
	_joint_reply_spends_the_opponent_slot()
	_opponent_returns_after_finishing_another_pile()
	_opponent_combines_paid_materials_and_people()
	_causal_wait_uses_the_real_remaining_time()
	_every_root_faces_the_same_reply_portfolio()
	_new_root_inspects_its_outputs_before_the_saved_suffix()
	_saved_suffix_is_recomputed_to_completion()
	_warm_candidate_can_lose_to_a_new_quote()
	_empty_wait_yields_without_removing_its_frontier()
	_an_episode_compares_sibling_uses()
	_branching_keeps_per_path_depth()
	finish()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":80}]
	config.rules.initial.money=20
	config.rules.bot.think_seconds=6.0
	config.rules.bot.evaluation_max_seconds=90.0
	config.rules.conveyor.interval_seconds=1000.0
	var world := OffWorkState.new(config)
	world.new_game(1907)
	world.offers.clear()
	world.drain_events()
	return world

func _target(world: OffWorkState) -> int:
	return int(world.cards[world._owner_type(0,"work")[0]].group)

func _offer(world: OffWorkState, kind: String) -> Dictionary:
	var offer: Dictionary=world._make_offer(kind)
	world.offers.append(offer)
	return {"kind":"buy","offer":offer.id,"card_type":kind,"intent":"buy"}

func _seed(world: OffWorkState, action: Dictionary) -> Dictionary:
	var branch := world.fork_for_bot(1908)
	check(Actions.apply_search_action(branch,0,action),"根候选通过同一个规则执行入口")
	branch.advance_for_search(3.0,-1)
	branch.mask_search_market(world._next_offer)
	var value: Dictionary=Evaluation.new().evaluate_current(branch,0,world.config.rules.bot,-1,[3.0,0.0])
	return {"action":action,"value":value,"elapsed":3.0,"next_actions":[3.0,0.0]}

func _universal_availability_and_cancellation() -> void:
	var world := _world()
	check(Continuations.available(world,0),"没有老板、摸鱼或咖啡也允许相同的长期续搜")
	var state := {}
	var status: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),
		func():return true,{"planner_state":state})
	check(status.examined==0 and state.is_empty(),"取消的决策不初始化搜索或枚举动作")
	status=Continuations.visit(world,0,world.config.rules.bot,Time.get_ticks_usec()-1,[0.0,3.0],Callable(),Callable(),{"planner_state":state})
	check(status.examined==0 and state.is_empty(),"已过期的决策不建立生产候选")

func _every_root_uses_the_same_continuation() -> void:
	var world := _world()
	var buy := _offer(world,"employee")
	var seeds := [_seed(world,{"kind":"wait","intent":"wait"}),_seed(world,buy)]
	var before := var_to_bytes([world.cards,world.groups,world.tasks,world.time,world.offers])
	var roots := {}
	var checked := {"legal":true,"score":true,"clock":true,"public":true,"count":0}
	var state := {}
	var status: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		roots[int(plan.growth.root_index)]=true
		checked.count+=1
		var replay := world.fork_for_bot(1908)
		var previous := -6.0
		for command in plan.commands:
			checked.clock=checked.clock and float(command.at)>=previous+6.0-1e-8
			previous=float(command.at)
			replay.advance_for_search(world.time+float(command.at)-replay.time,-1)
			replay.mask_search_market(world._next_offer)
			checked.legal=Actions.apply_search_action(replay,0,command.action) and checked.legal
			if command.action.kind=="buy": checked.public=checked.public and int(command.action.offer)==int(buy.offer)
		var fresh: Dictionary=Evaluation.new().evaluate_current(plan.world,0,world.config.rules.bot,-1,plan.next_actions)
		checked.score=checked.score and is_equal_approx(float(fresh.score),float(plan.evaluation.score))
		,Callable(),{"planner_state":state,"root_candidates":seeds,"expansion_limit":28,"depth_limit":3,
		"root_action_filter":func(action):return action.kind=="wait" or (action.kind=="buy" and int(action.offer)==int(buy.offer))})
	check(roots.has(0) and roots.has(1),"等待与当前公开人员购买都能继续同一合法动作树")
	check(status.max_depth>=2 and checked.count>2,"长期搜索真实延展根动作而不只比较单步尾值")
	check(checked.legal and checked.clock,"所有已发布前缀都可按真实行动间隔合法重放")
	check(checked.score,"探索调度没有混入发布分数，数值等于统一完工评价")
	check(checked.public,"所有购买只使用根观测中真实存在的公开报价")
	check(before==var_to_bytes([world.cards,world.groups,world.tasks,world.time,world.offers]),"续搜不修改真实牌桌、牌组、任务或时钟")

func _partial_seeds_keep_unseen_roots() -> void:
	var world := _world()
	var buy := _offer(world,"employee")
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),
		{"planner_state":state,"root_candidates":[_seed(world,{"kind":"wait","intent":"wait"})],"checkpoint_limit":1,"depth_limit":2})
	check(state.planner.nodes[0].actions.any(func(action):return action.kind=="buy" and int(action.offer)==int(buy.offer)),
		"只给已覆盖根前缀时，不丢弃其余普通合法动作")

func _paid_recruitment_can_be_deployed_by_ordinary_actions() -> void:
	var world := _world()
	world.add_card("boss",0)
	var generated: Dictionary=Actions.generate(world,0,world.config.rules.bot,-1)
	var choices: Array=generated.actions.filter(func(action):return action.get("intent","")=="recruitment")
	if not need(not choices.is_empty(),"普通合法动作生成器提供招聘动作"): return
	var seen := {"deployed":false,"after":false}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		var working := 0
		for id in plan.world._owner_type(0,"employee"):
			if plan.world.tasks.get(id,{}).get("kind","")=="work": working+=1
		seen.deployed=seen.deployed or working>1
		seen.after=seen.after or (plan.commands.size()>=3 and working>1)
		,Callable(),{"root_candidates":[_seed(world,choices[0])],"expansion_limit":20,"depth_limit":4,
		"root_action_filter":func(action):return false})
	check(seen.deployed and seen.after,"招聘、等待真实完成、派工由同一动作树衔接，没有专用招聘政策")

func _old_plan_is_an_option_after_new_spending() -> void:
	var world := _world()
	var idle := world.add_card("employee",0)
	var dispatch := {"kind":"move","ids":[idle],"group":_target(world),"intent":"staff"}
	var step: Dictionary=Execution.describe(world,0,dispatch)
	step.ready_at=0.0
	var context := {"observed_at":world.time,"source":"executable","steps":[step]}
	var buy := _offer(world,"overtime")
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),
		{"planner_state":state,"execution_context":context,"root_candidates":[_seed(world,buy)],"checkpoint_limit":1,"depth_limit":2,
		"root_action_filter":func(action):return action.kind=="buy" and int(action.offer)==int(buy.offer)})
	var planner: RefCounted=state.planner
	check(not planner.nodes[1].context.is_empty(),"根动作购买别的卡后仍保留已投资计划供同一续搜选择")
	check(planner.nodes[1].actions.any(func(action):return action.get("ids",[]).has(idle) and int(action.get("group",-1))==_target(world)),
		"购买后的同一候选集合包含原有员工返岗，不另设受保护执行队列")

func _event_wait_preserves_earlier_choices() -> void:
	var world := _world()
	world.config.rules.bot.think_seconds=2.0
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,1.0],Callable(),Callable(),
		{"planner_state":state,"checkpoint_limit":1,"depth_limit":1})
	var actions: Array=state.planner.nodes[0].actions
	check(actions.any(func(action):return action.kind=="wait" and not action.has("_event_at")) \
		and actions.any(func(action):return action.has("_event_at")),"事件跳转只是额外等待选项，保留更早行动机会")

func _production_wait_ignores_unrelated_market_ticks() -> void:
	var world := _world()
	world.config.rules.conveyor.interval_seconds=2.0
	_offer(world,"employee")
	var slack := world.add_card("slack",0)
	var leader := world.add_card("leader",0)
	var staff := {"kind":"move","ids":[slack,leader],"group":-1,"intent":"slack"}
	var state := {}
	var produced := {"seen":false}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		produced.seen=not plan.world._owner_type(0,"coffee").is_empty()
		,Callable(),{"planner_state":state,"root_candidates":[_seed(world,staff)],"seed_roots_only":true,"checkpoint_limit":1})
	check(state.planner.nodes[1].actions.any(func(action):return action.get("_causal",false) and float(action._event_at)>=18.0),
		"2秒市场更新不吞掉14秒真实任务完成的等待候选")
	check(produced.seen,"通用因果路径等待真实产物，不在刚开始任务后立即撤回人员")

func _joint_seed_replays_the_opponent() -> void:
	var world := _world()
	var strike := world.add_card("strike",1)
	var wait := {"kind":"wait","intent":"wait"}
	var attack := {"kind":"activate","tool":strike,"group":_target(world),"intent":"strike"}
	var branch := world.fork_for_bot(1908)
	Actions.apply_search_action(branch,0,wait)
	branch.advance_for_search(3.0,-1)
	if not need(Actions.apply_search_action(branch,1,attack),"短战术前缀包含对手真实罢工回应"): return
	branch.advance_for_search(3.0,-1)
	var value: Dictionary=Evaluation.new().evaluate_current(branch,0,world.config.rules.bot,-1,[0.0,3.0])
	var seed := {"action":wait,"value":value,"elapsed":6.0,"next_action":6.0,
		"commands":[{"at":0.0,"action":wait}],"replies":[{"at":3.0,"action":attack}]}
	var seen := {"reply":false,"strike":false}
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		seen.reply=plan.replies.size()==1 and plan.replies[0].action.tool==strike
		seen.strike=plan.world._owner_type(0,"employee").any(func(id):return plan.world.is_striking(int(id)))
		,Callable(),{"planner_state":state,"root_candidates":[seed],"seed_roots_only":true,"checkpoint_limit":1})
	check(seen.reply and seen.strike,"长期续搜保留已发生的对手回应及停工，不重建成无回应世界")
	check(state.planner.nodes[0].actions.is_empty(),"已回应根模式不生成绕过短战术的新根或长等待根")

func _every_root_replays_the_same_saved_suffix() -> void:
	var world := _world()
	var idle := world.add_card("employee",0)
	var boss := world.add_card("boss",0)
	var deploy := {"kind":"move","ids":[idle],"group":_target(world),"intent":"staff"}
	var hire := {"kind":"move","ids":[boss]+world._owner_type(0,"money").slice(0,10),"group":-1,"intent":"recruitment"}
	var first: Dictionary=Execution.describe(world,0,deploy)
	first.ready_at=0.0
	var second: Dictionary=Execution.describe(world,0,hire)
	second.ready_at=6.0
	var context := {"observed_at":world.time,"source":"executable","steps":[first,second]}
	var roots := [_seed(world,{"kind":"wait","intent":"wait"}),_seed(world,deploy)]
	var best := [INF,INF]
	var later := {"eta":INF}
	var hire_seen := [false,false]
	var clean := {"value":true}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		var root: int=plan.growth.root_index
		if root<0 or root>=2: return
		var operations: Array=plan.commands.filter(func(command):return command.action.kind!="wait")
		var same_suffix: bool=operations.size()==2 and Execution._same(operations[0].action,deploy) and Execution._same(operations[1].action,hire)
		if same_suffix and not plan.evaluation.detail.get("terminal",false):
			best[root]=minf(float(best[root]),float(plan.elapsed)+float(plan.evaluation.detail.sides[0].eta))
			if float(operations[1].at)>=24.0: later.eta=minf(float(later.eta),float(plan.elapsed)+float(plan.evaluation.detail.sides[0].eta))
		hire_seen[root]=hire_seen[root] or plan.commands.any(func(command):return command.action.get("intent","")=="recruitment")
		clean.value=clean.value and plan.commands.all(func(command):return not command.action.has("_warm") and not command.action.has("_warm_step"))
		,Callable(),{"root_candidates":roots,"seed_roots_only":true,"execution_context":context,"expansion_limit":8,"depth_limit":5})
	check(hire_seen[0] and hire_seen[1],"等待与立即执行旧步骤两根都实际重放相同的招聘后续")
	check(float(best[1])<=float(best[0]),"同投入立即派工不劣于最优等待方案，允许真实工作批次使完工时刻打平")
	check(is_finite(float(later.eta)) and float(best[1])<float(later.eta),"把同一招聘继续拖至24秒的完整方案确实更差")
	check(clean.value,"warm-start只调度搜索，内部标记不进入执行命令或分数")

func _paid_opponent_dispatch_keeps_its_clock() -> void:
	var world := _world()
	var idle := world.add_card("employee",1)
	var seed := _seed(world,{"kind":"wait","intent":"wait"})
	var expected: float=3.0+float(seed.value.detail.sides[1].eta)
	var evidence := {"paid":true,"clock":true,"eta":true,"count":0,"replay":true}
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		evidence.count+=1
		evidence.paid=evidence.paid and plan.world.tasks.get(idle,{}).get("kind","")=="work"
		evidence.clock=evidence.clock and plan.replies.size()==1 and is_equal_approx(float(plan.replies[0].at),3.0)
		if not plan.evaluation.detail.get("terminal",false):
			evidence.eta=evidence.eta and is_equal_approx(float(plan.elapsed)+float(plan.evaluation.detail.sides[1].eta),expected)
		,Callable(),{"planner_state":state,"root_candidates":[seed],"seed_roots_only":true,
		"physical_opponent":true,"root_replies":[{"kind":"wait","intent":"wait"}],"expansion_limit":24,"depth_limit":8})
	check(evidence.count>4 and evidence.paid and evidence.clock,"己方等多轮仍只在敌方原3秒行动格执行一次已付费派工")
	check(evidence.eta,"延长己方前缀不能反复推迟敌方派工、虚增敌方根时钟ETA")
	var planner: RefCounted=state.planner
	planner.cache_limit=2
	planner._evict(planner.nodes.size()-1)
	var replayed := false
	for index in range(1,planner.nodes.size()):
		var node: Dictionary=planner.nodes[index]
		if node.cursor.world!=null or node.cursor.replies.is_empty(): continue
		var expected_replies: Array=node.cursor.replies.duplicate(true)
		var expected_next := float(node.cursor.enemy_next)
		replayed=true
		evidence.replay=planner._materialize(index) and node.cursor.replies==expected_replies \
			and is_equal_approx(float(node.cursor.enemy_next),expected_next) \
			and node.cursor.world.tasks.get(idle,{}).get("kind","")=="work"
		break
	check(replayed and evidence.replay,"淘汰缓存后按真实双方动作重放，敌方派工与下一行动格保持不变")

func _paid_opponent_returns_after_a_later_strike() -> void:
	var world := _world()
	var idle := world.add_card("employee",1)
	var target := int(world.cards[world._owner_type(1,"work")[0]].group)
	var tool := world.add_card("strike",0)
	var attack := {"kind":"activate","tool":tool,"group":target,"intent":"strike"}
	var step: Dictionary=Execution.describe(world,0,attack)
	step.ready_at=6.0
	var context := {"observed_at":world.time,"source":"executable","steps":[step]}
	var seed := _seed(world,{"kind":"wait","intent":"wait"})
	var expected: float=3.0+float(seed.value.detail.sides[1].eta)
	var evidence := {"hit":false,"returned":false,"delayed":false,"clock":true}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		if not plan.commands.any(func(command):return command.action.get("tool",-1)==tool): return
		evidence.hit=evidence.hit or plan.world.is_striking(idle)
		evidence.returned=evidence.returned or (plan.replies.size()>1 and plan.world.tasks.get(idle,{}).get("kind","")=="work")
		if not plan.evaluation.detail.get("terminal",false):
			evidence.delayed=evidence.delayed or float(plan.elapsed)+float(plan.evaluation.detail.sides[1].eta)>expected+1.0
		var previous := -3.0
		for reply in plan.replies:
			evidence.clock=evidence.clock and float(reply.at)>=previous+6.0-1e-8
			previous=float(reply.at)
		,Callable(),{"root_candidates":[seed],"seed_roots_only":true,"physical_opponent":true,
		"execution_context":context,"expansion_limit":48,"depth_limit":10})
	check(evidence.hit and evidence.delayed,"真实后续罢工作用于同一世界并推迟敌方完工时间")
	check(evidence.returned and evidence.clock,"敌方已付费人员在罢工结束后的合法行动格返岗，不永久闲置或重复占槽")

func _joint_reply_spends_the_opponent_slot() -> void:
	var world := _world()
	var idle := world.add_card("employee",1)
	var wait := {"kind":"wait","intent":"wait"}
	var buy := _offer(world,"employee")
	var branch := world.fork_for_bot(1908)
	Actions.apply_search_action(branch,0,wait)
	branch.advance_for_search(3.0,-1)
	if not need(Actions.apply_search_action(branch,1,buy),"短战术实际执行敌方人员购买"): return
	branch.advance_for_search(3.0,-1)
	var value: Dictionary=Evaluation.new().evaluate_current(branch,0,world.config.rules.bot,-1,[0.0,3.0])
	var seed := {"action":wait,"value":value,"elapsed":6.0,"next_action":6.0,"next_actions":[0.0,3.0],
		"commands":[{"at":0.0,"action":wait}],"replies":[{"at":3.0,"action":buy}]}
	var evidence := {"legal":false}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		evidence.legal=plan.replies.size()==2 and is_equal_approx(float(plan.replies[1].at),9.0) \
			and plan.world.tasks.get(idle,{}).get("kind","")=="work"
		,Callable(),{"root_candidates":[seed],"seed_roots_only":true,"physical_opponent":true,"checkpoint_limit":1})
	check(evidence.legal,"短战术已发生的敌方回应占用原行动格，物理派工只能使用下一格")

func _opponent_returns_after_finishing_another_pile() -> void:
	var world := _world()
	var returning := world.add_card("employee",1)
	world.add_card("work",1,int(world.cards[returning].group))
	var seed := _seed(world,{"kind":"wait","intent":"wait"})
	var expected: float=3.0+float(seed.value.detail.sides[1].eta)
	var evidence := {"returned":false,"eta":true,"clock":true}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		if float(plan.elapsed)<18.0: return
		evidence.returned=evidence.returned or plan.replies.any(func(reply):return reply.action.get("ids",[]).has(returning))
		evidence.clock=evidence.clock and plan.replies.any(func(reply):return is_equal_approx(float(reply.at),15.0) and reply.action.get("ids",[]).has(returning))
		if not plan.evaluation.detail.get("terminal",false):
			evidence.eta=evidence.eta and is_equal_approx(float(plan.elapsed)+float(plan.evaluation.detail.sides[1].eta),expected)
		,Callable(),{"root_candidates":[seed],"seed_roots_only":true,"physical_opponent":true,"expansion_limit":24,"depth_limit":8})
	check(evidence.returned and evidence.clock,"敌方小堆自然清空后在15秒合法格返岗，长前缀不能越过已知调度")
	check(evidence.eta,"多堆自然清空后的真实返岗保持敌方根时钟ETA")

func _opponent_combines_paid_materials_and_people() -> void:
	var world := _world()
	var idle := world.add_card("employee",1)
	var material := world.add_card("work",1)
	var seed := _seed(world,{"kind":"wait","intent":"wait"})
	var evidence := {"combined":false}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		evidence.combined=plan.replies.size()==1 and is_equal_approx(float(plan.replies[0].at),3.0) \
			and plan.replies[0].action.get("ids",[]).has(idle) and plan.replies[0].action.get("ids",[]).has(material)
		,Callable(),{"root_candidates":[seed],"seed_roots_only":true,"physical_opponent":true,"checkpoint_limit":1})
	check(evidence.combined,"物理尾同目的地同时间的人员与孤立工作合为一次真实行动")

func _causal_wait_uses_the_real_remaining_time() -> void:
	for kind in ["slack","recruitment"]:
		var world := _world()
		var action := {}
		if kind=="slack":
			var tool := world.add_card("slack",0)
			var leader := world.add_card("leader",0)
			action={"kind":"move","ids":[tool,leader],"group":-1,"intent":"slack"}
		else:
			world.add_card("boss",0)
			action=Actions.generate(world,0,world.config.rules.bot,-1).actions.filter(func(candidate):return candidate.get("intent","")=="recruitment")[0]
		var after := world.fork_for_bot(1908)
		Actions.apply_search_action(after,0,action)
		after.advance_for_search(6.0,-1)
		var planner := Continuations.Planner.new()
		planner.source=world
		planner.owner=0
		planner.period=6.0
		planner.next_actions=[0.0,3.0]
		var ready: float=planner._completion_slot(world,after,action,6.0)
		check(is_equal_approx(ready,18.0 if kind=="slack" else 12.0),"%s按真实剩余任务时间取最近合法格，没有额外等待一轮"%kind)

func _every_root_faces_the_same_reply_portfolio() -> void:
	var world := _world()
	var tool := world.add_card("strike",1)
	var buy := _offer(world,"overtime")
	var wait := {"kind":"wait","intent":"wait"}
	var reply := {"kind":"activate","tool":tool,"group":_target(world),"intent":"strike"}
	var seeds := [_seed(world,wait),_seed(world,buy)]
	var roots := {}
	var evidence := {"worst":true,"same_world":false,"first":-1,"checkpoints":[0,0]}
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		roots[int(plan.growth.root_index)]=true
		if int(evidence.first)<0: evidence.first=int(plan.growth.root_index)
		if plan.growth.get("root_checkpoint",false): evidence.checkpoints[int(plan.growth.root_index)]+=1
		evidence.worst=evidence.worst and not plan.replies.is_empty() \
			and plan.replies[0].action.get("tool",-1)==tool and is_equal_approx(float(plan.replies[0].at),3.0)
		evidence.same_world=evidence.same_world or (plan.world.pending_strikes.has(tool) \
			or plan.world._owner_type(0,"employee").any(func(id):return plan.world.is_striking(int(id))))
		,Callable(),{"planner_state":state,"root_candidates":seeds,"seed_roots_only":true,"physical_opponent":true,
		"root_replies":[wait,reply],"expansion_limit":8,"depth_limit":3})
	check(roots.size()==2 and evidence.worst,"每个根都以相同有限敌回应组合重估，不只续搜短期前K根")
	check(evidence.same_world,"选中的最坏真实回应保留在后续世界里，不与无回应世界拼接ETA")
	state.planner.cache_limit=2
	state.planner._evict(state.planner.nodes.size()-1)
	state.planner._materialize(1)
	state.planner._materialize(2)
	check(evidence.first==0 and evidence.checkpoints==[1,1],"首先发布incumbent的共同回应基线，每根完整checkpoint只发一次且缓存重放不重复发")

func _new_root_inspects_its_outputs_before_the_saved_suffix() -> void:
	var world := _world()
	var idle := world.add_card("employee",0)
	var boss := world.add_card("boss",0)
	var tool := world.add_card("slack",0)
	var leader := world.add_card("leader",0)
	var deploy := {"kind":"move","ids":[idle],"group":_target(world),"intent":"staff"}
	var hire := {"kind":"move","ids":[boss]+world._owner_type(0,"money").slice(0,5),"group":-1,"intent":"recruitment"}
	var first: Dictionary=Execution.describe(world,0,deploy)
	first.ready_at=6.0
	var second: Dictionary=Execution.describe(world,0,hire)
	second.ready_at=12.0
	var context := {"observed_at":world.time,"source":"executable","steps":[first,second]}
	var wait := {"kind":"wait","intent":"wait"}
	var start := {"kind":"move","ids":[tool,leader],"group":-1,"intent":"slack"}
	var evidence := {"incumbent":false,"output":false,"score":true}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		if plan.commands.size()<2: return
		if int(plan.growth.root_index)==0:
			evidence.incumbent=evidence.incumbent or (plan.commands[1].action.kind=="move" and plan.commands[1].action.get("ids",[]).has(idle))
		elif plan.commands.size()>=3:
			evidence.output=evidence.output or (plan.commands[1].action.kind=="wait" \
				and is_equal_approx(float(plan.commands[2].at),18.0) and plan.commands[2].action.get("intent","")=="coffee")
		var fresh: Dictionary=Evaluation.new().evaluate_current(plan.world,0,world.config.rules.bot,-1,plan.next_actions)
		evidence.score=evidence.score and is_equal_approx(float(fresh.score),float(plan.evaluation.score))
		,Callable(),{"root_candidates":[_seed(world,wait),_seed(world,start)],"seed_roots_only":true,
		"physical_opponent":true,"root_replies":[wait],"execution_context":context,"expansion_limit":24,"depth_limit":6})
	check(evidence.incumbent,"incumbent仍实际评分已有派工后续，维持同一比较基线")
	check(evidence.output,"不同根先等待真实产物并检验其合法用途，不被旧后续吞掉整段计算")
	check(evidence.score,"新产物优先仅分配计算，发布值仍精确等于统一完工评价")

func _saved_suffix_is_recomputed_to_completion() -> void:
	var world := _world()
	var steps := []
	var first := {}
	for index in 6:
		var idle := world.add_card("employee",0)
		var action := {"kind":"move","ids":[idle],"group":_target(world),"intent":"staff"}
		if index==0: first=action
		var step: Dictionary=Execution.describe(world,0,action)
		step.ready_at=float(index)*6.0
		steps.append(step)
	var context := {"observed_at":world.time,"source":"executable","steps":steps}
	var wait := {"kind":"wait","intent":"wait"}
	var evidence := {"complete":false,"fresh":true}
	var options := {"root_candidates":[_seed(world,wait),_seed(world,first)],"seed_roots_only":true,
		"physical_opponent":true,"root_replies":[wait],"execution_context":context,"expansion_limit":5}
	var result: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		evidence.complete=evidence.complete or (plan.growth.get("warm_complete",false) and plan.commands.size()==6)
		var fresh: Dictionary=Evaluation.new().evaluate_current(plan.world,0,world.config.rules.bot,-1,plan.next_actions)
		evidence.fresh=evidence.fresh and is_equal_approx(float(fresh.score),float(plan.evaluation.score))
		,Callable(),options)
	check(result.warm_complete and result.warm_root_index==1 and result.warm_examined==5 and evidence.complete,
		"已有有限suffix优先完整重算，五个剩余操作不会被普通四操作episode截断")
	check(evidence.fresh,"暖候选每个已发布前缀都使用当前真实世界重新完成的尾评分")
	options.expansion_limit=2
	var partial: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),options)
	check(not partial.warm_complete,"暖候选中断时不冒称已完整兑现保存队列")
	var invalid := context.duplicate(true)
	invalid.steps[1]={"kind":"buy","offer":-999,"card_type":"employee","ready_at":6.0}
	options.execution_context=invalid
	var rejected: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),options)
	check(not rejected.warm_complete,"保存后续失效只结束该计算候选，不把删除队列算成完成")

func _warm_candidate_can_lose_to_a_new_quote() -> void:
	var world := _world()
	var idle := world.add_card("employee",0)
	var deploy := {"kind":"move","ids":[idle],"group":_target(world),"intent":"staff"}
	var step: Dictionary=Execution.describe(world,0,deploy)
	step.ready_at=0.0
	var context := {"observed_at":world.time,"source":"executable","steps":[step]}
	var wait := {"kind":"wait","intent":"wait"}
	var buy := _offer(world,"employee")
	var best := {"eta":INF,"action":{}}
	var result: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		if plan.evaluation.detail.get("terminal",false): return
		var eta: float=float(plan.elapsed)+float(plan.evaluation.detail.sides[0].eta)
		if eta<float(best.eta)-1e-8: best.merge({"eta":eta,"action":plan.commands[0].action},true)
		,Callable(),{"root_candidates":[_seed(world,wait),_seed(world,deploy),_seed(world,buy)],"seed_roots_only":true,
		"physical_opponent":true,"root_replies":[wait],"execution_context":context,"expansion_limit":24,"depth_limit":5})
	check(result.warm_complete and best.action.get("kind","")=="buy",
		"完整暖候选仍可被更好公开报价的真实完工计划击败，没有保护执行或否决权")

func _empty_wait_yields_without_removing_its_frontier() -> void:
	var world := _world()
	world.config.cards.work.work_seconds=1000.0
	var buy := _offer(world,"employee")
	var state := {}
	var result: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),
		{"planner_state":state,"expansion_limit":3,"root_action_filter":func(action):
			return action.kind=="wait" or (action.kind=="buy" and int(action.offer)==int(buy.offer))})
	check(result.empty_wait_yields==1 and result.root_serviced==2,
		"冷启动无产物普通等待只占一次延展便轮给下一根，不以二十次空等吞掉预算")
	var waited: Dictionary=state.planner.nodes[2]
	check(waited.cursor.commands.size()==2 and waited.cursor.commands[-1].action.kind=="wait" and not waited.finished,
		"让出计算仍保留普通等待的合法已评分子节点，后续可以重访")
	var idle := world.add_card("employee",0)
	var action := {"kind":"move","ids":[idle],"group":_target(world),"intent":"staff"}
	var step: Dictionary=Execution.describe(world,0,action)
	step.ready_at=30.0
	var context := {"observed_at":world.time,"source":"executable","steps":[step]}
	var wait := {"kind":"wait","intent":"wait"}
	var completed := {"at":-1.0}
	result=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		if plan.growth.get("warm_complete",false): completed.at=float(plan.commands[-1].at)
		,Callable(),{"root_candidates":[_seed(world,wait)],"seed_roots_only":true,"execution_context":context,"expansion_limit":2})
	check(result.warm_complete and result.empty_wait_yields==0 and is_equal_approx(float(completed.at),30.0),
		"保存队列的必要等待即使无新产物也完整重算，时钟和既有预算不变")

func _an_episode_compares_sibling_uses() -> void:
	var world := _world()
	world.config.rules.transfer.seconds=1.0
	var buy := _offer(world,"transfer")
	var candidates := []
	var state := {}
	Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
		if plan.commands.size()==2 and plan.commands[1].action.kind=="move":
			candidates.append({"action":plan.commands[1].action,"eta":float(plan.elapsed)+float(plan.evaluation.detail.sides[0].eta)})
		,Callable(),{"planner_state":state,"root_candidates":[_seed(world,buy)],"seed_roots_only":true,"expansion_limit":4})
	check(candidates.size()>=2 and not Execution._same(candidates[0].action,candidates[1].action),
		"一个episode在既有四节点预算内比较同一新资源的不同合法用途，首子节点不能垄断深入")
	check(candidates.size()>=2 and float(candidates[1].eta)<float(candidates[0].eta),
		"后续兄弟的收益来自重新执行后的完工时间，不靠人员或卡种优先级")

func _branching_keeps_per_path_depth() -> void:
	var world := _world()
	# A narrower legal traversal reaches the four-operation boundary within
	# the unchanged twenty-node episode cap while still comparing siblings.
	world.config.rules.bot.search_reply_width=1
	for index in 3: world.add_card("employee",0)
	world.add_card("boss",0)
	var buy := _offer(world,"employee")
	var state := {}
	var status: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),
		{"planner_state":state,"root_candidates":[_seed(world,buy)],"seed_roots_only":true,"expansion_limit":64})
	var counts := {}
	var bounded := true
	var deepest := 0
	for node in state.planner.nodes:
		deepest=maxi(deepest,node.cursor.commands.filter(func(command):return command.action.kind!="wait").size())
		var episode: int=int(node.created_episode)
		if episode<0: continue
		counts[episode]=int(counts.get(episode,0))+int(node.operation)
		var operations: int=int(node.operation)
		var ancestor: int=int(node.parent)
		while ancestor>=0:
			var parent: Dictionary=state.planner.nodes[ancestor]
			if int(parent.created_episode)==episode: operations+=int(parent.operation)
			ancestor=int(parent.parent)
		bounded=bounded and operations<=int(world.config.rules.bot.search_max_depth)
	check(counts.values().any(func(count):return int(count)>int(world.config.rules.bot.search_max_depth)),
		"兄弟各有非wait深度额度，同一episode能真实评分超过四个分布在不同路径的操作")
	check(bounded and status.episode_peak_new_operations==int(world.config.rules.bot.search_max_depth) \
		and status.episode_peak_expansions<=status.episode_expansion_limit,
		"每条路径新增操作仍限四步，整个episode仍受原二十节点总上限约束")
	check(deepest>int(world.config.rules.bot.search_max_depth)+1,
		"后续episode重访旧frontier可继续深入，旧节点不形成永久四步硬截断")
