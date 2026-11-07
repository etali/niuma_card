extends "res://tests/off_work/test_work_ui.gd"

## Real pointer input through the inherited Board: elevated stacks must agree
## with the footprint they occupy once lowered onto another stack.
func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await _settle()
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	board.touch_mode = true
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.money = 0
	board.set_snap_hit_fraction(0.75)
	for angle in [45.0, 60.0, 80.0]:
		for count in [67, 1]: await _landing_stack(angle, count)
		await _outside_boundary(angle)
	await _visible_center()
	await _visible_priority(70)
	await _visible_priority(1)
	await _small_correction()
	await _empty_small_move()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_STACK_SNAP %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(angle: float, counts: Array) -> Array:
	board.cancel_pointer()
	var initial: Array = []
	for count in counts: initial.append({"work": count})
	initial.append({"employee": 1})
	state.config.rules.initial.groups = initial
	main._new_game()
	main.hud.set_perspective_angle(angle)
	board.set_snap_hit_fraction(0.75)
	await _settle()
	_check(state.last_error.is_empty(), "fixture starts a valid new game")
	var piles: Array = []
	for gid in state.groups:
		if state.groups[gid].owner != 0: continue
		var ids: Array = state.group_cards(gid)
		if not ids.all(func(id): return state.cards[id].type == "work"): continue
		var card: CardEntity = board.by_uid[ids[0]]
		var visual: Variant = board.group_of(card)
		piles.append(visual if visual != null else {"cards": [card], "work_group_id": gid, "compact": false})
	_check(piles.size() == counts.size(), "fixture exposes every requested work pile including singletons")
	for index in mini(piles.size(), counts.size()):
		_check(piles[index].cards.size() == int(counts[index]), "fixture work count matches %d" % int(counts[index]))
	return piles

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

func _begin(card: CardEntity) -> bool:
	var start := _point(card)
	if not _check(start != Vector2.INF, "drag source exposes a real collider"): return false
	await _button(start, true)
	await _move_pointer(start + Vector2(32.0, 0.0))
	return _check(board.is_dragging(), "real mouse motion crosses the click threshold")

func _held_at(desired: Vector3) -> void:
	# Compensate the actual grip point, not the hit-test result. x/z represent
	# the intended resting footprint; original Board determines held height.
	var anchor := Vector3(desired.x - board._grab_offset.x, Board.DRAG_HEIGHT,
		desired.z - board._grab_offset.z)
	await _move_pointer(board.camera.unproject_position(anchor))
	_check(Vector2(board._drag_cards[0].global_position.x - desired.x,
		board._drag_cards[0].global_position.z - desired.z).length() < 0.001,
		"original drag loop reaches the intended x/z footprint")

func _release() -> void:
	await _button(pointer, false)
	await _settle()
	_check(not board.is_dragging(), "release clears the original drag state")

func _landing_stack(angle: float, count: int) -> void:
	var piles := await _fixture(angle, [count, 133])
	var source: CardEntity = piles[0].cards[0]
	var target: CardEntity = piles[1].cards[0]
	var source_uid := source.uid
	var target_uid := target.uid
	var target_group: int = state.cards[target_uid].group
	if not await _begin(source): return
	await _held_at(target.global_position)
	_check(board._nearest_group(source.global_position, board._drag_cards) == piles[1],
		"%d degrees, %d cards: resting footprint previews target stack" % [angle, count])
	if angle == 45.0:
		_check(is_inf(board._face_hit_distance(source.global_position, target)),
			"45 degrees reproduces the elevated visual-centre miss")
		_check(is_finite(board._snap_distance(source.global_position, target)),
			"ordinary stacking accepts the matching resting footprint")
	await _release()
	_check(state.cards[source_uid].group == target_group and state.cards[target_uid].group == target_group,
		"%d degrees, %d cards: real release merges into the target" % [angle, count])
	_check(state.group_cards(target_group).size() == count + 133,
		"%d degrees, %d cards: merged count and identities are preserved" % [angle, count])

func _outside_boundary(angle: float) -> void:
	var piles := await _fixture(angle, [67, 133])
	var source: CardEntity = piles[0].cards[0]
	var target: CardEntity = piles[1].cards[0]
	var original_group: int = state.cards[source.uid].group
	if not await _begin(source): return
	# Move away from the camera's lateral centre, so perspective cannot turn
	# an out-of-bounds landing point into a valid visual-centre hit.
	var direction := signf(target.global_position.x - board.camera.global_position.x)
	if is_zero_approx(direction): direction = -1.0
	var edge := target.global_position + Vector3(direction * (CardEntity.CARD_SIZE.x * 0.75 * 0.5 + 0.01), 0, 0)
	await _held_at(edge)
	_check(is_inf(board._face_hit_distance(source.global_position, target)), "boundary fixture also misses the visible face")
	_check(is_inf(board._snap_distance(source.global_position, target)), "%d degrees: just outside 75%% remains outside" % angle)
	await _release()
	_check(state.cards[source.uid].group == original_group, "out-of-range drop remains a separate real group")
	# Repeat on clear tabletop: height compensation must not restore the old
	# broad circular snapping radius around a neighbouring pile.
	piles = await _fixture(angle, [67, 133])
	source = piles[0].cards[0]
	target = piles[1].cards[0]
	original_group = state.cards[source.uid].group
	if not await _begin(source): return
	await _held_at(target.global_position + Vector3(CardEntity.CARD_SIZE.x + 0.1, 0, 0))
	_check(board._nearest_group(source.global_position, board._drag_cards) == null, "adjacent blank table has no hover target")
	await _release()
	_check(state.cards[source.uid].group == original_group, "adjacent blank-table drop does not merge")

