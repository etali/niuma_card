# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name DrawerWindow
extends Node

const UIConfig = preload("res://engine/ui_config.gd")

## 桌面侧边抽屉。窗口几何与悬停状态独立于牌局，SceneTree 暂停后仍然工作。
## 收放过程中使用原尺寸画面的遮罩；牌桌只在展开终点适配一次，不能跟着窗口挤压。

const DRAWER_WIDTH := 1920
const WINDOW_HEIGHT := 1200
const PEEK_WIDTH := 168
const PEEK_HEIGHT := 192
## 保持高度，仅裁掉宽屏两侧的空桌面；比例档位仍决定最大工作区尺寸。
const MAX_EXPANDED_ASPECT := 1.65
var handle_texture: Texture2D = null
## 比例档位：窗口始终按当前工作区计算，避免固定分辨率在不同屏幕上失真。
const SIZE_PRESETS := {
	"small": 0.75,
	"medium": 0.85,
	"large": 0.92,
	"wide": 1.0,
	"full": 0.98,
}
const LEAVE_DELAY := 0.16
const EXPAND_DURATION := 0.28
const COLLAPSE_DURATION := 0.12

signal expanded_changed(expanded: bool)
signal transition_finished(expanded: bool)
signal transition_started(expanded: bool)
signal pinned_changed(pinned: bool)
## 收起拉手需要在启动时主动提示玩家。界面层收到后播放图标招手动画。
signal attention_requested
## 入口悬停只播放问候；只有点击入口才展开。
signal handle_hovered(hovered: bool)
signal handle_size_changed(size: Vector2i)

## 默认随当前屏幕工作区变大；显式设置尺寸后才使用固定像素值。
var expanded_size := Vector2i(DRAWER_WIDTH, WINDOW_HEIGHT):
	set(value):
		expanded_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		_size_fraction = 0.0
var collapsed_size := Vector2i(PEEK_WIDTH, PEEK_HEIGHT)
var handle_vertical_ratio := 0.5
## 顶部/底部吸附时使用的水平位置；保留 vertical_ratio 兼容旧调用。
var handle_horizontal_ratio := 0.5
## 当前吸附边：right/left/top/bottom。
var anchor_edge := "right"
## 返回 false 时保留窗口，供主场景阻止拖牌、菜单操作期间自动收起。
var can_collapse: Callable
var animations_enabled := true

var _window: Window
var _expanded := true
var _pinned := false
var _collapse_at := -1
var _screen_rect := Rect2i()
var _enabled := false
var _use_os_window := false
var _mouse_inside := false
var _transitioning := false
var _transition_target := true
var _transition_tween: Tween
var _geometry := Rect2i()
var _next_screen_check := 0
var _cover_layer: CanvasLayer
var _cover: TextureRect
var _snapshot: ImageTexture
var _original_disable_3d := false
var _attention_until := -1
var _attention_announced := false
var _handle_hovered := false
var _size_fraction: float
var _display_scale := 1.0
var _icon_scale: float
var _dragging := false
var _drag_moved := false
var _drag_start_pointer := Vector2i.ZERO
var _drag_start_geometry := Rect2i()
const DRAG_THRESHOLD := 12

func _init(config_path: String = "") -> void:
	var defaults := UIConfig.read_defaults(config_path)
	_size_fraction = defaults["window_fraction"]
	_icon_scale = defaults["icon_scale"]

## 测试可用 setup(false, usable_rect)，驱动相同状态机而不更改系统窗口。
func setup(use_os_window := true, usable_rect := Rect2i()) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_use_os_window = use_os_window and DisplayServer.get_name() != "headless"
	_screen_rect = usable_rect
	_enabled = true
	if ResourceLoader.exists("res://assets/art/app_icon.png"):
		handle_texture = load("res://assets/art/app_icon.png")
	if _use_os_window:
		_window = get_window()
		if _window == null:
			_enabled = false
			return
		_window.borderless = true
		_window.unresizable = true
		_window.always_on_top = true
		_window.min_size = Vector2i.ONE
		_window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		_window.content_scale_size = Vector2i.ZERO
		_window.content_scale_factor = 1.0
		# 透明原生窗口只保留抽屉内容本身的边框，收起态不会出现黑色矩形背景。
		_window.transparent = true
		_window.transparent_bg = true
		_original_disable_3d = _window.disable_3d
		if not _window.mouse_entered.is_connected(_on_mouse_entered):
			_window.mouse_entered.connect(_on_mouse_entered)
			_window.mouse_exited.connect(_on_mouse_exited)
		_create_transition_cover()
		_refresh_screen_rect()
	if _screen_rect.size.x <= 0 or _screen_rect.size.y <= 0:
		_screen_rect = Rect2i(Vector2i.ZERO, expanded_size)
	set_display_scale(_display_scale)
	_expanded = true
	_apply_geometry(_rect_for(true))
	# main 先按完整窗口建立牌桌，再调用 start_collapsed() 展示启动入口。
	# 不在 setup 中暂停半建成的场景，也不会先把整张牌桌闪到办公窗口上。
	_collapse_at = -1

