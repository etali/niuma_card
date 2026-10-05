# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 理牌功能测试：玩家回合开始自动整理散牌 + BOT 组合不越界进购牌区
## 运行：godot --headless -s tests/test_tidy.gd


func _initialize() -> void:
	print("=== 理牌功能测试 ===\n")
	var main: Node = await boot_main()
	var state: GameState = main.state
	var board: Board = main.board

	# --- 1. 玩家理牌：散落现金/用户各自成摞（开局 _sync_round 已自动整理一次） ---
	main.layout._tidy_player_idle()
	await create_timer(0.6).timeout
	for i in 5:
		await physics_frame

	var cash_x := {}
	var user_x := {}
	var in_zone := true
	for c in state.players[GameState.PLAYER]["cards"]:
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT:
			continue
		var e: CardEntity = main.entities[c["uid"]]
		var p: Vector3 = e.position
		if absf(p.x) > 9.0 or p.z < board.player_min_z or p.z > board.player_max_z:
			in_zone = false
		var key := "%.1f" % p.x
		if c["def_id"] == "cash":
			cash_x[key] = cash_x.get(key, 0) + 1
		else:
			user_x[key] = user_x.get(key, 0) + 1
	check(in_zone, "玩家散牌全部在真实落牌边界内（|x|≤9，%.1f≤z≤%.1f）" % [
		board.player_min_z, board.player_max_z])
	# 每列多少张从开局配置推：被测的是「按 PLAYER_PILE_PER_COL 切列、往 +x 排」，
	# start_cash 不是被测的常量（这条曾把列内张数写死成 8+8+6，
	# 后来 rebalance 调了 start_cash，判据就一直是红的）
	var per: int = main.layout.PLAYER_PILE_PER_COL
	var pitch: float = main.layout.PLAYER_PILE_COL_PITCH
	# 两侧同一套算法，锚点各取自己那个常量
	for side in [
		{"res": CardDB.RES_CASH, "n": int(CardDB.game_rules()["start_cash"]),
			"x0": main.layout.PLAYER_PILE_CASH_ANCHOR.x, "at": cash_x},
		{"res": CardDB.RES_USER, "n": int(CardDB.game_rules()["start_user"]),
			"x0": main.layout.PLAYER_PILE_USER_ANCHOR.x, "at": user_x},
	]:
		var want: Array = col_split(int(side["n"]), per)
		var got: Array = []
		for i in want.size():
			got.append(int(side["at"].get("%.1f" % (side["x0"] + float(i) * pitch), 0)))
		check(got == want, "%s %d 张分 %d 摞：%s（x 从 %.1f 起、节距 %.1f，实际 %s）" % [
			CardDB.res_label(side["res"]), side["n"], want.size(), str(want),
			side["x0"], pitch, str(got)])
	# 理牌后必须是真实分组：拖动任意一张能整摞带走
	var cash_pile_grouped := false
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] != "cash":
			continue
		var e: CardEntity = main.entities[c["uid"]]
		var g: Variant = board.group_of(e)
		if g != null and g["cards"].size() == per:
			cash_pile_grouped = true
	check(cash_pile_grouped,
		"现金摞是真实分组（board.group_of 命中且组内 %d 张，可整摞拖动）" % per)
	# 摞内向 +z 排，首张完整卡面应落在视觉托盘内而非市场缓冲带
	var min_user_z := 99.0
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "user":
			min_user_z = minf(min_user_z, main.entities[c["uid"]].position.z)
	var visual_zone: Rect2 = main.TableRegions.zone_rect(true, false,
		int(CardDB.game_rules()["market_size"]))
	var user_north: float = min_user_z - CardEntity.CARD_SIZE.z * 0.5
	check(user_north >= visual_zone.position.y - 0.01,
		"用户初始牌面北缘 %.2f 在托盘北界 %.2f 内（完整卡面避开市场缓冲带）" % [
			user_north, visual_zone.position.y])

	# --- 2. 已编组的组合不被理牌移动 ---
	var core_id := "shuabuting"
	var seats: int = int(CardDB.get_def(core_id)["recipe_n"])
	var core: CardEntity = main._spawn_entity(
		state.add_card(GameState.PLAYER, core_id), Vector3(0, 0.3, 3.0), true)
	var users: Array = [core]
	for k in seats:
		var uc: Dictionary = state.add_card(GameState.PLAYER, "user")
		users.append(main._spawn_entity(uc, Vector3(0.3, 0.3, 3.0), true))
	var g := { "cards": users, "label": null }
	board.groups.append(g)
	board._layout_group(g)
	await create_timer(0.4).timeout
	for i in 5:
		await physics_frame
	var before: Array = users.map(func(e): return e.position)
	main.layout._tidy_player_idle()
	await create_timer(0.6).timeout
	for i in 5:
		await physics_frame
	var untouched := true
	for k in users.size():
		if users[k].position.distance_to(before[k]) > 0.05:
			untouched = false
	check(untouched, "已编组的组合不被理牌移动")
	# 编组后再理一次牌，量的是「编了组的那 recipe_n 张不算散牌」：
	# 散牌仍该是开局那 start_user 张、按 per 切成同样几列。
	# 必须编组后重扫（上面第 1 节的 user_x 是编组前的快照，复述它等于什么都没考）——
	# 理牌要是把编了组的也数进去，散牌就会按 start_user + recipe_n 张重新排列，
	# 列数和各列张数当场对不上。
	#
	# 扫的时候**不排除**编了组的那几张：排除掉等于自己把要查的东西藏起来。
	# 实测过 —— 把 `_collect_idle_units` 里「编了组的不算散牌」那道闸去掉，
	# 编组那 recipe_n 张也被摊进网格，可没编组那 start_user 张仍排在前两列（8/2），
	# 于是「排除编组后再数」照旧全绿，只有上面那条「不被理牌移动」响。
	# 数网格上的**所有**用户卡才抓得住：那时是 17 张 → [8, 8, 1]，两条一起红。
	# 「在网格上」由 idle_x_hist 按列格筛（锚点 + 整数格 × pitch）：编了组的停在组合
	# 位置、x 不落在格上（实测 0.0），进不来；上面那条「不被理牌移动」正好钉住
	# 它们没挪窝，所以正常情况下这个直方图里只有散牌
	var idle_want: Array = col_split(int(CardDB.game_rules()["start_user"]), per)
	var idle_at: Dictionary = idle_x_hist(main, CardDB.RES_USER,
		main.layout.PLAYER_PILE_USER_ANCHOR.x, pitch)
	var idle_got: Array = []
	for i in idle_want.size():
		idle_got.append(int(idle_at.get(
			"%.1f" % (main.layout.PLAYER_PILE_USER_ANCHOR.x + float(i) * pitch), 0)))
	check(idle_got == idle_want,
		"编组后用户摞仍只统计散牌（%d 张编进组合不算，散牌 %s，实际 %s）" % [
			users.size() - 1, str(idle_want), str(idle_got)])
	# 顺带钉住「多出来的列一列都没有」：上面那条只比前 idle_want.size() 列，
	# 多摊出第 3 列时前两列可能仍是 8/2，得数总列数才抓得住
	check(idle_at.size() == idle_want.size(),
		"散牌只占 %d 列（实际 %d 列：%s）" % [
			idle_want.size(), idle_at.size(), str(idle_at)])

	# --- 3. BOT 长组合：分列摊开（列数按预算算）、不横着出格、不越进购牌区 ---
	var a_core: Dictionary = state.add_card(GameState.BOT, core_id)
	var a_e: CardEntity = main._spawn_entity(a_core, Vector3(0, 0.05, -3.6), false)
	var a_users: Array = []
	for k in seats:
		var uc: Dictionary = state.add_card(GameState.BOT, "user")
		a_users.append(main._spawn_entity(uc, Vector3(0, 0.05, -3.6), false))
	var combo_uids: Array = [a_core["uid"]]
	for e in a_users:
		combo_uids.append(e.uid)
	var r: Dictionary = state.create_combo(GameState.BOT, combo_uids)
	check(r["ok"], "BOT「%s+用户×%d」编组成立" % [CardDB.card_name(core_id), seats])
	main.layout._layout_bot_zone()
	await create_timer(0.6).timeout
	for i in 5:
		await physics_frame
	var all_clamped := true
	var min_z := INF
	var max_z := -INF
	var xs := {}
	for u in combo_uids:
		var e: CardEntity = main.entities[u]
		if e.position.z > -2.0 + 0.01:
			all_clamped = false
		xs[snappedf(e.position.x, 0.1)] = true
		min_z = minf(min_z, e.position.z)
		max_z = maxf(max_z, e.position.z)
	check(all_clamped, "BOT 组合所有卡 z ≤ -2.0（不越进购牌区 MARKET_Z=-1.6）")
	# 原先这儿是「保持单列竖排」。那条连着让 8 张组合一律收拢成一块 ——
	# z 向一列最多摊得开 4 张，而配方大多在 5 张以上，摊不开就退回收拢，
	# 屏幕上只看得见最南那一张。现在长组合分列摊开，所以这条改成量
	# 「分的列数正是预算允许的列数」，而不是「一列」
	var want_cols: int = main.layout.combo_cols(combo_uids.size())
	check(xs.size() == want_cols, "%d 张组合分成 %d 列（实际 %d 列）" % [
		combo_uids.size(), want_cols, xs.size()])
	# 横着不许出格：整片的宽度不超过前行能用的宽度。
	# 这条是「单列」那条真正想守的东西 —— 组合不能横着摊到把整行占掉
	var col_xs: Array = xs.keys()
	col_xs.sort()
	var wide: float = col_xs[-1] - col_xs[0] + CardEntity.CARD_SIZE.x
	var room: float = main.layout.combo_row_width()
	check(wide <= room + 0.01, "组合横着没出格（宽 %.2f ≤ %.2f）" % [wide, room])
	# 一列之内仍然只占一张卡的纵深：摊开的那一列摊到标题带那条线为止，
	# 摊过头就是整片牌往南长进货架里
	check(max_z - min_z <= CardEntity.CARD_SIZE.z,
		"BOT 组合一列的纵深在一张卡以内（z 跨度 %.2f ≤ %.2f）" % [
			max_z - min_z, CardEntity.CARD_SIZE.z])
	check(main.layout._bot_pile_of_uid.has(a_core["uid"]), "BOT 组合登记成摞（攻击阶段点摞顶能找到靶）")

	await _check_flight_clearance(main)

	finish()


