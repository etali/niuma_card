# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node3D

## One queued paper per actually consumed work UID. Bounded active meshes keep
## mass outsourcing smooth without silently dropping completed work effects.
const PaperShader = preload("res://shaders/off_work_paper_disposal.gdshader")
var pending: Array[Dictionary] = []
var active: Array[Dictionary] = []
var emitted := 0
var completed := 0
var _head := 0
var _delay := 0.0
var _serial := 0
var _mesh: PlaneMesh
var _settings: Dictionary

func setup(settings: Dictionary) -> void:
	_settings = settings
	_mesh = PlaneMesh.new()
	_mesh.size = Vector2.ONE
	_mesh.subdivide_width = int(settings.subdivisions)
	_mesh.subdivide_depth = int(settings.subdivisions)

func enqueue(texture: Texture2D, origin: Vector3, owner: int, source_size := Vector2.ZERO) -> void:
	if source_size == Vector2.ZERO:
		var frame := OffWorkUI.section("frame")
		var width := CardEntity.CARD_SIZE.x * float(frame.art_width) * float(frame.get("art_scale_by_type", {}).get("work", 1.0))
		source_size = Vector2(width, width * float(texture.get_height()) / float(texture.get_width()))
	pending.append({"texture": texture, "origin": origin, "owner": owner, "serial": _serial, "source_size": source_size})
	_serial += 1

func advance(delta: float) -> void:
	if _settings.is_empty(): return
	_delay -= delta
	while _head < pending.size() and active.size() < int(_settings.max_concurrent) and _delay <= 0.0:
		_spawn(pending[_head])
		_head += 1
		_delay += float(_settings.emission_interval_seconds)
	if _head == pending.size():
		pending.clear()
		_head = 0
		_delay = maxf(_delay, 0.0)
	var done: Array[Dictionary] = []
	for paper in active:
		paper.age += delta
		var fold := clampf(float(paper.age) / float(_settings.crumple_seconds), 0.0, 1.0)
		var flight := clampf((float(paper.age) - float(_settings.crumple_seconds)) / float(_settings.flight_seconds), 0.0, 1.0)
		var node: MeshInstance3D = paper.node
		var material: ShaderMaterial = node.material_override
		material.set_shader_parameter("fold", fold)
		material.set_shader_parameter("opacity", 1.0 - smoothstep(0.72, 1.0, flight))
		node.global_position = (paper.origin as Vector3).lerp(paper.destination, flight) + Vector3.UP * sin(flight * PI) * float(_settings.arc_height)
		node.rotation_degrees = Vector3(flight, flight * 0.7, flight * 0.4) * float(_settings.rotation_degrees)
		if flight >= 1.0: done.append(paper)
	for paper in done:
		active.erase(paper)
		paper.node.queue_free()
		completed += 1

func _spawn(request: Dictionary) -> void:
	var node := MeshInstance3D.new()
	node.mesh = _mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = PaperShader
	material.set_shader_parameter("paper_texture", request.texture)
	material.set_shader_parameter("source_size", request.source_size)
	material.set_shader_parameter("ball_size", float(_settings.ball_size))
	node.material_override = material
	add_child(node)
	node.global_position = request.origin
	var direction := -1.0 if int(request.owner) == 0 else 1.0
	# Stable fan avoids random state and never changes the game's seeded RNG.
	var fan := (int(request.serial) % 7 - 3) * 0.12
	var destination: Vector3 = request.origin + Vector3(direction * float(_settings.throw_distance), 0.0, fan)
	active.append({"node": node, "origin": request.origin, "destination": destination, "age": 0.0})
	emitted += 1

func clear() -> void:
	pending.clear()
	_head = 0
	_delay = 0.0
	for paper in active:
		remove_child(paper.node)
		paper.node.queue_free()
	active.clear()
	emitted = 0
	completed = 0
	_serial = 0

func queued_count() -> int:
	return pending.size() - _head
