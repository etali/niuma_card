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
	var draws := 0
	var painted_hands := 0
	func _supports_native_cursor() -> bool:
		return supported
	func _native_cursor_scale() -> float:
		return magnification
	func _apply_cursor(image: Image, hotspot := Vector2.ZERO) -> void:
		installations.append({"image": image, "hotspot": hotspot})
	func paint(canvas: Control) -> void:
		draws += 1
		super.paint(canvas)
	func _hand(canvas: Control, at: Vector2, angle: float, zoom: float, grip: bool, angry: bool, opacity: float) -> void:
		painted_hands += 1
		super._hand(canvas, at, angle, zoom, grip, angry, opacity)

class CursorHost extends Node:
	var board := {"_drag_cards": [], "attack_mode": false}
	var drawer_presentation: Node
	var mobile_mode := false
	var blocked := false
	func _drawer_input_blocked() -> bool:
		return blocked

class Presentation extends Node:
	func content_rect() -> Rect2:
		return Rect2(-10000, -10000, 20000, 20000)
	func pointer_over_panels(_pointer: Vector2) -> bool:
		return false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_images()
	_test_cursor_lifecycle()
	await _test_tear_canvas()
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
	hands._pointing = false
	hands._update_cursor()
	check(hands.installations.back().image == null, "移出牌桌或进入面板后恢复系统默认光标")
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
