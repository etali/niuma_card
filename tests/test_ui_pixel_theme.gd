# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 抽屉 UI 在实际输出像素里排版：改变 DPI/窗口时重算字号，
## 而不是把小字形连 CanvasLayer 或祖先 Control 一起放大。
const WEIGHT_AXIS := 0x77676874

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉原生像素主题 ===")
	for dpi in [1.0, 2.0]:
		var main := await _boot_drawer(float(dpi), Vector2i(1280, 800))
		if not need(main != null, "%s倍DPI可启动抽屉" % dpi):
			continue
		var presentation: Node = main.drawer_presentation
		var prefix := "%s倍DPI" % dpi
		_check_main_theme(main, float(dpi), prefix)
		await _check_utility_pages(main, float(dpi), prefix)
		await _check_external_panels(main, float(dpi), prefix)
		await _check_card_tooltip(main, float(dpi), prefix)

		var small_font: int = presentation._pin.get_theme_font_size("font_size")
		root.size = Vector2i(roundi(1600 * dpi), roundi(1000 * dpi))
		presentation.relayout()
		await process_frame
		var large_font: int = presentation._pin.get_theme_font_size("font_size")
		check(large_font > small_font, "%s窗口放大后实际字号增加，不依赖Canvas缩放" % prefix)
		_check_main_theme(main, float(dpi), "%s大窗口" % prefix)
		await _free_drawer(main)
	finish()

func _boot_drawer(dpi: float, logical: Vector2i) -> Node:
	paused = false
	root.size = Vector2i(roundi(logical.x * dpi), roundi(logical.y * dpi))
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
	return main

func _check_main_theme(main: Node, dpi: float, prefix: String) -> void:
	var presentation: CanvasLayer = main.drawer_presentation
	check(presentation.scale.is_equal_approx(Vector2.ONE), "%s抽屉CanvasLayer不缩放字形" % prefix)
	check(main.msg_log.scale.is_equal_approx(Vector2.ONE), "%s记录CanvasLayer不缩放字形" % prefix)
	_check_text_tree(presentation._header, dpi, "%s顶部" % prefix)
	_check_text_tree(presentation._footer, dpi, "%s底部" % prefix)
	var popup: PopupMenu = presentation._menu.get_popup()
	var popup_font := popup.get_theme_font_size("font_size")
	check(popup_font == presentation._menu.get_theme_font_size("font_size"), "%s下拉菜单与入口使用相同实际字号" % prefix)
	check(popup_font >= roundi(17 * dpi * 0.85), "%s下拉菜单字号直接适配DPI" % prefix)
	_check_font(popup.get_theme_font("font"), "%s下拉菜单" % prefix)
	var popup_style: StyleBoxFlat = popup.get_theme_stylebox("panel")
	check(popup_style != null and popup_style.bg_color.is_equal_approx(Palette.get_color("world", "table_frame")),
		"%s下拉菜单使用统一奶油色表面" % prefix)

