# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/off_work/test_side_extract.gd"

## Course input goes through actual side-label clicks, fan drags and table drops.
func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-tool-lessons-%d" % OS.get_process_id())
	root.size = Vector2i(1280, 800)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	board.touch_mode = true
	state = main.state
	await _extract_lesson()
	await _meeting_lesson()
	await _transfer_lesson()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_TOOL_LESSONS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _begin_lesson(id: String) -> bool:
	main.begin_practice(id)
	state = main.state
	await _settle()
	return _check(main.lesson.lesson.get("id") == id and main.lesson.step == 0, "%s starts its actual practice table" % id)

func _open_type(gid: int, kind: String) -> bool:
	var members: Array = state.group_cards(gid)
	var visual: Dictionary = board.group_of(board.by_uid[members[0]])
	var rows: Array = board.side_extract.side_rows(visual)
	var index := rows.find_custom(func(row): return row.kind == kind)
	if not _check(index >= 0, "%s has a visible type entry on the real pile" % kind): return false
	var label: Node3D = visual.side[index * 2 + 1]
	var at := board.camera.unproject_position(label.global_position)
	if not _check(board.side_extract.hit_test(at).get("kind") == kind, "%s side label has the correct actual hit target" % kind): return false
	await _click(at)
	return _check(board.side_extract.is_open() and board.side_extract.view.kind == kind,
		"actual %s side click opens the matching inspection fan" % kind)

func _drag_fan_to_empty(index: int) -> bool:
	var destination: Vector3 = main.hud._practice_gesture.cue.get("target_world", Vector3.INF)
	if not _check(destination.is_finite(), "the lesson gesture supplies its actual extraction destination"): return false
	if not _check(board.player_bounds.has_point(Vector2(destination.x, destination.z)),
		"the gesture's extraction destination stays inside the player's table"): return false
	var target: Vector2 = main.hud._practice_gesture.world_anchor(destination)
	if not _check(main.hud.content_rect().has_point(target) and not main.hud._practice_panel.get_global_rect().has_point(target),
		"the gesture's extraction destination is visible and uncovered by its instruction panel"): return false
	var fan: Control = board.side_extract.view
	var press: Vector2 = fan.screen_point_for_index(index)
	await _button(press, true)
	var motion := InputEventMouseMotion.new()
	motion.position = press + Vector2(float(board._settings.side_extract.drag_threshold) + 5.0, 0.0)
	motion.global_position = motion.position
	motion.relative = motion.position - press
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer = motion.position
	root.push_input(motion)
	await process_frame
	board._process(0.0)
	if not _check(board.is_dragging(), "moving the pressed fan card starts the original card drag"): return false
	await _move_held_to(destination)
	await _release_held()
	return true

func _check_type_cue(kind: String, dragging: bool) -> void:
	var gesture: Control = main.hud._practice_gesture
	if not _check(is_instance_valid(gesture), "%s extraction has a live tutorial gesture" % kind): return
	var source: Node = gesture.cue.get("source")
	if not _check(is_instance_valid(source), "%s gesture has an actual source node" % kind): return
	var at: Vector2 = gesture.anchor(source)
	_check(not main.hud._practice_panel.get_global_rect().has_point(at),
		"%s guidance panel leaves its actual side or fan click target exposed" % kind)
	if dragging:
		_check(gesture.cue.get("gesture") == "drag" and source == board.side_extract.view
			and board.side_extract.view.index_at_screen_point(at) == 0 and gesture.cue.has("target_world"),
			"%s gesture points at the first exposed fan card and an empty table destination" % kind)
	else:
		_check(gesture.cue.get("gesture") == "tap" and source is Label3D
			and board.side_extract.hit_test(at).get("kind") == kind,
			"%s gesture taps the real matching type label" % kind)

func _close_fan_with_escape() -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.pressed = pressed
		root.push_input(event)
		await process_frame
	await _settle()
	_check(not board.side_extract.is_open() and not main.practice.is_empty(), "Escape closes the fan while preserving the current lesson")

