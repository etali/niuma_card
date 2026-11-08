extends "res://tests/harness.gd"

var host: Node

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1440, 900)
	host = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(host)
	await process_frame
	host.set_process(false)
	host.audio.muted = true
	host.sfx.user_muted = true
	host.state.config.rules.initial.groups = [{"employee": 2, "work": 12}]
	host.state.config.rules.bot.enabled = false
	host._new_game()
	host.hud.drawer_window.pin()
	var live: OffWorkState = host.state
	live.advance(12.0)
	host.board.sync_state(live)
	var original := live.cards.duplicate(true)
	var engine_speed := Engine.time_scale
	var path: String = host.replay.save(host)
	check(host._load_replay(path).ok, "读取真实保存的下班录像")
	var hud: CanvasLayer = host.hud
	check(hud._replay_speed.item_count == 7 and host.replay.speed == 1.0, "提供0.5到4倍的七档速度，初始为1倍")
	for index in host.replay.SPEEDS.size():
		var speed: float = host.replay.SPEEDS[index]
		host.replay.seek(host, 0.0)
		hud._replay_speed.select(index)
		hud._replay_speed.item_selected.emit(index)
		host._process(1.0)
		check(is_equal_approx(host.replay.clock, speed) and is_equal_approx(host.state.time, speed),
			"选择%s倍后，一秒只推进对应录像时间" % speed)
		check(live.time == 12.0 and live.cards == original and Engine.time_scale == engine_speed,
			"倍速不改变暂存真人局或全局时钟")
	host.replay.seek(host, 9.0)
	host._process(1.0)
	check(host.replay.clock == 12.0 and host.state.cards == original, "高速越过关键帧时恢复真实末态并停在录像终点")
	host.replay.seek(host, 2.0)
	hud.set_manual_paused(true)
	host.set_process(true)
	await create_timer(0.1, true).timeout
	check(paused and host.replay.clock == 2.0, "真实暂停阻止录像时间继续推进")
	host.set_process(false)
	hud._replay_time.value = 4.2
	check(is_equal_approx(host.state.time, 4.2) and paused, "暂停时拖动时间条精确跳转，保持暂停")
	hud._replay_speed.select(4)
	hud._replay_speed.item_selected.emit(4)
	check(host.replay.speed == 2.0 and is_equal_approx(host.replay.clock, 4.2), "暂停时选择倍速不移动录像位置")
	hud.set_manual_paused(false)
	host._process(1.0)
	check(is_equal_approx(host.replay.clock, 6.2), "恢复后按新倍率继续，跳转位置不乘倍率")
	hud.set_manual_paused(true)
	for dimensions in [Vector2i(960, 640), Vector2i(1440, 900)]:
		root.size = dimensions
		await process_frame
		hud.relayout()
		await process_frame
		var slider: HSlider = hud._replay_time
		var button: Button = hud.btn_pause
		check(slider.size.y >= button.size.y * 0.7 and slider.size.y < button.size.y,
			"时间条明显加高且略低于同排按钮：%s" % dimensions)
		check(slider.get_theme_stylebox("slider").get_minimum_size().y >= button.size.y * 0.5,
			"可见轨道同步加粗，非仅增大点击区域")
		check(slider.get_global_rect().end.x <= hud._replay_speed.get_global_rect().position.x
			and hud._replay_speed.get_global_rect().end.x <= button.get_global_rect().position.x,
			"进度、倍速和暂停按钮在同排不重叠")
		check(slider.get_global_rect().position.y >= hud._footer.position.y
			and button.get_global_rect().end.x <= hud._footer.get_global_rect().end.x,
			"两种窗口宽度均完整容纳录像控制条")
	if OS.has_environment("WORK_REPLAY_CAPTURE") and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		print("REPLAY_CAPTURE_READY ", OS.get_process_id())
		await create_timer(5.0, true).timeout
	host.stop_replay()
	check(host.state == live and live.time == 12.0 and live.cards == original, "退出录像恢复原牌局和时钟")
	check(not hud._replay_time.visible and not hud._replay_speed.visible and host.replay.speed == 1.0,
		"退出后隐藏录像控制并恢复默认播放倍率")
	host.replay.advance(host, 1.0)
	check(live.time == 12.0 and Engine.time_scale == engine_speed, "非播放状态的推进不影响真人局")
	DirAccess.remove_absolute(path)
	host.queue_free()
	await process_frame
	finish()
