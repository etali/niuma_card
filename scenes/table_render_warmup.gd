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
enum Sample { CAMERA, BACK, TEAR, RECEIPT, TRACE, OUTLINE, PRODUCTION, BADGE, STAMP, IMPACT, SEAL, LIGHT, UPGRADE, PARTICLES, DONE }
const FRAMES_BETWEEN_SAMPLES := 4
var _sample := Sample.CAMERA
var _world: Node3D
var _card_ids: Array
var _pending_art := ""
var _warm_allowed: Callable
var _presented := false
var _frames_since_sample := FRAMES_BETWEEN_SAMPLES

static func prepare(parent: Node) -> SubViewport:
	if DisplayServer.get_name() == "headless" or _completed:
		return null
	if _pending != null and _pending.get_ref() != null:
		return _pending.get_ref()
	var viewport := new()
	viewport.name = "TableRenderWarmup"
	viewport._warm_allowed = parent.get_meta("may_warm_table_effects", Callable())
	viewport.size = Vector2i(32, 32)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.gui_disable_input = true
	viewport.process_mode = Node.PROCESS_MODE_ALWAYS
	_pending = weakref(viewport)
	# 同时开多张桌子只准备一次；关闭首个规则页不应中断其余桌子的预热。
	# 入口也可能位于根窗口首次传播 ready 时，推迟添加兄弟节点。
	parent.get_tree().root.add_child.call_deferred(viewport)
	return viewport

func _ready() -> void:
	_card_ids = OnWorkCardDB.all_cards().keys()
	RenderingServer.frame_post_draw.connect(_after_draw)

func _process(_delta: float) -> void:
	# Let the visible viewport present first. Submit one real shader/effect family
	# per frame and keep at most one asynchronous illustration load in flight.
	if not _presented: return
	if not _pending_art.is_empty() and CardArt.collect_warm_art(_pending_art):
		_pending_art = ""
	if _pending_art.is_empty() and not _card_ids.is_empty():
		_pending_art = CardArt.request_warm_art(str(_card_ids.pop_back()))
	if _sample == Sample.DONE or _frames_since_sample < FRAMES_BETWEEN_SAMPLES: return
	if _warm_allowed.is_valid() and not _warm_allowed.call(): return
	_frames_since_sample = 0
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	match _sample:
		Sample.CAMERA:
			_world = Node3D.new()
			add_child(_world)
			var camera := Camera3D.new()
			camera.position = Vector3(0, 8, 0)
			camera.rotation_degrees.x = -90
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = 10
			_world.add_child(camera)
		Sample.BACK:
			var back := _warm_card(OnWorkCardDB.RES_CASH, Vector3(-2,0,0))
			back.set_face_down(true)
		Sample.TEAR:
			var front := _warm_card(OnWorkCardDB.RES_CASH, Vector3(2,0,0))
			front.tear_apart()
		Sample.RECEIPT:
			Feedback.receipt(_world, "warmup", Vector3(0,0,-2), "+1", Color.WHITE)
		Sample.TRACE:
			Feedback.trace(_world, "warmup", Vector3(-2,0,2), Vector3(2,0,2), Color.WHITE)
		Sample.OUTLINE:
			Feedback.outline(_world, "warmup", Vector3.ZERO, Vector2(1.2,1.6), Color.WHITE)
		Sample.PRODUCTION:
			var particles := Motion.play(_world, "production", Vector3.ZERO, Color.WHITE, 1) as CPUParticles3D
			particles.preprocess = 0.05
		Sample.BADGE:
			ComicFx.badge_pop(_world, Vector3(-2,0,0), "+1", OnWorkCardDB.RES_CASH, Color.WHITE)
		Sample.STAMP:
			ComicFx.stamp(_world, Vector3(2,0,0), "章")
			ComicFx.InkStamp.prewarm(ComicFx.rules().get("stamps", {}).values() + ["作废"])
		Sample.IMPACT:
			var target := _warm_card(OnWorkCardDB.RES_USER, Vector3(0,0,-2))
			target.impact_damage(0.1)
			target.flash_stamp("章")
		Sample.SEAL:
			ComicFx.seal(_world, Vector3(0,0,2), "封", "章", Color.WHITE)
		Sample.LIGHT:
			ComicFx.spotlight(_world, Vector3.ZERO)
		Sample.UPGRADE:
			Motion.play(_world, "upgrade", Vector3.ZERO, Color.WHITE)
		Sample.PARTICLES:
			# All particle shapes share one shader.
			for shape in Materials.PARTICLE_SHAPES:
				var sprite := MeshInstance3D.new()
				var quad := QuadMesh.new()
				quad.size = Vector2.ONE * 0.3
				sprite.mesh = quad
				sprite.material_override = Materials.particles(shape)
				_world.add_child(sprite)
	_sample = (_sample + 1) as Sample

func _warm_card(resource_kind: String, at: Vector3) -> CardEntity:
	var card := CardEntity.new()
	card.setup(-1, OnWorkCardDB.unit_id(resource_kind))
	card.freeze = true
	card.collision_layer = 0
	card.collision_mask = 0
	card.position = at
	_world.add_child(card)
	return card

func _after_draw() -> void:
	_presented = true
	_frames_since_sample += 1
	if _frames_since_sample == 2:
		# The submitted family gets two draws for late-created meshes/particles.
		# Leave the following frames to the visible table before the next family.
		render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _sample == Sample.DONE and _frames_since_sample >= 2 and _card_ids.is_empty() and _pending_art.is_empty():
		_completed = true
		RenderingServer.frame_post_draw.disconnect(_after_draw)
		queue_free()

func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	if _pending != null and _pending.get_ref() == self:
		_pending = null
