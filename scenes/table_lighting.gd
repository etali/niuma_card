# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name TableLighting
extends Node3D

## 一摞牌共用一片软接触阴影。原来的定向光逐张投影，会把叠牌的高度台阶
## 放大成桌上的锯齿；这里保留卡牌本身的厚度与受光，只重画桌面上的投影。
## 一张 PlaneMesh + 一个 MultiMesh，不创建碰撞或 Control，不参与鼠标拾取。
## 所有阴影共享一个 draw call，牌堆移动只更新实例数据，不重建节点或纹理。
## 贴近桌面，低于薄卡自然落定后的底板；否则透明软影会直接把牌面蒙灰。
## 托盘不写深度，阴影与托盘的先后由 render_priority 保证，不需抬高到牌面附近。
const CONTACT_Y := 0.002
const COLUMN_TOLERANCE := 0.16
const NEIGHBOR_DISTANCE := 0.70
const REST_Y := 0.05
const BASE_SOFTNESS := 0.12
const BASE_OPACITY := 0.14
const MAX_HEIGHT := 4.0

const SHADOW_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
varying vec4 shape;
void vertex() {
	shape = INSTANCE_CUSTOM;
}
void fragment() {
	// custom: 半影平面的宽/长、半影宽度、不透明度。以世界单位计算圆角
	// 距离，所以长牌列不会把柔边也拉成长条，任何窗口尺寸都没有贴图锯齿。
	vec2 p = (UV - vec2(0.5)) * shape.xy;
	float softness = shape.z;
	float radius = 0.08;
	vec2 core_half = shape.xy * 0.5 - vec2(softness * 3.0);
	vec2 q = abs(p) - core_half + vec2(radius);
	float distance_to_card = length(max(q, vec2(0.0)))
		+ min(max(q.x, q.y), 0.0) - radius;
	float falloff = max(distance_to_card, 0.0) / softness;
	float alpha = shape.w * exp(-falloff * falloff * 1.5);
	ALBEDO = vec3(0.16, 0.17, 0.13);
	ALPHA = alpha;
}
"""

static var _contact_material: ShaderMaterial
var _board: Board
var _instances: MultiMeshInstance3D
var _multimesh: MultiMesh
var _capacity := 0
var _last_data: Array = []
var _last_positions := PackedVector3Array()
## Hidden stack sheets stay registered, but never enter the per-frame scan.
var _prepared_cards := {}
var _visible_cards := {}
var _card_visuals := {}
var _registration_order := {}
var _next_order := 0
var _visible_order: Array = []
var _visible_order_dirty := false

func bind(board: Board) -> void:
	_disconnect_board()
	_board = board
	name = "TableContactShadows"
	if _instances == null:
		_create_mesh()
	_board.card_registered.connect(_register_card)
	_board.card_unregistered.connect(_unregister_card)
	# This is the only full registration scan, including when restoring or
	# binding a presenter whose cards have already been built.
	for card in _board.cards:
		_register_card(card)
	# 牌的位置补间/物理已经跑完再取坐标，拖牌时阴影不会落后一帧。
	process_priority = 80
	refresh()

func _create_mesh() -> void:
	# 阴影只接收深度遮挡，不再把自身送进光照投影。
	_instances = MultiMeshInstance3D.new()
	_instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_instances)
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	_multimesh.mesh = plane
	_instances.multimesh = _multimesh
	if _contact_material == null:
		var shader := Shader.new()
		shader.code = SHADOW_SHADER
		_contact_material = ShaderMaterial.new()
		_contact_material.shader = shader
		_contact_material.render_priority = -32
	_instances.material_override = _contact_material

## 同一物理列里的重叠卡只投一次影；用实际位置而不是规则组，玩家/BOT/
## 联网拖动和飞入动画都走同一条路径。每列按 z 排序，分开的两摞不会被
## 拉成一块大矩形。x 分桶限制每片影的宽度，横向铺开的多列各有独立的影。
static func contact_footprints(cards: Array) -> Array:
	return _positions_footprints(_contact_positions(cards))

## 每帧只采样真实位置与显隐；静止牌桌无需重复建桶、排序和分配阴影字典。
static func _contact_positions(cards: Array) -> PackedVector3Array:
	var positions := PackedVector3Array()
	for value in cards:
		var card := value as CardEntity
		if not is_instance_valid(card) or card.is_queued_for_deletion() \
				or not card.is_visible_in_tree() or card._visual_retired:
			continue
		# Covered stack layers retain their physical/picking identity. Only the
		# printed visual casts a contact shadow, including during table rebuilds.
		if card._visual != null and not card._visual.is_visible_in_tree():
			continue
		var pos := card.global_position
		if card._visual != null:
			pos.y += card._visual.position.y
		if pos.y > MAX_HEIGHT + REST_Y:
			continue
		positions.append(pos)
	return positions

static func _positions_footprints(positions: PackedVector3Array) -> Array:
	var buckets := {}
	for pos in positions:
		var key := roundi(pos.x / COLUMN_TOLERANCE)
		var samples: Array = buckets.get(key, [])
		samples.append(pos)
		buckets[key] = samples
	var output: Array = []
	for key in buckets:
		var samples: Array = buckets[key]
		samples.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.z < b.z)
		var run := {"min": samples[0], "max": samples[0], "last_z": samples[0].z}
		for i in range(1, samples.size()):
			var pos: Vector3 = samples[i]
			# 拖起的牌与桌上牌即便处于同一投影位置，也需要自己的松软影子。
			var same_height_band := absf(pos.y - float(run["min"].y)) < 0.85
			if pos.z - float(run["last_z"]) <= NEIGHBOR_DISTANCE and same_height_band:
				run["min"] = (run["min"] as Vector3).min(pos)
				run["max"] = (run["max"] as Vector3).max(pos)
				run["last_z"] = pos.z
			else:
				output.append(_describe_contact(run))
				run = {"min": pos, "max": pos, "last_z": pos.z}
		output.append(_describe_contact(run))
	return output

static func _describe_contact(run: Dictionary) -> Dictionary:
	var lower: Vector3 = run["min"]
	var upper: Vector3 = run["max"]
	var lift := clampf(lower.y - REST_Y, 0.0, MAX_HEIGHT)
	var softness := BASE_SOFTNESS + lift * 0.14
	# 升高时淡出并略微偏移，既表现拿起的高度，也不把整摞变成浓黑光圈。
	var opacity := BASE_OPACITY / (1.0 + lift * 0.9)
	var center := (lower + upper) * 0.5
	center.y = CONTACT_Y
	center.x -= 0.025 + lift * 0.10
	center.z += 0.045 + lift * 0.16
	var span := Vector2(upper.x - lower.x + CardEntity.CARD_SIZE.x,
		upper.z - lower.z + CardEntity.CARD_SIZE.z)
	return {"center": center, "size": span + Vector2.ONE * softness * 6.0,
		"softness": softness, "opacity": opacity}

func _disable_mesh_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_mesh_shadows(child)

func _register_card(card: CardEntity) -> void:
	if not is_instance_valid(card): return
	var id := card.get_instance_id()
	if _prepared_cards.has(id): return
	_prepared_cards[id] = card
	_registration_order[id] = _next_order
	_next_order += 1
	_disable_mesh_shadows(card)
	card.visibility_changed.connect(_sync_card_visibility.bind(id))
	card.tree_entered.connect(_sync_card_visibility.bind(id))
	card.tree_exiting.connect(_card_exiting.bind(id))
	card.child_entered_tree.connect(_card_child_entered.bind(id))
	_track_visual(id)
	_sync_card_visibility(id)

func _unregister_card(card: CardEntity) -> void:
	if is_instance_valid(card): _forget_card(card.get_instance_id())

func _forget_card(id: int) -> void:
	_hide_card(id)
	_untrack_visual(id)
	var card = _prepared_cards.get(id)
	if is_instance_valid(card):
		card.visibility_changed.disconnect(_sync_card_visibility.bind(id))
		card.tree_entered.disconnect(_sync_card_visibility.bind(id))
		card.tree_exiting.disconnect(_card_exiting.bind(id))
		card.child_entered_tree.disconnect(_card_child_entered.bind(id))
	_prepared_cards.erase(id)
	_registration_order.erase(id)

func _track_visual(id: int) -> void:
	var card: CardEntity = _prepared_cards.get(id)
	if not is_instance_valid(card): return
	var visual := card._visual
	if _card_visuals.get(id) == visual: return
	_untrack_visual(id)
	if not is_instance_valid(visual): return
	_card_visuals[id] = visual
	_disable_mesh_shadows(visual)
	visual.visibility_changed.connect(_sync_card_visibility.bind(id))
	visual.tree_entered.connect(_sync_card_visibility.bind(id))
	visual.tree_exiting.connect(_visual_exiting.bind(id))
	visual.child_entered_tree.connect(_visual_child_entered)

func _untrack_visual(id: int) -> void:
	var visual = _card_visuals.get(id)
	if is_instance_valid(visual):
		visual.visibility_changed.disconnect(_sync_card_visibility.bind(id))
		visual.tree_entered.disconnect(_sync_card_visibility.bind(id))
		visual.tree_exiting.disconnect(_visual_exiting.bind(id))
		visual.child_entered_tree.disconnect(_visual_child_entered)
	_card_visuals.erase(id)

func _card_child_entered(child: Node, id: int) -> void:
	_track_visual(id)
	_visual_child_entered(child)
	_sync_card_visibility(id)

func _visual_child_entered(child: Node) -> void:
	_disable_mesh_shadows(child)
	# Deferred printed faces add their nested mesh children after attaching the
	# container. Finish this one new subtree once construction has completed.
	_finish_new_subtree.call_deferred(weakref(child))

func _finish_new_subtree(reference: WeakRef) -> void:
	var node: Node = reference.get_ref()
	if is_instance_valid(node): _disable_mesh_shadows(node)

func _sync_card_visibility(id: int) -> void:
	var card: CardEntity = _prepared_cards.get(id)
	if is_instance_valid(card) and card.is_visible_in_tree() \
			and (card._visual == null or card._visual.is_visible_in_tree()):
		if not _visible_cards.has(id): _visible_order_dirty = true
		_visible_cards[id] = card
	else:
		_hide_card(id)

func _hide_card(id: int) -> void:
	if _visible_cards.erase(id): _visible_order_dirty = true

func _visual_exiting(id: int) -> void:
	_hide_card(id)

func _card_exiting(id: int) -> void:
	_hide_card(id)
	# Reparenting may leave/re-enter the tree without changing registration.
	# Keep those subscriptions; discard objects that actually got freed.
	_forget_freed_card.call_deferred(id)

func _forget_freed_card(id: int) -> void:
	if _prepared_cards.has(id) and not is_instance_valid(_prepared_cards[id]):
		_forget_card(id)

func _disconnect_board() -> void:
	if is_instance_valid(_board):
		_board.card_registered.disconnect(_register_card)
		_board.card_unregistered.disconnect(_unregister_card)
	for id in _prepared_cards.keys(): _forget_card(id)
	_next_order = 0
	_board = null

func _exit_tree() -> void:
	_disconnect_board()

func _process(_delta: float) -> void:
	refresh()

## Rebuilding a paused table must replace its old GPU shadows before the
## pause is restored; there may be no later process frame for this node.
func refresh() -> void:
	if not is_instance_valid(_board) or _multimesh == null:
		return
	if _visible_order_dirty:
		_visible_order = _visible_cards.values()
		# Preserve board registration order, even after an older sheet is
		# revealed again. Sorting happens only when candidate membership changes.
		_visible_order.sort_custom(func(a: CardEntity, b: CardEntity) -> bool:
			return int(_registration_order[a.get_instance_id()]) < int(_registration_order[b.get_instance_id()]))
		_visible_order_dirty = false
	var positions := _contact_positions(_visible_order)
	if positions == _last_positions:
		return
	_last_positions = positions
	var data := _build_contacts(positions)
	if data == _last_data:
		return
	_last_data = data
	if data.size() > _capacity:
		_capacity = maxi(16, _capacity)
		while _capacity < data.size():
			_capacity *= 2
		_multimesh.instance_count = _capacity
	_multimesh.visible_instance_count = data.size()
	for i in data.size():
		var contact: Dictionary = data[i]
		var extent: Vector2 = contact["size"]
		var basis := Basis.IDENTITY.scaled(Vector3(extent.x, 1.0, extent.y))
		_multimesh.set_instance_transform(i, Transform3D(basis, contact["center"]))
		_multimesh.set_instance_custom_data(i,
			Color(extent.x, extent.y, contact["softness"], contact["opacity"]))

func _build_contacts(positions: PackedVector3Array) -> Array:
	return _positions_footprints(positions)
