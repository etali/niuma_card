extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_config_contract()
	_sequential_chain()
	_insufficient_and_refill()
	_move_and_cancel()
	_queue_and_priority()
	_income_and_personnel()
	_pause_and_interrupt()
	_step_independence()
	for failure in failures: printerr("FAIL ", failure)
	print("EMPLOYEE_TIERS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func state(contents: Dictionary = {"employee": 1, "work": 200}) -> WorkState:
	var cfg := WorkConfig.new()
	cfg.rules.initial.groups = [contents]
	cfg.rules.initial.money = 0
	var s := WorkState.new(cfg)
	s.new_game(73)
	s.drain_events()
	return s

func ids(s: WorkState, kind: String, owner := 0) -> Array:
	return s.cards.keys().filter(func(id): return s.cards[id].type == kind and int(s.cards[id].owner) == owner)

func cups(s: WorkState, count: int, owner := 0) -> Array:
	var result: Array = []
	var group := s.create_group(owner)
	for _i in count: result.append(s.add_card("coffee", owner, group))
	return result

func add_drink(s: WorkState, p: int, count: int) -> Array:
	var result := cups(s, count, int(s.cards[p].owner))
	s.move_cards(result, int(s.cards[p].group), p)
	return result

func _config_contract() -> void:
	var cfg := WorkConfig.new()
	check(cfg.validate() and cfg.roles.size() == 5 and cfg.cards.size() == 14, "five personnel kinds and fourteen cards validate")
	var kinds := ["employee", "grinder", "workaholic", "work_emperor"]
	for i in kinds.size():
		var kind: String = kinds[i]
		check(cfg.is_person(kind) and cfg.can_work(kind) and cfg.can_be_meeting_target(kind), kind + " is a working, meeting-eligible person")
		check(is_equal_approx(cfg.work_rate(kind, 0), 0.1) and int(cfg.roles[kind].work_income_multiplier) == int(pow(2, i)), kind + " changes income without changing work speed")
		if i > 0:
			check(not cfg.can_purchase(kind) and not cfg.rules.conveyor.pool.has(kind) and not cfg.rules.conveyor.opening.has(kind), kind + " cannot be bought")
		if i < 3:
			check(cfg.coffee_upgrade(kind).to == kinds[i + 1] and cfg.coffee_upgrade(kind).cost == int(pow(2, i)) and cfg.coffee_seconds(kind) == 5.0, kind + " upgrades exactly one tier with configured cost and time")
	check(cfg.coffee_upgrade("leader").is_empty() and cfg.coffee_upgrade("work_emperor").is_empty(), "leader and maximum tier do not consume coffee")
	for invalid in ["employee", "leader", "unknown", "work_emperor"]:
		var bad := WorkConfig.new()
		bad.rules.coffee.upgrades.employee.to = invalid
		check(not bad.validate(), "invalid next tier including cycles/skips is rejected: " + invalid)
	for invalid_cost in [0.0, -1.0, 1.5]:
		var bad := WorkConfig.new()
		bad.rules.coffee.upgrades.grinder.cost = invalid_cost
		check(not bad.validate(), "nonpositive or fractional coffee cost rejected")
	var missing := WorkConfig.new()
	missing.rules.coffee.upgrades.erase("grinder")
	check(not missing.validate(), "missing intermediate upgrade rejected")
	var extra := WorkConfig.new()
	extra.rules.coffee.upgrades.work_emperor = {"to": "employee", "cost": 1}
	check(not extra.validate(), "unexpected upgrade beyond maximum rejected")
	for kind in ["grinder", "workaholic", "work_emperor"]:
		var bad := WorkConfig.new()
		bad.cards[kind].purchasable = true
		check(not bad.validate() and not bad.can_purchase(kind), "purchase flag cannot bypass upgrade-only " + kind)
	var tuned := WorkConfig.new()
	tuned.rules.coffee.upgrades.grinder.seconds = 3.0
	check(tuned.validate() and tuned.coffee_seconds("grinder") == 3.0 and tuned.coffee_seconds("employee") == 5.0, "per-stage seconds override common duration")

func _sequential_chain() -> void:
	var s := state()
	var p: int = ids(s, "employee")[0]
	var material := add_drink(s, p, 8)
	check(s.tasks[p].coffee_ids.size() == 1 and s.tasks[p].from_type == "employee" and s.tasks[p].to_type == "grinder", "eight cups still begin only first tier")
	s.advance(4.99)
	check(s.cards[p].type == "employee" and material.all(func(id): return s.cards.has(id)), "all cups survive before first bar completes")
	s.advance(0.01)
	check(s.cards[p].type == "grinder" and ids(s, "coffee").size() == 7, "first bar consumes exactly one and preserves person UID")
	check(s.tasks[p].from_type == "grinder" and s.tasks[p].to_type == "workaholic" and s.tasks[p].coffee_ids.size() == 2 and is_zero_approx(s.tasks[p].progress), "second stage automatically begins at zero with two cups")
	s.advance(2.5)
	for id in s.tasks[p].coffee_ids:
		check(is_equal_approx(s.cards[id].progress, 0.5) and is_equal_approx(s.cards[id].remaining, 2.5), "all reserved stage-two cups share one timer")
	s.advance(2.5)
	check(s.cards[p].type == "workaholic" and ids(s, "coffee").size() == 5, "second bar consumes two, not the four reserved for later")
	check(s.tasks[p].coffee_ids.size() == 4 and is_zero_approx(s.tasks[p].progress), "third stage begins a separate four-cup bar")
	s.advance(4.999)
	check(s.cards[p].type == "workaholic" and ids(s, "coffee").size() == 5, "no skipped final progress")
	s.advance(0.001)
	check(s.cards[p].type == "work_emperor" and ids(s, "coffee").size() == 1, "fifteen seconds consumes seven cups total and leaves surplus")
	var events := s.drain_events().filter(func(e): return e.kind == "coffee_upgrade")
	check(events.size() == 3 and events.map(func(e): return e.amount) == [1, 2, 4], "three completion events retain each exact material batch")
	check(events.all(func(e): return e.person == p) and s.people_count(0) == 1, "upgrading never creates another personnel card")
	var spare: int = ids(s, "coffee")[0]
	check(not s.activate(spare, s.cards[p].group, p) and s.cards[spare].status == "ready", "maximum-tier person cannot drink spare coffee")
	s.advance(10.0)
	check(s.work_count(0) == 199 and s.money(0) == 8 and s.cards.has(spare), "maximum tier handles one work and earns eight without consuming spare coffee")

func _insufficient_and_refill() -> void:
	for spec in [{"kind": "grinder", "cost": 2}, {"kind": "workaholic", "cost": 4}]:
		var s := state({spec.kind: 1, "work": 200})
		var p: int = ids(s, spec.kind)[0]
		var material := add_drink(s, p, spec.cost - 1)
		check(s.tasks[p].kind == "work" and material.all(func(id): return s.cards[id].status == "ready"), "insufficient " + spec.kind + " materials neither pause work nor reserve cups")
		var last := cups(s, 1)
		s.move_cards(last, s.cards[p].group, p)
		check(s.cards[last[0]].status == "active" and s.tasks[p].kind == "coffee", "the final cup immediately wakes the existing same-group upgrade queue")
		check(s.tasks[p].coffee_ids.size() == spec.cost and is_zero_approx(s.tasks[p].progress), "full ready material set begins an exact fresh stage")
		s.advance(5.0)
		check(s.cards[p].type == s.config.coffee_upgrade(spec.kind).to and ids(s, "coffee").is_empty(), "complete material set consumed at completion")

func _move_and_cancel() -> void:
	var s := state({"workaholic": 1, "work": 200})
	var p: int = ids(s, "workaholic")[0]
	var material := add_drink(s, p, 4)
	s.advance(2.0)
	var batch := material.duplicate()
	batch.append(p)
	var moved := s.move_cards(batch, -1)
	check(s.tasks[p].group == moved and is_equal_approx(s.tasks[p].progress, 0.4), "moving person and all four cups preserves stage progress")
	check(s.tasks[p].work_id == -1, "moving full drink batch frees work in original group")
	s.move_cards([material[2]], -1)
	check(not s.tasks.has(p) and s.cards[p].type == "workaholic", "removing a secondary cup cancels entire upgrade")
	check(material.all(func(id): return s.cards.has(id) and s.cards[id].status == "ready" and s.cards[id].progress == 0.0), "cancel returns all four cups without consumption")
	s.move_cards([material[2]], moved, p)
	check(s.tasks[p].coffee_ids.size() == 4 and is_zero_approx(s.tasks[p].progress), "rebuilding material batch restarts fresh")
	s.advance(1.0)
	var before := s.money(0)
	check(s.dismiss_people([p], 0) and s.money(0) == before + 4, "dismiss during four-cup upgrade uses current role refund")
	check(material.all(func(id): return s.cards.has(id) and s.cards[id].status == "ready"), "dismiss returns every reserved cup")
	s.advance(10.0)
	check(not s.cards.has(p) and material.all(func(id): return s.cards.has(id)), "cancelled upgrade never consumes cups later or resurrects person")

func _queue_and_priority() -> void:
	var s := state({"employee": 3, "work": 200})
	var staff := s.group_people(s.cards[ids(s, "employee")[0]].group)
	var material := cups(s, 3)
	s.move_cards(material, s.cards[staff[0]].group, staff[0])
	for index in staff.size():
		check(staff.filter(func(id): return s.tasks.has(id) and s.tasks[id].kind == "coffee") == [staff[index]], "one active coffee task advances through stable personnel order")
		check(s.tasks[staff[index]].coffee_ids.size() == 1, "queued employee reserves only its own one-cup stage")
		s.advance(5.0)
		check(s.cards[staff[index]].type == "grinder" and ids(s, "coffee").size() == staff.size() - index - 1, "queued employee consumes exactly one cup at its own deadline")
	check(staff.all(func(id): return s.cards[id].type == "grinder"), "three employees and three cups complete three successive grinder upgrades")
	var targeted := state({"employee": 2, "workaholic": 1, "work": 200})
	var high: int = ids(targeted, "workaholic")[0]
	add_drink(targeted, high, 6)
	check(targeted.tasks[high].kind == "coffee" and targeted.tasks[high].coffee_ids.size() == 4, "explicit high-tier target reserves four for the first queue position")
	check(ids(targeted, "employee").all(func(id): return targeted.tasks[id].kind == "work"), "other personnel keep working while specified person drinks")
	targeted.advance(5.0)
	var waiting := ids(targeted, "employee")
	check(targeted.cards[high].type == "work_emperor" and targeted.tasks[waiting[0]].kind == "coffee", "finishing the explicit target continues with the lowest remaining tier")
	targeted.advance(10.0)
	check(waiting.all(func(id): return targeted.cards[id].type == "grinder") and ids(targeted, "coffee").is_empty(), "maximum-tier first target never blocks coworkers behind it")

func _income_and_personnel() -> void:
	var s := state({"employee": 1, "grinder": 1, "workaholic": 1, "work_emperor": 1, "leader": 1, "work": 200})
	var group: int = s.cards[ids(s, "employee")[0]].group
	check(s.people_count(0) == 5 and s.group_work_participants(group).size() == 4, "all four ranks count one worker each and leader cannot work")
	s.advance(10.0)
	check(s.work_count(0) == 196 and s.money(0) == 15, "one shared ten-second settlement produces four work and 1+2+4+8 cash")
	var event := s.drain_events().filter(func(e): return e.kind == "work_complete" and e.owner == 0)
	check(event.size() == 1 and event[0].participants.size() == 4 and event[0].amount == 15, "mixed tiers preserve shared group settlement event")
	var slack := s.add_card("slack", 0)
	s.move_cards([slack], group)
	s.advance(14.0)
	check(ids(s, "coffee").size() == 5, "higher tiers still produce one coffee per person, not income-multiplied coffee")
	for kind in ["workaholic", "work_emperor"]:
		var transfer := state({kind: 1, "work": 200})
		var p: int = ids(transfer, kind)[0]
		var tool := transfer.add_card("transfer", 0)
		transfer.move_cards([tool], transfer.cards[p].group)
		transfer.advance(10.0)
		check(transfer.work_count(0) == 199 and transfer.work_count(1) == 200 and transfer.money(0) == 0, kind + " transfers one work without earning money")
		var fire := state({kind: 1, "work": 200})
		check(fire.dismiss_people(ids(fire, kind), 0) and fire.money(0) == 4, kind + " can be fired for configured current refund")

func _pause_and_interrupt() -> void:
	var s := state({"workaholic": 1, "work_emperor": 1, "work": 200})
	var p: int = ids(s, "workaholic", 1)[0]
	var material := add_drink(s, p, 4)
	s.advance(1.0)
	var leader := s.add_card("leader", 0)
	var meeting := s.add_card("meeting", 0, s.cards[leader].group)
	check(s.activate(meeting, s.cards[leader].group, leader), "leader starts meeting including new personnel tiers")
	check(s.is_meeting_target(p) and material.all(func(id): return s.cards[id].paused), "meeting pauses person and every reserved coffee")
	s.advance(12.0)
	check(s.cards[p].type == "workaholic" and is_equal_approx(s.tasks[p].progress, 0.2), "meeting preserves exact partial upgrade")
	s.advance(4.0)
	check(s.cards[p].type == "work_emperor" and material.all(func(id): return not s.cards.has(id)), "after meeting all four cups settle together")
	var strike := state({"workaholic": 1, "work_emperor": 1, "work": 200})
	var sp: int = ids(strike, "workaholic", 1)[0]
	var coffee := add_drink(strike, sp, 4)
	strike.advance(1.0)
	var tool := strike.add_card("strike", 0)
	check(strike.activate(tool, strike.cards[sp].group), "active mixed-tier work group accepts strike")
	check(strike.is_striking(sp) and not strike.tasks.has(sp) and coffee.all(func(id): return strike.cards[id].status == "ready"), "strike ejects upgrading person and returns every cup")
	check(strike.dismiss_people([sp], 1), "striking high-tier person may still be dismissed")

func _step_independence() -> void:
	var coarse := state()
	var fine := state()
	var p: int = ids(coarse, "employee")[0]
	var q: int = ids(fine, "employee")[0]
	for s in [coarse, fine]:
		s.config.rules.coffee.upgrades.employee.seconds = 2.0
		s.config.rules.coffee.upgrades.grinder.seconds = 3.0
		s.config.rules.coffee.upgrades.workaholic.seconds = 4.0
	add_drink(coarse, p, 7)
	add_drink(fine, q, 7)
	coarse.advance(19.0)
	for _i in 190: fine.advance(0.1)
	check(coarse.cards[p].type == "work_emperor" and fine.cards[q].type == "work_emperor", "configured two/three/four-second stages finish in both time-step modes")
	check(coarse.work_count(0) == 199 and fine.work_count(0) == 199 and coarse.money(0) == 8 and fine.money(0) == 8, "coarse and fine clocks agree across chain and first eight-cash settlement")
	check(coarse.drain_events().filter(func(e): return e.kind == "coffee_upgrade").map(func(e): return e.time) == [2.0, 5.0, 9.0], "stage deadlines follow per-stage config without skipped intermediate tier")
