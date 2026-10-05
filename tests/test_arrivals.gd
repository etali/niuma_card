# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 「到货就地摞好，不动桌上已有的布局」回归测试
##
## 典当和结算都不许走 _tidy_player_idle：它会先解散全部纯资源摞、再按锚点整片重排，
## 于是玩家典当一张卡、或者过一次结算，自己摆好的现金堆/用户堆就被洗了一遍位置 ——
## 桌面是玩家的记忆，不该被系统顺手重排。这两条路只管「刚出现的这几张」：
##   典当   —— 回收的现金摞在被当那张卡的原位（够 PILE_CHUNK 张才摞）
##   结算   —— 产出按每份 PILE_CHUNK 张摞好，摆到屏幕左侧，尽量不压场上的卡


func _initialize() -> void:
	print("=== 到货摞牌 / 布局不被重排 测试 ===")
	var main: Node = await boot_main()
	var board: Board = main.board

	# T3 先跑：它要验「左侧那一带找得到空位」，而典当两节会往桌上倒一百张现金，
	# 把左侧挤满 —— 那是测试环境的噪声，不是真实开局的样子
	await _t3_settle_stacks_left(main, board)
	await _t1_pawn_keeps_layout(main, board)
	await _t2_pawn_stacks_at_card_spot(main, board)
	await _t4_small_batch_not_stacked(main, board)
	await _t5_hover_shows_pawn_price(main, board)
	await _t6_real_settle_stacks(main, board)
	await _t7_tear_splits_card(main, board)
	await _t8_fly_from_combo(main, board)
	await _t9_left_side_is_cumulative(main, board)
	# T10/T11 各自 isolate 清空桌面（要看「新到这批落在哪」），所以放在最后
	await _t10_arrivals_land_in_band(main, board)
	await _t11_produce_uses_per_card_drop(main, board)
	await _t12_pawn_during_settle_flight(main, board)

	finish()

# ---------- T1. 典当不动桌上已有的布局 ----------

func _t1_pawn_keeps_layout(main: Node, board: Board) -> void:
	print("--- T1. 典当之后，场上原有的卡一张都没挪 ---")
	var state: GameState = main.state
	# 玩家自己摆的一摞（位置刻意选在锚点以外，理牌会把它搬走）
	var mine: Array = []
	for i in 4:
		var c: Dictionary = state.add_card(GameState.PLAYER, "cash")
		mine.append(main._spawn_entity(c, Vector3(0.0 + i * 0.1, 0.05, 3.4), true))
	for c in mine:
		board._detach_from_group(c)
	var g: Dictionary = board.make_group(mine.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var before := {}
	for uid in main.entities:
		if is_instance_valid(main.entities[uid]):
			before[uid] = main.entities[uid].global_position

	# 典当一张传说卡（pawn 值大，回收的现金够摞）
	var legend: Dictionary = state.add_card(GameState.PLAYER, "dujiaoshou")
	var le: CardEntity = main._spawn_entity(legend, Vector3(-2.0, 0.05, 2.6), true)
	await settle()
	before.erase(legend["uid"])   # 这张自己会被当掉，不算「原有布局」
	main.phase = main.PHASE_ACTION
	main._actor = GameState.PLAYER
	await main._on_dropped_on_pawn([le])
	await settle()

	var moved: Array = []
	for uid in before:
		if not main.entities.has(uid) or not is_instance_valid(main.entities[uid]):
			continue
		var d: float = main.entities[uid].global_position.distance_to(before[uid])
		if d > 0.05:
			moved.append("%d 挪了 %.2f" % [uid, d])
	check(moved.is_empty(), "典当前后场上原有的卡一张都没挪（%s）" % [
		"无" if moved.is_empty() else ", ".join(moved)])
	# 玩家自己那一摞还在，没被解散
	var still: Variant = board.group_of(mine[0])
	check(still != null and still["cards"].size() == 4,
		"玩家自己摆的 4 张摞没被解散（%d 张）" % [0 if still == null else still["cards"].size()])

# ---------- T2. 典当所得摞在被当那张卡的原位 ----------

func _t2_pawn_stacks_at_card_spot(main: Node, board: Board) -> void:
	print("--- T2. 典当回收 > 10 → 摞成一组，落在被当那张卡的位置 ---")
	var state: GameState = main.state
	# z 取在 1.23~3.98 之间：50 张摞纵深 2.45，摞的中心对到这一带时
	# board 给玩家卡的钳制（player_min_z=0 / player_max_z=5.2）两头都不生效。
	# 种在 4.2 那种贴边的位置上，钳制会把不同的算法压成同一个结果，测不出对错
	var spot := Vector3(6.5, 0.05, 2.6)
	var legend: Dictionary = state.add_card(GameState.PLAYER, "dujiaoshou")
	var le: CardEntity = main._spawn_entity(legend, spot, true)
	await settle()
	var pawn_n := CardDB.pawn_value("dujiaoshou")
	check(pawn_n >= main.PILE_CHUNK, "独角兽（dujiaoshou）典当价 %d ≥ %d，够摞一摞" % [pawn_n, main.PILE_CHUNK])
	var cash_before := int(state.resource_count(GameState.PLAYER, CardDB.RES_CASH))
	# 只认这一次新建的摞：T1 也典当过一张，桌上已经有一摞同样 50 张的现金
	var old_groups: Array = board.groups.duplicate()

	main.phase = main.PHASE_ACTION
	main._actor = GameState.PLAYER
	await main._on_dropped_on_pawn([le])
	await settle()
	var gained := int(state.resource_count(GameState.PLAYER, CardDB.RES_CASH)) - cash_before
	check(gained == pawn_n, "现金 +%d（实际 +%d）" % [pawn_n, gained])

	# 回收的现金成了一个收拢摞，摞的位置在被当那张卡的原位附近
	var found: Dictionary = {}
	for gg in board.groups:
		var seen := false
		for og in old_groups:
			if is_same(gg, og):
				seen = true
				break
		if not seen and gg["cards"].size() == gained and gg.get("compact", false):
			found = gg
			break
	check(not found.is_empty(), "%d 张现金摞成了一个收拢组（board.groups 里找得到）" % gained)
	if found.is_empty():
		return
	# 量的是摞的中心对不对得上原位，不是第一张卡：50 张收拢摞纵深 2.45，
	# 把第一张钉在原位的话整摞会往玩家身前压出去一大截，看着就不在那张卡的地方了
	var origin: Vector3 = board._group_origin(found)
	var center := origin + Vector3(0, 0, main.layout.COMPACT_SPAN * (gained - 1) / 2.0)
	var d := Vector2(center.x - spot.x, center.z - spot.z).length()
	check(d < 0.9, "摞的中心就在被当那张卡的原位（差 %.2f 格）" % d)
	check(found.get("compact", false), "直接是收拢态，不用玩家再双击一次")

# ---------- T3. 结算产出摞到屏幕左侧 ----------

func _t3_settle_stacks_left(main: Node, board: Board) -> void:
	print("--- T3. 结算产出 > 10 → 按每份 10 张摞好，摆在屏幕左侧 ---")
	var state: GameState = main.state
	# 场上先摆一摞玩家自己的牌，位置压在左侧那一带：验「尽量不重叠」
	var mine: Array = []
	for i in 3:
		var c: Dictionary = state.add_card(GameState.PLAYER, "user")
		mine.append(main._spawn_entity(c, main.layout.SETTLE_CASH_ANCHOR + Vector3(0, 0, 0.1), true))
	for c in mine:
		board._detach_from_group(c)
	var gm: Dictionary = board.make_group(mine.duplicate())
	board.groups.append(gm)
	board._layout_group(gm, main.layout.SETTLE_CASH_ANCHOR)
	await settle()
	var mine_pos: Array = mine.map(func(e): return e.global_position)

	# 造 25 张「本回合产出」：走 _stack_settled 的真实入口（known 之外的都算新到）
	var known := {}
	for uid in main.entities:
		known[uid] = true
	# 只看这一次新建的摞：桌上还留着前面几节典当出来的摞，一起数就分不清了
	var old_groups: Array = board.groups.duplicate()
	# 摆之前场上所有卡的位置：既用来数空位，也用来查有没有压到旧卡
	var before_pos: Array = []
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e) and not e.is_market and e.draggable:
			before_pos.append(e.global_position)
	# 张数从 PILE_CHUNK 推：要「两个整份 + 一个凑不满的余数」，一次同时验分组和余数。
	# 半份余数是刻意的 —— 取 1 张的话余数只有一张，「余数不摞」和「余数摆得开」
	# 两件事分不出来
	var t3_n: int = main.PILE_CHUNK * 2 + main.PILE_CHUNK / 2
	for i in t3_n:
		state.add_card(GameState.PLAYER, "cash")
	main._sync_entities()
	await settle()
	main.layout._stack_settled(known)
	await settle()
	var made: Array = []
	for gg in board.groups:
		var seen := false
		for og in old_groups:
			# Dictionary 的 == 是逐键深比较，两摞同尺寸就可能相等 —— 认身份得用 is_same
			if is_same(gg, og):
				seen = true
				break
		if not seen:
			made.append(gg)

	# t3_n 张按每份 PILE_CHUNK 摞成几个整份，凑不满的余数不摞（见 _stack_settled）
	made = _piles_only(made)
	var sizes: Array = []
	for gg in made:
		sizes.append(int(gg["cards"].size()))
	sizes.sort()
	var t3_want: Array = []
	for i in t3_n / main.PILE_CHUNK:
		t3_want.append(main.PILE_CHUNK)
	check(sizes == t3_want,
		"%d 张产出摞成 %s、余 %d 张不摞（实际 %s）" % [
			t3_n, str(t3_want), t3_n % main.PILE_CHUNK, str(sizes)])
	# 余数「不摞」= 不替玩家收拢，但仍按列成一组：同一列里前后两张占地重叠
	# （步长 0.52 < 卡纵深 1.7），不成组就没有 y 台阶，下面那张的图标会从
	# 上面那张的底板里穿出来；而且散着的牌双击也摞不起来（toggle_compact 只认组）
	var rest_g: Array = []
	for gg in board.groups:
		if gg.get("settle_rest", false):
			rest_g.append(gg)
	check(not rest_g.is_empty(), "余下的 5 张按列成了组（余数组 %d 个）" % rest_g.size())
	var not_spread: Array = []
	for gg in rest_g:
		if gg.get("compact", false):
			not_spread.append(str(gg["cards"].size()))
	check(not_spread.is_empty(), "余数组是摊开态、每张露标题带（被收拢的 %s）" % [
		"无" if not_spread.is_empty() else ", ".join(not_spread)])

	# 都在屏幕左侧，但也不能滑出画面：真窗口实测 x=-11.7 那一列的卡左缘落在屏幕 x=30
	# （1600 宽），再往左一列（-13.1）近端就出画了。这条守栏管住「越挪越左」
	var right: Array = []
	var off: Array = []
	for gg in made:
		var o: Vector3 = board._group_origin(gg)
		if o.x > -6.0:
			right.append("%.1f" % o.x)
		if o.x - CardEntity.CARD_SIZE.x / 2.0 < -12.4:
			off.append("%.1f" % o.x)
	check(right.is_empty(), "产出的摞都在屏幕左侧（x ≤ -6，越界的 %s）" % [
		"无" if right.is_empty() else ", ".join(right)])
	check(off.is_empty(), "产出的摞没滑出画面左缘（左缘 ≥ -12.4，越界的 %s）" % [
		"无" if off.is_empty() else ", ".join(off)])

	# 玩家原有那一摞没被挪走，且新摞没压在它头上
	var untouched := true
	for i in mine.size():
		if mine[i].global_position.distance_to(mine_pos[i]) > 0.05:
			untouched = false
	check(untouched, "结算前后玩家自己那一摞没挪窝")
	# 压没压到旧卡：判定框按真实卡尺寸（CardEntity.CARD_SIZE），
	# 不是随手取的小框 —— 框比卡窄的话，明明压着也判成不重叠
	var overlap: Array = []
	for gg in made:
		var pr := _pile_rect(board, gg)
		for p in before_pos:
			if pr.intersects(_card_rect(p)):
				overlap.append("(%.1f,%.1f)" % [pr.position.x, pr.position.y])
				break
	# 「尽可能不重叠」是尽力而为：左侧那条带子只有 x∈[-11.7,-8.9] 三列、z∈[0,4.7] 这么大
	# （再往右是玩家的现金堆，再往上过购牌区 board 会把卡钳回来），
	# 摆得下几摞就是几摞。所以断言的是「空位没被浪费」：
	# 重叠的摞数不能超过「摞数 − 当时的空位数」
	var slots := _clean_slots(main, board, before_pos)
	var allow: int = maxi(0, made.size() - slots)
	check(overlap.size() <= allow,
		"空位没被浪费：%d 摞 / %d 个干净空位 → 最多 %d 摞重叠（实际 %d：%s）" % [
			made.size(), slots, allow, overlap.size(),
			"无" if overlap.is_empty() else ", ".join(overlap)])
	# 新摞彼此也不能压：三摞叠一处就等于只看得见一摞。
	# 这里按「摞真正占的那块地」算，不借用被测代码的 PILE_TAKE_CLEAR_Z ——
	# 判据一旦读被测常量，改坏那个常量会把代码和判据一起改掉，测试就抓不住了
	var self_clash: Array = []
	for i in made.size():
		for j in range(i + 1, made.size()):
			var ra := _pile_rect(board, made[i])
			var rb := _pile_rect(board, made[j])
			if ra.intersects(rb):
				self_clash.append("(%.1f,%.1f %.1f×%.1f)×(%.1f,%.1f %.1f×%.1f)" % [
					ra.position.x, ra.position.y, ra.size.x, ra.size.y,
					rb.position.x, rb.position.y, rb.size.x, rb.size.y])
	check(self_clash.is_empty(), "三摞之间也没叠在一起（%s）" % [
		"都够开" if self_clash.is_empty() else ", ".join(self_clash)])

