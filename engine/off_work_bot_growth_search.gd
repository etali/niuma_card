# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Economic macro plans start at the observed root, rather than repeating the
## same factory rollout after every ordinary action. A completed plan publishes
## its first real command; its later productivity is never attached to a free
## wait. Both seats receive the same policy portfolio on the same action clock.
const Growth = preload("res://engine/off_work_bot_growth_plans.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")

static func refine(world: OffWorkState, owner: int, policy: Dictionary, until: int,
		ordinary_root_value: Dictionary, on_choice: Callable, cancelled: Callable = Callable(),
		root_action_filter: Callable = Callable()) -> Dictionary:
	var run := Refinement.new()
	run.world = world
	run.owner = owner
	run.policy = policy
	run.until = until
	run.ordinary = ordinary_root_value
	run.on_choice = on_choice
	run.cancelled = cancelled
	run.root_action_filter = root_action_filter
	return run.run()

class Refinement extends RefCounted:
	var world: OffWorkState
	var owner: int
	var policy: Dictionary
	var until := -1
	var ordinary: Dictionary
	var source_base: Dictionary
	var on_choice: Callable
	var cancelled: Callable
	var root_action_filter: Callable
	var evaluator := Evaluation.new()
	var rows: Array = [[], []]
	var diagnostics := {"complete":true,"plans":0,"examined":0,"evaluated":0,
		"choices":0,"rounds":0,"sides_evaluated":[0,0],"rejected_quotes":0,"rejected_unobserved":0}

	func _open() -> bool:
		return (until < 0 or Time.get_ticks_usec() < until) and not (cancelled.is_valid() and cancelled.call())

	func run() -> Dictionary:
		if not ordinary.get("complete", false) or ordinary.get("detail", {}).get("terminal", true): return diagnostics
		var period := maxf(0.001, float(policy.get("think_seconds", world.config.rules.bot.think_seconds)))
		var clock := [period * 0.5, period * 0.5]
		clock[owner] = 0.0
		# The incumbent may already include a strike, transfer, purchase or other
		# first action. Its modified opponent must not become the starting model
		# of a macro which does not perform that action.
		source_base = _evaluate(world, clock, until)
		if not source_base.get("complete", false) or source_base.detail.get("terminal", false):
			diagnostics.complete = false
			return diagnostics
		var states := [{}, {}]
		var pending := [Growth.available(world, 0), Growth.available(world, 1)]
		var served := [not pending[0], not pending[1]]
		# Alternate whole checkpoints, retaining each policy's cursor. Dividing
		# the budget by candidates x sides x policies made every slice shorter
		# than the minimum time to execute a legal production sequence.
		while pending.any(func(value): return value) and _open():
			var order := [owner, 1-owner] if int(diagnostics.rounds) % 2 == 0 else [1-owner, owner]
			for side in order:
				if not pending[side] or not _open(): continue
				var result: Dictionary = Growth.visit(world, side, policy, until, clock,
					func(plan): _record(plan, side), cancelled,
					{"consume_immediately":true,"planner_state":states[side],"round_limit":1})
				diagnostics.plans += int(result.plans)
				diagnostics.examined += int(result.examined)
				pending[side] = bool(result.get("pending", false))
				# A side with no reachable growth finishes without a checkpoint.
				# A side interrupted before any completed forecast is not covered.
				served[side] = served[side] or bool(result.complete) or not rows[side].is_empty()
				if not result.complete and not pending[side]: diagnostics.complete = false
			diagnostics.rounds += 1
		if pending.any(func(value): return value): diagnostics.complete = false
		if not served[0] or not served[1]: return diagnostics
		# Only now reduce completed numerical results. A later opponent checkpoint
		# can invalidate an earlier attractive plan, so no premature macro choice
		# is published and then left in the caller as an optimistic incumbent.
		var best := {}
		var best_value := _joint_value({"own":ordinary.detail.sides[owner],"other":ordinary.detail.sides[1-owner]}, false)
		diagnostics["ordinary_score"] = ordinary.score
		diagnostics["incumbent_score"] = best_value.score
		for row in rows[owner]:
			var value := _joint_value(row)
			if value.is_empty() or not _greater(value, best_value): continue
			best = row
			best_value = value
		if not best.is_empty() and not (cancelled.is_valid() and cancelled.call()):
			diagnostics.choices = 1
			diagnostics["score"] = best_value.score
			if on_choice.is_valid(): on_choice.call(best.action.duplicate(true), best_value, best.plan.duplicate(true))
		return diagnostics

	func _record(plan: Dictionary, side: int) -> void:
		if not _open() or plan.commands.is_empty(): return
		var enemy := 1-side
		var held: Dictionary = source_base.detail.sides[enemy].get("forecast_purchases", {})
		# Retain the ordinary opponent's paid/public opportunity. A different
		# root search can contest it by buying first; two forecasts cannot own
		# one quote, including a quote used by the terminal economic tail.
		if not _compatible(plan.purchases, held):
			diagnostics.rejected_quotes += 1
			return
		var action: Dictionary = plan.commands[0].action.duplicate(true) if float(plan.commands[0].at) <= 1e-8 \
			else {"kind":"wait","intent":"wait","reason":"等待已预测的资金或生产任务到达下一合法操作时机"}
		if side == owner and root_action_filter.is_valid() and not root_action_filter.call(action):
			diagnostics.rejected_unobserved += 1
			return
		var own: Dictionary
		var other: Dictionary = source_base.detail.sides[enemy].duplicate(true)
		var elapsed := float(plan.elapsed)
		if plan.world.winner >= 0:
			if int(plan.world.winner) != side: return
			own = source_base.detail.sides[side].duplicate(true)
			own.merge({"eta":elapsed,"remaining":0,"uncommitted":0,"stalled":false,
				"unreachable":false,"required_actions":0,"forecast_purchases":{},"forecast_commands":[]}, true)
		else:
			var tail_until: int = int(plan.get("evaluation_deadline", until))
			if until >= 0: tail_until = until if tail_until < 0 else mini(until, tail_until)
			var value := _evaluate(plan.world, plan.next_actions, tail_until)
			if not value.get("complete", false) or value.detail.get("terminal", false):
				diagnostics.complete = false
				return
			var pair: Array = value.detail.sides.duplicate(true)
			for forecast in pair: evaluator._offset_forecast(forecast, elapsed)
			own = pair[side]
			if float(pair[enemy].eta) < float(other.eta): other = pair[enemy]
			if not _compatible(own.get("forecast_purchases", {}), held):
				diagnostics.rejected_quotes += 1
				return
		own.forecast_purchases.merge(plan.purchases, true)
		own.required_actions = int(own.required_actions) + plan.commands.size()
		for key in ["work","current_rate","idle_pending","committed_work","pending_strikes","free_cash"]:
			if source_base.detail.sides[side].has(key): own[key] = source_base.detail.sides[side][key]
		# consume_immediately lends a live cursor; retain immutable commands and
		# numbers only. Neither this module nor its caller keeps plan.world.
		var evidence := {"kind":plan.kind,"owner":side,"person":int(plan.get("person",-1)),
			"elapsed":elapsed,"seconds":elapsed,"next_actions":plan.next_actions.duplicate(),
			"commands":plan.commands.duplicate(true),"purchases":plan.purchases.duplicate(true),
			"growth":plan.get("growth",{}).duplicate(true),"complete":true,
			"opponent_assumption":"real natural events during prefix; compatible faster opponent continuations retained"}
		own["production_chain"] = evidence.duplicate(true)
		rows[side].append({"own":own,"other":other,"action":action,"plan":evidence})
		diagnostics.evaluated += 1
		diagnostics.sides_evaluated[side] += 1

	func _evaluate(state: OffWorkState, clock: Array, limit: int) -> Dictionary:
		match str(ordinary.get("evaluation_mode", "economic")):
			"current": return evaluator.evaluate_current(state, owner, policy, limit, clock)
			"tactical": return evaluator.evaluate_tactical(state, owner, policy, limit, clock)
			_: return evaluator.evaluate(state, owner, policy, limit, clock, false)

	func _compatible(a: Dictionary, b: Dictionary) -> bool:
		return not a.keys().any(func(quote): return b.has(quote))

	func _precedes(a: Dictionary, b: Dictionary) -> bool:
		return float(a.at) < float(b.at)-1e-8 or (is_equal_approx(float(a.at),float(b.at)) and int(a.owner)<int(b.owner))

	func _joint_value(row: Dictionary, reject_blocked := true) -> Dictionary:
		var own: Dictionary = row.own
		var other: Dictionary = row.other
		var own_quotes: Dictionary = own.get("forecast_purchases", {})
		for reply in rows[1-owner]:
			var quotes: Dictionary = reply.own.get("forecast_purchases", {})
			var overlap := false
			for quote in own_quotes:
				if not quotes.has(quote): continue
				overlap = true
				# An opponent's earlier executable purchase makes this exact macro
				# unavailable; do not drop that reply and award us its unique tool.
				if reject_blocked and _precedes(quotes[quote], own_quotes[quote]): return {}
			if overlap: continue
			if float(reply.own.eta) < float(other.eta): other = reply.own
		var sides: Array = [null, null]
		sides[owner] = own
		sides[1-owner] = other
		var value: Dictionary = ordinary.duplicate(true)
		value.detail.sides = sides.duplicate(true)
		value.score = clampf(1000.0 * evaluator._race(sides, owner), -Evaluation.WIN * 0.5, Evaluation.WIN * 0.5)
		value.tie_score = int(other.required_actions) - int(own.required_actions)
		value["growth_extension"] = {"complete":diagnostics.complete,"plans":diagnostics.plans,"evaluated":diagnostics.evaluated}
		return value

	func _greater(a: Dictionary, b: Dictionary) -> bool:
		var first := snappedf(float(a.score), 0.0000001)
		var second := snappedf(float(b.score), 0.0000001)
		return first > second or (first == second and int(a.get("tie_score",0)) > int(b.get("tie_score",0)))
