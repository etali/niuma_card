# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends MeshInstance3D

## 桌面分区/卡槽是无碰撞的绘制层。尺寸使用牌桌坐标，缩窗和透视都与卡牌一起投影。
## 位图可替换默认画法；没有位图时仍有圆角分区和空槽，不依赖额外素材包。


const SURFACE_SHADER := preload("res://shaders/table_surface.gdshader")
var _role := "zone"
var _surface_material: ShaderMaterial
var _owner := ""
var _board: Board
var _feedback := 0.0
var _feedback_target := 0.0

func configure(extent: Vector2, role: String, artwork: Texture2D = null) -> void:
	_role = role
	name = "TableSurface_" + role
	var plane := PlaneMesh.new()
	plane.size = extent
	if role in ["zone", "market"]:
		plane.subdivide_width = clampi(ceili(extent.x * 9.0), 16, 192)
	mesh = plane
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface_material = ShaderMaterial.new()
	_surface_material.shader = SURFACE_SHADER
	# 从桌布到分区、空槽、接触阴影(-32)，最后才是牌面，透明绘制顺序固定。
	_surface_material.render_priority = -16 if role == "price" else (-48 if role in ["slot", "divider"] else (-60 if role == "market" else -64))
	_surface_material.set_shader_parameter("extent", extent)
	_surface_material.set_shader_parameter("radius", minf(0.055, extent.x * 0.2) if role in ["price", "divider"] else (0.12 if role == "slot" else 0.24))
	_surface_material.set_shader_parameter("fold_size", 0.12 if role == "price" else 0.43)
	_surface_material.set_shader_parameter("dashed", role == "slot")
	_surface_material.set_shader_parameter("folded", role in ["zone", "market"])
	_surface_material.set_shader_parameter("hanging_tag", role == "price")
	if role == "price":
		_surface_material.set_shader_parameter("stroke", CardArt.FRAME_BORDER * 0.4)
	_surface_material.set_shader_parameter("use_artwork", artwork != null)
	if artwork:
		_surface_material.set_shader_parameter("artwork", artwork)
	material_override = _surface_material
	refresh_palette()

func _ready() -> void:
	Palette.bus().changed.connect(_on_palette_changed)

func _on_palette_changed(_section: String, _key: String) -> void:
	refresh_palette()

func refresh_palette() -> void:
	if _surface_material == null:
		return
	var table := Palette.get_color("world", "table_felt")
	var paper := Palette.get_color("world", "table_frame")
	var ink := Palette.get_color("card", "frame")
	# 双方牌区要看得见边界，但不能压过卡牌；市场带保持同级而非独占焦点。
	var fill := table.lerp(paper, 0.32)
	var edge := fill.lerp(ink, 0.38)
	if _role == "market":
		fill = table.lerp(paper, 0.70)
		edge = fill.lerp(Palette.get_color("world", "market_floor"), 0.40)
	elif _role == "slot":
		fill = Color(ink, 0.07)
		edge = Color(ink, 0.22)
	elif _role == "price":
		fill = paper
		edge = ink
	elif _role == "divider":
		fill = Color(ink, 0.25)
		edge = Color(ink, 0.25)
	_surface_material.set_shader_parameter("feedback_color", Palette.semantic("success"))
	_surface_material.set_shader_parameter("fill_color", fill)
	_surface_material.set_shader_parameter("edge_color", edge)

func set_zone_owner(owner: String) -> void:
	_owner = owner
	refresh_palette()

func bind_board(board: Board) -> void:
	_board = board

func set_feedback(on: bool) -> void:
	_feedback_target = 1.0 if on else 0.0

func _process(delta: float) -> void:
	if _role == "zone" and _owner == "player" and is_instance_valid(_board):
		var valid := false
		if not _board.input_locked and not _board.attack_mode and not _board._drag_cards.is_empty() and is_instance_valid(_board._drag_cards[0]):
			var at: Vector3 = _board._drag_cards[0].global_position
			var bounds := _board.player_bounds
			valid = bounds.has_point(Vector2(at.x, at.z)) if Board.has_table_bounds(bounds) else at.z >= _board.player_min_z and at.z <= _board.player_max_z
		set_feedback(valid)
	_feedback = lerpf(_feedback, _feedback_target, 1.0 - exp(-18.0 * delta))
	if _surface_material:
		_surface_material.set_shader_parameter("feedback", _feedback)

func set_shift_roll(amount: float) -> void:
	_surface_material.set_shader_parameter("roll", amount)
