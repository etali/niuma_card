# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

## 新玩家首次引导：老玩家判定、收起入口的常驻提示、必须二选一的教程邀请、
## 以及跳过教程后第一次输局时结算页的一次性补救入口。均走实际装配的主场景。
const Catalog = preload("res://engine/tutorial_catalog.gd")
const Progress = preload("res://engine/tutorial_progress.gd")
const Store = preload("res://engine/json_store.gd")
const RECORDING := "user://replays/old_match.json"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 新玩家首次引导回归 ===")
	_check_returning_detection()
	await _check_handle_hint()
	await _check_modal_invitation()
	await _check_tutorial_choice()
	await _check_post_game_nudge()
	finish()

func _check_returning_detection() -> void:
	seed_first_run_player()
	Progress.settle_returning_player()
	check(not Progress.handle_opened() and not Progress.invitation_seen(), "空白存档按新玩家处理")
	check(Store.save(RECORDING, {}), "准备一份旧录像")
	Progress.settle_returning_player()
	check(not Progress.handle_opened(), "已判定的新玩家之后存下录像，入口提示不会提前消失")
	seed_first_run_player()
	Progress.settle_returning_player()
	check(Progress.handle_opened() and Progress.invitation_seen(), "只有录像的老玩家视为已展开过、也回应过邀请")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RECORDING))
	seed_first_run_player()
	_write_tutorial_progress({"courses": {"income": {"step": 3, "status": "completed"}}, "last_course": "income"})
	Progress.settle_returning_player()
	check(Progress.handle_opened() and Progress.invitation_seen()
		and Progress.course("income").get("status") == "completed", "已有学习记录的老玩家视为已展开过，原记录保留")

func _check_handle_hint() -> void:
	seed_first_run_player()
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "新玩家主场景成功启动"): return
	var presentation: Node = main.drawer_presentation
	var drawer: DrawerWindow = main.drawer_window
	var handle: DrawerMascot = presentation._handle
	check(handle.has_first_run_hint() and not Progress.handle_opened(), "新玩家的入口带首次提示")
	drawer.set_pinned(false)
	drawer.collapse_now()
	for i in 3:
		await process_frame
	_advance(handle, 3.0)
	check(handle.visible and not drawer.is_expanded() and not handle._hovered, "收起后显示桌面入口且尚未悬停")
	check(handle._greeting_label.text == DrawerMascot.FIRST_RUN_TEXT and handle._greeting_label.text == "点这里开局"
		and handle._bubble.visible and handle._bubble.modulate.a > 0.99, "不用悬停就常驻显示点这里开局")
	var before := handle._motion
	handle._process(DrawerMascot.FIRST_RUN_WAVE_INTERVAL + 0.1)
	check(handle._motion != before and handle._motion.is_valid(), "停在桌面时隔一会儿再招一次手")
	_advance(handle, 3.0)
	check(handle._bubble.modulate.a > 0.99, "招手结束后提示仍常驻")
	handle.mouse_entered.emit()
	_advance(handle, 0.3)
	check(handle._greeting_label.text == "点这里开局" and handle._bubble.modulate.a > 0.99, "悬停时仍是同一句提示")
	handle.mouse_exited.emit()
	_advance(handle, 0.3)
	check(handle._greeting_label.text == "点这里开局" and handle._bubble.modulate.a > 0.99, "移开后提示继续常驻")
	handle.set_state("connecting")
	check(handle._greeting_label.text == "正在连接…", "连接等业务状态优先于首次提示")
	handle.set_state("opening")

	var point := handle.get_icon_hit_rect().get_center()
	handle._gui_input(_mouse_button(point, true))
	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(40, 0) * handle.get_render_scale()
	handle._gui_input(motion)
	drawer.drag_to(drawer._geometry.get_center() + Vector2i(-100, 70))
	handle._gui_input(_mouse_button(motion.position, false))
	await process_frame
	_advance(handle, 0.3)
	check(not drawer.is_expanded() and handle.has_first_run_hint() and not Progress.handle_opened()
		and handle._greeting_label.text == "点这里开局", "拖动入口不算展开过，松手后提示仍在")

	point = handle.get_icon_hit_rect().get_center()
	handle._gui_input(_mouse_button(point, true))
	handle._gui_input(_mouse_button(point, false))
	await process_frame
	check(drawer.is_expanded() and not handle.has_first_run_hint() and Progress.handle_opened(), "第一次点开牌桌后记下已展开过")
	drawer.collapse_now()
	for i in 3:
		await process_frame
	_advance(handle, 3.0)
	check(handle.visible and handle._greeting_label.text.is_empty() and handle._bubble.modulate.a < 0.01, "之后再收起恢复安静的入口")
	await dispose_drawer(main)
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	check(not main.drawer_presentation._handle.has_first_run_hint(), "重启后入口不再显示首次提示")
	await dispose_drawer(main)