## 主场景完成构造后调用。直接进入透明入口，启动问候只播放一次。
func start_collapsed() -> void:
	if not _enabled:
		return
	set_pinned(false)
	_finish_transition(false)

func _announce_handle() -> void:
	if not _enabled or _expanded or _attention_announced:
		return
	_attention_announced = true
	_attention_until = Time.get_ticks_msec() + 5000
	attention_requested.emit()

func is_attention_active() -> bool:
	return _attention_until >= 0 and Time.get_ticks_msec() < _attention_until

func get_handle_texture() -> Texture2D:
	return handle_texture

func get_size_presets() -> Dictionary:
	return SIZE_PRESETS.duplicate(true)

func set_size_preset(preset: String) -> void:
	var key := preset.to_lower().strip_edges()
	if key == "fullscreen":
		key = "full"
	if SIZE_PRESETS.has(key):
		set_size_fraction(float(SIZE_PRESETS[key]))

func set_anchor_edge(edge: String) -> void:
	var normalized := edge.to_lower().strip_edges()
	if normalized not in ["left", "right", "top", "bottom"]:
		normalized = "right"
	anchor_edge = normalized
	if _enabled and not _transitioning:
		_apply_geometry(_rect_for(_expanded))

func get_anchor_edge() -> String:
	return anchor_edge

## 展开时从吸附边朝屏幕内部移动；窗口裁切和卡摞惯性共用这一方向。
func get_open_direction() -> Vector2:
	match anchor_edge:
		"left": return Vector2.RIGHT
		"top": return Vector2.DOWN
		"bottom": return Vector2.UP
	return Vector2.LEFT

func _transition_axis() -> int:
	return 1 if anchor_edge in ["top", "bottom"] else 0

func set_handle_size(value: Vector2i) -> void:
	collapsed_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
	_icon_scale = float(collapsed_size.x) / float(maxi(PEEK_WIDTH, 1)) / maxf(_display_scale, 0.01)
	handle_size_changed.emit(collapsed_size)
	if _enabled and not _transitioning and not _expanded:
		_apply_geometry(_rect_for(false))

func set_collapsed_size(value: Vector2i) -> void:
	set_handle_size(value)

func set_collapsed_size_fraction(value: float) -> void:
	set_icon_scale(value)

func set_display_scale(value: float) -> void:
	_display_scale = clampf(value, 1.0, 4.0)
	set_handle_size(Vector2i(roundi(PEEK_WIDTH * _display_scale * _icon_scale),
		roundi(PEEK_HEIGHT * _display_scale * _icon_scale)))

func get_handle_scale() -> float:
	return _display_scale * _icon_scale

func get_icon_scale() -> float:
	return _icon_scale

func set_icon_scale(value: float) -> void:
	_icon_scale = clampf(value, 0.5, 3.0)
	set_handle_size(Vector2i(roundi(PEEK_WIDTH * _display_scale * _icon_scale),
		roundi(PEEK_HEIGHT * _display_scale * _icon_scale)))

func _process(_delta: float) -> void:
	if not _enabled:
		return
	var now := Time.get_ticks_msec()
	if _use_os_window:
		if _dragging:
			var pointer := DisplayServer.mouse_get_position()
			drag_to(pointer)
			if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				end_drag(pointer)
			return
		if now >= _next_screen_check:
			_next_screen_check = now + 1000
			if _refresh_screen_rect():
				_finish_transition(_transition_target if _transitioning else _expanded)
		# 原生窗口变更尺寸时 entered/exited 的顺序因平台而异，以全局鼠标坐标为准。
		if not _transitioning:
			_update_hover(DisplayServer.mouse_get_position(), now)
	_tick_at(now)

