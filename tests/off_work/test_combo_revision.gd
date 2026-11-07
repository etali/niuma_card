extends SceneTree

var checks := 0
var errors: Array[String] = []

func _initialize() -> void:
	_upgrade_material()
	_meeting_random_draw()
	_meeting_boundaries()
	_permanent_and_stacking()
	_bot_upgrades()
	for error in errors: printerr("FAIL ", error)
	print("COMBO_REVISION ", "PASS" if errors.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if errors.is_empty() else 1)

func _state(contents: Dictionary, seed_value := 41) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(seed_value)
	state.drain_events()
	return state

func _owned(state: OffWorkState, kind: String, owner := 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == kind and int(state.cards[id].owner) == owner)

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: errors.append(label)

func _upgrade_material() -> void:
	var state := _state({"employee": 2, "work": 200, "leader": 1})
	var employees := _owned(state, "employee")
	var target: int = employees[1]
	var group: int = state.cards[target].group
	var coffee := state.add_card("coffee", 0)
	state.advance(3.0)
	var assignment: Dictionary = state.tasks[target].duplicate(true)
	var work := state.work_count(0)
	var before_money := state.money(0)
	group = state.move_cards([target])
	_check(state.move_cards([coffee], group, target) == group, "coffee drag command joins the actual target group")
	_check(state.cards.has(coffee) and state.cards[target].type == "employee" and state.tasks[target].kind == "coffee", "coffee starts a real upgrade task without premature consumption")
	state.advance(state.config.number("coffee", "seconds"))
	_check(not state.cards.has(coffee) and state.cards[target].type == "grinder", "one coffee is consumed and the targeted employee UID becomes grinder")
	_check(state.cards[employees[0]].type == "employee" and state.cards[target].owner == 0 and state.cards[target].group == group, "upgrade affects one target and preserves identity, owner and group")
	_check(not state.tasks.has(target) and is_equal_approx(state.group_work_progress(assignment.group), 0.8), "independent upgrade leaves the working colleague advancing the original group")
	_check(state.work_count(0) == work and state.money(0) == before_money, "upgrade does not complete work or mint money")
	var upgrades := state.drain_events().filter(func(event): return event.kind == "coffee_upgrade")
	_check(upgrades.size() == 1 and upgrades[0].source == coffee and upgrades[0].person == target, "one real upgrade event refers to consumed source and stable personnel UID")
	var unused := state.add_card("coffee", 0, group)
	for invalid in [target, _owned(state, "leader")[0], -123]:
		var snapshot := JSON.stringify(state.cards)
		_check(not state.activate(unused, group, invalid), "invalid upgrade target is rejected")
		_check(JSON.stringify(state.cards) == snapshot and state.cards.has(unused), "invalid target leaves ingredient and personnel unchanged")
	var enemy: int = _owned(state, "employee", 1)[0]
	_check(not state.activate(unused, state.cards[enemy].group, enemy) and state.cards.has(unused), "coffee cannot upgrade an opponent")
	_check(state.cards.has(unused) and state.cards[unused].status == "ready" and is_zero_approx(state.cards[unused].remaining), "fresh coffee is immediately ready without a preparation timer")
	_check(state.move_cards([employees[0]], group) == group and state.tasks[employees[0]].kind == "coffee" and state.cards.has(unused), "bringing the remaining employee to ready coffee begins exactly one timed upgrade")
	state.advance(state.config.number("coffee", "seconds"))
	_check(not state.cards.has(unused) and state.cards[employees[0]].type == "grinder", "full progress consumes the ready cup exactly once")
	state.move_cards(employees, assignment.group)
	_check(employees.all(func(id): return state.tasks[id].kind == "work" and is_equal_approx(state.cards[id].progress, 0.8)), "returning upgraded employees joins the original preserved shared work progress")
	var idle := _state({"work": 200, "employee": 1})
	var person := idle.add_card("employee", 0)
	var material := idle.add_card("coffee", 0)
	_check(idle.move_cards([material], idle.cards[person].group, person) >= 0 and idle.tasks[person].kind == "coffee", "idle employee can drink without any work combo")
	idle.advance(idle.config.number("coffee", "seconds"))
	_check(idle.cards[person].type == "grinder", "idle upgrade still waits for full progress")

