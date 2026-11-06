# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Control
## A transparent projection of the source cards, fanned vertically beside the
## stack. Looking never splits the logical group; only a drag transfers UIDs.
signal extract_requested(ids: Array, screen_position: Vector2)
signal closed()

const PreviewCard = preload("res://scenes/work_animation_preview_card.gd")

var settings: Dictionary
var group_id := -1
var kind := ""
var records: Array = []
var rendered_indices: Array[int] = []
var preview_cards: Array[WorkCard] = []
var _spare_cards: Array[WorkCard] = []
var focus_index := -1
var _definitions: Dictionary
var _texture: TextureRect
var _viewport: SubViewport
var _scene: Node3D
var _camera: Camera3D
var _anchor := Vector2.ZERO
var _source_rect := Rect2()
var _table_rect := Rect2()
var _view_rect := Rect2()
var _card_rects: Dictionary = {}
var _centers: Dictionary = {}
var _targets: Dictionary = {}
var _last_viewport_size := Vector2.ZERO
var _pressed := false
var _press_at := Vector2.ZERO
var _press_ids: Array = []
var _last_pointer := Vector2.INF
var _elapsed := 0.0
var _card_size := Vector2.ZERO
var _pixels_per_unit := 1.0
var _span := 0.0
var _column_x := 0.0
var _top_y := 0.0
var _direction := 1.0

func configure(spec: Dictionary) -> void:
	settings = spec.duplicate(true)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _texture == null: _build()
	hide()
	set_process(false)

func is_open() -> bool:
	return visible and not records.is_empty()

func show_cards(source_group: int, card_kind: String, source_records: Array, definitions: Dictionary, anchor_screen: Vector2, source_screen_rect := Rect2(), table_screen_rect := Rect2()) -> void:
	if kind != card_kind:
		for card in preview_cards + _spare_cards: card.free()
		preview_cards.clear()
		_spare_cards.clear()
	group_id = source_group
	kind = card_kind
	_definitions = definitions
	_anchor = anchor_screen
	_source_rect = source_screen_rect
	_table_rect = table_screen_rect
	_pressed = false
	_press_ids.clear()
	focus_index = -1
	_last_pointer = Vector2.INF
	_elapsed = 0.0
	_centers.clear()
	records = _matching_records(source_records)
	if records.is_empty():
		close_view()
		return
	show()
	set_process(true)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_layout_column()
	_rebuild_fan()
	_place_faces(0.0)

func update_cards(source_records: Array) -> void:
	if not is_open(): return
	var next := _matching_records(source_records)
	if next.is_empty():
		close_view()
		return
	var previous_ids := records.map(func(data): return int(data.id))
	var next_ids := next.map(func(data): return int(data.id))
	var held_uid := int(records[focus_index].id) if focus_index >= 0 and focus_index < records.size() else -1
	records = next
	if _pressed:
		_press_ids = _press_ids.filter(func(id): return next_ids.has(id))
		if _press_ids.is_empty(): _pressed = false
	if previous_ids != next_ids:
		focus_index = next_ids.find(held_uid)
		_layout_column()
		_rebuild_fan()
	else:
		for index in preview_cards.size():
			preview_cards[index].update_record(records[rendered_indices[index]])
			_hide_non_face_layers(preview_cards[index])

func close_view() -> void:
	var was_open := visible
	hide()
	set_process(false)
	_pressed = false
	_press_ids.clear()
	if _viewport != null: _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for card in preview_cards: card.set_process(false)
	if was_open: closed.emit()

func contains_screen_point(point: Vector2) -> bool:
	if not is_open(): return false
	# Transparent space between the source and the fanned cards is not a panel.
	if _view_rect.has_point(point): return true
	for rect in _card_rects.values():
		if rect.has_point(point): return true
	return false

func index_at_screen_point(point: Vector2) -> int:
	if not is_open(): return -1
	if records.size() <= int(settings.max_render_cards):
		for index in range(records.size() - 1, -1, -1):
			if _card_rects.has(index) and _card_rects[index].has_point(point): return index
		return -1
	# Use the full logical column, not the sampled drawings, for large stacks.
	# This axis stays fixed while nearby faces part, so a stationary pointer
	# cannot chase moving cards or change the cut by itself.
	if not _view_rect.has_point(point): return -1
	var fraction := clampf((point.y - _top_y) / maxf(_span, 0.001), 0.0, 1.0)
	return clampi(roundi(fraction * float(records.size() - 1)), 0, records.size() - 1)

func screen_point_for_index(index: int) -> Vector2:
	index = clampi(index, 0, maxi(0, records.size() - 1))
	if records.size() > int(settings.max_render_cards):
		return Vector2(_column_x, _top_y + _base_offset(index))
	var rect: Rect2 = _card_rects.get(index, Rect2())
	var exposed := rect.size.y
	if _card_rects.has(index + 1):
		exposed = maxf(1.0, (_card_rects[index + 1] as Rect2).position.y - rect.position.y)
	return rect.position + Vector2(rect.size.x * 0.5, minf(rect.size.y, exposed) * 0.5)

