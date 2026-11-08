extends SceneTree

var game: Node
var board: OffWorkBoard
var state: OffWorkState
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	board = game.board
	board.touch_mode = true
	board._pointer_at = Vector2(10, 400)
	state = game.state
	var opening: Array = state.config.rules.initial.groups.duplicate(true)
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 2, "work": 25, "overtime": 2}, {"leader": 1, "transfer": 1, "work": 6},
		{"leader": 1}, {"meeting": 1}, {"employee": 1, "slack": 1}, {"coffee": 2}, {"overtime": 1}]
	seed(20261101)
	game._new_game()
	await _settle()
	state.advance(2.0)
	board.sync_state(state)
	var player_positions := _player_positions()
	var state_before := _rule_snapshot()
	for gid in _enemy_groups(): _place(int(gid), Vector3(-6.0, 0.05, -4.0))
	board.sync_state(state)
	_check(_rule_snapshot() == state_before, "automatic opponent tidying does not change groups, tasks, money or progress")
	_check(_player_positions() == player_positions, "player hand-placed positions remain exactly unchanged")
	_assert_layout("overlapping work and support combinations")
	await _settle()
	var destinations := _enemy_positions()
	var passes := board._opponent_layout_passes
	for iteration in 12: board.sync_state(state)
	_check(_enemy_positions() == destinations, "settled BOT groups do not drift over repeated state refreshes")
	_check(board._opponent_layout_passes == passes, "unchanged geometry skips repeated packing work")
	var work_group := _working_group(1)
	var staff: Array = state.group_people(work_group)
	var split := state.move_cards([staff[0]] + state.group_work(work_group).slice(0, 5), -1)
	state_before = _rule_snapshot()
	board.sync_state(state)
	_check(_rule_snapshot() == state_before, "post-split arrangement preserves the rule command's exact result")
	_assert_layout("split production group")
	var split_visual: Dictionary = board.enemy_board.group_of(board.by_uid[state.group_cards(split)[0]])
	if split_visual.compact: board.enemy_board.toggle_compact(split_visual.cards[0])
	board.sync_state(state)
	_assert_layout("expanded production stack")
	state.move_cards(state.group_cards(split).duplicate(), work_group)
	state_before = _rule_snapshot()
	board.sync_state(state)
	_check(_rule_snapshot() == state_before, "post-merge layout does not reset the shared work timer")
	_assert_layout("merged production stack")
	# Long, multi-type expanded stacks also own a tall original side column.
	for kind in ["grinder", "coffee", "overtime"]: state.add_card(kind, 1, work_group)
	board.sync_state(state)
	var expanded: Dictionary = board.enemy_board.group_of(board.by_uid[state.group_cards(work_group)[0]])
	if expanded.compact: board.enemy_board.toggle_compact(expanded.cards[0])
	board.sync_state(state)
	_assert_layout("six-type expanded stack including its side column")
	for node in expanded.get("side", []):
		if is_instance_valid(node): _check(node.global_position.z >= board.enemy_board.player_bounds.position.y and node.global_position.z <= board.enemy_board.player_bounds.end.y, "native side-column row remains on the BOT desk")
	board.enemy_board.toggle_compact(expanded.cards[0])
	board.sync_state(state)
	await _meeting_reservations()
	await _income_reservations()
	await _strike_reservations()
	await _settle()
	if OS.get_environment("WORK_OPPONENT_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://reports/opponent-combinations-layout.png")
	state.config.rules.initial.groups = opening
	state.config.rules.bot.enabled = true
	seed(20261102)
	game._new_game()
	game.bot.start()
	var snapshots := 0
	for step in 2400:
		game.bot.advance(0.2)
		state.advance(0.2)
		state.drain_events()
		if step % 25 == 0:
			board.sync_state(state)
			_assert_layout("live BOT at %.1fs" % state.time)
			snapshots += 1
			await process_frame
		if state.winner >= 0: break
	_check(state.winner == 1 and state.work_count(1) == 0, "real BOT completes its game while repeated layout checks remain enabled")
	_check(snapshots > 20, "live game covers purchases, tools, income and late combinations")
	game.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL " + failure)
	print("OPPONENT_LAYOUT %s (%d checks, %d live snapshots)" % ["PASS" if failures.is_empty() else "FAIL", checks, snapshots])
	quit(0 if failures.is_empty() else 1)

func _meeting_reservations() -> void:
	var leader := _idle_person("leader", 1)
	var meeting := _kind("meeting", 1)
	var home: Vector3 = board.enemy_board.rest_pos(board.by_uid[leader])
	state.move_cards([meeting], int(state.cards[leader].group))
	board.sync_state(state)
	_check(state.meetings.has(meeting), "fixture starts a real opponent-hosted meeting")
	var group: Dictionary = board.enemy_board.group_of(board.by_uid[meeting])
	var anchor: Vector3 = board.enemy_board.rest_origin(group)
	for iteration in 4: board.sync_state(state)
	_check(board.enemy_board.rest_origin(group).distance_to(anchor) < 0.001, "active meeting host remains stationary while nearby groups are arranged")
	_assert_layout("meeting ring reserves guest space")
	var mine := _kind("meeting", 0)
	var my_leader := _idle_person("leader", 0)
	state.move_cards([mine], int(state.cards[my_leader].group))
	board.sync_state(state)
	var snapshot: Dictionary = board._opponent_layout_snapshot()
	_check(snapshot.entries.all(func(entry): return entry.shape.size.y <= board.enemy_board.player_bounds.size.y + 0.001), "foreign meeting seats never stretch a BOT home group's footprint across both desks")
	state.advance(float(state.config.rules.meeting.duration_seconds))
	board.sync_state(state)
	board._advance_meeting_visitors(2.0)
	board.sync_state(state)
	_assert_layout("meeting personnel return home")

