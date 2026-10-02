# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Mascot = preload("res://scenes/drawer_mascot.gd")
const Motion = preload("res://scenes/ui_motion.gd")
const ButtonTheme = preload("res://scenes/ui_button_theme.gd")
var activations := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 操作角色与语义动效回归 ===")
	var main := await boot_main()
	check(main.btn_resign.get_meta("ui_role", "") == "danger", "认输具有明确危险角色")
	check(main.btn_net.get_meta("ui_role", "") == "tool" and main.btn_save.get_meta("ui_role", "") == "tool", "联网和录像属于工具角色")
	check(main.btn_pass.get_meta("ui_role", "") == "primary", "完成行动保留唯一主操作角色")
	var normal: StyleBoxFlat = main.btn_resign.get_theme_stylebox("normal")
	check(normal.border_color.is_equal_approx(Palette.semantic("danger")), "认输外框呈危险色")
	main._on_resign_pressed()
	await process_frame
	var armed: StyleBoxFlat = main.btn_resign.get_theme_stylebox("normal")
	check(main.state.winner == "" and main._resign_armed, "第一次按下危险按钮仍需再次确认")
	check(armed.bg_color.is_equal_approx(Palette.semantic("danger")), "确认期间使用实心危险色")
	await create_timer(main.RESIGN_ARM_HOLD + 0.1).timeout
	check(not main._resign_armed and not main.btn_resign.get_meta("danger_armed", true), "确认过期后危险填充与业务状态一起撤回")
	main.queue_free()
	await process_frame

	var mascot := Mascot.new()
	root.add_child(mascot)
	mascot.set_state("waiting")
	var waiting_motion := mascot._motion
	mascot.set_state("waiting")
	check(mascot._motion == waiting_motion, "重复等待状态不重播状态动效")
	mascot.set_hovered(true)
	var hovered_motion := mascot._motion
	check(hovered_motion != waiting_motion, "首次悬停播放独立的放大摇头反馈")
	mascot.set_state("waiting")
	mascot.set_hovered(true)
	check(mascot._motion == hovered_motion, "重复状态与悬停不打断当前动画")
	mascot.hide()
	check(mascot.state() == "waiting", "隐藏保留等待语义状态")
	mascot.show()
	await create_timer(0.3).timeout
	check(mascot.state() == "waiting" and mascot._bubble.modulate.a > 0.9, "再次显示恢复等待状态反馈")
	check(mascot.state() == "waiting" and "等待" in mascot._state_copy().text or "等对手" in mascot._state_copy().text, "等待状态有文字语义")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = Vector2(60, 80)
	down.pressed = true
	mascot._gui_input(down)
	check(mascot.state() == "pressed", "按下入口进入按压态")
	await create_timer(0.12).timeout
	check(mascot._face_zoom < 1.0, "按压态实际压缩图标")
	var move := InputEventMouseMotion.new()
	move.position = Vector2(90, 80)
	mascot._gui_input(move)
	check(mascot.state() == "dragging", "超过阈值进入拖拽态")
	var drag_motion := mascot._motion
	mascot._gui_input(move)
	check(mascot._motion == drag_motion, "持续拖动不重复启动动画")
	mascot.set_state("connecting")
	check(mascot.state() == "dragging", "拖拽期间业务状态更新不打断手势反馈")
	mascot.set_state("waiting")
	down.pressed = false
	mascot._gui_input(down)
	check(mascot.state() == "waiting", "松手恢复之前的网络等待状态")
	for name in ["connecting", "resolving", "success", "defeat", "danger"]:
		mascot.set_state(name)
		check(mascot.state() == name, "%s保留自身语义状态" % name)
	mascot.activated.connect(func(): activations += 1)
	mascot.set_hovered(true)
	down.pressed = true
	mascot._gui_input(down)
	down.pressed = false
	mascot._gui_input(down)
	check(activations == 1 and mascot.state() == "danger", "失败后hover和再次点击仍可正常激活且保留危险提示")
	mascot.set_state("idle")
	mascot.set_hovered(false)
	await create_timer(0.25).timeout
	check(is_equal_approx(mascot._face_zoom, 1.0) and is_zero_approx(mascot._face_tilt), "idle完整恢复比例与角度")
	check(mascot._bubble_style.bg_color == Palette.get_color("world", "table_frame"), "idle清除旧danger底色")
	check(mascot._bubble.modulate.a < 0.01, "回到空闲后不遗留状态气泡")
	mascot.queue_free()
	await process_frame

	var stage := Node3D.new()
	root.add_child(stage)
	var purchase := Motion.play(stage, "purchase", Vector3.ZERO, Palette.semantic("cash"), 8)
	var production := Motion.play(stage, "production", Vector3.ZERO, Palette.semantic("success"), 8)
	var attack := Motion.play(stage, "attack", Vector3.ZERO, Palette.semantic("danger"), 8)
	var upgrade := Motion.play(stage, "upgrade", Vector3.ZERO, Palette.semantic("primary"))
	check(purchase is CPUParticles3D and production is CPUParticles3D and attack is CPUParticles3D, "购买产出攻击保留纸片材质")
	check(upgrade is MeshInstance3D and upgrade.mesh is TorusMesh, "升级使用独立的环形反馈")
	check(purchase.spread != production.spread and attack.direction != purchase.direction, "产出上升与攻击方向可区分")
	await create_timer(Motion.FEEDBACK_LIFETIME + Motion.SETTLE + 0.1).timeout
	check(stage.get_child_count() == 0, "动作结束释放全部反馈节点")
	# 提前删掉反馈节点时，补间也必须失效，不能等结束后回调一个已释放的目标。
	for event in ["purchase", "upgrade"]:
		var before := get_processed_tweens()
		var feedback := Motion.play(stage, event, Vector3.ZERO, Palette.semantic("primary"))
		var created: Tween = null
		for tween in get_processed_tweens():
			if tween not in before: created = tween
		feedback.queue_free()
		await process_frame
		await process_frame
		check(created != null and not created.is_valid(), "%s节点提前释放时补间一起失效" % event)
	stage.queue_free()
	await process_frame
	_test_custom_button_contrast()
	await _test_network_mascot_lifecycle()
	finish()

