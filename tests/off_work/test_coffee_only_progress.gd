extends SceneTree

var checks := 0
var failures: Array[String] = []
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _owned(kind: String) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].owner == 0 and state.cards[id].type == kind)

func _sync() -> void: board.sync_state(state)

func _cup_has_bar(id: int) -> bool:
	var card: OffWorkCard = board.by_uid[id]
	return card._task_progress.visible and card._task_progress_frame.visible

func _run() -> void:
	var cfg := OffWorkConfig.new()
	cfg.rules.initial.groups = [{"work": 200}, {"employee": 1}, {"coffee": 1}, {"coffee": 1}]
	cfg.rules.initial.money = 0
	cfg.rules.bot.enabled = false
	state = OffWorkState.new(cfg)
	state.new_game(20261101)
	OffWorkCardDB.configure(cfg)
	host = Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	_sync()
	var cups := _owned("coffee")
	var bank: int = state.cards[cups[0]].group
	_check(state.move_cards([cups[1]], bank) == bank, "two ready coffees can be stacked for storage")
	_sync()
	_check(state.tasks.is_empty() and cups.all(func(id): return state.cards[id].status == "ready"), "coffee plus coffee starts no task")
	_check(cups.all(func(id): return not _cup_has_bar(id)), "ready coffee-only pile has no progress bars")
	state.advance(3.0)
	_sync()
	_check(_owned("coffee").size() == 2 and cups.all(func(id): return not _cup_has_bar(id)), "ready coffee storage never produces a timer or consumes material")

	# Real slack output arrives ready in this same pure coffee bank. Storage
	# never acquires a timer, including when Debug is enabled.
	var person: int = _owned("employee")[0]
	var team: int = state.cards[person].group
	var slack := state.add_card("slack", 0, team)
	_check(state.activate(slack, team), "real slack production starts")
	state.advance(cfg.number("slack", "seconds"))
	var fresh: int = _owned("coffee").filter(func(id): return not cups.has(id))[0]
	_sync()
	_check(int(state.cards[fresh].group) == bank and state.cards[fresh].status == "ready", "fresh coffee lands immediately ready in existing storage")
	_check(is_zero_approx(state.cards[fresh].remaining) and is_zero_approx(state.cards[fresh].total), "fresh output has no extra preparation clock")
	_check(not _cup_has_bar(fresh) and cups.all(func(id): return not _cup_has_bar(id)), "pure coffee storage has no task-like bar in normal play")
	_check(not state.tasks.values().any(func(task): return task.kind == "coffee"), "coffee storage never starts an employee upgrade task")
	board.set_debug_mode(true)
	_check(not _cup_has_bar(fresh) and not board.by_uid[fresh]._debug_timer.is_visible_in_tree() and board.by_uid[fresh]._debug_remaining < 0.0, "Debug shows no countdown for immediately usable coffee")
	state.advance(2.0)
	_sync()
	_check(state.cards[fresh].status == "ready" and not board.by_uid[fresh]._debug_timer.is_visible_in_tree(), "waiting does not introduce an unnecessary material timer")
	board.set_debug_mode(false)
	_check(not _cup_has_bar(fresh), "turning Debug off keeps coffee storage free of bars")
	state.move_cards([slack], -1)
	_check(state.move_cards([fresh], team, person) == team and state.tasks[person].kind == "coffee", "freshly produced coffee immediately starts a valid employee upgrade")
	state.advance(cfg.coffee_seconds("employee"))
	_sync()
	_check(not state.cards.has(fresh) and state.cards[person].type == "grinder", "only the actual full upgrade bar consumes fresh coffee")

	# Every real employee tier still owns a visible gold bar and consumes the
	# exact materials only on completion; cancelling clears all cup timers.
	for kind in ["employee", "grinder", "workaholic"]:
		var worker := state.add_card(kind, 0)
		var gid: int = state.cards[worker].group
		var cost: int = int(cfg.coffee_upgrade(kind).cost)
		var materials: Array = []
		for _i in cost: materials.append(state.add_card("coffee", 0))
		_check(state.move_cards(materials, gid, worker) == gid, "%s starts with sufficient same-group coffee" % kind)
		state.advance(cfg.coffee_seconds(kind) * 0.5)
		_sync()
		_check(materials.all(func(id): return _cup_has_bar(id) and board.by_uid[id]._task_progress_phase == "coffee" and is_equal_approx(board.by_uid[id]._task_progress_value, 0.5)), "%s real ingredients show the actual half-complete upgrade" % kind)
		_check(state.move_cards(materials, bank) == bank, "%s ingredients may be moved back to storage" % kind)
		_sync()
		_check(not state.tasks.has(worker) and materials.all(func(id): return state.cards[id].status == "ready" and not _cup_has_bar(id)), "%s cancellation removes every old ingredient timer" % kind)
		_check(state.move_cards(materials, gid, worker) == gid, "%s cancelled material can start a fresh valid upgrade" % kind)
		state.advance(cfg.coffee_seconds(kind))
		_sync()
		_check(state.cards[worker].type == cfg.coffee_upgrade(kind).to and materials.all(func(id): return not state.cards.has(id)), "%s full timer consumes exact coffee and changes one tier" % kind)

	host.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("COFFEE_ONLY_PROGRESS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
