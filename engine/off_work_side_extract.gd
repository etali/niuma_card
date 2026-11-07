extends RefCounted
## Side counters stay on the original table. This adapter only opens a read-only
## face fan and hands an exact set of existing UIDs to Board's drag protocol.
const ExtractView = preload("res://scenes/off_work_pile_extract_view.gd")

var board: Board
var settings: Dictionary
var view: Control
var layer: CanvasLayer
var _pressed: Dictionary = {}
var _group_id := -1
var _kind := ""

func _init(owner_board: Board, options: Dictionary) -> void:
	board = owner_board
	settings = options

func entries(group_id: int) -> Array:
	var state: Object = board._state
	if state == null or not state.groups.has(group_id): return []
	var grouped: Dictionary = {}
	for uid in state.group_cards(group_id):
		var kind := str(state.cards[uid].type)
		if not grouped.has(kind): grouped[kind] = []
		grouped[kind].append(uid)
	var order: Array = settings.type_order.duplicate()
	for kind in grouped:
		if not order.has(kind): order.append(kind)
	var result: Array = []
	for kind in order:
		if not grouped.has(kind): continue
		var count: int = grouped[kind].size()
		if kind == "money":
			count = 0
			for uid in grouped[kind]: count += int(state.cards[uid].amount)
		result.append({"kind": kind, "ids": grouped[kind], "tex": CardArt.icon_texture(kind, OffWorkCardDB), "text": "×%d" % count})
	return result

func side_rows(group: Dictionary) -> Array:
	return entries(int(group.get("work_group_id", -1)))

func eligible(uid: int) -> bool:
	var state: Object = board._state
	if state == null or state.winner >= 0 or not state.cards.has(uid) or not board.by_uid.has(uid): return false
	var card: CardEntity = board.by_uid[uid]
	return int(state.cards[uid].owner) == int(board._settings.local_owner) and card.draggable \
		and not card.is_market and not card.has_meta("income_flight") and not card.has_meta("delivery_flight") \
		and not board._meeting_visitors.has(uid) and not state.is_meeting_target(uid) and not board._strike_in_flight(uid)

func _records() -> Array:
	var state: Object = board._state
	var result: Array = []
	if state == null or not state.groups.has(_group_id): return result
	for uid in state.group_cards(_group_id):
		if str(state.cards[uid].type) == _kind and eligible(int(uid)):
			result.append(state.cards[uid].duplicate(true))
	return result

func _ensure_view() -> void:
	if is_instance_valid(view): return
	layer = CanvasLayer.new()
	layer.name = "SideExtractLayer"
	layer.layer = int(settings.canvas_layer)
	board.add_child(layer)
	view = ExtractView.new()
	layer.add_child(view)
	view.configure(settings)
	view.extract_requested.connect(_begin_extraction)
	view.closed.connect(func():
		_group_id = -1
		_kind = "")

func _begin_extraction(ids: Array, at: Vector2) -> void:
	# Keep the grabbed header under the pointer as the transparent projection
	# becomes the real tabletop cards. Centering the card at the cursor here
	# would visibly jump by roughly half a card on every cut.
	var center := Vector2.INF
	if not ids.is_empty() and is_instance_valid(view):
		for index in view.records.size():
			if int(view.records[index].id) == int(ids[0]) and view._card_rects.has(index):
				center = (view._card_rects[index] as Rect2).get_center() + at - view._press_at
				break
	if not board.begin_side_extract(ids, at) or center == Vector2.INF or board.camera == null: return
	var first: CardEntity = board._drag_cards[0]
	var face_height: float = first._visual.to_global(Vector3(0.0, CardEntity.Y_TEXT, 0.0)).y
	var ray := board.camera.project_ray_normal(center)
	if is_zero_approx(ray.y): return
	var origin := board.camera.project_ray_origin(center)
	var desired := origin + ray * ((face_height - origin.y) / ray.y)
	var pointer: Vector3 = board._mouse_table_point()
	if pointer == Vector3.INF: return
	var offset: Vector3 = board._drag_offsets[0]
	board._grab_offset = Vector3(desired.x - pointer.x - offset.x, 0.0, desired.z - pointer.z - offset.z)
	board._process(0.0)

func source_screen_rect(group_id: int) -> Rect2:
	# Start the side spread at the visible front of the stack, never at its
	# first logical member (which may be buried under hundreds of work cards).
	if board.camera == null: return Rect2()
	var front: CardEntity
	var highest := -INF
	for group in board.groups:
		if int(group.get("work_group_id", -1)) != group_id: continue
		for card in group.cards:
			if not is_instance_valid(card) or not is_instance_valid(card._visual) or not card.visible or not card._visual.visible: continue
			if card.has_meta("income_flight") or card.has_meta("delivery_flight") or board._meeting_visitors.has(card.uid): continue
			var height: float = card._visual.global_position.y
			if front == null or height >= highest:
				front = card
				highest = height
	if front == null: return Rect2()
	return board._cash_note_screen_bounds(front._visual)

