# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Alternating minimax on isolated copies of the actual continuous-time game.
## The existing planner orders legal candidate commands. Only settled branch
## positions are scored here. A partial depth never replaces a completed one.
const Planner = preload("res://engine/off_work_bot_planner.gd")
const WIN := 1000000.0

var seat: int
var deadline: int
var cancelled: Callable
var policy: Dictionary
var opponent_policy: Dictionary
var period: float
var reply_width: int
var sample_seed: int
var nodes := 0
var stopped := false
var generator := Planner.new()

func search(game: OffWorkState, owner: int, settings: Dictionary, finalists: Array, until: int, cancel: Callable,
		publish: Callable = Callable()) -> Dictionary:
	nodes = 0
	stopped = false
	seat = owner
	policy = OffWorkConfig.merge_bot_policy(game.config.rules.bot, settings)
	# The purchase gate belongs to the actual decision. Future branches must
	# consider that purchasing may be possible, using the same scenarios for all roots.
	policy.buy_chance = 1.0
	# A restriction on our purchasing or tool preferences is not a rule that
	# binds the other player. Model their replies using the visible card pool.
	opponent_policy = policy.duplicate()
	opponent_policy.purchase_priority = game.config.cards.keys().filter(func(k): return game.config.can_purchase(k))
	opponent_policy.tool_priority = game.config.cards.keys().filter(func(k): return game.config.category(k) in ["tool", "ingredient"])
	opponent_policy.min_reserve = 0
	period = float(policy.think_seconds)
	var max_depth := clampi(int(policy.search_max_depth), 1, OffWorkConfig.MAX_BOT_SEARCH_DEPTH)
	var root_width := clampi(int(policy.search_root_width), 1, OffWorkConfig.MAX_BOT_SEARCH_WIDTH)
	reply_width = clampi(int(policy.search_reply_width), 1, OffWorkConfig.MAX_BOT_SEARCH_WIDTH)
	deadline = until
	cancelled = cancel
	sample_seed = hash([owner, int(game.time * 1000.0), game._supply_count, game._next_offer, 63187])
	var result := {"search_depth":0, "search_nodes":0, "principal_variation":[], "cutoff":false}
	if finalists.size() < 2: return result
	if not _can_fork(game):
		result.cutoff = true
		return result
	var world := game.fork_for_bot(sample_seed)
	var root := _node(world, owner)
	root.options = finalists.slice(0, root_width)
	# Saving cash or leaving a nearly finished group alone is a legal
	# alternative even when the static shortlist is full of positive actions.
	if not root.options.any(func(option): return option.action.kind == "wait"):
		root.options.append({"action":{"kind":"wait"}, "score":0.0, "reason":"保持当前组合与现金"})
	for ply in range(1, max_depth + 1):
		var rows := []
		var best := {}
		var best_score := -INF
		for index in root.options.size():
			var child := _child(root, index)
			if stopped: break
			if child.is_empty(): continue
			var value := _solve(child, ply - 1, -INF, INF)
			if stopped: break
			var opt: Dictionary = root.options[index]
			var row := {"kind":opt.action.kind, "score":value.score, "base_score":opt.score, "reason":opt.reason}
			for key in ["card_type", "offer", "group", "tool", "person"]:
				if opt.action.has(key): row[key] = opt.action[key]
			rows.append(row)
			if float(value.score) > best_score:
				best_score = value.score
				best = {"action":opt.action, "reason":opt.reason, "variation":[_step(root, opt.action)] + value.line}
		if stopped or not _open() or best.is_empty(): break
		rows.sort_custom(func(a, b): return a.score > b.score)
		result.action = best.action
		var route := PackedStringArray()
		for step in best.variation:
			var who := "我方" if int(step.seat) == seat else "对手"
			route.append(who + _step_label(step, game.config))
		result.reason = "%s；分支推演：%s" % [best.reason, " → ".join(route)]
		result.candidates = rows
		result.principal_variation = best.variation
		result.search_depth = ply
		result.search_nodes = nodes
		if publish.is_valid(): publish.call(result)
		if best_score > WIN * 0.9: break
	result.search_nodes = nodes
	result.cutoff = stopped
	return result

