# SPDX-License-Identifier: AGPL-3.0-only
extends SubViewport

## A compatibility renderer compiles at the first draw, even if the shader
## resource is already loaded. Use the scene-loading frames before either table
## is visible. These are the same shader resources and mesh types as the game.
const SAMPLES := [
	preload("res://shaders/table_felt.gdshader"),
	preload("res://shaders/table_surface.gdshader"),
	preload("res://shaders/card_face.gdshader"),
	preload("res://shaders/shift_paper_edges.gdshader"),
	preload("res://shaders/off_work_cash_face.gdshader"),
	preload("res://shaders/off_work_task_progress.gdshader"),
	preload("res://shaders/off_work_icon_motion.gdshader"),
]
var _face := MeshInstance3D.new()
var _next := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	size = Vector2i(8, 8)
	own_world_3d = true
	gui_disable_input = true
	var camera := Camera3D.new()
	camera.position.z = 2.0
	add_child(camera)
	_face.mesh = QuadMesh.new()
	_face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_face)

func _process(_delta: float) -> void:
	if _next == SAMPLES.size():
		queue_free()
		return
	var material := ShaderMaterial.new()
	material.shader = SAMPLES[_next]
	_face.material_override = material
	_next += 1
	render_target_update_mode = SubViewport.UPDATE_ONCE
