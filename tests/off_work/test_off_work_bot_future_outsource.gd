# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Economy = preload("res://engine/off_work_bot_economy.gd")

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
	config.rules.conveyor.employee_every = 3
	# Same 1/18 public outsource probability as the audited default. No
	# future RNG/offer is consulted by the forecast or supplied to the policy.
	config.rules.conveyor.pool = {"employee":17, "outsource":1}
	config.cards.outsource.price = 6
	config.cards.strike.price = 7
	config.rules.outsource.cost_per_work = 1
	config.rules.outsource.seconds = 10.0
	config.rules.strike.flight_seconds = 0.0
	return config

func _evaluation(world: OffWorkState) -> RefCounted:
	var result := Evaluation.new()
	result._config = world.config
	result._period = 1.0
	result._next_actions = [0.0, 0.0]
	result._horizon = 1800.0
	result._base_cycle = 10.0
	result._supply_wait = Economy.expected_supply_wait(world.config, "outsource")
	return result

func _spending_before_supply() -> void:
	var config := _config()
	config.rules.initial.groups = [{"work_emperor":1, "work":6}]
	config.rules.initial.money = 12
	config.roles.work_emperor.work_seconds = 10.0
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
	var evaluation := _evaluation(world)
	check(is_equal_approx(evaluation._supply_wait, 54.0), "未知外包仅从公开供应分布收取54秒等待")
	var before := _snapshot(world)
	var model: Dictionary = evaluation._model(world, 0, evaluation._index(world))
	model.events.append({"at":1.0, "kind":"spend", "amount":7.0, "action":true,
		"operation":"buy_strike", "offer":quote, "expires":12.0})
	model.events.append({"at":2.0, "kind":"commit_attack", "action":true,
		"operation":"attack", "after":"buy_strike", "lag":1.0})
	var forecast: Dictionary = evaluation._finish_forecast(model)
	check(_snapshot(world) == before, "完整WORLD_FIELDS与RNG在未来采购预测后逐字段保持只读")
	if not need(forecast.has("cashout") and forecast.cashout.future_supply, "保留可执行的未来外包收尾，而非丢弃该候选"):
		return
	var closing: Dictionary = forecast.cashout
	check(closing.has("purchase_at"), "未来外包诊断给出独立工具购买时隙")
	check(is_equal_approx(float(closing.get("purchase_at", -1)), 55.0), "t54现金不足，不能预支t55工资提前买工具")
	check(is_equal_approx(float(closing.funding_at), 56.0) and is_equal_approx(float(forecast.eta), 66.0),
		"购买后另用一个行动机会投料，预计t66真实完工")
	check(forecast.forecast_purchases.size() == 1 and forecast.forecast_purchases.has(quote),
		"统计供应不伪造未来报价ID，保留的具体报价只有真实公开罢工")
	var strike := world.buy(quote, 0)
	check(strike >= 0 and world.available_money(0) == 5, "t0先按原计划花7元购买公开罢工")
	world.advance(1.0)
	check(world.activate(strike, opponent), "t1使用已购买罢工，购买与使用占两个时隙")
	world.advance(44.0)
	check(world.move_cards([person], own) >= 0, "t45按原计划执行真实返岗")
	world.advance(9.0)
	# Realize the statistical arrival as a declared public event. This does
	# not claim that any RNG seed guarantees the mean supply waiting time.
	world.offers = [{}, {}, {}, {}, {}, world._make_offer("outsource")]
	var outsource_quote: int = world.offers[-1].id
	check(world.available_money(0) == 5 and world.buy(outsource_quote, 0) < 0,
		"t54公开外包到货后，真实规则拒绝5元购买6元工具")
	world.advance(1.0)
	check(world.available_money(0) == 13 and world.work_count(0) == 5, "t55真实工资入账后才具备工具与剩余工作资金")
	var tool := world.buy(outsource_quote, 0)
	check(tool >= 0 and world.available_money(0) == 7, "t55购买工具真实扣款6元一次")
	world.advance(1.0)
	check(world.move_cards([tool] + world._owner_type(0, "work") + world._owner_type(0, "money"), -1) >= 0
		and not world.outsourcing.is_empty(), "t56独立投料命令开始最后5份外包")
	world.advance(10.0)
	check(world.winner == 0 and world.time == 66.0 and is_equal_approx(world.time, float(forecast.eta)),
		"真实buy/activate/move/advance与预测完工时刻一致")
	check(world.money(0) == 2, "采购费与工作费各支付一次，实际结余2元")