## 一个收拢摞在桌面（x-z 平面）上真正占的矩形。
## 摞从第一张往 +z 长，n 张的纵深是 COMPACT_GAP.z×(n−1)，
## 再各往两头加半张卡（半张按 CardEntity.CARD_SIZE 算）
## 单张卡在桌面上占的矩形
func _card_rect(p: Vector3) -> Rect2:
	return Rect2(p.x - CardEntity.CARD_SIZE.x / 2.0, p.z - CardEntity.CARD_SIZE.z / 2.0,
		CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z)

func _pile_rect(board: Board, g: Dictionary) -> Rect2:
	var o: Vector3 = board._group_origin(g)
	var span: float = Board.COMPACT_GAP.z * (g["cards"].size() - 1)
	var w: float = CardEntity.CARD_SIZE.x
	var h: float = CardEntity.CARD_SIZE.z + span
	return Rect2(o.x - w / 2.0, o.z - CardEntity.CARD_SIZE.z / 2.0, w, h)

## 摆之前左侧那条带子里能塞下几个互不重叠的整份摞（摞的占地按真实几何算，
## 不读被测代码的避让常量：借用它的话，把常量改坏会连判据一起改掉）。
## 贪心数：沿 z 走，遇到放得下的地方就占住，跳过整个摞身，继续
const SLOT_STEP := 0.3
func _clean_slots(main: Node, _board: Board, blockers: Array) -> int:
	# 一个整份收拢摞的占地：CARD_SIZE.x 宽 × (CARD_SIZE.z + COMPACT_GAP.z×(份量−1)) 深
	var span: float = Board.COMPACT_GAP.z * (main.PILE_CHUNK - 1)
	var h: float = CardEntity.CARD_SIZE.z + span
	var n := 0
	var used: Array = []
	for col in main.layout.PILE_SLOT_COLS:
		var x: float = main.layout.SETTLE_CASH_ANCHOR.x + col * main.layout.PILE_SLOT_X_STEP
		var z: float = main.layout.PILE_SLOT_Z_MIN
		while z <= main.layout.PILE_SLOT_Z_MAX:
			var r := Rect2(x - CardEntity.CARD_SIZE.x / 2.0,
				z - CardEntity.CARD_SIZE.z / 2.0, CardEntity.CARD_SIZE.x, h)
			var ok := true
			for p in blockers:
				if r.intersects(_card_rect(p)):
					ok = false
					break
			if ok:
				for u in used:
					if r.intersects(u):
						ok = false
						break
			if ok:
				n += 1
				used.append(r)
				z += h
			else:
				z += SLOT_STEP
	return n

# ---------- T4. 少量到货不摞 ----------

## 两三张现金摆成「一摞」，玩家还得双击展开才看得见是什么，反而更难认
func _t4_small_batch_not_stacked(main: Node, board: Board) -> void:
	print("--- T4. 到货不足 %d 张：摆开不摞 ---" % main.PILE_CHUNK)
	var state: GameState = main.state
	var fresh: Array = []
	for i in 3:
		var c: Dictionary = state.add_card(GameState.PLAYER, "cash")
		fresh.append(main._spawn_entity(c, Vector3(2.0, 0.05, 4.6), true))
	await settle()
	var made: Array = main.layout._stack_arrivals(fresh, Vector3(2.0, 0.05, 4.6))
	await settle()
	check(made.is_empty(), "没建出摞（实际建了 %d 个）" % made.size())
	# 「不摞」= 不替玩家收拢，但三张仍成一个摊开的组：
	# 它们沿 z 的间距（0.52）远小于卡纵深（1.7），占地是重叠的 ——
	# 不成组就没有 y 台阶，后面那张的图标从前面那张的底板里穿出来
	var compacted := 0
	var ungrouped := 0
	for c in fresh:
		var g: Variant = board.group_of(c)
		if g == null:
			ungrouped += 1
		elif g.get("compact", false):
			compacted += 1
	check(ungrouped == 0, "三张都进了组（散着的 %d 张）" % ungrouped)
	check(compacted == 0, "但没被收拢成摞（收拢了 %d 张）" % compacted)
	# 玩家自己要摞得起来：散着的牌双击是白点（toggle_compact 只认组里的牌）
	check(board.toggle_compact(fresh[0]), "双击能把这三张摞起来")
	check(board.toggle_compact(fresh[0]), "再双击摊开回来")
	# 每张都得认得出是什么，也就是至少露出自己的标题带。
	# 门槛从标题带的高度反算（BAND_FRAC × 卡纵深），不读被测的那个步长常量
	# （Board.STACK_GAP.z）—— 拿被测值当判据的话，步长改成 0 也照样绿
	var band: float = CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z
	var clash: Array = []
	for i in fresh.size():
		for j in range(i + 1, fresh.size()):
			var d := Vector2(
				fresh[i].global_position.x - fresh[j].global_position.x,
				fresh[i].global_position.z - fresh[j].global_position.z).length()
			if d < band:
				clash.append("%.2f" % d)
	check(clash.is_empty(),
		"三张各自都露出标题带（≥%.2f，盖住的间距 %s）" % [
			band, "无" if clash.is_empty() else ", ".join(clash)])
	# 也不能全落在同一点上：上面那条只管相邻两张，一点重合要单独钉
	var spots := {}
	for c in fresh:
		spots["%.2f,%.2f" % [c.global_position.x, c.global_position.z]] = true
	check(spots.size() == fresh.size(),
		"三张落在三个不同的位置（实际 %d 个）" % spots.size())

# ---------- T5. 悬停白板上带典当价 ----------

## 典当是「要不要现在出手」的即时判断，价格和效果得在同一块白板上才比得出来。
## 每张卡都要带，不只传说卡：缺这一行就只能拖过去试
func _t5_hover_shows_pawn_price(main: Node, board: Board) -> void:
	print("--- T5. 悬停白板：效果 + 典当价 ---")
	var t_prod := board.hover_desc_text("yunketang")
	check(t_prod.contains("典当"), "组合卡的白板上有典当价（%s）" % t_prod.replace("\n", " / "))
	check(t_prod.contains("→"), "效果描述还在（没被典当价挤掉）")
	var pv := CardDB.pawn_value("yunketang")
	check(t_prod.contains("+%d" % pv), "写的是 pawn_value 算出的 %d" % pv)

	var t_legend := board.hover_desc_text("dujiaoshou")
	check(t_legend.contains("典当 +%d" % CardDB.pawn_value("dujiaoshou")),
		"传说卡的典当价也走同一条（%s）" % t_legend.replace("\n", " / "))
	check(t_legend.count("典当") == 1,
		"传说卡不再重复写两遍典当（%s）" % t_legend.replace("\n", " / "))

	# 现金卡不可典当：不写「+0」
	var t_cash := board.hover_desc_text("cash")
	check(not t_cash.contains("典当"), "现金卡不写典当（%s）" % t_cash.replace("\n", " / "))

# ---------- T6. 走真实回合结束（_run_settle），不是直接调 _stack_settled ----------

