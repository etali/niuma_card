# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"
const Art = preload("res://scenes/hand_art.gd")

## Headless 只替换系统边界，仍运行真实姿势选择、资源缓存和所有权逻辑。
class CountingHands extends "res://scenes/table_hands.gd":
	var supported := true
	var magnification := 1.0
	var installations: Array = []
	var shapes := {}   # 系统光标形状 → 当前图片；null = 系统默认
	var draws := 0
	var painted_hands := 0
	var painted: Array = []
	func _supports_native_cursor() -> bool:
		return supported
	func _native_cursor_scale() -> float:
		return magnification
	func _apply_cursor(image: Image, hotspot := Vector2.ZERO, text_too := false) -> void:
		installations.append({"image": image, "hotspot": hotspot})
		super._apply_cursor(image, hotspot, text_too)
	func _set_shape_cursor(image: Image, shape: int, _hotspot: Vector2) -> void:
		shapes[shape] = image
	func paint(canvas: Control) -> void:
		draws += 1
		super.paint(canvas)
	func _hand(canvas: Control, at: Vector2, angle: float, zoom: float, grip: bool, angry: bool, opacity: float) -> void:
		painted_hands += 1
		painted.append({"at": at, "grip": grip, "zoom": zoom})
		super._hand(canvas, at, angle, zoom, grip, angry, opacity)

class FakeBoard extends RefCounted:
	var _drag_cards: Array = []
	var attack_mode := false
	var touch_mode := false
	var hand_point := Vector3.INF
	var target: CardEntity = null
	func drag_hand_point() -> Vector3:
		return hand_point if not _drag_cards.is_empty() else Vector3.INF
	func _pick_card(_pointer: Vector2) -> CardEntity:
		return target

class CursorHost extends Node:
	var board := FakeBoard.new()
	var drawer_presentation: Node
	var mobile_mode := false
	var blocked := false
	var _attack_hl := {}
	var _player_attack_busy := 0
	func _drawer_input_blocked() -> bool:
		return blocked

class Presentation extends Node:
	var over_panels := false
	var table := Rect2(-10000, -10000, 20000, 20000)
	func content_rect() -> Rect2:
		return table
	func pointer_over_panels(_pointer: Vector2) -> bool:
		return over_panels

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_images()
	_test_cursor_lifecycle()
	await _test_game_area()
	await _test_tear_canvas()
	await _test_drag_hand()
	await _test_real_table_same_frame()
	finish()

func _test_images() -> void:
	for canvas_scale in [0.65, 1.0, 1.5]:
		for dpi in [1.0, 2.0, 3.0]:
			var scale_factor := Art.cursor_scale(canvas_scale, dpi)
			check(absf(scale_factor * dpi - canvas_scale) <= 0.075,
				"%s × %s DPI 的系统逻辑尺寸保持原手形实际尺寸" % [canvas_scale, dpi])
			for mode in ["point", "grip", "angry"]:
				var cursor := Art.cursor(mode, scale_factor)
				if not need(not cursor.is_empty(), "%s × %s 手形可解码" % [mode, scale_factor]):
					continue
				var image: Image = cursor.image
				var bounds := Rect2i(Vector2i.ZERO, image.get_size())
				var used := image.get_used_rect()
				check(image.get_width() <= 128 and image.get_height() <= 128
					and used.has_area() and bounds.has_point(cursor.hotspot), "图片满足 Web 上限，热点位于图片内")
				check(used.position.x > 0 and used.position.y > 0
					and used.end.x < bounds.end.x and used.end.y < bounds.end.y,
					"三种姿势含描边与怒纹都保留透明边，不裁掉轮廓")
				check(Art.cursor(mode, scale_factor).image == image, "同姿势与尺寸复用预渲染图片")
	var point: Image = Art.cursor("point", 1.0).image
	var grip: Image = Art.cursor("grip", 1.0).image
	var angry: Image = Art.cursor("angry", 1.0).image
	check(point.get_data() != grip.get_data() and point.get_data() != angry.get_data(),
		"普通、拖动与攻击状态确实有不同手形")
	check(Art.cursor_scale(1.0, 1.0) == Art.cursor_scale(1.001, 1.0),
		"窗口微小尺寸变化不产生新的光标图片")

