extends SceneTree

const Runner = preload("res://scenes/off_work_animation_scenario.gd")
var runner: Node3D
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-huge-preview-%d" % OS.get_process_id())
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func visual_group(name: String) -> Dictionary:
	var gid := int(runner._groups[name])
	var members: Array = runner.state.group_cards(gid)
	return runner.board.group_of(runner.board.by_uid[members[0]])

func people(name: String) -> Array:
	return runner.state.group_people(int(runner._groups[name]))

func work(name: String) -> Array:
	return runner.state.group_work(int(runner._groups[name]))

func conserved(initial_work: Array, initial_people: Array) -> void:
	var consumed: Array = []
	for event in runner.snapshot().events:
		if str(event.kind) == "work_complete" and int(event.owner) == 0:
			consumed.append_array(event.ids)
	var current: Array = runner.state.cards.keys().filter(func(id): return int(runner.state.cards[id].owner) == 0 and runner.state.cards[id].type == "work")
	var combined := current + consumed
	combined.sort()
	var expected := initial_work.duplicate()
	expected.sort()
	check(combined == expected, "all real work is either on the table or accounted for by production, with no duplicated extraction")
	var actual_people: Array = runner.state.cards.keys().filter(func(id): return int(runner.state.cards[id].owner) == 0 and runner.state.config.is_person(str(runner.state.cards[id].type)))
	actual_people.sort()
	var expected_people := initial_people.duplicate()
	expected_people.sort()
	check(actual_people == expected_people, "inspection and cuts conserve all twelve personnel UIDs")

