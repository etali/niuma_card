extends CanvasLayer
## 光标与撕纸共用一只简笔手；一次攻击批次只有一双手。
##
## 游戏窗口内统一为简笔手：牌桌、面板、按钮、教程小人都换成同一张图，只有文字输入框
## 保留系统的文本光标，方便定位插入点。
##
## 平时用系统光标承载这张图，移动最跟手。拖牌时改由场景绘制抓握手：系统光标由合成器按
## 最新鼠标位置直接画，牌却要等渲染管线晚几帧才显示，快速晃动时手和牌的相对
## 位置会随速度来回摆。手与牌同帧绘制后两者一起延迟，相对位置不再随速度变化。
const Motion = preload("res://scenes/card_motion.gd")
const Art = preload("res://scenes/hand_art.gd")
const GRIP := Motion.BATCH_GRIP
const DURATION := Motion.BATCH_DURATION
## 场景里的手当帧就画上，要再过两三帧才真正显示；这几帧先保留系统握拳光标，
## 交接完再换成透明图，抓起瞬间不会空手。
const HANDOFF_FRAMES := 3
var host: Node
var _canvas: HandCanvas
var _batches: Array[Dictionary] = []
var _pointer := Vector2.ZERO
var _pointing := false
var _angry := false
var _drag_hand := Vector2.INF   # 本帧场景绘制的抓握手位置；INF = 不画
var _drag_hand_frames := 0
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
	# 排在 Board 摆好在手的牌之后，抓握手读到的是同一帧的牌位
	process_priority = 90
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

## hold 是命中顿帧：抓到之后按住发抖这么久再往两边扯；duration 随之顺延。
func tear(cards: Array, positions: Array = [], hold := 0.0, duration := DURATION) -> void:
	var bounds := card_bounds(cards, positions)
	if bounds.size == Vector2.ZERO:
		return
	_batches.append({"bounds": bounds, "elapsed": 0.0, "count": cards.size(),
		"hold": maxf(0.0, hold), "duration": maxf(duration, GRIP + hold + 0.2)})
	batch_count += 1

func clear() -> void:
	_batches.clear()
	_drag_hand = Vector2.INF
	_drag_hand_frames = 0
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

## 控件各自声明光标形状（按钮是手指、小人是拖动、输入框是竖线），系统按形状取图；
## 只换箭头的话按钮上仍是系统手指。所以除文本光标外每种形状都换成同一张简笔手。
## text_too：拖动时手由场景画，竖线也藏起，否则划过输入框会和场景手叠在一起。
func _apply_cursor(image: Image, hotspot := Vector2.ZERO, text_too := false) -> void:
	for shape in DisplayServer.CURSOR_MAX:
		var covered := text_too or shape != Input.CURSOR_IBEAM
		_set_shape_cursor(image if covered else null, shape, hotspot)

func _set_shape_cursor(image: Image, shape: int, hotspot: Vector2) -> void:
	Input.set_custom_mouse_cursor(image, shape, hotspot)

func _native_pixel_scale() -> float:
	if OS.get_name() == "macOS":
		# Godot 的 macOS 窗口/鼠标坐标统一使用所有屏幕的最大缩放；
		# 混用 Retina 与普通外接屏时不能除以当前屏幕缩放。
		return DisplayServer.screen_get_max_scale()
	if OS.has_feature("web"):
		return DisplayServer.screen_get_scale(host.get_window().current_screen)
	return 1.0

func _native_cursor_scale() -> float:
	return Art.cursor_scale(_hand_scale(), _native_pixel_scale())

## 与系统光标显示成同一尺寸：系统光标按逻辑点 × 像素倍率显示，画布坐标还要经过视口拉伸。
func _drag_hand_scale() -> float:
	var stretch := host.get_viewport().get_final_transform().get_scale().x
	return _native_cursor_scale() * _native_pixel_scale() / maxf(stretch, 0.001)

