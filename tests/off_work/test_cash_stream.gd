extends SceneTree

var game: Node
var checks := 0
var failures: Array[String] = []
var capture := false
var frame_index := 0
var inside := true
var max_visible := 0

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	capture = OS.has_environment("WORK_CASH_STREAM_CAPTURE") and DisplayServer.get_name() != "headless"
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(4)
	game.hud.drawer_window.pin()
	game.set_process(false)
	game.board.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	game.state.config.rules.bot.enabled = false
	var widths: Array = []
	for amount in [1, 5, 20]:
		await _reset([{"employee": 1, "work": 80}], amount)
		var events := _produce(10.0)
		var before: Dictionary = game.state.cards.duplicate(true)
		for event in events: game.board.play_event(event)
		_check(game.board._cash_flights.size() == 2 * amount, "each currency unit retains its real flight for amount " + str(amount))
		var flight: Dictionary = game.board._cash_flights.values()[0]
		_check(flight.samples.is_empty(), "unit currency needs no substitute decorative notes")
		var staggered := false
		for current in game.board._cash_flights.values():
			staggered = staggered or float(current.delay) > float(flight.delay)
		_check(amount == 1 or staggered, "multiple real cards launch sequentially")
		await _advance(0.32, capture)
		widths.append(float(game.board._cash_flights.values()[0].width))
		await _shoot("amount-" + str(amount))
		var note_positions: Array = []
		for uid in game.board._cash_flights:
			var current: Dictionary = game.board._cash_flights[uid]
			if current.owner != 0: continue
			var card: OffWorkCard = game.board.by_uid[uid]
			if card._visual.visible: note_positions.append(card.global_position)
		if amount > 1:
			_check(note_positions.size() > 1, "multiple amounts reveal independently flying real cards")
			for a in note_positions.size():
				for b in range(a + 1, note_positions.size()): _check(note_positions[a].distance_to(note_positions[b]) > 0.05, "sequential notes do not share a rigid packet position")
		await _advance(1.7, capture)
		await _advance(0.5)
		_check(game.board._cash_flights.is_empty() and _notes() == 0, "complete stream lands and cleans decorative notes")
		_check(game.state.cards == before, "animation never clones, spends or changes actual currency")
	_check(widths[0] < widths[1] and widths[1] < widths[2], "more cards widen the stream")
	_check(widths[2] <= float(game.board._settings.income_motion.max_stream_width), "stream width stops at configured ceiling")
	# Three actual groups finish in the same simulation frame, rather than a
	# long advance artificially stacking independent historical completions.
	await _reset([{"employee": 1, "work": 20}, {"employee": 1, "work": 20}, {"employee": 1, "work": 20}], 5)
	var simultaneous := _produce(10.0)
	_check(simultaneous.size() == 6, "three groups per side produce simultaneously")
	for event in simultaneous: game.board.play_event(event)
	await _advance(0.45, capture)
	await _shoot("three-groups")
	var snapshot := _snapshot()
	paused = true
	await create_timer(0.08, true).timeout
	_check(_snapshot() == snapshot, "pause preserves every real and decorative trajectory")
	paused = false
	await _advance(1.7, capture)
	await _advance(0.5)
	# Keep the old large-wallet rendering compatibility check isolated from
	# ordinary earnings, which now create one authoritative card per unit.
	await _reset([{"employee": 1, "work": 100}], 1)
	var events := _produce(10.0)
	for event in events:
		game.state.cards[event.money_id].amount = 10000
		event.amount = 10000
	game.board.sync_state(game.state)
	for event in events: game.board.play_event(event)
	await _advance(0.3)
	for flight in game.board._cash_flights.values():
		_check(is_equal_approx(float(flight.width), float(game.board._settings.income_motion.max_stream_width)), "10000 income cannot exceed stream width")
		_check(flight.samples.size() < int(game.board._settings.income_motion.max_samples_per_payment), "10000 income does not allocate a node per unit")
	await _shoot("large-payment")
	await _reset([{"employee": 1, "work": 100}], 1)
	events = _produce(300.0)
	var balances := [game.state.money(0), game.state.money(1)]
	for event in events: game.board.play_event(event)
	_check(game.board._cash_flights.size() == events.size(), "burst keeps every real UID on a full flight instead of instant overflow deposit")
	await _advance(0.35)
	await _shoot("dense-stream")
	_check_budget()
	_check(game.state.money(0) == balances[0] and game.state.money(1) == balances[1], "dense visual sampling leaves all money accounted for")
	await _advance(2.5)
	_check(game.board._cash_flights.is_empty() and _notes() == 0, "dense burst drains within a bounded duration")
	_check(inside, "all visible notes stay inside legal tabletop corridor")
	# Dragging, spending and restart remove each independent note.
	events = _produce(10.0)
	for event in events: game.board.play_event(event)
	var uid: int = events[0].money_id
	game.board._cancel_cash_flight(game.board.by_uid[uid])
	_check(not game.board._cash_flights.has(uid) and game.board.by_uid[uid]._visual.visible, "cancel restores original real card visibility")
	game._new_game()
	_check(_notes() == 0 and game.board._cash_flights.is_empty(), "restart cleans the complete stream")
	await _dismissal()
	game.queue_free()
	await _frames(3)
	for message in failures: push_error(message)
	print("CASH_STREAM %s (%d checks, peak %d visible notes per side)" % ["PASS" if failures.is_empty() else "FAIL", checks, max_visible])
	quit(0 if failures.is_empty() else 1)

