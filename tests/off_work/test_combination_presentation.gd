extends SceneTree

## Five workers share one progress bar and one completion event; each money unit flies independently.
var game: Node
var checks := 0
var errors: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(4)
	# This is a presentation/state fixture. A headless audio mixer can still
	# retain its final WAV playback when fast parallel test processes exit.
	if DisplayServer.get_name() == "headless":
		game.sfx.user_muted = true
		game.audio.muted = true
	game.hud.drawer_window.pin()
	game.set_process(false)
	game.state.config.rules.initial.groups = [{"employee": 3, "grinder": 2, "work": 15}]
	game.state.config.rules.bot.enabled = false
	game._new_game()
	game.state.drain_events()
	game.state.advance(4.0)
	game.board.sync_state(game.state)
	await create_timer(0.4, true).timeout
	var groups: Array = []
	for owner in [0, 1]:
		var gid: int = game.state.cards[_person(owner)].group
		groups.append(gid)
		var bars := _work_bars(gid)
		_check(bars.size() == 1, "one compact combination bar for owner " + str(owner))
		if not bars.is_empty(): _check(is_equal_approx(bars[0]._task_progress_value, 0.4), "combination bar reads real shared progress")
		for person in game.state.group_people(gid):
			_check(is_equal_approx(game.state.cards[person].progress, 0.4), "all working roles share the same time")
	# Expanded original layout must not expose five personal work bars.
	var leader: OffWorkCard = game.board.by_uid[_person(0)]
	game.board.toggle_compact(leader)
	game.board.sync_state(game.state)
	await create_timer(0.3, true).timeout
	_check(_work_bars(groups[0]).size() == 1, "expanded five-person stack still has one work bar")
	await _capture("progress")
	var before := [game.state.money(0), game.state.money(1)]
	game.state.advance(6.0)
	var events: Array = game.state.drain_events().filter(func(e): return e.kind == "work_complete")
	_check(events.size() == 2, "two groups emit two events, not ten individual settlements")
	game._cache_positions(events)
	game.board.sync_state(game.state)
	for event in events:
		_check(event.ids.size() == 5 and event.participants.size() == 5, "one event owns all five completed documents and workers")
		_check(event.amount == 7, "three employees and two grinders earn seven together")
		_check(game.state.money(event.owner) - before[event.owner] == 7, "wallet matches the combined settlement")
		game._present(event)
	_check(game.board._cash_flights.size() == 14, "two combination settlements launch fourteen real one-money cards")
	for event in events:
		_check(event.money_ids.size() == 7 and event.money_ids.all(func(uid): return game.board._cash_flights.has(uid) and game.state.cards[uid].amount == 1), "all seven actual income cards follow the combined settlement")
	for gid in groups:
		_check(_work_bars(gid).size() == 1, "batch flash does not expose individual worker bars")
	_check(game.state.work_count(0) == 10 and game.state.work_count(1) == 10, "each group removes exactly five work cards")
	await _frames(3)
	await _capture("settlement")
	await create_timer(OffWorkUI.number("task_progress", "completion_hold_seconds") + 0.05, true).timeout
	game.state.advance(1.0)
	game.board.sync_state(game.state)
	for gid in groups:
		var bars := _work_bars(gid)
		_check(bars.size() == 1 and is_equal_approx(bars[0]._task_progress_value, 0.1), "next batch restarts one shared timer")
	await _locked_meeting_presentation()
	await _outsource()
	game.queue_free()
	await _frames(3)
	for message in errors: push_error(message)
	print("COMBINATION_PRESENTATION %s (%d checks)" % ["PASS" if errors.is_empty() else "FAIL", checks])
	quit(0 if errors.is_empty() else 1)

