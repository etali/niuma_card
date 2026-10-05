# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Mascot := preload("res://scenes/drawer_mascot.gd")
var _activations := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉游戏图标与招呼回归 ===")
	var mascot := Mascot.new()
	var icon := load("res://assets/art/app_icon.png") as Texture2D
	if not need(icon != null, "使用游戏完整图标资源"):
		finish()
		return
	root.size = Vector2i(Mascot.ENTRY_SIZE)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.transparent_bg = true
	mascot.setup(icon)
	root.add_child(mascot)
	mascot.activated.connect(func(): _activations += 1)
	await process_frame

	check(mascot.process_mode == Node.PROCESS_MODE_ALWAYS, "单机暂停时入口仍处理交互")
	check(mascot.size == Mascot.ENTRY_SIZE, "入口预留168×192完整绘制空间")
	check(mascot._icon.size.x >= 144 and mascot._icon.size.y >= 144, "图标至少144×144")
	check(mascot._icon.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "完整图标保持比例")
	check(mascot._icon.texture == icon, "入口使用完整原图，不裁取子区域")
	var image := icon.get_image()
	check(image.get_pixel(0, 0).a == 0.0 and image.get_pixel(image.get_width() - 1, image.get_height() - 1).a == 0.0, "源图标角落透明")
	check(mascot._greeting_label.text.is_empty() and mascot.tooltip_text.is_empty(), "初次显示的空闲入口没有展开提示或工具提示")
	check(mascot._bubble.modulate.a < 0.01, "初次显示的空闲入口没有空白气泡")
	_assert_drawing_bounds(mascot, "静止")
	await _capture("normal")

	paused = true
	mascot.set_hovered(true)
	_advance_motion(mascot, 0.3)
	check(mascot._face_zoom >= 1.07, "牌局暂停时悬停仍将游戏图标整体放大")
	check(mascot._bubble.modulate.a < 0.01 and mascot._greeting_label.text.is_empty() and mascot.tooltip_text.is_empty(), "空闲悬停只播放图标动画，不显示额外操作提示")
	check(mascot.state() == Mascot.STATE_IDLE, "悬停姿态不替换空闲语义状态")
	check(absf(mascot._face_tilt) > 0.001, "牌局暂停时牛马仍会摆动招呼")
	check(_activations == 0, "悬停招呼不发出展开请求")
	check(mascot.scale == Vector2.ONE and mascot._icon.scale == Vector2.ONE, "整张图片在自身区域内动画，入口控件不缩放")
	_assert_drawing_bounds(mascot, "悬停最大动画")
	await _capture("hover")

	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	mascot._gui_input(right)
	check(_activations == 0, "右键不会展开抽屉")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(50, 50)
	mascot._gui_input(click)
	var drag_move := InputEventMouseMotion.new()
	drag_move.position = Vector2(80, 50)
	mascot._gui_input(drag_move)
	click.pressed = false
	mascot._gui_input(click)
	check(_activations == 0, "按住并移动时不提前展开抽屉")
	click.pressed = true
	click.position = Vector2(50, 50)
	mascot._gui_input(click)
	click.pressed = false
	mascot._gui_input(click)
	check(_activations == 1, "点击并松手才发出一次展开请求")

	mascot.set_hovered(false)
	_advance_motion(mascot, 0.25)
	check(is_equal_approx(mascot._face_zoom, 1.0), "离开图标恢复原始大小")
	check(is_zero_approx(mascot._face_tilt), "离开图标恢复角度")
	check(mascot._bubble.modulate.a < 0.01, "离开图标隐藏气泡")

	var idle_motion: Tween = mascot._motion
	mascot.greet()
	check(mascot._motion == idle_motion and mascot._greeting_label.text != Mascot.INVITATION_TEXT, "空闲启动招呼不能产生对局邀请")
	mascot.set_state(Mascot.STATE_OPENING)
	mascot.greet()
	_advance_motion(mascot, 0.3)
	check(mascot._face_zoom >= 1.07, "BOT开场招呼在暂停状态也能播放")
	check(mascot._bubble.modulate.a < 0.01 and mascot._greeting_label.text.is_empty(), "开场图标招呼播放时未悬停也不显示邀请")
	check(_activations == 1, "启动招呼不会自动展开游戏")
	# 招呼末尾回调创建恢复姿态的另一条 Tween，分开推进两个阶段。
	_advance_motion(mascot, 2.2)
	_advance_motion(mascot, 0.25)
	check(is_equal_approx(mascot._face_zoom, 1.0), "启动招呼结束后恢复空闲大小")
	check(mascot._bubble.modulate.a < 0.01 and mascot._greeting_label.text.is_empty() and mascot.tooltip_text.is_empty(), "启动招呼及其结束都不能在未悬停时显示邀请")
	mascot.set_state(Mascot.STATE_IDLE)
	paused = false
	_test_interaction_copy(mascot)
	_test_opening_hover(mascot)
	await _test_native_sizes(mascot)
	await _test_match_statuses(mascot)
	await _test_status_before_entering_tree()
	mascot.queue_free()
	await process_frame
	finish()

