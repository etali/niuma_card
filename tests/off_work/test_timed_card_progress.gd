extends SceneTree

## Real rule timers, production WorkCards, and the original Board stack order.
var checks := 0
var failures: Array[String] = []
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _owned(type: String, owner := 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == type and int(state.cards[id].owner) == owner)

func _refresh() -> void: board.sync_state(state)

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 2, "work": 30}, {"coffee": 1}, {"meeting": 1, "leader": 1, "employee": 1, "work": 12}]
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(213)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	_refresh()
	var coffee: int = _owned("coffee")[0]
	var employee: int = _owned("employee")[0]
	var worker: OffWorkCard = board.by_uid[employee]
	var cup: OffWorkCard = board.by_uid[coffee]
	state.advance(2.0)
	_refresh()
	var work_id: int = state.tasks[employee].work_id
	var production_group: int = state.cards[employee].group
	_check(cup.has_dedicated_progress() and not cup._task_progress.visible, "ready coffee does not borrow a nearby work timer")
	var instance: int = worker.get_instance_id()
	var break_group := state.move_cards([employee])
	_check(state.move_cards([coffee], break_group, employee) == break_group, "combining ready coffee with the separate employee starts the real queue timer")
	_refresh()
	_check(worker.type == "employee" and state.cards.has(coffee), "reading does not change role or consume coffee early")
	_check(cup._task_progress.visible and is_zero_approx(cup._task_progress_value), "coffee owns an empty bar from the first timer frame")
	_check(worker._task_progress_phase == "coffee" and worker._task_progress.visible and not worker.illustration_is_active(), "drinking employee shows upgrade progress without typing")
	state.advance(config.number("coffee", "seconds") * 0.5)
	_refresh()
	_check(is_equal_approx(cup._task_progress_value, 0.5) and is_equal_approx(worker._task_progress_value, 0.5), "both real upgrade participants display the same half-full bar")
	_check(cup._task_progress_material.get_shader_parameter("fill_color") == Palette.semantic("cash"), "upgrade uses configured gold progress ink")
	_check(is_equal_approx(float(state.cards[work_id].progress), 0.45) and is_equal_approx(state.group_work_progress(production_group), 0.45), "working colleague advances the shared group clock while employee drinks")
	var group: Dictionary = board.group_of(cup)
	_check(group.cards[board._top_index(group)] == worker and worker._task_progress_phase == "coffee", "compact stack shows the upgrading employee's true timer")
	cup.flash_task_completion()
	_check(is_equal_approx(cup.task_progress_display_value(), 0.5), "an unrelated work completion cannot flash the coffee bar full")
	board.toggle_compact(cup)
	_refresh()
	group = board.group_of(cup)
	_check(group.cards[board._top_index(group)] == cup and is_equal_approx(cup._task_progress_value, 0.5) and cup._task_progress_phase == "coffee", "expanded top coffee keeps its own timer instead of the colleague's work")
	state.advance(config.number("coffee", "seconds") * 0.5)
	_refresh()
	_check(not state.cards.has(coffee) and worker.type == "grinder" and worker.get_instance_id() == instance, "only timer completion consumes coffee and upgrades the same card")
	state.move_cards([employee], production_group)
	_refresh()
	_check(is_equal_approx(worker._task_progress_value, state.group_work_progress(production_group)) and is_equal_approx(worker._task_progress_value, 0.7) and worker._task_progress_phase == "work", "completed upgrade rejoins the current shared work progress")
	for event in state.drain_events(): board.play_event(event)
	_check(worker.stamp_text() == OffWorkCardDB.card_name("grinder"), "actual upgrade completion triggers the original upgrade stamp")
	var meeting: int = _owned("meeting")[0]
	var card: OffWorkCard = board.by_uid[meeting]
	var meeting_group: int = state.cards[meeting].group
	_check(card.has_dedicated_progress() and not card._task_progress.visible, "ready meeting owns no fake work-progress bar")
	_check(state.activate(meeting, meeting_group), "real meeting starts")
	_refresh()
	_check(card._task_progress.visible and card._task_progress_phase == "meeting" and is_zero_approx(card._task_progress_value), "meeting card starts its own empty session bar")
	var duration := config.number("meeting", "duration_seconds")
	state.advance(duration * 0.5)
	_refresh()
	_check(is_equal_approx(card._task_progress_value, 0.5), "meeting card reads actual remaining session time")
	_check(card._task_progress_material.get_shader_parameter("fill_color") == Palette.semantic("success"), "active meeting has configured green ink")
	card.flash_task_completion()
	_check(is_equal_approx(card.task_progress_display_value(), 0.5), "colleague work completion never overwrites meeting progress")
	state.advance(duration * 0.5)
	_refresh()
	_check(not state.meetings.has(meeting) and state.cards[meeting].status == "recovering", "session ends exactly at its full timer")
	_check(card._task_progress.visible and is_zero_approx(card._task_progress_value) and card._task_progress_phase == "recovering", "meeting immediately starts a separate cooldown timer at zero elapsed")
	_check(card._task_progress_material.get_shader_parameter("fill_color") == Palette.semantic("info") and not card.illustration_is_active(), "cooldown is blue and does not show an ongoing meeting")
	_check(not state.activate(meeting, meeting_group), "cooldown cannot be restarted as another meeting")
	var cooldown := config.number("meeting", "recovery_seconds")
	state.advance(cooldown * 0.5)
	_refresh()
	_check(is_equal_approx(card._task_progress_value, 0.5), "meeting cooldown reads actual half-complete recovery")
	board.toggle_compact(card)
	_refresh()
	_check(card._task_progress_phase == "recovering" and is_equal_approx(card._task_progress_value, 0.5), "expanding a working group cannot overwrite the meeting cooldown")
	state.advance(cooldown * 0.5)
	_refresh()
	_check(state.cards[meeting].status == "active" and card._task_progress.visible and state.meetings.has(meeting), "finished cooldown automatically begins the next real meeting")
	_check(not state.activate(meeting, meeting_group), "automatically started meeting cannot start twice")
	_refresh()
	_check(card._task_progress_phase == "meeting" and is_zero_approx(card._task_progress_value), "new meeting begins at zero again")
	host.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("TIMED_CARD_PROGRESS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
