# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Enumerate effects, not preferences. The search applies each proposal to its
## own rule-state copy; this layer neither scores actions nor touches the world
## or its random stream. In particular, old shopping/personnel/material caps do
## not remove options. Equivalent cards share representatives, while quantities
## represent a batch, preserving production, or committing all available stock.

static func generate(world: OffWorkState, owner: int, _policy: Dictionary, until: int,
		cancelled: Callable = Callable()) -> Dictionary:
	var builder := Builder.new()
	builder.world = world
	builder.owner = owner
	builder.until = until
	builder.cancelled = cancelled
	return builder.run()

## The authoritative rules, rather than the proposal generator, decide final
## legality. Ownership is checked here because this entry point also serves
## callers outside the search. Extra diagnostic fields have no rule effects.
static func apply_action(world: OffWorkState, owner: int, action: Dictionary) -> bool:
	if action.get("kind", "") == "wait": return true
	if world.winner >= 0: return false
	for id in action.get("ids", []):
		if not id is int or not world.cards.has(id) or int(world.cards[id].owner) != owner: return false
	if action.has("tool"):
		if not world.cards.has(action.tool) or int(world.cards[action.tool].owner) != owner: return false
	match action.get("kind", ""):
		"buy": return world.buy(int(action.get("offer", -1)), owner) >= 0
		"move": return world.move_cards(action.get("ids", []), int(action.get("group", -1)), int(action.get("person", -1))) >= 0
		"activate": return world.activate(int(action.get("tool", -1)), int(action.get("group", -1)), int(action.get("person", -1)))
		"dismiss": return world.dismiss_people(action.get("ids", []), owner)
	return false

## Only isolated search branches use this entry point. Membership/type queries
## share the existing invalidated index for one command; every authoritative
## mutation and every card refresh still runs at its original call site.
static func apply_search_action(world: OffWorkState, owner: int, action: Dictionary) -> bool:
	if not world._bot_branch: return false
	var previous: bool = world._search_queries
	world._search_queries = true
	# The same authoritative mutations used by live play invalidate membership
	# and scheduling themselves. Invalidating again here discarded a completed
	# move's reschedule, forcing advance() to repeat it; even wait became dirty.
	var applied := apply_action(world, owner, action)
	world._search_queries = previous
	world._group_index.clear() # End only the command-local query scope.
	return applied

## The ordinary generator and the bounded UI incumbent assemble the same
## production command. These helpers only combine already observed materials;
## they neither choose a destination nor attach a value to a card type.
class Production extends RefCounted:
	static func accepts_work(function: String, exclusive: bool) -> bool:
		return function == "work" or (function.is_empty() and not exclusive)

	static func overtime_is_loose(function: String, has_work: bool, has_workers: bool) -> bool:
		return function != "work" or not has_work or not has_workers

	static func assemble(workers: Array, work: Array, overtime: Array, has_union: bool) -> Array:
		var ids: Array = workers + work
		if not has_union: ids.append_array(overtime)
		return ids

