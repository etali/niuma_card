# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")

func _initialize() -> void:
	_spending_before_supply()
	_occupied_slots([54.0, 55.0], 56.0, 57.0)
	_occupied_slots([55.0], 54.0, 56.0)
	_later_planned_payment()
	finish()

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := {}
	for key in OffWorkState.WORLD_FIELDS: fields[key] = world.get(key)
	return var_to_bytes([fields, world._rng.state])

func _config() -> OffWorkConfig:
	var config := OffWorkConfig.new()
	config.rules.bot.think_seconds = 1.0
	config.rules.conveyor.interval_seconds = 2.0
	config.rules.conveyor.pool = {"employee":26, "outsource":1}
	config.cards.outsource.price = 6
	config.cards.strike.price = 7
	config.rules.outsource.cost_per_work = 1
	config.rules.outsource.seconds = 10.0
	config.rules.strike.flight_seconds = 0.0
	return config

func _evaluation(world: OffWorkState, first := 0.0) -> RefCounted:
	var result := Evaluation.new()
	result._config = world.config
	result._period = 1.0
	result._next_actions = [first, first]
	result._horizon = 1800.0
	result._base_cycle = 10.0
	return result

func _physical(world: OffWorkState, first := 1.0) -> Dictionary:
	var value: Dictionary = Evaluation.new().evaluate_current(world, 0, world.config.rules.bot, -1, [first, first])
	check(value.complete, "公开物理评价完整计算真实已付款资源")
	return value.detail.sides[0] if value.complete else {}

func _unknown_is_not_owned(world: OffWorkState) -> void:
	var before := _snapshot(world)
	var value: Dictionary = Evaluation.new().evaluate(world, 0, world.config.rules.bot, -1, [0.0, 0.0])
	check(value.complete and value.detail.sides.all(func(side): return not side.get("cashout", {}).get("future_supply", false)),
		"公开评价不把未知未来外包报价当作可执行资产")
	check(_snapshot(world) == before, "公开评价保持全部真实字段和随机流只读")

func _spending_before_supply() -> void:
	var config := _config()
	config.rules.initial.groups = [{"work_emperor":1, "work":6}]
	config.rules.initial.money = 12
	config.cards.work.work_seconds = 10.0
	config.roles.work_emperor.work_income_multiplier = 8
	config.rules.strike.duration_seconds = 45.0
	check(config.validate(), "晚到工资的外包回归使用合法公开规则")
	var world := OffWorkState.new(config)
	world.new_game(611)
	var own: int = world.cards[world._owner_type(0, "work")[0]].group
	var opponent: int = world.cards[world._owner_type(1, "work")[0]].group
	var person: int = world._owner_type(0, "work_emperor")[0]
	check(world.activate(world.add_card("strike", 1), own), "真实罢工使己方人员暂停45秒")
	world.offers = [{}, {}, {}, {}, {}, world._make_offer("strike")]
	var quote: int = world.offers[-1].id
	_unknown_is_not_owned(world)
	var evaluation := _evaluation(world)
	var before := _snapshot(world)
	var model: Dictionary = evaluation._model(world, 0, evaluation._index(world))
	model.events.append({"at":1.0, "kind":"spend", "amount":7.0, "action":true,
		"operation":"buy_strike", "offer":quote, "expires":12.0})
	model.events.append({"at":2.0, "kind":"commit_attack", "action":true,
		"operation":"attack", "after":"buy_strike", "lag":1.0})
	var unknown: Dictionary = evaluation._finish_forecast(model)
	check(_snapshot(world) == before and not unknown.has("cashout"),
		"保留已计划付款时也不附加不存在的未来外包工具")
	check(unknown.forecast_purchases.size() == 1 and unknown.forecast_purchases.has(quote),
		"报价归属只有真实公开的罢工采购，没有虚构外包报价")
	var strike := world.buy(quote, 0)
	check(strike >= 0 and world.available_money(0) == 5, "t0先按原计划花7元购买公开罢工")
	world.advance(1.0)
	check(world.activate(strike, opponent), "t1使用已购买罢工，购买与使用占两个时隙")
	world.advance(44.0)
	check(world.move_cards([person], own) >= 0, "t45按原计划执行真实返岗")
	world.advance(9.0)
	# Reveal an actual quote now. It granted no asset credit to any earlier
	# evaluation; from this observation onward normal purchase rules apply.
	world.offers = [{}, {}, {}, {}, {}, world._make_offer("outsource")]
	var outsource_quote: int = world.offers[-1].id
	check(world.available_money(0) == 5 and world.buy(outsource_quote, 0) < 0,
		"t54真实公开外包到货后，规则拒绝预支t55工资买6元工具")
	world.advance(1.0)
	check(world.available_money(0) == 13 and world.work_count(0) == 5, "t55真实工资入账后才具备工具与剩余工作资金")
	var tool := world.buy(outsource_quote, 0)
	check(tool >= 0 and world.available_money(0) == 7, "t55购买工具真实扣款6元一次")
	var observed_at := world.time
	var forecast := _physical(world)
	if not need(forecast.has("cashout"), "真实已购工具保留可执行的最终外包收益"): return
	check(not forecast.cashout.future_supply and is_equal_approx(float(forecast.cashout.funding_at), 1.0)
		and is_equal_approx(observed_at + float(forecast.eta), 66.0),
		"真实购买后另用t56行动格投料，公开预测t66完工")
	world.advance(1.0)
	check(world.move_cards([tool] + world._owner_type(0, "work") + world._owner_type(0, "money"), -1) >= 0
		and not world.outsourcing.is_empty(), "t56独立投料命令开始最后5份外包")
	world.advance(10.0)
	check(world.winner == 0 and world.time == 66.0 and is_equal_approx(world.time, observed_at + float(forecast.eta)),
		"已观察资源的预测与真实buy/activate/move/advance完工时间一致")
	check(world.money(0) == 2 and is_equal_approx(float(world.money(0)), float(forecast.cash)),
		"采购费与工作费各支付一次，实际与预测结余均2元")