## 理牌**飞行途中**也要守住 Board.ladder_y 那条不变量：占地重叠的两张卡
## y 差必须大于 CardEntity.FACE_SPAN_Y，否则下面那张的图标/卡名比上面那张的
## 底板还高，从底板里穿出来（穿模）。
##
## 为什么要专门量飞行途中：那条不变量的所有既有判据都在**牌停下之后**量，
## 静止时靠台阶高自动满足。而理牌一趟里有牌从二十张厚的摞顶飞到别处的底座，
## 半路穿过第三摞的中间高度 —— 玩家看见的就是图标在别的牌里划过去。
## 实测原先一趟重排里有 5 对牌的最小 y 差落到 0.003~0.020
func _check_flight_clearance(main: Node) -> void:
	print("--- 理牌飞行途中不穿模 ---")
	var state: GameState = main.state
	# 造一摞厚的现金：越厚，从摞顶出发的那张要下降越多，也就越容易在半路
	# 蹭到别人。二十来张是一局打到中盘的常态
	var thick: Array = []
	for i in 20:
		var c: Dictionary = state.add_card(GameState.BOT, "cash")
		thick.append(main._spawn_entity(c, Vector3(-7.0 + float(i) * 0.05, 3.0, -6.5), false))
	main.layout._layout_bot_idle()
	await bot_moves_landed(main)
	await settle()

	# --- 判据一：整条航迹上都不越线（按算式采样，不靠逐帧读） ---
	# 逐帧读只采到帧率给的那几个点，短程的牌可能只被采到两三帧，
	# 越线的那一小段正好落在两帧之间就漏掉了（memory: vacuous-mutation-two-flavors）。
	# 直接问 _bot_arc「f 处在哪」，密度由这里说
	var arc_bad: Array = []
	# 「能动 y 的窗口从哪开始」这个数由判据**自己按定义算**（见下面 _gate_of），
	# 不读 foot_gate()：读被测量等于判据和被测代码取了同一个值，改错了一起错
	# （memory: green-suite-cant-prove-mapping）。
	# 定义是「两片占地肯定分开」= x 差 ≥ CARD_SIZE.x 或 z 差 ≥ CARD_SIZE.z
	var gap: float = Board.STACK_GAP.y
	# 一摞平移：两张同摞的牌各挪 1.25，y 差就是台阶高。这一种最容易被
	# 「抬到同一个高度」的写法压成共面（实测 27 对全掉到 0.002 以下）
	var slide_a := [Vector3(0, 0.05, -4.1), Vector3(-1.25, 0.05, -4.1)]
	var slide_b := [Vector3(0, 0.05 + gap, -4.1), Vector3(-1.25, 0.05 + gap, -4.1)]
	# 长程：从厚摞里飞去远处的底座。**两张都走长程**，出发时挨着、落点也挨着 ——
	# 「抬到同一个高度」的写法就是在这一对上把 y 差吃干净的（低的抬得多）
	var dive_a := [Vector3(-6.4, 1.5, -6.5), Vector3(1.25, 0.05, -3.7)]
	var dive_b := [Vector3(-6.4, 1.5 - gap, -6.5), Vector3(1.25, 0.05 - gap, -3.7)]
	# 停着不动的牌：from == at，占地就是它站的那片
	var sits_at_src := [Vector3(-6.4, 1.5 - gap, -6.5), Vector3(-6.4, 1.5 - gap, -6.5)]
	var sits_at_dst := [Vector3(1.25, 0.05 + gap, -3.7), Vector3(1.25, 0.05 + gap, -3.7)]
	var sits_above := [Vector3(0, 0.05 + gap, -4.1), Vector3(0, 0.05 + gap, -4.1)]
	var pairs: Array = [
		# 盯「抬同一个 Δy 而不是同一个高度」
		["一摞平移的两张", slide_a, slide_b],
		["同摞出发、落点也挨着的两张长程", dive_a, dive_b],
		# 盯「出发那片占地上冻住 y」：同伴就停在出发点下面一格
		["长程起飞的和它原摞的同伴", dive_a, sits_at_src],
		# 盯「进落点那片占地就停住 y」：同伴已经停在落点上面一格
		["长程降落的和它新邻座", dive_a, sits_at_dst],
		# 盯「短程全程平飞」：平移的那张头顶上停着一张，一抬就撞
		["平移的和它上面那张", slide_a, sits_above],
	]
	var lift: float = 2.0     # 比桌上最高的摞还高一截，照 _flush_bot_moves 的算法
	var steps := 400
	for pr in pairs:
		var name: String = pr[0]
		var pa: Array = pr[1]
		var pb: Array = pr[2]
		var worst := INF
		var ga: float = _gate_of(pa[0], pa[1])
		var gb: float = _gate_of(pb[0], pb[1])
		for i in steps + 1:
			var f: float = float(i) / float(steps)
			var a: Vector3 = _arc_at(main, pa[0], pa[1], ga, lift, f)
			var b: Vector3 = _arc_at(main, pb[0], pb[1], gb, lift, f)
			if absf(a.x - b.x) >= CardEntity.CARD_SIZE.x - 0.02:
				continue
			if absf(a.z - b.z) >= CardEntity.CARD_SIZE.z - 0.02:
				continue
			worst = minf(worst, absf(a.y - b.y))
		if worst < CardEntity.FACE_SPAN_Y:
			arc_bad.append("%s 最小 y 差 %.4f" % [name, worst])
	check(arc_bad.is_empty(), "航迹上占地重叠时 y 差都 > %.3f（越线的：%s）" % [
		CardEntity.FACE_SPAN_Y, "无" if arc_bad.is_empty() else ", ".join(arc_bad)])

	# --- 判据一之二：航迹是连续的，不许有跳变 ---
	# 上面那条按 400 个采样点比对相邻两张牌，**跳变它是量不出来的**：
	# 采样点之间跨过去的那一瞬没人看。而三段式航迹的两段平飞一旦失效
	# （比如闸门写成常假），w = (u-t0)/(t1-t0) 就跑到 [0,1] 之外，
	# sin(PI*w) 翻号，牌一出发先跳到落点**下面**去（实测 y 从 1.5 掉到 -0.496），
	# 到 f=1 再瞬移回来 —— 屏幕上就是牌闪一下、从桌面底下钻过去。
	#
	# 判据是「最大的一步 / 平均的一步」，不是「最大的一步 / 整段行程」：
	# 后者试过，太松 —— 起飞那头断掉时牌只跳 1.24，而整段行程有 8.27，
	# 1.24 连四分之一都不到，量不出来。
	# 比值这个形式跟行程长短无关：余弦缓动下最快的中点也只有平均步长的 π/2 倍，
	# 所以连续的航迹这个比值必然是个小数，跳一下就爆到几十
	var jump_bad: Array = []
	for pr in pairs:
		var seg: Array = pr[1]
		var a0: Vector3 = seg[0]
		var a1: Vector3 = seg[1]
		var g: float = _gate_of(a0, a1)
		var prev: Vector3 = _arc_at(main, a0, a1, g, lift, 0.0)
		var worst_jump := 0.0
		var walked := 0.0
		for i in range(1, steps + 1):
			var cur: Vector3 = _arc_at(main, a0, a1, g, lift, float(i) / float(steps))
			var d: float = prev.distance_to(cur)
			worst_jump = maxf(worst_jump, d)
			walked += d
			prev = cur
		var mean: float = maxf(walked / float(steps), 1e-6)
		if worst_jump > mean * 4.0:
			jump_bad.append("%s 最大一步是平均的 %.1f 倍（%.3f vs %.3f）" % [
				pr[0], worst_jump / mean, worst_jump, mean])
	check(jump_bad.is_empty(), "航迹上没有跳变（坏的：%s）" % [
		"无" if jump_bad.is_empty() else ", ".join(jump_bad)])

	# --- 判据二：两头都精确落在摆放算出来的坐标上 ---
	# lerp(from, at, 1.0) 是 from + (at - from) * 1.0，浮点下可以差一个 ulp。
	# 而落点常常正好压在别的判据的分桶边界上（比如 x=6.25 按 0.1 分列），
	# 差一个 ulp 就把一摞记成跨两列 —— 实跑遇到过
	# 端点必须挑**已知会掉 ulp 的**那几对，否则这条判据是空的：
	# 大多数坐标下 from + (at - from) 正好回到 at，随手挑一对量不出差别
	# （memory: vacuous-mutation-two-flavors 的第一种「换的值恰好合法」）。
	# 下面这几对是实测出来的：a.lerp(b, 1.0) != b
	var ulp_pairs: Array = [
		[Vector3(-7.0, 3.0, -6.5), Vector3(6.25, 0.05, -4.1)],
		[Vector3(-8.0, 0.05, 1.0), Vector3(6.25, 0.3, -3.3)],
		[Vector3(0.3, 0.7, -0.9), Vector3(6.25, 0.098, -3.3)],
	]
	var lerp_drifts := false
	for pr in ulp_pairs:
		if (pr[0] as Vector3).lerp(pr[1], 1.0) != pr[1]:
			lerp_drifts = true
	check(lerp_drifts, "选的端点确实会掉 ulp（lerp 到 1.0 回不到落点，否则下一条是空判据）")
	var ends_bad: Array = []
	for pr in ulp_pairs + pairs.map(func(x: Array) -> Array: return x[1]):
		var a: Vector3 = pr[0]
		var b: Vector3 = pr[1]
		var g2: float = _gate_of(a, b)
		if _arc_at(main, a, b, g2, lift, 1.0) != b:
			ends_bad.append("f=1 落在 %s 而不是 %s" % [_arc_at(main, a, b, g2, lift, 1.0), b])
		if _arc_at(main, a, b, g2, lift, 0.0) != a:
			ends_bad.append("f=0 落在 %s 而不是 %s" % [_arc_at(main, a, b, g2, lift, 0.0), a])
	check(ends_bad.is_empty(), "航迹两头逐位等于出发点/落点（坏的：%s）" % [
		"无" if ends_bad.is_empty() else ", ".join(ends_bad.slice(0, 3))])

	# --- 判据二之二：生产侧的闸门就是「占地最早分开的那一刻」 ---
	#
	# 前面几条都拿 _gate_of（判据自己抄的那份矩形算式）当闸门喂给 _bot_arc，
	# 所以生产侧的 foot_gate 写成什么形状它们一概看不见。第 3 节读生产侧，
	# 但那儿的口径是「跨摞掠过 ≤7 对」—— 这一版把节距撑开之后，圆形闸门和
	# 矩形闸门掠过的**是同一 7 对**（实测两边逐位同一组 uid，只有 y 差的小数不同），
	# 于是那条判据再也分不出两种形状。也就是说问题 1 的修复一度没有任何判据钉着。
	#
	# 这一条换个口径，不数对数，直接问定义：闸门是「沿这条直线走到两片占地
	# 肯定分开」的**最早**那个 f。最早这件事得自己走一遍线去找，不能再抄算式 ——
	# 抄了就跟 _gate_of 一样，跟被测代码同错同对（memory: green-suite-cant-prove-mapping）。
	#
	# 圆形写法差在「晚」：它按中心距到卡对角线才算分开，而占地是矩形，
	# 纯 x 位移上 x 差够了就分开了，对角线要求的距离是 x 边的 1.73 倍 ——
	# 于是闸门晚开，贴着出发那片占地平飞的那一段被拖长，正是当初 14 对的来源
	var scan := 4000
	var gate_bad: Array = []
	# 挑的位移要覆盖各个形状：纯 x（圆形晚得最多）、纯 z、对角线（两种写法
	# 最接近的地方）、以及短到全程都在占地里的（闸门该 ≥ 0.5，走平飞）
	var gate_moves: Array = [
		["纯 x 长程", Vector3(0, 0.05, -4.1), Vector3(8.0, 0.05, -4.1)],
		["纯 z 长程", Vector3(0, 0.05, -6.5), Vector3(0, 0.05, 1.0)],
		["对角线", Vector3(-6.4, 1.5, -6.5), Vector3(1.25, 0.05, -3.7)],
		["x 多 z 少", Vector3(-7.0, 3.0, -6.5), Vector3(6.25, 0.05, -4.1)],
		["短程（全程压在占地里）", Vector3(0, 0.05, -4.1), Vector3(0.6, 0.05, -4.1)],
	]
	for mv in gate_moves:
		var nm: String = mv[0]
		var a: Vector3 = mv[1]
		var b: Vector3 = mv[2]
		# 走一遍线找「最早分开」：一步一步问占地分没分，第一次分开就是答案。
		# 步长取 1/4000，比下面的余量 0.01 细得多
		var first := INF
		for i in scan + 1:
			var f: float = float(i) / float(scan)
			var pt: Vector3 = a.lerp(b, f)
			if absf(pt.x - a.x) >= CardEntity.CARD_SIZE.x \
					or absf(pt.z - a.z) >= CardEntity.CARD_SIZE.z:
				first = f
				break
		var got: float = main.layout.foot_gate(a, b)
		if first == INF:
			# 整条线都在占地里：闸门要 ≥ 0.5，调用处才走平飞那一支
			if got < 0.5:
				gate_bad.append("%s：全程都在占地里、闸门却是 %.4f（该 ≥ 0.5）" % [nm, got])
		elif absf(got - first) > 0.01:
			gate_bad.append("%s：闸门 %.4f，实走出来最早分开在 %.4f" % [nm, got, first])
	check(gate_bad.is_empty(), "闸门就是占地最早分开的那一刻（对不上的：%s）" % [
		"无" if gate_bad.is_empty() else ", ".join(gate_bad)])

	# --- 判据三：真跑一趟理牌，逐帧量整桌 ---
	# 上面按算式量的是「航迹本身对不对」，这一条量的是「一趟里真的没有牌
	# 被安排成互相穿过去」—— 一趟里谁跟谁同时在飞、飞去哪，是 _flush_bot_moves
	# 决定的，算式那头看不见
	# 核心卡不写死：这一趟必须**动到那一摞封了顶的**散资源摞，
	# 否则摞底那一堆重合牌根本不在这一趟的飞行计划里，下面「重合牌确实出现了」
	# 那条就恒假 —— 而红的是它，根在这儿（实测：配方从吃现金改成吃用户之后，
	# 拿走的是 8 张的用户摞，40 张的现金摞一张没动，重合对数直接掉到 0）
	var core_id := _core_pulling_capped_pile(main)
	check(core_id != "", "卡表里有一张吃「封了顶那一摞」的核心卡（没有的话这一节量不到重合）")
	if core_id == "":
		return
	var p2: Dictionary = state.add_card(GameState.BOT, core_id)
	# 出生点得挑一片**真空着**的地方，不能写死一个坐标：叠在别的牌上出生的话
	# 出发时 y 差就是 0，量出来的越线是判据自己造的（实测在 x=11 上就撞上了
	# 摊开的现金片 —— BOT_SPREAD_MAX_X 是 12.4，那一片能长到那儿）
	var born: Vector3 = _empty_spot(main)
	check(born != Vector3.INF, "给新卡找到了一块空地出生（找不到就说明桌面被铺满了）")
	main._spawn_entity(p2, born, false)
	var zk_def: Dictionary = CardDB.get_def(core_id)
	var zk_n := int(zk_def["recipe_n"])
	# 同上一节：喂的资源按卡表的 recipe_res 取，不写死币种
	var zk_unit := CardDB.unit_id(str(zk_def["recipe_res"]))
	var locked := {}
	for combo in state.combos:
		for u in combo["uids"]:
			locked[u] = true
	var uids2: Array = [p2["uid"]]
	for c in state.players[GameState.BOT]["cards"]:
		if c["def_id"] == zk_unit and uids2.size() <= zk_n and not locked.has(c["uid"]):
			uids2.append(c["uid"])
	check(state.create_combo(GameState.BOT, uids2).get("ok", false),
		"又编一个组合（%s，BOT 区多一摞 → 前行重新居中，这才是真在动的那一趟）" % core_id)
	# 这一趟**出发前**谁在摞底那一堆重合牌里，得在 _layout_bot_idle 清登记表之前问。
	# 这趟刚拿走 3 张现金编了组合，后面的牌整体往下挪 3 级，原来重合的那几张
	# 有的要爬出来 —— 它们的出发点就是那一堆，起飞瞬间 y 差本来就是 0。
	# 只看落地那头的话，这几对会被记成「同摞压成平面」，红的却是上一趟
	# 已经认下的那份重合在解开（见下面 heap_pre 的用法）
	var heap_pre: Dictionary = _heap_members(main)
	main.layout._layout_bot_idle()
	# 航迹按**算式密采**，不按物理帧采。
	# 原先这儿是「逐物理帧扫整桌」。那样采不准：一趟 0.3 秒只落到十几帧上，
	# 掠过一瞬的那种会不会被采到看帧的相位 —— 实测同一台机器上同一条判据
	# 时而 2 对时而 4 对（其中 30|70、31|71 两对只在帧正好落进窗口时才现形）。
	# 一条时而红时而绿的判据比没有更坏：它红的时候没人信，绿的时候也不能信
	# （memory: sampling-cannot-see-jumps）。
	# 现在从 _bot_flight（摆放那头登记的这一趟的 from/at/lift）拿到整趟的计划，
	# 拿 _bot_arc 逐张按同一批 f 采 —— 同一时刻的整桌姿态是算得出来的
	var flight: Dictionary = main.layout._bot_flight.duplicate(true)
	check(flight.size() >= 2, "这一趟真的有牌在飞（计划里 %d 张，0~1 张就是判据白站）"
		% flight.size())
	var worst_pair := {}
	_scan_flight(main, flight, worst_pair)
	# 计划和实跑之间搭一句：牌真在这条曲线上飞。
	# 少了这一句，上面那套判据只证明「计划是干净的」——_bot_fly 把 lift 丢了、
	# 或者把 from 传成落点，计划照旧干净，牌在屏幕上却是直接插过去的。
	# 趁补间还在跑的时候采几帧，每帧问「离自己那条曲线最远多远」
	var off := 0.0
	var frames := 0
	while main.layout.bot_moving() and frames < 60:
		await physics_frame
		frames += 1
		off = maxf(off, _off_plan(main, flight))
	check(frames > 1, "补间真的在跑（采到 %d 帧）" % frames)
	# 余量按台阶高的量级取：偏这么多就不是浮点尾数，是飞在另一条路上
	check(off < Board.STACK_GAP.y,
		"在飞的牌都贴着自己那条计划航迹（离曲线最远 %.4f < %.3f）" % [
			off, Board.STACK_GAP.y])
	# 越线的对分两类，因为**摆放那头只保得住其中一类**（见 settle_layout.gd
	# 的 foot_gate 那段注释）：
	#   同摞：y 差由台阶高定，飞的时候由「整趟共用一个 Δy」原样保住 ——
	#         这是当初报的那个症状（一整摞飞到半路压成一个平面，412 对越线），
	#         这一类必须一对都没有
	#   跨摞：贴着落点高度平滑那一段会从**邻摞已经停好的**牌上面擦过去。
	#         这一类归**摆放**管，不归航迹管：两处座位相距不足一张卡，
	#         而各摞底座高度都是 0.05，横着进座位就一定从邻摞上面过。
	#         航迹这头能做的已经做完了（foot_gate 按矩形算，14 对压到 7 对），
	#         再往下要么把座位拉开、要么给降落留一条空走廊，
	#         那是重排整个 BOT 区（见 foot_gate 那段末尾）。
	#         所以这里不要求它为零，只钉住「不许变多」—— 一涨就说明又多了一类穿模
	var pile_of: Dictionary = main.layout._bot_pile_of_uid
	# 同摞那一类里挖掉一小块：收拢摞的台阶封顶在 back_pile_cap() 级
	# （Board.capped_offset），第 cap 张往后都停在摞底那一级上，**故意**跟那一级
	# 本来那张完全重合，y 差为 0。开这个口子是为了让一摞的占地不随张数长
	# （不封顶的话 100 张现金摞到 y=4.5、南缘压在货架牌上），代价是重合的那几张
	# 看不出是几张 —— 由侧边清单（数真牌）和点摞攻击（按 key 整摞啃）补出口。
	#
	# 口子只对「同一摞、收拢态、摞内次序都 ≥ cap-1」的对开。同一摞里 cap-1 之前
	# 那些仍然一对都不许越线：它们每张占一级台阶，压平了就是当初报的那个症状
	var cap: int = main.layout.back_pile_cap()
	var heap_post: Dictionary = _heap_members(main)
	var same_bad: Array = []
	var cross_bad: Array = []
	var coincide: Array = []
	var cross_keys := {}
	for k in worst_pair:
		if worst_pair[k] >= CardEntity.FACE_SPAN_Y:
			continue
		var two: Array = k.split("|")
		var ua := int(two[0])
		var ub := int(two[1])
		var ka: String = pile_of.get(ua, "")
		var kb: String = pile_of.get(ub, "")
		var line := "%s(%.4f)" % [k, worst_pair[k]]
		if ka == "" or ka != kb:
			cross_bad.append(line)
			cross_keys[ka + " x " + kb] = true
			continue
		# 两头都问：出发前一起在那一堆里（这一趟正在解开）算，落地后一起在
		# 那一堆里（这一趟正在合上）也算。只问落地那头会把「爬出来的那两张」
		# 记成越线；只问出发那头会漏掉新合进去的那几张
		var pre_both: bool = heap_pre.get(ua, "") != "" \
			and heap_pre[ua] == heap_pre.get(ub, "")
		var post_both: bool = heap_post.get(ua, "") != "" \
			and heap_post[ua] == heap_post.get(ub, "")
		if not (pre_both or post_both):
			same_bad.append(line)
			continue
		# 口子只放过「真的重合」和「真的分开」这两种落地：一张爬出来却只爬了
		# 半级（落地 y 差 0 < dy < FACE_SPAN_Y）是穿模，不许借这个口子过
		var dy_end: float = absf(main.entities[ua].position.y
			- main.entities[ub].position.y)
		if dy_end < 0.0005 or dy_end >= CardEntity.FACE_SPAN_Y:
			coincide.append(line)
		else:
			same_bad.append(line)
	same_bad.sort()
	cross_bad.sort()
	check(same_bad.is_empty(), "一趟理牌里同摞、占地重叠的牌 y 差都 > %.3f（越线的 %d 对：%s）" % [
		CardEntity.FACE_SPAN_Y, same_bad.size(),
		"无" if same_bad.is_empty() else ", ".join(same_bad.slice(0, 6))])
	# 7 对是实测的残留：uid 30/31 两张现金飞进 bot_combo_1 的座位，而 bot_combo_0
	# 的东侧那一列（72/73/74）就停在它们进座位的路上，两处座位相距不足一张卡。
	#
	# 这个数从 2 改成 7 不是「变差了」，是**原先那个 2 是采样采出来的**：
	# 这一节以前按物理帧扫整桌，一趟 0.3 秒只落到十几帧上，7 对里只有 2 对
	# 恰好被采到（而且同一台机器上重跑会变成 4 对）。改成按算式密采之后
	# 两档 TEST_SPEED、重跑多次都是逐位相同的 7 对。
	# 顺带证实了 settle_layout.gd 那条「闸门半径两头堵」的注释是被采样骗的：
	# 圆形闸门（2.08）密采下是 14 对，换成按矩形算的 foot_gate 之后 7 对。
	#
	# 注意这个 14 对 7 是**当时那个节距下**测的。后来把稀疏行的节距撑开到
	# BOT_SLOT_PITCH 之后航迹被拉开，圆形闸门在这一趟里也只掠过 7 对
	# （跟矩形是逐位同一组 uid，只有 y 差的小数不同）—— 所以这条判据现在
	# 分不出闸门是什么形状了，别再拿它当闸门形状的防线。
	# 钉闸门形状的是第 2 节的「闸门就是占地最早分开的那一刻」，那条按定义走线量
	#
	# 写成上限而不是等号：这一趟里有几对跨摞掠过跟牌面内容有关（配方大小、
	# BOT 手里恰好有什么），钉等号会变成一条改了卡表就红的判据。
	#
	# 这个上限**跟着配方深度走**，不是一个魔数：新组合从散摞里抽走 recipe_n 张，
	# 抽得越深、后面往前挪的牌越多、掠过的对数越多。实测两档：
	# 抽 2 张时 7 对（当时最便宜的吃现金攻击卡是做空报告，配方 2），
	# 抽 3 张时 9 对（做空报告这一轮改成吃用户，最浅的变成地推扫码，配方 3）。
	# 两点拟不出公式，所以按「每多抽一张多两对」留量，宽一点也没关系 ——
	# 真正钉住形状的是下面那条**分类**判据，不是这个数
	var cross_cap := 3 + zk_n * 2
	check(cross_bad.size() <= cross_cap,
		"跨摞掠过的对数没变多（配方抽 %d 张 → ≤%d，现在 %d 对：%s）" % [
			zk_n, cross_cap, cross_bad.size(),
			"无" if cross_bad.is_empty() else ", ".join(cross_bad.slice(0, 6))])
	# 分类判据：跨摞掠过的必须全是**两个组合座位之间**的事。
	# 这才是 settle_layout.gd foot_gate 那段说的那一类 ——「两处座位相距不足一张卡，
	# 而各摞底座高度都是 0.05，横着进座位就一定从邻摞上面过」，归摆放管不归航迹管。
	# 少了这一条，上面那个上限就是唯一的防线，而它宽到 9：哪天散资源摞
	# 或货架牌也开始被掠过（那是另一类穿模、另一个成因），对数只要不超上限就没人看着
	var cross_shape: Array = []
	for k in cross_keys:
		var two: Array = str(k).split(" x ")
		# 用 is_front_pile 而不是自己再写一遍 begins_with：那边的注释说了缘由
		# （判前行的地方有四五处，各写一遍的话新加一种摞只在其中几处算前行）。
		# 它是静态的，但 settle_layout.gd 没有 class_name，所以从实例上调
		if not (main.layout.is_front_pile(str(two[0]))
				and main.layout.is_front_pile(str(two[1]))):
			cross_shape.append(str(k))
	cross_shape.sort()
	check(cross_shape.is_empty(),
		"跨摞掠过的只发生在组合座位之间（不该出现的摞对：%s）" % [
			"无" if cross_shape.is_empty() else ", ".join(cross_shape)])
	# 这个口子**这一趟真的用上了**。不钉这条的话，口子写得再宽也看不出来 ——
	# 哪天摞不再封顶（重合消失），上面那条照旧全绿，而口子会静静留在判据里
	# 等下一次误放行。「重合了几对」不在这儿钉：那个数由 cap 和摞里张数算得出，
	# 拿它当判据等于把摆放那头的算式抄一遍再和自己比。摞的形状归
	# tests/test_bot_pile.gd 的「占地不随张数长」那一节按真几何量
	check(not coincide.is_empty(),
		"摞底那一堆重合牌确实出现了（放行 %d 对；一对都没有说明摞不再封顶、口子该删）"
			% coincide.size())
	await settle()

	# --- 判据四：没牌要动的那一趟，一条补间都不发 ---
	# bot_moving() 是测试和 main 两头的同步条件（「摆完了没有」）。
	# 每张牌都发一条补间的话，一趟里明明没牌换地方，这个问题在整个
	# BOT_MOVE_TIME 里都答「没有」—— 等的人白等一趟，而且掩盖了「这一趟
	# 其实什么都没发生」这件事
	main.layout._layout_bot_idle()
	await bot_moves_landed(main)
	await settle()
	var before := {}
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e):
			before[uid] = e.position
	# 再理一趟：上一趟已经把每张牌放到位了，这一趟每张牌的落点就是它现在站的地方
	main.layout._layout_bot_idle()
	check(not main.layout.bot_moving(),
		"落点没变的那一趟不发补间（bot_moving 立刻是假，否则同步条件白等一趟）")
	var drifted: Array = []
	for uid in before:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e) and e.position.distance_to(before[uid]) > 0.0005:
			drifted.append(str(uid))
	check(drifted.is_empty(), "而且牌一张都没挪（漂了的：%s）" % [
		"无" if drifted.is_empty() else ", ".join(drifted.slice(0, 5))])


