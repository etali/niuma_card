# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 在真实抽屉场景中操作 UI 页的滑块，检查镜头、可玩边界和两种 DPI 下的控件。
## 角度变化必须走生产信号与重新构图，不能只修改一个未接入镜头的参数。
const WINDOW_RATIOS := [0.75, 0.85, 0.92, 0.98]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== UI 透视角度设置集成 ===")
	for dpi in [1.0, 2.0]:
		var main: Node = await _boot_drawer(float(dpi))
		var presentation: Node = main.drawer_presentation
		var context := "%d倍DPI" % int(dpi)
		if not need(presentation != null and presentation.has_method("set_perspective_angle"),
			"%s：抽屉呈现公开透视角度参数" % context):
			await _dispose(main)
			continue
		_check_menu(presentation, context)
		check(is_equal_approx(float(presentation.perspective_angle), 80.0),
			"%s：新会话保留配置默认80°斜俯视" % context)
		presentation._open_utility(3)
		await _layout(main)
		check(presentation._utility_title.text == "UI", "%s：原比例页标题改为UI" % context)
		var body: Control = presentation._utility_body
		var slider := body.find_child("PerspectiveAngle", true, false) as HSlider
		var value := body.find_child("PerspectiveAngleValue", true, false) as Label
		if not need(slider != null and value != null, "%s：UI页包含可操作角度滑块与实时度数" % context):
			await _dispose(main)
			continue
		check(slider.min_value == 45.0 and slider.max_value == 80.0 and slider.step == 1.0,
			"%s：透视角度提供45°至80°、每次1°的范围" % context)
		check(slider.value == 80.0, "%s：滑块与当前默认镜头角度一致" % context)
		var buttons := _ratio_buttons(body)
		check(buttons.size() == 4, "%s：UI页仍提供四个窗口比例按钮" % context)
		if not buttons.is_empty():
			check(slider.get_global_rect().position.y >= buttons.back().get_global_rect().end.y,
				"%s：透视角度位于窗口比例选项下方" % context)
		_check_native_controls(presentation._utility, float(dpi), context)
		var previous_bounds: Rect2 = main.board.player_bounds
		for angle in [45.0, 60.0, 80.0]:
			slider.value = angle
			var angle_context := "%s/%d°" % [context, int(angle)]
			check(is_equal_approx(float(presentation.perspective_angle), angle),
				"%s：滑块信号实时更新实际角度参数" % angle_context)
			check(absf(main.board.camera.rotation_degrees.x + angle) < 0.01,
				"%s：拖动滑块立即改变真实相机俯仰" % angle_context)
			check(str(int(angle)) in value.text and "°" in value.text,
				"%s：当前角度以度数实时显示" % angle_context)
			await _layout(main)
			_check_projection(main, angle_context)
			check(main.board.player_bounds != previous_bounds,
				"%s：角度变化重新计算实际可放牌边界" % angle_context)
			previous_bounds = main.board.player_bounds
			check(not main._drawer_input_blocked() and not main.board._interaction_is_blocked()
				and main._drawer_can_collapse(), "%s：UI页不锁牌桌或阻止抽屉收起" % angle_context)
		# 收起、展开与关闭、重开分别检验同一会话参数；不是每次建控件都回到60°。
		main.drawer_window.collapse_now()
		check(not main.drawer_window.is_expanded(), "%s：角度设置打开时仍可真实收起" % context)
		main.drawer_window.pin()
		await _layout(main)
		check(presentation.panels_open() and slider.value == 80.0,
			"%s：重新展开保留原UI页与当前角度" % context)
		presentation.close_panels()
		presentation._open_utility(3)
		await _layout(main)
		slider = presentation._utility_body.find_child("PerspectiveAngle", true, false) as HSlider
		check(slider != null and slider.value == 80.0 and presentation.perspective_angle == 80.0,
			"%s：关闭重开UI页保留会话内角度" % context)
		buttons = _ratio_buttons(presentation._utility_body)
		for i in mini(buttons.size(), WINDOW_RATIOS.size()):
			buttons[i].pressed.emit()
			check(is_equal_approx(float(main.drawer_window.get_size_ratio()), WINDOW_RATIOS[i]),
				"%s：%s仍设置自身窗口比例" % [context, buttons[i].text])
			check(presentation.perspective_angle == 80.0,
				"%s：改变窗口比例保留选定角度" % context)
		# 公开接口同样钳制越界值，避免程序调用使镜头变成平视或过顶。
		presentation.set_perspective_angle(0.0)
		check(presentation.perspective_angle == 45.0 and slider.value == 45.0,
			"%s：公开参数过小时镜头与滑块共同限制到45°" % context)
		presentation.set_perspective_angle(90.0)
		check(presentation.perspective_angle == 80.0 and slider.value == 80.0,
			"%s：公开参数过大时镜头与滑块共同限制到80°" % context)
		await _dispose(main)
	finish()

