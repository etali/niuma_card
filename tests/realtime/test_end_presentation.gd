extends SceneTree
## Complete production-scene endings, including a winner pulled into a meeting.
## Optional WORK_END_CAPTURE=1 writes the same real rendered states for review.
var game: Node
var board: WorkBoard
var state: WorkState
var checks := 0
var failures: Array[String] = []
var capture := false

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	capture = OS.get_environment("WORK_END_CAPTURE") == "1"
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1600, 900)
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.hud.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	board = game.board
	state = game.state
	state.config.rules.bot.enabled = false
	await _normal_ending(0)
	await _normal_ending(1)
	await _normal_ending(2)
	for compact in [true, false]:
		for winner in [0, 1, 2]: await _stacked_ending(winner, compact)
	await _stacked_ending(0, true, true)
	await _transfer_ending()
	await _meeting_ending()
	for winner in [0, 1, 2]: await _large_residual_ending(winner)
	_cooldown_display()
	game.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("END_PRESENTATION ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _reset() -> void:
	state.config.rules.initial.groups = [{"employee": 1}, {"grinder": 1}, {"leader": 1}, {"work": 1}]
	game._new_game()
	board.set_process(false)
	board.enemy_board.set_process(false)
	state.drain_events()
	game.hud._detail.hide()

func _normal_ending(winner: int) -> void:
	_reset()
	for owner in [0, 1]:
		if winner == 2 or winner == owner:
			var worker := _id("employee", owner)
			state.move_cards([worker], int(state.cards[_id("work", owner)].group))
	board.sync_state(state)
	state.drain_events()
	await create_timer(0.25).timeout
	if winner == 0: await _capture("before")
	state.advance(float(state.config.roles.employee.work_seconds))
	game._process(0.0)
	_check(state.winner == winner, "real work completion yields expected winner " + str(winner))
	await _verify_departure(winner, "player" if winner == 0 else ("opponent" if winner == 1 else "tie"))

func _meeting_ending() -> void:
	_reset()
	state.config.rules.meeting.duration_seconds = 20.0
	var host := _id("leader", 1)
	var tool := state.add_card("meeting", 1, int(state.cards[host].group))
	_check(state.activate(tool), "opponent really starts a meeting")
	game._process(0.0)
	board._advance_meeting_visitors(2.0)
	_check(board._meeting_visitors.size() == 2, "both eligible winning roles are physically visiting the other table")
	var work_group: int = state.cards[_id("work", 0)].group
	state.move_cards([_id("money", 0)], work_group)
	var outsource := state.add_card("outsource", 0, work_group)
	_check(state.activate(outsource), "outsource really starts with local cash while staff attend meeting")
	_check(state.winner == -1 and state.meetings.has(tool), "the meeting continues while outsourcing reads its timer")
	var visits := {}
	for uid in board._meeting_visitors:
		visits[uid] = [board.by_uid[uid].global_transform, board.by_uid[uid]._visual.transform]
	state.advance(state.config.number("outsource", "seconds"))
	game._process(0.0)
	_check(state.winner == 0, "outsourcing completion during meeting yields a real win")
	_check(board._meeting_visitors.is_empty(), "winning visitors hand off motion before departing")
	for uid in visits:
		_check(board.by_uid[uid].global_transform.is_equal_approx(visits[uid][0]) and board.by_uid[uid]._visual.transform.is_equal_approx(visits[uid][1]), "meeting visitor retains its full current pose when the win begins")
	await _verify_departure(0, "meeting")

func _transfer_ending() -> void:
	_reset()
	var host := _id("leader", 0)
	var group: int = state.cards[_id("work", 0)].group
	state.move_cards([host], group)
	var transfer := state.add_card("transfer", 0, group)
	_check(state.activate(transfer), "leader starts the final transfer batch")
	board.sync_state(state)
	state.drain_events()
	await create_timer(0.25).timeout
	var pose: Transform3D = board.by_uid[host].global_transform
	state.advance(state.config.number("transfer", "seconds"))
	game._process(0.0)
	_check(state.winner == 0, "transferring the last work wins without consuming its UID")
	_check(board.by_uid[host].global_transform.is_equal_approx(pose), "final transfer changes work ownership without closing the winning personnel stack")
	await _verify_departure(0, "transfer")

func _stacked_ending(winner: int, compact: bool, moving := false) -> void:
	state.config.rules.initial.groups = [{"employee": 1, "grinder": 1, "leader": 1, "work": 1, "overtime": 2}]
	game._new_game()
	board.set_process(false)
	board.enemy_board.set_process(false)
	for owner in [0, 1]:
		if winner != 2 and owner != winner:
			state.move_cards(state.group_people(state.cards[_id("work", owner)].group), -1)
	board.sync_state(state)
	state.drain_events()
	var static_cards: Array[WorkCard] = []
	var departing: Array[WorkCard] = []
	for owner in [0, 1]:
		if winner != 2 and owner != winner: continue
		var presenter := board._presenter(owner)
		var group: Dictionary = presenter.group_of(board.by_uid[_id("employee", owner)])
		# Cover both a tool above personnel and the consumed last work buried
		# between staff, without changing authoritative composition or tasks.
		var tools: Array = group.cards.filter(func(card): return card.type == "overtime")
		var people: Array = group.cards.filter(func(card): return card._is_person())
		var work: WorkCard = board.by_uid[_id("work", owner)]
		group.cards = [tools[0], people[0], work, people[1], people[2], tools[1]]
		group.compact = compact
		presenter._layout_group(group)
		for card: WorkCard in people: departing.append(card)
		for card: WorkCard in tools: static_cards.append(card)
	await create_timer(0.25).timeout
	if moving:
		for owner in [0, 1]:
			if winner != 2 and owner != winner: continue
			var presenter := board._presenter(owner)
			var group: Dictionary = presenter.group_of(board.by_uid[_id("employee", owner)])
			group.compact = not compact
			presenter._layout_group(group)
		await create_timer(0.04).timeout
	var poses := {}
	for card: WorkCard in board.by_uid.values():
		poses[card.uid] = [card.global_transform, card._visual.transform]
	state.advance(10.0)
	game._process(0.0)
	_check(state.winner == winner, "packed end has expected winner %d, compact=%s moving=%s" % [winner, compact, moving])
	for card: WorkCard in board.by_uid.values():
		if not poses.has(card.uid): continue # final income is genuinely new
		_check(card.global_transform.is_equal_approx(poses[card.uid][0]) and card._visual.transform.is_equal_approx(poses[card.uid][1]), "terminal removal and pointer cancellation preserve the complete starting pose")
	for card in departing:
		_check(not card._void_stamp.visible and not (card._void_stamp.material_override as ShaderMaterial).shader.code.contains("depth_test_disabled,"), "buried departure stamps wait for extraction and respect other card faces")
	for card: WorkCard in board._retired_cards.values():
		_check(not card.visible, "consumed final work cannot rise through personnel")
	for card in departing: card._leave_tween.pause()
	if compact and winner == 0 and not moving: await _capture("packed-compact-start")
	var ascent := WorkUI.number("animation", "leave_anticipation") + WorkUI.number("animation", "leave_clearance_duration")
	var total := ascent + WorkUI.number("animation", "leave_duration")
	_check(total < float(game.settings.result.delay), "whole-card extraction completes before the result panel")
	var starts := {}
	for card in departing: starts[card.uid] = card._visual.global_position.y
	var sampled := 0.0
	for sample in 40:
		var step := total / 40.0
		for card in departing: card._leave_tween.custom_step(step)
		sampled += step
		board._advance_meeting_visitors(step)
		board._advance_strike_dancers(step)
		board._advance_cash_flights(step)
		for card in departing:
			_check(card.global_transform.is_equal_approx(poses[card.uid][0]), "no native stack reflow moves the departure parent")
			if sampled <= ascent:
				_check(is_equal_approx(card._visual.global_position.y, starts[card.uid]), "buried personnel are pulled sideways without crossing upper layers")
			elif card.visible and not moving:
				for stationary in static_cards:
					if stationary.group_id == card.group_id:
						_check(not _face_rect(card).intersects(_face_rect(stationary)), "personnel clear the stationary tool footprint before lifting")
			for stationary in static_cards:
				_check(stationary.global_transform.is_equal_approx(poses[stationary.uid][0]) and stationary._visual.transform.is_equal_approx(poses[stationary.uid][1]), "remaining tool stays fixed throughout exit")
		if compact and winner == 0 and not moving and sample in [12, 23]: await _capture("packed-compact-frame-%d" % sample)
	for card in departing:
		card._leave_tween.custom_step(0.01)
		_check(not card.visible, "packed personnel exit completely with no empty frames")
	board.sync_state(state)
	for stationary in static_cards:
		_check(stationary.global_transform.is_equal_approx(poses[stationary.uid][0]), "later terminal sync cannot close stack gaps behind departing staff")
	game._new_game()
	await process_frame

func _face_rect(card: WorkCard) -> Rect2:
	var rectangle := Rect2(Vector2(card._visual.global_position.x, card._visual.global_position.z), Vector2.ZERO)
	for x in [-0.5, 0.5]:
		for z in [-0.5, 0.5]:
			var point := card._visual.to_global(Vector3(CardEntity.CARD_SIZE.x * x, 0.0, CardEntity.CARD_SIZE.z * z))
			rectangle = rectangle.expand(Vector2(point.x, point.z))
	return rectangle

func _large_residual_ending(winner: int) -> void:
	# Reproduce a winner with many personnel above hidden overtime cards, plus
	# a separate coffee bank. Personnel leave visually but remain in the state.
	state.config.rules.initial.groups = [{"employee": 8, "grinder": 7, "workaholic": 2, "overtime": 3, "work": 1}, {"coffee": 2}]
	game._new_game()
	board.set_process(false)
	board.enemy_board.set_process(false)
	for owner in [0, 1]:
		if winner != 2 and owner != winner:
			var gid: int = state.cards[_id("work", owner)].group
			state.move_cards(state.group_people(gid), -1)
	board.sync_state(state)
	state.drain_events()
	await create_timer(0.25).timeout
	var old_sides: Array = []
	for presenter in [board, board.enemy_board]:
		for group in presenter.groups: old_sides.append_array(group.get("side", []))
	_check(not old_sides.is_empty(), "large ending fixture has real side icons and counts before the win")
	var tools: Array[WorkCard] = []
	var poses: Dictionary = {}
	for card: WorkCard in board.by_uid.values():
		if card.type == "overtime" and (winner == 2 or card.card_owner == winner):
			tools.append(card)
			poses[card.uid] = [card.global_transform, card._visual.transform]
	_check(tools.any(func(card): return not card._visual.visible), "large winning stack starts with hidden overflow tools")
	state.advance(10.0)
	game._process(0.0)
	_check(state.winner == winner, "large personnel fixture reaches the intended win")
	for node in old_sides:
		_check(not is_instance_valid(node) or not node.is_visible_in_tree(), "terminal transition hides side nodes immediately, before deferred freeing")
	var departures: Array = board.by_uid.values().filter(func(card): return card._retired)
	var duration := WorkUI.number("animation", "leave_anticipation") + WorkUI.number("animation", "leave_clearance_duration") + WorkUI.number("animation", "leave_duration")
	for card in departures:
		card._leave_tween.pause()
		card._leave_tween.custom_step(duration + state.config.number("simulation", "epsilon"))
	for owner in [0, 1]:
		if winner == 2 or owner == winner:
			_check(tools.any(func(card): return card.card_owner == owner and card._visual.is_visible_in_tree()), "stationary overtime becomes visible after the personnel leave")
	for card in tools:
		_check(card.global_transform.is_equal_approx(poses[card.uid][0]) and card._visual.transform.is_equal_approx(poses[card.uid][1]), "restoring a buried tool never moves or reflows its card")
	board.resync_sides()
	board.enemy_board.resync_sides()
	board._advance_cash_flights(5.0)
	board.sync_state(state)
	for presenter in [board, board.enemy_board]:
		for group in presenter.groups:
			_check(group.get("side", []).is_empty(), "late layout and income callbacks cannot recreate a terminal side list")
	_check(departures.all(func(card): return not card.visible and state.cards.has(card.uid)), "no departure card returns and authoritative personnel remain intact")
	if winner == 0: await _capture("large-finished")
	game._new_game()
	board.resync_sides()
	board.enemy_board.resync_sides()
	_check(board.groups.any(func(group): return not group.get("side", []).is_empty()) and board.enemy_board.groups.any(func(group): return not group.get("side", []).is_empty()), "a new match restores both sides' ordinary quantity lists")
	await process_frame

func _verify_departure(winner: int, label: String) -> void:
	var departing: Array[WorkCard] = []
	var portraits := {}
	var poses := {}
	for card: WorkCard in board.by_uid.values():
		if card._is_person() and (winner == 2 or card.card_owner == winner):
			departing.append(card)
			portraits[card.uid] = card._icon.transform
			poses[card.uid] = card._visual.transform
			_check(card._retired and card._visual_retired and card.visible, "whole card begins a visible departure " + str(card.uid))
			_check(card.stamp_text() == WorkUI.section("animation").leave_stamp and not card._task_progress.visible, "departure stamps 下班 and removes task progress")
			_check(not card.draggable and not card.input_ray_pickable and card.collision_layer == 0, "departing card cannot be picked or collide")
			card._leave_tween.pause()
			var tween := card._leave_tween
			card.leave()
			_check(card._leave_tween == tween, "repeated win cannot restart departure")
	_check(departing.size() == (6 if winner == 2 else 3), "all winning personnel roles leave together")
	var midpoint := WorkUI.number("animation", "leave_anticipation") + WorkUI.number("animation", "leave_duration") * 0.5
	for card in departing: card._leave_tween.custom_step(midpoint)
	board._advance_meeting_visitors(midpoint)
	board._advance_cash_flights(midpoint)
	for card in departing:
		_check(card.visible and card._visual.position != poses[card.uid].origin and card._visual.scale.x < poses[card.uid].basis.get_scale().x, "entire frame travels and shrinks during exit")
		_check(card._visual.position.y >= poses[card.uid].origin.y, "departure never dips the solid frame underneath the table")
		_check(card._icon.transform == portraits[card.uid] and is_equal_approx(card._icon.modulate.a, 1.0), "portrait stays attached and opaque so no blank card appears")
	if label in ["player", "meeting"]: await _capture(label + "-departing")
	for card in departing: card._leave_tween.custom_step(WorkUI.number("animation", "leave_duration"))
	board._advance_meeting_visitors(2.0)
	board._advance_cash_flights(2.0)
	if capture: await create_timer(WorkUI.number("animation", "retire_wait") + WorkUI.number("animation", "retire_duration")).timeout
	board.sync_state(state)
	for card in departing:
		_check(not card.visible and not card._plate.is_visible_in_tree() and not card._icon.is_visible_in_tree() and not card.label.is_visible_in_tree(), "finished departure hides frame, title, and portrait together")
		_check(state.cards.has(card.uid), "presentation never deletes authoritative personnel")
	for card: WorkCard in board.by_uid.values():
		if not card._is_person() or (winner != 2 and card.card_owner != winner):
			_check(card.visible and card._icon.visible and card._icon.texture != null, "remaining board cards preserve their complete illustration")
	if label == "player": await _capture("player-finished")
	game._process(float(game.settings.result.delay))
	_check(is_instance_valid(game.result_layer), "normal result screen appears after departure")
	if label == "player": await _capture("player-result")
	var previous := departing.duplicate()
	game._new_game()
	await process_frame
	for card: WorkCard in board.by_uid.values():
		_check(card.visible and not card._retired and not card._visual_retired and card._icon.visible, "restart restores fresh complete cards")
	for card in previous: _check(not is_instance_valid(card), "restart releases prior retired card")

func _cooldown_display() -> void:
	var tool := WorkCard.new()
	root.add_child(tool)
	var record := {"id": -800, "type": "meeting", "owner": 0, "group": 0, "status": "recovering", "activity": "idle", "total": 24.0, "remaining": 24.0}
	tool.configure(record, state.config.cards.meeting)
	tool.freeze = true
	for remaining in [24.0, 18.0, 12.0, 6.0, 0.0]:
		record.remaining = remaining
		tool.update_record(record)
		_check(tool._task_progress.visible and is_equal_approx(tool.task_progress_display_value(), remaining / 24.0), "cooldown drains visibly from full to empty at " + str(remaining))
		tool.flash_task_completion()
		_check(is_zero_approx(tool._task_completion_hold) and is_equal_approx(tool.task_progress_display_value(), remaining / 24.0), "unrelated completion cannot flash cooldown back to full")
	record.status = "active"
	for elapsed in [0.0, 0.5, 1.0]:
		record.remaining = 24.0 * (1.0 - elapsed)
		tool.update_record(record)
		_check(is_equal_approx(tool.task_progress_display_value(), elapsed), "active meeting still fills from empty to full")
	tool.queue_free()

func _id(kind: String, owner: int) -> int:
	for id in state.cards:
		if state.cards[id].type == kind and int(state.cards[id].owner) == owner: return int(id)
	return -1

func _capture(label: String) -> void:
	if not capture: return
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png("res://reports/end-presentation-%s.png" % label) == OK, "render capture " + label)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
