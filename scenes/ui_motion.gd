# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 语义动作的共享节拍；卡牌移动和角色反馈都以准备、执行、收尾组织。
const ANTICIPATE := 0.10
const ACT := 0.34
const SETTLE := 0.16
const TRANSFER := 0.18
const TEAR := 0.46
const STAGGER := 0.08
const FEEDBACK_LIFETIME := 0.8

## 每种事件有独立的方向、形状和节奏，避免所有动作都读成同一团爆花。
static func play(parent: Node3D, event: String, pos: Vector3, color: Color, amount := 16) -> Node3D:
	if event == "upgrade":
		return _upgrade_ring(parent, pos, color)
	var p := CPUParticles3D.new()
	p.name = "Feedback_%s" % event
	p.set_meta("motion_event", event)
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = FEEDBACK_LIFETIME if event == "attack" else ACT
	p.direction = Vector3.UP
	p.spread = 22.0
	p.initial_velocity_min = 1.4
	p.initial_velocity_max = 2.3
	p.gravity = Vector3(0, -2.2, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 0.9
	p.color = color
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.09, 0.14)
	if event == "attack":
		p.direction = Vector3(0, 0.35, 1)
		p.spread = 65.0
		p.initial_velocity_min = 2.0
		p.initial_velocity_max = 3.8
		p.gravity = Vector3(0, -5, 0)
		mesh.size = Vector2(0.08, 0.20)
	elif event == "production":
		p.spread = 12.0
		p.initial_velocity_min = 1.9
		p.initial_velocity_max = 2.8
		mesh.size = Vector2(0.075, 0.075)
	elif event == "pawn":
		p.direction = Vector3.DOWN
		p.spread = 18.0
		p.initial_velocity_min = 0.8
		p.initial_velocity_max = 1.5
		p.gravity = Vector3.ZERO
	p.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = material
	p.angular_velocity_min = -80
	p.angular_velocity_max = 80
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0, 0.55, 1])
	fade.colors = PackedColorArray([Color.WHITE, Color.WHITE, Color(1, 1, 1, 0)])
	p.color_ramp = fade
	p.position = pos
	parent.add_child(p)
	p.emitting = true
	var tween := p.create_tween().bind_node(p)
	tween.tween_interval(p.lifetime + SETTLE)
	tween.tween_callback(p.queue_free)
	return p

static func _upgrade_ring(parent: Node3D, pos: Vector3, color: Color) -> Node3D:
	var ring := MeshInstance3D.new()
	ring.name = "Feedback_upgrade"
	ring.set_meta("motion_event", "upgrade")
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.70
	mesh.outer_radius = 0.76
	mesh.rings = 32
	mesh.ring_segments = 8
	ring.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	ring.material_override = material
	ring.position = pos
	ring.scale = Vector3.ONE * 0.5
	parent.add_child(ring)
	var tween := ring.create_tween().bind_node(ring).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(ring, "scale", Vector3.ONE * 0.42, ANTICIPATE)
	tween.tween_property(ring, "scale", Vector3.ONE * 1.8, ACT)
	tween.parallel().tween_property(material, "albedo_color:a", 0.0, ACT)
	tween.tween_interval(SETTLE)
	tween.tween_callback(ring.queue_free)
	return ring

## 只晃动按钮自身，结束后归零；Container布局和连续拒绝不会积累位置偏移。
static func deny_button(button: Button) -> Tween:
	var previous: Variant = button.get_meta("deny_tween") if button.has_meta("deny_tween") else null
	if previous is Tween and previous.is_valid():
		previous.kill()
	button.rotation = 0.0
	button.pivot_offset = button.size * 0.5
	var tween := button.create_tween().bind_node(button)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	for angle in [-0.035, 0.035, -0.025, 0.025, 0.0]:
		tween.tween_property(button, "rotation", angle, ANTICIPATE * 0.6)
	button.set_meta("deny_tween", tween)
	return tween
