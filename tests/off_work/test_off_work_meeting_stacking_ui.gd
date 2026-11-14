# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 900)
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 100}, {"leader": 1}]
	config.rules.bot.enabled = false
	config.rules.conveyor.interval_seconds = 1000.0
	state = OffWorkState.new(config)
	state.new_game(20261114)
	OffWorkCardDB.configure(config)
	var group := state.create_group(0)
	state.add_card("leader", 0, group)
	state.add_card("leader", 0, group)
	var primary := state.add_card("meeting", 0, group)
	var secondary := state.add_card("meeting", 0, group)
	var extra_host := state.add_card("employee", 0)
	var target_group := state.create_group(1)
	for _i in 12: state.add_card("employee", 1, target_group)
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
	board.set_debug_mode(true)
	_sync()
	_finish_layout()
	check(state.activate(primary, group), "真实规则启动两名领导和两张开会牌组合")
	_sync()
	var meeting: Dictionary = state.meetings[primary]
	var visitors: Array = meeting.targets.duplicate()
	check(visitors.size() == 8 and board._meeting_visitors.size() == 8,
		"两名领导累计八个名额，两张开会牌只拉入八名真实访客")
	check(is_equal_approx(meeting.total, 14.4), "两张开会牌共享14.4秒时长")
	state.advance(7.2)
	_sync()
	board._advance_meeting_visitors(7.2)
	check(visitors.all(func(uid): return board._meeting_visitors[uid].phase == "orbit"),
		"八名实际人员完成入场并持续绕圈")
	var elapsed: float = board._meeting_centers[primary].elapsed
	var identity: int = meeting.id
	var instance_ids := {}
	for uid in visitors: instance_ids[uid] = board.by_uid[uid].get_instance_id()
	check(state.move_cards([primary], -1) >= 0, "半途移走主开会牌")
	_sync()
	meeting = state.meetings.get(secondary, {})
	check(not meeting.is_empty() and meeting.get("id", -1) == identity
		and meeting.get("targets", []) == visitors,
		"剩余开会牌接续同一场会议和原八名人员")
	check(not board._meeting_centers.has(primary) and board._meeting_centers.has(secondary)
		and is_equal_approx(float(board._meeting_centers[secondary].elapsed), elapsed),
		"代表开会牌切换时绕圈时钟不归零")
	check(visitors.all(func(uid): return (board._meeting_visitors[uid].phase == "orbit"
		and int(board._meeting_visitors[uid].meeting) == secondary
		and board.by_uid[uid].get_instance_id() == instance_ids[uid])),
		"原人员保持绕圈，同一实体接续新中心而不重复拉入动画")
	var remaining_card: OffWorkCard = board.by_uid[secondary]
	check(remaining_card._task_progress_phase == "meeting"
		and is_equal_approx(remaining_card._task_progress_value, 0.5)
		and is_equal_approx(remaining_card._debug_remaining, 6.0),
		"次开会牌继续显示半程进度及缩短后的6秒倒计时")
	check(board.by_uid[primary]._task_progress_phase == "recovering"
		and is_equal_approx(board.by_uid[primary]._debug_remaining, 24.0),
		"移走的开会牌独立进入24秒冷却")
	check(state.move_cards([extra_host], group) == group, "新增员工实际加入主持组")
	_sync()
	var added: Array = state.meetings[secondary].targets.filter(func(uid): return not visitors.has(uid))
	check(added.size() == 2 and board._meeting_visitors.size() == 10
		and added.all(func(uid): return board._meeting_visitors[uid].phase == "pull")
		and visitors.all(func(uid): return board._meeting_visitors[uid].phase == "orbit"),
		"新增主持只拉入新增两人，原八人保持绕圈")
	board._advance_meeting_visitors(2.0)
	check(state.move_cards([extra_host], -1) >= 0, "新增主持随后离开会议")
	_sync()
	check(state.meetings[secondary].targets == visitors
		and added.all(func(uid): return board._meeting_visitors[uid].phase == "return")
		and visitors.all(func(uid): return board._meeting_visitors[uid].phase == "orbit"),
		"容量缩回八人，只释放超额两人返岗")
	board._advance_meeting_visitors(2.0)
	_finish_layout()
	check(board._meeting_visitors.size() == 8
		and added.all(func(uid): return (not board.by_uid[uid].has_meta("meeting_visit")
			and not state.is_meeting_target(uid) and int(state.cards[uid].group) == target_group)),
		"返岗完成释放动画标记，人员仍属于真实原组")
	host.queue_free()
	await process_frame
	finish()

func _sync() -> void:
	var events := state.drain_events()
	board.sync_state(state)
	for event in events: board.play_event(event)

func _finish_layout() -> void:
	for presenter in [board, board.enemy_board]:
		for item in presenter._move_tw.values():
			if item.tw != null and item.tw.is_valid():
				item.tw.pause()
				item.tw.custom_step(0.2)
