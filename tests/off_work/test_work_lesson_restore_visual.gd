# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/off_work/test_work_ui.gd"

## Entering/closing practice reconstructs card views while reusing the table.
## Check actual faces and contact shadows through that reconstruction.
var _transient_shadow_samples: Array = []

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-lesson-restore-visual-%d" % OS.get_process_id())
	root.size = Vector2i(1280, 800)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	state = main.state
	await _settle()
	_check_table("initial", true)
	for lesson_id in ["first", "extract", "overtime", "upgrade", "meeting", "transfer", "interrupt", "solo"]:
		main.begin_practice(lesson_id)
		_check_table("%s enter immediate" % lesson_id, false)
		await process_frame
		_check_table("%s enter next frame" % lesson_id, false)
		await _settle()
		_check_table("%s enter settled" % lesson_id, true)
		main.finish_practice()
		_check_table("%s exit immediate" % lesson_id, false)
		await process_frame
		_check_table("%s exit next frame" % lesson_id, false)
		await _settle()
		_check_table("%s exit settled" % lesson_id, true)
	# Switching several courses before queued old nodes are freed must not let
	# a callback address a new card that happens to reuse the same record UID.
	for cycle in 3:
		for lesson_id in ["extract", "upgrade", "meeting", "transfer"]:
			main.begin_practice(lesson_id)
			main.finish_practice()
		await _settle()
		_check_table("rapid cycle %d" % cycle, true)
	# A real session normally has nonzero time. Restoring it takes the regular
	# animated layout path, including when the user's previous pause is restored.
	main.state.advance(0.5)
	board.sync_state(main.state)
	await _settle()
	for pause_game in [false, true]:
		main.hud.set_manual_paused(pause_game)
		for lesson_id in ["extract", "interrupt"]:
			main.begin_practice(lesson_id)
			await _settle()
			main.finish_practice()
			_check_table("elapsed pause=%s %s exit immediate" % [pause_game, lesson_id], false)
			await _settle()
			_check_table("elapsed pause=%s %s exit settled" % [pause_game, lesson_id], true)
	main.hud.set_manual_paused(false)
	# Match the report's mature, mixed pile; restoration is a snapshot, not a
	# new player move, and must already be placed when the original game pauses.
	main.state.config.rules.initial.groups = [{"work":153,"employee":2,"grinder":2,"overtime":3}]
	main._new_game()
	main.state.advance(0.5)
	board.sync_state(main.state)
	await _settle()
	var original_person: int = main.state._owner_type(0, "employee")[0]
	_check(board.open_side_extract(int(main.state.cards[original_person].group), "employee"),
		"original mixed pile opens its type fan before entering the lesson")
	main.begin_practice("extract")
	_check(not board.side_extract.is_open(), "entering the lesson closes the original table's type fan")
	main.finish_practice()
	main.hud.set_manual_paused(true)
	main.begin_practice("extract")
	await _settle()
	var lesson_person: int = main.state._owner_type(0, "employee")[0]
	_check(board.open_side_extract(int(main.state.cards[lesson_person].group), "employee"),
		"practice pile opens its type fan before restoring the original table")
	main.finish_practice()
	_check(not board.side_extract.is_open(), "leaving the lesson closes its type fan before restoring reused card UIDs")
	_check_rest_layout("mixed paused restore immediate")
	_check_table("mixed paused restore immediate", false)
	await _settle()
	_check_rest_layout("mixed paused restore after waiting")
	_check_cached_shadows("mixed paused restore after waiting")
	_check_table("mixed paused restore after waiting", true)
	main.hud.set_manual_paused(false)
	print("LESSON_SHADOW_DIAGNOSTIC ", JSON.stringify(_transient_shadow_samples))
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_LESSON_RESTORE_VISUAL %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check_rest_layout(label_text: String) -> void:
	var displaced: Array = []
	for card in board.by_uid.values():
		if board._has_external_pose(card.uid): continue
		var final_position: Vector3 = board._presenter(card.card_owner).rest_pos(card)
		if card.global_position.distance_to(final_position) > 0.001:
			displaced.append({"id": card.uid, "kind": card.def_id, "at": str(card.global_position), "to": str(final_position)})
	if not displaced.is_empty():
		print("LESSON_RESTORE_LAYOUT_DIAGNOSTIC ", label_text, " ", displaced.size(), " displaced; ", JSON.stringify(displaced.slice(0, 6)))
	_check(displaced.is_empty(), "%s places every snapshot card at its rest position (%d still moving)" % [label_text, displaced.size()])

func _check_cached_shadows(label_text: String) -> void:
	for child in main.get_children():
		if not child is TableLighting: continue
		var expected: Array = TableLighting.contact_footprints(child._board.cards)
		if child._last_data != expected:
			print("LESSON_SHADOW_CACHE_DIAGNOSTIC ", label_text, " ", child.name,
				" cached=", child._last_data.size(), " expected=", expected.size(),
				" cached_first=", child._last_data[0] if not child._last_data.is_empty() else {},
				" expected_first=", expected[0] if not expected.is_empty() else {})
		_check(child._last_data == expected, "%s %s shadow geometry reflects the restored faces before pause" % [label_text, child.name])
		_check(child._multimesh.visible_instance_count == expected.size(),
			"%s %s has exactly the restored shadow instance count" % [label_text, child.name])

func _check_table(label_text: String, settled: bool) -> void:
	var visible: Array = []
	var omitted: Array = []
	var all: Array = board.cards + board.enemy_board.cards
	var below: Array = []
	for card in all:
		if not is_instance_valid(card) or card.is_queued_for_deletion(): continue
		if card._visual != null and card._visual.is_visible_in_tree() and card._plate != null and card._plate.is_visible_in_tree():
			visible.append(card)
			if card._plate.global_position.y < 0.0:
				below.append({"id": card.uid, "kind": card.def_id, "y": card._plate.global_position.y})
		else:
			omitted.append(card)
	var raw_positions: PackedVector3Array = TableLighting._contact_positions(all)
	var face_positions: PackedVector3Array = TableLighting._contact_positions(visible)
	var uncovered: Array = []
	for position in raw_positions:
		var matching := false
		for face in face_positions:
			if Vector2(position.x, position.z).distance_to(Vector2(face.x, face.z)) < 0.03:
				matching = true
				break
		if not matching: uncovered.append(position)
	if not uncovered.is_empty() or not below.is_empty():
		_transient_shadow_samples.append({"stage": label_text, "settled": settled, "hidden": omitted.size(),
			"uncovered_shadows": uncovered.size(), "below_felt": below, "first_uncovered": str(uncovered[0]) if not uncovered.is_empty() else ""})
	_check(not visible.is_empty(), "%s retains visible printed faces" % label_text)
	_check(below.is_empty(), "%s keeps visible faces above the felt: %s" % [label_text, below])
	_check(uncovered.is_empty(), "%s contact shadows have a corresponding visible face (%d unmatched positions)" % [label_text, uncovered.size()])
	if label_text.contains("immediate"): _check_cached_shadows(label_text)
	if settled:
		for presenter in [board, board.enemy_board]:
			for group in presenter.groups:
				_check(group.cards.any(func(card): return card in visible), "%s pile %s has a rendered face" % [label_text, group.get("work_group_id", -1)])
