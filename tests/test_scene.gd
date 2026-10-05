# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 场景回归测试（M3 版）：场景实例化 + 堆叠配方标签
## 运行：godot --headless -s tests/test_scene.gd


func _initialize() -> void:
	print("=== 场景回归测试 ===\n")
	var main: Node = await boot_main()
	check(main != null, "main.tscn 实例化成功")

	var board: Board = null
	for child in main.get_children():
		if child is Board:
			board = child
	check(board != null, "Board 节点存在")
	# 场上实体 = 两边手牌 + 公共区。数目从 state 反推：开局手牌张数和卡位数
	# 都是配置项（写死一个总数，`_game.market_size` 一调就得跟着改一次），
	# 这条要验的是「state 里每张卡都建了实体、一张不落也不多」
	var want: int = main.state.players[GameState.PLAYER]["cards"].size() \
		+ main.state.players[GameState.BOT]["cards"].size() \
		+ main.state.market.size()
	check(board.cards.size() == want, "全部实体注册（%d/%d）" % [board.cards.size(), want])

	# 注入一张核心卡 + 取一份配方的用户卡，测堆叠进度显示。
	# 配方量读卡表：这一节量的是「D 位怎么写」，吃几张是数值旋钮
	var core_def: Dictionary = CardDB.get_def("shuabuting")
	var need := int(core_def["recipe_n"])
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9999, "def_id": "shuabuting" }, Vector3(0, 2, 3), true)
	var users: Array[CardEntity] = []
	for c in board.cards:
		if c.def_id == "user" and c.draggable and users.size() < need:
			users.append(c)
	check(users.size() == need, "取到 %d 张用户卡" % need)

	var g := board.make_group([core] + users)
	board.groups.append(g)
	board._layout_group(g)
	await physics_frame
	# 桌面上不该有任何不属于卡牌的悬浮物（悬浮配方大字、组顶填充进度条）：
	# 进度只归核心卡右下角 D 位的墨团（同一个数，且随卡移动）
	check(not g.has("label"), "不生成悬浮配方标签")
	check(not g.has("bar_fill") and not g.has("bar_bg"), "不生成组顶进度条")
	var full := "%d/%d" % [need, need]
	check(core.recipe_progress_text() == full,
		"核心卡 D 位显示 %s（%s）" % [full, core.recipe_progress_text()])

	# --- 防御 Buff 保护：卡牌盾牌标记 ---
	var any_e: CardEntity = null
	for uid in main.entities:
		any_e = main.entities[uid]
		break
	if any_e:
		any_e.set_shield(true)
		# 标记有两种形态：护盾角标贴图（有素材）或「盾」字（素材缺失回退）
		var mark_ok := false
		if any_e._shield is Sprite3D:
			mark_ok = any_e._shield.texture != null
		elif any_e._shield is Label3D:
			mark_ok = any_e._shield.text == "盾"
		check(any_e._shield != null and any_e._shield.visible and mark_ok,
			"保护中的卡显示盾牌标记（永久）")
		any_e.set_shield(false)
		check(not any_e._shield.visible, "防御卡离组后盾牌标记隐藏")

	# --- 卡面标题字体自适应：任何卡名渲染宽度不得超出卡面（~1.15） ---
	var worst := 0.0
	var worst_name := ""
	for c in board.cards:
		var w: float = c.label.pixel_size * c.label.font_size * c.label.text.length()
		if w > worst:
			worst = w
			worst_name = c.label.text
	check(worst <= 1.15, "卡名最宽渲染 %.2f ≤ 1.15（最长卡名：%s）" % [worst, worst_name])

	# --- 结束面板要真的居中 ---
	# 检查真实屏幕坐标，不约束居中容器是否铺满窗口；长文案撑大后也应居中。
	main.state.winner = GameState.PLAYER
	main.state.win_reason = "测试"
	main._show_game_over()
	await process_frame
	await process_frame
	var panel: Control = main.game_over_panel
	check(panel != null, "结束面板建了出来")
	if panel != null:
		# 无头下 root.size 是 64×64，而界面按 content_scale_size 排版。
		var frame: Vector2 = Vector2(root.content_scale_size)
		check(panel.get_parent() is CenterContainer, "面板外面套着居中容器")
		check(Rect2(Vector2.ZERO, frame).encloses(panel.get_global_rect()),
			"结束面板完整落在屏幕内")
		var mid := panel.get_global_rect().get_center()
		var off := (mid - frame * 0.5).length()
		check(off < 1.0, "面板中心 %s 对上屏幕中心 %s（偏 %.1f）" % [str(mid), str(frame * 0.5), off])
		# 嘲讽话变长 → 面板撑大，仍要居中（KEEP_SIZE 版会在这里漂）
		panel.custom_minimum_size = Vector2(1000, 460)
		await process_frame
		await process_frame
		var mid2 := panel.get_global_rect().get_center()
		var off2 := (mid2 - frame * 0.5).length()
		check(off2 < 1.0, "撑大到 %s 后中心仍在正中（偏 %.1f）" % [str(panel.size), off2])
		# 重开一局要把整层 CanvasLayer 收掉，不能只放掉居中容器（否则每局漏一层）
		var layers0 := 0
		for ch in main.get_children():
			if ch is CanvasLayer:
				layers0 += 1
		main._on_restart()
		await process_frame
		await process_frame
		var layers1 := 0
		for ch in main.get_children():
			if ch is CanvasLayer:
				layers1 += 1
		check(layers1 == layers0 - 1,
			"重开一局收掉了那层 CanvasLayer（%d → %d）" % [layers0, layers1])

	finish()
