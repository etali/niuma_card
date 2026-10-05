# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 抽屉版场景回归：验证窗口变宽后牌面仍是原始比例，完整市场与玩家区都留在玩法框内。
## 该测试故意只依赖 main 暴露的 drawer_presentation，不读取私有布局常量。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉牌桌呈现回归 ===")
	var main := await _boot_drawer_main(Vector2i(1440, 960))
	if not need(main != null, "抽屉模式场景启动"):
		finish()
		return
	var presentation: Variant = main.get("drawer_presentation")
	if not need(presentation != null, "main 暴露 drawer_presentation"):
		main.queue_free()
		finish()
		return

	# 抽屉把牌桌标签留白还给卡牌；控制项集中到选项。
	var menu: MenuButton = presentation.get("_menu")
	check(menu != null, "选项菜单存在")
	if menu != null:
		var popup := menu.get_popup()
		check(popup.item_count >= 5, "选项包含存录像入口")
		var has_save := false
		var has_ratio := false
		var has_handle_size := false
		var has_pixel_resolution := false
		for item_idx in popup.item_count:
			var item_text := popup.get_item_text(item_idx)
			if item_text == "存录像":
				has_save = true
			if item_text == "UI":
				has_ratio = true
			if item_text == "入口大小":
				has_handle_size = true
			if item_text == "窗口尺寸":
				has_pixel_resolution = true
		check(has_save, "存录像位于选项")
		check(has_ratio, "选项提供UI入口")
		check(has_handle_size, "选项提供入口大小入口")
		check(not has_pixel_resolution, "选项不再提供像素分辨率入口")
	check(not main.btn_save.visible, "底栏不再占用存录像按钮空间")
	var world_tags := ["对手公司", "公共市场", "我的公司"]
	for child in presentation.get_children():
		if child is Label:
			for tag in world_tags:
				check(tag not in child.text, "牌桌不显示冗余标签%s" % tag)

	var layouts := [Vector2i(1440, 960), Vector2i(1280, 800)]
	var baseline_scales: Array = []
	for size in layouts:
		_set_window_size(main, size)
		presentation.relayout()
		await physics_frame
		var rect: Rect2 = presentation.content_rect()
		check(rect.size.x > 0.0 and rect.size.y > 0.0, "可用玩法区有效（%dx%d）" % [size.x, size.y])
		var table_bounds: Variant = presentation.get("table_bounds")
		if table_bounds != null:
			check(table_bounds == Rect2(-14.2, -8.9, 28.4, 15.6), "抽屉桌面边界固定且完整")
		var player_bounds: Variant = presentation.get("player_bounds")
		if player_bounds != null:
			check(player_bounds == Rect2(-12.5, 0.0, 25.0, 6.5), "玩家操作区边界固定且足够宽")
		check(rect.position.x >= -0.5 and rect.position.y >= -0.5, "玩法区不跑到窗口左上外")
		check(rect.end.x <= size.x + 0.5 and rect.end.y <= size.y + 0.5, "玩法区不越出窗口边界")

		var cards: Array = main.market_cards
		check(cards.size() == 8, "公共市场保留完整8张卡（%dx%d）" % [size.x, size.y])
		var camera: Camera3D = main.get("camera") if main.get("camera") else main.get_node_or_null("Camera3D")
		check(camera != null, "抽屉布局拥有可投影相机")
		if camera == null:
			continue
		for i in cards.size():
			var card: CardEntity = cards[i]
			check(card.visible, "市场卡%d可见" % (i + 1))
			var scale := card.global_transform.basis.get_scale()
			check(scale.is_equal_approx(Vector3.ONE), "市场卡%d根节点不被压缩" % (i + 1))
			if baseline_scales.size() <= i:
				baseline_scales.append(scale)
			else:
				check(scale.is_equal_approx(baseline_scales[i]), "窗口尺寸变化不改变市场卡%d缩放" % (i + 1))
			_assert_card_projection(camera, rect, card, "市场卡%d" % (i + 1))

		_assert_all_entities_inside(main, camera, rect)
		_check_price_alignment(main, cards)
		_check_no_hud_overlap(main, rect, camera)

	# 购买入口至少走过一次，确认抽屉重排没有把索引映射成当前可见页索引。
	var buy_method: Callable = Callable(main, "_try_buy")
	check(buy_method.is_valid(), "抽屉模式仍保留_try_buy(0)入口")
	if buy_method.is_valid():
		var result: Variant = await buy_method.call(0)
		check(result is Dictionary, "_try_buy(0)返回规则结果")

	# 购买后补牌仍须落在同一个玩法框，且索引始终对应完整市场数组。
	presentation.relayout()
	await process_frame
	var post_buy_rect: Rect2 = presentation.content_rect()
	var post_buy_camera: Camera3D = main.board.camera
	_assert_all_entities_inside(main, post_buy_camera, post_buy_rect)
	check(main.market_cards.size() == CardDB.game_rules()["market_size"] - 1, "购买后市场卡数量按规则减少一张")

	# 设置入口必须仍可打开；关闭后不得残留 modal，避免抽屉被 can_collapse 永久阻塞。
	presentation._open_utility(0)
	check(presentation.panels_open(), "配色设置入口可打开")
	_assert_drawer_theme(presentation, "配色")
	presentation.close_panels()
	presentation._open_utility(1)
	check(presentation.panels_open(), "BOT强度设置入口可打开")
	_assert_drawer_theme(presentation, "BOT强度")
	presentation.close_panels()
	presentation._open_utility(3)
	check(presentation.panels_open(), "窗口比例设置入口可打开")
	_assert_drawer_theme(presentation, "窗口比例")
	presentation.close_panels()
	check(not presentation.panels_open(), "关闭设置面板后恢复无工具页状态")

	# 窗口门控与业务行动锁分开：collapse/expand 不得改写 board.input_locked。
	var drawer = main.get("drawer_window")
	if drawer != null:
		main.board.input_locked = false
		drawer.collapse_now()
		await _wait_transition_process(drawer)
		check(main._drawer_input_blocked(), "抽屉收起时窗口门阻止桌面输入")
		check(not main.board.input_locked, "抽屉收起不篡改业务输入锁（原false）")
		drawer.expand()
		await _wait_transition_process(drawer)
		check(not main._drawer_input_blocked(), "抽屉展开完成解除窗口门")
		check(not main.board.input_locked, "抽屉展开不篡改业务输入锁（仍false）")
		main.board.input_locked = true
		drawer.collapse_now()
		await _wait_transition_process(drawer)
		drawer.expand()
		await _wait_transition_process(drawer)
		check(main.board.input_locked, "抽屉收放保留业务输入锁（原true）")

	if main.sfx:
		main.sfx.set_muted(true)
		main.sfx.free()
	main.queue_free()
	await process_frame
	await process_frame
	await process_frame
	finish()