## T3 自己控制 known 的时机（先记 known 再加卡），所以它测不出真实顺序。
## 真实路径里 _resolve_combo_visual 每演完一组就自己调一次 _sync_entities()，
## 产出的卡在演出途中就已经有实体了 —— known 记晚一步（比如记在演出循环之后），
## 本回合全部产出都会被当成「原有的卡」跳过，结果一张都不摞。
## 这一节就钉住这个顺序：必须走 _run_settle 才算数
func _t6_real_settle_stacks(main: Node, board: Board) -> void:
	print("--- T6. 真实回合结束：产出按每份 %d 张摞好 ---" % main.PILE_CHUNK)
	var state: GameState = main.state
	# 先把「已分胜负」这个标记摘掉：前面几节为了验摞给玩家堆了一百多张现金，
	# 早就过了 `_game.win_cash` 那条胜利线。winner 一旦定下来，结算意图会被
	# IntentApply 的 game_over 护栏挡掉（只放 finalize 过），一张产出都不会有 ——
	# 真实回合结束本来就只发生在未分胜负的局面上，这里补齐这个前提。
	# **只摘标记，不动牌**：后面 T9 数的是左侧累计张数，删牌会把它的输入一起改掉。
	# finalize 里还会再判一次胜负，摘掉不影响它把这局重新判成玩家赢
	state.winner = ""
	state.win_reason = ""

	# 挑信息茧房：它的 output_n 跨过 PILE_CHUNK，一次能同时验分组和余数
	var ld: Dictionary = CardDB.get_def("xinxijianfang")
	var members: Array = [state.add_card(GameState.PLAYER, "xinxijianfang")["uid"]]
	var unit := "cash" if str(ld.get("recipe_res")) == CardDB.RES_CASH else "user"
	for i in int(ld.get("recipe_n")):
		members.append(state.add_card(GameState.PLAYER, unit)["uid"])
	main._sync_entities()
	await settle()
	# 引擎认的是 state.combos（board.groups 只管摆放），得走 create_combo 登记
	var reg: Dictionary = state.create_combo(GameState.PLAYER, members)
	check(reg.get("ok", false), "组合登记成功（%s）" % str(reg.get("reason", "")))
	if not reg.get("ok", false):
		return

	var groups_before: Array = board.groups.duplicate()
	var n_before: int = state.players[GameState.PLAYER]["cards"].size()
	var loose_before := _loose_cash_left(main, board)
	await main._run_settle()
	# 结算里有若干 timer（开场 0.6 + 每组 0.5/0.7 + 收尾 0.5），等够再看
	for i in 240:
		await physics_frame

	# 产出结算是净增：配方卡不被吃掉（只是 locked 一回合），所以正好 +output_n
	var gained: int = state.players[GameState.PLAYER]["cards"].size() - n_before
	check(gained == int(ld.get("output_n")),
		"净增 %d 张现金（实际 %+d）" % [int(ld.get("output_n")), gained])

	var made: Array = []
	for gg in board.groups:
		var seen := false
		for og in groups_before:
			if is_same(gg, og):
				seen = true
				break
		if not seen:
			made.append(gg)
	# 余数组也在 made 里（按列成组，见 _place_loose_col），但它不是「摞」：
	# 摞的口径是收拢态，先滤出来再数
	var rests: Array = []
	for gg in made:
		if not gg.get("compact", false):
			rests.append(gg)
	made = _piles_only(made)
	var sizes: Array = []
	for gg in made:
		sizes.append(int(gg["cards"].size()))
	sizes.sort()
	# 产出与左侧已有散牌一起按每份 PILE_CHUNK 摞，余数不收拢。
	# 一摞都没有就是 known 记晚了：那时候新卡被算成「原有的卡」，池子是空的
	var t6_n: int = loose_before + int(ld.get("output_n"))
	var t6_want: Array = []
	for i in t6_n / main.PILE_CHUNK:
		t6_want.append(main.PILE_CHUNK)
	var t6_rest: int = t6_n % main.PILE_CHUNK
	check(sizes == t6_want,
		"累计 %d 张现金摞成 %s、余 %d 张不摞（实际 %s）" % [
			t6_n, str(t6_want), t6_rest, str(sizes)])
	check(t6_rest == 0 or not rests.is_empty(),
		"余下那 %d 张按列成了组（余数组 %d 个）" % [t6_rest, rests.size()])
	check(_loose_cash_left(main, board) == t6_rest, "现金余数与累计张数的取模一致")
	# 都摆在屏幕左侧那条结算带里。这里不钉「必须在现金列」：T6 排在 T1/T2/T4
	# 之后跑，那几节往桌上倒了上百张现金把左侧挤满，溢出到共用列是对的行为
	# （列的先后只是优先级，空列永远赢过占着的格子，见 SETTLE_CASH_COLS）。
	# 「现金一列、用户一列」在干净桌面上的表现由 T3 那一节钉
	var off: Array = []
	for gg in made:
		var o: Vector3 = board._group_origin(gg)
		if o.x > main.layout.SETTLE_SPILL_X + 0.1:
			off.append("%.1f" % o.x)
	check(off.is_empty(), "都在左侧结算带里（x ≤ %.1f，跑偏的 %s）" % [
		main.layout.SETTLE_SPILL_X, "无" if off.is_empty() else ", ".join(off)])

# ---------- T7. 受击的卡从中间撕开再淡掉，不翻面不放泡沫 ----------

## 钉三件事：撕成两片、两片朝相反方向分开、淡出和位移同时收尾。
## 第三条是真踩过的坑：淡出补间当初延迟 0.35×TEAR_TIME 却还是整段时长，
## 收尾拖到 1.35 倍，两片飞停了还满不透明挂在桌上，最后一下才闪掉。
func _t7_tear_splits_card(main: Node, board: Board) -> void:
	print("--- T7. 受击：从中间撕开再渐变消失 ---")
	var state: GameState = main.state
	var victim: Dictionary = state.add_card(GameState.PLAYER, "cash")
	main._sync_entities()
	await settle()
	var e: CardEntity = main.entities.get(victim["uid"])
	check(is_instance_valid(e), "拿到受击的卡")
	if not is_instance_valid(e):
		return

	var kids_before: int = e.get_child_count()
	main.entities.erase(e.uid)
	# 捕获真实撕牌 Tween，后面直接 custom_step 驱动动画进度。
	# 墙钟 create_timer 会受 headless 负载和 TEST_SPEED 影响，可能在 Tween
	# 只走了一小段时就触发判据，误报中间态和回收时机。
	var tweens_before: Array = get_processed_tweens()
	main._tear_out(e, Vector3(0, 0, 1.0))
	var tear_tween: Tween = null
	for tw: Tween in get_processed_tweens():
		if tw not in tweens_before and tw.is_valid():
			tear_tween = tw
			break
	check(tear_tween != null, "捕获到真实撕牌补间")
	if tear_tween == null:
		return
	tear_tween.pause()
	if not is_instance_valid(e):
		check(false, "撕开后卡就没了（应该先演完 %.2fs）" % main.TEAR_TIME)
		return

	# 两片是 Node3D 容器，半卡网格挂在里面（这样文字能改挂到片上而不跟网格的
	# -90° 旋转打架）
	var halves: Array = []
	for n in e.get_children():
		var m: ShaderMaterial = _half_mat(n)
		if m != null and m.get_shader_parameter("side") != null:
			halves.append(n)
	check(halves.size() == 2, "撕成两片（实际 %d 片，子节点由 %d 个变 %d 个）" % [
		halves.size(), kids_before, e.get_child_count()])
	if halves.size() != 2:
		return
	var sides: Array = []
	for h in halves:
		sides.append(float(_half_mat(h).get_shader_parameter("side")))
	sides.sort()
	check(sides == [-1.0, 1.0], "两片一上一下（side=%s）" % str(sides))
	# 撕的是这张卡本身，不是空模板：图标得合成进撕开着色器里跟着撕
	var icons := 0
	for h in halves:
		if float(_half_mat(h).get_shader_parameter("has_icon")) > 0.5:
			icons += 1
	check(icons == 2, "两片都带着卡自己的图标（实际 %d 片有）" % icons)
	# 不翻面：卡背材质不该被装上（翻面是典当/买卡的「离场」语汇）
	check(not e._face_down, "没有翻面")

	# 演到 60% 时：两片必须已经朝相反方向分开，且都在淡出途中
	#
	# Tween 由测试直接推进到 60%，避免把动画进度误当成墙钟时间。
	# 这里掐时刻是**两头都有边**的（fade 要在 0.02 和 0.9 之间）：
	# 判据验证的是确实经过某个中间态，不是等待某个固定墙钟时长。
	tear_tween.custom_step(main.TEAR_TIME * 0.6)
	if not is_instance_valid(e) or not is_instance_valid(halves[0]):
		check(false, "演到 60% 片就没了")
		return
	# 撕口是横的（沿卡面 UV.y），所以两片分开量的是 z，翻的是 x 轴
	var zs: Array = []
	var xs: Array = []
	var tilts: Array = []
	var fades: Array = []
	for h in halves:
		zs.append(h.position.z)
		xs.append(h.position.x)
		tilts.append(h.rotation_degrees.x)
		fades.append(float(_half_mat(h).get_shader_parameter("fade")))
	var spread: float = absf(zs[0] - zs[1])
	check(spread > 0.3, "60%% 时两片沿 z 分开 %.2f（>0.3）" % spread)
	var side_slip: float = absf(xs[0] - xs[1])
	check(side_slip < 0.05, "两片没往左右跑（x 差 %.3f，<0.05）" % side_slip)
	check(absf(tilts[0] - tilts[1]) > 10.0,
		"两片绕 x 轴反向翻起（%.1f° / %.1f°）" % [tilts[0], tilts[1]])
	var max_fade: float = maxf(fades[0], fades[1])
	check(max_fade < 0.9, "60%% 时已经在淡出（fade=%.2f，<0.9）" % max_fade)
	check(max_fade > 0.02, "60%% 时还没淡光（fade=%.2f，>0.02）" % max_fade)

	# 位移和淡出要一起收尾：再推进剩余 40%，Tween 回调应立即回收卡。
	tear_tween.custom_step(main.TEAR_TIME * 0.4 + 0.001)
	check(is_instance_valid(e) and e.is_queued_for_deletion(), "撕牌补间完成立即排队回收")
	await process_frame
	check(not is_instance_valid(e), "演完 %.2fs 后卡被回收" % main.TEAR_TIME)

## 撕出来的片：Node3D 容器 → 第一个子节点是半卡网格 → 它的 material_override
func _half_mat(n: Node) -> ShaderMaterial:
	if not (n is Node3D) or n.get_child_count() == 0:
		return null
	var mesh = n.get_child(0)
	if not (mesh is MeshInstance3D):
		return null
	return mesh.material_override as ShaderMaterial

# ---------- T8. 结算产出从组合位置飞出来，不是凭空出现 ----------

## 判据是「刚生出来那一帧在哪」而不是「最后落在哪」：落点是摞牌管的，
## 凭空产生的话首帧就已经在屏幕左边的落点上了。
## 顺带钉飞入补间和摞牌不打架 —— 摞牌走 _layout_group 直接赋坐标，
## 没跑完的补间会逐帧把卡拉回组合那边（实测能把整摞拖偏 8.8）
func _t8_fly_from_combo(main: Node, board: Board) -> void:
	print("--- T8. 结算产出从组合飞出来 ---")
	var state: GameState = main.state
	var known := {}
	for uid in main.entities:
		known[uid] = true
	var fresh: Array = []
	for i in 14:
		fresh.append(state.add_card(GameState.PLAYER, "cash")["uid"])
	# 故意选桌子右边：离结算落点（x≈-11.7）够远，首帧偏哪边一目了然
	var center := Vector3(3.0, 0.05, 2.0)
	main._sync_entities(center)
	# spawn与起点赋值同步完成；在让出当前帧前检查真正的出生位置。
	# 等physics_frame会让首张无延迟Tween先推进，机器负载/时间加速能把它推过中线。

	var near_combo := 0
	var flying := 0
	var original_flights := {}
	for uid in fresh:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		var d_combo := Vector2(e.position.x - center.x, e.position.z - center.z).length()
		var d_settle: float = absf(e.position.x - main.layout.SETTLE_CASH_ANCHOR.x)
		if d_combo < d_settle:
			near_combo += 1
		if e.has_meta("fly_tw"):
			flying += 1
			original_flights[uid] = e.get_meta("fly_tw")
	check(near_combo == fresh.size(),
		"%d 张产出首帧都在组合那边（实际 %d，0 就是凭空产生）" % [
			fresh.size(), near_combo])
	check(flying == fresh.size(), "都挂着飞入补间（%d/%d）" % [flying, fresh.size()])

	# 飞到一半就摞：真实流程等 0.7s 撞不上，但那是常量正好错开，不是约束
	main.layout._stack_settled(known)
	var still := 0
	# 余数可以启动新的落位补间；必须取消的是会拉回组合起点的旧飞入补间。
	for uid in original_flights:
		var flight: Tween = original_flights[uid]
		if flight.is_valid():
			still += 1
	check(still == 0, "摞牌前取消全部旧飞入补间（还剩 %d 条）" % still)

	for i in 120:
		await physics_frame
	var stray: Array = []
	var bad_scale: Array = []
	for uid in fresh:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		if Vector2(e.global_position.x - center.x,
				e.global_position.z - center.z).length() < 2.0:
			stray.append("(%.1f,%.1f)" % [e.global_position.x, e.global_position.z])
		if absf(e.scale.x - 1.0) > 0.01:
			bad_scale.append("%.2f" % e.scale.x)
	check(stray.is_empty(), "没有卡被补间拉回组合起点（%s）" % [
		"无" if stray.is_empty() else ", ".join(stray)])
	check(bad_scale.is_empty(), "缩放都长回原大小（半路停下的 %s）" % [
		"无" if bad_scale.is_empty() else ", ".join(bad_scale)])

