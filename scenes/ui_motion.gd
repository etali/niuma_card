# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Materials = preload("res://scenes/effect_materials.gd")

## 语义动作的共享节拍；卡牌移动和角色反馈都以准备、执行、收尾组织。
const ANTICIPATE := 0.10
const ACT := 0.34
const SETTLE := 0.16
const TRANSFER := 0.18
const TEAR := 0.46
const STAGGER := 0.08
const FEEDBACK_LIFETIME := 0.8
## 命中顿帧：抓握到位后整批停住这么久再撕开。抓握 + 顿帧 + 撕开仍落在原整批节拍内，
## 普通一击不因此拖慢回合；只有终结一击会额外延长（见 ComicFx.hitstop）。
const HITSTOP := 0.08
## 产出的硬币只是落袋前的一下迸发，真正的到账由飞向资源堆的牌表现。
const POP_LIFETIME := 0.42
## 事件默认用哪种纸片：钱相关是硬币，攻击是撕下的纸屑，购买是小星花。
const PARTICLE_SHAPE := {"production": "coin", "pawn": "coin", "purchase": "spark", "attack": "scrap"}
const PARTICLE_SIZE := {"coin": 0.27, "user": 0.34, "scrap": 0.20, "spark": 0.17}

## 每种事件有独立的方向、形状和节奏，避免所有动作都读成同一团爆花。
## shape 为空时按事件取默认纸片；产出用户等场合由调用方指定 "user"。
static func play(parent: Node3D, event: String, pos: Vector3, color: Color, amount := 16,
		shape := "") -> Node3D:
	if event == "upgrade":
		return _upgrade_ring(parent, pos, color)
	var kind := shape if not shape.is_empty() else str(PARTICLE_SHAPE.get(event, "spark"))
	var p := CPUParticles3D.new()
	p.name = "Feedback_%s" % event
	p.set_meta("motion_event", event)
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = FEEDBACK_LIFETIME if event == "attack" else (POP_LIFETIME if kind in ["coin", "user"] else ACT)
	p.direction = Vector3.UP
	p.spread = 22.0
	p.initial_velocity_min = 1.4
	p.initial_velocity_max = 2.3
	p.gravity = Vector3(0, -2.2, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 0.9
	p.color = color
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * float(PARTICLE_SIZE.get(kind, 0.17))
	if event == "attack":
		p.direction = Vector3(0, 0.35, 1)
		p.spread = 65.0
		p.initial_velocity_min = 2.0
		p.initial_velocity_max = 3.8
		p.gravity = Vector3(0, -5, 0)
	elif event == "production":
		# 硬币/小人从组合上抛起再落回，像一把钱撒出来，而不是直线喷射。
		p.spread = 28.0
		p.initial_velocity_min = 2.6
		p.initial_velocity_max = 3.6
		p.gravity = Vector3(0, -9.0, 0)
	elif event == "celebrate":
		# 升级/传说的彩纸：四种底板色的小星花向四周炸开再飘落。
		p.lifetime = FEEDBACK_LIFETIME
		p.spread = 75.0
		p.initial_velocity_min = 2.4
		p.initial_velocity_max = 4.2
		p.gravity = Vector3(0, -6.5, 0)
		var colors := Gradient.new()
		colors.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
		colors.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75])
		colors.colors = PackedColorArray([Palette.plate_color("plate_cash", "band"), Palette.plate_color("plate_user", "band"),
			Palette.plate_color("plate_t1_money", "band"), Palette.plate_color("plate_buff_up", "band")])
		p.color_initial_ramp = colors
	elif event == "pawn":
		p.direction = Vector3.DOWN
		p.spread = 18.0
		p.initial_velocity_min = 0.8
		p.initial_velocity_max = 1.5
		p.gravity = Vector3.ZERO
	p.mesh = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.material = Materials.particles(kind)
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
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.mesh = _ink_ring(0.73, 0.075)
	var material := Materials.flat(color, true)
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

## 一笔画成的墨圈：半径与笔压缓慢起伏，起笔收笔细、收笔压过起笔一小段，
## 不是圆规画的环。平铺在桌面上，双面可见。
static func _ink_ring(radius: float, width: float) -> ArrayMesh:
	var segments := 72
	var start := Materials.rng().randf() * TAU
	var sweep := TAU + 0.55
	var noise := Materials.rng()
	var salt := Vector3(noise.randf() * 10.0, noise.randf() * 10.0, noise.randf() * 10.0)
	var vertices := PackedVector3Array()
	for i in segments + 1:
		var t := float(i) / float(segments)
		var angle := start + sweep * t
		var r := radius * (1.0 + 0.035 * sin(angle * 3.0 + salt.x) + 0.02 * sin(angle * 7.0 + salt.y))
		var pressure := pow(sin(t * PI), 0.6)
		var w := width * (0.30 + 0.70 * pressure) * (1.0 + 0.2 * sin(angle * 5.0 + salt.z))
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		vertices.append(direction * (r - w * 0.5))
		vertices.append(direction * (r + w * 0.5))
	var indices := PackedInt32Array()
	for i in segments:
		var a := i * 2
		indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

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