func _test_interaction_copy(mascot: Control) -> void:
	for state_name in [Mascot.STATE_IDLE, Mascot.STATE_HOVER, Mascot.STATE_PRESSED, Mascot.STATE_DRAGGING]:
		mascot.set_state(state_name)
		mascot.set_hovered(true)
		_advance_motion(mascot, 0.3)
		check(mascot._greeting_label.text.is_empty() and mascot.tooltip_text.is_empty(),
			"%s交互状态没有展开、按住或松手操作提示" % state_name)
		check(mascot._bubble.modulate.a < 0.01, "%s交互状态不显示空白气泡" % state_name)
	mascot.set_hovered(false)
	mascot.set_state(Mascot.STATE_IDLE)

func _test_opening_hover(mascot: Control) -> void:
	mascot.set_state(Mascot.STATE_OPENING)
	check(not mascot._has_status(), "开场邀请不作为需要常驻的对局进度")
	check(mascot._greeting_label.text.is_empty() and mascot.tooltip_text.is_empty()
		and mascot._bubble.modulate.a < 0.01, "未悬停时开场邀请既没有文字也没有气泡")
	var before := _activations
	mascot.set_hovered(true)
	_advance_motion(mascot, 0.3)
	check(mascot._greeting_label.text == Mascot.INVITATION_TEXT and mascot._bubble.modulate.a > 0.99,
		"开场邀请仅在悬停时显示且保留问号")
	check(mascot.tooltip_text.is_empty(), "开场邀请没有重复的系统工具提示")
	var hover_motion: Tween = mascot._motion
	var tilt: float = mascot._face_tilt
	for frame in 3:
		mascot.set_state(Mascot.STATE_OPENING)
		mascot.set_hovered(true)
	check(mascot._motion == hover_motion, "开场状态重复刷新不重播悬停动画")
	_advance_motion(mascot, 0.15)
	check(not is_equal_approx(mascot._face_tilt, tilt), "开场状态重复刷新后摇头仍推进")
	mascot.set_hovered(false)
	check(mascot._greeting_label.text.is_empty() and mascot._bubble.modulate.a < 0.01,
		"鼠标移出立即清空开场邀请并隐藏气泡")
	_advance_motion(mascot, 0.25)
	check(is_equal_approx(mascot._face_zoom, 1.0) and is_zero_approx(mascot._face_tilt),
		"开场邀请移出后图标恢复静止")
	check(_activations == before, "悬停进入和移出都不触发游戏动作")

	# 拖拽期间收到鼠标进出事件，松手按最新指针位置决定是否显示邀请。
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = mascot.get_icon_hit_rect().get_center()
	var move := InputEventMouseMotion.new()
	move.position = down.position + Vector2(40, 0)
	for release_hovered in [false, true]:
		mascot.set_hovered(not release_hovered)
		down.pressed = true
		mascot._gui_input(down)
		mascot._gui_input(move)
		mascot.set_hovered(release_hovered)
		mascot.set_state(Mascot.STATE_OPENING)
		_advance_motion(mascot, 0.15)
		check(mascot._greeting_label.text.is_empty() and mascot.tooltip_text.is_empty()
			and mascot._bubble.modulate.a < 0.01, "拖拽中悬停变化也不显示邀请或手势文案")
		down.pressed = false
		mascot._gui_input(down)
		_advance_motion(mascot, 0.3)
		check(mascot.state() == Mascot.STATE_OPENING, "拖拽松手仍保留开场资格")
		if release_hovered:
			check(mascot._greeting_label.text == Mascot.INVITATION_TEXT and mascot._bubble.modulate.a > 0.99,
				"拖拽期间移入图标，松手显示悬停邀请")
		else:
			check(mascot._greeting_label.text.is_empty() and mascot._bubble.modulate.a < 0.01,
				"拖拽期间移出图标，松手不恢复旧邀请")
	check(_activations == before, "拖拽与悬停变化不触发展开")
	mascot.hide()
	mascot.show()
	_advance_motion(mascot, 0.3)
	check(not mascot._hovered and mascot._greeting_label.text.is_empty()
		and mascot.tooltip_text.is_empty() and mascot._bubble.modulate.a < 0.01,
		"入口隐藏再显示不沿用旧悬停邀请")
	mascot.set_state(Mascot.STATE_IDLE)

