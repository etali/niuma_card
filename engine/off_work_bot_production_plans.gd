# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Executable production continuations, not a second production simulator.
## Every purchase, assembly, coffee batch, upgrade and return goes through
## OffWorkState. Only complete continuations are offered to the ETA evaluator.
## The visitor consumes each branch immediately so a large table is not kept
## alive once for every possible staffing choice.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")

static func available(world: OffWorkState, owner: int) -> bool:
	var ingredient_source := not world._owner_type(owner, "slack").is_empty()
	if not ingredient_source:
		for offer in world.offers:
			if not offer.is_empty() and offer.type == "slack": ingredient_source = true
	if not ingredient_source: return false
	for id in world.activity_card_ids(owner):
		var card: Dictionary = world.cards[id]
		if world.config.can_work(str(card.type)) and not world.config.coffee_upgrade(str(card.type)).is_empty(): return true
	return false

static func visit(world: OffWorkState, owner: int, policy: Dictionary, until: int,
		next_actions: Array, visitor: Callable, cancelled: Callable = Callable(), options: Dictionary = {}) -> Dictionary:
	if not available(world, owner): return {"complete":true, "plans":0, "examined":0}
	if not options.get("allow_purchase",true) and not options.get("allow_assembly",true):
		var ongoing := false
		for id in world._owner_type(owner,"slack"):
			var gid := int(world.cards[id].group)
			if str(world.groups[gid].get("function",""))=="slack" and not world.group_people(gid).is_empty():
				ongoing = true
				break
		if not ongoing: return {"complete":true,"plans":0,"examined":0}
	var planner := Planner.new()
	planner.source = world
	planner.owner = owner
	planner.policy = policy
	planner.until = until
	planner.cancelled = cancelled
	planner.visitor = visitor
	planner.period = maxf(0.001, float(policy.get("think_seconds", world.config.rules.bot.think_seconds)))
	planner.next_actions = next_actions.duplicate() if next_actions.size() == 2 else [planner.period, planner.period]
	planner.horizon = maxf(planner.period, float(policy.get("evaluation_max_seconds", 1800.0)))
	planner.options = options
	return planner.run()