## 桌面上一块没有任何牌压着的空地。沿 +x 往外找，找不到返回 Vector3.INF
func _empty_spot(main: Node) -> Vector3:
	for i in 40:
		var at := Vector3(14.0 + float(i) * 2.0, 0.05, -3.6)
		var free := true
		for uid in main.entities:
			var e: CardEntity = main.entities[uid]
			if not is_instance_valid(e):
				continue
			if absf(e.position.x - at.x) < CardEntity.CARD_SIZE.x \
					and absf(e.position.z - at.z) < CardEntity.CARD_SIZE.z:
				free = false
				break
		if free:
			return at
	return Vector3.INF


## 问航迹上 f 处的坐标。span 由两端自己算，别让调用处各算一遍算歪
func _arc_at(main: Node, from: Vector3, at: Vector3, gate: float,
		lift: float, f: float) -> Vector3:
	var span: float = Vector2(at.x - from.x, at.z - from.z).length()
	return main.layout._bot_arc(from, at, span, gate, lift, f)


## 「能动 y 的窗口从哪开始」——**判据自己按定义算**的那一份，不读 foot_gate()。
##
## 定义：沿这条直线走到两片占地肯定分开，也就是 x 差 ≥ CARD_SIZE.x
## 或者 z 差 ≥ CARD_SIZE.z，先满足的那个。
## 抄一份而不是读被测量：读了就是判据和被测代码取同一个值，改错了一起错
## （memory: green-suite-cant-prove-mapping）。第 3 节反过来 —— 那儿要量的是
## 「生产侧这一趟的计划干不干净」，就必须读生产侧的 foot_gate
func _gate_of(from: Vector3, at: Vector3) -> float:
	var dx: float = absf(at.x - from.x)
	var dz: float = absf(at.z - from.z)
	var fx: float = CardEntity.CARD_SIZE.x / dx if dx > 0.0 else INF
	var fz: float = CardEntity.CARD_SIZE.z / dz if dz > 0.0 else INF
	return minf(fx, fz)


