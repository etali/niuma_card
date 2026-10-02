# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## AI 理牌测试：每步结束后 AI 的牌排成均匀的两行 —— 组合走前行、闲置卡走后行的
## 固定席位，位置按固定节距算。
##
## 每一摞是「摊开」还是「收拢」按地方够不够定，不是一律收拢：
##   摊开：牌沿 +z 台阶排开，每张都露出标题带；张数多了就横着分列
##   收拢：牌几乎完全重叠只占一张卡的地方，张数写在侧边清单里
## 组合是这回合要看的东西，摆得下就摊开；闲置摞是「一类东西」，收成一个对象
## 加一份清单反而读得出来。摊开与收拢的几何各有各的判据，
## 谁是哪种形态从 SettleLayout._ai_pile_compact 读（摆放那头自己的登记）


func _initialize() -> void:
	print("=== AI 理牌测试 ===")
	CardDB.ensure_loaded()
	var original_cards := CardDB.CARDS
	var original_rules := CardDB.GAME
	var main: Node = await _boot_geometry_main()

	_check_open_symmetry(main)
	_check_plan_row_stress(main)

	var state: GameState = main.state

	# 给 AI 补一批现金，补到远超 SettleLayout.PILE_CHUNK 好几倍是刻意的：
	# 按「按张数切块」的旧口径这会切成好几摞，正是「同一种资源摞了好几坨」那个样子。
	# 补几张是判据自己的规模，只要多到一眼看得出切没切块就够。
	# 补这么多还有一层用处：后面那节要看「后排的摞沿 +z 长出去会不会顶到前排」，
	# 摞得够厚才看得出「按张数往北退」这件事有没有做
	# 生在 AI 区上空、还没落下来：这是真实开局那一刻的样子（main.gd 发牌用
	# _rand_pos 把牌生在 y=2..5 的半空里，再飞到位）。这个高度是下面那条
	# 「侧边清单不许飘在半空」的考场 —— 清单是在这些牌还在空中时挂上去的，
	# 高度要是扫周围的实时坐标算，就会被半路上的牌顶上去。
	# 坐标写死不用 randf：判据不能靠随机数碰上才成立
	var extra_cash := 14
	for i in extra_cash:
		var c: Dictionary = state.add_card(GameState.AI, "cash")
		var e: CardEntity = main._spawn_entity(c,
			Vector3(-7.0 + float(i), 3.0, main.AI_ZONE_Z - 2.0), false)
		e.set_dimmed(true)

	# AI 编一个组合（刷不停 + 一份配方的用户）：组合同样要被收拢成摞。
	# 配方量读本测试的几何夹具：8 张组合用于验证多列摊开。
	var core_id := "shuabuting"
	var core_def: Dictionary = CardDB.get_def(core_id)
	var seats := int(core_def["recipe_n"])
	check(seats < int(CardDB.game_rules()["start_user"]),
		"牌桌前提：%s 的配方量 %d 少于开局用户数，编完还剩得下闲置用户摞" % [
			core_def["name"], seats])
	var prod: Dictionary = state.add_card(GameState.AI, core_id)
	main._spawn_entity(prod, Vector3(0, 0.05, -3.6), false)
	var combo_uids: Array = [prod["uid"]]
	var n := 0
	for c in state.players[GameState.AI]["cards"]:
		if c["def_id"] == "user" and n < seats:
			combo_uids.append(c["uid"])
			n += 1
	var r: Dictionary = state.create_combo(GameState.AI, combo_uids)
	check(r["ok"], "AI「%s+%s×%d」编组成立" % [
		core_def["name"], CardDB.card_name("user"), seats])

	main.layout._layout_ai_idle()
	await create_timer(0.6).timeout
	for i in 5:
		await physics_frame

	# --- 摞的划分：1 个组合 + 现金 1 摞 + 用户 1 摞 = 3 摞 ---
	# 同一种资源只摞一摞，不按张数切块：切块（几十张现金按 PILE_CHUNK 摊成好几摞）
	# 让玩家看到的是「同一种资源摞了好几坨」——摞的意义是把一类东西
	# 收成一个对象，切块把这个意义拆没了。张数在侧边清单里写着
	var piles: Dictionary = main.layout._ai_pile_uids
	check(piles.size() == 3, "分成 3 摞（组合 1 + 现金 1 + 用户 1，实际 %d）" % piles.size())
	var sizes: Array = []
	for k in piles:
		sizes.append(int(piles[k].size()))
	sizes.sort()
	# 张数从开局配置推出来，不写死：rebalance 调 start_cash 就会把写死的数字放旧
	# （这条曾经把三个数直接写在数组里，start_cash 一调就一直是红的）。
	# 这里被测的是「同一种资源不按张数切块」，start_cash 不是被测的那个常量
	var rules: Dictionary = CardDB.game_rules()
	var want_sizes: Array = [
		int(rules["start_user"]) - seats,     # 闲置用户：开局的用户卡去掉编进组合的那几张
		seats + 1,                           # 组合：核心 1 张 + 一份配方
		int(rules["start_cash"]) + extra_cash,  # 闲置现金：开局 + 上面补的，一摞不切块
	]
	want_sizes.sort()
	check(sizes == want_sizes, "每摞张数 %s（实际 %s）" % [str(want_sizes), str(sizes)])
	# 每种资源只出现在一个 key 里：ai_cash_* / ai_user_* 各只有一个
	var per_res := {}
	for k in piles:
		var base := str(k).trim_suffix("_0")
		per_res[base] = per_res.get(base, 0) + 1
	var dup: Array = []
	for base in per_res:
		if int(per_res[base]) > 1:
			dup.append("%s×%d" % [base, int(per_res[base])])
	check(dup.is_empty(), "同一种资源没有摞成两坨（重复：%s）" % [
		"无" if dup.is_empty() else ", ".join(dup)])

	# --- 形态：闲置摞收拢（沿高度摞），组合摊开（分列，每张露标题带）---
	# 两种形态在这一刻是分开的，不再「每摞都收拢」：
	# 组合是这回合要看的东西，摞成一块只看得见最南那一张（那正是要修的症状）；
	# 闲置摞是「一类东西」，收成一个对象加侧边清单反而读得出来。
	# 谁是哪种形态从 _ai_pile_compact 读 —— 那是摆放那头自己的登记，
	# 下面逐摞按它声明的形态去核几何，声明和实测不一致就红
	var compact_of: Dictionary = main.layout._ai_pile_compact
	check(compact_of.get("ai_combo_0", true) == false,
		"组合是摊开的（8 张分列摊开，摞成一块的话只看得见最南那一张）")
	check(compact_of.get("ai_cash_0", false) == true
			and compact_of.get("ai_user_0", false) == true,
		"两摞闲置资源都是收拢的（有组合时前行让给组合，见 _spread_ai_res）")
	var spread := []
	var flat := []
	for k in piles:
		var ext := _extent(main, piles[k])
		if ext.z > CardEntity.CARD_SIZE.z:
			spread.append("%s z=%.2f" % [k, ext.z])
		var want: float
		if bool(compact_of.get(k, true)):
			# n 张收拢摞的高度差 = (级数-1) * COMPACT_GAP.y。级数不是张数：
			# 台阶封顶在 back_pile_cap() 级（Board.capped_offset），超出的那几张
			# 停在摞底那一级上。按张数算的话现金摞（这一刻 34 张 > 29 级）
			# 会要求 1.485，而封顶之后就是 1.260 —— 红的是判据没跟上封顶这件事
			want = (mini(piles[k].size(), main.layout.back_pile_cap()) - 1) \
				* Board.COMPACT_GAP.y
		else:
			# 摊开的组合：高度差是**一列**的台阶（分列之后每列一样高），
			# 一列几张就是 ceil(n/列数)。
			#
			# 列数从场景里**数出来**（_col_count），不拿 combo_cols(n) 算：
			# combo_cols 给的是这一组「想」分几列，一行摆不下时
			# plan_combo_row 会把最宽的那组降列 —— 降完还是摊开的话，
			# 按 combo_cols 算的高度就对不上，红的是判据没跟上降列这件事。
			# 这一条要问的是「高度差和列数配不配」，两个数都该是实测的
			var n_all: int = piles[k].size()
			var cols_n: int = maxi(_col_count(main, str(k)), 1)
			want = (ceili(float(n_all) / float(cols_n)) - 1) * Board.STACK_GAP.y
			# 分了几列就得在 x 上**真的分开**：这一摞 8 张分 2 列，两列的 x
			# 必须差出一张卡宽。少了这条，「列与列错开多少」那一句改成 0
			# 上面全绿 —— 两列完全重合，高度差还是一列的台阶（每列同构），
			# 纵深也还在一张卡以内，前面那两条一条都看不见。
			# 而屏幕上是 8 张牌两两叠在一起，比不分列更糟
			var xs := {}
			for u in piles[k]:
				xs[snappedf(main.entities[u].position.x, 0.1)] = true
			var xl: Array = xs.keys()
			xl.sort()
			if xl.size() != cols_n:
				flat.append("%s 摊成 %d 列，量到 %d 个 x" % [k, cols_n, xl.size()])
			for ci in range(1, xl.size()):
				if float(xl[ci]) - float(xl[ci - 1]) < CardEntity.CARD_SIZE.x - 0.01:
					flat.append("%s 第 %d 列离上一列只有 %.2f（不到一张卡宽 %.2f）" % [
						k, ci, float(xl[ci]) - float(xl[ci - 1]), CardEntity.CARD_SIZE.x])
		if absf(ext.y - want) > 0.02:
			flat.append("%s y=%.3f≠%.3f" % [k, ext.y, want])
	check(spread.is_empty(), "每摞纵深都在一张卡以内（%s）" % str(spread))
	check(flat.is_empty(), "每摞的高度差都对得上它声明的形态（%s）" % str(flat))

	# --- 分行看的是「是什么」不是「第几个」：组合前排，闲置摞后排的固定席位 ---
	# 按序号分行的话开局（零组合）两堆闲置卡会被排进前排、贴着购牌区挤在中间，
	# 第一次上手的人分不清那是谁的牌
	var rows1 := { 0: [], 1: [] }
	var seat := {}
	for k in piles:
		# 摞的锚点 = 队尾那张（收拢偏移为 0 的那张）；队首反而偏得最远
		var p: Vector3 = main.entities[piles[k][-1]].position
		var row: int = 0 if absf(p.z - main.layout.AI_ROW_Z[0]) < 0.1 else 1
		rows1[row].append(str(k))
		# 席位量的是这一摞**占地的中心**，不是队尾那张的 x：分列之后队尾那张
		# 在最右那一列上（8 张分 2 列，队尾偏 +0.65），而整个组合仍然居中在 0。
		# 拿队尾去量的话，「居中」这条会随列数变化而红，红的却不是居中这件事
		seat[str(k)] = _center_x(main, piles[k])
	rows1[0].sort()
	rows1[1].sort()
	check(rows1[0] == ["ai_combo_0"], "前排只有组合（实际 %s）" % str(rows1[0]))
	check(rows1[1] == ["ai_cash_0", "ai_user_0"],
		"闲置摞都在后排（实际 %s）" % str(rows1[1]))
	check(absf(float(seat.get("ai_combo_0", 99.0))) < 0.01,
		"单个组合居中在 x=0（实际 %.2f）" % float(seat.get("ai_combo_0", 99.0)))

	# --- 不越过购牌区，且全在视野内 ---
	var in_screen := true
	var south := true
	for k in piles:
		for u in piles[k]:
			var p: Vector3 = main.entities[u].position
			if absf(p.x) > 9.1 or p.z < -8.1 or p.z > 5.0:
				in_screen = false
			if p.z > main.layout.AI_COMBO_MAX_Z:
				south = false
	check(in_screen, "所有 AI 卡都在视野内（|x|≤9, -8≤z≤5）")
	check(south, "所有摞都在购牌区以北（z ≤ %.1f）" % main.layout.AI_COMBO_MAX_Z)

	# 收拢态也要对着玩家侧的同种资源：有组合的这一刻 AI 收拢成摞（摊开那一片
	# 得让位给组合），但左右对位这条不因形态而改 —— 现金摞还是要落在玩家现金
	# 那一片的 x 跨度里。开局那一节量的是摊开态，这一节补的是收拢态
	_check_pile_x(main, piles)
	# 侧边清单只有收拢的摞才有（摊开态没有清单），所以它的考场在这一刻：
	# 上面刚补进来的那批现金正从远处飞过来，清单的高度要是扫实时坐标算的
	# 就会被半路上的牌顶到半空
	_check_side_height(main)

	# --- 组合摞：核心卡排在队首，也摆在最高处 ---
	# 收拢态只露得出最高那一张，所以队首必须是核心卡；摊开态每张都露着，
	# 但核心卡仍在最高、最靠南（台阶轴的尽头），两种形态是同一条队序
	var combo_key: String = main.layout._ai_pile_of_uid.get(prod["uid"], "")
	check(combo_key != "", "组合卡进了摞（key=%s）" % combo_key)
	if combo_key != "":
		var uids: Array = piles[combo_key]
		check(int(uids[0]) == int(prod["uid"]), "组合摞的队首是核心卡「%s」" % core_def["name"])
		var top_y: float = main.entities[uids[0]].position.y
		var highest := true
		for u in uids:
			if u != uids[0] and main.entities[u].position.y > top_y:
				highest = false
		check(highest, "队首那张也确实摆得最高")

	# --- 侧边清单：收拢摞看不见内容，靠它说明有多少用户/现金/buff ---
	# 只有收拢的摞该有清单。摊开的组合每张都露着标题带，再挂一份清单就是
	# 同一件事说两遍，还会挡住旁边那一列
	var missing := []
	var extra := []
	for k in piles:
		var g: Variant = main.board._ext_side.get(k)
		var has: bool = g != null and not g.get("side", []).is_empty()
		if bool(compact_of.get(k, true)):
			if not has:
				missing.append(k)
		elif has:
			extra.append(k)
	check(missing.is_empty(), "每个收拢的摞都挂了侧边清单（缺 %s）" % str(missing))
	check(extra.is_empty(), "摊开的组合不挂清单（每张都露着标题带，多余的：%s）" % str(extra))

	# --- 摞数超过一行就换到后排，且后排同样居中 ---
	# 摞数只能靠组合数堆上去：闲置卡每种资源就一摞，再多也不换行。
	# 用最便宜的配方（地推）连编 6 个组合，凑到 9 摞。
	# 配方张数从卡表取：这一节量的是「摞数超过一行怎么换排」，地推吃几张现金无关，
	# 硬写的话每轮调数值都在这儿红一次，而红的原因和排布毫无关系
	var ditui_n := int(CardDB.get_def("ditui")["recipe_n"])
	for i in 6:
		var locked := {}
		for combo in state.combos:
			if combo["owner"] == GameState.AI:
				for u in combo["uids"]:
					locked[u] = true
		var p2: Dictionary = state.add_card(GameState.AI, "ditui")
		main._spawn_entity(p2, Vector3(0, 0.05, -3.6), false)
		var uids2: Array = [p2["uid"]]
		var got := 0
		for c in state.players[GameState.AI]["cards"]:
			if c["def_id"] == "cash" and got < ditui_n and not locked.has(c["uid"]):
				uids2.append(c["uid"])
				got += 1
		var rr: Dictionary = state.create_combo(GameState.AI, uids2)
		check(rr["ok"], "AI 第 %d 个「地推+现金×%d」编组成立" % [i + 1, ditui_n])
	# 再加**最宽的那个配方**（春晚冠名，10 张现金 → 连核心卡 11 张 = 3 列）。
	#
	# 为什么这一节非要有它：前行现在按「最宽那组 + 空当」定节距（plan_combo_row），
	# 一行摆不下才降列。上面那 7 个组合（8 张的刷不停 + 六个 4 张的地推）
	# 加起来还在一行的宽度里 —— 也就是说**降列那条路一次都跑不到**，
	# 而那条路正是「摆不下时靠收拢 + 侧边清单顶上」的唯一出口。
	# 11 张这一组把整行顶出去，降列才真的发生（memory: green-mutation-means-no-observer）
	var chunwan_n := int(CardDB.get_def("chunwan")["recipe_n"])
	var locked3 := {}
	for combo in state.combos:
		if combo["owner"] == GameState.AI:
			for u in combo["uids"]:
				locked3[u] = true
	# 现金可能已经被上面几组吃光了：这一节要的是「一行摆不下」这个几何，
	# 不是「AI 攒得出这么多现金」，缺多少就补多少
	var have_cash := 0
	for c in state.players[GameState.AI]["cards"]:
		if c["def_id"] == "cash" and not locked3.has(c["uid"]):
			have_cash += 1
	for i in maxi(chunwan_n - have_cash, 0):
		var cc: Dictionary = state.add_card(GameState.AI, "cash")
		main._spawn_entity(cc, Vector3(-7.0, 0.05, -6.5), false)
	var p4: Dictionary = state.add_card(GameState.AI, "chunwan")
	main._spawn_entity(p4, Vector3(0, 0.05, -3.6), false)
	var uids4: Array = [p4["uid"]]
	var got4 := 0
	for c in state.players[GameState.AI]["cards"]:
		if c["def_id"] == "cash" and got4 < chunwan_n and not locked3.has(c["uid"]):
			uids4.append(c["uid"])
			got4 += 1
	var r4: Dictionary = state.create_combo(GameState.AI, uids4)
	check(r4["ok"], "AI「春晚冠名+现金×%d」编组成立（%s）" % [chunwan_n, str(r4.get("err", ""))])
	main.layout._layout_ai_idle()
	await create_timer(0.6).timeout
	for i in 5:
		await physics_frame

	# 组合 8（刷不停 1 + 地推 6 + 春晚冠名 1）+ 现金 1 + 用户 1 = 10 摞。
	# 组合再多也不换行 —— 换行会把第二行摆到闲置摞的席位上，
	# 两片牌互相压边比挤一点更难读
	var piles2: Dictionary = main.layout._ai_pile_uids
	check(piles2.size() == 10, "补到 10 摞（实际 %d）" % piles2.size())
	var rows := { 0: [], 1: [] }
	var kinds := { 0: [], 1: [] }
	for k in piles2:
		var p: Vector3 = main.entities[piles2[k][-1]].position
		var row: int = 0 if absf(p.z - main.layout.AI_ROW_Z[0]) < 0.1 else 1
		# x 取这一摞**所有列的中点**，不取某一张卡的 x：组合会分列
		# （见 _spread_ai_combo），随便挑一张的话挑到的是它所在那一列的 x，
		# 列数不同的两摞就量出两个不同的偏移 —— 下面「等距」「居中」两条
		# 会红在采样上，而不是红在排布上
		var xlo := INF
		var xhi := -INF
		for u in piles2[k]:
			var x: float = main.entities[u].position.x
			xlo = minf(xlo, x)
			xhi = maxf(xhi, x)
		rows[row].append((xlo + xhi) / 2.0)
		kinds[row].append(str(k).begins_with("ai_combo_"))
	check(rows[0].size() == 8 and rows[1].size() == 2,
		"8 个组合都在前排 / 后排仍是 2 个闲置摞（实际 %d / %d）" % [
			rows[0].size(), rows[1].size()])
	check(not kinds[0].has(false) and not kinds[1].has(true),
		"前排全是组合、后排全是闲置摞")
	var front: Array = rows[0]
	front.sort()
	if front.size() > 1:
		# 居中量的是**整片的占地**（含清单），不是卡心的首末两个。
		# 两者不是一件事：清单只往右长，按卡心居中的话整片就往右偏出
		# 一个清单宽（实测 8 个组合时占地 [-10.14,11.26]，右边 1.12 出格）。
		# 屏幕上「偏没偏」看的是有东西的那一片，所以判据也看那一片
		var ext: Vector2 = _front_extent(main, piles2)
		check(absf(ext.x + ext.y) < 0.01,
			"前排整片（含清单）以 x=0 居中（%.2f / %.2f）" % [ext.x, ext.y])
		# 节距要均匀。节距不再是固定的 AI_SLOT_PITCH：它按「这一行最宽的那组
		# 有多宽」现算（见 plan_combo_row），所以这里只问「等距」，不问具体值
		var pitch2: float = front[1] - front[0]
		var even2 := true
		for i in range(1, front.size()):
			if absf(front[i] - front[i - 1] - pitch2) > 0.01:
				even2 = false
		check(even2, "8 个组合的前排仍等距（实际 %s）" % str(front))
		# 整行不出桌：量的是**牌的边缘**（含收拢摞右边那份侧边清单），
		# 不是卡心 —— 清单是这一摞唯一能说出张数的东西，它出了桌等于读不出来。
		# 原先这条比的是「不宽于 6 格网格的宽度」，而那个网格正是这次要拆的
		# （固定 2.5 一格 → 2 列组合正好占满、相邻两组零空当）
		var edge: float = _front_edge(main, piles2)
		check(edge <= main.layout.AI_SPREAD_MAX_X + 0.01,
			"8 个组合的前排没出桌（最远边缘 %.2f ≤ %.2f）" % [
				edge, main.layout.AI_SPREAD_MAX_X])
		# 组合**之间**不许互相压边：这一条就是报上来那个 bug 的判据本身
		# （「每次 AI 理完牌，组合卡都叠在一起」）。见 _combo_overlaps
		var lap: Array = _combo_tight(main, piles2)
		check(lap.is_empty(), "8 个组合两两之间都留着空当（挨太近的：%s）" % [
			"无" if lap.is_empty() else ", ".join(lap)])
		# 上面三条都按清单的**预留宽**算地方，这一条判预留宽真罩得住文字 ——
		# 罩不住的话那三条算出来的空当是假的，屏幕上照样压
		var ov: Array = _side_overflow(main)
		check(ov.is_empty(), "每份侧边清单都在预留的宽度里（超出的：%s）" % [
			"无" if ov.is_empty() else ", ".join(ov)])
	var back_z := true
	for k in piles2:
		for u in piles2[k]:
			if main.entities[u].position.z < -8.1:
				back_z = false
	check(back_z, "后排没有排出桌面北缘（z ≥ -8.1）")
	# 后排的摞沿 +z 长（队首偏得最远），张数多了会往前行伸：整摞的南缘
	# 不许越过前排那片牌的北缘 —— 越过就是压在组合上。
	# 前排的边界从前排那几摞实测出来，不读 AI_ROW_Z：读常量的话把「按张数
	# 往北退」这段删掉、两排都按行线摆，这条照样过
	var front_north := INF      # 前排那片牌的北缘（最靠北那张的北边）
	var back_south := {}        # 后排每摞的南缘（最靠南那张的南边）
	for k in piles2:
		var zmin := INF
		var zmax := -INF
		for u in piles2[k]:
			var z: float = main.entities[u].position.z
			zmin = minf(zmin, z)
			zmax = maxf(zmax, z)
		if str(k).begins_with("ai_combo_"):
			front_north = minf(front_north, zmin - CardEntity.CARD_SIZE.z / 2.0)
		else:
			back_south[str(k)] = zmax + CardEntity.CARD_SIZE.z / 2.0
	var into_front: Array = []
	for k in back_south:
		if float(back_south[k]) > front_north + 0.01:
			into_front.append("%s 南缘 %.2f" % [k, float(back_south[k])])
	check(into_front.is_empty(), "后排的摞没有伸进前行（前排北缘 %.2f，越界的：%s）" % [
		front_north, "无" if into_front.is_empty() else ", ".join(into_front)])

	# 清单的**内容**在这一刻才量得到：8 个组合摆不下一行，最宽的那个
	# （春晚冠名，11 张 = 3 列）被降到收拢，也就挂上了清单（见 plan_combo_row
	# 里那个降列的循环）。它摊开时没有清单，在那时量内容等于量一份没画出来的东西。
	#
	# 判的是**春晚**而不是刷不停：降列先降最宽的那个，刷不停（8 张 2 列）
	# 让出一个 3 列的位置就够了，自己还是摊开的
	var cw_key: String = main.layout._ai_pile_of_uid.get(p4["uid"], "")
	check(cw_key != "", "春晚冠名那一组登记成了摞（key=%s）" % cw_key)
	if cw_key != "":
		check(bool(main.layout._ai_pile_compact.get(cw_key, false)),
			"一行摆不下时最宽的那组（春晚冠名 %d 张）降成收拢" % piles2[cw_key].size())
		var spec := Board.side_spec(_entities_of(main, piles2[cw_key]))
		check(spec.size() == 1 and str(spec[0]["text"]) == "×%d" % chunwan_n,
			"组合摞清单为 现金×%d（实际 %s）" % [chunwan_n, str(spec)])

	await _check_combo_form(main)
	await _check_pile_footprint(main)
	await _check_spread_width()
	await _check_bench_spread()
	await _check_same_core_twice()
	await _check_resource_anchor_configs()

	CardDB.CARDS = original_cards
	CardDB.GAME = original_rules
	finish()


