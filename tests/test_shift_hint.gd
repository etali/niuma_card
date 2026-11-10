# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	AudioServer.set_bus_mute(0, true)
	seed_first_run_player()
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 800)
	change_scene_to_file("res://scenes/shift_host.tscn")
	var deadline := Time.get_ticks_msec() + 20000
	while (current_scene == null or not is_instance_valid(current_scene.sign)
			or current_scene.display.texture == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	var host: Node = current_scene
	if not need(host != null and is_instance_valid(host.sign), "首次启动完成真实旋转门装配"):
		finish()
		return
	var door: BaseButton = host.sign
	var main: Node = host.tables[0]
	main.sfx.set_muted(true)
	var ui: Node = main.drawer_presentation
	var drawer: DrawerWindow = main.drawer_window
	drawer.set_process(false)
	drawer.animations_enabled = false
	drawer.pin()
	for i in 4: await process_frame
	check(door.intro and ui.is_learning_invitation_open(), "首次游玩显示开场旋转门和教程邀请")
	door.set_process(false)
	door._process(5.44 - door.elapsed)
	check(not door.intro and not door.turning and not is_instance_valid(door._hint),
		"上班牌刚刚转正时不抢先显示切换提示")
	door._process(3.0)
	check(not is_instance_valid(door._hint), "教程邀请遮挡时不显示或消耗提示时间")
	ui._learning_invitation.find_child("InvitationSkip", true, false).pressed.emit()
	for i in 3: await process_frame
	door._process(1.9)
	check(not is_instance_valid(door._hint), "上班牌可操作不足两秒时不显示提示")
	drawer.set_pinned(false)
	drawer.collapse_now()
	door._process(20.0)
	check(not is_instance_valid(door._hint), "收起牌桌期间暂停提示倒计时")
	drawer.pin()
	for i in 3: await process_frame
	door._process(0.11)
	check(is_instance_valid(door._hint) and door._hint.is_visible_in_tree()
		and door._hint_label.text == "点击旋转门\n切换到「下班牌」", "约两秒后明确提示点击旋转门切换下班牌")
	if is_instance_valid(door._hint):
		for i in 3: await process_frame
		var hint_style: StyleBox = door._hint.get_theme_stylebox("panel")
		var hint_minimum: Vector2 = door._hint.custom_minimum_size
		ui.relayout()
		for i in 3: await process_frame
		check(door._hint.get_theme_stylebox("panel") == hint_style
			and door._hint.custom_minimum_size == hint_minimum, "刷新牌桌布局不会再次缩放或覆盖提示样式")
		check(door._hint.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and door._hint_label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "提示不拦截牌桌或旋转门点击")
		check(door.get_viewport_rect().encloses(door._hint.get_global_rect()), "提示完整位于可见牌桌内")
		check(door._hint.size.y < door.size.y * 3.0, "提示只占两行文案高度，不扩成遮挡牌桌的大面板")
		check(not door.get_global_rect().intersects(door._hint.get_global_rect()), "提示位于旋转门下方，不挡住点击目标")
		await _capture(host, "hint-desktop.png")
		door._process(7.8)
		check(door._hint.visible, "提示留下充足阅读时间")
		door._process(0.3)
		check(not door._hint.visible and not door.is_processing(), "提示显示八秒后收起并停止计时")
	# Rebind only the presentation to exercise clicking during a visible hint;
	# the native input still travels through the actual host and table viewport.
	door.bind(host.title_slots[0], true, true)
	door.set_process(false)
	door._process(7.5)
	check(door._hint.visible, "准备带提示的真实点击场景")
	await _click(door)
	check(not door._hint.visible, "点击旋转门立即收起提示")
	deadline = Time.get_ticks_msec() + 20000
	while (host.switching or host.active != 1) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host.active == 1 and not host.switching and not door._hint.visible, "切到下班牌后不残留上班引导")
	change_scene_to_file("res://scenes/shift_host.tscn")
	deadline = Time.get_ticks_msec() + 20000
	while (current_scene == host or current_scene == null or not is_instance_valid(current_scene.sign)
			or current_scene.display.texture == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	host = current_scene
	check(host.active == 1 and not host.sign.intro and not host.sign._hint_pending,
		"重新打开按已记住的模式启动，首次切换提示不重复")
	finish()

func _click(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await process_frame

func _capture(host: Node, name: String) -> void:
	var output := OS.get_environment("SHIFT_HINT_CAPTURE_DIR")
	if output.is_empty() or DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(output)
	var capture: Image = host.display.texture.get_image()
	check(capture.save_png(output.path_join(name)) == OK, "保存真实渲染的首次切换提示截图")