func _dismissal() -> void:
	await _reset([{"employee": 1, "work": 4}], 1)
	var person := -1
	for uid in game.state.cards:
		if game.state.cards[uid].owner == 0 and game.state.cards[uid].type == "employee": person = uid
	var facility: Vector3 = game.board.pawn_pos
	game.board.by_uid[person].position = facility
	_check(game.state.dismiss_people([person], 0), "actual dismissal credits refund")
	var events: Array = game.state.drain_events().filter(func(e): return e.kind == "fire")
	game.board.sync_state(game.state)
	for event in events: game.board.play_event(event)
	game.board._advance_cash_flights(0.001)
	var cash: OffWorkCard = game.board.by_uid[events[0].money_id]
	_check(cash.position.distance_to(facility) < 0.35, "refund begins at facility without a teleport")
	await _advance(0.32)
	await _shoot("dismissal")
	await _advance(2.0)
	_check(game.board._cash_flights.is_empty(), "refund completes continuous path")

func _reset(groups: Array, income: int) -> void:
	game.state.config.rules.initial.groups = groups
	game.state.config.cards.work.income = income
	game._new_game()
	game.state.drain_events()
	await create_timer(0.35, true).timeout

func _produce(seconds: float) -> Array:
	game.state.advance(seconds)
	var events: Array = game.state.drain_events().filter(func(e): return e.kind == "work_complete")
	game.board.sync_state(game.state)
	game._update_hud()
	return events

func _notes() -> int:
	return game.board.find_children("IncomeNote*", "Node3D", false, false).size()

func _snapshot() -> Array:
	var result: Array = []
	for uid in game.board._cash_flights:
		var f: Dictionary = game.board._cash_flights[uid]
		result.append([uid, f.elapsed, game.board.by_uid[uid].position])
		for n in f.samples: result.append([n.node.global_position, n.node.visible])
	return result

func _check_budget() -> void:
	for owner in [0, 1]:
		var count := 0
		var notes := 0
		for uid in game.board._cash_flights:
			var f: Dictionary = game.board._cash_flights[uid]
			if int(f.owner) != owner: continue
			count += 1 if game.board.by_uid[uid]._visual.visible else 0
			notes += f.samples.size()
			for n in f.samples: count += 1 if n.node.visible else 0
		max_visible = maxi(max_visible, count)
		_check(notes <= int(game.board._settings.income_motion.max_decorative_cards_per_owner), "decorative node budget stays bounded")
		_check(count <= int(game.board._settings.income_motion.max_visible_notes_per_owner), "close notes are sampled rather than densely overdrawn")

func _advance(seconds: float, movie := false) -> void:
	var left := seconds
	while left > 0.000001:
		var delta := minf(left, 1.0 / 60.0)
		game.board._advance_cash_flights(delta)
		for uid in game.board._cash_flights:
			var f: Dictionary = game.board._cash_flights[uid]
			var region: Rect2 = game.board._cash_screen_region(int(f.owner), str(f.kind) == "fire").grow(float(game.board._settings.income_motion.screen_padding_pixels))
			var card: OffWorkCard = game.board.by_uid[uid]
			if card._visual.visible and float(f.elapsed) - float(f.delay) < float(game.board._settings.income_motion.travel_seconds): inside = inside and region.encloses(game.board._cash_note_screen_bounds(card._visual))
			for n in f.samples:
				if n.node.visible: inside = inside and region.encloses(game.board._cash_note_screen_bounds(n.node))
		left -= delta
		await process_frame
		if movie:
			await RenderingServer.frame_post_draw
			DirAccess.make_dir_recursive_absolute("res://reports/cash-stream-frames")
			root.get_texture().get_image().save_png("res://reports/cash-stream-frames/%04d.png" % frame_index)
			frame_index += 1

func _shoot(label: String) -> void:
	if not capture: return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://reports/cash-stream-" + label + ".png")

func _frames(count: int) -> void:
	for index in count: await process_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
