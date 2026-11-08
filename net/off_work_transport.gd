# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkTransport
extends NetTransport

signal frame_received(frame: Dictionary)

var balance_hash := ""
var latest: Dictionary = {}
var checkpoint: Dictionary = {}
var away := false

func _init(server_url := "", room_code := "") -> void:
	super(server_url, room_code)
	socket.inbound_buffer_size = OffWorkRoom.SOCKET_BUFFER

func join_message() -> Dictionary:
	var msg := Protocol.join(room, balance_hash, resume_token)
	msg.game = "off"
	return msg

func has_dealt_state() -> bool:
	return not latest.is_empty()

func _dispatch_message(msg: Dictionary) -> void:
	if msg.t not in [Protocol.OFF_WORK_FRAME, Protocol.OFF_WORK_SEAT]:
		super._dispatch_message(msg)
		return
	if msg.t == Protocol.OFF_WORK_SEAT:
		my_seat = msg.my_seat
		foe_seat = OnWorkState.opponent(my_seat)
		resume_token = msg.resume_token
	if not msg.frame.is_empty():
		var packed := Marshalls.base64_to_raw(msg.frame)
		var payload := packed.decompress_dynamic(16 * 1024 * 1024, FileAccess.COMPRESSION_DEFLATE)
		var frame: Variant = bytes_to_var(payload)
		if not _valid_frame(frame):
			socket.close(1002, "Invalid work snapshot")
			return
		checkpoint = frame
		if my_seat == OnWorkState.BOT:
			frame = frame.duplicate(true)
			_mirror(frame)
		latest = frame
	if msg.t == Protocol.OFF_WORK_SEAT:
		if away: send_action({"op": "away", "value": true})
		connected.emit(my_seat, foe_seat)
	else:
		frame_received.emit(latest)

func _valid_frame(frame: Variant) -> bool:
	if not frame is Dictionary or not frame.get("world") is Dictionary: return false
	if not frame.get("paused") is bool or not frame.get("round") is int or not frame.get("rng") is int: return false
	if not frame.get("events") is Array or not frame.world.has_all(OffWorkRoom.Session.STATE_FIELDS): return false
	for field in ["cards", "groups", "outsourcing", "tasks", "meetings", "pending_strikes", "recruitment"]:
		if not frame.world[field] is Dictionary: return false
	for field in ["cards", "groups", "outsourcing", "pending_strikes", "recruitment"]:
		for item in frame.world[field].values():
			if not item is Dictionary or item.get("owner") not in [0, 1]: return false
	for event in frame.events:
		if not event is Dictionary or not event.get("kind") is String: return false
	return frame.world.offers is Array and frame.world.time is float and frame.world.winner in [-1, 0, 1, 2]

# The board uses 0 for the near side in both seats. Entity IDs are shared.
func _mirror(frame: Dictionary) -> void:
	for field in ["cards", "groups", "outsourcing", "pending_strikes", "recruitment"]:
		for item in frame.world[field].values(): item.owner = 1 - int(item.owner)
	if frame.world.winner in [0, 1]: frame.world.winner = 1 - int(frame.world.winner)
	for event in frame.events:
		for key in ["owner", "target_owner", "winner", "resigned"]:
			if event.get(key, -1) in [0, 1]: event[key] = 1 - int(event[key])

func send_action(action: Dictionary) -> void:
	if online(): _send(Protocol.off_work_action(action))
