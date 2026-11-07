extends SceneTree
## Production-state visual fixture: the meeting command controls every card
## and timer. Fixed time steps make its staged screenshots reproducible.
var game: Node
var board: OffWorkBoard
var state: OffWorkState
var failures: Array[String] = []
var checks := 0

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
	state = game.state
	state.config.rules.bot.enabled = false
	game.hud.set_process(false)
	game.hud._detail.hide()
	await _case("employee", 2)
	await _case("leader", 4)
	for message in failures: printerr("FAIL ", message)
	print("MEETING_ORBIT_REVIEW ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _case(host_kind: String, count: int) -> void:
	state.config.rules.initial.groups = [{"employee": 4, "work": 48}, {host_kind: 1}, {"meeting": 1}, {"coffee": 1}]
	seed(20261030 + count)
	game._new_game()
	game.state.drain_events()
	board.set_process(false)
	board.enemy_board.set_process(false)
	game.hud.lbl_round.text = "演出检查 · " + ("员工两人会议" if count == 2 else "领导四人会议")
	game.hud._sync_header_status()
	await create_timer(0.65).timeout
	await _advance(1.5)
	var host: int = _ids(host_kind, 0).back()
	var tool: int = _ids("meeting", 0)[0]
	var before := {}
	for uid in _ids("employee", 1) + _ids("leader", 1):
		before[uid] = {"node": board.by_uid[uid], "group": state.cards[uid].group,
			"owner": state.cards[uid].owner, "progress": state.cards[uid].progress}
	await _capture(host_kind, "before")
	_check(state.move_cards([tool], int(state.cards[host].group)) >= 0 and state.meetings.has(tool), host_kind + " real combination starts meeting")
	game._process(0.0)
	board.sync_state(state)
	var targets: Array = state.meetings[tool].targets.duplicate()
	_check(targets.size() == count, host_kind + " pulls expected number of actual targets")
	var initial_center_screen := board.screen_position(tool)
	await _capture(host_kind, "start")
	await _advance(0.25)
	var current_center_screen := board.screen_position(tool)
	_check(current_center_screen.distance_to(initial_center_screen) > 1.0, "original merge tween brings the visible meeting card onto its host stack")
	_check(game.effects.card_position(tool, Vector2.INF).distance_to(current_center_screen) < 0.001, "meeting light follows the current card instead of its old position")
	var attached_effect := false
	for effect in game.effects.items:
		if effect.kind == "meeting_start" and int(effect.get("source_id", -1)) == tool:
			attached_effect = true
			_check(effect.get("target_ids", []).size() == count, "meeting pull light follows the real target identities")
	_check(attached_effect, "pull effect is anchored to the meeting card UID")
	for uid in targets:
		_check(not board.by_uid[uid]._task_progress.visible, "pull hides personal bar " + str(uid))
	await _capture(host_kind, "pull")
	await _advance(1.75)
	_check_meeting(tool, host, targets, before)
	var first_positions := {}
	for uid in targets: first_positions[uid] = board.by_uid[uid].global_position
	await _capture(host_kind, "orbit-a")
	await _advance(1.2)
	_check_meeting(tool, host, targets, before)
	for uid in targets:
		_check(board.by_uid[uid].global_position.distance_to(first_positions[uid]) > 0.1, "visitor continuously circles instead of sitting " + str(uid))
	await _capture(host_kind, "orbit-b")
	var duration: float = state.config.number("meeting", "duration_seconds")
	await _advance(duration * 0.5 - 3.2)
	_check(is_equal_approx(board.by_uid[tool]._task_progress_value, 0.5), host_kind + " actual meeting card reads half progress")
	await _capture(host_kind, "half")
	await _advance(duration * 0.5)
	_check(not state.meetings.has(tool) and state.cards[tool].status == "recovering", host_kind + " real full timer dissolves meeting and cools tool")
	for uid in targets:
		_check(not board.by_uid[uid]._task_progress.visible, "returning people retain hidden bar " + str(uid))
	await _advance_visual(0.22)
	await _capture(host_kind, "return")
	await _advance_visual(1.0)
	board.sync_state(state)
	_check(board._meeting_visitors.is_empty(), host_kind + " all visitors return")
	for uid in targets:
		var card: OffWorkCard = board.by_uid[uid]
		_check(card == before[uid].node and int(state.cards[uid].group) == int(before[uid].group), "return keeps same UID and source group " + str(uid))
		_check(not state.tasks.has(uid) or state.tasks[uid].kind != "work" or is_equal_approx(float(state.cards[uid].progress), state.group_work_progress(int(state.cards[uid].group))), "returned worker rejoins shared combination progress " + str(uid))
		_check(not card.is_meeting_participant(), "return releases meeting presentation " + str(uid))
		if state.tasks.has(uid) and state.tasks[uid].kind == "work":
			var bars := 0
			for member in state.group_cards(int(state.cards[uid].group)):
				var view: OffWorkCard = board.by_uid[member]
				if view._task_progress.visible and view._task_progress_phase == "work": bars += 1
			_check(bars == 1, "returning workers share one combination bar " + str(uid))
	await _capture(host_kind, "returned")
	await _advance(float(state.cards[tool].remaining) - 1.0)
	_check(board.by_uid[tool].task_progress_display_value() < 0.1 and state.cards[tool].status == "recovering", "meeting cooldown drains toward empty")
	await _capture(host_kind, "cooldown")
	await _advance(1.0)
	_check(state.meetings.has(tool) and state.cards[tool].status == "active", "same combination automatically starts next meeting")
	for uid in state.meetings[tool].targets:
		_check(state.cards[uid].type != "leader", "automatic next meeting excludes leaders")
	await _advance_visual(1.0)
	await _capture(host_kind, "repeat")

func _check_meeting(tool: int, host: int, targets: Array, before: Dictionary) -> void:
	var center: OffWorkCard = board.by_uid[tool]
	_check(center.visible and center._task_progress.visible and center._task_progress_phase == "meeting", "central meeting card owns visible timer")
	_check(not board.by_uid[host]._task_progress.visible, "host has no duplicate meeting bar")
	for uid in targets:
		var card: OffWorkCard = board.by_uid[uid]
		_check(not card._task_progress.visible and card.is_meeting_participant(), "orbit hides personal bar " + str(uid))
		_check(card == before[uid].node and state.cards[uid].owner == before[uid].owner and state.cards[uid].group == before[uid].group, "orbit preserves original identity and ownership " + str(uid))
		_check(bool(state.cards[uid].paused) and not state.tasks.has(uid), "orbit removes participant from the working slots " + str(uid))
		_check(board.player_bounds.has_point(Vector2(card.global_position.x, card.global_position.z)), "orbit stays on host table " + str(uid))

func _advance(seconds: float) -> void:
	var remaining := seconds
	while remaining > 0.000001:
		var delta := minf(1.0 / 60.0, remaining)
		game._process(delta)
		board._advance_cash_flights(delta)
		board._advance_meeting_visitors(delta)
		remaining -= delta
		await process_frame
	# The normal HUD refresh is intentionally throttled. A labelled exact-time
	# capture flushes that pending presentation update rather than rounding its
	# rule time or editing the progress value.
	board.sync_state(state)
	game._update_hud()

func _advance_visual(seconds: float) -> void:
	var remaining := seconds
	while remaining > 0.000001:
		var delta := minf(1.0 / 60.0, remaining)
		board._advance_cash_flights(delta)
		board._advance_meeting_visitors(delta)
		remaining -= delta
		await process_frame

func _ids(kind: String, owner: int) -> Array:
	return state.cards.keys().filter(func(uid): return state.cards[uid].type == kind and int(state.cards[uid].owner) == owner)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _capture(kind: String, label: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png("res://reports/meeting-orbit-%s-%s.png" % [kind, label])
	_check(result == OK, "capture " + kind + " " + label)
	print("MEETING_ORBIT_CAPTURE ", kind, " ", label, " result=", result)
