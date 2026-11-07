extends SceneTree

var state: OffWorkState
var board: OffWorkBoard
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(80)
	OffWorkCardDB.configure(config)
	var host := Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	board.sync_state(state)
	await _settle()
	_check_opening()
	var employee := _owned("employee")
	var work := _owned("work")
	var production: int = state.cards[work].group
	_check(board.begin_side_extract([work], board.camera.unproject_position(board.get_group_position(production))),
		"one document can be picked out of the opening stack")
	_check(board._drag_cards.size() == 1 and board._drag_cards[0].uid == work, "only the requested document is held")
	board.cancel_pointer()
	board.sync_state(state)
	_check(state.group_work(production).size() == 200, "cancelled extraction restores the complete opening stack")
	state.move_cards([employee], production)
	state.drain_events()
	board.sync_state(state)
	await _settle()
	state.advance(10.0)
	var event := _income()
	_check(not event.is_empty(), "first completed work emits money destination")
	var cash: int = event.money_id
	var bank: int = event.money_group
	board.sync_state(state)
	_check(state.cards[cash].group != production, "income is logically outside production group")
	var cash_group: Dictionary = board.group_of(board.by_uid[cash])
	_check(_cash_text(cash_group) == "×9", "cash side badge agrees with the nine real one-money cards")
	board.play_event(event)
	_check(board._cash_flights.has(cash) and board.by_uid[cash].has_meta("income_flight"), "actual money entity starts flight")
	_check(board.by_uid[cash].position.distance_to(board.get_card_position(employee)) < 0.5, "cash pops from employee rather than the bank")
	board._advance_cash_flights(0.1)
	var airborne: Vector3 = board.by_uid[cash].position
	_check(airborne.y > float(board._settings.rest_y), "cash rises above tabletop")
	board.sync_state(state)
	_check(board.by_uid[cash].position.is_equal_approx(airborne), "periodic sync cannot overwrite flight position")
	board._advance_cash_flights(0.25)
	state.advance(10.0)
	var second := _income()
	var before_growth: Vector3 = board.by_uid[cash].position
	board.sync_state(state)
	_check(board.by_uid[cash].position.is_equal_approx(before_growth) and board._cash_flights.has(cash), "growing cash stack updates landing without cancelling earlier flight")
	_check(int(second.money_group) == bank, "successive output uses the same pure cash group")
	board.play_event(second)
	var second_cash: int = second.money_id
	_check(_cash_text(board.group_of(board.by_uid[second_cash])) == "×10", "stack amount refreshes as more cash joins")
	# Spending an airborne 1-money card is allowed and must retire that exact entity.
	var initial_cash: Array = state.group_cards(bank).filter(func(id): return id != cash and id != second_cash)
	var offer: Dictionary = state.offers.filter(func(item): return not item.is_empty())[0]
	_check(state.buy(int(offer.id), 0, [cash] + initial_cash) > 0, "a real multi-card payment can include the airborne unit")
	board.sync_state(state)
	_check(not board.by_uid.has(cash) and not board._cash_flights.has(cash), "spending flying cash cancels presentation without resurrection")
	board._advance_cash_flights(0.1)
	state.move_cards([second_cash], -1)
	board.sync_state(state)
	_check(not board._cash_flights.has(second_cash), "moving income to a different group cancels its old destination")
	# Airborne income is visual-only: the original pickup entry must ignore it.
	state.advance(10.0)
	var third := _income()
	board.sync_state(state)
	board.play_event(third)
	var third_cash: int = third.money_id
	board._on_card_clicked(board.by_uid[third_cash])
	_check(board._cash_flights.has(third_cash) and not board.by_uid[third_cash].dragging, "original pointer pickup ignores income until it lands")
	_check(board.by_uid[third_cash].collision_layer == 0 and board.by_uid[third_cash].collision_mask == 0, "travelling money cannot intercept rays or collide with dragged cards")
	board.cancel_pointer()
	board.sync_state(state)
	await _settle()
	state.advance(10.0)
	var fourth := _income()
	board.sync_state(state)
	board.play_event(fourth)
	board._advance_cash_flights(2.0)
	var landed: OffWorkCard = board.by_uid[int(fourth.money_id)]
	_check(not landed.has_meta("income_flight") and not landed.has_meta("dest_pos"), "landing clears flight ownership")
	var landed_group: Dictionary = board.group_of(landed)
	_check(landed_group.cards.has(landed), "landed card remains in original Board cash pile")
	_check(state.group_cards(int(fourth.money_group)).all(func(id): return state.cards[id].type == "money"), "output pile contains only cash")
	state.advance(10.0)
	var fifth := _income()
	board.sync_state(state)
	board.play_event(fifth)
	board.reset_view()
	_check(board._cash_flights.is_empty(), "restart clears all cash flights")
	state.new_game(81)
	board.sync_state(state)
	board._advance_cash_flights(2.0)
	_check(board.by_uid.size() == state.cards.size() and state.money(0) == int(config.rules.initial.money), "old animation does not mutate or recreate cash in new game")
	await _check_income_during_cash_drag()
	await _check_bought_employee_placement()
	host.queue_free()
	await process_frame
	for error in failures: printerr("FAIL ", error)
	print("CASH_PRESENTATION ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _check_opening() -> void:
	_check(state.tasks.is_empty(), "opening has no assembled working group")
	for owner in [0, 1]:
		var presenter: Board = board if owner == 0 else board.enemy_board
		var footprints: Array[Rect2] = []
		var work_side_labels: Array[Rect2] = []
		var personnel_z: Array = []
		var work_piles := 0
		for gid in state.groups:
			if state.groups[gid].owner != owner: continue
			var members: Array = state.group_cards(gid)
			if members.is_empty(): continue
			var top: CardEntity = board.by_uid[members[0]]
			var view: Variant = presenter.group_of(top)
			var origin: Vector3 = presenter.rest_origin(view) if view != null else presenter.rest_pos(top)
			var span: float = Board.z_span(view) if view != null else 0.0
			var shape := Rect2(origin.x - CardEntity.CARD_SIZE.x / 2, origin.z - CardEntity.CARD_SIZE.z / 2, CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z + span)
			_check(presenter.player_bounds.grow(0.01).encloses(shape), "opening group %d remains in owner zone" % gid)
			for previous in footprints: _check(not shape.intersects(previous), "opening groups expose separate card faces")
			footprints.append(shape)
			if state.cards[members[0]].type == "work":
				work_piles += 1
				work_side_labels.append(Rect2(origin.x + CardEntity.CARD_SIZE.x / 2 + Board.SIDE_GAP,
					origin.z + span / 2 - Board.SIDE_ROW_Z / 2, Board.SIDE_W, Board.SIDE_ROW_Z))
			if state.config.is_person(state.cards[members[0]].type):
				personnel_z.append(origin.z)
				_check(members.size() == 1, "opening personnel is a standalone card")
		_check(work_piles == 1, "all opening work is in one stack on each desk")
		for side_label in work_side_labels:
			for shape in footprints:
				_check(not side_label.intersects(shape), "opening work count has space beyond the card face")
		_check(personnel_z.size() == 1, "opening has exactly one independent employee")

func _owned(kind: String) -> int:
	for id in state.cards:
		if state.cards[id].owner == 0 and state.cards[id].type == kind: return id
	return -1

func _income() -> Dictionary:
	var result: Dictionary = {}
	for event in state.drain_events():
		if event.kind == "work_complete" and event.owner == 0: result = event
	return result

func _cash_text(group: Dictionary) -> String:
	var nodes: Array = group.get("side", [])
	for index in range(0, nodes.size() - 1, 2):
		if nodes[index] is Sprite3D and nodes[index].texture == CardArt.res_icon_texture(OffWorkCardDB.RES_CASH, OffWorkCardDB): return nodes[index + 1].text
	return ""

func _check_income_during_cash_drag() -> void:
	for cancel in [false, true]:
		board.reset_view()
		state.new_game(90 if cancel else 89)
		board.sync_state(state)
		var employee := _owned("employee")
		state.move_cards([employee], int(state.cards[_owned("work")].group))
		state.advance(10.0)
		var first := _income()
		board.sync_state(state)
		board.play_event(first)
		board._advance_cash_flights(2.0)
		await _settle()
		var existing: Dictionary = board.group_of(board.by_uid[int(first.money_id)])
		var held: Array = existing.cards.map(func(card): return card.uid)
		board._snapshot_press(existing.cards[0], Vector2.ZERO)
		board._on_card_clicked(existing.cards[0])
		var shift := Vector3(8.8, Board.DRAG_HEIGHT, 5.0) - board._drag_cards[0].global_position
		for card in board._drag_cards: card.global_position += shift
		var hand_positions: Dictionary = {}
		for card in board._drag_cards: hand_positions[card.uid] = card.global_position
		var balance_before := state.money(0)
		state.advance(10.0)
		var income := _income()
		board.sync_state(state)
		board.play_event(income)
		_check(board._drag_cards.map(func(card): return card.uid) == held, "new income preserves the original cash held in hand")
		for uid in hand_positions:
			_check(board.by_uid[uid].global_position.is_equal_approx(hand_positions[uid]), "income does not reposition held money")
		_check(state.money(0) == balance_before + int(income.amount), "income during cash drag is credited exactly once")
		board._advance_cash_flights(0.4)
		board.sync_state(state)
		if cancel: board.cancel_pointer()
		else: board._end_drag()
		await _settle()
		board.sync_state(state)
		board._advance_cash_flights(2.0)
		await _settle()
		_check(not board.is_dragging() and board._cash_flights.is_empty(), "drop/cancel settles cash that arrived during the drag")
		_check(state.money(0) == balance_before + int(income.amount), "drop/cancel cannot duplicate the new cash amount")
		var seen: Dictionary = {}
		for group in board.groups:
			for card in group.cards:
				seen[card.uid] = int(seen.get(card.uid, 0)) + 1
				_check(state.cards.has(card.uid) and int(state.cards[card.uid].group) == int(group.work_group_id), "settled visual membership agrees with rule groups")
		for uid in state.cards:
			if state.cards[uid].owner != 0 or state.cards[uid].type != "money": continue
			_check(board.by_uid.has(uid) and board.cards.count(board.by_uid[uid]) == 1, "each cash card keeps exactly one registered entity")
			var card: OffWorkCard = board.by_uid[uid]
			var view: Variant = board.group_of(card)
			_check(int(seen.get(uid, 0)) == (1 if view != null else 0), "each cash entity belongs to one visual group or remains a single card")
			_check(not card.dragging and not card.has_meta("dest_pos") and card.position.y < Board.DRAG_HEIGHT, "cash remains on the table without stale hand or flight state")

func _check_bought_employee_placement() -> void:
	for existing_people in [1, 3]:
		board.reset_view()
		state.new_game(100)
		# The second run explicitly fills the three reserved personnel positions
		# to exercise fallback placement, without changing the shipped opening.
		for extra in range(1, existing_people): state.add_card("employee", 0)
		board.sync_state(state)
		await _settle()
		var offer: Dictionary = state.offers.filter(func(item): return not item.is_empty() and item.type == "employee")[0]
		var hired := state.buy(int(offer.id), 0)
		_check(hired > 0 and state.people_count(0) == existing_people + 1, "real purchase adds one employee with %d existing" % existing_people)
		board.sync_state(state)
		await _settle()
		var newcomer: OffWorkCard = board.by_uid[hired]
		var at := board.rest_pos(newcomer)
		var shape := Rect2(at.x - CardEntity.CARD_SIZE.x / 2, at.z - CardEntity.CARD_SIZE.z / 2, CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z)
		_check(board.player_bounds.grow(0.01).encloses(shape), "newly purchased employee stays within the player zone")
		for uid in state.cards:
			if uid == hired or state.cards[uid].owner != 0: continue
			var occupied := board.rest_pos(board.by_uid[uid])
			var other := Rect2(occupied.x - CardEntity.CARD_SIZE.x / 2, occupied.z - CardEntity.CARD_SIZE.z / 2, CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z)
			_check(not shape.intersects(other), "newly purchased employee does not cover existing card faces")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _settle() -> void:
	await create_timer(0.25).timeout
	await process_frame
