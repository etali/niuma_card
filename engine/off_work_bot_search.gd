# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## One action model, one race evaluation, and one progressive search. Every
## generated root gets the same real-rule preview before the deeper beam is
## selected. A partially explored deeper layer never replaces a complete one.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")
const PurchaseContinuations = preload("res://engine/off_work_bot_purchase_continuations.gd")
const GrowthSearch = preload("res://engine/off_work_bot_growth_search.gd")
const GrowthPlans = preload("res://engine/off_work_bot_growth_plans.gd")
const SCORE_EPSILON := 0.0000001

var deadline := 0
var cancelled: Callable
var policy: Dictionary
var seat := 0
var half_period := 1.0
var nodes := 0
var evaluated := 0
var stopped := false
var publisher: Callable
var root_action_filter: Callable
var known_offer_end := 0
var evaluator := Evaluation.new()
var purchase_continuations := PurchaseContinuations.new()
var result := {}
var cleanup_us := 1000
var current_only := true
var growth_reserve_us := 0

func search(world: OffWorkState, owner: int, settings: Dictionary, until: int,
		cancel: Callable = Callable(), publish: Callable = Callable(), deepen := true,
		observed_action: Callable = Callable()) -> Dictionary:
	deadline = until
	cancelled = cancel
	policy = settings
	seat = owner
	half_period = float(policy.think_seconds) * 0.5
	stopped = false
	nodes = 0
	evaluated = 0
	current_only = true
	growth_reserve_us = 0
	# Projection caches and GDScript containers also need time to release.
	# Scale that fixed part with the available budget, in addition to the
	# measured size of retained rule-state copies below.
	cleanup_us = clampi((until - Time.get_ticks_usec()) / 20, 1000, 100000)
	publisher = publish
	root_action_filter = observed_action
	known_offer_end = world._next_offer
	result = {"algorithm":"race_search_v2", "search_depth":0, "search_nodes":0,
		"evaluated":0, "root_complete":false, "root_candidates":0, "completed_candidates":0, "root_unobserved":0,
		"root_ordinary_us":0,"root_production_us":0,"root_production_candidates":0,"root_production_serviced":0,
		"root_production_complete":0,"root_evaluated_intents":{},
		"root_economic_us":0,"root_economic_completed":0,"evaluation_layer":"current",
		"root_tactical_us":0,"root_tactical_completed":0,
		"root_purchase_candidates":0,"root_purchase_serviced":0,"root_purchase_complete":0,"root_purchase_us":0,
		"principal_variation":[], "candidates":[], "cutoff":false, "fallback":true}
	if not _can_fork(world): return _finish()
	# Independent randomness remains useful for uncertain tool effects. New
	# market draws are masked in every descendant: no hidden future card can
	# guarantee recovery after an irreversible dismissal or purchase.
	var sample_seed := hash([owner, int(world.time * 1000.0), world._supply_count, world._next_offer, 87121])
	var root := _node(world.fork_for_bot(sample_seed), owner)
	_reserve_release(root.world)
	var ranked := _rank(root, true)
	var growing := _growth_pass(root)
	if growing or not ranked: return _finish()
	if root.ranked.is_empty(): return _finish()
	var frontier: Array = root.ranked.slice(0, int(policy.search_root_width))
	_include_wait(root.ranked, frontier)
	if not deepen: return _finish()
	for depth in range(2, int(policy.search_max_depth) + 1):
		var rows := []
		var best := {}
		var best_value := [-INF, -INF]
		for option in frontier:
			if not _open(): break
			var value := _solve(option.child, depth - 1, [-INF, -INF], [INF, INF])
			if stopped or value.is_empty(): break
			var row := _row(option, value.value)
			rows.append(row)
			if best.is_empty() or _greater(value.value, best_value):
				best_value = value.value
				best = {"action":option.action, "line":[_step(root, option.action)] + value.line,
					"evaluation":option.child.value.detail}
		if stopped or not _open() or rows.size() != frontier.size(): break
		rows.sort_custom(func(a, b): return _greater(_utility(a), _utility(b)))
		_publish(best.action, rows, best.line, depth, true, best.evaluation)
		if absf(best_value[0]) >= 900000.0: break
	return _finish()

