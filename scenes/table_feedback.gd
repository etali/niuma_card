# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 对局/规则书/录像共用的桌面笔触。只画视觉，无碰撞、无状态写入、无额外等待。
const Motion = preload("res://scenes/ui_motion.gd")
const Materials = preload("res://scenes/effect_materials.gd")
const TRACE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 ink : source_color;
uniform float progress = 0.0;
void fragment() {
	float head = progress * 1.24;
	float tail = smoothstep(head - 0.30, head - 0.06, UV.x);
	float front = 1.0 - smoothstep(head - 0.015, head + 0.02, UV.x);
	float edge = smoothstep(0.0, 0.24, UV.y) * (1.0 - smoothstep(0.76, 1.0, UV.y));
	ALBEDO = ink.rgb;
	ALPHA = ink.a * tail * front * edge;
}
"""
const OUTLINE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 ink : source_color;
uniform vec2 extent;
uniform float progress = 0.0;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * extent;
	vec2 half_size = extent * 0.5 - vec2(0.16 - 0.055 * sin(progress * 3.14159));
	vec2 q = abs(p) - half_size + vec2(0.15);
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 0.15;
	d += 0.006 * sin(p.x * 19.0 + p.y * 3.0);
	float aa = max(fwidth(d), 0.003);
	float line = 1.0 - smoothstep(0.015, 0.015 + aa, abs(d));
	float fade = (1.0 - smoothstep(0.45, 1.0, progress)) * smoothstep(0.0, 0.1, progress);
	ALBEDO = ink.rgb;
	ALPHA = ink.a * line * fade;
}
"""
static var _trace_shader: Shader
static var _outline_shader: Shader

## 一次结算只出一张小回执；展示实际结果，无碰撞，不增加流程等待。
static func receipt(parent: Node3D, event: String, center: Vector3, text: String,
		color: Color) -> Node3D:
	var receipt := Node3D.new()
	receipt.name = "Receipt_" + event
	receipt.set_meta("motion_event", event)
	receipt.position = center + Vector3(0, 0.16, -0.78)
	parent.add_child(receipt)
	var label := Label3D.new()
	label.text = text
	label.font = Fonts.zh_bold()
	label.font_size = 64
	label.pixel_size = 0.0025
	label.outline_size = 0
	label.modulate = Palette.readable_ink(color, Palette.semantic("surface"))
	label.rotation_degrees = Vector3(-90, 0, 0)
	label.position.y = 0.006
	label.render_priority = 2
	receipt.add_child(label)
	var backing := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	var size := label.font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, label.font_size) * label.pixel_size
	plane.size = size + Vector2(0.22, 0.09)
	backing.mesh = plane
	backing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := Materials.flat(Palette.semantic("surface"))
	backing.material_override = material
	receipt.add_child(backing)
	receipt.scale = Vector3.ONE * 0.72
	var tween := receipt.create_tween().bind_node(receipt)
	tween.tween_property(receipt, "scale", Vector3.ONE, Motion.ANTICIPATE + Motion.STAGGER).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(Motion.ACT * 0.7)
	tween.tween_property(receipt, "position:z", receipt.position.z - 0.20, Motion.SETTLE)
	tween.parallel().tween_property(label, "modulate:a", 0.0, Motion.SETTLE)
	tween.parallel().tween_property(material, "albedo_color:a", 0.0, Motion.SETTLE)
	tween.tween_callback(receipt.queue_free)
	return receipt

static func trace(parent: Node3D, event: String, from: Vector3, to: Vector3,
		color: Color, duration := Motion.ACT) -> MeshInstance3D:
	if from == Vector3.INF or to == Vector3.INF or from.distance_to(to) < 0.15:
		return null
	var effect := MeshInstance3D.new()
	effect.name = "Trace_" + event
	effect.set_meta("motion_event", event)
	effect.set_meta("from", from)
	effect.set_meta("to", to)
	effect.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var cross := Vector3(to.z - from.z, 0, from.x - to.x).normalized() * 0.045
	if cross.is_zero_approx():
		cross = Vector3.RIGHT * 0.045
	for i in 24:
		var t0 := float(i) / 24.0
		var t1 := float(i + 1) / 24.0
		var a := from.lerp(to, t0) + Vector3.UP * (0.08 + sin(t0 * PI) * 0.42)
		var b := from.lerp(to, t1) + Vector3.UP * (0.08 + sin(t1 * PI) * 0.42)
		for vertex in [[a-cross, Vector2(t0,0)], [b-cross, Vector2(t1,0)], [b+cross, Vector2(t1,1)],
			[a-cross, Vector2(t0,0)], [b+cross, Vector2(t1,1)], [a+cross, Vector2(t0,1)]]:
			mesh.surface_set_uv(vertex[1])
			mesh.surface_add_vertex(vertex[0])
	mesh.surface_end()
	effect.mesh = mesh
	if _trace_shader == null:
		_trace_shader = Shader.new()
		_trace_shader.code = TRACE_SHADER
	var material := ShaderMaterial.new()
	material.shader = _trace_shader
	material.set_shader_parameter("ink", color)
	effect.material_override = material
	parent.add_child(effect)
	_fade(effect, material, duration)
	return effect

static func outline(parent: Node3D, event: String, center: Vector3, extent: Vector2,
		color: Color, duration := Motion.ACT + Motion.SETTLE) -> MeshInstance3D:
	var effect := MeshInstance3D.new()
	effect.name = "Outline_" + event
	effect.set_meta("motion_event", event)
	effect.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var plane := PlaneMesh.new()
	plane.size = extent + Vector2.ONE * 0.32
	effect.mesh = plane
	effect.position = center + Vector3.UP * 0.055
	if _outline_shader == null:
		_outline_shader = Shader.new()
		_outline_shader.code = OUTLINE_SHADER
	var material := ShaderMaterial.new()
	material.shader = _outline_shader
	material.set_shader_parameter("ink", color)
	material.set_shader_parameter("extent", plane.size)
	effect.material_override = material
	parent.add_child(effect)
	_fade(effect, material, duration)
	return effect

static func _fade(effect: Node, material: ShaderMaterial, duration: float) -> void:
	var tween := effect.create_tween().bind_node(effect)
	tween.tween_method(func(value: float): material.set_shader_parameter("progress", value), 0.0, 1.0, duration)
	tween.tween_callback(effect.queue_free)
