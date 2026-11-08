extends SceneTree

var checks := 0
var errors: Array[String] = []
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "work": 30}, {"strike": 1}, {"leader": 1}]
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(54)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	board.sync_state(state)
	await create_timer(0.3).timeout
	var attacker := _card("strike", 1)
	var victim := _card("employee", 0)
	var target := int(state.cards[victim].group)
	var source_face: OffWorkCard = board.by_uid[attacker]
	_check(state.activate(attacker, target), "BOT can launch a real strike")
	board.sync_state(state)
	_check(board._strike_attacks.has(attacker) and board.by_uid[attacker] == source_face, "attack flies the original card node")
	_check(not board._strike_attacks[attacker].delivered, "automatic BOT launch keeps its flight from the source pile")
	_check(source_face.visible and source_face._visual.visible and not source_face.input_ray_pickable and not source_face.draggable, "flying face is visible and cannot intercept defense input")
	_check(not state.is_striking(victim), "launch does not apply damage before the response window")
	state.advance(float(state.config.rules.strike.flight_seconds) * 0.5)
	board.sync_state(state)
	var flight: Dictionary = board._strike_attacks[attacker]
	var middle := source_face.global_position
	_check(middle.y > maxf(flight.from.y, flight.to.y), "BOT strike travels visibly above the table toward the player")
	board._advance_strike_attacks(20.0)
	_check(source_face.global_position.is_equal_approx(middle), "wall time cannot advance the authoritative attack timer")
	board.reset_view()
	board.sync_state(state)
	_check(board._strike_attacks.has(attacker), "restoring a mid-flight snapshot reconstructs attack presentation without a launch event")
	var union_id := state.add_card("union", 0)
	_check(state.move_cards([union_id], target) == target, "player can insert a union while the attack is travelling")
	state.advance(float(state.config.rules.strike.flight_seconds) * 0.5)
	board.sync_state(state)
	for event in state.drain_events(): board.play_event(event)
	_check(state.cards.has(attacker) and not state.is_striking(victim), "last-moment defense keeps strike card and prevents damage")
	_check(board._strike_attacks[attacker].phase == "return" and board._strike_dancers.is_empty(), "blocked card bounces home without ejecting personnel")
	board._advance_strike_attacks(float(board._settings.strike_attack_motion.return_seconds))
	_check(not board._strike_attacks.has(attacker) and not board.by_uid[attacker].has_meta("in_flight"), "return lands and releases animation ownership")
	_check(board.by_uid[attacker].input_ray_pickable and not board.by_uid[attacker].draggable, "return keeps BOT ownership and restores inspection")
	# Player attacks take the same flight path and only consume on impact.
	attacker = _card("strike", 0)
	victim = _card("employee", 1)
	target = int(state.cards[victim].group)
	_check(state.activate(attacker, target), "player attack uses the same delayed command")
	board.sync_state(state)
	_check(board._strike_attacks.has(attacker) and not state.is_striking(victim), "player launch is also visible before damage")
	_check(not board._strike_attacks[attacker].delivered, "click activation without a physical drag still travels from the player's pile")
	state.advance(float(state.config.rules.strike.flight_seconds))
	board.sync_state(state)
	_check(not state.cards.has(attacker) and not board._strike_attacks.has(attacker) and state.is_striking(victim), "unblocked impact consumes the card and begins personnel strike")
	# Coffee must lose its visible bar immediately when its only person leaves.
	state.new_game(91)
	board.reset_view()
	victim = _card("employee", 0)
	var coffee := state.add_card("coffee", 0)
	state.move_cards([victim, coffee])
	state.advance(1.0)
	board.sync_state(state)
	_check(board.by_uid[coffee]._task_progress.visible and board.by_uid[coffee]._task_progress_value > 0.0, "coffee displays its real in-progress upgrade")
	var meeting := state.add_card("meeting", 1)
	state.move_cards([meeting], int(state.cards[_card("leader", 1)].group))
	board.sync_state(state)
	_check(state.is_meeting_target(victim), "opponent meeting removes the sole coffee participant")
	_check(not board.by_uid[coffee]._task_progress.visible and is_zero_approx(board.by_uid[coffee]._task_progress_value), "empty coffee combination immediately clears the track and value")
	_check(is_zero_approx(board.by_uid[coffee]._task_completion_hold), "empty coffee combination retains no completion flash")
	host.queue_free()
	await process_frame
	for error in errors: printerr("FAIL ", error)
	print("STRIKE_ATTACK_PRESENTATION %s (%d checks)" % ["PASS" if errors.is_empty() else "FAIL", checks])
	quit(0 if errors.is_empty() else 1)

func _card(kind: String, owner: int) -> int:
	for id in state.cards:
		if state.cards[id].type == kind and int(state.cards[id].owner) == owner: return int(id)
	return -1

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)
