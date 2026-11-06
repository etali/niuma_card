extends "res://tests/realtime/test_work_hud.gd"

var checks := 0
var clock = preload("res://engine/work_progress_clock.gd")

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-debug-options-%d" % OS.get_process_id())
	root.size = Vector2i(1440, 810)
	root.gui_embed_subwindows = true
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(8)
	game.set_process(false)
	game.audio.muted = true
	game.sfx.set_drawer_suspended(true)
	hud = game.hud
	game.board.touch_mode = true
	var board: WorkBoard = game.board
	var popup: PopupMenu = hud._menu.get_popup()
	var menu_id := int(hud.hud_config.debug_mode.menu_id)
	_check(not board.get_debug_mode(), "Debug defaults off")
	_check(popup.is_item_checkable(popup.get_item_index(menu_id)), "options exposes a checkable Debug mode")
	_fixture([{"leader": 1, "employee": 2, "work": 40}])
	await _frames(3)
	var top := _bar(1, "work")
	_check(top != null and not top._debug_timer.visible, "valid group has progress but no numeric timer by default")
	# Deliberately do not save this unrelated live edit.
	board.set_snap_hit_fraction(0.25)
	await _open_menu(menu_id)
	_check(board.get_debug_mode() and popup.is_item_checked(popup.get_item_index(menu_id)), "real options click enables and checks Debug")
	_check(not hud._utility.visible, "Debug toggle does not open an unrelated options page")
	_check(top._debug_timer.is_visible_in_tree(), "enabling Debug immediately reveals the existing bar's countdown")
	var fresh := WorkBoard.new()
	_check(fresh.get_debug_mode() and is_equal_approx(fresh.get_snap_hit_fraction(), 0.75), "Debug preference persists without saving unfinished absorption edit")
	fresh.free()
	_advance(4.0)
	_expect_timer(top, 6.0, "shared group clock counts two employees once")
	_check(top.type == "leader" and float(top.record.total) == 0.0, "visible leader uses the group's real clock instead of its own empty total")
	var overtime: int = game.state.add_card("overtime", 0)
	game.state.move_cards([overtime], 1)
	board.sync_state(game.state)
	_expect_timer(top, 5.0, "adding overtime recomputes remaining seconds at the new speed without resetting progress")
	if OS.get_environment("WORK_DEBUG_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await create_timer(0.6).timeout
		RenderingServer.force_draw(false)
		_check(root.get_texture().get_image().save_png("res://reports/debug-work.png") == OK, "GPU shared work countdown screenshot saved")
	_advance(1.0)
	_expect_timer(top, 4.0, "accelerated countdown consumes one real second per second")
	var extra: int = game.state.add_card("overtime", 0)
	game.state.move_cards([extra], 1)
	board.sync_state(game.state)
	_expect_timer(top, 4.0 / 1.2, "stacked overtime uses multiplicative instantaneous group speed")
	board.toggle_compact(top)
	board.sync_state(game.state)
	top = _bar(1, "work")
	_check(top != null and top.type == "work", "expanded stack projects Debug onto the new visible work card")
	_expect_timer(top, 4.0 / 1.2, "expanding a stack preserves its authoritative clock")
	await _click(hud.btn_pause)
	_check(paused, "real pause button pauses simulation")
	game.set_process(true)
	var frozen_time: float = game.state.time
	var frozen_text := top._debug_timer.text
	await create_timer(0.15, true).timeout
	_check(game.state.time == frozen_time and top._debug_timer.text == frozen_text, "paused Debug countdown freezes with the simulation")
	game.set_process(false)
	await _click(hud.btn_pause)
	_check(not paused, "real pause button resumes simulation")

	_fixture([{"leader": 1, "employee": 2, "work": 40}])
	_advance(3.0)
	var host_group: int = game.state.create_group(1)
	game.state.add_card("leader", 1, host_group)
	var meeting: int = game.state.add_card("meeting", 1)
	game.state.move_cards([meeting], host_group)
	board.sync_state(game.state)
	var meeting_card: WorkCard = board.by_uid[meeting]
	_expect_timer(meeting_card, 12.0, "meeting reads its actual active countdown")
	_advance(2.0)
	_expect_timer(meeting_card, 10.0, "meeting active countdown advances")
	top = _bar(1, "work")
	_check(top != null and top._task_progress_paused, "meeting suspends the source work group bar")
	if top != null:
		_expect_timer(top, 7.0, "meeting pauses preserve the work group's active-time remainder")
		_check(top._debug_timer.text.begins_with("暂停"), "suspended work countdown is marked paused")
	_advance(10.0)
	_check(meeting_card._task_progress_phase == "recovering", "meeting switches to reverse cooldown")
	_expect_timer(meeting_card, 24.0, "reverse cooldown starts with its actual full duration")
	_advance(4.0)
	_expect_timer(meeting_card, 20.0, "reverse cooldown counts down independently of fill direction")
	_check(is_equal_approx(meeting_card.task_progress_display_value(), 20.0 / 24.0), "cooldown's reverse fill agrees with numeric time")

	_fixture([{"employee": 1, "work": 40}])
	var transfer: int = game.state.add_card("transfer", 0)
	game.state.move_cards([transfer], 1)
	_advance(3.0)
	top = _bar(1, "transfer")
	_expect_timer(top, 7.0, "continuous transfer uses the group's shared ten-second cycle")
	_fixture([{"employee": 1, "work": 40}])
	var coffee: int = game.state.add_card("coffee", 0)
	game.state.move_cards([coffee], 1)
	_advance(2.0)
	_expect_timer(_bar(1, "coffee"), 3.0, "visible upgrading staff shows the real five-second coffee countdown")
	_check(is_equal_approx(board.by_uid[coffee]._debug_remaining, 3.0), "buried coffee retains the same material countdown without drawing through the stack")
	_fixture([{"employee": 1, "work": 40}])
	var slack: int = game.state.add_card("slack", 0, 1)
	_check(game.state.activate(slack, 1), "slack fixture starts a real task")
	_advance(7.0)
	for card: WorkCard in board.by_uid.values():
		if card.group_id == 1 and card._task_progress_active:
			_expect_timer(card, 7.0, "slack personnel and projected bars share the real fourteen-second task")
	_advance(7.0)
	var fresh_coffee := -1
	for id in game.state.cards:
		if game.state.cards[id].type == "coffee" and int(game.state.cards[id].owner) == 0: fresh_coffee = int(id)
	_check(fresh_coffee >= 0 and game.state.cards[fresh_coffee].status == "ready", "slack produces a separate immediately usable coffee")
	_check(not board.by_uid[fresh_coffee]._task_progress.visible and not board.by_uid[fresh_coffee]._debug_timer.is_visible_in_tree(), "new coffee has neither a progress bar nor a Debug countdown")
	_advance(2.0)
	_check(game.state.cards[fresh_coffee].status == "ready" and is_zero_approx(game.state.cards[fresh_coffee].remaining), "stored fresh coffee has no delayed readiness transition")
	_check(not board.by_uid[fresh_coffee]._task_progress.visible and not board.by_uid[fresh_coffee]._debug_timer.is_visible_in_tree(), "Debug continues to hide timers for unused coffee")

	_fixture([{"outsource": 1, "work": 40}, {"employee": 1}])
	var outsource: int = game.state.group_cards(1)[0]
	for index in 3: game.state.add_card("money", 0, 1)
	_advance(4.0)
	var outsource_card: WorkCard = board.by_uid[outsource]
	_expect_timer(outsource_card, 6.0, "outsource uses its real batch clock")
	# Add work and money while a batch is active; timing must not restart.
	game.state.add_card("work", 0, 1)
	game.state.add_card("money", 0, 1)
	board.sync_state(game.state)
	_expect_timer(outsource_card, 6.0, "dynamic batch inputs preserve the current countdown")
	_advance(6.0)
	_expect_timer(outsource_card, 18.0, "outsource switches to its eighteen-second reverse cooldown")
	_advance(3.0)
	_expect_timer(outsource_card, 15.0, "outsource cooldown uses actual remaining time")
	if OS.get_environment("WORK_DEBUG_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		game.state.move_cards([outsource], -1)
		var employee: int = game.state.group_people(2)[0]
		game.state.move_cards([employee], 1)
		_advance(4.0)
		await create_timer(0.6).timeout
		RenderingServer.force_draw(false)
		_check(root.get_texture().get_image().save_png("res://reports/debug-mode.png") == OK, "GPU Debug screenshot saved")
	await _open_menu(menu_id)
	_check(not board.get_debug_mode(), "second real options click disables Debug")
	for card: WorkCard in board.by_uid.values():
		_check(not card._debug_timer.visible, "disabling Debug immediately hides all countdown labels")
	_fixture([{"employee": 1, "work": 1}])
	game.state.add_card("work", 1, 2)
	board.set_debug_mode(true)
	_advance(2.0)
	_expect_timer(_bar(1, "work"), 8.0, "final work exposes the real pre-victory countdown")
	_advance(8.0)
	_check(game.state.winner == 0, "real final work settlement wins while the opponent still has work")
	for event in game.state.drain_events():
		if event.kind == "win": board.play_event(event)
	for card: WorkCard in board.by_uid.values():
		_check(not card._debug_timer.visible, "terminal presentation clears Debug countdowns on both tables")
	_readonly_preferences()
	game.queue_free()
	await _frames(3)
	print("DEBUG_MODE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(definitions: Array) -> void:
	var config := WorkConfig.new()
	config.rules.initial.groups = definitions
	config.rules.initial.money = 0
	config.rules.bot.enabled = false
	_check(config.validate(), "Debug fixture uses valid game configuration")
	var state := WorkState.new(config)
	state.new_game(273)
	game.state = state
	hud.state = state
	WorkCardDB.configure(config)
	game.board.reset_view()
	game.board.sync_state(state)
	hud.refresh(state)

func _advance(seconds: float) -> void:
	game.state.advance(seconds)
	game.board.sync_state(game.state)
	hud.refresh(game.state)

func _bar(group: int, phase: String) -> WorkCard:
	for card: WorkCard in game.board.by_uid.values():
		if card.group_id == group and card._task_progress.is_visible_in_tree() and card._task_progress_phase == phase: return card
	return null

func _expect_timer(card: WorkCard, expected: float, message: String) -> void:
	var ok := card != null and card._debug_timer.is_visible_in_tree() and is_equal_approx(card._debug_remaining, expected)
	_check(ok, message)
	if not ok and card != null:
		printerr("TIMER %s phase=%s remaining=%s expected=%s visible=%s group=%s" % [card.type, card._task_progress_phase, card._debug_remaining, expected, card._debug_timer.is_visible_in_tree(), card.group_id])

func _readonly_preferences() -> void:
	var original := OS.get_environment("WORK_DATA_DIR")
	var unused := original + "-readonly"
	OS.set_environment("WORK_DATA_DIR", unused)
	var board := WorkBoard.new(false)
	_check(not board.get_debug_mode(), "readonly preview defaults Debug off")
	_check(board.set_debug_mode(true) and board.get_debug_mode(), "readonly preview supports temporary Debug inspection")
	_check(not board.set_debug_mode(true, true), "readonly preview cannot persist even when requested")
	_check(not DirAccess.dir_exists_absolute(unused), "readonly preview never creates a settings directory")
	board.free()
	OS.set_environment("WORK_DATA_DIR", original)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		printerr("FAIL " + message)
