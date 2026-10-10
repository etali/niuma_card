# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Control

## 原牌桌上的一句话带教。实际操作与回滚仍由原 Session / Arena 管理。
const Catalog = preload("res://engine/tutorial_catalog.gd")
const Session = preload("res://engine/tutorial_session.gd")
const Arena = preload("res://scenes/tutorial_arena.gd")
const CLICK_DRAG_THRESHOLD := 12.0

signal exited
signal course_completed(course_id: String)
signal progress_changed(course_id: String, step_index: int, status: String)
signal layout_requested

class SpeechBubble extends PanelContainer:
	var vertical := false
	func _draw() -> void:
		var points: PackedVector2Array
		if vertical:
			points = PackedVector2Array([Vector2(20, 1), Vector2(28, -9), Vector2(37, 1)])
		else:
			var middle := clampf(size.y * 0.6, 12, maxf(12, size.y - 10))
			points = PackedVector2Array([Vector2(1, middle - 7), Vector2(-9, middle), Vector2(1, middle + 7)])
		draw_colored_polygon(points, Palette.plate_color("plate_t3", "face"))
		draw_polyline(points, Palette.get_color("card", "frame"), 1.0, true)

var session: RefCounted
var arena: Node3D
var _presentation: Node
var _goal: Label
var _mascot: TextureRect
var _bubble: SpeechBubble
var _close: Button
var _row: BoxContainer
# 原牌桌行动按钮，不在教程中复制。
var _finish: Button
var _last_step := -1
var _last_progress := ""
var _reported_complete := false
var _closing := false
var _notice := ""
var _awaiting_result := false
var _reference_open := false
var _floating_bounds := Rect2()
var _floating_anchor := Vector2(0.30, 1.0)
var _compact_landscape := false
var _has_dragged := false
var _pressed_control: Control
var _pointer_moved := false
var _pointer_can_tap := false
var _pointer_touch := -1
var _pointer_origin := Vector2.ZERO
var _drag_start_position := Vector2.ZERO
var _line_content: RegEx

func bind(presentation: Node, course_id: String) -> void:
	_presentation = presentation
	name = "TutorialPlayer"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	session = Session.new(course_id)
	_build_dialogue()
	_finish = presentation._main.btn_pass
	arena = Arena.new()
	presentation._main.add_child(arena)
	arena.changed.connect(_refresh)
	arena.operation_finished.connect(_operation_finished)
	arena.configure_on_table(presentation._main, session)
	visibility_changed.connect(_visibility_changed)
	resized.connect(_size_changed)
	presentation._apply_tree_theme(self)
	_refresh()

func _build_dialogue() -> void:
	_row = BoxContainer.new()
	_row.name = "TutorialDialogue"
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_theme_constant_override("separation", 8)
	add_child(_row)
	_mascot = TextureRect.new()
	_mascot.name = "TutorialMascot"
	_mascot.texture = preload("res://assets/art/app_icon.png")
	_mascot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mascot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mascot.set_meta("drawer_min_base", Vector2(64, 76))
	_mascot.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_mascot.size_flags_vertical = Control.SIZE_SHRINK_END
	_mascot.mouse_filter = Control.MOUSE_FILTER_STOP
	_mascot.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_mascot.tooltip_text = Catalog.ui("coach.drag")
	_mascot.gui_input.connect(_on_dialogue_input.bind(_mascot))
	_row.add_child(_mascot)
	_bubble = SpeechBubble.new()
	_bubble.name = "TutorialSpeechBubble"
	_bubble.set_meta("drawer_surface", Palette.plate_color("plate_t3", "face"))
	_bubble.set_meta("drawer_margin_base", 8)
	_bubble.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bubble.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bubble.mouse_filter = Control.MOUSE_FILTER_STOP
	_bubble.gui_input.connect(_on_dialogue_input.bind(_bubble))
	_row.add_child(_bubble)
	var sentence := HBoxContainer.new()
	sentence.add_theme_constant_override("separation", 4)
	sentence.mouse_filter = Control.MOUSE_FILTER_PASS
	_bubble.add_child(sentence)
	_goal = _presentation._label("", 15)
	_goal.name = "TutorialGoal"
	_goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_goal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_goal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_goal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sentence.add_child(_goal)
	_close = _presentation._button(Catalog.ui("coach.close"), 13, true)
	_close.name = "TutorialExit"
	_close.tooltip_text = Catalog.ui("exit")
	_close.accessibility_name = Catalog.ui("exit")
	_close.set_meta("drawer_min_base", Vector2(26, 26))
	_close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_close.pressed.connect(exit_tutorial)
	sentence.add_child(_close)