func _entry_anchor(group_id: int, kind: String, fallback: Rect2) -> Vector2:
	for group in board.groups:
		if int(group.get("work_group_id", -1)) != group_id: continue
		var rows: Array = group.get("extract_rows", [])
		var nodes: Array = group.get("side", [])
		for index in rows.size():
			if str(rows[index].kind) != kind or index * 2 + 1 >= nodes.size(): continue
			var label: Label3D = nodes[index * 2 + 1]
			if is_instance_valid(label): return board.camera.unproject_position(label.global_position)
	return Vector2(fallback.end.x, fallback.get_center().y)

func open_group(group_id: int, kind: String, anchor := Vector2.INF) -> bool:
	if board.input_locked or board.attack_mode or board.view_gesture or board._interaction_is_blocked() or board.is_dragging(): return false
	_group_id = group_id
	_kind = kind
	var records := _records()
	if records.is_empty():
		close()
		return false
	_ensure_view()
	var source := source_screen_rect(group_id)
	if anchor == Vector2.INF:
		anchor = _entry_anchor(group_id, kind, source)
	board._set_hover_card(null)
	board._hide_desc()
	view.show_cards(group_id, kind, records, board._state.config.cards, anchor, source, board._cash_screen_region(int(board._settings.local_owner)))
	return true

func is_open() -> bool:
	return is_instance_valid(view) and view.is_open()

func close() -> void:
	_pressed.clear()
	_group_id = -1
	_kind = ""
	if is_instance_valid(view): view.close_view()

func sync_state() -> void:
	if not is_open(): return
	if board.input_locked or board.attack_mode or board.view_gesture or board._interaction_is_blocked():
		close()
		return
	var records := _records()
	if records.is_empty(): close()
	else: view.update_cards(records)

func handle_input(event: InputEvent) -> bool:
	if board.touch_mode and event is InputEventMouse: board._pointer_at = event.position
	if board.input_locked or board.attack_mode or board.view_gesture or board._interaction_is_blocked():
		close()
		return false
	if board.is_dragging(): return false
	if event is InputEventMouse and board.hover_blocked.is_valid() and bool(board.hover_blocked.call()):
		if event is InputEventMouseButton and (event.pressed or event.button_index == MOUSE_BUTTON_LEFT): close()
		return false
	if is_open():
		# Clicking another side row changes the inspected type in one gesture.
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed \
				and not view.contains_screen_point(event.position):
			var hit := hit_test(event.position)
			if not hit.is_empty():
				close()
				_pressed = hit
				_pressed["at"] = event.position
				return true
		return bool(view.handle_pointer_event(event))
	if not _pressed.is_empty():
		if event is InputEventMouseMotion:
			if event.position.distance_to(_pressed.at) > float(settings.click_threshold): _pressed["cancelled"] = true
			return true
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if not event.pressed:
				var intent := _pressed.duplicate()
				_pressed.clear()
				if not event.canceled and not intent.get("cancelled", false) and event.position.distance_to(intent.at) <= float(settings.click_threshold):
					open_group(int(intent.group), str(intent.kind), intent.anchor)
			return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var hit := hit_test(event.position)
		if not hit.is_empty():
			_pressed = hit
			_pressed["at"] = event.position
			return true
	return false

func hit_test(at: Vector2) -> Dictionary:
	if board.camera == null: return {}
	var best: Dictionary = {}
	var distance := INF
	for group in board.groups:
		var rows: Array = group.get("extract_rows", [])
		var nodes: Array = group.get("side", [])
		for index in rows.size():
			if index * 2 + 1 >= nodes.size(): continue
			var label: Label3D = nodes[index * 2 + 1]
			if not is_instance_valid(label) or not label.visible: continue
			var center := label.global_position
			var left := center.x - Board.SIDE_ICON - float(settings.side_text_gap)
			var half_depth := Board.SIDE_ROW_Z * 0.5
			var polygon := PackedVector2Array()
			for point in [Vector3(left, center.y, center.z-half_depth), Vector3(left+Board.SIDE_W, center.y, center.z-half_depth), Vector3(left+Board.SIDE_W, center.y, center.z+half_depth), Vector3(left, center.y, center.z+half_depth)]:
				polygon.append(board.camera.unproject_position(point))
			if not Geometry2D.is_point_in_polygon(at, polygon): continue
			var score := board.camera.global_position.distance_squared_to(center)
			if score >= distance: continue
			distance = score
			best = {"group": int(group.get("work_group_id", -1)), "kind": rows[index].kind,
				"anchor": board.camera.unproject_position(center)}
	return best
