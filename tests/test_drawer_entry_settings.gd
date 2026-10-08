# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

## 通过真实菜单按钮检查抽屉比例设置与入口显示尺寸，防止只改变原生窗口而裁切图标。
## 在普通屏和 Retina 屏各走一遍，UI、入口视觉和窗口几何必须使用同一套缩放。
const Drawer = preload("res://scenes/drawer_window.gd")
const ENTRY_LOGICAL_SIZE := Vector2(168, 192)
const WINDOW_RATIOS := [0.75, 0.85, 0.92, 0.98]
const ICON_RATIOS := [0.75, 1.0, 1.25]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉入口与比例设置集成 ===")
	for dpi in [1.0, 2.0]:
		var main := await boot_drawer(Vector2i(roundi(1600 * dpi), roundi(1000 * dpi)), float(dpi))
		if not need(is_instance_valid(main), "抽屉场景在 %s 倍显示缩放下启动" % dpi):
			continue
		var presentation: Node = main.get("drawer_presentation")
		var drawer: Node = main.get("drawer_window")
		if not need(presentation != null and drawer != null, "完整抽屉呈现与窗口控制器已连接"):
			await dispose_drawer(main)
			continue
		if not need(drawer.has_method("get_size_ratio") and drawer.has_method("get_icon_scale") \
				and drawer.has_method("get_handle_scale"), "窗口公开比例与入口缩放接口"):
			await dispose_drawer(main)
			continue
		drawer.animations_enabled = false
		_check_menu_wording(presentation)
		_check_window_ratio_buttons(presentation, drawer)
		await _check_icon_ratio_buttons(presentation, drawer, float(dpi))
		await dispose_drawer(main)
	finish()

func _check_menu_wording(presentation: Node) -> void:
	var menu: MenuButton = presentation.get("_menu")
	if not need(menu != null, "选项菜单可见"):
		return
	var popup := menu.get_popup()
	var found_ratio := false
	var found_icon := false
	for i in popup.item_count:
		var text := popup.get_item_text(i)
		found_ratio = found_ratio or text == "UI"
		found_icon = found_icon or text == "入口大小"
		check(_uses_no_resolution_units(text), "菜单文案不出现像素分辨率：%s" % text)
	check(found_ratio and found_icon, "菜单同时提供UI与入口大小")

func _check_window_ratio_buttons(presentation: Node, drawer: Node) -> void:
	presentation._open_utility(3)
	var body: Node = presentation.get("_utility_body")
	_check_control_wording(body)
	var buttons: Array[Button] = []
	for button in _buttons_in(body):
		if button.text.begins_with("工作区 "):
			buttons.append(button)
	check(buttons.size() == WINDOW_RATIOS.size(), "窗口提供四个工作区比例按钮")
	check(body.find_child("ResetTableView", true, false) == null, "UI移除独立还原全桌按钮")
	check(presentation._ui_footer.find_child("ResetUISettings", true, false) is Button, "UI外层提供统一还原默认")
	for i in mini(buttons.size(), WINDOW_RATIOS.size()):
		var button: Button = buttons[i]
		var expected := float(WINDOW_RATIOS[i])
		check("%" in button.text, "窗口尺寸选项显示百分比")
		button.pressed.emit()
		check(is_equal_approx(float(drawer.get_size_ratio()), expected), \
			"%s 按钮确实设置自身比例" % button.text)
		var available: Rect2i = drawer.get("_screen_rect")
		var expanded: Vector2i = drawer.get_expanded_size()
		var target := Vector2i(roundi(available.size.x * expected), roundi(available.size.y * expected))
		check(expanded == Drawer.crop_empty_sides(target), "%s 以工作区比例为上限裁去左右空白" % button.text)
		check(expanded.y == target.y and expanded.x <= target.x, "%s 裁剪只限宽度，保留该档高度" % button.text)
	presentation.close_panels()
	check(not presentation.panels_open(), "关闭窗口比例设置后工具页隐藏")

