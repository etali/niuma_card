# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 胜负提示走真实终局入口，检查统一主题、像素字号以及抽屉收放生命周期。
## 终局必须继续锁牌；联机可能在抽屉已经收起后才结束，提示不能漏到入口窗口。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉胜负提示统一样式与收放回归 ===")
	for dpi in [1.0, 2.0]:
		for won in [true, false]:
			var prefix := "%s倍DPI%s" % [dpi, "胜利" if won else "失败"]
			var main := await _boot_drawer(float(dpi))
			_show_result(main, won)
			await _layout(main)
			if need(main.game_over_panel != null, "%s：真实终局提示建成" % prefix):
				await _check_result(main, float(dpi), won, prefix)
			await _dispose(main)
		var collapsed_main := await _boot_drawer(float(dpi))
		await _check_result_arrives_collapsed(collapsed_main, "%s倍DPI已收起" % dpi)
		await _dispose(collapsed_main)
		await _check_network_resign_center(float(dpi))
	finish()

func _boot_drawer(dpi: float) -> Node:
	paused = false
	root.size = Vector2i(roundi(1280 * dpi), roundi(800 * dpi))
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
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.sfx.set_muted(true)
	await _layout(main)
	return main

func _layout(main: Node) -> void:
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await process_frame

func _show_result(main: Node, won: bool) -> void:
	main.state.winner = main.my_seat if won else main.foe_seat
	main.state.win_reason = "测试结算原因：公司资金达到胜利条件。"
	main._show_game_over()

func _result_layer(main: Node) -> CanvasLayer:
	var node: Node = main.game_over_panel
	while node != null and not node is CanvasLayer:
		node = node.get_parent()
	return node as CanvasLayer

