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
	board.touch_mode = true
	# Exercise the deliberately narrow case independently of the user's saved
	# setting; the options suite verifies the shipped 75% default and controls.
	board.set_snap_hit_fraction(0.5)
	# Keep the money at an exact point while still driving the inherited drag
	# loop through real Viewport events and _process(0), without advancing FX.
	board.set_process(false)
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 1}, {"work": 30}, {"overtime": 1}, {"overtime": 1}]
	main._new_game()
	var employee := _owned("employee")
	var work := _owned("work")
	var production: int = state.cards[work].group
	state.move_cards([employee], production)
	state.drain_events()
	board.sync_state(state)
	await _settle()
	state.advance(10.0)
	var event: Dictionary = state.drain_events().filter(func(e): return e.kind == "work_complete" and e.owner == 0)[0]
	board.sync_state(state)
	board.play_event(event)
	board._advance_cash_flights(0.4)
	var cash: OffWorkCard = board.by_uid[int(event.money_id)]
	var bank: int = state.cards[cash.uid].group
	var balance := state.money(0)
	board.sync_state(state)
	await physics_frame
	_check(cash.collision_layer == 0 and cash.collision_mask == 0 and not cash.input_ray_pickable and not cash.draggable, "flight stays non-interactive after state sync")
	var flight_point := board.camera.unproject_position(cash.global_position)
	_check(board._pick_card(flight_point) != cash, "airborne cash does not intercept the pointer ray")
	_check(board._nearest_group(cash.global_position, []) == null, "airborne cash cannot pull a drop into its distant bank")
	await _click(flight_point)
	_check(board._press_snap.is_empty() and board._drag_cards.is_empty(), "clicking a flying note creates no pickup snapshot")
	_check(not board.try_merge(cash).merged and state.cards[cash.uid].group == bank, "flying money cannot be submitted as a dragged card")
	var tool := _owned("overtime")
	await _drop_at(board.by_uid[tool], cash.global_position)
	_check(state.cards[tool].group != bank and state.cards[tool].group != production, "dropping a tool through an income arc creates no unintended combination")
	_check(state.cards[cash.uid].group == bank and state.money(0) == balance, "income remains in its own bank with unchanged value")
	_check(board._cash_flights.has(cash.uid), "unrelated drag does not cancel the income flight")
	# Adjacent placement used to fall inside the original 1.6-unit snap radius.
	var group: Dictionary = board.group_of(board.by_uid[employee])
	var top: OffWorkCard = group.cards[board._top_index(group)]
	var buried: OffWorkCard = group.cards.back()
	var hidden_edge := buried.global_position - Vector3(0, 0, CardEntity.CARD_SIZE.z * 0.18)
	_check(is_inf(board._snap_distance(hidden_edge, top)) and is_finite(board._face_region_distance(hidden_edge, buried)), "fixture touches the buried face geometry outside the visible top's central snap area")
	_check(board._stack_occluded.has(buried.uid) and is_inf(board._snap_distance(hidden_edge, buried)), "occluded card geometry is explicitly excluded from snap targets")
	_check(board._nearest_group(hidden_edge, [board.by_uid[tool]]) == null, "buried compact cards cannot enlarge the visible snap range")
	var beside := top.global_position + Vector3(CardEntity.CARD_SIZE.x + 0.1, 0, 0)
	_check(board._nearest_group(beside, [board.by_uid[tool]]) == null, "free tabletop beside a stack is not a snap target")
	await _drop_at(board.by_uid[tool], beside)
	_check(state.cards[tool].group != production, "actual release beside the stack keeps cards separate")
	await _drop_at(board.by_uid[tool], top.global_position)
	_check(state.cards[tool].group == production, "clear overlap still combines through the original input path")
	# A settled wallet remains a valid purchase target while new money flies in.
	var wallet := _owned("money")
	var market: CardEntity = board.offers_by_id[int(state.offers[0].id)]
	_check(board._cash_at(board.by_uid[wallet].global_position, market) != null, "landed money pile remains usable during income animation")
	board._advance_cash_flights(2.5)
	await physics_frame
	_check(not cash.has_meta("income_flight") and cash.draggable and cash.input_ray_pickable, "landing restores normal interaction")
	_check(cash.collision_layer != 0 and cash.collision_mask != 0, "landing restores original collision settings")
	_check(not state.groups[bank].cards.has(tool), "no ghost money combination was committed")
	state.advance(10.0)
	var next_events: Array = state.drain_events().filter(func(e): return e.kind == "work_complete" and e.owner == 0)
	board.sync_state(state)
	for next_event in next_events: board.play_event(next_event)
	board._advance_cash_flights(0.2)
	board._on_card_clicked(board.by_uid[wallet])
	var wide := false
	for offset in board._drag_offsets:
		if absf(offset.x) > CardEntity.CARD_SIZE.x or absf(offset.z) > CardEntity.CARD_SIZE.z: wide = true
	_check(not wide and board._cash_flights.is_empty(), "deliberately grabbing the bank collects arrivals without giant drag offsets")
	board.cancel_pointer()
	board.sync_state(state)
	_check(state.group_cards(bank).all(func(uid): return state.cards[uid].type == "money"), "collecting arrivals preserves the pure money group")
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("CASH_POINTER_SAFETY %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _drop_at(card: CardEntity, target_world: Vector3) -> void:
	var start := _point(card)
	if not _check(start != Vector2.INF, "drag source exposes a settled collider"): return
	await _button(start, true)
	await _motion(start + Vector2(12, 0))
	# The caller specifies the visible destination, including the target's
	# stack height; compensate the original grab offset, not the snap result.
	var destination := board.camera.unproject_position(target_world)
	var origin := board.camera.project_ray_origin(destination)
	var ray := board.camera.project_ray_normal(destination)
	var anchor: Vector3 = origin + ray * ((Board.DRAG_HEIGHT - origin.y) / ray.y)
	destination = board.camera.unproject_position(Vector3(anchor.x - board._grab_offset.x, Board.DRAG_HEIGHT, anchor.z - board._grab_offset.z))
	await _motion(destination)
	await _button(destination, false)
	await _settle()
	_check(not board.is_dragging(), "release clears original dragging state")

func _motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer = at
	root.push_input(event)
	await process_frame
	board._process(0.0)
