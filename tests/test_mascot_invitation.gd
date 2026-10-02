# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 使用主场景实际装配的入口，覆盖鼠标、键盘和抽屉控制器间的连接。
## headless 没有真实系统指针，拖动时以相同控制器的 drag_to 注入全局位置。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉入口状态提示与手势回归 ===")
	root.size = Vector2i(1600, 1000)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	var presentation: Node = main.drawer_presentation
	var drawer: DrawerWindow = main.drawer_window
	var handle: DrawerMascot = presentation._handle
	check(presentation.find_child("HeaderMascot", true, false) == null, "展开顶部的完整子树中没有重复收起入口")
	check(not presentation.has_method("_on_header_mascot_input"), "顶部不残留点击或键盘收起处理器")
	check(_header_has_no_collapse_action(presentation._header), "顶部按钮和可聚焦控件不提供收起操作")
	drawer.animations_enabled = false
	drawer.set_pinned(false)
	drawer.collapse_now()
	await process_frame
	check(handle.visible and not drawer.is_expanded(), "收起后显示实际装配的桌面入口")
	check(handle._icon.texture != null, "入口仍使用实际应用图标")
	check(handle.state() == "opening" and not handle._hovered, "首次收起入口具备邀请资格且尚未悬停")
	check(handle._greeting_label.text.is_empty() and handle.tooltip_text.is_empty()
		and handle._bubble.modulate.a < 0.01, "首次收起不显示任何邀请、展开提示或空白气泡")
	var actor_before: String = main._actor
	var round_before: int = main.state.round_num
	handle.mouse_entered.emit()
	_advance_motion(handle, 0.30)
	var hover_motion := handle._motion
	# 真实presentation每帧刷新同一业务状态，不能取消刚触发的悬停动画。
	await process_frame
	check(handle._motion == hover_motion, "真实场景状态刷新保留入口悬停动画")
	check(is_equal_approx(handle._face_zoom, DrawerMascot.HOVER_ZOOM)
		and absf(handle._face_tilt) > 0.001, "指向真实入口时既放大也摇头")
	check(handle.state() == "opening", "首回合未行动时悬停仍是入口邀请")
	check(handle._greeting_label.text == "来摸一局？" and handle._bubble.modulate.a > 0.99, "首回合未行动时悬停显示来摸一局？")
	check(handle._face_zoom > 1.0, "状态提示仍保留图标抬起反馈")
	check(handle.tooltip_text.is_empty(), "悬停邀请不再叠加系统展开工具提示")
	handle.mouse_exited.emit()
	check(handle._greeting_label.text.is_empty() and handle._bubble.modulate.a < 0.01, "移出真实入口立即清空邀请和气泡")
	check(main._opening_action_pending and main._actor == actor_before
		and main.state.round_num == round_before and not drawer.is_expanded(), "悬停进入和移出不算玩家行动，也不展开牌桌")
	handle.mouse_entered.emit()
	_advance_motion(handle, 0.30)

	var point := handle.get_icon_hit_rect().get_center()
	handle._gui_input(_mouse_button(point, true))
	_advance_motion(handle, 0.14)
	check(handle.state() == "pressed" and drawer.is_dragging(), "按下入口同时建立实际窗口拖拽手势")
	check(handle._bubble.modulate.a < 0.01, "按住时气泡淡出")
	check(handle._face_zoom < 1.0, "按住时仍以图标压缩确认输入")
	check(handle._greeting_label.text.is_empty() and handle.tooltip_text.is_empty(), "按住不出现额外操作文案或工具提示")

	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(40, 0) * handle.get_render_scale()
	handle._gui_input(motion)
	# 原生平台会从系统取指针，这里将等价全局位移传入同一个窗口状态机。
	var before: Rect2i = drawer._geometry
	drawer.drag_to(before.get_center() + Vector2i(-100, 70))
	_advance_motion(handle, 0.14)
	check(handle.state() == "dragging" and drawer._drag_moved, "移动超过阈值进入拖拽并实际移动窗口")
	check(drawer._geometry.position != before.position, "拖拽后入口窗口位置发生变化")
	check(handle._bubble.modulate.a < 0.01 and absf(handle._face_tilt) > 0.001, "拖动保留倾斜姿态并隐藏气泡")
	check(handle._greeting_label.text.is_empty() and handle.tooltip_text.is_empty(), "拖动不出现额外操作文案或工具提示")
	handle._gui_input(_mouse_button(motion.position, false))
	_advance_motion(handle, 0.30)
	check(not drawer.is_dragging() and not drawer.is_expanded(), "拖拽松手结束并吸附，不误展开")
	check(handle.state() == "opening" and handle._greeting_label.text == "来摸一局？" and handle._bubble.modulate.a > 0.99, "仍悬停时松手恢复首回合邀请")

	for state_name in ["waiting", "success", "defeat"]:
		handle.set_state(state_name)
		var before_text: String = handle._greeting_label.text
		handle.mouse_exited.emit()
		handle.mouse_entered.emit()
		check(handle.state() == state_name and handle._greeting_label.text == before_text, "%s语义不会被鼠标进入邀请覆盖" % state_name)
	handle.set_state("your_turn")
	handle.mouse_exited.emit()
	handle.mouse_entered.emit()
	handle._gui_input(_mouse_button(point, true))
	handle._gui_input(_mouse_button(point, false))
	await process_frame
	check(drawer.is_expanded() and not handle.visible, "入口轻点仍展开牌桌并隐藏入口")

	drawer.collapse_now()
	await process_frame
	handle.grab_focus()
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	handle._gui_input(enter)
	await process_frame
	check(drawer.is_expanded() and not handle.visible, "入口Enter仍可展开，顶部无需重复收起按钮")
	paused = false
	main.queue_free()
	await process_frame
	finish()

func _advance_motion(mascot: DrawerMascot, seconds: float) -> void:
	var motion: Tween = mascot._motion
	motion.pause()
	motion.custom_step(seconds)

func _mouse_button(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	return event

func _header_has_no_collapse_action(node: Node) -> bool:
	if node is Control:
		var control := node as Control
		if control.focus_mode != Control.FOCUS_NONE or control is BaseButton:
			var copy := control.tooltip_text + control.accessibility_name
			if control is Button:
				copy += (control as Button).text
			if "收起" in copy:
				return false
	for child in node.get_children():
		if not _header_has_no_collapse_action(child):
			return false
	return true