func _locked_meeting_presentation() -> void:
	game.state.config.rules.initial.groups = [{"employee": 2, "work": 8}]
	game._new_game()
	game.state.advance(2.0)
	var tools := {}
	for owner in [0, 1]:
		var gid: int = game.state.cards[_person(owner)].group
		var meeting: int = game.state.add_card("meeting", owner)
		tools[owner] = meeting
		game.state.move_cards([meeting], gid)
	game.board.sync_state(game.state)
	for compact in [true, false]:
		for owner in [0, 1]:
			var person: OffWorkCard = game.board.by_uid[_person(owner)]
			var presenter: Board = game.board if owner == 0 else game.board.enemy_board
			var group: Dictionary = presenter.group_of(person)
			if bool(group.compact) != compact: presenter.toggle_compact(person)
		game.board.sync_state(game.state)
		await create_timer(0.3, true).timeout
		for owner in [0, 1]:
			var gid: int = game.state.cards[_person(owner)].group
			var presenter: Board = game.board if owner == 0 else game.board.enemy_board
			var group: Dictionary = presenter.group_of(game.board.by_uid[_person(owner)])
			var top: OffWorkCard = group.cards[presenter._top_index(group)]
			_check(game.state.groups[gid].function == "work" and game.state.cards[tools[owner]].status == "ready",
				"adding an unused meeting keeps the actual work function")
			_check(top.type == "work" and top._task_progress.is_visible_in_tree() and _work_bars(gid) == [top],
				"both stack shapes and owners keep the sole work bar on the exposed work card")
			_check(is_equal_approx(top._task_progress_value, 0.2), "unused meeting preserves the visible twenty-percent work progress")
	var meeting: int = tools[0]
	var work_group: int = game.state.cards[meeting].group
	game.state.move_cards([meeting], -1)
	var meeting_group: int = game.state.cards[meeting].group
	game.state.move_cards(game.state.group_people(work_group), meeting_group)
	game.state.move_cards(game.state.group_work(work_group), meeting_group)
	for phase in ["meeting", "recovering"]:
		game.board.sync_state(game.state)
		for compact in [true, false]:
			var view: OffWorkCard = game.board.by_uid[meeting]
			var group: Dictionary = game.board.group_of(view)
			if bool(group.compact) != compact: game.board.toggle_compact(view)
			game.board.sync_state(game.state)
			var top: OffWorkCard = group.cards[game.board._top_index(group)]
			_check(top == view and top._task_progress.is_visible_in_tree() and top._task_progress_phase == phase,
				"actual meeting stays exposed during activity and cooldown in both stack shapes")
			_check(_work_bars(meeting_group).is_empty(), "meeting and its cooldown expose no ordinary work progress")
		if phase == "meeting": game.state.advance(game.state.config.number("meeting", "duration_seconds"))

func _outsource() -> void:
	game.state.config.rules.initial.groups = [{"employee": 1}, {"work": 12}, {"outsource": 1}]
	game._new_game()
	var wallets: Array = []
	var tool := -1
	var gid := -1
	for id in game.state.cards:
		var data: Dictionary = game.state.cards[id]
		if data.owner != 0: continue
		if data.type == "money": wallets.append(id)
		if data.type == "outsource": tool = id
		if data.type == "work": gid = data.group
	game.state.move_cards(wallets, gid)
	game.state.move_cards([tool], gid)
	game.state.drain_events()
	_check(game.state.cards[tool].status == "active", "cash, work and outsource form a timed combination without a worker")
	var duration: float = game.state.config.number("outsource", "seconds")
	game.state.advance(duration * 0.5)
	game.board.sync_state(game.state)
	game._update_hud()
	await create_timer(0.3, true).timeout
	var view: OffWorkCard = game.board.by_uid[tool]
	_check(view._task_progress.visible and view._task_progress_phase == "outsource" and is_equal_approx(view.task_progress_display_value(), 0.5), "outsource tool shows its actual halfway progress")
	_check(game.state.work_count(0) == 12 and game.state.money(0) == 8, "reading outsource bar does not consume materials early")
	_check(_work_bars(gid).is_empty(), "outsource does not borrow an ordinary personnel work bar")
	game.board.toggle_compact(view)
	game.board.sync_state(game.state)
	var native_group: Dictionary = game.board.group_of(view)
	var top: OffWorkCard = native_group.cards[game.board._top_index(native_group)]
	_check(not native_group.compact and top._task_progress.visible and top._task_progress_phase == "outsource", "expanded outsourcing exposes the timer on its visible top")
	_check(is_equal_approx(top.task_progress_display_value(), 0.5), "expanded pile projects exactly the same outsourcing progress")
	game.board.toggle_compact(view)
	game.board.sync_state(game.state)
	await create_timer(0.3, true).timeout
	await _capture("outsource")
	game.state.advance(duration * 0.5)
	var events: Array = game.state.drain_events()
	var batches: Array = events.filter(func(e): return e.kind == "outsource")
	_check(batches.size() == 1 and batches[0].ids.size() == 8 and batches[0].spent == 8, "outsource completes eight work for eight money in one event")
	_check(events.filter(func(e): return e.kind == "work_complete").is_empty(), "outsource never produces work income")
	game.board.sync_state(game.state)
	for event in events: game._present(event)
	_check(game.state.work_count(0) == 4 and game.state.money(0) == 0 and game.board._cash_flights.is_empty(), "only unmatched work remains and no income flies out")
	_check(view._task_progress.visible and view._task_progress_phase == "recovering", "durable outsource begins its real recovery timer")

func _person(owner: int) -> int:
	for id in game.state.cards:
		if game.state.cards[id].owner == owner and game.state.cards[id].type == "employee": return id
	return -1

func _work_bars(group: int) -> Array:
	var result: Array = []
	for uid in game.state.group_cards(group):
		var card: OffWorkCard = game.board.by_uid[uid]
		if card._task_progress.visible and card._task_progress_phase == "work": result.append(card)
	return result

func _capture(name: String) -> void:
	if not OS.has_environment("WORK_COMBINATION_CAPTURE"): return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://reports")
	root.get_texture().get_image().save_png("res://reports/combination-" + name + ".png")

func _frames(count: int) -> void:
	for index in count: await process_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)
