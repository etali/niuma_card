# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 直接运行真实 Board 的拾取、拖动和松手路径；鼠标投影使用固定点，避免窗口系统
## 和摄像机自动构图影响测试。边界由抽屉展示层给定，本测试检查可玩范围和缩窗恢复。
class DragBoard extends Board:
	var mouse_point := Vector3.ZERO

	func _mouse_table_point() -> Vector3:
		return mouse_point

var board: DragBoard
var stage: Node3D
var next_uid := 940000

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	stage = Node3D.new()
	root.add_child(stage)
	board = DragBoard.new()
	stage.add_child(board)
	board.set_process(false)
	board.set_physics_process(false)
	board.player_min_z = 1.2
	board.player_max_z = 5.7
	var wide_table := Rect2(-17.0, -7.0, 34.0, 18.0)
	var wide_player := Rect2(-16.0, 1.2, 32.0, 9.0)
	board.set_playable_bounds(wide_table, wide_player)

	var left := _card(Vector3(-3.0, 0.05, 3.0))
	_drag_to(left, Vector3(-14.0, 0.05, 8.0))
	check(left.global_position.x < -10.0 and left.global_position.z > 5.7,
		"拖牌落点可进入旧左边界和旧底边之外的可见桌面")
	left.freeze = true
	var right := _card(Vector3(3.0, 0.05, 3.0))
	_drag_to(right, Vector3(14.0, 0.05, 8.0))
	check(right.global_position.x > 10.0 and right.global_position.z > 5.7,
		"拖牌落点可进入旧右边界和旧底边之外的可见桌面")
	right.freeze = true
	check(_inside(left) and _inside(right), "扩大后左右落点仍让整张卡面留在桌内")
	var middle := _card(Vector3(0.0, 0.05, 3.0))
	var middle_at := middle.global_position
	var members: Array = []
	for i in 5:
		members.append(_card(Vector3(12.0, 0.05, 6.0) + Board.STACK_GAP * i))
	var group := board.make_group(members)
	board.groups.append(group)
	var original_uids: Array = members.map(func(c): return c.uid)
	var original_offsets: Array = members.map(func(c): return c.global_position - members[0].global_position)
	var narrow_table := Rect2(-10.8, -5.25, 21.6, 11.3)
	var narrow_player := Rect2(-10.0, 1.2, 20.0, 4.5)
	board.set_playable_bounds(narrow_table, narrow_player)
	check(_all_inside(members + [left, right, middle]), "缩小窗口后整摞及散卡的完整卡面都留在新边界内")
	check(middle.global_position.is_equal_approx(middle_at), "缩窗不移动原本就在边界内的卡")
	check(members.map(func(c): return c.uid) == original_uids and group["cards"] == members,
		"缩窗保持牌组成员和 UID 顺序")
	var shape_preserved := true
	for i in members.size():
		shape_preserved = shape_preserved and (members[i].global_position - members[0].global_position).is_equal_approx(original_offsets[i])
		shape_preserved = shape_preserved and members[i].scale.is_equal_approx(Vector3.ONE)
	check(shape_preserved, "容得下的牌摞整体平移，组内相对位置和卡面比例不变")
	# 抓起整摞后在原位松手：即使拖拽帧把牌抬高，落点仍必须精确回到原锚点。
	var origin_members: Array = []
	for i in 4:
		origin_members.append(_card(Vector3(-4.0, 0.05, 3.0) + Board.STACK_GAP * i))
	var origin_group := board.make_group(origin_members)
	board.groups.append(origin_group)
	await create_timer(0.25).timeout
	var origin_positions: Array = origin_members.map(func(c): return c.global_position)
	board.mouse_point = origin_members[0].global_position
	board._on_card_clicked(origin_members[0])
	board.mouse_point = origin_positions[0]
	board._process(1.0 / 60.0)
	board._end_drag()
	await create_timer(0.25).timeout
	var origin_stable := true
	for i in origin_members.size():
		origin_stable = origin_stable and origin_members[i].global_position.is_equal_approx(origin_positions[i])
	check(origin_stable, "整摞原地松手后每张牌回到原始落点")

	check(board.toggle_compact(members[0]), "边缘牌摞仍能双击收拢")
	await create_timer(0.25).timeout
	check(_all_inside(members), "收拢后整摞卡面仍在边界内")
	# 高摞使用 capped_offset；原地拖放不能因重新建组时丢失 cap 而改变 x/z。
	var tall: Array = []
	for i in 24:
		tall.append(_card(Vector3(1.5, 0.05, 3.0)))
	var tall_group := board.make_group(tall.duplicate(), true)
	board.groups.append(tall_group)
	board._layout_group(tall_group, Vector3(1.5, 0.05, 3.0))
	await create_timer(0.25).timeout
	var tall_before: Array = tall.map(func(c): return c.global_position)
	board.mouse_point = tall[0].global_position
	board._on_card_clicked(tall[0])
	board.mouse_point = tall_before[0]
	board._process(1.0 / 60.0)
	board._end_drag()
	await create_timer(0.25).timeout
	var tall_same := true
	for i in tall.size():
		tall_same = tall_same and tall[i].global_position.is_equal_approx(tall_before[i])
	check(tall_same, "高摞原地松手后层距截断仍保持原始落点")

	check(board.toggle_compact(members[0]), "边缘牌摞仍能再次双击摊开")
	await create_timer(0.25).timeout
	check(_all_inside(members), "再次摊开自动修正锚点，不越过底边")

	# 飞入或结算中的牌先完成既有动作，再使用最新窗口边界；不能被窗口设置抢位。
	board.set_playable_bounds(wide_table, wide_player)
	var moving := _card(Vector3(-14.0, 0.05, 8.0))
	moving.set_meta("dest_pos", Vector3(-13.0, 0.05, 8.0))
	var before := moving.global_position
	board.input_locked = true
	board.set_playable_bounds(narrow_table, narrow_player)
	check(moving.global_position.is_equal_approx(before), "结算锁定期间缩窗不打断飞入卡的位置")
	board.input_locked = false
	board._apply_pending_playable_bounds()
	check(moving.global_position.is_equal_approx(before) and moving.has_meta("dest_pos"),
		"仍有飞入落点时保留动画及原落点")
	moving.global_position = moving.get_meta("dest_pos")
	moving.remove_meta("dest_pos")
	board._apply_pending_playable_bounds()
	check(_inside(moving), "既有飞入结束后自动将散卡容纳到新窗口")

	board.set_playable_bounds(wide_table, wide_player)
	board.mouse_point = middle.global_position
	board._on_card_clicked(middle)
	board.mouse_point = Vector3(13.0, 0.05, 8.0)
	board._process(1.0 / 60.0)
	var dragging_at := middle.global_position
	board.set_playable_bounds(narrow_table, narrow_player)
	check(middle.dragging and middle.global_position.is_equal_approx(dragging_at),
		"调整窗口时不取消玩家当前拖拽")
	board._end_drag()
	board._apply_pending_playable_bounds()
	middle.freeze = true
	check(_inside(middle), "拖拽松手采用新边界，卡面不会留在屏幕外")

	board.set_playable_bounds(wide_table, wide_player)
	var long_members: Array = []
	for i in 14:
		long_members.append(_card(Vector3(-12.0, 0.05, 2.1) + Board.STACK_GAP * i))
	var long_group := board.make_group(long_members)
	board.groups.append(long_group)
	board.set_playable_bounds(narrow_table, narrow_player)
	await create_timer(0.25).timeout
	check(_all_inside(long_members), "比新窗口更长的展开牌列只收紧层距，完整卡面仍留在桌内")
	check(long_members.all(func(c): return c.scale.is_equal_approx(Vector3.ONE))
		and long_group["cards"].size() == 14, "长牌列不缩放卡牌、不丢失组员")
	stage.queue_free()
	finish()

func _card(at: Vector3) -> CardEntity:
	var card := CardEntity.new()
	card.setup(next_uid, "cash")
	next_uid += 1
	card.draggable = true
	stage.add_child(card)
	card.global_position = at
	card.freeze = true
	board.register_card(card)
	return card

func _drag_to(card: CardEntity, point: Vector3) -> void:
	board.mouse_point = card.global_position
	board._on_card_clicked(card)
	board.mouse_point = point
	board._process(1.0 / 60.0)
	board._end_drag()

func _inside(card: CardEntity) -> bool:
	var at := card.global_position
	var half := Vector2(0.6, 0.8)
	var face := Rect2(Vector2(at.x, at.z) - half, half * 2.0)
	return board.player_bounds.grow(0.001).encloses(face)

func _all_inside(members: Array) -> bool:
	return members.all(func(c): return _inside(c))
