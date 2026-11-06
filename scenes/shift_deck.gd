# SPDX-License-Identifier: AGPL-3.0-only
extends Node3D
## 收齐后的牌摞。两张真实卡面印在不透明的纸边两侧，共用一根翻转轴。
const EDGE_SHADER = preload("res://shaders/shift_paper_edges.gdshader")
var front: Node3D
var back: Node3D
var edge := MeshInstance3D.new()
var front_depth: float
var back_depth: float

func setup(face: Node3D, depth: float, sheets: int) -> void:
	name = "ShiftDeck"
	front_depth = depth
	back_depth = depth
	var block := BoxMesh.new()
	block.size = Vector3(CardEntity.CARD_SIZE.x - CardEntity.PLATE_ART_INSET, 1.0,
		CardEntity.CARD_SIZE.z - CardEntity.PLATE_ART_INSET)
	edge.mesh = block
	var mat := ShaderMaterial.new()
	mat.shader = EDGE_SHADER
	mat.set_shader_parameter("stock", Palette.get_color("world", "table_frame"))
	mat.set_shader_parameter("seam", Palette.get_color("card", "frame"))
	mat.set_shader_parameter("sheets", clampi(sheets, 1, 10))
	edge.material_override = mat
	edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(edge)
	front = face
	if front: add_child(front)
	turn(0.0)
	hide()

func set_reverse(face: Node3D, depth: float) -> void:
	back_depth = depth
	back = face
	if back:
		add_child(back)
		back.rotation.z = PI
	turn(0.0)

func turn(progress: float) -> void:
	var depth := lerpf(front_depth, back_depth, progress)
	edge.scale.y = depth
	rotation.z = PI * progress
	# Only the exposed print is submitted. This also covers glow/stamp layers
	# that intentionally draw over other objects during ordinary gameplay.
	if front:
		front.position.y = depth * 0.5
		front.visible = progress < 0.5
	if back:
		back.position.y = -depth * 0.5
		back.visible = progress >= 0.5
