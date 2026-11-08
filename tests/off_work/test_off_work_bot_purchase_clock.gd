# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")

func _initialize() -> void:
	for early in [0, 1]:
		_funded_purchase(early)
		_insufficient_cash(early)
	finish()

func _fixture(early: int, money: int) -> Dictionary:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1,"work":40}]
	config.rules.initial.money = 4
	config.rules.bot.think_seconds = 1.0
	# This case measures public purchase/dispatch clocks, without later supply
	# or hypothetical cash-out plans changing the completion objective.
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 10000.0
	var world := OffWorkState.new(config)
	world.new_game(372)
	world._consume(world._owner_type(early,"employee")[0])
	var grinder := world.add_card("grinder", early)
	while world.money(early)>money: world._consume(world._owner_type(early,"money")[0])
	world.offers = [world._make_offer("employee")]
	world.advance(0.0)
	var clock := [0.5, 0.5]
	clock[early] = 0.0
	return {"world":world, "grinder":grinder, "offer":world.offers[0].duplicate(), "clock":clock}

func _group(world: OffWorkState, owner: int) -> int:
	return int(world.cards[world._owner_type(owner,"work")[0]].group)

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var values := [world._rng.state, world._events, world.last_error]
	for key in OffWorkState.WORLD_FIELDS: values.append(world.get(key))
	return var_to_bytes(values)

func _forecast(fixture: Dictionary, evaluator: RefCounted) -> Array:
	var world: OffWorkState = fixture.world
	var before := _snapshot(world)
	var value: Dictionary = evaluator.evaluate(world,0,world.config.rules.bot,-1,fixture.clock)
	check(value.complete, "无搜索截止干扰的购买评价完整结束")
	check(_snapshot(world)==before, "购买时钟预测不修改正式世界或随机流")
	return value.detail.sides

func _finish_at(world: OffWorkState, owner: int, eta: float, label: String) -> void:
	check(eta>world.time, label+" 预测完工在实际部署之后")
	if eta<=world.time: return
	world.advance(eta-world.time-0.001)
	check(world.winner<0 and world.work_count(owner)>0, label+" 预计时刻前仍有真实待办")
	world.advance(0.001)
	check(world.winner==owner and world.work_count(owner)==0 and is_equal_approx(world.time,eta),
		label+" buy/move/advance真实完工时间与预测ETA一致")

func _funded_purchase(early: int) -> void:
	var late := 1-early
	var fixture := _fixture(early,4)
	var world: OffWorkState = fixture.world
	var offer: Dictionary = fixture.offer
	var evaluator := Evaluation.new()
	var sides := _forecast(fixture,evaluator)
	var claims: Dictionary = sides[early].forecast_purchases
	check(claims.has(offer.id), "有现金的较早方取得唯一公开员工报价")
	if not claims.has(offer.id): return
	check(int(claims[offer.id].owner)==early and is_zero_approx(float(claims[offer.id].at)),
		"较早方在第0秒先买，不被闲置卷王自动返岗占用首行动")
	check(not sides[late].forecast_purchases.has(offer.id), "较晚方不能重复取得同一公开报价")
	check(int(sides[early].required_actions)==2, "预测只需要采购与合组两条命令")

	var model: Dictionary = evaluator._model(world,early,evaluator._index(world))
	var planned: Dictionary = evaluator._best_forecast(world,model,sides[late].forecast_purchases)
	var schedule: Dictionary = evaluator._schedule(planned._continuation.events,0.0)
	var workers: Array = schedule.events.filter(func(event): return event.kind=="worker")
	check(schedule.commands.size()==2 and workers.size()==2, "两名人员共享一次合组，未插入第三条部署命令")
	check(workers.size()==2 and is_equal_approx(float(workers[0].at),1.0)
		and is_equal_approx(float(workers[1].at),1.0) and workers[0].action_key==workers[1].action_key,
		"老闲人和新买员工在第1秒的同一合法行动一起返岗")

	var replay := world.fork_for_bot(89)
	var purchased := replay.buy(int(offer.id),early)
	check(purchased>=0 and replay.money(early)==0 and int(replay.cards[purchased].owner)==early,
		"真实第0秒购买成功并支付完整现金")
	if purchased<0: return
	replay.advance(0.5)
	check(replay.buy(int(offer.id),late)<0 and replay.money(late)==4,
		"真实较晚行动不能重买已售员工，也不会扣钱")
	replay.advance(0.5)
	var target := _group(replay,early)
	check(replay.move_cards([fixture.grinder,purchased],target)==target,
		"真实第1秒用一次move合并闲置卷王与新员工")
	check(replay.group_work_participants(target).size()==2, "同一真实工作组已有两名参与者")
	_finish_at(replay,early,float(sides[early].eta),"有钱先买")

func _insufficient_cash(early: int) -> void:
	var late := 1-early
	var fixture := _fixture(early,3)
	var world: OffWorkState = fixture.world
	var offer: Dictionary = fixture.offer
	var evaluator := Evaluation.new()
	var sides := _forecast(fixture,evaluator)
	check(not sides[early].forecast_purchases.has(offer.id), "较早方仅3钱时不能强行抢4钱员工")
	check(sides[late].forecast_purchases.has(offer.id), "资金足够的较晚方取得该报价")
	if not sides[late].forecast_purchases.has(offer.id): return
	check(int(sides[late].forecast_purchases[offer.id].owner)==late
		and is_equal_approx(float(sides[late].forecast_purchases[offer.id].at),0.5),
		"资金不足不会伪造较早采购，实际归属时刻是较晚方第0.5秒")
	var model: Dictionary = evaluator._model(world,early,evaluator._index(world))
	var independent: Dictionary = evaluator._best_forecast(world,model)
	check(independent.forecast_purchases.has(offer.id)
		and float(independent.forecast_purchases[offer.id].at)>=10.0,
		"即使无对手抢购，缺钱方也须先返岗并等真实首批工资")

	var replay := world.fork_for_bot(90)
	check(replay.buy(int(offer.id),early)<0 and replay.money(early)==3, "真实规则拒绝缺钱购买且保持现金")
	check(replay.move_cards([fixture.grinder],_group(replay,early))>=0, "缺钱方第0秒仍可先让已有卷王返岗")
	replay.advance(0.5)
	var purchased := replay.buy(int(offer.id),late)
	check(purchased>=0 and replay.money(late)==0, "较晚方在自身第一时隙真实购得员工")
	if purchased<0: return
	replay.advance(1.0)
	var target := _group(replay,late)
	check(replay.move_cards([purchased],target)==target and replay.group_work_participants(target).size()==2,
		"较晚方下一时隙将新员工加入原有在产队列")
	_finish_at(replay,late,float(sides[late].eta),"缺钱不可抢购")
