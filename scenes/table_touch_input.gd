# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

## Godot 将单指触摸转换为鼠标事件，拖拽/合并/购买仍由 Board 原入口处理。
## 这里仅补充无悬停设备的长按查看、触摸取消与后台中断。
const HOLD_SECONDS := 0.5
var host: Node
var finger := -1
var start := Vector2.ZERO
var current := Vector2.ZERO
var age := 0.0
var holding := false
var inspecting := false
var picked: CardEntity
var facility := false
var points := {}
var _view_active := false
var _view_pair: Array = []
var _view_distance := 0.0
var _view_center := Vector2.ZERO

func bind(main: Node) -> void:
	host = main
	name = "TableTouchInput"

func _input(event: InputEvent) -> void:
	if host == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			points[event.index] = event.position
		else:
			points.erase(event.index)
		if _view_active:
			if points.is_empty():
				_view_active = false
				host.board.view_gesture = false
				finger = -1
			return
		# 正在单指拖牌时，第二指仍保持原语义；双指查看从桌面空白发起。
		if points.size() == 2 and host.board._drag_cards.is_empty():
			var pane: Node = host.drawer_presentation
			if points.values().all(func(p): return pane.content_rect().has_point(p) and not pane.pointer_over_panels(p)):
				_view_pair = points.keys().slice(0, 2)
				_view_distance = points[_view_pair[0]].distance_to(points[_view_pair[1]])
				_view_center = (points[_view_pair[0]] + points[_view_pair[1]]) * 0.5
				_view_active = true
				host.board.view_gesture = true
				holding = false
				host.board._reset_click_track()
				return
		if event.pressed and finger < 0:
			finger = event.index
			start = event.position
			current = start
			age = 0.0
			inspecting = false
			holding = not host.drawer_presentation.pointer_over_panels(start) and not host.board.attack_mode
			picked = host.board._pick_card(start) if holding else null
			facility = holding and host.facility_contains_pointer(start)
		elif event.index == finger and not event.pressed:
			if event.canceled:
				host.board.cancel_pointer()
			finger = -1
			holding = false
	elif event is InputEventScreenDrag:
		if points.has(event.index):
			points[event.index] = event.position
		if _view_active:
			if _view_pair.all(func(id): return points.has(id)):
				var distance: float = points[_view_pair[0]].distance_to(points[_view_pair[1]])
				var center: Vector2 = (points[_view_pair[0]] + points[_view_pair[1]]) * 0.5
				var pane: Node = host.drawer_presentation
				pane.move_table_view(pane.camera_view.zoom * distance / maxf(_view_distance, 1.0), _view_center, center)
				_view_distance = distance
				_view_center = center
			return
		if event.index != finger:
			return
		current = event.position
		if current.distance_to(start) > host.board.CLICK_SLOP:
			holding = false
			host.drawer_presentation._detail.hide()
	elif event is InputEventMouseButton and event.pressed:
		# 新一击收起上次长按的说明，不吞掉这次操作。
		host.drawer_presentation._detail.hide()

func _process(delta: float) -> void:
	if host == null or not holding or inspecting or finger < 0:
		return
	age += delta
	if age < HOLD_SECONDS:
		return
	holding = false
	if not is_instance_valid(picked) and not facility:
		return
	inspecting = true
	host.board.cancel_pointer()
	# 说明放在手指上方，松手后保留到下一次点击。
	var point := current - Vector2(0, host.drawer_presentation._px(160))
	if is_instance_valid(picked):
		host.drawer_presentation.show_card_detail(picked, point)
	else:
		host.drawer_presentation.show_facility_detail(point)

func _notification(what: int) -> void:
	if host != null and what == NOTIFICATION_APPLICATION_PAUSED:
		finger = -1
		holding = false
		inspecting = false
		_view_active = false
		points.clear()
		host.board.view_gesture = false
