# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 抽屉集成测试共用的真实场景生命周期。只共享准备/同步，不共享业务预期。
const DRAWER_VIEWPORT_CASES := [
	{ "pixels": Vector2i(1280, 800), "dpi": 1.0, "name": "1280x800@1x" },
	{ "pixels": Vector2i(1920, 1200), "dpi": 1.0, "name": "1920x1200@1x" },
	{ "pixels": Vector2i(2560, 1600), "dpi": 2.0, "name": "2560x1600@2x" },
]

func boot_drawer(pixels: Vector2i, dpi: float, manual_window := false) -> Node:
	if _finishing:
		return null
	paused = false
	root.size = pixels
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = dpi
	root.add_child(main)
	_booted = main
	# _ready 失败时先让公共骨架检查记账；不要进入依赖 entities/layout 的等待。
	_assert_booted(main)
	if _finishing:
		return null
	for frame in 180:
		await physics_frame
		if frame > 12 and not _anim_busy(main):
			break
	if manual_window:
		# 测试驱动窗口/鼠标事件，控制器不能读取测试机的真实鼠标位置。
		main.drawer_window.set_process(false)
		main.drawer_window.animations_enabled = false
		main.drawer_window.pin()
	for frame in 3:
		await process_frame
	return main

func relayout_drawer(main: Node, wait_physics := false) -> void:
	main.drawer_presentation.relayout()
	for frame in 3:
		await process_frame
	main.drawer_presentation.relayout()
	if wait_physics:
		await physics_frame
	else:
		await process_frame

func tap_drawer_control(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	root.push_input(press)
	await process_frame
	press.pressed = false
	root.push_input(press)
	await process_frame

func dispose_drawer(main: Node) -> void:
	paused = false
	if not is_instance_valid(main):
		return
	if main.sfx:
		main.sfx.set_muted(true)
	main.queue_free()
	if _booted == main:
		_booted = null
	for frame in 3:
		await process_frame
