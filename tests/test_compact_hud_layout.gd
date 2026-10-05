# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 紧凑顶栏与牌桌构图回归：按真实字体/卡面投影量尺寸，防止空白重新挤小卡牌。
## 测试保持牌桌规则不变，仅让 HUD 面对更长的资源读数和思考状态。
const CASES := [
	[Vector2i(1280, 800), 1.0],
	[Vector2i(1920, 1200), 1.0],
	[Vector2i(1920, 1200), 2.0],
	[Vector2i(3840, 2400), 2.0],
	[Vector2i(2800, 1100), 1.0],
]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 紧凑资源栏与牌桌构图 ===")
	for item in CASES:
		var main: Node = await _boot(true, item[0], item[1])
		if not need(main != null and main.drawer_presentation != null, "抽屉场景可启动"):
			finish()
			return
		var tag := "%dx%d @%.0fx" % [item[0].x, item[0].y, item[1]]
		_check_drawer_header(main, item[1], tag + " 初始")
		_check_table_projection(main, tag)
		if item[0] == Vector2i(1920, 1200) and is_equal_approx(item[1], 2.0):
			var market: Node3D = main.get_node("TableSurface_market")
			var market_screen := _geometry_rect(main.board.camera, market)
			check(market_screen.size.x / float(item[0].x) >= 0.83,
				"1920×1200@2x购牌托盘占屏宽至少83%%（实测%.1f%%）" % (market_screen.size.x / float(item[0].x) * 100.0))
		await _check_content_changes(main, item[1], tag)
		await _dispose(main)
	await _check_normal_hud()
	finish()

func _boot(drawer: bool, viewport_size: Vector2i, dpi: float) -> Node:
	root.size = viewport_size
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = drawer
	main.drawer_ui_scale = dpi
	root.add_child(main)
	main.sfx.set_muted(true)
	_booted = main
	await settle()
	await _flush_layout(main)
	return main

func _flush_layout(main: Node) -> void:
	if main.drawer_presentation != null:
		main.drawer_presentation.relayout()
	else:
		main._position_table_hud()
	for i in 3:
		await process_frame

func _text_width(label: Label) -> float:
	return label.get_theme_font("font").get_string_size(label.text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x

func _check_drawer_header(main: Node, dpi: float, tag: String) -> void:
	var presentation: Node = main.drawer_presentation
	var header: Control = presentation._header
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(root.size))
	var factor: float = presentation._responsive_factor()
	check(header.size.y < 80.0 * dpi, tag + " 顶部高度小于80逻辑像素")
	check(viewport_rect.encloses(header.get_global_rect()), tag + " 顶栏完整留在窗口内")
	check(absf(header.get_global_rect().get_center().x - root.size.x * 0.5) <= 1.0,
		tag + " 顶栏按内容宽度整体居中")
	var widest_text := maxf(_text_width(main.lbl_player_res), _text_width(main.lbl_bot_res))
	for label: Label in [main.lbl_player_res, main.lbl_bot_res]:
		var cell: Control = label.get_parent()
		check(cell.size.x <= widest_text + 32.0 * factor + 2.0,
			tag + " 资源背景只比等宽读数多出必要内边距")
		check(label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER
			and label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER,
			tag + " 公司读数文字水平垂直居中")
		check(absf(label.get_global_rect().get_center().x - cell.get_global_rect().get_center().x) <= 1.0,
			tag + " 读数文本区域位于资源背景中心")
		check(_text_width(label) <= label.size.x + 1.0 and label.get_line_count() == 1,
			tag + " 资源读数完整单行显示")
	var round_label: Label = main.lbl_round
	check(_text_width(round_label) <= round_label.size.x + 1.0 and round_label.get_line_count() == 1,
		tag + " 回合、先手和思考状态不裁切")
	check(header.get_global_rect().grow(1).encloses(round_label.get_global_rect()),
		tag + " 回合状态完整包含在顶栏内")