func _input(event: InputEvent) -> void:
	if not _enabled or _transitioning:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var pointer := DisplayServer.mouse_get_position() if _use_os_window else Vector2i(event.position)
		if not event.pressed and _dragging:
			end_drag(pointer)
		elif event.pressed and _expanded:
			_take_focus()
	elif event is InputEventMouseMotion and _dragging:
		var pointer := DisplayServer.mouse_get_position() if _use_os_window else Vector2i(event.position)
		drag_to(pointer)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		collapse_now()

## 入口组件将真实点击桥接到窗口，透明角落不会进入这条路径。
func handle_press() -> void:
	if not _enabled or _expanded or _transitioning:
		return
	var pointer := DisplayServer.mouse_get_position() if _use_os_window else _geometry.get_center()
	start_drag(pointer)

func handle_move() -> void:
	if not _dragging:
		return
	var pointer := DisplayServer.mouse_get_position() if _use_os_window else _geometry.get_center()
	drag_to(pointer)

func handle_release() -> void:
	if not _dragging:
		return
	var pointer := DisplayServer.mouse_get_position() if _use_os_window else _geometry.get_center()
	end_drag(pointer)

## 点击入口后松手展开；按住并移动超过阈值则进入拖拽。
func start_drag(pointer: Vector2i) -> void:
	if not _enabled or _transitioning or _expanded:
		return
	_dragging = true
	_drag_moved = false
	_drag_start_pointer = pointer
	_drag_start_geometry = _geometry
	_collapse_at = -1

func drag_to(pointer: Vector2i) -> void:
	if not _dragging or not _enabled:
		return
	var delta := pointer - _drag_start_pointer
	if not _drag_moved and delta.length() < DRAG_THRESHOLD:
		return
	_drag_moved = true
	var next := _drag_start_geometry
	next.position += delta
	next.position.x = clampi(next.position.x, _screen_rect.position.x, _screen_rect.end.x - next.size.x)
	next.position.y = clampi(next.position.y, _screen_rect.position.y, _screen_rect.end.y - next.size.y)
	_apply_geometry(next)

func end_drag(pointer: Vector2i) -> void:
	if not _dragging:
		return
	drag_to(pointer)
	var moved := _drag_moved
	_dragging = false
	_drag_moved = false
	if not moved:
		activate_handle()
		return
	var target := _nearest_edge(pointer)
	var available := _screen_rect.size
	var size := _geometry.size
	if target in ["left", "right"]:
		handle_vertical_ratio = clampf(float(_geometry.position.y - _screen_rect.position.y) / float(maxi(available.y - size.y, 1)), 0.0, 1.0)
	else:
		handle_horizontal_ratio = clampf(float(_geometry.position.x - _screen_rect.position.x) / float(maxi(available.x - size.x, 1)), 0.0, 1.0)
	set_anchor_edge(target)
	_apply_geometry(_rect_for(false))

func is_dragging() -> bool:
	return _dragging

func _nearest_edge(pointer: Vector2i) -> String:
	var p := Vector2(pointer)
	var r := _screen_rect
	var distances := {
		"left": absf(p.x - float(r.position.x)),
		"right": absf(float(r.end.x) - p.x),
		"top": absf(p.y - float(r.position.y)),
		"bottom": absf(float(r.end.y) - p.y),
	}
	var best := "right"
	var best_distance := INF
	for edge in ["left", "right", "top", "bottom"]:
		if float(distances[edge]) < best_distance:
			best = edge
			best_distance = float(distances[edge])
	return best

## 连接图标按钮 pressed；透明留白不绑定点击，避免空白处误展开。
func activate_handle() -> void:
	if not _enabled:
		return
	expand()
	_take_focus()

func _take_focus() -> void:
	if _use_os_window and _window and _window.unfocusable:
		_window.unfocusable = false
		_window.grab_focus()

func _set_handle_hovered(value: bool) -> void:
	value = value and not _expanded and not _transitioning
	if value == _handle_hovered:
		return
	_handle_hovered = value
	handle_hovered.emit(value)

func _handle_hit(pointer: Vector2i) -> bool:
	if _expanded:
		return _geometry.has_point(pointer)
	var scale := maxf(get_handle_scale(), 0.01)
	var local := Vector2(pointer - _geometry.position) / scale
	return Rect2(Vector2(12, 44), Vector2(144, 144)).has_point(local)