func _occupied_slots(attacks: Array, expected_purchase: float, expected_funding: float) -> void:
	var config := _config()
	config.rules.initial.groups = [{"employee":1, "work":100}, {"employee":1, "work":100}]
	config.rules.initial.money = 220
	check(config.validate(), "命令占用回归使用真实合法双队列")
	var world := OffWorkState.new(config)
	world.new_game(612)
	world.offers.clear()
	var targets := []
	for gid in world.groups:
		if world.groups[gid].owner == 1 and not world.group_work_participants(gid).is_empty(): targets.append(gid)
	var tools := []
	for index in attacks.size(): tools.append(world.add_card("strike", 0))
	var evaluation := _evaluation(world)
	var before := _snapshot(world)
	var model: Dictionary = evaluation._model(world, 0, evaluation._index(world))
	for index in attacks.size():
		model.events.append({"at":float(attacks[index]) + 1.0, "kind":"commit_attack", "action":true,
			"operation":"planned_attack:%d" % index})
	var forecast: Dictionary = evaluation._finish_forecast(model)
	check(_snapshot(world) == before, "查找空闲购买/投料格不改变原世界与RNG：" + str(attacks))
	if not need(forecast.has("cashout") and forecast.cashout.future_supply,
		"保留既有计划后仍找到可执行外包：" + str(attacks)):
		return
	var closing: Dictionary = forecast.cashout
	check(is_equal_approx(float(closing.get("purchase_at", -1)), expected_purchase),
		"购买只能使用供应到达后未被原计划占用的格：" + str(attacks))
	check(is_equal_approx(float(closing.funding_at), expected_funding),
		"投料另占购买后的空闲格，不能和原攻击同格：" + str(attacks))
	check(forecast.required_actions == attacks.size() + 2, "原计划、买工具、投料分别计入必要命令")
	check(forecast.forecast_purchases.is_empty(), "无具体未来报价，不能生成虚假的市场归属")
	var quote := -1
	var bought := -1
	var recorded_attack_times := []
	var purchase_at := float(closing.get("purchase_at", -1))
	var funding_at := float(closing.funding_at)
	# Execute the declared original attacks at their original times. Neither
	# the predictor nor this validation may silently postpone their effects.
	for tick in range(54, int(expected_funding) + 1):
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
			check(bought >= 0 and world.available_money(0) == before_cash - 6, "空闲购买格真实扣除工具费一次")
		if is_equal_approx(float(tick), funding_at):
			commands += 1
			check(bought >= 0 and world.move_cards([bought] + world._owner_type(0, "work") + world._owner_type(0, "money"), -1) >= 0
				and not world.outsourcing.is_empty(), "购买后的空闲投料格真正启动外包")
		check(commands <= 1, "同一实际行动格不能同时攻击、购买或投料：" + str(tick))
	check(recorded_attack_times == attacks, "新增未来外包不移动已评估攻击时钟")
	world.advance(10.0)
	check(world.winner == 0 and is_equal_approx(world.time, expected_funding + 10.0)
		and is_equal_approx(world.time, float(forecast.eta)), "原计划占用后真实完工仍与预测一致")
	check(is_equal_approx(float(world.money(0)), float(forecast.cash)), "工具费用与材料付款的预测结余等于真实余额")

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
	if not need(config.validate(), "后续已计划采购回归使用合法公开价格与供应规则"):
		return
	var world := OffWorkState.new(config)
	world.new_game(613)
	world.offers = [{}, {}, {}, {}, {}, world._make_offer("employee")]
	var quote: int = world.offers[-1].id
	var destination: int = world.cards[world._owner_type(0, "work")[0]].group
	# This legal counterfactual demonstrates why merely finding an earlier
	# affordable outsource tool would invalidate the already selected plan.
	var premature := world.fork_for_bot(613)
	premature.advance(3.0)
	var premature_tool := _offer(premature, "outsource")
	check(premature_tool >= 0 and premature.buy(premature_tool, 0) >= 0 and premature.available_money(0) == 94,
		"t3确实买得起外包，但提前付款会占用已承诺给后续采购的钱")
	premature.advance(2.0)
	check(premature.buy(quote, 0) < 0, "提前购买外包会让t5原定100元员工采购真实失败")
	var evaluation := _evaluation(world)
	check(is_equal_approx(evaluation._supply_wait, 3.0), "本例公开外包供应等待为3秒，早于原计划付款")
	var before := _snapshot(world)
	var model: Dictionary = evaluation._model(world, 0, evaluation._index(world))
	model.events.append({"at":6.0, "kind":"spend", "amount":100.0, "action":true,
		"operation":"planned_employee", "offer":quote, "expires":12.0})
	model.events.append({"at":6.0, "kind":"worker", "group":destination, "id":"planned_employee_worker",
		"action":true, "after":"planned_employee", "lag":1.0, "unit":evaluation._unit("employee", 1, false, false)})
	var forecast: Dictionary = evaluation._finish_forecast(model)
	check(_snapshot(world) == before, "保留后续付款的预测不修改原世界任一字段或RNG")
	if not need(forecast.has("cashout") and forecast.cashout.future_supply,
		"支付原定投资后仍保留合法的最终外包计划"):
		return
	var purchase := float(forecast.cashout.get("purchase_at", -1))
	var funding := float(forecast.cashout.funding_at)
	check(purchase > 5.0 and funding >= purchase + 1.0,
		"买工具与投料均排在原财务前缀之后，且各自占用行动机会")
	check(forecast.forecast_purchases.has(quote) and is_equal_approx(float(forecast.forecast_purchases[quote].at), 5.0),
		"已选员工采购仍在原t5成功付款，不能偷偷改为失败或延后")
	check(forecast.forecast_purchases.size() == 1 and forecast.required_actions == 4,
		"原采购与合组、未来采购与投料共四个命令，不虚构未来报价归属")
	world.advance(5.0)
	var person := world.buy(quote, 0)
	check(person >= 0 and world.available_money(0) == 0, "真实t5仍能完整支付已计划的员工采购")
	world.advance(1.0)
	check(world.move_cards([person], destination) >= 0, "真实t6保持原新员工合组命令")
	world.advance(maxf(0.0, purchase - world.time))
	var available := _offer(world, "outsource")
	var cash_before := world.available_money(0)
	var tool := world.buy(available, 0)
	check(tool >= 0 and cash_before >= 6 and world.available_money(0) == cash_before - 6,
		"原采购之后仅用新到工资购买当前真实公开的外包工具")
	world.advance(maxf(0.0, funding - world.time))
	check(world.available_money(0) >= world.work_count(0), "完成原财务前缀及工具付款后，实际余款仍足以投料")
	check(world.move_cards([tool] + world._owner_type(0, "work") + world._owner_type(0, "money"), -1) >= 0
		and not world.outsourcing.is_empty(), "保守晚购的最终投料真实启动")
	world.advance(10.0)
	check(world.winner == 0 and is_equal_approx(world.time, float(forecast.eta)),
		"保留原采购全部收益的真实完工时间与预测一致")
	check(is_equal_approx(float(world.money(0)), float(forecast.cash)), "原投资、工具和投料三笔费用均真实支付且余额一致")