func _growth_pass(root: Dictionary) -> bool:
	if growth_reserve_us<=0: return false
	growth_reserve_us=0
	# Reaching the ordinary phase's local deadline does not cancel the
	# reserved growth phase. User cancellation and the real deadline still do.
	stopped=false
	if not _open() or not result.get("root_complete",false) or not result.has("action"): return false
	var incumbent := {}
	for option in root.ranked:
		if option.action==result.action:
			incumbent=option.child.value.duplicate(true)
			break
	if incumbent.is_empty() or incumbent.detail.get("terminal",false): return false
	# Ordinary root children are observed half a period after their command.
	# Growth starts at the root: compare both estimates on that same clock.
	for forecast in incumbent.detail.sides: evaluator._offset_forecast(forecast,half_period)
	if result.action.kind!="wait": incumbent.detail.sides[seat].required_actions+=1
	if result.action.kind=="buy":
		# The root purchase already disappeared from the child's market and
		# cash balance. Preserve that paid quote when comparing enemy plans.
		incumbent.detail.sides[seat].forecast_purchases[int(result.action.offer)]={"at":0.0,"owner":seat}
	incumbent.score=clampf(1000.0*evaluator._race(incumbent.detail.sides,seat),-Evaluation.WIN*0.5,Evaluation.WIN*0.5)
	incumbent.tie_score=int(incumbent.detail.sides[1-seat].required_actions)-int(incumbent.detail.sides[seat].required_actions)
	incumbent["evaluation_mode"]=result.evaluation_layer
	var refiner := GrowthSearch.new()
	var status: Dictionary = refiner.refine(root.world,seat,policy,_until(),incumbent,func(action,value,plan):
		var rows := [{"kind":action.kind,"intent":action.get("intent",action.kind),
			"score":value.score,"tie_score":value.get("tie_score",0.0),"reason":"持续生产与再投资的完整规则推演"}]
		var line := []
		for command in plan.commands:
			line.append(command.action.merged({"seat":seat,"seconds":root.world.time+float(command.at)}))
		_publish(action,rows,line,1,true,value.detail,true),cancelled,root_action_filter)
	result["root_growth"]=status
	_open()
	return int(status.get("choices",0))>0

func _finish() -> Dictionary:
	result.search_nodes = nodes
	result.evaluated = evaluated
	result.cutoff = stopped
	result.cleanup_reserve_us = cleanup_us
	return result

func _open() -> bool:
	if Time.get_ticks_usec() >= _until() or (cancelled.is_valid() and cancelled.call()): stopped = true
	return not stopped

func _until() -> int:
	return deadline - cleanup_us - growth_reserve_us

func _reserve_release(world: OffWorkState) -> void:
	# Cached branch worlds have a measurable destruction cost. Reserve it as
	# the tree grows, rather than returning a choice on time and freeing the
	# entire tree after the caller's deadline.
	cleanup_us += _release_cost(world)

func _release_cost(world: OffWorkState) -> int:
	return Budget.release_cost(world)

func _can_fork(world: OffWorkState) -> bool:
	if not _open(): return false
	# Copying a coherent rules snapshot is indivisible. Short UI deadlines use
	# the bounded emergency dispatcher instead of starting a known-late copy.
	if _until() - Time.get_ticks_usec() <= Budget.fork_cost(world):
		stopped = true
	return not stopped

func _node(world: OffWorkState, actor: int, production_commitments: Dictionary = {}, purchase_commitments: Dictionary = {}) -> Dictionary:
	return {"world":world, "actor":actor, "ranked":[], "complete":false,
		"production_commitments":production_commitments.duplicate(),"purchase_commitments":purchase_commitments.duplicate()}

