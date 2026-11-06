extends SceneTree

## Explicit presentation fixture: one real partially completed task, followed
## by the production coffee command. Captures never fabricate progress/output.
var game: Node

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	game.state.config.rules.bot.enabled = false
	game.state.config.rules.initial.groups = [{"employee": 1, "work": 20}, {"coffee": 1}]
	game._new_game()
	# Main processing is frozen for this fixture, so discard its setup event
	# instead of replaying the old new_game burst during the later upgrade.
	game.state.drain_events()
	game.hud.lbl_round.text = "演出测试 · 咖啡升级"
	game.hud.set_process(false)
	game.hud._detail.hide()
	var person := -1
	var coffee := -1
	for uid in game.state.cards:
		if int(game.state.cards[uid].owner) != 0: continue
		if game.state.cards[uid].type == "employee": person = int(uid)
		if game.state.cards[uid].type == "coffee": coffee = int(uid)
	game.state.advance(3.5)
	game.board.sync_state(game.state)
	game._update_hud()
	await create_timer(0.7).timeout
	await _capture("before")
	var instance: int = game.board.by_uid[person].get_instance_id()
	game._activate(coffee, int(game.state.cards[person].group), person)
	game._process(0.0)
	await _capture("start")
	var duration: float = game.state.config.number("coffee", "seconds")
	game.state.advance(duration * 0.5)
	game._process(0.0)
	await create_timer(0.9).timeout
	await _capture("reading")
	var reading: bool = game.state.cards[person].type == "employee" and game.state.cards.has(coffee) and is_equal_approx(float(game.state.cards[person].progress), 0.5)
	game.state.advance(duration * 0.5)
	game._process(0.0)
	await create_timer(0.23).timeout
	await _capture("impact")
	await create_timer(0.7).timeout
	await _capture("after")
	var upgraded: bool = game.state.cards[person].type == "grinder" and not game.state.cards.has(coffee)
	var retained: bool = instance == game.board.by_uid[person].get_instance_id() and is_equal_approx(float(game.state.cards[person].progress), 0.35)
	print("UPGRADE_REVIEW ", upgraded and retained and reading, " original_uid=", person, " progress=", game.state.cards[person].progress, " timed_reading=", reading)
	quit(0 if upgraded and retained and reading else 1)

func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png("res://reports/upgrade-%s.png" % label)
	print("UPGRADE_CAPTURE ", label, " result=", result)
