# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

class ActivityBoard extends RefCounted:
	var _settings := {"local_owner":0}

class CountedState extends OffWorkState:
	var global_rebuilds := 0
	func _ensure_membership_index() -> void:
		var rebuilding := _indexed_card_count != cards.size() or _indexed_group_count != groups.size()
		super._ensure_membership_index()
		if rebuilding: global_rebuilds += 1

func _initialize() -> void:
	_static_large_queues()
	_production_and_config_changes()
	_timed_events()
	_membership_and_restore()
	_cached_and_reconciled_rules()
	_activity_cache_invalidation()
	_simultaneous_settlement()
	finish()

func _state(work := 40, working := false) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":work, "employee":1}] if working else [{"work":work}, {"employee":1}]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(781)
	state.drain_events()
	return state

func _work(state: OffWorkState, owner := 0) -> int:
	return int(state.cards[state._owner_type(owner, "work")[0]].group)

func _person(state: OffWorkState, owner := 0) -> int:
	return int(state._owner_type(owner, "employee")[0])

func _assert_index(state: OffWorkState, label: String) -> void:
	for owner in [0, 1]:
		var works := 0
		var people := 0
		var funds := 0
		var activity := []
		for id in state.cards:
			var card: Dictionary = state.cards[id]
			if int(card.owner) != owner: continue
			if card.type == "work": works += 1
			if card.type == "money": funds += int(card.amount)
			if state.config.is_person(str(card.type)): people += 1
			if state.config.category(str(card.type)) in ["person", "tool", "ingredient"]: activity.append(id)
		check(state.work_count(owner) == works and state.people_count(owner) == people and state.money(owner) == funds,
			label + " owner counters match real cards %d" % owner)
		check(state.activity_card_ids(owner) == activity, label + " activity index matches real cards %d" % owner)
	for gid in state.groups:
		var expected := []
		for id in state.groups[gid].cards:
			if state.cards[id].type == "work": expected.append(id)
		check(state.group_work(gid) == expected, label + " group keeps exact ordered membership %d" % gid)

func _static_large_queues() -> void:
	var state := _state(4000)
	check(state.cards.size() == 8002 and state.work_count(0) == 4000 and state.work_count(1) == 4000,
		"large fixture keeps every actual card for both owners")
	var group := _work(state)
	var membership: Dictionary = state._indexed_group(group)
	var work_ids: Array = membership.types.work
	var events := state.drain_events()
	for frame in 120: state.advance(1.0 / 60.0)
	check(is_same(membership, state._indexed_group(group)) and is_same(work_ids, state._indexed_group(group).types.work),
		"unchanged frames reuse membership arrays instead of rebuilding 8000 work cards")
	check(state.tasks.is_empty() and not state._schedule_dirty and is_equal_approx(state.time, 2.0),
		"idle queues advance their clock without inventing tasks or dirty schedules")
	check(events.is_empty() and state.drain_events().all(func(event): return event.kind == "conveyor"),
		"idle frames preserve ordinary supply events")
	check(state.activity_card_ids().size() == 2, "dynamic projection excludes all 8000 idle work cards")
	var copy := state.activity_card_ids()
	copy.clear()
	check(state.activity_card_ids().size() == 2, "callers cannot change the activity index through its returned array")

func _production_and_config_changes() -> void:
	var state := _state(4000, true)
	var person := _person(state)
	var assignment: Dictionary = state.tasks[person]
	var group := _work(state)
	state.advance(0.1)
	state.advance(0.1)
	check(is_same(assignment, state.tasks[person]), "frames before a real event retain the same work assignment")
	check(is_equal_approx(state.group_work_progress(group), 0.02) and state.group_work(group).all(
		func(id): return is_equal_approx(state.cards[id].progress, 0.02)), "all real work cards retain their shared progress projection")
	state.config.roles.employee.work_capacity = 3
	state.advance(9.8)
	check(state.work_count(0) == 3997 and state.money(0) == 3, "live rule changes invalidate assignments before their exact completion")
	check(not is_same(assignment, state.tasks[person]), "a completed batch receives its next real assignment")
	_assert_index(state, "after production")

func _timed_events() -> void:
	var state := _state(80, true)
	var target := _work(state, 1)
	var person := _person(state, 1)
	state.advance(2.0)
	var strike := state.add_card("strike", 0)
	var flight: float = state.config.number("strike", "flight_seconds")
	check(state.activate(strike, target), "strike starts through the ordinary public action")
	state.advance(flight)
	check(state.is_striking(person) and not state.tasks.has(person), "flight event invalidates work slots at the hit boundary")
	var duration: float = state.config.number("strike", "duration_seconds")
	state.advance(duration - 0.01)
	check(state.is_striking(person), "cached timer cannot release striking staff early")
	state.advance(0.01)
	check(not state.is_striking(person) and state.cards[person].status == "ready", "striking timer settles exactly and refreshes the same card")
	state.move_cards([person], target)
	check(state.tasks.has(person) and state.tasks[person].kind == "work", "recovered staff rejoin existing work through the same schedule")
	_assert_index(state, "after strike recovery")

