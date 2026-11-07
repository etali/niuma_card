# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Read-only projection of the simulation clock. A bar may belong to an entire
## group, so the visible card's own `total` is not a reliable timer source.
static func remaining(state: Object, uid: int, phase: String, progress: float) -> float:
	if state == null or not state.cards.has(uid): return -1.0
	var data: Dictionary = state.cards[uid]
	var group := int(data.group)
	if phase == "work":
		var rate: float = state.group_work_rate(group)
		# A meeting can suspend every contributor without discarding the shared
		# progress. Show its frozen active-time remainder, including current buffs.
		if rate <= 0.0:
			var people: Array = state.group_people(group)
			var overtime := 0
			for card_id in state.group_cards(group):
				if state.cards[card_id].type == "overtime": overtime += 1
			var contributors := 0
			for person in people:
				if not state.config.can_work(str(state.cards[person].type)): continue
				# Scheduling releases work slots while their employee attends a
				# meeting; the group still owns its suspended cycle.
				var assigned: bool = state.tasks.has(person) and state.tasks[person].kind == "work"
				if not assigned and not state.is_meeting_target(int(person)): continue
				rate += state.config.work_rate(str(state.cards[person].type), overtime)
				contributors += 1
			if contributors > 0: rate /= float(contributors)
		return maxf(0.0, 1.0 - state.group_work_progress(group)) / rate if rate > 0.0 else -1.0
	if phase == "transfer":
		return maxf(0.0, 1.0 - state.group_transfer_progress(group)) * state.config.number("transfer", "seconds")
	if phase == "slack":
		var tools := 0
		for id in state.group_cards(group):
			if str(state.cards[id].type) == "slack": tools += 1
		# The shared cycle keeps its remaining active time when everybody is
		# away at a meeting or has been ejected by a strike.
		var rate: float = state.config.slack_rate(tools)
		return maxf(0.0, 1.0 - state.group_slack_progress(group)) / rate if rate > 0.0 else -1.0
	if phase == "recovering":
		return maxf(0.0, float(data.remaining))
	if phase in ["meeting", "outsource"]:
		var timers: Dictionary = state.meetings if phase == "meeting" else state.outsourcing
		if timers.has(uid): return maxf(0.0, float(timers[uid].remaining))
		# The top work/money card can display an active tool's group timer.
		for tool in state.group_actions(group):
			if timers.has(tool): return maxf(0.0, float(timers[tool].remaining))
		return -1.0
	if phase == "coffee":
		# Each tier owns its actual reserved task duration. A later tier can
		# have a different configured duration; never infer it from the icon.
		if state.tasks.has(uid) and str(state.tasks[uid].kind) == "coffee":
			return maxf(0.0, 1.0 - progress) * float(state.tasks[uid].total)
		if str(data.type) == "coffee" and float(data.total) > 0.0:
			return maxf(0.0, float(data.remaining))
		return -1.0
	return -1.0
