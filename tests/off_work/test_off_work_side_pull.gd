extends "res://tests/off_work/test_side_extract.gd"

## 重新分工一步到位：按住侧边清单的一行往外拖，这一类的牌就直接从摞里出来、跟着指针走
## （一张；按住 Shift 是这一类的全部）。原地点一下仍然是打开扇牌。规则只在松手时才变。
## 走根 Viewport 的真实按下、移动、松手。
func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-side-pull-%d" % OS.get_process_id())
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
	await _pull_one()
	await _pull_everyone()
	await _click_still_opens_the_fan()
	await _let_go_where_it_came_from()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("SIDE_PULL %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

## 侧边清单上这一类那一行在屏幕上的位置。
func _row(kind: String) -> Vector2:
	var visual: Dictionary = board.group_of(board.by_uid[_owned("work")])
	var rows: Array = board.side_extract.side_rows(visual)
	for index in rows.size():
		if rows[index].kind == kind:
			return board.camera.unproject_position((visual.side[index * 2 + 1] as Node3D).global_position)
	return Vector2.INF

func _motion(at: Vector2, shift := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.shift_pressed = shift
	pointer = at
	root.push_input(event)
	await process_frame

func _people(gid: int) -> Array:
	return state.group_people(gid)

func _pull_one() -> void:
	var gid := await _fixture([{"work": 200, "employee": 5, "overtime": 1}])
	var at := _row("employee")
	if not _check(at != Vector2.INF, "the side list has an employee row"): return
	var before := _people(gid).size()
	var revision: int = state.revision
	await _button(at, true)
	_check(not board.is_dragging() and not board.side_extract.is_open(), "pressing the row does nothing yet")
	var threshold := float(board._settings.side_extract.drag_threshold)
	await _motion(at + Vector2(threshold - 2.0, 0))
	_check(not board.is_dragging(), "a small wobble under the drag threshold is still a click in the making")
	await _motion(at + Vector2(threshold + 6.0, 0))
	_check(board.is_dragging() and board._drag_cards.size() == 1 and board._drag_cards[0].def_id == "employee",
		"dragging away from the row takes exactly one employee into the hand")
	_check(not board.side_extract.is_open(), "the fan is not opened on the way")
	_check(state.revision == revision and _people(gid).size() == before, "the rules have not changed while the card is in the hand")
	var card: CardEntity = board._drag_cards[0]
	var start := card.global_position
	# It starts where it lay in the pile and slides to the pointer; it does not jump there.
	var pile_at: Vector3 = board.by_uid[_owned("work")].global_position
	_check(Vector2(start.x - pile_at.x, start.z - pile_at.z).length() < CardEntity.CARD_SIZE.z, "the card starts at its pile, not under the pointer")
	board._process(float(board._settings.side_extract.pull_seconds) * 0.5)
	var half := card.global_position
	board._process(float(board._settings.side_extract.pull_seconds))
	var under: Vector3 = board._mouse_table_point()
	_check(Vector2(half.x - start.x, half.z - start.z).length() > 0.02 and Vector2(card.global_position.x - under.x, card.global_position.z - under.z).length() < 0.05,
		"within the pull time it slides under the pointer")
	# Carry it to an empty spot and let go: only now does the pile lose one person.
	var empty := _empty_point()
	for step in range(1, 7): await _motion(pointer.lerp(empty, float(step) / 6.0))
	await _button(empty, false)
	await _settle()
	_check(_people(gid).size() == before - 1 and int(state.cards[card.uid].group) != gid, "letting go on an empty spot moves that one employee out of the pile")
	_check(state.group_work_participants(gid).size() == before - 1, "the others keep working")

func _pull_everyone() -> void:
	var gid := await _fixture([{"work": 200, "employee": 5, "overtime": 1}])
	var at := _row("employee")
	await _button(at, true)
	await _motion(at + Vector2(float(board._settings.side_extract.drag_threshold) + 6.0, 0), true)
	_check(board.is_dragging() and board._drag_cards.size() == 5 and board._drag_cards.all(func(card): return card.def_id == "employee"),
		"with Shift the drag takes every employee of the pile")
	var empty := _empty_point()
	for step in range(1, 7): await _motion(pointer.lerp(empty, float(step) / 6.0), true)
	await _button(empty, false)
	await _settle()
	_check(_people(gid).is_empty() and state.group_work(gid).size() == 200, "all five leave together; the work stays")

func _click_still_opens_the_fan() -> void:
	var gid := await _fixture([{"work": 200, "employee": 5, "overtime": 1}])
	var at := _row("employee")
	await _button(at, true)
	await _button(at, false)
	await _settle()
	_check(board.side_extract.is_open() and not board.is_dragging() and _people(gid).size() == 5, "a plain click on the row still opens the fan for exact picking")
	board.side_extract.close()

func _let_go_where_it_came_from() -> void:
	var gid := await _fixture([{"work": 200, "employee": 5, "overtime": 1}])
	var at := _row("employee")
	var revision: int = state.revision
	await _button(at, true)
	await _motion(at + Vector2(float(board._settings.side_extract.drag_threshold) + 6.0, 0))
	if not _check(board.is_dragging(), "one employee is in the hand"): return
	# Back onto the pile it came from: nothing changes. Aim at the middle of the pile's top
	# face, where the card comes down. _point() is a pickable spot on the title band, at the
	# very edge of the snap region: whether that merged used to depend on how long the frames
	# took (this check passed alone and failed under the parallel runner).
	var pile_group: Dictionary = board.group_of(board.by_uid[_owned("work")])
	var pile: Vector2 = board.camera.unproject_position(pile_group.cards[board._top_index(pile_group)].global_position)
	for step in range(1, 5): await _motion(pointer.lerp(pile, float(step) / 4.0))
	await _button(pile, false)
	await _settle()
	_check(_people(gid).size() == 5 and state.group_work_participants(gid).size() == 5, "dropped back on its own pile, everyone is still at work")
