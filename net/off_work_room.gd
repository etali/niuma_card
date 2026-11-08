# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkRoom
extends RoomSeats

const State = preload("res://engine/off_work_state.gd")
const Session = preload("res://engine/off_work_session.gd")
const SNAPSHOT_INTERVAL := 0.12
# Compressed full-table snapshots may exceed the websocket default for custom opening decks.
const SOCKET_BUFFER := 4 * 1024 * 1024

var world: RefCounted
var away := {}
var _seed: int
var _elapsed := 0.0
var _started := false

func _init(room_code: String, seed_value: int, config: OffWorkConfig) -> void:
	super(room_code, seed_value)
	_seed = seed_value
	world = State.new(config)

func started() -> bool:
	return _started

func start_if_ready() -> bool:
	if _started or not full(): return false
	_started = true
	_deal()
	return true

func _deal() -> void:
	world.new_game(_seed if _seed != 0 else randi())
	world.drain_events()
	_elapsed = 0.0

func adopt(frame: Dictionary, seat: String, token: String) -> void:
	for key in Session.STATE_FIELDS: world.set(key, frame.world[key])
	world._rng.state = frame.rng
	game_num = frame.round
	tokens[seat] = token
	world._invalidate_group_index()
	_started = true

func match_finished() -> bool:
	return world.winner >= 0

func reset_for_rematch() -> Array:
	game_num += 1
	rematch_votes.clear()
	_deal()
	return _frame_updates()

func drop_peer(peer: int) -> String:
	var seat := super.drop_peer(peer)
	away.erase(seat)
	return seat

func advance(delta: float) -> Array:
	if not _started or not full() or not away.is_empty() or match_finished(): return []
	_elapsed += delta
	if _elapsed < SNAPSHOT_INTERVAL: return []
	world.advance(_elapsed)
	_elapsed = 0.0
	return _frame_updates()

func seated_msg(seat: String) -> Dictionary:
	return Protocol.off_work_seat(seat, tokens[seat], _frame([]) if _started else "")

func _frame(events: Array) -> String:
	var fields := {}
	for field in Session.STATE_FIELDS: fields[field] = world.get(field)
	# Variant preserves integer entity IDs (including dictionary keys); object decoding stays disabled.
	return Marshalls.raw_to_base64(var_to_bytes({"world": fields, "events": events,
		"rng": world._rng.state, "paused": not full() or not away.is_empty(), "round": game_num}).compress(FileAccess.COMPRESSION_DEFLATE))

func _frame_updates() -> Array:
	return [_all(Protocol.off_work_frame(_frame(world.drain_events())))]

func handle_action(peer: int, action: Dictionary) -> Array:
	var seat := seat_of(peer)
	if seat == "": return [_to(peer, Protocol.rejected("no_seat", "对局还未开始"))]
	if _started and full() and away.is_empty() and _elapsed > 0:
		world.advance(_elapsed)
		_elapsed = 0.0
	var op: Variant = action.get("op")
	if op == "away" and action.get("value") is bool:
		if action.value: away[seat] = true
		else: away.erase(seat)
		return _frame_updates() if _started else []
	if not _started or not full() or not away.is_empty():
		return [_to(peer, Protocol.rejected("paused", "双方回到下班牌桌后继续"))]
	var owner := SEATS.find(seat)
	if not _apply_action(owner, action):
		var reason: String = world.last_error if not world.last_error.is_empty() else "此操作无效"
		var updates := _frame_updates()
		updates.append(_to(peer, Protocol.rejected("bad_action", reason)))
		return updates
	return _frame_updates()

func _apply_action(owner: int, action: Dictionary) -> bool:
	world.last_error = ""
	for key in ["id", "group", "target"]:
		if action.has(key) and not OnWorkIntent.valid_integer(action[key], -1): return false
	var ids: Array = []
	if action.has("ids"):
		if not action.ids is Array or action.ids.size() > world.cards.size(): return false
		for uid in action.ids:
			if not OnWorkIntent.valid_integer(uid, 1) or not world.cards.has(int(uid)): return false
			if world.cards[int(uid)].owner != owner or int(uid) in ids: return false
			ids.append(int(uid))
	var id := int(action.get("id", -1))
	var group := int(action.get("group", -1))
	var target := int(action.get("target", -1))
	match action.get("op"):
		"buy": return world.buy(id, owner, ids) >= 0
		"dismiss": return world.dismiss_people(ids, owner)
		"move":
			var gid: int = world.move_cards(ids, group, target)
			if gid < 0: return false
			world._emit("net_drop", {"owner": owner, "ids": ids, "group": gid})
			return true
		"activate":
			if not world.cards.has(id) or world.cards[id].owner != owner: return false
			if world.cards[id].type == "coffee" and world.cards.has(target) and world.cards[id].group != group \
					and world.cards[target].group == group and world.cards[target].owner == owner:
				return world.move_cards([id], group, target) >= 0
			return world.activate(id, group, target)
		"deliver_strike":
			# The connection owns the action. A drag only selects the delivery
			# command; the authoritative state still validates the actual strike.
			if not world.cards.has(id) or world.cards[id].owner != owner: return false
			return world.deliver_strike(id, group)
		"resign": return world.resign(owner)
	return false
