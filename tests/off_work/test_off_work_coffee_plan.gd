# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Planner = preload("res://engine/off_work_coffee_plan.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Clock = preload("res://engine/off_work_progress_clock.gd")

func _initialize() -> void:
	_plan_priority()
	_frozen_forecast()
	_action_recipes()
	finish()

func _plan_priority() -> void:
	var config := OffWorkConfig.new()
	var people := [{"id":11,"kind":"employee"},{"id":12,"kind":"employee"}]
	var before := var_to_bytes([people,config.rules,config.roles,config.cards])
	var plan: Dictionary = Planner.plan(config,people,7)
	check(plan.coffee_used==7 and plan.upgrades.size()==1 and plan.upgrades[0].person==11,
		"同级按输入顺序，虚拟升级后继续优先升级同一人")
	var upgrade: Dictionary = plan.upgrades[0]
	check(upgrade.from_type=="employee" and upgrade.to_type=="work_emperor" and upgrade.cost==7,
		"一轮明确记录原等级、最终等级和总咖啡成本")
	check(upgrade.steps==[{"from_type":"employee","to_type":"grinder","cost":1},
		{"from_type":"grinder","to_type":"workaholic","cost":2},
		{"from_type":"workaholic","to_type":"work_emperor","cost":4}],
		"跨级结果仍保留每次逐级升级的事件历史")
	check(var_to_bytes([people,config.rules,config.roles,config.cards])==before,
		"纯规划不写人员输入和配置")
	var mixed := [{"id":10,"kind":"employee"},{"id":20,"kind":"grinder"},
		{"id":30,"kind":"workaholic"},{"id":40,"kind":"grinder"}]
	plan=Planner.plan(config,mixed,7)
	check(plan.coffee_used==7 and plan.upgrades.map(func(row):return row.person)==[30,20,10],
		"每步优先最高可负担等级，同级仍保留原输入顺序")
	check(plan.upgrades.map(func(row):return row.to_type)==["work_emperor","workaholic","grinder"],
		"分配完高等级配方后，剩余咖啡可用于较低等级")
	plan=Planner.plan(config,[{"id":30,"kind":"workaholic"},{"id":10,"kind":"employee"}],3)
	check(plan.upgrades.size()==1 and plan.upgrades[0].person==10 and plan.upgrades[0].to_type=="workaholic",
		"最高等级买不起下一阶段时，选择可升级的较低等级")
	check(Planner.plan(config,people,0).upgrades.is_empty() and Planner.plan(config,people,-5).coffee_used==0,
		"没有可用咖啡不产生升级或负消耗")
	plan=Planner.plan(config,[{"id":1,"kind":"work_emperor"},{"id":2,"kind":"leader"}],99)
	check(plan.upgrades.is_empty() and plan.coffee_used==0, "没有升级路径的人员不耗咖啡")
	config.rules.coffee.upgrades.employee.cost=2
	config.rules.coffee.upgrades.grinder.cost=3
	config.rules.coffee.upgrades.workaholic.cost=5
	plan=Planner.plan(config,people,10)
	check(plan.upgrades[0].to_type=="work_emperor" and plan.upgrades[0].cost==10,
		"规划完全服从当前卡表成本，不固定写死默认配方")

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":200}]
	config.rules.initial.money=0
	config.rules.conveyor.interval_seconds=1000.0
	var world := OffWorkState.new(config)
	world.new_game(442)
	world.offers.clear()
	return world

func _frozen_forecast() -> void:
	var world := _world()
	var group := world.create_group(0)
	var first := world.add_card("employee",0,group)
	var second := world.add_card("grinder",0,group)
	world.tasks[first]={"kind":"coffee","group":group,"from_type":"employee","to_type":"workaholic",
		"total":4.0,"progress":0.75,"coffee_ids":[],"batch_owner":first,"batch_members":[first,second]}
	world.tasks[second]={"kind":"coffee","group":group,"from_type":"grinder","to_type":"workaholic",
		"total":4.0,"progress":0.0,"coffee_ids":[],"batch_owner":first}
	for _index in 20: world.add_card("coffee",0,group)
	var evaluator := Evaluation.new()
	var before := var_to_bytes([world.cards,world.groups,world.tasks,world._rng.state])
	var prepared: Dictionary = evaluator._prepare_evaluation(world,0,world.config.rules.bot,-1,[0.0,0.0])
	var events: Array = prepared.models[0].events.filter(func(event):return event.kind=="worker" and event.id in [first,second])
	check(events.size()==2 and events.all(func(event):return event.unit.role=="workaholic"),
		"BOT只兑现已冻结最终等级，不把后来咖啡算进当前轮")
	check(events.all(func(event):return is_equal_approx(event.at,1.0+world.config.rules.bot.think_seconds)),
		"同批所有人读取主持任务的唯一剩余时钟")
	check(is_equal_approx(Clock.remaining(world,first,"coffee",0.75),1.0)
		and is_equal_approx(Clock.remaining(world,second,"coffee",0.0),1.0),
		"成员自身旧progress不同也不让显示时钟分叉")
	check(var_to_bytes([world.cards,world.groups,world.tasks,world._rng.state])==before,
		"BOT建模和时钟读取不修改冻结批次或真实随机流")
	world.tasks[first].erase("batch_owner")
	world.tasks[first].erase("batch_members")
	check(is_equal_approx(Clock.remaining(world,first,"coffee",0.75),1.0),
		"旧单人阶段快照继续使用其记录的耗时和进度")
	var model: Dictionary = prepared.models[0]
	var person := {"id":first,"kind":"employee","to":"work_emperor","cost":7,"seconds":1.0}
	var projected: Dictionary = evaluator._coffee(model,person,0.0)
	var future: Array = projected.events.filter(func(event):return event.kind=="worker" and event.id==first)
	check(future.size()==1 and future[0].unit.role=="work_emperor" and future[0].lag==1.0+world.config.rules.bot.think_seconds,
		"预测使用共享规划器按完整配方得到最终等级且只付一轮时间")

func _action_recipes() -> void:
	var world := _world()
	var person: int = world._owner_type(0,"employee")[0]
	for _index in 7: world.add_card("coffee",0)
	var generated: Dictionary = Actions.generate(world,0,world.config.rules.bot,-1)
	var recipes: Array = generated.actions.filter(func(action):return action.kind=="move" \
		and action.get("intent","")=="coffee" and action.get("person",-1)==person)
	var counts: Array = recipes.map(func(action):return action.ids.size()-1)
	check(generated.complete and counts.has(1) and counts.has(7),
		"共用规划器后保留原有下一等级/全部可达等级的合法动作")