## 这些场景量的是几何边界，必须同时有一列、两列、三列组合和剩余闲置资源。
## 平衡卡表调小配方后，原来的宽组合不再挤满前排；调大攻击配方后又可能缺材料。
## 只在当前测试进程内固定材料规模，仍经真实 create_combo / layout 生成和摆放。
## main._ready 会重新加载卡表，因此每次起场景后应用夹具，再重建实际开局牌片。
func _boot_geometry_main() -> Node:
	var main: Node = await boot_main()
	CardDB.CARDS = CardDB.CARDS.duplicate(true)
	CardDB.GAME = CardDB.GAME.duplicate(true)
	CardDB.GAME["start_cash"] = 20
	CardDB.GAME["start_user"] = 10
	var recipe_sizes := {"shuabuting": 7, "ditui": 3, "chunwan": 10, "zuokong": 2}
	for id in recipe_sizes:
		CardDB.CARDS[id]["recipe_n"] = recipe_sizes[id]
	main._teardown_for_new_game(true)
	main._reset_session_flags()
	main.state = GameState.new()
	main.state.new_game()
	main._rebuild_pipe()
	main._sync_round()
	await settle()
	return main


## 同一张牌桌切换开局资源配置：单列、多列、再回单列，收拢中线不能沿用旧值。
## 只在本测试进程内改规则夹具；通过真实玩家牌片测中线，不复写布局的计算公式。
func _check_resource_anchor_configs() -> void:
	print("--- 切换开局张数后，收拢资源仍与玩家资源片中线对齐 ---")
	var main: Node = await _boot_geometry_main()
	var original_rules := CardDB.GAME.duplicate(true)
	for counts in [[8, 8], [17, 17], [8, 8]]:
		CardDB.GAME["start_cash"] = counts[0]
		CardDB.GAME["start_user"] = counts[1]
		main._teardown_for_new_game(true)
		main._reset_session_flags()
		main.state = GameState.new()
		main.state.new_game()
		main._rebuild_pipe()
		main._sync_round()
		await settle()
		# 多一整列现金，迫使两种闲置资源收拢；玩家一侧保留开局排布作为独立基准。
		for i in main.layout.PLAYER_PILE_PER_COL:
			var card: Dictionary = main.state.add_card(main.foe_seat, CardDB.unit_id(CardDB.RES_CASH))
			main._spawn_entity(card, Vector3(-7, 0.05, -6), false)
		main.layout._layout_ai_idle()
		await settle()
		var compact_x := {}
		for res in [CardDB.RES_CASH, CardDB.RES_USER]:
			var did := CardDB.unit_id(res)
			var lo := INF
			var hi := -INF
			var columns := {}
			for card in main.state.players[main.my_seat]["cards"]:
				if card["def_id"] != did:
					continue
				var x: float = main.entities[card["uid"]].position.x
				lo = minf(lo, x)
				hi = maxf(hi, x)
				columns[snappedf(x, 0.1)] = true
			var label := "%s，开局现金/用户=%s" % [res, str(counts)]
			check(columns.size() == (1 if counts[0] == 8 else 3),
				"配置夹具实际形成预期单列/多列（%s）" % label)
			var key := "ai_%s_0" % did
			if not need(main.layout._ai_pile_uids.has(key), "AI闲置资源摞存在（%s）" % label):
				continue
			check(main.layout._ai_pile_compact.get(key, false), "资源确实收拢，正在验证收拢席位（%s）" % label)
			var pile: Array = main.layout._ai_pile_uids[key]
			var x: float = main.entities[pile[-1]].position.x
			var midpoint := (lo + hi) / 2.0
			compact_x[res] = x
			check(absf(x - midpoint) < 0.01,
				"收拢席位对齐当前玩家片中线（%s：AI %.2f / 玩家 %.2f）" % [label, x, midpoint])
			check(absf(main.layout._unit_anchor(main.foe_seat, did).x - midpoint) < 0.01,
				"新到资源卡的落位锚点使用同一当前中线（%s）" % label)
		var window: Vector2 = main.layout.bench_window([], false)
		var clearance := CardEntity.CARD_SIZE.x + 0.2
		check(compact_x.size() == 2 and is_equal_approx(window.x, float(compact_x.get(CardDB.RES_CASH, INF)) + clearance)
				and is_equal_approx(window.y, float(compact_x.get(CardDB.RES_USER, INF)) - clearance),
			"备牌窗口跟随当前资源席位并留足卡宽（开局现金/用户=%s）" % str(counts))
	CardDB.GAME = original_rules