func _open() -> bool:
	if Time.get_ticks_usec() >= deadline or (cancelled.is_valid() and cancelled.call()):
		stopped = true
	return not stopped

func _can_fork(world: OffWorkState) -> bool:
	# A deep copy and a single rules event are indivisible. Do not start one
	# when a tight external deadline cannot accommodate this board.
	var reserve := 250 + 10 * world.cards.size() + 12 * world.groups.size()
	if not _open() or deadline - Time.get_ticks_usec() <= reserve:
		stopped = true
	return not stopped

func _node(world: OffWorkState, actor: int) -> Dictionary:
	return {"world":world, "actor":actor, "children":{}}

func _step_label(step: Dictionary, config: RefCounted) -> String:
	var names := {"wait":"等待", "move":"调组", "dismiss":"开除", "buy":"购买", "activate":"使用"}
	var label: String = names.get(step.kind, step.kind)
	return label + str(config.cards.get(step.get("card_type",""), {}).get("name",""))

func _step(parent: Dictionary, action: Dictionary) -> Dictionary:
	var step := {"seat":parent.actor, "seconds":parent.world.time, "kind":action.kind}
	for key in ["card_type", "offer", "group", "tool", "person", "ids"]:
		if action.has(key): step[key] = action[key]
	if action.has("tool") and parent.world.cards.has(action.tool):
		step.card_type = parent.world.cards[action.tool].type
	return step

func _child(parent: Dictionary, index: int) -> Dictionary:
	if parent.children.has(index): return parent.children[index]
	var from: OffWorkState = parent.world
	if not _can_fork(from): return {}
	var world := from.fork_search_node()
	var choice: Dictionary = parent.options[index].action
	var next := {}
	if generator.apply_action(world, parent.actor, choice):
		# Opponent timing is a hypothesis, not access to a human's next move.
		# A half-period offset gives each side one action per full interval.
		if not world.advance_for_search(period * 0.5, deadline, cancelled) or not _open():
			stopped = true
			return {}
		next = _node(world, 1 - int(parent.actor))
		nodes += 1
	parent.children[index] = next
	return next

func _solve(node: Dictionary, remaining: int, alpha: float, beta: float) -> Dictionary:
	var world: OffWorkState = node.world
	if not _open(): return {}
	if remaining == 0 or world.winner >= 0: return _leaf(node)
	if not node.has("options"):
		var rng := RandomNumberGenerator.new()
		rng.seed = sample_seed
		var settings := policy if int(node.actor) == seat else opponent_policy
		var chosen := generator.choose(world, node.actor, settings, rng, deadline, cancelled)
		if chosen.diagnostics.timed_out or not _open():
			stopped = true
			return {}
		node.options = chosen.finalists.slice(0, reply_width)
	var maximizing: bool = node.actor == seat
	var best_score := -INF if maximizing else INF
	var line := []
	for index in node.options.size():
		var child := _child(node, index)
		if stopped: return {}
		if child.is_empty(): continue
		var value := _solve(child, remaining - 1, alpha, beta)
		if stopped: return {}
		var score: float = value.score
		if (score > best_score if maximizing else score < best_score):
			best_score = score
			line = [_step(node, node.options[index].action)] + value.line
		if maximizing: alpha = maxf(alpha, best_score)
		else: beta = minf(beta, best_score)
		if beta <= alpha: break
	return {"score":best_score, "line":line} if not line.is_empty() else _leaf(node)

func _leaf(node: Dictionary) -> Dictionary:
	if not node.has("value"): node.value = _score(node.world)
	return {"score":node.value, "line":[]}