func _occupied_slots(attacks: Array, purchase_at: float, funding_at: float) -> void:
	var config := _config()
	config.rules.initial.groups = [{"employee":1, "work":100}, {"employee":1, "work":100}]
	config.rules.initial.money = 220
	check(config.validate(), "命令占用回归使用真实合法双队列")
	var world := OffWorkState.new(config)
	world.new_game(612)
	world.offers.clear()
	_unknown_is_not_owned(world)
	var targets := []
	for gid in world.groups:
		if world.groups[gid].owner == 1 and not world.group_work_participants(gid).is_empty(): targets.append(gid)
	var tools := []
	for index in attacks.size(): tools.append(world.add_card("strike", 0))
	var quote := -1
	var bought := -1
	var forecast: Dictionary = {}
	var recorded_attack_times := []
	for tick in range(54, int(funding_at) + 1):
		world.advance(float(tick) - world.time)
		if tick == 54:
			world.offers = [{}, {}, {}, {}, {}, world._make_offer("outsource")]
			quote = world.offers[-1].id
		var commands := 0
		for index in attacks.size():
			if is_equal_approx(float(tick), float(attacks[index])):
				commands += 1
				check(world.activate(tools[index], targets[index]), "既定攻击在原时刻真实执行：" + str(tick))
				recorded_attack_times.append(world.time)
		if is_equal_approx(float(tick), purchase_at):
			commands += 1
			var before_cash := world.available_money(0)
			bought = world.buy(quote, 0)
			check(bought >= 0 and world.available_money(0) == before_cash - 6, "公开报价在空闲购买格真实扣除工具费一次")
			var before := _snapshot(world)
			var evaluation := _evaluation(world, 1.0)
			var model: Dictionary = evaluation._model(world, 0, evaluation._index(world))
			var remaining_attacks := 0
			for at in attacks:
				if float(at) <= world.time: continue
				remaining_attacks += 1
				model.events.append({"at":float(at) - world.time + 1.0, "kind":"commit_attack", "action":true,
					"operation":"planned_attack:%s" % at})
			forecast = evaluation._finish_forecast(model)
			check(_snapshot(world) == before, "已购工具查找空闲投料格不改变原世界与RNG")
			if not need(forecast.has("cashout"), "已有工具与原攻击时钟一起获得完整付款预测"): return
			check(not forecast.cashout.future_supply and is_equal_approx(world.time + float(forecast.cashout.funding_at), funding_at),
				"投料另占购买后的空闲格，不能和原攻击同格：" + str(attacks))
			check(forecast.required_actions == remaining_attacks + 1 and forecast.forecast_purchases.is_empty(),
				"只计尚未执行的原攻击和投料，不重复计已买工具或虚构报价")
		if is_equal_approx(float(tick), funding_at):
			commands += 1
			check(bought >= 0 and world.move_cards([bought] + world._owner_type(0, "work") + world._owner_type(0, "money"), -1) >= 0
				and not world.outsourcing.is_empty(), "购买后的空闲投料格真正启动外包")
		check(commands <= 1, "同一实际行动格不能同时攻击、购买或投料：" + str(tick))
	check(recorded_attack_times == attacks, "真实后续外包不移动已评估攻击时钟")
	world.advance(10.0)
	check(world.winner == 0 and is_equal_approx(world.time, funding_at + 10.0)
		and is_equal_approx(world.time, purchase_at + float(forecast.eta)), "双生产队列、原计划占用后真实完工与预测一致")
	check(is_equal_approx(float(world.money(0)), float(forecast.cash)), "工具费及两个生产队列的付款与真实余额一致")

