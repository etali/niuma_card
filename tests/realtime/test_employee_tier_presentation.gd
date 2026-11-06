extends "res://tests/realtime/test_work_ui.gd"

const Clock = preload("res://engine/work_progress_clock.gd")

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-tier-presentation-%d" % OS.get_process_id())
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	board.set_process(false)
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 1, "work": 40}, {"coffee": 8}]
	state.config.rules.initial.money = 0
	state.config.rules.coffee.upgrades.employee.seconds = 2.0
	state.config.rules.coffee.upgrades.grinder.seconds = 3.0
	state.config.rules.coffee.upgrades.workaholic.seconds = 4.0
	main._new_game()
	await _settle()
	_check_upgrade_highlights()
	var person := _owned("employee")
	var group: int = state.cards[person].group
	var card: WorkCard = board.by_uid[person]
	var identity := card.get_instance_id()
	var coffee := _owned_ids("coffee")
	state.move_cards(coffee, group, person)
	state.drain_events()
	board.sync_state(state)
	board.set_debug_mode(true)
	var stages := ["employee", "grinder", "workaholic"]
	var results := ["grinder", "workaholic", "work_emperor"]
	var costs := [1, 2, 4]
	var retained_coffee := coffee.size()
	for stage in stages.size():
		var from_type: String = stages[stage]
		var to_type: String = results[stage]
		var duration: float = state.config.coffee_seconds(from_type)
		_check(state.cards[person].type == from_type and state.tasks[person].kind == "coffee", "%s starts its own upgrade task" % from_type)
		var materials: Array = state.tasks[person].coffee_ids.duplicate()
		_check(materials.size() == costs[stage], "%s reserves its own required number of cups" % from_type)
		state.advance(duration * 0.5)
		board.sync_state(state)
		_check(card.get_instance_id() == identity and card.type == from_type, "%s remains the same visible personnel node while drinking" % from_type)
		_check(card._task_progress_active and card._task_progress_phase == "coffee" and is_equal_approx(card._task_progress_value, 0.5), "%s personnel shows real halfway progress" % from_type)
		_check(is_equal_approx(card._debug_remaining, duration * 0.5), "%s Debug reads this stage's remaining time" % from_type)
		for uid in materials:
			var cup: WorkCard = board.by_uid[uid]
			_check(cup._task_progress_active and is_equal_approx(cup._task_progress_value, 0.5) and is_equal_approx(cup._debug_remaining, duration * 0.5), "%s reserved cup remains visible with the actual stage timer" % from_type)
		_check(_owned_ids("coffee").size() == retained_coffee, "%s does not consume materials before the deadline" % from_type)
		state.advance(duration * 0.5)
		var events: Array = state.drain_events().filter(func(e): return e.kind == "coffee_upgrade" and e.owner == 0)
		_check(events.size() == 1, "%s produces one upgrade completion event" % from_type)
		retained_coffee -= costs[stage]
		board.sync_state(state)
		for event in events: board.play_event(event)
		_check(card.get_instance_id() == identity and board.by_uid[person] == card, "%s keeps physics, pointer and stack identity" % to_type)
		_check(card.type == to_type and card.def_id == to_type and card.label.text == state.config.cards[to_type].name, "%s refreshes title and definition on the existing card" % to_type)
		_check(card._icon.texture == CardArt.illustration_texture(to_type, WorkCardDB), "%s switches to its configured real artwork" % to_type)
		_check(card.uses_continuous_animation() and card.illustration_profile() == to_type and card._motion_material != null, "%s uses its own continuous motion profile" % to_type)
		_check(card._upgrade_visual_active and card._upgrade_remaining > 0.0, "%s plays the production upgrade ring" % to_type)
		_check(card.stamp_text() == str(state.config.cards[to_type].name), "%s upgrade stamp names the attained role" % to_type)
		_check(_owned_ids("coffee").size() == retained_coffee and materials.all(func(uid): return not board.by_uid.has(uid)), "%s removes exactly the consumed real coffee cards from the table" % to_type)
		if stage + 1 < stages.size():
			_check(card._task_progress_active and is_zero_approx(card._task_progress_value), "%s starts the next stage at an empty progress bar" % to_type)
	_check(state.cards[person].type == "work_emperor" and _owned_ids("coffee").size() == 1, "seven cups complete three stages and leave the eighth cup intact")
	_check(state.tasks[person].kind == "work", "maximum tier resumes ordinary work instead of drinking extra coffee")
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
	await _queue_presentation()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("EMPLOYEE_TIER_PRESENTATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _combination(kinds: Array) -> Dictionary:
	return WorkComboRules.evaluate(kinds.map(func(kind): return {"type": kind}))

func _queue_presentation() -> void:
	state.config.rules.initial.groups = [{"employee": 2, "work": 40}, {"coffee": 2}]
	state.config.rules.coffee.upgrades.employee.seconds = 5.0
	main._new_game()
	await _settle()
	var people := _owned_ids("employee")
	var material := _owned_ids("coffee")
	var group: int = state.cards[people[0]].group
	var visible_people: Array = people.map(func(uid): return board.by_uid[uid])
	state.move_cards(material, group, people[0])
	state.drain_events()
	board.sync_state(state)
	for index in people.size():
		var person: int = people[index]
		var cup: int = state.tasks[person].coffee_ids[0]
		var visible_cup: WorkCard = board.by_uid[cup]
		_check(visible_cup._task_progress_active and visible_cup._task_progress_phase == "coffee" and is_zero_approx(visible_cup._task_progress_value), "queued cup %d starts its visible timer from zero" % index)
		state.advance(2.5)
		board.sync_state(state)
		_check(is_equal_approx(visible_cup._task_progress_value, 0.5) and is_equal_approx(visible_cup._debug_remaining, 2.5), "queued cup %d displays its own real half-progress and remaining time" % index)
		state.advance(2.5)
		var completed: Array = state.drain_events().filter(func(event): return event.kind == "coffee_upgrade" and event.owner == 0)
		board.sync_state(state)
		for event in completed: board.play_event(event)
		_check(completed.size() == 1 and completed[0].person == person, "queued stage %d emits one matching visual completion" % index)
		_check(board.by_uid[person] == visible_people[index] and visible_people[index].type == "grinder" and visible_people[index].label.text == "卷王", "queued stage %d refreshes the same personnel node into a grinder" % index)
		_check(not board.by_uid.has(cup) and visible_people[index]._upgrade_visual_active, "queued stage %d removes its consumed cup and plays the real upgrade animation" % index)
	_check(people.all(func(uid): return board.by_uid[uid].type == "grinder") and _owned_ids("coffee").is_empty(), "two real visible employees complete without another stacking gesture")

func _check_upgrade_highlights() -> void:
	var insufficient := _combination(["grinder", "coffee"])
	_check(not bool(insufficient.valid) and insufficient.type != "upgrade", "one cup cannot highlight a two-cup grinder upgrade")
	var enough := _combination(["grinder", "coffee", "coffee"])
	_check(bool(enough.valid) and enough.type == "upgrade" and enough.output_card == "workaholic", "two cups highlight the actual next grinder tier")
	var final_stage := _combination(["workaholic", "coffee", "coffee", "coffee", "coffee"])
	_check(bool(final_stage.valid) and final_stage.type == "upgrade" and final_stage.output_card == "work_emperor", "four cups highlight the actual final upgrade")
	var maximum := _combination(["work_emperor", "coffee"])
	_check(not bool(maximum.valid) and maximum.type != "upgrade", "maximum tier does not show a nonexistent coffee upgrade")
	var income := _combination(["employee", "grinder", "workaholic", "work_emperor", "work", "work", "work", "work"])
	_check(bool(income.valid) and income.type == "production" and income.output_n == 15, "combination preview reports the four tiers' real fifteen-money income")
	_check(WorkCardDB.get_def("workaholic").output_n == 4 and WorkCardDB.get_def("work_emperor").output_n == 8, "high-tier card definitions expose their actual individual income")
