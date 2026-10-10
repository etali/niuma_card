# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node3D

## 价签提供纸面命中和交互反馈；购买意图与付款规则仍由 Board 的公共入口交给控制层。
const Surface = preload("res://scenes/table_surface.gd")
const Materials = preload("res://scenes/effect_materials.gd")
const HOLE_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec4 ink : source_color;
uniform vec4 paper : source_color;
uniform float opacity = 1.0;
void fragment() {
	float r = length(UV - vec2(0.5));
	if (r > 0.5) { discard; }
	// 深色孔心、浅色切口与细墨线，保持简笔画的纸张质感。
	vec3 color = mix(ink.rgb, paper.rgb, smoothstep(0.28, 0.33, r));
	color = mix(color, ink.rgb, smoothstep(0.43, 0.48, r));
	ALBEDO = color;
	ALPHA = opacity * (1.0 - smoothstep(0.48, 0.5, r));
}
"""
# 各价签只改自己的材质参数；程序跨售空/补货保留，不逐张重新编译。
static var _hole_shader: Shader
# 在右下角内侧留出纸边，同时避开产出墨团。坐标相对卡牌中心。
const CARD_HOLE := Vector3(0.48, CardEntity.Y_PLATE + 0.004, 0.735)
const CARD_HOLE_RADIUS := 0.026
var text: String:
	get:
		return _label.text if _label else ""
var _label: Label3D
var _paper: MeshInstance3D
var _coin: Sprite3D
var _presentation: Node3D
var _hanging: Node3D
var _hole_material: ShaderMaterial
var _string_material: StandardMaterial3D
var _card: WeakRef
var _board: Board
var _hovered := false
var _presented := false
var _retiring := false
var _price := 0
var _motion: Tween
var _following_drag := false
var _shelf_position := Vector3.ZERO
var _card_offset := Vector3.ZERO

func configure(price: int, card: CardEntity, board: Board) -> void:
	_price = price
	_card = weakref(card)
	_board = board
	_presentation = Node3D.new()
	add_child(_presentation)
	var hanging := Node3D.new()
	_hanging = hanging
	hanging.position = Vector3(0.80, 0.0, 0.18)
	hanging.rotation_degrees.y = -12
	_presentation.add_child(hanging)
	_paper = Surface.new()
	_paper.configure(Vector2(1.10, 0.64), "price")
	_paper.position.y = -0.004
	hanging.add_child(_paper)
	_coin = Sprite3D.new()
	_coin.texture = CardArt.res_icon_texture(CardDB.RES_CASH)
	_coin.pixel_size = 0.29 / float(_coin.texture.get_width())
	_coin.rotation_degrees.x = -90
	_coin.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	hanging.add_child(_coin)
	_label = Label3D.new()
	_label.text = str(price)
	_label.font = Fonts.zh_bold()
	_label.font_size = CardEntity._raster()
	_label.pixel_size = 0.0042
	_label.outline_size = 0
	_label.rotation_degrees.x = -90
	hanging.add_child(_label)
	_queue_layout_price.call_deferred()
	_add_string()
	refresh_palette()
	Palette.bus().changed.connect(_on_palette)

## 直接投影实际纸面的四角，不加不可见碰撞体或屏幕固定尺寸的点击区。
func hit_test(screen_pos: Vector2, camera: Camera3D) -> bool:
	if _retiring or not is_inside_tree() or not is_visible_in_tree() \
			or not is_instance_valid(camera) or not is_instance_valid(_paper) or not _paper.is_visible_in_tree():
		return false
	var bounds := _paper.get_aabb()
	var polygon := PackedVector2Array()
	for local in [Vector3(bounds.position.x, 0.0, bounds.position.z),
			Vector3(bounds.end.x, 0.0, bounds.position.z),
			Vector3(bounds.end.x, 0.0, bounds.end.z),
			Vector3(bounds.position.x, 0.0, bounds.end.z)]:
		var world: Vector3 = _paper.to_global(local)
		if camera.is_position_behind(world):
			return false
		polygon.append(camera.unproject_position(world))
	return Geometry2D.is_point_in_polygon(screen_pos, polygon)

func sync_card_position() -> void:
	if _retiring:
		return
	var card := _card.get_ref() as CardEntity if _card else null
	if not is_instance_valid(card):
		return
	if card.dragging:
		if not _following_drag:
			# 每次拖动才记真实货架位置；窗口重排后沿用新位置，点击价签不搬动纸签。
			_shelf_position = global_position
			var origin: Vector3 = _board._press_snap.get("pos", card.global_position) \
				if is_instance_valid(_board) else card.global_position
			_card_offset = _shelf_position - origin
			_following_drag = true
		global_position = card.global_position + _card_offset
	elif _following_drag:
		global_position = _shelf_position
		_following_drag = false

func _queue_layout_price() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	# Label3D下一帧才有墨迹尺寸。使用节点方法连接，销毁时自动断开；
	# await会保留函数栈，价签提前释放后连函数内的有效性守卫也无法执行。
	get_tree().process_frame.connect(_layout_price, CONNECT_ONE_SHOT)

func _layout_price() -> void:
	# 将金币和实际数字墨迹作为一整行排版；整组在圆孔右侧的长方形牌身内居中。
	if not is_inside_tree() or is_queued_for_deletion() or not is_instance_valid(_label):
		return
	var bounds := _label.get_aabb()
	var coin_width := 0.29
	var gap := 0.030
	var factor := minf(0.37 / maxf(bounds.size.y, 0.001),
		(0.60 - coin_width - gap) / maxf(bounds.size.x, 0.001))
	_label.pixel_size *= factor
	var number_width := bounds.size.x * factor
	var row_width := coin_width + gap + number_width
	var row_left := 0.10 - row_width * 0.5
	_coin.position = Vector3(row_left + coin_width * 0.5, 0.006, 0.0)
	_label.position = Vector3(row_left + coin_width + gap - bounds.position.x * factor,
		0.008, 0.0 + (bounds.position.y + bounds.size.y * 0.5) * factor)

func _on_palette(_section: String, _key: String) -> void:
	refresh_palette()

func refresh_palette() -> void:
	if _hole_material:
		_hole_material.set_shader_parameter("ink", Palette.get_color("card", "frame"))
		var card := _card.get_ref() as CardEntity
		if is_instance_valid(card):
			_hole_material.set_shader_parameter("paper", CardArt.face_color(card.def_id))
	if _label:
		_label.modulate = Palette.get_color("card", "frame")
	if _string_material:
		_string_material.albedo_color = Palette.get_color("card", "frame")

func _add_string() -> void:
	# 价签根节点比卡牌高 0.15、向下偏移 1.0；绳端落在卡面穿孔中。
	var corner := CARD_HOLE - Vector3(0.0, 0.15, 1.0)
	var hole: Vector3 = _hanging.transform * Vector3(-1.10 * 0.5 + 0.055 + 0.17, 0.018, 0.0)
	var rope := ImmediateMesh.new()
	# 两股细绳穿过卡面孔与吊牌孔，向纸边外绕行，避开墨团。
	_add_rope_curve(rope, corner, Vector3(0.72, -0.07, -0.08), Vector3(0.64, 0.018, 0.09), hole)
	_add_rope_curve(rope, hole, Vector3(0.37, 0.018, 0.04), Vector3(0.43, -0.07, -0.14), corner)
	var thread := MeshInstance3D.new()
	thread.name = "TagString"
	thread.mesh = rope
	thread.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_string_material = Materials.flat(Palette.get_color("card", "frame"), true)
	thread.material_override = _string_material
	_presentation.add_child(thread)
	# 细纸边与内凹阴影表现穿孔，绳端穿进孔心，替代角上的实心绳结。
	var eyelet := MeshInstance3D.new()
	eyelet.name = "CardStringHole"
	var disc := QuadMesh.new()
	disc.size = Vector2.ONE * CARD_HOLE_RADIUS * 2.0
	eyelet.mesh = disc
	eyelet.rotation_degrees.x = -90
	eyelet.position = corner - Vector3(0.0, 0.001, 0.0)
	if _hole_shader == null:
		_hole_shader = Shader.new()
		_hole_shader.code = HOLE_SHADER
	_hole_material = ShaderMaterial.new()
	_hole_material.shader = _hole_shader
	eyelet.material_override = _hole_material
	eyelet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_presentation.add_child(eyelet)

func _add_rope_curve(mesh: ImmediateMesh, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in 25:
		var t := float(i) / 24.0
		var q := 1.0 - t
		var point := p0 * q * q * q + p1 * 3.0 * q * q * t + p2 * 3.0 * q * t * t + p3 * t * t * t
		var tangent := (p1 - p0) * q * q + (p2 - p1) * 2.0 * q * t + (p3 - p2) * t * t
		var normal := Vector3(-tangent.z, 0.0, tangent.x).normalized() * 0.010
		mesh.surface_add_vertex(point + normal)
		mesh.surface_add_vertex(point - normal)
	mesh.surface_end()

func set_hovered(on: bool) -> void:
	_hovered = on
	_update_hover(on)

func _update_hover(on: bool) -> void:
	if _retiring or _presented == on:
		return
	_presented = on
	if _motion and _motion.is_valid():
		_motion.kill()
	_motion = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_motion.tween_property(_presentation, "position:y", CardEntity.HOVER_LIFT if on else 0.0, 0.12)

func _process(_delta: float) -> void:
	if _retiring:
		return
	var valid := false
	var card := _card.get_ref() as CardEntity if _card else null
	if is_instance_valid(card) and is_instance_valid(_board) and not _board.input_locked and not _board._drag_cards.is_empty() and is_instance_valid(_board._drag_cards[0]):
		valid = _board._market_card_near(_board._drag_cards[0].global_position) == card \
			and _board._drag_cards.size() >= _price \
			and _board._drag_cards.all(func(c): return is_instance_valid(c) and c.def_id == CardDB.RES_CASH)
	_paper.set_feedback(valid)
	_update_hover(_hovered or valid)

func retire() -> void:
	if _retiring:
		return
	_retiring = true
	if _motion and _motion.is_valid():
		_motion.kill()
	_motion = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_motion.tween_property(_presentation, "position:y", 0.05, 0.07)
	_motion.tween_property(_presentation, "position:y", 0.0, 0.10)
	_motion.parallel().tween_method(_fade, 1.0, 0.0, 0.10)
	_motion.tween_callback(queue_free)

func _fade(value: float) -> void:
	_hole_material.set_shader_parameter("opacity", value)
	(_paper.material_override as ShaderMaterial).set_shader_parameter("opacity", value)
	_coin.modulate = Color(1, 1, 1, value)
	_label.modulate = Color(Palette.get_color("card", "frame"), value)
	_string_material.albedo_color = Color(Palette.get_color("card", "frame"), value)
