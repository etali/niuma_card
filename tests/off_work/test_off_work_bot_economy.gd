# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Economy = preload("res://engine/off_work_bot_economy.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
class InterruptedFunding extends Evaluation:
	func _forecast(model: Dictionary, horizon: float = -1.0) -> Dictionary:
		if horizon>=0.0:
			_complete=false
			return {"eta":0.0,"cash":0.0,"required_actions":0}
		return super._forecast(model,horizon)

func _initialize() -> void: _run.call_deferred()

func _world(owned := true) -> OffWorkState:
	var config := OffWorkConfig.new()
	# The replay below uses explicit 2.8-second purchase/return opportunities.
	config.rules.bot.think_seconds = 2.8
	config.rules.initial.groups=[{"employee":1,"work":120}]
	config.rules.initial.money=12
	var world := OffWorkState.new(config)
	world.new_game(91823)
	world.offers.clear()
	if owned: world.add_card("outsource",0)
	return world

func _value(world: OffWorkState) -> Dictionary:
	return Evaluation.new().evaluate(world,0,world.config.rules.bot,-1,[2.8,2.8])

func _run() -> void:
	var world := _world()
	world.config.rules.conveyor.pool={"employee":1}
	var original := var_to_bytes([world.cards,world.groups,world.time,world._rng.state])
	var baseline := _value(world)
	check(not InterruptedFunding.new().evaluate(world,0,world.config.rules.bot).complete,"最终付款预测中途截止立即撤回，不能读取未完成结果或发布半份估值")
	check(baseline.complete and baseline.detail.sides[0].has("cashout"),"已有外包工具可将后续真实工资用于最终付款")
	check(not baseline.detail.sides[0].cashout.future_supply and baseline.detail.sides[0].cashout.tool_price==0.0,"已持有工具不重复付购买费或随机到货等待")
	check(var_to_bytes([world.cards,world.groups,world.time,world._rng.state])==original,"经济预测保持真实牌桌与随机流只读")
	var person: int = world._owner_type(0,"employee")[0]
	world.add_card("coffee",0)
	var with_recipe := _value(world)
	check(with_recipe.detail.sides[0].public_investment.get("kind")=="coffee","默认各级相同产能下，升级的实际工资收益仍被统一完工模型识别")
	check(with_recipe.detail.sides[0].eta<baseline.detail.sides[0].eta-100.0,"增加工资通过真实外包费用缩短完工，不是人物等级附加分")
	var coffee: Dictionary = {}
	for action in Actions.generate(world,0,world.config.rules.bot,-1).actions:
		if action.get("intent")=="coffee": coffee=action; break
	check(not coffee.is_empty() and Actions.apply_action(world,0,coffee),"按真实命令开始升级")
	var upgraded := _value(world)
	var closing: Dictionary = upgraded.detail.sides[0].cashout
	world.advance(5.6)
	var workplace: int = world.cards[world._owner_type(0,"work")[0]].group
	check(world.cards[person].type=="grinder" and world.move_cards([person],workplace)>=0,"升级完成后在真实下一行动时隙返岗")
	world.advance(float(closing.funding_at)-world.time)
	var ids: Array = world._owner_type(0,"outsource")+world._owner_type(0,"work")+world._owner_type(0,"money")
	check(world.available_money(0)>=world.work_count(0),"预测最终付款时真实现金足以覆盖每份剩余工作")
	check(world.move_cards(ids,-1)>=0 and not world.outsourcing.is_empty(),"预测最终批次可以通过真实组堆启动")
	world.advance(world.config.rules.outsource.seconds)
	check(world.winner==0 and absf(world.time-float(upgraded.detail.sides[0].eta))<0.0001,"工资、等待返岗、全额付款及外包读条与真实结局时间一致")
	var market := _world(false)
	var hidden_before := var_to_bytes([market.offers,market._rng.state])
	var stochastic := _value(market)
	var future: Dictionary = stochastic.detail.sides[0].cashout
	check(future.future_supply and future.supply_wait>0.0 and future.tool_price==market.config.cards.outsource.price,"未知工具收取公开分布等待和完整购买价格，不能当作现成免费工具")
	check(stochastic.detail.sides[0].forecast_purchases.is_empty(),"统计市场估计不能伪造具体报价或抢购归属")
	check(var_to_bytes([market.offers,market._rng.state])==hidden_before,"供应估计不读写实际未来报价或消耗随机数")
	var normal := Economy.expected_supply_wait(market.config,"outsource")
	market.config.rules.conveyor.pool.outsource*=2
	check(Economy.expected_supply_wait(market.config,"outsource")<normal,"公开供应概率增加才会缩短预计到货等待")
	market.config.rules.conveyor.employee_every=1
	check(not is_finite(Economy.expected_supply_wait(market.config,"outsource")),"全部到货固定为员工时不能虚构外包供应")
	check(not _value(market).detail.sides[0].has("cashout"),"无外包工具也无供应时回到真实自然生产，不奖励无用途现金")
	var limited := _world()
	limited.config.cards.outsource.max_per_owner=1
	limited.config.rules.conveyor.pool={"outsource":1}
	limited.config.rules.conveyor.interval_seconds=1.0
	limited._credit(0,300)
	var tool: int = limited._owner_type(0,"outsource")[0]
	var batch: Array = [tool]+limited._owner_type(0,"money")+limited._owner_type(0,"work").slice(0,10)
	check(limited.move_cards(batch,-1)>=0,"按真实规则建立有限持有外包的首批次")
	limited.advance(10.0)
	limited.offers.clear()
	var waiting := _value(limited)
	check(not limited.can_acquire("outsource",0) and limited.cards[tool].status=="recovering","已有唯一外包工具仍在真实冷却")
	check(not waiting.detail.sides[0].cashout.future_supply and waiting.detail.sides[0].cashout.funding_at>=18.0,"供应预测不能买第二张来绕过真实持有上限和现有冷却")
	_cashout_clock(100,100,false,0.0,0.0)
	_cashout_clock(50,50,true,1.0,30.0)
	_cashout_clock(50,50,true,1.25,30.25)
	finish()

