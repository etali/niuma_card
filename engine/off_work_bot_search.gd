# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Legal first actions and their continuations share actual rules and one
## completion-time objective. Only completed evaluations can be published.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")
const GrowthSearch = preload("res://engine/off_work_bot_growth_search.gd")
const ExecutionPlan = preload("res://engine/off_work_bot_execution_plan.gd")
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
var growth_reserve_us := 0
var saved_action := {}
var execution_context := {}

func search(world: OffWorkState, owner: int, settings: Dictionary, until: int,
		cancel: Callable = Callable(), publish: Callable = Callable(), deepen := true,
		observed_action: Callable = Callable(), continuation_action: Dictionary = {}, continuation_context: Dictionary = {}) -> Dictionary:
	deadline = until
	cancelled = cancel
	policy = settings
	seat = owner
	half_period = float(policy.think_seconds) * 0.5
	stopped = false
	nodes = 0
	evaluated = 0
	growth_reserve_us = 0
	# Projection caches and GDScript containers also need time to release.
	# Scale that fixed part with the available budget, in addition to the
	# measured size of retained rule-state copies below.
	cleanup_us = clampi((until - Time.get_ticks_usec()) / 20, 1000, 100000)
	publisher = publish
	root_action_filter = observed_action
	saved_action=continuation_action
	execution_context=continuation_context
	known_offer_end = world._next_offer
	result = {"algorithm":"completion_search_v3", "search_depth":0, "search_nodes":0,
		"evaluated":0, "root_complete":false, "root_candidates":0, "completed_candidates":0, "root_unobserved":0,
		"short_search_depth":0,"short_search_nodes":0,"short_root_candidates":0,
		"root_ordinary_us":0,"root_production_us":0,"root_production_candidates":0,"root_production_serviced":0,
		"root_production_complete":0,"root_evaluated_intents":{},
		"root_economic_us":0,"root_economic_completed":0,"evaluation_layer":"current",
		"root_tactical_us":0,"root_tactical_completed":0,
		"root_purchase_candidates":0,"root_purchase_serviced":0,"root_purchase_complete":0,"root_purchase_us":0,
		"observed_card_end":world._next_card,"observed_group_end":world._next_group,
		"principal_variation":[], "candidates":[], "cutoff":false, "fallback":true}
	if not _can_fork(world): return _finish()
	# Independent randomness remains useful for uncertain tool effects. New
	# market draws are masked in every descendant: no hidden future card can
	# guarantee recovery after an irreversible dismissal or purchase.
	var sample_seed := hash([owner, int(world.time * 1000.0), world._supply_count, world._next_offer, 87121])
	var root := _node(world.fork_for_bot(sample_seed), owner)
	_reserve_release(root.world)
	# Every position and legal first action receives the same long-horizon
	# opportunity. Production-card ownership does not enable a privileged pass.
	growth_reserve_us=maxi(0,(_until()-Time.get_ticks_usec())*3/5) if deepen else 0
	result["root_growth_reserved_us"]=growth_reserve_us
	var ranked := _rank(root,true)
	result["root_coverage_complete"]=result.get("root_complete",false)
	if ranked and deepen: _short_search(root)
	_growth_pass(root)
	return _finish()

