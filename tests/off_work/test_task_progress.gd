extends SceneTree

var checks := 0
var failures: Array[String] = []
var stage: Node3D
var state: OffWorkState
var worker: OffWorkCard
var employee := -1
var group := -1

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "work": 6}]
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(117)
	OffWorkCardDB.configure(config)
	stage = Node3D.new()
	root.add_child(stage)
	for id in state.cards:
		if state.cards[id].type == "employee" and state.cards[id].owner == 0:
			employee = id
			group = state.cards[id].group
	worker = _view(employee)
	worker.set_process(false)
	_check(not worker._task_progress.visible, "ordinary personnel do not create a separate work bar")
	_refresh()
	_check(worker._task_progress.visible and worker._task_progress_value == 0.0, "valid group shows empty track from its first frame")
	_check(worker.task_progress_display_value() == 0.0, "empty track has no residual fill")
	var surfaces := worker._task_progress.get_children().filter(func(node): return node is MeshInstance3D)
	_check(surfaces.size() == 1 and surfaces[0] == worker._task_progress_frame and worker._task_progress_material.shader.resource_path.ends_with("off_work_task_progress.gdshader"), "one opaque surface renders frame, track and fill without coplanar overlap")
	_check(worker._debug_timer.position.y > worker._task_progress_frame.position.y and not worker._debug_timer.visible, "optional Debug text sits above the progress surface and defaults hidden")
	state.advance(2.5)
	_refresh()
	_check(is_equal_approx(worker.task_progress_display_value(), 0.25), "work bar shader receives current quarter-finished document")
	var left := _left_edge(worker)
	state.advance(2.5)
	_refresh()
	_check(is_equal_approx(worker._task_progress_value, 0.5), "half of ten-second task fills half width")
	_check(is_equal_approx(_left_edge(worker), left), "bar fills from fixed left edge rather than its centre")
	var overtime: int = state.add_card("overtime", 0)
	state.move_cards([overtime], group)
	_refresh()
	_check(is_equal_approx(worker._task_progress_value, 0.5), "adding speed tool does not jump already completed work")
	state.advance(1.0)
	_refresh()
	_check(is_equal_approx(worker._task_progress_value, 0.62), "bar follows modified work speed")
	state.move_cards([overtime], -1)
	state.advance(3.79)
	_refresh()
	_check(worker._task_progress_value > 0.998 and worker._task_progress_value < 1.0, "first work nearly fills before actual completion")
	state.drain_events()
	state.advance(0.01)
	_refresh()
	_check(worker._task_progress_value < 0.00001, "new document resets real task progress after completion")
	var completed := false
	for event in state.drain_events():
		if event.kind == "work_complete" and event.source == employee:
			worker.play_event(event.kind)
			completed = true
	_check(completed and worker.task_progress_display_value() == 1.0, "actual completion event flashes a full bar")
	state.advance(0.25)
	_refresh()
	worker._process(OffWorkUI.number("task_progress", "completion_hold_seconds") + 0.01)
	_check(is_equal_approx(worker.task_progress_display_value(), 0.025), "short completion feedback returns to new document's live value")
	_check(state.money(0) == int(config.rules.initial.money) + int(config.cards.work.income), "bar feedback creates no extra completion or income")
	var strike := state.add_card("strike", 1)
	_check(state.activate(strike, group), "real strike is accepted")
	_check(state.pending_strikes.has(strike) and state.cards.has(strike), "attack is visible during its reaction window")
	var flight: float = config.number("strike", "flight_seconds")
	state.advance(flight)
	var retained: float = 0.025 + flight / config.work_seconds()
	_refresh()
	_check(not worker._task_progress.visible and not state.cards.has(strike), "strike hides the ejected person's bar and consumes its card")
	state.advance(config.number("strike", "duration_seconds"))
	state.move_cards([employee], group)
	_refresh()
	_check(is_equal_approx(worker.task_progress_display_value(), retained), "regrouping restores progress earned through strike arrival")
	state.advance(1.0)
	var foe := -1
	for id in state.cards:
		if state.cards[id].type == "employee" and state.cards[id].owner == 1: foe = id
	state.move_cards([foe], -1)
	var meeting := state.add_card("meeting", 1, state.cards[foe].group)
	_check(state.activate(meeting), "real meeting pauses opponent worker")
	_refresh()
	var stopped := worker._task_progress_value
	_check(not worker._task_progress.visible and worker._task_progress_paused, "meeting hides personnel bar while retaining the paused task")
	state.advance(1.0)
	_refresh()
	_check(is_equal_approx(worker._task_progress_value, stopped), "paused worker bar does not move")
	var host_view := _view(foe)
	_check(not host_view._task_progress.visible and is_equal_approx(host_view._task_progress_value, 1.0 / config.number("meeting", "duration_seconds")), "host hides duplicate progress while retaining actual meeting time")
	var meeting_view := _view(meeting)
	_check(meeting_view._task_progress.visible and is_equal_approx(meeting_view._task_progress_value, 1.0 / config.number("meeting", "duration_seconds")), "meeting card alone displays the real meeting timer")
	var coffee := state.add_card("coffee", 0)
	_check(state.move_cards([coffee], group, employee) == group and state.cards[coffee].status == "ready",
		"adding coffee to personnel and work preserves the paused work task")
	state.advance(0.5)
	_refresh()
	_check(worker.type == "employee" and state.cards[coffee].status == "ready" and is_equal_approx(worker._task_progress_value, stopped),
		"mixed work group displays retained work progress and cannot start coffee")
	state.move_cards([foe], -1)
	var coffee_group := state.move_cards([employee], -1)
	state.move_cards([coffee], coffee_group, employee)
	var next_meeting := state.add_card("meeting", 1, state.cards[foe].group)
	_check(state.activate(next_meeting), "a fresh meeting can pause the employee in a separate coffee group")
	_refresh()
	_check(worker.type == "employee" and worker._task_progress_paused and is_zero_approx(worker._task_progress_value), "absent employee has no residual upgrade fill")
	var coffee_view := _view(coffee)
	_check(not coffee_view._task_progress.visible and not coffee_view._task_progress_paused and is_zero_approx(coffee_view._task_progress_value), "unattended coffee hides its cancelled timer and clears the fill")
	state.advance(0.5)
	_refresh()
	_check(is_zero_approx(worker._task_progress_value) and state.cards.has(coffee), "meeting cannot advance upgrade or consume its ingredient")
	state.move_cards([foe], -1)
	state.advance(config.number("coffee", "seconds"))
	_refresh()
	_check(worker.type == "grinder" and not state.cards.has(coffee) and not state.tasks.has(employee),
		"full coffee timer consumes the ingredient and leaves improved personnel ready for reassignment")
	state.move_cards([employee], group)
	_refresh()
	_check(is_equal_approx(worker._task_progress_value, stopped), "returning to the work pile restores its preserved progress")
	state.advance(0.5)
	_refresh()
	_check(not worker._task_progress_paused and worker._task_progress_value > stopped, "host departure resumes upgraded person's retained task")
	var retained_progress := worker.task_progress_display_value()
	worker.set_meeting_participant(true)
	_check(not worker._task_progress.visible and is_equal_approx(worker.task_progress_display_value(), retained_progress), "return flight can keep the real resumed task hidden without clearing it")
	worker.flash_task_completion()
	_check(not worker._task_progress.visible and is_zero_approx(worker._task_completion_hold), "meeting personnel never leak a completion flash")
	worker.set_meeting_participant(false)
	_check(worker._task_progress.visible and is_equal_approx(worker.task_progress_display_value(), retained_progress), "landing restores the same current task bar")
	state.move_cards([employee], -1)
	_refresh()
	_check(not worker._task_progress.visible, "removing person from valid combination hides task bar")
	var transfer := state.add_card("transfer", 0, group)
	state.move_cards([employee], group)
	state.advance(1.0)
	_refresh()
	_check(state.cards[employee].activity == "transfer" and not worker._task_progress.visible and worker._task_progress_value > 0.0, "transfer participant retains shared progress without an independent bar")
	var slack_group := state.move_cards([employee], -1)
	var slack := state.add_card("slack", 0, slack_group)
	_check(state.activate(slack), "real coffee-production task starts")
	state.advance(1.0)
	_refresh()
	_check(state.cards[employee].activity == "slack" and not worker._task_progress.visible and is_equal_approx(worker._task_progress_value, state.group_slack_progress(slack_group)), "slack participant carries shared progress without a private bar")
	var tool_view := _view(slack)
	_check(not tool_view._task_progress.visible, "tool timers do not masquerade as standalone worker tasks")
	var leader := state.add_card("leader", 0)
	var leader_group: int = state.cards[leader].group
	state.add_card("work", 0, leader_group)
	var leader_view := _view(leader)
	_check(not leader_view._task_progress.visible and not leader_view.illustration_is_active(), "leader with work has no ordinary task bar or work animation")
	state._spend(0, state.money(0))
	var leader_slack := state.add_card("slack", 0, leader_group)
	_check(state.money(0) == 0 and state.activate(leader_slack), "leader starts coffee production with zero money")
	state.advance(1.0)
	leader_view.update_record(state.cards[leader])
	leader_view._process(0.1)
	_check(not leader_view._task_progress.visible and is_equal_approx(leader_view._task_progress_value, state.group_slack_progress(leader_group)), "leader projects the shared slack cycle without an independent bar")
	_check(leader_view.illustration_is_active() and leader_view._icon.visible and leader_view._realtime.find_children("*", "Sprite3D", true, false).is_empty(), "leader coffee task plays its complete illustration without rig overlays")
	var offer := OffWorkCard.new()
	stage.add_child(offer)
	offer.configure(state.cards[employee], config.cards[state.cards[employee].type], true)
	offer.freeze = true
	_check(not offer._task_progress.visible, "conveyor cards never display task progress")
	worker.leave()
	_check(not worker._task_progress.visible, "leaving the table hides completed task UI")
	stage.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("TASK_PROGRESS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _view(uid: int) -> OffWorkCard:
	var card := OffWorkCard.new()
	stage.add_child(card)
	card.configure(state.cards[uid], state.config.cards[state.cards[uid].type])
	card.freeze = true
	return card

func _refresh() -> void:
	worker.update_record(state.cards[employee])
	# Exercise the shared-bar renderer on this selected representative. The real
	# Board's single-representative choice is covered by group/integration tests.
	var gid: int = state.cards[employee].group
	if state.group_work(gid).is_empty() or state.cards[employee].activity in ["coffee", "meeting", "transfer", "slack"]: return
	worker.set_task_progress(state.group_work_progress(gid), true, state.group_work_participants(gid).is_empty(), "work")

func _left_edge(card: OffWorkCard) -> float:
	var border: Vector2 = card._task_progress_material.get_shader_parameter("border_uv")
	return card._task_progress_frame.mesh.size.x * (-0.5 + border.x)

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