func same_state(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b): return false
	if a is Dictionary:
		if a.size() != b.size(): return false
		for key in a:
			if not b.has(key) or not same_state(a[key], b[key]): return false
		return true
	if a is Array:
		if a.size() != b.size(): return false
		for index in a.size():
			if not same_state(a[index], b[index]): return false
		return true
	if a is float: return is_equal_approx(a, b)
	if a is Vector2 or a is Vector3 or a is Transform3D or a is Basis or a is Color: return a.is_equal_approx(b)
	return a == b

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 900)
	viewport.own_world_3d = true
	root.add_child(viewport)
	runner = Runner.new()
	viewport.add_child(runner)
	runner.load_scenario("huge_stack_extract")
	await process_frame
	if runner.entry.is_empty():
		push_error("huge_stack_extract is missing from the real preview catalog")
		quit(1)
		return
	var at: Dictionary = runner.entry.preview_checks
	runner.seek(float(at.initial))
	var initial_people: Array = people("source").duplicate()
	var initial_work: Array = work("source") + work("target")
	check(runner.state.group_cards(int(runner._groups.source)).size() == 516, "source contains 516 actual cards, not a count label standing in for material")
	check(work("source").size() == 500 and initial_people.size() == 12, "initial source has five hundred work and twelve employees")
	check(bool(visual_group("source").compact), "large source starts as the formal compact pile")
	check(runner.board.by_uid.size() == runner.state.cards.size(), "every fixture UID has a formal card entity")
	runner.seek(float(at.expanded))
	var expanded := visual_group("source")
	check(not bool(expanded.compact) and expanded.cards.size() == 516, "first expansion preserves all 516 real members")
	var expanded_faces: Array = expanded.cards.filter(func(card): return card._visual.visible)
	var stack_spec: Dictionary = runner.board._settings.stack_display
	check(expanded_faces.size() <= int(stack_spec.expanded_visible_layers) and expanded_faces.size() > Board.BOUNDED_COMPACT_LAYERS, "whole-pile expansion exposes bounded material edges instead of hundreds of overlapping faces")
	check(expanded_faces.all(func(card): return not card.card_mesh.visible), "huge preview uses card faces without the accumulated black side wall")
	var heights: Array = expanded.cards.map(func(card): return card.global_position.y)
	var depths: Array = expanded.cards.map(func(card): return card.global_position.z)
	check(float(heights.max()) - float(heights.min()) <= float(stack_spec.expanded_layer_height) * float(int(stack_spec.expanded_visible_layers) - 1) + 0.001, "huge preview height is bounded by displayed layers rather than real card count")
	check(float(depths.max()) - float(depths.min()) <= float(stack_spec.expanded_max_span) + 0.001, "huge preview respects configured expansion depth")
	check(not runner.board.side_extract.is_open(), "ordinary whole-pile expansion does not substitute a side projection")
	runner.seek(float(at.collapsed))
	check(bool(visual_group("source").compact), "whole pile folds back before category extraction")

	runner.seek(float(at.personnel_open))
	var fan: Control = runner.board.side_extract.view
	check(fan.is_open() and fan.kind == "employee" and fan.records.size() == 12, "side entry opens all twelve real employees from the huge pile")
	check(fan.find_children("*", "Panel", true, false).is_empty(), "large-group extraction retains the direct card-only presentation")
	check(people("source") == initial_people and people("target").is_empty(), "opening personnel inspection does not move any real employee")
	runner.seek(float(at.personnel_cut))
	check(runner.board.side_extract.view.focus_index == 6, "personnel cut highlights the exact six-person suffix")
	runner.seek(float(at.personnel_drag))
	check(runner.board.is_dragging(), "personnel cut enters the native Board drag protocol")
	check(runner.board._drag_cards.map(func(card): return card.uid) == initial_people.slice(6), "native hand contains exactly the latter six employee UIDs")
	check(people("source").size() == 12 and people("target").is_empty(), "real membership waits until the drag is released")
	check(bool(runner.snapshot().hand.visible) and int(runner.snapshot().hand.native_cursor_requests) == 0, "preview draws the native gripping hand without modifying the system cursor")
	runner.seek(float(at.personnel_dropped))
	check(people("source") == initial_people.slice(0, 6) and people("target") == initial_people.slice(6), "personnel release commits six staff to the real destination group")
	check(not runner.board.is_dragging() and not bool(runner.snapshot().hand.visible), "personnel release clears both held cards and the visual hand")

	runner.seek(float(at.work_open))
	fan = runner.board.side_extract.view
	check(fan.is_open() and fan.kind == "work" and fan.records.size() > 400, "the same source exposes hundreds of real work cards after production")
	check(fan.preview_cards.size() <= int(fan.settings.max_render_cards), "hundreds of work retain bounded drawn-card cost")
	runner.seek(float(at.work_cut))
	fan = runner.board.side_extract.view
	check(absi(fan.focus_index - roundi(float(fan.records.size() - 1) * 0.5)) <= 1, "work cut follows the middle of the current real stack, not a stale five-hundred count")
	var paused_snapshot: Dictionary = runner.snapshot()
	var paused_faces: Array = fan.preview_cards.map(func(card): return card.position)
	await process_frame
	await process_frame
	check(runner.snapshot() == paused_snapshot and fan.preview_cards.map(func(card): return card.position) == paused_faces, "paused playback freezes the simulation and local spread animation")
	runner.seek(float(at.work_drag))
	var taken_work: Array = runner.board._drag_cards.map(func(card): return card.uid)
	check(runner.board.is_dragging() and taken_work.size() > 200, "dense work cut enters a real drag with hundreds of UIDs")
	check(taken_work.all(func(uid): return runner.state.cards[uid].type == "work"), "work cut leaves all staff and overtime tools in their existing groups")
	runner.seek(float(at.work_dropped))
	check(runner._groups.has("extracted_work"), "release records the actual new empty-table group")
	if runner._groups.has("extracted_work"):
		check(work("extracted_work") == taken_work, "all dragged work lands in one real new pile without changing order")
		check(int(runner._groups.extracted_work) not in [int(runner._groups.source), int(runner._groups.target)], "work landed on the configured empty area rather than an existing combination")
		check(people("extracted_work").is_empty(), "work-only cut contains no phantom employee")
	check(people("source").size() == 6 and people("target").size() == 6, "both working combinations retain their six employees after material extraction")
	conserved(initial_work, initial_people)
	runner.seek(float(at.expanded_remaining))
	check(not bool(visual_group("source").compact), "remaining huge source expands again using its changed actual composition")
	runner.seek(float(at.finished))
	check(bool(visual_group("source").compact), "demonstration ends with the source folded back")
	check(runner.state.winner < 0 and runner.snapshot().events.any(func(event): return event.kind == "work_complete" and int(event.owner) == 0), "production keeps running throughout the demonstration")
	conserved(initial_work, initial_people)

	# Reconstructing an earlier time must replay both real cuts identically.
	runner.seek(float(at.work_cut))
	var replay: Dictionary = runner.snapshot()
	for key in paused_snapshot:
		if not same_state(replay[key], paused_snapshot[key]): printerr("REPLAY_DIFF ", key)
	check(same_state(replay, paused_snapshot), "rewinding and replaying reconstructs the same real large-pile state and poses within floating-point tolerance")
	check(not DirAccess.dir_exists_absolute(OS.get_environment("WORK_DATA_DIR")), "preview writes no player preferences or game data")
	viewport.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("HUGE_STACK_PREVIEW %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