func _evaluate(node: Dictionary) -> bool:
	if node.has("value"): return true
	if not _open(): return false
	# This node is already at the next actor's turn. A leaf must not grant
	# both sides a free move at the same future instant, or keep postponing a
	# useful root action while charging its delay to neither side.
	var next_actions := [half_period, half_period]
	next_actions[int(node.actor)] = 0.0
	var value: Dictionary
	if not current_only:
		value=evaluator.evaluate(node.world,seat,policy,_until(),next_actions,false)
	elif result.evaluation_layer=="tactical":
		value=evaluator.evaluate_tactical(node.world,seat,policy,_until(),next_actions)
	else:
		value=evaluator.evaluate_current(node.world,seat,policy,_until(),next_actions)
		value["evaluation_mode"]="current"
	if not value.get("complete", false) or not _open():
		stopped = true
		return false
	node.value = value
	evaluated += 1
	return true

func _rank(node: Dictionary, root := false) -> bool:
	if node.complete: return true
	if not _open(): return false
	var ordinary_started := Time.get_ticks_usec()
	var generated: Dictionary = Actions.generate(node.world, int(node.actor), policy, _until(), cancelled)
	if root: result.root_candidates = generated.actions.size()
	var order := 0
	for action in generated.actions:
		if not _open(): return false
		# Live planning first advances its observation to the action time. Its
		# sampled arrivals are valid for deeper projections, not for a command
		# submitted on the real table. Headless callers omit this root filter.
		if root and root_action_filter.is_valid() and not root_action_filter.call(action):
			result.root_candidates -= 1
			result.root_unobserved += 1
			continue
		if not _can_fork(node.world): return false
		var child_world: OffWorkState = node.world.fork_search_node()
		if not Actions.apply_search_action(child_world, int(node.actor), action): continue
		# Capture the paid identity before natural events can produce coffee or
		# recruited staff of the same type during the intervening half-turn.
		var bought_ids: Array = []
		if action.kind=="buy":
			bought_ids=child_world._owner_type(int(node.actor),str(action.card_type)).filter(func(id): return not node.world.cards.has(id))
		if not child_world.advance_for_search(half_period, _until(), cancelled) or not _open():
			stopped = true
			return false
		child_world.mask_search_market(known_offer_end)
		var purchases: Dictionary = node.purchase_commitments.duplicate()
		for id in purchases.keys():
			if not child_world.cards.has(id) or action.get("ids",[]).has(id) or int(action.get("tool",-1))==int(id) or int(action.get("person",-1))==int(id): purchases.erase(id)
		for id in bought_ids:
			if child_world.cards.has(id): purchases[int(id)]=int(node.actor)
		var commitments: Dictionary = node.production_commitments.duplicate()
		if action.kind=="buy" and action.get("card_type","")=="slack":
			# Actual purchased identities survive intervening opponent replies.
			# This is search-node context, not a persistent shopping preference.
			for uid in child_world._owner_type(int(node.actor),"slack"):
				if not node.world.cards.has(uid): commitments[int(uid)] = int(node.actor)
		var child := _node(child_world, 1 - int(node.actor), commitments, purchases)
		_reserve_release(child_world)
		nodes += 1
		if not _evaluate(child): return false
		var entry := {"action":action, "child":child, "score":child.value.score, "tie_score":child.value.get("tie_score", 0.0), "order":order,
			"production_possible":evaluator.has_production_continuation(child_world,commitments,false),
			"purchase_possible":purchase_continuations.available(child_world,purchases)}
		order += 1
		node.ranked.append(entry)
		if root:
			result.completed_candidates += 1
			result.root_ordinary_us = Time.get_ticks_usec()-ordinary_started
			var intent := str(action.get("intent",action.kind))
			result.root_evaluated_intents[intent] = int(result.root_evaluated_intents.get(intent,0))+1
			var best: Dictionary = node.ranked[0]
			for candidate in node.ranked:
				if _greater(_utility(candidate), _utility(best)): best = candidate
			# Same-horizon evaluations form a monotone incumbent even when a
			# small budget can only inspect a prefix of all legal root actions.
			if not result.has("action") or best.action != result.action:
				_publish(best.action, [_row(best, _utility(best))], [_step(node, best.action)], 0, false, best.child.value.detail)
			# Retain values and legal commands, not a full world for every root.
			# Recreate a branch only when refining it or entering the final beam.
			# This keeps copy-release reservations from consuming the coverage
			# budget merely because a table has many legal alternatives.
			child_world = null
			_release_option_world(entry)
	if not generated.complete or not _open():
		stopped = true
		return false
	# First cover every ordinary legal action. An ongoing recipe on the first
	# wait candidate must never prevent a ready coffee/return action from being
	# evaluated. Publish this completed layer before optional continuations.
	if root: _publish_ranking(node)
	if root and (GrowthPlans.available(node.world,0) or GrowthPlans.available(node.world,1)):
		# Cover ordinary legal actions first. Then share the remaining time
		# between ordinary refinement and root growth policies. Re-running a
		# long economy after every root action multiplied its cost and left no
		# single plan enough time to finish a real recruitment/upgrade batch.
		growth_reserve_us=maxi(0,(_until()-Time.get_ticks_usec())/2)
	var pending: Array = node.ranked.filter(func(option): return option.production_possible)
	var purchases: Array = node.ranked.filter(func(option): return option.purchase_possible)
	if root and not _refine_economic_layer(node,pending.size()+purchases.size()): return false
	if root and current_only and not _refine_tactical_layer(node,pending.size()+purchases.size()): return false
	var purchase_started := Time.get_ticks_usec()
	if root: result.root_purchase_candidates=purchases.size()
	for index in purchases.size():
		if not _open(): return false
		var now := Time.get_ticks_usec()
		var task_until := now+maxi(0,(_until()-now)/(purchases.size()-index+pending.size()))
		var continuing := _extend_purchase(node,purchases[index],root,task_until)
		if root:
			_release_option_world(purchases[index])
			result.root_purchase_serviced+=1
			result.root_purchase_us=Time.get_ticks_usec()-purchase_started
			if purchases[index].child.value.get("purchase_extension",{}).get("complete",true): result.root_purchase_complete+=1
		if not continuing: return false
	var production_started := Time.get_ticks_usec()
	if root: result.root_production_candidates = pending.size()
	for index in pending.size():
		if not _open(): return false
		# Share the actual remaining budget among unserved continuations. A
		# local cutoff keeps completed plans and yields to the next candidate;
		# it is not a global search cancellation. Do not trim by ordinary score.
		var now := Time.get_ticks_usec()
		var task_until := now + maxi(0,(_until()-now)/(pending.size()-index))
		var continuing := _extend_option(node,pending[index],root,task_until)
		if root:
			_release_option_world(pending[index])
			result.root_production_serviced += 1
			result.root_production_us = Time.get_ticks_usec()-production_started
			if pending[index].child.value.get("production_extension",{}).get("complete",true): result.root_production_complete += 1
		if not continuing: return false
	var maximizing := int(node.actor) == seat
	node.ranked.sort_custom(func(a, b):
		if _utility(a) == _utility(b): return a.order < b.order
		return _greater(_utility(a), _utility(b)) if maximizing else _greater(_utility(b), _utility(a)))
	node.complete = true
	if root: _publish_ranking(node)
	_trim_rank(node, int(policy.search_root_width) if root else int(policy.search_reply_width))
	if root:
		for option in node.ranked:
			if not _materialize(node,option,_until()):
				stopped = true
				return false
	return true

