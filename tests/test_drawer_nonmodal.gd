# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 真实抽屉场景回归：工具页只挡住自身矩形，不锁牌桌、不延缓收起；
## 收放保留编辑内容和业务锁；顶部先手文字按真实字体宽度完整显示。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉非模态工具页与先手读数回归 ===")
	for config in [[Vector2i(1280, 800), 1.0], [Vector2i(1920, 1200), 1.0], [Vector2i(2560, 1600), 2.0]]:
		var viewport_size: Vector2i = config[0]
		var dpi: float = config[1]
		var prefix := "%dx%d@%dx" % [viewport_size.x, viewport_size.y, int(dpi)]
		var main: Node = await _boot_drawer(viewport_size, dpi)
		if not need(main.drawer_presentation != null and main.drawer_window != null,
			"%s：真实抽屉场景启动" % prefix):
			await _dispose(main)
			continue
		await _check_header(main, prefix)
		# 两种像素密度分别走过所有真实工具页，不仅检查 Callable 返回值。
		if viewport_size.x != 1920:
			await _check_utilities(main, prefix)
			await _check_join_panel(main, prefix)
			await _check_save_notice(main, prefix)
		await _dispose(main)
	finish()

func _boot_drawer(viewport_size: Vector2i, dpi: float) -> Node:
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
	# 测试驱动鼠标事件，窗口控制器不读取测试机的真实鼠标位置。
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.board.input_locked = false
	await _layout(main)
	return main

func _layout(main: Node) -> void:
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await physics_frame

func _check_header(main: Node, prefix: String) -> void:
	main.state.draw_first = main.foe_seat
	for thinking in [false, true]:
		main._thinking = thinking
		main._update_hud()
		await _layout(main)
		var label: Label = main.lbl_round
		var label_rect := label.get_global_rect()
		var font := label.get_theme_font("font")
		var font_size := label.get_theme_font_size("font_size")
		var actual_width := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var context := "%s%s" % [prefix, "思考时" if thinking else "行动时"]
		check("对手先手" in label.text, "%s：先手完整文字保留" % context)
		check(not label.clip_text and label.get_line_count() == 1, "%s：先手不裁字、不另占第二行" % context)
		check(actual_width <= label.size.x + 0.5,
			"%s：真实字体宽度%.1f不超过分配宽度%.1f" % [context, actual_width, label.size.x])
		for company: Label in [main.lbl_player_res, main.lbl_bot_res]:
			var surface: Control = company.get_parent()
			check(not surface.get_global_rect().intersects(label_rect),
				"%s：%s状态面板不遮挡先手文字" % [context, company.text])
		check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(label_rect),
			"%s：先手标签完整留在窗口内" % context)
	main._thinking = false
	main._update_hud()
	await _layout(main)

