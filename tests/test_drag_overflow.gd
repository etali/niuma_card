# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 抓住展开牌列时跟随首牌，尾部可临时越过底边；松手按原目标合并，随后安全落桌。
const CameraFit = preload("res://scenes/drawer_camera_fit.gd")
class PointerBoard extends Board:
	var pointer := Vector3.ZERO
	func _mouse_table_point() -> Vector3:
		return pointer

var next_uid := 970000

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for size in [Vector2i(1280, 900), Vector2i(2800, 1100), Vector2i(3840, 2400)]:
		for pitch in [45.0, 80.0]:
			await _check_drag(size, pitch)
	finish()

func _check_drag(size: Vector2i, pitch: float) -> void:
	root.size = size
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	await process_frame
	var world := Node3D.new()
	root.add_child(world)
	var board := PointerBoard.new()
	world.add_child(board)
	board.set_process(false)
	board.set_physics_process(false)
	var camera := Camera3D.new()
	world.add_child(camera)
	board.camera = camera
	var dpi := 2.0 if size.x > 3000 else 1.0
	var content := Rect2(16 * dpi, 90 * dpi, size.x - 32 * dpi, size.y - 175 * dpi)
	var fitted := CameraFit.fit_perspective(Vector2(size), content, Rect2(-10.8, -5.25, 21.6, 11.3), 0.0, 0.5, pitch, 44.0, 8 * dpi)
	CameraFit.apply(camera, fitted)
	board.screen_position_clamper = func(at: Vector3, offsets: Array) -> Vector3:
		return CameraFit.clamp_anchor_to_screen(camera, content, at, offsets, CardEntity.CARD_SIZE, Board.BOUNDS_PAD, Vector2(size))
	board.table_bounds = Rect2(-60, -60, 120, 120)
	board.player_bounds = Rect2(-60, 1.2, 120, 60)
	var tag := "%dx%d/%.0f°" % [size.x, size.y, pitch]
	var landing: Vector3 = board.clamp_player_position(Vector3(0, 0.05, 1000))
	var requested: Vector3 = board.screen_position_clamper.call(Vector3(0, Board.DRAG_HEIGHT, landing.z), [])
	# 先验证整列与中途拆出的子列；保持相同请求，不让尾部长度改变抓取点位置。
	for split in [0, 2]:
		var members := _pile(world, board, 10, Vector3(-4, 0.05, 2.2))
		await create_timer(0.25).timeout
		board.pointer = members[split].global_position
		board._on_card_clicked(members[split])
		var offsets: Array = board._drag_offsets.duplicate()
		board.pointer = requested
		board._process(0.016)
		check(Vector2(members[split].position.x, members[split].position.z).distance_to(Vector2(requested.x, requested.z)) < 0.001,
			tag + "：展开整列/子列抓取点跟随鼠标，不被尾部顶回去")
		check(_face(camera, members.back().position).end.y > content.end.y + 5,
			tag + "：展开尾部实际投影超出底边")
		check(content.grow(0.2).encloses(_face(camera, members[split].position)), tag + "：手上抓住的首牌仍可见")
		var shape := true
		for i in board._drag_cards.size():
			shape = shape and (board._drag_cards[i].position - board._drag_cards[0].position).is_equal_approx(offsets[i] - offsets[0])
		check(shape, tag + "：越界途中不压缩牌距或改变组内顺序")
		board.cancel_drag()
		check(members.all(func(c): return content.grow(0.2).encloses(_face(camera, c.position))), tag + "：取消拖拽后全部牌能回到可见区")
		await _clear(board, members)
	# 底部散卡和已有组都能接住展开长列；先回夹再判目标的旧路径会漏掉它们。
	for grouped in [false, true]:
		var target_cards := _pile(world, board, 2 if grouped else 1, Vector3(0, 0.05, landing.z), true)
		var members := _pile(world, board, 10, Vector3(-4, 0.05, 2.2))
		await create_timer(0.25).timeout
		board.pointer = members[0].position
		board._on_card_clicked(members[0])
		board.pointer = requested
		board._process(0.016)
		board._end_drag()
		await create_timer(0.3).timeout
		var merged: Variant = board.group_of(target_cards[0])
		check(merged != null and members.all(func(c): return merged["cards"].has(c)), tag + "：按实际松手目标合并底部" + ("已有牌组" if grouped else "散卡"))
		check((members + target_cards).all(func(c): return content.grow(0.2).encloses(_face(camera, c.position))), tag + "：合并完成后整个新组安全落回可见区")
		await _clear(board, members + target_cards)
	world.queue_free()
	await process_frame

func _pile(world: Node3D, board: Board, count: int, at: Vector3, compact := false) -> Array:
	var cards: Array = []
	for i in count:
		var card := CardEntity.new()
		card.setup(next_uid, "cash")
		next_uid += 1
		card.freeze = true
		world.add_child(card)
		board.register_card(card)
		card.position = at
		cards.append(card)
	if count > 1:
		var group := board.make_group(cards.duplicate(), compact)
		board.groups.append(group)
		board._layout_group(group, at)
	return cards

func _clear(board: Board, cards: Array) -> void:
	for card in cards:
		board.unregister_card(card)
		card.queue_free()
	await process_frame

func _face(camera: Camera3D, at: Vector3) -> Rect2:
	var rect := Rect2(camera.unproject_position(at), Vector2.ZERO)
	for x in [-0.6, 0.6]:
		for z in [-0.8, 0.8]:
			rect = rect.expand(camera.unproject_position(at + Vector3(x, 0.04, z)))
	return rect