func _check_result(main: Node, dpi: float, won: bool, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	var panel: PanelContainer = main.game_over_panel
	var layer := _result_layer(main)
	if not need(layer != null, "%s：提示拥有可独立释放的CanvasLayer" % prefix):
		return
	check(layer.layer == 10 and layer.visible, "%s：提示保留终局层级并真实显示" % prefix)
	check(panel.get_parent() is CenterContainer, "%s：内容由居中容器排版" % prefix)
	var title: Label = panel.find_child("ResultTitle", true, false)
	var message: Label = panel.find_child("ResultMessage", true, false)
	var reason: Label = panel.find_child("ResultReason", true, false)
	var restart: Button = panel.find_child("ResultRestart", true, false)
	if not need(title != null and message != null and reason != null and restart != null,
		"%s：标题、嘲讽、原因与重开入口完整" % prefix):
		return
	check(title.text == ("胜利" if won else "失败"), "%s：胜负标题与玩家座位一致" % prefix)
	var taunts: Array = main.WIN_TAUNTS if won else main.LOSE_TAUNTS
	check(taunts.has(message.text), "%s：保留原有对应胜负嘲讽" % prefix)
	check(reason.text == main.state.win_reason, "%s：展示实际终局原因" % prefix)
	check(restart.text == "再战一局" and not restart.disabled, "%s：单机重开按钮仍可用" % prefix)
	check(main.board.input_locked and main.btn_pass.disabled and main.btn_resign.disabled,
		"%s：统一样式后终局业务锁仍生效" % prefix)
	check(main._drawer_can_collapse(), "%s：终局提示不阻止抽屉收起" % prefix)

	var style: StyleBoxFlat = panel.get_theme_stylebox("panel")
	var tab_style: StyleBoxFlat = presentation._utility.get_theme_stylebox("panel")
	check(style != null and tab_style != null and style.bg_color.is_equal_approx(tab_style.bg_color),
		"%s：提示与当前tab共享表面配色" % prefix)
	check(style != null and tab_style != null and style.border_color.is_equal_approx(tab_style.border_color)
		and style.border_width_left == tab_style.border_width_left
		and style.corner_radius_top_left == tab_style.corner_radius_top_left,
		"%s：提示与当前tab共享边框与圆角" % prefix)
	var ink := Palette.get_color("card", "body")
	for entry in [[title, 21], [message, 17], [reason, 15], [restart, 17]]:
		var control: Control = entry[0]
		var base: int = entry[1]
		check(control.get_theme_font_size("font_size") == roundi(base * dpi),
			"%s：%s采用统一%d号字并按DPI直接渲染" % [prefix, control.name, base])
		var expected_ink := ink
		if control is Button:
			expected_ink = Palette.readable_ink(Palette.semantic("ink"), (control.get_theme_stylebox("normal") as StyleBoxFlat).bg_color)
		check(control.get_theme_color("font_color").is_equal_approx(expected_ink),
			"%s：%s使用可读的语义墨色" % [prefix, control.name])
		check(control.scale.is_equal_approx(Vector2.ONE)
			and control.get_global_transform_with_canvas().get_scale().is_equal_approx(Vector2.ONE),
			"%s：%s保持原生像素变换" % [prefix, control.name])
	check(layer.scale.is_equal_approx(Vector2.ONE), "%s：终局画布没有二次放大" % prefix)
	check(restart.get_theme_stylebox("normal") is StyleBoxFlat,
		"%s：重开按钮使用当前tab按钮样式" % prefix)
	_check_geometry(panel, prefix)

	var old_title_font := title.get_theme_font_size("font_size")
	var old_body_font := message.get_theme_font_size("font_size")
	root.size = Vector2i(roundi(1600 * dpi), roundi(1000 * dpi))
	await _layout(main)
	check(title.get_theme_font_size("font_size") > old_title_font
		and message.get_theme_font_size("font_size") > old_body_font,
		"%s：窗口放大后标题与正文实际字号同步增大" % prefix)
	_check_geometry(panel, "%s大窗口" % prefix)

	main.save_notice.show_saved("/tmp/drawer-result-check.record", 12)
	await _layout(main)
	check(main.save_notice.visible and main.save_notice.layer > layer.layer,
		"%s：录像通知仍可在终局提示之上显示" % prefix)
	main.drawer_window.collapse_now()
	check(not main.drawer_window.is_expanded() and not layer.visible,
		"%s：真实收起立即隐藏整层终局提示" % prefix)
	check(not main.save_notice.visible and main.board.input_locked,
		"%s：收起同时隐藏录像通知且保留终局业务锁" % prefix)
	main.drawer_window.pin()
	await _layout(main)
	check(main.game_over_panel == panel and _result_layer(main) == layer and layer.visible,
		"%s：展开恢复同一个终局面板" % prefix)
	check(main.board.input_locked and main.phase == main.PHASE_OVER,
		"%s：展开不误解锁已经结束的牌局" % prefix)
	check(main.save_notice.visible, "%s：展开恢复原录像通知" % prefix)
	main.save_notice._on_close()
	main._show_game_over()
	check(main.game_over_panel == panel, "%s：重复终局通知不会另建面板" % prefix)

	# 用真实单机按钮走重开信号，验证注册主题后仍释放整层而非留下空容器。
	var result_id := layer.get_instance_id()
	restart.pressed.emit()
	await _layout(main)
	check(main.game_over_panel == null and not is_instance_valid(layer),
		"%s：实际重开按钮释放完整终局层" % prefix)
	check(not _has_panel_id(presentation._suspended_panels, result_id),
		"%s：重开的提示不留在抽屉待恢复集合" % prefix)
	check(main.state.winner == "" and main.phase != main.PHASE_OVER,
		"%s：重开按钮确实进入新牌局" % prefix)

func _check_geometry(panel: Control, prefix: String) -> void:
	var rect := panel.get_global_rect()
	var window := Rect2(Vector2.ZERO, Vector2(root.size))
	check(window.grow(1).encloses(rect), "%s：整块终局提示完整留在窗口内" % prefix)
	check((rect.get_center() - window.get_center()).length() < 1.0,
		"%s：终局提示在当前窗口居中" % prefix)

func _check_result_arrives_collapsed(main: Node, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	main.drawer_window.collapse_now()
	check(presentation._collapsed, "%s：前提为抽屉已经完成收起" % prefix)
	# 联机收起时继续接收结算；这里只恢复时钟，不伪造网络对象或协议连接。
	paused = false
	_show_result(main, false)
	var layer := _result_layer(main)
	if not need(layer != null, "%s：收起期间真实创建终局层" % prefix):
		return
	check(not layer.visible, "%s：创建同一帧即隐藏，不把失败提示漏到入口icon" % prefix)
	check(presentation._suspended_panels.has(layer), "%s：新提示登记为展开后恢复" % prefix)
	main.drawer_window.pin()
	await _layout(main)
	check(layer.visible and main.board.input_locked, "%s：展开显示收到的终局并继续锁牌" % prefix)
	_check_geometry(main.game_over_panel, prefix)
	main.drawer_window.collapse_now()
	check(not layer.visible and presentation._suspended_panels.has(layer),
		"%s：再次收起登记同一提示" % prefix)
	var result_id := layer.get_instance_id()
	# 两条重开路径共用的清理函数必须也能处理正在等待恢复的终局层。
	paused = false
	main._on_restart()
	await process_frame
	await process_frame
	check(not is_instance_valid(layer) and main.game_over_panel == null,
		"%s：重开时完整释放等待恢复的终局层" % prefix)
	check(not _has_panel_id(presentation._suspended_panels, result_id),
		"%s：等待恢复集合不残留已释放终局" % prefix)
	main.drawer_window.pin()
	await _layout(main)
	check(main.find_child("GameOver", false, false) == null,
		"%s：新局展开不会复活上一局胜负提示" % prefix)

func _has_panel_id(panels: Array, instance_id: int) -> bool:
	for panel in panels:
		if is_instance_valid(panel) and panel.get_instance_id() == instance_id:
			return true
	return false

var _resign_finished := false

## 真实局域网通知后只等布局帧，不调用 _layout 人为补一次 relayout。
func _check_network_resign_center(dpi: float) -> void:
	var pair: Array = await net_seated_pair(47780, 20260829, "CENTER")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	var main := await _boot_drawer(dpi)
	main.begin_net_game(a)
	if not need(await net_until(pair, func(): return main._net_table_drawn and main.phase == main.PHASE_ACTION),
		"联网居中：双方实际入座并进入行动阶段"):
		a.close()
		b.close()
		await _dispose(main)
		return
	_resign_finished = false
	# 接收方必须由 main._process 自己 poll：测试在 physics_frame 抢先 poll
	# 会改变弹窗与主题更新的帧内顺序，掩盖首帧容器被最小高度撑大的问题。
	net_pump_until([b], func(): return _resign_finished)
	var result: Dictionary = await b.submit(Intent.resign(b.my_seat))
	_resign_finished = true
	check(result.get("ok", false), "联网居中：对手认输被服务器接受")
	if need(await net_until([b], func(): return main.game_over_panel != null),
		"联网居中：对手认输后自动出现终局提示"):
		await _wait_result_layout()
		check(main.state.winner == main.my_seat, "联网居中：胜利属于当前玩家")
		check(main._rematch_btn != null, "联网居中：包含退出房间与再来一局两个按钮")
		_check_geometry(main.game_over_panel, "%s倍DPI联网认输首次弹出" % dpi)
		b.close()
		check(await net_until([], func(): return not main._foe_online),
			"联网居中：主循环已处理对手断开的通知")
		await _wait_result_layout()
		_check_geometry(main.game_over_panel, "%s倍DPI认输后对手断开" % dpi)
		for extent in [Vector2i(960, 600), Vector2i(1600, 1000)]:
			root.size = Vector2i(Vector2(extent) * dpi)
			await _wait_result_layout()
			_check_geometry(main.game_over_panel, "%s倍DPI联网终局缩放%s" % [dpi, extent])
		main.drawer_window.collapse_now()
		main.drawer_window.pin()
		await _wait_result_layout()
		_check_geometry(main.game_over_panel, "%s倍DPI联网终局重新展开" % dpi)
	a.close()
	b.close()
	await _dispose(main)

func _wait_result_layout() -> void:
	for i in 6:
		await process_frame

func _dispose(main: Node) -> void:
	paused = false
	if main.sfx:
		main.sfx.set_muted(true)
	main.queue_free()
	for i in 3:
		await process_frame
