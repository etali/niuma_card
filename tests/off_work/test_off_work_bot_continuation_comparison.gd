# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const GrowthSearch = preload("res://engine/off_work_bot_growth_search.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Cursor = preload("res://engine/off_work_bot_plan_cursor.gd")

func _initialize() -> void:
	_actual_strike_has_one_value()
	_joint_purchases_belong_to_their_actor()
	_equal_eta_prefers_fewer_future_commands()
	finish()

func _world(groups: Array = [{"employee":3,"work":120}], funds := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=groups.duplicate(true)
	config.rules.initial.money=funds
	config.cards.work.work_seconds=20.0
	config.rules.strike.flight_seconds=0.0
	config.rules.strike.duration_seconds=30.0
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.conveyor.pool={"employee":1}
	config.rules.bot.think_seconds=6.0
	config.rules.bot.evaluation_max_seconds=180.0
	var world := OffWorkState.new(config)
	world.new_game(3921)
	world.offers.clear()
	return world

func _wait() -> Dictionary:
	return {"kind":"wait","intent":"wait"}

func _prefix(world: OffWorkState, steps: Array, elapsed: float) -> Dictionary:
	# Use the production cursor and actual rules, without running any search.
	# Both timing and purchase evidence are the same objects the planner emits.
	var builder := Cursor.new()
	builder.source=world
	builder.owner=0
	builder.policy=world.config.rules.bot
	builder.period=6.0
	builder.horizon=180.0
	builder.next_actions=[0.0,3.0]
	var cursor: Dictionary=builder._cursor(world)
	for step in steps:
		var applied := false
		if int(step.seat)==0:
			cursor.next=float(step.at)
			applied=builder._command(cursor,step.action)
		else:
			applied=builder._reply(cursor,int(step.seat),step.action,float(step.at))
		if not need(applied,"比较夹具的每条前缀命令由真实规则执行"): return {}
	if not need(builder._advance(cursor,elapsed),"比较夹具按共同截止时刻推进真实状态"): return {}
	var plan: Dictionary=builder._plan(cursor,"legal_continuation")
	plan.evaluation=Evaluation.new().evaluate_current(plan.world,0,world.config.rules.bot,-1,plan.next_actions)
	if not need(plan.evaluation.complete and not plan.evaluation.detail.terminal,"前缀尾部得到完整的公共ETA评价"): return {}
	return plan

func _root_value(plan: Dictionary) -> Dictionary:
	var evaluator := Evaluation.new()
	var value: Dictionary=plan.evaluation.duplicate(true)
	for forecast in value.detail.sides: evaluator._offset_forecast(forecast,float(plan.elapsed))
	value.score=1000.0*evaluator._race(value.detail.sides,0)
	value.tie_score=int(value.detail.sides[1].required_actions)-int(value.detail.sides[0].required_actions)
	return value

func _comparison(world: OffWorkState, ordinary: Dictionary, joint := false) -> RefCounted:
	var run := GrowthSearch.Refinement.new()
	run.world=world
	run.owner=0
	run.policy=world.config.rules.bot
	run.ordinary=ordinary.duplicate(true)
	run.source_base=Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,[0.0,3.0])
	run.joint_prefixes=joint
	return run

func _actual_strike_has_one_value() -> void:
	var world := _world()
	var strike := world.add_card("strike",0)
	var target := int(world.cards[world._owner_type(1,"employee")[0]].group)
	var attack := {"kind":"activate","tool":strike,"group":target,"intent":"strike"}
	var plan := _prefix(world,[{"seat":0,"at":0.0,"action":attack}],3.0)
	if plan.is_empty(): return
	var ordinary := _root_value(plan)
	var run := _comparison(world,ordinary)
	check(float(ordinary.detail.sides[1].eta)>float(run.source_base.detail.sides[1].eta),
		"真实罢工前缀确实延后对手完工，夹具不是无效攻击")
	run._record(plan,0)
	if not need(run.rows[0].size()==1,"已执行罢工的完整前缀进入同一比较"): return
	var recorded: Dictionary=run._joint_value(run.rows[0][0])
	var incumbent: Dictionary=run._joint_value({"own":ordinary.detail.sides[0],"other":ordinary.detail.sides[1]},false)
	check(is_equal_approx(float(recorded.detail.sides[1].eta),float(incumbent.detail.sides[1].eta)),
		"同一真实罢工作为普通根或长期前缀时保留相同的敌方停工影响")
	check(is_equal_approx(float(recorded.score),float(incumbent.score)) and int(recorded.tie_score)==int(incumbent.tie_score),
		"同一已执行前缀不会因为比较入口不同而改变分数或剩余动作数")

