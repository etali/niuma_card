# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for dpi in [1.0, 2.0]:
		var main: Node = await _boot_drawer(dpi)
		var drawer: DrawerWindow = main.drawer_window
		var presentation: Node = main.drawer_presentation
		var button: Button = presentation._pin
		var glyph: TextureRect = button.get_node("IconGlyph")
		var prefix := "%s倍DPI：" % dpi
		_check_state(drawer, button, glyph, false, prefix + "初始")
		var unpinned := glyph.texture.get_image().get_data()
		await _capture(main, "unpinned", dpi)
		await _click(button)
		_check_state(drawer, button, glyph, true, prefix + "真实鼠标点击钉住")
		check(glyph.texture.get_image().get_data() != unpinned, prefix + "钉住后图案本身变化，无需依赖颜色")
		var pinned := glyph.texture.get_image().get_data()
		await _capture(main, "pinned", dpi)
		presentation.relayout()
		check(glyph.texture.get_image().get_data() == pinned, prefix + "重排保留已钉住图案")
		await _click(button)
		_check_state(drawer, button, glyph, false, prefix + "再次真实点击取消")
		check(glyph.texture.get_image().get_data() == unpinned, prefix + "取消后恢复原图案")
		drawer.pin()
		_check_state(drawer, button, glyph, true, prefix + "程序钉住")
		check(glyph.texture.get_image().get_data() == pinned, prefix + "程序钉住同步相同图案")
		var previous_value := Palette.get_string("icon", "foreground")
		Palette.set_color("icon", "foreground", Color("e45429"))
		check(glyph.modulate == Palette.icon_color(Palette.get_color("card", "body")), prefix + "修改配色同步图钉墨色")
		check(glyph.texture.get_image().get_data() == pinned, prefix + "修改配色保留状态图案")
		Palette._cfg["icon"]["foreground"] = previous_value
		Palette.bus().changed.emit("icon", "foreground")
		drawer.set_pinned(false)
		_check_state(drawer, button, glyph, false, prefix + "程序取消")
		check(glyph.texture.get_image().get_data() == unpinned, prefix + "程序取消同步原图案")
		check(button.size.x >= 25 * dpi and button.size.y >= 25 * dpi, prefix + "触控区域随DPI放大")
		check(button.get_global_rect().encloses(glyph.get_global_rect()), prefix + "图案完整位于按钮内")
		main.sfx.set_muted(true)
		await create_timer(0.08, true, false, true).timeout
		main.queue_free()
		for i in 3:
			await process_frame
	finish()

func _check_state(drawer: DrawerWindow, button: Button, glyph: TextureRect, pinned: bool, prefix: String) -> void:
	check(drawer.is_pinned() == pinned and button.button_pressed == pinned, prefix + "真实窗口与按钮状态一致")
	check(button.tooltip_text == ("已钉住，点击取消" if pinned else "钉住") and button.accessibility_name == button.tooltip_text, prefix + "提示与无障碍名称表达当前状态")
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		check(button.get_theme_stylebox(state) is StyleBoxEmpty, prefix + state + "状态保持无边框")
	check(glyph.texture != null and glyph.visible and glyph.mouse_filter == Control.MOUSE_FILTER_IGNORE, prefix + "图案可见且不拦截点击")

func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = point
		click.pressed = pressed
		root.push_input(click)
		await process_frame

func _boot_drawer(dpi: float) -> Node:
	paused = false
	root.size = Vector2i(roundi(1280 * dpi), roundi(800 * dpi))
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = dpi
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.activate_handle()
	main.drawer_window.set_pinned(false)
	# 真窗口启动会读取屏幕DPI；显式覆盖，让截图也覆盖指定的两档显示缩放。
	main.drawer_ui_scale = dpi
	main.drawer_presentation._ui_scale = dpi
	main.drawer_window.set_display_scale(dpi)
	root.size = Vector2i(roundi(1280 * dpi), roundi(800 * dpi))
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	return main

func _capture(main: Node, state: String, dpi: float) -> void:
	var folder := OS.get_environment("CARD_PIN_SHOTS")
	if folder.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(folder.path_join("pin-%s-%sx.png" % [state, dpi]))
	var rect: Rect2 = main.drawer_presentation._header.get_global_rect()
	image.get_region(Rect2i(rect)).save_png(folder.path_join("pin-%s-%sx-header.png" % [state, dpi]))