class Builder extends RefCounted:
	var world: OffWorkState
	var owner: int
	var until: int
	var cancelled: Callable
	var actions: Array[Dictionary] = [{"kind":"wait", "intent":"wait", "reason":"维持现有安排"}]
	var complete := true
	var examined := 0
	var seen := {}
	var rows := {}
	var stock := {}
	var people := []
	var movable := []
	var workers := []
	var idle_workers := []
	var idle_people := []
	var work := []
	var cash := []
	var assigned := {}
	var reserved_work := {}
	var reserved_cash := {}
	var funds := 0
	var movable_funds := 0
	var person_representatives := []
	var work_targets := []

	func run() -> Dictionary:
		if world.winner < 0 and _open():
			_observe()
			if _open(): _shopping()
			if _open(): _production()
			if _open(): _modifiers()
			if _open(): _coffee()
			if _open(): _meetings_and_strikes()
			if _open(): _outsourcing()
			if _open(): _transfer_and_slack()
			if _open(): _recruitment()
			if _open(): _dismissal()
		return {"actions":actions, "complete":complete, "examined":examined}

	func _open() -> bool:
		if not complete: return false
		if (until >= 0 and Time.get_ticks_usec() >= until) or (cancelled.is_valid() and cancelled.call()):
			complete = false
		return complete

	func _observe() -> void:
		for task in world.tasks.values():
			if not _open(): return
			if task.kind == "work":
				for id in task.get("work_ids", []): assigned[id] = true
		for batch in world.outsourcing.values():
			if not _open(): return
			for id in batch.work_ids: reserved_work[id] = true
		for batches in [world.outsourcing, world.recruitment]:
			for batch in batches.values():
				if not _open(): return
				for id in batch.payments:
					reserved_cash[id] = int(reserved_cash.get(id, 0)) + int(batch.payments[id])
		for gid in world.groups:
			if not _open(): return
			var g: Dictionary = world.groups[gid]
			rows[gid] = {"id":gid, "owner":int(g.owner), "function":str(g.get("function", g.job)),
				"job":str(g.job), "work":[], "people":[], "workers":[], "movable":[], "types":{},
				"progress":float(g.get("work_progress", 0.0)), "signature":[], "exclusive":false}
		for id in world.cards:
			if not _open(): return
			var c: Dictionary = world.cards[id]
			var row: Dictionary = rows[c.group]
			var kind: String = c.type
			if not row.types.has(kind): row.types[kind] = []
			row.types[kind].append(id)
			if kind in ["meeting", "transfer", "slack", "outsource"]: row.exclusive = true
			if kind == "work": row.work.append(id)
			if world.config.is_person(kind):
				row.people.append(id)
				if world.config.can_work(kind): row.workers.append(id)
			if int(c.owner) != owner: continue
			if not stock.has(kind): stock[kind] = []
			stock[kind].append(id)
			if kind == "work" and not reserved_work.has(id): work.append(id)
			if kind == "money":
				funds += maxi(0, int(c.amount) - int(reserved_cash.get(id, 0)))
				# Moving a partially reserved wallet would cancel its other batch.
				# Spending that wallet at the market remains supported above.
				if not reserved_cash.has(id):
					cash.append(id)
					movable_funds += int(c.amount)
			if not world.config.is_person(kind): continue
			people.append(id)
			if world.is_meeting_target(id) or world.is_striking(id): continue
			movable.append(id)
			row.movable.append(id)
			if world.config.can_work(kind): workers.append(id)
			if not world.tasks.has(id):
				idle_people.append(id)
				if world.config.can_work(kind): idle_workers.append(id)
		for gid in rows:
			if not _open(): return
			var row: Dictionary = rows[gid]
			var type_keys: Array = row.types.keys()
			type_keys.sort()
			var shape := []
			for kind in type_keys:
				if not _open(): return
				var states := {}
				for id in row.types[kind]:
					if not _open(): return
					var c: Dictionary = world.cards[id]
					var signature := str([c.status, c.get("paused",false), c.get("remaining",0), c.get("amount",0), world.tasks.get(id,{}).get("kind","")])
					states[signature] = int(states.get(signature, 0)) + 1
				shape.append([kind, row.types[kind].size(), states])
			# Partial final batches allocate files in visible stack order. Two
			# piles with the same role counts can therefore earn different sums.
			# Preserve that effect without putting concrete UIDs in the key.
			var ordered_people := []
			for id in world.groups[gid].cards:
				if not _open(): return
				var card: Dictionary = world.cards[id]
				if not world.config.is_person(str(card.type)): continue
				var task: Dictionary = world.tasks.get(id,{})
				ordered_people.append([card.type,task.get("kind",""),task.get("work_ids",[]).size()])
			var attacks := []
			for flight in world.pending_strikes.values():
				if int(flight.target_group) == int(gid): attacks.append([flight.owner,flight.remaining])
			row.signature = [row.function, row.job, row.progress, world.groups[gid].get("transfer_progress",0),
				world.groups[gid].get("slack_progress",0), shape, ordered_people, attacks]
			if row.owner == owner and not row.work.is_empty() and Production.accepts_work(row.function, row.exclusive):
				work_targets.append(gid)
		person_representatives = _representatives(movable)
		# Free tail work comes first, retaining the currently assigned batch for
		# smaller allocations. No IDs disappear when considering a full commit.
		work.sort_custom(func(a, b):
			if assigned.has(a) != assigned.has(b): return not assigned.has(a)
			return a > b)

	func _person_key(id: int) -> String:
		var c: Dictionary = world.cards[id]
		var task: Dictionary = world.tasks.get(id, {})
		return str([c.type, c.status, task.get("kind", ""), task.get("progress",0),
			task.get("work_ids",[]).size(), rows[c.group].signature,
			task if task.get("kind","") not in ["","work","transfer","slack"] else {}])

	func _representatives(ids: Array) -> Array:
		var result := []
		var signatures := {}
		for id in ids:
			if not _open(): return result
			var key := _person_key(id)
			if signatures.has(key): continue
			signatures[key] = true
			result.append(id)
		return result

	func _equivalent_groups(ids: Array) -> Array:
		var result := []
		var signatures := {}
		for gid in ids:
			if not _open(): return result
			var key := str(rows[gid].signature)
			if signatures.has(key): continue
			signatures[key] = true
			result.append(gid)
		return result

	func _emit(action: Dictionary, intent: String, reason: String) -> void:
		if not _open(): return
		examined += 1
		var ids: Array = action.get("ids", []).duplicate()
		ids.sort()
		var key := str([action.kind, ids, action.get("group",-1), action.get("person",-1), action.get("tool",-1), action.get("offer",-1)])
		if seen.has(key): return
		seen[key] = true
		action["intent"] = intent
		action["reason"] = reason
		actions.append(action)

	func _move(ids: Array, gid: int, intent: String, reason: String, person := -1) -> void:
		var unique := []
		var included := {}
		for id in ids:
			if not _open(): return
			if included.has(id) or (gid >= 0 and int(world.cards[id].group) == gid): continue
			included[id] = true
			unique.append(id)
		if unique.is_empty(): return
		if gid < 0:
			var source: int = int(world.cards[unique[0]].group)
			if unique.size() == world.groups[source].cards.size() and unique.all(func(id): return int(world.cards[id].group) == source): return
		_emit({"kind":"move", "ids":unique, "group":gid, "person":person},intent,reason)

	func _activate(tool: int, gid: int, intent: String, reason: String, person := -1) -> void:
		_emit({"kind":"activate", "tool":tool, "group":gid, "person":person},intent,reason)

	func _shopping() -> void:
		for offer in world.offers:
			if not _open(): return
			if offer.is_empty() or not world.config.can_purchase(str(offer.type)): continue
			if int(offer.price) > funds or not world.can_acquire(str(offer.type), owner): continue
			_emit({"kind":"buy", "offer":offer.id, "card_type":offer.type}, "buy", "购买当前公开且可负担的%s" % world.config.cards[offer.type].name)

	func _batches(ids: Array, singles := true) -> Array:
		var result := []
		if singles:
			for id in _representatives(ids): result.append([id])
		var by_kind := {}
		for id in ids:
			if not _open(): return result
			var kind: String = world.cards[id].type
			if not by_kind.has(kind): by_kind[kind] = []
			by_kind[kind].append(id)
		for batch in by_kind.values():
			if batch.size() > 1: result.append(batch)
		if ids.size() > 1: result.append(ids.duplicate())
		return result

	func _capacity(ids: Array, transfer := false) -> int:
		var total := 0
		for id in ids:
			if not _open(): return total
			var role: Dictionary = world.config.roles[world.cards[id].type]
			total += int(role.transfer_capacity if transfer else role.work_capacity)
		return total

	func _production() -> void:
		var destinations := _equivalent_groups(work_targets)
		var representatives := _representatives(workers)
		var loose_overtime := []
		for id in stock.get("overtime",[]):
			if not _open(): return
			var origin: Dictionary = rows[world.cards[id].group]
			if Production.overtime_is_loose(origin.function, not origin.work.is_empty(), not origin.workers.is_empty()): loose_overtime.append(id)
		var loose_work := []
		for id in work:
			if not _open(): return
			var origin: Dictionary = rows[world.cards[id].group]
			if origin.function == "work" and not origin.workers.is_empty(): continue
			if origin.function == "transfer" and not origin.people.is_empty(): continue
			loose_work.append(id)
		var sources := []
		for row in rows.values():
			if not _open(): return
			if row.owner == owner: sources.append(row.id)
		sources = _equivalent_groups(sources)
		for gid in destinations:
			if not _open(): return
			var assembly := Production.assemble(idle_workers, loose_work, loose_overtime, rows[gid].types.has("union"))
			_move(assembly,gid,"assemble_work","一次合并闲置人员、散工作和未投入生产的加班")
			for id in representatives:
				_move([id],gid,"staff","将人员派到工作组合")
			for batch in _batches(idle_workers, false):
				_move(batch,gid,"staff_batch","一次派回同类或全部闲置工作人员")
			for source_id in sources:
				if not _open(): return
				var source: Dictionary = rows[source_id]
				if source.owner != owner or source.id == gid: continue
				var staff: Array = source.movable.filter(func(id): return world.config.can_work(str(world.cards[id].type)))
				if staff.size() > 1: _move(staff,gid,"staff_batch","整批调度同一组合的工作人员")
				if rows[gid].workers.is_empty(): continue
				var incoming: Array = source.work.filter(func(id): return not reserved_work.has(id))
				_move(incoming,gid,"feed_work","将整批待办加入工作组合")
			if not rows[gid].workers.is_empty(): _move(work,gid,"feed_work","合并全部可移动待办")
		if work.is_empty(): return
		# Independent groups are real alternatives even when another group is
		# already producing: they can recover locked work and diversify strikes.
		var batches := []
		for id in representatives: batches.append([id])
		batches.append_array(_batches(idle_workers, false))
		for batch in batches:
			if not _open(): return
			var capacity := _capacity(batch)
			var share := mini(work.size(), maxi(capacity, ceili(float(work.size()) * batch.size() / maxi(1,workers.size()))))
			var amounts := [mini(work.size(),capacity), share]
			if destinations.is_empty() or batch.size() == workers.size(): amounts.append(work.size())
			for amount in amounts:
				if int(amount) <= 0: continue
				_move(batch + work.slice(0,int(amount)),-1,"split_work","人员与工作另组生产组合")
				if not loose_overtime.is_empty():
					_move(Production.assemble(batch, work.slice(0,int(amount)), loose_overtime, false),-1,"assemble_work","人员、工作和空闲加班一次另组生产组合")

	func _tool_representatives(kind: String, statuses: Array = ["ready"]) -> Array:
		var result := []
		var signatures := {}
		for id in stock.get(kind, []):
			if not _open(): return result
			var c: Dictionary = world.cards[id]
			if c.status not in statuses: continue
			var key := str([c.status, rows[c.group].signature])
			if signatures.has(key): continue
			signatures[key] = true
			result.append(id)
		return result

	func _modifiers() -> void:
		for gid in _equivalent_groups(work_targets):
			if not _open(): return
			if rows[gid].types.has("union"): continue
			for id in _tool_representatives("overtime"):
				_move([id],gid,"overtime","调配一张加班到工作组合")
			_move(stock.get("overtime", []),gid,"overtime_batch","一次调配全部加班到工作组合")
			for source in rows.values():
				if not _open(): return
				if source.owner == owner and source.id != gid and source.types.get("overtime",[]).size() > 1:
					_move(source.types.overtime,gid,"overtime_batch","整批调配同组加班")
		for id in _tool_representatives("union"):
			if not _open(): return
			_move([id],-1,"remove_union","拆出工会以恢复原有工作等级和加班选择")
			var destinations := []
			for row in rows.values():
				if row.owner == owner and not row.people.is_empty() and not row.types.has("union"): destinations.append(row.id)
			for gid in _equivalent_groups(destinations):
				_move([id],gid,"union","给人员组合加入工会防护")

	func _coffee() -> void:
		var cups: Array = stock.get("coffee", []).filter(func(id): return world.cards[id].status == "ready")
		if cups.is_empty(): return
		for person in person_representatives:
			if not _open(): return
			var kind: String = world.cards[person].type
			var recipe: Dictionary = world.config.coffee_upgrade(kind)
			if recipe.is_empty() or int(recipe.cost) > cups.size(): continue
			var total := 0
			var amounts := [int(recipe.cost)]
			while not recipe.is_empty() and total + int(recipe.cost) <= cups.size():
				if not _open(): return
				total += int(recipe.cost)
				recipe = world.config.coffee_upgrade(str(recipe.to))
			amounts.append(total)
			for count in amounts:
				_move([person] + cups.slice(0,count),-1,"coffee","拆出人员并备齐完整升级配方",person)
			var gid: int = int(world.cards[person].group)
			if rows[gid].work.is_empty() and rows[gid].job in ["work","meeting"]:
				for id in rows[gid].types.get("coffee",[]):
					if world.cards[id].status == "ready":
						_activate(id,gid,"coffee","启动已经备齐的咖啡组合",person)
						break

	func _meetings_and_strikes() -> void:
		for tool in _tool_representatives("strike"):
			for row in rows.values():
				if not _open(): return
				if row.owner != owner and world.can_strike_group(int(row.id),owner):
					_activate(tool,row.id,"strike","向对方正在生产的组合发起罢工")
		if world.meeting_candidates(owner).is_empty(): return
		for tool in _tool_representatives("meeting",["ready","recovering"]):
			for person in person_representatives:
				if not _open(): return
				_move([tool,person],-1,"meeting","主持人与开会牌独立组队",person)
				var gid: int = int(world.cards[tool].group)
				if world.cards[tool].status == "ready" and int(world.cards[person].group) == gid and rows[gid].function in ["","meeting"]:
					_activate(tool,gid,"meeting","启动已有会议组合",person)

	func _cash_for(amount: int, exclude_group := -1) -> Array:
		var ids := []
		var left := amount
		for id in cash:
			if not _open(): return ids
			if left <= 0: break
			if exclude_group >= 0 and int(world.cards[id].group) == exclude_group: continue
			ids.append(id)
			left -= int(world.cards[id].amount)
		return ids if left <= 0 else []

	func _outsource_amounts(limit: int) -> Array:
		var unscheduled := 0
		var naturally := 0
		for id in work:
			if not _open(): return []
			if not assigned.has(id): unscheduled += 1
		for gid in work_targets:
			if not _open(): return []
			var participants := world.group_work_participants(gid)
			var capacity := 0
			for id in participants: capacity += world.tasks[id].work_ids.size()
			var cycles := floori(float(rows[gid].progress) + world.group_work_rate(gid) * world.config.number("outsource","seconds"))
			naturally += mini(rows[gid].work.size(), maxi(0,cycles) * capacity)
		return [limit, mini(limit,unscheduled), mini(limit,maxi(0,work.size()-naturally))]

	func _outsourcing() -> void:
		if work.is_empty(): return
		var unit: int = world.config.integer("outsource","cost_per_work")
		for tool in _tool_representatives("outsource",["ready","recovering","active"]):
			if not _open(): return
			var gid: int = int(world.cards[tool].group)
			var active: bool = world.cards[tool].status == "active"
			var local_surplus := 0
			var available := movable_funds
			if active:
				# A reserved wallet cannot be moved, but its unreserved balance
				# already belongs to this batch's group. Refill with work alone
				# or combine that balance with movable money from other groups.
				for id in rows[gid].types.get("money",[]):
					if not _open(): return
					var amount: int = world.cards[id].amount
					local_surplus += maxi(0,amount-int(reserved_cash.get(id,0)))
					if not reserved_cash.has(id): available -= amount
				available += local_surplus
			var maximum := mini(work.size(),available / unit)
			if maximum <= 0: continue
			for amount in _outsource_amounts(maximum):
				if not _open(): return
				if int(amount) <= 0: continue
				var payment: Array = _cash_for(maxi(0,int(amount)*unit-local_surplus),gid) if active else _cash_for(int(amount)*unit)
				var materials: Array = work.slice(0,int(amount)) + payment
				if active:
					_move(materials,gid,"outsource_feed","给正在进行的外包追加可支付的整批工作")
				else:
					_move([tool]+materials,-1,"outsource","将外包、完整资金和工作独立组队；比较全额冲线与保留生产")
			if world.cards[tool].status == "ready" and rows[gid].function in ["","outsource"] and not rows[gid].work.is_empty() and rows[gid].types.has("money"):
				_activate(tool,gid,"outsource","启动已有外包组合")

	func _tool_staff_choices() -> Array:
		var batches := []
		for person in person_representatives: batches.append([person])
		batches.append_array(_batches(idle_people,false))
		var sources := []
		for row in rows.values():
			if not _open(): return batches
			if row.owner == owner and row.movable.size() > 1: sources.append(row.id)
		for gid in _equivalent_groups(sources): batches.append_array(_batches(rows[gid].movable,false))
		if movable.size() > 1: batches.append(movable.duplicate())
		return batches

	func _transfer_and_slack() -> void:
		var staff_choices := _tool_staff_choices()
		for kind in ["transfer","slack"]:
			for tool in _tool_representatives(kind,["ready","active"]):
				if not _open(): return
				var gid: int = int(world.cards[tool].group)
				for staff in staff_choices:
					if not _open(): return
					if kind == "slack":
						_move([tool]+staff,-1,"slack","人员与摸鱼牌独立组队生产咖啡")
						if rows[gid].function == "slack": _move(staff,gid,"slack_staff","批量补充摸鱼人员")
					else:
						var capacity := _capacity(staff,true)
						for count in [mini(capacity,work.size()),work.size()]:
							if count > 0: _move([tool]+staff+work.slice(0,count),-1,"transfer","甩锅工具、人员与工作独立组队")
						if rows[gid].function == "transfer": _move(staff,gid,"transfer_staff","批量补充甩锅人员")
				if kind == "transfer" and rows[gid].function == "transfer":
					_move(work,gid,"transfer_feed","给甩锅组合补入完整待办")
				# A running slack line already produces on its natural clock.
				# Re-activating it only reconciles the same state, consuming a BOT
				# command and forecast budget without starting another batch.
				var running_slack: bool = kind == "slack" and world.cards[tool].status == "active" and rows[gid].function == "slack"
				if not running_slack and not rows[gid].people.is_empty() and rows[gid].function in ["",kind] and (kind == "slack" or not rows[gid].work.is_empty()):
					_activate(tool,gid,kind,"启动已有工具组合")
		# Multiple slack cards accelerate the same queue, just as overtime
		# accelerates work; moving all available copies is one real drag action.
		for row in rows.values():
			if not _open(): return
			if row.owner == owner and row.function == "slack":
				_move(stock.get("slack",[]),row.id,"slack_tools","整批合并摸鱼工具")

	func _recruitment() -> void:
		if not world.config.rules.has("recruitment") or cash.is_empty(): return
		var unit: int = world.config.integer("recruitment","cost_per_employee")
		var maximum: int = movable_funds / unit
		if maximum <= 0: return
		for boss in stock.get("boss",[]):
			if not _open(): return
			if world.is_meeting_target(boss) or world.is_striking(boss): continue
			var gid: int = int(world.cards[boss].group)
			for count in [1,maximum]:
				var materials := _cash_for(count*unit)
				if world.recruitment.has(boss):
					_move(materials,gid,"recruitment_feed","给老板追加整批招聘资金")
				else:
					_move([boss]+materials,-1,"recruitment","老板与完整资金独立招聘；比较单人和全额批量")

	func _dismissal() -> void:
		var eligible := []
		for id in people:
			if not _open(): return
			if not world.is_meeting_target(id): eligible.append(id)
		var maximum := maxi(0,people.size()-world.config.integer("fire","minimum_people"))
		if maximum <= 0: return
		for id in _representatives(eligible):
			_emit({"kind":"dismiss","ids":[id]},"dismiss","开除一名不同状态或职责的人员换取现金")
		# Financing quantities are determined by visible prices, rather than
		# a guessed value for a future purchase. Idle/refund order and productive
		# order remain distinct, so the evaluator sees their actual opportunity cost.
		var orders := [eligible.duplicate(),eligible.duplicate()]
		orders[0].sort_custom(func(a,b):
			var a_idle: bool = not world.tasks.has(a)
			var b_idle: bool = not world.tasks.has(b)
			if a_idle != b_idle: return a_idle
			return int(world.config.cards[world.cards[a].type].refund) > int(world.config.cards[world.cards[b].type].refund))
		orders[1].reverse()
		for offer in world.offers:
			if not _open(): return
			if offer.is_empty() or int(offer.price) <= funds or not world.config.can_purchase(str(offer.type)): continue
			for order in orders:
				var chosen := []
				var raised := funds
				for person in order:
					if not _open(): return
					if chosen.size() >= maximum: break
					chosen.append(person)
					raised += int(world.config.cards[world.cards[person].type].refund)
					if raised >= int(offer.price): break
				if raised >= int(offer.price):
					_emit({"kind":"dismiss","ids":chosen},"finance","通过整批开除筹足当前公开报价的资金")
