# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 选项旁声音开关：按钮状态与抽屉临时静音相互独立。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 选项声音开关 ===")
	var main := await _boot_drawer_main()
	if not need(main != null and main.drawer_presentation != null, "抽屉呈现已建立"):
		finish()
		return
	var presentation: Node = main.drawer_presentation
	var button: Button = presentation.get("_sound_button")
	check(button != null, "选项旁喇叭按钮存在")
	if button == null:
		main.queue_free()
		finish()
		return
	var menu: Control = presentation.get("_menu")
	check(button.get_parent() == menu.get_parent() and button.get_index() == menu.get_index() + 1 and pin_index(presentation) == menu.get_index() + 2,
		"喇叭与钉子紧接齿轮选项按钮")
	check(button.accessibility_name == "关闭声音", "默认声音开启且提供无障碍文案")
	check(button.get_meta("drawer_icon_button", false) and button.get_theme_stylebox("normal") is StyleBoxEmpty, "喇叭按钮使用无边框图标样式")
	var pin: Button = presentation.get("_pin")
	check(pin != null and pin.find_child("IconGlyph", true, false) != null and pin.get_meta("drawer_icon_button", false) and pin.get_theme_stylebox("normal") is StyleBoxEmpty, "钉子按钮使用线稿图标且无外边框")
	check(button.tooltip_text == "关闭声音", "默认声音按钮提示关闭声音")
	check(not main.sfx.user_muted and not main.sfx.muted, "默认没有用户静音")
	main.sfx.play("buy")
	var next_before: int = main.sfx._next
	check(_playing_count(main.sfx) > 0, "切换前音效确实已开始播放")
	button.pressed.emit()
	check(main.sfx.user_muted and main.sfx.muted, "点击喇叭立即静音")
	check(_playing_count(main.sfx) == 0, "静音后停止所有已开始的音效")
	main.sfx.play("buy")
	check(main.sfx._next == next_before, "静音后新音效不再进入播放器")
	check(button.text.is_empty() and button.find_child("IconGlyph", true, false) != null and button.tooltip_text == "打开声音", "静音状态使用线稿图标并提示打开声音")
	button.pressed.emit()
	check(not main.sfx.user_muted and not main.sfx.muted, "再次点击恢复声音")
	main.sfx.play("buy")
	check(main.sfx._next != next_before, "恢复后新音效正常进入播放器")
	main._on_drawer_expanded_changed(false)
	check(main.sfx.drawer_suspended and main.sfx.muted, "抽屉收起时临时静音")
	main._on_drawer_expanded_changed(true)
	check(not main.sfx.drawer_suspended and not main.sfx.muted, "抽屉展开恢复用户选择")
	button.pressed.emit()
	main._on_drawer_expanded_changed(false)
	main._on_drawer_expanded_changed(true)
	check(main.sfx.user_muted and main.sfx.muted, "收起展开不覆盖用户静音选择")
	presentation.relayout()
	check(button.accessibility_name == "打开声音" and button.tooltip_text == "打开声音",
		"重排和主题刷新保留可读的声音操作文案")
	check(not button.button_pressed, "静音状态显示未按下的声音按钮")
	main.sfx.set_user_muted(false)
	check(button.accessibility_name == "关闭声音" and button.button_pressed, "外部更新声音偏好同步按钮")
	main.sfx.set_muted(true)
	# AudioServer 在混音线程消费 stop，请让它完成本帧后再销毁播放器。
	await create_timer(0.08, true, false, true).timeout
	main.sfx.free()
	main.queue_free()
	for i in 3:
		await process_frame
	finish()

func _playing_count(sfx: Sfx) -> int:
	var count := 0
	for player: AudioStreamPlayer in sfx._players:
		if player.playing:
			count += 1
	return count

func _boot_drawer_main() -> Node:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.add_child(main)
	_booted = main
	main.drawer_window.animations_enabled = false
	main.drawer_window.set_process(false)
	main.drawer_window.pin()
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	return main

func pin_index(presentation: Node) -> int:
	var pin: Button = presentation.get("_pin")
	return pin.get_index() if pin != null else -1