## 同一张核心卡攥了两张：摞在一起是对的，但清单必须说出「×2」。
##
## 这是报上来那个 bug 的判据本身：「AI 合成了 2 张独角兽，下一回合只看到 1 张」。
## 两头合起来才出这个症状 ——
##   1. 备牌摞按 def_id 分摞（_ai_piles 的 by_def），两张同名核心必然进同一摞；
##   2. 摞是收拢的，只露得出摞顶那一张；
##   3. 而 side_spec 那道闸门原先写的是「核心**种类** ≥ 2 才列」，
##      同名两张只有 1 种 → 核心一行都不出。
## 于是第二张既看不见、清单也不提，屏幕上和「只合出一张」逐像素相同。
##
## 上面那几节一条都量不到：_check_bench_spread 补的 12/29 种是**各不相同**的卡，
## 种类数恒等于张数，闸门数种还是数张给的是同一个答案
## （memory: vacuous-mutation-two-flavors 的第一种 —— 换的值恰好也合法）。
## 要分岔就得让「种」和「张」不相等，也就是同一张卡来两份。
##
## 拿独角兽当考题不是随手挑的：它是 `upgrade_from = dup_t2` 的传说卡，
## 合成路径本身就是「同名两张 T2 升上来」，一局里出两张是常事
## （录像 20260912_075816 里 AI 就攒到了两张）
func _check_same_core_twice() -> void:
	print("--- 同名核心攥两张：摞在一起，清单说得出 ×2 ---")
	var main: Node = await _boot_geometry_main()
	await settle()
	var state: GameState = main.state
	# 挑一张传说卡：从卡表里取，不写死 dujiaoshou —— 这一条问的是「同名两张」
	# 这件事，哪张卡是数值侧的选择。取 kind=legend 里 id 最小的那张，
	# 每次跑都是同一张（keys() 的次序不保证，得排）
	var legend := ""
	var ids: Array = CardDB.all_cards().keys()
	ids.sort()
	for def_id in ids:
		if str(CardDB.get_def(str(def_id)).get("kind", "")) == CardDB.KIND_LEGEND:
			legend = str(def_id)
			break
	check(legend != "", "卡表里有传说卡（没有的话这一节考不了同名核心）")
	if legend == "":
		return
	for i in 2:
		main._spawn_entity(state.add_card(GameState.AI, legend),
			Vector3(9.0 + float(i), 0.05, -7.0), false)
	main.layout._layout_ai_idle()
	await ai_moves_landed(main)
	await settle()
	# 两张进的是同一摞（这一半是**对的**行为，不是要改的那一半）
	var key := ""
	var uids: Array = []
	for k in main.layout._ai_pile_uids:
		var arr: Array = main.layout._ai_pile_uids[k]
		var n := 0
		for u in arr:
			if main.entities.has(u) and is_instance_valid(main.entities[u]) \
					and main.entities[u].def_id == legend:
				n += 1
		if n > 0:
			check(n == 2, "两张「%s」在同一摞里（%s 里有 %d 张）" % [
				CardDB.card_name(legend), str(k), n])
			key = str(k)
			uids = arr
	check(key != "", "两张「%s」登记在某一摞里" % CardDB.card_name(legend))
	if key == "":
		return
	# 收拢的：摊开的话每张自己露标题带，清单本来就不画，下面量的不是同一件事
	check(bool(main.layout._ai_pile_compact.get(key, false)),
		"%s 是收拢的（摊开的话第二张自己露得出来，清单不是唯一出口）" % key)
	# 几何上真的盖住了：这是「只看到 1 张」的直接量。
	# 不问「完全重合」——收拢态有个很小的台阶偏移，问的是**露出来的那条边
	# 够不够看出是两张牌**，取半张卡当阈值（盖住 50% 以上就读不出张数了）
	var cards: Array = _entities_of(main, uids)
	var a: CardEntity = null
	var b: CardEntity = null
	for c in cards:
		if c.def_id != legend:
			continue
		if a == null:
			a = c
		else:
			b = c
	check(a != null and b != null, "两张的实体都在场上")
	if a == null or b == null:
		return
	var dz: float = absf(a.position.z - b.position.z)
	var dx: float = absf(a.position.x - b.position.x)
	check(dz < CardEntity.CARD_SIZE.z / 2.0 and dx < CardEntity.CARD_SIZE.x / 2.0,
		"两张确实盖住了（dx=%.2f dz=%.2f，都不到半张卡）—— 所以清单是唯一出口" % [dx, dz])
	# 清单里必须有一行说得出这张卡有两份。
	# 问的是「有一行的 ×N 是 ×2」，不问是第几行：行序按 用户→现金→buff→核心，
	# 写死下标等于把那个排序抄第二遍（memory: number-lives-in-five-places）
	var spec := Board.side_spec(cards)
	var hit := false
	for row in spec:
		if str(row["text"]) == "×2":
			hit = true
	check(hit, "清单里有一行「×2」（实际 %s）—— 少了这行，第二张既看不见也没人提，"
		% str(spec) + "屏幕上和「只合出一张」一模一样")