# ---------- T9. 左侧散牌是累计口径，且产出一张张错开起飞 ----------

## 两条都是「只看本回合」会漏掉的：
## 1. 连着两回合各产半摞多一点，每批都不到 PILE_CHUNK，可左边累计早就过了一摞。
##    摞不摞得看左侧累计有多少张，不是这一批有多少张。
## 2. 一次产出十几张，全在同一时刻从同一点出发的话整批完全重叠，
##    看着就是「产出了一张牌」—— 数量得能数出来
func _t9_left_side_is_cumulative(main: Node, board: Board) -> void:
	print("--- T9. 左侧散牌按累计张数决定摞不摞 ---")
	var state: GameState = main.state
	var groups_before: Array = board.groups.duplicate()

	# 第一回合：补到至少「半摞 + 1 张散现金」。前面几节往桌上倒了上百张卡，
	# 左侧本来就躺着一些散牌 —— 累计口径下它们是算进池子的，所以这里按现存的
	# 张数倒推该加几张，而不是假定桌面是干净的
	# 若已有余数超过半摞就保留它；每批仍不到一摞，两批累计过一摞且带余数 ——
	# 三个条件全从 PILE_CHUNK 推，改摞的份量不用回来重新配这个数
	var already: int = _loose_cash_left(main, board)
	var want: int = maxi(main.PILE_CHUNK / 2 + 1, already)
	check(want < main.PILE_CHUNK and want * 2 > main.PILE_CHUNK,
		"夹具前提：每批 %d 张，单批不到 %d、两批过 %d" % [want, main.PILE_CHUNK, main.PILE_CHUNK])
	var known1 := {}
	for uid in main.entities:
		known1[uid] = true
	var batch1: Array = []
	for i in maxi(want - already, 0):
		batch1.append(state.add_card(GameState.PLAYER, "cash")["uid"])
	main._sync_entities()
	await settle()
	main.layout._stack_settled(known1)
	await settle()
	var pool1: int = already + batch1.size()
	check(pool1 == want, "左侧凑到 %d 张散现金（原有 %d + 新加 %d）" % [
		want, already, batch1.size()])
	var made1: Array = _piles_only(_new_groups(board, groups_before))
	check(made1.is_empty(), "左侧只有 %d 张（<%d）时一摞都没建（实际 %d 摞）" % [
		pool1, main.PILE_CHUNK, made1.size()])
	var stray1: Array = []
	for uid in batch1:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		if not main.layout._in_settle_zone(e):
			stray1.append("%.1f" % e.global_position.x)
	check(stray1.is_empty(), "新加的都摆到左侧结算带里了（跑偏的 x=%s）" % [
		"无" if stray1.is_empty() else ", ".join(stray1)])
	check(_loose_cash_left(main, board) == pool1,
		"这 %d 张仍是散着的（实际散牌 %d）" % [pool1, _loose_cash_left(main, board)])

	# 第二回合：再产同样一批。这批自己也不到一摞，但左侧累计过线 → 该摞出一组
	var known2 := {}
	for uid in main.entities:
		known2[uid] = true
	for i in want:
		state.add_card(GameState.PLAYER, "cash")
	main._sync_entities()
	await settle()
	main.layout._stack_settled(known2)
	await settle()
	var made: Array = _piles_only(_new_groups(board, groups_before))
	var sizes: Array = []
	for gg in made:
		sizes.append(int(gg["cards"].size()))
	sizes.sort()
	check(sizes == [main.PILE_CHUNK],
		"两批 %d+%d 累计 %d 张 → 摞出一组 %d（实际 %s）—— 只看本回合就是 []" % [
			pool1, want, pool1 + want, main.PILE_CHUNK, str(sizes)])
	# 摞里必须真收进了上一轮的散牌，否则就是拿新卡凑的一摞，老散牌还躺在左边。
	# batch1 空（左侧本来就够 want 张）时改验「摞里有 known1 里的卡」
	var old_in_pile := 0
	if made.size() == 1:
		for c in made[0]["cards"]:
			if batch1.has(c.uid) or known1.has(c.uid):
				old_in_pile += 1
	check(old_in_pile > 0, "摞里收进了上一轮留下的散牌（实际 %d 张）" % old_in_pile)
	# 余数继续散着，且左侧散牌一定压在一摞的份量以下
	var rest: int = _loose_cash_left(main, board)
	check(rest < main.PILE_CHUNK,
		"摞完之后左侧散牌 %d 张（<%d）" % [rest, main.PILE_CHUNK])

	# 散牌不能压在摞头上。余数不能一张一张去 _pile_slot 找位置：
	# 那条路按「一摞」的余量（PileSolver.PILE_TAKE_CLEAR_Z）避让，左侧三列
	# 一共只放得下几个这样的位置，几张余数就把带子占满，后面的只能挑「最不挤」的
	# 格子 —— 真窗口实测落到了现金摞自己的坐标上。
	#
	# 这一条**必须在带子被占满的情况下**验：上面两批只留一点余数、
	# taken 里也只有一条，随便找都是空位，缺陷不会现形（这么验等于没验）。
	# 所以照真窗口那一炮来：现金给「两摞半」、用户给「一摞半」一次结算 ——
	# 现金先摆 2 摞 + 余数，等用户那批挑位置时 taken 已有好几条，整条带子确实是满的
	var groups_b4: Array = board.groups.duplicate()
	var piled_b4: int = _piled_cards(main, board)
	# 每个已有摞此刻各有几张：下面要验的是「这一炮让它长了整份」，
	# 不能拿绝对张数去验 —— T1/T2 的典当摞也在桌上，那是一次性换出的一笔钱
	# 整笔摞成一摞（见 settle_layout._stack_arrivals 头注释），张数就是 pawn 值，
	# 本来不该是 PILE_CHUNK 的倍数 —— 早先的 pawn 恰好都是整份，扫全桌那条判据
	# 才一直是绿的。
	# 身份用 is_same 认（同上 _new_groups 的注释：Dictionary 的 == 是深比较）
	var pile_ref_b4: Array = []
	var pile_n_b4: Array = []
	for gg in board.groups:
		if bool(gg.get("compact", false)):
			pile_ref_b4.append(gg)
			pile_n_b4.append(gg["cards"].size())
	var known4 := {}
	for uid in main.entities:
		known4[uid] = true
	# 现金「两摞半」、用户「一摞半」：都带余数，两批加起来至少三个整摞，
	# 且现金那批先把 taken 占掉两条，用户那批才是在满带子上挑位置。
	# 三个量全从 PILE_CHUNK 推
	var shot_cash: int = main.PILE_CHUNK * 2 + main.PILE_CHUNK / 2
	var shot_user: int = main.PILE_CHUNK + main.PILE_CHUNK / 2
	for i in shot_cash:
		state.add_card(GameState.PLAYER, "cash")
	for i in shot_user:
		state.add_card(GameState.PLAYER, "user")
	main._sync_entities()
	await settle()
	main.layout._stack_settled(known4)
	await settle()
	# 口径是「进摞的牌多了几张」，不是「新建了几个组」：带子满了以后，新凑齐的
	# 那一份会**并进**已有的同种摞而不新建组（见 _stack_arrivals 的合并分支）。
	# 按新建组数去数，「并成一摞双份」会被误判成「只摞出一摞」——
	# 那样数会假失败（数出一份的张数，而真相是几份都进了摞）。
	#
	# 张数不钉死：T9 跑在 T1–T8 之后，左侧带里本来就躺着前面几节留下的牌，
	# 累计口径下（见 _stack_settled 的头注释）这一炮该摞几摞取决于带里的存量。
	# 钉的是「至少 3 个整 chunk 进了摞」—— 这一炮的新卡摆进去，少于这个数
	# 就是累计口径没生效（变异：让 _merge_loose_left 只返回 fresh，这条立刻报）
	var piles: Array = _piles_only(_new_groups(board, groups_b4))
	var piled_now: int = _piled_cards(main, board)
	check(piled_now - piled_b4 >= 3 * main.PILE_CHUNK,
		"%d 现金 + %d 用户 → 至少 %d 张进摞（实际多了 %d 张：%d→%d）" % [
			shot_cash, shot_user, 3 * main.PILE_CHUNK,
			piled_now - piled_b4, piled_b4, piled_now])
	# 每一摞都是整 chunk 的倍数：只有整份才说明「只摞整份、余数留着散排」
	# 这条口径下并出来的两份仍然合格，而「摞了半份」会报出来
	var odd: Array = []
	for gg in board.groups:
		if not bool(gg.get("compact", false)):
			continue
		var n: int = gg["cards"].size()
		# 这一炮之前就在桌上的摞：只验「长出来的部分」是整份，
		# 底数是它自己的事（典当摞的底数就是 pawn 值）
		var base := 0
		for i in pile_ref_b4.size():
			if is_same(gg, pile_ref_b4[i]):
				base = pile_n_b4[i]
				break
		if (n - base) % main.PILE_CHUNK != 0:
			odd.append("%d(+%d)" % [n, n - base])
	check(odd.is_empty(), "每摞都只长出 %d 的整数倍（不齐的 %s）" % [
		main.PILE_CHUNK, "无" if odd.is_empty() else ", ".join(odd)])
	var on_pile: Array = []
	var loose_n := 0
	for c in state.players[GameState.PLAYER]["cards"]:
		if not main.entities.has(c["uid"]):
			continue
		var e = main.entities[c["uid"]]
		if not is_instance_valid(e) or _in_pile(board, e):
			continue
		if not main.layout._in_settle_zone(e):
			continue
		loose_n += 1
		for gg in piles:
			var pr := _pile_rect(board, gg)
			if pr.intersects(_card_rect(e.global_position)):
				on_pile.append("(%.1f,%.1f)" % [
					e.global_position.x, e.global_position.z])
				break
	check(loose_n > 0, "确实有余数散在左侧（%d 张，0 张就是这条没验到东西）" % loose_n)
	check(on_pile.is_empty(), "%d 张散牌都没压在摞上（压着的 %s）" % [
		loose_n, "无" if on_pile.is_empty() else ", ".join(on_pile)])
	# 散牌互相之间也不许坐标重合：两张完全叠死在一格，屏幕上看着就是少了一张。
	# 真机实测过这个坑（cash 和 user 各一张都落在 (-10.30, 3.64)），
	# 而上面那条「没压在摞上」测不到它 —— 它只看散牌和摞的关系
	var dup: Array = []
	var loose_pos: Array = []
	var floor_gap: float = CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z
	for c in state.players[GameState.PLAYER]["cards"]:
		if not main.entities.has(c["uid"]):
			continue
		var e2 = main.entities[c["uid"]]
		if not is_instance_valid(e2) or _in_pile(board, e2):
			continue
		if not main.layout._in_settle_zone(e2):
			continue
		# 玩家自己编在带里的摊开组不算「散牌」：那是他摆的结构，一张都不许动
		# （见 main.gd 的硬约束）。我们的余数是被 _loose_slots 填进它的缝里的，
		# 两个独立结构在 z 上交错本来就会互相进到标题带的距离内 ——
		# 判得着也改不了，只能靠 y 台阶不穿模（上一条查的就是这个）。
		# 这一条要钉的是「**我们自己摆下的**这一条余数，张张认得出是什么」
		var g2: Variant = board.group_of(e2)
		if g2 != null and not main.layout._is_loose_remainder(g2):
			continue
		var p: Vector3 = e2.global_position
		for q in loose_pos:
			# 判据是标题带的高度：挤到下限也得让每张露出自己的标题带
			if absf(q.x - p.x) < 0.05 and absf(q.z - p.z) < floor_gap * 0.9:
				dup.append("(%.2f,%.2f)" % [p.x, p.z])
				break
		loose_pos.append(p)
	check(dup.is_empty(), "%d 张散牌两两之间都露得出标题带（叠死的 %s）" % [
		loose_n, "无" if dup.is_empty() else ", ".join(dup)])
	# 占地重叠的两张，高度必须拉开 —— 上面两条都只比 x/z，正是这个缺陷溜过去的原因。
	# 余数沿 z 的步长（STACK_GAP.z=0.52）远小于卡的纵深（1.7），同一列里相邻几张
	# 本来就是**故意重叠**的（摊开组「每张露一条标题带」的排法）；余数要是一路
	# 平铺在 anchor.y=0.05，后面那张的图标/卡名就比前面那张的底板还高，
	# 从底板里穿出来（实测 9 张余数里有 16 对是「重叠且 Δy=0」）。
	#
	# 判据取 CardEntity.FACE_SPAN_Y（卡面元素在卡内的抬升跨度）—— 那是 card.gd
	# 自己声明的不变量，不是被测代码里的数。故意把排高度用的 Board.STACK_GAP.y
	# 调小，这一条会立刻报出来
	#
	# 查的是**整条带子上的每一张**，不只是余数：摞里的牌、余数、玩家先前摆在
	# 带里的牌，两两之间都算。只查余数的话，「余数和摞之间」「余数和旧卡之间」
	# 这两类穿模测不到 —— 而屏幕上的穿模不区分那张卡属于谁
	var band_pos: Array = []
	var band_tag: Array = []
	for c in state.players[GameState.PLAYER]["cards"]:
		if not main.entities.has(c["uid"]):
			continue
		var e3 = main.entities[c["uid"]]
		if not is_instance_valid(e3) or not main.layout._in_settle_zone(e3):
			continue
		band_pos.append(e3.global_position)
		band_tag.append(_struct_tag(main, board, e3))
	var clip: Array = []
	for i in band_pos.size():
		for j in range(i + 1, band_pos.size()):
			var a: Vector3 = band_pos[i]
			var b: Vector3 = band_pos[j]
			# 占地重叠 = 两张卡的矩形有交集
			if absf(a.x - b.x) >= CardEntity.CARD_SIZE.x \
					or absf(a.z - b.z) >= CardEntity.CARD_SIZE.z:
				continue
			if absf(a.y - b.y) <= CardEntity.FACE_SPAN_Y:
				# 带上所属结构：光有坐标看不出这是「摞压摞」（带子满了的容量问题）
				# 还是「余数没垫到摞顶上」（台阶问题），两者的修法完全不同
				clip.append("%s(%.2f,%.3f,%.2f)×%s(%.2f,%.3f,%.2f) Δy=%.3f" % [
					band_tag[i], a.x, a.y, a.z,
					band_tag[j], b.x, b.y, b.z, absf(a.y - b.y)])
	check(clip.is_empty(),
		"结算带 %d 张里，重叠的两两都拉开了 %.3f 以上，卡面不穿模（穿模的 %s）" % [
			band_pos.size(), CardEntity.FACE_SPAN_Y,
			"无" if clip.is_empty() else ", ".join(clip)])
	# 垫高必须**有出处、有上界**，而不是不能超过某个绝对高度。
	#
	# 不能钉「都低于 SIDE_Y=0.42」（理由本来是「垫得比侧边清单还高就压清单」），
	# 两头都不成立：
	#   1. 余数落在摞上时本来就该比摞顶高一级（不然就是穿模，见上一条），
	#      压着一个满份摞（实测顶 0.455）的余数必然超过 0.42 —— 那是对的样子，不是缺陷
	#   2. 侧边清单的高度跟着自己那一摞走（见 board._place_side），
	#      本身就不是一个绝对的 0.42，拿它当天花板没有意义
	#
	# 换成查「每张的高度都解释得通」：要么贴桌，要么恰好落在它身下那个结构的
	# 顶面之上一级台阶。上界按「最高的一摞 + 一整条余数台阶」算 —— 这个数
	# 不读被测的 STACK_GAP.y，而是从桌上实际最长的摞和实际余数张数反推。
	#
	# 变异：把散牌落位的 floor 从 maxf(base_y, _pile_top_under(seats)) 改成
	# base_y + _pile_top_under(seats)（main.gd 的 _lay_loose_run），这条立刻报
	# （实测 2.508 > 上界 1.436）。
	# 注意**不是**改 _pile_floor / _pile_top_under 里面那两处 maxf ——
	# 实测那两处改成累加，这条一条都不报：T9 里每个座位身下只压着一层结构，
	# 循环只匹配一次，top 从 0 起算，`0 + x` 和 `maxf(0, x)` 完全同值。
	# 取大改累加这类变异，只有在同一处压着两层以上时才有区别
	var tallest := 0
	for gg in board.groups:
		if bool(gg.get("compact", false)):
			tallest = maxi(tallest, gg["cards"].size())
	var ceil_y: float = 0.05 + Board.COMPACT_GAP.y * float(maxi(tallest - 1, 0)) \
		+ Board.ladder_y(maxi(loose_pos.size(), 1))
	var too_high: Array = []
	for p2 in loose_pos:
		if p2.y > ceil_y:
			too_high.append("%.3f" % p2.y)
	# 余数组必须是**一列**：组的意义就是「占地重叠的这几张共用一套 y 台阶」，
	# 而重叠的前提是同一列（列间距 1.4 > 卡宽 1.2，不同列压不着）。
	# 一个组里的牌散在好几列的话，台阶名次是按整组算的 —— 隔着半张桌子的两张牌
	# 也各占一级，于是最后那张被抬到十几级上去，屏幕上是一排牌悬在半空。
	#
	# 这条和上面那条「垫高有上界」是两个量：上界那条量的是**高度**（它先报了红，
	# 1.844 > 1.700），这条量的是**成员构成**。前者是后者的下游 —— 只有前者的话，
	# 组散成几列但恰好张数少、抬不高时就全绿溜过。
	#
	# 缺陷实录：_move_to_spot 不宣告归宿，第二趟（用户那趟）读到的是第一趟
	# 刚送出去那几张的**出发点**，于是把它们按半路上的坐标重新钉死 ——
	# 实测一个组里 11 张散在 x=-11.7..7.3，横穿整张桌子
	var col_spread: Array = []
	for gi in board.groups.size():
		var gr = board.groups[gi]
		if not main.layout._is_loose_remainder(gr):
			continue
		var xs := {}
		for c in gr["cards"]:
			if is_instance_valid(c):
				xs[snappedf(c.global_position.x, 0.1)] = true
		if xs.size() > 1:
			var ks: Array = xs.keys()
			ks.sort()
			col_spread.append("余数#%d 跨 %d 列 %s" % [gi, xs.size(), str(ks)])
	check(col_spread.is_empty(), "每个余数组都只占一列（跨列的：%s）" % [
		"无" if col_spread.is_empty() else ", ".join(col_spread)])
	#
	# 曾想再加一条「而且那一列得是结算带自己的列」——**不成立，别加回来**。
	# REST_FLAG 是 _place_loose_col 给任何一次 _lay_loose_run 盖的章，而
	# _stack_arrivals 的 anchor/col_xs 由调用方给：典当那条路（main._on_pawn
	# 拿被当那张卡的原位当 anchor）摆出来的余数组本来就在带外。实测这条会报
	# T9 里 T5 留下的「余数#11@2.0」—— 那是典当摞的零头，不是缺陷。
	# 何况它也查不出新东西：跨带必然跨列，上面那条先报
	#
	# 一列之内还得**真摊开**：同组相邻两张沿 z 至少隔开一条标题带。
	#
	# 和上面那条是两个量，也和 T1 那条「余数组是摊开态」是两个量：
	# T1 查的是 compact 这个**标志位**，这条查的是标志位说的那件事有没有发生。
	# 标志位是摊开、几张牌却叠在同一个 z 上，屏幕上就是一叠看不出张数的牌
	# —— 而 compact=false 让它连侧边清单都没有（_sync_side 只给收拢的摞挂），
	# 于是那几张是彻底读不出来的。
	#
	# 和上面那条「%d 张散牌两两之间都露得出标题带」也不重合：那条按
	# _in_settle_zone 筛，而结算带就是 SETTLE_CASH_COLS 那三列（-11.7/-10.3/-8.9）
	# 上下半个列距以内。典当那条路摆出来的余数组在带外（实测 x=2.0），
	# 那条一张都看不见，这条按**组**取所以照样查。反过来那条查的是带里
	# 所有结构两两之间（摞/余数/玩家的旧牌），这条只查同一组内相邻两张 ——
	# 两条各盖一头。
	#
	# 为什么非要几何量：_relift_remainders 里那句 `var at := _rest_pos(c)` 改成
	# 读实时坐标，报表上是「退出码 0，失败 0 条」—— 那一趟只把 z 读坏，
	# 而组里的牌本来就在同一列，x 一个都没变，「只占一列」那条看不见。
	# 坏在哪：那几张还在 0.3s 补间路上，出发点是同一个格子，于是全被按回
	# 同一个 z、只靠 y 台阶错开
	var band_floor := CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z
	var flat: Array = []
	var pairs := 0
	for gi2 in board.groups.size():
		var gr2 = board.groups[gi2]
		if not main.layout._is_loose_remainder(gr2) \
				or bool(gr2.get("compact", false)):
			continue
		var zs: Array = []
		for c in gr2["cards"]:
			if is_instance_valid(c):
				zs.append(c.global_position.z)
		if zs.size() < 2:
			continue
		zs.sort()
		pairs += zs.size() - 1
		for r2 in range(1, zs.size()):
			var gap: float = zs[r2] - zs[r2 - 1]
			if gap < band_floor - 0.01:
				flat.append("余数#%d 相邻 Δz=%.3f" % [gi2, gap])
	# 上面那个循环一对都没数到的话这条是空判据（memory: 判据得有观察点）
	check(pairs > 0, "有摊开的余数组可查（相邻对数 %d，0 对就是这条没验到东西）" % pairs)
	check(flat.is_empty(),
		"摊开的余数组张张露标题带（≥%.3f，挤在一起的 %s）" % [
			band_floor, "无" if flat.is_empty() else ", ".join(flat)])
	check(too_high.is_empty(),
		"散牌垫高都在「最高一摞（%d 张）+ 一条余数台阶」= %.3f 以内（超了的 %s）" % [
			tallest, ceil_y, "无" if too_high.is_empty() else ", ".join(too_high)])

	# 摞被抬起来必须**有东西垫在下面**：上一条查的是散牌的上界，这一条查摞自己。
	#
	# 为什么单独要一条：抬升是「整摞统一 +lift」，抬得齐整就不产生任何重叠，
	# 所以穿模那条查不出来；而它抬的是整摞、不是散牌，散牌上界那条也查不出来。
	# 于是「全场摞集体悬空」这种缺陷两条都漏 —— 实测把 main.layout._pile_top_under 的
	# exclude 参数去掉（新摞量身下那摞时把自己也量进去），每摞按自己的高度
	# 抬自己 0.429，屏幕上所有摞离桌悬着，改之前一条判据都不报。
	#
	# 判据只看「贴桌 or 身下真有牌」，不读 COMPACT_GAP.y / ladder_y：
	# 底面高过贴桌高度的摞，它的座位底下必须真找得到一张更低的牌
	var float_bad: Array = []
	for gi2 in board.groups.size():
		var g4 = board.groups[gi2]
		if not bool(g4.get("compact", false)) or g4["cards"].is_empty():
			continue
		var bottom: float = 99.0
		for c4 in g4["cards"]:
			if is_instance_valid(c4):
				bottom = minf(bottom, c4.global_position.y)
		# 0.05 = 贴桌静止高度（桌面碰撞顶 + 牌碰撞半高，见 board._layout_group）。
		# 留一格台阶的容差：贴桌的摞本身没抬，读到的就是 0.05
		if bottom <= 0.05 + Board.ladder_y(1):
			continue
		# 扫**全场**的卡，不是只扫 band_pos：带子满了之后摞会溢出到结算带以外
		# （实测有摞落在 x=-8.0，_in_settle_zone 判它在带外），顶起它的那个
		# 玩家组也在带外 —— 只扫带内会把这种合理的抬升误报成悬空
		var propped := false
		for c4 in g4["cards"]:
			if not is_instance_valid(c4):
				continue
			for c5 in board.cards:
				if not is_instance_valid(c5) or g4["cards"].has(c5):
					continue
				var cp2: Vector3 = c5.global_position
				if cp2.y >= bottom:
					continue      # 只算比这一摞底面更低的牌
				if absf(cp2.x - c4.global_position.x) < CardEntity.CARD_SIZE.x \
						and absf(cp2.z - c4.global_position.z) < CardEntity.CARD_SIZE.z:
					propped = true
					break
			if propped:
				break
		if not propped:
			float_bad.append("摞#%d(%d张) 底面y=%.3f 身下没牌" % [
				gi2, g4["cards"].size(), bottom])
	check(float_bad.is_empty(),
		"抬起来的摞底下都真垫着牌，没有悬空的（悬空的 %s）" % [
			"无" if float_bad.is_empty() else ", ".join(float_bad)])

	# 侧边清单（收拢摞右侧那列「图标 ×N」）不能埋在牌底下。
	#
	# 它平铺在桌面上、没有厚度，判据比卡与卡之间更简单：清单节点落在谁的占地里，
	# 就必须比那张卡高。写死成 SIDE_Y=0.42 两头都不够：
	#   1. 自己这一摞就能超过它 —— 满份收拢摞顶面实测 0.455，清单反而在底下；
	#      带子挤起来整摞还会被抬到 y=1.8（见 main.layout._settle_pile_heights），差得更远
	#   2. 这一列贴在摞右沿 +0.76 处、整条宽约 SIDE_W=0.95，而结算带列距只有
	#      PILE_SLOT_X_STEP=1.4、卡半宽 0.6 —— 它必然探进**邻列**的占地里，
	#      邻列被抬高时同样埋掉它（实测这两类合计 8 处）
	#
	# 判据里不读 SIDE_Y、也不读 overlay_y 用的台阶常量：只比「清单 y」和
	# 「压着它的卡 y」的大小关系。变异：把 board._place_side 的高度改回
	# 写死的 SIDE_Y，或者删掉 _stack_arrivals 末尾的 board.resync_sides()，
	# 这条都会报（后者报的是次序：清单摆下时邻列还没抬起来）
	var side_bad: Array = []
	for gi in board.groups.size():
		var g3 = board.groups[gi]
		if not bool(g3.get("compact", false)):
			continue
		for node in g3.get("side", []):
			if node == null or not is_instance_valid(node):
				continue
			var np: Vector3 = node.global_position
			for k in band_pos.size():
				var cp: Vector3 = band_pos[k]
				# 清单节点当成一个点：落在这张卡的矩形里就算被它盖着
				if absf(cp.x - np.x) >= CardEntity.CARD_SIZE.x / 2.0 \
						or absf(cp.z - np.z) >= CardEntity.CARD_SIZE.z / 2.0:
					continue
				if cp.y >= np.y:
					side_bad.append("摞#%d 清单y=%.3f 被 %s y=%.3f 压着" % [
						gi, np.y, band_tag[k], cp.y])
					break
	check(side_bad.is_empty(),
		"每摞的侧边清单都浮在压着它的牌之上（埋着的 %s）" % [
			"无" if side_bad.is_empty() else ", ".join(side_bad)])

	# 错开起飞：14 张不能是同一时刻同一个点
	var known3 := {}
	for uid in main.entities:
		known3[uid] = true
	var batch3: Array = []
	for i in 14:
		batch3.append(state.add_card(GameState.PLAYER, "user")["uid"])
	var center := Vector3(3.0, 0.05, 2.0)
	main._sync_entities(center)
	await physics_frame
	var spots := {}
	var moving := 0
	var first: Array = []
	for uid in batch3:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		first.append(e.position)
		spots["%.2f,%.2f" % [e.position.x, e.position.z]] = true
	check(spots.size() >= 10,
		"14 张起点铺开了（不同落点 %d 个，全重叠就是 1 个）" % spots.size())
	# 逮**第一张动的那一帧**，看那一刻还有没有人在原地等。
	#
	# 不掐 SPAWN_FLY_SPREAD 的一半那个时刻：要测的是「张与张之间错开」，
	# 是个差值，不需要绝对时刻，而掐时刻会从两头红 ——
	# 采样早于所有人起飞就是 moving=0（实测撞到过：并跑里这一条报过
	# 「飞了 0 张、还在等 14 张」，单跑两档各六次都是绿的），
	# 采样晚于所有人起飞就是 still=0。两种都不是被测的东西错了。
	#
	# 轮询版反而更强：同时起飞的话，第一张动的那一帧所有人都动了 → still=0 红；
	# 错开的话最后几张还差 0.3 秒（18 帧）没动 → still>0 绿。
	# 上限 90 帧是防挂死，不是判据（0.3 秒的错开在 60Hz 下 18 帧就够）
	var still := 0
	for _f in 90:
		await physics_frame
		var m := 0
		var s := 0
		for i in batch3.size():
			var e = main.entities.get(batch3[i])
			if not is_instance_valid(e) or i >= first.size():
				continue
			if e.position.distance_to(first[i]) < 0.02:
				s += 1
			else:
				m += 1
		if m > 0:
			moving = m
			still = s
			break
	check(moving > 0 and still > 0,
		"起飞是错开的（第一张动的那一帧：飞了 %d 张、还在等 %d 张；同时起飞会是 %d/0）"
			% [moving, still, batch3.size()])

