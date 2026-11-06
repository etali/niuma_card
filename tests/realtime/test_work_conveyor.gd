extends SceneTree

var game: Node
var board: WorkBoard
var state: WorkState
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	root.size = Vector2i(1440, 810)
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	board = game.board
	state = game.state
	state.config.rules.bot.enabled = false
	_check(state.offers.size() == 6 and board.offers_by_id.size() == 6, "opening has six real offers")
	_check(board._prices.size() == 6, "opening has one price tag per offer")
	var first_card: WorkCard = board.offers_by_id[int(state.offers[0].id)]
	var entry_start: Vector3 = first_card.global_position
	_check_links("entry start")
	for step in 8:
		await create_timer(0.05).timeout
		_check_links("entry frame %d" % step)
	_check(first_card.global_position.distance_to(entry_start) < 0.001, "opening offers start settled inside their real conveyor grooves")
	var old_first := int(state.offers[0].id)
	var retained := int(state.offers[1].id)
	var old_tag: Node = board._prices[old_first]
	var old_x: float = board.offers_by_id[retained].global_position.x
	state.advance(state.config.number("conveyor", "interval_seconds"))
	board.sync_state(state)
	_check(not board.offers_by_id.has(old_first) and not board._prices.has(old_first), "leftmost offer and tag leave together")
	_check(state.offers.size() == 6 and board.offers_by_id.size() == 6, "rolling preserves six slots and offers")
	_check_links("roll start")
	for step in 8:
		await create_timer(0.05).timeout
		_check_links("roll frame %d" % step)
	_check(not is_instance_valid(old_tag), "departed price tag has no orphan node")
	_check(board.offers_by_id[retained].global_position.x < old_x - 1.0, "retained offer actually moves left one slot")
	# Exercise original pointer pickup and cancellation while the price remains
	# attached, including its hit-test geometry rather than only its label.
	var market: WorkCard = board.offers_by_id[retained]
	var resting: Vector3 = market.global_position
	board._on_card_clicked(market)
	_check(board._drag_cards.has(market), "original board picks up moving-market card")
	market.global_position += Vector3(1.0, 0.6, 0.8)
	board._sync_market_tag(market)
	_check_links("drag")
	board.cancel_pointer()
	board.sync_state(state)
	await create_timer(0.4).timeout
	_check(market.global_position.distance_to(resting) < 0.001, "original cancel restores the shelf card")
	_check_links("cancelled drag")
	# A successful real purchase removes only its own card/tag and leaves the
	# empty slot to participate in the following conveyor step.
	var bought_index := 0
	var offer: Dictionary = state.offers[bought_index]
	var purchased_id := int(offer.id)
	var purchased_tag: Node = board._prices[purchased_id]
	_check(state.buy(purchased_id, 0) >= 0, "real purchase succeeds")
	board.sync_state(state)
	await process_frame
	_check(state.offers[bought_index].is_empty() and state.offers.size() == 6, "purchase leaves one of six slots empty")
	_check(not board.offers_by_id.has(purchased_id) and not board._prices.has(purchased_id) and not is_instance_valid(purchased_tag), "purchase removes its price with the offer")
	_check_links("after purchase")
	# Force a second roll before the first tween has finished. A surviving offer
	# must arrive at the newest slot, with no stale price tween returning later.
	var overlapping_id := int(state.offers.back().id)
	state.advance(state.config.number("conveyor", "interval_seconds"))
	board.sync_state(state)
	await create_timer(0.04).timeout
	var midway: Vector3 = board.offers_by_id[overlapping_id].global_position
	state.advance(state.config.number("conveyor", "interval_seconds"))
	board.sync_state(state)
	_check(board.offers_by_id[overlapping_id].global_position.is_equal_approx(midway), "repeated roll retargets from actual in-flight position")
	for step in 5:
		await create_timer(0.08).timeout
		_check_links("overlapping roll %d" % step)
	var overlapping_card: WorkCard = board.offers_by_id[overlapping_id]
	_check(overlapping_card.global_position.distance_to(overlapping_card.get_meta("market_slot")) < 0.001, "overlapping roll settles at newest slot without an old tween")
	for viewport_size in [Vector2i(1440, 810), Vector2i(1024, 640), Vector2i(960, 540)]:
		root.size = viewport_size
		game.hud.relayout()
		await create_timer(0.15).timeout
		var content: Rect2 = game.hud.content_rect()
		var facility: Node3D = game.get_node("MarketFacility")
		_check(facility.visible and content.has_point(board.camera.unproject_position(facility.global_position)), "dismissal entrance stays visible beside six offers %s" % viewport_size)
		for offer_card in board.offers_by_id.values():
			_check(offer_card.global_position.x < facility.global_position.x, "dismissal entrance stays to the right of every offer")
		for card in board.offers_by_id.values():
			var tag: Node3D = card.get_meta("price_tag").get_ref()
			_check(content.has_point(board.camera.unproject_position(card.global_position)) and content.has_point(board.camera.unproject_position(tag._paper.global_position)), "six-slot offer and price fit viewport %s" % viewport_size)
	game._new_game()
	_check(board.offers_by_id.size() == 6 and board._prices.size() == 6, "restart rebuilds six matched pairs")
	_check_links("restart")
	game.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_CONVEYOR ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _check_links(stage: String) -> void:
	var expected: Vector3 = board._setting_vector("price_tag_offset")
	for id in board.offers_by_id:
		var card: CardEntity = board.offers_by_id[id]
		var tag: Node3D = board._prices[id]
		_check(tag.global_position.distance_to(card.to_global(expected)) < 0.00001, "%s: price follows offer %d at the same instant" % [stage, id])
		var paper_center: Vector2 = board.camera.unproject_position(tag._paper.global_position)
		_check(tag.hit_test(paper_center, board.camera) == card.is_visible_in_tree(), "%s: moving price is hittable exactly while its offer is visible %d" % [stage, id])

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