func _release_option_world(option: Dictionary) -> void:
	if option.child.world == null: return
	var cost := _release_cost(option.child.world)
	option.child.world = null
	cleanup_us -= cost

func _materialize(node: Dictionary, option: Dictionary, until: int) -> bool:
	if option.child.world != null: return true
	if not _open() or until-Time.get_ticks_usec()<=Budget.fork_cost(node.world)+Budget.release_cost(node.world): return false
	var world: OffWorkState = node.world.fork_search_node()
	if not Actions.apply_search_action(world,int(node.actor),option.action): return false
	if not world.advance_for_search(half_period,until,cancelled): return false
	world.mask_search_market(known_offer_end)
	option.child.world = world
	_reserve_release(world)
	return true

func _publish_ranking(node: Dictionary, retain_completed := false) -> void:
	if node.ranked.is_empty(): return
	var ranking: Array = node.ranked.duplicate()
	ranking.sort_custom(func(a,b): return a.order<b.order if _utility(a)==_utility(b) else _greater(_utility(a),_utility(b)))
	var rows := []
	for option in ranking: rows.append(_row(option,_utility(option)))
	var best: Dictionary = ranking[0]
	_publish(best.action,rows,[_step(node,best.action)],1,true,best.child.value.detail,retain_completed)

func _refine_economic_layer(node: Dictionary, production_count: int) -> bool:
	var values := []
	var started := Time.get_ticks_usec()
	for index in node.ranked.size():
		if not _open(): return false
		var now := Time.get_ticks_usec()
		# Reserve the same per-task opportunity for every remaining economic
		# comparison and production continuation. A failed rich layer is never
		# mixed with current-only values and does not consume the production pass.
		var task_until := now + maxi(0,(_until()-now)/(node.ranked.size()-index+production_count))
		var option: Dictionary = node.ranked[index]
		if not _materialize(node,option,task_until): return _open()
		var child: Dictionary = option.child
		var clock := [half_period,half_period]
		clock[int(child.actor)] = 0.0
		var value: Dictionary = evaluator.evaluate(child.world,seat,policy,task_until,clock,false)
		_release_option_world(option)
		result.root_economic_us = Time.get_ticks_usec()-started
		if not value.get("complete",false): return _open()
		values.append(value)
		result.root_economic_completed += 1
	current_only = false
	result.evaluation_layer = "economic"
	for index in node.ranked.size():
		var option: Dictionary = node.ranked[index]
		option.child.value = values[index]
		option.score = values[index].score
		option.tie_score = values[index].get("tie_score",0.0)
	_publish_ranking(node,true)
	return _open()

