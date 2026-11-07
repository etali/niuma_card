extends "res://tests/off_work/test_work_ui.gd"

const Regions = preload("res://scenes/table_regions.gd")

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.set_drawer_suspended(true)
	board = main.board
	board.touch_mode = true
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.money = 100
	main._new_game()
	await _settle()
	# Move a real card into the next reserved employee opening slot. Previously
	# the price-tag purchase returned that slot without checking its occupant.
	var occupant: CardEntity = board.by_uid[_owned("employee")]
	var region := Regions.zone_rect(true, board.drawer_mode, state.offers.size())
	var layout: Dictionary = board._settings.opening_layout
	var slot: Array = layout.person[1]
	var inset := CardEntity.CARD_SIZE.z * 0.5 + float(layout.edge_padding)
	var occupied := board.clamp_player_position(Vector3(float(slot[0]), float(board._settings.rest_y),
		lerpf(region.position.y + inset, region.end.y - inset, float(slot[1]))))
	occupant.global_position = occupied
	board._origin_by_gid[occupant.group_id] = occupied
	board.group_overrides[occupant.group_id] = occupied
	for index in 6:
		state.offers[0] = state._make_offer("employee")
		board.sync_state(state)
		await _settle()
		var before := state.cards.keys()
		var stationary: Dictionary = {}
		var cash_origins: Dictionary = {}
		for uid in before:
			if int(state.cards[uid].owner) != 0: continue
			if state.cards[uid].type != "money":
				stationary[uid] = board.rest_pos(board.by_uid[uid])
				continue
			var cash_gid := int(state.cards[uid].group)
			if cash_origins.has(cash_gid): continue
			var cash_view: Variant = board.group_of(board.by_uid[uid])
			cash_origins[cash_gid] = board.rest_origin(cash_view) if cash_view != null else board.rest_pos(board.by_uid[uid])
		var market: CardEntity = board.offers_by_id[int(state.offers[0].id)]
		var price: Node3D = market.get_meta("price_tag").get_ref()
		await _click(board.camera.unproject_position(price._paper.global_position))
		var added := state.cards.keys().filter(func(uid): return not before.has(uid))
		_check(added.size() == 1, "real price click adds exactly one card %d" % index)
		if added.size() != 1: continue
		var card: CardEntity = board.by_uid[added[0]]
		var at := board.rest_pos(card)
		var shape := Rect2(Vector2(at.x, at.z) - Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5,
			Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z))
		var clear := true
		for obstacle in board._spawn_obstacles(card.group_id, 0): clear = clear and not shape.intersects(obstacle)
		_check(clear, "purchase finds an actually empty footprint %d" % index)
		_check(board.clamp_player_position(at).distance_to(at) < 0.001, "purchase stays inside final playable bounds %d" % index)
		var untouched := true
		for uid in stationary:
			if state.cards.has(uid): untouched = untouched and board.rest_pos(board.by_uid[uid]).distance_to(stationary[uid]) < 0.001
		_check(untouched, "finding a new slot does not rearrange existing nonpayment cards %d" % index)
		var cash_anchored := true
		for gid in cash_origins:
			var remaining: Array = state.group_cards(gid)
			if remaining.is_empty(): continue
			var cash_view: Variant = board.group_of(board.by_uid[remaining[0]])
			var at_after: Vector3 = board.rest_origin(cash_view) if cash_view != null else board.rest_pos(board.by_uid[remaining[0]])
			cash_anchored = cash_anchored and at_after.distance_to(cash_origins[gid]) < 0.001
		_check(cash_anchored, "payment may close unit-card gaps without moving the cash-pile anchor %d" % index)
	_check(board.rest_pos(occupant).distance_to(occupied) < 0.001, "original occupant remains at the reserved location")
	# An airborne producer reserves its destination even while its visible card
	# is elsewhere; the next spawn must avoid the future footprint.
	var reserved: CardEntity = board.by_uid[_owned("coffee")]
	var reserve: Vector3 = board._free_spawn_position(-999, 0, occupied)
	reserved.set_meta("dest_pos", reserve)
	var next: Vector3 = board._free_spawn_position(-999, 0, reserve)
	_check(absf(next.x - reserve.x) >= CardEntity.CARD_SIZE.x or absf(next.z - reserve.z) >= CardEntity.CARD_SIZE.z,
		"in-flight destination is occupied even when its sprite is elsewhere")
	reserved.remove_meta("dest_pos")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://reports/purchase-empty-space.png")
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("PURCHASE_EMPTY_SPACE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