func _check_content_changes(main: Node, dpi: float, tag: String) -> void:
	var presentation: Node = main.drawer_presentation
	var initial_width: float = main.lbl_player_res.get_parent().size.x
	var saved_cards := {}
	for seat: String in [main.my_seat, main.foe_seat]:
		saved_cards[seat] = main.state.players[seat]["cards"].duplicate(true)
		for res: String in [CardDB.RES_CASH, CardDB.RES_USER]:
			while main.state.resource_count(seat, res) < 123:
				main.state.add_card(seat, CardDB.unit_id(res))
	# HUD 读数使用真实规则状态；此处不新增牌面，避免将构图测试变成数百张牌的压力测试。
	main._update_hud()
	main.lbl_player_res.text += " ⚠"
	main.lbl_bot_res.text += " ⚠"
	presentation.compact_header_resources()
	await _flush_layout(main)
	_check_drawer_header(main, dpi, tag + " 三位数与预警")
	check(main.lbl_player_res.text.contains("123") and main.lbl_player_res.text.contains("⚠"),
		tag + " 三位数资源和预警均进入紧凑读数")
	check(main.lbl_player_res.get_parent().size.x > initial_width,
		tag + " 数字增长后资源背景随内容增宽")
	var stable_width: float = presentation._header.size.x
	for i in 8:
		await _flush_layout(main)
	check(absf(presentation._header.size.x - stable_width) <= 1.0,
		tag + " 重复布局不会逐次撑大顶栏")
	main._thinking = true
	ThinkClock.start(ThinkClock.SRC_BOT)
	ThinkClock._t0 -= 9900
	main._update_hud()
	await _flush_layout(main)
	_check_drawer_header(main, dpi, tag + " 思考中")
	check(main.lbl_round.text.contains("先手") and main.lbl_round.text.contains("思考中"),
		tag + " 思考状态保留先手说明")
	check(main.lbl_round.text.contains("秒"), tag + " 顶部思考状态包含实际秒数")
	var thinking_rect: Rect2 = presentation._header.get_global_rect()
	ThinkClock._t0 -= 200
	main._update_thinking_hint()
	await _flush_layout(main)
	check(thinking_rect.is_equal_approx(presentation._header.get_global_rect()),
		tag + " 思考秒数跨位增长时顶栏位置与尺寸稳定")
	main._thinking = false
	ThinkClock.stop()
	for seat: String in saved_cards:
		main.state.players[seat]["cards"] = saved_cards[seat]
	main._update_hud()
	await _flush_layout(main)
	check(absf(main.lbl_player_res.get_parent().size.x - initial_width) <= 1.0,
		tag + " 数值恢复后背景收回原来的紧凑宽度")

func _check_table_projection(main: Node, tag: String) -> void:
	var camera: Camera3D = main.board.camera
	var screen: Rect2 = main.drawer_presentation.content_rect()
	var cards_inside := true
	for card: CardEntity in main.board.cards:
		cards_inside = cards_inside and screen.grow(1.0).encloses(
			_face_rect(camera, card.global_position + Vector3.UP * CardEntity.HOVER_LIFT))
	check(cards_inside, tag + " 全部市场及开局牌面悬浮后仍完整可见")
	var facility_inside := true
	for geometry: GeometryInstance3D in main.get_node("MarketFacility").find_children("*", "GeometryInstance3D", true, false):
		facility_inside = facility_inside and screen.grow(1.0).encloses(_geometry_rect(camera, geometry))
	check(facility_inside, tag + " 典当行卡面、设施标记与说明完整可见")
	var shadows_inside := true
	for contact: Dictionary in TableLighting.contact_footprints(main.board.cards):
		for x in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var point: Vector3 = contact["center"] + Vector3(contact["size"].x * x, 0, contact["size"].y * z)
				shadows_inside = shadows_inside and screen.grow(1.0).has_point(camera.unproject_position(point))
	check(shadows_inside, tag + " 开局接触阴影的完整平面未被裁切")
	var offsets: Array = [Vector3.ZERO, Vector3(0, 0.315, 0.35)]
	for side in [-1.0, 1.0]:
		var target: Vector3 = main.board.screen_position_clamper.call(Vector3(side * 1000.0, Board.DRAG_HEIGHT, 1000.0), offsets)
		var held_inside := true
		for offset: Vector3 in offsets:
			held_inside = held_inside and screen.grow(1.0).encloses(_face_rect(camera, target + offset))
		check(held_inside, tag + " 边缘抬起整摞后按实际视锥保持完整可见")

