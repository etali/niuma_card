# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 临时特效消失后仍持有材质模板，避免每次重新编译相同着色器。
## 会改颜色/透明度的特效取独立副本；粒子色来自顶点，可共享只读材质。
static var _flat: Dictionary = {}
static var _particles: StandardMaterial3D

static func flat(color: Color, double_sided := false) -> StandardMaterial3D:
	if not _flat.has(double_sided):
		var template := StandardMaterial3D.new()
		template.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		template.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		template.cull_mode = BaseMaterial3D.CULL_DISABLED if double_sided else BaseMaterial3D.CULL_BACK
		# 模板本身不上屏；取得 RID 才会让 BaseMaterial3D 注册并持有生成的 shader。
		# 只保留尚未初始化的模板仍会在最后一个副本释放时丢掉缓存。
		template.get_rid()
		_flat[double_sided] = template
	var material := _flat[double_sided].duplicate() as StandardMaterial3D
	material.albedo_color = color
	return material

static func particles() -> StandardMaterial3D:
	if _particles == null:
		_particles = StandardMaterial3D.new()
		_particles.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_particles.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_particles.vertex_color_use_as_albedo = true
		_particles.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	return _particles