func _meeting_random_draw() -> void:
	var draws: Dictionary = {}
	for seed_value in range(1, 9):
		var state := _state({"employee": 8, "work": 200}, seed_value)
		var host: int = _owned(state, "employee")[0]
		var group: int = state.cards[host].group
		var meeting := state.add_card("meeting", 0, group)
		_check(state.activate(meeting, group, host), "employee meeting starts with eligible opponents")
		var targets: Array = state.meetings[meeting].targets
		_check(targets.size() == 2 and targets[0] != targets[1], "employee draws at most two distinct opponents")
		for person in targets:
			_check(state.cards[person].owner == 1 and state.cards[person].paused and state.groups[state.cards[person].group].owner == 1, "meeting retains actual opponent ownership and original group")
		var key: Array = targets.duplicate()
		key.sort()
		draws[str(key)] = true
		var same := _state({"employee": 8, "work": 200}, seed_value)
		var same_host: int = _owned(same, "employee")[0]
		var same_tool := same.add_card("meeting", 0, same.cards[same_host].group)
		same.activate(same_tool, same.cards[same_host].group, same_host)
		_check(same.meetings[same_tool].targets == targets, "same match seed and commands reproduce the same random meeting")
	_check(draws.size() > 1, "different seeds select different actual personnel rather than dictionary-first people")
	var leader_state := _state({"employee": 6, "work": 200})
	var leader := leader_state.add_card("leader", 0)
	var leader_group: int = leader_state.cards[leader].group
	var tool := leader_state.add_card("meeting", 0, leader_group)
	_check(leader_state.activate(tool, leader_group, leader) and leader_state.meetings[tool].targets.size() == 4, "leader draws up to four opponents")
	var one := _state({"employee": 1, "work": 200})
	var single: int = _owned(one, "employee")[0]
	var one_tool := one.add_card("meeting", 0, one.cards[single].group)
	_check(one.activate(one_tool, one.cards[single].group) and one.meetings[one_tool].targets.size() == 1, "one available opponent produces one target")
	var empty := _state({"employee": 1, "work": 200})
	empty.dismiss_people(_owned(empty, "employee", 1), 1)
	var empty_host: int = _owned(empty, "employee")[0]
	var empty_tool := empty.add_card("meeting", 0, empty.cards[empty_host].group)
	_check(not empty.activate(empty_tool, empty.cards[empty_host].group) and empty.meetings.is_empty() and empty.cards[empty_tool].status == "ready", "zero opponents rejects without inventing personnel or spending meeting")

func _meeting_boundaries() -> void:
	var state := _state({"employee": 2, "work": 200})
	state.advance(2.0)
	var host: int = _owned(state, "employee")[0]
	var group: int = state.cards[host].group
	var enemy: int = _owned(state, "employee", 1)[0]
	var workplace: int = state.cards[enemy].group
	var work: int = state.tasks[enemy].work_id
	state.move_cards(state.group_people(workplace))
	var meeting := state.add_card("meeting", 0, group)
	state.activate(meeting, group, host)
	var targets: Array = state.meetings[meeting].targets.duplicate()
	var target: int = targets[0]
	var target_group: int = state.cards[target].group
	_check(state.move_cards([target], -1) < 0 and not state.dismiss_people([target], 1), "forced attendees cannot leave by moving or being dismissed")
	var coffee := state.add_card("coffee", 1, target_group)
	_check(not state.activate(coffee, target_group) and state.cards.has(coffee), "automatic upgrade never reaches a pulled-away employee through the old group")
	_check(state.activate(coffee, target_group, target), "explicit upgrade queues a paused drink for an attendee")
	_check(state.cards[target].type == "employee" and state.cards[target].paused and state.meetings[meeting].targets == targets, "upgrade keeps pause and the exact locked meeting targets")
	state.advance(4.0)
	_check(state.tasks[target].kind == "coffee" and state.tasks[target].progress == 0.0 and state.tasks[target].resume_task.is_empty() and is_equal_approx(state.cards[work].progress, 0.2), "paused standalone drink and separate unattended work both preserve their own progress")
	state.move_cards([host], -1)
	_check(not state.meetings.has(meeting) and not state.cards[target].paused and state.cards[target].group == target_group, "host departure immediately releases original personnel to original groups")
	state.advance(state.config.number("coffee", "seconds"))
	_check(state.cards[target].type == "grinder" and not state.tasks.has(target), "after meeting release coffee finishes in the independent personnel group")
	state.move_cards(targets, workplace)
	state.advance(1.0)
	_check(is_equal_approx(state.cards[work].progress, 0.3), "returning released attendees resumes the original shared work progress")

