extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "work": 20}]
	config.rules.initial.money = 2000
	config.cards.work.income = 12
	config.rules.conveyor.pool = {"employee": 1}
	var state := OffWorkState.new(config)
	state.new_game(92832)
	var board := OffWorkBoard.new(false)
	root.add_child(board)
	board.set_process(false)
	board.player_bounds = Rect2(-12, -7, 24, 14)
	board.enemy_board.player_bounds = Rect2(-12, -7, 24, 14)
	board.table_bounds = board.player_bounds
	var camera := Camera3D.new()
	board.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.camera = camera
	board.enemy_board.camera = camera
	board.sync_state(state)
	var cash: Array = board.by_uid.values().filter(func(card): return card.type == "money")
	var hidden: Array = cash.filter(func(card): return card.face_deferred)
	_check(cash.size() == 4000 and state.money(0) == 2000 and state.money(1) == 2000,
		"two thousand currency units per seat keep all four thousand real UIDs")
	_check(hidden.size() > 3900 and hidden.all(func(card): return card._plate == null and not card.is_processing()),
		"covered stable cash defers printed faces and per-card processing (%d deferred, %d processing)" % [hidden.size(), hidden.filter(func(card): return card.is_processing()).size()])
	_check(hidden.all(func(card): return card._material_collision.disabled)
		and cash.filter(func(card): return card._visual.visible).all(func(card): return not card._material_collision.disabled),
		"only exactly overlapping hidden material shapes leave the physics broadphase")
	var sheet: OffWorkCard = hidden.filter(func(card): return card.card_owner == 0)[0]
	var original_collision := Vector2i(sheet.collision_layer, sheet.collision_mask)
	_check(state.move_cards([sheet.uid], -1), "one covered currency UID can be split from its real wallet")
	board.sync_state(state)
	_check(board.by_uid[sheet.uid] == sheet and sheet._visual.visible and sheet._plate != null and sheet.is_processing()
		and not sheet._material_collision.disabled and Vector2i(sheet.collision_layer, sheet.collision_mask) == original_collision,
		"splitting covered cash reveals the same real draggable body and resumes feedback")
	var bank := int(cash.filter(func(card): return card.card_owner == 0 and card.uid != sheet.uid)[0].group_id)
	_check(state.move_cards([sheet.uid], bank), "cash can be returned to the existing wallet")
	board.sync_state(state)
	_check(not sheet._visual.visible and not sheet.is_processing() and sheet._material_collision.disabled,
		"a printed cash face stops processing and disables only its duplicate shape when covered again")
	state.drain_events()
	state.advance(config.work_seconds())
	var events: Array = state.drain_events().filter(func(event): return event.kind == "work_complete")
	board.sync_state(state)
	var income_ids: Array = []
	for event in events:
		income_ids.append_array(event.money_ids)
		board._start_cash_flight(event)
	_check(income_ids.size() == 24 and board._cash_flights.size() == 24, "all newly earned currency retains its own protected income flight")
	_check(income_ids.all(func(uid): return not board.by_uid[uid].face_deferred and board.by_uid[uid]._plate != null),
		"income builds real printed faces before recording their opacity materials")
	_check(income_ids.all(func(uid): return board.by_uid[uid].collision_layer == 0 and board.by_uid[uid].collision_mask == 0),
		"revealing income shapes never bypasses the original flight collision lock")
	var motion: Dictionary = board._settings.income_motion
	board._advance_cash_flights(float(motion.travel_seconds) + float(motion.land_seconds) + float(motion.max_emission_window_seconds) + 0.1)
	board._sync_stack_occlusion()
	_check(board._cash_flights.is_empty() and income_ids.all(func(uid): return board.by_uid[uid].draggable == (int(state.cards[uid].owner) == 0)),
		"income completion restores the original collision and drag ownership")
	_check(income_ids.all(func(uid): return Vector2i(board.by_uid[uid].collision_layer, board.by_uid[uid].collision_mask) == original_collision \
		and board.by_uid[uid]._material_collision.disabled == (not board.by_uid[uid]._visual.visible)),
		"landed income restores layer/mask and the correct visible-versus-covered shape state")
	_check(income_ids.all(func(uid): return board.by_uid[uid]._visual.visible or not board.by_uid[uid].is_processing()),
		"landed covered income does not leave thousands of material animation callbacks")
	var offer: Dictionary = state.offers.filter(func(item): return not item.is_empty())[0]
	var wallet: Array = state.group_cards(bank)
	var payment := wallet.slice(wallet.size() - int(offer.price))
	_check(payment.all(func(uid): return state.cards[uid].type == "money"), "payment selects actual currency identities")
	var balance := state.money(0)
	_check(state.buy(int(offer.id), 0, payment) >= 0, "covered currency remains valid for explicit real purchase payment")
	board.sync_state(state)
	_check(state.money(0) == balance - int(offer.price) and payment.all(func(uid): return not state.cards.has(uid) and not board.by_uid.has(uid)),
		"purchase consumes exactly the selected cash UIDs and amount")
	_check(board.by_uid.size() == state.cards.size(), "cash optimization neither merges nor drops a logical identity")
	board.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("LARGE_CASH_REFRESH %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
