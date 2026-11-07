extends SceneTree

## Explicit presentation fixture using real personnel, meeting commands and timers.
var game: Node

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.state.config.rules.bot.enabled = false
	game.state.config.rules.initial.money = 0
	game.state.config.rules.initial.groups = [{"employee": 4, "work": 67}, {"work": 67}, {"work": 66}, {"leader": 1}, {"meeting": 1}, {"coffee": 1}]
	game._new_game()
	game.hud.set_process(false)
	game.hud._detail.hide()
	game.hud.lbl_round.text = "演出检查 · 自动组合"
	game.hud._sync_header_status()
	await create_timer(0.7).timeout
	game.state.advance(2.0)
	game.board.sync_state(game.state)
	var host := _owned("leader", 0)
	var meeting := _owned("meeting", 0)
	await _capture("before")
	game.state.move_cards([meeting], int(game.state.cards[host].group))
	game._process(0.0)
	await create_timer(0.28).timeout
	await _capture("pull")
	await create_timer(0.85).timeout
	await _capture("seated")
	var targets: Array = game.state.meetings[meeting].targets.duplicate()
	var arrived := true
	for uid in targets:
		var at: Vector3 = game.board.by_uid[uid].global_position
		arrived = arrived and game.board.player_bounds.has_point(Vector2(at.x, at.z))
	print("MEETING_REAL_ARRIVAL ", arrived, " targets=", targets.size())
	game.state.advance(float(game.state.config.rules.meeting.duration_seconds))
	game._process(0.0)
	await create_timer(0.26).timeout
	await _capture("return")
	await create_timer(0.65).timeout
	await _capture("returned")
	print("MEETING_REAL_RETURN ", game.board._meeting_visitors.is_empty())
	quit(0 if arrived and game.board._meeting_visitors.is_empty() else 1)

func _owned(kind: String, owner: int) -> int:
	for uid in game.state.cards:
		if game.state.cards[uid].type == kind and int(game.state.cards[uid].owner) == owner: return int(uid)
	return -1

func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png("res://reports/meeting-%s.png" % label)
	print("MEETING_REVIEW ", label, " result=", error)

func _process(_delta: float) -> bool:
	if is_instance_valid(game) and is_instance_valid(game.board): game._process(0.0)
	return false