func _test_native_sizes(mascot: Control) -> void:
	for factor in [0.75, 1.5, 2.5]:
		mascot.set_render_scale(float(factor))
		root.size = Vector2i(Mascot.ENTRY_SIZE * factor)
		await process_frame
		check(is_equal_approx(mascot.get_render_scale(), factor), "%s倍入口公开实际绘制比例" % factor)
		check(mascot.size.is_equal_approx(Mascot.ENTRY_SIZE * factor), "%s倍入口使用实际像素尺寸" % factor)
		check(mascot.scale == Vector2.ONE and mascot._icon.scale == Vector2.ONE,
			"%s倍入口使用原生绘制，不通过Control.scale放大" % factor)
		var greeting: Label = mascot._greeting_label
		check(greeting.get_theme_font_size("font_size") == roundi(19.0 * factor),
			"%s倍招呼字体直接按目标像素字号渲染" % factor)
		var hit: Rect2 = mascot.get_icon_hit_rect()
		check(hit == Rect2(Mascot.ICON_RECT.position * factor, Mascot.ICON_RECT.size * factor),
			"%s倍图标命中区域与实际绘制边界一致" % factor)
		_assert_drawing_bounds(mascot, "%s倍入口" % factor)
		var before := _activations
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = Vector2(3, 3) * factor
		click.pressed = true
		mascot._gui_input(click)
		click.pressed = false
		mascot._gui_input(click)
		check(_activations == before, "%s倍入口透明角落不展开游戏" % factor)
		click.position = hit.get_center()
		click.pressed = true
		mascot._gui_input(click)
		click.pressed = false
		mascot._gui_input(click)
		check(_activations == before + 1, "%s倍入口实际图标可点击" % factor)
		mascot.set_hovered(true)
		_advance_motion(mascot, 0.3)
		_assert_drawing_bounds(mascot, "%s倍悬停招呼" % factor)
		await _capture("native-%s" % str(factor).replace(".", "_"))
		mascot.set_hovered(false)
		_advance_motion(mascot, 0.2)

