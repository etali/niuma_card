extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _view(board: OffWorkBoard) -> Dictionary:
	var result := {}
	for uid in board.by_uid:
		var card: OffWorkCard = board.by_uid[uid]
		result[uid] = [card.type, card.card_owner, card.group_id, card.draggable,
			card._visual.visible, card.face_deferred, card._task_progress_active,
			card._task_progress_value, card._task_progress_phase, card._task_progress_source,
			card._debug_timer_enabled, card._debug_remaining, card._material_collision.disabled]
	return {"cards": result, "hidden": board._stack_occluded.duplicate(),
		"representatives": board._stack_representatives.duplicate(),
		"thin": board._thin_stack_cards.duplicate(), "titles": board._muted_stack_titles.duplicate()}

func _fixture(work: int) -> void:
	var construction_started := Time.get_ticks_usec()
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 2, "work": work}, {"transfer": 1}]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(92831)
	var board := OffWorkBoard.new(false)
	root.add_child(board)
	board.set_process(false)
	board.player_bounds = Rect2(-12, -7, 24, 14)
	board.enemy_board.player_bounds = Rect2(-12, -7, 24, 14)
	board.sync_state(state)
	var construction_us := Time.get_ticks_usec() - construction_started
	var uid_count := state.cards.size()
	_check(board.by_uid.size() == uid_count and state.work_count(0) == work and state.work_count(1) == work,
		"large table retains every real work UID and body on both seats")
	var tool := int(state.activity_card_ids().filter(func(uid): return state.cards[uid].type == "transfer")[0])
	state.cards[tool].status = "recovering"
	state.cards[tool].total = 0.5
	state.cards[tool].remaining = 0.5
	board.sync_state(state)
	var revision := state.revision
	var start := Time.get_ticks_usec()
	for frame in 60: board._sync_stack_occlusion()
	var occlusion_us := (Time.get_ticks_usec() - start) / 60.0
	start = Time.get_ticks_usec()
	for frame in 8: board.sync_state(state)
	var sync_us := (Time.get_ticks_usec() - start) / 8.0
	state.advance(0.25)
	board.sync_state(state)
	_check(state.revision == revision, "continuous progress refresh does not rely on a structural revision")
	_check(is_equal_approx(board.by_uid[tool]._task_progress_value, 0.5), "cached refresh still advances tool cooldown")
	var gid := int(state.cards[state.activity_card_ids(0).filter(func(uid): return state.cards[uid].type == "employee")[0]].group)
	var group: Dictionary = board.group_of(board.by_uid[state.group_cards(gid)[0]])
	var top: OffWorkCard = group.cards[board._top_index(group)]
	_check(top.freeze and is_equal_approx(top.gravity_scale, 3.0) and top.continuous_cd
		and top.physics_material_override != null and top.axis_lock_angular_x and top.axis_lock_angular_y and top.axis_lock_angular_z,
		"authoritative material keeps inherited paper physics while remaining frozen")
	_check(top._task_progress_active and is_equal_approx(top._task_progress_value, state.group_work_progress(gid)),
		"visible work representative follows the real shared batch clock")
	board.set_debug_mode(true)
	_check(top._debug_timer_enabled and top._debug_remaining >= 0.0, "debug countdown remains available on the visible work representative")
	state.advance(0.25)
	board.sync_state(state)
	_check(state.cards[tool].status == "ready" and not board.by_uid[tool]._task_progress_active,
		"cooldown completion clears the tool bar even without membership changes")
	var cached := _view(board)
	board._record_sync_key.clear()
	board._stack_occlusion_dependencies.clear()
	board.sync_state(state)
	_check(_view(board) == cached, "cached and complete refresh agree for every UID, bar and occlusion mapping")
	var replacement := state.fork_for_bot(15)
	board.sync_state(replacement)
	_check(board.by_uid.values().all(func(card): return is_same(card.record, replacement.cards[card.uid])),
		"same-revision restored world rebinds every card to the replacement records")
	board.sync_state(state)
	group = board.group_of(board.by_uid[state.group_cards(gid)[0]])
	board.toggle_compact(group.cards[0])
	board.sync_state(state)
	var middle: int = group.work_expanded_indices[group.work_expanded_indices.size() / 2]
	var picked: OffWorkCard = group.cards[middle]
	var original: Array = group.cards.duplicate()
	var suffix: Array = original.slice(middle)
	board._snapshot_press(picked, Vector2.ZERO)
	start = Time.get_ticks_usec()
	board._on_card_clicked(picked)
	board._sync_stack_occlusion()
	var pick_us := Time.get_ticks_usec() - start
	_check(board._drag_cards == suffix and suffix.size() > work / 4,
		"exposed middle layer picks its full real suffix, including hidden work")
	_check(board._drag_cards.any(func(card): return card._visual.visible), "held suffix retains a visible representative")
	start = Time.get_ticks_usec()
	board.cancel_pointer()
	var cancel_us := Time.get_ticks_usec() - start
	board.sync_state(state)
	_check(state.cards.size() == uid_count and state.work_count(0) == work and state.group_cards(gid).size() == original.size(),
		"cancelling the large split preserves all real cards and membership")
	_check(board.group_of(picked).cards == original, "cancel restores the original visual order")
	_check(original.all(func(card): return card.freeze), "snapshot cancellation never leaves authoritative cards dynamic")
	board._on_card_clicked(original[0])
	board._press_snap.clear()
	board.cancel_pointer()
	board.sync_state(state)
	_check(board._drag_cards.is_empty() and original.all(func(card): return card.freeze)
		and board.group_of(picked).cards == original, "cancellation without a press snapshot restores the real pile without dynamic bodies")
	var old_instance := top.get_instance_id()
	start = Time.get_ticks_usec()
	board.reset_view()
	var reset_us := Time.get_ticks_usec() - start
	_check(board.cards.is_empty() and board.enemy_board.cards.is_empty() and board.groups.is_empty()
		and board.enemy_board.groups.is_empty() and board.by_uid.is_empty() and board.offers_by_id.is_empty()
		and board._move_tw.is_empty() and board.enemy_board._move_tw.is_empty(),
		"reset clears both seats, offers, groups and all registered card motion in one batch")
	await process_frame
	_check(not is_instance_id_valid(old_instance), "reset releases the previous real card bodies")
	var next_game := OffWorkState.new(config)
	next_game.new_game(92832)
	board.sync_state(next_game)
	_check(board.by_uid.size() == next_game.cards.size() and board.by_uid.values().all(func(card):
		return is_same(card.record, next_game.cards[card.uid]) and card.freeze),
		"reusing the board for a new large game creates every real UID with fresh records and frozen bodies")
	board.reset_view()
	await process_frame
	board.sync_state(replacement)
	_check(board.by_uid.size() == replacement.cards.size() and board.by_uid.values().all(func(card):
		return is_same(card.record, replacement.cards[card.uid]) and card.group_id == replacement.cards[card.uid].group),
		"restoring a saved large world after reset rebinds the complete original membership")
	print("LARGE_BOARD_TIMING ", JSON.stringify({"cards":uid_count, "occlusion_us":occlusion_us,
		"stable_sync_us":sync_us, "suffix_pick_us":pick_us, "cancel_us":cancel_us,
		"construction_us":construction_us, "reset_us":reset_us, "picked":suffix.size()}))
	board.queue_free()
	await process_frame

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	for work in [2000, 4000]: await _fixture(work)
	for failure in failures: printerr("FAIL ", failure)
	print("LARGE_BOARD_REFRESH %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
