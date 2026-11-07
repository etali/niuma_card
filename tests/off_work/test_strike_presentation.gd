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
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 2, "leader": 1, "work": 30}, {"strike": 1}, {"employee": 1}, {"slack": 1}]
	main._new_game()
	await _settle()
	var strike := _owned("strike")
	var idle := -1
	var target_group := -1
	for gid in state.groups:
		if int(state.groups[gid].owner) != 1: continue
		if not state.group_work(gid).is_empty(): target_group = int(gid)
		elif state.group_cards(gid).size() == 1 and state.cards[state.group_cards(gid)[0]].type == "employee": idle = int(state.group_cards(gid)[0])
	var original := board.rest_pos(board.by_uid[strike])
	await _drag(board.by_uid[strike], _point(board.by_uid[idle]))
	_check(state.cards.has(strike), "invalid strike drop keeps the consumable")
	_check(board.rest_pos(board.by_uid[strike]).distance_to(original) < 0.02, "invalid enemy target springs back to exact original position")
	var people: Array = state.group_people(target_group).duplicate()
	var source_positions: Dictionary = {}
	for uid in people: source_positions[uid] = board.by_uid[uid].global_position
	var target: Dictionary = board.enemy_board.group_of(board.by_uid[people[0]])
	await _drag(board.by_uid[strike], _point(target.cards[board.enemy_board._top_index(target)]))
	_check(not state.cards.has(strike), "valid pointer drop consumes one strike")
	_check(board._strike_dancers.size() == people.size(), "all present enemy personnel enter independent dance motion")
	for uid in people:
		var card: OffWorkCard = board.by_uid[uid]
		_check(state.is_striking(uid) and state.group_cards(card.group_id) == [uid], "ejected personnel are real separate groups %d" % uid)
		_check(not card.draggable and not card.input_ray_pickable and card.collision_layer == 0 and card.collision_mask == 0, "ejection flight blocks physics and pointer pickup %d" % uid)
		_check(not card._task_progress.visible and board.enemy_board.group_of(card) == null, "dance has neither stale task bar nor old visual group %d" % uid)
		_check(is_inf(board._snap_distance(card.global_position, card)) and not board.try_merge(card).merged, "dance cannot attract another combination %d" % uid)
		_check((board._strike_dancers[uid].from as Vector3).distance_to(source_positions[uid]) < 0.2, "ejection originates at the old combination %d" % uid)
	board._advance_strike_dancers(1.0)
	var pose: Vector3 = board.by_uid[people[0]].global_position
	board._advance_strike_dancers(1.0 / 60.0)
	_check(board.by_uid[people[0]].global_position.distance_to(pose) < 0.0001, "landed strike card stays fixed while its illustration dances")
	_check(board.by_uid[people[0]]._visual.rotation.is_zero_approx() and board.by_uid[people[0]]._visual.scale.is_equal_approx(Vector3.ONE), "landed strike never rotates or squashes the entire card")
	var dancer: OffWorkCard = board.by_uid[people[0]]
	var elapsed := dancer.illustration_time()
	dancer._process(0.02)
	_check(dancer.illustration_time() != elapsed, "person illustration moves even though work is paused")
	board.sync_state(state)
	_check(not dancer.draggable and dancer.input_ray_pickable and dancer.collision_layer != 0, "landed enemy stays pickable for inspection but ownership forbids dragging")
	_check(is_inf(board._snap_distance(dancer.global_position, dancer)) and not board.try_merge(dancer).merged, "landed striking personnel still reject combinations")
	var world_before := dancer.global_position
	root.get_tree().paused = true
	await create_timer(0.05, true).timeout
	_check(dancer.global_position == world_before, "global pause freezes the dance pose")
	root.get_tree().paused = false
	state.advance(19.9)
	board.sync_state(state)
	_check(people.all(func(uid): return state.is_striking(uid)), "personnel remain on strike before twenty seconds")
	state.advance(0.1)
	board.sync_state(state)
	_check(board._strike_dancers.is_empty(), "twenty-second expiry releases every visual motion")
	for uid in people:
		var card: OffWorkCard = board.by_uid[uid]
		_check(not state.is_striking(uid) and state.group_cards(card.group_id) == [uid], "expiry leaves each person loose %d" % uid)
		_check(card.input_ray_pickable and card.collision_layer != 0 and not card.has_meta("in_flight"), "expiry restores collider and removes flight lock %d" % uid)
		_check(not card.draggable, "enemy ownership still forbids stealing expired personnel %d" % uid)
	await _coffee_flight()
	await _opponent_strike_interrupts_drag()
	if OS.get_environment("WORK_STRIKE_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await _capture_strike()
	main.queue_free()
	await process_frame
	for message in failures: printerr("FAIL ", message)
	print("STRIKE_PRESENTATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _coffee_flight() -> void:
	var worker := -1
	for uid in state.cards:
		if int(state.cards[uid].owner) == 0 and state.cards[uid].type == "employee" and state.group_cards(int(state.cards[uid].group)).size() == 1:
			worker = int(uid)
	var slack := _owned("slack")
	var group := int(state.cards[worker].group)
	state.move_cards([slack], group)
	state.activate(slack)
	state.drain_events()
	board.sync_state(state)
	await _settle()
	state.advance(float(state.config.rules.slack.seconds))
	var produced: Array = state.drain_events().filter(func(event): return event.kind == "slack_complete" and int(event.owner) == 0)
	if not _check(not produced.is_empty(), "slacking really produces a coffee event"): return
	var event: Dictionary = produced[0]
	board.sync_state(state)
	board.play_event(event)
	var uid := int(event.coffee_id)
	var coffee: OffWorkCard = board.by_uid[uid]
	_check(int(state.cards[uid].group) != group and state.group_cards(int(state.cards[uid].group)).all(func(id): return state.cards[id].type == "coffee"), "real coffee goes to a separate coffee-only pile")
	_check(board._delivery_flights.has(uid) and coffee.collision_layer == 0 and not coffee.draggable and not coffee.input_ray_pickable, "flying coffee cannot intercept a mouse or drag")
	_check(is_inf(board._snap_distance(coffee.global_position, coffee)) and not board.try_merge(coffee).merged, "flying coffee cannot become an accidental merge target")
	var trajectory: Dictionary = board._delivery_flights[uid]
	board._advance_deliveries(float(board._settings.coffee_motion.travel_seconds) * 0.5)
	_check(coffee.global_position.y > maxf(trajectory.from.y, trajectory.to.y), "coffee travels along a visible parabola")
	if OS.get_environment("WORK_STRIKE_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		board._pointer_at = Vector2(10, 400)
		await _draw_frame()
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))
		root.get_texture().get_image().save_png("res://reports/coffee-pop-out.png")
	board.sync_state(state)
	_check(coffee.collision_layer == 0 and not coffee.draggable, "sync does not make an airborne coffee interactive")
	board._advance_deliveries(2.0)
	_check(not board._delivery_flights.has(uid) and coffee.draggable and coffee.collision_layer != 0, "landing restores coffee interaction")
	_check(coffee.global_position.distance_to(trajectory.to) < 0.001, "coffee lands exactly on its independent pile")
	_check(int(state.cards[uid].group) != group and state.cards[uid].status == "ready" and is_zero_approx(state.cards[uid].remaining), "landed coffee is immediately usable without an additional timer")

func _opponent_strike_interrupts_drag() -> void:
	main._new_game()
	await _settle()
	var work := _owned("work")
	var target_group := int(state.cards[work].group)
	var people: Array = state.group_people(target_group).duplicate()
	var group: Dictionary = board.group_of(board.by_uid[work])
	var top: OffWorkCard = group.cards[board._top_index(group)]
	var start := _point(top)
	await _button(start, true)
	var motion := InputEventMouseMotion.new()
	motion.position = start + Vector2(30, 0)
	motion.global_position = motion.position
	motion.relative = Vector2(30, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion)
	await process_frame
	_check(board.is_dragging(), "local production group can be held before an incoming strike")
	var opponent_tool := -1
	for uid in state.cards:
		if state.cards[uid].type == "strike" and int(state.cards[uid].owner) == 1: opponent_tool = int(uid)
	_check(state.activate(opponent_tool, target_group), "opponent uses the same strike rule")
	board.sync_state(state)
	for event in state.drain_events():
		if event.kind == "strike": board.play_event(event)
	_check(not board.is_dragging() and board._press_snap.is_empty(), "incoming strike releases held personnel without a dangling drag")
	for uid in people:
		var card: OffWorkCard = board.by_uid[uid]
		_check(not card.draggable and card.collision_layer == 0 and card.selected == false, "local dancer cannot remain selected or draggable %d" % uid)
		board._snapshot_press(card, board.camera.unproject_position(card.global_position))
		_check(board._press_snap.is_empty(), "local dance cannot create a hidden pointer snapshot %d" % uid)
	board._advance_strike_dancers(1.0)
	board.sync_state(state)
	await _settle()
	_check(people.all(func(uid): return board.by_uid[uid].draggable and board.by_uid[uid].input_ray_pickable and board.by_uid[uid].collision_layer != 0), "local striking personnel regain loose-card dragging after landing")
	var moved_uid: int = people[0]
	var moved: OffWorkCard = board.by_uid[moved_uid]
	var before_move := board.rest_pos(moved)
	var strike_remaining := float(state.cards[moved_uid].remaining)
	var moved_start := _point(moved)
	await _button(moved_start, true)
	var reposition := InputEventMouseMotion.new()
	reposition.position = moved_start + Vector2(30, 0)
	reposition.global_position = reposition.position
	reposition.relative = Vector2(30, 0)
	reposition.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(reposition)
	await process_frame
	_check(board.is_dragging() and board._drag_cards.has(moved), "landed striking person enters a real pointer drag")
	var held_position := moved.global_position
	board.sync_state(state)
	_check(board.is_dragging() and board._drag_cards.has(moved) and moved.global_position.is_equal_approx(held_position), "periodic state sync neither cancels nor repositions a held striking person")
	board.cancel_pointer()
	await _button(reposition.position, false)
	board.sync_state(state)
	await _settle()
	await _drag(moved, _interior_empty_point(), true)
	var placed := board.rest_pos(moved)
	_check(placed.distance_to(before_move) > 0.2 and state.group_cards(int(state.cards[moved_uid].group)) == [moved_uid], "real pointer drag moves the striking person as a loose card")
	_check(state.is_striking(moved_uid) and is_equal_approx(float(state.cards[moved_uid].remaining), strike_remaining), "manual relocation does not cancel or restart the strike clock")
	var production: Dictionary = board.group_of(board.by_uid[work])
	await _drop_on_world(moved, production.cards[board._top_index(production)].global_position)
	_check(state.group_cards(int(state.cards[moved_uid].group)) == [moved_uid] and int(state.cards[moved_uid].group) != target_group, "dropping striking personnel on a work pile cannot start a combination")
	_check(board.rest_pos(moved).distance_to(placed) < 0.02, "invalid striking-person combination springs back to its manual position")
	var extra_work := state.add_card("work", 0)
	board.sync_state(state)
	await _settle()
	await _drop_on_world(board.by_uid[extra_work], moved.global_position)
	_check(int(state.cards[extra_work].group) != int(state.cards[moved_uid].group) and state.group_cards(int(state.cards[moved_uid].group)) == [moved_uid], "dragging ordinary work onto striking personnel also cannot combine")
	_check(is_equal_approx(float(state.cards[moved_uid].remaining), strike_remaining), "both invalid combine gestures preserve the strike countdown")
	var fired_uid: int = people[1]
	var refund := int(state.config.cards[str(state.cards[fired_uid].type)].refund)
	var money_before := state.money(0)
	await _drop_on_world(board.by_uid[fired_uid], board.pawn_pos, false)
	_check(not state.cards.has(fired_uid) and not board.by_uid.has(fired_uid) and not board._strike_dancers.has(fired_uid), "real dismissal-zone drag removes a striking person and its dance state")
	_check(state.money(0) == money_before + refund, "dismissing striking personnel pays the ordinary configured refund")
	state.advance(strike_remaining - 0.1)
	board.sync_state(state)
	_check(state.is_striking(moved_uid) and is_equal_approx(float(state.cards[moved_uid].remaining), 0.1), "relocated personnel remain striking until the original deadline")
	state.advance(0.1)
	board.sync_state(state)
	await _settle()
	_check(not state.is_striking(moved_uid) and moved.draggable and state.group_cards(int(state.cards[moved_uid].group)) == [moved_uid], "strike expiry leaves moved personnel loose and usable")
	_check(board.rest_pos(moved).distance_to(placed) < 0.02, "expiry preserves the manually chosen tabletop position")
	main._new_game()
	_check(board._strike_dancers.is_empty() and board._delivery_flights.is_empty(), "restart clears transient strike and coffee owners")

func _capture_strike() -> void:
	main._new_game()
	await _settle()
	var strike := _owned("strike")
	var target := -1
	for gid in state.groups:
		if state.can_strike_group(int(gid), 0): target = int(gid)
	main._activate(strike, target)
	board._pointer_at = Vector2(10, 400)
	await create_timer(0.28).timeout
	await _draw_frame()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))
	root.get_texture().get_image().save_png("res://reports/strike-ejection.png")
	await create_timer(0.85).timeout
	await _draw_frame()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))
	root.get_texture().get_image().save_png("res://reports/strike-dance.png")