## 备牌那一片：种类多起来也不出桌、不压在资源片上。
##
## 为什么单独开一局：上面那些节桌上的非资源闲置卡最多一两种，而这一节要量的
## 两件事都只在**种类多**的时候才现形，而且各自是我改这一版时真踩出来的：
##   1. 席位表按 AI_PILE_BENCH_X 居中，而节距是从窗口宽反解的 ——
##      两个基准不是一个数，居中完整片会探到窗口外面。实测 6 摞时最左那摞
##      落在 -5.00，摊开的现金片右缘在 -4.80，相差 0.20 而牌宽 1.2，
##      是一次真穿模。治它的是 _bench_seats 末尾那个 clampf
##   2. 摆不下时把整片撑出窗口。实测 29 种时最外那几摞落到
##      x = -18.80 / -17.60 / 12.40 / 13.60 / 14.80（AI_SPREAD_MAX_X 是 12.4，
##      直接出桌），照旧压在现金片上，比不分摞还糟。
##      治它的是 bench_seat_cap + _merge_bench_overflow
##
## 12 / 29 两档：12 是刚过 cap（cap 按窗口算，摊开态实测是 5）的第一档，
## 29 是卡表里非资源卡的全部种类 —— 那是这个数的上界，再多不可能了
func _check_bench_spread() -> void:
	print("--- 备牌那一片种类多起来也不出桌 ---")
	var main: Node = await _boot_geometry_main()
	await settle()
	var state: GameState = main.state
	# 开局这一刻：AI 手上是 start_cash 张现金、没有组合，资源那一片正是**摊开**的。
	# 备牌就往这上头加，不清场 —— 摊开的现金片会把备牌的左边界往右推，
	# 窗口最窄的就是这一刻，穿模也最容易出（清了场资源片反而不摊开，量的就不是这件事）
	var non_res: Array = []
	for id in CardDB.all_cards():
		if str(CardDB.get_def(id).get("kind", "")) != CardDB.KIND_UNIT:
			non_res.append(id)
	non_res.sort()
	check(non_res.size() >= 12,
		"卡表里非资源卡够多，这一节才量得到（%d 种）" % non_res.size())
	var added: int = 0
	# 两档：12 是刚过 cap 的第一档，全部种类是这个数的上界
	for kinds in [12, non_res.size()]:
		while added < kinds:
			var c2: Dictionary = state.add_card(GameState.AI, non_res[added])
			main._spawn_entity(c2, Vector3(13.0, 0.05, -7.0), false)
			added += 1
		main.layout._layout_ai_idle()
		await ai_moves_landed(main)
		await settle()

		var pile_of: Dictionary = main.layout._ai_pile_of_uid
		# 先确认资源那一片真是摊开的 —— 收拢的话窗口是宽的那一版，
		# 上面说的「最窄的一刻」就没量到（memory: vacuous-mutation-two-flavors）
		check(bool(main.layout._ai_pile_compact.get("ai_cash_0", true)) == false,
			"%d 种时资源那一片仍是摊开的（收拢的话量的不是最窄那一刻）" % kinds)
		# --- 不出桌 ---
		var off: Array = []
		for u in pile_of.keys():
			if not str(pile_of[u]).begins_with("ai_bench"):
				continue
			if not (main.entities.has(u) and is_instance_valid(main.entities[u])):
				continue
			var px: float = main.entities[u].position.x
			if absf(px) + CardEntity.CARD_SIZE.x / 2.0 > main.layout.AI_SPREAD_MAX_X:
				off.append("%.2f" % px)
		check(off.is_empty(), "%d 种时备牌都在桌上（出桌的 x：%s）" % [
			kinds, "无" if off.is_empty() else ", ".join(off.slice(0, 5))])
		# --- 备牌跟别的摞不许互相盖住（含资源片）---
		# 同一摞内部叠着是对的（那是收拢），所以只比**跨摞**的对
		var bad: Array = []
		var us: Array = pile_of.keys()
		for ia in us.size():
			for ib in range(ia + 1, us.size()):
				var ua: int = us[ia]
				var ub: int = us[ib]
				var ka: String = str(pile_of[ua])
				var kb: String = str(pile_of[ub])
				if ka == kb:
					continue
				if not ka.begins_with("ai_bench") and not kb.begins_with("ai_bench"):
					continue
				if not (main.entities.has(ua) and main.entities.has(ub)):
					continue
				if not (is_instance_valid(main.entities[ua])
						and is_instance_valid(main.entities[ub])):
					continue
				var pa: Vector3 = main.entities[ua].position
				var pb: Vector3 = main.entities[ub].position
				if absf(pa.x - pb.x) >= CardEntity.CARD_SIZE.x - 0.02:
					continue
				if absf(pa.z - pb.z) >= CardEntity.CARD_SIZE.z - 0.02:
					continue
				bad.append("%s|%s dx=%.2f dz=%.2f" % [ka, kb,
					absf(pa.x - pb.x), absf(pa.z - pb.z)])
		check(bad.is_empty(), "%d 种时备牌跟别的摞不互相盖住（越线 %d 对：%s）" % [
			kinds, bad.size(), "无" if bad.is_empty() else ", ".join(bad.slice(0, 5))])
		# --- 一张卡都没丢：并摞是合并、不是丢弃 ---
		var seen := {}
		for u in pile_of.keys():
			if str(pile_of[u]).begins_with("ai_bench") \
					and main.entities.has(u) and is_instance_valid(main.entities[u]):
				seen[main.entities[u].def_id] = true
		check(seen.size() == kinds,
			"%d 种时一种都没丢（登记在备牌摞里的有 %d 种）" % [kinds, seen.size()])
		# --- 摞数不超过这片窗口摆得下的席位数 ---
		# 不写死 6：6 是从窗口宽和卡宽算出来的，写死等于把 bench_seat_cap
		# 那个算式抄第二遍（memory: number-lives-in-five-places）。
		# 问的是「摆出来的摞数 ≤ 它自己说摆得下的数」—— 超了就是上面第 2 条那个
		# 「把整片撑出窗口」又回来了
		var keys: Array = []
		for key in main.layout._ai_pile_uids:
			if str(key).begins_with("ai_bench"):
				keys.append(str(key))
		var idles: Array = []
		for p in main.layout._ai_piles():
			# is_front_pile 是静态的，但 settle_layout.gd 没有 class_name，从实例上调
			if not main.layout.is_front_pile(str(p["key"])):
				idles.append(p)
		var win: Vector2 = main.layout.bench_window(idles, true)
		var cap: int = main.layout.bench_seat_cap(win.x, win.y)
		check(keys.size() <= cap,
			"%d 种时摞数 %d ≤ 这片窗口摆得下的 %d 个席位" % [kinds, keys.size(), cap])
		check(cap >= 2 and cap < kinds,
			"%d 种时 cap=%d 真的吃紧（不吃紧的话并摞那一支根本没走到）" % [kinds, cap])
		# 并起来的那一摞得有清单顶上 —— 「看不出是哪几种」的替代出口是「说得出几张」
		var big: Array = []
		var big_key: String = ""
		for key in keys:
			var arr: Array = main.layout._ai_pile_uids[key]
			if arr.size() > big.size():
				big = arr
				big_key = key
		check(big.size() >= 2,
			"%d 种时确实并出了一摞多张的（最大那摞 %d 张）" % [kinds, big.size()])
		# 清单要说得出「摞里还有别的卡种」。不问具体几行：行数按 Board.SIDE_MAX_ROWS
		# 封顶、超出的折成「+N 种」，写死行数等于把那个上限抄第二遍。
		# 问的是**说全了没有** —— 列出来的卡种数 + 折行里的 N == 摞里真有的卡种数
		var cards_big: Array = _entities_of(main, big)
		var spec2 := Board.side_spec(cards_big)
		var kinds_big := {}
		for c in cards_big:
			kinds_big[c.def_id] = true
		var listed: int = 0
		var folded: int = 0
		for row in spec2:
			var txt: String = str(row["text"])
			if txt.begins_with("+"):
				folded += int(txt.trim_prefix("+").trim_suffix(" 种"))
			else:
				listed += 1
		check(listed + folded == kinds_big.size(),
			"%d 种时并起来那一摞的清单说全了卡种（列出 %d + 折行 %d == 实有 %d；清单 %s）" % [
				kinds, listed, folded, kinds_big.size(), str(spec2)])
		check(listed >= 2,
			"%d 种时并起来那一摞至少列出两行核心（列出 %d 行）" % [kinds, listed])
		# 清单这一列本身也得留在后行那条带子里。
		#
		# 这条是上面那个封顶（Board.SIDE_MAX_ROWS）存在的**理由**：清单以摞顶为
		# 中心上下摊开，行数一多两头一起探 —— 北边探出 AI 区，南边压进前行的组合。
		# 不封顶会探出去多少（把封顶关掉实测的，不是拿行数乘节距算的）：
		# 12 种时 8 行，z 落在 [-7.76, -5.24]；29 种时 25 行，z 落在 [-10.32, -1.68]，
		# 而这条带子只有 [-7.60, -4.95] —— 两头都出界。
		#
		# 量的是**真节点**的 z，不是行数乘节距（那是把 _place_side 的算式抄一遍）
		var north: float = -INF
		var south: float = INF
		for nd in main.board.side_nodes_of(big_key):
			if nd == null or not is_instance_valid(nd):
				continue
			north = maxf(north, -nd.global_position.z)
			south = minf(south, -nd.global_position.z)
		if north > -INF:
			# 北：不越过 AI 区北缘（AI_FAR_Z_MIN，不是 AI_BACK_Z_MIN ——
			# 后者是「后行的**卡心**往北退到哪儿为止」，清单是卡之外的东西）；
			# 南：不压进前行组合的北沿
			var lim_n: float = -main.layout.AI_FAR_Z_MIN
			var lim_s: float = -(main.layout.AI_ROW_Z[0] - CardEntity.CARD_SIZE.z / 2.0)
			check(north <= lim_n + 0.01 and south >= lim_s - 0.01,
				"%d 种时清单这一列留在后行带子里（z ∈ [%.2f, %.2f] ⊂ [%.2f, %.2f]）" % [
					kinds, -north, -south, main.layout.AI_FAR_Z_MIN,
					main.layout.AI_ROW_Z[0] - CardEntity.CARD_SIZE.z / 2.0])
		else:
			check(false, "%d 种时并起来那一摞挂上了清单节点" % kinds)


## 摊开那一片**不比开局更宽**：现金再多也不横着长出去，到顶就改收拢。
##
## 为什么要有这一节（报上来的症状是「资源牌多的时候也不怎么摞」）：
## 摊开是按 PLAYER_PILE_PER_COL 切列的，列数随张数长而没有上限 ——
## 实测拆掉 spread_max_cols 那道闸门，现金能摊到 7 列 56 张、横着占掉
## 大半个 AI 区，一眼看不出是几张，而它明明该收成一摞加一份清单。
##
## 上面那些节都量不到这件事：开局 AI 恰好 20 张现金 = ceil(20/8) = 3 列
## = spread_max_cols(cash)，**闸门正好不吃紧**，拆了和不拆一样；
## 而后面几节桌上都有组合，_spread_ai_res 第一条（有组合就不摊开）先返回 false，
## 闸门根本走不到。所以要单独开一局：没有组合、现金比开局多
## （memory: vacuous-mutation-two-flavors 的第二种 —— 两道独立防线里
## 只要有一道先挡住，后一道就是白站的）
##
## 判据不写「最多 3 列」：3 是从 start_cash / PLAYER_PILE_PER_COL 算出来的，
## 写死等于把那个算式抄第二遍（memory: number-lives-in-five-places）。
## 写成「和开局那一刻一样宽」—— 那正是 spread_max_cols 的定义本身
func _check_spread_width() -> void:
	print("--- 摊开那一片不比开局更宽 ---")
	var main: Node = await _boot_geometry_main()
	await settle()
	var state: GameState = main.state
	var key := "ai_cash_0"
	# 开局那一刻这一片有多宽：AI 无组合、现金正好 start_cash，是摊开的
	main.layout._layout_ai_idle()
	await ai_moves_landed(main)
	await settle()
	check(bool(main.layout._ai_pile_compact.get(key, true)) == false,
		"开局这一片是摊开的（收拢的话下面量的不是「变没变宽」这件事）")
	var cols0: int = _col_count(main, key)
	var w0: float = _extent(main, main.layout._ai_pile_uids.get(key, [])).x
	check(cols0 > 1, "开局就摊成了 %d 列（1 列量不出「横着长出去」）" % cols0)
	# 补到明显放不下的张数：翻一倍多，按开局那个口径要 5 列
	var want: int = int(CardDB.game_rules()["start_cash"]) * 2 + 5
	var have: int = int(main.layout._ai_pile_uids.get(key, []).size())
	for i in maxi(want - have, 0):
		main._spawn_entity(state.add_card(GameState.AI, "cash"),
			Vector3(13.0, 0.05, -7.0), false)
	main.layout._layout_ai_idle()
	await ai_moves_landed(main)
	await settle()
	var uids: Array = main.layout._ai_pile_uids.get(key, [])
	check(uids.size() >= want, "补到 %d 张现金（实际 %d）" % [want, uids.size()])
	# 到顶就收拢：这一片改成一摞，宽度回到一张卡
	check(bool(main.layout._ai_pile_compact.get(key, false)),
		"%d 张时这一片改收拢了（摊着的话就是「牌多反而不怎么摞」）" % uids.size())
	var w1: float = _extent(main, uids).x
	check(w1 <= w0 + 0.01,
		"%d 张时不比开局那一刻宽（%.2f ≤ %.2f）" % [uids.size(), w1, w0])
	# 收拢了就得有清单顶上 —— 「看不出是几张」的替代出口
	var spec := Board.side_spec(_entities_of(main, uids))
	check(spec.size() == 1 and str(spec[0]["text"]) == "×%d" % uids.size(),
		"清单写着 ×%d（实际 %s）" % [uids.size(), str(spec)])

