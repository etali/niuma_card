extends SceneTree

## Native Viewport input -> unchanged Board pawn hit -> real dismissal/refund.
var game: Node
var board: OffWorkBoard
var state: OffWorkState
var pointer := Vector2.ZERO
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1600, 900)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	board = game.board
	board.touch_mode = true
	state = game.state
	state.config.rules.bot.enabled = false
	await _restart()
	_check(board.offers_by_id.size() == 6, "all six offers remain beside the dismissal facility")
	_check(game.get_node("MarketFacility").visible and game.get_node("MarketFacilityDivider").visible, "original facility and divider remain visible")
	_check(game.get_node("MarketFacility/FacilityName").text == "开除", "original facility shows configured dismissal name")
	_check(game.get_node("MarketFacility/FacilityAction").text.is_empty(), "dismissal facility omits the removed action caption")
	_check(board.pawn_pos.is_equal_approx(game.get_node("MarketFacility").position), "original pawn hit target and facility share position")
	for role in ["employee", "leader", "grinder"]:
		await _single(role)
	await _mixed_pile()
	await _expanded_tail()
	await _invalid_and_cancelled()
	await _changed_during_drag()
	game.queue_free()
	await process_frame
	for error in failures: printerr("FAIL ", error)
	print("WORK_DISMISS_ZONE ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks; original Board + Viewport.push_input)")
	quit(0 if failures.is_empty() else 1)

func _single(role: String) -> void:
	await _restart()
	var person := _owned("employee") if role == "employee" else state.add_card(role, 0)
	board.sync_state(state)
	await _settle()
	var before := state.money(0)
	var people := state.people_count(0)
	await _drag_to_zone(board.by_uid[person])
	_check(not state.cards.has(person) and state.people_count(0) == people - 1, "%s real input dismisses one person" % role)
	_check(state.money(0) == before + int(state.config.cards[role].refund), "%s refunds configured amount exactly once" % role)
	_check(game.bot.is_started(), "successful %s dismissal starts BOT" % role)
	var source: Vector3 = board._previous_positions.get(person, Vector3.INF)
	_check(source != Vector3.INF and Vector2(source.x - board.pawn_pos.x, source.z - board.pawn_pos.z).length() < Board.PAWN_RADIUS, "dismissal caches %s release position" % role)
	game._process(0.0)
	_check(board._cash_flights.size() == int(state.config.cards[role].refund), "%s refund launches one real card per money unit" % role)
	if not board._cash_flights.is_empty():
		var flight: Dictionary = board._cash_flights.values()[0]
		_check(flight.from.is_equal_approx(source + Vector3.UP * float(board._settings.income_motion.spawn_height)), "%s refund launches from dismissed person" % role)
		var cash: int = board._cash_flights.keys()[0]
		_check(state.group_cards(int(state.cards[cash].group)).all(func(id): return state.cards[id].type == "money"), "refund lands in pure cash pile")
	await _restart()
	_check(board._cash_flights.is_empty() and board._dismiss_pick_snapshot.is_empty() and not game.bot.is_started(), "restart clears dismissal motion and resets BOT")

func _mixed_pile() -> void:
	state.config.rules.initial.groups = [{"work": 200, "employee": 1, "leader": 1, "grinder": 1, "overtime": 1}]
	await _restart()
	var work := _owned("work")
	var gid: int = state.cards[work].group
	var cash := _owned("money")
	state.move_cards([cash], gid)
	board.sync_state(state)
	game._remember_player_activity()
	await _settle()
	var group: Dictionary = board.group_of(board.by_uid[work])
	var origin := board.rest_origin(group)
	var expected: Array = state.group_cards(gid).filter(func(id): return not state.config.is_person(str(state.cards[id].type)))
	var before := state.money(0)
	var refund := 0
	for role in ["employee", "leader", "grinder"]: refund += int(state.config.cards[role].refund)
	await _drag_to_zone(group.cards[0])
	_check(state.people_count(0) == 0, "mixed pile dismisses all three own personnel including last person")
	_check(state.work_count(0) == 200, "all 200 work cards survive dismissal")
	_check(state.group_cards(gid) == expected, "mixed pile preserves all work, cash, tools and membership")
	_check(state.money(0) == before + refund, "mixed pile refunds personnel only")
	group = board.group_of(board.by_uid[work])
	_check(board.rest_origin(group).distance_to(origin) < 0.01 and bool(group.compact), "200-card pile returns to original support plane and compact state")
	for iteration in 3: board.sync_state(state)
	await _settle()
	_check(board.rest_origin(board.group_of(board.by_uid[work])).distance_to(origin) < 0.01, "periodic sync cannot move remaining work into dismissal zone")
	game._process(0.0)
	_check(board._cash_flights.size() == refund, "each dismissed person launches all of its real unit refund cards")
	for uid in board._cash_flights:
		_check(int(state.cards[uid].group) != gid, "refund never joins retained mixed work pile")