func handle_pointer_event(event: InputEvent) -> bool:
	if not is_open(): return false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_view()
		return true
	if event is InputEventMouseMotion:
		_last_pointer = event.position
		if _pressed and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_pressed = false
			_press_ids.clear()
		if _pressed:
			if event.position.distance_to(_press_at) >= float(settings.drag_threshold):
				var ids := _press_ids.duplicate()
				close_view()
				if not ids.is_empty(): extract_requested.emit(ids, event.position)
			return true
		_set_focus(index_at_screen_point(event.position))
		return contains_screen_point(event.position)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if not contains_screen_point(event.position):
					close_view()
					return true
				var index := index_at_screen_point(event.position)
				if index >= 0:
					_set_focus(index)
					_pressed = true
					_press_at = event.position
					_press_ids = records.slice(index).map(func(data): return int(data.id))
				return true
			_pressed = false
			_press_ids.clear()
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed: close_view()
			return true
		return contains_screen_point(event.position)
	return false

func _matching_records(source: Array) -> Array:
	var out: Array = []
	for data in source:
		if data is Dictionary and str(data.get("type", "")) == kind and int(data.get("group", -1)) == group_id:
			out.append(data.duplicate(true))
	return out

func _build() -> void:
	_texture = TextureRect.new()
	_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_texture)
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_texture.texture = _viewport.get_texture()
	_scene = Node3D.new()
	_viewport.add_child(_scene)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.position.y = float(settings.camera_height)
	_camera.rotation_degrees.x = -90.0
	_scene.add_child(_camera)
	_camera.make_current()

func _layout_column() -> void:
	var screen := get_viewport().get_visible_rect().size
	_last_viewport_size = screen
	var margin := float(settings.screen_margin)
	var top := minf(float(settings.top_margin), screen.y * float(settings.edge_margin_fraction))
	var bottom := minf(float(settings.bottom_margin), screen.y * float(settings.edge_margin_fraction))
	if _table_rect.has_area():
		top = maxf(top, _table_rect.position.y)
		bottom = maxf(bottom, screen.y - _table_rect.end.y)
	var height := float(settings.card_height)
	if _source_rect.has_area(): height = clampf(_source_rect.size.y * float(settings.source_size_ratio), float(settings.min_card_height), float(settings.max_card_height))
	height = minf(height, (screen.y - top - bottom) * float(settings.max_card_height_fraction))
	_card_size = Vector2(height * CardEntity.CARD_SIZE.x / CardEntity.CARD_SIZE.z, height)
	_pixels_per_unit = height / CardEntity.CARD_SIZE.z
	var max_height := minf(float(settings.max_height), minf(screen.y * float(settings.height_fraction), screen.y - top - bottom))
	_span = minf(float(maxi(records.size() - 1, 0)) * height * float(settings.card_step_ratio), maxf(0.0, max_height - height - float(settings.cut_gap)))
	var column_height := _span + height + float(settings.cut_gap)
	var extra_x := float(settings.cut_shift)
	var gap := height * float(settings.anchor_gap_ratio)
	var left := _anchor.x + gap
	_direction = 1.0
	if left + _card_size.x + extra_x > screen.x - margin:
		left = (_source_rect.position.x if _source_rect.has_area() else _anchor.x) - gap - _card_size.x
		_direction = -1.0
	left = clampf(left, margin + extra_x, maxf(margin + extra_x, screen.x - margin - _card_size.x - extra_x))
	var start := _source_rect.position.y if _source_rect.has_area() else _anchor.y - height * 0.5
	start = clampf(start, top, maxf(top, screen.y - bottom - column_height))
	_column_x = left + _card_size.x * 0.5
	_top_y = start + float(settings.cut_gap)
	_view_rect = Rect2(Vector2(left - extra_x, start), Vector2(_card_size.x + extra_x * 2.0, column_height))
	# The texture includes the flight from the actual source, while every pixel
	# outside card faces stays transparent. It is not an interactive backdrop.
	var source := _source_rect if _source_rect.has_area() else Rect2(_anchor - _card_size * 0.5, _card_size)
	var render_rect := _view_rect.merge(source).grow(float(settings.render_padding))
	render_rect = render_rect.intersection(Rect2(Vector2.ZERO, screen))
	position = render_rect.position
	size = render_rect.size
	_texture.position = Vector2.ZERO
	_texture.size = size
	_viewport.size = Vector2i(size * float(settings.render_scale))
	_camera.size = size.y / _pixels_per_unit

func _set_focus(index: int) -> void:
	if index == focus_index: return
	focus_index = index
	_rebuild_fan()

