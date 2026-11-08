# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## A single possible attack continuation, not an attack bonus or a second
## scheduler. The evaluator must pay and schedule purchase/use on its existing
## action clock, then recheck these targets at use/arrival. Each alternative
## uses ONE tool. No live state or private random stream is changed here.
##
## Public purchases carry their real price and expiry, including purchases not
## affordable yet: the caller's cash forecast decides whether they can occur.
## Owned tools carry ready_seconds. A meeting additionally occupies its host
## for duration_seconds; its sampled targets are one legal public hypothesis.
static func plans(world: OffWorkState, owner: int, until: int = -1) -> Dictionary:
	var result := {"plans":[], "complete":true}
	if not _open(until):
		result.complete = false
		return result
	if world.winner >= 0 or not world.config.rules.simulation.owners.any(func(value): return int(value)==owner): return result
	var owned := {}
	var hosts := []
	var host_keys := {}
	for id in world.cards:
		if not _open(until):
			result.complete = false
			return result
		var card: Dictionary = world.cards[id]
		if int(card.owner) != owner: continue
		var kind := str(card.type)
		if kind in ["strike", "meeting"]:
			var ready := str(card.status) == "ready"
			var recovering := kind == "meeting" and str(card.status) == "recovering"
			if not ready and not recovering: continue
			var seconds := maxf(0.0, float(card.remaining)) if recovering else 0.0
			# With one attack per continuation, identical owned tools have the
			# same effect. Keep the one available first, without an inventory cap.
			if not owned.has(kind) or seconds < float(owned[kind].ready_seconds):
				owned[kind] = {"kind":kind, "tool":int(id), "ready_seconds":seconds}
		elif world.config.is_person(kind):
			if world.is_striking(int(id)) or world.is_meeting_target(int(id)): continue
			var task: Dictionary = world.tasks.get(id, {})
			if str(task.get("kind", "")) not in ["", "work"]: continue
			var key := str([kind,card.group,task.get("kind", ""),task.get("progress",0.0)])
			if host_keys.has(key): continue
			host_keys[key] = true
			hosts.append(int(id))
	var sources: Array = owned.values()
	for slot in world.offers.size():
		if not _open(until):
			result.complete = false
			return result
		var offer: Dictionary = world.offers[slot]
		if offer.is_empty() or str(offer.type) not in ["strike", "meeting"]: continue
		var kind := str(offer.type)
		if not world.config.can_purchase(kind) or not world.can_acquire(kind, owner): continue
		var expires: float = (slot + 1) * world.config.number("conveyor", "interval_seconds") - world._conveyor_elapsed
		if expires <= 0.0: continue
		sources.append({"kind":kind, "offer":int(offer.id), "price":int(offer.price),
			"expires":expires, "ready_seconds":0.0})
	if sources.is_empty(): return result
	var strike_targets := []
	if sources.any(func(source): return source.kind == "strike"):
		for gid in world.groups:
			if not _open(until):
				result.complete = false
				return result
			if not world.can_strike_group(int(gid), owner): continue
			var targets := []
			for id in world.group_people(int(gid)):
				if not _open(until):
					result.complete = false
					return result
				if world.can_person_be_struck(int(id)): targets.append(int(id))
			strike_targets.append({"target_group":int(gid), "targets":targets})
	var meeting_targets := world.meeting_candidates(owner) if not hosts.is_empty() else []
	meeting_targets.sort()
	# The actual meeting draws without replacement. Reproduce that mechanism
	# with a separate seed derived only from visible eligible identities. The
	# seed excludes tool/offer IDs so buying and owning the same opportunity
	# cannot improve its forecast merely by changing an allocated card ID.
	var sample_seed := hash(["off_work_attack_continuation", owner, meeting_targets])
	var samples := {}
	for source in sources:
		if not _open(until):
			result.complete = false
			return result
		if source.kind == "strike":
			for target in strike_targets:
				if not _open(until):
					result.complete = false
					return result
				result.plans.append(source.merged(target).merged({"owner":owner,
					"flight_seconds":float(world.config.rules.strike.get("flight_seconds",0.0)),
					"duration_seconds":world.config.number("strike", "duration_seconds")}))
		elif not meeting_targets.is_empty():
			for host in hosts:
				if not _open(until):
					result.complete = false
					return result
				var capacity: int = world.config.meeting_capacity(str(world.cards[host].type))
				if not samples.has(capacity):
					var remaining: Array = meeting_targets.duplicate()
					var selected := []
					var rng := RandomNumberGenerator.new()
					rng.seed = sample_seed
					while not remaining.is_empty() and selected.size() < capacity:
						if not _open(until):
							result.complete = false
							return result
						selected.append(remaining.pop_at(rng.randi_range(0,remaining.size()-1)))
					samples[capacity] = selected
				result.plans.append(source.merged({"owner":owner, "host":host,
					"targets":samples[capacity].duplicate(), "sampled_targets":true, "sample_seed":sample_seed,
					"flight_seconds":0.0, "duration_seconds":world.config.number("meeting", "duration_seconds")}))
	result.complete = _open(until)
	return result

static func _open(until: int) -> bool:
	return until < 0 or Time.get_ticks_usec() < until
