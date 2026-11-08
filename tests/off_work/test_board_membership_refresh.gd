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
	config.rules.initial.groups = [{"employee": 1}, {"work": 40}]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(92833)
	for owner in [0, 1]:
		var tool := state.add_card("transfer", owner)
		var person: int = state.activity_card_ids(owner).filter(func(uid): return state.cards[uid].type == "employee")[0]
		var work: Array = state.cards.keys().filter(func(uid): return state.cards[uid].type == "work" and state.cards[uid].owner == owner)
		_check(state.move_cards([person] + work, state.cards[tool].group), "each owner starts a real transfer batch")
	var board := OffWorkBoard.new(false)
	root.add_child(board)
	board.set_process(false)
	board.player_bounds = Rect2(-12, -7, 24, 14)
	board.enemy_board.player_bounds = Rect2(-12, -7, 24, 14)
	board.sync_state(state)
	var snapshot := {}
	for key in OffWorkState.WORLD_FIELDS:
		var value: Variant = state.get(key)
		snapshot[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	state.drain_events()
	state.advance(config.number("transfer", "seconds"))
	var transfers: Array = state.drain_events().filter(func(event): return event.kind == "transfer")
	_check(transfers.size() == 2 and state.revision == snapshot.revision and state.cards.size() == snapshot.cards.size(),
		"both transfers exchange real work without changing revision or total count")
	board.sync_state(state)
	for event in transfers:
		for uid in event.ids:
			var card: OffWorkCard = board.by_uid[uid]
			var presenter: Board = board if int(event.target_owner) == 0 else board.enemy_board
			_check(card.card_owner == int(event.target_owner) and card.group_id == int(event.target_group)
				and presenter.group_of(card) != null, "same-revision transferred UID belongs to the actual receiving visual group")
	for key in OffWorkState.WORLD_FIELDS: state.set(key, snapshot[key])
	state._invalidate_group_index()
	board.sync_state(state)
	_check(board.by_uid.values().all(func(card): return is_same(card.record, state.cards[card.uid]) \
		and card.card_owner == int(state.cards[card.uid].owner) and card.group_id == int(state.cards[card.uid].group)),
		"restoring the same State and revision rebinds owner, group and record for every UID")
	board.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("BOARD_MEMBERSHIP_REFRESH %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