## 此刻各收拢摞「摞底那一堆重合牌」的成员：uid → 摞的 key。
##
## 收拢摞的台阶封顶在 back_pile_cap() 级（Board.capped_offset），次序第 cap-1 张
## 往后都停在摞底那一级上、彼此完全重合。这几张是防穿模那条不变量唯一放行的对象，
## 所以「谁在里面」得算清楚，不能按 y 坐标反推（飞行中的牌 y 是插值出来的，
## 反推会把半路擦过的牌也算进来）。
##
## 摊开的摞不进来：它们每张各占一级台阶，没有重合这回事
## 挑一张「配方吃的正是那一摞封了顶的散资源」的核心卡，返回 def_id（没有则空串）。
##
## 为什么要挑而不是写死：摞底那一堆重合牌只出现在**张数超过 back_pile_cap** 的
## 那一摞里，而这一节要量的是「这一趟真的在动那一堆」。核心卡吃的币种一改
## （卡表调配方就会），拿走的就是另一摞，那一堆一张没动 ——
## 下面那条「重合牌确实出现了」会恒假，而它红起来指的方向是「摞不再封顶」
func _core_pulling_capped_pile(main: Node) -> String:
	var cap: int = main.layout.back_pile_cap()
	var capped: Array = []
	for key in main.layout._bot_pile_uids:
		if not bool(main.layout._bot_pile_compact.get(key, false)):
			continue
		if int(main.layout._bot_pile_uids[key].size()) <= cap:
			continue
		if str(key).begins_with("bot_cash"):
			capped.append(CardDB.RES_CASH)
		elif str(key).begins_with("bot_user"):
			capped.append(CardDB.RES_USER)
	# 配方最小的先挑：拿走的张数越少，剩下那一摞越可能还超着 cap
	# （拿到不足 cap 的话重合整个消失，判据同样恒假）
	var best := ""
	var best_n := 0
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if not d.has("recipe_res") or not d.has("recipe_n"):
			continue
		if not capped.has(str(d["recipe_res"])):
			continue
		var n := int(d["recipe_n"])
		if n >= 1 and (best == "" or n < best_n):
			best = def_id
			best_n = n
	return best