func _new_hands(host: CursorHost) -> CountingHands:
	var hands := CountingHands.new()
	host.add_child(hands)
	hands.bind(host)
	hands.set_process(false)
	hands._pointing = true
	return hands

func _test_cursor_lifecycle() -> void:
	var host := CursorHost.new()
	root.add_child(host)
	var hands := _new_hands(host)
	var mouse_mode := Input.mouse_mode
	for frame in 60:
		hands._pointer = Vector2(frame * 5, frame * 3)
		hands._update_cursor()
	check(hands.installations.size() == 1 and hands.installations.back().image == Art.cursor("point", 1.0).image,
		"移动 60 帧只安装一次系统光标，位置交给系统更新")
	host.board._drag_cards.append(1)
	hands._update_cursor()
	check(hands.installations.size() == 2 and hands.installations.back().image == Art.cursor("grip", 1.0).image,
		"开始拖动切换抓握手形")
	host.board._drag_cards.clear()
	hands._angry = true
	hands._update_cursor()
	check(hands.installations.size() == 3 and hands.installations.back().image == Art.cursor("angry", 1.0).image,
		"可攻击目标切换带怒纹的手形")
	hands.magnification = 0.5
	hands._update_cursor()
	check(hands.installations.back().image == Art.cursor("angry", 0.5).image, "DPI 或窗口变化当帧切换正确尺寸")
	hands._angry = false
	hands.magnification = 1.0
	hands._update_cursor()
	var point: Image = Art.cursor("point", 1.0).image
	var others := range(DisplayServer.CURSOR_MAX).filter(func(shape): return shape != Input.CURSOR_IBEAM)
	check(others.all(func(shape): return hands.shapes.get(shape) == point),
		"按钮手指、小人拖动等全部形状统一为简笔手")
	check(hands.shapes.has(Input.CURSOR_IBEAM) and hands.shapes[Input.CURSOR_IBEAM] == null,
		"文字输入框保留系统文本光标")
	hands._pointing = false
	hands._update_cursor()
	check(hands.installations.back().image == null and hands.shapes.values().all(func(image): return image == null),
		"移出游戏窗口或失焦后全部形状恢复系统默认光标")
	var count := hands.installations.size()
	hands._update_cursor()
	check(hands.installations.size() == count, "已还原光标无需每帧重复调用系统")
	hands._pointing = true
	hands._update_cursor()
	var successor := _new_hands(host)
	successor._update_cursor()
	var predecessor_calls := hands.installations
	count = predecessor_calls.size()
	hands.free()
	check(predecessor_calls.size() == count and successor.installations.size() == 1,
		"旧场景退出不清掉新场景持有的光标")
	successor.clear()
	check(successor.installations.back().image == null, "清空场景恢复默认光标")
	successor.supported = false
	count = successor.installations.size()
	successor._update_cursor()
	check(successor.installations.size() == count and Input.mouse_mode == mouse_mode,
		"平台不支持自定义光标时保留系统光标，不隐藏指针")
	successor.supported = true
	successor._update_cursor()
	host.remove_child(successor)
	check(successor.installations.back().image == null, "离开场景树也恢复系统默认光标")
	successor.free()
	host.free()

func _test_tear_canvas() -> void:
	var host := CursorHost.new()
	root.add_child(host)
	host.drawer_presentation = Presentation.new()
	host.add_child(host.drawer_presentation)
	var hands := _new_hands(host)
	for frame in 60:
		hands._process(1.0 / 60.0)
	check(not hands._canvas.visible and hands.painted_hands == 0,
		"无撕牌批次的 60 帧不绘制软件指针")
	var original_outline := Art.outline(true).duplicate()
	hands._batches.append({"bounds": Rect2(100, 100, 90, 130), "elapsed": 0.0, "count": 7})
	hands._process(0.2)
	await process_frame
	await process_frame
	check(hands._canvas.visible and hands.painted_hands == 2,
		"一批七张牌仍由场景绘制一双撕牌手")
	check(Art.outline(true) == original_outline, "绘制闭合描边不修改共享轮廓缓存")
	host.blocked = true
	hands._process(0.2)
	check(not hands._canvas.visible and is_equal_approx(hands._batches[0].elapsed, 0.2),
		"抽屉阻塞时隐藏双手并暂停批次时间")
	host.blocked = false
	hands._process(0.2)
	await process_frame
	await process_frame
	check(hands.painted_hands == 4 and Art.outline(true) == original_outline,
		"恢复后继续绘制同一双手，连续绘制不增长轮廓")
	hands._process(hands.DURATION)
	check(not hands._canvas.visible and hands._batches.is_empty(), "撕牌结束后隐藏绘制层")
	host.free()

