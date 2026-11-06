# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node

## Reuses niuma_card samples; no dependency on CardDB or its save directory.
var config: Dictionary
var muted := false:
	set(value):
		muted = value
		if muted: _clear_typing()
var _players: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}
var _next := 0
var _played := 0
var _pending: Array[Dictionary] = []
var _typing_players: Dictionary = {}
var _typing_speeds: Dictionary = {}
var _typing_stream: AudioStreamWAV
var _playback_enabled := false

func setup(settings: Dictionary, enable_playback := DisplayServer.get_name() != "headless") -> void:
	stop_all()
	for player in _players: player.queue_free()
	_players.clear()
	_streams.clear()
	_typing_stream = null
	_next = 0
	_played = 0
	config = settings
	# Headless validation has no audible output. Do not create asynchronous WAV
	# playback resources that outlive a forced --quit-after test shutdown.
	_playback_enabled = enable_playback
	if not _playback_enabled: return
	for action in config.actions.values():
		var path: String = "res://assets/sfx/" + str(action.file)
		if not _streams.has(path):
			_streams[path] = load(path)
	# The source pickup sample stays a one-shot for the original UI. Only this
	# private copy loops, timed by the audio mixer rather than rendered frames.
	var typing_source := _streams["res://assets/sfx/" + str(config.actions.typing.file)] as AudioStreamWAV
	_typing_stream = typing_source.duplicate() as AudioStreamWAV
	_typing_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_typing_stream.loop_begin = 0
	_typing_stream.loop_end = roundi(typing_source.get_length() * float(typing_source.mix_rate))
	for i in int(config.pool_size):
		var player := AudioStreamPlayer.new()
		add_child(player)
		_players.append(player)

func _process(delta: float) -> void:
	_played = 0
	for item in _pending:
		item.delay -= delta
		if float(item.delay) <= 0.0: play(str(item.action))
	_pending = _pending.filter(func(item: Dictionary) -> bool: return float(item.delay) > 0.0)

## One independent voice per local working group, regardless of employee count.
## Group identity preserves playback position through settlements and buffs.
func sync_work_groups(state: RefCounted, owner: int) -> void:
	var speeds: Dictionary = {}
	if not muted and state != null and state.winner < 0:
		for group in state.groups:
			if int(state.groups[group].owner) != owner: continue
			var participants: Array = state.group_work_participants(int(group))
			if participants.is_empty(): continue
			var rate: float = state.group_work_rate(int(group))
			var base_rate := 0.0
			for person in participants:
				base_rate += state.config.work_rate(str(state.cards[person].type), 0)
			base_rate /= float(participants.size())
			if rate > 0.0 and base_rate > 0.0: speeds[int(group)] = rate / base_rate
	_typing_speeds = speeds
	for group in _typing_players.keys():
		if not speeds.has(group): _remove_typing_player(int(group))
	if not _playback_enabled: return
	var spec: Dictionary = config.actions.typing
	for group in speeds:
		var pitch := float(spec.pitch) * float(speeds[group])
		if _typing_players.has(group):
			# Never restart the sample when a person joins or a buff changes.
			var player: AudioStreamPlayer = _typing_players[group]
			if not is_equal_approx(player.pitch_scale, pitch): player.pitch_scale = pitch
		else:
			var player := AudioStreamPlayer.new()
			player.name = "WorkingGroup%d" % int(group)
			player.stream = _typing_stream
			player.volume_db = float(spec.db)
			player.pitch_scale = pitch
			player.max_polyphony = 1
			add_child(player)
			_typing_players[group] = player
			player.play()

func _remove_typing_player(group: int) -> void:
	var player: AudioStreamPlayer = _typing_players[group]
	_typing_players.erase(group)
	player.stop()
	player.stream = null
	player.queue_free()

func _clear_typing() -> void:
	for group in _typing_players.keys(): _remove_typing_player(int(group))
	_typing_speeds.clear()

func schedule(action: String, delay: float) -> void:
	_pending.append({"action": action, "delay": delay})

func play(action: String) -> void:
	# Typing has its own group voices; effects cannot steal them or drop a beat
	# by exhausting this frame's transient-effect budget.
	if action == "typing": return
	if muted or not config.actions.has(action) or _players.is_empty():
		return
	if _played >= int(config.max_per_frame):
		return
	var spec: Dictionary = config.actions[action]
	var player: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = _streams["res://assets/sfx/" + str(spec.file)]
	player.volume_db = float(spec.db)
	player.pitch_scale = float(spec.pitch) * randf_range(float(config.pitch_min), float(config.pitch_max))
	player.play()
	_played += 1

func stop_all() -> void:
	_pending.clear()
	_clear_typing()
	for player in _players:
		player.stop()
		player.stream = null

func _exit_tree() -> void:
	stop_all()
	_streams.clear()