func _invalid_and_cancelled() -> void:
	state.config.rules.initial.groups = [{"work": 200}, {"employee": 1}, {"overtime": 1}]
	for kind in ["work", "overtime", "money"]:
		await _restart()
		var id := _owned(kind)
		var before := JSON.stringify(state.cards)
		var original := board.get_group_position(int(state.cards[id].group))
		await _drag_to_zone(board.by_uid[id])
		_check(JSON.stringify(state.cards) == before, "%s is never consumed by dismissal" % kind)
		_check(board.get_group_position(int(state.cards[id].group)).distance_to(original) < 0.01, "%s invalid drop returns to original location" % kind)
		_check(not game.bot.is_started(), "invalid %s dismissal does not start BOT" % kind)
	await _restart()
	var employee := _owned("employee")
	var original := board.get_card_position(employee)
	await _begin_drag(board.by_uid[employee])
	var destination := await _move_to_zone()
	await _button(destination, false, true)
	await _settle()
	_check(state.cards.has(employee) and board.get_card_position(employee).distance_to(original) < 0.03, "cancelled release returns employee without dismissal")
	_check(not game.bot.is_started() and board._dismiss_pick_snapshot.is_empty(), "cancel clears snapshot without starting BOT")
	# Enemy collider is visible but unchanged Board rejects picking it.
	var enemy := _owned("employee", 1)
	var before := JSON.stringify(state.cards)
	await _button(_point(board.by_uid[enemy]), true)
	await _button(_point(board.by_uid[enemy]), false)
	_check(JSON.stringify(state.cards) == before and not board.is_dragging(), "opponent cannot be picked for dismissal")
	# Market cards use original purchase path and reject the facility as a buy point.
	var offer: CardEntity = board.offers_by_id.values()[0]
	await _drag_to_zone(offer)
	_check(JSON.stringify(state.cards) == before and not game.bot.is_started(), "market card cannot be sold or bought through dismissal area")
	_check(offer.global_position.distance_to(offer.get_meta("market_slot")) < 0.03, "rejected market card returns to conveyor")
	await _restart()
	state.config.rules.fire.minimum_people = state.people_count(0)
	employee = _owned("employee")
	original = board.get_card_position(employee)
	before = JSON.stringify(state.cards)
	await _drag_to_zone(board.by_uid[employee])
	_check(JSON.stringify(state.cards) == before and not game.bot.is_started(), "rule-level refusal is atomic and leaves BOT waiting")
	_check(board.get_card_position(employee).distance_to(original) < 0.03, "rule-level refusal restores personnel location")
	state.config.rules.fire.minimum_people = 0

