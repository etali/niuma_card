# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Preserve only the next dispatch promised by an already paid macro prefix.
## Future recruitment UIDs belong to a hypothetical branch and are never kept.
## The BOT may use this legal incumbent while a new root ranking is incomplete.
static func remember(world: OffWorkState, owner: int, action: Dictionary, report: Dictionary) -> Dictionary:
	var sides: Array = report.get("evaluation", {}).get("sides", [])
	if sides.size() != 2: return {}
	var chain: Dictionary = sides[owner].get("production_chain", {})
	if chain.get("kind", "") != "sustained_growth" or not chain.get("complete", false): return {}
	if int(chain.get("owner", owner)) != owner: return {}
	var commands: Array = chain.get("commands", [])
	if commands.size() < 2 or float(commands[0].get("at", INF)) > 1e-8: return {}
	var first: Dictionary = commands[0].action
	var next: Dictionary = commands[1].action
	var intent := str(first.get("growth_intent", first.get("intent", "")))
	if intent not in ["growth_recruit", "growth_recruit_feed", "growth_upgrade"]: return {}
	if not _same_command(first, action) or not _paid(world, owner, action, intent): return {}
	if str(next.get("growth_intent", next.get("intent", ""))) != "growth_return" or next.get("kind", "") != "move": return {}
	var group := int(next.get("group", -1))
	if not _target(world, owner, group, -1): return {}
	var delay := float(commands[1].get("at", -1.0)) - float(commands[0].at)
	if not is_finite(delay) or delay <= 0.0: return {}
	return {"group":group,"ready_at":float(world.time)+delay,"observed_at":float(world.time)}

static func resolve(world: OffWorkState, owner: int, context: Dictionary, until: int) -> Dictionary:
	var waiting := {"action":{"kind":"wait"},"context":context.duplicate(true)}
	if context.is_empty(): return waiting
	var group := int(context.get("group", -1))
	var seen := float(context.get("observed_at", INF))
	var ready := float(context.get("ready_at", INF))
	if world.winner >= 0 or not is_finite(seen) or not is_finite(ready) or world.time < seen - 1e-8 \
			or not world.groups.has(group) or int(world.groups[group].owner) != owner \
			or str(world.groups[group].get("function", "")) not in ["","work"]:
		waiting.context = {}
		return waiting
	if until >= 0 and Time.get_ticks_usec() >= until: return waiting
	if not _target(world, owner, group, until):
		if until < 0 or Time.get_ticks_usec() < until: waiting.context = {}
		return waiting
	if world.time + 1e-8 < ready: return waiting
	# A temporary strike may block joining this very group. Keep the promise
	# and revalidate later; it is not a reason to select another destination.
	for id in world.groups[group].cards:
		if until >= 0 and Time.get_ticks_usec() >= until: return waiting
		if world.can_person_work(int(id)) and world.is_striking(int(id)): return waiting
	var staff := []
	# Walk real groups with a deadline check, avoiding an indivisible rebuild
	# of the whole work-card index just to discover recently recruited people.
	for gid in world.groups:
		if int(gid) == group or int(world.groups[gid].owner) != owner: continue
		for id in world.groups[gid].cards:
			if until >= 0 and Time.get_ticks_usec() >= until: return waiting
			if not world.cards.has(id) or int(world.cards[id].owner) != owner: continue
			if not world.can_person_work(int(id)) or world.tasks.has(id): continue
			if bool(world.cards[id].get("paused", false)) or world.is_striking(int(id)) or world.is_meeting_target(int(id)): continue
			staff.append(int(id))
	if staff.is_empty():
		# A delayed upgrade/recruitment can still settle later. If none remains,
		# the expected staff were already dispatched or the investment cancelled.
		var pending := world.tasks.keys().any(func(id): return world.cards.has(id) and int(world.cards[id].owner)==owner \
			and str(world.tasks[id].get("kind", "")) in ["coffee","recruitment"])
		if not pending: waiting.context = {}
		return waiting
	waiting.action = {"kind":"move","ids":staff,"group":group,"person":-1,
		"intent":"staff_batch","growth_intent":"growth_continuation",
		"reason":"将已完成招聘或升级的空闲人员投入原计划的工作组合"}
	return waiting

static func _target(world: OffWorkState, owner: int, group: int, until: int) -> bool:
	if not world.groups.has(group) or int(world.groups[group].owner) != owner or str(world.groups[group].get("function", "")) not in ["","work"]: return false
	var has_work := false
	for id in world.groups[group].cards:
		if until >= 0 and Time.get_ticks_usec() >= until: return false
		if not world.cards.has(id): continue
		if world.cards[id].type == "work": has_work = true
		# An empty work pile loses its work lock until personnel arrive. Do not
		# mistake that for an invalid target, but avoid starting another tool's
		# function by adding the promised staff to an unlocked mixed pile.
		if str(world.groups[group].get("function", "")) == "" and str(world.cards[id].type) in ["meeting","transfer","slack","outsource"]: return false
	return has_work

static func _paid(world: OffWorkState, owner: int, action: Dictionary, intent: String) -> bool:
	if intent == "growth_upgrade":
		var person := int(action.get("person", -1))
		return world.cards.has(person) and int(world.cards[person].owner) == owner \
			and str(world.tasks.get(person, {}).get("kind", "")) == "coffee"
	for boss in world.recruitment:
		var batch: Dictionary = world.recruitment[boss]
		if int(batch.owner) != owner or int(batch.count) <= 0: continue
		if action.get("ids", []).has(boss) or (intent == "growth_recruit_feed" and int(action.get("group", -1)) == int(batch.group)): return true
	return false

static func _same_command(a: Dictionary, b: Dictionary) -> bool:
	if a.get("kind", "") != b.get("kind", ""): return false
	for key in ["group","person","tool","offer"]:
		if int(a.get(key, -1)) != int(b.get(key, -1)): return false
	var first: Array = a.get("ids", []).duplicate()
	var second: Array = b.get("ids", []).duplicate()
	first.sort()
	second.sort()
	return first == second