func _heap_members(main: Node) -> Dictionary:
	var cap: int = main.layout.back_pile_cap()
	var out := {}
	for key in main.layout._bot_pile_uids:
		if not bool(main.layout._bot_pile_compact.get(key, false)):
			continue
		var order: Array = main.layout._bot_pile_uids[key]
		for i in range(maxi(cap - 1, 0), order.size()):
			out[int(order[i])] = str(key)
	return out


## 整趟航迹采多少个点。
##
## 采算式而不采物理帧，所以这个密度是判据自己说了算的，不再看帧率：
## 一趟 0.3 秒按物理帧只落到十几个点上，掠过一瞬的那种被不被采到看相位。
## 600 点把一趟切成 0.0005 秒一格，最快的那张（长途 ~14 单位）一格走 0.023 单位，
## 比一张卡的短边（1.2）小两个量级。
##
## 密采在这儿站得住，是因为**位置本身就是这条连续曲线**：_bot_arc 分三段、
## 接口处斜率连续，两个采样点之间牌不会跳到别处去。
## memory 里那条「采样看不见跳变」说的是位置会跳的那种（牌从桌面底下钻过去），
## 那种情形靠密度救不了，得改成查算式 —— 这里正是改成了查算式
const FLIGHT_STEPS := 600

## 拿这一趟的航迹计划把整趟采一遍，每一对「占地重叠」的牌的最小 y 差记进 worst。
## 占地按整张卡算（留 0.02 余量避免正好贴边的那种算重叠）。
##
## 只查「至少一张在飞」的对：两张都停着的对整趟 y 差一动不动，
## 那是静止时的事（Board.ladder_y 那条不变量的静态版，第 1、2 节各有判据盯）
func _scan_flight(main: Node, flight: Dictionary, worst: Dictionary) -> void:
	var still := {}
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e) and not flight.has(int(uid)):
			still[int(uid)] = e.position
	var fly: Array = flight.keys()
	var pos := {}
	for s in FLIGHT_STEPS + 1:
		var f: float = float(s) / float(FLIGHT_STEPS)
		for u in fly:
			pos[u] = _plan_at(main, flight[u], f)
		for i in fly.size():
			var ua: int = int(fly[i])
			var pa: Vector3 = pos[ua]
			for j in range(i + 1, fly.size()):
				_note_pair(worst, ua, pa, int(fly[j]), pos[fly[j]])
			for ub in still:
				_note_pair(worst, ua, pa, int(ub), still[ub])


