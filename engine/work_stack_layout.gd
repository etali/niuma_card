extends RefCounted

## The visual layers represent real indices; no card, UID or simulation order
## is removed. An expanded layer can still be picked to cut its real suffix.
## prepare() runs once at a layout boundary, never inside offset()'s card loop.
static func prepare(group: Dictionary, spec: Dictionary) -> void:
	var cards: Array = group.cards
	var types: Array[String] = []
	for card in cards: types.append(str(card.def_id))
	var signature := [cards.hash(), types.hash(), spec.hash()]
	if group.get("work_expanded_signature", []) == signature: return
	group.work_expanded_signature = signature
	group.work_expanded_indices = []
	group.work_expanded_slots = []
	group.work_expanded_distances = []
	group.work_expanded_max_gap = 0.0
	var count := cards.size()
	var cap := maxi(2, int(spec.expanded_visible_layers))
	if count <= cap: return

	# Endpoints preserve the native origin and top/progress carrier. Keep every
	# detailed card when the budget permits; long repeated material runs supply
	# most of the layers which can be represented by a smaller set of real cards.
	var indices: Array[int] = [0, count - 1]
	var details: Array[int] = []
	var boundaries: Array[int] = []
	for index in count:
		if spec.expanded_detail_types.has(types[index]) and not indices.has(index):
			details.append(index)
		if index > 0 and types[index] != types[index - 1]:
			for boundary in [index - 1, index]:
				if not boundaries.has(boundary): boundaries.append(boundary)
	_add_candidates(indices, details, cap)
	_add_candidates(indices, boundaries, cap)

	# Fill the largest uncovered real-index interval, so a large homogeneous
	# pile has a distributed set of cuts rather than only its first few cards.
	indices.sort()
	while indices.size() < cap:
		var widest := 1
		var insert_at := -1
		for slot in indices.size() - 1:
			var width: int = indices[slot + 1] - indices[slot]
			if width > widest:
				widest = width
				insert_at = slot + 1
		if insert_at < 0: break
		var middle := indices[insert_at - 1] + widest / 2
		indices.insert(insert_at, middle)

	var slots: Array[int] = []
	var nearest := 0
	for index in count:
		while nearest + 1 < indices.size() and absi(index - indices[nearest + 1]) < absi(index - indices[nearest]):
			nearest += 1
		slots.append(nearest)
	group.work_expanded_indices = indices
	group.work_expanded_slots = slots
	# Repeated materials read as closely spaced edges; a change of type gets
	# more room for its heading. These are weights, scaled together at layout
	# time to fit the current table without changing the cut/index mapping.
	var distances: Array[float] = [0.0]
	var largest_gap := 0.0
	for slot in range(1, indices.size()):
		var repeated := types[indices[slot - 1]] == types[indices[slot]]
		var gap := maxf(0.0, float(spec.expanded_repeat_gap if repeated else spec.expanded_type_gap))
		distances.append(distances[-1] + gap)
		largest_gap = maxf(largest_gap, gap)
	group.work_expanded_distances = distances
	group.work_expanded_max_gap = largest_gap

## Compute only from the prepared map. Both height and spread depend on the
## bounded visual layer count, never on hundreds of logical material cards.
static func offset(group: Dictionary, index: int, spec: Dictionary, available_z: float) -> Vector3:
	var slots: Array = group.get("work_expanded_slots", [])
	var indices: Array = group.get("work_expanded_indices", [])
	var layer: int = slots[index] if slots.size() == group.cards.size() else index
	var layers: int = indices.size() if not indices.is_empty() else group.cards.size()
	var height := maxf(float(spec.expanded_layer_height),
		CardEntity.FACE_SPAN_Y + float(spec.expanded_layer_clearance))
	var span := minf(maxf(0.0, float(spec.expanded_max_span)), maxf(0.0, available_z))
	var gap := minf(Board.STACK_GAP.z, span / maxi(layers - 1, 1))
	var z := gap * layer
	var distances: Array = group.get("work_expanded_distances", [])
	if not indices.is_empty() and distances.size() == layers:
		var total: float = distances[-1]
		var largest_gap := float(group.work_expanded_max_gap)
		var ratio := 0.0 if total <= 0.0 else span / total
		if largest_gap > 0.0: ratio = minf(ratio, Board.STACK_GAP.z / largest_gap)
		z = float(distances[layer]) * ratio
	return Vector3(0.0, height * layer, z)

## Prefer all candidates when possible. If detailed cards alone overflow the
## budget, repeatedly choose the candidate furthest from existing real cuts.
## This remains deterministic and covers both ends of a crowded personnel pile.
static func _add_candidates(indices: Array[int], candidates: Array[int], cap: int) -> void:
	var pending: Array[int] = []
	for candidate in candidates:
		if not indices.has(candidate): pending.append(candidate)
	if pending.size() + indices.size() <= cap:
		indices.append_array(pending)
		return
	while indices.size() < cap and not pending.is_empty():
		var best := -1
		var furthest := -1
		for candidate in pending:
			var distance := absi(candidate - indices[0])
			for chosen in indices: distance = mini(distance, absi(candidate - chosen))
			if distance > furthest:
				furthest = distance
				best = candidate
		indices.append(best)
		pending.erase(best)