## 拖动时手由场景与牌同帧绘制：系统光标藏起，交接完成前保留握拳光标。
func _test_drag_hand() -> void:
	var host := CursorHost.new()
	root.add_child(host)
	host.drawer_presentation = Presentation.new()
	host.add_child(host.drawer_presentation)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees = Vector3(-71, 0, 0)
	camera.make_current()
	var hands := _new_hands(host)
	var step := 1.0 / 60.0
	await _move_pointer(root.get_visible_rect().get_center())
	var hidden: Image = Art.cursor("hidden", 1.0).image
	check(hidden.get_size() == Vector2i.ONE and hidden.get_pixel(0, 0).a == 0.0, "拖动用的系统光标是透明图")
	var grab := Vector3(1.5, Board.DRAG_HEIGHT, 2.0)
	host.board.hand_point = grab
	host.board._drag_cards.append(1)
	hands._process(step)
	check(hands._canvas.visible and hands.installations.back().image == Art.cursor("grip", 1.0).image,
		"抓起当帧先画场景手，系统握拳光标留到交接完成")
	for frame in hands.HANDOFF_FRAMES:
		hands._process(step)
	check(hands.installations.back().image == hidden, "交接完成后系统光标换成透明图")
	check(hands.shapes.get(Input.CURSOR_IBEAM) == hidden and hands.shapes.get(Input.CURSOR_POINTING_HAND) == hidden,
		"拖动中文本光标、按钮手指也一并藏起，只剩场景手")
	var installs := hands.installations.size()
	for frame in 30:
		hands._process(step)
	check(hands.installations.size() == installs, "拖动途中不反复安装系统光标")
	hands.painted.clear()
	await process_frame
	await process_frame
	check(hands.painted.size() == 1 and hands.painted[0].grip, "拖动中只画一只抓握手")
	if hands.painted.size() == 1:
		check(hands.painted[0].at.distance_to(camera.unproject_position(grab)) < 0.5,
			"手画在 Board 给出的抓取点上，与牌同帧")
		# 系统光标按逻辑点 × 像素倍率显示；画布还要乘视口拉伸才是实际像素
		var native_pixels := hands.magnification * hands._native_pixel_scale()
		var stretch_mode := root.content_scale_mode
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		check(is_equal_approx(hands._drag_hand_scale(), native_pixels), "无拉伸时场景手与系统光标同一尺寸")
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		var stretch := root.get_final_transform().get_scale().x
		check(not is_equal_approx(stretch, 1.0) and is_equal_approx(hands._drag_hand_scale() * stretch, native_pixels),
			"视口拉伸时场景手按实际像素与系统光标同一尺寸")
		root.content_scale_mode = stretch_mode
	grab = Vector3(-2.0, Board.DRAG_HEIGHT, 3.0)
	host.board.hand_point = grab
	hands._process(step)
	check(hands._drag_hand.distance_to(camera.unproject_position(grab)) < 0.5, "抓取点移动当帧手跟着移动")
	host.drawer_presentation.over_panels = true
	hands._process(step)
	check(hands._drag_hand != Vector2.INF and hands.installations.back().image == hidden,
		"划过侧边面板仍画手、藏系统光标")
	host.drawer_presentation.over_panels = false
	host.drawer_presentation.table = Rect2(-20000, -20000, 1, 1)
	hands._process(step)
	check(hands._drag_hand != Vector2.INF and hands.installations.back().image == hidden, "拖出牌桌区域仍画手")
	host.drawer_presentation.table = Rect2(-10000, -10000, 20000, 20000)
	await _move_pointer(root.get_visible_rect().end + Vector2(80, 80))
	hands._process(step)
	check(hands._drag_hand != Vector2.INF and hands.installations.back().image == hidden, "拖动中鼠标移出窗口手仍随牌")
	await _move_pointer(root.get_visible_rect().get_center())
	host.board._drag_cards.clear()
	hands._process(step)
	check(hands._drag_hand == Vector2.INF and not hands._canvas.visible
		and hands.installations.back().image == Art.cursor("point", 1.0).image, "松手当帧恢复系统指向手，不再画场景手")
	check(hands.shapes.get(Input.CURSOR_IBEAM) == null, "松手后文本光标恢复系统竖线")
	host.drawer_presentation.over_panels = false
	host.board.touch_mode = true
	host.board._drag_cards.append(1)
	for frame in hands.HANDOFF_FRAMES + 2:
		hands._process(step)
	check(hands._drag_hand == Vector2.INF and hands.installations.back().image == Art.cursor("grip", 1.0).image,
		"触屏拖动不画场景手，也不藏系统光标")
	host.board.touch_mode = false
	hands.supported = false
	for frame in hands.HANDOFF_FRAMES + 2:
		hands._process(step)
	check(hands._drag_hand == Vector2.INF and not hands._canvas.visible, "系统光标藏不掉的平台不画第二只手")
	hands.supported = true
	for frame in hands.HANDOFF_FRAMES + 2:
		hands._process(step)
	hands.clear()
	check(hands._drag_hand == Vector2.INF and not hands._canvas.visible and hands.installations.back().image == null,
		"清空场景同时撤下场景手并恢复系统光标")
	host.free()