## 计划里某张牌在 f 处的坐标。
##
## 这儿**读生产侧的 foot_gate**（跟第 1 节的 _gate_of 相反）：要量的是
## 「生产侧这一趟的计划干不干净」，闸门换成判据自己那一份就等于量了另一条航迹
func _plan_at(main: Node, plan: Dictionary, f: float) -> Vector3:
	var from: Vector3 = plan["from"]
	var at: Vector3 = plan["at"]
	var span: float = Vector2(at.x - from.x, at.z - from.z).length()
	return main.layout._bot_arc(from, at, span, main.layout.foot_gate(from, at),
		float(plan["lift"]), f)


## 一对牌在某一刻的 y 差：占地重叠才记，只留整趟最小的那个值
func _note_pair(worst: Dictionary, ua: int, pa: Vector3, ub: int, pb: Vector3) -> void:
	if absf(pa.x - pb.x) >= CardEntity.CARD_SIZE.x - 0.02:
		return
	if absf(pa.z - pb.z) >= CardEntity.CARD_SIZE.z - 0.02:
		return
	var dy: float = absf(pa.y - pb.y)
	var k := "%d|%d" % [mini(ua, ub), maxi(ua, ub)]
	if not worst.has(k) or dy < worst[k]:
		worst[k] = dy


