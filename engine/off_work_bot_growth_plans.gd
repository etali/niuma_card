# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Sustained economic continuations run on the authoritative rule state. The
## small policy portfolio chooses commands; it never credits forecast workers,
## coffee, wages or upgrades. Every published checkpoint can be replayed.
static func available(world: OffWorkState, owner: int) -> bool:
	var sources := {}
	for kind in ["boss", "slack"]:
		if not world._owner_type(owner, kind).is_empty(): sources[kind] = true
		for offer in world.offers:
			if not offer.is_empty() and str(offer.type) == kind and world.config.can_purchase(kind): sources[kind] = true
	if sources.has("boss"): return true
	if sources.has("slack"):
		for id in world.activity_card_ids(owner):
			if not world.config.coffee_upgrade(str(world.cards[id].type)).is_empty(): return true
	return false

## Optional planner_state + round_limit allow both seats to share a deadline
## fairly. Counts are deltas for this call; pending means another round can
## resume without replaying the already executed prefix. State is search-local.
static func visit(world: OffWorkState, owner: int, policy: Dictionary, until: int,
		clock: Array, visitor: Callable, cancelled: Callable = Callable(), options: Dictionary = {}) -> Dictionary:
	var result := {"complete":true, "plans":0, "examined":0, "pending":false}
	if not available(world, owner): return result
	var state: Dictionary = options.get("planner_state", {})
	var identity := [world.get_instance_id(), owner, world.revision, world.time, world._next_card]
	if state.get("identity", []) != identity:
		state.clear()
		state.identity = identity
		state.planners = []
		var hiring := not world._owner_type(owner, "boss").is_empty()
		var coffee := not world._owner_type(owner, "slack").is_empty()
		if options.get("allow_purchase", true):
			for offer in world.offers:
				if offer.is_empty(): continue
				hiring = hiring or str(offer.type) == "boss"
				coffee = coffee or str(offer.type) == "slack"
		var policies := []
		if hiring and coffee: policies.append("combined")
		if hiring: policies.append("recruitment")
		if coffee: policies.append("coffee")
		for index in policies.size():
			var planner := Planner.new()
			planner.source = world
			planner.owner = owner
			planner.policy = policy
			# Do not retain state -> planners -> options -> state reference cycles.
			planner.options = options.duplicate()
			planner.options.erase("planner_state")
			planner.mode = policies[index]
			planner.period = maxf(0.001, float(policy.get("think_seconds", world.config.rules.bot.think_seconds)))
			planner.next_actions = clock.duplicate() if clock.size() == 2 else [planner.period, planner.period]
			planner.horizon = maxf(planner.period, float(policy.get("evaluation_max_seconds", 1800.0)))
			state.planners.append(planner)
	var planners: Array = state.planners
	var before_plans := 0
	var before_examined := 0
	for planner in planners:
		planner.until = until
		planner.cancelled = cancelled
		planner.visitor = visitor
		before_plans += planner.emitted
		before_examined += planner.examined
	# A real command/event sequence has a minimum cost. Dividing a small job
	# into three even smaller deadlines prevented *every* policy from reaching
	# its first checkpoint. Serve one complete growth milestone per policy,
	# then deepen the retained cursors in rounds under the same total deadline.
	var rounds := 0
	while planners.any(func(planner): return not planner.finished and planner.complete):
		if (until >= 0 and Time.get_ticks_usec() >= until) or (cancelled.is_valid() and cancelled.call()): break
		for planner in planners:
			if planner.finished or not planner.complete: continue
			planner.run(1)
		rounds += 1
		if int(options.get("round_limit", -1)) > 0 and rounds >= int(options.round_limit): break
	for planner in planners:
		result.complete = result.complete and planner.complete and planner.finished
		result.plans += planner.emitted
		result.examined += planner.examined
		result.pending = result.pending or (not planner.finished and planner.complete)
		planner.visitor = Callable()
		planner.cancelled = Callable()
	result.plans -= before_plans
	result.examined -= before_examined
	return result

