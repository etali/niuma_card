# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Bot = preload("res://engine/off_work_bot.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_long_and_short_returns()
	_wages_finance_recruitment()
	_deadline_and_cancellation()
	_live_behavior()
	finish()

# These are in-memory scenario rules, not replacements for the game's card
# table. Equal wages isolate productivity from the final outsource shortcut.
func _world(work := 400, boss := true, slack := true, funds := 10) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":work}]
	config.rules.initial.money = funds
	config.rules.bot.think_seconds = 2.0
	config.rules.bot.evaluation_max_seconds = 120.0
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 1000.0
	config.rules.recruitment.cost_per_employee = 5
	config.rules.recruitment.seconds = 10.0
	config.rules.slack.seconds = 6.0
	config.rules.slack.coffee_per_person = 1
	var capacity := 1
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		config.roles[kind].work_capacity = capacity
		config.roles[kind].work_income_multiplier = 1
		capacity *= 2
	var world := OffWorkState.new(config)
	world.new_game(814)
	world.offers.clear()
	if boss: world.add_card("boss",0)
	if slack:
		var tool := world.add_card("slack",0)
		var leader := world.add_card("leader",0)
		# Starting from an operating line checks its continuing value directly;
		# assembling and buying are covered by the ordinary production tests.
		world.move_cards([leader],int(world.cards[tool].group))
	return world

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := []
	for key in OffWorkState.WORLD_FIELDS: fields.append(world.get(key))
	return var_to_bytes([fields,world._rng.state,world._events,world.config.rules,world.config.roles,world.config.cards])

func _project(world: OffWorkState) -> Dictionary:
	# A fixed expansion count makes this economic comparison reproducible.
	# It is independent of the real-budget BOT acceptance test below; every
	# ordinary legal action remains available, with no economic-root filter.
	var before := _snapshot(world)
	var clock := [0.0,float(world.config.rules.bot.think_seconds)*0.5]
	var baseline: Dictionary=Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,clock)
	var best := {"eta":float(baseline.detail.sides[0].eta),"commands":[],"elapsed":0.0,"events":[]}
	var status: Dictionary=Continuations.visit(world,0,world.config.rules.bot,-1,clock,func(plan):
		var value: Dictionary=plan.evaluation
		if not value.get("complete",false): return
		var eta: float=float(plan.elapsed) if value.detail.get("terminal",false) and int(value.detail.get("winner",-1))==0 else INF
		if not value.detail.get("terminal",false): eta=float(plan.elapsed)+float(value.detail.sides[0].eta)
		if eta<float(best.eta)-1e-8:
			best.merge({"eta":eta,"commands":plan.commands.duplicate(true),"elapsed":float(plan.elapsed),
				"next_actions":plan.next_actions.duplicate(),"evaluation":value.duplicate(true)},true),
		Callable(),{"expansion_limit":160,"depth_limit":10})
	check(status.examined>0 and status.plans>0,"统一合法动作搜索完成真实前缀评价，非空基线比较")
	check(before==_snapshot(world),"长期搜索不改真实规则、参数、世界或随机流")
	print("CONTINUATION_ETA ",JSON.stringify({"work":world.work_count(0),"baseline":baseline.detail.sides[0].eta,
		"best":best.eta,"commands":best.commands.size(),"status":status}))
	if not best.commands.is_empty(): _replay(world,best)
	return best.merged({"baseline":baseline})

func _long_and_short_returns() -> void:
	for work in [400,3]:
		var world := _world(work)
		world.config.rules.bot.evaluation_max_seconds=1800.0
		var projected := _project(world)
		var plain_eta: float=projected.baseline.detail.sides[0].eta
		if work==400:
			check(float(projected.eta)<plain_eta-1e-6,"长期工作下真实扩产前缀缩短同一根时钟的清空时间")
		else:
			check(is_equal_approx(float(projected.eta),plain_eta),"只剩一个工作批次时不为建立产线虚增收益")
	var cheap := _world(400,true,false,10)
	var expensive := _world(400,true,false,10)
	cheap.config.rules.bot.evaluation_max_seconds=1800.0
	expensive.config.rules.bot.evaluation_max_seconds=1800.0
	expensive.config.rules.recruitment.cost_per_employee=5000
	var cheap_value := _project(cheap)
	var expensive_value := _project(expensive)
	check(float(cheap_value.eta)<float(expensive_value.eta),"真实招聘价格会改变搜索到的完工收益，付不起的老板没有资产加分")

func _wage_world(with_coffee := true) -> OffWorkState:
	var world := _world(400,true,with_coffee,10)
	var wages := 1
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		world.config.roles[kind].work_capacity = 1
		world.config.roles[kind].work_income_multiplier = wages
		wages *= 2
	world.config.rules.bot.evaluation_max_seconds = 1800.0
	return world

func _wages_finance_recruitment() -> void:
	var combined := _wage_world()
	var recruitment := _wage_world(false)
	var value := _project(combined)
	var recruitment_value := _project(recruitment)
	# Owning an optional line must not itself win the comparison. Different
	# finite search trees may discover equally good (or different) routes;
	# requiring coffee's tree to be strictly better would turn its use into
	# an objective. The paired real-wage certificate lives in
	# test_off_work_bot_wage_reinvestment.gd and checks its marginal return.
	check(is_equal_approx(float(value.baseline.detail.sides[0].eta),float(recruitment_value.baseline.detail.sides[0].eta)),
		"未兑现的咖啡库存和产线不会独立获得工资或工作收益加分")
	check(float(value.eta)<float(value.baseline.detail.sides[0].eta),"间接生产力收益来自实际前缀，优于只维持现状的物理尾部")

