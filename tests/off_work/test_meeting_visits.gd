extends SceneTree

var game: Node
var board: OffWorkBoard
var state: OffWorkState
var pointer := Vector2.ZERO
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1600, 900)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	board = game.board
	board.touch_mode = true
	state = game.state
	state.config.rules.bot.enabled = false
	_check(board.offers_by_id.size() == 6 and board.pawn_pos.x > board.offers_by_id.values().back().global_position.x, "six products and rightmost original dismissal facility")
	await _meeting_round_trip()
	await _orbit_follows_meeting_card()
	await _drag_live_meeting_tool()
	await _exact_coffee_drop()
	await _enemy_meeting_upgrade()
	await _meeting_interrupts_tail_drag()
	await _relocate_target_source_stack()
	await _drag_returning_person_with_stack()
	game.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("MEETING_VISITS ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _restart(groups: Array) -> void:
	state.config.rules.initial.groups = groups
	game._new_game()
	await _settle()

func _ids(kind: String, owner := 0) -> Array:
	return state.cards.keys().filter(func(uid): return state.cards[uid].type == kind and int(state.cards[uid].owner) == owner)

func _meeting_round_trip() -> void:
	await _restart([{"employee": 4, "work": 24}, {"leader": 1}, {"meeting": 1}])
	var host: int = _ids("leader")[0]
	var tool: int = _ids("meeting")[0]
	state.advance(2.0)
	var before: Dictionary = {}
	for uid in _ids("employee", 1): before[uid] = float(state.cards[uid].progress)
	_check(state.move_cards([tool], int(state.cards[host].group)) >= 0 and state.meetings.has(tool), "leader starts meeting with random targets")
	var targets: Array = state.meetings[tool].targets.duplicate()
	_check(targets.size() == 4, "leader gathers four available enemy people")
	var originals: Dictionary = {}
	for uid in targets:
		originals[uid] = {"node": board.by_uid[uid], "owner": state.cards[uid].owner, "group": state.cards[uid].group, "work": state.tasks.get(uid, {}).get("work_id", -1)}
	board.set_process(false)
	board.sync_state(state)
	for uid in targets:
		_check(board._meeting_visitors.has(uid) and board.by_uid[uid] == originals[uid].node, "meeting moves real personnel UID %d" % uid)
		_check(not board.enemy_board.cards.has(board.by_uid[uid]) and not board.by_uid[uid].draggable, "visitor leaves source display group and cannot be dragged %d" % uid)
		_check(not board.by_uid[uid]._task_progress.visible and board.by_uid[uid].is_meeting_participant(), "being pulled hides only personnel progress %d" % uid)
	board._advance_meeting_visitors(0.30)
	var halfway: Dictionary = {}
	for uid in targets:
		halfway[uid] = board.by_uid[uid].global_position
		_check(board.by_uid[uid].global_position.y > float(board._settings.rest_y), "forced pull has an elevated arc %d" % uid)
	board.sync_state(state)
	for uid in targets: _check(board.by_uid[uid].global_position.distance_to(halfway[uid]) < 0.001, "sync cannot teleport visitor home during flight %d" % uid)
	board.set_process(true)
	paused = true
	await create_timer(0.2, true).timeout
	for uid in targets: _check(board.by_uid[uid].global_position.distance_to(halfway[uid]) < 0.001, "drawer-style pause freezes meeting flight %d" % uid)
	board.set_process(false)
	paused = false
	board._advance_meeting_visitors(1.0)
	for uid in targets:
		var at: Vector3 = board.by_uid[uid].global_position
		_check(board.player_bounds.has_point(Vector2(at.x, at.z)), "enemy personnel actually arrives on host desk %d" % uid)
		_check(state.cards[uid].owner == originals[uid].owner and state.cards[uid].group == originals[uid].group, "meeting preserves real owner and group %d" % uid)
		_check(board._meeting_visitors[uid].phase == "orbit" and not board.by_uid[uid]._task_progress.visible, "visitor orbits with no task timer %d" % uid)
		board._on_card_clicked(board.by_uid[uid])
		_check(not board.is_dragging(), "host cannot grab visitor %d" % uid)
	state.advance(2.0)
	for uid in targets:
		if before.has(uid): _check(is_equal_approx(state.group_work_progress(int(state.cards[uid].group)), float(before[uid])), "group retains progress while all four workers are in meeting %d" % uid)
	_check(state.move_cards([host], -1) >= 0 and state.meetings.is_empty(), "moving host releases meeting immediately")
	board.sync_state(state)
	board._advance_meeting_visitors(1.0)
	_check(board._meeting_visitors.is_empty(), "all released targets finish return")
	for uid in targets:
		var card: OffWorkCard = board.by_uid[uid]
		_check(card == originals[uid].node and board.enemy_board.cards.has(card), "return restores exactly the same source entity %d" % uid)
		_check(card.global_position.distance_to(board.enemy_board.rest_pos(card)) < 0.001, "return lands at current native pile location %d" % uid)
		_check(not card.is_meeting_participant() and card._visual.scale.is_equal_approx(Vector3.ONE), "return releases visual scale and progress suppression %d" % uid)
	board.set_process(true)

func _orbit_follows_meeting_card() -> void:
	await _restart([{"employee": 4, "work": 24}, {"employee": 1}, {"meeting": 1}])
	var host: int = _ids("employee")[-1]
	var tool: int = _ids("meeting")[0]
	state.advance(1.25)
	_check(state.move_cards([tool], int(state.cards[host].group)) >= 0, "employee starts a two-person orbit")
	var targets: Array = state.meetings[tool].targets.duplicate()
	var logical_order: Array = state.group_cards(int(state.cards[host].group)).duplicate()
	board.set_process(false)
	board.sync_state(state)
	await _settle()
	board._advance_meeting_visitors(1.0)
	_check(targets.size() == 2 and board._meeting_centers.has(tool), "one actual meeting card anchors two targets")
	var center: Vector3 = board.by_uid[tool].global_position
	_check(center.y > board.by_uid[host].global_position.y and board.by_uid[tool]._task_progress.visible, "meeting is the native top card and owns its timer")
	_check(not board.by_uid[host]._task_progress.visible, "host does not duplicate the meeting timer")
	var before: Dictionary = {}
	for uid in targets: before[uid] = board.by_uid[uid].global_position
	board._advance_meeting_visitors(0.6)
	for uid in targets:
		_check(board.by_uid[uid].global_position.distance_to(before[uid]) > 0.1, "visitors continuously orbit instead of seating %d" % uid)
	var current_center: Vector3 = board.by_uid[tool].global_position
	var current_positions: Dictionary = {}
	for uid in targets: current_positions[uid] = board.by_uid[uid].global_position
	board.by_uid[tool].global_position.x += 0.6
	board._advance_meeting_visitors(0.0)
	var shift: Vector3 = board.by_uid[tool].global_position - current_center
	for uid in targets:
		_check((board.by_uid[uid].global_position - current_positions[uid]).is_equal_approx(shift), "orbit follows actual meeting center without phase reset %d" % uid)
	_check(state.group_cards(int(state.cards[host].group)) == logical_order, "presenting the meeting never changes logical stack order")
	# Move the actual center to legal near-corner card positions. The orbit
	# shrinks to the available room without moving the host stack.
	var original_drawer := board.drawer_mode
	for drawer in [false, true]:
		board.drawer_mode = drawer
		var region: Rect2 = board.TableRegions.zone_rect(true, drawer, state.offers.size())
		var inset := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5
		for corner in [region.position + inset, region.end - inset]:
			board.by_uid[tool].global_position = Vector3(corner.x, 0.095, corner.y)
			for step in 16:
				board._advance_meeting_visitors(float(board._settings.meeting_motion.orbit_period_seconds) / 16.0)
				for uid in targets:
					var pos: Vector3 = board.by_uid[uid].global_position
					_check(region.has_point(Vector2(pos.x, pos.z)), "orbit stays on host side across window bounds")
	board.drawer_mode = original_drawer
	state.advance(state.config.number("meeting", "duration_seconds"))
	board.sync_state(state)
	for uid in targets:
		_check(board.by_uid[uid].is_meeting_participant() and not board.by_uid[uid]._task_progress.visible, "return keeps personnel bar hidden until landed")
	board._advance_meeting_visitors(1.0)
	_check(board._meeting_centers.is_empty() and board._meeting_visitors.is_empty(), "meeting completion releases the central display and every visitor")
	for uid in targets:
		_check(not board.by_uid[uid].is_meeting_participant() and is_equal_approx(float(state.cards[uid].progress), state.group_work_progress(int(state.cards[uid].group))), "returned person rejoins the current shared work progress")
	board.set_process(true)

func _drag_live_meeting_tool() -> void:
	await _restart([{"employee": 4, "work": 24}, {"leader": 1}, {"meeting": 1}])
	var host: int = _ids("leader")[0]
	var tool: int = _ids("meeting")[0]
	var gid := int(state.cards[host].group)
	state.move_cards([tool], gid)
	board.sync_state(state)
	await create_timer(1.1).timeout
	var before: float = state.meetings[tool].remaining
	_check(board.by_uid[tool].draggable and _point(board.by_uid[tool]) != Vector2.INF, "raised meeting card remains reachable through the native pointer")
	await _drag(board.by_uid[tool], board.camera.unproject_position(Vector3(5.0, 0.05, 4.3)), true)
	_check(state.meetings.has(tool) and int(state.cards[tool].group) == gid and state.meetings[tool].remaining == before, "moving the compact center stack preserves its real meeting and timer")
	var group: Dictionary = board.group_of(board.by_uid[tool])
	if group.compact: board.toggle_compact(group.cards[0])
	await _settle()
	_check(group.cards.back().uid == tool, "expanded native ordering leaves meeting tool at the draggable tail")
	await _drag(board.by_uid[tool], board.camera.unproject_position(Vector3(-4.0, 0.05, 4.3)), true)
	_check(not state.meetings.has(tool) and int(state.cards[tool].group) != int(state.cards[host].group), "native tool-only drag dissolves the meeting instead of being locked by its animation")
	await create_timer(1.0).timeout
	_check(board._meeting_centers.is_empty() and board._meeting_visitors.is_empty(), "dragging the live tool releases every temporary center and visitor pose")

func _exact_coffee_drop() -> void:
	await _restart([{"work": 24}, {"employee": 1}, {"employee": 1}, {"coffee": 1}])
	var people := _ids("employee")
	var target: int = people[1]
	var other: int = people[0]
	var coffee: int = _ids("coffee")[0]
	var node: OffWorkCard = board.by_uid[target]
	# A long horizontal drag retains the native world-space grip. Align the
	# held card's visible centre, rather than mistaking the pointer for it.
	await _drag(board.by_uid[coffee], _point(node), false, -1, -1, true)
	_check(state.cards[target].type == "employee" and state.cards[coffee].status == "active", "coffee drop begins reading a real upgrade bar")
	state.advance(state.config.number("coffee", "seconds"))
	game._process(0.0)
	_check(state.cards[target].type == "grinder" and state.cards[other].type == "employee", "coffee native mouse drop upgrades the exact touched employee")
	_check(not state.cards.has(coffee), "real coffee material is consumed once")
	_check(game._selected_tool == -1, "consumed coffee clears selected UID so Esc and idle hint remain available")
	_check(board.by_uid[target] == node and node.def_id == "grinder", "same UID and node refresh role after upgrade")
	_check(game.bot.is_started(), "idle employee upgrade is a meaningful first action")

func _enemy_meeting_upgrade() -> void:
	await _restart([{"work": 24}, {"employee": 1}, {"leader": 1}, {"meeting": 1}, {"coffee": 1}])
	var host: int = _ids("leader", 1)[0]
	var tool: int = _ids("meeting", 1)[0]
	var person: int = _ids("employee")[0]
	var coffee: int = _ids("coffee")[0]
	_check(state.move_cards([tool], int(state.cards[host].group)) >= 0 and state.meetings.has(tool), "opponent starts real meeting")
	board.sync_state(state)
	await create_timer(1.1).timeout
	_check(state.meetings[tool].targets.has(person) and board._meeting_visitors.has(person), "BOT meeting takes local employee away")
	var node: OffWorkCard = board.by_uid[person]
	_check(not board.cards.has(node) and not node.draggable, "captured local employee cannot be grabbed back")
	var click_at := _point(node)
	await _button(click_at, true)
	_check(board._press_snap.is_empty() and not board.is_dragging(), "native click on visitor cannot create a hidden drag snapshot")
	await _button(click_at, false)
	_check(node.freeze and not board.cards.has(node), "visitor click release cannot re-enable physics or source membership")
	var at: Vector3 = node.global_position
	_check(board.enemy_board.player_bounds.has_point(Vector2(at.x, at.z)), "local employee physically arrives at enemy desk")
	_check(state.move_cards([person], -1) < 0 and not state.dismiss_people([person], 0), "captured personnel cannot escape via move or dismissal API")
	await _drag(board.by_uid[coffee], _point(node))
	_check(state.cards[person].type == "employee" and state.cards[coffee].status == "ready" and state.cards[coffee].group == state.cards[person].group and not board.by_uid[coffee]._task_progress.visible, "coffee waits without a progress bar in the captured employee's empty group")
	_check(state.meetings[tool].targets.has(person) and bool(state.cards[person].paused), "upgrade does not release meeting or change target identity")
	state.advance(float(state.config.rules.meeting.duration_seconds))
	board.sync_state(state)
	await create_timer(0.9).timeout
	_check(not board._meeting_visitors.has(person) and board.by_uid[person] == node and node.draggable and state.cards[person].type == "employee", "employee returns with the same node before its upgrade completes")
	state.advance(state.config.number("coffee", "seconds"))
	game._process(0.0)
	_check(state.cards[person].type == "grinder" and not state.cards.has(coffee) and board.by_uid[person] == node, "returned employee completes upgrade only after reading its full timer")
	# Restart while another person is in flight must discard only old view state.
	var fresh: int = state.add_card("meeting", 1, int(state.cards[host].group))
	state.activate(fresh, int(state.cards[host].group), host)
	board.sync_state(state)
	_check(not board._meeting_visitors.is_empty(), "restart fixture has an actual ongoing pull")
	game._new_game()
	_check(board._meeting_visitors.is_empty() and board._meeting_home_order.is_empty() and board.by_uid.size() == state.cards.size(), "restart discards visitor animation and restores exactly live entities")

func _meeting_interrupts_tail_drag() -> void:
	await _restart([{"employee": 1, "work": 3}, {"work": 21}, {"leader": 1}, {"meeting": 1}])
	var person: int = _ids("employee")[0]
	var group: Dictionary = board.group_of(board.by_uid[person])
	if group.compact: board.toggle_compact(group.cards[0])
	await _settle()
	var tail: CardEntity = group.cards[1]
	var logical: Array = state.group_cards(int(state.cards[person].group)).duplicate()
	board._snapshot_press(tail, _point(tail))
	board._on_card_clicked(tail)
	_check(not board._drag_cards.has(board.by_uid[person]) and board._press_snap.cards.has(board.by_uid[person]), "tail drag snapshot includes unheld employee prefix")
	var host: int = _ids("leader", 1)[0]
	var meeting: int = _ids("meeting", 1)[0]
	state.move_cards([meeting], int(state.cards[host].group))
	board.sync_state(state)
	_check(state.meetings[meeting].targets.has(person) and board._meeting_visitors.has(person), "meeting pulls unheld employee from source prefix")
	_check(not board.is_dragging() and board._press_snap.is_empty(), "meeting cancels the full original snapshot before taking prefix")
	board.cancel_pointer()
	_check(board.group_of(board.by_uid[person]) == null and not board.cards.has(board.by_uid[person]), "later cancel cannot reinsert visitor into native source group")
	_check(state.group_cards(int(state.cards[person].group)) == logical, "interrupted drag preserves all logical source members")
	for native in board.groups: _check(not native.cards.has(board.by_uid[person]), "no native pile retains an invisible visitor reference")
	state.advance(float(state.config.rules.meeting.duration_seconds))
	board.sync_state(state)
	await create_timer(0.9).timeout
	_check(board.cards.has(board.by_uid[person]) and board.group_of(board.by_uid[person]) != null, "interrupted prefix returns to its original native group")

func _relocate_target_source_stack() -> void:
	for mode in ["whole", "split", "merge"]:
		await _restart([{"employee": 1, "work": 4}, {"work": 20}, {"leader": 1}, {"meeting": 1}])
		var person: int = _ids("employee")[0]
		var gid := int(state.cards[person].group)
		var host: int = _ids("leader", 1)[0]
		var meeting: int = _ids("meeting", 1)[0]
		state.advance(2.0)
		var work: int = state.tasks[person].work_id
		var progress: float = state.cards[work].progress
		state.move_cards([meeting], int(state.cards[host].group))
		board.sync_state(state)
		await create_timer(1.1).timeout
		var group: Dictionary = board.group_of(board.by_uid[work])
		var old_origin := board.rest_origin(group)
		var origin_owner: int = state.cards[person].owner
		if mode == "split":
			if group.compact: board.toggle_compact(group.cards[0])
			await _settle()
			var prefix: Array = group.cards.slice(0, 2).map(func(card): return card.uid)
			var suffix: Array = group.cards.slice(2).map(func(card): return card.uid)
			await _drag(group.cards[2], board.camera.unproject_position(Vector3(-1.5, 0.05, 4.4)), true)
			_check(int(state.cards[suffix[0]].group) != gid and state.group_work(gid).size() == 2, "real tail split still creates a separate group while coworker is away")
			_check(not state.tasks.has(person) and prefix.all(func(uid): return state.group_work(gid).has(uid)) and is_equal_approx(state.group_work_progress(gid), progress), "tail split retains the visible source prefix and shared progress without reserving a visitor's slot")
		elif mode == "merge":
			var destination := -1
			for other in state.groups:
				if int(state.groups[other].owner) == 0 and int(other) != gid and not state.group_work(other).is_empty(): destination = int(other)
			var target: OffWorkCard = board.by_uid[state.group_work(destination)[0]]
			var moved: Array = state.group_work(gid).duplicate()
			await _drag(group.cards[0], board.camera.unproject_position(target.global_position + Vector3(0, CardEntity.Y_TEXT, 0)), false, -1, destination)
			_check(moved.all(func(uid): return int(state.cards[uid].group) == destination), "real merge into a different pile still changes work group")
			_check(int(state.cards[person].group) == gid and not state.tasks.has(person), "deliberate work reassignment leaves meeting person behind and cancels only lost task")
		else:
			var members: Array = state.group_cards(gid).duplicate()
			await _drag(group.cards[0], board.camera.unproject_position(Vector3(5.0, 0.05, 4.4)), true)
			_check(state.group_cards(gid) == members and int(state.cards[work].group) == gid, "moving complete visible stack preserves original logical group with absent visitor")
			_check(not state.group_work_participants(gid).has(person) and int(state.cards[work].group) == gid and is_equal_approx(state.group_work_progress(gid), progress), "pure relocation preserves group progress and excludes the visiting worker")
			var moved_origin := board.rest_origin(board.group_of(board.by_uid[work]))
			_check(moved_origin.distance_to(old_origin) > 1.0, "actual Viewport gesture moved the original stack to a new empty location")
			_check(board._meeting_visitors.has(person) and int(state.cards[person].owner) == origin_owner, "relocating home stack cannot pull visitor out of the meeting")
			state.advance(float(state.config.rules.meeting.duration_seconds))
			board.sync_state(state)
			await create_timer(0.9).timeout
			var returned: Dictionary = board.group_of(board.by_uid[person])
			_check(int(returned.work_group_id) == gid and board.rest_origin(returned).distance_to(moved_origin) < 0.01, "visitor returns to relocated original pile rather than an old empty group")
			_check(state.tasks.has(person) and is_equal_approx(float(state.cards[person].progress), state.group_work_progress(gid)) and is_equal_approx(state.group_work_progress(gid), progress), "returned worker rejoins the preserved combination progress")

func _drag_returning_person_with_stack() -> void:
	await _restart([{"work": 4}, {"employee": 1}, {"work": 20}, {"leader": 1}, {"meeting": 1}])
	var person: int = _ids("employee")[0]
	var work: int = _ids("work")[0]
	var gid := int(state.cards[work].group)
	var group: Dictionary = board.group_of(board.by_uid[work])
	if not group.compact: board.toggle_compact(group.cards[board._top_index(group)])
	await _settle()
	state.move_cards([person], gid)
	board.sync_state(state)
	await _settle()
	var host: int = _ids("leader", 1)[0]
	var meeting: int = _ids("meeting", 1)[0]
	state.move_cards([meeting], int(state.cards[host].group))
	board.sync_state(state)
	await create_timer(1.1).timeout
	state.advance(float(state.config.rules.meeting.duration_seconds))
	board.sync_state(state)
	group = board.group_of(board.by_uid[work])
	_check(board._meeting_visitors.has(person) and board._meeting_visitors[person].phase == "return" and group.compact and group.cards[0].def_id == "work", "returning employee belongs to the compact pile under its draggable work top")
	var members: Array = state.group_cards(gid).duplicate()
	await _drag(group.cards[0], board.camera.unproject_position(Vector3(5.0, 0.05, 4.3)), true, person)
	_check(not board._meeting_visitors.has(person) and state.group_cards(gid) == members, "whole-pile pickup takes ownership from return animation without splitting logical group")
	var card: OffWorkCard = board.by_uid[person]
	_check(not card.has_meta("meeting_visit") and not card.has_meta("in_flight") and card.draggable, "return handoff clears only meeting motion and leaves usable personnel")
	var at := card.global_position
	board._advance_meeting_visitors(2.0)
	_check(card.global_position.distance_to(at) < 0.001, "stale return animation cannot steal the card from its new pile")

func _point(card: CardEntity) -> Vector2:
	for z in [0.0, -0.35, 0.35]:
		var at := board.camera.unproject_position(card.global_position + Vector3(0, CardEntity.Y_TEXT, z * CardEntity.CARD_SIZE.z))
		if game.hud.content_rect().has_point(at) and board._pick_card(at) == card: return at
	return Vector2.INF

func _button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	pointer = at
	root.push_input(event, true)
	await process_frame

func _drag(card: CardEntity, destination: Vector2, empty := false, returning_person := -1, expected_group := -1, align_face := false) -> void:
	var start := _point(card)
	_check(start != Vector2.INF and destination != Vector2.INF, "original drag targets are visible")
	if start == Vector2.INF or destination == Vector2.INF: return
	var ground := Vector3.ZERO
	if empty:
		var ray := board.camera.project_ray_normal(destination)
		var origin := board.camera.project_ray_origin(destination)
		ground = origin + ray * ((0.05 - origin.y) / ray.y)
	await _button(start, true)
	if returning_person >= 0:
		_check(board._drag_cards.has(board.by_uid[returning_person]) and not board._meeting_visitors.has(returning_person), "native head pickup immediately hands returning member to drag ownership")
	if empty:
		var trigger := InputEventMouseMotion.new()
		trigger.position = start + Vector2(10, 0)
		trigger.global_position = trigger.position
		trigger.relative = Vector2(10, 0)
		trigger.button_mask = MOUSE_BUTTON_MASK_LEFT
		pointer = trigger.position
		root.push_input(trigger, true)
		await process_frame
		destination = board.camera.unproject_position(Vector3(ground.x - board._grab_offset.x, Board.DRAG_HEIGHT, ground.z - board._grab_offset.z))
	for step in range(1, 9):
		var at := start.lerp(destination, float(step) / 8.0)
		var event := InputEventMouseMotion.new()
		event.position = at
		event.global_position = at
		event.relative = at - pointer
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
		pointer = at
		root.push_input(event, true)
		await process_frame
	if expected_group >= 0 or align_face:
		# A compact hand keeps its native grip offset/layer height. Align the
		# held card face, rather than assuming pointer == centre of that face.
		var face_target := destination
		for correction in 2:
			destination = pointer + face_target - board.camera.unproject_position(card.global_position)
			var event := InputEventMouseMotion.new()
			event.position = destination
			event.global_position = destination
			event.relative = destination - pointer
			event.button_mask = MOUSE_BUTTON_MASK_LEFT
			pointer = destination
			root.push_input(event, true)
			await process_frame
		if expected_group >= 0:
			var hovered: Variant = board._hover_group
			_check(hovered != null and int(hovered.get("work_group_id", -1)) == expected_group, "explicit centre drop highlights destination before release")
	await _button(destination, false)
	await _settle()

func _settle() -> void:
	await create_timer(0.45).timeout
	await physics_frame
	await process_frame

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