func _update_hover(pointer: Vector2i, now: int) -> void:
	var inside := _handle_hit(pointer)
	if inside:
		_collapse_at = -1
	else:
		if _expanded and not _pinned and _collapse_at < 0:
			_collapse_at = now + int(LEAVE_DELAY * 1000.0)
	_mouse_inside = inside
	_set_handle_hovered(inside)

func _tick_at(now: int) -> void:
	if _transitioning:
		return
	if _collapse_at >= 0 and now >= _collapse_at:
		if _pinned or _mouse_inside:
			_collapse_at = -1
		elif _can_collapse():
			_start_transition(false)
		# 操作未完成时保留到期请求；操作结束的下一帧继续收起。

func _on_mouse_entered() -> void:
	if not _enabled or _transitioning:
		return
	_mouse_inside = true
	_collapse_at = -1
	_set_handle_hovered(not _expanded)

func _on_mouse_exited() -> void:
	if not _enabled or _transitioning:
		return
	_mouse_inside = false
	_set_handle_hovered(false)
	if _expanded and not _pinned:
		_collapse_at = Time.get_ticks_msec() + int(LEAVE_DELAY * 1000.0)

func expand() -> void:
	if not _enabled:
		return
	_collapse_at = -1
	if (_transitioning and _transition_target) or (_expanded and not _transitioning):
		return
	_start_transition(true)

## 原 pin() 的兼容入口，现在会真正保持展开；pin(false) 恢复自动收起。
func pin(value := true) -> void:
	if not _enabled:
		return
	set_pinned(value)
	if value:
		expand()

func set_pinned(value: bool) -> void:
	if _pinned == value:
		return
	_pinned = value
	_collapse_at = -1
	pinned_changed.emit(value)
	if value:
		expand()
	elif _expanded and not _mouse_inside:
		_collapse_at = Time.get_ticks_msec() + int(LEAVE_DELAY * 1000.0)

func toggle_pin() -> void:
	set_pinned(not _pinned)

func is_pinned() -> bool:
	return _pinned

func collapse_now() -> void:
	if not _enabled or not _can_collapse():
		return
	set_pinned(false)
	_collapse_at = -1
	if (_transitioning and not _transition_target) or (not _expanded and not _transitioning):
		return
	_start_transition(false)

func is_expanded() -> bool:
	return _expanded

func is_transitioning() -> bool:
	return _transitioning

func get_expanded_size() -> Vector2i:
	return _rect_for(true).size

func set_expanded_size(value: Vector2i) -> void:
	expanded_size = value
	if _enabled and not _transitioning:
		_apply_geometry(_rect_for(_expanded))

## 百分比档位在不同分辨率及移动到另一块屏幕时仍使用足够大的工作区。
func set_size_fraction(value: float) -> void:
	_size_fraction = clampf(value, 0.50, 1.0)
	if _enabled and not _transitioning:
		_apply_geometry(_rect_for(_expanded))

## 语义别名：UI 可直接以工作区比例设置窗口大小。
func set_size_ratio(value: float) -> void:
	set_size_fraction(value)

func get_size_ratio() -> float:
	return _size_fraction

func _can_collapse() -> bool:
	return not can_collapse.is_valid() or bool(can_collapse.call())

## 纯几何变换：窄窗口不变；不通过压扁卡面或改变高度消除留白。
static func crop_empty_sides(requested: Vector2i) -> Vector2i:
	return Vector2i(mini(requested.x, maxi(1, floori(requested.y * MAX_EXPANDED_ASPECT))), requested.y)

func _rect_for(expanded: bool) -> Rect2i:
	var preferred := expanded_size if expanded else collapsed_size
	var available := _screen_rect.size
	if available.x <= 0 or available.y <= 0:
		available = expanded_size
	if expanded and _size_fraction > 0.0:
		preferred = Vector2i(roundi(available.x * _size_fraction), roundi(available.y * _size_fraction))
	var size := Vector2i(clampi(preferred.x, 1, available.x), clampi(preferred.y, 1, available.y))
	if expanded:
		size = crop_empty_sides(size)
	var x := _screen_rect.position.x + roundi(float(available.x - size.x) * clampf(handle_horizontal_ratio, 0.0, 1.0))
	var y := _screen_rect.position.y + roundi(float(available.y - size.y) * clampf(handle_vertical_ratio, 0.0, 1.0))
	match anchor_edge:
		"left": x = _screen_rect.position.x
		"right": x = _screen_rect.end.x - size.x
		"top": y = _screen_rect.position.y
		"bottom": y = _screen_rect.end.y - size.y
	return Rect2i(Vector2i(x, y), size)

