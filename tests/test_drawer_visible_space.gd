# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 真实抽屉展示层 + 相机 + Board 集成：可见桌面边缘可落牌，首行资源不再占第二行。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main: Node = await _boot(Vector2i(1920, 1200), 1.0)
	if not need(main.drawer_presentation != null, "抽屉展示层真实启动"):
		finish()
		return
	for viewport_size in [Vector2i(1920, 1200), Vector2i(2800, 1100), Vector2i(1280, 900)]:
		await _resize(main, viewport_size)
		_check_visible_space(main, 1.0, "%dx%d" % [viewport_size.x, viewport_size.y])

	# 宽屏的额外左右空间必须真的可供整摞拖放，随后缩窗仍保留 UID 和组员。
	await _resize(main, Vector2i(2800, 1100))
	var board: Board = main.board
	var members: Array = []
	for card in board.cards:
		if is_instance_valid(card) and card.draggable and not card.is_market and card.def_id == "cash":
			members.append(card)
			if members.size() == 3:
				break
	if need(members.size() == 3, "开局存在可拖动的三张现金牌"):
		for card in members:
			board._detach_from_group(card)
		var group := board.make_group(members)
		board.groups.append(group)
		board._layout_group(group, Vector3(0.0, 0.05, 3.0))
		await settle()
		var uids: Array = members.map(func(c): return c.uid)
		var original_count := board.cards.size()
		board.set_process(false)
		board._on_card_clicked(members[0])
		var offsets: Array = []
		for card in members:
			offsets.append(card.global_position - members[0].global_position)
		var target := Board.clamp_stack_anchor(Vector3(1000.0, Board.DRAG_HEIGHT, 1000.0), offsets, board.player_bounds)
		for i in members.size():
			members[i].global_position = target + offsets[i]
		board._end_drag()
		board.set_process(true)
		await settle()
		check(members[0].global_position.x > 10.0, "真实整摞松手后保留在旧右边界之外")
		for card in members:
			check(_projected_face_inside(main, card), "宽屏拖放后牌%s完整显示" % card.uid)
		await _resize(main, Vector2i(1280, 900))
		await settle()
		for card in members:
			check(_projected_face_inside(main, card), "缩窗后牌%s整张夹回可见桌面" % card.uid)
		var restored: Variant = board.group_of(members[0])
		check(restored != null and restored["cards"].map(func(c): return c.uid) == uids,
			"真实缩窗保持整摞的 UID、成员及次序")
		check(board.cards.size() == original_count, "拖到新增可见边缘及缩窗都不丢失卡牌")
	await _dispose(main)

	main = await _boot(Vector2i(3840, 2400), 2.0)
	_check_visible_space(main, 2.0, "Retina 1920x1200@2x")
	await _dispose(main)
	finish()

func _boot(viewport_size: Vector2i, dpi: float) -> Node:
	root.size = viewport_size
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = dpi
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	await _resize(main, viewport_size)
	return main

func _resize(main: Node, viewport_size: Vector2i) -> void:
	root.size = viewport_size
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await process_frame

func _check_visible_space(main: Node, dpi: float, label: String) -> void:
	var presentation: Node = main.drawer_presentation
	var camera: Camera3D = main.board.camera
	var content: Rect2 = presentation.content_rect()
	var header: Control = presentation._header
	var title_row: Control = presentation._title_row
	var header_rect := header.get_global_rect()
	var row_rect := title_row.get_global_rect()
	check(header.size.y <= 80.0 * dpi, "%s：首行顶部高度不超过80逻辑像素" % label)
	check(header_rect.end.y < content.position.y, "%s：顶部与牌桌内容区分离" % label)
	for company: Label in [main.lbl_player_res, main.lbl_bot_res]:
		var company_rect := company.get_global_rect()
		check(company.get_parent().get_parent().get_parent() == title_row,
			"%s：%s与游戏标题位于同一个首行容器" % [label, company.text])
		check(company_rect.position.y >= row_rect.position.y - 1.0
			and company_rect.end.y <= row_rect.end.y + 1.0
			and absf(company_rect.get_center().y - row_rect.get_center().y) <= 1.0,
			"%s：公司资源与首行垂直居中，不另起第二行" % label)
		check(company.get_line_count() == 1, "%s：公司资源保持单行" % label)
	var board: Board = main.board
	var px_per_x := camera.unproject_position(Vector3.RIGHT).distance_to(camera.unproject_position(Vector3.ZERO))
	var px_per_z := camera.unproject_position(Vector3.FORWARD).distance_to(camera.unproject_position(Vector3.ZERO))
	# 可见边界只允许安全留白与描边呼吸空间；不能将旧固定桌面外的大块区域算作安全边距。
	var edge_tolerance_x := Board.BOUNDS_PAD * px_per_x + 10.0 * dpi
	var edge_tolerance_z := Board.BOUNDS_PAD * px_per_z + 10.0 * dpi
	for side in ["left", "right", "bottom"]:
		var request := Vector3(0.0, 0.05, board.player_bounds.get_center().y)
		if side == "left":
			request.x = -10000.0
		elif side == "right":
			request.x = 10000.0
		else:
			request.z = 10000.0
		var at := board.clamp_player_position(request)
		var face := _projected_face(camera, at)
		check(content.grow(0.2).encloses(face), "%s：%s边落点完整卡面位于可见内容区" % [label, side])
		var distance := face.position.x - content.position.x if side == "left" else content.end.x - face.end.x
		if side == "bottom":
			distance = content.end.y - face.end.y
		check(distance <= (edge_tolerance_z if side == "bottom" else edge_tolerance_x),
			"%s：%s边可落牌至描边安全距离内（实距%.2f像素）" % [label, side, distance])
		if side == "bottom":
			# 旧player_rect南沿5.7对应中心极限4.82（半张牌0.8 + 留白0.08）。
			check(at.z > 4.82, "%s：底部可落牌超出旧中心极限z=4.82" % label)
		if label == "2800x1100" and side in ["left", "right"]:
			check(absf(at.x) > 10.0, "%s：%s侧可落牌超出旧x=±10限制" % [label, side])
		# 透视抬起会放大；真实拖拽每帧按当前高度重新夹取，不能复用落桌坐标。
		var held_at: Vector3 = board.screen_position_clamper.call(Vector3(at.x, Board.DRAG_HEIGHT, at.z), []) 			if board.screen_position_clamper.is_valid() else Vector3(at.x, Board.DRAG_HEIGHT, at.z)
		var held_face := _projected_face(camera, held_at)
		check(content.grow(0.2).encloses(held_face), "%s：%s边拖拽抬起后仍不被界面裁切" % [label, side])

func _projected_face(camera: Camera3D, at: Vector3) -> Rect2:
	var rect := Rect2()
	var first := true
	# 卡面真实宽1.2、长1.6；不扩大内容区域来容忍不正确的边界。
	for x in [-0.6, 0.6]:
		for z in [-0.8, 0.8]:
			var projected := camera.unproject_position(at + Vector3(x, 0.04, z))
			if first:
				rect = Rect2(projected, Vector2.ZERO)
				first = false
			else:
				rect = rect.expand(projected)
	return rect

func _projected_face_inside(main: Node, card: CardEntity) -> bool:
	var content: Rect2 = main.drawer_presentation.content_rect()
	return content.grow(0.2).encloses(_projected_face(main.board.camera, card.global_position))

func _dispose(main: Node) -> void:
	if main.sfx:
		main.sfx.set_muted(true)
	main.queue_free()
	await process_frame
	await process_frame
