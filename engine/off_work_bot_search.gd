# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## One action model, one race evaluation, and one progressive search. Every
## generated root gets the same real-rule preview before the deeper beam is
## selected. A partially explored deeper layer never replaces a complete one.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
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
var result := {}
var cleanup_us := 1000

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
	# Projection caches and GDScript containers also need time to release.
	# Scale that fixed part with the available budget, in addition to the
	# measured size of retained rule-state copies below.
	cleanup_us = clampi((until - Time.get_ticks_usec()) / 20, 1000, 100000)
	publisher = publish
	root_action_filter = observed_action
	known_offer_end = world._next_offer
	result = {"algorithm":"race_search_v2", "search_depth":0, "search_nodes":0,
		"evaluated":0, "root_complete":false, "root_candidates":0, "completed_candidates":0, "root_unobserved":0,
		"principal_variation":[], "candidates":[], "cutoff":false, "fallback":true}
	if not _can_fork(world): return _finish()
	# Independent randomness remains useful for uncertain tool effects. New
	# market draws are masked in every descendant: no hidden future card can
	# guarantee recovery after an irreversible dismissal or purchase.
	var sample_seed := hash([owner, int(world.time * 1000.0), world._supply_count, world._next_offer, 87121])
	var root := _node(world.fork_for_bot(sample_seed), owner)
	_reserve_release(root.world)
	if not _rank(root, true): return _finish()
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
	return deadline - cleanup_us

func _reserve_release(world: OffWorkState) -> void:
	# Cached branch worlds have a measurable destruction cost. Reserve it as
	# the tree grows, rather than returning a choice on time and freeing the
	# entire tree after the caller's deadline.
	cleanup_us += _release_cost(world)

func _release_cost(world: OffWorkState) -> int:
	return 250 + world.cards.size() * 2 + world.groups.size() * 6

func _can_fork(world: OffWorkState) -> bool:
	if not _open(): return false
	# Copying a coherent rules snapshot is indivisible. Short UI deadlines use
	# the bounded emergency dispatcher instead of starting a known-late copy.
	if _until() - Time.get_ticks_usec() <= 250 + world.cards.size() * 6 + world.groups.size() * 12:
		stopped = true
	return not stopped

func _node(world: OffWorkState, actor: int) -> Dictionary:
	return {"world":world, "actor":actor, "ranked":[], "complete":false}

func _evaluate(node: Dictionary) -> bool:
	if node.has("value"): return true
	if not _open(): return false
	# This node is already at the next actor's turn. A leaf must not grant
	# both sides a free move at the same future instant, or keep postponing a
	# useful root action while charging its delay to neither side.
	var next_actions := [half_period, half_period]
	next_actions[int(node.actor)] = 0.0
	var value: Dictionary = evaluator.evaluate(node.world, seat, policy, _until(), next_actions)
	if not value.get("complete", false) or not _open():
		stopped = true
		return false
	node.value = value
	evaluated += 1
	return true

func _rank(node: Dictionary, root := false) -> bool:
	if node.complete: return true
	if not _open(): return false
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
		if not child_world.advance_for_search(half_period, _until(), cancelled) or not _open():
			stopped = true
			return false
		child_world.mask_search_market(known_offer_end)
		var child := _node(child_world, 1 - int(node.actor))
		_reserve_release(child_world)
		nodes += 1
		if not _evaluate(child): return false
		var entry := {"action":action, "child":child, "score":child.value.score, "tie_score":child.value.get("tie_score", 0.0), "order":order}
		order += 1
		node.ranked.append(entry)
		if root:
			result.completed_candidates += 1
			var best: Dictionary = node.ranked[0]
			for candidate in node.ranked:
				if _greater(_utility(candidate), _utility(best)): best = candidate
			# Same-horizon evaluations form a monotone incumbent even when a
			# small budget can only inspect a prefix of all legal root actions.
			if not result.has("action") or best.action != result.action:
				_publish(best.action, [_row(best, _utility(best))], [_step(node, best.action)], 0, false, best.child.value.detail)
	if not generated.complete or not _open():
		stopped = true
		return false
	var maximizing := int(node.actor) == seat
	node.ranked.sort_custom(func(a, b):
		if _utility(a) == _utility(b): return a.order < b.order
		return _greater(_utility(a), _utility(b)) if maximizing else _greater(_utility(b), _utility(a)))
	node.complete = true
	if root and not node.ranked.is_empty():
		var rows := []
		for option in node.ranked: rows.append(_row(option, _utility(option)))
		var best: Dictionary = node.ranked[0]
		_publish(best.action, rows, [_step(node, best.action)], 1, true, best.child.value.detail)
	_trim_rank(node, int(policy.search_root_width) if root else int(policy.search_reply_width))
	return true

func _trim_rank(node: Dictionary, width: int) -> void:
	# Evaluate every option, but retain rule-state copies only for branches
	# that can enter deeper search. Free the rest while their release time is
	# still reserved, instead of collecting all discarded worlds at the end.
	var ranked: Array = node.ranked
	var retained: Array = ranked.slice(0, width)
	_include_wait(ranked, retained)
	var kept := {}
	for option in retained: kept[option.child.world.get_instance_id()] = true
	var released := 0
	for option in ranked:
		if not kept.has(option.child.world.get_instance_id()): released += _release_cost(option.child.world)
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

func _publish(action: Dictionary, rows: Array, line: Array, depth: int, complete: bool, detail: Dictionary) -> void:
	if not _open(): return
	result.merge({"action":action, "reason":"比较双方预计清空工作的时间：" + str(action.get("reason", action.get("intent", action.kind))),
		"search_depth":depth, "depth":depth, "search_nodes":nodes, "evaluated":evaluated,
		"root_complete":complete, "candidates":rows.slice(0, 8), "principal_variation":line,
		"evaluation":detail, "fallback":false}, true)
	if publisher.is_valid(): publisher.call(result.duplicate(true))