func _check_modal_invitation() -> void:
	seed_first_run_player()
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "邀请用主场景成功启动"): return
	var presentation: Node = main.drawer_presentation
	await relayout_drawer(main)
	var panel: PanelContainer = presentation._learning_invitation
	var scrim: ColorRect = presentation._invitation_scrim
	check(panel.is_visible_in_tree() and scrim.is_visible_in_tree(), "新玩家展开牌桌即弹出教程邀请并压暗牌桌")
	check(presentation._invitation_layer.layer > maxi(main.msg_log.layer, maxi(main.save_notice.layer, 10)),
		"邀请层压在提示记录、通知和终局层之上")
	var viewport := root.get_visible_rect().size
	check(scrim.get_global_rect().is_equal_approx(Rect2(Vector2.ZERO, viewport)), "压暗层铺满整个视口")
	check(panel.get_global_rect().get_center().distance_to(viewport * 0.5) <= 1.5
		and Rect2(Vector2.ZERO, viewport).encloses(panel.get_global_rect()), "邀请居中且完整可见")
	var start: Button = panel.find_child("InvitationStart", true, false)
	var skip: Button = panel.find_child("InvitationSkip", true, false)
	var body: Label = panel.find_child("InvitationBody", true, false)
	check(body != null and body.text == Catalog.ui("hub.invitation_body") and skip.text == "我会玩，直接开局"
		and start.text == Catalog.ui("hub.invitation_start"), "邀请说明课程内容并给出两个明确选项")
	check(start.has_focus(), "主按钮获得键盘焦点")
	var table_point: Vector2 = presentation.content_rect().get_center()
	check(presentation.pointer_over_panels(Vector2(4, 4)) and presentation.pointer_over_panels(table_point),
		"牌桌任何位置都不能悬停")
	var passes := [0]
	if need(main.btn_pass.is_visible_in_tree(), "结束回合按钮在邀请背后可见"):
		main.btn_pass.pressed.connect(func(): passes[0] += 1)
		await tap_drawer_control(main.btn_pass)
		check(passes[0] == 0 and panel.visible, "点击压暗层后的按钮不起作用，邀请仍在")

	main.drawer_window.set_pinned(false)
	main.drawer_window.collapse_now()
	await process_frame
	check(not panel.visible and not scrim.visible, "收起时邀请和压暗层一起暂存")
	main.drawer_window.pin()
	await relayout_drawer(main)
	check(panel.is_visible_in_tree() and scrim.is_visible_in_tree() and not Progress.invitation_seen(),
		"没有选择前重新展开仍要二选一")
	await tap_drawer_control(skip)
	check(not panel.visible and not scrim.visible and Progress.invitation_seen()
		and Progress.read().get("invitation_choice") == "skip", "选我会玩后关闭并记下选择")
	check(not presentation.pointer_over_panels(table_point), "关闭邀请后牌桌恢复可操作")
	await tap_drawer_control(main.btn_pass)
	check(passes[0] == 1, "同样的点击在关闭邀请后能按到结束回合")
	await dispose_drawer(main)
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	await relayout_drawer(main)
	check(not main.drawer_presentation.is_learning_invitation_open(), "回答过的邀请重启后不再出现")
	await dispose_drawer(main)

func _check_tutorial_choice() -> void:
	seed_first_run_player()
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "教程选择用主场景成功启动"): return
	var presentation: Node = main.drawer_presentation
	await relayout_drawer(main)
	await tap_drawer_control(presentation._learning_invitation.find_child("InvitationStart", true, false))
	await relayout_drawer(main)
	check(is_instance_valid(presentation.tutorial) and presentation.tutorial.session.course_id == str(Catalog.courses()[0]["id"])
		and not presentation.is_learning_invitation_open(), "带我上手直接在牌桌上开始第一课")
	check(Progress.read().get("invitation_choice") == "tutorial" and not Progress.wants_post_game_nudge(),
		"选了教程的玩家不会在结算页再被提示")
	presentation.finish_tutorial()
	await dispose_drawer(main)

func _check_post_game_nudge() -> void:
	seed_first_run_player()
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "结算补救用主场景成功启动"): return
	main.sfx.set_muted(true)
	var presentation: Node = main.drawer_presentation
	await relayout_drawer(main)
	await tap_drawer_control(presentation._learning_invitation.find_child("InvitationSkip", true, false))
	_finish_match(main, true)
	await relayout_drawer(main)
	check(main.game_over_panel.find_child("ResultTutorial", true, false) == null and Progress.wants_post_game_nudge(),
		"赢了不打扰，补救机会留到之后")
	main._on_restart()
	await relayout_drawer(main)
	_finish_match(main, false)
	await relayout_drawer(main)
	var learn: Button = main.game_over_panel.find_child("ResultTutorial", true, false)
	check(learn != null and learn.is_visible_in_tree() and learn.text == Catalog.ui("hub.post_game_nudge"),
		"跳过教程后第一次输掉单机局，结算页补一个教程入口")
	check(not Progress.wants_post_game_nudge(), "补救入口只给一次")
	if learn != null:
		var layer := _canvas_of(main.game_over_panel)
		await tap_drawer_control(learn)
		await relayout_drawer(main)
		check(is_instance_valid(presentation.tutorial) and not layer.visible, "点它在原牌桌开始第一课，终局层暂存")
		presentation.finish_tutorial()
		await relayout_drawer(main)
		check(layer.visible and main.phase == main.PHASE_OVER, "结束教程回到原来的终局画面")
	main._on_restart()
	await relayout_drawer(main)
	_finish_match(main, false)
	await relayout_drawer(main)
	check(main.game_over_panel.find_child("ResultTutorial", true, false) == null, "之后再输也不再提示")
	await dispose_drawer(main)

func _finish_match(main: Node, won: bool) -> void:
	main.state.winner = main.my_seat if won else main.foe_seat
	main.state.win_reason = "测试结算原因。"
	main._show_game_over()

func _canvas_of(node: Node) -> CanvasLayer:
	while node != null and not node is CanvasLayer:
		node = node.get_parent()
	return node as CanvasLayer

func _advance(mascot: DrawerMascot, seconds: float) -> void:
	var motion: Tween = mascot._motion
	if motion == null or not motion.is_valid():
		return
	motion.pause()
	motion.custom_step(seconds)

func _mouse_button(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.global_position = position
	return event