# ---------- T10. 产出直接落进左侧资源带，落地就按每 PILE_CHUNK 张分组 ----------

## 老毛病：产出牌是「先落到别处、糊成一张、然后整批跳到左边」。
## 两个原因 ——
##   1. 落点走的是 PLAYER_PILE_*_ANCHOR（玩家自己的堆），不是左侧结算带；
##   2. 整批同时出生，_free_spot 只看实体实时坐标，而这时候整批都还在
##      组合中心，于是每一张都判「锚点那儿是空的」，返回同一个坐标。
##
## 所以判据看的是**落地那一刻**（补间跑完、还没跑结算末尾那趟统一摞牌）：
## 这时候牌就该已经在带子里、按每 PILE_CHUNK 张一组分开，而不是叠成一坨。
## 只看最终形态测不出这个 bug —— 末尾那趟本来就会把它们拽到带子里
func _t10_arrivals_land_in_band(main: Node, board: Board) -> void:
	print("--- T10. 产出直接落进左侧资源带、落地即分组 ---")
	var state: GameState = main.state
	# 前面几节往桌上倒了上百张卡，带子里已经躺着一片。这一节要看的是
	# 「新到的这批落在哪」，所以先把桌面清空到只剩公共区
	isolate(board, [])
	await physics_frame

	var known := {}
	for uid in main.entities:
		known[uid] = true
	var n := 14
	var fresh: Array = []
	for i in n:
		fresh.append(state.add_card(GameState.PLAYER, "cash")["uid"])
	# BOT 也产一批：同一批同时出生，落点也不许互相重叠（对方的产出同样看得见）
	var bot_fresh: Array = []
	for i in 5:
		bot_fresh.append(state.add_card(GameState.BOT, "cash")["uid"])
	var center := Vector3(3.0, 0.05, 2.0)
	main.layout.begin_arrivals()
	main._sync_entities(center)
	# 等到最后一张也落地。问补间「跑完了没有」而不是按墙钟估：这一节下面几条
	# 读的是实时坐标，等不够就会读到出发点，而同批出生的出发点挨得近 → 假「重合」
	await arrivals_landed(main)

	# 1. 落地就在带子里，不是先落到别处
	var outside: Array = []
	for uid in fresh:
		var e = main.entities.get(uid)
		if is_instance_valid(e) and not main.layout._in_settle_zone(e):
			outside.append("(%.1f,%.1f)" % [e.global_position.x, e.global_position.z])
	check(outside.is_empty(), "%d 张产出落地就在左侧资源带里（带外的：%s）" % [
		n, "无" if outside.is_empty() else ", ".join(outside)])

	# 2. 不许完全重叠：同一个坐标上不许有两张
	var at := {}
	var dup := 0
	for uid in fresh:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		var k := "%.2f,%.2f,%.2f" % [e.global_position.x, e.global_position.y,
			e.global_position.z]
		if at.has(k):
			dup += 1
		at[k] = true
	check(dup == 0, "落地没有两张压在同一个坐标上（重合 %d 张）" % dup)

	# 3. 按每 PILE_CHUNK 张分组：把落点按「列 x + 组基准 z」聚类，
	#    n 张该聚成「整份几组 + 余数一组」。全落一处的话只有 1 组、组里 n 张
	var chunk: int = main.layout.PILE_CHUNK
	var cluster := {}
	for uid in fresh:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		# 一组内部沿收拢偏移码高（COMPACT_GAP），z 跨度不到半张卡；
		# 两组之间隔着摞的避让距离。按 1 为格宽聚类刚好把两者分开
		var k := "%.0f:%.0f" % [e.global_position.x, roundf(e.global_position.z)]
		cluster[k] = int(cluster.get(k, 0)) + 1
	var sizes: Array = cluster.values().duplicate()
	sizes.sort()
	sizes.reverse()
	check(sizes.size() == 2 and int(sizes[0]) == chunk and int(sizes[1]) == n - chunk,
		"落地即按每 %d 张分组（实际各组 %s，全落一处会是 [%d]）" % [
			chunk, str(sizes), n])

	# 4. BOT 那批也不许互相重叠：同一批同时出生，读实时坐标读到的全是出发点
	var bot_at := {}
	var bot_dup := 0
	for uid in bot_fresh:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		var k := "%.1f,%.1f" % [e.global_position.x, e.global_position.z]
		if bot_at.has(k):
			bot_dup += 1
		bot_at[k] = true
	check(bot_dup == 0, "BOT 那批 %d 张也各有落点（重合 %d 张）" % [
		bot_fresh.size(), bot_dup])

	# 5. 结算末尾那趟统一摞牌之后：整份的那几摞成了真摞，余数留着散
	main.layout.end_arrivals()
	var groups_before: Array = board.groups.duplicate()
	main.layout._stack_settled(known)
	await settle()
	var piled := _piled_cards(main, board)
	check(piled == chunk, "统一那趟把整 %d 张摞成一摞（带里摞着 %d 张）" % [chunk, piled])
	check(_loose_cash_left(main, board) == n - chunk,
		"余下 %d 张继续散着（实际 %d）" % [n - chunk, _loose_cash_left(main, board)])
	var made: Array = _piles_only(_new_groups(board, groups_before))
	check(made.size() == 1, "新摞正好一摞（实际 %d）" % made.size())
	# 落点和末尾那趟挑的位置要对得上：摞是原地收拢，不是又整摞搬一次。
	# 容差 = 一张卡的宽度：同一格里收拢会动一点（组内偏移变了），换格子会远得多
	if made.size() == 1:
		var moved := 0.0
		var origin: Vector3 = board._group_origin(made[0])
		for e in made[0]["cards"]:
			moved = maxf(moved, absf(e.global_position.x - origin.x))
		check(moved < CardEntity.CARD_SIZE.x,
			"整 10 张那份是原地收拢，没被整摞搬走（列内偏移 %.2f < %.2f）" % [
				moved, CardEntity.CARD_SIZE.x])

	# 6. 带里已经躺着上一轮的零头时，新到的这批要接着它们码 ——
	#    这一批和那 4 张零头本轮会被末尾那趟并成同一摞，所以挑落点时
	#    零头占的位置不算障碍。要是把它们当障碍绕开，新的 6 张会落到别处，
	#    等末尾那趟把两边并起来，整摞再搬一次 —— 玩家看到的就是「跳一下」
	var loose_at: Array = []
	for e in _loose_cash_entities(main, board):
		loose_at.append(e.global_position)
	var rest: int = n - chunk
	# 第二轮结算：桌上现有的都算「上一轮的」，只有这一批是新到的。
	# 上一轮那一份已经摞好了，known 不刷新的话它们会被当成新卡重排一遍
	var known2 := {}
	for uid in main.entities:
		known2[uid] = true
	var fill: Array = []
	for i in (chunk - rest):
		fill.append(state.add_card(GameState.PLAYER, "cash")["uid"])
	main.layout.begin_arrivals()
	main._sync_entities(center)
	await arrivals_landed(main)
	# 新到的这批落在零头旁边（同一格里），不是被零头挤到别处
	var far: Array = []
	for uid in fill:
		var e = main.entities.get(uid)
		if not is_instance_valid(e):
			continue
		var near := INF
		for p in loose_at:
			near = minf(near, Vector2(e.global_position.x - (p as Vector3).x,
				e.global_position.z - (p as Vector3).z).length())
		if near > 1.0:
			far.append("%.2f" % near)
	check(far.is_empty(), "新到的这批就落在带里那 %d 张零头旁边（离得远的：%s）" % [
		rest, "无" if far.is_empty() else ", ".join(far)])
	var g2_before: Array = board.groups.duplicate()
	main.layout.end_arrivals()
	main.layout._stack_settled(known2)
	await settle()
	# 并出来的第二摞要停在零头原来那个位置：末尾那趟挑的位置和落地时挑的一致
	var made2: Array = _piles_only(_new_groups(board, g2_before))
	check(made2.size() == 1, "零头 + 新到的并成第二摞（实际 %d）" % made2.size())
	if made2.size() == 1 and not loose_at.is_empty():
		var o2: Vector3 = board._group_origin(made2[0])
		var jump := INF
		for p in loose_at:
			jump = minf(jump, Vector2(o2.x - (p as Vector3).x,
				o2.z - (p as Vector3).z).length())
		check(jump < 1.0, "第二摞是在零头原地收拢，没有整摞搬走（挪了 %.2f）" % jump)
	check(_loose_cash_left(main, board) == 0,
		"两摞都满了，带里不再有散牌（实际 %d）" % _loose_cash_left(main, board))

	# 7. 两种资源同一轮到货 —— 这一节要的是「另一批还在飞」这个时机。
	#    产出现在是直飞左侧带的（见 arrival_spot），现金那批先落，用户那批还在
	#    从现金列上空横穿时末尾那趟就开跑了（main.gd 的 _cancel_fly 一节写明了
	#    「_stack_settled 会把没跑完的补间掐掉」，就是说它本来就跑在飞行途中）。
	#    这一趟要是不知道「用户那批也是本轮要重排的」，就把半空中那几张判成障碍，
	#    现金那摞躲去隔壁列最南端，余数跟着往南推、尾巴滑出画面
	#    （实测最南那张 x=-13.0，屏幕投影 x=-58，玩家根本看不到自己的钱）
	#
	#    判据是差分：同一场景摞的落点不许因为「另一批飞没飞完」而变。
	#    落定后结算 = 参照，飞行途中结算 = 真实路径，两者必须落在同一列
	var ref_x: float = await _settle_two_res(main, board, state, center, 999.0, "落定后")
	var mid_x: float = await _settle_two_res(main, board, state, center,
		main.SPAWN_FLY_TIME, "飞行中")
	check(absf(mid_x - ref_x) <= CardEntity.CARD_SIZE.x,
		"另一批还在飞时，现金那摞落点不变（落定后 x=%.2f，飞行中 x=%.2f）" % [
			ref_x, mid_x])