func _refine_tactical_layer(node: Dictionary, continuation_count: int) -> bool:
	var values := []
	var started := Time.get_ticks_usec()
	for index in node.ranked.size():
		if not _open(): return false
		var now := Time.get_ticks_usec()
		var task_until := now+maxi(0,(_until()-now)/(node.ranked.size()-index+continuation_count))
		var option: Dictionary = node.ranked[index]
		if not _materialize(node,option,task_until): return _open()
		var clock := [half_period,half_period]
		clock[int(option.child.actor)]=0.0
		var value: Dictionary = evaluator.evaluate_tactical(option.child.world,seat,policy,task_until,clock)
		_release_option_world(option)
		result.root_tactical_us=Time.get_ticks_usec()-started
		if not value.get("complete",false): return _open()
		values.append(value)
		result.root_tactical_completed+=1
	# No partial attack model may compete with a physical-only candidate.
	for index in node.ranked.size():
		var option: Dictionary = node.ranked[index]
		option.child.value=values[index]
		option.score=values[index].score
		option.tie_score=values[index].get("tie_score",0.0)
	result.evaluation_layer="tactical"
	_publish_ranking(node,true)
	return _open()

func _extend_purchase(node: Dictionary, option: Dictionary, root: bool, task_until: int) -> bool:
	if not _materialize(node,option,task_until):
		option.child.value["purchase_extension"]={"complete":false,"plans":0,"examined":0}
		return _open()
	var clock := [half_period,half_period]
	clock[int(option.child.actor)]=0.0
	var value: Dictionary = purchase_continuations.extend(option.child.world,seat,policy,task_until,clock,
		option.child.value,option.child.purchase_commitments,cancelled)
	option.child.value=value
	option.score=value.score
	option.tie_score=value.get("tie_score",0.0)
	if root: _publish_ranking(node,true)
	return _open()

func _extend_option(node: Dictionary, option: Dictionary, root: bool, task_until: int = -1) -> bool:
	if not _open(): return false
	if not _materialize(node,option,_until() if task_until<0 else task_until):
		option.child.value["production_extension"] = {"complete":false,"plans":0,"examined":0}
		return _open()
	var next_actions := [half_period,half_period]
	next_actions[int(option.child.actor)] = 0.0
	var observed: Dictionary = option.action.merged({"actor":node.actor,"sustained_growth":false})
	var value: Dictionary = evaluator.extend_production(option.child.world,seat,policy,_until() if task_until<0 else task_until,next_actions,option.child.value,observed,cancelled,
		option.child.production_commitments,current_only)
	# The value contains only completed candidates, even when enumeration of
	# the next alternative hits the deadline. Publish that incumbent before
	# stopping; no further rule work is required to keep it.
	option.child.value = value
	option.score = value.score
	option.tie_score = value.get("tie_score",0.0)
	if root: _publish_ranking(node,true)
	return _open()

