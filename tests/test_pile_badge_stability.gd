# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 右侧清单属于落在桌上的牌摞；手牌划过、悬停抬起和飞行动画不能把它推走。
class PointerBoard extends Board:
	var pointer := Vector3.ZERO
	var pointed_card: CardEntity = null
	func _mouse_table_point() -> Vector3:
		return pointer
	func _pick_card(_screen_pos: Vector2) -> CardEntity:
		return pointed_card

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 收拢组合侧边图标稳定性 ===")
	root.size = Vector2i(1600, 900)
	var world := Node3D.new()
	root.add_child(world)
	var board := PointerBoard.new()
	world.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 42.0
	camera.position = Vector3(0, 11, 8)
	camera.look_at(Vector3(0, 0, 1.0), Vector3.UP)
	camera.current = true
	board.camera = camera

	var core := _card(world, board, 99000, "shuabuting", Vector3(0, 0.05, 1))
	var members: Array = [core]
	var recipe_n := int(CardDB.get_def(core.def_id)["recipe_n"])
	for i in recipe_n:
		members.append(_card(world, board, 99001 + i, "user", Vector3(0, 0.05, 1)))
	var group := board.make_group(members, true)
	board.groups.append(group)
	board._layout_group(group, Vector3(0, 0.05, 1))
	await create_timer(0.3).timeout
	check(bool(group["was_valid"]) and core.recipe_progress_text() == "%d/%d" % [recipe_n, recipe_n],
		"样本是真正配方已凑齐的产出卡 + 材料收拢组合")
	var original := _positions(group)
	check(original.size() >= 2, "实测图标与数量节点，覆盖侧边图标和文字")
	if original.size() < 2:
		world.queue_free()
		finish()
		return
	var original_pixels := _project(camera, original)
	print("       初始清单：3D=%s；屏幕=%s" % [original, original_pixels])

	# 真正走拖拽 _process 的吸附高亮进出：刚离开吸附半径时，手牌仍盖着右侧清单。
	var hand := _card(world, board, 99100, "cash", Vector3(-5, 0.05, 1))
	board.pointer = hand.global_position
	board._on_card_clicked(hand)
	for pass_n in 3:
		var route: Array[Vector3] = [
			core.global_position + Vector3(0.3, 0, 0),
			core.global_position + Vector3(1.5, 0, 0),
			core.global_position + Vector3(1.65, 0, 0),
			core.global_position + Vector3(3.5, 0, 0)]
		for step in route.size():
			board.pointer = route[step]
			board._process(0.016)
			var label := "第%d次划过，路径点%d" % [pass_n + 1, step + 1]
			_assert_positions(group, original, camera, original_pixels, label)
			if pass_n == 0:
				print("       %s：手牌=%s；清单=%s；屏幕=%s" % [
					label, hand.global_position, _positions(group), _project(camera, _positions(group))])
		check(board._hover_group == null, "划过离开后吸附高亮已正确清理")
		board.pointer = core.global_position + Vector3(1.3, 0, 0)
		board._process(0.016)
		board.resync_sides()
		_assert_positions(group, original, camera, original_pixels, "手牌覆盖清单时全场重同步")
	board.pointer = Vector3(-5, Board.DRAG_HEIGHT, 1)
	board._process(0.016)
	board.cancel_drag()
	hand.freeze = true
	hand.position = Vector3(-5, 0.05, 1)

	# 鼠标指着组合只抬视觉子节点；图标不会因为自身悬停的高度跟着漂移。
	for pass_n in 3:
		board.pointed_card = core
		board._process(0.016)
		await create_timer(0.16).timeout
		board.refresh_group(group)
		_assert_positions(group, original, camera, original_pixels, "悬停组合完成抬牌后")
		board.pointed_card = null
		board._process(0.016)
		await create_timer(0.16).timeout
		board.refresh_group(group)
		_assert_positions(group, original, camera, original_pixels, "鼠标离开组合后")

	# main 的购牌/产出 tween 使用 dest_pos 宣告落点，不能拿途中高度当障碍。
	hand.set_meta("dest_pos", Vector3(-5, 0.05, 1))
	for flight in [Vector3(1.2, 2.6, 1.1), Vector3(1.8, 1.6, 1.3), Vector3(-5, 0.05, 1)]:
		hand.global_position = flight
		board.resync_sides()
		_assert_positions(group, original, camera, original_pixels, "有确定落点的飞牌从清单上方经过")
	hand.remove_meta("dest_pos")

	# 真实停在旁边的高摞仍然需要避让，包含正在落位的已声明目标高度。
	var neighbor_cards: Array = []
	for i in 6:
		neighbor_cards.append(_card(world, board, 99200 + i, "cash", Vector3(4, 0.05, 1)))
	var neighbor := board.make_group(neighbor_cards, true)
	board.groups.append(neighbor)
	for i in neighbor_cards.size():
		board._move_to(neighbor_cards[i], Vector3(1.5, 1.7, core.global_position.z)
			+ Board.compact_offset(neighbor_cards.size(), i))
	board.resync_sides()
	var raised := _positions(group)
	check(raised[0].y > original[0].y + 1.0, "真实高摞落位时侧边清单提前避让其目标高度")
	await create_timer(0.3).timeout
	board.resync_sides()
	var high_top := 0.0
	for card in neighbor_cards:
		high_top = maxf(high_top, card.global_position.y)
	for at in _positions(group):
		check(at.y > high_top, "图标和数字仍在相邻高摞之上，不会被埋掉")
	_assert_positions(group, raised, camera, _project(camera, raised), "高摞落定后清单不重复上跳")
	for card in neighbor_cards:
		card.global_position.x += 6.0
	board.resync_sides()
	_assert_positions(group, original, camera, original_pixels, "真实高摞搬离后恢复清单正常高度")

	# 整摞自身搬动应跟随新锚点；随后悬停刷新不能把清单拽回补间中途位置。
	var move := Vector3(-2.5, 0, 0.7)
	var anchor := board.rest_origin(group)
	board._layout_group(group, anchor + move)
	var relocated := _positions(group)
	check(relocated[0].distance_to(original[0] + move) < 0.0001,
		"移动整摞后图标与整摞保持相同位移")
	var relocated_pixels := _project(camera, relocated)
	board._hover_group = group
	board._set_group_highlight(group, true)
	board.clear_hover_group()
	_assert_positions(group, relocated, camera, relocated_pixels, "整摞尚在归位时清除悬停")
	await create_timer(0.08).timeout
	board.refresh_group(group)
	_assert_positions(group, relocated, camera, relocated_pixels, "整摞归位补间中途刷新")
	await create_timer(0.3).timeout
	board.resync_sides()
	_assert_positions(group, relocated, camera, relocated_pixels, "整摞归位完成")
	check(bool(group["was_valid"]) and core.recipe_progress_text() == "%d/%d" % [recipe_n, recipe_n],
		"划过、悬停、邻摞避让和搬动均不改变实际组合与配方进度")
	world.queue_free()
	await process_frame
	finish()

