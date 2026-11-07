extends SceneTree

## A labelled fixture with the real meeting lifecycle and the formal card bar.
var game: Node

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	game.state.config.rules.bot.enabled = false
	game.state.config.rules.initial.groups = [{"meeting": 1, "leader": 1, "employee": 1, "work": 20}]
	game._new_game()
	game.state.drain_events()
	game.hud.lbl_round.text = "演出测试 · 会议读条与冷却"
	game.hud.set_process(false)
	game.hud._detail.hide()
	var meeting := -1
	for uid in game.state.cards:
		if int(game.state.cards[uid].owner) == 0 and game.state.cards[uid].type == "meeting": meeting = int(uid)
	game._activate(meeting, int(game.state.cards[meeting].group))
	game._process(0.0)
	await create_timer(0.8).timeout
	await _capture("start")
	var duration: float = game.state.config.number("meeting", "duration_seconds")
	var cooldown: float = game.state.config.number("meeting", "recovery_seconds")
	game.state.advance(duration * 0.5)
	game._process(0.0)
	await _capture("active")
	var card: OffWorkCard = game.board.by_uid[meeting]
	var active: bool = is_equal_approx(card._task_progress_value, 0.5) and card._task_progress_phase == "meeting"
	game.state.advance(duration * 0.5)
	game._process(0.0)
	await create_timer(0.8).timeout
	await _capture("cooldown-start")
	game.state.advance(cooldown * 0.5)
	game._process(0.0)
	await _capture("cooldown")
	var recovering: bool = is_equal_approx(card._task_progress_value, 0.5) and card._task_progress_phase == "recovering"
	game.state.advance(cooldown * 0.5)
	game._process(0.0)
	await _capture("restarted")
	var ready: bool = game.state.cards[meeting].status == "active" and card._task_progress.visible and card._task_progress_phase == "meeting"
	print("MEETING_TIMER_REVIEW ", active and recovering and ready, " active=", active, " cooldown=", recovering, " ready=", ready)
	quit(0 if active and recovering and ready else 1)

func _capture(label: String) -> void:
	# Rules are deliberately frozen; let real cash flights and completion stamps
	# settle so they cannot hide the meeting card whose timer is under review.
	await create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png("res://reports/meeting-timer-%s.png" % label)
	print("MEETING_TIMER_CAPTURE ", label, " result=", result)
