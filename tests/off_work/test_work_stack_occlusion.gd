extends "res://tests/off_work/test_work_ui.gd"

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	state = main.state
	state.config.rules.bot.enabled = false
	_lazy_opening_faces()
	await _reflow_motion()
	await _overflow_visibility()
	for compact in [true, false]: await _settlements(compact)
	await _overflow_ending()
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_STACK_OCCLUSION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(initial: Dictionary) -> int:
	state.config.rules.initial.groups = [initial]
	main._new_game()
	state.drain_events()
	await _settle()
	return int(state.cards[_owned("employee")].group)

func _lazy_opening_faces() -> void:
	var covered: Array = board.by_uid.values().filter(func(c): return c.face_deferred)
	_check(covered.size() > 300, "default opening builds full faces only for visibly distinct work layers")
	if covered.is_empty(): return
	var sheet: OffWorkCard = covered.filter(func(c): return c.card_owner == 0)[0]
	_check(sheet._plate == null and not sheet._visual.visible and sheet.input_ray_pickable,
		"covered work retains its original physical identity")
	state.move_cards([sheet.uid], -1)
	board.sync_state(state)
	_check(board.by_uid[sheet.uid] == sheet and sheet._visual.visible and sheet.draggable,
		"exposing a work UID keeps the same draggable body")
	_check(sheet._plate != null and sheet._icon.texture != null and sheet.label.text == state.config.cards.work.name,
		"the exposed sheet gets its printed face and illustration before rendering")

## 收拢摞和展开摞的层序相反。固定推进真实的理牌补间，可查到旧动画
## 里几个标题几乎穿过同一个平面的那一帧，而不依赖显示器的刷新率。
func _reflow_motion() -> void:
	await _fixture({"employee": 1, "work": 3})
	for presenter: Board in [board, board.enemy_board]:
		var group: Dictionary
		for candidate in presenter.groups:
			if candidate.cards.any(func(c): return c.def_id == "work"):
				group = candidate
				break
		for compact in [false, true]:
			var start_pixels := {}
			for card: CardEntity in group.cards:
				start_pixels[card] = board.camera.unproject_position(card.global_position)
			var origin := presenter.rest_origin(group)
			group.compact = compact
			presenter._layout_group(group, origin)
			var pinned := true
			for card: CardEntity in group.cards:
				presenter._move_tw[card].tw.pause()
				pinned = pinned and board.camera.unproject_position(card.global_position).distance_to(start_pixels[card]) < 0.05
			_check(pinned, "switching layer order preserves each card's starting screen position")
			var stable := true
			for frame in 18:
				for card: CardEntity in group.cards: presenter._move_tw[card].tw.custom_step(0.01)
				for i in range(1, group.cards.size()):
					var previous: CardEntity = group.cards[i - 1]
					var next: CardEntity = group.cards[i]
					var gap := next.global_position.y - previous.global_position.y
					stable = stable and (gap * (-1.0 if compact else 1.0) > CardEntity.FACE_SPAN_Y)
			_check(stable, "moving cards keep target depth order and clearance for the full fold on both desks")
			await _settle()