## 跑一遍「现金一摞多、用户不到一摞，同一轮到货」，返回现金那摞的 x。
## 两个量从 PILE_CHUNK 推：现金要摞得出整整一摞（下面按「就这一摞」找它），
## 用户要凑不出一摞（否则两摞一起挑位置，量的就不是这一条了）。
## wait —— 从 _sync_entities 到 _stack_settled 之间等多久：给足就是两批都落定，
## 给 SPAWN_FLY_TIME 就是用户那批还有一半在空中（错开总时长是 SPAWN_FLY_SPREAD）
func _settle_two_res(main: Node, board: Board, state: GameState, center: Vector3,
		wait: float, tag: String) -> float:
	isolate(board, [])
	await physics_frame
	var known := {}
	for uid in main.entities:
		known[uid] = true
	var n_cash: int = main.PILE_CHUNK + main.PILE_CHUNK / 2 - 1
	var n_user: int = main.PILE_CHUNK - 2
	for i in n_cash:
		state.add_card(GameState.PLAYER, "cash")
	for i in n_user:
		state.add_card(GameState.PLAYER, "user")
	main.layout.begin_arrivals()
	main._sync_entities(center)
	await create_timer(minf(wait, main.SPAWN_FLY_SPREAD + main.SPAWN_FLY_TIME + 0.1)).timeout
	main.layout.end_arrivals()
	main.layout._stack_settled(known)
	await settle()
	# 只量这一轮产出的那几张：isolate 把别的散卡冻在画面外的角落里，
	# 那是清场手法，不是布局出的错
	var born: Array = []
	for uid in main.entities:
		if not known.has(uid):
			born.append(main.entities[uid])
	_check_on_screen(main, born, tag)
	# 这一轮新摞出来的那一摞（整一份现金）落在哪儿
	for g in board.groups:
		if not g.get("compact", false):
			continue
		var ours := true
		for c in g["cards"]:
			if not born.has(c):
				ours = false
				break
		if ours and not g["cards"].is_empty():
			return board._group_origin(g).x
	check(false, "%s：这一轮摞出了一摞（没找到）" % tag)
	return NAN

