extends SceneTree

class FullLayoutBoard extends OffWorkBoard:
	var motion_calls := 0
	func _try_compact_sync_layout(_presenter: Board, _group: Dictionary, _origin: Vector3) -> Variant:
		return null
	func _preserve_income_motion(card: CardEntity, destination: Vector3) -> bool:
		if _syncing_structure: motion_calls += 1
		return super._preserve_income_motion(card, destination)

class LocalLayoutBoard extends OffWorkBoard:
	var local_layouts := 0
	var motion_calls := 0
	var layout_debug: Array = []
	func _try_compact_sync_layout(presenter: Board, group: Dictionary, origin: Vector3) -> Variant:
		if _syncing_structure and group.cards.size() > 1000:
			var last: CardEntity = group.cards.back()
			layout_debug.append({"origin":origin,"last":last.global_position,"distance":last.global_position.distance_to(origin),
				"y":[String.num(last.global_position.y,16),String.num(origin.y,16)],
				"meta":last.get_meta_list(),"motion":presenter._move_tw.has(last),
				"running":presenter._move_tw[last].tw.is_running() if presenter._move_tw.has(last) else false})
		var result: Variant = super._try_compact_sync_layout(presenter, group, origin)
		if result != null: local_layouts += 1
		return result
	func _preserve_income_motion(card: CardEntity, destination: Vector3) -> bool:
		if _syncing_structure: motion_calls += 1
		return super._preserve_income_motion(card, destination)

var checks := 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _equal_views(fast: OffWorkBoard, full: OffWorkBoard, label: String) -> void:
	var equal := fast.by_uid.keys() == full.by_uid.keys()
	for uid in fast.by_uid:
		if not full.by_uid.has(uid): equal = false; continue
		var a: OffWorkCard = fast.by_uid[uid]
		var b: OffWorkCard = full.by_uid[uid]
		equal = equal and a.global_position.is_equal_approx(b.global_position) \
			and fast._presenter(a.card_owner).rest_pos(a).is_equal_approx(full._presenter(b.card_owner).rest_pos(b)) \
			and a.group_id == b.group_id and a.card_owner == b.card_owner and a.freeze == b.freeze \
			and a.highlighted == b.highlighted and a._visual.visible == b._visual.visible \
			and a._material_collision.disabled == b._material_collision.disabled \
			and a._task_progress_active == b._task_progress_active \
			and is_equal_approx(a._task_progress_value, b._task_progress_value)
	_check(equal, label + ": every real UID has identical position, destination, ownership, visibility and progress")
	var groups_equal := true
	for pair in [[fast, full], [fast.enemy_board, full.enemy_board]]:
		var expected := {}
		for group in pair[1].groups: expected[int(group.get("work_group_id", -1))] = group
		for group in pair[0].groups:
			var gid := int(group.get("work_group_id", -1))
			if not expected.has(gid): groups_equal = false; continue
			var other: Dictionary = expected[gid]
			groups_equal = groups_equal and group.cards.map(func(c): return c.uid) == other.cards.map(func(c): return c.uid) \
				and group.get("was_valid", false) == other.get("was_valid", false) and group.side.size() == other.side.size()
			for index in mini(group.side.size(), other.side.size()):
				groups_equal = groups_equal and group.side[index].global_position.is_equal_approx(other.side[index].global_position)
				if group.side[index] is Label3D: groups_equal = groups_equal and group.side[index].text == other.side[index].text
	_check(groups_equal, label + ": actual member order, composition feedback and every side count/position match full layout")

func _step_motion(boards: Array) -> void:
	for board in boards:
		for presenter in [board, board.enemy_board]:
			for item in presenter._move_tw.values():
				if item.tw != null and item.tw.is_valid(): item.tw.pause()
	for frame in 18:
		for board in boards:
			for presenter in [board, board.enemy_board]:
				for item in presenter._move_tw.values():
					if item.tw != null and item.tw.is_valid(): item.tw.custom_step(0.01)
		_equal_views(boards[0], boards[1], "landing frame %d" % frame)

func _fixture(people: int) -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": people, "work": 4000}]
	config.rules.initial.money = 0
	config.cards.work.work_seconds = 10.0
	var state := OffWorkState.new(config)
	state.new_game(92837)
	var fast := LocalLayoutBoard.new(false)
	var full := FullLayoutBoard.new(false)
	for board in [fast, full]:
		root.add_child(board)
		board.set_process(false)
		board.player_bounds = Rect2(-12, -7, 24, 14)
		board.enemy_board.player_bounds = board.player_bounds
		var camera := Camera3D.new()
		board.add_child(camera)
		camera.position = Vector3(0, 25, 12)
		camera.look_at(Vector3.ZERO)
		board.camera = camera
		board.enemy_board.camera = camera
		board.sync_state(state)
	_equal_views(fast, full, "initial snapshot")
	# Actual Main has already animated/resized its opening table. Board keeps
	# those finished tween records; exercise that history on every real UID.
	for board in [fast, full]:
		for card in board.by_uid.values():
			var presenter: Board = board._presenter(card.card_owner)
			presenter._move_to(card, card.global_position + Vector3(0.125, 0, 0))
			if presenter._move_tw.has(card): presenter._move_tw[card].tw.custom_step(0.2)
	_check(fast._move_tw.size() > 3900 and full._move_tw.size() > 3900,
		"the fixture retains thousands of real completed opening-move records")
	for batch in 2:
		state.advance(10.0)
		fast.motion_calls = 0
		fast.layout_debug.clear()
		full.motion_calls = 0
		for board in [fast, full]: board.sync_state(state)
		_check(fast.local_layouts >= 2 * (batch + 1), "both actual work stacks use the local layout path")
		_check(fast.motion_calls < 200 and full.motion_calls > 7900,
			"completed motion records do not restart a full-pile movement pass (%d local / %d full, people%d batch%d %s)" % [fast.motion_calls, full.motion_calls, people, batch, str(fast.layout_debug)])
		_check(state.work_count(0) == 4000 - people * (batch + 1)
			and state.money(0) == people * (batch + 1) * config.income_per_work("employee"),
			"%d-person batch settles real work and cash without dropping identities" % people)
		_equal_views(fast, full, "batch %d immediate" % batch)
		_step_motion([fast, full])
	# A real split and a snapshot replacement also preserve full-layout results.
	var uid: int = fast._group_progress_cards.keys()[0]
	_check(state.move_cards([uid], -1), "old visible work representative splits through the real rule command")
	for board in [fast, full]: board.sync_state(state)
	_equal_views(fast, full, "split")
	var replacement := state.fork_for_bot(17)
	for board in [fast, full]: board.sync_state(replacement)
	_equal_views(fast, full, "record replacement")
	for board in [fast, full]: board.queue_free()
	await process_frame

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	for people in [12, 24]: await _fixture(people)
	for failure in failures: printerr("FAIL ", failure)
	print("INCREMENTAL_STRUCTURE_LAYOUT %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