func _joint_purchases_belong_to_their_actor() -> void:
	var world := _world([{"employee":1,"work":20}],40)
	var own_quote: Dictionary=world._make_offer("coffee")
	var other_quote: Dictionary=world._make_offer("employee")
	world.offers=[own_quote,other_quote]
	var plan := _prefix(world,[
		{"seat":0,"at":0.0,"action":{"kind":"buy","offer":own_quote.id,"intent":"buy"}},
		{"seat":1,"at":3.0,"action":{"kind":"buy","offer":other_quote.id,"intent":"buy"}}],6.0)
	if plan.is_empty(): return
	check(plan.purchases.size()==2 and int(plan.purchases[own_quote.id].owner)==0 \
		and int(plan.purchases[other_quote.id].owner)==1,"真实联合前缀确实记录双方各一次付费购买")
	check(plan.world.available_money(0)==40-int(own_quote.price) and plan.world.available_money(1)==40-int(other_quote.price),
		"双方购买均从实际规则状态扣款，没有免费获得预测中的卡")
	var run := _comparison(world,_root_value(plan),true)
	run._record(plan,0)
	if not need(run.rows[0].size()==1,"双方购买的联合前缀可以进入比较"): return
	var row: Dictionary=run.rows[0][0]
	check(row.own.forecast_purchases.has(own_quote.id) and not row.own.forecast_purchases.has(other_quote.id) \
		and row.other.forecast_purchases.has(other_quote.id) and not row.other.forecast_purchases.has(own_quote.id),
		"联合前缀购买证据按实际执行方分开，不把对手的报价记成己方资产")
	check(is_equal_approx(float(row.own.forecast_purchases[own_quote.id].at),0.0) \
		and is_equal_approx(float(row.other.forecast_purchases[other_quote.id].at),3.0),
		"购买时刻保持根时钟，不因尾部估值重复偏移")
	check(int(row.own.required_actions)==int(plan.evaluation.detail.sides[0].required_actions) \
		and int(row.other.required_actions)==int(plan.evaluation.detail.sides[1].required_actions)+1,
		"当前已提交首步不再计入未来动作，对手下一行动槽的购买仍需计入")

func _equal_eta_prefers_fewer_future_commands() -> void:
	# The active worker is busy until t=20. Feeding its ninth work card at
	# t=0 or t=6 reaches exactly the same state and finish time at t=12.
	# No card-specific preference is needed: only the remaining command count.
	var world := _world([{"employee":1,"work":8},{"work":1}])
	var target := int(world.cards[world._owner_type(0,"employee")[0]].group)
	var pending := -1
	for id in world._owner_type(0,"work"):
		if int(world.cards[id].group)!=target: pending=int(id)
	if not need(pending>=0,"等ETA夹具有尚未入组的真实待办工作"): return
	var move := {"kind":"move","ids":[pending],"group":target,"intent":"feed_work"}
	var now := _prefix(world,[{"seat":0,"at":0.0,"action":move},{"seat":0,"at":6.0,"action":_wait()}],12.0)
	var later := _prefix(world,[{"seat":0,"at":0.0,"action":_wait()},{"seat":0,"at":6.0,"action":move}],12.0)
	if now.is_empty() or later.is_empty(): return
	var first := _root_value(now)
	var deferred := _root_value(later)
	check(is_equal_approx(float(first.detail.sides[0].eta),float(deferred.detail.sides[0].eta)) \
		and is_equal_approx(float(first.detail.sides[1].eta),float(deferred.detail.sides[1].eta)),
		"即时完成与下一槽完成同一操作的真实前缀具有相同双方ETA")
	var run := _comparison(world,first)
	run._record(now,0)
	run._record(later,0)
	if not need(run.rows[0].size()==2,"即时方案和延后方案都经过同一比较入口"): return
	var now_value: Dictionary=run._joint_value(run.rows[0][0])
	var later_value: Dictionary=run._joint_value(run.rows[0][1])
	check(is_equal_approx(float(now_value.score),float(later_value.score)),"比较器不为当前操作额外增加ETA收益")
	check(int(later_value.detail.sides[0].required_actions)==int(now_value.detail.sides[0].required_actions)+1,
		"延后同一操作保留一条未来非等待命令，即时操作已经完成该责任")
	check(run._greater(now_value,later_value) and not run._greater(later_value,now_value),
		"同ETA时按更少未来非等待命令选当前执行，不依赖卡牌类型优先级")