func _reading_step() -> bool:
	return str(session.current_step().get("kind", "")) in ["intro", "info", "review", "read", "confirm"]

func _final_reading_step() -> bool:
	return _reading_step() and int(session.step_index) == session.course_data.get("steps", []).size() - 1

func _needs_result_confirmation() -> bool:
	# 课末与说明不能被连跳；普通操作可直接接上下一项牌桌动作。
	return _reading_step() or int(session.step_index) == session.course_data.get("steps", []).size() - 1 \
		or session.current_step().get("advance", "confirm") == "confirm"

func _can_tap() -> bool:
	return not _closing and not _reference_open and not arena.operation_pending and (session.completed or _reading_step() or _awaiting_result)

func _base_sentence() -> String:
	if _awaiting_result:
		var step: Dictionary = session.current_step()
		return Catalog.ui("coach.tap_continue", {"goal": step.get("completion_goal", step.get("explanation", ""))})
	if session.completed or _final_reading_step():
		var next_id := Catalog.next_course_id(session.course_id)
		if not next_id.is_empty():
			return Catalog.ui("coach.tap_next_course", {"title": Catalog.course(next_id).get("title", "")})
	if session.completed:
		return Catalog.ui("coach.completed")
	var goal := str(session.current_step().get("goal", ""))
	if _final_reading_step():
		return Catalog.ui("coach.tap_return", {"goal": goal})
	if _reading_step():
		return Catalog.ui("coach.tap_continue", {"goal": goal})
	return goal

func _refresh() -> void:
	if _closing or session == null or _finish == null:
		return
	if _last_step != int(session.step_index):
		_last_step = int(session.step_index)
		_notice = ""
		_awaiting_result = false
		arena.highlight_focus()
	var sentence := _base_sentence()
	if not _notice.is_empty():
		sentence = _notice
	if _goal.text != sentence:
		_goal.text = sentence
	# 展开牌摞时对白不变，但仍要避让牌的落点，不能挡住下一步要拿的牌。
	layout_requested.emit()
	_bubble.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _can_tap() else Control.CURSOR_ARROW
	_mascot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _can_tap() else Control.CURSOR_MOVE
	_finish.text = Catalog.ui("next_round" if session.phase == "review" else ("finish_attack" if session.phase == "attack" else "complete_action"))
	_finish.disabled = _reference_open or session.completed or session.demo_active or arena.operation_pending or _awaiting_result or session.phase not in ["action", "attack", "review"]
	var status := "completed" if session.completed else "started"
	var progress := "%s:%s:%s" % [session.course_id, session.step_index, status]
	if progress != _last_progress:
		_last_progress = progress
		progress_changed.emit(session.course_id, session.step_index, status)
	if session.completed and not _reported_complete:
		_reported_complete = true
		course_completed.emit(session.course_id)

func _operation_finished(result: Dictionary) -> void:
	if _closing:
		return
	_awaiting_result = false
	arena.set_transition_busy(_reference_open)
	if result.get("rolled_back", false) or not result.get("expected", false):
		_notice = str(result.get("reason", ""))
		if _notice.is_empty():
			_notice = Catalog.ui("operation_rollback", {"goal": str(session.current_step().get("goal", ""))})
	else:
		_notice = ""
		if session.step_complete and not session.completed and not _reading_step():
			# 只响应演出结束后的成功操作，不按时间或普通changed刷新推进。
			if not _needs_result_confirmation() and not _reference_open:
				_advance()
				return
			_awaiting_result = true
			arena.set_transition_busy(true)
	_refresh()

