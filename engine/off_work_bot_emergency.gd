# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

const Actions = preload("res://engine/off_work_bot_actions.gd")

## Bounded legal dispatch for the UI thread. This is not a second evaluator:
## it is only the safe incumbent while the complete search runs in a worker.
static func choose(world: OffWorkState, owner: int, until: int, context: Dictionary) -> Dictionary:
	var cursor := maxi(1, int(context.get("group_cursor", 1)))
	var worker := int(context.get("worker", -1))
	var work := int(context.get("work", -1))
	if Time.get_ticks_usec() >= until:
		return {"action":{"kind":"wait"}, "context":context}
	if not _worker(world, owner, worker): worker = -1
	if not _work(world, owner, work): work = -1
	var upper := world._next_group
	var visited := 0
	var target := -1
	var target_union := false
	var target_ready := false
	var idle_workers: Array = []
	var loose_overtime: Array = []
	var observed := true
	# Reuse only an already valid index. Rebuilding it here would turn the
	# sub-millisecond incumbent into an unbounded scan of every queued file.
	var indexed: bool = world._membership_card_count == world.cards.size() \
		and world._membership_group_count == world.groups.size()
	while Time.get_ticks_usec() < until and visited < maxi(0, upper - 1):
		if cursor >= upper: cursor = 1
		var gid := cursor
		cursor += 1
		visited += 1
		if not world.groups.has(gid): continue
		var group: Dictionary = world.groups[gid]
		if group.owner != owner or group.cards.is_empty(): continue
		# Keep the old resumable endpoint discovery even if this group's cold
		# membership is too large to finish. The next turn starts past it.
		for id in [group.cards.front(), group.cards.back()]:
			if target < 0 and _work(world, owner, int(id)): work = int(id)
			elif _worker(world, owner, int(id)): worker = int(id)
		var row := _observe_group(world, gid, indexed, until)
		if row.is_empty():
			observed = false
			continue
		var ready := false
		for id in row.people:
			if Time.get_ticks_usec() >= until: observed = false; break
			if _worker(world, owner, int(id)):
				idle_workers.append(id)
				worker = int(id)
				ready = true
			elif not bool(world.cards[id].paused) and not world.is_striking(int(id)) \
				and world.tasks.get(id, {}).get("kind", "") == "work":
				ready = true
		if not observed: break
		if not row.types.get("work", []).is_empty() and Actions.Production.accepts_work(row.function, row.exclusive) \
			and target < 0:
			target = gid
			target_union = row.types.has("union")
			target_ready = ready
			work = int(row.types.work[0])
		if Actions.Production.overtime_is_loose(row.function, row.types.has("work"), row.workers):
			for id in row.types.get("overtime", []):
				if Time.get_ticks_usec() >= until: observed = false; break
				if int(world.cards[id].owner) == owner: loose_overtime.append(id)
	var saved := {"group_cursor":cursor, "worker":worker, "work":work}
	# Publish a complete assembly only after the small observed groups have
	# all been visited. Existing work stays in its destination; no assigned
	# batch or another production combination is dismantled by this fallback.
	if observed and visited >= maxi(0, upper - 1) and target >= 0 and Time.get_ticks_usec() < until:
		var materials := Actions.Production.assemble(idle_workers, [], loose_overtime, target_union)
		var ids: Array = []
		var incoming_worker := false
		for id in materials:
			if Time.get_ticks_usec() >= until: observed = false; break
			if int(world.cards[id].group) == target: continue
			ids.append(id)
			if world.can_person_work(int(id)): incoming_worker = true
		if observed and not ids.is_empty() and (target_ready or incoming_worker) and Time.get_ticks_usec() < until:
			return {"action":{"kind":"move", "ids":ids, "group":target, "person":-1,
				"intent":"assemble_work", "reason":"一次合并闲置人员和未投入生产的加班"}, "context":saved}
	# A partial scan never publishes a partial assembly. The previously legal
	# single-person dispatch remains available when the complete scan expires.
	if worker >= 0 and work >= 0 and world.cards[worker].group != world.cards[work].group:
		return {"action":{"kind":"move", "ids":[worker], "group":world.cards[work].group,
			"person":-1, "intent":"dispatch", "reason":"先让已找到的空闲人员处理待办"}, "context":saved}
	return {"action":{"kind":"wait"}, "context":saved}

static func _observe_group(world: OffWorkState, gid: int, indexed: bool, until: int) -> Dictionary:
	var group: Dictionary = world.groups[gid]
	var types: Dictionary = {}
	var people: Array = []
	if indexed and world._membership_index.has(gid):
		var entry: Dictionary = world._membership_index[gid]
		types = entry.types
		people = entry.people
	else:
		for id in group.cards:
			if Time.get_ticks_usec() >= until: return {}
			var kind: String = world.cards[id].type
			# Only presence and one destination witness are needed for inert
			# materials. Do not allocate another array of hundreds of files.
			if kind == "money": continue
			if kind == "work":
				if not types.has(kind): types[kind] = [id]
				continue
			if not types.has(kind): types[kind] = []
			types[kind].append(id)
			if world.config.is_person(kind): people.append(id)
	var workers := false
	for kind in types:
		if Time.get_ticks_usec() >= until: return {}
		if world.config.is_person(str(kind)) and world.config.can_work(str(kind)): workers = true
	return {"types":types, "people":people, "workers":workers,
		"function":str(group.get("function", group.job)),
		"exclusive":types.has("meeting") or types.has("transfer") or types.has("slack") or types.has("outsource")}

static func _worker(world: OffWorkState, owner: int, id: int) -> bool:
	if not world.cards.has(id): return false
	var card: Dictionary = world.cards[id]
	return card.owner == owner and not card.paused and world.can_person_work(id) and not world.tasks.has(id) \
		and not world.is_striking(id) and not world.is_meeting_target(id)

static func _work(world: OffWorkState, owner: int, id: int) -> bool:
	if not world.cards.has(id): return false
	var card: Dictionary = world.cards[id]
	if card.owner != owner or card.type != "work" or not world.groups.has(card.group): return false
	var group: Dictionary = world.groups[card.group]
	var function := str(group.get("function", group.job))
	if function == "work": return true
	if not function.is_empty(): return false
	if group.cards.size() == 1: return true
	# A cold endpoint cannot prove the absence of an exclusive tool hidden
	# inside a huge pile. Only a complete observation may nominate that target.
	if world._membership_card_count != world.cards.size() or world._membership_group_count != world.groups.size() \
		or not world._membership_index.has(card.group): return false
	var types: Dictionary = world._membership_index[card.group].types
	return Actions.Production.accepts_work(function,
		types.has("meeting") or types.has("transfer") or types.has("slack") or types.has("outsource"))