func _check_utility_pages(main: Node, dpi: float, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	for entry in [[1, "BOT强度"], [3, "UI"], [4, "入口大小"], [5, "存录像"]]:
		presentation._open_utility(int(entry[0]))
		await process_frame
		presentation._relayout_utility()
		var utility: Control = presentation._utility
		check(utility.visible, "%s%s设置可见" % [prefix, entry[1]])
		_check_text_tree(utility, dpi, "%s%s" % [prefix, entry[1]])
		_check_inside(utility, "%s%s设置" % [prefix, entry[1]])
		presentation.close_panels()
	presentation._open_utility(2)
	await process_frame
	presentation._position_log()
	check(main.msg_log.visible and main.msg_log.expanded(), "%s提示记录真实展开" % prefix)
	_check_text_tree(main.msg_log._frame, dpi, "%s提示记录" % prefix)
	_check_inside(main.msg_log._frame, "%s提示记录" % prefix)
	presentation.close_panels()

func _check_external_panels(main: Node, dpi: float, prefix: String) -> void:
	var join: CanvasLayer = main._open_join_panel()
	for i in 3:
		await process_frame
	check(join.scale.is_equal_approx(Vector2.ONE), "%s局域网面板CanvasLayer不二次缩放" % prefix)
	var center: Control = join.get_child(0)
	_check_text_tree(center, dpi, "%s局域网对战" % prefix)
	_check_inside(center.get_child(0), "%s局域网面板" % prefix)
	join._on_cancel()
	await process_frame

	main.save_notice.show_saved("/tmp/niumapai-theme-check.record", 12)
	for i in 3:
		await process_frame
	check(main.save_notice.scale.is_equal_approx(Vector2.ONE), "%s录像通知CanvasLayer不二次缩放" % prefix)
	var frame: Control = main.save_notice.get_node("Frame")
	_check_text_tree(frame, dpi, "%s录像通知" % prefix)
	_check_inside(frame, "%s录像通知" % prefix)
	main.save_notice._on_close()

func _check_card_tooltip(main: Node, dpi: float, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	var card: CardEntity = main.market_cards[0]
	var content: Rect2 = presentation.content_rect()
	presentation.show_card_detail(card, Vector2(content.end.x - 8, content.position.y + 20))
	var detail: Control = presentation._detail
	check(detail.visible, "%s悬停详情可见" % prefix)
	check(not presentation._detail_icon.visible and presentation._detail_icon.custom_minimum_size == Vector2.ZERO,
		"%s悬停详情不为重复大图占用空间" % prefix)
	check(presentation._detail_title.get_theme_font_size("font_size") > presentation._detail_text.get_theme_font_size("font_size"),
		"%s悬停详情按标题17/正文15层级排版" % prefix)
	_check_text_tree(detail, dpi, "%s悬停详情" % prefix)
	var width: float = detail.get_combined_minimum_size().x
	check(width <= 300 * dpi and width <= root.size.x / 3.0,
		"%s悬停详情宽度受限，不覆盖大块牌桌" % prefix)
	_check_inside(detail, "%s悬停详情" % prefix)
	detail.hide()

func _check_text_tree(node: Node, dpi: float, prefix: String) -> void:
	var controls: Array[Control] = []
	_collect_text_controls(node, controls)
	var unscaled := true
	var readable := true
	var real_weights := true
	var consistent_buttons := true
	var ink := Palette.get_color("card", "body")
	for control in controls:
		unscaled = unscaled and control.scale.is_equal_approx(Vector2.ONE)
		var transform := control.get_global_transform_with_canvas()
		unscaled = unscaled and transform.get_scale().is_equal_approx(Vector2.ONE)
		var font_key := "normal_font" if control is RichTextLabel else "font"
		var size_key := "normal_font_size" if control is RichTextLabel else "font_size"
		var base := int(control.get_meta("drawer_font_base", 17))
		readable = readable and control.get_theme_font_size(size_key) >= roundi(base * dpi * 0.85)
		var font: Font = control.get_theme_font(font_key)
		real_weights = real_weights and _has_real_weight(font)
		if control is Button and not control.get_meta("drawer_icon_button", false):
			var normal: StyleBoxFlat = control.get_theme_stylebox("normal")
			var role: String = control.get_meta("ui_role", "tool")
			var role_ink := Palette.semantic("danger") if role == "danger" else Palette.semantic("ink")
			if role == "danger" and control.get_meta("danger_armed", false):
				role_ink = Color.WHITE
			var expected_ink := Palette.readable_ink(role_ink, normal.bg_color)
			consistent_buttons = consistent_buttons and control.get_theme_color("font_color").is_equal_approx(expected_ink)
			consistent_buttons = consistent_buttons and normal is StyleBoxFlat

	check(not controls.is_empty(), "%s有可检查的文字控件" % prefix)
	check(unscaled, "%s文字与所有祖先保持1:1像素变换" % prefix)
	check(readable, "%s使用实际输出字号，DPI提高时不放大小字形纹理" % prefix)
	check(real_weights, "%s文字使用真实Regular/SemiBold字重" % prefix)
	check(consistent_buttons, "%s按钮采用角色语义色与统一面板样式" % prefix)

func _collect_text_controls(node: Node, out: Array[Control]) -> void:
	if node is DrawerMascot:
		return
	if node is Label or node is LineEdit or node is RichTextLabel:
		out.append(node)
	elif node is Button and not node.get_meta("drawer_icon_button", false):
		out.append(node)
	if node is SpinBox:
		out.append(node.get_line_edit())
	for child in node.get_children():
		_collect_text_controls(child, out)

func _has_real_weight(font: Font) -> bool:
	if not font is FontVariation:
		return false
	var rids := font.get_rids()
	if rids.is_empty():
		return false
	var axes := TextServerManager.get_primary_interface().font_get_variation_coordinates(rids[0])
	return int(axes.get(WEIGHT_AXIS, 0)) in [400, 600] and is_zero_approx(font.variation_embolden)

func _check_font(font: Font, prefix: String) -> void:
	check(_has_real_weight(font), "%s使用真实字重的共享字体" % prefix)

func _check_inside(control: Control, prefix: String) -> void:
	var rect := Rect2(control.get_global_transform_with_canvas() * Vector2.ZERO, control.size)
	check(Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(rect), "%s完整留在当前窗口内" % prefix)

func _free_drawer(main: Node) -> void:
	paused = false
	if main.sfx:
		main.sfx.set_muted(true)
		main.sfx.free()
	main.queue_free()
	for i in 3:
		await process_frame