func _live_behavior() -> void:
	# Judge investment by actual completion/output against the identical
	# passive rule-state control, not a quota of hires or upgrades by 60 s.
	# Different scenarios can rationally choose different investment sequences.
	_observe_live(_wage_world(),"wage_recruitment")
	var coffee := _world(400,false,true,0)
	coffee.config.rules.bot.evaluation_max_seconds=1800.0
	_observe_live(coffee,"coffee_productivity")

func _observe_live(world: OffWorkState, scenario: String) -> Dictionary:
	world.config.rules.bot.think_seconds = 6.0
	world.drain_events()
	var control := world.fork_for_bot(815)
	control._bot_branch=false
	control._rng.state=world._rng.state
	var bot := Bot.new(world,0)
	check(OffWorkConfig.decision_budget_ms(bot._policy)==700,"真实BOT在标准700ms内给全部合法根动作分配预算")
	var evidence := {"published_growth":0,"applied":true,"within_budget":true,"recruitment_complete":0,"coffee_upgrade":0}
	for step in 60:
		if world.winner>=0: break
		var action: Dictionary = bot.decide_action(-1,Callable(),true,func(_action,report):
			var chain: Dictionary = report.get("evaluation",{}).get("sides",[{},{}])[0].get("production_chain",{})
			if chain.get("kind","")=="legal_continuation": evidence.published_growth+=1)
		var selected: Dictionary = bot.last_decision.get("evaluation",{}).get("sides",[{},{}])[0].get("production_chain",{})
		print("GROWTH_LIVE ",JSON.stringify({"scenario":scenario,"time":world.time,"action":action.get("intent",action.kind),
			"chain":selected.get("kind",""),"root_candidates":bot.last_decision.get("root_candidates",0),
			"production_serviced":bot.last_decision.get("root_production_serviced",0),
			"production_complete":bot.last_decision.get("root_production_complete",0),
			"growth_search":bot.last_decision.get("root_growth",{}),
			"elapsed_ms":bot.last_decision.get("elapsed_us",0)/1000.0}))
		evidence.within_budget=evidence.within_budget and not bot.last_decision.get("overrun",false)
		evidence.applied = bot.commit_action(action,bot.last_decision) and evidence.applied
		world.advance(6.0)
		control.advance(world.time-control.time)
		world.offers.clear()
		for event in world.drain_events():
			if int(event.get("owner",-1))==0 and event.kind in ["recruitment_complete","coffee_upgrade"]:
				evidence[event.kind]+=1
	print("GROWTH_LIVE_TOTALS ",JSON.stringify(evidence.merged({"scenario":scenario,"work":world.work_count(0),
		"control_work":control.work_count(0),"winner":world.winner,"time":world.time})))
	check(evidence.applied and evidence.within_budget,"真实BOT命令全部合法，并始终遵守原700ms预算")
	check(is_equal_approx(world.time,control.time) and world.work_count(0)<control.work_count(0),
		"投资在实际完工或360秒同钟观察点产生净工作收益，超过相同初始世界仅自然工作的对照")
	check(evidence.published_growth>0,"长期合法前缀实际进入已发布完工比较，测试没有绕过统一续搜")
	return evidence

func _deadline_and_cancellation() -> void:
	var world := _world()
	var rows := []
	var result: Dictionary = Continuations.visit(world,0,world.config.rules.bot,Time.get_ticks_usec()-1,[0.0,0.0],func(plan): rows.append(plan))
	check(not result.complete and rows.is_empty(),"已过期预算不能发布未执行的增长计划")
	result = Continuations.visit(world,0,world.config.rules.bot,-1,[0.0,0.0],func(plan): rows.append(plan),func(): return true)
	check(not result.complete and rows.is_empty(),"取消请求传到持续生产前瞻")
	var ordinary: Dictionary = Evaluation.new().evaluate(world,0,world.config.rules.bot,-1,[0.0,0.0],false)
	var partial: Dictionary = Evaluation.new().extend_production(world,0,world.config.rules.bot,Time.get_ticks_usec()-1,[0.0,0.0],ordinary)
	check(partial.complete and partial.score==ordinary.score and partial.detail==ordinary.detail,
		"增长预算到期保留已完成的普通评价，不发布半截未来收益")

func _replay(world: OffWorkState, plan: Dictionary) -> void:
	var actual := world.fork_for_bot(814)
	actual._bot_branch=false
	actual.drain_events()
	var previous := -INF
	var legal := true
	for command in plan.commands:
		legal=legal and float(command.at)>=previous+float(world.config.rules.bot.think_seconds)-1e-8
		actual.advance(world.time+float(command.at)-actual.time)
		legal=Actions.apply_action(actual,0,command.action) and legal
		legal=legal and actual.money(0)>=actual.reserved_money(0)
		previous=float(command.at)
	actual.advance(world.time+float(plan.elapsed)-actual.time)
	check(legal,"胜出前缀逐条经真实规则重放，操作占用时间且资金没有透支")
	var fresh: Dictionary=Evaluation.new().evaluate_current(actual,0,world.config.rules.bot,-1,plan.next_actions)
	var eta: float=float(plan.elapsed) if fresh.detail.get("terminal",false) and int(fresh.detail.get("winner",-1))==0 else INF
	if not fresh.detail.get("terminal",false): eta=float(plan.elapsed)+float(fresh.detail.sides[0].eta)
	check(fresh.complete and is_equal_approx(eta,float(plan.eta)),"独立重放后的尾ETA加真实前缀耗时精确等于所比较的根时钟ETA")