func _memberships_snapshot(state: OffWorkState) -> Dictionary:
	var world := {}
	for key in OffWorkState.WORLD_FIELDS:
		var value: Variant = state.get(key)
		world[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	return world

func _membership_and_restore() -> void:
	var state := _state(100)
	var person := _person(state)
	var group := _work(state)
	var transfer := state.add_card("transfer", 0)
	var target: int = state.cards[transfer].group
	state.move_cards([person] + state.group_work(group).slice(0, 6), target)
	state.advance(state.config.number("transfer", "seconds"))
	check(state.work_count(0) == 99 and state.work_count(1) == 101, "real transfer changes ownership without changing total workload")
	_assert_index(state, "after transfer")
	var snapshot := _memberships_snapshot(state)
	var added := state.add_card("employee", 0)
	check(state.activity_card_ids(0).has(added), "new personnel immediately enter the dynamic index")
	check(state.dismiss_people([added], 0) and not state.activity_card_ids(0).has(added), "dismissal removes the actual UID from all indexes")
	_assert_index(state, "after dismissal and payout")
	for key in OffWorkState.WORLD_FIELDS: state.set(key, snapshot[key])
	state._invalidate_group_index()
	_assert_index(state, "after restoring a previously indexed instance")
	var branch := state.fork_for_bot(91)
	check(branch._membership_index.is_empty(), "BOT fork carries only authoritative world fields")
	branch.advance(0.25)
	_assert_index(branch, "after independent BOT continuation")
	check(is_equal_approx(state.time, state.config.number("transfer", "seconds")), "BOT continuation leaves the original world clock intact")
	state.new_game(782)
	_assert_index(state, "after reused instance starts a new game")

func _cached_and_reconciled_rules() -> void:
	var state := _state(150, true)
	var person := _person(state)
	state.move_cards([person])
	var coffee := state.add_card("coffee", 0)
	state.move_cards([coffee], state.cards[person].group)
	var host := state.add_card("leader", 1)
	var meeting := state.add_card("meeting", 1)
	state.move_cards([meeting], state.cards[host].group)
	var branch := state.fork_for_bot(88)
	var reconciled := state.fork_for_bot(88)
	for seconds in [0.1, 0.2, 1.1, 5.0, 10.0, 20.0, 30.0]:
		# A forced reconstruction uses the identical rules. Only cache lifetime
		# differs, including meeting release, recovery/repeat and coffee queues.
		reconciled._invalidate_group_index()
		branch.advance(seconds)
		reconciled.advance(seconds)
		var differences := []
		for key in OffWorkState.WORLD_FIELDS:
			if branch.get(key) != reconciled.get(key): differences.append(key)
		check(differences.is_empty(), "persistent and freshly reconciled worlds agree after %.2f seconds: %s" % [seconds, differences])

func _activity_cache_invalidation() -> void:
	var state := _state(40)
	for owner in [0, 1]:
		var transfer := state.add_card("transfer", owner)
		state.move_cards([_person(state, owner)] + state.group_work(_work(state, owner)), state.cards[transfer].group)
	var host = load("res://scenes/off_work_main.gd").new()
	host.state = state
	host.board = ActivityBoard.new()
	var before: Dictionary = host._capture_player_activity()
	var group: int = state.cards[_person(state)].group
	var before_version := state.membership_version()
	var snapshot := _memberships_snapshot(state)
	state.advance(state.config.number("transfer", "seconds"))
	check(state.revision == int(snapshot.revision) and state.membership_version() > before_version,
		"simultaneous transfers invalidate membership without changing gameplay revision")
	var after: Dictionary = host._capture_player_activity()
	var expected := state.group_cards(group)
	expected.sort()
	check(after.groups[group].size() == before.groups[group].size() and after.groups[group] != before.groups[group],
		"equal-size exchanged stacks publish their new real UIDs")
	check(after.groups[group] == expected, "main activity cache follows the indexed membership generation")
	var after_version := state.membership_version()
	for key in OffWorkState.WORLD_FIELDS: state.set(key, snapshot[key])
	state._invalidate_group_index()
	check(state.revision == int(snapshot.revision) and state.membership_version() > after_version,
		"same-instance same-revision restore changes only the derived membership lifetime")
	check(host._capture_player_activity() == before, "main refreshes restored membership even at identical gameplay revision")
	var stable := state.membership_version()
	state.advance(0.1)
	stable = state.membership_version()
	state.advance(0.1)
	check(state.membership_version() == stable, "ordinary elapsed time does not churn membership generation")
	check(not OffWorkState.WORLD_FIELDS.has("_membership_generation"), "cache generation stays outside snapshots and network protocol")
	host.free()

func _simultaneous_settlement() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":2000, "employee":12, "overtime":4}]
	config.rules.initial.money = 0
	var state := CountedState.new(config)
	state.new_game(783)
	var cycle: float = 1.0 / config.work_rate("employee", 4)
	state.advance(cycle - 0.01)
	var rebuilt_before := state.global_rebuilds
	var reference := state.fork_for_bot(783)
	state.advance(0.02)
	reference._sync_schedule()
	reference.advance(0.02)
	check(state.global_rebuilds - rebuilt_before == 1,
		"simultaneous twelve-person settlements rebuild the global index once, after both payouts")
	check(state.work_count(0) == 1988 and state.work_count(1) == 1988 and state.money(0) == 12 and state.money(1) == 12,
		"one shared boundary consumes all 24 actual files and creates all 24 actual cash cards")
	var differences := []
	for key in OffWorkState.WORLD_FIELDS:
		if state.get(key) != reference.get(key): differences.append(key)
	check(differences.is_empty(), "batched index rebuilding agrees with forced schedule reconciliation: %s" % differences)
	var group := _work(state)
	var before_group: Dictionary = state._indexed_group(group)
	var global_before := state.global_rebuilds
	state._invalidate_group_index()
	var rebuilt_group: Dictionary = state._indexed_group(group)
	check(state.global_rebuilds == global_before, "rebuilding one pile never constructs the unrelated global indexes")
	state.activity_card_ids()
	check(not is_same(before_group, rebuilt_group) and is_same(rebuilt_group, state._indexed_group(group)) and state.global_rebuilds == global_before + 1,
		"global lookups preserve a freshly rebuilt group's membership")