func _advance() -> void:
	if _closing or _reference_open or arena.operation_pending:
		return
	if session.completed:
		if not _continue_course(): exit_tutorial()
		return
	var exit_after := _final_reading_step()
	arena.board.cancel_pointer()
	session.preview_groups(arena.current_groups())
	var result: Dictionary = session.acknowledge()
	if not result.get("ok", false): return
	_awaiting_result = false
	if result.get("completed", false):
		# 先记住本课已完成，再换下一课；不释放借用原牌桌的Context或Arena。
		_refresh()
		if _continue_course(): return
	arena.sync_state()
	arena.set_transition_busy(false)
	_refresh()
	if exit_after and result.get("completed", false):
		exit_tutorial()

func _continue_course() -> bool:
	var id := Catalog.next_course_id(session.course_id)
	return _course_begin(id) if not id.is_empty() else false

## 查看课程列表时选课也复用同一教学现场；点当前课继续，内部retry才从头重练。
func switch_course(id: String) -> bool:
	if _closing or Catalog.course(id).is_empty(): return false
	if id == session.course_id and not session.completed: return true
	return _course_begin(id)

func _reset_step_feedback() -> void:
	_awaiting_result = false
	_last_step = -1
	_last_progress = ""
	_reported_complete = false
	_notice = ""
	_reset_pointer()

func _course_begin(id: String) -> bool:
	if Catalog.course(id).is_empty(): return false
	arena.cancel_pending_operation()
	arena.board.cancel_pointer()
	_reset_step_feedback()
	if not session.start(id): return false
	arena.sync_state(true)
	arena.set_transition_busy(_reference_open)
	_refresh()
	return true

## 查阅图鉴/课程时暂停牌桌操作；关闭查看页后保留当前目标或待确认结果。
func set_reference_open(value: bool) -> void:
	if _closing or _reference_open == value: return
	_reference_open = value
	# 查阅时连同付款、飞牌与落地音一起暂停，回来继续看这一手的结果。
	_sync_arena_process()
	_reset_pointer()
	if value: arena.board.cancel_pointer()
	arena.set_transition_busy(value or _awaiting_result)
	_refresh()

## 内部恢复入口，复用原教学状态与原牌桌；不另建教程菜单或按钮。
func retry() -> void:
	arena.cancel_pending_operation()
	arena.board.cancel_pointer()
	_reset_step_feedback()
	session.retry()
	arena.sync_state(true)
	arena.set_transition_busy(_reference_open)
	_refresh()

func exit_tutorial() -> void:
	if _closing:
		return
	_closing = true
	_reset_pointer()
	_awaiting_result = false
	arena.cancel_pending_operation()
	arena.board.cancel_pointer()
	process_mode = Node.PROCESS_MODE_DISABLED
	exited.emit()

func preferred_dock(_available: Vector2) -> String:
	return "bottom"

func _wants_compact(available: Vector2) -> bool:
	var dpi: float = maxf(1.0, _presentation._ui_scale) if _presentation != null else 1.0
	return available.y < 320 * dpi and available.x > available.y * 1.8

func _font_size() -> int:
	return maxi(14, roundi(15 * _presentation._responsive_factor()))

func _avatar_size(compact: bool) -> Vector2:
	return ((Vector2(48, 50) if compact else Vector2(64, 76)) * maxf(0.85, _presentation._responsive_factor())).ceil()

func _has_orphan_line(paragraph: TextParagraph) -> bool:
	if paragraph.get_line_count() < 2:
		return false
	if _line_content == null:
		_line_content = RegEx.new()
		_line_content.compile("[\\p{P}\\p{Z}\\p{C}]")
	for index in [0, paragraph.get_line_count() - 1]:
		var bounds := paragraph.get_line_range(index)
		var line := _goal.text.substr(bounds.x, bounds.y - bounds.x)
		if _line_content.sub(line, "", true).length() <= 1:
			return true
	return false