## 事件在下一帧开头才送达，再等一帧读到的鼠标位置才是新的
func _move_pointer(at: Vector2) -> void:
	_pointer_event(at)
	await process_frame
	await process_frame

## at 是视口坐标；系统事件用窗口坐标，根窗口拉伸时要先换算
func _pointer_event(at: Vector2, button := -1) -> void:
	var event: InputEventMouse
	if button < 0:
		event = InputEventMouseMotion.new()
	else:
		event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = button == 1
	var window_at := root.get_final_transform() * at
	event.position = window_at
	event.global_position = window_at
	Input.parse_input_event(event)

## 真实牌桌：鼠标每帧都在动，场景手必须落在 Board 本帧摆牌用的那一点上；
## TableHands 若排在 Board 之前，读到的是上一帧的牌位，手会落后一帧。
func _test_real_table_same_frame() -> void:
	root.size = Vector2i(1600, 900)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = 1.0
	root.add_child(main)
	_booted = main
	await settle()
	main.drawer_window.activate_handle()
	main.drawer_window.pin()
	var record: Dictionary = main.state.add_card(main.my_seat, "cash")
	var card: CardEntity = main._spawn_entity(record, Vector3(0, 0.3, 3.0), true)
	main._sync_entities()
	await settle()
	# Headless 不支持自定义光标，原 TableHands 不画手；另挂一只只替换系统边界的
	var hands := CountingHands.new()
	main.add_child(hands)
	# 挂在 Board 之前：树序会让它先跑，只有 process_priority 能把它排到摆牌之后
	main.move_child(hands, 0)
	hands.bind(main)
	var at: Vector2 = main.board.camera.unproject_position(card.global_position)
	_pointer_event(at)
	await process_frame
	_pointer_event(at, 1)
	await process_frame
	if not need(main.board._drag_cards.has(card), "真实牌桌按下即拎起牌"):
		return
	var worst := 0.0
	var mouse := at
	# process_frame 在本帧节点处理之前发出：事件在帧首送达，再等一帧读的才是
	# 这一帧处理完的结果。若手排在 Board 之前，读到的仍是上一个鼠标点
	for i in 20:
		mouse = at + Vector2(i * 9.0, -i * 4.0)
		_pointer_event(mouse)
		await process_frame
		await process_frame
		worst = maxf(worst, hands._drag_hand.distance_to(mouse))
	check(hands._drag_hand_frames > hands.HANDOFF_FRAMES and worst < 0.5,
		"鼠标每帧移动时场景手落在本帧鼠标点上，与牌同帧（最大偏差 %.2f px）" % worst)
	_pointer_event(mouse, 0)
	await process_frame
	await process_frame
	check(main.board._drag_cards.is_empty() and hands._drag_hand == Vector2.INF, "真实牌桌松手后撤下场景手")
	# 「怎么玩」面板：按钮声明的是手指形状，系统按形状取图，这一形状也得是简笔手
	var p: Node = main.drawer_presentation
	p._learning_invitation.hide()
	p._open_utility(p.UTILITY_RULEBOOK)
	await create_timer(0.3).timeout
	var buttons: Array = p._rulebook.find_children("*", "Button", true, false) \
		.filter(func(b): return b.is_visible_in_tree())
	var point: Image = Art.cursor("point", hands._native_cursor_scale()).image
	if need(not buttons.is_empty(), "「怎么玩」面板有可见按钮"):
		var button: Button = buttons[0]
		var center := button.get_global_rect().get_center()
		await _move_pointer(center)
		check(p.pointer_over_panels(center) and hands._pointing and hands.installations.back().image == point,
			"「怎么玩」面板上是简笔手")
		check(hands.shapes.get(button.get_cursor_shape(button.get_local_mouse_position())) == point,
			"面板按钮的手指形状也换成简笔手")
	p.close_panels()
	var field := LineEdit.new()
	main.add_child(field)
	check(hands.shapes.get(field.get_cursor_shape(Vector2.ZERO), point) == null, "文字输入框的形状保留系统文本光标")
	field.queue_free()
	hands.queue_free()