func _offer(world: OffWorkState, kind: String) -> int:
	for offer in world.offers:
		if not offer.is_empty() and offer.type == kind: return int(offer.id)
	return -1

func _later_planned_payment() -> void:
	var config := _config()
	config.rules.initial.groups = [{"employee":1, "work":100}]
	config.rules.initial.money = 100
	config.cards.employee.price = 100
	config.rules.recruitment.cost_per_employee = 101
	config.rules.conveyor.pool = {"outsource":1}
	config.rules.conveyor.interval_seconds = 3.0
	if not need(config.validate(), "后续已计划采购回归使用合法公开价格与供应规则"): return
	var world := OffWorkState.new(config)
	world.new_game(613)
	world.offers = [{}, {}, {}, {}, {}, world._make_offer("employee")]
	var quote: int = world.offers[-1].id
	var destination: int = world.cards[world._owner_type(0, "work")[0]].group
	_unknown_is_not_owned(world)
	# Even guaranteed future draws are not currently paid tools. This actual
	# counterfactual demonstrates why their price cannot spend committed cash.
	var premature := world.fork_for_bot(613)
	premature.advance(3.0)
	var premature_tool := _offer(premature, "outsource")
	check(premature_tool >= 0 and premature.buy(premature_tool, 0) >= 0 and premature.available_money(0) == 94,
		"t3实际新报价可买，但提前付款会占用已承诺给后续采购的钱")
	premature.advance(2.0)
	check(premature.buy(quote, 0) < 0, "提前购买外包会让t5原定100元员工采购真实失败")
	var evaluation := _evaluation(world)
	var before := _snapshot(world)
	var model: Dictionary = evaluation._model(world, 0, evaluation._index(world))
	model.events.append({"at":6.0, "kind":"spend", "amount":100.0, "action":true,
		"operation":"planned_employee", "offer":quote, "expires":12.0})
	model.events.append({"at":6.0, "kind":"worker", "group":destination, "id":"planned_employee_worker",
		"action":true, "after":"planned_employee", "lag":1.0, "unit":evaluation._unit("employee", 1, false, false)})
	var known: Dictionary = evaluation._finish_forecast(model)
	check(_snapshot(world) == before and not known.has("cashout"), "计划保留原付款，不叠加未观察的未来外包收益")
	check(known.forecast_purchases.has(quote) and is_equal_approx(float(known.forecast_purchases[quote].at), 5.0),
		"已选员工采购仍在原t5成功付款，不能偷偷改为失败或延后")
	check(known.forecast_purchases.size() == 1 and known.required_actions == 2,
		"已知采购与合组共两个命令，无未知报价及其投料命令")
	world.advance(5.0)
	var person := world.buy(quote, 0)
	check(person >= 0 and world.available_money(0) == 0, "真实t5完整支付已计划的员工采购")
	world.advance(1.0)
	check(world.move_cards([person], destination) >= 0, "真实t6保持原新员工合组命令")
	world.advance(60.0 - world.time)
	var available := _offer(world, "outsource")
	var cash_before := world.available_money(0)
	var tool := world.buy(available, 0)
	check(tool >= 0 and cash_before >= 6 and world.available_money(0) == cash_before - 6,
		"原采购之后仅用已到账工资购买现在真实公开的外包工具")
	var observed_at := world.time
	var forecast := _physical(world)
	if not need(forecast.has("cashout") and not forecast.cashout.future_supply, "已购工具才获得后续真实付款收益"): return
	check(float(forecast.cashout.funding_at) >= 1.0, "购买与投料仍占不同真实行动机会")
	world.advance(float(forecast.cashout.funding_at))
	check(world.available_money(0) >= world.work_count(0), "员工与工具均已付款后，实际余款足以完成投料")
	check(world.move_cards([tool] + world._owner_type(0, "work") + world._owner_type(0, "money"), -1) >= 0
		and not world.outsourcing.is_empty(), "后续可执行的最终投料真实启动")
	world.advance(10.0)
	check(world.winner == 0 and is_equal_approx(world.time, observed_at + float(forecast.eta)),
		"保留原采购收益后，实际完工与已观察资源的预测一致")
	check(is_equal_approx(float(world.money(0)), float(forecast.cash)), "原投资、工具和投料三笔费用均真实支付且余额一致")
