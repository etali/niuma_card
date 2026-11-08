# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 连续时间录像只在动作与规则事件发生时记关键帧。帧间由原规则时钟推进。
const Session = preload("res://engine/off_work_session.gd")
const JsonStore = preload("res://engine/json_store.gd")
const SavePaths = preload("res://engine/save_paths.gd")
const SPEEDS: Array[float] = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]
var playing := false
var speed := 1.0
var source_path := ""
var frames: Array = []
var playback: Array = []
var clock := 0.0
var next := 0
var last_revision := -1
var result_taunt := ""
var parked: Dictionary

func reset() -> void:
	frames.clear()
	last_revision = -1
	result_taunt = ""

func _layout(board: Node) -> Dictionary:
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key] = board.get(key).duplicate(true)
	return layout

func record(host: Node, events: Array = [], force := false) -> void:
	if playing: return
	var state: OffWorkState = host.state
	if not force and state.revision == last_revision and events.is_empty(): return
	last_revision = state.revision
	var world := {}
	for key in Session.STATE_FIELDS: world[key] = state.get(key)
	var payload := var_to_bytes({"world": world, "rng": state._rng.state, "layout": _layout(host.board), "events": events})
	frames.append({"t": state.time, "data": Marshalls.raw_to_base64(payload.compress(FileAccess.COMPRESSION_ZSTD)), "size": payload.size()})

func save(host: Node) -> String:
	if playing: return source_path
	record(host, [], true)
	var path := SavePaths.recordings_dir().path_join("下班-%s-%d.json" % [Time.get_datetime_string_from_system().replace(":", "-"), Time.get_ticks_usec()])
	var tape := {"game": "work", "version": 1, "cards": host.state.config.balance_document(), "frames": frames}
	# Record the policy actually bound to this match, so a saved loss can be
	# audited without guessing its strength from the cadence of visible moves.
	if host.bot != null:
		tape["bot"] = {"model_version":host.state.config.bot_preferences.get("model_version", 0),
			"policy":host.bot._policy.duplicate(true),
			"selection":preload("res://engine/off_work_bot_preferences.gd").selection_snapshot()}
	return path if JsonStore.save(path, tape, false) else ""

func begin(host: Node, path: String) -> Dictionary:
	if playing or host.shift_network_live(): return {"ok": false, "reason": "请先退出当前录像或联机对局"}
	var tape: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not tape is Dictionary or tape.get("game") != "work" or tape.get("version") != 1 or not tape.get("frames") is Array or tape.frames.is_empty() or not tape.get("cards") is Dictionary:
		return {"ok": false, "reason": "请选用下班玩法保存的录像"}
	var config := OffWorkConfig.new(tape.cards)
	if not config.errors.is_empty(): return {"ok": false, "reason": "录像卡表无效"}
	if tape.has("bot"):
		if not tape.bot is Dictionary or not tape.bot.get("policy") is Dictionary:
			return {"ok": false, "reason": "录像 BOT 参数无效"}
		var preferences: Dictionary = config.bot_preferences.duplicate(true)
		preferences.model_version = tape.bot.get("model_version", preferences.model_version)
		config = OffWorkConfig.new(tape.cards, {"bot":tape.bot.policy, "preferences":preferences})
		if not config.errors.is_empty(): return {"ok": false, "reason": "录像 BOT 参数无效"}
	var view := OffWorkState.new(config)
	var last_time := -1.0
	for frame in tape.frames:
		var entry := decode_frame(frame, view)
		if entry.is_empty() or entry.world.time < last_time or not (frame.get("t") is int or frame.get("t") is float) or not is_equal_approx(entry.world.time, float(frame.t)):
			return {"ok": false, "reason": "录像关键帧损坏"}
		last_time = entry.world.time
	parked = host.park_table()
	host.state = view
	host._use_table_config(config)
	playing = true
	speed = 1.0
	source_path = ProjectSettings.globalize_path(path)
	playback = tape.frames
	next = 0
	clock = playback[0].t
	advance(host, 0)
	return {"ok": true}

static func decode_frame(frame: Variant, model: OffWorkState) -> Dictionary:
	if not frame is Dictionary or not frame.get("data") is String: return {}
	var size := int(frame.get("size", 0))
	if size <= 0 or size > 32000000: return {}
	var raw := Marshalls.base64_to_raw(frame.data).decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size: return {}
	var entry: Variant = bytes_to_var(raw)
	if not entry is Dictionary or not entry.get("world") is Dictionary or not entry.get("layout") is Dictionary or not entry.get("events") is Array or not entry.get("rng") is int: return {}
	if not entry.layout.has_all(Session.BOARD_FIELDS): return {}
	for key in ["pending_strikes", "recruitment"]:
		if not entry.world.has(key): entry.world[key] = {}
	for key in Session.STATE_FIELDS:
		if typeof(entry.world.get(key)) != typeof(model.get(key)): return {}
	for card in entry.world.cards.values():
		if not card is Dictionary or not model.config.cards.has(card.get("type")): return {}
	return entry

func set_speed(value: float) -> void:
	speed = clampf(value, SPEEDS.front(), SPEEDS.back())

func advance(host: Node, delta: float) -> void:
	if not playing or playback.is_empty(): return
	# Only the recording clock changes speed; the parked game and UI keep real time.
	clock = minf(clock + maxf(0.0, delta) * speed, playback.back().t)
	while next < playback.size() and playback[next].t <= clock:
		var frame := decode_frame(playback[next], host.state)
		for key in Session.STATE_FIELDS: host.state.set(key, frame.world[key])
		host.state._rng.state = frame.rng
		host.state._invalidate_group_index()
		for key in Session.BOARD_FIELDS: host.board.set(key, frame.layout[key])
		host.board.sync_state(host.state)
		for event in frame.events: host._present(event)
		next += 1
	host.state.advance(maxf(0.0, clock - host.state.time))
	host.state.drain_events()
	host.board.sync_state(host.state)
	host._update_hud()

func seek(host: Node, seconds: float) -> void:
	if not playing: return
	clock = clampf(seconds, playback.front().t, playback.back().t)
	next = playback.bsearch_custom(clock, func(a, b): return a.t < b, true)
	next = clampi(next - 1, 0, playback.size() - 1)
	host.board.reset_view()
	host.conveyor.reset()
	host.effects.clear()
	host.audio.stop_all()
	# 倒带后不能把上一次终局的暖光/暗场留在未结束的牌局上。
	host.hud.clear_result()
	host.result_layer = null
	advance(host, 0.0)
	if host.state.winner >= 0: host.hud.begin_off_work_finale(int(host.state.winner))

func end(host: Node) -> void:
	if not playing: return
	playing = false
	speed = 1.0
	playback.clear()
	host.restore_table(parked)
	parked.clear()