func _extract_lesson() -> void:
	if not await _begin_lesson("extract"): return
	var people := _owned_ids("employee")
	var gid: int = state.cards[people[0]].group
	var original: Array = state.group_cards(gid).duplicate()
	var work: Array = state.group_work(gid).duplicate()
	var overtime: Array = state._group_type(gid, "overtime").duplicate()
	_check(people.size() == 3 and work.size() == 200 and overtime.size() == 1,
		"deep pile contains the real three employees, two hundred work and one overtime card")
	_check_type_cue("employee", false)
	if not await _open_type(gid, "employee"): return
	main._process(0.01)
	_check(main.lesson.step == 1 and state.group_cards(gid) == original,
		"inspection completes its lesson step without changing membership or starting extraction")
	var fan: Control = board.side_extract.view
	_check(fan.records.size() == 3 and fan.records.all(func(record): return record.type == "employee"),
		"employee fan exposes only its three actual personnel")
	_check_type_cue("employee", true)
	await _close_fan_with_escape()
	_check_type_cue("employee", false)
	if not await _open_type(gid, "employee"): return
	_check_type_cue("employee", true)
	if not await _drag_fan_to_empty(0): return
	main._process(0.01)
	var destination: int = state.cards[people[0]].group
	var extracted: Array = state.group_cards(destination)
	_check(destination != gid and extracted.size() == 3 and people.all(func(id): return extracted.has(id)),
		"fan drag moves precisely three employee UIDs into their own pile")
	_check(state.group_work(gid) == work and state._group_type(gid, "overtime") == overtime
		and state.group_cards(gid).size() == 201,
		"all two hundred work cards and overtime stay in the source pile")
	_check(main.lesson.complete() and not main.lesson.used_demo, "side-click and fan-drag input completes extraction without demonstration")

func _meeting_lesson() -> void:
	if not await _begin_lesson("meeting"): return
	var host_id := _owned("leader")
	var meeting := _owned("meeting")
	var worker := _owned("employee")
	var host_group: int = state.cards[host_id].group
	var worker_group: int = state.cards[worker].group
	var work_before: int = state.work_count(0)
	var enemy_work: int = state.work_count(1)
	_check(host_group != worker_group and state.group_work(host_group).is_empty(),
		"meeting lesson separates its host from the colleague's work pile")
	var cue: Dictionary = main.hud._practice_gesture.cue
	_check(cue.get("gesture") == "drag" and cue.get("source") == board.by_uid[meeting]
		and cue.get("target") == board.by_uid[host_id], "meeting gesture targets the real own independent host")
	await _drag(board.by_uid[meeting], _point(board.by_uid[host_id]))
	main._process(0.01)
	if not _check(state.meetings.has(meeting) and main.lesson.step == 1, "dropping meeting onto own host starts the real meeting step"): return
	var session: Dictionary = state.meetings[meeting]
	_check(session.host == host_id and not session.targets.is_empty()
		and session.targets.all(func(id): return state.cards[id].owner == 1 and state.is_meeting_target(id)),
		"meeting summons and pauses actual opponent personnel")
	_check(state.tasks.get(worker, {}).get("kind") == "work" and not state.cards[worker].paused,
		"the other own employee keeps working while the independent host runs the meeting")
	main._process(float(state.config.roles.employee.work_seconds) + 0.01)
	_check(main.lesson.complete() and state.work_count(0) < work_before
		and state.work_count(1) == enemy_work and state.meetings.has(meeting),
		"own production settles during the active meeting while the opponent's work remains")
	_check(not main.lesson.used_demo, "meeting course completes through actual tool input and game time")

func _transfer_lesson() -> void:
	if not await _begin_lesson("transfer"): return
	var tool := _owned("transfer")
	var worker := _owned("employee")
	var gid: int = state.cards[worker].group
	var own_work: int = state.work_count(0)
	var enemy_work: int = state.work_count(1)
	var cash: int = state.money(0)
	var cue: Dictionary = main.hud._practice_gesture.cue
	_check(cue.get("gesture") == "drag" and cue.get("source") == board.by_uid[tool]
		and cue.get("target") == board.by_uid[worker], "transfer gesture targets the real own working personnel")
	await _drag(board.by_uid[tool], _point(board.by_uid[worker]))
	main._process(0.01)
	if not _check(state.tasks.get(worker, {}).get("kind") == "transfer" and main.lesson.step == 1,
		"dragging transfer into personnel and work starts the real transfer cycle"): return
	main._process(state.config.number("transfer", "seconds") + 0.01)
	var sent: int = own_work - state.work_count(0)
	_check(main.lesson.step == 2 and sent > 0 and state.work_count(1) == enemy_work + sent
		and state.money(0) == cash,
		"one transfer cycle moves real work without income (step %d, sent %d, opponent %d to %d, cash %d to %d)" %
		[main.lesson.step, sent, enemy_work, state.work_count(1), cash, state.money(0)])
	_check_type_cue("transfer", false)
	if not await _open_type(gid, "transfer"): return
	_check_type_cue("transfer", true)
	await _close_fan_with_escape()
	_check_type_cue("transfer", false)
	if not await _open_type(gid, "transfer"): return
	_check_type_cue("transfer", true)
	if not await _drag_fan_to_empty(0): return
	_check(state.cards[tool].group != gid and state.tasks.get(worker, {}).get("kind") == "work",
		"extracting only the transfer tool immediately resumes the original work group")
	var remaining: int = state.work_count(0)
	main._process(float(state.config.roles.employee.work_seconds) + 0.01)
	_check(main.lesson.complete() and state.work_count(0) < remaining and state.money(0) > cash,
		"resumed work actually settles income and completes the transfer course")
	_check(not main.lesson.used_demo, "transfer and restoration complete through original drag input")
