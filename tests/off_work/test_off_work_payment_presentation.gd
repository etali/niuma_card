# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## Spending is shown, never implied: one note per unit of price leaves the buyer's cash and
## ends underneath the purchased card; the card waits for it and only then travels home.
## Nothing that is consumed shrinks or fades where it lies.
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	await _own_purchase()
	await _whole_wallet_and_count()
	await _caught_in_the_air()
	await _carried_home_by_hand()
	await _cash_carried_to_the_slot()
	await _opponent_purchase()
	await _dismissed_person_goes_under_the_entrance()
	await _dispose()
	finish()

func _fixture(money: int, pool: Dictionary = {"employee": 1}) -> void:
	await _dispose()
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 40}, {"employee": 2}]
	config.rules.initial.money = money
	config.rules.bot.enabled = false
	config.rules.conveyor.pool = pool
	config.rules.conveyor.interval_seconds = 1000.0
	state = OffWorkState.new(config)
	state.new_game(20261120)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera, true)
	board.offer_bought.connect(func(id): state.buy(id, 0, board.purchase_payment_ids))
	board.sync_state(state)
	_settle()

func _dispose() -> void:
	if is_instance_valid(host):
		host.queue_free()
		await process_frame
	host = null
	board = null

func _settle() -> void:
	for presenter in [board, board.enemy_board]:
		for item in presenter._move_tw.values():
			if item.tw != null and item.tw.is_valid():
				item.tw.pause()
				item.tw.custom_step(1.0)

