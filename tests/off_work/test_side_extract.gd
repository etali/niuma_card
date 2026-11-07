extends "res://tests/off_work/test_work_ui.gd"

## The side fan is only an inspection projection. Real UIDs enter the original
## Board drag protocol and authoritative groups change only on a valid drop.
func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-side-extract-%d" % OS.get_process_id())
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
	state.config.rules.initial.money = 0
	await _entries_and_inspection()
	await _vertical_spread()
	await _real_fan_drag()
	await _release_over_hud()
	await _exact_subset_drop()
	await _merge_subset()
	await _cancel_subset()
	await _dismiss_subset()
	await _forbidden_pickups()
	await _large_drag()
	await _paused_inspection()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("SIDE_EXTRACT %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(initial: Array) -> int:
	paused = false
	board.cancel_pointer()
	state.config.rules.initial.groups = initial
	main._new_game()
	await _settle()
	_check(state.last_error.is_empty(), "side fixture starts valid rules")
	return int(state.cards[_owned("work")].group)

func _entries_and_inspection() -> void:
	var gid := await _fixture([{"work": 200, "employee": 1, "overtime": 2}])
	var entries: Array = board.side_extract_entries(gid)
	_check(entries.any(func(e): return e.kind == "employee" and e.ids.size() == 1), "single employee has a direct side extraction entry")
	var visual: Dictionary = board.group_of(board.by_uid[_owned("employee")])
	var rows: Array = board.side_extract.side_rows(visual)
	var index := -1
	for i in rows.size():
		if rows[i].kind == "employee": index = i
	if _check(index >= 0, "visible side list includes the lone employee"):
		var label: Node3D = visual.side[index * 2 + 1]
		var at := board.camera.unproject_position(label.global_position)
		var hit: Dictionary = board.side_extract.hit_test(at)
		_check(hit.get("kind", "") == "employee", "actual side label projects to the employee hit region")
		var members: Array = state.group_cards(gid).duplicate()
		var origin: Vector3 = board.rest_origin(visual)
		await _click(at)
		_check(is_instance_valid(board.side_extract.view) and board.side_extract.view.is_open(), "real viewport click opens the same-type fan")
		_check(not board.is_dragging() and board._press_snap.is_empty(), "view-only click never starts native pickup")
		_check(state.group_cards(gid) == members and not main.bot.is_started(), "view-only click neither splits real group nor starts opponent")
		_check(board.rest_origin(board.group_of(board.by_uid[members[0]])).distance_to(origin) < 0.001, "inspection leaves source stack anchored")
		state.advance(1.0)
		board.sync_state(state)
		_check(state.group_work_progress(gid) > 0.0, "production continues while side fan is open")
		_check(state.group_cards(gid) == members, "inspection itself leaves work and personnel membership intact")
		board.side_extract.close()
	var all_types := {"work": 20, "money": 2, "employee": 1, "grinder": 1, "workaholic": 1, "work_emperor": 1, "leader": 1, "overtime": 1, "coffee": 1, "transfer": 1, "meeting": 1, "slack": 1, "outsource": 1, "strike": 1}
	var opening := all_types.duplicate()
	opening.erase("money")
	gid = await _fixture([opening])
	for _money_index in int(all_types.money): state.add_card("money", 0, gid)
	board.sync_state(state)
	await _settle()
	entries = board.side_extract_entries(gid)
	_check(entries.size() == all_types.size(), "more than six kinds remain individually reachable rather than hidden behind +N")
	_check(entries.all(func(e): return all_types.has(e.kind) and e.ids.size() == int(all_types[e.kind])), "every side row points to exactly the matching real UIDs")
	visual = board.group_of(board.by_uid[_owned("employee")])
	rows = board.side_extract.side_rows(visual)
	_check(rows.size() == all_types.size(), "all kinds have visible side rows")
	for i in rows.size():
		var label: Node3D = visual.side[i * 2 + 1]
		var hit: Dictionary = board.side_extract.hit_test(board.camera.unproject_position(label.global_position))
		_check(hit.get("kind", "") == rows[i].kind, "%s side row stays independently hittable across columns" % rows[i].kind)

func _move_held_to(world: Vector3) -> void:
	var at := board.camera.unproject_position(Vector3(world.x - board._grab_offset.x, Board.DRAG_HEIGHT, world.z - board._grab_offset.z))
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.relative = at - pointer
	pointer = at
	root.push_input(motion)
	await process_frame
	board._process(0.0)

func _vertical_spread() -> void:
	var gid := await _fixture([{"work": 200, "employee": 5, "overtime": 2}])
	var visual: Dictionary = board.group_of(board.by_uid[_owned("employee")])
	var front: CardEntity
	for card in visual.cards:
		if front == null or card._visual.global_position.y >= front._visual.global_position.y: front = card
	var source: Rect2 = board.side_extract.source_screen_rect(gid)
	var expected: Rect2 = board._cash_note_screen_bounds(front._visual)
	_check(source.position.distance_to(expected.position) < 0.01 and source.size.distance_to(expected.size) < 0.01, "spread originates from the visible front card, not a buried logical member")
	_check(source.has_area(), "source face has a real projected size")
	_check(board.open_side_extract(gid, "employee"), "native side entry can position a vertical spread without a fixed screen anchor")
	var initial_view: Control = board.side_extract.view
	_check((initial_view._card_rects[0] as Rect2).get_center().distance_to(source.get_center()) < 0.01, "vertical cards begin at the source face before the opening motion")
	initial_view._process(float(board._settings.side_extract.open_seconds) * 0.4)
	var travelling: Vector2 = (initial_view._card_rects[0] as Rect2).get_center()
	_check(travelling.distance_to(source.get_center()) > 1.0 and travelling.distance_to(initial_view._targets[int(initial_view.records[0].id)]) > 0.1, "cards travel visibly through an intermediate pose instead of popping into a panel")
	await _settle()
	var fan: Control = board.side_extract.view
	_check(fan.find_children("*", "Panel", true, false).is_empty() and fan.find_children("*", "Label", true, false).is_empty(), "spread has no backing panel, heading, footer or close-button label")
	_check(fan._viewport.transparent_bg, "only card fronts render over the existing tabletop")
	var previous := Rect2()
	for index in 5:
		var face: Rect2 = fan._card_rects[index]
		if index > 0:
			_check(absf(face.get_center().x - previous.get_center().x) < 1.0 and face.get_center().y > previous.get_center().y, "personnel %d follows the preceding card vertically" % index)
		_check(fan.index_at_screen_point(fan.screen_point_for_index(index)) == index, "personnel %d exposes a precise cut point" % index)
		previous = face
	var nearest := INF
	for rect in fan._card_rects.values():
		nearest = minf(nearest, rect.get_center().distance_to(source.get_center()))
	_check(nearest < source.size.length() * 2.0, "spread remains beside its source pile instead of opening an unrelated dialog")
	board.side_extract.close()
	_check(board.open_side_extract(gid, "work"), "large work spread uses the same direct side entry")
	await _settle()
	fan = board.side_extract.view
	_check(fan.records.size() == 200 and fan.preview_cards.size() <= int(board._settings.side_extract.max_render_cards), "vertical spread retains all real work with bounded render count")
	var middle: Vector2 = fan.screen_point_for_index(100)
	_check(fan.index_at_screen_point(middle) == 100, "middle of the vertical work spread resolves against all two hundred cards")
	board.side_extract.close()

func _real_fan_drag() -> void:
	var gid := await _fixture([{"work": 40, "employee": 5}])
	var original: Array = state.group_people(gid).duplicate()
	var empty := _empty_point()
	if not _check(empty != Vector2.INF, "fan gesture fixture has an empty destination"): return
	_check(board.open_side_extract(gid, "employee", Vector2(600, 400)), "five-person fan opens for an actual drag gesture")
	await _settle()
	var fan: Control = board.side_extract.view
	var press: Vector2 = fan.screen_point_for_index(1)
	if not _check(fan.index_at_screen_point(press) == 1, "second personnel card exposes a distinct clickable face"): return
	await _button(press, true)
	_check(not board.is_dragging() and state.group_people(gid) == original, "pressing inside fan only arms a possible extraction")
	var event := InputEventMouseMotion.new()
	event.position = press + Vector2(float(board._settings.side_extract.drag_threshold) + 5.0, 0.0)
	event.global_position = event.position
	event.relative = event.position - press
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	var expected_center: Vector2 = (fan._card_rects[1] as Rect2).get_center() + event.position - press
	pointer = event.position
	root.push_input(event)
	await process_frame
	board._process(0.0)
	if not _check(board.is_dragging(), "real mouse movement beyond the fan threshold starts native pickup"): return
	_check(board._drag_cards.map(func(c): return c.uid) == original.slice(1), "fan index locks the exact personnel suffix even after focus moves")
	var held: CardEntity = board._drag_cards[0]
	var actual_center: Vector2 = board.camera.unproject_position(held._visual.to_global(Vector3(0.0, CardEntity.Y_TEXT, 0.0)))
	_check(actual_center.distance_to(expected_center) < 5.0, "real drag preserves the side card grab point instead of snapping its center to the cursor")
	_check(not fan.is_open(), "fan closes when its real cards enter the hand")
	await _move_held_to(_ground(empty))
	await _release_held()
	var destination: int = state.cards[original[1]].group
	_check(destination != gid and state.group_people(destination) == original.slice(1), "real fan-to-table gesture commits only the selected personnel")
	_check(state.group_work(gid).size() == 40 and state.group_people(gid).size() == 1, "fan gesture leaves all material and unselected personnel behind")

func _ground(screen: Vector2) -> Vector3:
	var ray := board.camera.project_ray_normal(screen)
	var from := board.camera.project_ray_origin(screen)
	return from + ray * ((0.05 - from.y) / ray.y)

func _release_over_hud() -> void:
	var gid := await _fixture([{"work": 40, "employee": 5}])
	var before: Array = state.group_cards(gid).duplicate()
	_check(board.open_side_extract(gid, "employee", Vector2(600, 400)), "fan opens for GUI-release regression")
	await _settle()
	var fan: Control = board.side_extract.view
	var press: Vector2 = fan.screen_point_for_index(1)
	await _button(press, true)
	var content: Rect2 = main.hud.content_rect()
	var gui_point := Vector2(content.get_center().x, content.position.y * 0.5)
	_check(main.hud.pointer_over_panels(gui_point), "release point belongs to the original header UI")
	var into_gui := InputEventMouseMotion.new()
	into_gui.position = gui_point
	into_gui.global_position = gui_point
	into_gui.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(into_gui)
	await process_frame
	await _button(gui_point, false)
	var return_without_button := InputEventMouseMotion.new()
	return_without_button.position = press
	return_without_button.global_position = press
	return_without_button.button_mask = 0
	root.push_input(return_without_button)
	await process_frame
	board._process(0.0)
	_check(not board.is_dragging() and board._press_snap.is_empty(), "releasing over GUI then returning without a held button cannot start a ghost extraction")
	_check(not fan.is_open(), "GUI release clears the armed inspection gesture")
	_check(state.group_cards(gid) == before and not main.bot.is_started(), "cancelled GUI gesture has no gameplay effect")

func _begin_ids(ids: Array) -> bool:
	var at := board.camera.unproject_position(board.by_uid[ids[0]].global_position)
	pointer = at
	return _check(board.begin_side_extract(ids, at), "selected UIDs enter original Board drag")

func _release_held() -> void:
	await _button(pointer, false)
	await _settle()
	_check(not board.is_dragging(), "real release clears extraction drag")

func _exact_subset_drop() -> void:
	var gid := await _fixture([{"work": 40, "employee": 3, "overtime": 2}])
	var work: Array = state.group_work(gid)
	var suffix: Array = work.slice(20)
	var original: Array = state.group_cards(gid).duplicate()
	var people: Array = state.group_people(gid).duplicate()
	var anchor: Vector3 = board.rest_origin(board.group_of(board.by_uid[people[0]]))
	var empty := _empty_point()
	if not _check(empty != Vector2.INF, "subset test has a free tabletop destination"): return
	if not _begin_ids(suffix): return
	_check(state.group_cards(gid) == original, "lifting selected work does not prematurely mutate authoritative group")
	_check(board._drag_cards.map(func(c): return c.uid) == suffix, "suffix contains only the selected twenty real work cards")
	_check(board._drag_compact, "extracted substack travels compactly")
	await _move_held_to(_ground(empty))
	await _release_held()
	var destination: int = state.cards[suffix[0]].group
	_check(destination != gid, "dropping subset on blank space creates an independent group")
	_check(state.group_cards(destination) == suffix and state.group_work(gid).size() == 20, "drop moves exactly the chosen suffix, with no duplicate or missing work")
	_check(people.all(func(id): return state.cards[id].group == gid), "personnel stay in their original working group")
	_check(board.rest_origin(board.group_of(board.by_uid[people[0]])).distance_to(anchor) < 0.001, "source pile does not jump when a hidden middle subset is removed")

func _merge_subset() -> void:
	var gid := await _fixture([{"work": 30, "employee": 3}, {"work": 10}])
	var ids: Array = state.group_people(gid).slice(1)
	var target: int = -1
	for other in state.groups:
		if other != gid and int(state.groups[other].owner) == 0 and state.group_work(other).size() == 10: target = int(other)
	if not _check(target >= 0, "merge fixture exposes another work pile"): return
	var target_card: CardEntity = board.by_uid[state.group_cards(target)[0]]
	if not _begin_ids(ids): return
	await _move_held_to(target_card.global_position)
	await _release_held()
	_check(ids.all(func(id): return state.cards[id].group == target), "subset joins the intended existing work group")
	_check(state.group_people(gid).size() == 1 and state.group_people(target).size() == 2, "source and destination keep exact personnel counts")

func _cancel_subset() -> void:
	var gid := await _fixture([{"work": 30, "employee": 3, "overtime": 2}])
	state.advance(2.0)
	board.sync_state(state)
	await _settle()
	var original: Array = state.group_cards(gid).duplicate()
	var view: Dictionary = board.group_of(board.by_uid[original[0]])
	var order: Array = view.cards.map(func(c): return c.uid)
	var origin: Vector3 = board.rest_origin(view)
	var progress := state.group_work_progress(gid)
	if not _begin_ids(state.group_people(gid).slice(1)): return
	board.cancel_pointer()
	board._process(0.0)
	await _settle()
	_check(not board.is_dragging() and board._press_snap.is_empty(), "cancel clears native pointer state")
	_check(state.group_cards(gid) == original and is_equal_approx(state.group_work_progress(gid), progress), "cancel preserves authoritative membership and shared progress")
	view = board.group_of(board.by_uid[original[0]])
	_check(view.cards.map(func(c): return c.uid) == order, "cancel restores original visual ordering")
	_check(board.rest_origin(view).distance_to(origin) < 0.001, "cancel restores exact source anchor")

func _dismiss_subset() -> void:
	var gid := await _fixture([{"work": 30, "employee": 3, "overtime": 2}])
	var ids: Array = state.group_people(gid).slice(1)
	var money := state.money(0)
	if not _begin_ids(ids): return
	await _move_held_to(board.pawn_pos)
	await _release_held()
	_check(ids.all(func(id): return not state.cards.has(id)), "side-extracted personnel can use the existing dismissal facility")
	_check(state.money(0) == money + 4 and state.group_people(gid).size() == 1, "dismissal refunds selected personnel exactly once")
	_check(state.group_work(gid).size() == 30 and state.group_cards(gid).filter(func(id): return state.cards[id].type == "overtime").size() == 2, "dismissal leaves all work and tools in their source group")

func _forbidden_pickups() -> void:
	var gid := await _fixture([{"work": 20, "employee": 1}, {"coffee": 2}])
	var person := _owned("employee")
	var work: int = state.group_work(gid)[0]
	_check(not board.begin_side_extract([person, work], Vector2(500, 500)), "cross-type extraction cannot bypass the selected-kind contract")
	var foreign := -1
	for id in state.cards:
		if state.cards[id].owner == 1: foreign = int(id); break
	_check(not board.begin_side_extract([foreign], Vector2(500, 500)), "side extraction cannot pick opponent cards")
	var coffee := _owned("coffee")
	var card: OffWorkCard = board.by_uid[coffee]
	card.set_meta("delivery_flight", true)
	_check(not board.begin_side_extract([coffee], Vector2(500, 500)), "airborne produced coffee cannot be picked by a side entry")
	card.remove_meta("delivery_flight")
	card.set_meta("income_flight", true)
	_check(not board.begin_side_extract([coffee], Vector2(500, 500)), "airborne money lock also applies to side extraction")
	card.remove_meta("income_flight")
	var meet: int = state.add_card("meeting", 1)
	var leader: int = state.add_card("leader", 1, int(state.cards[meet].group))
	state.activate(meet, int(state.cards[leader].group), leader)
	board.sync_state(state)
	_check(state.is_meeting_target(person) and not board.begin_side_extract([person], Vector2(500, 500)), "person forced into meeting cannot escape through side extraction")
	_check(not board.open_side_extract(gid, "employee", Vector2(500, 500)), "side fan does not offer a fully unavailable personnel type")

func _large_drag() -> void:
	var gid := await _fixture([{"work": 200, "employee": 1}])
	if not _begin_ids(state.group_work(gid)): return
	var heights: Array = board._drag_offsets.map(func(v): return v.y)
	_check(heights.max() - heights.min() <= Board.COMPACT_GAP.y * Board.BOUNDED_COMPACT_LAYERS + 0.001, "two hundred extracted cards have bounded held height")
	_check(board._drag_cards.size() == 200 and state.group_cards(gid).size() == 201, "bounded visual drag keeps every actual work card and defers logical split")
	board.cancel_pointer()
	board._process(0.0)
	await _settle()

func _paused_inspection() -> void:
	var gid := await _fixture([{"work": 20, "employee": 1}])
	_check(board.open_side_extract(gid, "employee", Vector2(600, 400)), "personnel fan opens before pausing")
	main.hud.set_manual_paused(true)
	_check(paused and not board.side_extract.view.is_open(), "real pause control immediately closes the inspection fan")
	_check(not board.begin_side_extract(state.group_people(gid), Vector2(600, 400)), "paused game rejects starting a side drag")
	main.hud.set_manual_paused(false)
	_check(board.open_side_extract(gid, "employee", Vector2(600, 400)), "fan reopens after resuming")
	var expanded: bool = main.hud.drawer_window.is_expanded()
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	root.push_input(escape)
	await process_frame
	_check(not board.side_extract.view.is_open() and main.hud.drawer_window.is_expanded() == expanded and not paused, "Escape closes fan first without collapsing or pausing the game drawer")
	if not _begin_ids(state.group_people(gid)): return
	main.hud.set_manual_paused(true)
	_check(not board.is_dragging(), "real pause control cancels an in-progress extraction drag")
	main.hud.set_manual_paused(false)
	board._process(0.0)
	await _settle()
	_check(state.group_people(gid).size() == 1 and not board.is_dragging(), "pause cancellation leaves personnel in the source combination")