## Adversarial short prefixes retain actual enemy actions. A completed layer
## supplies the SAME rule-executed prefixes to the longer continuation tree.
func _short_search(root: Dictionary) -> void:
	var started_nodes := nodes
	var ranking: Array=root.ranked.duplicate()
	ranking.sort_custom(func(a,b):return a.order<b.order if _utility(a)==_utility(b) else _greater(_utility(a),_utility(b)))
	var frontier: Array=ranking.slice(0,int(policy.search_root_width))
	_include_wait(ranking,frontier)
	result.short_root_candidates=frontier.size()
	for depth in range(2,int(policy.search_max_depth)+1):
		var rows := []
		var choices := []
		var best := {}
		var best_value := [-INF,-INF]
		for option in frontier:
			if not _materialize(root,option,_until()): break
			var value := _solve(option.child,depth-1,[-INF,-INF],[INF,INF])
			if stopped or value.is_empty(): break
			var line: Array = [_step(root,option.action)]+value.line
			rows.append(_row(option,value.value))
			choices.append({"option":option,"seed":_continuation_seed(root,option.action,line,value.leaf_value)})
			if best.is_empty() or _greater(value.value,best_value):
				best_value=value.value
				best={"action":option.action,"line":line,"evaluation":value.leaf_value.detail}
		if stopped or not _open() or rows.size()!=frontier.size(): break
		for choice in choices: choice.option["continuation_seed"]=choice.seed
		rows.sort_custom(func(a,b):return _greater(_utility(a),_utility(b)))
		result.short_search_depth=depth
		_publish(best.action,rows,best.line,depth,true,best.evaluation,false,depth*half_period)
		if absf(best_value[0])>=900000.0: break
	result.short_search_nodes=nodes-started_nodes
	# Release adversarial branches before the next phase; long search replays
	# their compact real commands, never a score from a different position.
	for option in root.ranked:
		_release_tree(option.child)

func _continuation_seed(root: Dictionary, action: Dictionary, line: Array, value: Dictionary) -> Dictionary:
	var commands := []
	var replies := []
	var next := 0.0
	for step in line:
		var command: Dictionary=step.duplicate(true)
		command.erase("seat")
		command.erase("seconds")
		var at := float(step.seconds)-float(root.world.time)
		var entry := {"at":at,"action":command}
		if int(step.seat)==seat:
			commands.append(entry)
			next=at+half_period*2.0
		else: replies.append(entry)
	return {"action":action,"value":value,"elapsed":line.size()*half_period,
		"commands":commands,"replies":replies,"next_action":next,"joint_prefix":true}

func _release_tree(node: Dictionary) -> void:
	for option in node.ranked: _release_tree(option.child)
	node.ranked.clear()
	if node.world!=null:
		cleanup_us-=_release_cost(node.world)
		node.world=null

func _growth_pass(root: Dictionary) -> bool:
	if growth_reserve_us<=0: return false
	growth_reserve_us=0
	# Reaching the ordinary phase's local deadline does not cancel the
	# reserved growth phase. User cancellation and the real deadline still do.
	stopped=false
	# A completed candidate is a valid incumbent even if other ordinary
	# candidates did not fit. Its score still uses the same completion model;
	# incomplete values are never admitted to this comparison.
	if not _open() or not result.has("action"): return false
	var incumbent := {}
	var incumbent_seed := {}
	for option in root.ranked:
		if option.action==result.action:
			incumbent_seed=option.get("continuation_seed",{})
			incumbent=incumbent_seed.get("value",option.child.value).duplicate(true)
			break
	if incumbent.is_empty() or incumbent.detail.get("terminal",false): return false
	# Ordinary root children are observed half a period after their command.
	# Growth starts at the root: compare both estimates on that same clock.
	var root_elapsed := float(result.get("forecast_root_offset_seconds",half_period))
	for forecast in incumbent.detail.sides: evaluator._offset_forecast(forecast,root_elapsed)
	if incumbent_seed.is_empty():
		if result.action.kind=="buy":
			incumbent.detail.sides[seat].forecast_purchases[int(result.action.offer)]={"at":0.0,"owner":seat}
	else:
		for side in 2:
			var prefix: Array=incumbent_seed.commands if side==seat else incumbent_seed.replies
			for command in prefix:
				if command.action.kind!="wait" and float(command.at)>1e-8: incumbent.detail.sides[side].required_actions+=1
				if command.action.kind=="buy":
					incumbent.detail.sides[side].forecast_purchases[int(command.action.offer)]={"at":command.at,"owner":side}
	incumbent.score=clampf(1000.0*evaluator._race(incumbent.detail.sides,seat),-Evaluation.WIN*0.5,Evaluation.WIN*0.5)
	incumbent.tie_score=int(incumbent.detail.sides[1-seat].required_actions)-int(incumbent.detail.sides[seat].required_actions)
	incumbent["evaluation_mode"]=result.evaluation_layer
	var seeds := []
	var replies := [{"kind":"wait","intent":"wait"}]
	# Short search supplies a common finite response set, not a gate on which
	# first actions are allowed to discover delayed investment returns.
	for option in root.ranked:
		seeds.append({"action":option.action,"value":option.child.value,"elapsed":half_period,
			"next_action":2.0*half_period})
		var prefix: Dictionary=option.get("continuation_seed",{})
		var found: Array=prefix.get("replies",[])
		if found.is_empty(): continue
		var reply: Dictionary=found[0].action
		if not _source_reply(root.world,reply): continue
		if not replies.any(func(existing):return ExecutionPlan._same(existing,reply)):
			replies.append(reply.duplicate(true))
	# Re-evaluate the current choice under the same reply set before allowing
	# a new model to replace it. This is computation order, never a score bonus.
	for index in seeds.size():
		if ExecutionPlan._same(seeds[index].action,result.action):
			var first: Dictionary=seeds.pop_at(index)
			seeds.push_front(first)
			break
	incumbent["action"]=result.action.duplicate(true)
	var refiner := GrowthSearch.new()
	var status: Dictionary = refiner.refine(root.world,seat,policy,_until(),incumbent,func(action,value,plan):
		var rows := [{"kind":action.kind,"intent":action.get("intent",action.kind),
			"score":value.score,"tie_score":value.get("tie_score",0.0),"reason":"同一合法动作空间的长期完工时间比较"}]
		var line := []
		for command in plan.commands:
			line.append(command.action.merged({"seat":seat,"seconds":root.world.time+float(command.at)}))
		for reply in plan.get("replies",[]):
			line.append(reply.action.merged({"seat":1-seat,"seconds":root.world.time+float(reply.at)}))
		line.sort_custom(func(a,b):return a.seconds<b.seconds if a.seconds!=b.seconds else a.seat<b.seat)
		_publish(action,rows,line,int(plan.get("growth",{}).get("depth",1)),bool(result.root_coverage_complete),value.detail,true,0.0),cancelled,root_action_filter,execution_context,seeds,replies)
	result["root_growth"]=status
	result["root_continuation"]=status
	nodes+=int(status.get("examined",0))
	evaluated+=int(status.get("evaluated",0))
	_open()
	return int(status.get("choices",0))>0