func _score(world: OffWorkState) -> float:
	if world.winner >= 0:
		if world.winner == world.config.integer("simulation","tie_winner"): return 0.0
		var value := WIN - minf(float(policy.tree_terminal_time_penalty_cap), world.time * float(policy.tree_terminal_time_penalty))
		return value if world.winner == seat else -value
	var files := [0, 0]
	var funds := [0, 0]
	var capacity := [0.0, 0.0]
	var income_rate := [0.0, 0.0]
	var progress := [0.0, 0.0]
	var tools := [0.0, 0.0]
	var horizon: float = float(policy.tree_horizon_work_cycles) * world.config.roles.employee.work_seconds
	for id in world.cards:
		if not _open(): return 0.0
		var card: Dictionary = world.cards[id]
		var side: int = card.owner
		match card.type:
			"work": files[side] += 1
			"money": funds[side] += int(card.amount)
			_:
				if not world.config.roles.has(card.type):
					if card.type != "coffee" or card.status == "ready":
						tools[side] += float(policy.tree_tool_value)
					continue
				var task: Dictionary = world.tasks.get(id,{})
				var job: String = task.get("kind","")
				var role: Dictionary = world.config.roles[task.to_type if job == "coffee" else card.type]
				if not role.can_work:
					tools[side] += float(policy.tree_support_person_value)
					continue
				var rate: float = float(policy.tree_busy_worker_rate_ratio) * role.work_capacity / role.work_seconds
				if job.is_empty():
					# A loose worker can return to a work combination on the
					# next action. Use that same delay before/after promotion.
					rate = float(role.work_capacity) / role.work_seconds * clampf(1.0 - period / horizon, 0.0, 1.0)
				if job == "work":
					rate = task.work_ids.size() * float(card.rate_multiplier) / float(role.work_seconds)
					progress[side] += task.work_ids.size() * world.group_work_progress(card.group)
				elif job == "coffee":
					# After the running recipe settles the same worker earns the promoted income.
					var delay: float = task.total * (1.0 - task.progress) + period
					rate = float(role.work_capacity) / role.work_seconds * clampf(1.0 - delay / horizon, 0.0, 1.0)
				if card.paused: rate *= float(policy.tree_paused_worker_rate_ratio)
				capacity[side] += rate
				income_rate[side] += rate * role.work_income_multiplier * world.config.cards.work.income
	for gid in world.groups:
		if not _open(): return 0.0
		var group: Dictionary = world.groups[gid]
		var side: int = group.owner
		if group.job == "transfer":
			var batch := 0
			for id in world.group_transfer_participants(gid):
				batch += int(world.config.roles[world.cards[id].type].transfer_capacity)
			var expected: float = world.group_transfer_progress(gid) + horizon * world.group_transfer_rate(gid)
			progress[side] += 2.0 * minf(world.group_work(gid).size(), batch * expected)
		elif group.job == "slack":
			var expected: float = world.group_slack_progress(gid) + horizon * world.group_slack_rate(gid)
			tools[side] += float(policy.tree_tool_value) * expected * world.group_slack_participants(gid).size() * world.config.rules.slack.coffee_per_person
	for id in world.outsourcing:
		if not _open(): return 0.0
		var batch: Dictionary = world.outsourcing[id]
		var side: int = world.cards[id].owner
		progress[side] += batch.work_ids.size() * clampf(1.0 - batch.remaining / world.config.rules.outsource.seconds, 0.0, 1.0)
		funds[side] -= int(batch.amount)
	var values := [0.0, 0.0]
	for side in 2:
		var output := minf(files[side], capacity[side] * horizon)
		var income: float = output * income_rate[side] / maxf(0.000001, capacity[side])
		var buying_power := float(policy.tree_cash_log_weight) * log(1.0 + maxi(0, funds[side]) + income)
		values[side] = -files[side] * float(policy.tree_pending_work_weight) + progress[side] * float(policy.tree_progress_weight) + output * float(policy.tree_forecast_output_weight) + buying_power + minf(tools[side], float(policy.tree_tool_value_cap))
	# Adjustable heuristics never enter the terminal-score band or trigger a proven-win cutoff.
	return clampf(float(values[seat] - values[1-seat]), -WIN * 0.5, WIN * 0.5)
