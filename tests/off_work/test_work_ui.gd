extends SceneTree

## Original Board input -> adapter -> real OffWorkState, using Viewport events.
var main: Node
var board: Board
var state: OffWorkState
var pointer := Vector2.ZERO
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1600, 900)
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
	state.config.rules.initial.groups = [{"employee": 1, "work": 4}, {"employee": 1, "work": 4}, {"overtime": 1}, {"coffee": 1}]
	state.config.rules.initial.money = 16
	main._new_game()
	await _settle()
	_check(board.get_script().get_base_script().resource_path == "res://scenes/board.gd", "OffWorkBoard inherits original Board")
	await _purchase()
	await _stacking()
	await _coffee_grouping()
	await _coffee_lesson_input()
	main.queue_free()
	await process_frame
	for message in failures: printerr("FAIL ", message)
	print("WORK_UI_INPUT ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks; original Board + Viewport.push_input)")
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> bool:
	checks += 1
	if not ok: failures.append(message)
	return ok

func _purchase() -> void:
	var offer: Dictionary = state.offers[0].duplicate()
	var card: CardEntity = board.offers_by_id[int(offer.id)]
	var price_tag: Node3D = card.get_meta("price_tag").get_ref()
	var at := board.camera.unproject_position(price_tag._paper.global_position)
	var before: int = state.people_count(0)
	var cash: int = state.money(0)
	await _click(at)
	_check(state.people_count(0) == before + 1, "original price tag click buys real personnel")
	_check(state.money(0) == cash - int(offer.price), "original purchase route charges once")
	_check(state.offers[0].is_empty(), "conveyor purchase leaves an empty slot")
	for mode in ["reverse", "cash"]:
		var index := 1 if mode == "reverse" else 2
		var next: Dictionary = state.offers[index].duplicate()
		var market: CardEntity = board.offers_by_id[int(next.id)]
		var wallet: CardEntity = board.by_uid[_owned("money")]
		var money_before: int = state.money(0)
		var wallet_group: int = state.cards[wallet.uid].group
		var payment_ids: Array = state.group_cards(wallet_group)
		var expected_remaining: Array = payment_ids.slice(int(next.price))
		if mode == "reverse":
			await _drag(market, _point(wallet))
		else:
			await _drag(wallet, _point(market))
		_check(state.offers[index].is_empty(), "original %s drag purchases offer" % mode)
		_check(state.money(0) == money_before - int(next.price), "%s drag charges actual amount once" % mode)
		_check(state.group_cards(wallet_group) == expected_remaining and expected_remaining.all(func(uid): return state.cards[uid].amount == 1), "%s drag consumes the paid unit cards and preserves exact remaining identities" % mode)


func _stacking() -> void:
	var employee := _owned("employee")
	var inner := _owned("overtime")
	var gid: int = state.cards[employee].group
	var group: Dictionary = board.group_of(board.by_uid[employee])
	var top: CardEntity = group.cards[0]
	await _drag(board.by_uid[inner], _point(top))
	if not _check(state.cards[inner].group == gid, "original snapping combines tool with real work group"): return
	group = board.group_of(board.by_uid[employee])
	var before: bool = group.get("compact", false)
	await _click(_point(group.cards[0]), true)
	_check(bool(group.compact) != before, "double click changes original compact state")
	_check(state.cards[inner].group == gid, "double click does not mutate real group membership")
	if group.compact:
		await _click(_point(group.cards[0]), true)
	if not _check(not bool(group.compact), "pile expanded before splitting"): return
	# Middle-card drag must take exactly the original suffix; no Shift modifier.
	var members: Array = group.cards.duplicate()
	var cut := members.size() - 2
	var suffix: Array = members.slice(cut).map(func(c): return c.uid)
	var at := _empty_point()
	if not _check(at != Vector2.INF, "empty tabletop destination is available"): return
	await _drag(members[cut], at, true)
	var split: int = state.cards[suffix[0]].group
	_check(split != gid, "middle-card drag creates a separate real group")
	var actual: Array = state.group_cards(split)
	actual.sort(); suffix.sort()
	_check(actual == suffix, "middle-card drag moves the complete suffix, matching original Board")
	_check(state.group_cards(gid).size() == cut, "source group keeps precisely the prefix")
	# Moving the head preserves the full group and task progress.
	state.advance(1.0)
	board.sync_state(state)
	await _settle()
	group = board.group_of(board.by_uid[employee])
	if not group.compact: await _click(_point(group.cards[0]), true)
	var expected: Array = state.group_cards(gid).duplicate()
	var progress: Dictionary = {}
	for id in state.group_work(gid): progress[id] = state.cards[id].progress
	await _drag(group.cards[0], _empty_point(), true)
	var after: Array = state.group_cards(int(state.cards[employee].group))
	expected.sort(); after.sort()
	_check(after == expected, "compact head moves the whole original pile")
	var retained := true
	for id in progress:
		retained = retained and is_equal_approx(state.cards[id].progress, progress[id])
	_check(retained, "spatial movement preserves work progress")
	var positions: Dictionary = {}
	for id in after: positions[id] = board.rest_pos(board.by_uid[id])
	for iteration in 3: board.sync_state(state)
	await _settle()
	for id in after:
		_check(board.rest_pos(board.by_uid[id]).distance_to(positions[id]) < 0.02, "periodic state sync preserves original placement %d" % id)