class Planner extends "res://engine/off_work_bot_plan_cursor.gd":
	var visitor: Callable
	var options: Dictionary
	var mode := "combined"
	var emitted := 0
	var examined := 0
	var producers: Array = []
	var producer_group := -1
	var last_checkpoint := ""
	var policy_commands := 0
	var last_investment := ""
	var original_workers: Array = []
	var live_cursor := {}
	var finished := false
	var initialized := false

	func run(checkpoint_limit := -1) -> Dictionary:
		if finished or not _open(): return _result()
		if not initialized:
			initialized = true
			live_cursor = _cursor(source)
			if live_cursor.is_empty():
				finished = true
				return _result()
			for id in source.activity_card_ids(owner):
				if source.config.can_work(str(source.cards[id].type)): original_workers.append(id)
			_observe_producers(live_cursor.world)
		var cursor: Dictionary = live_cursor
		var previous := emitted
		while _open():
			if not _slot(cursor): break
			var world: OffWorkState = cursor.world
			var action := _next_action(world)
			if not _open(): break
			if not action.is_empty():
				examined += 1
				if not _command(cursor, action): break
				policy_commands += 1
				match str(action.get("growth_intent", "")):
					"growth_upgrade": last_investment = "coffee"
					"growth_recruit", "growth_recruit_feed": last_investment = "recruitment"
				if action.get("growth_intent", "") == "growth_staff":
					producer_group = int(world.cards[int(action.tool)].group)
					producers = world.group_people(producer_group).duplicate()
			else:
				if not _can_change(world): break
				cursor.next += period
			_checkpoint(cursor)
			if checkpoint_limit > 0 and emitted - previous >= checkpoint_limit: return _result()
		finished = true
		if _open() and int(cursor.world.winner) == owner: _publish(cursor, false)
		return _result()

	func _result() -> Dictionary:
		return {"complete":complete, "plans":emitted, "examined":examined}

	func _uses_recruitment() -> bool:
		return mode in ["combined", "recruitment"]

	func _uses_coffee() -> bool:
		return mode in ["combined", "coffee"]

	func _ready_person(world: OffWorkState, id: int) -> bool:
		return world.cards.has(id) and not world.is_striking(id) and not world.is_meeting_target(id)

	func _observe_producers(world: OffWorkState) -> void:
		if not _uses_coffee(): return
		for tool in world._owner_type(owner, "slack"):
			var gid := int(world.cards[tool].group)
			if str(world.groups[gid].get("function", "")) != "slack": continue
			var staff: Array = world.group_people(gid)
			if staff.is_empty(): continue
			# Preserve a real established line, including its partially completed
			# batch. Extra owned lines keep running naturally in the branch.
			producer_group = gid
			producers = staff.duplicate()
			return

	func _work_target(world: OffWorkState) -> int:
		var target := -1
		var count := 0
		for gid in world.groups:
			if not _open(): return -1
			if int(world.groups[gid].owner) != owner or str(world.groups[gid].get("function", "")) not in ["", "work"]: continue
			var size: int = world.group_work(int(gid)).size()
			if size > count:
				count = size
				target = int(gid)
		return target

	func _next_action(world: OffWorkState) -> Dictionary:
		var target := _work_target(world)
		if target < 0: return {}
		# Employment and the return after an upgrade are separate, real actions.
		var returning := []
		for id in world.activity_card_ids(owner):
			if not _open(): return {}
			if producers.has(id) or not world.config.can_work(str(world.cards[id].type)) or not _ready_person(world, int(id)): continue
			if world.tasks.has(id) or int(world.cards[id].group) == target: continue
			returning.append(id)
		if not returning.is_empty(): return _move(returning, target, "growth_return")
		# A selected producer temporarily upgraded or ejected by a real strike
		# must explicitly rejoin; neither recovery nor promotion teleports it.
		if _uses_coffee() and world.groups.has(producer_group):
			var resuming := producers.filter(func(id): return _ready_person(world, int(id)) and not world.tasks.has(id) \
				and int(world.cards[id].group) != producer_group)
			if not resuming.is_empty(): return _move(resuming, producer_group, "growth_resume")
		var purchase := _purchase(world)
		if not purchase.is_empty(): return purchase
		var upgrade := {}
		if _uses_coffee():
			var staffing := _staffing(world)
			if not staffing.is_empty(): return staffing
			upgrade = _upgrade(world)
		var recruitment := _recruit(world) if _uses_recruitment() else {}
		# In the combined candidate, a continuous coffee supply must not starve
		# wage reinvestment (nor vice versa). Alternate only when BOTH commands
		# are executable now; never wait for a preferred queue. This cursor-local
		# service history changes only after a successful real command, and the
		# whole candidate still competes with pure policies on the same ETA scale.
		if mode == "combined" and not upgrade.is_empty() and not recruitment.is_empty():
			return recruitment if last_investment == "coffee" else upgrade
		return upgrade if not upgrade.is_empty() else recruitment

	func _move(ids: Array, target: int, intent: String, person := -1) -> Dictionary:
		# Growth plans execute through the ordinary BOT and feed the same replay
		# and balance statistics. Keep their public action vocabulary identical.
		var semantics := {
			"growth_upgrade":["coffee", "用已备齐的咖啡升级人员，提升后续生产力"],
			"growth_recruit":["recruitment", "老板与完整资金组队招聘员工"],
			"growth_recruit_feed":["recruitment_feed", "把新收入补入老板的招聘批次"],
			"growth_staff":["slack", "保留人员与摸鱼牌组队，持续生产咖啡"],
			"growth_resume":["slack_staff", "将恢复或升级完成的生产人员调回摸鱼组合"],
			"growth_return":["staff_batch", "将新员工和升级完成的人员投入工作"],
			"growth_finish":["staff_batch", "结束咖啡生产，将人员调回工作组合"]}
		var meaning: Array = semantics[intent]
		return {"kind":"move", "ids":ids, "group":target, "person":person,
			"intent":meaning[0], "reason":meaning[1], "growth_intent":intent}

	func _purchase(world: OffWorkState) -> Dictionary:
		if not options.get("allow_purchase", true): return {}
		for offer in source.offers:
			if not _open(): return {}
			if offer.is_empty() or not _quote_exists(world, int(offer.id)): continue
			var kind := str(offer.type)
			if not ((kind == "boss" and _uses_recruitment()) or (kind == "slack" and _uses_coffee())): continue
			if not world._owner_type(owner, kind).is_empty() or not world.can_acquire(kind, owner): continue
			if world.available_money(owner) < int(offer.price): continue
			return {"kind":"buy", "offer":int(offer.id), "card_type":kind, "intent":"buy",
				"reason":"购买当前公开的生产牌，建设后续人员或咖啡供给", "growth_intent":"growth_purchase"}
		return {}

	func _staffing(world: OffWorkState) -> Dictionary:
		if not producers.is_empty() or not options.get("allow_assembly", true): return {}
		var tools: Array = world._owner_type(owner, "slack")
		if tools.is_empty(): return {}
		var person := -1
		var opportunity := INF
		for id in world.activity_card_ids(owner):
			if not _open(): return {}
			var kind := str(world.cards[id].type)
			if not world.config.is_person(kind) or not _ready_person(world, int(id)): continue
			if _uses_recruitment() and kind == "boss": continue
			if str(world.tasks.get(id, {}).get("kind", "")) not in ["", "work"]: continue
			var cost: float = world.config.work_rate(kind, 0) * float(world.config.roles[kind].work_capacity) if world.config.can_work(kind) else 0.0
			if cost < opportunity:
				opportunity = cost
				person = int(id)
		if person < 0: return {}
		var action := _move([int(tools[0]), person], -1, "growth_staff")
		action.tool = int(tools[0])
		return action

	func _upgrade(world: OffWorkState) -> Dictionary:
		var cups: Array = world._owner_type(owner, "coffee").filter(func(id): return world.cards[id].status == "ready")
		if cups.is_empty(): return {}
		var chosen := -1
		var count := 0
		var best := -INF
		var best_secondary := -INF
		var chosen_producer := true
		for id in world.activity_card_ids(owner):
			if not _open(): return {}
			var kind := str(world.cards[id].type)
			if not world.config.can_work(kind) or not _ready_person(world, int(id)): continue
			if str(world.tasks.get(id, {}).get("kind", "")) not in ["", "work", "slack"]: continue
			var recipe: Dictionary = world.config.coffee_upgrade(kind)
			if recipe.is_empty() or int(recipe.cost) > cups.size(): continue
			var next_kind := str(recipe.to)
			var current_rate: float = world.config.work_rate(kind, 0) * float(world.config.roles[kind].work_capacity)
			var next_rate: float = world.config.work_rate(next_kind, 0) * float(world.config.roles[next_kind].work_capacity)
			var work_gain: float = (next_rate - current_rate) / maxi(1, int(recipe.cost))
			var income_gain: float = (next_rate * world.config.income_per_work(next_kind) \
				- current_rate * world.config.income_per_work(kind)) / maxi(1, int(recipe.cost))
			# The portfolio covers throughput-first and reinvestment-first choices.
			# Compare like units lexicographically, never invent an asset score by
			# adding money to work. Completed plans still compete solely by ETA.
			var ratio := income_gain if mode == "combined" else work_gain
			var secondary := work_gain if mode == "combined" else income_gain
			var is_producer := producers.has(id)
			# Work-side promotions preserve coffee supply. If the only eligible
			# worker is the producer, alternate producing and upgrading legally.
			if chosen < 0 or (chosen_producer and not is_producer) or (chosen_producer == is_producer \
				and (ratio > best or (is_equal_approx(ratio, best) and secondary > best_secondary))):
				chosen = int(id)
				count = int(recipe.cost)
				best = ratio
				best_secondary = secondary
				chosen_producer = is_producer
		if chosen < 0: return {}
		return _move([chosen] + cups.slice(0, count), -1, "growth_upgrade", chosen)

	func _recruit(world: OffWorkState) -> Dictionary:
		if not options.get("allow_recruitment", true): return {}
		var allocated := world.cards.size()
		for batch in world.recruitment.values(): allocated += int(batch.count)
		if allocated >= OffWorkConfig.MAX_CARD_ALLOCATION: return {}
		var wallets := []
		var money := 0
		for id in world._owner_type(owner, "money"):
			if not _open(): return {}
			# Moving even a partially reserved wallet cancels its paid batch.
			if world.available_cash_amount(int(id)) != int(world.cards[id].amount): continue
			wallets.append(id)
			money += int(world.cards[id].amount)
		if money < world.config.integer("recruitment", "cost_per_employee"): return {}
		for boss in world._owner_type(owner, "boss"):
			if not _ready_person(world, int(boss)): continue
			if world.recruitment.has(boss):
				var gid := int(world.cards[boss].group)
				var outside := wallets.filter(func(id): return int(world.cards[id].group) != gid)
				if not outside.is_empty(): return _move(outside, gid, "growth_recruit_feed")
			elif not world.tasks.has(boss):
				return _move([boss] + wallets, -1, "growth_recruit")
		return {}

	func _growth(world: OffWorkState) -> Dictionary:
		var recruited := 0
		var upgrades := 0
		for id in _workers(world):
			if not _open(): break
			var kind := str(world.cards[id].type)
			if not world.config.can_work(kind): continue
			if not source.cards.has(id): recruited += 1
			var before: int = world.config.coffee_rank(str(source.cards[id].type)) if source.cards.has(id) else 0
			upgrades += maxi(0, world.config.coffee_rank(kind) - before)
		return {"policy":mode, "recruited":recruited, "upgrades":upgrades, "producers":producers.size(),
			"commands":policy_commands, "checkpoints":emitted, "persistent_production":not producers.is_empty()}

	func _workers(world: OffWorkState) -> Array:
		# Mutation invalidates the whole membership index. A growth checkpoint
		# only needs original workers and new identities, not another scan of
		# every outstanding work card just to discover a handful of recruits.
		var result: Array = original_workers.filter(func(id): return world.cards.has(id))
		for id in range(source._next_card, world._next_card):
			if not _open(): return result
			if world.cards.has(id) and int(world.cards[id].owner) == owner and world.config.can_work(str(world.cards[id].type)):
				result.append(id)
		return result

	func _checkpoint(cursor: Dictionary) -> void:
		if not _open(): return
		var growth := _growth(cursor.world)
		if int(growth.recruited) + int(growth.upgrades) == 0: return
		var key := str([growth.recruited, growth.upgrades])
		if key == last_checkpoint: return
		# Wait until newly available staff really join work or the persistent
		# production line; an unfinished batch never becomes a worker bonus.
		for id in _workers(cursor.world):
			if not _open(): return
			if not cursor.world.config.can_work(str(cursor.world.cards[id].type)): continue
			if not source.cards.has(id) and not cursor.world.tasks.has(id): return
		last_checkpoint = key
		_publish(cursor, false)
		if not producers.is_empty(): _publish(cursor, true)

	func _publish(cursor: Dictionary, finish_production: bool) -> void:
		if not _open(): return
		# The evaluator consumes the checkpoint inside this call and stores
		# only numbers/commands. Other callers get an immutable owned snapshot.
		var snapshot := cursor if options.get("consume_immediately", false) and not finish_production else _cursor(cursor.world, cursor)
		if snapshot.is_empty(): return
		if finish_production and snapshot.world.winner < 0:
			var destination := _work_target(snapshot.world)
			var returning := producers.filter(func(id): return _ready_person(snapshot.world, int(id)) \
				and snapshot.world.config.can_work(str(snapshot.world.cards[id].type)) \
				and str(snapshot.world.tasks.get(id, {}).get("kind", "")) in ["", "slack"] \
				and int(snapshot.world.cards[id].group) != destination)
			if destination < 0 or returning.is_empty(): return
			if not _command(snapshot, _move(returning, destination, "growth_finish")): return
		var plan := _plan(snapshot, "sustained_growth")
		plan["evaluation_deadline"] = until
		plan["growth"] = _growth(snapshot.world)
		if not _open(): return
		plan.growth["commands"] = plan.commands.size()
		plan.growth["finish_production"] = finish_production
		emitted += 1
		visitor.call(plan)

	func _can_change(world: OffWorkState) -> bool:
		# No future random quote is a promised input. Keep waiting only for an
		# existing paid task, actual production/income, or a current public quote.
		var earning := false
		var producing := false
		var upgradeable := false
		for id in world.activity_card_ids(owner):
			if not _open(): return false
			var kind := str(world.tasks.get(id, {}).get("kind", ""))
			if kind in ["coffee", "recruitment"]: return true
			if kind == "work" and world.config.income_per_work(str(world.cards[id].type)) > 0: earning = true
			if kind == "slack": producing = true
			if not world.config.coffee_upgrade(str(world.cards[id].type)).is_empty(): upgradeable = true
		if _uses_coffee() and producing and upgradeable: return true
		if not earning: return false
		if _uses_recruitment() and options.get("allow_recruitment", true) and not world._owner_type(owner, "boss").is_empty(): return true
		if options.get("allow_purchase", true):
			for offer in source.offers:
				if not _open(): return false
				if offer.is_empty() or not _quote_exists(world, int(offer.id)): continue
				var kind := str(offer.type)
				if ((kind == "boss" and _uses_recruitment()) or (kind == "slack" and _uses_coffee())) \
					and world._owner_type(owner, kind).is_empty() and world.can_acquire(kind, owner): return true
		return false
