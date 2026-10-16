# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SubViewport

## 首次出现的特效也会编译着色器；开桌时在离屏小视口绘制一次真实表现，
## 将准备工作留在启动阶段。静态资源负责后续复用，这个视口不常驻。
const Feedback = preload("res://scenes/table_feedback.gd")
const Motion = preload("res://scenes/ui_motion.gd")
const ComicFx = preload("res://scenes/comic_fx.gd")
const Materials = preload("res://scenes/effect_materials.gd")
static var _completed := false
static var _pending: WeakRef
var _frames := 0

static func prepare(parent: Node) -> SubViewport:
	if DisplayServer.get_name() == "headless" or _completed:
		return null
	if _pending != null and _pending.get_ref() != null:
		return _pending.get_ref()
	var viewport := new()
	viewport.name = "TableRenderWarmup"
	viewport.size = Vector2i(32, 32)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_disable_input = true
	viewport.process_mode = Node.PROCESS_MODE_ALWAYS
	_pending = weakref(viewport)
	# 同时开多张桌子只准备一次；关闭首个规则页不应中断其余桌子的预热。
	# 入口也可能位于根窗口首次传播 ready 时，推迟添加兄弟节点。
	parent.get_tree().root.add_child.call_deferred(viewport)
	return viewport

func _ready() -> void:
	_build_samples()
	RenderingServer.frame_post_draw.connect(_after_draw)

func _build_samples() -> void:
	# 补货若同时出现多张新插画，逐张同步解码会再次拉长回合切换帧。
	# 这里只准备当前卡表的静态小图；悬停动画仍按需在后台加载。
	for id in CardDB.all_cards():
		if CardArt.illustration_texture(str(id)) == null:
			CardArt.icon_texture(str(id))
	var world := Node3D.new()
	add_child(world)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 8, 0)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10
	world.add_child(camera)
	for back in [true, false]:
		var card := CardEntity.new()
		card.setup(-1, CardDB.unit_id(CardDB.RES_CASH))
		card.freeze = true
		card.collision_layer = 0
		card.collision_mask = 0
		card.position = Vector3(-2 if back else 2, 0, 0)
		world.add_child(card)
		if back:
			card.set_face_down(true)
		else:
			card.tear_apart()
	Feedback.receipt(world, "warmup", Vector3(0, 0, -2), "+1", Color.WHITE)
	Feedback.trace(world, "warmup", Vector3(-2, 0, 2), Vector3(2, 0, 2), Color.WHITE)
	Feedback.outline(world, "warmup", Vector3.ZERO, Vector2(1.2, 1.6), Color.WHITE)
	var particles := Motion.play(world, "production", Vector3.ZERO, Color.WHITE, 1) as CPUParticles3D
	particles.preprocess = 0.05
	# 牌桌特效的着色器与每种纸片形状都画一次；第一次结算、盖章、受击不再临场编译。
	ComicFx.badge_pop(world, Vector3(-2, 0, 0), "+1", CardDB.RES_CASH, Color.WHITE)
	ComicFx.stamp(world, Vector3(2, 0, 0), "章")
	# 章上的字第一次用到时要离屏排一次；开局先把配置里的词都排好。
	ComicFx.InkStamp.prewarm(ComicFx.rules().get("stamps", {}).values() + ["作废"])
	var target := CardEntity.new()
	target.setup(-2, CardDB.unit_id(CardDB.RES_USER))
	target.freeze = true
	target.collision_layer = 0
	target.collision_mask = 0
	target.position = Vector3(0, 0, -2)
	world.add_child(target)
	target.impact_damage(0.1)
	target.flash_stamp("章")
	ComicFx.seal(world, Vector3(0, 0, 2), "封", "章", Color.WHITE)
	ComicFx.spotlight(world, Vector3.ZERO)
	Motion.play(world, "upgrade", Vector3.ZERO, Color.WHITE)
	for shape in Materials.PARTICLE_SHAPES:
		var sprite := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * 0.3
		sprite.mesh = quad
		sprite.material_override = Materials.particles(shape)
		world.add_child(sprite)

func _after_draw() -> void:
	_frames += 1
	# 粒子和文字的内部网格可能在首帧末尾才准备好，再绘制一帧后释放。
	if _frames >= 2:
		_completed = true
		RenderingServer.frame_post_draw.disconnect(_after_draw)
		queue_free()

func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	if _pending != null and _pending.get_ref() == self:
		_pending = null
