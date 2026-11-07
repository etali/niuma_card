extends "res://tests/off_work/test_work_ui.gd"

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 1}, {"work": 27}, {"work": 12}, {"outsource": 1}]
	state.config.rules.initial.money = 156
	for compact in [true, false]:
		main._new_game()
		await _settle()
		var target := -1
		var source := -1
		for gid in state.groups:
			if int(state.groups[gid].owner) != 0: continue
			if state.group_work(gid).size() == 27: target = int(gid)
			if state.group_work(gid).size() == 12: source = int(gid)
		state.move_cards(_owned_ids("money") + [_owned("outsource")], target)
		state.advance(4.0)
		board.sync_state(state)
		var visual: Dictionary = board.group_of(board.by_uid[state.group_cards(source)[0]])
		if bool(visual.compact) != compact: board.toggle_compact(visual.cards[0])
		await _settle()
		var source_origin: Vector3 = board.rest_origin(visual)
		var target_visual: Dictionary = board.group_of(board.by_uid[state.group_cards(target)[0]])
		var target_origin: Vector3 = board.rest_origin(target_visual)
		var untouched := _owned("employee")
		var untouched_origin: Vector3 = board.rest_pos(board.by_uid[untouched])
		var moved: Array = visual.cards.slice(0, 7).map(func(card): return card.uid)
		_check(state.move_cards(moved, target) == target, "real refill moves the source's visible head into an earlier target group")
		var logical := JSON.stringify({"cards": state.cards, "groups": state.groups, "tasks": state.tasks})
		var timer: float = state.cards[_owned("outsource")].remaining
		board.sync_state(state)
		var remaining_offsets: Array = []
		for index in visual.cards.size(): remaining_offsets.append(board._stack_offset(visual, index))
		var bounded_source: Vector3 = board.clamp_player_position(source_origin, remaining_offsets)
		_check(board.rest_origin(visual).distance_to(bounded_source) < 0.001, "%s source remainder retains its anchor with only native boundary clamping" % compact)
		_check(board.rest_origin(target_visual).distance_to(target_origin) < 0.001, "%s receiving stack stays at its original anchor" % compact)
		_check(board.rest_pos(board.by_uid[untouched]).distance_to(untouched_origin) < 0.001, "unrelated manually placed player card does not move")
		_check(state.group_work(source).size() == 5 and state.group_work(target).size() == 34, "spatial synchronization never alters the real refill membership")
		_check(JSON.stringify({"cards": state.cards, "groups": state.groups, "tasks": state.tasks}) == logical and state.cards[_owned("outsource")].remaining == timer, "layout preserves the exact progress and active reservation")
		await _settle()
		for iteration in 5: board.sync_state(state)
		_check(board.rest_origin(visual).distance_to(bounded_source) < 0.001, "later refreshes cannot pull the leftover source pile toward the receiving pile")
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL " + failure)
	print("GROUP_SYNC_ORIGINS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
