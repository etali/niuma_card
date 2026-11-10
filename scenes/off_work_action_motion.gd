# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Presentation only: the authoritative action has already happened. A bounded
## set of its real cards retraces the move without delaying rules or decisions.
var board: Node
var motions: Dictionary = {}
var offer_sources: Dictionary = {}
var playback_speed := 1.0

func setup(host: Node) -> void:
	clear()
	board = host

func remember_offer(id: int, position: Vector3) -> void:
	offer_sources[id] = position
	# Expired offers also pass through this hook. Keep only recent visual
	# origins, bounded by the live market rather than the length of a match.
	var capacity := 12
	if is_instance_valid(board) and is_instance_valid(board._state):
		capacity = maxi(capacity, board._state.offers.size() * 2)
	while offer_sources.size() > capacity:
		offer_sources.erase(offer_sources.keys()[0])

func play_event(event: Dictionary) -> void:
	if not _ready(): return
	var kind := str(event.get("kind", ""))
	if kind not in ["group_changed", "buy"]: return
	var owner := int(event.get("owner", -1))
	var source: Variant = null
	if kind == "buy":
		var offer_id := int(event.get("offer_id", -1))
		source = offer_sources.get(offer_id)
		offer_sources.erase(offer_id)
	var ids: Array = event.get("ids", []) if kind == "group_changed" else [int(event.get("source", -1))]
	var candidates: Array = []
	for value in ids:
		var uid := int(value)
		var previous_group := int(board._previous_action_groups.get(uid, -1))
		# Consume even a hidden/non-opponent member: the same replay event must
		# never restart its old movement on a later presentation tick.
		board._previous_action_groups.erase(uid)
		if owner != int(board._settings.opponent_owner) or not _available(uid): continue
		var card: Node3D = board.by_uid[uid]
		if card.card_owner != owner: continue
		var from: Vector3
		if kind == "group_changed":
			if previous_group < 0 or previous_group == card.group_id or not board._previous_positions.has(uid): continue
			from = board._previous_positions[uid]
		else:
			if not source is Vector3: continue
			from = source
		if motions.has(uid): from = card.global_position
		candidates.append({"uid": uid, "from": from, "source_group": previous_group,
			"bucket": str(previous_group) + ":" + str(card.type)})
	if candidates.is_empty(): return
	var spec := _spec()
	var selected := _representatives(candidates, int(spec.max_visible), int(spec.batch_layers))
	# Prefer the newest visible action without accumulating motion nodes or
	# tweens for every real member of a large stack.
	for candidate in selected:
		if motions.has(candidate.uid): cancel(int(candidate.uid))
	while motions.size() + selected.size() > int(spec.max_visible):
		cancel(int(motions.keys()[0]), true)
	var layers: Dictionary = {}
	for candidate in selected:
		var layer := int(layers.get(candidate.bucket, 0))
		layers[candidate.bucket] = layer + 1
		_begin(candidate, layer, spec)
	board._invalidate_stack_occlusion()

func advance(delta: float) -> void:
	if motions.is_empty(): return
	if not _ready():
		clear()
		return
	var elapsed_delta := maxf(0.0, delta) * maxf(0.0, playback_speed)
	for value in motions.keys():
		var uid := int(value)
		var motion: Dictionary = motions[uid]
		if not _available(uid) or int(board.by_uid[uid].group_id) != int(motion.group):
			cancel(uid)
			continue
		var card: Node3D = board.by_uid[uid]
		motion.elapsed = float(motion.elapsed) + elapsed_delta
		var age := float(motion.elapsed)
		var pickup := float(motion.pickup_seconds)
		var travel := float(motion.travel_seconds)
		var drop := float(motion.drop_seconds)
		var settle := float(motion.settle_seconds)
		if age >= pickup + travel + drop + settle:
			cancel(uid, true)
			continue
		var from: Vector3 = motion.from
		var to: Vector3 = motion.to
		var lift_y := maxf(float(motion.lift_y), to.y + float(motion.lift_height))
		var raised_from := Vector3(from.x, lift_y, from.z)
		var raised_to := Vector3(to.x, lift_y, to.z)
		var position: Vector3
		var phase: String
		if age < pickup:
			phase = "pickup"
			position = from.lerp(raised_from, _ease(age / maxf(pickup, 0.000001)))
		elif age < pickup + travel:
			phase = "travel"
			position = raised_from.lerp(raised_to, _ease((age - pickup) / maxf(travel, 0.000001)))
		elif age < pickup + travel + drop:
			phase = "drop"
			position = raised_to.lerp(to, _ease((age - pickup - travel) / maxf(drop, 0.000001)))
		else:
			phase = "settle"
			position = to
		var velocity := (position - card.global_position) / maxf(delta, 0.000001)
		card.global_position = position
		if phase in ["drop", "settle"] and not bool(motion.landed):
			motion.landed = true
			card.pulse_landed()
		else:
			card.update_drag_motion(velocity, maxf(0.0, delta))
		motion.phase = phase
		card.set_meta("dest_pos", to)

