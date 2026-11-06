extends "res://tests/realtime/test_work_ui.gd"

const Clock = preload("res://engine/work_progress_clock.gd")

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	if OS.get_environment("WORK_DATA_DIR").is_empty():
		OS.set_environment("WORK_DATA_DIR", "/tmp/work-slack-presentation-%d" % OS.get_process_id())
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
	state.config.rules.initial.groups = [{"employee": 2, "grinder": 1, "slack": 1}, {"work": 40}]
	state.config.rules.initial.money = 0
	main._new_game()
	await _settle()
	_check(state.last_error.is_empty(), "fixture uses valid rules")
	var tool := _owned("slack")
	var group: int = state.cards[tool].group
	var people := state.group_people(group).duplicate()
	board.set_debug_mode(true)
	state.advance(7.0)
	state.drain_events()
	board.sync_state(state)
	var bars := _bars(group)
	_check(bars.size() == 1, "three personnel share one visible coffee progress bar")
	_check(bars.size() == 1 and is_equal_approx(bars[0]._task_progress_value, 0.5), "shared coffee progress is halfway through the real cycle")
	_check(bars.size() == 1 and is_equal_approx(bars[0]._debug_remaining, 7.0), "Debug shows the group countdown")
	var second := state.add_card("slack", 0)
	state.move_cards([second], group)
	board.sync_state(state)
	bars = _bars(group)
	var remaining := 0.5 / state.group_slack_rate(group)
	_check(is_equal_approx(state.group_slack_progress(group), 0.5), "adding another slack card does not restart production")
	_check(bars.size() == 1 and is_equal_approx(bars[0]._debug_remaining, remaining), "Debug immediately reflects stacked slack acceleration")
	state.advance(remaining)
	var events: Array = state.drain_events().filter(func(e): return e.kind == "slack_complete" and e.owner == 0)
	_check(events.size() == 1 and events[0].ids.size() == 3, "three coffees arrive as one actual group settlement")
	board.sync_state(state)
	for event in events: board.play_event(event)
	var ids: Array = events[0].coffee_ids
	_check(board._delivery_flights.size() == 3, "all three real coffee cards receive flight animations")
	for uid in ids:
		var card: WorkCard = board.by_uid[uid]
		_check(state.cards[uid].group != group and state.group_cards(state.cards[uid].group).all(func(id): return state.cards[id].type == "coffee"), "coffee leaves production for a separate coffee-only pile")
		_check(not card.draggable and card.collision_layer == 0 and not card.input_ray_pickable, "every flying coffee is excluded from interaction")
		_check(is_inf(board._snap_distance(card.global_position, card)), "flying coffee cannot attract combinations")
	board._advance_deliveries(0.3)
	_check(board.by_uid[ids[0]].global_position.distance_to(board.by_uid[ids[1]].global_position) > 0.01, "batch coffees follow distinct staggered trajectories")
	_check(board.by_uid[ids[1]].global_position.distance_to(board.by_uid[ids[2]].global_position) > 0.01, "later coffees remain visibly separated")
	board._advance_deliveries(2.0)
	_check(board._delivery_flights.is_empty(), "coffee flights finish without leaving a pending card")
	for uid in ids:
		_check(board.by_uid[uid].draggable and board.by_uid[uid]._visual.visible, "every landed coffee is visible and draggable")
	state.advance(1.0 / state.group_slack_rate(group))
	events = state.drain_events().filter(func(e): return e.kind == "slack_complete" and e.owner == 0)
	_check(events.size() == 1 and events[0].ids.size() == 3, "the next batch produces three more without activation")
	board.sync_state(state)
	state.advance(2.0)
	board.sync_state(state)
	var saved_progress := state.group_slack_progress(group)
	var leader := state.add_card("leader", 1)
	var meeting := state.add_card("meeting", 1, state.cards[leader].group)
	_check(state.activate(meeting), "opponent leader pulls all three coffee makers into a real meeting")
	board.sync_state(state)
	bars = _bars(group)
	_check(bars.size() == 1 and bars[0]._task_progress_paused, "the remaining slack tool shows one paused group bar")
	var frozen := Clock.remaining(state, tool, "slack", saved_progress)
	state.advance(3.0)
	board.sync_state(state)
	_check(is_equal_approx(state.group_slack_progress(group), saved_progress) and is_equal_approx(Clock.remaining(state, tool, "slack", saved_progress), frozen), "all attendees away freezes shared progress and Debug time")
	state.advance(state.config.number("meeting", "duration_seconds") - 3.0)
	board.sync_state(state)
	board._advance_meeting_visitors(3.0)
	_check(state.group_slack_participants(group).size() == 3, "all three personnel resume their coffee group after the meeting")
	var strike := state.add_card("strike", 1)
	_check(state.activate(strike, group), "strike can target a coffee-only production group")
	board.sync_state(state)
	bars = _bars(group)
	_check(bars.size() == 1 and bars[0]._task_progress_paused, "strike leaves the shared production bar paused")
	_check(people.all(func(uid): return state.is_striking(uid)), "every present coffee maker is ejected and striking")
	state.drain_events()
	state.advance(state.config.number("slack", "seconds"))
	_check(state.drain_events().all(func(e): return e.kind != "slack_complete" or e.owner != 0), "unmanned coffee production emits no more coffee")
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("SLACK_PRESENTATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _bars(group: int) -> Array:
	return board.by_uid.values().filter(func(card): return card.group_id == group and card._task_progress_active and card._task_progress_phase == "slack" and not card.is_meeting_participant())
