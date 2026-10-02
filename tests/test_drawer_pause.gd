# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 抽屉暂停语义回归：等待玩家输入时冻结时钟，AI 与联网对手在收起时继续推进。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉暂停与 AI 线程回归 ===")
	var main := await _boot_drawer_main()
	if not need(main != null and main.drawer_window != null, "抽屉模式 main 实例化"):
		finish()
		return
	var drawer = main.drawer_window
	drawer.animations_enabled = false
	drawer.pin()
	self.paused = false

	# 等待玩家输入时，单机收起暂停 _animation_now_ms；计时器仍使用墙钟。
	var before: int = main._animation_now_ms()
	drawer.collapse_now()
	check(self.paused, "等待玩家行动时收起后 SceneTree 暂停")
	var paused_at: int = main._animation_now_ms()
	await _real_wait(0.15)
	var paused_after: int = main._animation_now_ms()
	check(abs(paused_after - paused_at) <= 2, "收起期间演出时钟冻结（变化%dms）" % abs(paused_after - paused_at))
	drawer.expand()
	check(not self.paused, "展开后恢复 SceneTree")
	await _real_wait(0.15)
	var resumed: int = main._animation_now_ms()
	check(resumed > paused_after, "展开后演出时钟继续增加")
	check(before <= paused_at, "暂停起点不早于收起前时钟")

	# 此探针没有切成AI行动，仍在等待玩家：纯计算可结束，包装协程须等展开。
	ThinkClock.reset()
	var probe := {"done": false, "returns": 0, "value": null}
	call_deferred("_probe_think", main, probe)
	var wait := 0
	while not ThinkClock.running() and wait < 30:
		await process_frame
		wait += 1
	check(ThinkClock.running(), "AI 搜索开始并进入 ThinkClock")
	drawer.collapse_now()
	await _real_wait(0.22)
	check(not ThinkClock.running(), "AI 工作线程完成后 ThinkClock 停表")
	check(not probe.done, "等待玩家期间收起时，线程探针仍遵守暂停")
	drawer.expand()
	wait = 0
	while not probe.done and wait < 60:
		await process_frame
		wait += 1
	check(probe.done, "展开后 AI 包装协程恢复")
	check(probe.returns == 1 and probe.value == 42, "AI 结果只返回一次且值正确")
	check(not ThinkClock.running(), "AI 结果恢复后 ThinkClock 仍已停止")

	# 真实行动阶段锁不被窗口收放覆盖。
	main.phase = main.PHASE_ACTION
	main._actor = main.foe_seat
	main.board.input_locked = true
	drawer.collapse_now()
	check(not self.paused, "真正轮到AI行动时收起不暂停，可继续计算和落地")
	check(main.board.input_locked, "AI行动阶段的业务输入锁保持")
	drawer.expand()
	check(main.board.input_locked, "AI行动阶段展开后业务输入锁仍保持")

	# _host 非空代表本机嵌入服务器：收起只静音，不暂停 SceneTree。
	main._host = EmbeddedHost.new()
	self.paused = false
	drawer.collapse_now()
	check(not self.paused, "嵌入主机存在时收起不暂停 SceneTree")
	check(main.sfx.muted, "嵌入主机收起时静音")
	drawer.expand()
	check(not self.paused, "嵌入主机展开仍不暂停 SceneTree")
	check(not main.sfx.muted, "嵌入主机展开恢复音效")
	main._host = null

	main.sfx.set_muted(true)
	main.sfx.free()
	main.queue_free()
	await process_frame
	await process_frame
	finish()

func _boot_drawer_main() -> Node:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	if main.get("force_drawer_layout") != null:
		main.force_drawer_layout = true
	var window := root
	if window is Window:
		window.size = Vector2i(1280, 900)
		window.content_scale_size = Vector2i.ZERO
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	return main

func _real_wait(seconds: float) -> void:
	await create_timer(seconds, true, false, true).timeout

func _probe_think(main: Node, probe: Dictionary) -> void:
	var result: Variant = await main._think_off_thread(func() -> Variant:
		OS.delay_msec(100)
		return 42)
	probe.value = result
	probe.returns += 1
	probe.done = true