func _refresh_screen_rect() -> bool:
	if not _use_os_window or _window == null:
		return false
	var screen := clampi(_window.current_screen, 0, maxi(DisplayServer.get_screen_count() - 1, 0))
	var rect := DisplayServer.screen_get_usable_rect(screen)
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen))
	var changed := rect != _screen_rect
	_screen_rect = rect
	return changed

func _apply_geometry(rect: Rect2i) -> void:
	_geometry = rect
	if _use_os_window and _window:
		_window.size = rect.size
		_window.position = rect.position

func _create_transition_cover() -> void:
	_cover_layer = CanvasLayer.new()
	_cover_layer.layer = 128
	add_child(_cover_layer)
	_cover = TextureRect.new()
	_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cover.stretch_mode = TextureRect.STRETCH_KEEP
	_cover.visible = false
	_cover_layer.add_child(_cover)

func _capture_snapshot() -> void:
	if not _use_os_window or _window == null or (_cover and _cover.visible):
		return
	var image := _window.get_texture().get_image()
	if image != null and not image.is_empty():
		_snapshot = ImageTexture.create_from_image(image)

func _start_transition(expanded: bool) -> void:
	var previous := _expanded
	var reversing := _transitioning
	if _transition_tween and _transition_tween.is_valid():
		_transition_tween.kill()
	_collapse_at = -1
	_transitioning = true
	_set_handle_hovered(false)
	_transition_target = expanded
	transition_started.emit(expanded)
	if not expanded and not reversing:
		_capture_snapshot()
	if expanded:
		_expanded = true
		if _use_os_window:
			_window.disable_3d = _original_disable_3d
		if not previous:
			expanded_changed.emit(true)
	if not _use_os_window or not animations_enabled:
		_finish_transition(expanded)
		return
	if _snapshot:
		_cover.texture = _snapshot
		_cover.size = Vector2(_snapshot.get_size())
		_cover.visible = true
	# 只沿吸附边的法线轴收放。另一轴先恢复完整尺寸，画面始终1:1裁切。
	var axis := _transition_axis()
	var current_extent := _geometry.size[axis]
	var target_extent := _rect_for(expanded).size[axis]
	_animate_extent(float(current_extent))
	_transition_tween = create_tween()
	_transition_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_transition_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_transition_tween.tween_method(_animate_extent, float(current_extent), float(target_extent), EXPAND_DURATION if expanded else COLLAPSE_DURATION)
	_transition_tween.tween_callback(_finish_transition.bind(expanded))

func _animate_extent(extent: float) -> void:
	var full_rect := _rect_for(true)
	var rect := full_rect
	var axis := _transition_axis()
	rect.size[axis] = clampi(roundi(extent), 1, full_rect.size[axis])
	if anchor_edge in ["right", "bottom"]:
		rect.position[axis] = full_rect.end[axis] - rect.size[axis]
	_apply_geometry(rect)
	if _cover:
		_cover.position = Vector2.ZERO
		# 顶/左入口处，画面的内侧边缘随窗口向内移动；底/右则由窗口原点移动。
		# 快照保持原始像素大小，不把牌桌压扁到过渡中的小窗口里。
		if anchor_edge in ["left", "top"]:
			_cover.position[axis] = float(rect.size[axis]) - _cover.size[axis]

func _finish_transition(expanded: bool) -> void:
	var changed := _expanded != expanded
	if _transition_tween and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null
	_expanded = expanded
	_transition_target = expanded
	_transitioning = false
	_collapse_at = -1
	_apply_geometry(_rect_for(expanded))
	if _use_os_window:
		_window.disable_3d = _original_disable_3d if expanded else true
		if not expanded:
			_window.unfocusable = true
	if changed:
		expanded_changed.emit(expanded)
	transition_finished.emit(expanded)
	if not expanded:
		call_deferred("_announce_handle")
	if _cover:
		_cover.visible = false
		_cover.position = Vector2.ZERO
	# 自己变更窗口造成的 mouse_exited 不参与下一轮判断。
	# 下一帧全局坐标轮询会重新开始完整的离开延迟。
	_mouse_inside = false