func _coffee_grouping() -> void:
	state.config.rules.initial.groups = [{"work": 12}, {"employee": 1}, {"coffee": 1}]
	main._new_game()
	await _settle()
	var worker := _owned("employee")
	var coffee := _owned("coffee")
	var job := _owned("work")
	var work_group: int = state.cards[job].group
	await _drag(board.by_uid[worker], _point(board.by_uid[job]))
	await _drag(board.by_uid[coffee], _point(board.by_uid[worker]))
	_check(state.cards[coffee].group == work_group and state.tasks[worker].kind == "work"
		and state.cards[coffee].status == "ready", "real pointer input leaves personnel, work and coffee processing work only")
	state.advance(state.config.coffee_seconds("employee"))
	board.sync_state(state)
	await _settle()
	_check(state.cards.has(coffee) and state.cards[worker].type == "employee"
		and state.group_work_progress(work_group) > 0.0, "mixed pile advances work while retaining unconsumed coffee")
	var pile: Dictionary = board.group_of(board.by_uid[worker])
	if pile.compact: await _click(_point(pile.cards[0]), true)
	await _drag(board.by_uid[coffee], _empty_point(), true)
	await _drag(board.by_uid[job], _empty_point(), true)
	_check(state.cards[worker].group != state.cards[job].group and state.group_work(state.cards[worker].group).is_empty(),
		"dragging the work suffix away leaves personnel in a separate pile")
	await _drag(board.by_uid[coffee], _point(board.by_uid[worker]))
	_check(state.tasks[worker].kind == "coffee" and state.cards[coffee].status == "active",
		"coffee dragged to separated personnel starts the real coffee timer")
	var work_before: int = state.work_count(0)
	state.advance(state.config.coffee_seconds("employee"))
	board.sync_state(state)
	_check(state.cards[worker].type == "grinder" and not state.cards.has(coffee)
		and state.work_count(0) == work_before, "separate coffee pile raises intensity without consuming work")

func _coffee_lesson_input() -> void:
	main.begin_practice("upgrade")
	state = main.state
	await _settle()
	var worker := _owned("employee")
	var coffee := _owned("coffee")
	var work_group: int = state.cards[worker].group
	await _drag(board.by_uid[worker], _empty_point(), true)
	main._process(0.01)
	if not _check(main.lesson.step == 1 and state.cards[worker].group != work_group
		and state.group_work(state.cards[worker].group).is_empty(), "real lesson pointer drag takes only the employee and completes its first step"): return
	await _drag(board.by_uid[coffee], _point(board.by_uid[worker]))
	main._process(0.01)
	_check(main.lesson.step == 2 and state.tasks.get(worker, {}).get("kind") == "coffee",
		"real lesson coffee drag starts the separate group's timer")
	main._process(state.config.coffee_seconds("employee"))
	_check(main.lesson.complete() and state.cards[worker].type == "grinder",
		"the coffee lesson can be completed through real pointer inputs and the real timer")
	main.finish_practice()
	state = main.state

func _owned(kind: String) -> int:
	for id in state.cards:
		if state.cards[id].owner == 0 and state.cards[id].type == kind: return id
	return -1

func _owned_ids(kind: String) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].owner == 0 and state.cards[id].type == kind)

func _point(card: CardEntity) -> Vector2:
	for z in [-0.40, 0.0, 0.40]:
		for x in [0.0, -0.35, 0.35]:
			var at := board.camera.unproject_position(card.global_position + Vector3(x * CardEntity.CARD_SIZE.x, CardEntity.Y_TEXT, z * CardEntity.CARD_SIZE.z))
			if main.hud.content_rect().has_point(at) and board._pick_card(at) == card: return at
	return Vector2.INF

func _empty_point() -> Vector2:
	var safe := board.player_bounds.grow(-1.0)
	for row in 9:
		for col in 18:
			var p := safe.position + Vector2(float(col) / 17.0, float(row) / 8.0) * safe.size
			var world := Vector3(p.x, 0.05, p.y)
			var at := board.camera.unproject_position(world)
			if board._pick_card(at) != null or not main.hud.content_rect().has_point(at): continue
			var clear := true
			for card in board.cards:
				if not card.is_market and Vector2(card.position.x-p.x,card.position.z-p.y).length() < 1.8: clear = false
			if clear: return at
	return Vector2.INF

func _click(at: Vector2, double_click := false) -> void:
	if not _check(at != Vector2.INF, "click target exposes original collider"): return
	await _button(at, true, double_click)
	await _button(at, false)
	await _settle()

func _button(at: Vector2, pressed: bool, double_click := false) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.double_click = double_click
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	pointer = at
	root.push_input(event)
	await process_frame

func _drag(card: CardEntity, destination: Vector2, empty := false) -> void:
	var start := _point(card)
	if not _check(start != Vector2.INF and destination != Vector2.INF, "drag endpoints reachable"): return
	var ground := Vector3.ZERO
	if empty:
		var ray := board.camera.project_ray_normal(destination)
		var origin := board.camera.project_ray_origin(destination)
		ground = origin + ray * ((0.05 - origin.y) / ray.y)
	await _button(start, true)
	if empty:
		var trigger := InputEventMouseMotion.new()
		trigger.position = start + Vector2(10, 0)
		trigger.global_position = trigger.position
		trigger.relative = Vector2(10, 0)
		trigger.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(trigger)
		await process_frame
		destination = board.camera.unproject_position(Vector3(ground.x - board._grab_offset.x, Board.DRAG_HEIGHT, ground.z - board._grab_offset.z))
	for step in range(1, 9):
		var at := start.lerp(destination, float(step) / 8.0)
		var event := InputEventMouseMotion.new()
		event.position = at
		event.global_position = at
		event.relative = at - pointer
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
		pointer = at
		root.push_input(event)
		await process_frame
	_check(board.is_dragging(), "original pointer path starts dragging")
	await _button(destination, false)
	await _settle()
	_check(not board.is_dragging(), "original release clears drag state")

func _settle() -> void:
	await create_timer(0.40).timeout
	await physics_frame
	await process_frame
