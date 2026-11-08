# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

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
	while Time.get_ticks_usec() < until and visited < maxi(0, upper - 1):
		if worker >= 0 and work >= 0 and world.cards[worker].group != world.cards[work].group:
			return {"action":{"kind":"move", "ids":[worker], "group":world.cards[work].group,
				"person":-1, "intent":"dispatch", "reason":"先让已找到的空闲人员处理待办"},
				"context":{"group_cursor":cursor, "worker":worker, "work":work}}
		if cursor >= upper: cursor = 1
		var gid := cursor
		cursor += 1
		visited += 1
		if not world.groups.has(gid): continue
		var group: Dictionary = world.groups[gid]
		if group.owner != owner or group.job != "work" or group.cards.is_empty(): continue
		for id in [group.cards.front(), group.cards.back()]:
			if _work(world, owner, int(id)): work = int(id)
			elif _worker(world, owner, int(id)): worker = int(id)
	return {"action":{"kind":"wait"}, "context":{"group_cursor":cursor, "worker":worker, "work":work}}

static func _worker(world: OffWorkState, owner: int, id: int) -> bool:
	if not world.cards.has(id): return false
	var card: Dictionary = world.cards[id]
	return card.owner == owner and not card.paused and world.can_person_work(id) and not world.tasks.has(id)

static func _work(world: OffWorkState, owner: int, id: int) -> bool:
	if not world.cards.has(id): return false
	var card: Dictionary = world.cards[id]
	return card.owner == owner and card.type == "work" and world.groups[card.group].job == "work"
