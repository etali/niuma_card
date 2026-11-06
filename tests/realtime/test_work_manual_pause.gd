extends SceneTree

## Actual footer pointer input, with both simulation and presentation in flight.
var game: Node
var hud: CanvasLayer
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(4)
	hud = game.hud
	hud.drawer_window.pin()
	var button: Button = hud.btn_pause
	_check(button.get_parent() == hud.btn_resign.get_parent(), "pause reuses the original footer")
	_check(button.get_index() == button.get_parent().get_child_count() - 1, "pause is the rightmost footer action")
	_check(root.get_visible_rect().encloses(button.get_global_rect()), "pause fits inside viewport")
	await _click(button)
	_check(paused and hud._manual_paused and button.text == str(hud.hud_config.pause.resume), "real click pauses and exposes continue")
	_check(not game.bot.is_started(), "pause is not the player's first gameplay action")
	await _click(button)
	_check(not paused and not hud._manual_paused, "real click resumes while HUD stays processable")
	# Small controlled queues; leave the production defaults untouched.
	game.state.config.rules.initial.groups = [{"employee": 1, "work": 8}, {"slack": 1}]
	game._new_game()
	game._start_opponent_after_action(0)
	game.state.advance(10.0)
	game.board.sync_state(game.state)
	for event in game.state.drain_events(): game._present(event)
	var slack := -1
	for id in game.state.cards:
		if game.state.cards[id].owner == 0 and game.state.cards[id].type == "slack": slack = id
	game._selected_tool = slack
	game._update_hud()
	await _frames(2)
	await _click(button)
	_check(paused and game._drawer_input_blocked(), "manual pause blocks table and tool activation")
	var snapshot := _snapshot()
	await create_timer(0.22, true).timeout
	var after := _snapshot()
	for key in snapshot: _check(snapshot[key] == after[key], "pause freezes " + key)
	var status: String = game.state.cards[slack].status
	game._activate(slack, int(game.state.cards[slack].group))
	_check(game.state.cards[slack].status == status, "drag activation handler cannot activate tools while paused")
	if OS.has_environment("WORK_PAUSE_CAPTURE"):
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("res://reports")
		root.get_texture().get_image().save_png("res://reports/manual-pause.png")
	# Drawer must not erase a manual pause when it opens again.
	hud.drawer_window.collapse_now()
	await _frames(2)
	hud.drawer_window.pin()
	await _frames(3)
	_check(paused and hud._manual_paused and hud.drawer_window.is_expanded(), "reopening preserves manual pause")
	_check(game.state.time == snapshot.time, "fold and reopen do not advance the clock")
	await _click(button)
	await create_timer(0.06, true).timeout
	_check(not paused and game.state.time > snapshot.time, "resume continues work and BOT")
	_check(game.state.time - snapshot.time < 0.20, "resume does not catch up paused wall time")
	await _click(button)
	await _click(hud.btn_resign)
	_check(paused and hud._manual_paused and game.state.winner < 0, "arming resignation preserves the paused game")
	await _click(hud.btn_resign)
	_check(not paused and not hud._manual_paused and game.state.winner == 1, "confirming resignation unpauses result presentation")
	game._rematch()
	_check(not game.bot.is_started(), "restart returns to waiting for the first action")
	for layout in [[Vector2i(1440, 810), 2.0], [Vector2i(960, 540), 2.0]]:
		root.size = layout[0]
		hud.drawer_ui_scale = float(layout[1])
		hud._ui_scale = float(layout[1])
		hud.relayout()
		await _frames(3)
		_check(root.get_visible_rect().encloses(button.get_global_rect()), "pause remains inside small/high-scale layout " + str(layout))
		await _click(button)
		_check(paused and hud._manual_paused, "pause remains clickable " + str(layout))
		await _click(button)
		_check(not paused, "continue remains clickable " + str(layout))
	game.state.winner = 0
	hud.refresh(game.state)
	_check(button.disabled, "finished game cannot pause before result presentation")
	game.queue_free()
	await _frames(3)
	for message in failures: push_error(message)
	print("MANUAL_PAUSE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _snapshot() -> Dictionary:
	var result := {"time": game.state.time, "conveyor": game.state.conveyor_progress,
		"bot_schedule": game.bot._next_think, "tasks": game.state.tasks.duplicate(true),
		"cards": game.state.cards.duplicate(true), "offers": game.state.offers.duplicate(true),
		"effects": game.effects.items.duplicate(true), "cash_flights": game.board._cash_flights.duplicate(true)}
	for id in game.board.by_uid:
		var card: Node = game.board.by_uid[id]
		result["position_" + str(id)] = card.position
		result["animation_" + str(id)] = card.illustration_time()
	return result

func _click(control: Control) -> void:
	var at := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	await _frames(2)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = down
		root.push_input(event, true)
		await _frames(2)

func _frames(count: int) -> void:
	for index in count: await process_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
