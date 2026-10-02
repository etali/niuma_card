# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 散卡拖拽合并测试：两张散卡拖到一起能自动成组（Stacklands 式吸附）


func _initialize() -> void:
	print("=== 散卡拖拽合并测试 ===")
	var main: Node = await boot_main()

	var board: Board = main.board
	var cs: Array = main.state.players[GameState.PLAYER]["cards"]
	var e1: CardEntity = main.entities[cs[0]["uid"]]
	var e2: CardEntity = main.entities[cs[1]["uid"]]
	var e3: CardEntity = main.entities[cs[2]["uid"]]

	# 清场：其他玩家卡全部挪远，避免随机落位干扰吸附
	var idx := 0
	for c in cs:
		var e: CardEntity = main.entities[c["uid"]]
		if e == e1 or e == e2 or e == e3:
			continue
		e.freeze = true
		e.global_position = Vector3(12.0 + (idx % 5) * 1.5, 0.2, 8.0 + (idx / 5) * 2.0)
		idx += 1
	e3.freeze = true
	e3.global_position = Vector3(-8, 0.2, 8)

	# 两张卡摆近（间距 0.8，明显重叠范围）
	e1.freeze = true
	e1.global_position = Vector3(0, 0.2, 3.0)
	e2.global_position = Vector3(0.8, 0.2, 3.0)

	# 模拟：点住 e2 → 拖到 e1 旁边 → 松手
	board._on_card_clicked(e2)
	e2.global_position = Vector3(0.8, 0.2, 3.0)  # _on_card_clicked 后保持位置
	board._end_drag()
	await create_timer(0.4).timeout
	for i in 10:
		await physics_frame

	var merged := false
	for g in board.groups:
		if g["cards"].has(e1) and g["cards"].has(e2):
			merged = true
	check(merged, "两张散卡拖到一起自动成组")

	# 成组后竖直一条线：x 相同，z 递增，露出标题
	if merged:
		for g in board.groups:
			if g["cards"].has(e1) and g["cards"].has(e2):
				var a: Vector3 = g["cards"][0].global_position
				var b: Vector3 = g["cards"][1].global_position
				check(absf(a.x - b.x) < 0.01, "组内卡牌 x 对齐（一条直线）")
				check(absf(b.z - a.z - Board.STACK_GAP.z) < 0.05, "组内 z 间距 = 标题条间距")
				# y 间距必须盖得住卡面元素：小于 FACE_SPAN_Y 时，上面那张卡的底板
				# 比下面那张卡的卡名还低，压不住反被穿透（电脑玩家牌列曾整列漏字）
				check(b.y - a.y > CardEntity.FACE_SPAN_Y,
					"组内 y 间距 > 卡面元素跨度（%.3f > %.3f，压住下层标题）" \
						% [b.y - a.y, CardEntity.FACE_SPAN_Y])
				# 但也不能抬太高，否则一摞牌看着像楼梯而不是叠在桌上
				check(Board.STACK_GAP.y <= CardEntity.CARD_SIZE.y,
					"组内 y 间距 ≤ 单张牌厚（%.3f ≤ %.3f，仍像一摞牌）" \
						% [Board.STACK_GAP.y, CardEntity.CARD_SIZE.y])

	# 第三张卡拖到组的中间位置也能并入（不只认组顶）
	var g_target = null
	for g in board.groups:
		if g["cards"].has(e1):
			g_target = g
	if g_target:
		var mid: CardEntity = g_target["cards"][0]
		board._on_card_clicked(e3)
		e3.global_position = mid.global_position + Vector3(0.3, 0, 0.3)
		board._end_drag()
		await create_timer(0.4).timeout
		for i in 10:
			await physics_frame
		check(g_target["cards"].has(e3), "拖到牌列中间也能并入组")

	# --- 子堆拖拽：点中间卡 = 它 + 下方所有牌；点顶卡 = 整组 ---
	if g_target and g_target["cards"].size() == 3:
		board._on_card_clicked(e2)
		check(board._drag_cards.size() == 2 and board._drag_cards[0] == e2 and board._drag_cards[1] == e3,
			"点中间卡带出子组合（它 + 下方所有牌）")
		check(g_target["cards"].size() == 1 and g_target["cards"][0] == e1, "上方余牌留在原组")
		e2.global_position = Vector3(5, 0.3, 6.0)
		board._end_drag()
		await create_timer(0.2).timeout
		for i in 5:
			await physics_frame
		var sub_ok := false
		for g2 in board.groups:
			if g2["cards"].size() == 2 and g2["cards"].has(e2) and g2["cards"].has(e3):
				sub_ok = true
		check(sub_ok, "子组合落桌自成新组并保持堆叠")
		# e1 现在是单卡组：点它 = 整组拖走
		board._on_card_clicked(e1)
		check(board._drag_cards.size() == 1 and board._drag_cards[0] == e1, "点单卡组的顶牌 = 整组拖走")
		board._end_drag()
		await create_timer(0.2).timeout

		# --- 一摞组好的牌挪到单张散卡上：散卡并入这摞 ---
		e1.freeze = true
		e1.global_position = Vector3(-3, 0.2, 5.0)
		board._on_card_clicked(e2)   # 点子堆顶牌 = 拖走整摞 [e2,e3]
		check(board._drag_cards.size() == 2, "拖起整摞子堆（2 张）")
		e2.global_position = Vector3(-2.7, 0.2, 5.0)   # 摞到 e1 旁边（明显重叠）
		board._end_drag()
		await create_timer(0.2).timeout
		for i in 5:
			await physics_frame
		var merged3 := false
		for g3 in board.groups:
			if g3["cards"].has(e1) and g3["cards"].has(e2) and g3["cards"].has(e3):
				merged3 = true
		check(merged3, "整摞牌落到单张散卡上，散卡并入（3 张同组）")

	# --- 射线拾取：冻结的成组卡牌也能点到（_pick_card + 模拟点击） ---
	if g_target:
		var screen_pos: Vector2 = main.get_node("Camera3D").unproject_position(e1.global_position)
		var picked := board._pick_card(screen_pos)
		check(picked != null, "射线能拾取到成组冻结卡")
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = screen_pos
		board._unhandled_input(press)
		# 按下当场就把牌拎起来（手感：点了就得起来，不等双击窗口）。
		# 双击的第一击也会拎一次，由它的原地松手照 board._press_snap 精确复位，
		# 所以那一击对桌面是空操作 —— 见 board._restore_press
		check(board._drag_cards.size() >= 1, "点击成组卡牌可以开始拖拽（%d 张）" % board._drag_cards.size())
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		board._unhandled_input(release)
		await create_timer(0.2).timeout

	# --- 配方凑满：整条牌列金色高亮 + group_completed 信号 ---
	# 配方量读卡表，下面所有「几张 / 几分之几」都从它推：这一节量的是高亮和信号，
	# 吃几张是数值旋钮，写死等于每轮调参都要回来改十几处
	var core_def: Dictionary = CardDB.get_def("shuabuting")
	var need := int(core_def["recipe_n"])
	var full := need + 1                     # 核心 1 张 + 一份配方
	var half := need / 2                     # 半成品：凑一半，够写出「没满」
	check(half > 0 and half < need, "夹具前提：半成品 %d 张确实介于 0 和 %d 之间" % [half, need])
	var prod: Dictionary = main.state.add_card(GameState.PLAYER, "shuabuting")
	var e_prod: CardEntity = main._spawn_entity(prod, Vector3(-5, 0.3, 4.5), true)
	var combo_cards: Array = [e_prod]
	# 开局的散用户已被理牌成真实分组，这里新造一份干净的用户卡
	for k in need:
		var uc: Dictionary = main.state.add_card(GameState.PLAYER, "user")
		combo_cards.append(main._spawn_entity(uc, Vector3(-5, 0.3, 4.5), true))
	if combo_cards.size() == full:
		var fired := [false]
		board.group_completed.connect(func(): fired[0] = true)
		var cg = { "cards": combo_cards, "label": null }
		board.groups.append(cg)
		board.refresh_group(cg)
		check(fired[0], "配方凑满发出 group_completed 信号")
		var all_lit := true
		for cc in combo_cards:
			if not cc.highlighted:
				all_lit = false
		check(all_lit, "配方凑满整条牌列金色高亮")
		# 进度只写卡面 D 位：凑满 → N/N（组顶那条悬浮填充条已删）
		check(not cg.has("bar_fill"), "不生成组顶进度条")
		var txt_full := "%d/%d" % [need, need]
		check(e_prod.recipe_progress_text() == txt_full,
			"凑满时核心卡 D 位显示 %s（%s）" % [txt_full, e_prod.recipe_progress_text()])
		# 半成品 → D 位按已到位数量显示
		var prod2: Dictionary = main.state.add_card(GameState.PLAYER, "shuabuting")
		var e_prod2: CardEntity = main._spawn_entity(prod2, Vector3(6, 0.3, 4.5), true)
		var half_cards: Array = [e_prod2]
		for k in half:
			var uc: Dictionary = main.state.add_card(GameState.PLAYER, "user")
			half_cards.append(main._spawn_entity(uc, Vector3(6.5 + k * 0.3, 0.3, 5.2), true))
		if half_cards.size() == half + 1:
			var hg = { "cards": half_cards, "label": null }
			board.groups.append(hg)
			board.refresh_group(hg)
			var txt_half := "%d/%d" % [half, need]
			check(e_prod2.recipe_progress_text() == txt_half,
				"半成品核心卡 D 位显示 %s（%s）" % [txt_half, e_prod2.recipe_progress_text()])
		else:
			check(false, "凑齐第二组 %s+%d用户（实际 %d 张）" % [
				core_def["name"], half, half_cards.size()])
	else:
		check(false, "凑齐%s+%d用户（实际 %d 张）" % [core_def["name"], need, combo_cards.size()])

	# --- 双音效回归：一拖凑满配方时 card_stacked 只发一次且 completed=true，group_completed 只发一次 ---
	var prod3: Dictionary = main.state.add_card(GameState.PLAYER, "shuabuting")
	var e_prod3: CardEntity = main._spawn_entity(prod3, Vector3(-11, 0.3, 3), true)
	var five: Array = [e_prod3]
	for k in need - 1:      # 差一张凑满：下面那张就是「一拖凑满」的那一张
		var uc5: Dictionary = main.state.add_card(GameState.PLAYER, "user")
		five.append(main._spawn_entity(uc5, Vector3(-11, 0.3, 3), true))
	var g5 = { "cards": five, "label": null }
	board.groups.append(g5)
	board._layout_group(g5)
	board.refresh_group(g5)   # 差一张，未凑满
	check(not g5.get("was_valid", true), "%s+%d用户 未凑满（was_valid=false）" % [
		core_def["name"], need - 1])
	var last_uc: Dictionary = main.state.add_card(GameState.PLAYER, "user")
	var e_last: CardEntity = main._spawn_entity(last_uc, Vector3(0, 0.3, 7), true)
	var stack_events: Array = []
	var completed_count := [0]
	board.card_stacked.connect(func(c): stack_events.append(c))
	board.group_completed.connect(func(): completed_count[0] += 1)
	board._on_card_clicked(e_last)
	e_last.global_position = five[0].global_position + Vector3(0.3, 0, 0.3)
	board._end_drag()
	await create_timer(0.3).timeout
	for i in 5:
		await physics_frame
	check(stack_events.size() == 1, "一拖凑满时 card_stacked 只发一次（实际 %d 次）" % stack_events.size())
	if stack_events.size() == 1:
		check(stack_events[0] == true, "card_stacked 携带 completed=true（凑满音由 group_completed 播）")
	check(completed_count[0] == 1, "group_completed 只发一次（实际 %d 次）" % completed_count[0])

	# --- 误叮回归1：整体挪动已凑满的组合（拾起→落到空桌）不重复报叮 ---
	var ding1 := [0]
	board.group_completed.connect(func(): ding1[0] += 1)
	board._on_card_clicked(g5["cards"][0])   # 点顶牌 = 拖走整组
	check(board._drag_cards.size() == full, "点顶牌拖走整个已凑满组合")
	g5["cards"][0].global_position = Vector3(16, 0.3, 4)   # 空旷角落
	board._end_drag()
	await create_timer(0.3).timeout
	for i in 5:
		await physics_frame
	check(ding1[0] == 0, "挪动已凑满组合不再触发风铃双叮（实际 %d 次）" % ding1[0])
	var moved_g = null
	for g6 in board.groups:
		if g6["cards"].has(e_prod3):
			moved_g = g6
	check(moved_g != null and moved_g.get("was_valid", false) and moved_g["cards"].size() == full,
		"挪动后组合保持凑满状态（金色高亮不丢）")

	# --- 误叮回归2：购买/典当失败退回牌区，已凑满的一摞不误报叮 ---
	if moved_g:
		var ding2 := [0]
		board.group_completed.connect(func(): ding2[0] += 1)
		board._on_card_clicked(moved_g["cards"][0])   # 拖起整组（组被摘下，模拟购买失败时的状态）
		main._return_cards_to_player_zone(board._drag_cards.duplicate())
		board._drag_cards = []
		await create_timer(0.2).timeout
		for i in 5:
			await physics_frame
		check(ding2[0] == 0, "退回牌区不触发风铃双叮（实际 %d 次）" % ding2[0])

	# --- 单卡拖上组：发 card_stacked(false) 记账，声音走落桌那一声 ---
	var prod4: Dictionary = main.state.add_card(GameState.PLAYER, "shuabuting")
	var e_prod4: CardEntity = main._spawn_entity(prod4, Vector3(-14, 0.3, 3), true)
	var half2: Array = [e_prod4]
	for k in half:
		var uc6: Dictionary = main.state.add_card(GameState.PLAYER, "user")
		half2.append(main._spawn_entity(uc6, Vector3(-14, 0.3, 3), true))
	var g_half2 = { "cards": half2, "label": null }
	board.groups.append(g_half2)
	board._layout_group(g_half2)   # 半成品
	await create_timer(0.25).timeout
	for i in 3:
		await physics_frame
	var single_uc: Dictionary = main.state.add_card(GameState.PLAYER, "user")
	var e_single: CardEntity = main._spawn_entity(single_uc, Vector3(18, 0.3, 6), true)
	var stacks2: Array = []
	var drops2 := [0]
	board.card_stacked.connect(func(c): stacks2.append(c))
	board.card_dropped_table.connect(func(): drops2[0] += 1)
	board._on_card_clicked(e_single)
	e_single.global_position = half2[0].global_position + Vector3(0.3, 0, 0.3)   # 拖到半成品组上
	board._end_drag()
	await create_timer(0.3).timeout
	for i in 5:
		await physics_frame
	check(stacks2.size() == 1 and stacks2[0] == false,
		"单卡拖上半成品组发 card_stacked(false)（stacked=%s）" % str(stacks2))
	# 组合不单独发音：它永远伴随一次「拖到位松手」，落桌那一声已经交代了这个动作。
	# 咔哒（stack.wav）留给「摞」—— 双击收拢/摊开是玩家单独做的一个动作，
	# 由 pile_toggled 发（见 Board 的信号声明）
	check(drops2[0] == 1, "组合照发落桌声（drop=%d 次）" % drops2[0])
	var tog: Array = []
	board.pile_toggled.connect(func(): tog.append(true))
	var g_now: Variant = board.group_of(e_single)
	check(g_now != null and board.toggle_compact(e_single), "把这一组摞起来")
	check(tog.size() == 1, "摞牌发 pile_toggled（实际 %d 次）" % tog.size())
	var stacks_after: int = stacks2.size()
	board.toggle_compact(e_single)
	check(tog.size() == 2, "摊开回来也发 pile_toggled（实际 %d 次）" % tog.size())
	check(stacks2.size() == stacks_after,
		"摞牌不再借 card_stacked 发声（多发了 %d 次）" % [stacks2.size() - stacks_after])

	# --- 区域拦截：玩家卡不能放过购牌区（z<0.6 一律钳回边界） ---
	var bc: Dictionary = main.state.add_card(GameState.PLAYER, "cash")
	var e_bc: CardEntity = main._spawn_entity(bc, Vector3(0, 0.3, 4), true)
	board._on_card_clicked(e_bc)
	e_bc.global_position = Vector3(2, 0.3, -3.0)   # 拖到购牌区以北（避开货架卡位）
	board._end_drag()
	await create_timer(0.3).timeout
	for i in 5:
		await physics_frame
	check(e_bc.global_position.z >= -0.01, "越过购牌区的落点被钳回玩家区（z=%.2f，player_min_z=0.0）" % e_bc.global_position.z)

	# --- 同名升级组拆开：留下的那张不许还亮着 ---
	#
	# 只在同名组上看得见：升级组 2 张就成立（upgrade_dup_n 最小 2），
	# 配方组最少要 3 张（recipe_n 最小 2 + 核心），所以只有同名组会走
	# 「2 张金光亮着 → 1 张」这个转换，而 refresh_group 的 size()<2
	# 提前返回原先只退进度、不灭灯
	var up_a: Dictionary = main.state.add_card(GameState.PLAYER, "shuabuting")
	var up_b: Dictionary = main.state.add_card(GameState.PLAYER, "shuabuting")
	var e_ua: CardEntity = main._spawn_entity(up_a, Vector3(-8, 0.3, 5.5), true)
	var e_ub: CardEntity = main._spawn_entity(up_b, Vector3(-8, 0.3, 5.5), true)
	var ug = { "cards": [e_ua, e_ub], "label": null }
	board.groups.append(ug)
	board.refresh_group(ug)
	check(e_ua.highlighted and e_ub.highlighted, "同名×2 凑成升级组：两张都亮")
	board._detach_from_group(e_ub)
	check(not e_ub.highlighted, "抽走的那张灭灯")
	check(not e_ua.highlighted, "留下的那张也要灭灯（组已经不成立了）")

	await _drop_onto_flying_core(main, board)
	finish()