func _ray_at_height(screen: Vector2, height: float) -> Vector3:
	var origin := board.camera.project_ray_origin(screen)
	var ray := board.camera.project_ray_normal(screen)
	return origin + ray * ((height - origin.y) / ray.y)

func _visible_center() -> void:
	var piles := await _fixture(45.0, [67, 133])
	var source: CardEntity = piles[0].cards[0]
	var target: CardEntity = piles[1].cards[0]
	var group: int = state.cards[target.uid].group
	if not await _begin(source): return
	var desired := _ray_at_height(board.camera.unproject_position(target.global_position), source.global_position.y)
	await _held_at(desired)
	_check(board._face_hit_distance(source.global_position, target) < 0.001, "visual-centre fixture really points at the visible target")
	_check(absf(source.global_position.z - target.global_position.z) > CardEntity.CARD_SIZE.z * 0.75 * 0.5,
		"visual-centre fixture would miss if only vertical landing were used")
	await _release()
	_check(state.cards[source.uid].group == group, "existing visual-centre merge remains supported")

func _place_top(group: Dictionary, at: Vector3) -> void:
	var origin: Vector3 = at - board._stack_offset(group, 0)
	var gid: int = group.work_group_id
	board._origin_by_gid[gid] = origin
	board.group_overrides[gid] = origin
	board._layout_group(group, origin)

func _visible_priority(visible_count: int) -> void:
	var piles := await _fixture(45.0, [67, visible_count, 63])
	var source: CardEntity = piles[0].cards[0]
	var visible: CardEntity = piles[1].cards[0]
	var landing: CardEntity = piles[2].cards[0]
	# Put both possible targets in the playable area; the held centre points
	# exactly at the visible target, while its vertical footprint hits another.
	var centre := board.player_bounds.get_center()
	var landing_top := Vector3(centre.x, landing.global_position.y, centre.y + 0.55)
	_place_top(piles[2], landing_top)
	await _settle()
	var held_height := Board.DRAG_HEIGHT + board._stack_offset(piles[0], 0).y
	var elevated := Vector3(landing.global_position.x, held_height, landing.global_position.z)
	var visible_top := _ray_at_height(board.camera.unproject_position(elevated), visible.global_position.y)
	_place_top(piles[1], visible_top)
	await _settle()
	var preferred_group: int = state.cards[visible.uid].group
	if not await _begin(source): return
	await _held_at(landing.global_position)
	_check(board._face_hit_distance(source.global_position, visible) < 0.001, "priority fixture hits the visible target centre")
	_check(is_inf(board._face_hit_distance(source.global_position, landing)), "priority fixture's landing target is visually separate")
	if visible_count > 1:
		_check(board._nearest_group(source.global_position, board._drag_cards) == piles[1], "visible target wins over an alternative landing target")
	else:
		_check(board._nearest_group(source.global_position, board._drag_cards) == null, "landing group does not steal a visibly targeted loose card")
		_check(board._nearest_loose_card(source.global_position, board._drag_cards) == visible, "visibly targeted loose card remains selectable")
	await _release()
	_check(state.cards[source.uid].group == preferred_group, "release follows the visible preview priority")
	_check(state.cards[landing.uid].group != preferred_group, "fallback target is not accidentally absorbed")

func _small_correction() -> void:
	var piles := await _fixture(45.0, [67, 133])
	var source: CardEntity = piles[0].cards[0]
	var target: CardEntity = piles[1].cards[0]
	var target_group: int = state.cards[target.uid].group
	_place_top(piles[0], target.global_position + Vector3(0.02, 0.04, 0.0))
	await _settle()
	var original_group: int = state.cards[source.uid].group
	await _click(_point(source))
	_check(state.cards[source.uid].group == original_group, "clicking an overlapping stack still does not merge")
	# Keep this intentional drag outside the original double-click window.
	await create_timer(0.5).timeout
	var before := source.global_position
	if not await _begin(source): return
	await _held_at(before + Vector3(0.05, 0, 0))
	_check(Vector2(source.global_position.x - before.x, source.global_position.z - before.z).length() < 0.12,
		"correction ends inside the original 0.12 return-to-origin threshold")
	_check(board._nearest_group(source.global_position, board._drag_cards) == piles[1], "small correction previews the overlapping other stack")
	await _release()
	_check(state.cards[source.uid].group == target_group, "small intentional correction merges instead of restoring the overlap")

func _empty_small_move() -> void:
	var piles := await _fixture(45.0, [67, 133])
	var source: CardEntity = piles[0].cards[0]
	var original_group: int = state.cards[source.uid].group
	var before := source.global_position
	if not await _begin(source): return
	await _held_at(before + Vector3(0.05, 0, 0))
	await _release()
	_check(state.cards[source.uid].group == original_group and source.global_position.distance_to(before) < 0.001,
		"small drag without another target keeps the original exact restore behavior")
