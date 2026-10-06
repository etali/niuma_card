extends CanvasLayer
## 光标与撕纸共用一只简笔手；一次攻击批次只有一双手。
const Motion = preload("res://scenes/card_motion.gd")
const GRIP := Motion.BATCH_GRIP
const DURATION := Motion.BATCH_DURATION
var host: Node
var _canvas: HandCanvas
var _batches: Array[Dictionary] = []
var _pointer := Vector2.ZERO
var _pointing := false
var _angry := false
var _hid_cursor := false
var batch_count := 0
var cursor_enabled := true

class HandCanvas extends Control:
	func _draw() -> void:
		get_parent().paint(self)

func bind(main: Node) -> void:
	host = main
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = HandCanvas.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_canvas)

func card_bounds(cards: Array, positions: Array = []) -> Rect2:
	var camera: Camera3D = host.get_viewport().get_camera_3d()
	var bounds := Rect2()
	var first := true
	for index in cards.size():
		var card: CardEntity = cards[index]
		if not is_instance_valid(card):
			continue
		for x in [-0.6, 0.6]:
			for z in [-0.8, 0.8]:
				var world_point: Vector3 = card.to_global(Vector3(x, 0.06, z)) if positions.is_empty() else positions[index] + Vector3(x, 0.06, z)
				var point := camera.unproject_position(world_point)
				if first:
					bounds = Rect2(point, Vector2.ZERO)
					first = false
				else:
					bounds = bounds.expand(point)
	return bounds

func tear(cards: Array, positions: Array = []) -> void:
	var bounds := card_bounds(cards, positions)
	if bounds.size == Vector2.ZERO:
		return
	_batches.append({"bounds": bounds, "elapsed": 0.0, "count": cards.size()})
	batch_count += 1

func clear() -> void:
	_batches.clear()
	_restore_cursor()

func _restore_cursor() -> void:
	if _hid_cursor:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_hid_cursor = false

func _exit_tree() -> void:
	_restore_cursor()

func _process(delta: float) -> void:
	if not is_instance_valid(host) or _canvas == null:
		return
	_pointer = host.get_viewport().get_mouse_position()
	var presentation: Node = host.drawer_presentation
	var available: bool = presentation != null and not host._drawer_input_blocked()
	_pointing = cursor_enabled and available and host.get_window().has_focus() and not host.mobile_mode and presentation.content_rect().has_point(_pointer) \
		and not presentation.pointer_over_panels(_pointer)
	_angry = false
	if _pointing:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		_hid_cursor = true
		if host.board.attack_mode:
			var card: CardEntity = host.board._pick_card(_pointer)
			_angry = card != null and host._attack_hl.has(card) and host._player_attack_busy == 0
	else:
		_restore_cursor()
	if available:
		for batch in _batches:
			batch.elapsed += delta
		_batches = _batches.filter(func(batch): return batch.elapsed < DURATION)
	_canvas.visible = available
	_canvas.queue_redraw()

func paint(canvas: Control) -> void:
	var scale_factor := clampf(host.get_viewport().get_visible_rect().size.x / 1100.0, 0.65, 1.5)
	for batch in _batches:
		var rect: Rect2 = batch.bounds
		var t: float = batch.elapsed
		var pull := smoothstep(GRIP, DURATION - 0.10, t)
		var approach := 1.0 - smoothstep(0.0, GRIP, t)
		var reach := approach * 35.0 + pull * 45.0
		var opacity := 1.0 - smoothstep(DURATION - 0.12, DURATION, t)
		var size_factor := scale_factor * clampf(rect.size.x / 90.0, 1.6, 2.5)
		_hand(canvas, Vector2(rect.get_center().x - rect.size.x * 0.15, rect.position.y + 18.0 * size_factor - reach), PI, size_factor, true, false, opacity)
		_hand(canvas, Vector2(rect.get_center().x + rect.size.x * 0.15, rect.end.y - 18.0 * size_factor + reach), 0, size_factor, true, false, opacity)
	if _pointing and _batches.is_empty():
		_hand(canvas, _pointer, -0.12 if _angry else 0.0, scale_factor, not host.board._drag_cards.is_empty(), _angry, 1.0)
	canvas.draw_set_transform(Vector2.ZERO)

func _hand(canvas: Control, at: Vector2, angle: float, magnification: float, grip: bool, angry: bool, opacity: float) -> void:
	canvas.draw_set_transform(at, angle, Vector2.ONE * magnification)
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(3,-1), Vector2(6,2), Vector2(7,17),
		Vector2(10,16), Vector2(14,18), Vector2(15,21), Vector2(19,20),
		Vector2(23,22), Vector2(24,25), Vector2(28,25), Vector2(31,29),
		Vector2(31,39), Vector2(27,48), Vector2(27,56), Vector2(8,57),
		Vector2(7,48), Vector2(1,42), Vector2(-5,33), Vector2(-5,29),
		Vector2(-2,27), Vector2(2,29), Vector2(5,34), Vector2(1,16), Vector2(-1,4)])
	if grip:
		points = PackedVector2Array([Vector2(-4,14),Vector2(-3,8),Vector2(1,5),Vector2(5,6),Vector2(8,12),
			Vector2(9,5),Vector2(13,3),Vector2(17,5),Vector2(19,11),Vector2(20,7),Vector2(24,7),Vector2(28,12),
			Vector2(28,20),Vector2(32,23),Vector2(32,37),Vector2(27,46),Vector2(27,56),Vector2(8,57),
			Vector2(7,47),Vector2(0,41),Vector2(-8,31),Vector2(-9,26),Vector2(-6,22),Vector2(-2,22),
			Vector2(5,28),Vector2(6,25),Vector2(2,21)])
	# 圆化关节轮廓，避免多边形尖角像机械手套。
	for iteration in 2:
		var rounded := PackedVector2Array()
		for i in points.size():
			var next := points[(i + 1) % points.size()]
			rounded.append(points[i].lerp(next, 0.2))
			rounded.append(points[i].lerp(next, 0.8))
		points = rounded
	var ink := Color(0.18, 0.16, 0.12, opacity)
	canvas.draw_colored_polygon(points, Color(0.96,0.92,0.81,opacity))
	points.append(points[0])
	canvas.draw_polyline(points, ink, 2.3, true)
	canvas.draw_polyline(PackedVector2Array([Vector2(7,26),Vector2(14,29),Vector2(18,25)]), ink, 1.8, true)
	canvas.draw_line(Vector2(23,27),Vector2(23,35),ink,1.7,true)
	canvas.draw_line(Vector2(10,49),Vector2(24,48),ink,1.7,true)
	if angry:
		var red := Color(0.72,0.19,0.15,opacity)
		canvas.draw_polyline(PackedVector2Array([Vector2(37,12),Vector2(33,17),Vector2(39,18)]),red,2.2,true)
		canvas.draw_polyline(PackedVector2Array([Vector2(35,25),Vector2(39,21),Vector2(43,25)]),red,2.2,true)