func _source_reply(world: OffWorkState, action: Dictionary) -> bool:
	for id in action.get("ids",[]):
		if not world.cards.has(id): return false
	for key in ["tool","person"]:
		if int(action.get(key,-1))>=0 and not world.cards.has(int(action[key])): return false
	if int(action.get("group",-1))>=0 and not world.groups.has(int(action.group)): return false
	if action.kind=="buy" and not world.offers.any(func(offer):return not offer.is_empty() and int(offer.id)==int(action.offer)): return false
	return true

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

func _node(world: OffWorkState, actor: int) -> Dictionary:
	return {"world":world, "actor":actor, "ranked":[], "complete":false}

func _evaluate(node: Dictionary) -> bool:
	if node.has("value"): return true
	if not _open(): return false
	var next_actions := [half_period, half_period]
	next_actions[int(node.actor)] = 0.0
	var value := evaluator.evaluate_current(node.world,seat,policy,_until(),next_actions)
	value["evaluation_mode"]="current"
	if not value.get("complete", false) or not _open():
		stopped = true
		return false
	# Bind the physical tail while this evaluated leaf still exists. A later
	# execution plan is prepared against the observed root, where groups and
	# people created by the prefix do not yet have these identities.
	if not value.get("detail",{}).get("terminal",false):
		for side in 2:
			var forecast: Dictionary=value.detail.sides[side]
			forecast["forecast_steps"]=ExecutionPlan.physical_steps(node.world,side,
				forecast.get("forecast_commands",[]),0.0,{},_until())
	if not _open(): return false
	node.value = value
	evaluated += 1
	return true

