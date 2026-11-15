extends "res://tests/off_work/test_work_ui.gd"

const Clock = preload("res://engine/off_work_progress_clock.gd")

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-tier-presentation-%d" % OS.get_process_id())
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	board.set_process(false)
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 1}, {"work": 40}, {"coffee": 8}]
	state.config.rules.initial.money = 0
	state.config.rules.coffee.seconds = 2.0
	# Retired role overrides cannot lengthen a new shared batch.
	state.config.rules.coffee.upgrades.employee.seconds = 20.0
	state.config.rules.coffee.upgrades.grinder.seconds = 30.0
	state.config.rules.coffee.upgrades.workaholic.seconds = 40.0
	main._new_game()
	await _settle()
	_check_upgrade_highlights()
	var person := _owned("employee")
	var group: int = state.cards[person].group
	var card: OffWorkCard = board.by_uid[person]
	var identity := card.get_instance_id()
	var coffee := _owned_ids("coffee")
	state.move_cards(coffee, group, person)
	state.drain_events()
	board.sync_state(state)
	board.set_debug_mode(true)
	var duration: float = state.config.coffee_batch_seconds()
	_check(state.cards[person].type == "employee" and state.tasks[person].kind == "coffee"
		and state.tasks[person].to_type == "work_emperor", "one batch reserves the employee's final attainable tier")
	var materials: Array = state.tasks[person].coffee_ids.duplicate()
	_check(materials.size() == 7 and is_equal_approx(state.tasks[person].total, duration),
		"three tier jumps reserve seven cups but use only one shared two-second timer")
	state.advance(duration * 0.5)
	board.sync_state(state)
	_check(card.get_instance_id() == identity and card.type == "employee", "employee remains the same visible personnel node before the batch deadline")
	_check(card._task_progress_active and card._task_progress_phase == "coffee" and is_equal_approx(card._task_progress_value, 0.5), "personnel shows real halfway batch progress")
	_check(is_equal_approx(card._debug_remaining, duration * 0.5), "personnel Debug reads shared batch remaining time")
	for uid in materials:
		var cup: OffWorkCard = board.by_uid[uid]
		_check(cup._task_progress_active and is_equal_approx(cup._task_progress_value, 0.5) and is_equal_approx(cup._debug_remaining, duration * 0.5), "each reserved cup remains visible with the actual shared batch timer")
	_check(_owned_ids("coffee").size() == 8, "no batch materials are consumed before the deadline")
	state.advance(duration * 0.5)
	var events: Array = state.drain_events().filter(func(e): return e.kind == "coffee_upgrade" and e.owner == 0)
	_check(events.size() == 1 and events[0].person == person, "multi-level batch emits one final upgrade completion for the actual person")
	board.sync_state(state)
	for event in events: board.play_event(event)
	_check(card.get_instance_id() == identity and board.by_uid[person] == card, "final upgrade keeps physics, pointer and stack identity")
	_check_personnel_presentation(card, "work_emperor")
	_check(_owned_ids("coffee").size() == 1 and materials.all(func(uid): return not board.by_uid.has(uid)), "the batch removes exactly seven consumed real coffee cards and leaves the eighth intact")
	_check(not state.tasks.has(person), "maximum tier waits for reassignment and leaves spare coffee intact")
	var work_group: int = state.cards[_owned("work")].group
	state.move_cards([person], work_group)
	group = work_group
	board.sync_state(state)
	_check(state.tasks[person].kind == "work", "moving the improved personnel back to work starts the ordinary work timer")
	state.advance(5.0)
	board.sync_state(state)
	var bars: Array = board.by_uid.values().filter(func(c): return c.group_id == group and c._task_progress_active and c._task_progress_phase == "work")
	_check(bars.size() == 1 and is_equal_approx(bars[0]._task_progress_value, 0.5), "maximum tier shares the existing ten-second group work progress")
	state.advance(5.0)
	var paid: Array = state.drain_events().filter(func(e): return e.kind == "work_complete" and e.owner == 0)
	board.sync_state(state)
	for event in paid: board.play_event(event)
	_check(paid.size() == 1 and paid[0].money_ids.size() == 8, "maximum tier's first full cycle produces eight real money cards")
	_check(board._cash_flights.size() == 8, "all eight earned cards use the existing bounded cash flight presentation")
	_check(_owned_ids("coffee").size() == 1, "working at maximum tier preserves spare coffee")
	await _batch_presentation()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("EMPLOYEE_TIER_PRESENTATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _combination(kinds: Array) -> Dictionary:
	return OffWorkComboRules.evaluate(kinds.map(func(kind): return {"type": kind}))

func _check_personnel_presentation(card: OffWorkCard, to_type: String) -> void:
	_check(card.type == to_type and card.def_id == to_type and card.label.text == state.config.cards[to_type].name, "%s refreshes title and definition on the existing card" % to_type)
	_check(card._icon.texture == CardArt.illustration_texture(to_type, OffWorkCardDB), "%s switches to its configured real artwork" % to_type)
	_check(card.uses_continuous_animation() and card.illustration_profile() == to_type and card._motion_material != null, "%s uses its own continuous motion profile" % to_type)
	_check(card._upgrade_visual_active and card._upgrade_remaining > 0.0, "%s plays the production upgrade ring" % to_type)
	_check(card.stamp_text() == str(state.config.cards[to_type].name), "%s upgrade stamp names the attained role" % to_type)

func _batch_presentation() -> void:
	state.config.rules.initial.groups = [{"employee": 2}, {"work": 40}, {"coffee": 4}]
	state.config.rules.coffee.seconds = 5.0
	main._new_game()
	await _settle()
	var people := _owned_ids("employee")
	var material := _owned_ids("coffee")
	var group: int = state.cards[people[0]].group
	var visible_people: Array = people.map(func(uid): return board.by_uid[uid])
	var final_types := ["workaholic", "grinder"]
	state.move_cards(material, group, people[0])
	state.drain_events()
	board.sync_state(state)
	_check(state.tasks[people[0]].coffee_ids.size() == 3 and state.tasks[people[1]].coffee_ids.size() == 1,
		"batch plans all participants up front, allocating three then one cup in equal-tier group order")
	for index in people.size():
		var person: int = people[index]
		_check(state.tasks[person].to_type == final_types[index] and visible_people[index]._task_progress_active
			and is_zero_approx(visible_people[index]._task_progress_value), "batch participant %d starts at zero with its planned final tier" % index)
	for uid in material:
		_check(board.by_uid[uid]._task_progress_active and board.by_uid[uid]._task_progress_phase == "coffee"
			and is_zero_approx(board.by_uid[uid]._task_progress_value), "every reserved cup starts the same visible batch timer")
	state.advance(2.5)
	board.sync_state(state)
	for uid in people + material:
		var visible: OffWorkCard = board.by_uid[uid]
		_check(is_equal_approx(visible._task_progress_value, 0.5) and is_equal_approx(visible._debug_remaining, 2.5),
			"every participant and cup displays shared half-progress and remaining time")
	_check(people.all(func(uid): return state.cards[uid].type == "employee") and _owned_ids("coffee").size() == 4,
		"all participants retain original types and materials until the common deadline")
	state.advance(2.5)
	var completed: Array = state.drain_events().filter(func(event): return event.kind == "coffee_upgrade" and event.owner == 0)
	board.sync_state(state)
	for event in completed: board.play_event(event)
	_check(completed.size() == 2 and people.all(func(uid): return completed.any(func(event): return event.person == uid)),
		"one batch deadline emits exactly one completion per actual person")
	for index in people.size():
		var person: int = people[index]
		_check(board.by_uid[person] == visible_people[index], "simultaneous upgrade keeps participant %d's existing visible node" % index)
		_check_personnel_presentation(visible_people[index], final_types[index])
	_check(material.all(func(uid): return not board.by_uid.has(uid)) and _owned_ids("coffee").is_empty(),
		"the shared deadline removes all four consumed cups without another stacking gesture")

func _check_upgrade_highlights() -> void:
	var working := _combination(["employee", "coffee", "work"])
	_check(bool(working.valid) and working.type == "production", "mixed personnel, coffee and work highlights actual work instead of coffee")
	var insufficient := _combination(["grinder", "coffee"])
	_check(not bool(insufficient.valid) and insufficient.type != "upgrade", "one cup cannot highlight a two-cup grinder upgrade")
	var enough := _combination(["grinder", "coffee", "coffee"])
	_check(bool(enough.valid) and enough.type == "upgrade" and enough.output_card == "workaholic", "two cups highlight the actual next grinder tier")
	var final_stage := _combination(["workaholic", "coffee", "coffee", "coffee", "coffee"])
	_check(bool(final_stage.valid) and final_stage.type == "upgrade" and final_stage.output_card == "work_emperor", "four cups highlight the actual final upgrade")
	var maximum := _combination(["work_emperor", "coffee"])
	_check(not bool(maximum.valid) and maximum.type != "upgrade", "maximum tier does not show a nonexistent coffee upgrade")
	var tiers: Array = ["employee", "grinder", "workaholic", "work_emperor"]
	var full_queue := tiers.duplicate()
	for _i in 15: full_queue.append("work")
	var income := _combination(full_queue)
	_check(bool(income.valid) and income.type == "production" and income.recipe_pay_n == 15 and income.output_n == 15, "combination preview reports the four tiers clearing fifteen work for fifteen money")
	var short_queue := _combination(tiers + ["work", "work", "work", "work"])
	_check(bool(short_queue.valid) and short_queue.recipe_pay_n == 4 and short_queue.output_n == 4, "a four-work queue pays only for the four files actually cleared")
	for kind in tiers:
		var definition := OffWorkCardDB.get_def(kind)
		_check(int(definition.recipe_n) == int(definition.output_n) and int(definition.output_n) == int(pow(2, tiers.find(kind))), "%s card definition clears and earns the same per batch" % kind)
