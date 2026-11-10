# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node

## Reuses niuma_card samples; no dependency on OnWorkCardDB or its save directory.
var config: Dictionary
var muted := false:
	set(value):
		muted = value
		if muted: stop_all()
var _players: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}
var _next := 0
var _played := 0
var _pending: Array[Dictionary] = []
var _typing_players: Dictionary = {}
var _typing_speeds: Dictionary = {}
var _typing_stream: AudioStreamWAV
var _playback_enabled := false
var _last_started_usec: Dictionary = {}

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

## Local working groups form a bounded ambient mix, regardless of card count.
## Audible group identities preserve playback through settlements and buffs.
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
	# Many groups are one ambient texture, not an unbounded number of equally
	# loud loops. Stable IDs preserve the existing voices while the scene grows.
	var audible := speeds.keys()
	audible.sort()
	audible.resize(mini(audible.size(),maxi(1,int(config.get("typing_voice_limit",8)))))
	for group in _typing_players.keys():
		if not audible.has(group): _remove_typing_player(int(group))
	if not _playback_enabled: return
	var spec: Dictionary = config.actions.typing
	# Linear gain normalization bounds even perfectly phase-aligned copies.
	var volume := float(spec.db)-linear_to_db(float(maxi(1,audible.size())))
	for group in audible:
		# Production can accelerate exponentially; sound must stay audible and
		# comfortable instead of moving pickup's harmonics into a whistle.
		var pitch := clampf(float(spec.pitch)*float(speeds[group]),
			float(config.get("typing_pitch_min",0.6)),float(config.get("typing_pitch_max",2.7)))
		if _typing_players.has(group):
			# Never restart the sample when a person joins or a buff changes.
			var player: AudioStreamPlayer = _typing_players[group]
			if not is_equal_approx(player.pitch_scale, pitch): player.pitch_scale = pitch
			if not is_equal_approx(player.volume_db,volume): player.volume_db=volume
		else:
			var player := AudioStreamPlayer.new()
			player.name = "WorkingGroup%d" % int(group)
			player.stream = _typing_stream
			player.volume_db = volume
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
	if muted or not config.actions.has(action): return
	var interval := float(config.actions[action].get("min_interval_seconds",0.0))
	if interval>0.0:
		# Keep the earliest audible arrival instead of accumulating a delayed
		# replay of hundreds of identical production events.
		for pending in _pending:
			if str(pending.action)==action and absf(float(pending.delay)-delay)<interval:
				pending.delay=minf(float(pending.delay),delay)
				return
	_pending.append({"action": action, "delay": delay})

func play(action: String) -> void:
	# Typing has its own group voices; effects cannot steal them or drop a beat
	# by exhausting this frame's transient-effect budget.
	if action == "typing": return
	if muted or not config.actions.has(action) or _players.is_empty():
		return
	var spec: Dictionary = config.actions[action]
	# All ordinary events retain the frame budget, including actions without a
	# voice limit. Only explicitly marked interaction/result feedback bypasses it.
	if _played>=int(config.max_per_frame) and not bool(spec.get("bypass_frame_limit",false)): return
	var interval := float(spec.get("min_interval_seconds",0.0))
	var now := _now_usec()
	if interval>0.0 and _last_started_usec.has(action) \
		and now-int(_last_started_usec[action])<int(interval*1000000.0): return
	var voice_limit := int(spec.get("max_voices",0))
	if voice_limit>0:
		var active := 0
		for existing in _players:
			if existing.playing and existing.get_meta("off_work_action","")==action: active+=1
		if active>=voice_limit: return
		var free := -1
		for offset in _players.size():
			var index := (_next+offset)%_players.size()
			if not _players[index].playing: free=index;break
		if free<0: return
		_next=free
	var player: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = _streams["res://assets/sfx/" + str(spec.file)]
	player.volume_db = float(spec.db)
	player.pitch_scale = float(spec.pitch) * randf_range(float(config.pitch_min), float(config.pitch_max))
	player.set_meta("off_work_action",action)
	player.play()
	_last_started_usec[action]=now
	_played += 1

func _now_usec() -> int:
	return Time.get_ticks_usec()

func stop_all() -> void:
	_pending.clear()
	_last_started_usec.clear()
	_played=0
	_clear_typing()
	for player in _players:
		player.stop()
		player.stream = null

func _exit_tree() -> void:
	stop_all()
	_streams.clear()
