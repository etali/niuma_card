extends "res://tests/realtime/test_work_ui.gd"

var belt: Node3D

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.set_drawer_suspended(true)
	board = main.board
	board.touch_mode = true
	state = main.state
	state.config.rules.bot.enabled = false
	belt = main.conveyor
	await _settle()
	_check(belt.carriers.size() == 6, "six moving carriers replace static purchase grooves")
	for index in 6: _check(not main.get_node("MarketSlot_%d" % index).visible, "original static groove %d is hidden" % index)
	_links("opening")
	await _capture("opening")
	var bought: Dictionary = state.offers[1].duplicate()
	var old_carrier: Node3D = belt.carriers[1]
	var old_position: Vector3 = old_carrier.global_position
	var market: CardEntity = board.offers_by_id[int(bought.id)]
	var tag: Node3D = market.get_meta("price_tag").get_ref()
	var click_at := board.camera.unproject_position(tag._paper.global_position)
	await _button(click_at, true)
	_check(board._press_snap.get("price_tag", false) and not board._press_snap.get("price_cancelled", false), "real pointer press captures the conveyor price tag")
	await _button(click_at, false)
	await _settle()
	_check(state.offers[1].is_empty() and belt.carriers[1] == old_carrier, "price purchase leaves the same empty carrier")
	_check(old_carrier.get_node("MovingGroove").is_visible_in_tree(), "purchased groove stays visible")
	await _capture("empty-slot")
	state.advance(state.config.number("conveyor", "interval_seconds"))
	board.sync_state(state)
	_check(belt.carriers[0] == old_carrier, "empty carrier participates in the next real belt step")
	_check(old_carrier.global_position.distance_to(old_position) < 0.001, "step begins from the current groove position")
	var top_y: float = board.offers_by_id.values()[0].global_position.y
	for frame in 6:
		await create_timer(0.035).timeout
		_links("rolling-%d" % frame)
		if frame in [1, 4]: await _capture("rolling-%d" % frame)
	_check(old_carrier.global_position.x < old_position.x, "empty groove visibly moves left")
	_check(is_equal_approx(board.offers_by_id.values()[0].global_position.y, top_y), "new and retained cards stay on the belt plane")
	var frozen: Array = belt.carriers.map(func(c): return c.global_position)
	paused = true
	await create_timer(0.15, true).timeout
	for index in belt.carriers.size():
		_check(belt.carriers[index].global_position.distance_to(frozen[index]) < 0.001, "pause freezes carrier %d" % index)
	_links("paused")
	paused = false
	await _settle()
	# Two updates before the first transition finishes must retarget the same
	# visual carrier without moving its card to a separately animated origin.
	var retained: Node3D = belt.carriers[4]
	state.advance(state.config.number("conveyor", "interval_seconds"))
	board.sync_state(state)
	await create_timer(0.04).timeout
	var midpoint: Vector3 = retained.global_position
	state.advance(state.config.number("conveyor", "interval_seconds"))
	board.sync_state(state)
	_check(retained.global_position.distance_to(midpoint) < 0.001, "rapid step retargets from the current pose without teleporting")
	_links("rapid-start")
	await create_timer(0.12).timeout
	_links("rapid-mid")
	await _capture("rapid")
	await _settle()
	state.advance(state.config.number("conveyor", "interval_seconds") * 3.0)
	board.sync_state(state)
	for frame in 4:
		_links("coarse-%d" % frame)
		await create_timer(0.08).timeout
	await _capture("coarse")
	await _settle()
	_check(belt.departing.is_empty() and belt._exiting.is_empty(), "departed card, tag and groove are removed together")
	for size in [Vector2i(960, 540), Vector2i(1440, 810)]:
		root.size = size
		main.hud.relayout()
		await _settle()
		_links("window-%s" % size)
		for carrier in belt.carriers:
			_check(main.hud.content_rect().has_point(board.camera.unproject_position(carrier.global_position)), "moving groove fits %s" % size)
	main._new_game()
	await _settle()
	_check(belt.carriers.size() == 6 and belt.departing.is_empty(), "restart resets all six grooves without leftover departures")
	_links("restart")
	await _capture("restart")
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("MOVING_CONVEYOR %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _links(label: String) -> void:
	var offset: Vector3 = board._setting_vector("price_tag_offset")
	var visible_x: Array[float] = []
	for carrier in belt.carriers + belt.departing:
		var visible_card: CardEntity = belt._card_of(carrier)
		if is_instance_valid(visible_card) and visible_card.visible: visible_x.append(visible_card.global_position.x)
	visible_x.sort()
	var regular_spacing := true
	for index in range(1, visible_x.size()):
		regular_spacing = regular_spacing and visible_x[index] - visible_x[index - 1] >= float(belt._pitch) - 0.001
	_check(regular_spacing, "%s even departing cards keep the belt pitch and cannot stack their prices" % label)
	for index in state.offers.size():
		if state.offers[index].is_empty(): continue
		var id: int = int(state.offers[index].id)
		var card: CardEntity = board.offers_by_id[id]
		var carrier: Node3D = belt.carriers[index]
		_check(card.global_position.distance_to(carrier.global_position) < 0.00001, "%s card and groove have exactly one trajectory %d" % [label, index])
		var tag: Node3D = board._prices[id]
		_check(tag.global_position.distance_to(card.to_global(offset)) < 0.00001, "%s price follows the same carrier %d" % [label, index])
		var point: Vector2 = board.camera.unproject_position(tag._paper.global_position)
		_check(tag.hit_test(point, board.camera) == card.is_visible_in_tree(), "%s price input matches visible boundary %d" % [label, index])
		if card.visible:
			_check(card.global_position.x + CardEntity.CARD_SIZE.x * 0.5 < float(belt._right), "%s visible offer stays before dismissal entrance %d" % [label, index])
		else:
			_check(card.collision_layer == 0 and card.collision_mask == 0 and not card.input_ray_pickable,
				"%s hidden offer cannot intercept input %d" % [label, index])
			_check(board._market_card_near(card.global_position) != card, "%s cash drag ignores the hidden arrival %d" % [label, index])

func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	var pointer_event := InputEventMouseMotion.new()
	pointer_event.position = Vector2(20, 430)
	pointer_event.global_position = pointer_event.position
	root.push_input(pointer_event)
	await process_frame
	RenderingServer.force_draw()
	root.get_texture().get_image().save_png("res://reports/conveyor-%s.png" % label)
