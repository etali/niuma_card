extends SceneTree

var checks := 0
var errors: Array[String] = []
var state: WorkState
var board: WorkBoard

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := WorkConfig.new()
	# Tool before personnel deliberately exercises the original core-first order.
	config.rules.initial.groups = [{"transfer": 1, "employee": 1, "work": 4}]
	config.rules.bot.enabled = false
	state = WorkState.new(config)
	state.new_game(237)
	WorkCardDB.configure(config)
	var host := Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = WorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	board.sync_state(state)
	await create_timer(0.3).timeout
	var person: int = state.group_people(1)[0]
	var group: Dictionary = board.group_of(board.by_uid[person])
	var original_order: Array = group.cards.map(func(card): return card.uid)
	var top: WorkCard = group.cards[board._top_index(group)]
	_check(group.compact and top.type == "transfer", "tool-first compact stack retains original top")
	_check(top._task_progress.visible and is_zero_approx(top._task_progress_value), "valid zero-progress task exposes its empty track")
	state.advance(2.5)
	board.sync_state(state)
	_check(is_equal_approx(top._task_progress_value, 0.25), "top tool projects actual quarter-complete work")
	_check(group.cards.map(func(card): return card.uid) == original_order, "progress projection never reorders stack")
	for presenter in [board, board.enemy_board]:
		var other_group: Dictionary = presenter.groups[0]
		var other_top: WorkCard = other_group.cards[presenter._top_index(other_group)]
		_check(other_top._task_progress.visible and is_equal_approx(other_top._task_progress_value, 0.25), "both sides expose real progress")
	board.toggle_compact(top)
	board.sync_state(state)
	group = board.group_of(board.by_uid[person])
	top = group.cards[board._top_index(group)]
	_check(not group.compact and top.type == "work", "expanded stack preserves original document on top")
	_check(top._task_progress.visible and is_equal_approx(top._task_progress_value, 0.25), "expanded stack projects progress onto visible document")
	_check(is_equal_approx(board.by_uid[person]._task_progress_value, 0.25) and not board.by_uid[person]._task_progress.visible, "person retains shared value without a duplicate work bar")
	state.drain_events()
	state.advance(7.5)
	var completed: Array = state.drain_events().filter(func(event): return event.kind == "work_complete")
	board.sync_state(state)
	group = board.group_of(board.by_uid[person])
	top = group.cards[board._top_index(group)]
	_check(is_zero_approx(top._task_progress_value), "next real work begins at zero")
	for event in completed: board.play_event(event)
	_check(top._task_progress.visible and is_equal_approx(top.task_progress_display_value(), 1.0), "actual completion briefly fills visible track")
	_check(state.work_count(0) == 3 and state.money(0) == 9, "completion feedback does not double-settle work or income")
	top._process(WorkUI.number("task_progress", "completion_hold_seconds") + 0.01)
	_check(is_zero_approx(top.task_progress_display_value()), "completion hold returns to the new task's empty track")
	state.advance(2.0)
	board.sync_state(state)
	_check(is_equal_approx(top._task_progress_value, 0.2), "second work advances from its own start")
	# A real opponent meeting pauses this worker and the projected track.
	var meeting := state.add_card("meeting", 1)
	var host_person := -1
	for id in state.cards:
		if int(state.cards[id].owner) == 1 and state.cards[id].type == "employee": host_person = int(id)
	state.move_cards([meeting], int(state.cards[host_person].group))
	_check(state.meetings.has(meeting), "moving meeting into host group starts a real meeting")
	board.sync_state(state)
	var visitor: WorkCard = board.by_uid[person]
	_check(visitor._task_progress_paused and not visitor._task_progress.visible, "pulled meeting participant hides the retained paused task progress")
	state.advance(1.0)
	board.sync_state(state)
	_check(is_equal_approx(state.group_work_progress(1), 0.2), "meeting freezes a work combination with no remaining available worker")
	# Remove work through the same legal grouping operation used by dragging.
	state.move_cards(state.group_work(1), -1)
	board.sync_state(state)
	await create_timer(WorkUI.number("task_progress", "completion_hold_seconds") + 0.05).timeout
	# Meeting guests are physically detached from their original Board, while
	# the authoritative owner/group stay unchanged. Check those real members.
	for uid in state.group_cards(int(state.cards[person].group)):
		_check(not board.by_uid[uid]._task_progress.visible, "invalid work combination has no fake task track")
	for offer in board.offers_by_id.values():
		_check(not offer._task_progress.visible, "shop cards have no task track")
	var leader := state.add_card("leader", 0)
	var leader_group: int = state.cards[leader].group
	for _index in 4: state.add_card("work", 0, leader_group)
	board.sync_state(state)
	var leadership: Dictionary = board.group_of(board.by_uid[leader])
	var leader_top: WorkCard = leadership.cards[board._top_index(leadership)]
	_check(leader_top.uid == leader and not leader_top._task_progress.visible, "leader with work keeps original compact ordering without inventing a task")
	var colleague := state.add_card("employee", 0, leader_group)
	state.advance(2.5)
	board.sync_state(state)
	_check(not state.tasks.has(leader) and state.tasks.has(colleague), "mixed group allocates ordinary work only to its employee")
	_check(leader_top._task_progress.visible and is_equal_approx(leader_top._task_progress_value, 0.25) and not leader_top.illustration_is_active(), "leader covering a worker projects the group's real progress without claiming it is doing ordinary work")
	state.move_cards([colleague], -1)
	board.sync_state(state)
	_check(not leader_top._task_progress.visible, "removing the only worker clears the leadership stack's projected task")
	var transfer := state.add_card("transfer", 0, leader_group)
	_check(state.activate(transfer, leader_group), "leader can start a real transfer task")
	state.advance(1.0)
	board.sync_state(state)
	board.toggle_compact(leader_top)
	board.sync_state(state)
	leadership = board.group_of(board.by_uid[leader])
	leader_top = leadership.cards[board._top_index(leadership)]
	_check(not leadership.compact and leader_top.type == "work" and leader_top._task_progress.visible, "expanded leadership group exposes transfer progress on its visible work card")
	_check(is_equal_approx(leader_top._task_progress_value, float(state.cards[leader].progress)) and leader_top._task_progress_value > 0.0, "projected leadership transfer exactly matches its real task progress")
	host.queue_free()
	await process_frame
	for error in errors: printerr("FAIL ", error)
	print("GROUP_PROGRESS ", "PASS" if errors.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if errors.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)