func _test_custom_button_contrast() -> void:
	var previous_surface := Palette.semantic("surface")
	var previous_danger := Palette.semantic("danger")
	Palette.set_color("semantic", "surface", Color("#2A2927"))
	Palette.set_color("semantic", "danger", Color("#6A332A"))
	var button := Button.new()
	button.set_meta("ui_role", "danger")
	for armed in [false, true]:
		button.set_meta("danger_armed", armed)
		ButtonTheme.apply(button)
		for pair in [["font_color", "normal"], ["font_hover_color", "hover"], ["font_pressed_color", "pressed"]]:
			var ink := button.get_theme_color(pair[0])
			var surface := (button.get_theme_stylebox(pair[1]) as StyleBoxFlat).bg_color
			var a := ink.srgb_to_linear().get_luminance()
			var b := surface.srgb_to_linear().get_luminance()
			check((maxf(a, b) + 0.05) / (minf(a, b) + 0.05) >= 4.5, "自定义深色表面danger %s %s满足文字对比度" % [armed, pair[1]])
	button.free()
	Palette.set_color("semantic", "surface", previous_surface)
	Palette.set_color("semantic", "danger", previous_danger)

func _test_network_mascot_lifecycle() -> void:
	root.size = Vector2i(1280, 800)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	for i in 20: await physics_frame
	var presentation: Node = main.drawer_presentation
	check(presentation.find_child("HeaderMascot", true, false) == null, "展开态不重复显示收起入口")
	var join: JoinPanel = main._open_join_panel()
	join._mascot("connecting")
	check(presentation._mascot_state == "connecting", "开始连接显示connecting状态")
	main._set_mascot_state("idle")
	check(presentation._mascot_state == "connecting", "牌局idle不能盖掉实际连接状态")
	join._mascot("waiting")
	check(presentation._mascot_state == "waiting", "入座等待显示waiting状态")
	join._on_cancel()
	await process_frame
	check(presentation._mascot_state == "opening", "取消连接后角色恢复首回合邀请")
	join = main._open_join_panel()
	join._on_down("test_error", "无法连接")
	check(presentation._mascot_state == "danger", "拒连后角色提示危险")
	join._on_cancel()
	await process_frame
	check(presentation._mascot_state == "opening", "关闭拒连面板后恢复首回合邀请，不残留危险状态")
	main.phase = main.PHASE_SETTLING
	main._set_mascot_state("resolving")
	main._resign_armed = true
	main._refresh_mascot_state()
	check(presentation._mascot_state == "danger", "认输确认优先于结算角色状态")
	main._resign_armed = false
	main._set_mascot_state("idle")
	check(presentation._mascot_state == "resolving", "取消确认恢复实际结算状态")
	main.state.winner = main.my_seat
	main._set_connection_mascot_state("waiting")
	check(presentation._mascot_state == "success", "迟来的连接事件不能覆盖终局胜利")
	main.queue_free()
	await process_frame
