# SPDX-License-Identifier: AGPL-3.0-only
extends Node3D

## 两副牌共用的桌面。换班只移动桌上的物件，桌面的材质、图案与实例始终保留。
var _table_mat: StandardMaterial3D
var _felt_material: ShaderMaterial
var _table_felt_lit := false

func build(drawer_mode: bool) -> void:
	name = "TableBackdrop"
	var mesh_inst := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(60, 0.15, 60) if drawer_mode else Vector3(34, 0.15, 22)
	mesh_inst.mesh = plane
	mesh_inst.position.y = -0.1
	var mat := StandardMaterial3D.new()
	# 台面与手绘卡面使用相同的平涂色；接触阴影独立绘制，灯光不再将绿底推成荧光色。
	mat.albedo_color = Palette.get_color("world", "table_felt")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 0.9
	mesh_inst.material_override = mat
	_table_mat = mat
	add_child(mesh_inst)

	# 可选台面毛毡：贴图单独铺在顶面的平面上，避免同时贴到桌子侧壁。
	var felt_tex := CardArt.table_texture("table_felt")
	if felt_tex:
		mat.albedo_color = Palette.get_color("world", "table_felt_lit")  # 侧壁配合毛毡压暗
		_table_felt_lit = true
		var felt := MeshInstance3D.new()
		var fq := QuadMesh.new()
		fq.size = Vector2(60, 60) if drawer_mode else Vector2(34, 22)
		felt.mesh = fq
		var fmat := StandardMaterial3D.new()
		fmat.albedo_texture = felt_tex
		# 与卡面底板同理：手绘平涂素材一律不受光，否则环境光+方向光把颜色顶到过曝
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		felt.material_override = fmat
		felt.rotation_degrees = Vector3(-90, 0, 0)
		felt.position = Vector3(0, -0.024, 0)
		add_child(felt)
	else:
		var felt := MeshInstance3D.new()
		felt.name = "PaperDesktop"
		var surface := PlaneMesh.new()
		surface.size = Vector2(60, 60) if drawer_mode else Vector2(34, 22)
		felt.mesh = surface
		_felt_material = ShaderMaterial.new()
		_felt_material.shader = load("res://shaders/table_felt.gdshader")
		_felt_material.set_shader_parameter("extent", surface.size)
		_felt_material.set_shader_parameter("doodle_pattern", preload("res://assets/art/table/user_cash_pattern.svg"))
		_felt_material.set_shader_parameter("felt_color", Palette.get_color("world", "table_felt"))
		_felt_material.set_shader_parameter("doodle_ink", Palette.get_color("pattern", "ink"))
		_felt_material.set_shader_parameter("pattern_density", Palette.get_number("pattern", "density"))
		_felt_material.set_shader_parameter("pattern_spacing", Palette.get_number("pattern", "spacing"))
		felt.material_override = _felt_material
		felt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		felt.position.y = -0.024
		add_child(felt)

