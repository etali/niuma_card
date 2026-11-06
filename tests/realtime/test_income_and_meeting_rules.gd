extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_income_frequency()
	_income_configuration()
	_legacy_card_values()
	_upgrade_income()
	_transfer_never_pays()
	_leader_immunity()
	_meeting_cycles()
	_meeting_waits_for_conditions()
	_config_validation()
	for failure in failures: printerr("FAIL ", failure)
	print("INCOME_AND_MEETING_RULES ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _state(contents: Dictionary, seed_value := 19) -> WorkState:
	var config := WorkConfig.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	var state := WorkState.new(config)
	state.new_game(seed_value)
	state.drain_events()
	return state

func _ids(state: WorkState, kind: String, owner := 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == kind and int(state.cards[id].owner) == owner)

func _person(state: WorkState, kind: String, owner := 0) -> int:
	return int(_ids(state, kind, owner)[0])

func _group(state: WorkState, owner := 0) -> int:
	return int(state.cards[_ids(state, "work", owner)[0]].group)

func _income_events(state: WorkState) -> Array:
	return state.drain_events().filter(func(event): return event.kind == "work_complete" and event.owner == 0)

func _check_income(state: WorkState, events: Array, amount: int) -> void:
	var seen: Dictionary = {}
	for event in events:
		_check(event.amount == amount and state.cards.has(event.money_id), "paid completion points to a real cash card with correct amount")
		_check(event.money_ids.all(func(id): return not seen.has(id)), "each completion creates distinct cash UIDs")
		for id in event.money_ids: seen[id] = true
		_check(event.money_ids.size() == amount and event.money_ids.all(func(id): return state.cards[id].amount == 1 and state.cards[id].group == event.money_group), "event amount and destination equal the authoritative unit cash records")
		_check(event.money_group != event.group and state.group_cards(event.money_group).all(func(id): return state.cards[id].type == "money"), "income stays outside production in a pure cash pile")

func _income_frequency() -> void:
	for overtime_count in [0, 1, 2, 3]:
		var employee := _state({"employee": 1, "work": 100})
		var grinder := _state({"grinder": 1, "work": 100})
		for state in [employee, grinder]:
			for i in range(overtime_count): state.add_card("overtime", 0, _group(state))
			state.advance(23.75)
		var ordinary := _income_events(employee)
		var doubled := _income_events(grinder)
		_check(ordinary.size() == doubled.size() and employee.work_count(0) == grinder.work_count(0), "equal combinations produce at identical frequency, overtime=%d" % overtime_count)
		_check(is_equal_approx(employee.cards[_person(employee, "employee")].progress, grinder.cards[_person(grinder, "grinder")].progress), "next task progress also matches employee")
		_check(grinder.money(0) == employee.money(0) * 2, "grinder doubles actual cash without processing extra work")
		_check_income(grinder, doubled, 2)

func _income_configuration() -> void:
	for kind in ["employee", "grinder"]:
		var state := _state({kind: 1, "work": 100})
		state.advance(10.0)
		var expected := 1 if kind == "employee" else 2
		_check(state.money(0) == expected, "role income multiplier applies to the base work payment")
		_check_income(state, _income_events(state), expected)
	var configured := _state({"grinder": 1, "work": 100})
	configured.config.cards.work.income = 3
	configured.config.roles.grinder.work_income_multiplier = 4
	configured.advance(10.0)
	_check(configured.money(0) == 12 and configured.work_count(0) == 99, "base money and role multiplier are both read from configuration")

func _legacy_card_values() -> void:
	var legacy := WorkConfig.new().balance_document()
	legacy.cards.work.erase("income")
	legacy.rules.simulation.work_income = 3
	legacy.rules.initial.groups = [{"employee": 1, "work": 20}]
	legacy.rules.initial.money = 0
	for kind in legacy.roles:
		legacy.roles[kind].refund = legacy.cards[kind].refund
		legacy.cards[kind].erase("refund")
	legacy.roles.employee.refund = 1
	var source_snapshot := JSON.stringify(legacy)
	var migrated := WorkConfig.new(legacy)
	_check(migrated.errors.is_empty(), "legacy card values are migrated before validation")
	_check(JSON.stringify(legacy) == source_snapshot, "loading preserves the caller's saved request snapshot")
	var exported := migrated.balance_document()
	_check(exported.cards.work.income == 3 and exported.cards.employee.refund == 1, "canonical export stores values on their cards")
	_check(not exported.rules.simulation.has("work_income") and exported.roles.values().all(func(role): return not role.has("refund")), "canonical export removes old global and role fields")
	_check(not exported.rules.has("bot"), "card export keeps opponent policy in the BOT document")
	exported.cards.work.income = 8
	_check(migrated.cards.work.income == 3, "export cannot mutate the loaded card configuration")
	var state := WorkState.new(migrated)
	state.new_game(71)
	state.advance(10.0)
	_check(state.money(0) == 3 and state.work_count(0) == 19, "migrated income is paid by real work completion")
	_check(state.dismiss_people([_person(state, "employee")], 0) and state.money(0) == 4, "migrated card refund is paid by real dismissal")
	WorkCardDB.configure(migrated)
	_check(WorkCardDB.get_def("employee").output_n == 3 and WorkCardDB.pawn_value("employee") == 1, "card presentation uses migrated income and refund")
	legacy.cards.work.income = 5
	legacy.cards.employee.refund = 3
	var preferred := WorkConfig.new(legacy)
	_check(preferred.errors.is_empty() and preferred.cards.work.income == 5 and preferred.cards.employee.refund == 3, "new card fields override conflicting legacy fields")
	legacy.cards.work.income = {}
	_check(not WorkConfig.new(legacy).errors.is_empty(), "invalid new value is rejected even if legacy value is valid")

func _upgrade_income() -> void:
	var state := _state({"employee": 1, "work": 100})
	var person := _person(state, "employee")
	var group := _group(state)
	state.advance(4.0)
	var work: int = state.tasks[person].work_id
	var coffee := state.add_card("coffee", 0, group)
	_check(state.activate(coffee, group, person), "actual coffee upgrade begins")
	state.advance(5.0)
	_check(state.cards[person].type == "grinder" and is_equal_approx(state.cards[work].progress, 0.4), "upgrade keeps old work progress and same personnel UID")
	state.advance(5.9)
	_check(state.money(0) == 0 and state.cards.has(work), "new grinder cannot finish earlier than employee at same progress")
	state.advance(0.1)
	_check(state.money(0) == 2 and not state.cards.has(work), "upgraded employee first finishes at unchanged deadline and earns two")

func _transfer_never_pays() -> void:
	for kind in ["employee", "grinder", "leader"]:
		var state := _state({kind: 1, "work": 100})
		var person := _person(state, kind)
		var group := _group(state)
		var tool := state.add_card("transfer", 0, group)
		state.move_cards([_person(state, kind, 1)], -1)
		var original_work: Array = state.group_work(group)
		_check(state.activate(tool), "all personnel roles can transfer work")
		state.drain_events()
		state.advance(state.config.number("transfer", "seconds"))
		var events := state.drain_events()
		var transfers := events.filter(func(event): return event.kind == "transfer" and event.owner == 0)
		_check(state.money(0) == 0 and _ids(state, "money").is_empty(), "transfer never creates real cash, role=" + kind)
		_check(events.filter(func(event): return event.kind == "work_complete" and event.owner == 0).is_empty(), "transfer emits no paid-work event")
		_check(transfers.size() == 1 and original_work.has(transfers[0].ids[0]), "transfer event contains exactly the original work UID")
		var moved: int = transfers[0].ids[0]
		var capacity: int = int(state.config.roles[kind].transfer_capacity)
		_check(transfers[0].ids.size() == capacity and state.cards.has(moved) and state.cards[moved].owner == 1 and state.work_count(0) == 100 - capacity and state.work_count(1) == 100 + capacity, "work is preserved and each role contributes its own transfer capacity")

func _leader_immunity() -> void:
	for seed_value in range(1, 9):
		var state := _state({"employee": 2, "grinder": 2, "leader": 6, "work": 200}, seed_value)
		var host := _person(state, "leader")
		var tool := state.add_card("meeting", 0, _group(state))
		_check(state.activate(tool, _group(state), host), "leader may host while being immune to enemy meetings")
		var targets: Array = state.meetings[tool].targets
		_check(targets.size() == 4 and targets.all(func(id): return state.cards[id].type in ["employee", "grinder"]), "four-capacity meeting takes only employees and grinders, never leaders")
		_check(_ids(state, "leader", 1).all(func(id): return not state.cards[id].paused), "all enemy leaders remain unpaused")
	var only := _state({"leader": 3, "work": 100})
	var host := only.add_card("employee", 0, _group(only))
	var tool := only.add_card("meeting", 0, _group(only))
	only.advance(2.0)
	only.drain_events()
	var before := JSON.stringify({"cards": only.cards, "groups": only.groups, "tasks": only.tasks, "meetings": only.meetings, "revision": only.revision})
	_check(not only.activate(tool, _group(only), host), "all-leader opponents reject meeting")
	_check(before == JSON.stringify({"cards": only.cards, "groups": only.groups, "tasks": only.tasks, "meetings": only.meetings, "revision": only.revision}) and only.drain_events().is_empty(), "rejected meeting preserves host work, tool timer and events atomically")
	var one := only.add_card("grinder", 1)
	_check(only.activate(tool, _group(only), host) and only.meetings[tool].targets == [one], "single eligible grinder is drawn alone despite many immune leaders")

func _cycle_state() -> WorkState:
	var state := _state({"employee": 2, "work": 200})
	var tool := state.add_card("meeting", 0, _group(state))
	_check(state.activate(tool), "repeating meeting starts")
	return state

func _meeting_cycles() -> void:
	var state := _cycle_state()
	var tool: int = _ids(state, "meeting")[0]
	state.advance(12.0)
	_check(state.cards[tool].status == "recovering" and state.meetings.is_empty(), "meeting dissolves at exact full session bar")
	state.advance(23.9)
	_check(state.cards[tool].status == "recovering" and state.meetings.is_empty(), "meeting cannot restart before cooldown empty")
	state.advance(0.1)
	_check(state.cards[tool].status == "active" and state.meetings.has(tool) and is_zero_approx(state.cards[tool].progress), "same tool automatically restarts at exact cooldown end")
	var coarse := _cycle_state()
	var fine := _cycle_state()
	coarse.advance(123.5)
	for i in range(1235): fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.work_count(1) == fine.work_count(1) and coarse.money(0) == fine.money(0) and coarse.money(1) == fine.money(1), "repeated meetings remain deterministic across large and small clock steps")
	var cm: int = _ids(coarse, "meeting")[0]
	var fm: int = _ids(fine, "meeting")[0]
	_check(coarse.cards[cm].status == fine.cards[fm].status and is_equal_approx(coarse.cards[cm].progress, fine.cards[fm].progress), "repeated timer phase and progress agree across frame sizes")
	var ce := coarse.drain_events().filter(func(event): return event.kind == "meeting_start")
	var fe := fine.drain_events().filter(func(event): return event.kind == "meeting_start")
	_check(ce.size() == 4 and ce.map(func(event): return event.targets) == fe.map(func(event): return event.targets), "repeated target random draws and session counts agree")

