extends SceneTree

const Replay = preload("res://engine/off_work_replay.gd")
const Session = preload("res://engine/off_work_session.gd")

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_immediate_delivery()
	_invalid_deliveries()
	_recorded_timing()
	for message in failures: printerr("FAIL ", message)
	print("STRIKE_DELIVERY %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 2, "work": 30}, {"strike": 1}]
	config.rules.bot.enabled = false
	var state := OffWorkState.new(config)
	state.new_game(71)
	state.drain_events()
	return state

func _card(state: OffWorkState, kind: String, owner: int) -> int:
	for id in state.cards:
		if state.cards[id].type == kind and state.cards[id].owner == owner: return int(id)
	return -1

func _immediate_delivery() -> void:
	for owner in [0, 1]:
		var state := _state()
		var strike := _card(state, "strike", owner)
		var target: int = state.cards[_card(state, "employee", 1 - owner)].group
		var people := state.group_people(target)
		state.advance(0.25)
		var before := state.time
		var progress := state.group_work_progress(target)
		_check(state.config.rules.strike.flight_seconds > 0.0, "fixture retains the normal automatic flight duration")
		_check(state.deliver_strike(strike, target), "either side can deliver a valid strike")
		_check(state.time == before and not state.cards.has(strike) and state.pending_strikes.is_empty(), "delivery consumes the card at the same game time without a queued flight")
		_check(people.all(func(id): return state.is_striking(id) and state.cards[id].remaining == state.config.rules.strike.duration_seconds), "all personnel immediately begin the full strike duration")
		_check(state.group_people(target).is_empty() and is_equal_approx(progress, state.group_work_progress(target)), "delivery scatters personnel while preserving accumulated work")
		var events := state.drain_events()
		_check(events.filter(func(event): return event.kind == "strike").size() == 1 and events.all(func(event): return event.kind != "strike_launch"), "delivery records one impact without a launch event")
		_rejected(state, strike, target, "consumed delivery cannot be repeated")
		state.advance(float(state.config.rules.strike.duration_seconds) - 0.01)
		_check(people.all(func(id): return state.is_striking(id)), "manual strike lasts until its actual deadline")
		state.advance(0.01)
		_check(people.all(func(id): return not state.is_striking(id)), "manual strike ends without adding an unused flight duration")

func _invalid_deliveries() -> void:
	var state := _state()
	var strike := _card(state, "strike", 0)
	var person := _card(state, "employee", 1)
	var target: int = state.cards[person].group
	_rejected(state, -99, target, "missing source")
	_rejected(state, _card(state, "employee", 0), target, "wrong card type")
	_rejected(state, strike, -1, "missing explicit target")
	_rejected(state, strike, 99999, "nonexistent target")
	_rejected(state, strike, int(state.cards[_card(state, "employee", 0)].group), "own group")
	var idle := state.add_card("employee", 1)
	_rejected(state, strike, int(state.cards[idle].group), "idle target")
	var union_id := state.add_card("union", 1, target)
	_rejected(state, strike, target, "union-protected target")
	state.move_cards([union_id], -1)
	_check(state.activate(strike, target), "ordinary activation still launches a delayed strike")
	_rejected(state, strike, target, "in-flight source cannot be instantly delivered again")
	_check(state.pending_strikes.has(strike) and not state.is_striking(person), "rejection preserves the automatic flight and its response window")
	state.advance(float(state.config.rules.strike.flight_seconds))
	_check(state.is_striking(person), "automatic strike still lands at its original deadline")
	state = _state()
	strike = _card(state, "strike", 0)
	target = int(state.cards[_card(state, "employee", 1)].group)
	state.winner = 0
	_rejected(state, strike, target, "finished match")

func _rejected(state: OffWorkState, strike: int, target: int, reason: String) -> void:
	var before := var_to_bytes(_world(state))
	_check(not state.deliver_strike(strike, target) and not state.last_error.is_empty(), reason + " is rejected")
	_check(before == var_to_bytes(_world(state)), reason + " leaves the world unchanged")

func _world(state: OffWorkState) -> Dictionary:
	var world := {}
	for key in Session.STATE_FIELDS: world[key] = state.get(key)
	return world

func _recorded_timing() -> void:
	for manual in [false, true]:
		var state := _state()
		var strike := _card(state, "strike", 0)
		var person := _card(state, "employee", 1)
		var target: int = state.cards[person].group
		if manual: state.deliver_strike(strike, target)
		else: state.activate(strike, target)
		var world := _world(state)
		var layout := {}
		for key in Session.BOARD_FIELDS: layout[key] = {}
		# Use the same compressed version-1 frame representation as saved replays.
		var raw := var_to_bytes({"world":world, "layout":layout, "events":state.drain_events(), "rng":state._rng.state})
		var frame := {"t":state.time, "size":raw.size(), "data":Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD))}
		var restored := OffWorkState.new(state.config)
		var entry: Dictionary = Replay.decode_frame(frame, restored)
		_check(not entry.is_empty(), "manual and old automatic strike frames remain decodable without a format change")
		if entry.is_empty(): continue
		for key in Session.STATE_FIELDS: restored.set(key, entry.world[key])
		restored._rng.state = entry.rng
		restored._invalidate_group_index()
		_check(restored.is_striking(person) == manual and restored.pending_strikes.has(strike) != manual, "restored frame preserves immediate delivery versus recorded flight timing")
		restored.advance(float(state.config.rules.strike.flight_seconds) * 0.5)
		_check(restored.is_striking(person) == manual, "replay does not add a delay to delivery or remove a historical flight delay")
		restored.advance(float(state.config.rules.strike.flight_seconds) * 0.5)
		var expected: float = state.config.rules.strike.duration_seconds
		if manual: expected -= float(state.config.rules.strike.flight_seconds)
		_check(restored.is_striking(person) and is_equal_approx(restored.cards[person].remaining, expected), "replayed impact and strike expiry remain aligned with the original game clock")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