func _permanent_and_stacking() -> void:
	var state := _state({"employee": 1, "work": 200})
	var person: int = _owned(state, "employee")[0]
	var group: int = state.cards[person].group
	var overtime := state.add_card("overtime", 0)
	state.move_cards([overtime], group)
	state.advance(50.0)
	_check(state.work_count(0) == 194 and is_equal_approx(state.cards[person].rate_multiplier, 1.2), "overtime remains fully effective beyond the old duration")
	_check(state.cards[overtime].status == "ready" and state.cards[overtime].remaining == 0.0 and state.cards[overtime].total == 0.0, "permanent overtime has no artificial duration or recovery state")
	var first := state.add_card("overtime", 0)
	var second := state.add_card("overtime", 0)
	state.move_cards([first, second], group)
	_check(is_equal_approx(state.cards[person].rate_multiplier, 1.728), "three overtime cards multiply their configured gains")
	state.advance(1.0)
	var work: int = state.tasks[person].work_id
	var progress: float = state.cards[work].progress
	state.move_cards([first], -1)
	_check(is_equal_approx(state.cards[person].rate_multiplier, 1.44) and is_equal_approx(state.cards[work].progress, progress), "removing one overtime divides only its multiplier without rewriting progress")
	state.move_cards([overtime], -1)
	_check(is_equal_approx(state.cards[person].rate_multiplier, 1.2), "removing overtime immediately removes its persistent gain")
	state.move_cards([second], -1)
	_check(is_equal_approx(state.cards[person].rate_multiplier, 1.0), "removing final tool restores base rate")
	state.move_cards([overtime], group)
	_check(is_equal_approx(state.cards[person].rate_multiplier, 1.2) and state.cards.has(overtime), "reattaching overtime works immediately without a cooldown")
	var extra := state.add_card("overtime", 0)
	state.move_cards([extra], group)
	_check(is_equal_approx(state.cards[person].rate_multiplier, 1.44), "two overtime cards multiply the same work cycle by 1.2 squared")

func _bot_upgrades() -> void:
	var state := _state({"employee": 1, "work": 200})
	state.config.rules.bot.buy_chance = 0.0
	# Give the promotion a concrete production benefit so this decision tests
	# executing an upgrade rather than the strategy's income valuation.
	state.config.roles.grinder.work_capacity = 2
	var person: int = _owned(state, "employee")[0]
	var workplace: int = state.cards[person].group
	var coffee := state.add_card("coffee", 0)
	var bot := OffWorkBot.new(state, 0)
	bot.start()
	bot.advance(0.0)
	_check(state.cards[person].type == "employee" and state.cards[coffee].status == "active", "BOT starts the same timed upgrade as a player")
	state.advance(state.config.number("coffee", "seconds"))
	_check(state.cards[person].type == "grinder" and not state.cards.has(coffee), "BOT uses coffee as a one-time personnel upgrade after the task")
	var overtime := state.add_card("overtime", 0, workplace)
	state.advance(state.config.number("bot", "think_seconds"))
	bot.advance(0.0)
	_check(state.cards[overtime].status == "ready" and state.cards[person].rate_multiplier >= 1.2, "BOT leaves persistent overtime in place without repeatedly restarting it")