func _card(world: Node3D, board: Board, uid: int, definition: String, at: Vector3) -> CardEntity:
	var card := CardEntity.new()
	card.setup(uid, definition)
	card.freeze = true
	world.add_child(card)
	card.global_position = at
	board.register_card(card)
	return card

func _positions(group: Dictionary) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for node in group.get("side", []):
		if node != null and is_instance_valid(node):
			result.append(node.global_position)
	return result

func _project(camera: Camera3D, positions: Array[Vector3]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	for at in positions:
		result.append(camera.unproject_position(at))
	return result

func _assert_positions(group: Dictionary, expected: Array[Vector3], camera: Camera3D,
		expected_pixels: Array[Vector2], label: String) -> void:
	var positions := _positions(group)
	var unchanged := positions.size() == expected.size()
	var max_world_drift := 0.0
	var max_pixel_drift := 0.0
	for i in mini(positions.size(), expected.size()):
		max_world_drift = maxf(max_world_drift, positions[i].distance_to(expected[i]))
		max_pixel_drift = maxf(max_pixel_drift,
			camera.unproject_position(positions[i]).distance_to(expected_pixels[i]))
	check(unchanged and max_world_drift < 0.0001,
		"%s：清单3D位置稳定（最大偏移 %.6f）" % [label, max_world_drift])
	check(unchanged and max_pixel_drift < 0.01,
		"%s：透视屏幕位置稳定（最大偏移 %.3fpx）" % [label, max_pixel_drift])
