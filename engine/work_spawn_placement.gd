extends RefCounted

## A new card is placed against the final, clamped geometry, never an old
## fixed-z grid that can collapse several candidates onto the same position.
static func pick(anchor: Vector3, bounds: Rect2, card_size: Vector2,
		obstacles: Array[Rect2], spec: Dictionary, clamper: Callable) -> Vector3:
	var gap := Vector2(float(spec.clearance[0]), float(spec.clearance[1]))
	var half := card_size * 0.5
	var usable := Rect2(bounds.position + half, (bounds.size - card_size).max(Vector2.ZERO))
	var first: Vector3 = clamper.call(anchor)
	if _overlap(first, card_size, gap, obstacles) <= float(spec.overlap_tolerance): return first
	var xs: Array[float] = [first.x]
	var zs: Array[float] = [first.z]
	var step := float(spec.grid_step)
	var columns := maxi(1, ceili(usable.size.x / step))
	var rows := maxi(1, ceili(usable.size.y / step))
	for index in columns + 1:
		xs.append(lerpf(usable.position.x, usable.end.x, float(index) / columns))
	for index in rows + 1:
		zs.append(lerpf(usable.position.y, usable.end.y, float(index) / rows))
	# Include exact edges of occupied footprints so a narrow real gap is not
	# missed merely because it lies between two regular grid samples.
	for obstacle in obstacles:
		xs.append(clampf(obstacle.position.x - half.x - gap.x, usable.position.x, usable.end.x))
		xs.append(clampf(obstacle.end.x + half.x + gap.x, usable.position.x, usable.end.x))
		zs.append(clampf(obstacle.position.y - half.y - gap.y, usable.position.y, usable.end.y))
		zs.append(clampf(obstacle.end.y + half.y + gap.y, usable.position.y, usable.end.y))
	var best := first
	var best_overlap := INF
	var best_distance := INF
	var visited: Dictionary = {}
	for x in xs:
		for z in zs:
			var candidate: Vector3 = clamper.call(Vector3(x, anchor.y, z))
			var key := Vector2(candidate.x, candidate.z)
			if visited.has(key): continue
			visited[key] = true
			var overlap := _overlap(candidate, card_size, gap, obstacles)
			var distance := Vector2(candidate.x - first.x, candidate.z - first.z).length_squared()
			if overlap < best_overlap - float(spec.overlap_tolerance) or (
				absf(overlap - best_overlap) <= float(spec.overlap_tolerance) and distance < best_distance):
				best = candidate
				best_overlap = overlap
				best_distance = distance
	return best

static func _overlap(at: Vector3, card_size: Vector2, gap: Vector2, obstacles: Array[Rect2]) -> float:
	var footprint := Rect2(Vector2(at.x, at.z) - (card_size + gap) * 0.5, card_size + gap)
	var area := 0.0
	for obstacle in obstacles:
		var occupied := Rect2(obstacle.position - gap * 0.5, obstacle.size + gap)
		if footprint.intersects(occupied): area += footprint.intersection(occupied).get_area()
	return area