func _advance(seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		var step := minf(left, 1.0 / 60.0)
		board._action_motion.advance(step)
		board._advance_payment(step)
		board._advance_side_rolls(step)
		# Exit tweens (a sold tag, a consumed card) are driven by the same clock here.
		for tween in board._effect_tweens:
			if tween != null and tween.is_valid(): tween.custom_step(step)
		left -= step

func _spec() -> Dictionary:
	return board._settings.payment_motion

func _hold(notes: int) -> float:
	var interval := minf(float(_spec().emission_interval_seconds), float(_spec().max_emission_window_seconds) / maxf(1.0, float(notes - 1)))
	return float(notes - 1) * interval + float(_spec().travel_seconds)

func _cash_label(owner: int) -> String:
	var presenter: Board = board if owner == 0 else board.enemy_board
	for group in presenter.groups:
		var nodes: Array = group.get("side", [])
		for index in range(0, nodes.size() - 1, 2):
			if nodes[index] is Sprite3D and nodes[index].texture == CardArt.res_icon_texture(OffWorkCardDB.RES_CASH, OffWorkCardDB):
				return nodes[index + 1].text
	return ""

func _wallet_position(owner: int) -> Vector3:
	return board.by_uid[state._owner_type(owner, "money")[0]].global_position

func _own_purchase() -> void:
	await _fixture(16)
	var offer: Dictionary = state.offers[0].duplicate(true)
	var price := int(offer.price)
	var market: OffWorkCard = board.offers_by_id[int(offer.id)]
	var origin := market.global_position
	var wallet := _wallet_position(0)
	var tag: Node3D = board._prices[int(offer.id)]
	var people_before: Array = state._owner_type(0, "employee")
	check(_cash_label(0) == "×16", "the cash pile starts at sixteen")
	board._purchase([], market)
	var bought: int = state._owner_type(0, "employee").filter(func(id): return not people_before.has(id))[0]
	var card: OffWorkCard = board.by_uid[bought]
	check(state.money(0) == 16 - price, "the rules charge the price once, before anything is shown")
	check(board._payment_notes.size() == price, "one note leaves the cash pile for every unit of price")
	check(board._action_motion.motions.has(bought) and bool(board._action_motion.motions[bought].own) \
		and card.global_position.distance_to(origin) < 0.001,
		"the buyer's own card starts from its conveyor slot in the same frame, not from its seat")
	check(is_instance_valid(tag) and tag.get_parent() == board and board._lingering_tags.has(tag),
		"the price tag stays where it hung while the payment arrives")
	check(_cash_label(0) == "×16", "the amount beside the cash pile starts counting down from its old value")
	var scale: float = float(_spec().note_scale)
	var seen := {}
	var covered := true
	var constant := true
	var total := _hold(price)
	var elapsed := 0.0
	var mid_label := ""
	while elapsed < total + 0.02:
		_advance(1.0 / 60.0)
		elapsed += 1.0 / 60.0
		if is_equal_approx(snappedf(elapsed, 0.01), 0.15): mid_label = _cash_label(0)
		for item in board._payment_notes:
			var note: Node3D = item.node
			if not note.visible: continue
			seen[note.get_instance_id()] = true
			constant = constant and note.scale.is_equal_approx(Vector3.ONE * scale) \
				and is_equal_approx(float(note.get_meta("income_opacity", 1.0)), 1.0)
			var progress: float = (float(item.elapsed) - float(item.delay)) / float(_spec().travel_seconds)
			if progress > 0.97:
				covered = covered and note.global_position.y < card.global_position.y \
					and Vector2(note.global_position.x - origin.x, note.global_position.z - origin.z).length() < CardEntity.CARD_SIZE.x * 0.5
		if elapsed < total - 0.05:
			check(board._action_motion.motions.has(bought) and Vector2(card.global_position.x - origin.x, card.global_position.z - origin.z).length() < 0.001,
				"the card waits over its slot until the last note is underneath it")
	check(seen.size() == price and constant, "every note is shown at one constant size and full opacity: nothing shrinks or fades")
	check(covered, "each note ends underneath the purchased card, inside its footprint")
	check(board._payment_notes.is_empty(), "a note is removed only after it is covered")
	check(mid_label != "×16" and mid_label != "×12" and _cash_label(0) == "×12", "the amount rolls down through intermediate values to twelve")
	check(str(board._action_motion.motions[bought].phase) != "hold", "the card leaves once it has been paid for")
	_advance(1.2)
	_settle()
	check(not board._action_motion.motions.has(bought) and card.draggable and card.global_position.distance_to(origin) > 1.0,
		"the card lands at its seat and is an ordinary draggable card again")
	# Clicking a tag is quick: the money is under the card within a quarter of a second and the
	# card is on the table within six tenths, however the opponent's replay is paced.
	var own: Dictionary = _spec().own_card
	check(total <= 0.25 and total + float(own.travel_seconds) + float(own.drop_seconds) <= 0.6,
		"from the click to the card on the table takes at most 0.6 seconds (%.2f)" % (total + float(own.travel_seconds) + float(own.drop_seconds)))
	check(float(own.travel_seconds) < float(board._settings.action_motion.travel_seconds), "the buyer's own card is carried faster than an opponent's replayed move")
	check(not is_instance_valid(tag) or tag.is_queued_for_deletion() or tag._retiring, "the tag has left with its own exit")
	# The controller drains the same event later and presents it again.
	var events: Array = state.drain_events()
	board.sync_state(state)
	for event in events: board.play_event(event)
	check(events.any(func(event): return event.kind == "buy") and board._payment_notes.is_empty() and not board._action_motion.motions.has(bought),
		"presenting the drained purchase event a second time starts nothing again")
	check(state.money(0) == 16 - price and state._owner_type(0, "employee").size() == people_before.size() + 1, "one purchase, one payment, one new card")

func _whole_wallet_and_count() -> void:
	await _fixture(4)
	var offer: Dictionary = state.offers[0].duplicate(true)
	var cash: Array = state._owner_type(0, "money").map(func(id): return board.by_uid[id])
	board._purchase([], board.offers_by_id[int(offer.id)])
	check(state.money(0) == 0 and board._payment_notes.size() == 4, "spending the whole pile still shows four notes leaving")
	check(cash.all(func(card): return is_instance_valid(card) and not card.visible and card.scale.is_equal_approx(Vector3.ONE) \
		and card._visual.scale.is_equal_approx(Vector3.ONE)),
		"the spent cards are not left shrinking where the pile was; the notes are their departure")
	_advance(2.0)
	# Twelve is the most notes one payment shows, whatever the price.
	await _fixture(40, {"boss": 1})
	state.config.cards.boss.price = 30
	state.offers[0].price = 30
	board._purchase([], board.offers_by_id[int(state.offers[0].id)])
	check(state.money(0) == 10 and board._payment_notes.size() == int(_spec().max_notes), "a large price is capped at the configured number of notes")
	_advance(2.0)

func _caught_in_the_air() -> void:
	await _fixture(16)
	var offer: Dictionary = state.offers[0].duplicate(true)
	var people_before: Array = state._owner_type(0, "employee")
	board._purchase([], board.offers_by_id[int(offer.id)])
	var bought: int = state._owner_type(0, "employee").filter(func(id): return not people_before.has(id))[0]
	var card: OffWorkCard = board.by_uid[bought]
	check(card.draggable and card.collision_layer != 0 and card.input_ray_pickable, "the buyer's travelling card stays catchable")
	# Paid for, and half way home.
	_advance(_hold(int(offer.price)) + float(_spec().own_card.travel_seconds) * 0.5)
	var landing: Vector3 = board._action_motion.motions[bought].to
	var in_air := card.global_position
	check(str(board._action_motion.motions[bought].phase) == "travel" and in_air.distance_to(landing) > 0.5, "the card is on its way home")
	board._snapshot_press(card, board.camera.unproject_position(in_air))
	check(not board._action_motion.motions.has(bought) and not card.has_meta("off_work_action_motion") \
		and card.global_position.is_equal_approx(in_air),
		"pressing it takes it out of the flight where it is, under the pointer")
	check((board._press_snap.pos as Vector3).is_equal_approx(landing), "a press that is only a click settles it where it was going to land")
	board.cancel_pointer()
	_settle()
	check(card.draggable and int(state.cards[bought].owner) == 0, "after the release it is an ordinary card of the buyer")

## The player drags the offer off the conveyor and lets go in their own half. The card is
## already where it lands, so nothing is retraced: the payment goes to it there.
func _carried_home_by_hand() -> void:
	await _fixture(16)
	var offer: Dictionary = state.offers[0].duplicate(true)
	var price := int(offer.price)
	var market: OffWorkCard = board.offers_by_id[int(offer.id)]
	var origin := market.global_position
	var wallet := _wallet_position(0)
	var people_before: Array = state._owner_type(0, "employee")
	var centre: Vector2 = board.player_bounds.get_center()
	var drop := Vector3(centre.x, float(board._settings.rest_y), centre.y)
	market.global_position = drop
	market.set_meta("purchase_placement", {"position": drop})
	board._purchase([], market)
	var bought: int = state._owner_type(0, "employee").filter(func(id): return not people_before.has(id))[0]
	var card: OffWorkCard = board.by_uid[bought]
	_settle()
	var seat := card.global_position
	check(state.money(0) == 16 - price and board._payment_notes.size() == price, "a card carried home is paid for with the same notes")
	check(not board._action_motion.motions.has(bought) and not board._action_motion.offer_sources.has(int(offer.id)) \
		and seat.distance_to(origin) > 1.0 and Vector2(seat.x - drop.x, seat.z - drop.z).length() < CardEntity.CARD_SIZE.z * 2.0,
		"it stays where the player put it and is never sent back to the conveyor to fly again")
	check(board._payment_notes.all(func(item): return Vector2((item.from as Vector3).x - wallet.x, (item.from as Vector3).z - wallet.z).length() < CardEntity.CARD_SIZE.z \
		and Vector2((item.to as Vector3).x - seat.x, (item.to as Vector3).z - seat.z).length() < 0.001 and (item.to as Vector3).y < seat.y),
		"the notes go from the cash pile to underneath the card where it lies")
	_advance(_hold(price) + 0.05)
	check(board._payment_notes.is_empty() and card.global_position.is_equal_approx(seat) and card.draggable, "the card does not move while it is paid for")
	var events: Array = state.drain_events()
	board.sync_state(state)
	for event in events: board.play_event(event)
	check(board._payment_notes.is_empty() and not board._action_motion.motions.has(bought), "the drained event shows nothing a second time")

## The player drags cash onto the offer. The notes leave from where the cash was released, the
## card waits for them over its slot, and what was not spent returns to the pile.
func _cash_carried_to_the_slot() -> void:
	await _fixture(16)
	var offer: Dictionary = state.offers[0].duplicate(true)
	var price := int(offer.price)
	var market: OffWorkCard = board.offers_by_id[int(offer.id)]
	var origin := market.global_position
	var people_before: Array = state._owner_type(0, "employee")
	var cash: Array = state._owner_type(0, "money").map(func(id): return board.by_uid[id])
	var released := origin + Vector3(0.12, Board.DRAG_HEIGHT, 0.08)
	for note in cash: note.global_position = released
	board._purchase(cash, market)
	var bought: int = state._owner_type(0, "employee").filter(func(id): return not people_before.has(id))[0]
	var card: OffWorkCard = board.by_uid[bought]
	check(state.money(0) == 16 - price and board._payment_notes.size() == price, "cash carried to the offer pays the price once")
	check(board._payment_notes.all(func(item): return Vector2((item.from as Vector3).x - released.x, (item.from as Vector3).z - released.z).length() < 0.001 \
		and Vector2((item.control as Vector3).x - origin.x, (item.control as Vector3).z - origin.z).length() < CardEntity.CARD_SIZE.z),
		"the notes leave from where the cash was released and go straight under the card, without a detour")
	check(board._action_motion.motions.has(bought) and card.global_position.distance_to(origin) < 0.001, "the bought card starts from its slot and waits there")
	_advance(_hold(price) + 1.4)
	_settle()
	check(board._payment_notes.is_empty() and not board._action_motion.motions.has(bought) and card.global_position.distance_to(origin) > 1.0,
		"once paid for, it travels to its seat")
	var left: Array = state._owner_type(0, "money").map(func(id): return board.by_uid[id])
	# Where the rest of a dragged pile comes to rest is the drag's own business (test_work_ui).
	check(left.size() == 16 - price and left.all(func(note): return note.visible and note.scale.is_equal_approx(Vector3.ONE)),
		"the cash that was not spent is still there as ordinary cards")

func _opponent_purchase() -> void:
	await _fixture(16)
	var offer: Dictionary = state.offers[0].duplicate(true)
	var origin: Vector3 = board.offers_by_id[int(offer.id)].global_position
	var wallet := _wallet_position(1)
	var bought := state.buy(int(offer.id), 1)
	var events: Array = state.drain_events()
	board.sync_state(state)
	for event in events: board.play_event(event)
	var card: OffWorkCard = board.by_uid[bought]
	check(bought >= 0 and board._payment_notes.size() == int(offer.price), "the opponent's purchase shows its own payment")
	check(board._payment_notes.all(func(item): return (item.from as Vector3).z < origin.z and (item.control as Vector3).z < origin.z),
		"the opponent's notes come from its cash and enter the slot over its own edge of the conveyor")
	check(board._action_motion.motions.has(bought) and not bool(board._action_motion.motions[bought].own) and not card.draggable,
		"the opponent's card retraces the purchase and cannot be caught by the player")
	check(Vector2(wallet.x - (board._payment_notes[0].from as Vector3).x, wallet.z - (board._payment_notes[0].from as Vector3).z).length() < CardEntity.CARD_SIZE.z,
		"the notes start at the opponent's cash pile")
	_advance(_hold(int(offer.price)) + 1.2)
	_settle()
	check(board._payment_notes.is_empty() and not board._action_motion.motions.has(bought) and _cash_label(1) == "×%d" % (16 - int(offer.price)),
		"the opponent's payment completes and its cash count has rolled down")

func _dismissed_person_goes_under_the_entrance() -> void:
	await _fixture(8)
	board.pawn_pos = Vector3(6.0, 0.2, -1.6)
	var person: int = state._owner_type(0, "employee")[0]
	var card: OffWorkCard = board.by_uid[person]
	# Dropped on the entrance, slightly off its centre and at drag height.
	card.global_position = board.pawn_pos + Vector3(0.4, 0.5, 0.3)
	state.drain_events()
	check(state.dismiss_people([person], 0), "the rules dismiss the person")
	var events: Array = state.drain_events()
	board.sync_state(state)
	for event in events: board.play_event(event)
	check(board._retired_cards.has(person) and not card.is_queued_for_deletion(), "the dismissed card is still drawn while it leaves")
	check(card.stamp_showing() and card.stamp_text() == str(OffWorkUI.section("rig").dismiss_word),
		"the word is stamped on the dismissed card itself, not drawn over the table")
	var before := card.global_position
	var stamped := OffWorkUI.number("animation", "dismiss_stamp_seconds")
	for tween in board._effect_tweens:
		if tween != null and tween.is_valid(): tween.custom_step(stamped * 0.9)
	check(card.global_position.is_equal_approx(before) and card.visible, "it stays where it was dropped while the stamp is read")
	var duration := OffWorkUI.number("animation", "retire_wait") + OffWorkUI.number("animation", "retire_duration")
	for tween in board._effect_tweens:
		if tween != null and tween.is_valid(): tween.custom_step(stamped * 0.1 + OffWorkUI.number("animation", "retire_duration") * 0.98)
	check(card.visible and card.scale.is_equal_approx(Vector3.ONE) and card._visual.scale.is_equal_approx(Vector3.ONE),
		"a dismissed person is neither shrunk nor hidden in place")
	check(Vector2(card.global_position.x - board.pawn_pos.x, card.global_position.z - board.pawn_pos.z).length() < 0.05 \
		and card.global_position.y < board.pawn_pos.y and card.global_position.y < before.y,
		"it slides to the centre of the dismissal entrance and ends underneath it")
	# Anything else that is consumed while lying loose goes straight down under what it rests on.
	var loose: int = state.add_card("coffee", 0)
	board.sync_state(state)
	_settle()
	var cup: OffWorkCard = board.by_uid[loose]
	var rest := cup.global_position
	state._consume(loose)
	board.sync_state(state)
	for tween in board._effect_tweens:
		if tween != null and tween.is_valid(): tween.custom_step(duration * 0.98)
	check(is_instance_valid(cup) and cup.scale.is_equal_approx(Vector3.ONE) \
		and is_equal_approx(cup.global_position.x, rest.x) and is_equal_approx(cup.global_position.z, rest.z) and cup.global_position.y < rest.y,
		"a loose consumed card keeps its size and place and only goes down out of sight")
