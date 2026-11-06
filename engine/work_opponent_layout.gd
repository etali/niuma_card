extends RefCounted

## Stable rectangle packing for the BOT desk only. Shapes include the whole
## native stack and its side labels; the state and its groups are never edited.
static func arrange(entries: Array, bounds: Rect2, reserved: Array[Rect2], spec: Dictionary) -> Dictionary:
	var fixed: Array[Rect2] = reserved.duplicate()
	var movable: Array = []
	var positions: Dictionary = {}
	for entry in entries:
		if bool(entry.fixed):
			fixed.append(_rect(entry, entry.at))
			positions[entry.id] = entry.at
		else: movable.append(entry)
	# Preserve every non-conflicting old slot before asking new/grown groups
	# to find space. This is what keeps settled groups still across rule ticks.
	var occupied: Array[Rect2] = fixed.duplicate()
	var waiting: Array = []
	for entry in movable:
		var rect := _rect(entry, entry.at)
		if bounds.encloses(rect) and _overlap(rect, occupied, spec) <= float(spec.overlap_tolerance):
			positions[entry.id] = entry.at
			occupied.append(rect)
		else: waiting.append(entry)
	for entry in waiting:
		var at := _pick(entry, bounds, occupied, spec, false)
		positions[entry.id] = at
		occupied.append(_rect(entry, at))
	var score := _total_overlap(entries, positions, reserved, spec)
	if score <= float(spec.overlap_tolerance): return positions
	# A grown stack can be blocked by several individually valid old slots.
	# Only then try a deterministic whole-desk packing, with tall stacks first.
	movable.sort_custom(func(a, b):
		if not is_equal_approx(a.shape.size.y, b.shape.size.y): return a.shape.size.y > b.shape.size.y
		if not is_equal_approx(a.shape.size.x, b.shape.size.x): return a.shape.size.x > b.shape.size.x
		return int(a.id) < int(b.id))
	var packed: Dictionary = {}
	occupied = fixed.duplicate()
	for entry in entries:
		if bool(entry.fixed): packed[entry.id] = entry.at
	for entry in movable:
		var at := _pick(entry, bounds, occupied, spec, true)
		packed[entry.id] = at
		occupied.append(_rect(entry, at))
	return packed if _total_overlap(entries, packed, reserved, spec) < score - float(spec.overlap_tolerance) else positions

static func _rect(entry: Dictionary, at: Vector3) -> Rect2:
	return Rect2(Vector2(at.x, at.z) + entry.shape.position, entry.shape.size)

static func _pick(entry: Dictionary, bounds: Rect2, occupied: Array[Rect2], spec: Dictionary, packed: bool) -> Vector3:
	var shape: Rect2 = entry.shape
	var minimum := bounds.position - shape.position
	var maximum := bounds.end - shape.end
	var original: Vector3 = entry.at
	var xs: Array[float] = [clampf(original.x, minimum.x, maximum.x), minimum.x, maximum.x]
	var zs: Array[float] = [clampf(original.z, minimum.y, maximum.y), minimum.y, maximum.y]
	var gap := float(spec.gap)
	for obstacle in occupied:
		xs.append(clampf(obstacle.end.x + gap - shape.position.x, minimum.x, maximum.x))
		xs.append(clampf(obstacle.position.x - gap - shape.end.x, minimum.x, maximum.x))
		zs.append(clampf(obstacle.end.y + gap - shape.position.y, minimum.y, maximum.y))
		zs.append(clampf(obstacle.position.y - gap - shape.end.y, minimum.y, maximum.y))
	var columns := maxi(1, ceili((maximum.x - minimum.x) / float(spec.grid_step)))
	var rows := maxi(1, ceili((maximum.y - minimum.y) / float(spec.grid_step)))
	for index in columns + 1: xs.append(lerpf(minimum.x, maximum.x, float(index) / columns))
	for index in rows + 1: zs.append(lerpf(minimum.y, maximum.y, float(index) / rows))
	var best := Vector3(xs[0], original.y, zs[0])
	var best_overlap := INF
	var best_distance := INF
	var visited: Dictionary = {}
	for x in xs:
		for z in zs:
			var coordinate := Vector2(x, z)
			if visited.has(coordinate): continue
			visited[coordinate] = true
			var at := Vector3(x, original.y, z)
			var overlap := _overlap(_rect(entry, at), occupied, spec)
			var distance := (x - minimum.x) * float(spec.pack_x_weight) + z - minimum.y if packed \
				else coordinate.distance_squared_to(Vector2(original.x, original.z))
			if overlap < best_overlap - float(spec.overlap_tolerance) or (
				absf(overlap - best_overlap) <= float(spec.overlap_tolerance) and distance < best_distance):
				best = at
				best_overlap = overlap
				best_distance = distance
	return best

static func _overlap(rect: Rect2, occupied: Array[Rect2], spec: Dictionary) -> float:
	var expanded := rect.grow(float(spec.gap) * 0.5)
	var result := 0.0
	for obstacle in occupied:
		var other := obstacle.grow(float(spec.gap) * 0.5)
		if expanded.intersects(other): result += expanded.intersection(other).get_area()
	return result

static func _total_overlap(entries: Array, positions: Dictionary, reserved: Array[Rect2], spec: Dictionary) -> float:
	var occupied: Array[Rect2] = reserved.duplicate()
	var result := 0.0
	for entry in entries:
		var rect := _rect(entry, positions[entry.id])
		result += _overlap(rect, occupied, spec)
		occupied.append(rect)
	return result