func _assert_drawer_theme(presentation: Node, name: String) -> void:
	var utility: Control = presentation.get("_utility")
	check(utility != null and utility.visible, "%s面板可见" % name)
	if utility == null:
		return
	var title: Label = presentation.get("_utility_title")
	check(title != null and title.get_theme_font_size("font_size") >= 18, "%s标题使用统一字号" % name)
	var buttons := _find_buttons(utility)
	check(buttons.size() > 0, "%s面板包含统一按钮" % name)
	for node in buttons:
		var button := node as Button
		check(button.get_theme_font_size("font_size") >= 15, "%s按钮字号随抽屉主题设置" % name)
		check(button.get_theme_stylebox("normal") != null and button.get_theme_stylebox("hover") != null,
			"%s按钮具备normal/hover统一样式" % name)

func _find_buttons(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in root.get_children():
		if child is Control:
			if child is Button:
				out.append(child as Control)
			out.append_array(_find_buttons(child))
	return out

func _boot_drawer_main(size: Vector2i) -> Node:
	var scene := load("res://scenes/main.tscn")
	var main: Node = scene.instantiate()
	if main.get("force_drawer_layout") != null:
		main.force_drawer_layout = true
	var window := root
	if window is Window:
		window.size = size
		window.content_scale_size = Vector2i.ZERO
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.add_child(main)
	_booted = main
	var cap := 180
	for i in cap:
		await physics_frame
		if not _anim_busy(main) and i > 12:
			break
	_assert_booted(main)
	return main

func _set_window_size(main: Node, size: Vector2i) -> void:
	var window := main.get_window()
	if window:
		window.size = size
		window.content_scale_size = Vector2i.ZERO
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED

func _project_card_corners(camera: Camera3D, card: CardEntity) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for x in [-CardEntity.CARD_SIZE.x * 0.5, CardEntity.CARD_SIZE.x * 0.5]:
		for z in [-CardEntity.CARD_SIZE.z * 0.5, CardEntity.CARD_SIZE.z * 0.5]:
			out.append(camera.unproject_position(card.to_global(Vector3(x, 0.04, z))))
	return out

func _assert_card_projection(camera: Camera3D, rect: Rect2, card: CardEntity, label: String) -> void:
	var projected := _project_card_corners(camera, card)
	for corner in projected:
		check(rect.grow(1.0).has_point(corner), "%s四角留在玩法区" % label)
	if camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		# 真透视下四边长度随深度变化，不能再用正交sin俯角比值作为断言。
		# 将每个屏幕角反投影回该卡平面，验证它仍对应未拉伸的真实几何。
		var restored: Array[Vector3] = []
		for point in projected:
			var origin := camera.project_ray_origin(point)
			var ray := camera.project_ray_normal(point)
			var t := (card.global_position.y + 0.04 - origin.y) / ray.y
			restored.append(origin + ray * t)
		check(absf(restored[2].distance_to(restored[0]) - CardEntity.CARD_SIZE.x) < 0.002
			and absf(restored[1].distance_to(restored[0]) - CardEntity.CARD_SIZE.z) < 0.002,
			"%s透视角点还原到真实3:4卡面，未非等比缩放" % label)
	else:
		var x_edge := projected[2].distance_to(projected[0])
		var z_edge := projected[1].distance_to(projected[0])
		var tilt := absf(camera.rotation_degrees.x)
		var expected_ratio := CardEntity.CARD_SIZE.x / (CardEntity.CARD_SIZE.z * maxf(sin(deg_to_rad(tilt)), 0.1))
		check(z_edge > 0.01 and absf(x_edge / z_edge - expected_ratio) <= 0.03, "%s投影边长匹配俯视角" % label)

func _assert_all_entities_inside(main: Node, camera: Camera3D, rect: Rect2) -> void:
	for uid in main.entities:
		var card = main.entities[uid]
		if not is_instance_valid(card) or not card.visible:
			continue
		_assert_card_projection(camera, rect, card, "实体卡%s" % str(uid))

func _check_price_alignment(main: Node, cards: Array) -> void:
	var labels: Array = main.get("market_price_labels")
	check(labels != null and labels.size() == cards.size(), "8张市场卡都有对应价签")
	if labels == null:
		return
	for i in mini(labels.size(), cards.size()):
		var label = labels[i]
		var card: CardEntity = cards[i]
		if is_instance_valid(label) and label is Node3D:
			check(absf(label.global_position.x - card.global_position.x) <= 0.03, "市场卡%d价签中心对齐" % (i + 1))

func _check_no_hud_overlap(main: Node, rect: Rect2, camera: Camera3D) -> void:
	# HUD 允许位于玩法框外；若有 Control 落在玩法框内，只要不盖住任何市场卡投影即可。
	var card_rect := Rect2()
	for card in main.market_cards:
		for point in _project_card_corners(camera, card):
			card_rect = Rect2(point, Vector2.ZERO) if card_rect == Rect2() else card_rect.expand(point)
	for child in main.get_children():
		if not (child is CanvasLayer):
			continue
		for node in child.get_children():
			if node is Control and node.visible:
				var r := Rect2(node.global_position, node.size)
				check(not r.intersects(card_rect), "HUD控件不覆盖市场卡牌面")

func _wait_transition_process(drawer: Node) -> void:
	var n := 0
	while drawer.is_transitioning() and n < 90:
		await process_frame
		n += 1
	check(not drawer.is_transitioning(), "抽屉过渡在暂停时仍能结束")
