extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_two_people()
	_fair_tiers()
	_refill_and_fresh_output()
	_cancel_and_dismiss()
	_move_and_merge()
	_meeting_and_strike()
	_step_independence()
	for failure in failures: printerr("FAIL ", failure)
	print("COFFEE_QUEUE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func state(contents := {"employee": 2, "work": 200}) -> WorkState:
	var cfg := WorkConfig.new()
	cfg.rules.initial.groups = [contents]
	cfg.rules.initial.money = 0
	cfg.rules.bot.enabled = false
	var s := WorkState.new(cfg)
	s.new_game(20261101)
	s.drain_events()
	return s

func ids(s: WorkState, kind: String, owner := 0) -> Array:
	return s.cards.keys().filter(func(id): return str(s.cards[id].type) == kind and int(s.cards[id].owner) == owner)

func cups(s: WorkState, count: int, owner := 0) -> Array:
	var group := s.create_group(owner)
	var result: Array = []
	for _index in count: result.append(s.add_card("coffee", owner, group))
	return result

func drinkers(s: WorkState, group: int) -> Array:
	return s.group_people(group).filter(func(id): return s.tasks.has(id) and s.tasks[id].kind == "coffee")

func events(s: WorkState, owner := 0) -> Array:
	return s.drain_events().filter(func(event): return event.kind == "coffee_upgrade" and int(event.owner) == owner)

func _two_people() -> void:
	var s := state()
	var people := ids(s, "employee")
	var group: int = s.cards[people[0]].group
	var material := cups(s, 2)
	s.move_cards(material, group, people[0])
	check(drinkers(s, group) == [people[0]], "two stacked cups begin exactly one employee upgrade")
	s.advance(4.999)
	check(people.all(func(id): return s.cards[id].type == "employee") and material.all(func(id): return s.cards.has(id)), "first bar consumes nothing before completion")
	s.advance(0.001)
	check(s.cards[people[0]].type == "grinder" and s.cards[people[1]].type == "employee", "first completion upgrades only the first employee")
	check(drinkers(s, group) == [people[1]] and is_zero_approx(s.tasks[people[1]].progress), "the second employee immediately starts a fresh bar without another drag")
	check(ids(s, "coffee").size() == 1 and s.tasks[people[1]].coffee_ids.size() == 1, "the remaining cup is reserved for the waiting employee, not the first grinder")
	s.advance(5.0)
	check(people.all(func(id): return s.cards[id].type == "grinder") and ids(s, "coffee").is_empty(), "two employees plus two cups finish as two grinders")
	var completed := events(s)
	check(completed.map(func(event): return event.time) == [5.0, 10.0] and completed.map(func(event): return event.person) == people, "queue completion events preserve separate configured deadlines and stable order")

func _fair_tiers() -> void:
	var s := state({"workaholic": 1, "grinder": 1, "employee": 2, "leader": 1, "work_emperor": 1, "work": 200})
	var people := ids(s, "employee")
	var original_grinder: int = ids(s, "grinder")[0]
	var original_high: int = ids(s, "workaholic")[0]
	var group: int = s.cards[people[0]].group
	s.move_cards(cups(s, 8), group)
	check(drinkers(s, group) == [people[0]], "default queue chooses the lowest tier even if higher tiers precede it in the stack")
	s.advance(5.0)
	check(drinkers(s, group) == [people[1]], "remaining ordinary employee goes before every grinder")
	s.advance(5.0)
	check(drinkers(s, group) == [original_grinder], "equal tiers use stable group order after the ordinary employees finish")
	s.advance(15.0)
	check(s.cards[original_grinder].type == "workaholic" and people.all(func(id): return s.cards[id].type == "workaholic"), "all three available grinders progress one at a time before a higher rank drinks")
	check(s.cards[original_high].type == "workaholic" and ids(s, "coffee").is_empty(), "queue neither skips a level nor spends four cups on a higher rank ahead of lower ranks")
	var completed := events(s)
	check(completed.map(func(event): return event.amount) == [1, 1, 2, 2, 2], "mixed queue consumes each configured stage cost once")

func _refill_and_fresh_output() -> void:
	var s := state()
	var people := ids(s, "employee")
	var group: int = s.cards[people[0]].group
	s.move_cards(cups(s, 1), group, people[0])
	s.advance(5.0)
	check(drinkers(s, group).is_empty() and s.cards[people[1]].type == "employee", "material shortage leaves remaining personnel unchanged")
	s.move_cards(cups(s, 1), group)
	check(drinkers(s, group) == [people[1]], "adding coffee resumes the waiting lower tier automatically")
	s.advance(5.0)
	check(people.all(func(id): return s.cards[id].type == "grinder"), "refilled queue completes without duplicating the first upgrade")
	var fresh := state()
	people = ids(fresh, "employee")
	group = fresh.cards[people[0]].group
	var slack := fresh.add_card("slack", 0, group)
	fresh.activate(slack, group)
	fresh.advance(fresh.config.number("slack", "seconds"))
	var material := ids(fresh, "coffee")
	check(material.size() == 2 and material.all(func(id): return fresh.cards[id].status == "ready" and is_zero_approx(fresh.cards[id].remaining)), "a real production batch supplies two immediately usable coffees")
	fresh.move_cards([slack])
	fresh.move_cards(material, group, people[0])
	check(drinkers(fresh, group) == [people[0]] and is_zero_approx(fresh.tasks[people[0]].progress), "fresh output immediately starts the first full upgrade bar")
	fresh.advance(5.0)
	check(drinkers(fresh, group) == [people[1]] and is_zero_approx(fresh.tasks[people[1]].progress), "second fresh cup immediately continues the next employee's full bar")
	fresh.advance(5.0)
	check(ids(fresh, "coffee").is_empty() and people.all(func(id): return fresh.cards[id].type == "grinder"), "fresh output upgrades both employees without any extra waiting phase")

func _move_and_merge() -> void:
	var s := state()
	var people := ids(s, "employee")
	var group: int = s.cards[people[0]].group
	var material := cups(s, 2)
	s.move_cards(material, group, people[0])
	s.advance(2.0)
	var first_material: Array = s.tasks[people[0]].coffee_ids.duplicate()
	var destination := s.move_cards([people[0]] + first_material)
	check(drinkers(s, destination) == [people[0]] and is_equal_approx(s.tasks[people[0]].progress, 0.4), "moving a complete active batch preserves its progress")
	check(drinkers(s, group) == [people[1]] and is_zero_approx(s.tasks[people[1]].progress), "source queue continues with its remaining employee and coffee")
	s.advance(3.0)
	check(s.cards[people[0]].type == "grinder" and s.cards[people[1]].type == "employee", "independent groups keep independent upgrade clocks")
	s.advance(2.0)
	check(s.cards[people[1]].type == "grinder" and ids(s, "coffee").is_empty(), "both relocated batches consume one unique cup")

	var merged := state()
	people = ids(merged, "employee")
	group = merged.cards[people[0]].group
	var other := merged.move_cards([people[1]])
	var first_cups := cups(merged, 1)
	var second_cups := cups(merged, 1)
	merged.move_cards(first_cups, group, people[0])
	merged.advance(1.0)
	merged.move_cards(second_cups, other, people[1])
	merged.advance(1.0)
	merged.move_cards([people[1]] + second_cups, group)
	check(drinkers(merged, group) == [people[0]] and is_equal_approx(merged.tasks[people[0]].progress, 0.4), "merging active upgrade stacks keeps the destination's current stage")
	check(merged.cards[second_cups[0]].status == "ready", "incoming unfinished stage returns its coffee to the shared queue")
	merged.advance(3.0)
	check(drinkers(merged, group) == [people[1]] and is_zero_approx(merged.tasks[people[1]].progress), "merged queue starts the incoming employee after the existing stage")
	merged.advance(5.0)
	check(people.all(func(id): return merged.cards[id].type == "grinder") and ids(merged, "coffee").is_empty(), "merged queues never duplicate or double-consume materials")

func _cancel_and_dismiss() -> void:
	var s := state()
	var people := ids(s, "employee")
	var group: int = s.cards[people[0]].group
	var material := cups(s, 2)
	s.move_cards(material, group, people[0])
	s.advance(1.0)
	var reserved: int = s.tasks[people[0]].coffee_ids[0]
	s.move_cards([reserved])
	check(s.cards[reserved].status == "ready" and s.cards[reserved].progress == 0.0, "taking away the reserved cup cancels and resets that cup without consuming it")
	check(drinkers(s, group) == [people[0]] and not s.tasks[people[0]].coffee_ids.has(reserved) and is_zero_approx(s.tasks[people[0]].progress), "remaining material can start a fresh stage after cancellation")
	s.advance(5.0)
	check(s.cards[people[0]].type == "grinder" and s.cards[people[1]].type == "employee" and ids(s, "coffee").size() == 1, "cancelled stage cannot cause a second completion or consume remote coffee")
	s.move_cards([reserved], group)
	s.advance(5.0)
	check(people.all(func(id): return s.cards[id].type == "grinder") and ids(s, "coffee").is_empty(), "returning the removed material continues with the remaining employee")
	var dismissed := state()
	people = ids(dismissed, "employee")
	group = dismissed.cards[people[0]].group
	dismissed.move_cards(cups(dismissed, 2), group, people[0])
	dismissed.advance(1.0)
	check(dismissed.dismiss_people([people[0]], 0), "active queue participant can be fired through the existing rules")
	check(drinkers(dismissed, group) == [people[1]] and is_zero_approx(dismissed.tasks[people[1]].progress), "firing the active participant immediately starts the next employee with released coffee")
	dismissed.advance(5.0)
	check(not dismissed.cards.has(people[0]) and dismissed.cards[people[1]].type == "grinder" and ids(dismissed, "coffee").size() == 1, "dismissed participant never completes and only the next employee consumes one cup")

func _meeting_and_strike() -> void:
	var s := state()
	var people := ids(s, "employee", 1)
	var group: int = s.cards[people[0]].group
	var material := cups(s, 2, 1)
	s.move_cards(material, group, people[0])
	s.advance(1.0)
	var leader := s.add_card("leader", 0)
	var meeting := s.add_card("meeting", 0, s.cards[leader].group)
	check(s.activate(meeting, s.cards[leader].group, leader), "meeting starts against queued personnel")
	check(people.all(func(id): return s.is_meeting_target(id)), "both queued employees are pulled into the meeting")
	s.advance(12.0)
	check(drinkers(s, group) == [people[0]] and is_equal_approx(s.tasks[people[0]].progress, 0.2), "meeting freezes the active upgrade and does not start another stage")
	s.advance(9.0)
	check(people.all(func(id): return s.cards[id].type == "grinder") and ids(s, "coffee", 1).is_empty(), "meeting return resumes the first bar and then the waiting employee")

	var struck := state()
	people = ids(struck, "employee", 1)
	group = struck.cards[people[0]].group
	material = cups(struck, 2, 1)
	struck.move_cards(material, group, people[0])
	struck.advance(1.0)
	var attack := struck.add_card("strike", 0)
	check(struck.activate(attack, group), "strike can interrupt the working group containing an upgrade queue")
	check(people.all(func(id): return struck.is_striking(id)) and material.all(func(id): return struck.cards[id].status == "ready"), "strike cancels the active drink and releases all material without consumption")
	struck.advance(20.0)
	check(ids(struck, "coffee", 1).size() == 2, "dispersed striking personnel never consume the abandoned material")
	struck.move_cards(people, group)
	check(drinkers(struck, group) == [people[0]], "recombining recovered personnel restarts the queue")
	struck.advance(10.0)
	check(people.all(func(id): return struck.cards[id].type == "grinder") and ids(struck, "coffee", 1).is_empty(), "recovered queue upgrades both employees exactly once")

func _step_independence() -> void:
	var coarse := state()
	var fine := state()
	for s in [coarse, fine]:
		var people := ids(s, "employee")
		s.move_cards(cups(s, 6), s.cards[people[0]].group, people[0])
	coarse.advance(20.0)
	for _index in 200: fine.advance(0.1)
	check(ids(coarse, "workaholic").size() == 2 and ids(fine, "workaholic").size() == 2, "coarse and fine clocks complete the same four queued stages")
	var completed := events(coarse)
	check(completed.map(func(event): return event.time) == [5.0, 10.0, 15.0, 20.0], "queued deadlines do not depend on frames or new input")
	check(ids(coarse, "coffee").is_empty() and ids(fine, "coffee").is_empty(), "time slicing never changes material consumption")
