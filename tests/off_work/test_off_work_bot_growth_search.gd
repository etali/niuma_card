# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const GrowthSearch = preload("res://engine/off_work_bot_growth_search.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_incumbent_attack_is_not_a_macro_attack()
	_future_funding_requires_wait()
	_public_boss_is_unique()
	finish()

func _world(funds := 10, with_boss := true) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":120}]
	config.rules.initial.money = funds
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 1000.0
	config.rules.recruitment.cost_per_employee = 5
	config.rules.recruitment.seconds = 10.0
	config.rules.strike.flight_seconds = 0.0
	config.rules.strike.duration_seconds = 30.0
	config.rules.bot.think_seconds = 6.0
	config.rules.bot.evaluation_max_seconds = 120.0
	var world := OffWorkState.new(config)
	world.new_game(814)
	world.offers.clear()
	if with_boss: world.add_card("boss",0)
	return world

func _base(world: OffWorkState, clock: Array = [0.0,3.0]) -> Dictionary:
	var value: Dictionary = Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,clock)
	value["evaluation_mode"] = "current"
	return value

func _refine(world: OffWorkState, base: Dictionary) -> Dictionary:
	var result := {}
	var status: Dictionary = GrowthSearch.refine(world,0,world.config.rules.bot,-1,base,
		func(action,value,plan): result.merge({"action":action,"value":value,"plan":plan},true))
	result["status"] = status
	return result

func _incumbent_attack_is_not_a_macro_attack() -> void:
	var world := _world()
	var strike := world.add_card("strike",0)
	var base := _base(world)
	var trial := world.fork_for_bot(814)
	var enemy_group: int = trial.cards[trial._owner_type(1,"employee")[0]].group
	check(trial.activate(strike,enemy_group), "普通incumbent先通过真实规则罢工对手")
	trial.advance(3.0)
	var incumbent := _base(trial,[3.0,0.0])
	var evaluator := Evaluation.new()
	for forecast in incumbent.detail.sides: evaluator._offset_forecast(forecast,3.0)
	incumbent.score = 1000.0 * evaluator._race(incumbent.detail.sides,0)
	incumbent.detail.sides[0].required_actions += 1
	check(float(incumbent.detail.sides[1].eta)>float(base.detail.sides[1].eta),
		"夹具中的普通根动作确实改变了对方完工时间")
	var refined := _refine(world,incumbent)
	if not need(refined.status.choices==1, "招聘宏计划在同一ETA尺度下优于真实罢工incumbent"): return
	check(float(refined.value.detail.sides[1].eta)<=float(base.detail.sides[1].eta)+1e-8,
		"未发罢工的招聘宏计划不能继承普通incumbent给对手的停工")
	check(not refined.plan.commands.any(func(command): return command.action.kind=="activate" and int(command.action.get("tool",-1))==strike),
		"获选增长计划自身没有夹带罢工操作")
	check(float(refined.plan.commands[0].at)==0.0 and refined.action==refined.plan.commands[0].action,
		"当前可执行的宏方案直接发布真实首命令，不把其收益挂到wait")
	var actual := world.fork_for_bot(815)
	check(Actions.apply_action(actual,0,refined.action) and not actual.recruitment.is_empty(),
		"返回的首命令能在原局面正式支付并启动招聘")
	check(refined.value.score>incumbent.score, "方案确实超过给定普通incumbent，而非只超过原地不动")

func _future_funding_requires_wait() -> void:
	var world := _world(0)
	var result := _refine(world,_base(world))
	if not need(result.status.choices==1, "无启动现金时识别工资到账后的真实招聘增长"): return
	check(result.action.kind=="wait" and float(result.plan.commands[0].at)>0.0,
		"未来工资才付得起的首命令，当前只能选择等待")
	var actual := world.fork_for_bot(816)
	check(actual.available_money(0)<world.config.integer("recruitment","cost_per_employee"),
		"当前没有足够资金，不能提前搬入不存在的钱")
	actual.advance(float(result.plan.commands[0].at))
	check(Actions.apply_action(actual,0,result.plan.commands[0].action) and not actual.recruitment.is_empty(),
		"等到证据中的真实行动槽后才可支付并开始招聘")

func _public_boss_is_unique() -> void:
	var world := _world(20,false)
	var quote: Dictionary = world._make_offer("boss")
	world.offers = [quote]
	var result := _refine(world,_base(world))
	if not need(result.status.choices==1, "公开唯一老板有足够资金时可成为真实增长首购"): return
	check(result.action.kind=="buy" and int(result.action.offer)==int(quote.id),
		"宏计划发布当前可见老板的真实购买")
	var own: Dictionary = result.value.detail.sides[0].forecast_purchases
	var enemy: Dictionary = result.value.detail.sides[1].forecast_purchases
	check(own.has(quote.id) and not enemy.has(quote.id), "双方预测不能共享唯一的老板报价")
	var actual := world.fork_for_bot(817)
	check(Actions.apply_action(actual,0,result.action) and actual.buy(int(quote.id),1)<0,
		"规则重放确认己方先买后，对方已无法再买同一报价")
	world = _world(0,false)
	quote = world._make_offer("boss")
	world.offers = [quote]
	var cash := world.add_card("money",1)
	world.cards[cash].amount = 30
	result = _refine(world,_base(world))
	check(result.status.sides_evaluated[0]>0 and result.status.sides_evaluated[1]>0,
		"竞争用例确实为双方执行了完整招聘续接")
	check(result.status.choices==0,
		"对方先有钱买走唯一老板时，不能奖励己方稍后购买同一老板的增长")