func _rank(node: Dictionary, root := false) -> bool:
	if node.complete: return true
	if not _open(): return false
	var ordinary_started := Time.get_ticks_usec()
	var generated: Dictionary = Actions.generate(node.world, int(node.actor), policy, _until(), cancelled)
	if root and not saved_action.is_empty() and saved_action.get("kind","wait")!="wait":
		# Keep a saved semantic batch available without a preferred position.
		# Matching generated actions inherit its identity solely for consumption.
		var found := false
		for index in generated.actions.size():
			if ExecutionPlan._same(generated.actions[index],saved_action):
				generated.actions[index]=saved_action
				found=true
				break
		if not found: generated.actions.append(saved_action)
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
		var child := _node(child_world, 1-int(node.actor))
		_reserve_release(child_world)
		nodes += 1
		if not _evaluate(child): return false
		var entry := {"action":action, "child":child, "score":child.value.score, "tie_score":child.value.get("tie_score", 0.0), "order":order}
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
	if root:
		result.short_search_depth=1
		_publish_ranking(node)
		node.complete=true
		return true
	var maximizing := int(node.actor)==seat
	node.ranked.sort_custom(func(a,b):
		if _utility(a)==_utility(b): return a.order<b.order
		return _greater(_utility(a),_utility(b)) if maximizing else _greater(_utility(b),_utility(a)))
	node.complete=true
	_trim_rank(node,int(policy.search_reply_width))
	return true

func _release_option_world(option: Dictionary) -> void:
	if option.child.world == null: return
	var cost := _release_cost(option.child.world)
	option.child.world = null
	cleanup_us -= cost

func _publish_ranking(node: Dictionary, retain_completed := false) -> void:
	if node.ranked.is_empty(): return
	var ranking: Array = node.ranked.duplicate()
	ranking.sort_custom(func(a,b): return a.order<b.order if _utility(a)==_utility(b) else _greater(_utility(a),_utility(b)))
	var rows := []
	for option in ranking: rows.append(_row(option,_utility(option)))
	var best: Dictionary = ranking[0]
	_publish(best.action,rows,[_step(node,best.action)],1,true,best.child.value.detail,retain_completed)

func _utility(value: Dictionary) -> Array:
	# Discrete batch forecasts can differ by floating round-off alone. Snap
	# only that numerical noise, then prefer a continuation requiring fewer
	# still-unexecuted commands. This is shared by every leaf and both players.
	return [snappedf(float(value.score), SCORE_EPSILON), float(value.get("tie_score", 0.0))]

func _greater(a: Array, b: Array) -> bool:
	return a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])

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
		retain_completed := false, root_offset_seconds := -1.0) -> void:
	if not retain_completed and not _open(): return
	result.merge({"action":action, "reason":"比较双方预计清空工作的时间：" + str(action.get("reason", action.get("intent", action.kind))),
		"search_depth":depth, "depth":depth, "search_nodes":nodes, "evaluated":evaluated,
		"root_complete":complete, "candidates":rows.slice(0, 8), "principal_variation":line,
		"evaluation":detail, "fallback":false,
		"forecast_root_offset_seconds":half_period if root_offset_seconds<0.0 else root_offset_seconds}, true)
	if publisher.is_valid(): publisher.call(result.duplicate(true))

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
		return {"value":_utility(node.value), "line":[],"leaf_value":node.value}
	if not _rank(node): return {}
	if node.ranked.is_empty():
		if not _evaluate(node): return {}
		return {"value":_utility(node.value), "line":[],"leaf_value":node.value}
	var options: Array = node.ranked.slice(0, int(policy.search_reply_width))
	_include_wait(node.ranked, options)
	var maximizing := int(node.actor) == seat
	var best := [-INF, -INF] if maximizing else [INF, INF]
	var line := []
	var leaf_value := {}
	for option in options:
		var value := _solve(option.child, remaining - 1, alpha, beta)
		if stopped or value.is_empty(): return {}
		var score: Array = value.value
		if line.is_empty() or (_greater(score, best) if maximizing else _greater(best, score)):
			best = score
			line = [_step(node, option.action)] + value.line
			leaf_value=value.leaf_value
		if maximizing and _greater(best, alpha): alpha = best
		elif not maximizing and _greater(beta, best): beta = best
		if not _greater(beta, alpha): break
	return {"value":best, "line":line,"leaf_value":leaf_value}


func _include_wait(ranked: Array, choices: Array) -> void:
	if choices.any(func(row): return row.action.kind == "wait"): return
	for row in ranked:
		if row.action.kind == "wait":
			choices.append(row)
			return
