extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_configuration()
	_protection_and_production()
	_overtime_boundaries()
	_flight_defence()
	_flight_hit_and_fork()
	_terminal_cancels_flight()
	_coffee_priority_and_absence()
	for failure in failures: printerr("FAIL ", failure)
	print("OFF_WORK_UNION_RULES %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 100}, {"employee": 1}]
	config.rules.initial.money = 0
	var s := OffWorkState.new(config)
	s.new_game(74)
	s.drain_events()
	return s

func ids(s: OffWorkState, kind: String, owner := 0) -> Array:
	return s.cards.keys().filter(func(id): return s.cards[id].type == kind and s.cards[id].owner == owner)

func work_group(s: OffWorkState, owner := 0) -> int:
	return int(s.cards[ids(s, "work", owner)[0]].group)

func working_person(s: OffWorkState, owner := 0) -> int:
	var person := int(ids(s, "employee", owner)[0])
	s.move_cards([person], work_group(s, owner))
	return person

func _configuration() -> void:
	var config := OffWorkConfig.new()
	check(config.validate() and config.cards.has("union") and config.can_purchase("union"), "new union is a configurable purchasable tool")
	var old := config.balance_document()
	old.cards.erase("union")
	old.cards.erase("boss")
	old.roles.erase("boss")
	old.rules.erase("recruitment")
	old.rules.conveyor.pool.erase("boss")
	old.rules.erase("union")
	old.rules.conveyor.pool.erase("union")
	old.rules.strike.erase("flight_seconds")
	var archived := OffWorkConfig.new(old)
	check(archived.validate() and archived.balance_document() == old, "archived card pools retain exact contents without adding union or attack delay")
	config.rules.strike.flight_seconds = -0.1
	check(not config.validate(), "negative attack flight time is rejected")

func _protection_and_production() -> void:
	var s := state()
	var person := working_person(s)
	var group := work_group(s)
	s.cards[person].type = "work_emperor"
	s.config.roles.work_emperor.work_seconds = 2.0
	s.config.roles.work_emperor.work_capacity = 3
	var protection := s.add_card("union", 0)
	s.move_cards([protection], group)
	check(s.cards[person].type == "work_emperor" and s.effective_work_kind("work_emperor", group) == "employee", "union lowers effective role without transforming card")
	check(s.tasks[person].work_ids.size() == 1 and is_equal_approx(s.group_work_rate(group), 0.1), "union uses employee batch size and speed")
	s.advance(10.0)
	check(s.work_count(0) == 99 and s.money(0) == 1, "union work pays employee income instead of high-tier income")
	var attack := s.add_card("strike", 1)
	check(not s.can_strike_group(group, 1) and not s.activate(attack, group) and s.cards.has(attack) and s.pending_strikes.is_empty(), "pre-existing protection rejects strike without consuming or launching it")
	s.move_cards([protection])
	check(s.tasks[person].work_ids.size() == 3 and is_equal_approx(s.group_work_rate(group), 0.5), "removing union restores original effective capacity")
	s.advance(2.0)
	check(s.work_count(0) == 96 and s.money(0) == 25, "restored emperor earns original income")
	var leader := s.add_card("leader", 0, group)
	s.move_cards([protection], group)
	s.advance(0.01)
	check(not s.can_person_work(leader) and not s.tasks.has(leader), "union preserves non-worker eligibility")
	check(s.effective_work_kind("leader", group) == "leader" and s.effective_work_kind("boss", group) == "boss", "shared effective role preserves both non-worker roles for BOT and previews")

func _overtime_boundaries() -> void:
	var s := state()
	working_person(s)
	var group := work_group(s)
	var first := s.add_card("overtime", 0, group)
	var second := s.add_card("overtime", 0, group)
	var protection := s.add_card("union", 0)
	s.move_cards([protection], group)
	check(s.group_has_union(group) and s.cards[first].group != group and s.cards[second].group != group, "union entering a stack ejects every overtime card")
	check(s.cards[first].group != s.cards[second].group and s.group_cards(s.cards[first].group) == [first], "ejected overtime cards occupy independent loose stacks")
	var from := int(s.cards[first].group)
	check(s.move_cards([first], group) == -1 and s.cards[first].group == from, "overtime cannot enter a protected stack")
	var person := s.add_card("employee", 0, from)
	check(s.move_cards([person, first], group) == -1 and s.cards[person].group == from, "mixed overtime drag is rejected atomically")
	check(s.move_cards([protection], from) == from and s.cards[first].group != from, "moving union onto an overtime stack ejects its existing overtime")

func _flight_defence() -> void:
	var s := state()
	var person := working_person(s, 1)
	var group := work_group(s, 1)
	var attack := s.add_card("strike", 0)
	var origin := int(s.cards[attack].group)
	check(s.activate(attack, group) and s.pending_strikes.has(attack) and not s.is_striking(person), "strike launch creates a real reaction window")
	check(s.cards[attack].status == "in_flight" and not s.activate(attack, group) and s.move_cards([attack]) == -1, "an in-flight card cannot launch twice or move")
	s.advance(0.6)
	var protection := s.add_card("union", 1)
	s.move_cards([protection], group)
	s.advance(0.6)
	check(s.pending_strikes.is_empty() and s.cards.has(attack) and s.cards[attack].status == "ready" and s.cards[attack].group == origin, "union placed during flight returns same attack card to origin")
	check(not s.is_striking(person) and s.cards[person].group == group, "mid-flight protection prevents the entire strike effect")
	var blocked := s.drain_events().filter(func(event): return event.kind == "strike_blocked")
	check(blocked.size() == 1 and blocked[0].reason == "union" and blocked[0].source == attack, "blocked event identifies the visual source and cause")
	check(not s.activate(attack, group), "returned attack cannot immediately strike the still-protected group")

func _flight_hit_and_fork() -> void:
	var s := state()
	var person := working_person(s, 1)
	var group := work_group(s, 1)
	var attack := s.add_card("strike", 0)
	s.activate(attack, group)
	s.advance(0.4)
	var fork := s.fork_for_bot(8)
	check(fork.pending_strikes == s.pending_strikes, "BOT fork carries the same pending attack and deadline")
	fork.advance(0.8)
	check(fork.is_striking(person) and s.pending_strikes.has(attack) and not s.is_striking(person), "search settlement remains isolated from live attack")
	s.advance(0.799)
	check(s.cards.has(attack) and not s.is_striking(person), "attack cannot land early")
	s.advance(0.001)
	check(not s.cards.has(attack) and s.is_striking(person) and s.pending_strikes.is_empty(), "unprotected attack consumes the card only at arrival")
	check(is_equal_approx(s.cards[person].remaining, s.config.number("strike", "duration_seconds")), "strike duration begins at arrival")
	var misses := state()
	var target := working_person(misses, 1)
	var missile := misses.add_card("strike", 0)
	misses.activate(missile, work_group(misses, 1))
	misses.move_cards([target])
	misses.advance(1.2)
	check(misses.cards.has(missile) and not misses.is_striking(target), "empty target returns an attack instead of retargeting another stack")

func _coffee_priority_and_absence() -> void:
	var s := state()
	var employee := int(ids(s, "employee", 1)[0])
	var group := int(s.cards[employee].group)
	var high := s.add_card("workaholic", 1, group)
	var mid := s.add_card("grinder", 1, group)
	var cups: Array = []
	for i in 3: cups.append(s.add_card("coffee", 1))
	s.move_cards(cups, group, employee)
	check(s.tasks.has(mid) and s.tasks[mid].kind == "coffee" and not s.tasks.has(employee) and not s.tasks.has(high), "highest affordable tier wins even when the drop points to a lower-tier employee")
	s.advance(5.0)
	check(s.cards[mid].type == "workaholic" and s.tasks[employee].kind == "coffee", "unaffordable higher stages yield to a lower affordable employee")
	s.advance(1.0)
	var host := s.add_card("leader", 0)
	var meeting := s.add_card("meeting", 0, s.cards[host].group)
	s.activate(meeting)
	check(not s.tasks.has(employee) and s.cards[cups[2]].status == "ready" and is_zero_approx(s.cards[cups[2]].progress), "last attending drinker releases coffee and clears its progress immediately")
	s.advance(s.config.number("meeting", "duration_seconds"))
	check(s.tasks[employee].kind == "coffee" and is_zero_approx(s.tasks[employee].progress), "returning personnel start a new full upgrade clock")

func _terminal_cancels_flight() -> void:
	var s := state()
	working_person(s)
	var target := working_person(s, 1)
	var own := work_group(s)
	var works := ids(s, "work")
	for work in works.slice(1): s._consume(int(work))
	s.groups[own].work_progress = 0.95
	var attack := s.add_card("strike", 0)
	s.activate(attack, work_group(s, 1))
	s.advance(1.2)
	check(s.winner == 0 and s.pending_strikes.is_empty() and s.cards[attack].status == "ready", "victory during flight returns the pending card and clears its timer")
	check(not s.is_striking(target), "no attack applies after the work-clearing victory")
	var blocked := s.drain_events().filter(func(event): return event.kind == "strike_blocked")
	check(blocked.size() == 1 and blocked[0].reason == "match_finished", "terminal cancellation publishes an explicit return reason")
	var surrender := state()
	working_person(surrender, 1)
	attack = surrender.add_card("strike", 0)
	surrender.activate(attack, work_group(surrender, 1))
	surrender.resign(0)
	check(surrender.pending_strikes.is_empty() and surrender.cards[attack].status == "ready", "resignation also cancels a pending strike")