## 前行的组合两两之间有没有压边。返回压边的那几对的说明（空 = 都留着空当）。
##
## 这是报上来那个 bug 的判据本身：「每次 AI 理完牌，组合卡都叠在一起」。
## 原先前行是固定节距 2.5 的格子，而一个分了 2 列的组合横着正好占 2.50 ——
## 相邻两组边挨边、零空当，屏幕上连成一片分不出哪几张是一组。
##
## 量的是**静止落点**，不是航迹：既有那几条（test_tidy 的 _check_flight_clearance）
## 量的是飞行途中的穿模，牌停下之后横向挨得多近它们一条都看不见
## （memory: green-mutation-means-no-observer）。
##
## 判据问的是「两组之间留出的空当 ≥ COMBO_ROW_GAP」，**不是**「两组不相交」。
##
## 「不相交」这条太松，松到漏掉的正是报上来的那个 bug：改之前相邻两组的边缘
## 一个在 -0.60、一个在 +0.60，正好边挨边 —— 空当是 0，但并没有相交，
## 「不相交」照样绿。屏幕上零空当和相交长得一样（都是连成一片分不出组），
## 所以判据得要一个**正的**空当（memory: vacuous-mutation-two-flavors）。
##
## 阈值取 COMBO_ROW_GAP 本身（从 layout 读，不抄成字面量）：那个常量就是
## 「两组之间留多少才看得出是两组」的声明，这一条问的是排布真把它兑现了
## —— 兑现不了的话，节距是从哪个组算出来的就错了（比如只看第一组多宽）。
##
## 有一处例外：整行实在摆不下时最后那步会压节距，压下去空当就小于声明值
## （见 plan_combo_row 的封顶那一段）。所以这一条只在没压过节距时成立，
## 调用方自己保证 —— 8 个组合这一节实测节距 2.91、空当正好 0.60，没压过
##
## 收拢摞右边那份侧边清单也算进占地：清单是这一摞唯一能说出张数的东西，
## 被右邻的牌压掉就等于这一摞读不出来了。位置从场景里实测（见 _front_edge）
func _combo_tight(main: Node, piles: Dictionary) -> Array:
	var span := {}      # key → Vector2(左缘, 右缘)
	for k in piles:
		if not str(k).begins_with("ai_combo_"):
			continue
		span[k] = _pile_span(main, str(k), piles[k])
	# 按左缘排序找**相邻**的那一对：空当只在左右相邻的两组之间有意义，
	# 隔着一组的两组离得远是自然的
	var keys: Array = span.keys()
	keys.sort_custom(func(a, b) -> bool: return span[a].x < span[b].x)
	var want: float = main.layout.COMBO_ROW_GAP
	var bad: Array = []
	for i in range(1, keys.size()):
		var left: Vector2 = span[keys[i - 1]]
		var right: Vector2 = span[keys[i]]
		var gap: float = right.x - left.y
		if gap < want - 0.01:
			bad.append("%s|%s 空当 %.2f < %.2f" % [
				keys[i - 1], keys[i], gap, want])
	return bad

## 一摞占的地：Vector2(左缘, 右缘)。收拢摞右边那份侧边清单也算进来 ——
## 清单是这一摞唯一能说出张数的东西，被右邻的牌压掉就等于这一摞读不出来。
##
## 清单这一段取**预留宽**（SIDE_GAP + SIDE_W），不取文字渲染出来的实际宽度。
## 两者差着一点：×28 那三个字符实测只铺到预留宽里的 0.876／0.95。
## 取预留宽是因为排布那头就是按预留宽算地方的（settle_layout.combo_reach），
## 判据跟着同一个口径才问得出「排布对不对」；改用渲染宽的话，「整片居中」
## 会随最右那摞的张数写成几个字符而漂（×9 比 ×28 短半个字符），
## 红的就不是居中这件事了。
##
## 预留宽本身是不是真的罩得住文字，由 _side_overflow 单独判 —— 那一条把
## 这里用到的两个常量和场景里真实的节点接上，抄错了不会两边一起错
## （memory: number-lives-in-five-places）
func _pile_span(main: Node, key: String, uids: Array) -> Vector2:
	var lo := INF
	var hi := -INF
	for u in uids:
		var x: float = main.entities[u].position.x
		lo = minf(lo, x - CardEntity.CARD_SIZE.x / 2.0)
		hi = maxf(hi, x + CardEntity.CARD_SIZE.x / 2.0)
	if lo == INF:
		return Vector2.ZERO
	# 挂没挂清单不自己推（「收拢且 ≥2 张」是 board._sync_side 的规矩），
	# 直接看场景里到底有没有这几个节点
	var g: Variant = main.board._ext_side.get(key)
	if g != null and not (g.get("side", []) as Array).is_empty():
		hi += Board.SIDE_GAP + Board.SIDE_W
	return Vector2(lo, hi)

## 前行那片牌占的地：Vector2(最左缘, 最右缘)
func _front_extent(main: Node, piles: Dictionary) -> Vector2:
	var lo := INF
	var hi := -INF
	for k in piles:
		if not str(k).begins_with("ai_combo_"):
			continue
		var s: Vector2 = _pile_span(main, str(k), piles[k])
		lo = minf(lo, s.x)
		hi = maxf(hi, s.y)
	if lo == INF:
		return Vector2.ZERO
	return Vector2(lo, hi)

## 每份侧边清单的**实际渲染范围**都在预留宽（SIDE_GAP + SIDE_W）里吗。
##
## 这一条是上面 _pile_span 那个口径的底座：整套「组合之间留空当」的算法都按
## 预留宽排地方，预留宽罩不住文字的话，算出来的空当是假的 —— 屏幕上照样压。
## 文字宽从 Label3D.get_aabb() 实测（局部 AABB，左对齐所以从 0 起算），
## 不照字号估：估出来的数一改字体就废
func _side_overflow(main: Node) -> Array:
	var bad: Array = []
	for k in main.board._ext_side:
		var g: Variant = main.board._ext_side[k]
		var uids: Array = main.layout._ai_pile_uids.get(k, [])
		if uids.is_empty():
			continue
		var right := -INF
		for u in uids:
			right = maxf(right, main.entities[u].position.x + CardEntity.CARD_SIZE.x / 2.0)
		var lim: float = right + Board.SIDE_GAP + Board.SIDE_W
		for nd in g.get("side", []):
			if not (nd is Node3D and is_instance_valid(nd)):
				continue
			var far: float = (nd as Node3D).global_position.x
			if nd is Label3D:
				far += (nd as Label3D).get_aabb().size.x
			if far > lim + 0.01:
				bad.append("%s 的清单铺到 %.3f，预留只到 %.3f" % [k, far, lim])
	return bad

## 前行那片牌**最远的边缘**离 x=0 有多远（左右取大者）
func _front_edge(main: Node, piles: Dictionary) -> float:
	var ext: Vector2 = _front_extent(main, piles)
	return maxf(absf(ext.x), absf(ext.y))

## 一摞摊成了几列：按 x 归到 0.1 的格子里数
func _col_count(main: Node, key: String) -> int:
	var xs := {}
	for u in main.layout._ai_pile_uids.get(key, []):
		xs[snappedf(main.entities[u].position.x, 0.1)] = true
	return xs.size()

## 收拢摞的占地**不随张数长**：加到胜利线那么多张，摞占的地方一寸不变。
##
## 为什么要有这一节：上面那几条只量得到桌上现有的张数（开局 20 张现金）。
## 台阶封顶（Board.capped_offset / back_pile_cap）是给几十张、上百张那一头
## 准备的，而那一头桌上量不到 —— 实测不封顶的话 40 张就压进前行，
## 100 张（= 规则表的 win_cash，一局真能走到）摞到 y=4.46、南缘 -1.40
## 盖在货架牌上，240 张时摞顶投到屏幕外。也就是说这一段代码的读者只有这一节，
## 没有它就是「加了个封顶，但没人证明它封住了什么」
##
## 判据是「三个张数下占地逐位相同」，而不是「占地小于某个数」：
## 后者要写一个阈值，而阈值本身又是从这几个常量算出来的（memory:
## number-lives-in-five-places）。「不随张数变」是这次改动的**内容**本身，
## 且它一句话就把「封顶了」和「封在正地方」都问到了
func _check_pile_footprint(main: Node) -> void:
	print("--- 收拢摞的占地不随张数长 ---")
	var state: GameState = main.state
	var cap: int = main.layout.back_pile_cap()
	var win_n: int = int(CardDB.game_rules()["win_cash"])
	# 三档：刚好满级（占地第一次到顶）、胜利线、胜利线的两倍多。
	# 满级那一档单独取，是因为「到顶」和「到顶之后不再长」是两件事：
	# 只量两个大数的话，封顶的级数比 cap 小一截（摞更矮）同样两个都相同
	var marks: Array = [cap, win_n, win_n * 2 + 40]
	var seen: Array = []
	var key := "ai_cash_0"
	# 先跑一趟拿到这一摞现在有几张：下面按**摞里**的张数补，不按 AI 手里的现金数补。
	# 手里的现金包含编进组合的那些（这一局有一个 7 张的组合吃了 3 张现金），
	# 而摞里只有闲置的那些 —— 按手里的数补会每档都少补一个常量，
	# 要 29 张只得到 14 张，三档全都没到该量的那一头
	main.layout._layout_ai_idle()
	await ai_moves_landed(main)
	for want in marks:
		# 补到 want 张。只加不减：这一节在最后跑，后面没有别的判据看这批牌
		var have: int = int(main.layout._ai_pile_uids.get(key, []).size())
		for i in maxi(want - have, 0):
			main._spawn_entity(state.add_card(GameState.AI, "cash"),
				Vector3(13.0, 0.05, -7.0), false)
		main.layout._layout_ai_idle()
		await ai_moves_landed(main)
		await settle()
		var uids: Array = main.layout._ai_pile_uids.get(key, [])
		check(uids.size() >= want, "%s 摞到 %d 张（实际 %d）" % [key, want, uids.size()])
		check(bool(main.layout._ai_pile_compact.get(key, false)),
			"%d 张时这一摞是收拢的（摊开的话下面量的不是封顶那件事）" % want)
		var ext: Vector3 = _extent(main, uids)
		# 南缘：摞沿 +z 长，最靠南那张的南边
		var zmax := -INF
		var top_y := -INF
		for u in uids:
			zmax = maxf(zmax, main.entities[u].position.z)
			top_y = maxf(top_y, main.entities[u].position.y)
		seen.append({"n": uids.size(), "z": ext.z, "y": ext.y,
			"south": zmax + CardEntity.CARD_SIZE.z / 2.0, "top": top_y})
	var drift: Array = []
	for i in range(1, seen.size()):
		var a: Dictionary = seen[0]
		var b: Dictionary = seen[i]
		for f in ["z", "y", "south", "top"]:
			if absf(float(a[f]) - float(b[f])) > 0.001:
				drift.append("%d 张 %s=%.3f ≠ %d 张的 %.3f" % [
					int(b["n"]), f, float(b[f]), int(a["n"]), float(a[f])])
	check(drift.is_empty(),
		"%d/%d/%d 张时摞的占地逐位相同（跨度 z=%.2f y=%.2f 南缘 %.2f 顶高 %.2f；漂的：%s）" % [
			int(seen[0]["n"]), int(seen[1]["n"]), int(seen[2]["n"]),
			float(seen[0]["z"]), float(seen[0]["y"]), float(seen[0]["south"]),
			float(seen[0]["top"]), "无" if drift.is_empty() else ", ".join(drift)])
	# 而且这个占地**正好卡在席位的南界上**：满级的摞退到底，南缘顶着前行的北缘。
	# 少了这条，封顶封在 12 级（摞更矮、更早重合）也满足上面那条 ——
	# 而 12 会显得是算出来的，其实是把「不碰前行」偷偷换成一条更严的规矩
	# （settle_layout.gd 的 back_pile_cap 注释里记着这个坑）
	var front_north: float = main.layout.AI_ROW_Z[0] - CardEntity.CARD_SIZE.z / 2.0
	check(absf(float(seen[0]["south"]) - front_north) < 0.05,
		"满级的摞南缘（%.2f）正好顶在前行北缘（%.2f）上：封顶封在席位真正的容量上" % [
			float(seen[0]["south"]), front_north])
	# 张数一张不少地写在侧边清单里 —— 这是「看不出是几张」那件事的替代出口
	var spec := Board.side_spec(_entities_of(main, main.layout._ai_pile_uids[key]))
	var n_now: int = int(main.layout._ai_pile_uids[key].size())
	check(spec.size() == 1 and str(spec[0]["text"]) == "×%d" % n_now,
		"清单照旧数的是真牌（×%d，实际 %s）" % [n_now, str(spec)])

