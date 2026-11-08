extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var cfg := OffWorkConfig.new()
	cfg.rules.initial.groups = [{"employee": 1, "work": 60}]
	cfg.rules.initial.money = 0
	cfg.rules.bot.enabled = false
	var state := OffWorkState.new(cfg)
	state.new_game(31)
	OffWorkCardDB.configure(cfg)
	var host := Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	var board := OffWorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	board.sync_state(state)
	await create_timer(0.3).timeout
	for presenter in [board, board.enemy_board]:
		var group: Dictionary = presenter.groups[0]
		_check(group.cards[presenter._top_index(group)].def_id == "work", "ordinary personnel-work pile exposes work on top for both players")
	var boss := state.add_card("boss", 0)
	var cash := state.add_card("money", 0)
	state.cards[cash].amount = 21
	state.move_cards([cash], int(state.cards[boss].group))
	state.advance(cfg.number("recruitment", "seconds") * 0.5)
	board.sync_state(state)
	var face: OffWorkCard = board.by_uid[boss]
	_check(face._task_progress.visible and face._task_progress_phase == "recruitment" and is_equal_approx(face._task_progress_value, 0.5), "boss exposes an independent halfway recruitment bar")
	_check(is_equal_approx(preload("res://engine/off_work_progress_clock.gd").remaining(state, boss, "recruitment", 0.5), cfg.number("recruitment", "seconds") * 0.5), "debug recruitment clock follows actual reserved batch")
	state.drain_events()
	state.advance(cfg.number("recruitment", "seconds") * 0.5)
	board.sync_state(state)
	var work_count := 0
	var recruits: Array = []
	for event in state.drain_events():
		if event.kind == "work_complete": work_count += event.ids.size()
		if event.kind == "recruitment_complete": recruits = event.person_ids
		board.play_event(event)
	_check(recruits.size() == 4 and state.cards[cash].amount == 1, "21 cash creates four actual employees with one cash left")
	_check(recruits.all(func(id): return board._delivery_flights.has(id)), "all recruits visibly fly from boss into their separate output pile")
	_check(not face._task_progress.visible, "completed boss batch clears its progress bar")
	_check(board._paper_disposal.emitted + board._paper_disposal.queued_count() == work_count, "every actual completed work queues exactly one paper")
	var texture: Texture2D = board.by_uid[state.group_work(1)[0]]._icon.texture
	board._paper_disposal.clear()
	for index in 100: board._paper_disposal.enqueue(texture, Vector3.ZERO, 0)
	var peak := 0
	for frame in 600:
		board._advance_paper_disposal(1.0 / 60.0)
		peak = maxi(peak, board._paper_disposal.active.size())
	_check(peak <= int(board._settings.paper_disposal.max_concurrent), "mass completion keeps its configured active mesh limit")
	_check(board._paper_disposal.emitted == 100 and board._paper_disposal.completed == 100 and board._paper_disposal.queued_count() == 0, "bounded queue eventually throws every paper without truncation")
	# A large real outsourcing batch exercises removed-card texture capture.
	var tool := state.add_card("outsource", 0)
	var gid := int(state.cards[tool].group)
	var payment := state.add_card("money", 0, gid)
	state.cards[payment].amount = 30
	var works := state.group_work(1).slice(0, 30)
	state.move_cards(works, gid)
	board.sync_state(state)
	state.drain_events()
	state.advance(cfg.number("outsource", "seconds"))
	board.sync_state(state)
	board._paper_disposal.clear()
	for event in state.drain_events():
		if event.kind == "outsource":
			board.play_event(event)
	_check(board._paper_disposal.emitted + board._paper_disposal.queued_count() == 30, "outsourcing also crumples every consumed work icon")
	board.reset_view()
	_check(board._paper_disposal.active.is_empty() and board._paper_disposal.queued_count() == 0, "reset removes meshes and pending papers before switching/tutorial restore")
	host.queue_free()
	await process_frame
	for message in failures: printerr("FAIL ", message)
	print("WORK_DISPOSAL_PRESENTATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
