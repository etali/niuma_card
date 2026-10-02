# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 卡面交互不能改变刚体比例；整摞拖到窗口边缘后，所有牌都必须能捡回来。
class PointerBoard extends Board:
	var pointer := Vector3.ZERO
	func _mouse_table_point() -> Vector3:
		return pointer
	func _pick_card(_screen_pos: Vector2) -> CardEntity:
		return null

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 卡面交互与抽屉边界 ===")
	var world := Node3D.new()
	root.add_child(world)
	var board := PointerBoard.new()
	world.add_child(board)
	board.set_process(false)
	board.table_bounds = Rect2(-4.0, -5.0, 8.0, 11.5)
	board.player_bounds = Rect2(-4.0, 0.0, 8.0, 6.5)
	var card := _card(world, board, 88001)
	var collision: CollisionShape3D = null
	for child in card.get_children():
		if child is CollisionShape3D:
			collision = child
	check(collision != null and collision.get_parent() == card, "碰撞直属刚体，视觉效果有独立容器")
	check(card.card_mesh.get_parent() == card._visual, "卡面网格使用统一视觉容器")
	var start_mesh := card.card_mesh.transform
	for i in 16:
		card.set_drag_visual(true)
		card.update_drag_motion(Vector3(20.0, 0.0, -20.0), 0.1)
		await create_timer(0.13).timeout
		check(card.scale.is_equal_approx(Vector3.ONE) and collision.scale.is_equal_approx(Vector3.ONE),
			"第 %d 次抓取不改变根与碰撞比例" % (i + 1))
		card.set_drag_visual(false)
		card.pulse_landed()
		# 刻意在回弹尚未结束时再拎起，覆盖旧实现累积放大的路径。
		await create_timer(0.08).timeout
	await create_timer(0.3).timeout
	check(card._visual.transform.is_equal_approx(Transform3D.IDENTITY), "反复中断回弹后卡面准确回到基准")
	check(card.card_mesh.transform.is_equal_approx(start_mesh), "纸牌网格尺寸与横纵比例保持不变")
	card.set_hover_visual(true)
	await create_timer(0.16).timeout
	check(card._visual.position.y > 0.0 and card.scale == Vector3.ONE, "悬停只抬起卡面")
	card.reset_interaction_visual()
	check(card._visual.transform.is_equal_approx(Transform3D.IDENTITY), "交互动画可即时取消")
	board.unregister_card(card)
	card.queue_free()

	var members: Array = []
	for i in 16:
		members.append(_card(world, board, 88100 + i))
	var group: Dictionary = board.make_group(members)
	board.groups.append(group)
	board._layout_group(group, Vector3(90.0, 0.05, 90.0))
	await create_timer(0.3).timeout
	check(_inside(members, board.player_bounds), "16 张长牌列重排后全部卡面在玩家区内")
	check(Board.z_span(group) < Board.STACK_GAP.z * 15.0, "长牌列收紧层间距，不缩放卡牌")
	var root_sizes_unchanged := true
	for member in members:
		root_sizes_unchanged = root_sizes_unchanged and member.scale == Vector3.ONE
	check(root_sizes_unchanged, "压紧长牌列保持每张卡原尺寸")

	board.pointer = members[0].global_position
	board._on_card_clicked(members[0])
	board.pointer = Vector3(80.0, Board.DRAG_HEIGHT, 80.0)
	board._process(0.016)
	check(_inside([members[0]], board.table_bounds) and not _inside(members, board.table_bounds),
		"拖向右下屏外时首牌仍可见，展开尾部允许越界")
	board._end_drag()
	await create_timer(0.35).timeout
	check(_inside(members, board.player_bounds), "右下角松手后，整摞落入玩家区")
	group = board.group_of(members[0])
	check(group != null and group["cards"].size() == 16, "边缘拖放没有丢牌或拆散整组")
	board.pointer = members[0].global_position
	board._on_card_clicked(members[0])
	board.pointer = Vector3(-80.0, Board.DRAG_HEIGHT, -80.0)
	board._process(0.016)
	check(_inside(members, board.table_bounds), "拖向左上屏外时，整摞仍位于可见桌面内")
	board.cancel_drag()
	check(_inside(members, board.player_bounds), "强制取消会把完整手牌带回玩家区")
	board.pointer = members[0].global_position
	board._on_card_clicked(members[0])
	board.interaction_blocked = func() -> bool: return true
	board._process(0.016)
	check(board._drag_cards.is_empty() and not members[0].dragging,
		"窗口输入门关闭时终止手牌状态，释放事件不会遗失")
	check(not board.input_locked, "窗口输入门不污染业务输入锁")
	board.interaction_blocked = Callable()
	members[0].freeze = false
	members[0].global_position = Vector3(80.0, 0.05, 80.0)
	board._physics_process(0.016)
	check(_inside([members[0]], board.player_bounds), "落地碰撞推出边线的散卡被带回可见区域")

	# 100 张收拢摞沿高度增长也会被俯视镜头投出屏幕；边界布局限制可见台阶数。
	for member in members:
		member.freeze = true
	for i in range(16, 100):
		members.append(_card(world, board, 88100 + i))
	group = board.make_group(members, true)
	board.groups.append(group)
	board._layout_group(group, Vector3(80.0, 0.05, 80.0))
	await create_timer(0.3).timeout
	check(_inside(members, board.player_bounds), "100 张收拢摞卡面仍在玩家区域内")
	var highest := 0.0
	for member in members:
		highest = maxf(highest, member.global_position.y)
	check(highest < 0.5, "百张收拢摞高度有界，不会沿高度爬出视野")
	var top: CardEntity = members[0]
	board._show_desc("现金卡\n配方材料", top)
	check(board._desc.global_position.x + board._desc_extent(board._desc.text).x < board.table_bounds.end.x,
		"右侧卡牌说明自动翻到窗口内侧")
	board.unregister_card(top)
	var halves := top.tear_apart()
	check(halves.size() == 2, "视觉容器不破坏撕成两片的效果")
	if halves.size() == 2:
		check(halves[0].get_parent() == top and halves[1].get_parent() == top,
			"撕片继续保持原动画接口的局部坐标")
	world.queue_free()
	await process_frame
	finish()

func _card(world: Node3D, board: Board, uid: int) -> CardEntity:
	var card := CardEntity.new()
	card.setup(uid, "cash")
	card.freeze = true
	world.add_child(card)
	board.register_card(card)
	return card

func _inside(members: Array, bounds: Rect2) -> bool:
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5
	for member in members:
		var at: Vector3 = member.global_position
		if at.x - half.x < bounds.position.x - 0.005 or at.x + half.x > bounds.end.x + 0.005 \
				or at.z - half.y < bounds.position.y - 0.005 or at.z + half.y > bounds.end.y + 0.005:
			return false
	return true