func _update_cursor() -> void:
	if not _pointing or not _supports_native_cursor():
		_restore_cursor()
		return
	var mode := "angry" if _angry else "point"
	if not host.board._drag_cards.is_empty():
		mode = "hidden" if _drag_hand_frames > HANDOFF_FRAMES else "grip"
	var magnification := _native_cursor_scale()
	var key := "%s:%.2f" % [mode, magnification]
	if key == _cursor_key and _cursor_owner == get_instance_id():
		return
	var cursor := Art.cursor(mode, magnification)
	if cursor.is_empty():
		_restore_cursor()
		return
	_apply_cursor(cursor.image, cursor.hotspot, mode == "hidden")
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
	var dragging: bool = not host.board._drag_cards.is_empty()
	# 面板也在游戏窗口内，同样是简笔手；拖动中手随牌走，鼠标移出窗口也不撤
	_pointing = cursor_enabled and available and host.get_window().has_focus() and not host.mobile_mode \
		and (dragging or host.get_viewport().get_visible_rect().has_point(_pointer))
	_angry = false
	# 怒手只指牌桌上的目标：面板挡住的牌点不到
	if _pointing and presentation.content_rect().has_point(_pointer) and not presentation.pointer_over_panels(_pointer):
		if host.board.attack_mode:
			var card: CardEntity = host.board._pick_card(_pointer)
			_angry = card != null and host._attack_hl.has(card) and host._player_attack_busy == 0
	_update_drag_hand()
	_update_cursor()
	var had_batches := not _batches.is_empty()
	if available and had_batches:
		for batch in _batches:
			batch.elapsed += delta
		_batches = _batches.filter(func(batch): return batch.elapsed < float(batch.get("duration", DURATION)))
	var drawing_hand := _drag_hand != Vector2.INF
	_canvas.visible = available and (not _batches.is_empty() or drawing_hand)
	if available and (had_batches or drawing_hand):
		_canvas.queue_redraw()

## 系统光标藏不掉的平台上不画，否则会出现两只手；触屏拖动由手指代替手。
func _update_drag_hand() -> void:
	var at: Vector3 = host.board.drag_hand_point() \
		if _pointing and _supports_native_cursor() and not host.board.touch_mode else Vector3.INF
	var camera: Camera3D = host.get_viewport().get_camera_3d()
	if at == Vector3.INF or camera == null or camera.is_position_behind(at):
		_drag_hand = Vector2.INF
		_drag_hand_frames = 0
		return
	_drag_hand = camera.unproject_position(at)
	_drag_hand_frames += 1

func _hand_scale() -> float:
	return clampf(host.get_viewport().get_visible_rect().size.x / 1100.0, 0.65, 1.5)

func paint(canvas: Control) -> void:
	var scale_factor := _hand_scale()
	for batch in _batches:
		var rect: Rect2 = batch.bounds
		var hold := float(batch.get("hold", 0.0))
		var duration := float(batch.get("duration", DURATION))
		# 顿帧期间时间轴停在抓握完成那一刻；之后的扯开照原节拍走完。
		var t: float = batch.elapsed
		var held := clampf(t - GRIP, 0.0, hold)
		t -= held
		var span := duration - hold
		var pull := smoothstep(GRIP, span - 0.10, t)
		var approach := 1.0 - smoothstep(0.0, GRIP, t)
		var reach := approach * 35.0 + pull * 45.0
		var opacity := 1.0 - smoothstep(span - 0.12, span, t)
		var size_factor := scale_factor * clampf(rect.size.x / 90.0, 1.6, 2.5)
		var tremble := Vector2.ZERO
		if held > 0.0 and held < hold:
			tremble = Vector2(sin(batch.elapsed * 95.0), cos(batch.elapsed * 77.0)) * 2.0 * size_factor
		_hand(canvas, Vector2(rect.get_center().x - rect.size.x * 0.15, rect.position.y + 18.0 * size_factor - reach) + tremble, PI, size_factor, true, false, opacity)
		_hand(canvas, Vector2(rect.get_center().x + rect.size.x * 0.15, rect.end.y - 18.0 * size_factor + reach) - tremble, 0, size_factor, true, false, opacity)
	if _drag_hand != Vector2.INF:
		# 轮廓原点即系统光标热点，交接前后手停在同一处
		_hand(canvas, _drag_hand, 0.0, _drag_hand_scale(), true, false, 1.0)
	canvas.draw_set_transform(Vector2.ZERO)

func _hand(canvas: Control, at: Vector2, angle: float, magnification: float, grip: bool, angry: bool, opacity: float) -> void:
	Art.draw(canvas, at, angle, magnification, grip, angry, opacity)