## 此刻在飞的牌离**自己那条计划航迹**最远有多远。
##
## 上面那套判据全是在计划上量的，它证明的是「计划里没有互相穿过去」。
## 补间到底按不按计划飞，得另外问一句 —— 否则 _bot_fly 传错参数
## （比如把 lift 丢了、把 from 换成落点）在那套判据里一点动静都没有。
## 量「离曲线多远」而不是「某一时刻在哪」：补间的相位读不到，
## 而「在这条曲线上」跟相位无关
func _off_plan(main: Node, flight: Dictionary) -> float:
	var worst := 0.0
	for u in flight:
		if not main.entities.has(u) or not is_instance_valid(main.entities[u]):
			continue
		var p: Vector3 = main.entities[u].position
		var near := INF
		for s in FLIGHT_STEPS + 1:
			near = minf(near, p.distance_to(
				_plan_at(main, flight[u], float(s) / float(FLIGHT_STEPS))))
		worst = maxf(worst, near)
	return worst


## n 张按每列 per 张切出来的各列张数，例如 n 比 per 多一点就是 [per, n-per]。
## 抽出来是因为盯它的判据有两处（第 1 节量开局分摞、第 2 节量编组后仍只算散牌），
## 各写一遍的话改了一处就开始互相矛盾
func col_split(n: int, per: int) -> Array:
	var out: Array = []
	var left := n
	while left > 0:
		out.append(mini(per, left))
		left -= out[-1]
	return out


## 扫某一侧某种资源的散牌落点 → {"%.1f" % x: 张数}，skip 里的 uid 不算。
## 第 1 节和第 2 节量的是同一件事（摞按列摊开），只是第 2 节多了「要排除编了组的」
func idle_x_hist(main: Node, res: String, anchor_x: float, pitch: float) -> Dictionary:
	var at := {}
	for c in main.state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] != res:
			continue
		if not main.entities.has(c["uid"]):
			continue
		var x: float = main.entities[c["uid"]].position.x
		# 只数落在列格上的（anchor_x + 整数格 × pitch，往右）。
		# 不筛的话编了组的那几张（停在组合位置，实测 x=0.0）会被当成又一列 ——
		# 正常情况下就红，判据自己先站不住。
		# 也不能改成「把编组的 uid 排除掉」：那等于把要查的东西藏起来，
		# 「编组的也被摊进网格」这件事就再也看不见了（上面第 2 节写了实测经过）
		var k: float = (x - anchor_x) / pitch
		if k < -0.01 or absf(k - roundf(k)) > 0.01:
			continue
		at["%.1f" % x] = at.get("%.1f" % x, 0) + 1
	return at