func _check_utilities(main: Node, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	for utility_id in range(6):
		var context := "%s工具页%d" % [prefix, utility_id]
		presentation._open_utility(utility_id)
		await _layout(main)
		check(presentation.panels_open(), "%s：真实工具页打开" % context)
		var surface: Control = main.msg_log._frame if utility_id == 2 else presentation._utility
		check(surface.mouse_filter == Control.MOUSE_FILTER_STOP,
			"%s：面板本体消费GUI点击，空白处不点穿" % context)
		check(not main._drawer_input_blocked() and not main.board._interaction_is_blocked(),
			"%s：窗口交互门不锁牌桌" % context)
		check(main._drawer_can_collapse(), "%s：打开后仍允许自动收起" % context)
		_assert_real_pick(main, context)
		var children_before: Array = presentation._utility_body.get_children()
		var title_before: String = presentation._utility_title.text
		await _collapse_restore(main, context)
		check(presentation.panels_open() and surface.is_visible_in_tree(),
			"%s：再展开恢复原工具页" % context)
		check(presentation._utility_body.get_children() == children_before
			and presentation._utility_title.text == title_before,
			"%s：收放保留原面板控件与内容" % context)
		presentation.close_panels()
		await process_frame
	check(not presentation.panels_open(), "%s：所有工具页可正常关闭" % prefix)

func _assert_real_pick(main: Node, context: String) -> void:
	var board: Board = main.board
	var presentation: Node = main.drawer_presentation
	var click_point := Vector2.INF
	var target: CardEntity = null
	# 射线命中实际玩家卡的可见部分；堆叠盖住中心时检查卡面上几个位置。
	for entity in board.cards:
		if not is_instance_valid(entity) or not entity.visible or not entity.draggable or entity.is_market:
			continue
		for offset in [Vector3.ZERO, Vector3(-0.3, 0.0, -0.5), Vector3(0.3, 0.0, 0.5)]:
			var point := board.camera.unproject_position(entity.to_global(offset + Vector3(0, 0.045, 0)))
			if not presentation.content_rect().has_point(point) or presentation.pointer_over_panels(point):
				continue
			var picked := board._pick_card(point)
			if picked != null and picked.draggable and not picked.is_market:
				click_point = point
				target = picked
				break
		if target != null:
			break
	if not need(target != null, "%s：工具页外真实射线能找到可操作卡牌" % context):
		return
	board._reset_click_track()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = click_point
	press.pressed = true
	# 模拟已经由 GUI 判为未处理的牌桌点击，随后走原始射线拾取与拖拽入口。
	board._unhandled_input(press)
	check(not board._drag_cards.is_empty() and target in board._drag_cards,
		"%s：真实未处理点击能抓起牌，不受工具页阻塞" % context)
	check(not main._drawer_can_collapse(), "%s：仅实际抓牌期间暂缓收起" % context)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = click_point
	release.pressed = false
	board._unhandled_input(release)
	check(board._drag_cards.is_empty(), "%s：松手结束抓牌" % context)
	check(main._drawer_can_collapse(), "%s：松手后立即允许收起" % context)
	board._reset_click_track()

func _check_join_panel(main: Node, prefix: String) -> void:
	for initially_locked in [false, true]:
		main.board.input_locked = initially_locked
		var join: JoinPanel = main._open_join_panel()
		await _layout(main)
		var context := "%s局域网页业务锁%s" % [prefix, str(initially_locked)]
		check(main.board.input_locked == initially_locked, "%s：打开不覆盖业务锁" % context)
		check(not main.board._interaction_is_blocked() and main._drawer_can_collapse(),
			"%s：面板不锁窗口交互且允许收起" % context)
		var center: Control = join.get_child(0)
		var surface: Control = center.get_child(0)
		check(center.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and surface.mouse_filter == Control.MOUSE_FILTER_STOP,
			"%s：仅联网表单本体挡住点击" % context)
		if not initially_locked:
			_assert_real_pick(main, context)
		join._room_edit.text = "ABCD7"
		join._url_edit.text = "ws://192.168.2.8:8910"
		await _collapse_restore(main, context)
		check(join.visible and main._join_panel == join, "%s：展开恢复同一个联网表单" % context)
		check(join._room_edit.text == "ABCD7" and join._url_edit.text == "ws://192.168.2.8:8910",
			"%s：收放保留房间码和服务器输入" % context)
		check(main.board.input_locked == initially_locked, "%s：收放保留原业务锁" % context)
		# 打开表单后BOT若接管行动，其设置的锁也不应被关闭表单恢复成旧值。
		main.board.input_locked = true
		join._on_cancel()
		await process_frame
		check(main.board.input_locked, "%s：关闭不会解除后来设置的BOT业务锁" % context)
	main.board.input_locked = false

func _check_save_notice(main: Node, prefix: String) -> void:
	main.save_notice.show_saved("/tmp/drawer-nonmodal-check.record", 12)
	await _layout(main)
	check(main.save_notice.visible and main._drawer_can_collapse()
		and not main.board._interaction_is_blocked(), "%s：录像保存通知不锁牌桌或收起" % prefix)
	_assert_real_pick(main, "%s录像通知" % prefix)
	var before: String = main.save_notice._path_edit.text
	await _collapse_restore(main, "%s录像通知" % prefix)
	check(main.save_notice.visible and main.save_notice._path_edit.text == before,
		"%s：展开恢复录像路径和通知" % prefix)
	main.save_notice._on_close()

func _collapse_restore(main: Node, context: String) -> void:
	var drawer: Node = main.drawer_window
	var presentation: Node = main.drawer_presentation
	var original_lock: bool = main.board.input_locked
	drawer.collapse_now()
	check(not drawer.is_expanded() and main._drawer_input_blocked(),
		"%s：工具页打开时仍能真实收起并关闭牌桌输入" % context)
	check(not presentation._utility.visible and not main.msg_log.visible
		and not main.save_notice.visible, "%s：收起后工具页、日志与通知全部隐藏" % context)
	if main._join_panel != null and is_instance_valid(main._join_panel):
		check(not main._join_panel.visible, "%s：收起后联网表单也隐藏" % context)
	check(main.board.input_locked == original_lock, "%s：收起不改业务锁" % context)
	drawer.pin()
	await _layout(main)
	check(drawer.is_expanded() and not main._drawer_input_blocked(),
		"%s：展开后窗口输入门恢复" % context)
	check(main.board.input_locked == original_lock, "%s：展开不改业务锁" % context)

func _dispose(main: Node) -> void:
	paused = false
	if main.sfx:
		main.sfx.set_muted(true)
	main.queue_free()
	await process_frame
	await process_frame