func _cashout_clock(work: int, cash: int, purchase: bool, first: float, expected: float) -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":work}]
	config.rules.initial.money=cash
	config.rules.bot.think_seconds=1.0
	config.rules.conveyor.pool={"employee":1}
	var world := OffWorkState.new(config)
	world.new_game(91777)
	world.offers.clear()
	if purchase:
		world.offers=[world._make_offer("outsource")]
		check(world.buy(int(world.offers[0].id),0)>=0 and world.available_money(0)==cash-6,
			"外包时钟回归先按真实报价支付工具费用")
	else:
		world.add_card("outsource",0)
	world.offers.clear()
	var original := var_to_bytes([world.cards,world.groups,world._rng.state])
	var evaluator := Evaluation.new()
	evaluator._config=config
	evaluator._period=1.0
	evaluator._next_actions=[first,first]
	evaluator._base_cycle=10.0
	var model: Dictionary = evaluator._model(world,0,evaluator._index(world))
	var forecast: Dictionary = evaluator._finish_forecast(model)
	check(forecast.has("cashout") and is_equal_approx(float(forecast.cashout.funding_at),expected),
		"现金在行动时刻恰好足额时立即付款，不因连续二分误差多收一次行动；错位时钟仍等合法时隙")
	check(var_to_bytes([world.cards,world.groups,world._rng.state])==original,"付款时钟预测只读")
	if not forecast.has("cashout"): return
	if purchase:
		world.advance(29.999)
		check(world.available_money(0)<world.work_count(0),"足额时刻前的真实现金不足，不能通过扩大误差容限提前外包")
	world.advance(float(forecast.cashout.funding_at)-world.time)
	check(world.available_money(0)>=world.work_count(0),"预测时隙真实现金覆盖全部剩余工作")
	check(world.move_cards(world._owner_type(0,"outsource")+world._owner_type(0,"work")+world._owner_type(0,"money"),-1)>=0,
		"边界时刻的外包可以真实提交")
	world.advance(float(forecast.eta)-world.time-0.001)
	check(world.winner<0 and world.work_count(0)>0,"预计结算前仍未实际完成")
	world.advance(0.001)
	check(world.winner==0 and is_equal_approx(world.time,float(forecast.eta)),"边界付款的预计完工时刻与真实结局一致")
