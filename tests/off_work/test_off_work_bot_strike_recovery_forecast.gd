# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const AttackPlans = preload("res://engine/off_work_bot_attack_plans.gd")

func _initialize() -> void:
	for progress in [0.01, 8.7]:
		for clock in [[1.4, 0.0], [0.0, 1.4]]:
			for kind in ["grinder", "employee"]:
				_compare_attack(progress, clock, kind)
	finish()

func _world(progress: float) -> OffWorkState:
	var config := OffWorkConfig.new()
	# Both sampled action phases below are tied to this exact service clock.
	config.rules.bot.think_seconds = 2.8
	config.rules.initial.groups = [{"employee":2,"work":10},{"grinder":1,"work":150}]
	config.rules.initial.money = 0
	config.roles.grinder.work_capacity = 10
	# Isolate the attack/recovery plan from any purchases or uncertain supply.
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 10000.0
	var state := OffWorkState.new(config)
	state.new_game(23)
	state.offers.clear()
	var target: int = state.cards[state._owner_type(0,"grinder")[0]].group
	var source: int = state.cards[state._owner_type(0,"employee")[0]].group
	state.move_cards(state.group_cards(source), target)
	state.add_card("strike", 0)
	state.advance(progress)
	return state

func _clock_after(clock: Array, elapsed: float, period: float) -> Array:
	var remaining := []
	for first in clock:
		var turns := maxf(0.0, ceil((elapsed-float(first)-1e-9)/period))
		remaining.append(float(first)+turns*period-elapsed)
	return remaining

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := [world._rng.state, world._events, world.last_error]
	for key in OffWorkState.WORLD_FIELDS: fields.append(world.get(key))
	return var_to_bytes(fields)

func _model(evaluator: RefCounted, world: OffWorkState, side: int, clock: Array) -> Dictionary:
	var evaluated: Dictionary = evaluator.evaluate(world, 0, world.config.rules.bot, -1, clock)
	check(evaluated.complete, "公开状态评价完整结束")
	return evaluator._model(world, side, evaluator._index(world))

func _compare_attack(progress: float, clock: Array, kind: String) -> void:
	var world := _world(progress)
	var original := _snapshot(world)
	var evaluator := Evaluation.new()
	var own := _model(evaluator, world, 0, clock)
	var other: Dictionary = evaluator._model(world, 1, evaluator._index(world))
	var target: int = world.cards[world._owner_type(1,kind)[0]].group
	var plans: Dictionary = AttackPlans.plans(world, 0)
	var matching: Array = plans.plans.filter(func(plan): return plan.kind=="strike" and plan.target_group==target)
	check(matching.size()==1, "两个不同产能队列都保留独立罢工候选")
	if matching.size()!=1: return
	var candidate: Dictionary = evaluator._attack_candidate(world, own, other, matching[0])
	check(not candidate.is_empty(), "罢工候选可以排入合法行动时钟")
	if candidate.is_empty(): return
	var predicted: Dictionary = evaluator._forecast(candidate.other)
	var returns: Array = candidate.other.events.filter(func(event): return event.kind=="strike_return")
	check(returns.size()==1, "一个攻击只排一次返岗")
	if returns.size()!=1: return
	var return_group := int(returns[0].group)
	var label := "%s progress=%.2f clock=%s" % [kind, progress, clock]
	var branch := world.fork_for_bot(71)
	var use_at := float(candidate.detail.use_at)
	var flight := float(candidate.detail.flight_seconds)
	var period := float(world.config.rules.bot.think_seconds)
	branch.advance(use_at)
	check(branch.activate(int(matching[0].tool),target), label+" 真实规则成功发射")
	branch.advance(flight*0.5)
	var pending_at := use_at+flight*0.5
	var pending := _model(evaluator, branch, 1, _clock_after(clock,pending_at,period))
	var pending_eta := float(evaluator._forecast(pending).eta)+pending_at
	check(is_equal_approx(pending_eta,float(predicted.eta)), label+" 飞行中与发射前的绝对完工时间一致")
	var pending_returns: Array = pending.events.filter(func(event): return event.kind=="strike_return")
	check(pending_returns.size()==1 and int(pending_returns[0].group)==return_group, label+" 公开飞行和未来攻击使用同一返岗队列")
	branch.advance(flight*0.5)
	var impact := use_at+flight
	var after := _model(evaluator, branch, 1, _clock_after(clock,impact,period))
	var actual_eta := float(evaluator._forecast(after).eta)+impact
	check(branch.pending_strikes.is_empty() and not branch.cards.has(matching[0].tool), label+" 真实罢工已结算并消耗卡牌")
	check(return_group==int(after.target), label+" 预测返岗目标等于真实命中后的生产目标")
	check(is_equal_approx(actual_eta,float(predicted.eta)), label+" 真实命中后绝对完工时间一致：%.6f / %.6f" % [actual_eta,predicted.eta])
	if kind=="grinder":
		check(return_group!=target, "高产队列中断后，将材料与返岗人员转给仍工作的低产队列")
	else:
		check(return_group==int(other.target), "低产队列中断后继续使用原高产队列")
	check(_snapshot(world)==original, "计划和真实副本重放均不修改原牌桌或随机流")
