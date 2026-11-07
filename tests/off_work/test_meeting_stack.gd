extends "res://tests/off_work/test_work_ui.gd"

## Ready stacks are settled before activation, separating actual meeting
## motion from the original pointer's ordinary drag-and-drop landing tween.
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
	for leader_first in [true, false]:
		for compact in [true, false]:
			await _case(leader_first, compact)
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("MEETING_STACK %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _case(leader_first: bool, compact: bool) -> void:
	state.config.rules.initial.groups = [{"leader": 1, "meeting": 1} if leader_first else {"meeting": 1, "leader": 1}, {"employee": 4, "work": 80}]
	main._new_game()
	board.set_process(false)
	await _settle()
	var leader := _owned("leader")
	var tool := _owned("meeting")
	var group: Dictionary = board.group_of(board.by_uid[tool])
	var gid: int = state.cards[tool].group
	if bool(group.compact) != compact: board.toggle_compact(group.cards[board._top_index(group)])
	await _settle()
	_check(group.cards[board._top_index(group)].uid == tool, "ready meeting is front for either arrival order and stack shape")
	var logical_order: Array = state.group_cards(gid).duplicate()
	var positions := {leader: board.by_uid[leader].global_position, tool: board.by_uid[tool].global_position}
	await _capture(leader_first, compact, "before")
	_check(state.activate(tool, gid), "actual leader meeting starts")
	board.sync_state(state)
	await _capture(leader_first, compact, "start")
	var max_shift := 0.0
	for frame in 75:
		state.advance(1.0 / 60.0)
		board.sync_state(state)
		board._advance_meeting_visitors(1.0 / 60.0)
		for uid in positions: max_shift = maxf(max_shift, board.by_uid[uid].global_position.distance_to(positions[uid]))
		await process_frame
		if frame == 14: await _capture(leader_first, compact, "quarter")
	_check(max_shift < 0.001, "activation never lifts or shifts the host combination")
	_check(group.cards[board._top_index(group)].uid == tool, "active meeting remains the native visible top")
	_check(board.by_uid[tool]._task_progress.visible and not board.by_uid[leader]._task_progress.visible, "only front meeting shows the active timer")
	_check(state.group_cards(gid) == logical_order, "visual priority preserves actual group order")
	var targets: Array = state.meetings[tool].targets
	_check(targets.size() == 4, "leader still gathers four eligible people")
	var geometry: Dictionary = board._meeting_geometry(tool)
	_check(geometry.center.is_equal_approx(board.by_uid[tool].global_position), "orbit center is the actual meeting card")
	var before := {}
	for uid in targets:
		before[uid] = board.by_uid[uid].global_position
		_check(board._meeting_visitors[uid].phase == "orbit" and not board.by_uid[uid]._task_progress.visible, "visitor orbits without an individual bar")
	board._advance_meeting_visitors(0.6)
	for uid in targets: _check(board.by_uid[uid].global_position.distance_to(before[uid]) > 0.05, "visitor continues circling the fixed meeting card")
	await _capture(leader_first, compact, "orbit")
	state.advance(float(state.meetings[tool].remaining))
	board.sync_state(state)
	board._advance_meeting_visitors(1.0)
	_check(board._meeting_centers.is_empty() and board._meeting_visitors.is_empty(), "meeting completion releases only temporary visitors")
	for uid in positions: _check(board.by_uid[uid].global_position.distance_to(positions[uid]) < 0.001, "dissolution does not bounce or lower host cards")
	state.advance(float(state.cards[tool].remaining))
	board.sync_state(state)
	_check(state.meetings.has(tool), "same stack automatically repeats after cooldown")
	board._advance_meeting_visitors(0.3)
	for uid in positions: _check(board.by_uid[uid].global_position.distance_to(positions[uid]) < 0.001, "automatic repeat has no accumulated lift")

func _capture(leader_first: bool, compact: bool, stage: String) -> void:
	if not OS.has_environment("WORK_MEETING_STACK_CAPTURE") or DisplayServer.get_name() == "headless": return
	main._update_hud()
	main.hud._detail.hide()
	await RenderingServer.frame_post_draw
	var path := "res://reports/meeting-stack-%s-%s-%s.png" % ["leader-first" if leader_first else "tool-first", "compact" if compact else "expanded", stage]
	_check(root.get_texture().get_image().save_png(path) == OK, "captures actual meeting stack " + stage)