func _test_match_statuses(mascot: Control) -> void:
	var states := {
		Mascot.STATE_CONNECTING: "正在连接…",
		Mascot.STATE_WAITING: "等对手加入…",
		Mascot.STATE_FOE_ACTING: "等待对手行动",
		Mascot.STATE_FOE_DONE: "等待你行动",
		Mascot.STATE_YOUR_TURN: "轮到你行动",
		Mascot.STATE_FOE_ATTACKING: "对手攻击中…",
		Mascot.STATE_YOUR_ATTACK: "轮到你攻击",
		Mascot.STATE_FOE_OFFLINE: "对手已断开",
		Mascot.STATE_DISCONNECTED: "连接已断开",
		Mascot.STATE_RESOLVING: "结算中…",
		Mascot.STATE_SUCCESS: "做得漂亮！",
		Mascot.STATE_DEFEAT: "这局结束了",
		Mascot.STATE_DANGER: "注意这一步",
	}
	mascot.set_render_scale(1.0)
	root.size = Vector2i(Mascot.ENTRY_SIZE)
	paused = true
	for status in states:
		mascot.set_hovered(false)
		mascot.set_state(status)
		_advance_motion(mascot, 0.3)
		check(mascot.state() == status and mascot._greeting_label.text == states[status], "%s显示对应的对局文案" % status)
		check(mascot._bubble.modulate.a > 0.99, "%s无需悬停即可看到对局提示" % status)
		check(mascot.tooltip_text.is_empty() and states[status] in mascot.accessibility_name, "%s不生成系统悬停小字，同时保留无障碍状态" % status)
		mascot.set_hovered(true)
		_advance_motion(mascot, 0.3)
		check(is_equal_approx(mascot._face_zoom, Mascot.HOVER_ZOOM) and absf(mascot._face_tilt) > 0.001,
			"%s悬停图标确实放大并摇头" % status)
		check(mascot.state() == status and mascot._greeting_label.text == states[status], "%s悬停不覆盖业务文案" % status)
		var motion: Tween = mascot._motion
		var tilt: float = mascot._face_tilt
		for frame in 3:
			mascot.set_state(status)
			mascot.set_hovered(true)
		check(mascot._motion == motion, "%s重复状态刷新和悬停不取消或重播动画" % status)
		_advance_motion(mascot, 0.15)
		check(not is_equal_approx(mascot._face_tilt, tilt), "%s重复刷新后摇头仍继续推进" % status)
		mascot.greet()
		check(mascot._motion == motion and Mascot.INVITATION_TEXT not in mascot._greeting_label.text,
			"%s不被开场招呼或邀请覆盖" % status)
		await _capture(status)
		mascot.set_hovered(false)
		_advance_motion(mascot, 0.25)
		var rest_zoom := 1.0 if status in [Mascot.STATE_DANGER, Mascot.STATE_DEFEAT] else 1.03
		check(is_equal_approx(mascot._face_zoom, rest_zoom) and is_zero_approx(mascot._face_tilt), "%s鼠标离开恢复业务姿态" % status)
		check(mascot._bubble.modulate.a > 0.99 and mascot._greeting_label.text == states[status], "%s鼠标离开仍保留业务气泡" % status)

	# 手势中继续收到业务进度，松手应恢复最近进度，而不是按下前的旧消息。
	mascot.set_state(Mascot.STATE_FOE_ACTING)
	mascot.set_hovered(true)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.position = mascot.get_icon_hit_rect().get_center()
	down.pressed = true
	mascot._gui_input(down)
	_advance_motion(mascot, 0.12)
	check(mascot._bubble.modulate.a < 0.01 and mascot._greeting_label.text != Mascot.INVITATION_TEXT, "按住时隐藏对局提示且不产生邀请")
	var move := InputEventMouseMotion.new()
	move.position = down.position + Vector2(40, 0)
	mascot._gui_input(move)
	mascot.set_state(Mascot.STATE_FOE_DONE)
	mascot.set_state(Mascot.STATE_YOUR_ATTACK)
	check(mascot.state() == Mascot.STATE_DRAGGING and mascot._greeting_label.text != Mascot.INVITATION_TEXT, "对局进度更新不打断拖拽姿态且不产生邀请")
	down.pressed = false
	mascot._gui_input(down)
	_advance_motion(mascot, 0.3)
	check(mascot.state() == Mascot.STATE_YOUR_ATTACK and mascot._greeting_label.text == states[Mascot.STATE_YOUR_ATTACK], "松手恢复拖拽期间更新到的最新对局状态")
	check(mascot._bubble.modulate.a > 0.99 and mascot._face_zoom >= 1.07 and absf(mascot._face_tilt) > 0.001, "仍悬停时松手恢复常驻提示和放大摇头")
	mascot.set_hovered(false)
	_advance_motion(mascot, 0.25)
	check(is_zero_approx(mascot._face_tilt), "松手后移出鼠标清除倾斜")
	mascot.set_hovered(true)
	_advance_motion(mascot, 0.3)

	mascot.hide()
	mascot.set_state(Mascot.STATE_FOE_DONE)
	mascot.show()
	_advance_motion(mascot, 0.3)
	check(mascot.state() == Mascot.STATE_FOE_DONE and mascot._greeting_label.text == states[Mascot.STATE_FOE_DONE], "隐藏期间变更状态，再显示使用最新文案")
	check(mascot._bubble.modulate.a > 0.99, "再次收起到入口后仍显示对局气泡")
	check(not mascot._hovered and is_zero_approx(mascot._face_tilt) and is_equal_approx(mascot._face_zoom, 1.03), "隐藏再显示清除旧悬停和偏转")
	paused = false

	# Font.get_string_size 使用实际共享中文字体的字形排版结果；同时检查
	# 容器布局后的可用区域，避免用字数估算漏掉省略号或DPI取整。
	for factor in [0.25, 0.75, 1.0, 1.5, 2.5, 4.0]:
		mascot.set_render_scale(factor)
		root.size = Vector2i(Mascot.ENTRY_SIZE * factor)
		var visible_states: Array = states.keys() + [Mascot.STATE_OPENING]
		for status in visible_states:
			mascot.set_hovered(status == Mascot.STATE_OPENING)
			mascot.set_state(status)
			await process_frame
			await process_frame
			var label: Label = mascot._greeting_label
			var font: Font = label.get_theme_font("font")
			var font_size := label.get_theme_font_size("font_size")
			var glyph_size := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			check(glyph_size.x <= label.size.x and font.get_height(font_size) <= label.size.y,
				"%s倍%s实际字形%s完整容纳于%s" % [factor, status, glyph_size, label.size])
			var text_rect := Rect2(mascot._bubble.position + label.position, label.size)
			check(Rect2(mascot._bubble.position, mascot._bubble.size).encloses(text_rect),
				"%s倍%s文字不越过气泡边界" % [factor, status])
		_assert_drawing_bounds(mascot, "%s倍对局状态" % factor)
		await _capture("status-native-%s" % str(factor).replace(".", "_"))