func _trim_rank(node: Dictionary, width: int) -> void:
	# Evaluate every option, but retain rule-state copies only for branches
	# that can enter deeper search. Free the rest while their release time is
	# still reserved, instead of collecting all discarded worlds at the end.
	var ranked: Array = node.ranked
	var retained: Array = ranked.slice(0, width)
	_include_wait(ranked, retained)
	var kept := {}
	for option in retained:
		if option.child.world != null: kept[option.child.world.get_instance_id()] = true
	var released := 0
	for option in ranked:
		if option.child.world != null and not kept.has(option.child.world.get_instance_id()): released += _release_cost(option.child.world)
	node.ranked = retained
	ranked.clear()
	cleanup_us -= released

func _solve(node: Dictionary, remaining: int, alpha: Array, beta: Array) -> Dictionary:
	if not _open(): return {}
	if remaining == 0 or node.world.winner >= 0:
		if not _evaluate(node): return {}
		return {"value":_utility(node.value), "line":[]}
	if not _rank(node): return {}
	if node.ranked.is_empty():
		if not _evaluate(node): return {}
		return {"value":_utility(node.value), "line":[]}
	var options: Array = node.ranked.slice(0, int(policy.search_reply_width))
	_include_wait(node.ranked, options)
	var maximizing := int(node.actor) == seat
	var best := [-INF, -INF] if maximizing else [INF, INF]
	var line := []
	for option in options:
		var value := _solve(option.child, remaining - 1, alpha, beta)
		if stopped or value.is_empty(): return {}
		var score: Array = value.value
		if line.is_empty() or (_greater(score, best) if maximizing else _greater(best, score)):
			best = score
			line = [_step(node, option.action)] + value.line
		if maximizing and _greater(best, alpha): alpha = best
		elif not maximizing and _greater(beta, best): beta = best
		if not _greater(beta, alpha): break
	return {"value":best, "line":line}

func _utility(value: Dictionary) -> Array:
	# Discrete batch forecasts can differ by floating round-off alone. Snap
	# only that numerical noise, then prefer a continuation requiring fewer
	# still-unexecuted commands. This is shared by every leaf and both players.
	return [snappedf(float(value.score), SCORE_EPSILON), float(value.get("tie_score", 0.0))]

func _greater(a: Array, b: Array) -> bool:
	return a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])

func _include_wait(ranked: Array, choices: Array) -> void:
	if choices.any(func(row): return row.action.kind == "wait"): return
	for row in ranked:
		if row.action.kind == "wait":
			choices.append(row)
			return

func _row(option: Dictionary, score: Array) -> Dictionary:
	var action: Dictionary = option.action
	var row := {"kind":action.kind, "score":score[0], "tie_score":score[1], "base_score":option.score, "base_tie_score":option.get("tie_score", 0.0),
		"reason":action.get("reason", action.get("intent", action.kind))}
	for key in ["card_type", "offer", "group", "tool", "person", "intent"]:
		if action.has(key): row[key] = action[key]
	return row

func _step(node: Dictionary, action: Dictionary) -> Dictionary:
	return action.merged({"seat":node.actor, "seconds":node.world.time}, true)

func _publish(action: Dictionary, rows: Array, line: Array, depth: int, complete: bool, detail: Dictionary,
		retain_completed := false) -> void:
	if not retain_completed and not _open(): return
	result.merge({"action":action, "reason":"比较双方预计清空工作的时间：" + str(action.get("reason", action.get("intent", action.kind))),
		"search_depth":depth, "depth":depth, "search_nodes":nodes, "evaluated":evaluated,
		"root_complete":complete, "candidates":rows.slice(0, 8), "principal_variation":line,
		"evaluation":detail, "fallback":false}, true)
	if publisher.is_valid(): publisher.call(result.duplicate(true))