func _fit_paragraph(width: float, maximum_width: float) -> TextParagraph:
	var paragraph := TextParagraph.new()
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE | _goal.autowrap_trim_flags
	paragraph.width = width
	paragraph.add_string(_goal.text, _goal.get_theme_font("font"), _font_size(), _goal.language)
	# 中文禁则仍由同一 TextServer 处理；小幅调整宽度，让“续）”“户。”不单独占一行。
	# 最多加宽一个字，不增加行数；避免窄屏为消除孤字反而挤成高长条。
	if _has_orphan_line(paragraph):
		var original_lines := paragraph.get_line_count()
		for delta in range(1, _font_size() * 3 + 1):
			for candidate in [width - delta, width + delta]:
				if candidate < 48 or candidate > minf(maximum_width, width + _font_size()):
					continue
				paragraph.width = candidate
				if paragraph.get_line_count() <= original_lines and not _has_orphan_line(paragraph):
					return paragraph
		paragraph.width = width
	return paragraph

func preferred_size(available: Vector2) -> Vector2:
	var compact := _wants_compact(available)
	var factor: float = _presentation._responsive_factor()
	var dpi: float = maxf(1.0, _presentation._ui_scale)
	var width := floorf(minf(available.x, 160 * dpi if compact else maxf(330, 440 * factor)))
	var avatar := _avatar_size(compact)
	var panel: StyleBox = _bubble.get_theme_stylebox("panel")
	var margin := panel.get_minimum_size()
	var close_width := ceilf(_close.get_combined_minimum_size().x)
	var gap := float(_row.get_theme_constant("separation"))
	var sentence_gap := float(_goal.get_parent().get_theme_constant("separation"))
	var occupied: float = margin.x + close_width + sentence_gap + (0.0 if compact else avatar.x + gap)
	var text_width := maxf(50, width - occupied)
	var paragraph := _fit_paragraph(text_width, available.x - occupied)
	width -= text_width - paragraph.width
	var text_size := paragraph.get_size()
	var lines := paragraph.get_line_count()
	var text_height := ceilf(text_size.y) + (lines - 1) * _goal.get_theme_constant("line_spacing") + 2
	var bubble_height := maxf(text_height, _close.get_combined_minimum_size().y) + margin.y
	var height := avatar.y + gap + bubble_height if compact else maxf(avatar.y, bubble_height)
	return Vector2(width, minf(available.y, height))

## 浮层位置只在原取景区内变化，绝不占用或修改牌桌的布局区域。
func place_in(available: Rect2) -> void:
	_floating_bounds = available
	_compact_landscape = _wants_compact(available.size)
	_goal.add_theme_font_size_override("font_size", _font_size())
	_mascot.custom_minimum_size = _avatar_size(_compact_landscape)
	_row.vertical = _compact_landscape
	_bubble.vertical = _compact_landscape
	_bubble.queue_redraw()
	size = preferred_size(available.size)
	var travel := (available.size - size).max(Vector2.ZERO)
	var anchor := Vector2(1.0, 0.5) if _compact_landscape and not _has_dragged else _floating_anchor
	position = available.position + travel * anchor
	if not _has_dragged:
		position = _clear_position(available, position)
	_size_changed()

## 仅在默认摆位时选一块空地，玩家拖过后不再替他挪动提示。
func _clear_position(available: Rect2, preferred: Vector2) -> Vector2:
	if not is_instance_valid(arena) or not is_instance_valid(arena.camera):
		return preferred
	var focused: Array = arena.focus_cards()
	var obstacles: Array = []
	for card in arena.board.cards:
		if not is_instance_valid(card) or not card.is_visible_in_tree():
			continue
		var resting: Vector3 = arena.board.rest_pos(card)
		var rect := Rect2(arena.camera.unproject_position(resting), Vector2.ZERO)
		for x in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var corner: Vector3 = resting + card.global_basis * Vector3(CardEntity.CARD_SIZE.x * x, 0.03, CardEntity.CARD_SIZE.z * z)
				rect = rect.expand(arena.camera.unproject_position(corner))
		obstacles.append({"rect": rect.grow(7), "weight": 100.0 if card in focused else 1.0})
	var travel := (available.size - size).max(Vector2.ZERO)
	var candidates: Array[Vector2] = [preferred]
	for anchor in [Vector2(0.3, 1), Vector2(0.65, 1), Vector2(0, 1), Vector2(1, 1), Vector2(0.5, 0), Vector2(0.3, 0), Vector2(1, 0.5), Vector2(0, 0.5)]:
		candidates.append(available.position + travel * anchor)
	var best := preferred
	var best_score := INF
	for candidate in candidates:
		var footprint := Rect2(candidate, size)
		var score := 0.0
		for obstacle in obstacles:
			var overlap: Rect2 = footprint.intersection(obstacle["rect"])
			if overlap.has_area():
				score += (overlap.get_area() + 1.0) * float(obstacle["weight"])
		if score < best_score:
			best_score = score
			best = candidate
		if is_zero_approx(score):
			break
	return best

