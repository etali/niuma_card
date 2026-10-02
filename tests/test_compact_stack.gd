# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 双击收拢测试：一摞牌在「摊开」（沿 z 铺，每张露标题带）
## 和「收拢」（沿 y 摞高，占地缩到单张卡）之间切换


func _initialize() -> void:
	print("=== 双击收拢测试 ===")
	var main: Node = await boot_main()
	var board: Board = main.board

	# 把桌面上其他玩家卡挪远，避免随机落位被吸附进来
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9101, "def_id": "shuabuting" }, Vector3(-1.0, 0.05, 3.0), true)
	var units: Array = _take(board, "user", 6)
	var recipe_n := int(CardDB.get_def(core.def_id)["recipe_n"])
	var progress := "%d/%d" % [units.size(), recipe_n]
	var empty_progress := "0/%d" % recipe_n
	# buff 卡要花钱买，开局牌堆里没有：直接造一张，否则取不到会连带后面全崩
	var buff: Array = [main._spawn_entity(
		{ "uid": 9102, "def_id": "tuisong" }, Vector3(-1.0, 0.05, 4.6), true)]
	check(units.size() == 6 and is_instance_valid(buff[0]), "取到 6 张用户卡 + 1 张 buff")
	_clear_field(board, [core] + units + buff)
	await physics_frame

	# 组内顺序刻意打乱：buff 摆最后、核心卡摆中间，验证收拢会把核心卡提到队首
	var members: Array = [units[0], units[1], core, units[2], units[3],
		units[4], units[5], buff[0]]
	for c in members:
		board._detach_from_group(c)
	var g: Dictionary = board.make_group(members)
	board.groups.append(g)
	board._layout_group(g)
	await create_timer(0.4).timeout
	for i in 10:
		await physics_frame

	check(not g.get("compact", false), "新组从摊开态起步")
	var spread := _extent(g)
	print("       摊开占地：z %.2f / y %.2f" % [spread.z, spread.y])

	# ---- 双击收拢 ----
	check(board.toggle_compact(core), "双击返回 true（真的切了）")
	check(g["compact"], "切到收拢态")
	await create_timer(0.4).timeout
	for i in 10:
		await physics_frame

	var comp := _extent(g)
	print("       收拢占地：z %.2f / y %.2f" % [comp.z, comp.y])
	check(comp.z < spread.z * 0.35,
		"占地明显变小（z %.2f < 摊开 %.2f 的 35%%）" % [comp.z, spread.z])
	check(comp.z <= CardEntity.CARD_SIZE.z,
		"收拢后 z 向不超单张卡长（%.2f ≤ %.2f）" % [comp.z, CardEntity.CARD_SIZE.z])
	check(comp.y > spread.y, "改为沿高度摞起来（y %.2f > 摊开 %.2f）" % [comp.y, spread.y])

	# 核心卡在第一张、buff 第二张，且「第一张」在收拢态是摞的最顶上（y 最大）
	check(g["cards"][0] == core, "核心卡排在第一张")
	check(g["cards"][1] == buff[0], "buff 卡排在第二张")
	var top: CardEntity = _highest(g)
	check(top == core, "核心卡在摞的最顶上（露脸的那张是它）")
	check(core.global_position.y > buff[0].global_position.y,
		"核心卡压在 buff 之上（%.3f > %.3f）" % [core.global_position.y, buff[0].global_position.y])

	# 整摞仍在同一处：x 全同、z 跨度极小
	var same_x := true
	for c in g["cards"]:
		if absf(c.global_position.x - core.global_position.x) > 0.01:
			same_x = false
	check(same_x, "收拢后整摞 x 对齐")

	# 桌上没有任何悬浮进度条（整组唯一的进度显示是核心卡 D 位墨团）
	check(not g.has("bar_bg") and not g.has("bar_fill"), "没有悬浮进度条")
	check(core.recipe_progress_text() == progress,
		"进度只在核心卡 D 位（6/N，实际 %s）" % core.recipe_progress_text())

	# ---- 侧边清单：收拢后摞里有什么全靠它 ----
	var spec := Board.side_spec(g["cards"])
	check(spec.size() == 2, "清单两行（用户 + buff），实际 %d" % spec.size())
	if spec.size() == 2:
		check(str(spec[0]["text"]) == "×6", "第一行 用户×6（实际 %s）" % spec[0]["text"])
		check(str(spec[1]["text"]) == "×1", "第二行 buff×1（实际 %s）" % spec[1]["text"])
	var side: Array = g.get("side", [])
	# 不铺衬底：这一列落在空桌面上，纯白硬边矩形跟任何卡都不搭，
	# 图标和数字各自带浅色描边就够托出来了
	check(side.size() == spec.size() * 2,
		"清单节点数 = 每行(图标+文字)，无衬底（%d）" % side.size())
	var plates := 0
	for nd in side:
		if nd is MeshInstance3D:
			plates += 1
	check(plates == 0, "清单里没有衬底方块（实际 %d 块）" % plates)
	# 清单贴在摞右侧、离桌高度压过摞顶
	var lb: Label3D = side[1] if side.size() > 1 else null
	if lb:
		check(lb.global_position.x > core.global_position.x + CardEntity.CARD_SIZE.x / 2.0,
			"清单在摞的右侧（%.2f > %.2f）" % [
				lb.global_position.x, core.global_position.x + CardEntity.CARD_SIZE.x / 2.0])
		check(lb.global_position.y > core.global_position.y,
			"清单压在摞顶之上（%.2f > %.2f）" % [lb.global_position.y, core.global_position.y])
		check(absf(lb.rotation_degrees.x + 90.0) < 0.01, "清单与桌面同平面（-90°）")
		# ×N 用常规字重：伪加粗是给十几像素的中文撑笔画的，
		# 半角数字在 1.3 倍下笔画并到一起，一缩就糊
		check(lb.font == Fonts.zh(), "×N 用常规字重（不伪加粗，免得糊）")
		check(lb.outline_size > 0 and lb.outline_size <= int(lb.font_size * 0.12),
			"×N 带浅色描边且不超字号 12%%（%d/%d）" % [lb.outline_size, lb.font_size])
	else:
		check(false, "清单生成了文字节点")

	# ---- 再双击摊开 ----
	check(board.toggle_compact(core), "再双击返回 true")
	check(not g["compact"], "切回摊开态")
	await create_timer(0.4).timeout
	for i in 10:
		await physics_frame
	var again := _extent(g)
	print("       摊开占地（第二次）：z %.2f / y %.2f" % [again.z, again.y])
	check(absf(again.z - spread.z) < 0.2, "摊开占地回到原样（%.2f ≈ %.2f）" % [again.z, spread.z])
	# 收拢时重排过顺序，摊开时不再动它一次：核心卡留在队首是稳定的
	check(g["cards"][0] == core, "摊开后顺序不再变动")

	# ---- 边界 ----
	var lone: Array = _take(board, "cash", 1)
	if lone.size() == 1:
		board._detach_from_group(lone[0])
		check(board.group_of(lone[0]) == null, "取到一张真正的散卡")
		check(not board.toggle_compact(lone[0]), "双击散卡无效（单张没有摞可言）")
	else:
		check(false, "取到一张散现金卡")
	if not main.market_cards.is_empty():
		check(not board.toggle_compact(main.market_cards[0]), "双击公共区卡无效")
	else:
		check(false, "公共区有卡")

	# 收拢态下拖走 = 整摞一起走（射线只打得到顶上那张，拆半截既点不准也看不出来）
	board.toggle_compact(core)
	await physics_frame
	var n: int = g["cards"].size()
	board._on_card_clicked(g["cards"][3])   # 故意点摞中间那张
	check(board._drag_cards.size() == n,
		"收拢态点任意一张 = 整摞一起拖（%d/%d）" % [board._drag_cards.size(), n])
	check(board._drag_compact, "拖拽途中记着这摞是收拢的")
	# 整摞拎起来时进度数字要跟着牌一起走。整摞被拎走那条路会把组字典从 groups
	# 摘掉（在手的牌不参与桌面上的组运算），但牌的集合一张没变、落桌就照原样重建 ——
	# 摘组时无条件把进度退回 0/N 的话，玩家看到的是「金色凑满高亮还亮着，
	# 进度却写着 0/N」，看着像组合被拎散了
	check(board.group_of(core) == null, "在手期间组字典确实摘掉了（这条是下一条的前提）")
	check(core.recipe_progress_text() == progress,
		"整摞拎在手上，进度还是 6/N（实际 %s）" % core.recipe_progress_text())
	# 拖拽途中层高不按 index 重算：收拢态 index 0 在顶上，重算会把核心卡翻到摞底
	board._process(0.016)
	var dragged: Array = board._drag_cards.duplicate()
	var top_in_hand := true
	for c in dragged:
		if c != core and c.global_position.y > core.global_position.y:
			top_in_hand = false
	check(top_in_hand, "拎在手上时核心卡仍在摞顶")

	# ---- 落桌：收拢态要撑过这次拖拽（这是本次改动的核心诉求） ----
	# 落到空地（远离其他卡与典当行/公共区），走「子组合落桌自成新组」那条分支
	for c in dragged:
		c.global_position = Vector3(-6.0, Board.DRAG_HEIGHT, 4.6)
	board._end_drag()
	await create_timer(0.4).timeout
	for i in 10:
		await physics_frame
	var ng: Variant = board.group_of(core)
	check(ng != null, "落桌后重新成组")
	if ng != null:
		check(ng.get("compact", false), "落桌后仍是收拢态（不会被拖拽摊开）")
		var moved := _extent(ng)
		print("       拖走后占地：z %.2f / y %.2f" % [moved.z, moved.y])
		check(moved.z <= CardEntity.CARD_SIZE.z,
			"占地仍是一张卡（z %.2f ≤ %.2f）" % [moved.z, CardEntity.CARD_SIZE.z])
		check(_highest(ng) == core, "核心卡仍在摞顶")
		check(ng.get("side", []).size() > 0, "侧边清单跟着摞一起搬过来了")
		check(core.recipe_progress_text() == progress,
			"落桌后进度仍是 6/N（实际 %s）" % core.recipe_progress_text())
		# 再双击才摊开
		check(board.toggle_compact(core), "落桌后仍能双击")
		check(not ng["compact"], "双击才摊开")
		await create_timer(0.4).timeout
		for i in 10:
			await physics_frame
		check(ng.get("side", []).is_empty(), "摊开后清单撤掉（每张卡自己露着标题带）")

	# ---- 反向的一条：强制中止拖拽（HUD 吃掉松手事件的兜底）不重建组 ----
	# 整摞拎起来时进度是跟着牌走的，可 cancel_drag 是把牌**散着**放回桌面、
	# 不重建组。那条路上留着数字就成了「不属于任何组的 6/N」，得退回 0/N
	if ng != null:
		# 组的大小现场读：落桌那下可能把附近的散卡吸进来（上面记的 n 已经过期）
		var n2: int = ng["cards"].size()
		board._on_card_clicked(ng["cards"][0])   # 摊开态点队首 = 整摞
		check(board._drag_cards.size() == n2,
			"摊开态点队首 = 整摞一起拖（%d/%d）" % [board._drag_cards.size(), n2])
		check(core.recipe_progress_text() == progress, "拎起来的一瞬进度还在（%s）" % core.recipe_progress_text())
		board.cancel_drag()
		await physics_frame
		check(board.group_of(core) == null, "强制中止后牌是散着的（没有组）")
		check(core.recipe_progress_text() == empty_progress,
			"没有组就不该留着进度数字，退回 0/N（实际 %s）" % core.recipe_progress_text())

	finish()