func _check_icon_ratio_buttons(presentation: Node, drawer: Node, dpi: float) -> void:
	var handle: Control = presentation.get("_handle")
	if not need(handle != null, "抽屉入口控件存在"):
		return
	for i in ICON_RATIOS.size():
		drawer.expand()
		presentation._open_utility(4)
		var body: Node = presentation.get("_utility_body")
		_check_control_wording(body)
		var buttons := _buttons_in(body)
		if not need(buttons.size() == ICON_RATIOS.size(), "入口提供三个比例大小按钮"):
			presentation.close_panels()
			continue
		var button: Button = buttons[i]
		var expected := float(ICON_RATIOS[i])
		check("%" in button.text, "入口大小选项显示百分比")
		button.pressed.emit()
		check(is_equal_approx(float(drawer.get_icon_scale()), expected), \
			"%s 设置独立于 DPI 的图标比例" % button.text)
		check(is_equal_approx(float(drawer.get_handle_scale()), dpi * expected), \
			"入口系统尺寸同时应用 DPI 与用户比例")
		presentation.close_panels()
		drawer.collapse_now()
		await process_frame
		check(not drawer.is_expanded(), "选择入口大小后可以正常自动收起")
		check(handle.visible, "收起后入口完整显示")
		check(handle.size.is_equal_approx(ENTRY_LOGICAL_SIZE * dpi * expected), "入口按最终像素尺寸排版，不放大小字号文字")
		var geometry: Rect2i = drawer.get("_geometry")
		var visual := _visual_rect(handle)
		var expected_size := ENTRY_LOGICAL_SIZE * dpi * expected
		check(visual.position.is_equal_approx(Vector2.ZERO), "入口画面从透明窗口原点开始")
		check(visual.size.is_equal_approx(expected_size), "入口视觉大小与选项比例一致")
		check(visual.size.is_equal_approx(Vector2(geometry.size)), \
			"%s倍DPI/%s%%入口视觉边界匹配窗口边界" % [dpi, roundi(expected * 100)])
		_check_entry_content_inside(handle, Rect2(Vector2.ZERO, Vector2(geometry.size)))
		drawer.expand()
		await process_frame

func _check_entry_content_inside(handle: Control, window_rect: Rect2) -> void:
	var icon: TextureRect = handle.get_node_or_null("Icon")
	if need(icon != null, "入口显示实际游戏图标"):
		check(icon.texture != null, "游戏图标纹理已加载")
		check(icon.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "图标保持原始比例")
		check(window_rect.grow(0.5).encloses(_visual_rect(icon)), "图标四边留在透明窗口内")
	var bubble: Control = handle.get_node_or_null("Greeting")
	if need(bubble != null, "入口招呼气泡存在"):
		check(window_rect.grow(0.5).encloses(_visual_rect(bubble)), "招呼气泡四边留在透明窗口内")
	check(not handle.clip_contents, "入口不裁剪招手视觉")

func _visual_rect(control: Control) -> Rect2:
	var transform := control.get_global_transform_with_canvas()
	var result := Rect2(transform * Vector2.ZERO, Vector2.ZERO)
	for point in [Vector2(control.size.x, 0), control.size, Vector2(0, control.size.y)]:
		result = result.expand(transform * point)
	return result

func _buttons_in(node: Node) -> Array[Button]:
	var result: Array[Button] = []
	for child in node.get_children():
		if child is Button:
			result.append(child)
		result.append_array(_buttons_in(child))
	return result

func _check_control_wording(node: Node) -> void:
	for child in node.get_children():
		if child is Button or child is Label:
			check(_uses_no_resolution_units(child.text), "选项文案只使用比例：%s" % child.text)
		_check_control_wording(child)

func _uses_no_resolution_units(text: String) -> bool:
	var lowered := text.to_lower()
	var resolution := RegEx.new()
	resolution.compile("[0-9]+\\s*[x×]\\s*[0-9]+")
	return "px" not in lowered and "dp" not in lowered and resolution.search(text) == null
