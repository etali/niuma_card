# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Symmetric, declared stress starts. All subsequent actions use real rules.
## These are separate comparisons, never pooled with the ordinary opening.
static func configure(config: RefCounted, scenario: String) -> bool:
	match scenario:
		"default": pass
		"growth":
			config.rules.initial.groups = [{"employee":12, "work":240}, {"employee":6}, {"overtime":6}]
			config.rules.initial.money = 120
		"production":
			# The 19th employee completes all 19 documents in one batch. This
			# aligns the bulk-staffing capability with the real race objective.
			config.rules.initial.groups = [{"employee":12, "work":19}, {"employee":6}]
			config.rules.initial.money = 120
		"overtime":
			config.rules.initial.groups = [{"employee":18, "work":600, "overtime":6}]
			config.rules.initial.money = 120
		"recovery":
			config.rules.initial.groups = [{"employee":18, "work":300, "overtime":6}, {"strike":1}]
			config.rules.initial.money = 40
		"outsource":
			config.rules.initial.groups = [{"employee":2}, {"work":48}, {"outsource":1}]
			config.rules.initial.money = 80
		_: return false
	return config.validate()

static func prepare(state: OffWorkState, scenario: String) -> bool:
	# These are declared, already visible offers, not future conveyor input.
	if scenario in ["production", "overtime"]:
		# Put the target in the newest public slot so a legitimate preceding
		# staffing action does not lose it to the next conveyor movement.
		state.offers = [{}, {}, {}, {}, {}, state._make_offer("employee" if scenario == "production" else "overtime")]
	if scenario != "recovery": return true
	for owner in [0, 1]:
		var strike: int = state._owner_type(owner, "strike")[0]
		var target: int = state.cards[state._owner_type(1 - owner, "work")[0]].group
		if not state.activate(strike, target): return false
	state.advance(state.config.number("strike", "flight_seconds") + state.config.number("strike", "duration_seconds"))
	# The recovery capability isolates issuing a bulk return command. A visible
	# overtime investment can rationally precede returning workers, so remove
	# that competing initial action. Later conveyor events still use real rules.
	state.offers.clear()
	return state.pending_strikes.is_empty() and state.cards.values().all(func(card): return card.status != "striking")

static func observe(state: OffWorkState, owner: int, previous := {}) -> Dictionary:
	var people := 0
	var overtime := 0
	for gid in state.groups:
		if state.groups[gid].owner != owner: continue
		var workers := state.group_work_participants(gid).size()
		people += workers
		if workers > 0:
			for id in state.group_tools(gid):
				if state.cards[id].type == "overtime": overtime += 1
	var batch := int(previous.get("largest_outsource", 0))
	for job in state.outsourcing.values():
		if job.owner == owner: batch = maxi(batch, job.work_ids.size())
	return {"active_people":people, "installed_overtime":overtime, "largest_outsource":batch,
		"remaining_work":state.work_count(owner)}

static func achieved(scenario: String, observed: Dictionary) -> bool:
	match scenario:
		"production": return int(observed.active_people) >= 19
		"overtime": return int(observed.installed_overtime) >= 7
		"recovery": return int(observed.active_people) >= 18
		"outsource": return int(observed.largest_outsource) >= 48 and int(observed.remaining_work) == 0
	return false