## cards 里每一张都得在画面里。四角按实际 transform 取（卡是刚体，会有转角），
## 判据不读任何布局常量 —— 量的是玩家能不能看见自己的牌，而不是某个坐标等于几
func _check_on_screen(main: Node, cards: Array, tag: String = "") -> void:
	var cam: Camera3D = main.get_viewport().get_camera_3d()
	if cam == null:
		check(false, "拿到相机（拿不到就量不了出画）")
		return
	var vp: Vector2 = Vector2(main.get_viewport().get_visible_rect().size)
	var hx: float = CardEntity.CARD_SIZE.x / 2.0
	var hz: float = CardEntity.CARD_SIZE.z / 2.0
	var off: Array = []
	for e in cards:
		if not is_instance_valid(e):
			continue
		for sx in [-hx, hx]:
			for sz in [-hz, hz]:
				var sp: Vector2 = cam.unproject_position(
					e.global_transform * Vector3(sx, 0.0, sz))
				if sp.x < 0.0 or sp.y < 0.0 or sp.x > vp.x or sp.y > vp.y:
					off.append("%s@(%.1f,%.1f) 角 (%.0f,%.0f)" % [e.def_id,
						e.global_position.x, e.global_position.z, sp.x, sp.y])
					break
	check(off.is_empty(), "%s结算完没有牌被挤出画面（出画的：%s）" % [
		"" if tag == "" else tag + "：",
		"无" if off.is_empty() else ", ".join(off)])

# ---------- T11. 产出没有独立音效：每张牌落地各响一声 drop ----------

## 产出是「一批牌落到桌上」，所以它的声音就是一批 drop —— 听到几声就是几张。
## 整组一声 produce 说不出产出了几张，而且和「手放牌落桌」是同一件事、
## 却响两种声音。判据两头都要钉：produce 这个音效不许还在，drop 得按张数响
##
## 张数和响度都不写字面量：响几声按实际产出的张数算，多响按配置里
## card_drop 那一档算 —— 这一节量的是「产出和落桌是同一声」，不是某个 dB 值
func _t11_produce_uses_per_card_drop(main: Node, board: Board) -> void:
	print("--- T11. 产出用每张一声 drop，没有独立音效 ---")
	check(not Sfx.sounds().has("produce"), "音效表 _sfx.sounds 里没有 produce 这一项")
	var actions: Dictionary = CardDB.sfx_rules().get("actions", {})
	check(not actions.has("produce"), "_sfx.actions 里没有 produce 这个动作")
	# 产出那个动作必须解到和手放牌落桌一模一样的一声（同 wav 同响度），
	# 不然「产出听起来就是落桌」这句话在配置那一侧就已经不成立了
	var land := Sfx.action("produce_land")
	var drop := Sfx.action("card_drop")
	check(str(land.get("sound", "")) == str(drop.get("sound", ""))
		and absf(float(land.get("db", 0.0)) - float(drop.get("db", 0.0))) < 0.01,
		"produce_land 和 card_drop 同 wav 同响度（实 %s/%s dB 对 %s/%s dB）" % [
			land.get("sound", ""), land.get("db", 0.0),
			drop.get("sound", ""), drop.get("db", 0.0)])
	var src: String = FileAccess.open("res://scenes/main.gd", FileAccess.READ).get_as_text()
	check(not src.contains('play("produce"'), "main.gd 里没有 produce 的播放调用")

	isolate(board, [])
	await physics_frame
	var rec := SfxRecorder.new()
	var real: Sfx = main.sfx
	main.add_child(rec)
	main.sfx = rec

	var n := 6
	var fresh: Array = []
	for i in n:
		fresh.append(main.state.add_card(GameState.PLAYER, "cash")["uid"])
	main.layout.begin_arrivals()
	main._sync_entities(Vector3(3.0, 0.05, 2.0))
	await arrivals_landed(main)
	main.layout.end_arrivals()

	# 按解出来的音效名收，不按动作名 —— 这一节的问题是「玩家听到几声」，
	# 而 produce_land 和 card_drop 是同一声的两个入口
	var drop_wav := str(Sfx.action("card_drop").get("sound", ""))
	var want_db := float(Sfx.action("card_drop").get("db", 0.0))
	var drops: Array = []
	for c in rec.calls:
		if str(c["key"]) == drop_wav:
			drops.append(float(c["db"]))
	check(drops.size() == n, "%d 张产出响了 %d 声 %s（整组一声会是 1）" % [
		n, drops.size(), drop_wav])
	var same_db := true
	for db in drops:
		if absf(float(db) - want_db) > 0.01:
			same_db = false
	check(same_db, "落地音量和手放牌落桌一致（配置 card_drop 那一档 %.1f dB）" % want_db)

	main.sfx = real
	rec.queue_free()

