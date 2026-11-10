# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")

func _initialize() -> void:
	_checkpoint_coverage()
	_resume_after_cancel()
	finish()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":3,"work":120}]
	config.rules.initial.money=20
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.bot.think_seconds=6.0
	config.rules.bot.evaluation_max_seconds=60.0
	var world := OffWorkState.new(config)
	world.new_game(829)
	world.offers.clear()
	world.add_card("boss",0)
	world.add_card("coffee",0)
	world.add_card("slack",0)
	world.offers.append(world._make_offer("employee"))
	world.offers.append(world._make_offer("overtime"))
	world.drain_events()
	return world

func _key(action: Dictionary) -> String:
	var ids: Array=action.get("ids",[]).duplicate()
	ids.sort()
	return str([action.kind,ids,action.get("group",-1),action.get("person",-1),action.get("tool",-1),action.get("offer",-1)])

func _checkpoint_coverage() -> void:
	var world := _world()
	var generated: Dictionary=Actions.generate(world,0,world.config.rules.bot,-1)
	var expected := {}
	var intents := {}
	for action in generated.actions:
		expected[_key(action)]=true
		intents[str(action.get("intent",action.kind))]=true
	check(generated.complete and intents.has("recruitment") and intents.has("coffee") and intents.has("buy")
		and intents.has("slack"),"夹具实际同时提供招聘、升级、摸鱼和公开购牌，不靠模板预选路线")
	var original := var_to_bytes([world.cards,world.groups,world.tasks,world._rng.state,world.time])
	var state := {}
	var observed := {}
	var valid := {"score":true,"binding":true,"clock":true,"legal":true}
	var status := {}
	var count := 0
	for step in expected.size()+4:
		status=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],func(plan):
			observed[_key(plan.commands[0].action)]=true
			valid.binding=valid.binding and plan.commands[0].has("binding")
			valid.clock=valid.clock and is_zero_approx(float(plan.commands[0].at)) and plan.commands.size()==1
			var actual := world.fork_for_bot(830)
			valid.legal=Actions.apply_search_action(actual,0,plan.commands[0].action) and valid.legal
			actual.advance_for_search(float(plan.elapsed),-1)
			var fresh: Dictionary=Evaluation.new().evaluate_current(actual,0,world.config.rules.bot,-1,plan.next_actions)
			valid.score=valid.score and fresh.complete and is_equal_approx(float(fresh.score),float(plan.evaluation.score)),
			Callable(),{"planner_state":state,"checkpoint_limit":1,"depth_limit":1})
		count+=int(status.plans)
		check(int(status.plans)<=1,"单次访问至多发布一个完整前缀，其他候选可以获得下一次服务")
		if status.complete: break
	check(status.get("complete",false) and not status.get("pending",true)
		and expected.keys().all(func(key):return observed.has(key)),"逐次恢复后覆盖全部普通合法根动作，任何卡种都没有专用遗漏或优待")
	check(state.planner.nodes[0].parent==-1 and state.planner.nodes.filter(func(node):return node.parent==-1).size()==1,
		"恢复checkpoint沿用同一根和前缀缓存，不反复重新初始化")
	check(count>=expected.size() and int(status.root_serviced)>=expected.size(),"覆盖统计来自实际完成评价，不把初始化候选算作服务完成")
	check(valid.score and valid.binding and valid.clock and valid.legal,"所有根分支都使用真实命令、绑定、相同行动时钟及统一ETA评分")
	check(original==var_to_bytes([world.cards,world.groups,world.tasks,world._rng.state,world.time]),"分配搜索预算不修改真实牌局或随机流")

func _resume_after_cancel() -> void:
	var world := _world()
	var state := {}
	var first: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),
		{"planner_state":state,"checkpoint_limit":1,"depth_limit":1})
	var nodes := int(first.nodes)
	var paused: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),func():return true,
		{"planner_state":state,"checkpoint_limit":1,"depth_limit":1})
	check(paused.examined==0 and state.planner.nodes.size()==nodes,"取消请求不执行下一分支，也不丢弃已有完整前缀")
	var resumed: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,3.0],Callable(),Callable(),
		{"planner_state":state,"checkpoint_limit":1,"depth_limit":1})
	check(resumed.plans==1 and int(resumed.nodes)>nodes,"取消后可以继续尚未服务的根动作，已完成前缀不会重复发布")
