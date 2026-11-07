class_name OffWorkIconMotion
extends RefCounted
## Animate the existing GPT master texture. No generated pose swapping or
## invented raster frames: the same continuous UV map drives card and preview.
const REGION_LIMIT := 8
const SPATIAL := preload("res://shaders/off_work_icon_motion.gdshader")
const CANVAS := preload("res://shaders/off_work_icon_motion_canvas.gdshader")
static var _data: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		_data = UIConfig.read_section("icon_motion")
	return _data

static func profile(kind: String) -> Dictionary:
	if kind.contains("/"):
		var parts := kind.split("/", false, 1)
		return data().get("activity_profiles", {}).get(parts[0], {}).get(parts[1], {})
	return data().get("cards", {}).get(kind, {})

static func profile_key(kind: String, activity := "") -> String:
	var activities: Dictionary = data().get("activity_profiles", {})
	return activity + "/" + kind if activities.get(activity, {}).has(kind) else kind

static func enabled(kind: String) -> bool:
	return not profile(kind).is_empty() and bool(profile(kind).get("enabled", true))

static func duration(kind: String) -> float:
	return float(profile(kind).get("duration", 1.0))

static func sample_fps() -> float:
	return float(data().get("sample_fps", 60.0))

static func sample_count(kind: String) -> int:
	# Include the closed endpoint for inspection; live time remains continuous.
	return ceili(duration(kind) * sample_fps()) + 1

static func _v2(value: Variant, fallback := Vector2.ZERO) -> Vector2:
	if not value is Array or value.size() < 2: return fallback
	return Vector2(float(value[0]), float(value[1]))

static func _movement(value: Dictionary) -> Vector4:
	var shift := _v2(value.get("translation", []))
	var size := _v2(value.get("scale", []))
	return Vector4(float(value.get("rotation", 0.0)), shift.x, shift.y, size.x)

static func _secondary(value: Dictionary) -> Vector4:
	return Vector4(_v2(value.get("scale", [])).y, float(value.get("phase", 0.0)), float(value.get("cycles", 1.0)), 0.0)

static func make_material(kind: String, canvas := false) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = CANVAS if canvas else SPATIAL
	_apply_profile(material, kind)
	return material

static func _apply_profile(material: ShaderMaterial, kind: String) -> void:
	var spec := profile(kind)
	var global: Dictionary = spec.get("global", {})
	material.set_shader_parameter("motion_duration", duration(kind))
	material.set_shader_parameter("motion_global_pivot", _v2(global.get("pivot", []), Vector2(0.5, 0.5)))
	material.set_shader_parameter("motion_global", _movement(global))
	material.set_shader_parameter("motion_global_secondary", _secondary(global))
	material.set_shader_parameter("motion_inverse_iterations", clampi(int(data().get("inverse_iterations", 2)), 1, 4))
	var regions: Array = spec.get("regions", [])
	var count := mini(regions.size(), mini(int(data().get("max_regions", REGION_LIMIT)), REGION_LIMIT))
	var shapes := PackedVector4Array()
	var pivots := PackedVector4Array()
	var moves := PackedVector4Array()
	var extras := PackedVector4Array()
	for index in REGION_LIMIT:
		var region: Dictionary = regions[index] if index < count else {}
		var center := _v2(region.get("center", []), Vector2(0.5, 0.5))
		var radius := _v2(region.get("radius", []), Vector2.ONE)
		var pivot := _v2(region.get("pivot", []), center)
		shapes.append(Vector4(center.x, center.y, radius.x, radius.y))
		pivots.append(Vector4(pivot.x, pivot.y, float(region.get("inner", 0.6)), 0.0))
		moves.append(_movement(region))
		extras.append(_secondary(region))
	material.set_shader_parameter("motion_region_count", count)
	material.set_shader_parameter("motion_shapes", shapes)
	material.set_shader_parameter("motion_pivots", pivots)
	material.set_shader_parameter("motion_moves", moves)
	material.set_shader_parameter("motion_extras", extras)
	material.set_meta("work_motion_kind", kind)

static func sync_material(material: ShaderMaterial, kind: String, texture: Texture2D, seconds: float, tint: Color) -> void:
	if material == null: return
	if material.get_meta("work_motion_kind", "") != kind: _apply_profile(material, kind)
	# Most of the hundreds of queued cards are still. Avoid resubmitting their
	# identical texture/tint/time to RenderingServer every render frame.
	if not material.has_meta("work_motion_texture") or material.get_meta("work_motion_texture") != texture:
		material.set_shader_parameter("art_texture", texture)
		material.set_meta("work_motion_texture", texture)
	if material.get_meta("work_motion_time", -1.0) != seconds:
		material.set_shader_parameter("motion_seconds", seconds)
		material.set_meta("work_motion_time", seconds)
	if not material.has_meta("work_motion_color") or material.get_meta("work_motion_color") != tint:
		material.set_shader_parameter("motion_tint", tint)
		material.set_meta("work_motion_color", tint)

static func _wave(seconds: float, period: float, spec: Dictionary) -> float:
	var phase := float(spec.get("phase", 0.0))
	return sin(TAU * float(spec.get("cycles", 1.0)) * seconds / period + phase) - sin(phase)

static func _transform(point: Vector2, spec: Dictionary, wave: float) -> Vector2:
	var pivot := _v2(spec.get("pivot", []), _v2(spec.get("center", []), Vector2(0.5, 0.5)))
	var scale := Vector2.ONE + _v2(spec.get("scale", [])) * wave
	var local := (point - pivot) * scale
	return pivot + local.rotated(float(spec.get("rotation", 0.0)) * wave) + _v2(spec.get("translation", [])) * wave

static func _displacement(point: Vector2, seconds: float, period: float, regions: Array) -> Vector2:
	var result := Vector2.ZERO
	for region: Dictionary in regions.slice(0, mini(int(data().get("max_regions", REGION_LIMIT)), REGION_LIMIT)):
		var center := _v2(region.get("center", []), Vector2(0.5, 0.5))
		var radius := _v2(region.get("radius", []), Vector2.ONE)
		var distance := ((point - center) / radius).length()
		var weight := 1.0 - smoothstep(float(region.get("inner", 0.6)), 1.0, distance)
		result += (_transform(point, region, _wave(seconds, period, region)) - point) * weight
	return result

## CPU mirror for numeric continuity and bounds tests, not image generation.
static func source_uv(kind: String, point: Vector2, seconds: float) -> Vector2:
	var spec := profile(kind)
	var period := duration(kind)
	var global: Dictionary = spec.get("global", {})
	var wave := _wave(seconds, period, global)
	var pivot := _v2(global.get("pivot", []), Vector2(0.5, 0.5))
	var shift := _v2(global.get("translation", [])) * wave
	var scale := Vector2.ONE + _v2(global.get("scale", [])) * wave
	var target := pivot + (point - pivot - shift).rotated(-float(global.get("rotation", 0.0)) * wave) / scale
	var source := target
	for iteration in clampi(int(data().get("inverse_iterations", 2)), 1, 4):
		source = target - _displacement(source, seconds, period, spec.get("regions", []))
	return source
