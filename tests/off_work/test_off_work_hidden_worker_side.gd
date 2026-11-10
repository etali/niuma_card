# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":800, "employee":2, "overtime":1}]
	config.rules.initial.money = 0
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(67)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	board.sync_state(state)
	var shared := Board.new()
	check(not shared.side_include_single_core, "共享上班侧栏默认行为不变")
	shared.free()
	check(not Board.side_spec([board.by_uid[state._owner_type(1, "employee")[0]]]).any(
		func(row): return row.tex == CardArt.icon_texture("employee", OffWorkCardDB)),
		"共享静态侧栏调用仍省略已露顶的单核心")
	state.advance(2.0)
	for owner in [0, 1]:
		_check_split(owner)
	await _check_meeting()
	host.queue_free()
	await process_frame
	finish()

func _check_split(owner: int) -> void:
	var people: Array = state._owner_type(owner, "employee")
	var gid := int(state.cards[people[0]].group)
	var presenter: Board = board._presenter(owner)
	# The reported 67-second position follows this legal split: one worker and
	# one file leave; a single worker remains buried behind hundreds of files.
	check(state.move_cards([people[0], state.group_work(gid).back()]) != gid,
		"玩家%d：一名员工携工作拆成另组" % owner)
	board.sync_state(state)
	var group: Dictionary = presenter.group_of(board.by_uid[people[1]])
	check(group.compact and board._stack_occluded.has(people[1]) and not board.by_uid[people[1]]._visual.visible,
		"玩家%d：复现剩余员工牌面被大工作堆遮挡" % owner)
	_check_row(group, "employee", "×1", "玩家%d拆分后" % owner)
	_check_row(group, "overtime", "×1", "玩家%d拆分后" % owner)
	var top: OffWorkCard = group.cards[presenter._top_index(group)]
	var progress := state.group_work_progress(gid)
	check(top._task_progress.visible and state.group_work_participants(gid) == [people[1]],
		"玩家%d：进度条对应真实唯一员工" % owner)
	state.advance(1.0)
	board.sync_state(state)
	check(state.group_work_progress(gid) > progress and top._task_progress.visible,
		"玩家%d：有员工时真实生产继续" % owner)
	_check_row(group, "employee", "×1", "玩家%d计时刷新后" % owner)
	check(state.move_cards([people[1]]) != gid, "玩家%d：最后一名员工离开" % owner)
	board.sync_state(state)
	check(state.group_work_participants(gid).is_empty() and not top._task_progress.visible,
		"玩家%d：无人组同帧清除进度条" % owner)
	check(_row(group, "employee").is_empty(), "玩家%d：无人组不残留员工图标" % owner)
	progress = state.group_work_progress(gid)
	var files := state.group_work(gid).size()
	state.advance(1.0)
	board.sync_state(state)
	check(is_equal_approx(state.group_work_progress(gid), progress) and state.group_work(gid).size() == files
		and not top._task_progress.visible, "玩家%d：加班不能单独推进工作" % owner)
	check(state.move_cards([people[1]], gid) == gid, "玩家%d：员工返回原组" % owner)
	board.sync_state(state)
	_check_row(group, "employee", "×1", "玩家%d返岗后" % owner)
	check(top._task_progress.visible and is_equal_approx(top._task_progress_value, progress),
		"玩家%d：返岗恢复真实保留进度" % owner)

func _check_meeting() -> void:
	var capacity: int = state.config.meeting_capacity("leader")
	state.config.rules.initial.groups = [{"work":800, "employee":capacity + 1, "overtime":1}]
	state.new_game(68)
	board.reset_view()
	var workers: Array = state._owner_type(1, "employee")
	var gid := int(state.cards[workers[0]].group)
	board.sync_state(state)
	var leader := state.add_card("leader", 0)
	var meeting := state.add_card("meeting", 0)
	state.move_cards([meeting], int(state.cards[leader].group))
	board.sync_state(state)
	var affected: Array = state.meetings[meeting].targets
	check(affected.size() == capacity, "真实开会带走除一人以外的员工")
	var remaining: Array = workers.filter(func(uid): return not affected.has(uid))
	check(remaining.size() == 1 and state.group_people(gid).size() == capacity + 1,
		"参会者保留逻辑归属但现场仅剩一人")
	var group: Dictionary = board.enemy_board.group_of(board.by_uid[remaining[0]])
	_check_row(group, "employee", "×1", "开会后的实际留岗人员")
	check(state.group_work_participants(gid) == remaining, "仅剩真实留岗员工推进生产")
	board._advance_meeting_visitors(2.0)
	await process_frame

func _row(group: Dictionary, kind: String) -> Array:
	var texture := CardArt.icon_texture(kind, OffWorkCardDB)
	var nodes: Array = group.get("side", [])
	for index in range(0, nodes.size() - 1, 2):
		if is_instance_valid(nodes[index]) and nodes[index] is Sprite3D and nodes[index].texture == texture:
			return [nodes[index], nodes[index + 1]]
	return []

func _check_row(group: Dictionary, kind: String, expected: String, label: String) -> void:
	var row := _row(group, kind)
	check(row.size() == 2 and row[0].is_visible_in_tree() and row[1].is_visible_in_tree()
		and row[1].text == expected, "%s：%s图标和%s数量都可见" % [label, kind, expected])