## 前行的组合张数少就摊开、多才收拢 —— 摊开的那几组每张都露得出标题带。
##
## 为什么要有这一节：上面两节的组合都是 7～8 张，一律走收拢那条路。
## 于是 _spread_ai_combo 整个函数**一次都没被跑到**，删掉它上面全绿
## （memory: green-mutation-means-no-observer 的第二种）。这一节补一个
## 张数少的组合（做空报告，配方 2 张 → 连核心卡 3 张），把摊开那条路跑起来。
##
## 判据全部按**测出来的几何量**取，不读 combo_spread_step 自己那几个常量：
## 读被测常量等于判据和被测量取了同一个值（memory: green-suite-cant-prove-mapping）。
## 南界那条尤其要实测 —— 货架牌的北缘从 is_market 那几张身上量
func _check_combo_form(main: Node) -> void:
	print("--- 组合的形态：摊得下就摊开，摊不下才收拢 ---")
	var state: GameState = main.state
	# 已编进组合的牌不能再编：上面那节连编了 7 个组合，AI 手里的现金被吃掉不少
	var locked := {}
	for combo in state.combos:
		if combo["owner"] == GameState.AI:
			for u in combo["uids"]:
				locked[u] = true
	# 夹具中的攻击配方为 2 张资源，确保本节同时存在摊开的小组与收拢的大组。
	var zk_def: Dictionary = CardDB.get_def("zuokong")
	var zk_n := int(zk_def["recipe_n"])
	# 喂什么资源也从卡表取：写死 "cash" 的话，配方币种一改这一节就编不成组，
	# 而报出来的是「排布不对」——错的位置对，说法把人往错方向带
	var zk_unit := CardDB.unit_id(str(zk_def["recipe_res"]))
	var p3: Dictionary = state.add_card(GameState.AI, "zuokong")
	main._spawn_entity(p3, Vector3(0, 0.05, -3.6), false)
	var uids3: Array = [p3["uid"]]
	for c in state.players[GameState.AI]["cards"]:
		if c["def_id"] == zk_unit and uids3.size() <= zk_n and not locked.has(c["uid"]):
			uids3.append(c["uid"])
	var r3: Dictionary = state.create_combo(GameState.AI, uids3)
	check(r3["ok"], "AI「做空报告+%s×%d」编组成立（%s）" % [
		CardDB.card_name(zk_unit), zk_n, str(r3.get("err", ""))])
	main.layout._layout_ai_idle()
	await create_timer(0.6).timeout
	for i in 5:
		await physics_frame

	var piles: Dictionary = main.layout._ai_pile_uids
	# 货架牌的北缘：实测，不读 MARKET_Z。摊开的组合往南长，越过这条线
	# 就是 AI 的牌钻进货架底下
	# 货架牌不在 main.entities 里（它们是 uid=-1000-idx 的展示牌，没进实体表），
	# 只在 main.market_cards 里 —— 照 entities 扫的话一张都找不到、量出个 inf 来
	var market_north := INF
	for e in main.market_cards:
		if is_instance_valid(e):
			market_north = minf(market_north,
				e.global_position.z - CardEntity.CARD_SIZE.z / 2.0)
	check(market_north < INF, "量到了货架牌的北缘（%.2f）" % market_north)

	var band := CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z
	var n_spread := 0
	var n_compact := 0
	var bad: Array = []
	for k in piles:
		if not str(k).begins_with("ai_combo_"):
			continue
		var uids: Array = piles[k]
		if uids.size() < 2:
			continue
		# 按 x 分列。**组合现在可以有多列**：z 向一列最多摊得开 4 张，
		# 而配方大多是 5 张以上，一列摆不下就横着分列（见 _spread_ai_combo）。
		# 这一节原先断言「一组就是一列」，那条断言连着让 17 个配方全走收拢
		var cols := {}
		for u in uids:
			var kx: float = snappedf(main.entities[u].position.x, 0.1)
			if not cols.has(kx):
				cols[kx] = []
			cols[kx].append(int(u))
		var col_xs: Array = cols.keys()
		col_xs.sort()
		# 列与列不许压边：隔开至少一张卡宽，否则两列的标题带互相盖掉，
		# 分列就白分了（分列的全部意义就是让每张露出自己的标题带）
		for ci in range(1, col_xs.size()):
			var d: float = col_xs[ci] - col_xs[ci - 1]
			if d < CardEntity.CARD_SIZE.x - 0.01:
				bad.append("%s 第 %d 列离上一列只有 %.2f（不到一张卡宽 %.2f）"
					% [k, ci, d, CardEntity.CARD_SIZE.x])
		# zs 取**所有列合起来**的 z 集合。南缘/北端那两条这样量是对的
		# （逐列同构，合起来的最南最北就是每列的最南最北），
		# 但**最小间隔不能这样量** —— 见下面 min_gap 那一段
		var zs: Array = []
		for u in uids:
			zs.append(main.entities[u].position.z)
		zs.sort()
		# 核心卡（uids[0]，core_first_order 排的）在**它那一列**里最南、最高 ——
		# 两种形态都一样。摊开态的台阶是 +z*seat、y 也随 seat 长，座次不翻过来
		# （_spread_ai_combo 里那句 seat = per - 1 - j%per）核心卡就落到最北那个座、
		# 被后面每一张压掉，屏幕上露的是随便一张用户卡。
		#
		# 按列判而不是按整组判：分列之后每列的 z/y 范围一模一样，
		# 「整组最高的那张」在多列之间是平的，谁被挑出来只看遍历次序
		var core: int = int(uids[0])
		var core_x: float = snappedf(main.entities[core].position.x, 0.1)
		var col0: Array = cols[core_x]
		var top_u: int = -1
		var top_y := -INF
		var south_u: int = -1
		var south_z := -INF
		for u in col0:
			var p: Vector3 = main.entities[u].position
			if p.y > top_y:
				top_y = p.y
				top_u = int(u)
			if p.z > south_z:
				south_z = p.z
				south_u = int(u)
		if top_u != core:
			bad.append("%s 核心卡那一列最高的不是核心卡" % k)
		if south_u != core:
			bad.append("%s 核心卡那一列最南的不是核心卡" % k)
		# 南缘不许越过货架牌的北缘
		var south_edge: float = zs[-1] + CardEntity.CARD_SIZE.z / 2.0
		if south_edge > market_north + 0.01:
			bad.append("%s 南缘 %.2f 钻进货架（北缘 %.2f）" % [k, south_edge, market_north])
		# 北端钉在行线上：张数多少都不该让「前行在哪」这件事变位置
		if absf(zs[0] - main.layout.AI_ROW_Z[0]) > 0.01:
			bad.append("%s 北端 %.2f≠行线 %.2f" % [k, zs[0], main.layout.AI_ROW_Z[0]])
		# 形态二分按「读不读得出张数」分，不按张数或形态标志分：
		# 相邻两张隔得出标题带 → 每张自己看得见；隔不出 → 这一摞看不出张数，
		# 必须有侧边清单顶上。最糟的是两样都没有 —— 挤成一坨又没有清单，
		# 那几张彻底读不出来（摊开挤到 0.11 就是这个样子）
		# 最小间隔**逐列量**，不能拿合起来的 zs 量：分了列之后每列同构 ——
		# 同一个 z 在 zs 里出现列数那么多次，排序后相邻两个就是 0，
		# 于是「挤到看不出张数」对任何多列组合都必然成立。
		# 这条判据原先正是这么写的（那句注释说「合起来量等于逐列量」，
		# 对南缘北端成立、对最小间隔不成立），而它一直没红是因为前行的
		# 固定格子把地方压到一列都放不下第二列 —— 多列这条路从没跑到过，
		# 也就是这次修的那个 bug 本身（memory: vacuous-mutation-two-flavors）
		var min_gap := INF
		for cx in cols:
			var cz: Array = []
			for u in cols[cx]:
				cz.append(main.entities[u].position.z)
			cz.sort()
			for i in range(1, cz.size()):
				min_gap = minf(min_gap, cz[i] - cz[i - 1])
		var span: float = zs[-1] - zs[0]
		var g: Variant = main.board._ext_side.get(k)
		var has_badge: bool = g != null and not g.get("side", []).is_empty()
		if min_gap >= band - 0.01:
			n_spread += 1
			# 摊开的不挂侧边清单：每张自己露着标题带，清单是收拢态的替代品
			if has_badge:
				bad.append("%s 摊开了还挂着侧边清单" % k)
		# 收拢态**按有没有清单数**，不按几何跨度数：跨度小不等于收拢了 ——
		# 8 张挤到 Δz=0.11 的跨度只有 0.8（还不到一张卡的 1.7），
		# 按跨度数的话这种「摊开摊到看不出张数」会被记成一个合格的收拢样本，
		# 于是「张数多的组合仍然收拢」这条前提就白站着了（实测过：去掉标题带
		# 那道闸门，按跨度数是 n_compact=1 全绿，按清单数才是 0）
		elif has_badge:
			n_compact += 1
			if span > CardEntity.CARD_SIZE.z + 0.01:
				bad.append("%s 挂着清单却没收拢（跨度 %.2f > 一张卡 %.2f）"
					% [k, span, CardEntity.CARD_SIZE.z])
		else:
			bad.append("%s 挤到看不出张数（最小 Δz=%.3f < 标题带 %.3f）又没有侧边清单"
				% [k, min_gap, band])
	# 两条前提：摊开和收拢**各自都得有样本**，否则下面那条 bad 是半个空判据。
	# 一个都没摊开就是这一节根本没跑到 _spread_ai_combo（这一节存在的理由）；
	# 一个都没收拢就是上面两节那些 7～8 张的组合也被摊开了 —— 它们摊不下
	check(n_spread > 0, "有组合摊开了（%d 组，0 组就是摊开那条路没跑到）" % n_spread)
	check(n_compact > 0, "张数多的组合仍然收拢（%d 组，0 组就是全被摊开了）" % n_compact)
	check(bad.is_empty(), "每个组合的形态都完整可读（坏的：%s）" % [
		"无" if bad.is_empty() else ", ".join(bad)])

	# --- 台阶步长这个函数本身：整个张数域上都要守住两头 ---
	# 上面那几条只量得到桌上真有的那几种张数（现在是 3/4/7/8）。步长的两头
	# 各有一条线，桌上量不到：
	#   上头 —— 不比玩家侧摊得更开（Board.STACK_GAP.z）。这条只在 n=2 时收紧
	#   （预算 0.80 > 0.52），而卡表里最小的配方是 2 张资源、连核心卡 3 张，
	#   桌上永远到不了 n=2。不查的话「别摊得比玩家还开」这条规则没有读者。
	#   下头 —— 不比标题带更挤（挤到看不出张数就该收拢，让侧边清单顶上）。
	# 还要查那道闸门**掐在正地方**：最后一个摊得开的张数确实摊得下（南缘不越界），
	# 第一个摊不开的张数按标题带那条线摊也确实越界 —— 只查「返回 0」的话，
	# 闸门提前一档收手（比如 n≥3 就收拢）同样全绿
	var layout: Node = main.layout
	var step_band: float = layout.combo_band_step()
	var prev := INF
	var dom: Array = []
	var last_spread := 0
	var first_compact := 0
	for n in range(2, 13):
		var s: float = layout.combo_spread_step(n)
		if s > 0.0:
			if s > Board.STACK_GAP.z + 0.0001:
				dom.append("n=%d 步长 %.3f 比玩家侧的 %.3f 还开" % [n, s, Board.STACK_GAP.z])
			if s < step_band - 0.0001:
				dom.append("n=%d 步长 %.3f 比标题带 %.3f 还挤" % [n, s, step_band])
			if s > prev + 0.0001:
				dom.append("n=%d 步长 %.3f 反而比 n=%d 的 %.3f 大" % [n, s, n - 1, prev])
			prev = s
			last_spread = n
		elif first_compact == 0:
			first_compact = n
	check(dom.is_empty(), "步长在整个张数域上都在标题带和玩家侧之间、且随张数递减（%s）" % [
		"无" if dom.is_empty() else ", ".join(dom)])
	var half: float = CardEntity.CARD_SIZE.z / 2.0
	var row0: float = layout.AI_ROW_Z[0]
	if last_spread > 0:
		var edge: float = row0 + layout.combo_spread_step(last_spread) \
			* float(last_spread - 1) + half
		check(edge <= market_north + 0.01,
			"最后一个摊得开的张数（%d）南缘 %.2f 没越过货架北缘 %.2f"
				% [last_spread, edge, market_north])
	if first_compact > 0:
		var edge2: float = row0 + step_band * float(first_compact - 1) + half
		check(edge2 > market_north + 0.01,
			"第一个改收拢的张数（%d）确实摊不下：按标题带摊南缘 %.2f 越过 %.2f"
				% [first_compact, edge2, market_north])

