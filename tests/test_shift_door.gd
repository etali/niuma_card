# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	_run.call_deferred()

func click_control(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion,true)
	await process_frame
	for pressed in [true,false]:
		var mouse := InputEventMouseButton.new()
		mouse.position = point
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.pressed = pressed
		root.push_input(mouse,true)
		await process_frame

func _run() -> void:
	# The normal boot is intentional: a test that only instantiates either table
	# misses input forwarding between the native window and the active viewport.
	root.size = Vector2i(1600,900)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for _i in 12: await process_frame
	var host := current_scene
	check(host.scene_file_path == "res://scenes/shift_host.tscn","默认入口载入双模式宿主")
	if not host.has_method("switch_mode"):
		finish()
		return
	var on: Node = host.tables[0]
	var first: BaseButton = host.sign
	check(on.state != null and host.tables[1] == null and first.intro,"先显示牛马牌并保留原开局")
	await create_timer(6.5).timeout
	check(not first.intro and not first.turning and host.active == 0,"五秒旋转门介绍结束后仍在上班")
	var felt: Node3D = host.backdrop
	var on_state: RefCounted = on.state
	var timer: Timer = on._drawer_timer(10.0)
	var animated := Node2D.new()
	on.add_child(animated)
	var tween := animated.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(animated,"position:x",100.0,10.0)
	await click_control(first)
	await create_timer(1.1).timeout
	check(host.active == 1 and not host.views[0].visible,"顶部标题点击进入下班")
	if host.active != 1:
		finish()
		return
	var off: Node = host.tables[1]
	check(host.sign == first and host.backdrop == felt and felt.get_parent() == off, "换班沿用同一个招牌和桌面背景")
	var off_state: RefCounted = off.state
	var frozen: float = timer.time_left
	var frame_before: float = animated.position.x
	var time_before: float = off.state.time
	await create_timer(0.3).timeout
	check(is_equal_approx(timer.time_left,frozen) and off.state.time > time_before,"上班计时器暂停，仅下班推进")
	check(is_equal_approx(animated.position.x,frame_before),"允许暂停时播放的补间也冻结在切换帧")
	off.hud.set_manual_paused(true)
	await click_control(host.sign)
	await create_timer(1.15).timeout
	check(host.active == 0 and not paused and on.state == on_state,"从手动暂停的下班局切回原上班局")
	var off_time: float = off.state.time
	await create_timer(0.25).timeout
	check(is_equal_approx(off_time,off.state.time) and timer.time_left < frozen,"离开的下班时钟冻结，上班节拍继续")
	check(animated.position.x > frame_before,"返回上班，冻结补间从原进度继续")
	await click_control(first)
	await create_timer(1.15).timeout
	check(host.active == 1 and off.state == off_state and paused,"再入下班保留同一游戏实例和手动暂停")
	off.hud.set_manual_paused(false)
	off.begin_practice("upgrade")
	var practice: OffWorkState = off.state
	await click_control(host.sign)
	await create_timer(1.15).timeout
	check(host.active == 0 and on.state == on_state, "练习面板不挡换班招牌")
	await click_control(host.sign)
	await create_timer(1.15).timeout
	check(host.active == 1 and off.state == practice and off.lesson.lesson.id == "upgrade", "回到下班继续原来那课")
	off.finish_practice()
	check(off.state == off_state, "从跨班次练习回到原正式桌")
	await create_timer(0.2).timeout
	check(off.state.time > off_time,"两种模式可分别继续游戏")
	await click_control(host.sign)
	await create_timer(1.15).timeout
	# A hosted room is a live peer, so its socket must keep polling even when
	# the foreground off-duty table is manually paused.
	var opened: Dictionary = on.start_local_host()
	check(opened.get("ok",false),"上班真实联机房间启动")
	if opened.get("ok",false):
		await click_control(first)
		await create_timer(1.15).timeout
		check(host.active == 1 and on.can_process(),"上班后台继续轮询，前台显示下班")
		off.hud.set_manual_paused(true)
		var remote := WebSocketPeer.new()
		var error := remote.connect_to_url("ws://127.0.0.1:%d" % on.local_host_port())
		var until := Time.get_ticks_msec() + 3000
		while remote.get_ready_state() == WebSocketPeer.STATE_CONNECTING and Time.get_ticks_msec() < until:
			remote.poll()
			await process_frame
		check(error == OK and remote.get_ready_state() == WebSocketPeer.STATE_OPEN,
			"下班暂停时上班仍完成真实 WebSocket 握手")
		remote.close()
		off.hud.set_manual_paused(false)
		on.stop_local_host()
	check(not host.remembers_mode(["--room=ABCD"]) and not host.remembers_mode(["--solo"])
		and not host.remembers_mode(["--cards-config=/tmp/custom.json"]),"联网或显式单局启动保留玩家的班次偏好")
	# Re-enter through the real project boot with persisted slots, using the
	# mobile layout to also exercise touch targets without a native drawer.
	OS.set_environment("CARD_MOBILE_MODE","1")
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for _i in 20: await process_frame
	host = current_scene
	check(host.active == 1 and host.tables[0] == null and not host.sign.intro,"重新打开直接回下班，不重播首次介绍")
	off = host.tables[1]
	check(off.mobile_mode and off.hud.drawer_window == null,"移动端下班使用固定全屏，没有桌面抽屉")
	await create_timer(0.7).timeout
	var touch := InputEventScreenTouch.new()
	touch.position = host.sign.get_global_rect().get_center()
	for pressed in [true,false]:
		touch.pressed = pressed
		Input.parse_input_event(touch.duplicate())
		await process_frame
	await create_timer(1.15).timeout
	check(host.active == 0 and host.tables[0].mobile_mode and host.tables[0].drawer_window == null,
		"移动端触摸标题从下班回到全屏上班")
	finish()
