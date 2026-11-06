extends SceneTree

const Audio = preload("res://scenes/work_audio.gd")

var checks := 0
var failures: Array[String] = []
var audio: Node
var settings: Dictionary

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok: failures.append(description)

func _run() -> void:
	# Run with --headless --audio-driver Dummy. Also mute the bus if this test
	# is launched manually with a real audio driver; playback clocks still run.
	var previous_mute := AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0, true)
	settings = UIConfig.read_section("presentation").audio
	audio = Audio.new()
	root.add_child(audio)
	audio.setup(settings, true)
	_sample_isolation()
	await _group_identity_and_speed()
	_meeting_and_coffee()
	_lifecycle()
	await _pause_and_resume()
	audio.stop_all()
	audio.queue_free()
	await process_frame
	await _wait_real(0.08)
	AudioServer.set_bus_mute(0, previous_mute)
	for failure in failures: printerr("FAIL ", failure)
	print("GROUP_WORK_AUDIO %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _state(people := 5) -> WorkState:
	var config := WorkConfig.new()
	config.rules.initial.groups = [{"employee": people, "work": 100}]
	config.rules.initial.money = 0
	var result := WorkState.new(config)
	result.new_game(71)
	check(result.last_error.is_empty(), "fixture has valid game configuration")
	return result

func _group(s: WorkState, owner := 0) -> int:
	for id in s.groups:
		if int(s.groups[id].owner) == owner and not s.group_people(int(id)).is_empty(): return int(id)
	return -1

func _voice(group: int) -> AudioStreamPlayer:
	return audio._typing_players.get(group) as AudioStreamPlayer

func _sync(s: WorkState, owner := 0) -> void:
	audio.sync_work_groups(s, owner)

func _wait_real(seconds: float) -> void:
	# First-frame delta can include resource loading. Use real elapsed time so
	# the separate Dummy mixing thread has actually processed each state change.
	var deadline := Time.get_ticks_usec() + int(seconds * 1000000.0)
	while Time.get_ticks_usec() < deadline: await process_frame

func _sample_isolation() -> void:
	var source: AudioStreamWAV = audio._streams["res://assets/sfx/" + str(settings.actions.typing.file)]
	check(audio._typing_stream != source, "typing owns a separate WAV resource")
	check(source.loop_mode == AudioStreamWAV.LOOP_DISABLED, "shared UI pickup remains a one-shot")
	check(audio._typing_stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "typing is a mixer-timed loop")
	check(audio._typing_stream.loop_begin == 0 and audio._typing_stream.loop_end == roundi(source.get_length() * source.mix_rate), "loop bounds use sample frames, independent of compressed data size")
	check(audio._typing_stream.data == source.data and audio._typing_stream.mix_rate == source.mix_rate, "loop reuses the existing niuma typing sample")

func _group_identity_and_speed() -> void:
	var s := _state()
	var group := _group(s)
	var opponent := _group(s, 1)
	_sync(s)
	check(s.group_work_participants(group).size() == 5 and audio._typing_players.size() == 1, "five workers in one group create exactly one voice")
	check(not audio._typing_players.has(opponent), "opponent workers have no voice")
	var player := _voice(group)
	check(player.max_polyphony == 1 and not audio._players.has(player), "working voice is monophonic and independent of transient effect pool")
	check(is_equal_approx(player.pitch_scale, float(settings.actions.typing.pitch)), "default pitch has no randomized variation")
	for _i in range(int(settings.pool_size) + 1): audio.play("pickup")
	audio.play("typing")
	check(_voice(group) == player and audio._typing_players.size() == 1, "effect bursts and legacy typing action cannot steal or duplicate group voices")
	await _wait_real(0.08)
	var before := player.get_playback_position()
	var playback := player.get_stream_playback()
	check(before > 0.0, "Dummy audio mixer advances the real looping player")
	for _i in range(8): _sync(s)
	check(_voice(group) == player and player.get_stream_playback() == playback, "unchanged sync retains the player and running playback")
	var person: int = s.group_people(group)[0]
	s.move_cards([person], -1)
	_sync(s)
	check(audio._typing_players.size() == 1 and _voice(group) == player, "removing one worker preserves the other four workers' voice")
	check(player.get_stream_playback() == playback, "personnel change does not restart the sample")
	var separate: int = s.cards[person].group
	s.move_cards([s.group_work(group)[0]], separate)
	_sync(s)
	check(audio._typing_players.size() == 2 and _voice(separate) != player, "two working groups get independent voices")
	var buff := s.add_card("overtime", 0)
	s.move_cards([buff], group)
	_sync(s)
	check(_voice(group) == player and is_equal_approx(audio._typing_speeds[group], 1.2), "one overtime card accelerates the same voice by 1.2")
	check(is_equal_approx(player.pitch_scale, float(settings.actions.typing.pitch) * 1.2), "one overtime pitch follows real work rate")
	var second := s.add_card("overtime", 0)
	s.move_cards([second], group)
	_sync(s)
	check(_voice(group) == player and is_equal_approx(audio._typing_speeds[group], 1.44), "stacking overtime gives 1.44 without replacing player")
	check(is_equal_approx(player.pitch_scale, float(settings.actions.typing.pitch) * 1.44), "stacked overtime updates pitch")
	check(player.get_stream_playback() == playback, "overtime changes do not restart the current sample")
	check(is_equal_approx(audio._typing_speeds[separate], 1.0), "overtime only affects its own group")
	var enemy_buff := s.add_card("overtime", 1)
	s.move_cards([enemy_buff], opponent)
	_sync(s)
	check(audio._typing_players.size() == 2 and not audio._typing_players.has(opponent) and is_equal_approx(audio._typing_speeds[group], 1.44), "opponent overtime neither creates a voice nor changes local speed")
	s.move_cards([buff, second], -1)
	_sync(s)
	check(_voice(group) == player and is_equal_approx(audio._typing_speeds[group], 1.0), "removing overtime restores base speed on the same player")
	s.config.rules.overtime.speed_multiplier = 1.5
	s.config.roles.employee.work_seconds = 7.0
	s.move_cards([buff, second], group)
	_sync(s)
	check(is_equal_approx(audio._typing_speeds[group], 2.25), "audio derives stacked speed from configuration, not hardcoded 1.2 or ten seconds")
	check(is_equal_approx(player.pitch_scale, float(settings.actions.typing.pitch) * 2.25), "custom configured work speed reaches actual audio pitch")
	_sync(s, 1)
	check(audio._typing_players.size() == 1 and audio._typing_players.has(opponent), "local owner is configurable rather than hardcoded to player zero")
	audio.stop_all()

func _meeting_and_coffee() -> void:
	var s := _state()
	var group := _group(s)
	_sync(s)
	var player := _voice(group)
	var leader := s.add_card("leader", 1)
	var host_group: int = s.cards[leader].group
	var meeting := s.add_card("meeting", 1, host_group)
	check(s.activate(meeting, host_group, leader), "opponent leader starts a real meeting")
	_sync(s)
	check(s.group_work_participants(group).size() == 1 and _voice(group) == player, "four meeting attendees leave one coworker working on the existing voice")
	s.advance(s.config.number("meeting", "duration_seconds"))
	_sync(s)
	check(s.group_work_participants(group).size() == 5 and _voice(group) == player, "meeting ending retains the still-working group's voice")
	var person: int = s.group_people(group)[0]
	var cup := s.add_card("coffee", 0)
	s.move_cards([cup], group, person)
	_sync(s)
	check(s.tasks[person].kind == "coffee" and s.group_work_participants(group).size() == 4 and _voice(group) == player, "one coffee upgrade does not silence coworkers")
	s.advance(s.config.number("coffee", "seconds"))
	_sync(s)
	check(s.cards[person].type == "grinder" and _voice(group) == player and is_equal_approx(audio._typing_speeds[group], 1.0), "grinder's double income neither doubles typing rate nor restarts it")
	audio.stop_all()
	s = _state(1)
	group = _group(s)
	_sync(s)
	person = s.group_people(group)[0]
	cup = s.add_card("coffee", 0)
	s.move_cards([cup], group, person)
	_sync(s)
	check(audio._typing_players.is_empty(), "sole worker upgrading stops the working voice")
	s.advance(s.config.number("coffee", "seconds"))
	_sync(s)
	check(audio._typing_players.size() == 1, "finished solo upgrade resumes work audio")
	leader = s.add_card("leader", 1)
	host_group = s.cards[leader].group
	meeting = s.add_card("meeting", 1, host_group)
	check(s.activate(meeting, host_group, leader), "meeting targets the sole local worker")
	_sync(s)
	check(audio._typing_players.is_empty(), "all workers attending a meeting stops the voice")
	s.advance(s.config.number("meeting", "duration_seconds"))
	_sync(s)
	check(audio._typing_players.size() == 1, "meeting ending resumes a previously silent working group")
	# A local meeting host also releases only that host, not their coworkers.
	audio.stop_all()
	s = _state(2)
	group = _group(s)
	_sync(s)
	player = _voice(group)
	meeting = s.add_card("meeting", 0, group)
	check(s.activate(meeting, group), "local worker starts a meeting")
	_sync(s)
	check(s.group_work_participants(group).size() == 1 and _voice(group) == player, "local meeting host does not silence their working coworker")
	audio.stop_all()

func _lifecycle() -> void:
	var s := _state()
	var group := _group(s)
	_sync(s)
	var player := _voice(group)
	audio.muted = true
	check(audio._typing_players.is_empty() and audio._typing_speeds.is_empty() and not player.playing, "muting immediately stops and removes all working voices")
	_sync(s)
	check(audio._typing_players.is_empty(), "muted syncing cannot restart work audio")
	audio.muted = false
	_sync(s)
	check(audio._typing_players.size() == 1 and _voice(group) != player, "unmuting restores only the currently working group")
	player = _voice(group)
	audio.schedule("pickup", 2.0)
	audio.stop_all()
	check(audio._typing_players.is_empty() and audio._typing_speeds.is_empty() and audio._pending.is_empty() and not player.playing, "stop_all clears group voices and pending effects")
	s.new_game(83)
	_sync(s)
	check(audio._typing_players.size() == 1 and _voice(_group(s)) != player, "new game cannot inherit a previous voice through reused group IDs")
	for winner in [0, 1, 2]:
		s.winner = winner
		_sync(s)
		check(audio._typing_players.is_empty() and audio._typing_speeds.is_empty(), "all terminal outcomes stop work audio: %d" % winner)
		s.winner = -1
		_sync(s)
	audio.stop_all()

func _pause_and_resume() -> void:
	var s := _state()
	var group := _group(s)
	_sync(s)
	var player := _voice(group)
	await _wait_real(0.06)
	paused = true
	await process_frame
	await process_frame
	await _wait_real(0.06)
	var position := player.get_playback_position()
	await _wait_real(0.12)
	check(is_equal_approx(position, player.get_playback_position()), "SceneTree pause freezes the typing sample clock")
	check(_voice(group) == player, "pause preserves the working group voice")
	paused = false
	await _wait_real(0.12)
	check(not is_equal_approx(position, player.get_playback_position()), "resuming continues audio playback")
	check(_voice(group) == player, "resuming does not recreate the voice")
	var playback := player.get_stream_playback()
	await _wait_real(audio._typing_stream.get_length() / player.pitch_scale + 0.05)
	check(player.playing and player.get_stream_playback() == playback, "sample repeats continuously across its natural end without frame-triggered restarts")
	audio.stop_all()