func _expanded_tail() -> void:
	state.config.rules.initial.groups = [{"employee": 1, "leader": 1, "grinder": 1, "overtime": 1, "work": 3}]
	await _restart()
	var employee := _owned("employee")
	var leader := _owned("leader")
	var grinder := _owned("grinder")
	var gid: int = state.cards[employee].group
	var group: Dictionary = board.group_of(board.by_uid[employee])
	if group.compact: board.toggle_compact(group.cards[0])
	# Finish fixture expansion at its intended native destination before measuring.
	for card in group.cards: board._stop_move(card)
	await _settle()
	var origin := board.rest_origin(group)
	var expected: Array = state.group_cards(gid).filter(func(id): return id != leader and id != grinder)
	await _drag_to_zone(board.by_uid[leader])
	_check(state.cards.has(employee) and not state.cards.has(leader) and not state.cards.has(grinder), "expanded middle-card gesture only sells personnel in dragged suffix")
	_check(state.group_cards(gid) == expected, "expanded suffix returns its work and tool to original prefix")
	group = board.group_of(board.by_uid[employee])
	var offsets: Array = []
	for index in group.cards.size(): offsets.append(board._stack_offset(group, index))
	# The original screen clamp can make a tiny correction when a shorter
	# expanded pile no longer needs the old high-stack viewport offset.
	var restored := board.clamp_player_position(origin, offsets)
	_check(not group.compact and board.rest_origin(group).distance_to(restored) < 0.01, "expanded pile restores source plane under original viewport bounds")

func _changed_during_drag() -> void:
	state.config.rules.initial.groups = [{"work": 200, "employee": 1}]
	await _restart()
	var employee := _owned("employee")
	var gid: int = state.cards[employee].group
	var group: Dictionary = board.group_of(board.by_uid[employee])
	var origin := board.rest_origin(group)
	await _begin_drag(group.cards[0])
	await _move_to_zone()
	state.advance(float(state.config.roles.employee.work_seconds))
	board.sync_state(state)
	_check(state.work_count(0) == 199, "real task completes while source pile is in pointer")
	var destination := await _move_to_zone()
	await _button(destination, false)
	await _settle()
	_check(not state.cards.has(employee) and state.work_count(0) == 199, "dismissal after task completion cannot resurrect consumed work")
	_check(board.rest_origin(board.group_of(board.by_uid[state.group_cards(gid)[0]])).distance_to(origin) < 0.01, "concurrent work completion preserves source pile origin")
	_check(not board.is_dragging() and board._press_snap.is_empty() and board._dismiss_pick_snapshot.is_empty(), "all pointer state clears after concurrent completion")

func _restart() -> void:
	game._new_game()
	await _settle()

func _owned(kind: String, owner := 0) -> int:
	for id in state.cards:
		if str(state.cards[id].type) == kind and int(state.cards[id].owner) == owner: return id
	return -1

func _point(card: CardEntity) -> Vector2:
	for z in [-0.40, 0.0, 0.40]:
		for x in [0.0, -0.35, 0.35]:
			var at := board.camera.unproject_position(card.global_position + Vector3(x * CardEntity.CARD_SIZE.x, CardEntity.Y_TEXT, z * CardEntity.CARD_SIZE.z))
			if game.hud.content_rect().has_point(at) and board._pick_card(at) == card: return at
	return Vector2.INF

func _begin_drag(card: CardEntity) -> void:
	var at := _point(card)
	if not _check(at != Vector2.INF, "drag source exposes original collider"): return
	await _button(at, true)
	await _motion(at + Vector2(20, 0))
	_check(board.is_dragging(), "original pointer path begins drag")

func _move_to_zone() -> Vector2:
	var destination := board.camera.unproject_position(Vector3(board.pawn_pos.x - board._grab_offset.x, Board.DRAG_HEIGHT, board.pawn_pos.z - board._grab_offset.z))
	var start := pointer
	for step in range(1, 7): await _motion(start.lerp(destination, float(step) / 6.0))
	return destination

func _drag_to_zone(card: CardEntity) -> void:
	await _begin_drag(card)
	var destination := await _move_to_zone()
	await _button(destination, false)
	await _settle()
	_check(not board.is_dragging() and board._press_snap.is_empty(), "release clears original pointer state")

func _motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer = at
	root.push_input(event)
	await process_frame

func _button(at: Vector2, pressed: bool, cancelled := false) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.canceled = cancelled
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	pointer = at
	root.push_input(event)
	await process_frame

func _settle() -> void:
	await create_timer(0.35).timeout
	await physics_frame
	await process_frame

func _check(ok: bool, message: String) -> bool:
	checks += 1
	if not ok: failures.append(message)
	return ok
