# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Shift = preload("res://scenes/shift_choreography.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var on := await boot_main()
	var board: Board = on.board
	var cards := make_stack(on, board, 9000, "yunketang", 4)
	var mine := board.make_group(cards, true)
	board.groups.append(mine)
	board._layout_group(mine)
	await settle()
	board.show_side_badges("foe", cards, Vector3(4.0, 0.1, -4.0))
	_check_shift(on, [mine, board._ext_side["foe"]], "上班")

	var fx := preload("res://scenes/table_feedback.gd").receipt(on, "purchase", Vector3.ZERO, "到账", Color.WHITE)
	var torn := CardEntity.new()
	torn.setup(9050, "cash")
	on.add_child(torn)
	torn.tear_apart()
	var phase := Shift.new()
	phase.capture(on)
	phase.pose(1.0, 0.0)
	check(not fx.is_visible_in_tree() and not torn.is_visible_in_tree(), "撕裂半牌、桌面回执不会残留")
	board.show_side_badges("network", cards, Vector3(3.0, 0.1, -2.0))
	var fresh := board.side_nodes_of("network")
	check(not fresh[1].is_visible_in_tree(), "换班中联机新建的侧栏在牌堆旁保持收起")
	phase.restore()
	check(fresh[1].is_visible_in_tree(), "散牌后新侧栏在实际牌位展开")
	on.free()
	_booted = null

	var off: Node3D = load("res://scenes/work_main.tscn").instantiate()
	off.set_meta("shift_enter_expanded", true)
	root.add_child(off)
	off.set_process(false)
	off.state.config.rules.initial.groups = [{"work": 4, "employee": 1, "overtime": 1}]
	off._new_game()
	await create_timer(0.4).timeout
	off.set_shift_hidden(true)
	check(not off.effects.is_visible_in_tree() and not off.table_hands.visible, "收牌时暂存手势与屏幕特效")
	off.set_shift_hidden(false)
	check(off.effects.is_visible_in_tree() and off.table_hands.visible, "回桌时恢复手势与屏幕特效")
	var groups_with_sides: Array = []
	for side in [off.board, off.board.enemy_board]:
		for group in side.groups:
			if not group.get("side", []).is_empty(): groups_with_sides.append(group)
	if need(groups_with_sides.size() >= 2, "下班己方与对手使用真实收拢组合"):
		_check_shift(off, groups_with_sides, "下班")
	finish()

func _check_shift(game: Node3D, stacks: Array, label: String) -> void:
	var marks: Array[Node3D] = []
	var original: Array[Vector3] = []
	for group in stacks:
		for node in group.side:
			if is_instance_valid(node):
				marks.append(node)
				original.append(node.global_position)
	if not need(not marks.is_empty(), label + "有可见图标和计数"): return
	var phase := Shift.new()
	phase.capture(game)
	phase.pose(0.30, 0.0)
	var moved := true
	for i in marks.size():
		moved = moved and marks[i].global_position.distance_to(original[i]) > 0.025
	check(moved, label + "开始收牌时左右两侧牌摞的图标、计数跟随牌摞")
	phase.pose(1.0, 1.0)
	check(marks.all(func(mark): return not mark.is_visible_in_tree()), label + "桌面收空时没有悬空图标、计数")
	phase.pose(0.30, 0.0)
	phase.restore()
	var restored := true
	for i in marks.size():
		restored = restored and marks[i].is_visible_in_tree() and marks[i].global_position.is_equal_approx(original[i])
	check(restored, label + "散牌后每个图标与计数均原位恢复")
	phase.deck.free()
