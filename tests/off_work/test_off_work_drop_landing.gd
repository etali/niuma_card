extends "res://tests/off_work/test_work_ui.gd"

## Exercise the original pointer/release path, including the deferred adapter
## commit: frozen realtime cards must land before their positions are saved.
func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
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
	state.config.rules.initial.money = 0
	for kind in ["meeting", "slack", "money"]:
		await _single_card_drop(kind)
	await _merge_onto_dropped_money()
	await _expanded_money_drop()
	await _network_drop()
	await _restored_placement()
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("OFF_WORK_DROP_LANDING %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(initial: Array) -> void:
	board.cancel_pointer()
	var cash_groups: Array = []
	var other_groups: Array = []
	var amount := 0
	for group in initial:
		if group.has("money"):
			cash_groups.append(int(group.money))
			amount += int(group.money)
		else: other_groups.append(group)
	state.config.rules.initial.groups = other_groups + [{"employee": 1}, {"work": 8}]
	state.config.rules.initial.money = amount
	main._new_game()
	var remaining: Array = _owned_ids("money")
	for index in maxi(0, cash_groups.size() - 1):
		var count: int = cash_groups[index]
		state.move_cards(remaining.slice(0, count), -1)
		remaining = remaining.slice(count)
	board.sync_state(state)
	await _settle()

func _assert_table_origin(gid: int, context: String) -> void:
	var height := float(board._settings.rest_y)
	_check(board._origin_by_gid.has(gid) and absf(board._origin_by_gid[gid].y - height) < 0.001,
		context + ": remembered origin stays on the tabletop")
	_check(board.group_overrides.has(gid) and absf(board.group_overrides[gid].y - height) < 0.001,
		context + ": saved placement stays on the tabletop")

func _single_card_drop(kind: String) -> void:
	await _fixture([{kind: 1}])
	var card: CardEntity = board.by_uid[_owned(kind)]
	var gid: int = state.cards[card.uid].group
	await _drag(card, _empty_point(), true)
	_check(state.cards[card.uid].group == gid and state.group_cards(gid).size() == 1,
		kind + ": empty-table drop keeps the singleton's identity")
	_check(card.freeze and not card.dragging and absf(card.global_position.y - float(board._settings.rest_y)) < 0.001,
		kind + ": released singleton lands while retaining frozen realtime physics")
	_assert_table_origin(gid, kind)
	for refresh in 3: board.sync_state(state)
	await _settle()
	_check(absf(card.global_position.y - float(board._settings.rest_y)) < 0.001,
		kind + ": later synchronization cannot restore the held height")

func _merge_onto_dropped_money() -> void:
	await _fixture([{"money": 1}, {"money": 4}])
	var loose: CardEntity = null
	var pile: Dictionary = {}
	for uid in _owned_ids("money"):
		var candidate: CardEntity = board.by_uid[uid]
		var group: Variant = board.group_of(candidate)
		if group == null: loose = candidate
		else: pile = group
	if not _check(loose != null and pile.get("cards", []).size() == 4,
		"money merge fixture has a singleton and a four-card pile"): return
	var expected: Array = _owned_ids("money")
	await _drag(loose, _empty_point(), true)
	await _drag(pile.cards[0], board.camera.unproject_position(loose.global_position), false, true)
	var combined: Variant = board.group_of(loose)
	if not _check(combined != null and combined.cards.size() == 5,
		"four real money cards merge onto the previously dropped singleton"): return
	var gid: int = state.cards[loose.uid].group
	_check(expected.all(func(uid): return state.cards[uid].group == gid),
		"money merge preserves all five actual currency units")
	_check(absf(board.rest_origin(combined).y - float(board._settings.rest_y)) < 0.001,
		"money pile does not inherit a suspended singleton's support height")
	_assert_table_origin(gid, "merged money")

func _expanded_money_drop() -> void:
	await _fixture([{"money": 5}])
	var group: Dictionary = board.group_of(board.by_uid[_owned("money")])
	await _click(_point(group.cards[0]), true)
	if not _check(not group.compact, "money pile expands through the original double click"): return
	var members: Array = group.cards.duplicate()
	await _drag(members[0], _empty_point(), true)
	group = board.group_of(members[0])
	_check(group != null and not group.compact and group.cards.size() == 5,
		"moving expanded money preserves its five-card layout")
	if group == null: return
	for index in group.cards.size():
		var expected_y: float = float(board._settings.rest_y) + board._stack_offset(group, index).y
		_check(absf(group.cards[index].global_position.y - expected_y) < 0.001,
			"expanded money layer %d settles at its tabletop offset" % index)
	_assert_table_origin(int(state.cards[members[0].uid].group), "expanded money")

func _network_drop() -> void:
	await _fixture([{"meeting": 1}])
	var card: CardEntity = board.by_uid[_owned("meeting")]
	var observed := {}
	board.network_drop = func(ids: Array, target: int, person: int, at: Vector3) -> bool:
		observed.ids = ids.duplicate()
		observed.at = at
		return true
	await _drag(card, _empty_point(), true)
	board.network_drop = Callable()
	_check(observed.get("ids", []) == [card.uid], "network interception receives the real dragged singleton")
	_check(observed.has("at") and absf(observed.at.y - float(board._settings.rest_y)) < 0.001,
		"network drop sends the tabletop destination instead of the held height")
	_check(absf(card.global_position.y - float(board._settings.rest_y)) < 0.001,
		"network-handled singleton lands while the acknowledgement is pending")

func _restored_placement() -> void:
	await _fixture([{"meeting": 1}, {"slack": 1}, {"money": 5}])
	var saved := {}
	for kind in ["meeting", "slack", "money"]:
		var card: CardEntity = board.by_uid[_owned(kind)]
		var group: Variant = board.group_of(card)
		var at := board.rest_origin(group) if group != null else board.rest_pos(card)
		at.y = Board.DRAG_HEIGHT
		saved[int(state.cards[card.uid].group)] = at
	board.reset_view()
	board._origin_by_gid = saved.duplicate()
	board.group_overrides = saved.duplicate()
	board.sync_state(state)
	await _settle()
	for kind in ["meeting", "slack", "money"]:
		var card: CardEntity = board.by_uid[_owned(kind)]
		var gid: int = state.cards[card.uid].group
		var group: Variant = board.group_of(card)
		var at := board.rest_origin(group) if group != null else board.rest_pos(card)
		_check(absf(at.y - float(board._settings.rest_y)) < 0.001,
			kind + ": restoring a previous suspended placement repairs its height")
		_check(Vector2(at.x - saved[gid].x, at.z - saved[gid].z).length() < 0.001,
			kind + ": restoring placement preserves the player's table position")
		_assert_table_origin(gid, "restored " + kind)