# ---------- T12. 余数还在飞的时候典当 ----------

## _relift_remainders 读实时坐标的那条路，**只有这一节走得到**。
##
## 为什么别的节走不到：一次结算里两趟 _relift_remainders（现金/用户各一趟，
## 走 _stack_piles_only → _stack_arrivals）**都排在两趟 _lay_loose_run 前面**，
## 所以本轮自己摆的余数它一张都看不见；而上几轮的余数早落定了。
## 实测在这一节之前，全表 30 次 _relift 调用读到的 `_rest_pos` 和
## `global_position` 差都是 0.000 —— 那句改成读实时坐标是全绿的
## （memory: green-mutation-means-no-observer 的第二种，「那个量根本没人读」）。
##
## 唯一的窗口：结算刚把余数送上路（_move_to_spot 的 0.3s 补间），玩家在补间
## 跑完前典当一张 —— main._on_pawn 直接调 _stack_arrivals，于是 _relift_remainders
## 读到的是那几张的**出发点**。玩家手速够得着：0.3s 而已，桌面又不锁
## （memory: settle-runs-mid-flight 是同一个形状的另一头）。
##
## 所以这一节**故意不 await 补间**。别「顺手」在 _on_dropped_on_pawn 前面
## 补一句 await settle()：那就把窗口关上了，这一节退化成 T9 的重复
func _t12_pawn_during_settle_flight(main: Node, board: Board) -> void:
	print("--- T12. 余数还在飞的时候典当，不把它们按半路上的位置钉死 ---")
	var state: GameState = main.state
	isolate(board, [])
	await physics_frame
	# 同 T6：前面几节堆的现金早过了胜利线，winner 一定下来，典当意图会被
	# IntentApply 的 game_over 护栏挡掉（只放 finalize 过），_stack_arrivals
	# 一次都不跑 —— 这一节整段就成了空判据。只摘标记，不动牌
	state.winner = ""
	state.win_reason = ""

	# 张数取「不够一摞」：半份现金全是余数，一个 REST_FLAG 组，几级台阶。
	# 够 PILE_CHUNK 张的话整份进收拢摞，_relift_remainders 根本不管收拢的摞。
	# 取半份而不是 1 张：下面那条「窗口真的开着」要至少 2 张还在半路上
	var known := {}
	for uid in main.entities:
		known[uid] = true
	for i in main.PILE_CHUNK / 2:
		state.add_card(GameState.PLAYER, "cash")
	main._sync_entities()
	await arrivals_landed(main)
	main.layout._stack_settled(known)

	# 余数此刻正在 _move_to_spot 的补间上。先验窗口真的开着 —— 不验的话
	# 机器一慢补间早跑完了，下面那两条判据就什么都没盖住（判据的前提，不是判据）
	var flying := 0
	var rest_cards: Array = []
	for g in board.groups:
		if not main.layout._is_loose_remainder(g):
			continue
		for c in g["cards"]:
			if is_instance_valid(c):
				rest_cards.append(c)
				if not main.layout._rest_pos(c).is_equal_approx(c.global_position):
					flying += 1
	check(flying >= 2, "典当发生时余数确实还在半路上（%d/%d 张没到位，"
		% [flying, rest_cards.size()]
		+ "0 张就是窗口没开着、下面两条没验到东西）")

	# 现在典当。_on_dropped_on_pawn → _stack_arrivals → _relift_remainders，
	# 那一趟会把上面这个余数组重新摆一遍
	var legend: Dictionary = state.add_card(GameState.PLAYER, "dujiaoshou")
	var le: CardEntity = main._spawn_entity(legend, Vector3(6.5, 0.05, 2.6), true)
	main.phase = main.PHASE_ACTION
	main._actor = GameState.PLAYER
	var cash_b4 := int(state.resource_count(GameState.PLAYER, CardDB.RES_CASH))
	await main._on_dropped_on_pawn([le])
	await settle()
	# 典当真的成交了吗。**判据的前提**：被 pipe 拒掉（不在行动阶段 / 用户卡会归零）
	# 的话 _stack_arrivals 一次都不跑，下面那两条查的只是上一节留下的桌面
	var gained := int(state.resource_count(GameState.PLAYER, CardDB.RES_CASH)) - cash_b4
	check(gained == CardDB.pawn_value("dujiaoshou"),
		"典当成交了（现金 +%d，+0 就是被 pipe 拒了、_stack_arrivals 一次没跑）"
			% gained)

	# 余数组还得是「一列 + 张张露标题带」。和 T9 里那两条是同一对量，
	# 但这一节的局面到得了那句读实时坐标的代码，T9 到不了
	var band_floor := CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z
	var bad: Array = []
	var checked := 0
	for gi in board.groups.size():
		var g2 = board.groups[gi]
		if not main.layout._is_loose_remainder(g2) \
				or bool(g2.get("compact", false)):
			continue
		var xs := {}
		var zs: Array = []
		for c in g2["cards"]:
			if is_instance_valid(c):
				xs[snappedf(c.global_position.x, 0.1)] = true
				zs.append(c.global_position.z)
		if zs.size() < 2:
			continue
		checked += 1
		if xs.size() > 1:
			var ks: Array = xs.keys()
			ks.sort()
			bad.append("余数#%d 跨 %d 列 %s" % [gi, xs.size(), str(ks)])
		zs.sort()
		for r in range(1, zs.size()):
			if zs[r] - zs[r - 1] < band_floor - 0.01:
				bad.append("余数#%d 相邻 Δz=%.3f（<%.3f）" % [
					gi, zs[r] - zs[r - 1], band_floor])
	check(checked > 0, "典当之后还找得到那个余数组（查了 %d 个，0 个就是这条没验到东西）"
		% checked)
	check(bad.is_empty(), "半路上被典当打断，余数照样一列排开、张张露标题带（坏的：%s）"
		% ["无" if bad.is_empty() else ", ".join(bad)])

## 记账用的假音效：只记谁被播了，不真出声。
## 继承 Sfx 是因为 main.sfx 是 `var sfx: Sfx` 带类型的，塞别的类进去会报错。
##
## 为什么不读真 Sfx 的池子：那 10 格是轮转的，播满一轮就把旧的盖掉，
## 而这一节要的是**按次序的全部调用**（六张牌六声）。
## 顺带说清 —— headless 下 wav 是真加载得上的，替身不是为了绕开这个
## （见 tests/test_config_complete.gd 的 T4，那一节反过来专门读真池子）
##
## 动作名和它解出来的音效/响度都记：调用方只说动作名（play("produce_land")），
## 「这一声听着是哪个 wav、多响」得从配置里解一遍才知道 ——
## 只记动作名的话，「产出和手放牌落桌是同一声」这条就无从判起
class SfxRecorder extends Sfx:
	var calls: Array = []
	func play(action_name: String, pitch_scale := 1.0) -> void:
		var spec := Sfx.action(action_name)
		calls.append({
			"action": action_name,
			"key": str(spec.get("sound", "")),
			"db": float(spec.get("db", 0.0)),
			"pitch": float(spec.get("pitch", 1.0)) * pitch_scale,
		})

## 结算带里有多少张牌进了收拢的摞。
##
## 「摞了几摞」不能拿组数来数：带子满了以后新的整份会并进已有的摞
## （见 _stack_arrivals 的合并分支），组数不涨、张数涨。数张数才是稳的
func _piled_cards(main: Node, board: Board) -> int:
	var n := 0
	for c in main.state.players[GameState.PLAYER]["cards"]:
		if not main.entities.has(c["uid"]):
			continue
		var e = main.entities[c["uid"]]
		if is_instance_valid(e) and main.layout._in_settle_zone(e) and _in_pile(board, e):
			n += 1
	return n

## 这张卡属于哪种结构，给穿模报告用：摞#i / 余数#i / 散。
## 编号按 board.groups 的下标，同一摞的牌拿到同一个号，一眼看出是不是同一对结构撞的
func _struct_tag(main: Node, board: Board, e) -> String:
	for i in board.groups.size():
		var g = board.groups[i]
		if not g["cards"].has(e):
			continue
		if g.get("compact", false):
			return "摞#%d" % i
		# 代收的零头和玩家自己的摊开组要分开报：前者我们可以重排（_relift_remainders），
		# 后者一张都不许动，压上去了只能怪摞没避开
		return ("余数#%d" % i) if g.get(main.layout.REST_FLAG, false) else ("玩家组#%d" % i)
	return "散"

## 左侧结算带里「还没摞起来」的现金张数 —— 就是 _stack_settled 的池子口径。
##
## 口径是「不在收拢的摞里」，不是「不在任何组里」：余数现在也是一个组
## （摊开态，每张露标题带），组是为了两件事 —— 占地重叠的牌之间要有 y 台阶
## 不然穿模，以及玩家双击得能把它们摞起来。「不够 PILE_CHUNK 不摞」说的是不替玩家
## 收拢，不是不成组，所以这条口径认的是收拢与否
func _loose_cash_left(main: Node, board: Board) -> int:
	return _loose_cash_entities(main, board).size()

## 左侧带里还散着（不在任何摞里）的现金卡实体
func _loose_cash_entities(main: Node, board: Board) -> Array:
	var out: Array = []
	for c in main.state.players[GameState.PLAYER]["cards"]:
		if not main.entities.has(c["uid"]):
			continue
		var e = main.entities[c["uid"]]
		if not is_instance_valid(e) or not main.layout._in_settle_zone(e):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT or def.get("res") != CardDB.RES_CASH:
			continue
		if not _in_pile(board, e):
			out.append(e)
	return out

## 这张卡在不在一个「摞」里（收拢态的组）
func _in_pile(board: Board, e: CardEntity) -> bool:
	var g: Variant = board.group_of(e)
	return g != null and bool(g.get("compact", false))

## made 里真正是「摞」的那几个（收拢态）。余数组也在 made 里，但它不是摞
func _piles_only(made: Array) -> Array:
	var out: Array = []
	for gg in made:
		if gg.get("compact", false):
			out.append(gg)
	return out

## 新建了哪几摞：Dictionary 的 == 是逐键深比较，两摞同尺寸就可能相等，认身份得用 is_same
func _new_groups(board: Board, before: Array) -> Array:
	var out: Array = []
	for gg in board.groups:
		var seen := false
		for og in before:
			if is_same(gg, og):
				seen = true
				break
		if not seen:
			out.append(gg)
	return out