## 开局双方的牌要左右对称：现金在左、用户在右，两边看过去是同一个布局。
## 判据全部拿玩家侧实测出来的坐标当基准，不读 AI 那几个常量 ——
## 读常量的话把常量改错了这条照样过
## 前行排布在**组合个数一路加上去**时的下限，直接喂 plan_combo_row。
##
## 为什么不摆真牌：摆到 20 个组合要 AI 真的成 20 个编组，一局里见不到
## （实测上限 11 个）。而 plan_combo_row 是个纯函数 —— 进去一串 {张数, 形态}、
## 出来一串 x，不碰场景。喂它就能把「摆不下之后怎么退」这一段跑到底。
##
## 这一段守的是两条**摆不下时**才生效的规矩，上面摆真牌那一节碰不到
## （8 个组合还在一行的宽度里，压节距和封顶都没启用 ——
## 也就是「有分支没人看」，memory: green-mutation-means-no-observer）：
##   1. 压节距压到卡宽为止，再挤也不许**牌压牌** —— 牌压牌看不见
##      （长得像「本来就这么多牌」），出桌看得见，所以宁可出桌
##   2. 卡宽这条底线放得下的时候，整行就得真的在桌上
func _check_plan_row_stress(main: Node) -> void:
	# 混着摆，且**把宽的排在一起**：摆真牌那一节里最宽的两摞恰好一头一尾
	# （编组次序决定的），于是「节距不够」这件事在那儿看不见 ——
	# 中间挨着的都是窄摞，窄摞之间怎么算都有空当。这里按 5 个一轮循环，
	# 8 张（2 列）和 11 张（3 列）必然成为邻居
	var sizes: Array = [2, 4, 5, 8, 11]
	var avail: float = main.layout.combo_row_width()
	var want_gap: float = main.layout.COMBO_ROW_GAP
	var off := []      # 放得下却出了桌的
	var lap := []      # 牌压牌的
	var skew := []     # 整片没居中的
	var tight := []    # 没压节距却挤掉了声明的空当
	var caved := []    # 空当还能挤、却已经降列崩成收拢的
	var cramp := []    # 一行空得慌、节距却没撑开的
	for k in range(1, 25):
		var piles: Array = []
		for i in k:
			piles.append({ "n": sizes[i % sizes.size()], "compact": null })
		var plan: Array = main.layout.plan_combo_row(piles)
		if plan.size() != k:
			skew.append("%d 组只排出 %d 个" % [k, plan.size()])
			continue
		# 先量出每一组的占地，再逐条判：整行的节距按**最宽那组**算，
		# 所以判之前得先知道谁最宽
		var reach: Array = []
		var lead := 0.0
		var trail := 0.0
		for e in plan:
			var r: Vector2 = main.layout.combo_reach(
				int(e["n"]), int(e["cols"]), bool(e["compact"]))
			reach.append(r)
			lead = maxf(lead, r.x)
			trail = maxf(trail, r.y)
		# 不压节距摆得下吗。摆得下就不许压，下面那条空当只在这种 k 上判。
		#
		# 这个数自己算（k、最宽那组的占地、声明的空当），**不从 plan 里读节距**：
		# 读节距等于拿排布算出来的数去判排布自己 —— 节距算错了这个前提跟着错，
		# 空当那一条就被跳过去了（memory: vacuous-mutation-two-flavors）
		var need_squeeze: bool = float(k - 1) * (lead + trail + want_gap) \
			+ lead + trail > avail + 0.01
		# --- 降列这一步不许提前走：空当还挤得动就不该崩成收拢 ---
		#
		# 「空当挤到 0 摆得下」这个前提要按**这几组想要的形态**算，不是按
		# plan 给出来的形态算：plan 里已经是降完列的结果，拿它算等于
		# 「排布说降得对，所以降得对」（memory: vacuous-mutation-two-flavors）。
		# 所以自己按张数问一遍 combo_cols / combo_spread_step。
		#
		# 这一条盯的是断崖：9 个 8 张的组合，带空当要 27.30 > 24.80，
		# 空当挤到 0 只要 22.50 —— 挤一下就摆得下，却曾经全体降列变收拢，
		# 屏幕上九个组合各剩一张牌（正是报上来的「组合牌摞在一块儿」）
		var w_reach: Array = []
		var w_lead := 0.0
		var w_trail := 0.0
		var want_spread := 0
		for i in k:
			var n2: int = sizes[i % sizes.size()]
			var c2: int = main.layout.combo_cols(n2)
			var s2: float = main.layout.combo_spread_step(
				ceili(float(n2) / float(maxi(c2, 1))))
			if s2 <= 0.0:
				c2 = 1
			else:
				want_spread += 1
			var r2: Vector2 = main.layout.combo_reach(n2, c2, s2 <= 0.0)
			w_reach.append(r2)
			w_lead = maxf(w_lead, r2.x)
			w_trail = maxf(w_trail, r2.y)
		# 零空当摆得下吗：节距取 w_lead+w_trail（最宽那组边挨边），
		# 但整片的宽要**逐组量**，不能拿 k×节距 估。
		#
		# 这里踩过一次：按 k×(w_lead+w_trail) 估的话，7 组算出 26.60 > 24.80、
		# 判成「摆不下」于是跳过这一条 —— 而 7 组正是降列闸门写错时唯一露馅的地方，
		# 判据于是一条也不红。差别在于两头那两组是窄的（张数按 sizes 轮转），
		# 整片的边缘由它们定，按最宽那组算等于每一组都当最宽的算
		# （memory: vacuous-mutation-two-flavors）
		var zlo := INF
		var zhi := -INF
		for i in k:
			var zx: float = float(i) * (w_lead + w_trail)
			zlo = minf(zlo, zx - (w_reach[i] as Vector2).x)
			zhi = maxf(zhi, zx + (w_reach[i] as Vector2).y)
		var zero_gap_fits: bool = zhi - zlo <= avail + 0.01
		if zero_gap_fits:
			var got_spread := 0
			for e in plan:
				if not bool(e["compact"]):
					got_spread += 1
			if got_spread < want_spread:
				caved.append("%d 组：该摊开 %d 组、只摊开了 %d 组（零空当只要 %.2f ≤ %.2f）" % [
					k, want_spread, got_spread, zhi - zlo, avail])
		# --- 一行空得慌的时候节距要撑开 ---
		#
		# 「不重叠」和「不显得挤」是两件事：节距按最宽那组的伸出算，组合小的时候
		# 那个数很小 —— 两个 2 张的组合各占一列，节距只有 1.80，而前行有 24.80、
		# 这两组一共只用了 3.00。原先的固定网格给的是 2.50，所以光判不重叠的话，
		# 「比改之前还挤」这件事一条判据也不会红。
		#
		# 撑得到多宽自己反解（占地对节距线性、斜率 k-1），不读 plan 里的节距：
		# 读它就成了拿排布的结果判排布自己
		if k > 1:
			var room_pitch: float = (avail - lead - trail) / float(k - 1)
			var want_pitch: float = minf(main.layout.AI_SLOT_PITCH, room_pitch)
			var got_pitch: float = float(plan[0]["pitch"])
			if got_pitch < want_pitch - 0.01:
				cramp.append("%d 组：节距 %.2f < %.2f（撑得下 %.2f）" % [
					k, got_pitch, want_pitch, room_pitch])
		var lo := INF
		var hi := -INF
		for i in plan.size():
			var x: float = float(plan[i]["x"])
			lo = minf(lo, x - reach[i].x)
			hi = maxf(hi, x + reach[i].y)
			if i == 0:
				continue
			var px: float = float(plan[i - 1]["x"])
			# 牌压牌只看**牌**的占地，不算清单：清单互相盖住是压节距时
			# 明码认下的代价（张数读不出来），牌互相盖是绝对不许的
			var half_l: float = float(int(plan[i]["cols"]) - 1) / 2.0 \
				* main.layout.COMBO_COL_PITCH + CardEntity.CARD_SIZE.x / 2.0
			var half_p: float = float(int(plan[i - 1]["cols"]) - 1) / 2.0 \
				* main.layout.COMBO_COL_PITCH + CardEntity.CARD_SIZE.x / 2.0
			if x - half_l < px + half_p - 0.01:
				lap.append("%d 组：第 %d 个的左缘 %.2f 压进左邻的 %.2f" % [
					k, i + 1, x - half_l, px + half_p])
			# 空当（含清单）。整行摆得下时必须兑现声明的那个空当 ——
			# 摆不下才允许压（need_squeeze）
			var gap: float = (x - reach[i].x) - (px + reach[i - 1].y)
			if not need_squeeze and gap < want_gap - 0.01:
				tight.append("%d 组：第 %d 和第 %d 之间只剩 %.2f" % [
					k, i, i + 1, gap])
		if absf(lo + hi) > 0.01:
			skew.append("%d 组：[%.2f,%.2f]" % [k, lo, hi])
		# 「放得下」= 节距压到卡宽这条底线时整片还在桌上。
		#
		# 底线宽度不是 k×卡宽：两头还各挂着一截 —— 左边是最靠边那组的半张卡，
		# 右边还要加上收拢摞的侧边清单（1.71，比半张卡宽出一倍多）。
		# 按 k×卡宽算的话，20 个组合会算成「放得下」（24.00 ≤ 24.80），
		# 而带上两头那两截其实要 25.11 —— 那时出桌是明码认下的代价，不是 bug，
		# 判据却会红在一件做不到的事上
		var floor_w: float = float(k - 1) * CardEntity.CARD_SIZE.x + lead + trail
		if floor_w <= avail + 0.01 and hi - lo > avail + 0.01:
			off.append("%d 组：宽 %.2f > %.2f（底线只要 %.2f）" % [
				k, hi - lo, avail, floor_w])
	check(lap.is_empty(), "组合个数加到 24 也没有牌压牌（%s）" % [
		"无" if lap.is_empty() else ", ".join(lap)])
	check(off.is_empty(), "卡宽放得下的组合数都没出桌（%s）" % [
		"无" if off.is_empty() else ", ".join(off)])
	check(skew.is_empty(), "每个组合个数下整片都居中（%s）" % [
		"无" if skew.is_empty() else ", ".join(skew)])
	check(tight.is_empty(), "一行摆得下时每两组之间都兑现了声明的空当（%s）" % [
		"无" if tight.is_empty() else ", ".join(tight)])
	check(caved.is_empty(), "空当还挤得动就不降列（不崩成收拢）（%s）" % [
		"无" if caved.is_empty() else ", ".join(caved)])
	check(cramp.is_empty(), "一行空得慌时节距撑开到 AI_SLOT_PITCH（%s）" % [
		"无" if cramp.is_empty() else ", ".join(cramp)])