func _income_reservations() -> void:
	state.advance(4.0)
	var events := state.drain_events()
	board.sync_state(state)
	for event in events:
		if int(event.get("owner", -1)) == 1 and event.kind in ["slack_complete", "work_complete"]: board.play_event(event)
	board._advance_cash_flights(0.25)
	board._advance_deliveries(0.25)
	board.sync_state(state)
	_assert_layout("cash and coffee landing reservations")
	var before := _enemy_positions()
	board._advance_cash_flights(0.13)
	board._advance_deliveries(0.13)
	board.sync_state(state)
	_check(_enemy_positions() == before, "moving income arcs do not make settled group targets wander")

func _strike_reservations() -> void:
	# Test strike landing reservations on a desk with room for all footprints.
	# The earlier long-stack/meeting/income cases retain their own assertions;
	# accumulating all of them plus three loose strikers exceeds the default
	# spacing capacity of this shallow desk and tests a different packing limit.
	var previous_opening: Array = state.config.rules.initial.groups.duplicate(true)
	state.config.rules.initial.groups = [{"employee": 3, "work": 25, "overtime": 1},
		{"employee": 1, "work": 12}, {"leader": 1}, {"coffee": 2}]
	game._new_game()
	state.config.rules.initial.groups = previous_opening
	await _settle()
	var target := _working_group(1)
	if not _check(state.can_strike_group(target, 0), "fixture offers a working opponent strike target"): return
	var strike := state.add_card("strike", 0)
	state.activate(strike, target)
	state.advance(state.config.number("strike", "flight_seconds"))
	board.sync_state(state)
	board._advance_strike_dancers(1.0)
	_check(not board._strike_dancers.is_empty(), "fixture reserves real scattered personnel destinations")
	_assert_layout("striking personnel reserve their landing places")

func _working_group(owner: int) -> int:
	for gid in state.groups:
		if int(state.groups[gid].owner) == owner and state.group_work_rate(int(gid)) > 0.0: return int(gid)
	return -1

func _idle_person(kind: String, owner: int) -> int:
	for uid in state.cards:
		# A transfer host may have no current task while its combination still
		# owns the transfer function. The meeting fixture needs the loose host.
		if state.cards[uid].type == kind and int(state.cards[uid].owner) == owner and not state.tasks.has(uid) \
				and state.group_cards(int(state.cards[uid].group)).size() == 1 \
				and not state.is_meeting_target(int(uid)): return int(uid)
	return -1

func _kind(kind: String, owner: int) -> int:
	for uid in state.cards:
		if state.cards[uid].type == kind and int(state.cards[uid].owner) == owner: return int(uid)
	return -1

func _enemy_groups() -> Array:
	return state.groups.keys().filter(func(gid): return int(state.groups[gid].owner) == 1)

func _place(gid: int, at: Vector3) -> void:
	var card: OffWorkCard = board.by_uid[state.group_cards(gid)[0]]
	var group: Variant = board.enemy_board.group_of(card)
	board._origin_by_gid[gid] = at
	board.group_overrides[gid] = at
	if group != null: board.enemy_board._layout_group(group, at)
	else: board.enemy_board._move_to(card, at)

func _player_positions() -> Dictionary:
	var result: Dictionary = {}
	for uid in board.by_uid:
		if board.by_uid[uid].card_owner == 0: result[uid] = board.rest_pos(board.by_uid[uid])
	return result

func _enemy_positions() -> Dictionary:
	var result: Dictionary = {}
	for entry in board._opponent_layout_snapshot().entries: result[entry.id] = entry.at
	return result

func _rule_snapshot() -> String:
	return JSON.stringify({"cards": state.cards, "groups": state.groups, "tasks": state.tasks})

func _assert_layout(label: String) -> void:
	var snapshot: Dictionary = board._opponent_layout_snapshot()
	var rectangles: Array[Rect2] = snapshot.reserved.duplicate()
	var clear := true
	var inside := true
	for entry in snapshot.entries:
		var rectangle := Rect2(Vector2(entry.at.x, entry.at.z) + entry.shape.position, entry.shape.size)
		inside = inside and board.enemy_board.player_bounds.grow(0.002).encloses(rectangle)
		for other in rectangles:
			if rectangle.intersects(other) and rectangle.intersection(other).get_area() > 0.002: clear = false
		rectangles.append(rectangle)
	_check(clear, label + ": whole stack and side-label footprints do not overlap")
	_check(inside, label + ": entire combinations stay on the opponent desk")

func _settle() -> void:
	await create_timer(0.4).timeout
	await process_frame

func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition: failures.append(message)
	return condition