func _face_rect(camera: Camera3D, at: Vector3) -> Rect2:
	var result := Rect2()
	var first := true
	for x in [-CardEntity.CARD_SIZE.x * 0.5, CardEntity.CARD_SIZE.x * 0.5]:
		for z in [-CardEntity.CARD_SIZE.z * 0.5, CardEntity.CARD_SIZE.z * 0.5]:
			var point := camera.unproject_position(at + Vector3(x, CardEntity.Y_OVERLAY, z))
			result = Rect2(point, Vector2.ZERO) if first else result.expand(point)
			first = false
	return result

func _geometry_rect(camera: Camera3D, geometry: GeometryInstance3D) -> Rect2:
	var aabb := geometry.get_aabb()
	var result := Rect2()
	var first := true
	for x in [aabb.position.x, aabb.end.x]:
		for y in [aabb.position.y, aabb.end.y]:
			for z in [aabb.position.z, aabb.end.z]:
				var point := camera.unproject_position(geometry.to_global(Vector3(x, y, z)))
				result = Rect2(point, Vector2.ZERO) if first else result.expand(point)
				first = false
	return result

func _check_normal_hud() -> void:
	var main: Node = await _boot(false, Vector2i(1920, 1200), 1.0)
	if not need(main != null, "普通横屏场景可启动"):
		return
	var cards: Array = [main.hud_player_card, main.hud_bot_card]
	for card: ResourceHUD in cards:
		card.set_resources(123, 123, 123, 100, 23, true, true)
	await _flush_layout(main)
	var widths: Array = cards.map(func(card): return card.size.x)
	for viewport_size in [Vector2i(1280, 800), Vector2i(2800, 1100)]:
		root.size = viewport_size
		ThinkClock.start(ThinkClock.SRC_BOT)
		ThinkClock._t0 -= 9900
		main._update_thinking_hint(true)
		await _flush_layout(main)
		check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(main.table_hud_rect()),
			"普通横屏%d资源顶栏完整位于窗口内" % viewport_size.x)
		var round_font: Font = main.lbl_round.get_theme_font("font")
		var round_font_size: int = main.lbl_round.get_theme_font_size("font_size")
		var fits := true
		for line: String in main.lbl_round.text.split("\n"):
			fits = fits and round_font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, round_font_size).x <= main.lbl_round.size.x + 1
		check(fits and main.lbl_round.get_line_count() == 3,
			"普通横屏%d思考秒数完整显示，未增加意外换行" % viewport_size.x)
		var thinking_rect: Rect2 = main.table_hud_rect()
		ThinkClock._t0 -= 200
		main._update_thinking_hint()
		await _flush_layout(main)
		check(thinking_rect.is_equal_approx(main.table_hud_rect()),
			"普通横屏%d秒数跨位时顶栏不跳动" % viewport_size.x)
		for i in cards.size():
			var card: ResourceHUD = cards[i]
			check(card.size.x <= 340.0 and absf(card.size.x - widths[i]) <= 1.0,
				"普通横屏%d资源卡由内容定宽，不随宽屏膨胀" % viewport_size.x)
			for label: Label in [card.title, card.cash_value, card.user_value, card.due_value, card.deployment, card.warning]:
				check(label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
					"普通横屏%s文字或数字使用居中对齐" % label.text)
			var heading: BoxContainer = card.title.get_parent()
			var title_bounds := card.title.get_global_rect().merge(card.due_value.get_global_rect())
			check(absf(title_bounds.get_center().x - heading.get_global_rect().get_center().x) <= 1.0,
				"普通横屏公司名称与待付作为整体居中")
			for number: Label in [card.cash_value, card.user_value]:
				var metric: BoxContainer = number.get_parent()
				var metric_bounds := (metric.get_child(0) as Control).get_global_rect().merge(number.get_global_rect())
				check(absf(metric_bounds.get_center().x - metric.get_global_rect().get_center().x) <= 1.0,
					"普通横屏资源名称与数字作为整体居中")
		ThinkClock.stop()
		main._update_thinking_hint()
	check(main.hud_player_card.summary == main.lbl_player_res and main.hud_bot_card.summary == main.lbl_bot_res,
		"紧凑布局仍保留原资源摘要接口")
	await _dispose(main)

func _dispose(main: Node) -> void:
	main.queue_free()
	_booted = null
	await process_frame
	await process_frame
