extends CanvasLayer
## 光标与撕纸共用一只简笔手；一次攻击批次只有一双手。
const Motion = preload("res://scenes/card_motion.gd")
const Art = preload("res://scenes/hand_art.gd")
const GRIP := Motion.BATCH_GRIP
const DURATION := Motion.BATCH_DURATION
var host: Node
var _canvas: HandCanvas
var _batches: Array[Dictionary] = []
var _pointer := Vector2.ZERO
var _pointing := false
var _angry := false
static var _cursor_owner := 0
var _cursor_key := ""
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
	_canvas.hide()
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
	if _canvas != null:
		_canvas.hide()
	_restore_cursor()

func _restore_cursor() -> void:
	if _cursor_owner == get_instance_id():
		_apply_cursor(null)
		_cursor_owner = 0
	_cursor_key = ""

func _supports_native_cursor() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_CUSTOM_CURSOR_SHAPE)

func _apply_cursor(image: Image, hotspot := Vector2.ZERO) -> void:
	Input.set_custom_mouse_cursor(image, Input.CURSOR_ARROW, hotspot)

func _native_cursor_scale() -> float:
	var pixel_scale := 1.0
	if OS.get_name() == "macOS":
		# Godot 的 macOS 窗口/鼠标坐标统一使用所有屏幕的最大缩放；
		# 混用 Retina 与普通外接屏时不能除以当前屏幕缩放。
		pixel_scale = DisplayServer.screen_get_max_scale()
	elif OS.has_feature("web"):
		pixel_scale = DisplayServer.screen_get_scale(host.get_window().current_screen)
	return Art.cursor_scale(_hand_scale(), pixel_scale)

func _update_cursor() -> void:
	if not _pointing or not _supports_native_cursor():
		_restore_cursor()
		return
	var mode := "grip" if not host.board._drag_cards.is_empty() else ("angry" if _angry else "point")
	var magnification := _native_cursor_scale()
	var key := "%s:%.2f" % [mode, magnification]
	if key == _cursor_key and _cursor_owner == get_instance_id():
		return
	var cursor := Art.cursor(mode, magnification)
	if cursor.is_empty():
		_restore_cursor()
		return
	_apply_cursor(cursor.image, cursor.hotspot)
	_cursor_key = key
	_cursor_owner = get_instance_id()

func _exit_tree() -> void:
	_restore_cursor()

func _process(delta: float) -> void:
	if not is_instance_valid(host) or _canvas == null:
		_restore_cursor()
		return
	_pointer = host.get_viewport().get_mouse_position()
	var presentation: Node = host.drawer_presentation
	var available: bool = presentation != null and not host._drawer_input_blocked()
	_pointing = cursor_enabled and available and host.get_window().has_focus() and not host.mobile_mode and presentation.content_rect().has_point(_pointer) \
		and not presentation.pointer_over_panels(_pointer)
	_angry = false
	if _pointing:
		if host.board.attack_mode:
			var card: CardEntity = host.board._pick_card(_pointer)
			_angry = card != null and host._attack_hl.has(card) and host._player_attack_busy == 0
	_update_cursor()
	var had_batches := not _batches.is_empty()
	if available and had_batches:
		for batch in _batches:
			batch.elapsed += delta
		_batches = _batches.filter(func(batch): return batch.elapsed < DURATION)
	_canvas.visible = available and not _batches.is_empty()
	if available and had_batches:
		_canvas.queue_redraw()

func _hand_scale() -> float:
	return clampf(host.get_viewport().get_visible_rect().size.x / 1100.0, 0.65, 1.5)

func paint(canvas: Control) -> void:
	var scale_factor := _hand_scale()
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
	canvas.draw_set_transform(Vector2.ZERO)

func _hand(canvas: Control, at: Vector2, angle: float, magnification: float, grip: bool, angry: bool, opacity: float) -> void:
	Art.draw(canvas, at, angle, magnification, grip, angry, opacity)