## 组的占地：z 向跨度与 y 向跨度（世界单位）
func _extent(g) -> Vector3:
	var zmin := INF
	var zmax := -INF
	var ymin := INF
	var ymax := -INF
	for c in g["cards"]:
		zmin = minf(zmin, c.global_position.z)
		zmax = maxf(zmax, c.global_position.z)
		ymin = minf(ymin, c.global_position.y)
		ymax = maxf(ymax, c.global_position.y)
	return Vector3(0, ymax - ymin, zmax - zmin)

## 摞得最高的那张（收拢态里露脸的就是它）
func _highest(g) -> CardEntity:
	var best: CardEntity = null
	for c in g["cards"]:
		if best == null or c.global_position.y > best.global_position.y:
			best = c
	return best

## 取 n 张指定 def_id 的玩家卡
func _take(board: Board, def_id: String, n: int) -> Array:
	var out: Array = []
	for c in board.cards:
		if out.size() >= n:
			break
		if is_instance_valid(c) and c.def_id == def_id and c.draggable and not c.is_market:
			out.append(c)
	return out

## 把不参与测试的玩家卡挪到远处，免得随机落位被吸附进组
func _clear_field(board: Board, keep: Array) -> void:
	var i := 0
	for c in board.cards:
		if not is_instance_valid(c) or c.is_market or not c.draggable or keep.has(c):
			continue
		board._detach_from_group(c)
		c.freeze = true
		c.global_position = Vector3(14.0 + (i % 5) * 1.5, 0.2, 9.0 + float(i / 5) * 2.0)
		i += 1
