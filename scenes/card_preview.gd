# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Control

## 将正式 CardEntity 放入独立小视口；卡面、插画和悬停动作均由正式实体绘制。
## adapter 只负责取景和 UI 事件，不注册到对局 Board，也不操作原桌镜头。
const TableScene = preload("res://scenes/table_scene.gd")

var def_id := ""
var card: CardEntity
var camera: Camera3D
var viewport: SubViewport
var _presentation: Node
var _container: SubViewportContainer
var _hovered := false
var _render_frames := 0
var _render_remaining := 0.0


func configure(id: String, presentation: Node = null) -> void:
	def_id = id
	_presentation = presentation
	name = "CardPreview_" + id
	set_meta("def_id", id)
	accessibility_name = CardDB.card_name(id)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 独立使用时仍调用正式 Board 文案；抽屉里由同一张详情面板承接。
	if not is_instance_valid(_presentation) or not _presentation.has_method("show_preview_card_detail"):
		var descriptions := Board.new()
		tooltip_text = descriptions.hover_desc_text(id)
		descriptions.free()
	if is_inside_tree():
		_build()


func _ready() -> void:
	resized.connect(_fit)
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	visibility_changed.connect(_visibility_changed)
	if not def_id.is_empty():
		_build()


func _build() -> void:
	if is_instance_valid(viewport):
		return
	_container = SubViewportContainer.new()
	_container.name = "RealCardViewport"
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)
	_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport = SubViewport.new()
	viewport.name = "CardWorld"
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.physics_object_picking = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_container.add_child(viewport)
	var stage := Node3D.new()
	stage.name = "CardStage"
	viewport.add_child(stage)
	var table := TableScene.new(stage, true)
	table._setup_environment()
	camera = table.camera
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.position = Vector3(0, 8, 0)
	camera.rotation_degrees = Vector3(-90, 0, 0)
	camera.current = true
	card = CardEntity.new()
	card.name = "RealCard"
	card.setup(-1, def_id)
	card.freeze = true
	card.draggable = false
	card.collision_layer = 0
	card.collision_mask = 0
	stage.add_child(card)
	_fit()
	_fit.call_deferred()


func _fit() -> void:
	if not is_instance_valid(camera) or size.x <= 0 or size.y <= 0:
		return
	var aspect := size.x / size.y
	camera.size = maxf(CardEntity.CARD_SIZE.z, CardEntity.CARD_SIZE.x / aspect) * 1.08
	_request_render()


func _request_render() -> void:
	# 首帧末才完成的文字网格以及悬停淡出需要少量后续帧；静止时停止小视口渲染。
	_render_frames = 2
	_render_remaining = 0.2
	set_process(true)
	if is_instance_valid(viewport):
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _set_hovered(value: bool) -> void:
	if _hovered == value:
		return
	_hovered = value
	if is_instance_valid(card) and card.is_inside_tree():
		card.set_hover_visual(value, false)
	_request_render()
	if not value:
		_hide_detail()
	else:
		_show_detail()


func _show_detail() -> void:
	if is_instance_valid(_presentation) and _presentation.has_method("show_preview_card_detail") and is_instance_valid(card):
		_presentation.show_preview_card_detail(card, get_global_mouse_position(), self)


func _hide_detail() -> void:
	if is_instance_valid(_presentation) and _presentation.has_method("hide_preview_card_detail"):
		_presentation.hide_preview_card_detail(self)


func _visibility_changed() -> void:
	if not is_visible_in_tree():
		_set_hovered(false)
	else:
		_request_render()


func _process(delta: float) -> void:
	if not is_instance_valid(viewport):
		return
	if _hovered:
		var inside := is_visible_in_tree() and get_global_rect().has_point(get_global_mouse_position())
		if inside and is_instance_valid(_presentation) and _presentation.has_method("_preview_contains_pointer"):
			inside = _presentation._preview_contains_pointer(self, get_global_mouse_position())
		if not inside:
			_set_hovered(false)
		else:
			_show_detail()
	if _hovered:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif _render_frames > 0 or _render_remaining > 0.0:
		_render_frames = maxi(0, _render_frames - 1)
		_render_remaining = maxf(0.0, _render_remaining - delta)
	else:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		set_process(false)


func _exit_tree() -> void:
	_hide_detail()
