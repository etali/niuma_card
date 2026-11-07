extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_five_person_batch()
	_role_mix_and_short_queue()
	_configured_work_capacity()
	_join_split_and_merge()
	_meeting_capacity()
	_coffee_capacity()
	_strike_and_other_jobs()
	_step_independence()
	for failure in failures: printerr("FAIL ", failure)
	print("GROUP_WORK_CYCLES ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _state(contents: Dictionary) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(53)
	state.drain_events()
	return state

func _ids(state: OffWorkState, kind: String, owner := 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == kind and int(state.cards[id].owner) == owner)

func _group(state: OffWorkState, owner := 0) -> int:
	return int(state.cards[_ids(state, "work", owner)[0]].group)

func _events(state: OffWorkState, owner := 0) -> Array:
	return state.drain_events().filter(func(event): return event.kind == "work_complete" and event.owner == owner)

func _five_person_batch() -> void:
	var state := _state({"employee": 5, "work": 30})
	var group := _group(state)
	state.advance(7.5)
	_check(is_equal_approx(state.group_work_progress(group), 0.75), "five-person production has one group clock at 75 percent")
	_check(state.group_work_participants(group).size() == 5 and is_equal_approx(state.group_work_rate(group), 0.1), "five people increase batch capacity without speeding its clock")
	for person in state.group_people(group):
		_check(is_equal_approx(state.cards[person].progress, state.group_work_progress(group)), "each person is a projection of the same shared clock")
	_check(_events(state).is_empty() and state.money(0) == 0, "no partial payout before the shared bar fills")
	state.advance(2.5)
	var events := _events(state)
	_check(events.size() == 1, "one group completion emits exactly one paid event")
	var event: Dictionary = events[0]
	_check(event.ids.size() == 5 and event.participants == state.group_people(group), "one batch consumes five distinct work cards with five actual participants")
	_check(event.amount == 5 and state.money(0) == 5 and state.work_count(0) == 25, "one batch accounts for five work and five money exactly once")
	_check(_ids(state, "money").size() == 5 and event.money_ids.size() == 5 and event.money_ids.all(func(id): return state.cards[id].amount == 1), "one shared batch credits five separately spendable unit cash cards")
	_check(event.money_group != group and state.group_cards(event.money_group) == event.money_ids, "batch cash belongs to its separate pure money pile")
	_check(is_zero_approx(state.group_work_progress(group)), "next batch begins with one empty clock")
	state.advance(10.0)
	_check(_events(state).size() == 1 and state.money(0) == 10 and _ids(state, "money").size() == 10, "second shared batch yields five more unit cash cards")

func _role_mix_and_short_queue() -> void:
	var state := _state({"employee": 3, "grinder": 2, "leader": 2, "work": 30})
	var group := _group(state)
	state.advance(10.0)
	var event: Dictionary = _events(state)[0]
	_check(event.ids.size() == 5 and event.amount == 7 and event.participants.size() == 5, "mixed batch sums three employee incomes and two doubled grinder incomes")
	_check(event.participants.all(func(person): return state.cards[person].type != "leader"), "leaders contribute neither a work slot nor income")
	var short := _state({"employee": 5, "work": 2})
	short.advance(10.0)
	var tail: Dictionary = _events(short)[0]
	_check(tail.ids.size() == 2 and tail.participants.size() == 2 and tail.amount == 2, "short final queue completes only its actual two work cards")
	_check(short.work_count(0) == 0 and short.money(0) == 2 and _ids(short, "money").size() == 2, "final short batch neither overpays nor creates empty work")
	var rewarded := _state({"employee": 1, "grinder": 1, "work": 30})
	rewarded.advance(10.0)
	var paid: Dictionary = _events(rewarded)[0]
	_check(paid.amount == 3 and paid.participants.size() == 2, "mixed batch pays one employee plus doubled grinder income once")

func _configured_work_capacity() -> void:
	var state := _state({"employee": 1, "grinder": 1, "work": 9})
	state.config.roles.employee.work_capacity = 2
	state.config.roles.grinder.work_capacity = 3
	OffWorkCardDB.configure(state.config)
	var recipe := OffWorkCardDB.get_def("grinder")
	_check(recipe.recipe_n == 3 and recipe.output_n == 6, "card recipe uses full configured grinder capacity")
	var cards: Array = [{"type": "employee"}, {"type": "grinder"}]
	for _i in range(4): cards.append({"type": "work"})
	var preview := OffWorkComboRules.evaluate(cards)
	_check(preview.recipe_pay_n == 4 and preview.output_n == 6, "short queue preview pays two employee and two grinder files")
	state.advance(10.0)
	var full: Dictionary = _events(state)[0]
	_check(full.participants.size() == 2 and full.ids.size() == 5 and full.amount == 8, "two workers use their individual capacities and income multipliers")
	state.advance(10.0)
	var tail: Dictionary = _events(state)[0]
	_check(tail.participants.size() == 2 and tail.ids.size() == preview.recipe_pay_n and tail.amount == preview.output_n, "partial final batch matches composition preview")
	_check(state.work_count(0) == 0 and state.money(0) == 14, "full and partial batches settle actual work and cash once")

func _join_split_and_merge() -> void:
	var state := _state({"employee": 1, "work": 30})
	var group := _group(state)
	state.advance(6.0)
	var extra := state.add_card("employee", 0)
	state.move_cards([extra], group)
	_check(is_equal_approx(state.group_work_progress(group), 0.6) and is_equal_approx(state.cards[extra].progress, 0.6), "mid-batch join follows the target shared progress immediately")
	state.advance(4.0)
	var events := _events(state)
	_check(events.size() == 1 and events[0].ids.size() == 2 and events[0].participants.has(extra), "new colleague participates when current shared batch completes")
	state.advance(4.0)
	var work: int = state.group_work(group)[0]
	var detached := state.move_cards([extra, work], -1)
	_check(detached != group and is_equal_approx(state.group_work_progress(detached), 0.4) and is_equal_approx(state.group_work_progress(group), 0.4), "splitting personnel with work carries shared progress into the new group")
	state.drain_events()
	state.advance(6.0)
	events = _events(state)
	_check(events.size() == 2 and events.all(func(event): return event.ids.size() == 1), "two newly independent groups finish one work each without duplicate settlement")
	var claimed: Array = []
	for event in events: claimed.append_array(event.ids)
	_check(claimed.size() == 2 and claimed[0] != claimed[1] and state.money(0) == 4, "split batches contain unique real work and correct total money")
	var merge := _state({"employee": 1, "work": 30})
	var main := _group(merge)
	merge.advance(7.0)
	var person := merge.add_card("employee", 0)
	var fresh := int(merge.cards[person].group)
	merge.add_card("work", 0, fresh)
	merge.advance(1.0)
	_check(is_equal_approx(merge.group_work_progress(main), 0.8) and is_equal_approx(merge.group_work_progress(fresh), 0.1), "merge fixture has independent source and target progress")
	merge.move_cards(merge.group_cards(main), fresh)
	_check(is_equal_approx(merge.group_work_progress(fresh), 0.1), "merging follows destination progress without adding clocks or granting a completion")
	merge.drain_events()
	merge.advance(9.0)
	events = _events(merge)
	_check(events.size() == 1 and events[0].ids.size() == 2 and merge.money(0) == 2, "merged group settles once at target deadline")

func _meeting_capacity() -> void:
	var state := _state({"employee": 5, "work": 100})
	var group := _group(state)
	state.advance(5.0)
	var enemy_host := state.add_card("employee", 1)
	var enemy_group: int = state.cards[enemy_host].group
	var meeting := state.add_card("meeting", 1, enemy_group)
	_check(state.activate(meeting, enemy_group, enemy_host), "enemy meeting removes two personnel from the current production batch")
	var targets: Array = state.meetings[meeting].targets.duplicate()
	state.drain_events()
	state.advance(5.0)
	var events := _events(state)
	_check(events.size() == 1 and events[0].ids.size() == 3 and events[0].amount == 3, "remaining three employees settle one smaller batch at the original deadline")
	_check(events[0].participants.all(func(person): return not targets.has(person)), "meeting attendees receive no share and consume no work while absent")
	state.advance(7.0)
	_check(not state.meetings.has(meeting) and state.group_work_participants(group).size() == 5 and is_equal_approx(state.group_work_progress(group), 0.7), "released personnel rejoin the current group clock rather than restart private work")
	state.advance(3.0)
	events = _events(state)
	_check(events.size() == 1 and events[0].ids.size() == 5 and state.money(0) == 8, "released employees join the next full five-person payout")
	var single := _state({"employee": 1, "work": 30})
	var own := _group(single)
	single.advance(3.0)
	var host: int = _ids(single, "employee", 1)[0]
	var tool := single.add_card("meeting", 1, single.cards[host].group)
	single.activate(tool)
	single.advance(12.0)
	_check(is_equal_approx(single.group_work_progress(own), 0.3) and single.money(0) == 0, "group clock freezes if all workers attend a meeting")

func _coffee_capacity() -> void:
	var state := _state({"employee": 2, "work": 30})
	var group := _group(state)
	state.advance(6.0)
	var upgrading: int = _ids(state, "employee")[0]
	var break_group := state.move_cards([upgrading])
	var coffee := state.add_card("coffee", 0, break_group)
	state.activate(coffee, break_group, upgrading)
	state.drain_events()
	state.advance(4.0)
	var events := _events(state)
	_check(events.size() == 1 and events[0].ids.size() == 1 and not events[0].participants.has(upgrading), "drinking employee is absent from work batch while colleague continues")
	state.advance(1.0)
	state.move_cards([upgrading], group)
	_check(state.cards[upgrading].type == "grinder" and is_equal_approx(state.group_work_progress(group), 0.1) and is_equal_approx(state.cards[upgrading].progress, 0.1), "finished upgrade joins current shared progress with same UID")
	state.advance(9.0)
	events = _events(state)
	_check(events.size() == 1 and events[0].ids.size() == 2 and events[0].amount == 3, "upgraded grinder contributes doubled income to next shared batch")
	var only := _state({"employee": 1, "work": 30})
	var person: int = _ids(only, "employee")[0]
	only.advance(4.0)
	var original_group := _group(only)
	var only_break := only.move_cards([person])
	var cup := only.add_card("coffee", 0, only_break)
	only.activate(cup, only_break, person)
	only.advance(5.0)
	_check(is_equal_approx(only.group_work_progress(original_group), 0.4) and only.money(0) == 0, "single-worker upgrade freezes and retains group progress")

func _strike_and_other_jobs() -> void:
	var state := _state({"employee": 3, "work": 100})
	var group := _group(state)
	state.advance(4.0)
	var people := state.group_people(group)
	var strike := state.add_card("strike", 1)
	_check(state.activate(strike, group) and not state.cards.has(strike), "strike targets a working group and is consumed")
	_check(is_equal_approx(state.group_work_progress(group), 0.4) and state.group_people(group).is_empty(), "strike ejects all workers while preserving the shared clock")
	state.drain_events()
	state.advance(20.0)
	_check(_events(state).is_empty() and state.money(0) == 0, "ejected workers cannot produce during the full dance duration")
	state.move_cards(people, group)
	state.advance(6.0)
	_check(_events(state).size() == 1 and state.money(0) == 3, "regrouped workers complete the remaining shared work exactly once")
	var transfer := state.add_card("transfer", 0, group)
	state.activate(transfer)
	state.drain_events()
	state.advance(12.0)
	_check(_events(state).is_empty() and state.money(0) == 3, "switching group to transfer cannot trigger an ordinary work payout")

func _step_independence() -> void:
	var coarse := _state({"employee": 3, "grinder": 2, "work": 200, "overtime": 3})
	var fine := _state({"employee": 3, "grinder": 2, "work": 200, "overtime": 3})
	coarse.advance(43.7)
	for i in range(437): fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.money(0) == fine.money(0), "shared work and cash totals are independent of frame size")
	_check(is_equal_approx(coarse.group_work_progress(_group(coarse)), fine.group_work_progress(_group(fine))), "shared residual progress is independent of frame size")
	var a := _events(coarse)
	var b := _events(fine)
	_check(a.size() == b.size() and a.map(func(event): return event.ids) == b.map(func(event): return event.ids), "large advance preserves the same ordered real work batches")
	_check(a.map(func(event): return event.money_ids) == b.map(func(event): return event.money_ids), "large advance creates the same complete batch of cash UIDs")
