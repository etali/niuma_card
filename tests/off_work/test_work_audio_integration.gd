extends SceneTree

var game: Node
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok: failures.append(description)

func _run() -> void:
	# Uses the real scene and event routing, with no audible output or user data.
	var previous_mute := AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0, true)
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(3)
	check(game.sfx._action_overrides==game.settings.audio.arrival_actions, "real-time scene installs its own arrival sound limits on the shared effect player")
	game.set_process(false)
	game.hud.drawer_window.pin()
	await _frames(3)
	game.audio.setup(game.settings.audio, true)
	game.audio.set_process(false)
	game.audio.muted = false
	game.state.config.rules.initial.groups = [{"employee": 3, "work": 20}]
	game._new_game()
	game._process(0.0)
	var voices: Dictionary = game.audio._typing_players
	check(voices.size() == 1, "real game creates one voice for the three local workers")
	for group in voices:
		check(game.state.groups[group].owner == game.board._settings.local_owner, "real scene passes the local owner to audio")
	var initial_player: AudioStreamPlayer = voices.values()[0]
	game._process(0.0)
	check(game.audio._typing_players.values()[0] == initial_player, "successive main frames preserve playback")

	# Audio follows the configured side instead of assuming that the player is 0.
	game.board._settings.local_owner = 1
	game._process(0.0)
	check(game.audio._typing_players.size() == 1, "changing local owner still has exactly one voice")
	for group in game.audio._typing_players:
		check(game.state.groups[group].owner == 1, "configured owner controls which side is audible")
	game.board._settings.local_owner = 0
	game._process(0.0)

	game.state.advance(10.0)
	game.board.sync_state(game.state)
	var settlements := 0
	for event in game.state.drain_events():
		if event.kind != "work_complete": continue
		settlements += 1
		game.audio._played = 0
		game._present(event)
		check(game.audio._played == (1 if event.owner == 0 else 0), "only local ordinary work settlement plays a sound")
	check(settlements == 2, "both sides complete real work in the fixture")
	check(game.state.work_count(0) == 17 and game.state.work_count(1) == 17, "silencing opponent does not change production")

	game._new_game()
	check(game.audio._typing_players.is_empty(), "real restart clears old group voices immediately")
	game._process(0.0)
	check(game.audio._typing_players.size() == 1, "new working group starts normally after restart")
	game.state.winner = 0
	game.audio._played = 0
	game._present({"kind": "win", "winner": 0, "owner": 0})
	game._process(0.0)
	check(game.audio._typing_players.is_empty(), "real victory clears all work loops")
	check(game.audio._played == 1, "work synchronization does not silence the victory sound")
	game.queue_free()
	await _frames(3)
	await create_timer(0.15, true).timeout
	AudioServer.set_bus_mute(0, previous_mute)
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_AUDIO_INTEGRATION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _frames(count: int) -> void:
	for index in count: await process_frame