class Planner extends RefCounted:
	var source: OffWorkState
	var owner := 0
	var policy: Dictionary
	var until := -1
	var cancelled: Callable
	var visitor: Callable
	var period := 1.0
	var horizon := 1800.0
	var next_actions: Array
	var options: Dictionary
	var complete := true
	var emitted := 0
	var examined := 0

	func _open() -> bool:
		if (until >= 0 and Time.get_ticks_usec() >= until) or (cancelled.is_valid() and cancelled.call()): complete = false
		return complete

	func run() -> Dictionary:
		if not _open(): return _result()
		var root := _cursor(source)
		if root.is_empty(): return _result()
		_owned(root)
		if not options.get("allow_purchase",true): return _result()
		# Waiting to afford a CURRENT quote is legal; its actual conveyor slot
		# must still contain it when buy executes. New draws are never eligible.
		for offer in source.offers:
			if not _open(): break
			if offer.is_empty() or str(offer.type) != "slack" or not source.config.can_purchase("slack"): continue
			var cursor := _cursor(source)
			if cursor.is_empty(): break
			while _slot(cursor):
				if not _quote_exists(cursor.world, int(offer.id)): break
				if cursor.world.available_money(owner) >= int(offer.price):
					var before: Array = cursor.world._owner_type(owner, "slack").duplicate()
					if _command(cursor, {"kind":"buy", "offer":int(offer.id), "card_type":"slack", "intent":"production_purchase"}):
						var bought: Array = cursor.world._owner_type(owner, "slack").filter(func(id): return not before.has(id))
						if bought.size() == 1: _assemblies(cursor, int(bought[0]))
					break
				cursor.next += period
		return _result()

	func _result() -> Dictionary:
		return {"complete":complete, "plans":emitted, "examined":examined}

	func _cursor(world: OffWorkState, previous: Dictionary = {}) -> Dictionary:
		if not _open(): return {}
		# Copying and later releasing a coherent branch are indivisible. Use
		# exactly the tree search's existing cost model, not another time cap.
		if until>=0 and until-Time.get_ticks_usec()<=Budget.fork_cost(world)+Budget.release_cost(world):
			complete = false
			return {}
		var branch := world.fork_search_node() if world._bot_branch else world.fork_for_bot(hash(["production_chain",owner,world.time,world._next_card,world._next_offer]))
		return {"world":branch, "next":float(next_actions[owner]) if previous.is_empty() else float(previous.next),
			"commands":[] if previous.is_empty() else previous.commands.duplicate(true),
			"purchases":{} if previous.is_empty() else previous.purchases.duplicate(true)}

	func _owned(cursor: Dictionary) -> void:
		var world: OffWorkState = cursor.world
		var groups := {}
		for id in world._owner_type(owner, "slack"):
			if not _open(): return
			var gid := int(world.cards[id].group)
			if groups.has(gid): continue
			groups[gid] = true
			if str(world.groups[gid].get("function", "")) == "slack":
				var staff: Array = world.group_people(gid)
				if not staff.is_empty(): _recipes(cursor, staff, gid)
		if options.get("allow_assembly",true): _assemblies(cursor)

	func _assemblies(cursor: Dictionary, required_tool := -1) -> void:
		if not _open(): return
		# Use the action generator's existing semantic staffing choices. This
		# keeps individual, spare-staff and whole-team alternatives in sync with
		# ordinary search without creating another hidden personnel limit.
		var generated: Dictionary = Actions.generate(cursor.world, owner, policy, until, cancelled)
		if not generated.complete:
			complete = false
			return
		for action in generated.actions:
			if not _open(): return
			if str(action.get("intent", "")) not in ["slack", "slack_staff", "slack_tools"]: continue
			if required_tool >= 0 and not action.get("ids", []).has(required_tool) and int(action.get("tool",-1)) != required_tool: continue
			var trial := _cursor(cursor.world, cursor)
			if trial.is_empty(): return
			if not _command(trial, action): continue
			var tool := required_tool
			if tool < 0:
				tool = int(action.get("tool", -1))
				for id in action.get("ids", []):
					if trial.world.cards.has(id) and str(trial.world.cards[id].type) == "slack":
						tool = int(id)
						break
			var gid := int(trial.world.cards[tool].group) if tool >= 0 and trial.world.cards.has(tool) else int(action.get("group", -1))
			if not trial.world.groups.has(gid) or str(trial.world.groups[gid].get("function", "")) != "slack": continue
			var staff: Array = trial.world.group_people(gid)
			if not staff.is_empty(): _recipes(trial, staff, gid)

	func _recipes(cursor: Dictionary, staff: Array, producer_group: int) -> void:
		var seen := {}
		for id in cursor.world.activity_card_ids(owner):
			if not _open(): return
			var card: Dictionary = cursor.world.cards[id]
			var kind := str(card.type)
			if not cursor.world.config.can_work(kind): continue
			var recipe: Dictionary = cursor.world.config.coffee_upgrade(kind)
			if recipe.is_empty(): continue
			var task: Dictionary = cursor.world.tasks.get(id, {})
			if str(task.get("kind", "")) not in ["", "work", "slack", "coffee"]: continue
			# Members with different unfinished batches/statuses are distinct.
			var key := str([kind,card.group,card.status,card.remaining,task.get("kind",""),task.get("progress",0.0),staff.has(id)])
			if seen.has(key): continue
			seen[key] = true
			examined += 1
			var trial := _cursor(cursor.world, cursor)
			if trial.is_empty(): return
			_finish_recipe(trial, int(id), recipe, staff, producer_group)

	func _finish_recipe(cursor: Dictionary, person: int, recipe: Dictionary, staff: Array, producer_group: int) -> void:
		var world: OffWorkState = cursor.world
		var original_rank: int = world.config.coffee_rank(str(world.cards[person].type))
		var started := str(world.tasks.get(person, {}).get("kind", "")) == "coffee"
		while _slot(cursor):
			if not world.cards.has(person): return
			if world.config.coffee_rank(str(world.cards[person].type)) > original_rank \
				and str(world.tasks.get(person, {}).get("kind", "")) != "coffee":
				_return_to_work(cursor, person, staff)
				return
			if started:
				# If an actual attack cancelled the paid recipe, stop this plan;
				# a later live search can choose a new legal recovery sequence.
				if str(world.tasks.get(person, {}).get("kind", "")) != "coffee": return
			else:
				var cups := _ready_coffee(world)
				if cups.size() >= int(recipe.cost) and _available_person(world, person):
					if not _command(cursor, {"kind":"move", "ids":[person] + cups.slice(0, int(recipe.cost)),
						"group":-1, "person":person, "intent":"production_upgrade"}): return
					started = str(world.tasks.get(person, {}).get("kind", "")) == "coffee"
					if not started: return
					continue
				# A landed strike ejects staff; recovery alone does not put them
				# back. Rejoining is a separately paid real command at this slot.
				var returning: Array = staff.filter(func(id): return world.cards.has(id) and _available_person(world,int(id)) \
					and int(world.cards[id].group) != producer_group and str(world.tasks.get(id,{}).get("kind","")) != "coffee")
				if not returning.is_empty() and world.groups.has(producer_group):
					if not _command(cursor, {"kind":"move", "ids":returning, "group":producer_group, "intent":"production_resume"}): return
					continue
			cursor.next += period
		# A natural finish during the prefix is also a complete, real outcome.
		if _open() and world.winner >= 0: _publish(cursor, person)

	func _return_to_work(cursor: Dictionary, person: int, staff: Array) -> void:
		var world: OffWorkState = cursor.world
		var destination := -1
		var most_work := 0
		for gid in world.groups:
			if int(world.groups[gid].owner) != owner or str(world.groups[gid].get("function", "")) not in ["", "work"]: continue
			var count: int = world.group_work(int(gid)).size()
			if count > most_work:
				most_work = count
				destination = int(gid)
		if destination < 0: return
		var people: Array = [person]
		for id in staff:
			if not people.has(id) and world.cards.has(id) and world.config.can_work(str(world.cards[id].type)) and _available_person(world,int(id)):
				people.append(id)
		if not _command(cursor, {"kind":"move", "ids":people, "group":destination, "intent":"production_return"}): return
		if str(world.tasks.get(person, {}).get("kind", "")) != "work": return
		_publish(cursor, person)

	func _publish(cursor: Dictionary, person: int) -> void:
		if not _open(): return
		var elapsed: float = cursor.world.time - source.time
		var future := []
		for side in 2:
			var next := float(cursor.next) if side == owner else float(next_actions[side])
			if next < elapsed: next += ceili((elapsed-next) / period) * period
			future.append(maxf(0.0, next-elapsed))
		emitted += 1
		visitor.call({"world":cursor.world, "owner":owner, "person":person, "elapsed":elapsed,
			"next_actions":future, "commands":cursor.commands, "purchases":cursor.purchases,
			"complete":true, "kind":"slack_upgrade_return"})

	func _slot(cursor: Dictionary) -> bool:
		if not _open() or cursor.world.winner >= 0 or float(cursor.next) > horizon: return false
		var delta := maxf(0.0, source.time + float(cursor.next) - float(cursor.world.time))
		if delta > 0.0 and not cursor.world.advance_for_search(delta, until, cancelled):
			complete = false
			return false
		cursor.world.mask_search_market(source._next_offer)
		return _open() and cursor.world.winner < 0

	func _command(cursor: Dictionary, action: Dictionary) -> bool:
		if not _slot(cursor): return false
		var price := 0
		if action.kind == "buy":
			for offer in cursor.world.offers:
				if not offer.is_empty() and int(offer.id) == int(action.offer): price = int(offer.price)
		if not Actions.apply_search_action(cursor.world, owner, action): return false
		var at: float = cursor.world.time - source.time
		cursor.commands.append({"at":at, "action":action.duplicate(true)})
		if action.kind == "buy": cursor.purchases[int(action.offer)] = {"at":at,"owner":owner,"price":price}
		cursor.next = at + period
		return _open()

	func _quote_exists(world: OffWorkState, id: int) -> bool:
		return world.offers.any(func(offer): return not offer.is_empty() and int(offer.id) == id)

	func _ready_coffee(world: OffWorkState) -> Array:
		return world._owner_type(owner,"coffee").filter(func(id): return str(world.cards[id].status) == "ready")

	func _available_person(world: OffWorkState, id: int) -> bool:
		return world.cards.has(id) and int(world.cards[id].owner) == owner and not world.is_striking(id) and not world.is_meeting_target(id)