## 拖一摞资源到一张**正在飞**的组合卡上：组合卡不许被自己的补间拽走。
##
## 「有时候组合卡会消失」就是这一条。桌上写 CardEntity.position 的补间分属两处
## 登记：board._move_tw（编组重排、抬升）和 main 那侧的 fly_tw（买卡飞入
## main._move_to、产出飞入 _fly_from、理牌搬运 layout._move_to_spot）。
## board._stop_move 原先只看得见前者，于是并组时：
##   1) _group_origin 读到核心卡的**中间坐标**，整摞按那个坐标排好；
##   2) main 那条补间接着跑完，把核心卡一路搬去它自己的落点。
## 屏幕上就是核心卡不见了 —— 修之前实测它离组内第二张 0.89 远（一张卡宽还多）。
## 「有时候」正是那 0.3~0.35 秒的窗口：刚买到手、刚被理牌挪过、刚产出飞进来
##
## 判据取「核心卡和组里第二张的水平距离」而不是某个绝对坐标：并组之后
## 整摞落在哪儿不重要（玩家松手的位置、钳回边界都会改它），
## **整摞在一起**才是这一条要的东西
func _drop_onto_flying_core(main: Node, board: Board) -> void:
	var st: GameState = main.state
	# 清场：这一节要量「摞在不在一起」，别的牌落在附近会被 _nearest_group 吸走
	for c in st.players[GameState.PLAYER]["cards"]:
		var e: CardEntity = main.entities[c["uid"]]
		if is_instance_valid(e):
			e.freeze = true
			e.global_position = Vector3(20, 0.2, 20)
	var core: Dictionary = st.add_card(GameState.PLAYER, "shuabuting")
	# 摞几张单位卡是判据自己的规模：这一节量的是「并没并到一起」，配方满不满不参与
	var n_units := 4
	var units: Array = []
	for i in n_units:
		units.append(st.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER)))
	main._sync_entities()
	await settle()

	var ce: CardEntity = main.entities[core["uid"]]
	board._detach_from_group(ce)
	ce.freeze = true
	ce.global_position = Vector3(0, 0.2, 3.0)
	var ues: Array = []
	for i in units.size():
		var e: CardEntity = main.entities[units[i]["uid"]]
		board._detach_from_group(e)
		e.freeze = true
		e.global_position = Vector3(4.0, 0.2, 3.0 + i * 0.02)
		ues.append(e)
	var g := board.make_group(ues.duplicate(), true)
	board.groups.append(g)
	board._layout_group(g)
	await settle()

	# 核心卡起飞（= 刚买到手 / 刚被理牌搬走）。终点故意选得远：
	# 近了的话「被拽走」和「正常落位」量不出区别
	var away := Vector3(-6, 0.2, 6.0)
	main._move_to(ce, away)
	check(ce.has_meta("fly_tw"),
		"main._move_to 起飞时登记了补间（不登记 board 就掐不掉）")
	# 补间跑到**一半**时并上去：这是那个窗口。等它跑完再并就测不到东西了
	await create_timer(0.12).timeout
	check(not ce.global_position.is_equal_approx(away), "这会儿核心卡还在飞")

	board._on_card_clicked(ues[0])
	var anchor := ce.global_position
	for i in board._drag_cards.size():
		board._drag_cards[i].global_position = anchor + board._drag_offsets[i] \
			+ Vector3(0, Board.DRAG_HEIGHT, 0)
	board._end_drag()
	var gg: Variant = board.group_of(ce)
	check(gg != null, "资源摞并进了核心卡（组建起来了）")
	# 并组当帧核心卡就该被按到它的归宿上：整摞是按它的坐标起排的，
	# 那个坐标得是**它最终会在的地方**，不能是补间半路的中间值
	check(ce.global_position.is_equal_approx(away),
		"并组当帧核心卡被按到补间终点（%s，应为 %s）" % [ce.global_position, away])
	check(not ce.has_meta("fly_tw"), "并组时它的飞行补间被掐掉了")

	await settle()
	await create_timer(0.5).timeout
	gg = board.group_of(ce)
	check(gg != null and gg["cards"].size() == n_units + 1,
		"补间全跑完，摞里还是 %d 张" % (n_units + 1))
	if gg != null and gg["cards"].size() >= 2:
		var second: CardEntity = gg["cards"][1] if gg["cards"][0] == ce else gg["cards"][0]
		var d := Vector2(second.global_position.x - ce.global_position.x,
			second.global_position.z - ce.global_position.z).length()
		# 阈值卡在实测的两个数中间：修之前 0.89，修之后 0.05
		# （收拢摞的层间水平间距 COMPACT_GAP.z=0.05，所以修好的值就该是这个量级）。
		# **别按卡宽 1.3 定阈值**：脱队的那 0.89 还没到一张卡宽，1.0 的阈值
		# 会把 bug 值一起放过去 —— 判据得落在「好」和「坏」之间，
		# 不是落在「坏」的外面（实测：阈值 1.0 时把三个场景文件整体退回修复前，
		# 这一条照旧是绿的）
		check(d < 0.4,
			"核心卡没被自己的补间拽出摞（离组内第二张 %.2f，>0.4 就是脱队）" % d)