func _advance_motion(mascot: Control, seconds: float) -> void:
	# 精确推进真实 Tween，避免测试加速或帧率改变摇头采样位置。
	var motion: Tween = mascot._motion
	motion.pause()
	motion.custom_step(seconds)

func _test_status_before_entering_tree() -> void:
	var mascot := Mascot.new()
	mascot.set_state(Mascot.STATE_FOE_ACTING)
	root.add_child(mascot)
	_advance_motion(mascot, 0.3)
	check(mascot._greeting_label.text == "等待对手行动" and mascot._bubble.modulate.a > 0.99,
		"入树前收到的对局状态在入口初次显示时生效")
	mascot.queue_free()
	await process_frame

func _assert_drawing_bounds(mascot: Control, label: String) -> void:
	var bounds := Rect2(Vector2.ZERO, mascot.size)
	for child in mascot.get_children():
		if child is Control:
			var drawing := Rect2(child.position, child.size)
			check(bounds.encloses(drawing), "%s：%s绘制不越过入口窗口" % [label, child.name])

func _capture(suffix: String) -> void:
	var directory := OS.get_environment("DRAWER_MASCOT_CAPTURE_DIR")
	if directory.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(directory)
	check(frame.save_png(directory.path_join("drawer-mascot-%s.png" % suffix)) == OK, "保存%s实渲染截图" % suffix)
	for corner in [Vector2i.ZERO, Vector2i(frame.get_width() - 1, 0), Vector2i(0, frame.get_height() - 1), Vector2i(frame.get_width() - 1, frame.get_height() - 1)]:
		check(frame.get_pixelv(corner).a < 0.01, "%s截图的窗口角落透明" % suffix)