func _check_open_symmetry(main: Node) -> void:
	var lo := {}     # def_id → 该方该资源最小 x
	var hi := {}
	var near := {}   # 该方最靠购牌区的那张卡到购牌区的距离
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if not is_instance_valid(e) or e.is_market:
			continue
		var who: String = GameState.PLAYER if e.draggable else GameState.AI
		var k := "%s:%s" % [who, e.def_id]
		lo[k] = minf(float(lo.get(k, INF)), e.position.x)
		hi[k] = maxf(float(hi.get(k, -INF)), e.position.x)
		var d: float = absf(e.position.z - main.MARKET_Z)
		near[who] = minf(float(near.get(who, INF)), d)

	var pc := "%s:%s" % [GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH)]
	var pu := "%s:%s" % [GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER)]
	var ac := "%s:%s" % [GameState.AI, CardDB.unit_id(CardDB.RES_CASH)]
	var au := "%s:%s" % [GameState.AI, CardDB.unit_id(CardDB.RES_USER)]
	if not (lo.has(pc) and lo.has(pu) and lo.has(ac) and lo.has(au)):
		check(false, "开局双方都有现金和用户卡（缺 key）")
		return
	# AI 那一摞的 x 要落在玩家同种资源那一片的 x 跨度里：两边的现金对着现金、
	# 用户对着用户，隔着购牌区看是同一列
	check(float(lo[ac]) >= float(lo[pc]) - 0.01 and float(hi[ac]) <= float(hi[pc]) + 0.01,
		"AI 现金摞对着玩家的现金那一片（AI x=%.2f，玩家 %.2f..%.2f）" % [
			float(lo[ac]), float(lo[pc]), float(hi[pc])])
	check(float(lo[au]) >= float(lo[pu]) - 0.01 and float(hi[au]) <= float(hi[pu]) + 0.01,
		"AI 用户摞对着玩家的用户那一片（AI x=%.2f，玩家 %.2f..%.2f）" % [
			float(lo[au]), float(lo[pu]), float(hi[pu])])
	check(float(hi[ac]) < float(lo[au]), "AI 侧也是现金在左、用户在右")
	# 开局零组合时 AI 的牌不许贴着购牌区：离购牌区至少和玩家侧一样远。
	# 这是那个 bug 的正脸 —— AI 的两堆闲置卡被排进了靠购牌区的前排
	check(float(near.get(GameState.AI, 0.0)) >= float(near.get(GameState.PLAYER, INF)) - 0.01,
		"AI 的牌离购牌区不比玩家近（AI %.2f / 玩家 %.2f）" % [
			float(near.get(GameState.AI, 0.0)), float(near.get(GameState.PLAYER, 0.0))])
	_check_open_form(main)

## 开局两边的形态也得一样：玩家摊开，AI 就不许收拢成一坨。
## 上面那几条只管「x 对得上、不比玩家更贴购牌区」—— 玩家摊成三列、
## AI 挤成一摞的时候它们照样全过，那正是这个 bug 的样子。
##
## 判据是把两边各自拆成列，一列对一列地比：列数、每列张数、每列的形态。
## 形态只看「同一列里前后两张挪开多少」比卡自己的长度 —— 差得远就是摞
## （牌几乎完全重叠、看不出张数），够看得见就是摊开。量的是卡自己的尺寸，
## 拿玩家侧实测出来的当基准，不读 AI 那几个摊开常量
func _check_open_form(main: Node) -> void:
	var cols := {}     # "阵营:def_id" → {x → Array[z]}
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if not is_instance_valid(e) or e.is_market:
			continue
		var k := "%s:%s" % [GameState.PLAYER if e.draggable else GameState.AI, e.def_id]
		if not cols.has(k):
			cols[k] = {}
		# 归列：同一列的 x 是一个数，抖动归到 0.1 的格子里
		var bx: float = snappedf(e.position.x, 0.1)
		if not cols[k].has(bx):
			cols[k][bx] = []
		cols[k][bx].append(e.position.z)

	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		var did: String = CardDB.unit_id(res)
		var p: Array = _columns_of(cols, GameState.PLAYER, did)
		var a: Array = _columns_of(cols, GameState.AI, did)
		if p.is_empty() or a.is_empty():
			check(false, "%s：开局双方都有这种资源（玩家 %d 列 / AI %d 列）" % [
				did, p.size(), a.size()])
			continue
		check(p.size() == a.size(), "%s：AI 的列数和玩家一样（玩家 %d 列 / AI %d 列）" % [
			did, p.size(), a.size()])
		if p.size() != a.size():
			continue
		var bad: Array = []
		for i in p.size():
			if int(p[i]["n"]) != int(a[i]["n"]) or String(p[i]["form"]) != String(a[i]["form"]) \
					or absf(float(p[i]["x"]) - float(a[i]["x"])) > 0.2:
				bad.append("玩家[%s] ≠ AI[%s]" % [_col_desc(p[i]), _col_desc(a[i])])
		check(bad.is_empty(), "%s：AI 一列对一列地照玩家的排布来（对不上的：%s）" % [
			did, "无" if bad.is_empty() else "; ".join(bad)])

## 某一方某种资源的列，按 x 从左到右
func _columns_of(cols: Dictionary, who: String, def_id: String) -> Array:
	var one: Dictionary = cols.get("%s:%s" % [who, def_id], {})
	var xs: Array = one.keys()
	xs.sort()
	var out: Array = []
	for x in xs:
		var zs: Array = one[x]
		out.append({"x": x, "n": zs.size(), "form": _form_of(zs)})
	return out

## 一列牌是摞着还是摊开的。看的是前后两张之间挪开多少：
## 不到卡长的两成就是摞（几乎完全重叠），够多就是摊开
func _form_of(zs: Array) -> String:
	if zs.size() <= 1:
		return "单张"
	var lo := INF
	var hi := -INF
	for z in zs:
		lo = minf(lo, float(z))
		hi = maxf(hi, float(z))
	var step: float = (hi - lo) / float(zs.size() - 1)
	return "摞" if step < CardEntity.CARD_SIZE.z * 0.2 else "摊开"

func _col_desc(c: Dictionary) -> String:
	return "x=%.1f %d张 %s" % [float(c["x"]), int(c["n"]), String(c["form"])]

## 收拢态的摞也要对着玩家侧的同种资源。基准是玩家那一片实测出来的 x 跨度，
## 不读 AI_PILE_*_ANCHOR —— 读常量的话把常量改错了这条照样过
func _check_pile_x(main: Node, piles: Dictionary) -> void:
	var lo := {}
	var hi := {}
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if not is_instance_valid(e) or e.is_market or not e.draggable:
			continue
		lo[e.def_id] = minf(float(lo.get(e.def_id, INF)), e.position.x)
		hi[e.def_id] = maxf(float(hi.get(e.def_id, -INF)), e.position.x)
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		var did: String = CardDB.unit_id(res)
		var key := "ai_%s_0" % did
		if not piles.has(key) or not lo.has(did):
			check(false, "%s：这一刻双方都有这种资源（AI 摞 %s / 玩家 %s）" % [
				did, piles.has(key), lo.has(did)])
			continue
		var x: float = main.entities[piles[key][-1]].position.x
		check(x >= float(lo[did]) - 0.01 and x <= float(hi[did]) + 0.01,
			"AI %s摞对着玩家的%s那一片（AI x=%.2f，玩家 %.2f..%.2f）" % [
				did, did, x, float(lo[did]), float(hi[did])])

## 摞的侧边清单不许飘在半空。开局这一刻是它的考场：发牌那批正从头顶飞过，
## 清单的高度要是拿实时坐标扫周围算的，就会被半路上的牌顶起来，落地之后
## 没人再把它放回来（实测 AI 现金摞的 ×20 挂到 y=4.45，投出去在屏幕外）。
## 判据是「清单不许比桌上最高那张牌还高」—— 清单是给一摞牌作注的，
## 不读 SIDE_Y 那几个高度常量
func _check_side_height(main: Node) -> void:
	var ceil_y := -INF
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e):
			ceil_y = maxf(ceil_y, e.global_position.y)
	ceil_y += CardEntity.CARD_SIZE.y
	var floating: Array = []
	for k in main.board._ext_side:
		for nd in main.board._ext_side[k].get("side", []):
			if nd != null and is_instance_valid(nd) and nd.global_position.y > ceil_y:
				floating.append("%s y=%.2f" % [k, nd.global_position.y])
	check(floating.is_empty(), "侧边清单没飘在半空（不高于最高的牌 %.2f，飘着的：%s）" % [
		ceil_y, "无" if floating.is_empty() else ", ".join(floating)])

## 一摞牌占地的横向中心。收拢摞就是那一张的 x；分列的组合是最左列与最右列的中点
func _center_x(main: Node, uids: Array) -> float:
	var xmin := INF
	var xmax := -INF
	for u in uids:
		var x: float = main.entities[u].position.x
		xmin = minf(xmin, x)
		xmax = maxf(xmax, x)
	return (xmin + xmax) / 2.0

## 一摞牌的 z / y 跨度
func _extent(main: Node, uids: Array) -> Vector3:
	var zmin := INF
	var zmax := -INF
	var ymin := INF
	var ymax := -INF
	for u in uids:
		var p: Vector3 = main.entities[u].position
		zmin = minf(zmin, p.z)
		zmax = maxf(zmax, p.z)
		ymin = minf(ymin, p.y)
		ymax = maxf(ymax, p.y)
	return Vector3(0, ymax - ymin, zmax - zmin)

func _entities_of(main: Node, uids: Array) -> Array:
	var out: Array = []
	for u in uids:
		out.append(main.entities[u])
	return out