## 游戏窗口内统一为简笔手：面板、牌桌外的栏位都一样；只有移出窗口才还给系统。
func _test_game_area() -> void:
	var host := CursorHost.new()
	root.add_child(host)
	host.drawer_presentation = Presentation.new()
	host.add_child(host.drawer_presentation)
	var hands := _new_hands(host)
	var step := 1.0 / 60.0
	var point: Image = Art.cursor("point", 1.0).image
	var inside := root.get_visible_rect().get_center()
	await _move_pointer(inside)
	hands._process(step)
	check(hands._pointing and hands.installations.back().image == point, "牌桌上是简笔手")
	host.drawer_presentation.over_panels = true
	hands._process(step)
	check(hands._pointing and hands.installations.back().image == point, "「怎么玩」等面板上同样是简笔手")
	host.drawer_presentation.over_panels = false
	host.drawer_presentation.table = Rect2(-20000, -20000, 1, 1)
	hands._process(step)
	check(hands._pointing and hands.installations.back().image == point, "牌桌外的顶栏、底栏也是简笔手")
	host.drawer_presentation.table = Rect2(-10000, -10000, 20000, 20000)
	# 怒手只指牌桌上的目标；同一张牌被面板挡住时不发怒
	var target := CardEntity.new()
	host.board.target = target
	host._attack_hl[target] = true
	host.board.attack_mode = true
	hands._process(step)
	check(hands.installations.back().image == Art.cursor("angry", 1.0).image, "牌桌上的攻击目标显示怒手")
	host.drawer_presentation.over_panels = true
	hands._process(step)
	check(hands.installations.back().image == point, "面板挡住攻击目标时仍是普通简笔手")
	host.drawer_presentation.over_panels = false
	host.board.attack_mode = false
	host.board.target = null
	target.free()
	await _move_pointer(root.get_visible_rect().end + Vector2(80, 80))
	hands._process(step)
	check(not hands._pointing and hands.installations.back().image == null, "移出游戏窗口后还给系统光标")
	await _move_pointer(inside)
	host.blocked = true
	hands._process(step)
	check(hands.installations.back().image == null, "抽屉收起或切换中还给系统光标")
	host.blocked = false
	hands._process(step)
	host.mobile_mode = true
	hands._process(step)
	check(hands.installations.back().image == null, "手机模式不使用简笔手光标")
	host.mobile_mode = false
	hands.clear()
	host.free()