func _size_changed() -> void:
	if _row != null:
		_row.size = size

func _on_dialogue_input(event: InputEvent, control: Control) -> void:
	if _closing:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_pointer(control, event.global_position)
		elif _pointer_touch < 0:
			_end_pointer(event.global_position)
		control.accept_event()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_pointer(control, control.global_position + event.position, event.index)
		elif event.index == _pointer_touch:
			_end_pointer(control.global_position + event.position, event.canceled)
		control.accept_event()

func _begin_pointer(control: Control, point: Vector2, touch_index: int = -1) -> void:
	if _pressed_control != null:
		return
	_pressed_control = control
	_pointer_touch = touch_index
	_pointer_moved = false
	_pointer_can_tap = _can_tap()
	_pointer_origin = point
	_drag_start_position = position

func _move_pointer(point: Vector2) -> void:
	if _pressed_control == null:
		return
	if not _pointer_moved and point.distance_to(_pointer_origin) < CLICK_DRAG_THRESHOLD * _presentation._responsive_factor():
		return
	_pointer_moved = true
	if _pressed_control != _mascot or _floating_bounds.size == Vector2.ZERO:
		return
	var travel := (_floating_bounds.size - size).max(Vector2.ZERO)
	position = (_drag_start_position + point - _pointer_origin).clamp(_floating_bounds.position, _floating_bounds.position + travel)
	var offset := position - _floating_bounds.position
	_has_dragged = true
	_floating_anchor = Vector2(offset.x / travel.x if travel.x > 0 else 0.5, offset.y / travel.y if travel.y > 0 else 1.0)

func _end_pointer(point: Vector2, canceled: bool = false) -> void:
	if _pressed_control == null:
		return
	if not canceled:
		_move_pointer(point)
	var should_advance := not canceled and _pointer_can_tap and not _pointer_moved \
		and _pressed_control.get_global_rect().has_point(point) and _can_tap()
	_reset_pointer()
	if should_advance:
		_advance()

func _reset_pointer() -> void:
	_pressed_control = null
	_pointer_touch = -1
	_pointer_can_tap = false

func _visibility_changed() -> void:
	_reset_pointer()
	if _closing or not is_instance_valid(arena):
		return
	if not is_visible_in_tree():
		arena.board.cancel_pointer()
	process_mode = Node.PROCESS_MODE_ALWAYS if is_visible_in_tree() else Node.PROCESS_MODE_DISABLED
	_sync_arena_process()

func _sync_arena_process() -> void:
	if is_instance_valid(arena):
		arena.set_presentation_active(is_visible_in_tree() and not _reference_open)

func _input(event: InputEvent) -> void:
	# 小人与气泡共用点击判定；在外面松手、拖动、触摸取消都不会继续。
	if _pressed_control != null:
		if event is InputEventMouseMotion and _pointer_touch < 0:
			_move_pointer(event.position)
			get_viewport().set_input_as_handled()
			return
		if event is InputEventScreenDrag and event.index == _pointer_touch:
			_move_pointer(event.position)
			get_viewport().set_input_as_handled()
			return
		if (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _pointer_touch < 0) \
			or (event is InputEventScreenTouch and event.index == _pointer_touch and not event.pressed):
			_end_pointer(event.position, event is InputEventScreenTouch and event.canceled)
			get_viewport().set_input_as_handled()
			return
	if arena == null or not is_visible_in_tree() or arena.board._drag_cards.is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if _bubble.get_global_rect().has_point(event.position):
			arena.board.cancel_pointer()
