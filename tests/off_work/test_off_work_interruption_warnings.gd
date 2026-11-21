# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 打断先有预告：罢工还在飞的时候，它瞄准的那一组就画上铅笔虚线框，能拦它的工会牌动一下；
## 被工会挡回时工会牌盖「驳回」；罢工中的人显示一条朱红色、往回走的条；结束时盖「复工」。
## 三种坏消息各有自己的声音。
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	_sounds()
	await _strike_in_flight()
	await _blocked_by_the_union()
	await _dispose()
	finish()

func _fixture(flight_seconds: float) -> void:
	await _dispose()
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 120, "employee": 2}]
	config.rules.initial.money = 3
	config.rules.bot.enabled = false
	config.rules.strike.flight_seconds = flight_seconds
	config.rules.conveyor.pool = {"employee": 1}
	config.rules.conveyor.interval_seconds = 1000.0
	state = OffWorkState.new(config)
	state.new_game(20261121)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera, true)
	_sync([])

func _dispose() -> void:
	if is_instance_valid(host):
		host.queue_free()
		await process_frame
	host = null
	board = null

func _sync(events: Array) -> void:
	board.sync_state(state)
	for event in events: board.play_event(event)
	board._sync_group_task_progress()
	board._sync_stack_occlusion()
	board._sync_drop_targets(0.3)
	for presenter in [board, board.enemy_board]:
		for item in presenter._move_tw.values():
			if item.tw != null and item.tw.is_valid():
				item.tw.pause()
				item.tw.custom_step(1.0)

func _my_gid() -> int:
	return int(state.cards[state._owner_type(0, "work")[0]].group)

func _sounds() -> void:
	var actions: Dictionary = UIConfig.read_section("presentation").audio.actions
	var files := {}
	for name in ["strike_launch", "meeting_start", "transfer"]:
		check(actions.has(name) and FileAccess.file_exists("res://assets/sfx/" + str(actions[name].file)), "%s 有自己的声音文件" % name)
		files[str(actions[name].file)] = true
	check(files.size() == 3, "罢工起飞、被叫去开会、被甩锅是三种不同的声音（%s）" % str(files.keys()))
	check(str(actions.strike_launch.file) == "whistle.wav" and str(actions.meeting_start.file) == "meeting_bell.wav" and str(actions.transfer.file) == "paper_slam.wav",
		"分别是哨声、会议铃、一摞纸砸在桌上")
	for name in ["strike_blocked", "strike_end"]:
		check(actions.has(name) and FileAccess.file_exists("res://assets/sfx/" + str(actions[name].file)), "%s 不再是无声事件" % name)

func _strike_in_flight() -> void:
	await _fixture(1.2)
	var gid := _my_gid()
	var union: int = state.add_card("union", 0)
	var strike: int = state.add_card("strike", 1)
	_sync(state.drain_events())
	check(board._threat_frames.is_empty(), "没有罢工在飞时桌上没有预告框")
	var card: OffWorkCard = board.by_uid[union]
	check(card._drag_visual_tween == null or not card._drag_visual_tween.is_running(), "工会牌原本静止")
	check(state.activate(strike, gid), "对手对我方的工作组发动罢工")
	var events: Array = state.drain_events()
	check(events.any(func(event): return event.kind == "strike_launch") and state.pending_strikes.has(strike), "罢工牌还在飞，没有落下")
	_sync(events)
	check(board._threat_frames.keys() == [gid], "它瞄准的那一组画上预告框")
	var frame: Node3D = board._threat_frames[gid]
	var front: OffWorkCard = board.group_of(board.by_uid[state._owner_type(0, "work")[0]]).cards[0]
	check(frame.material_override.get_shader_parameter("dashed") == true and is_equal_approx(frame.material_override.get_shader_parameter("opacity"), 1.0),
		"框是铅笔虚线，已经画出来")
	check(absf(frame.global_position.x - front.global_position.x) < CardEntity.CARD_SIZE.x and absf(frame.global_position.z - front.global_position.z) < CardEntity.CARD_SIZE.z,
		"框围着被瞄准的那一组")
	check(card._drag_visual_tween != null and card._drag_visual_tween.is_valid() and card._drag_visual_tween.is_running(),
		"手里能拦它的工会牌动了一下（和落桌一样的一下压弹）")
	# 落下：框撤掉，人开始罢工，头上是一条朱红色往回走的条。
	state.advance(1.3)
	_sync(state.drain_events())
	check(not state.pending_strikes.has(strike) and board._threat_frames.is_empty(), "罢工落下后预告框撤掉")
	var strikers: Array = state.cards.keys().filter(func(uid): return state.is_striking(uid))
	if not need(not strikers.is_empty(), "有人开始罢工"): return
	var person: OffWorkCard = board.by_uid[strikers[0]]
	check(person._task_progress.visible and person._task_progress_phase == "strike", "罢工中的人显示罢工的条")
	check(person._task_progress_material.get_shader_parameter("fill_color").is_equal_approx(Palette.semantic("danger")), "条是朱红色（危险色）")
	var full: float = person.task_progress_display_value()
	state.advance(float(state.cards[strikers[0]].total) * 0.5)
	_sync(state.drain_events())
	var half: float = person.task_progress_display_value()
	check(full > 0.9 and absf(half - 0.5) < 0.1, "条从满往回走：刚开始 %.2f，过一半 %.2f" % [full, half])
	# 结束：盖「复工」，条收起。
	state.advance(float(state.cards[strikers[0]].total))
	var ending: Array = state.drain_events()
	check(ending.any(func(event): return event.kind == "strike_end"), "罢工结束")
	_sync(ending)
	check(person.stamp_showing() and person.stamp_text() == str(OffWorkUI.section("rig").resume_word), "罢工结束的人牌面盖「复工」")
	check(person._task_progress_phase != "strike" or not person._task_progress.visible, "罢工的条收起")

func _blocked_by_the_union() -> void:
	await _fixture(1.2)
	var gid := _my_gid()
	var union: int = state.add_card("union", 0)
	var strike: int = state.add_card("strike", 1)
	_sync(state.drain_events())
	check(state.activate(strike, gid), "对手发动罢工")
	_sync(state.drain_events())
	check(board._threat_frames.has(gid), "罢工在飞，预告框在")
	# 飞行途中把工会放进这一组。
	check(state.move_cards([union], gid) >= 0, "把工会牌加进被瞄准的组")
	state.advance(1.3)
	var events: Array = state.drain_events()
	check(events.any(func(event): return event.kind == "strike_blocked"), "罢工被工会挡回")
	_sync(events)
	var card: OffWorkCard = board.by_uid[union]
	check(card.stamp_showing() and card.stamp_text() == str(OffWorkUI.section("rig").blocked_word), "挡住它的工会牌盖「驳回」")
	check(board._threat_frames.is_empty(), "预告框撤掉")
	check(state.cards.keys().filter(func(uid): return state.is_striking(uid)).is_empty(), "没有人罢工")
