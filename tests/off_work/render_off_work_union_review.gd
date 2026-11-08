extends SceneTree

## Captures real rule events and their production presentation at controlled
## game times. No fabricated winning state or UI-only attack settlement.
var game: Node
const OUTPUT := "/tmp/off-work-union-review"

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	game.state.config.rules.bot.enabled = false
	game.state.config.rules.initial.groups = [{"employee": 1, "work": 60}, {"strike": 1}, {"union": 1}, {"boss": 1}]
	game.state.config.rules.initial.money = 0
	game._new_game()
	game.state.drain_events()
	game.hud.set_process(false)
	game.hud._detail.hide()
	game.hud.lbl_round.text = "演出验收 · 工作置顶 / 揉纸 / 工会防守"
	await create_timer(0.7).timeout
	game.board.set_process(false)
	await _capture("01-work-top")
	game.state.advance(10.0)
	_sync_events()
	game.board._advance_paper_disposal(0.07)
	await _capture("02-paper-crumple")
	game.board._advance_paper_disposal(0.33)
	await _capture("03-paper-throw")
	game.board._advance_paper_disposal(2.0)
	var attacker := _card("strike", 1)
	var person := _card("employee", 0)
	var target := int(game.state.cards[person].group)
	game.state.activate(attacker, target)
	_sync_events()
	game.state.advance(float(game.state.config.rules.strike.flight_seconds) * 0.5)
	_sync_events()
	await _capture("04-strike-incoming")
	game.state.move_cards([_card("union", 0)], target)
	game.state.advance(float(game.state.config.rules.strike.flight_seconds) * 0.5)
	_sync_events()
	game.board._advance_strike_attacks(0.12)
	await _capture("05-union-rebound")
	game.board._advance_strike_attacks(1.0)
	var boss := _card("boss", 0)
	var cash: int = game.state.add_card("money", 0)
	game.state.cards[cash].amount = 21
	game.state.move_cards([cash], int(game.state.cards[boss].group))
	game.state.advance(float(game.state.config.rules.recruitment.seconds) * 0.5)
	_sync_events()
	await create_timer(0.6).timeout
	await _capture("06-boss-recruiting")
	print("UNION_REVIEW ", OUTPUT)
	game.queue_free()
	await process_frame
	quit()

func _sync_events() -> void:
	game.board.sync_state(game.state)
	for event in game.state.drain_events(): game.board.play_event(event)
	game._update_hud()

func _card(kind: String, owner: int) -> int:
	for id in game.state.cards:
		if game.state.cards[id].type == kind and int(game.state.cards[id].owner) == owner: return int(id)
	return -1

func _capture(label: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(OUTPUT.path_join(label + ".png"))
	print("UNION_CAPTURE ", label, " result=", error)