## Board layout can change while a card is carried. Only its destination moves;
## the visible pickup and its clock belong to this action until it lands.
func preserve(card: Node3D, destination: Vector3) -> bool:
	if not is_instance_valid(card) or not motions.has(card.uid): return false
	var motion: Dictionary = motions[card.uid]
	if int(motion.group) != int(card.group_id):
		cancel(int(card.uid))
		return false
	motion.to = destination
	card.set_meta("dest_pos", destination)
	return true

func cancel(uid: int, snap := false) -> void:
	if not motions.has(uid): return
	var motion: Dictionary = motions[uid]
	motions.erase(uid)
	if not is_instance_valid(board): return
	var card: Variant = board.by_uid.get(uid)
	if is_instance_valid(card):
		if snap: card.global_position = motion.to
		card.remove_meta("off_work_action_motion")
		board._motion_unlock(card, motion)
	board._invalidate_stack_occlusion()

func clear() -> void:
	for uid in motions.keys(): cancel(int(uid), true)
	motions.clear()
	offer_sources.clear()
	playback_speed = 1.0
	if is_instance_valid(board): board._previous_action_groups.clear()

func _begin(candidate: Dictionary, layer: int, spec: Dictionary) -> void:
	var uid := int(candidate.uid)
	if not _available(uid): return
	var card: Node3D = board.by_uid[uid]
	var presenter: Node = board._presenter(card.card_owner)
	var destination: Vector3 = presenter.rest_pos(card)
	presenter._stop_move(card, false)
	var motion: Dictionary = board._motion_lock(card)
	var from: Vector3 = candidate.from
	motion.merge({"from": from, "to": destination, "elapsed": 0.0,
		"group": card.group_id, "source_group": int(candidate.source_group),
		"phase": "pickup", "landed": false,
		"lift_y": maxf(from.y, destination.y) + float(spec.lift_height) + layer * float(spec.layer_gap),
		"lift_height": float(spec.lift_height), "pickup_seconds": float(spec.pickup_seconds),
		"travel_seconds": float(spec.travel_seconds), "drop_seconds": float(spec.drop_seconds),
		"settle_seconds": float(spec.settle_seconds)})
	motions[uid] = motion
	card.set_meta("off_work_action_motion", true)
	card.set_meta("in_flight", true)
	card.set_meta("dest_pos", destination)
	card.global_position = from
	card.reveal_stack_face()
	card.set_drag_visual(true)

func _available(uid: int) -> bool:
	if not board.by_uid.has(uid) or not board._state.cards.has(uid): return false
	var card: Variant = board.by_uid[uid]
	if not is_instance_valid(card) or card._retired or card._visual_retired: return false
	if int(board._state.cards[uid].owner) != int(board._settings.opponent_owner): return false
	for other in [board._cash_flights, board._delivery_flights, board._meeting_visitors,
		board._strike_dancers, board._strike_attacks]:
		if other.has(uid): return false
	return true

func _ready() -> bool:
	return is_instance_valid(board) and is_instance_valid(board._state) \
		and not board._terminal_pose_locked and int(board._state.winner) < 0

func _spec() -> Dictionary:
	var result := {"pickup_seconds": 0.12, "travel_seconds": 0.5,
		"drop_seconds": 0.16, "settle_seconds": 0.12, "lift_height": 0.65,
		"max_visible": 12, "batch_layers": 3, "layer_gap": 0.045}
	result.merge(board._settings.get("action_motion", {}), true)
	result.max_visible = clampi(int(result.max_visible), 1, 12)
	result.batch_layers = clampi(int(result.batch_layers), 1, int(result.max_visible))
	for key in ["pickup_seconds", "travel_seconds", "drop_seconds", "settle_seconds", "lift_height", "layer_gap"]:
		result[key] = maxf(0.0, float(result[key]))
	return result

static func _representatives(candidates: Array, limit: int, layers: int) -> Array:
	if candidates.size() <= limit: return candidates
	var buckets: Dictionary = {}
	for candidate in candidates:
		if not buckets.has(candidate.bucket): buckets[candidate.bucket] = []
		# Keep only bounded real representatives, not a second huge UID queue.
		if buckets[candidate.bucket].size() < layers: buckets[candidate.bucket].append(candidate)
	var selected: Array = []
	for layer in layers:
		for bucket in buckets.values():
			if layer >= bucket.size(): continue
			selected.append(bucket[layer])
			if selected.size() == limit: return selected
	return selected

static func _ease(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
