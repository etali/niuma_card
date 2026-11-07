extends "res://tests/off_work/test_work_ui.gd"

## Exercise the real table, colliders and native suffix drag. All material stays
## in OffWorkState; bounded face samples only change how a large stack is drawn.
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
	board.touch_mode = true
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.money = 0
	await _bounded_expansion()
	await _middle_cut()
	await _cancel_cut()
	await _small_pile()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("LARGE_STACK_LAYOUT %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(initial: Dictionary) -> int:
	board.cancel_pointer()
	state.config.rules.initial.groups = [initial]
	main._new_game()
	state.drain_events()
	await _settle()
	return int(state.cards[_owned("employee")].group)

func _view(gid: int) -> Dictionary:
	return board.group_of(board.by_uid[state.group_cards(gid)[0]])

func _expanded(gid: int) -> Dictionary:
	var group := _view(gid)
	if group.compact:
		await _click(_point(group.cards[0]), true)
	board.sync_state(state)
	await _settle()
	_check(not group.compact, "real double click expands the large combination")
	return group

func _visible(group: Dictionary) -> Array:
	return group.cards.filter(func(card): return card._visual.visible)

func _check_bounded(group: Dictionary, label: String) -> void:
	var spec: Dictionary = board._settings.stack_display
	var visible := _visible(group)
	_check(visible.size() <= int(spec.expanded_visible_layers) and visible.size() > Board.BOUNDED_COMPACT_LAYERS, "%s presents more than the compact outline but never hundreds of faces" % label)
	var heights: Array = group.cards.map(func(card): return board.rest_pos(card).y)
	var depths: Array = group.cards.map(func(card): return board.rest_pos(card).z)
	_check(float(heights.max()) - float(heights.min()) <= float(spec.expanded_layer_height) * float(int(spec.expanded_visible_layers) - 1) + 0.001, "%s has bounded physical height independent of real card count" % label)
	_check(float(depths.max()) - float(depths.min()) <= float(spec.expanded_max_span) + 0.001, "%s stays within configured table depth" % label)
	_check(visible.all(func(card): return not card.card_mesh.visible), "%s has card faces instead of a solid wall of thick black bodies" % label)
	var positions := {}
	var distinct := true
	for card in visible:
		var at: Vector3 = board.rest_pos(card)
		if positions.has(at): distinct = false
		positions[at] = true
	_check(distinct, "%s never draws two faces in the same slot" % label)
	var representatives: Array = group.get("work_expanded_indices", [])
	_check(representatives.size() == visible.size(), "%s tracks each displayed face back to a real member" % label)
	_check(group.get("work_expanded_slots", []).size() == group.cards.size(), "%s maps every real member to a bounded slot" % label)

func _bounded_expansion() -> void:
	var gid := await _fixture({"employee": 12, "work": 500, "overtime": 4})
	var actual: Array = state.group_cards(gid).duplicate()
	state.advance(1.0)
	board.sync_state(state)
	var progress := state.group_work_progress(gid)
	var group := await _expanded(gid)
	_check(actual.size() == 516 and state.group_cards(gid) == actual, "expansion retains all 516 actual members and their order")
	_check(is_equal_approx(progress, state.group_work_progress(gid)), "inspection does not reset shared work progress")
	_check_bounded(group, "516-card expansion")
	_check(_visible(group).any(func(card): return card.def_id == "employee") and _visible(group).any(func(card): return card.def_id == "overtime"), "material compression retains personnel and tool faces")
	var faces := _visible(group)
	_check(faces.filter(func(card): return card.label.visible).size() < faces.size(), "dense repeated card strips do not repeat unreadable clipped titles")
	_check(group.cards[board._top_index(group)].label.visible, "front card keeps its complete identifying title")
	var hidden: Array = group.cards.filter(func(card): return not card._visual.visible)
	_check(hidden.size() > 450 and hidden.all(func(card): return board.by_uid.has(card.uid) and state.cards.has(card.uid)), "hidden material is still real, selectable through its type entry and consumable")
	var safe_hits := true
	for index in range(0, hidden.size(), maxi(1, hidden.size() / 12)):
		var card: CardEntity = hidden[index]
		var point: Vector2 = board.camera.unproject_position(card.global_position + Vector3(0.0, CardEntity.Y_PLATE, -CardEntity.CARD_SIZE.z * 0.47))
		var hit: CardEntity = board._pick_card(point)
		if hit != null and not hit._visual.visible: safe_hits = false
	_check(safe_hits, "hidden coincident colliders never expose an invisible drag target")
	await _capture("expanded")
	var original_cap: int = int(board._settings.stack_display.expanded_visible_layers)
	board._settings.stack_display.expanded_visible_layers = 16
	board._layout_group(group, board.rest_origin(group))
	board._sync_stack_occlusion()
	await _settle()
	_check(_visible(group).size() <= 16, "changing the configured layer cap changes the rendered stack")
	board._settings.stack_display.expanded_visible_layers = original_cap
	board._layout_group(group, board.rest_origin(group))
	board._sync_stack_occlusion()
	await _settle()
	for cycle in 2:
		await _click(_point(group.cards[board._top_index(group)]), true)
		_check(group.compact and state.group_cards(gid) == actual, "closing %d retains all real cards" % cycle)
		_check(group.cards.all(func(card): return card.label.visible), "closing %d restores normal titles including the compact front" % cycle)
		await _click(_point(group.cards[0]), true)
		_check_bounded(group, "reopened expansion %d" % cycle)
	_check(board.open_side_extract(gid, "employee"), "personnel side extraction remains available from the large stack")
	await _settle()
	_check(board.side_extract.view.records.size() == 12, "personnel fan contains all twelve actual personnel")
	board.side_extract.close()

func _exposed_point(card: CardEntity) -> Vector2:
	# Large compressed strips may be narrower than the original helper's three
	# probes. Sample the real face; no direct call bypasses pointer hit testing.
	for step in 80:
		var z := lerpf(-0.49, 0.49, float(step) / 79.0)
		for x in [0.0, -0.3, 0.3]:
			var at: Vector2 = board.camera.unproject_position(card.global_position + Vector3(float(x) * CardEntity.CARD_SIZE.x, CardEntity.Y_PLATE, z * CardEntity.CARD_SIZE.z))
			if main.hud.content_rect().has_point(at) and board._pick_card(at) == card: return at
	return Vector2.INF

func _cut_candidate(group: Dictionary) -> Dictionary:
	var candidates: Array = group.get("work_expanded_indices", []).duplicate()
	candidates.sort_custom(func(a, b): return absf(float(a) - float(group.cards.size()) * 0.5) < absf(float(b) - float(group.cards.size()) * 0.5))
	for index in candidates:
		if int(index) <= 0 or int(index) >= group.cards.size() - 1: continue
		var at := _exposed_point(group.cards[int(index)])
		if at != Vector2.INF: return {"index": int(index), "point": at}
	return {}

func _begin_cut(group: Dictionary, cut: Dictionary) -> void:
	var index := int(cut.index)
	var expected: Array = group.cards.slice(index).map(func(card): return card.uid)
	await _button(cut.point, true)
	await _move_pointer(cut.point + Vector2(20.0, 0.0))
	_check(board.is_dragging(), "a real exposed middle-card gesture starts native dragging")
	_check(board._drag_cards.map(func(card): return card.uid) == expected, "native drag takes the exact actual suffix, including hidden material")
	var visible: Array = board._drag_cards.filter(func(card): return card._visual.visible)
	var heights: Array = board._drag_offsets.map(func(offset): return offset.y)
	_check(visible.size() <= int(board._settings.stack_display.expanded_visible_layers), "the held suffix keeps bounded visible faces")
	_check(not heights.is_empty() and float(heights.max()) - float(heights.min()) <= float(board._settings.stack_display.expanded_layer_height) * float(int(board._settings.stack_display.expanded_visible_layers) - 1) + 0.001, "holding a suffix cannot recreate the black wall")

func _move_pointer(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	pointer = at
	root.push_input(event)
	await process_frame
	board._process(0.0)

func _middle_cut() -> void:
	var gid := await _fixture({"employee": 3, "work": 500, "overtime": 2})
	var group := await _expanded(gid)
	var cut := _cut_candidate(group)
	if not _check(not cut.is_empty(), "expanded material exposes a real, clickable middle strip"): return
	var original: Array = group.cards.map(func(card): return card.uid)
	var expected: Array = original.slice(int(cut.index))
	var target := _empty_point()
	if not _check(target != Vector2.INF, "large stack leaves empty table for the cut suffix"): return
	var ray: Vector3 = board.camera.project_ray_normal(target)
	var from: Vector3 = board.camera.project_ray_origin(target)
	var ground: Vector3 = from + ray * ((float(board._settings.rest_y) - from.y) / ray.y)
	await _begin_cut(group, cut)
	if not board.is_dragging(): return
	var destination: Vector2 = board.camera.unproject_position(Vector3(ground.x - board._grab_offset.x, Board.DRAG_HEIGHT, ground.z - board._grab_offset.z))
	await _move_pointer(destination)
	await _button(destination, false)
	await _settle()
	var result: int = state.cards[expected[0]].group
	_check(result != gid and state.group_cards(result) == expected, "release creates a real suffix pile with every intended UID")
	var left: Array = state.group_cards(gid).duplicate()
	var prefix: Array = original.slice(0, int(cut.index))
	left.sort(); prefix.sort()
	_check(left == prefix, "source retains precisely the unselected prefix")
	_check(not board.is_dragging(), "real drop clears the native hand")
	_check_bounded(_view(result), "dropped suffix")

func _cancel_cut() -> void:
	var gid := await _fixture({"employee": 3, "work": 500, "overtime": 2})
	var group := await _expanded(gid)
	var cut := _cut_candidate(group)
	if not _check(not cut.is_empty(), "cancel fixture has a reachable middle strip"): return
	var original: Array = state.group_cards(gid).duplicate()
	var visual_order: Array = group.cards.map(func(card): return card.uid)
	var origin: Vector3 = board.rest_origin(group)
	await _begin_cut(group, cut)
	board.cancel_pointer()
	board._process(0.0)
	await _settle()
	group = _view(gid)
	_check(not board.is_dragging() and state.group_cards(gid) == original, "cancel preserves authoritative group membership")
	_check(group.cards.map(func(card): return card.uid) == visual_order and not group.compact, "cancel restores the original expanded order and mode")
	_check(board.rest_origin(group).distance_to(origin) < 0.001, "cancel restores the exact source anchor")
	_check_bounded(group, "cancelled suffix")

func _small_pile() -> void:
	var gid := await _fixture({"employee": 2, "work": 4, "overtime": 1})
	var group := await _expanded(gid)
	_check(group.cards.size() == 7 and _visible(group).size() == 7, "ordinary seven-card expansion still displays every real face")
	_check(group.cards.all(func(card): return card.card_mesh.visible), "small piles retain the original card bodies")

func _capture(stage: String) -> void:
	if not OS.has_environment("WORK_LARGE_STACK_CAPTURE") or DisplayServer.get_name() == "headless": return
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png("res://reports/large-stack-%s.png" % stage)
