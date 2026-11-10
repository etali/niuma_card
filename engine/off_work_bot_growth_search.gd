# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Generic legal continuations share one completion-time objective. Both seats
## use the same action model. Opponent replies and paid physical continuation
## stay in the SAME rule state; estimates from incompatible worlds are never
## spliced together. Completed prefixes compete on the root clock.
const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")
const ForecastCommands = preload("res://engine/off_work_bot_forecast_commands.gd")
const AttackPlans = preload("res://engine/off_work_bot_attack_plans.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")

static func refine(world: OffWorkState, owner: int, policy: Dictionary, until: int,
		ordinary_root_value: Dictionary, on_choice: Callable, cancelled: Callable = Callable(),
		root_action_filter: Callable = Callable(), execution_context: Dictionary = {}, root_candidates: Array = [], root_replies: Array = []) -> Dictionary:
	var run := Refinement.new()
	run.world = world
	run.owner = owner
	run.policy = policy
	run.until = until
	run.ordinary = ordinary_root_value
	run.on_choice = on_choice
	run.cancelled = cancelled
	run.root_action_filter = root_action_filter
	run.execution_context = execution_context
	run.root_candidates = root_candidates
	run.root_replies = root_replies
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
	var execution_context: Dictionary
	var root_candidates: Array
	var root_replies: Array = []
	var joint_prefixes := false
	var release_reserves := [0,0]
	var evaluator := Evaluation.new()
	var rows: Array = [[], []]
	var diagnostics := {"complete":true,"plans":0,"examined":0,"evaluated":0,
		"choices":0,"rounds":0,"sides_evaluated":[0,0],"rejected_quotes":0,"rejected_unobserved":0,
		"execution_checkpoints":0,"execution_complete":true}

	func _open() -> bool:
		return (until < 0 or Time.get_ticks_usec() < until-int(release_reserves[0])-int(release_reserves[1])) and not (cancelled.is_valid() and cancelled.call())

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
		if not _public_reply(clock):
			diagnostics.complete=false
			return diagnostics
		joint_prefixes=root_candidates.any(func(seed):return seed.get("joint_prefix",false))
		var state := {}
		var pending := true
		diagnostics["opponent_model"]="common_first_reply_resource_use_and_paid_physical_tail"
		diagnostics["joint_prefixes"]=joint_prefixes
		diagnostics["reply_candidates"]=root_replies.size()
		# Every candidate keeps its actual opponent state. A second independent
		# production tree cannot be joined by quote ownership alone: attacks,
		# transferred work and response times make those worlds incompatible.
		while pending and _open():
			var options := {"consume_immediately":true,"planner_state":state,"checkpoint_limit":1,
				"root_candidates":root_candidates,"seed_roots_only":joint_prefixes,
				"root_replies":root_replies,
				"execution_context":execution_context,"source_evaluation":source_base,
				"physical_opponent":true,
				"root_action_filter":Callable(self,"_allowed_root"),
				"evaluate":func(plan): return _evaluate(plan.world,plan.next_actions,int(plan.get("evaluation_deadline",until)))}
			var result: Dictionary=Continuations.visit(world,owner,policy,until,clock,
				func(plan): _record(plan,owner),cancelled,options)
			release_reserves[owner]=int(result.get("release_reserve_us",0))
			diagnostics.plans+=int(result.plans)
			diagnostics.examined+=int(result.examined)
			pending=bool(result.get("pending",false))
			diagnostics["side_%d"%owner]=result.duplicate(true)
			if not result.complete: diagnostics.complete=false
			diagnostics.rounds+=1
		if pending: diagnostics.complete=false
		if rows[owner].is_empty(): return diagnostics
		# Reduce complete values from actual shared states on the common clock.
		# A cutoff can discard an unfinished branch, never mix partial sides.
		var best := {}
		var best_value := {}
		if not root_replies.is_empty() and ordinary.has("action"):
			# The previous short-tree value used a different response model.
			# Establish its value using these same completed real continuations.
			for row in rows[owner]:
				if not _same_action(row.action,ordinary.action): continue
				var value := _joint_value(row)
				if best_value.is_empty() or _greater(value,best_value):
					best=row
					best_value=value
			if best_value.is_empty():
				diagnostics["incumbent_rechecked"]=false
				return diagnostics
			diagnostics["incumbent_rechecked"]=true
		else:
			best_value=_joint_value({"own":ordinary.detail.sides[owner],"other":ordinary.detail.sides[1-owner]},false)
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

	func _public_reply(clock: Array) -> bool:
		# A tactical forecast proposes a public first command only. Its scores
		# never enter the common current-state evaluation or either ETA.
		var available: Dictionary=AttackPlans.available_kinds(world,1-owner,until)
		if not available.complete: return false
		if available.kinds.is_empty(): return _open()
		var tactical: Dictionary=evaluator.evaluate_tactical(world,owner,policy,until,clock)
		if not tactical.get("complete",false) or not _open(): return false
		var forecast: Dictionary=tactical.detail.get("sides",[{},{}])[1-owner]
		if forecast.get("forecast_attack",{}).is_empty(): return true
		var cost := Budget.fork_cost(world)+Budget.release_cost(world)
		if until>=0 and until-Time.get_ticks_usec()<=cost: return false
		var trial := world.fork_search_node()
		var limit: int=until-Budget.release_cost(trial) if until>=0 else -1
		var at := float(clock[1-owner])
		if not trial.advance_for_search(at,limit,cancelled): return false
		trial.mask_search_market(world._next_offer)
		var proposed: Dictionary=ForecastCommands.next_command(trial,1-owner,policy,forecast,at,at,limit)
		if not proposed.get("complete",false) or not _open(): return false
		if proposed.has("action") and not proposed.action.is_empty():
			var action: Dictionary=proposed.action
			# A source proposal cannot import a future sampled person's identity.
			for id in action.get("ids",[]):
				if not world.cards.has(id): return true
			for key in ["person","tool"]:
				if int(action.get(key,-1))>=0 and not world.cards.has(int(action[key])): return true
			if int(action.get("group",-1))>=0 and not world.groups.has(int(action.group)): return true
			if not root_replies.any(func(existing):return _same_action(existing,action)):
				root_replies.append(action.duplicate(true))
		return _open()

	func _allowed_root(action: Dictionary) -> bool:
		if root_action_filter.is_valid() and not root_action_filter.call(action): return false
		if not joint_prefixes: return true
		return root_candidates.any(func(seed):return _same_action(seed.action,action))

	func _same_action(a: Dictionary, b: Dictionary) -> bool:
		# Continuation metadata does not alter the legal command.
		return preload("res://engine/off_work_bot_execution_plan.gd")._same(a,b)

	func _record(plan: Dictionary, side: int) -> void:
		if not _open() or plan.commands.is_empty() or plan.get("opponent_use_pending",false): return
		var enemy := 1-side
		var held: Dictionary = source_base.detail.sides[enemy].get("forecast_purchases", {})
		var own_purchases := {}
		var enemy_purchases := {}
		for quote in plan.purchases:
			var purchase: Dictionary=plan.purchases[quote]
			if int(purchase.get("owner",side))==side: own_purchases[quote]=purchase
			else: enemy_purchases[quote]=purchase
		# Retain the ordinary opponent's paid/public opportunity. A different
		# root search can contest it by buying first; two forecasts cannot own
		# one quote, including a quote used by the terminal economic tail.
		if not _compatible(own_purchases, held):
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
		var terminal := {}
		if plan.world.winner >= 0:
			terminal=plan.get("evaluation",{})
			if not terminal.get("detail",{}).get("terminal",false):
				terminal=_evaluate(plan.world,plan.next_actions,int(plan.get("evaluation_deadline",until)))
			if not terminal.get("complete",false): return
			own=source_base.detail.sides[side].duplicate(true)
			for actor in 2:
				var forecast: Dictionary=own if actor==side else other
				var remaining: int=plan.world.work_count(actor)
				forecast.merge({"eta":elapsed if remaining==0 else INF,"remaining":remaining,"uncommitted":0,
					"stalled":false,"unreachable":false,"required_actions":0,"forecast_purchases":{},
					"forecast_commands":[],"forecast_steps":[]},true)
		else:
			var tail_until: int = int(plan.get("evaluation_deadline", until))
			if until >= 0: tail_until = until if tail_until < 0 else mini(until, tail_until)
			var value: Dictionary = plan.get("evaluation",{})
			if value.is_empty(): value = _evaluate(plan.world, plan.next_actions, tail_until)
			if not value.get("complete", false) or value.detail.get("terminal", false):
				diagnostics.complete = false
				return
			var pair: Array = value.detail.sides.duplicate(true)
			for forecast in pair: evaluator._offset_forecast(forecast, elapsed)
			own = pair[side]
			other = pair[enemy]
			# Absolute-time semantic bindings must be captured in the actual leaf,
			# before that world is released or future identities reach the root.
			own.forecast_steps=Execution.physical_steps(plan.world,side,value.detail.sides[side].get("forecast_commands",[]),0.0,{},tail_until)
			if not _open() or (tail_until>=0 and Time.get_ticks_usec()>=tail_until): return
			if not _compatible(own.get("forecast_purchases", {}), held):
				diagnostics.rejected_quotes += 1
				return
		own.forecast_purchases.merge(own_purchases, true)
		other.forecast_purchases.merge(enemy_purchases, true)
		# Ordinary root values are evaluated AFTER the current command. Match
		# that same count: only future non-wait commands remain to be executed.
		# Counting the immediate command again tied "do it now" with "defer it"
		# and let rolling replans postpone equally good physical production.
		own.required_actions = int(own.required_actions) + plan.commands.filter(func(command):return command.action.kind!="wait" and float(command.at)>1e-8).size()
		other.required_actions = int(other.required_actions) + plan.get("replies",[]).filter(func(command):return command.action.kind!="wait" and float(command.at)>1e-8).size()
		for key in ["work","current_rate","idle_pending","committed_work","pending_strikes","free_cash"]:
			if source_base.detail.sides[side].has(key): own[key] = source_base.detail.sides[side][key]
		# consume_immediately lends a live cursor; retain immutable commands and
		# numbers only. Neither this module nor its caller keeps plan.world.
		var evidence := {"kind":plan.kind,"owner":side,"person":int(plan.get("person",-1)),
			"elapsed":elapsed,"seconds":elapsed,"next_actions":plan.next_actions.duplicate(),
			"commands":plan.commands.duplicate(true),"replies":plan.get("replies",[]).duplicate(true),"purchases":plan.purchases.duplicate(true),
			"growth":plan.get("growth",{}).duplicate(true),"complete":true,
			"opponent_assumption":"same rule world; common first replies, one resource-related legal follow-up and paid physical tail; finite passive-own reply preview, not full minimax"}
		own["production_chain"] = evidence.duplicate(true)
		rows[side].append({"own":own,"other":other,"action":action,"plan":evidence,"terminal":terminal})
		diagnostics.evaluated += 1
		diagnostics.sides_evaluated[side] += 1

	func _evaluate(state: OffWorkState, clock: Array, limit: int) -> Dictionary:
		return evaluator.evaluate_current(state,owner,policy,limit,clock)

	func _compatible(a: Dictionary, b: Dictionary) -> bool:
		return not a.keys().any(func(quote): return b.has(quote))

	func _precedes(a: Dictionary, b: Dictionary) -> bool:
		return float(a.at) < float(b.at)-1e-8 or (is_equal_approx(float(a.at),float(b.at)) and int(a.owner)<int(b.owner))

	func _joint_value(row: Dictionary, _reject_blocked := true) -> Dictionary:
		var own: Dictionary = row.own
		var other: Dictionary = row.other
		var sides: Array = [null, null]
		sides[owner] = own
		sides[1-owner] = other
		var value: Dictionary = ordinary.duplicate(true)
		value.detail.sides = sides.duplicate(true)
		var terminal: Dictionary=row.get("terminal",{})
		value.score = terminal.score if not terminal.is_empty() else clampf(1000.0 * evaluator._race(sides, owner), -Evaluation.WIN * 0.5, Evaluation.WIN * 0.5)
		value.tie_score = int(other.required_actions) - int(own.required_actions)
		if not terminal.is_empty():
			value.score=terminal.score
			value.tie_score=terminal.get("tie_score",0)
			value.detail["terminal"]=true
			value.detail["winner"]=terminal.detail.winner
		value["growth_extension"] = {"complete":diagnostics.complete,"plans":diagnostics.plans,"evaluated":diagnostics.evaluated}
		return value

	func _greater(a: Dictionary, b: Dictionary) -> bool:
		var first := snappedf(float(a.score), 0.0000001)
		var second := snappedf(float(b.score), 0.0000001)
		return first > second or (first == second and int(a.get("tie_score",0)) > int(b.get("tie_score",0)))
