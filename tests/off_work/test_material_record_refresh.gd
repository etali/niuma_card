extends SceneTree

class ObservedCard extends OffWorkCard:
	var progress_writes := 0
	func set_task_progress(value: float, active: bool, paused := false, phase := "work", source_uid := -1) -> void:
		progress_writes += 1
		super.set_task_progress(value, active, paused, phase, source_uid)

var checks := 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _appearance(card: OffWorkCard) -> Array:
	return [card.card_owner, card.group_id, card._task_progress_active,
		card._task_progress_value, card._task_progress_paused, card._task_progress_phase,
		card._task_progress_source, card._task_completion_hold, card._task_progress.visible,
		card._debug_timer.visible, card._icon.modulate if card._icon != null else Color.WHITE]

func _refresh_pair(card: OffWorkCard, full: OffWorkCard, data: Dictionary) -> void:
	card.update_record(data)
	# Reference executes the same complete production path, without its shortcut.
	full._material_record_visuals_current = false
	full.update_record(data)
	_check(_appearance(card) == _appearance(full), "cached and complete record refresh have identical visible state")

func _batch(people: int) -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": people, "work": 80}]
	config.rules.initial.money = 0
	config.cards.work.work_seconds = 10.0
	var state := OffWorkState.new(config)
	state.new_game(92836)
	var board := OffWorkBoard.new(false)
	root.add_child(board)
	board.set_process(false)
	board.player_bounds = Rect2(-12, -7, 24, 14)
	board.enemy_board.player_bounds = board.player_bounds
	board.sync_state(state)
	_check(not board.native_recipe_progress_enabled and not board.enemy_board.native_recipe_progress_enabled,
		"both realtime desks omit absent native badges while keeping actual group timers")
	state.drain_events()
	state.advance(10.0)
	var completed := state.drain_events().filter(func(event): return event.kind == "work_complete")
	board.sync_state(state)
	_check(completed.size() == 2 and state.work_count(0) == 80 - people and state.work_count(1) == 80 - people
		and state.money(0) == people * config.income_per_work("employee")
		and board.by_uid.size() == state.cards.size(),
		"a real %d-person batch replaces exactly its consumed work with real income on both desks" % people)
	state.advance(2.5)
	board.sync_state(state)
	var projected := board._group_progress_cards.keys()
	_check(projected.size() == 2 and projected.all(func(uid): return board.by_uid[uid]._task_progress_active \
		and is_equal_approx(board.by_uid[uid]._task_progress_value, 0.25)),
		"both next batches expose their real quarter-progress after structural settlement")
	var former := int(projected[0])
	_check(state.move_cards([former], -1), "the previous work-bar UID can be split into a real independent pile")
	board.sync_state(state)
	_check(not board.by_uid[former]._task_progress_active and not board.by_uid[former]._task_progress.visible,
		"splitting the old representative clears its bar instead of retaining cached group progress")
	var cached := {}
	for uid in board.by_uid: cached[uid] = _appearance(board.by_uid[uid])
	for uid in board.by_uid:
		board.by_uid[uid]._material_record_visuals_current = false
		board.by_uid[uid].update_record(state.cards[uid])
	board._sync_group_task_progress()
	_check(board.by_uid.keys().all(func(uid): return _appearance(board.by_uid[uid]) == cached[uid]),
		"every UID agrees with a complete refresh after real settlement and splitting")
	var replacement := state.fork_for_bot(17)
	board.sync_state(replacement)
	_check(board.by_uid.values().all(func(card): return is_same(card.record, replacement.cards[card.uid]) \
		and card.card_owner == replacement.cards[card.uid].owner and card.group_id == replacement.cards[card.uid].group),
		"restored same-revision records rebind every material owner and group")
	board.queue_free()
	await process_frame

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	var config := OffWorkConfig.new()
	var state := OffWorkState.new(config)
	state.new_game(92835)
	for kind in ["work", "money"]:
		for deferred in [false, true]:
			var uid := state.add_card(kind, 0)
			var data: Dictionary = state.cards[uid].duplicate(true)
			var card := ObservedCard.new()
			var full := OffWorkCard.new()
			for item in [card, full]:
				item.configure(data, config.cards[kind], false, deferred)
				item.freeze = true
				root.add_child(item)
			var writes := card.progress_writes
			for index in 50:
				data = data.duplicate(true)
				data.owner = index % 2
				data.group = 1000 + index
				data.progress = float(index) / 100.0
				card.update_record(data)
			_check(card.progress_writes == writes, "unchanged material avoids all repeated progress/visual writes")
			_check(is_same(card.record, data) and card.card_owner == data.owner and card.group_id == data.group
				and card._task_progress_value == data.progress,
				"each replacement record and changed ownership/group is still rebound")
			_refresh_pair(card, full, data)
			for item in [card, full]: item.set_task_progress(0.6, true, true, "transfer", uid)
			_refresh_pair(card, full, data)
			_check(not card._task_progress_active and card._task_progress_phase == "idle" and card._task_progress_source == uid,
				"refresh clears an old UID's projected group progress before it can move to another group")
			for item in [card, full]:
				item.set_task_progress(0.6, true)
				item.flash_task_completion()
			_refresh_pair(card, full, data)
			_check(card._task_completion_hold == 0.0, "material refresh clears a stale group completion hold")
			data = data.duplicate(true)
			data.status = "recovering"
			data.progress = 0.25
			_refresh_pair(card, full, data)
			data = data.duplicate(true)
			data.status = "ready"
			data.progress = 0.0
			_refresh_pair(card, full, data)
			for item in [card, full]: item.reveal_stack_face()
			_refresh_pair(card, full, data)
			_check(card._plate != null and not card._material_collision.disabled and card._icon.modulate == Color.WHITE,
				"revealing a deferred material builds and refreshes the full original face")
			card.queue_free()
			full.queue_free()
			await process_frame
	for people in [12, 24]: await _batch(people)
	for failure in failures: printerr("FAIL ", failure)
	print("MATERIAL_RECORD_REFRESH %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