func _overflow_visibility() -> void:
	var gid := await _fixture({"employee": 12, "work": 200, "overtime": 2})
	var group: Dictionary = board.group_of(board.by_uid[_owned("employee")])
	var logical: Array = state.group_cards(gid).duplicate()
	var visible: Array = group.cards.filter(func(card): return card._visual.visible)
	_check(visible.size() == int(group.bounded_compact_cap), "only distinct compact layers are drawn for 214 real cards")
	var slots := {}
	for card in visible:
		var at: Vector3 = board.rest_pos(card)
		_check(not slots.has(at), "no two visible compact faces occupy one depth plane")
		slots[at] = true
	_check(logical.size() == 214 and state.group_cards(gid) == logical, "occlusion leaves real material and personnel counts intact")
	var hidden_person := -1
	for person in state.group_people(gid):
		if board._stack_occluded.has(person): hidden_person = person; break
	if _check(hidden_person >= 0, "fixture includes a person below the rendered layer limit"):
		_check(board.side_extract.eligible(hidden_person), "hidden staff remain available to explicit side extraction")
		var point: Vector2 = board.camera.unproject_position(board.by_uid[hidden_person].global_position)
		var picked: CardEntity = board._pick_card(point)
		_check(picked != null and not board._stack_occluded.has(picked.uid), "physics never picks an invisible overlapping material")
		_check(board.begin_side_extract([hidden_person], Vector2(800, 600)), "hidden personnel can be extracted through the real handoff")
		_check(board.by_uid[hidden_person]._visual.visible and not board._stack_occluded.has(hidden_person), "extracted actual person is visible immediately")
		board.cancel_pointer()
		board.sync_state(state)
		_check(state.group_cards(gid) == logical, "cancel keeps the full original composition")
	group = board.group_of(board.by_uid[_owned("employee")])
	board.toggle_compact(group.cards[0])
	board.sync_state(state)
	await _settle()
	var expanded_faces: Array = group.cards.filter(func(card): return card._visual.visible)
	_check(not group.compact and group.cards.size() == logical.size() and expanded_faces.size() <= int(board._settings.stack_display.expanded_visible_layers), "large expansion retains every real card and draws only bounded distinct faces")
	_check(expanded_faces.size() > int(group.bounded_compact_cap) and expanded_faces.all(func(card): return not card.card_mesh.visible), "large expansion shows more material edges without stacked black bodies")
	board.toggle_compact(group.cards[board._top_index(group)])
	board.sync_state(state)
	await _settle()
	_check(group.cards.filter(func(card): return card._visual.visible).size() == int(group.bounded_compact_cap), "closing the pile suppresses only coincident overflow again")

func _settlements(compact: bool) -> void:
	var gid := await _fixture({"employee": 5, "work": 200})
	var group: Dictionary = board.group_of(board.by_uid[_owned("employee")])
	if bool(group.compact) != compact: board.toggle_compact(group.cards[board._top_index(group)])
	board.sync_state(state)
	await _settle()
	for batch in 3:
		if batch == 0 and compact: await _capture("before")
		state.advance(10.0)
		var events: Array = state.drain_events()
		board.sync_state(state)
		var papers_before := int(board._paper_disposal.emitted) + int(board._paper_disposal.queued_count()) if is_instance_valid(board._paper_disposal) else 0
		for event in events: board.play_event(event)
		_check(group.cards.all(func(card): return not card._stamp_flash_on), "work completion leaves the crumpling file visible without stamps piercing its pile")
		_check(board._paper_disposal.emitted + board._paper_disposal.queued_count() - papers_before == 10,
			"a shared settlement queues one actual paper per consumed file on both tables")
		if batch == 0 and compact: await _capture("settlement")
		var retired: Array = board._retired_cards.values().duplicate()
		_check(retired.size() == 10, "one shared settlement consumes five work on each side")
		_check(retired.all(func(card): return not card.visible), "consumed faces disappear before refill can intersect the working staff")
		_check(state.group_work(gid).size() == 200 - (batch + 1) * 5, "successive groups keep processing their full batch")
		for sample in 8:
			await create_timer(0.1).timeout
			if batch == 0 and compact and sample in [1, 4]: await _capture("after-%d" % sample)
			_check(retired.all(func(card): return not is_instance_valid(card) or not card.visible), "retired material never rises through the active pile during its former exit duration")
		_check(board._retired_cards.is_empty(), "hidden consumed faces are fully disposed after their existing lifetime")

func _overflow_ending() -> void:
	await _fixture({"employee": 12, "work": 1, "overtime": 2})
	var hidden: Array = board._stack_occluded.keys().filter(func(uid): return state.cards.has(uid) and state.cards[uid].type == "employee")
	_check(not hidden.is_empty(), "terminal fixture has truly occluded overflow people")
	state.advance(10.0)
	main._process(0.0)
	_check(state.winner == 2, "both sides complete their real last work")
	_check(hidden.all(func(uid): return not board.by_uid[uid]._visual.visible), "ending does not revive coincident buried faces")
	await create_timer(0.5).timeout
	_check(hidden.all(func(uid): return not board.by_uid[uid]._visual.visible), "overflow remains occluded throughout side departure")

func _capture(stage: String) -> void:
	if not OS.has_environment("WORK_STACK_CAPTURE") or DisplayServer.get_name() == "headless": return
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png("res://reports/work-stack-stable-%s.png" % stage)