func _meeting_waits_for_conditions() -> void:
	var state := _cycle_state()
	var tool: int = _ids(state, "meeting")[0]
	state.advance(12.0)
	state.dismiss_people(_ids(state, "employee", 1), 1)
	state.add_card("leader", 1)
	state.advance(24.0)
	_check(state.cards[tool].status == "ready" and state.meetings.is_empty(), "cooldown without eligible targets finishes ready instead of consuming another cycle")
	var error_before := state.last_error
	state.advance(1.0)
	_check(state.last_error == error_before, "automatic waiting does not report a failed player command")
	var target := state.add_card("employee", 1)
	state.advance(0.25)
	_check(state.meetings.has(tool) and state.meetings[tool].targets == [target], "new eligible opponent automatically resumes the retained meeting combo")
	var no_host := _cycle_state()
	var nh_tool: int = _ids(no_host, "meeting")[0]
	for person in _ids(no_host, "employee"): no_host.move_cards([person], -1)
	no_host.advance(24.0)
	_check(no_host.cards[nh_tool].status == "ready" and no_host.meetings.is_empty(), "split combo finishes cooldown but cannot summon a host")
	var host: int = _ids(no_host, "employee")[0]
	no_host.move_cards([host], no_host.cards[nh_tool].group)
	_check(no_host.meetings.has(nh_tool), "putting a host back resumes the ready combination")
	var manual := _cycle_state()
	manual.config.rules.meeting.auto_repeat = false
	manual.advance(36.0)
	_check(manual.meetings.is_empty() and manual.cards[_ids(manual, "meeting")[0]].status == "ready", "automatic repeat is a real configurable rule")

func _config_validation() -> void:
	for field in ["work_income_multiplier", "can_be_meeting_target"]:
		var missing := WorkConfig.new()
		missing.roles.grinder.erase(field)
		_check(not missing.validate(), "missing role capability rejects configuration: " + field)
	for value in [0, -1, 1.5, "two"]:
		var invalid := WorkConfig.new()
		invalid.roles.grinder.work_income_multiplier = value
		_check(not invalid.validate(), "money multiplier requires a positive integer")
	var invalid := WorkConfig.new()
	invalid.roles.leader.can_be_meeting_target = 0
	_check(not invalid.validate(), "meeting target eligibility is explicitly boolean")
	var malformed := WorkConfig.new()
	malformed.rules.meeting.auto_repeat = "yes"
	_check(not malformed.validate(), "meeting repetition must be explicitly boolean")
	var unsafe := WorkConfig.new()
	unsafe.rules.initial.money = 1_000_000_000
	_check(not unsafe.validate(), "reject opening allocations before creating cash entities")
	var wrong_category := WorkConfig.new()
	wrong_category.cards.employee.category = {}
	_check(not wrong_category.validate() and not wrong_category.errors.is_empty(), "wrong JSON types report validation errors")
