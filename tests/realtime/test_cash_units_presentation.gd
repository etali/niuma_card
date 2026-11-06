extends "res://tests/realtime/test_work_ui.gd"

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	board.touch_mode = true
	board.set_process(false)
	state = main.state
	state.config.rules.bot.enabled = false
	_check_opening_without_frames()
	await _settle()
	await _opening_income()
	state.config.rules.initial.groups = [{"employee": 3, "work": 30}]
	state.config.rules.initial.money = 0
	main._new_game()
	state.drain_events()
	await _settle()
	var bank := -1
	for batch in 3:
		state.advance(10.0)
		var events: Array = state.drain_events().filter(func(e): return e.kind == "work_complete")
		_check(events.size() == 2, "each side settles its production group once")
		board.sync_state(state)
		for event in events:
			_check(event.money_ids.size() == 3, "three workers produce three real currency identities")
			board.play_event(event)
			if int(event.owner) == 0: bank = int(event.money_group)
		_check(board._cash_flights.size() == 6, "all six newly produced units take a real flight")
		board._advance_cash_flights(0.28)
		board.sync_state(state)
		for event in events:
			for uid in event.money_ids:
				var card: WorkCard = board.by_uid[uid]
				_check(not card.draggable and not card.input_ray_pickable and card.collision_layer == 0 and card.collision_mask == 0,
					"each individual income card remains non-interactive throughout flight")
		board._advance_cash_flights(2.0)
		await _settle()
	var money: Array = state.group_cards(bank)
	_check(money.size() == 9 and state.money(0) == 9, "three production cycles visibly and logically yield nine money cards")
	var visual: Dictionary = board.group_of(board.by_uid[money[0]])
	_check(visual.cards.size() == 9 and visual.compact, "native compact stack contains all nine actual cards")
	var positions: Array = []
	for card in visual.cards:
		_check(state.cards[card.uid].amount == 1 and card.draggable, "each landed card represents exactly one spendable unit")
		positions.append(board.rest_pos(card))
	for a in positions.size():
		for b in range(a + 1, positions.size()):
			_check(positions[a].distance_to(positions[b]) > 0.01, "nine-card stack exposes nine distinct layers")
	var labels: Array = visual.side.filter(func(node): return node is Label3D)
	_check(labels.any(func(label): return label.text == "×9"), "native side label matches the nine visible cards")
	if OS.get_environment("WORK_CASH_UNITS_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await process_frame
		RenderingServer.force_draw(false)
		_check(root.get_texture().get_image().save_png("res://reports/cash-nine-real-cards.png") == OK, "nine-card screenshot saved")
	# Expand through the actual input path, then split just the last card.
	await _click(_point(visual.cards[0]), true)
	_check(not visual.compact, "double click exposes the actual individual currency cards")
	var last: WorkCard = visual.cards.back()
	await _drag(last, _empty_point(), true)
	_check(state.cards[last.uid].group != bank and state.group_cards(int(state.cards[last.uid].group)).size() == 1,
		"dragging one expanded card splits exactly one money card")
	_check(state.group_cards(bank).size() == 8 and state.money(0) == 9 and state.cards[last.uid].amount == 1,
		"splitting leaves eight money in the original pile and one outside without changing value")
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("CASH_UNITS_PRESENTATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check_opening_without_frames() -> void:
	main._new_game()
	for owner in [0, 1]:
		var cash: Array = state.cards.keys().filter(func(uid): return state.cards[uid].type == "money" and int(state.cards[uid].owner) == owner)
		_check(cash.size() == 8, "both sides create eight initial money cards synchronously")
		var presenter: Board = board if owner == 0 else board.enemy_board
		for uid in cash:
			_check(board.by_uid[uid].global_position.distance_to(presenter.rest_pos(board.by_uid[uid])) < 0.0001 and not presenter._move_tw.has(board.by_uid[uid]), "initial cash is already at rest without advancing one animation frame")
		for a in cash.size():
			for b in range(a + 1, cash.size()):
				_check(board.by_uid[cash[a]].global_position.distance_to(board.by_uid[cash[b]].global_position) > 0.01, "initial money is visibly separated even before the first frame or drawer resume")
	# Simulate reset while an enclosing UI pause prevents all ordinary tweens.
	root.get_tree().paused = true
	main._new_game()
	var paused_cash: Array = state.cards.keys().filter(func(uid): return state.cards[uid].type == "money" and int(state.cards[uid].owner) == 0)
	var positions: Array = paused_cash.map(func(uid): return board.by_uid[uid].global_position)
	_check(positions.size() == 8 and positions[0].distance_to(positions[-1]) > 0.1, "paused new game also has a complete eight-card pile immediately")
	root.get_tree().paused = false

func _opening_income() -> void:
	var cash: Array = state.cards.keys().filter(func(uid): return state.cards[uid].type == "money" and int(state.cards[uid].owner) == 0)
	_check(cash.size() == 8 and state.money(0) == 8, "default opening has eight actual money cards before any income")
	var pile: Dictionary = board.group_of(board.by_uid[cash[0]])
	var before: Array = []
	for card in pile.cards:
		_check(card.is_visible_in_tree() and card._visual.visible, "every opening money card is visible from the start")
		before.append(board.rest_pos(card))
	for a in before.size():
		for b in range(a + 1, before.size()): _check(before[a].distance_to(before[b]) > 0.01, "opening money layers are distinct before production")
	await _capture_money("cash-opening-eight.png")
	state.move_cards([_owned("employee")], int(state.cards[_owned("work")].group))
	state.drain_events()
	board.sync_state(state)
	state.advance(10.0)
	var events: Array = state.drain_events().filter(func(e): return e.kind == "work_complete" and int(e.owner) == 0)
	_check(events.size() == 1 and events[0].money_ids.size() == 1, "first employee completion adds exactly one actual money card")
	board.sync_state(state)
	for event in events: board.play_event(event)
	board._advance_cash_flights(2.0)
	await _settle()
	var after: Array = state.group_cards(int(state.cards[cash[0]].group))
	_check(after.size() == 9 and state.money(0) == 9 and cash.all(func(uid): return after.has(uid)), "first payout preserves the eight opening UIDs and adds only a ninth")
	main._update_hud()
	_check(main.hud.lbl_player_res.text.contains("钱9"), "the first payout also updates the original HUD to nine")
	await _capture_money("cash-first-income-nine.png")

func _capture_money(filename: String) -> void:
	if OS.get_environment("WORK_CASH_UNITS_CAPTURE") != "1" or DisplayServer.get_name() == "headless": return
	main._update_hud()
	await process_frame
	RenderingServer.force_draw(false)
	_check(root.get_texture().get_image().save_png("res://reports/" + filename) == OK, "actual opening/income frame saved")
