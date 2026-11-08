extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_configuration()
	_eject_and_recover()
	_move_without_combinations()
	_dismiss_striking_people()
	_invalid_targets()
	_other_jobs()
	_coffee_separation()
	_step_independence()
	for failure in failures: printerr("FAIL ", failure)
	print("STRIKE_RULES %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _state(contents: Dictionary = {"employee": 3, "leader": 1, "work": 100}) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	config.rules.strike.flight_seconds = 0.0
	var state := OffWorkState.new(config)
	state.new_game(71)
	state.drain_events()
	return state

func _group(state: OffWorkState, owner: int) -> int:
	for group in state.groups:
		if int(state.groups[group].owner) == owner and not state.group_work(int(group)).is_empty(): return int(group)
	return -1

func _configuration() -> void:
	var config := OffWorkConfig.new()
	_check(config.validate() and config.cards.has("union"), "current card pool including union validates")
	_check(not config.cards.has("bonus") and not config.cards.has("rework") and config.cards.has("strike"), "bonus is removed and strike replaces rework")
	_check(config.rules.initial.groups.any(func(group): return group.has("overtime")) and not config.rules.initial.groups.any(func(group): return group.has("involution")), "opening has overtime rather than involution")
	_check(is_equal_approx(config.work_rate("employee", 1), 0.12), "one overtime multiplies work speed by 1.2")
	_check(is_equal_approx(config.work_rate("employee", 3), 0.1728), "three overtime cards multiply cumulatively")
	config.rules.strike.duration_seconds = 0.0
	_check(not config.validate(), "zero strike duration is rejected")
	config.rules.strike.duration_seconds = 20.0
	config.rules.overtime.speed_multiplier = 0.0
	_check(not config.validate(), "invalid overtime multiplier is rejected")

func _eject_and_recover() -> void:
	var state := _state()
	var enemy := _group(state, 1)
	var people := state.group_people(enemy)
	var source := state.add_card("strike", 0)
	state.advance(4.0)
	var before_work := state.work_count(1)
	var before_money := state.money(0) + state.money(1)
	_check(state.can_strike_group(enemy, 0), "a working opposing combination is eligible")
	_check(state.activate(source, enemy) and not state.cards.has(source), "successful strike consumes exactly its attack card")
	_check(state.group_people(enemy).is_empty() and is_equal_approx(state.group_work_progress(enemy), 0.4), "all present personnel are ejected while completed work progress is preserved")
	_check(state.work_count(1) == before_work and state.money(0) + state.money(1) == before_money, "strike creates no work removal or money")
	var seen: Dictionary = {}
	for person in people:
		var card: Dictionary = state.cards[person]
		_check(state.is_striking(person) and card.activity == "striking" and card.paused and card.remaining == 20.0 and card.total == 20.0, "ejected person has a twenty-second locked dance state")
		_check(state.group_cards(card.group) == [person] and not seen.has(card.group), "each ejected person owns a separate loose group")
		seen[card.group] = true
		_check(not state.tasks.has(person) and state.move_cards([person], enemy) == -1, "ejected person cannot work or join a combination during the effect")
		_check(not state.meeting_candidates(0).has(person), "ejected person cannot be called into a meeting")
	var employee: int = people.filter(func(id): return state.cards[id].type == "employee")[0]
	var coffee := state.add_card("coffee", 1)
	_check(state.move_cards([coffee], state.cards[employee].group, employee) == -1, "another card cannot be merged into a locked person")
	var saved := JSON.stringify(state.cards)
	_check(not state.activate(source, enemy) and JSON.stringify(state.cards) == saved, "consumed strike cannot be reused")
	state.advance(19.99)
	_check(people.all(func(id): return state.is_striking(id)), "dance remains locked until the full duration")
	_check(state.work_count(1) == before_work and is_equal_approx(state.group_work_progress(enemy), 0.4), "unmanned work does not advance during dance")
	state.advance(0.01)
	_check(people.all(func(id): return not state.is_striking(id) and not state.cards[id].paused and state.cards[id].activity == "idle"), "exactly twenty seconds releases all people")
	_check(state.group_people(enemy).is_empty() and people.all(func(id): return state.group_cards(state.cards[id].group) == [id]), "release keeps personnel scattered rather than automatically regrouping")
	var events := state.drain_events()
	_check(events.filter(func(event): return event.kind == "strike").size() == 1 and events.filter(func(event): return event.kind == "strike_end").size() == people.size(), "one attack and one release per person are emitted")
	_check(state.move_cards(people, enemy) == enemy, "released people can be explicitly regrouped")
	state.advance(6.0)
	_check(state.work_count(1) == before_work - 3, "regrouped workers finish the preserved batch once")

func _move_without_combinations() -> void:
	var state := _state({"employee": 2, "work": 100})
	var old_work := _group(state, 1)
	var people := state.group_people(old_work)
	var person: int = people[0]
	state.activate(state.add_card("strike", 0), old_work)
	state.advance(6.5)
	var loose: int = state.cards[person].group
	var remaining: float = state.cards[person].remaining
	_check(state.move_cards([person], -1) == loose and state.group_cards(loose) == [person], "blank-table relocation preserves the single-person group")
	_check(state.is_striking(person) and is_equal_approx(state.cards[person].remaining, remaining), "dragging the loose person does not restart or clear the strike timer")
	var empty := state.create_group(1)
	_check(state.move_cards([person], empty) == empty and state.group_cards(empty) == [person], "one striking person may move to an explicitly empty own group")
	_check(state.move_cards([person], empty, person) == empty and state.is_striking(person), "dropping a lone striking person on itself is a harmless no-op")
	for kind in state.config.cards:
		var other := state.add_card(str(kind), 1)
		var target: int = state.cards[other].group
		var before := JSON.stringify({"cards": state.cards, "groups": state.groups, "tasks": state.tasks, "revision": state.revision})
		_check(state.move_cards([person], target, other) == -1, "striking person cannot join " + str(kind))
		_check(state.move_cards([other], empty, person) == -1, str(kind) + " cannot be stacked onto a striking person")
		_check(state.move_cards([person, other], -1) == -1, "striking person cannot be moved together with " + str(kind))
		_check(JSON.stringify({"cards": state.cards, "groups": state.groups, "tasks": state.tasks, "revision": state.revision}) == before, "rejected " + str(kind) + " combinations preserve membership, status and time atomically")
		if kind == "coffee":
			_check(not state.activate(other, empty, person) and state.cards[other].status == "ready", "direct coffee activation cannot bypass strike grouping immunity")
	_check(state.move_cards(people, -1) == -1, "two striking people cannot form a group on blank space")
	_check(state.move_cards([person], old_work) == -1 and not state.tasks.has(person), "moving a striking person onto original work is rejected without starting production")
	state.advance(3.0)
	_check(is_equal_approx(state.cards[person].remaining, remaining - 3.0), "status time continues naturally through all drag attempts")
	_check(not state.meeting_candidates(0).has(person), "a relocated striking person remains immune to meeting pulls")
	state.advance(remaining - 3.0)
	_check(not state.is_striking(person) and state.group_cards(empty) == [person], "strike ends at the original deadline and leaves the relocated person loose")
	_check(state.move_cards([person], old_work) == old_work and state.tasks.has(person), "after expiry the person can join work normally")

func _dismiss_striking_people() -> void:
	var state := _state({"employee": 1, "grinder": 1, "leader": 1, "work": 100})
	var group := _group(state, 1)
	var people := state.group_people(group)
	var refund := 0
	for person in people: refund += int(state.config.cards[state.cards[person].type].refund)
	state.activate(state.add_card("strike", 0), group)
	state.advance(5.0)
	state.drain_events()
	_check(state.dismiss_people(people, 1), "all three striking personnel types can be dismissed")
	_check(people.all(func(person): return not state.cards.has(person)) and state.money(1) == refund, "dismissal removes actual people and pays their configured unit-card refunds")
	var events := state.drain_events().filter(func(event): return event.kind == "fire")
	_check(events.size() == people.size() and events.all(func(event): return event.money_ids.size() == event.amount), "each dismissed dancer emits one normal event with all refund UIDs")
	_check(not state.dismiss_people(people, 1) and state.money(1) == refund, "dismissed dancers cannot be refunded twice")
	state.advance(20.0)
	_check(state.drain_events().filter(func(event): return event.kind == "strike_end" and people.has(event.person)).is_empty(), "dismissed people never reappear or emit a stale strike expiry")

func _invalid_targets() -> void:
	var state := _state({"leader": 1, "work": 30})
	var source := state.add_card("strike", 0)
	var enemy := _group(state, 1)
	var saved := JSON.stringify(state.cards)
	_check(not state.can_strike_group(enemy, 0) and not state.activate(source, enemy), "leader with ordinary work cannot be struck because it cannot consume work")
	_check(JSON.stringify(state.cards) == saved and state.cards.has(source), "invalid strike leaves source and all target cards unchanged")
	_check(not state.activate(source, _group(state, 0)) and state.cards.has(source), "own combination is never a valid target")
	var idle := state.add_card("employee", 1)
	_check(not state.activate(source, state.cards[idle].group) and state.cards.has(source), "idle employee without work is invalid")
	_check(not state.activate(source, 99999) and state.cards.has(source), "missing group is invalid and preserves the card")

func _other_jobs() -> void:
	var state := _state({"leader": 2, "work": 100})
	var enemy := _group(state, 1)
	var transfer := state.add_card("transfer", 1, enemy)
	state.activate(transfer)
	state.advance(3.0)
	var source := state.add_card("strike", 0)
	_check(state.activate(source, enemy) and state.group_people(enemy).is_empty(), "leaders consuming work through transfer can be struck")
	_check(is_equal_approx(state.group_transfer_progress(enemy), 0.3), "strike preserves accumulated transfer progress")
	var outsource_state := _state({"employee": 1, "work": 30})
	var outsource_group := _group(outsource_state, 1)
	var cash := outsource_state.add_card("money", 1, outsource_group)
	outsource_state.cards[cash].amount = 3
	var outsource := outsource_state.add_card("outsource", 1)
	outsource_state.move_cards([cash], int(outsource_state.cards[outsource].group))
	outsource_group = outsource_state.move_cards(outsource_state.group_cards(outsource_group), int(outsource_state.cards[outsource].group))
	var strike := outsource_state.add_card("strike", 0)
	_check(outsource_state.activate(strike, outsource_group) and outsource_state.outsourcing.has(outsource), "staff present in an active outsourcing group can be ejected without cancelling paid outsourcing")
	var second := outsource_state.add_card("strike", 0)
	_check(not outsource_state.activate(second, outsource_group) and outsource_state.cards.has(second), "outsourcing without personnel is not a strike target")
	var hosted := _state({"employee": 3, "leader": 1, "work": 100})
	var hosted_group := _group(hosted, 1)
	var meeting := hosted.add_card("meeting", 1)
	hosted_group = hosted.move_cards(hosted.group_cards(hosted_group), int(hosted.cards[meeting].group))
	_check(hosted.meetings.has(meeting) and is_zero_approx(hosted.group_work_rate(hosted_group)), "meeting combination leaves its other personnel idle")
	var attack := hosted.add_card("strike", 0)
	_check(not hosted.activate(attack, hosted_group) and hosted.meetings.has(meeting), "meeting-only combination rejects strike without ending its session")
	hosted.move_cards([meeting], -1)
	_check(hosted.activate(attack, hosted_group) and not hosted.meetings.has(meeting), "removing the meeting restores productive work and permits strike")
	_check(hosted.meeting_candidates(1).size() == 3, "meeting guests regain their original ability after host ejection")
	var upgrading := _state({"employee": 2, "work": 100})
	var upgrade_group := _group(upgrading, 1)
	var material := upgrading.add_card("coffee", 1, upgrade_group)
	_check(not upgrading.activate(material, upgrade_group, upgrading.group_people(upgrade_group)[0]), "work takes priority over mixed coffee before a strike")
	var disruption := upgrading.add_card("strike", 0)
	_check(upgrading.activate(disruption, upgrade_group), "mixed work and coffee group is eligible for a strike")
	_check(upgrading.cards.has(material) and upgrading.cards[material].status == "ready" and upgrading.cards.values().filter(func(card): return card.owner == 1 and card.type == "employee" and card.status == "striking").size() == 2, "strike leaves the unconsumed ready coffee in the work group")

func _coffee_separation() -> void:
	var state := _state({"employee": 2, "work": 100})
	var group := _group(state, 0)
	var slack := state.add_card("slack", 0)
	group = state.move_cards(state.group_cards(group), int(state.cards[slack].group))
	state.advance(state.config.number("slack", "seconds"))
	var events := state.drain_events().filter(func(event): return event.kind == "slack_complete" and event.owner == 0)
	_check(events.size() == 1 and events[0].coffee_ids.size() == 2, "slacking combination settles two real coffees in one batch")
	var coffee_group: int = events[0].coffee_group
	for event in events:
		_check(event.coffee_id == event.ids[0] and event.coffee_ids == event.ids and event.coffee_group == coffee_group and coffee_group != group, "coffee batch exposes its separate destination and every real UID")
		for coffee in event.coffee_ids:
			_check(state.cards[coffee].status == "ready" and is_zero_approx(state.cards[coffee].remaining), "each produced coffee is immediately ready with no extra timer")
	_check(state.group_cards(coffee_group).all(func(id): return state.cards[id].type == "coffee"), "coffee destination contains no personnel, work or tools")
	_check(state.group_cards(coffee_group).all(func(id): return state.cards[id].status == "ready"), "fresh coffee remains separate and ready for deliberate use")

func _step_independence() -> void:
	var coarse := _state()
	var fine := _state()
	for state in [coarse, fine]:
		state.activate(state.add_card("strike", 0), _group(state, 1))
	coarse.advance(20.5)
	for _i in 205: fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.work_count(1) == fine.work_count(1), "strike timing is independent of simulation step size")
	_check(coarse.group_people(_group(coarse, 1)).is_empty() and fine.group_people(_group(fine, 1)).is_empty(), "both clocks leave released personnel scattered")
	var complete := _state({"employee": 1, "work": 1})
	complete.advance(10.0)
	_check(complete.winner >= 0 and not complete.can_strike_group(_group(complete, 1), 0), "strike cannot act after the match has ended")