func _boot_drawer(dpi: float) -> Node:
	paused = false
	root.size = Vector2i(roundi(1600 * dpi), roundi(1000 * dpi))
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
	main.board.input_locked = false
	await _layout(main)
	return main

func _layout(main: Node) -> void:
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await settle()

func _check_menu(presentation: Node, context: String) -> void:
	var popup: PopupMenu = presentation._menu.get_popup()
	var ui_count := 0
	var old_count := 0
	for i in popup.item_count:
		var text := popup.get_item_text(i)
		if text == "UI":
			ui_count += 1
			check(popup.get_item_id(i) == 3, "%s：UI菜单继续使用原设置页ID" % context)
		if text == "窗口比例":
			old_count += 1
	check(ui_count == 1 and old_count == 0, "%s：菜单唯一UI入口替代旧窗口比例入口" % context)

func _check_projection(main: Node, context: String) -> void:
	var camera: Camera3D = main.board.camera
	check(camera.projection == Camera3D.PROJECTION_PERSPECTIVE,
		"%s：仍采用真正透视投影" % context)
	check(camera.scale.is_equal_approx(Vector3.ONE) and main.scale.is_equal_approx(Vector3.ONE),
		"%s：不缩放相机或世界伪造视角" % context)
	var content: Rect2 = main.drawer_presentation.content_rect()
	var cards: Array = main.entities.values() + main.market_cards
	check(main.market_cards.size() == 8, "%s：市场仍保留全部8张牌" % context)
	for card: CardEntity in cards:
		if not is_instance_valid(card) or not card.visible:
			continue
		var inside := true
		var half := CardEntity.CARD_SIZE * 0.5
		for dx in [-half.x, half.x]:
			for dz in [-half.z, half.z]:
				var point := camera.unproject_position(card.to_global(Vector3(dx, half.y, dz)))
				inside = inside and content.grow(1.0).has_point(point)
		check(inside, "%s：%s卡%d的四角完整留在牌桌内容区" % [context,
			"市场" if card.is_market else "实体", card.uid])
		check(card.global_transform.basis.get_scale().is_equal_approx(Vector3.ONE),
			"%s：卡%d保留真实卡面比例" % [context, card.uid])
	var far_width := camera.unproject_position(Vector3(0.6, 0.1, -4.2)).distance_to(
		camera.unproject_position(Vector3(-0.6, 0.1, -4.2)))
	var near_width := camera.unproject_position(Vector3(0.6, 0.1, 4.8)).distance_to(
		camera.unproject_position(Vector3(-0.6, 0.1, 4.8)))
	check(near_width > far_width, "%s：近处卡牌仍比远处大，保留纵深" % context)

func _ratio_buttons(node: Node) -> Array[Button]:
	var result: Array[Button] = []
	for child in node.get_children():
		if child is Button and "%" in child.text:
			result.append(child)
		result.append_array(_ratio_buttons(child))
	return result

func _check_native_controls(node: Node, dpi: float, context: String) -> void:
	if node is Control:
		check(node.scale.is_equal_approx(Vector2.ONE), "%s：%s按原生像素排版，不拉伸控件" % [context, node.name])
		if node is Label or node is Button:
			check(node.get_theme_font_size("font_size") >= roundi(15.0 * dpi),
				"%s：%s字体跟随DPI保持可读字号" % [context, node.name])
	for child in node.get_children():
		_check_native_controls(child, dpi, context)

func _dispose(main: Node) -> void:
	paused = false
	if main.sfx:
		main.sfx.set_muted(true)
	main.queue_free()
	await process_frame
	await process_frame
