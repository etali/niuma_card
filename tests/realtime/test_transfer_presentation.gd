extends "res://tests/realtime/test_combination_presentation.gd"

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(4)
	game.set_process(false)
	game.sfx.user_muted = true
	game.audio.muted = true
	game.state.config.rules.bot.enabled = false
	game.state.config.rules.initial.groups = [{"employee": 2, "leader": 1, "grinder": 1, "work": 30, "transfer": 1}]
	game._new_game()
	var groups: Array = []
	for uid in game.state.cards:
		if game.state.cards[uid].type != "transfer": continue
		var gid: int = game.state.cards[uid].group
		groups.append(gid)
		_check(game.state.activate(uid, gid), "each mixed group starts continuous transfer")
	game.state.drain_events()
	game.state.advance(5.0)
	game.board.sync_state(game.state)
	await create_timer(0.3, true).timeout
	for gid in groups:
		var bars := _transfer_bars(gid)
		_check(bars.size() == 1 and is_equal_approx(bars[0]._task_progress_value, 0.5), "compact stack shows one half-complete transfer bar")
		game.board._presenter(int(game.state.groups[gid].owner)).toggle_compact(bars[0])
	game.board.sync_state(game.state)
	for gid in groups:
		var bars := _transfer_bars(gid)
		_check(bars.size() == 1 and is_equal_approx(bars[0]._task_progress_value, 0.5), "expanded stack still shows only the shared transfer progress")
		for person in game.state.group_people(gid):
			var view: WorkCard = game.board.by_uid[person]
			_check(not view._task_progress.visible or (bars.size() == 1 and bars[0] == view), "a visible front person may represent the group, but never has a second independent bar")
	var balances := [game.state.money(0), game.state.money(1)]
	for cycle in 3:
		game.state.advance(5.0 if cycle == 0 else 10.0)
		var events: Array = game.state.drain_events()
		var transfers: Array = events.filter(func(e): return e.kind == "transfer")
		_check(transfers.size() == 2, "one event per group per continuous cycle")
		for event in transfers:
			_check(event.ids.size() == 5 and event.participants.size() == 4, "two employees plus grinder plus leader transfer five together")
		_check(not events.any(func(e): return e.kind == "work_complete"), "transfer never falls back to producing cash between batches")
		game._cache_positions()
		game.board.sync_state(game.state)
		for event in transfers: game._present(event)
		if cycle == 0:
			await create_timer(0.28, true).timeout
			game.board.sync_state(game.state)
			for event in transfers:
				for uid in event.ids:
					var card: WorkCard = game.board.by_uid[uid]
					_check(card._visual.is_visible_in_tree() and card._icon.is_visible_in_tree(),
						"buried transferred card actually draws its face in flight: %d" % uid)
					_check(card.global_position.y > 0.65 and card.collision_layer == 0,
						"transferred card clears the table and stays out of hit testing: %d" % uid)
		for gid in groups:
			var bars := _transfer_bars(gid)
			_check(bars.size() == 1 and is_zero_approx(bars[0]._task_progress_value), "next cycle starts immediately with one empty bar")
		_check(game.state.money(0) == balances[0] and game.state.money(1) == balances[1] and game.board._cash_flights.is_empty(), "continuous transfer creates no income or cash animation")
		await create_timer(1.2, true).timeout
	game.state.advance(2.0)
	game.board.sync_state(game.state)
	for gid in groups:
		var bars := _transfer_bars(gid)
		_check(bars.size() == 1 and is_equal_approx(bars[0]._task_progress_value, 0.2), "fourth cycle keeps progressing without another input")
	await _capture("transfer-continuous")
	await _winning_transfer()
	game.queue_free()
	await _frames(3)
	for message in errors: push_error(message)
	print("TRANSFER_PRESENTATION %s (%d checks)" % ["PASS" if errors.is_empty() else "FAIL", checks])
	quit(0 if errors.is_empty() else 1)

func _transfer_bars(group: int) -> Array:
	var result: Array = []
	for uid in game.state.group_cards(group):
		var card: WorkCard = game.board.by_uid[uid]
		if card._task_progress.visible and card._task_progress_phase == "transfer": result.append(card)
	return result

func _winning_transfer() -> void:
	game.state.config.roles.employee.work_seconds = 60.0
	game.state.config.rules.initial.groups = [{"employee": 2, "work": 2}, {"transfer": 1}]
	game._new_game()
	var gid: int = game.state.cards[_person(0)].group
	var tool: int = game.state.cards.values().filter(func(card): return card.type == "transfer" and card.owner == 0)[0].id
	var ids: Array = game.state.group_work(gid)
	game.state.move_cards([tool], gid)
	game.board.sync_state(game.state)
	await create_timer(0.25, true).timeout
	game._process(game.state.config.number("transfer", "seconds"))
	_check(game.state.winner == 0 and game.state.work_count(1) == 4, "last two transfers end the game with the actual recipient counts")
	await create_timer(0.30, true).timeout
	for uid in ids:
		var card: WorkCard = game.board.by_uid[uid]
		_check(card._visual.is_visible_in_tree() and card.global_position.y > 0.65, "final cards still cross the board before settling")
	await create_timer(0.8, true).timeout
	var a: WorkCard = game.board.by_uid[ids[0]]
	var b: WorkCard = game.board.by_uid[ids[1]]
	_check(a.global_position.z < 0 and b.global_position.z < 0 and a.global_position.distance_to(b.global_position) > CardEntity.FACE_SPAN_Y,
		"final documents land on separate layers of the receiving stack")