func _drop_on_world(card: CardEntity, target: Vector3, visible_face := true) -> void:
	var start := _point(card)
	if not _check(start != Vector2.INF, "striking-card gesture starts on an exposed collider"): return
	await _button(start, true)
	await _move_pointer(start + Vector2(12, 0))
	var anchor := Vector3(target.x, Board.DRAG_HEIGHT, target.z)
	if visible_face:
		var screen := board.camera.unproject_position(target)
		var origin := board.camera.project_ray_origin(screen)
		var ray := board.camera.project_ray_normal(screen)
		anchor = origin + ray * ((Board.DRAG_HEIGHT - origin.y) / ray.y)
	# As in the original dismissal and pointer-safety tests, move the held
	# card's centre to the actual target, compensating its original grab point.
	var destination := board.camera.unproject_position(Vector3(anchor.x - board._grab_offset.x, Board.DRAG_HEIGHT, anchor.z - board._grab_offset.z))
	var from := pointer
	for step in range(1, 9): await _move_pointer(from.lerp(destination, float(step) / 8.0))
	_check(board.is_dragging(), "striking-card gesture uses the original pointer drag")
	if visible_face:
		_check(board._strike_drop_conflict(card.global_position), "actual release overlaps the forbidden target face")
	await _button(destination, false)
	await _settle()
	_check(not board.is_dragging(), "striking-card release clears the pointer state")

func _move_pointer(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.relative = at - pointer
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer = at
	root.push_input(motion)
	await process_frame
	board._process(0.0)

func _interior_empty_point() -> Vector2:
	var safe := board.player_bounds.grow(-1.0)
	# Keep the relocated person away from the edge so the opposite-direction
	# drag can put another elevated card's centre over the same visible face
	# without the native board-boundary clamp changing the intended gesture.
	for row in [4, 5, 3, 6, 2, 7, 1, 8, 0]:
		for col in [9, 10, 8, 11, 7, 12, 6, 13, 5, 14, 4, 15, 3, 16, 2, 17, 1, 0]:
			var p: Vector2 = safe.position + Vector2(float(col) / 17.0, float(row) / 8.0) * safe.size
			var at := board.camera.unproject_position(Vector3(p.x, float(board._settings.rest_y), p.y))
			if board._pick_card(at) != null or not main.hud.content_rect().has_point(at): continue
			var clear := true
			for other in board.cards:
				if not other.is_market and Vector2(other.position.x - p.x, other.position.z - p.y).length() < 1.8: clear = false
			if clear: return at
	return Vector2.INF

func _draw_frame() -> void:
	await process_frame
	RenderingServer.force_draw(false)
