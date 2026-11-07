extends SceneTree

## Shipped opening and an actual price-tag mouse click. Waiting screenshots
## perform no player commands, so the opponent must remain idle on its own.
var game: Node

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.hud.set_process(false)
	# Feed deterministic Viewport mouse events through the original pointer path.
	game.board.touch_mode = true
	game.hud._detail.hide()
	await create_timer(0.7).timeout
	await _capture("opening")
	await create_timer(4.4).timeout
	await _capture("moving")
	await create_timer(5.5).timeout
	var waiting: bool = not game.bot.is_started() and game.state.people_count(1) == 1 and game.state.work_count(1) == game.state.work_count(0) and game.state.work_count(1) == _initial_work()
	print("MARKET_IDLE ", waiting, " time=", game.state.time)
	await _capture("waiting")
	var offer_id := -1
	for offer in game.state.offers:
		if not offer.is_empty() and int(offer.price) <= game.state.money(0):
			offer_id = int(offer.id)
			break
	if offer_id < 0:
		printerr("No affordable offer for the real-click review")
		quit(1)
		return
	var card: OffWorkCard = game.board.offers_by_id[offer_id]
	var tag: Node3D = card.get_meta("price_tag").get_ref()
	var at: Vector2 = game.camera.unproject_position(tag._paper.global_position)
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	await process_frame
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		click.position = at
		click.global_position = at
		root.push_input(click, true)
		await process_frame
	await create_timer(0.6).timeout
	var started: bool = game.bot.is_started() and not game.board.offers_by_id.has(offer_id)
	print("MARKET_PURCHASE_START ", started)
	await _capture("started")
	var dismissed: bool = await _dismiss_review()
	quit(0 if waiting and started and dismissed else 1)

func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png("res://reports/market-%s.png" % label)
	print("MARKET_REVIEW ", label, " result=", result)

func _initial_work() -> int:
	var count := 0
	for group in game.state.config.rules.initial.groups:
		count += int(group.get("work", 0))
	return count

func _dismiss_review() -> bool:
	# Freeze only rule advancement to capture the real mouse dismissal/refund.
	game.set_process(false)
	game.board.touch_mode = true
	var employee := -1
	for uid in game.state.cards:
		var record: Dictionary = game.state.cards[uid]
		if int(record.owner) == 0 and str(record.type) == "employee":
			employee = int(uid)
			break
	if employee < 0: return false
	var card: OffWorkCard = game.board.by_uid[employee]
	var start := Vector2.INF
	for z in [-0.4, 0.0, 0.4]:
		var point: Vector2 = game.camera.unproject_position(card.global_position + Vector3(0, CardEntity.Y_TEXT, z * CardEntity.CARD_SIZE.z))
		if game.board._pick_card(point) == card and game.hud.content_rect().has_point(point):
			start = point
			break
	if start == Vector2.INF: return false
	var before: int = game.state.money(0)
	var refund: int = game.state.config.cards.employee.refund
	await _mouse_button(start, true)
	var pointer := start + Vector2(10, 0)
	await _mouse_move(pointer, Vector2(10, 0))
	var facility: Vector3 = game.board.pawn_pos
	var end: Vector2 = game.camera.unproject_position(Vector3(facility.x - game.board._grab_offset.x, Board.DRAG_HEIGHT, facility.z - game.board._grab_offset.z))
	for step in range(1, 9):
		var point := start.lerp(end, float(step) / 8.0)
		await _mouse_move(point, point - pointer)
		pointer = point
	await _capture("dismiss-held")
	await _mouse_button(end, false)
	game._process(0.0)
	await create_timer(0.18).timeout
	await _capture("dismiss-cash")
	await create_timer(0.9).timeout
	await _capture("dismissed")
	var ok: bool = not game.state.cards.has(employee) and game.state.money(0) == before + refund and not game.board.is_dragging()
	print("MARKET_DISMISS ", ok, " refund=", game.state.money(0) - before)
	return ok

func _mouse_button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event, true)
	await process_frame

func _mouse_move(point: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event, true)
	await process_frame