func _sample_indices() -> Array[int]:
	var out: Array[int] = []
	var maximum := maxi(1, int(settings.max_render_cards))
	if records.size() <= maximum:
		for index in records.size(): out.append(index)
		return out
	var chosen := {0: true, records.size() - 1: true}
	# A dense stack is evenly spaced until the pointer asks for a local cut.
	if focus_index >= 0:
		var radius := int(settings.local_radius)
		for index in range(maxi(0, focus_index - radius), mini(records.size(), focus_index + radius + 1)):
			chosen[index] = true
	var remaining := maxi(0, maximum - chosen.size())
	for sample in remaining:
		chosen[roundi(float(sample + 1) / float(remaining + 1) * float(records.size() - 1))] = true
	for index in chosen: out.append(int(index))
	out.sort()
	return out

func _fan_span() -> float:
	return _span / _pixels_per_unit

func _base_offset(index: int) -> float:
	return _span * float(index) / float(maxi(records.size() - 1, 1))

func _position_for_index(index: int) -> float:
	if records.size() <= int(settings.max_render_cards) or focus_index < 0: return _base_offset(index)
	var radius := int(settings.local_radius)
	var start := maxi(0, focus_index - radius)
	var end := mini(records.size() - 1, focus_index + radius)
	var gap := minf(_card_size.y * float(settings.local_step_ratio), _span / float(maxi(end - start, 1)))
	var center := _base_offset(focus_index)
	var first := clampf(center - float(focus_index - start) * gap, 0.0, _span - float(end - start) * gap)
	var last := first + float(end - start) * gap
	if index < start: return lerpf(0.0, first, float(index) / float(maxi(start, 1)))
	if index > end: return lerpf(last, _span, float(index - end) / float(maxi(records.size() - 1 - end, 1)))
	return first + float(index - start) * gap

func _target_for_index(index: int) -> Vector2:
	var at := Vector2(_column_x, _top_y + _card_size.y * 0.5 + _position_for_index(index))
	if focus_index >= 0:
		if index >= focus_index: at.x += float(settings.cut_shift) * _direction
		else: at.y -= float(settings.cut_gap)
	return at

func _rebuild_fan() -> void:
	if not is_open(): return
	var indices := _sample_indices()
	var wanted := {}
	for index in indices: wanted[int(records[index].id)] = true
	var by_id: Dictionary = {}
	for card in preview_cards:
		if wanted.has(card.uid): by_id[card.uid] = card
		else:
			card.hide()
			card.set_process(false)
			_spare_cards.append(card)
			_centers.erase(card.uid)
	var next_cards: Array[WorkCard] = []
	_targets.clear()
	for index in indices:
		var uid := int(records[index].id)
		var card: WorkCard = by_id.get(uid)
		if card == null and not _spare_cards.is_empty(): card = _spare_cards.pop_back()
		if card == null:
			card = PreviewCard.new()
			_scene.add_child(card)
			card.configure(records[index], _definitions.get(kind, _definitions))
			card.freeze = true
			card.collision_layer = 0
			card.collision_mask = 0
			card.input_ray_pickable = false
		else:
			card.update_record(records[index])
		card.uid = uid
		card.show()
		next_cards.append(card)
		_targets[uid] = _target_for_index(index)
		if not _centers.has(uid):
			_centers[uid] = _source_rect.get_center() if _elapsed == 0.0 and _source_rect.has_area() else (_anchor if _elapsed == 0.0 else Vector2(_column_x, _top_y + _card_size.y * 0.5 + _base_offset(index)))
		_hide_non_face_layers(card)
		card.set_process(true)
	preview_cards = next_cards
	rendered_indices = indices
	_place_faces(0.0)

func _place_faces(delta: float) -> void:
	_card_rects.clear()
	var origin := _source_rect.get_center() if _source_rect.has_area() else _anchor
	var smooth := 1.0 - exp(-float(settings.hover_response) * delta)
	for order in preview_cards.size():
		var card := preview_cards[order]
		var index := rendered_indices[order]
		var delay := float(settings.stagger_seconds) * float(order) / float(maxi(preview_cards.size() - 1, 1))
		var duration := float(settings.open_seconds)
		if _elapsed < duration + delay:
			var t := clampf((_elapsed - delay) / duration, 0.0, 1.0)
			var eased := 1.0 - pow(1.0 - t, float(settings.ease_power))
			_centers[card.uid] = origin.lerp(_targets[card.uid], eased)
		elif delta > 0.0:
			_centers[card.uid] = (_centers[card.uid] as Vector2).lerp(_targets[card.uid], smooth)
		var center: Vector2 = _centers[card.uid]
		var world := (center - get_global_rect().get_center()) / _pixels_per_unit
		card.position = Vector3(world.x, float(settings.face_layer_gap) * float(order), world.y)
		_card_rects[index] = Rect2(center - _card_size * 0.5, _card_size)

func _hide_non_face_layers(card: WorkCard) -> void:
	card.card_mesh.hide()
	card._realtime.hide()
	for child in card.find_children("*", "GeometryInstance3D", true, false):
		child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _process(delta: float) -> void:
	if not is_open(): return
	_elapsed += delta
	if get_viewport().get_visible_rect().size != _last_viewport_size:
		_layout_column()
		_rebuild_fan()
	_place_faces(delta)
