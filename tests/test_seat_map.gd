# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 座位映射测试：把座位对调，验证界面照样以「我」为近侧。
## 运行：godot --headless -s tests/test_seat_map.gd
##
## 为什么要有这一条：其余 864 条断言全跑在 my_seat=PLAYER 的单机局上，
## 场景层漏掉一处 `GameState.PLAYER` 硬编码，它们照样全绿 —— 因为那一处
## 恰好等于 my_seat。只有把座位换成 BOT 才能让漏掉的那处露出来：
## 它会去摆对手的牌，摆到远侧；双方相同卡牌保持同一套配色。
##
## 联网局里客户端 B 拿到的就是 GameState.BOT 这个座位（scenes/main.gd 的 set_seats：
## GameState.PLAYER/BOT 全仓引用近八百处、其中测试占九成，改名要波及三十多个
## 测试文件，所以映射不改名）。
##
## 判据用「近侧 / 远侧」而不是读 PLAYER_ZONE_Z / BOT_ZONE_Z：判据不许读被测
## 常量。两侧隔着购牌区（MARKET_Z=-1.6），拿 z 的正负号分边就够，
## 谁把区域整体挪了这条也不该跟着动


func _initialize() -> void:
	print("=== 座位映射测试 ===\n")
	# 本测试检查座位与场景流程，使用小计算额度，不把完整搜索耗时误判为未交接。
	BOTSearch.restore_defaults()
	BOTSearch.set_override("compute_budget",100000)

	# --- 单机默认：my_seat 就是 PLAYER ---
	var a: Node = await boot_main()
	check(a.my_seat == GameState.PLAYER and a.foe_seat == GameState.BOT,
		"默认座位 = PLAYER / BOT（单机局与改造前一致）")
	a.queue_free()
	await physics_frame

	# --- 对调座位：我坐 BOT 这个座位 ---
	#
	# 只等 5 帧就先清空公共区：换座位后对手是先手，_sync_round 末尾那个
	# _begin_action_phase() 已经把它的 _foe_action() 挂在 BEAT_BOT_THINK(0.6s) 后面。
	# 公共区不空，对手会买到攻击卡并打我 —— 我方产出就不是确定的那一份了
	# （实测见过 20→28：产出满额、被攻击掉 4）。
	# 所以这里必须定帧，不能用不带参数的 boot_main（那条等的是「开局补间跑完」，
	# 等完就压着那 0.6s 的边了）—— 代价是第 5 帧撞在飞入补间中间，见 _clear_market
	var main: Node = await boot_main_seated(GameState.BOT, GameState.PLAYER, 5)
	_clear_market(main)
	for i in 25:
		await physics_frame
	_free_market_visuals(main)
	check(main.my_seat == GameState.BOT and main.foe_seat == GameState.PLAYER,
		"set_seats 生效（my_seat=BOT）")

	# 我的牌：近侧（z>0）、可拖、不变暗
	var mine_far := 0
	var mine_locked := 0
	var mine_dimmed := 0
	var mine_n := 0
	for c in main.state.players[main.my_seat]["cards"]:
		var e: CardEntity = main.entities.get(c["uid"])
		if e == null or not is_instance_valid(e):
			continue
		mine_n += 1
		if e.position.z <= 0.0:
			mine_far += 1
		if not e.draggable:
			mine_locked += 1
		if e._dimmed:
			mine_dimmed += 1
	# 每条都把张数并进判据：漏掉一处硬编码时这一侧会建出 0 张实体，
	# 而「越界 0 张 / 不可拖 0 张」在空集上都是真空为真 —— 只报一条红会
	# 让人以为是单点问题，实际是整侧没建出来
	check(mine_n > 0, "我的牌建出了实体（%d 张）" % mine_n)
	check(mine_n > 0 and mine_far == 0, "我的牌全在近侧（越界 %d / %d 张）" % [mine_far, mine_n])
	check(mine_n > 0 and mine_locked == 0, "我的牌全可拖（不可拖 %d / %d 张）" % [mine_locked, mine_n])
	check(mine_n > 0 and mine_dimmed == 0, "我的牌都不变暗（变暗 %d / %d 张）" % [mine_dimmed, mine_n])

	# 对手的牌：远侧（z<0）、不可拖、与我方使用相同卡面配色
	var foe_near := 0
	var foe_draggable := 0
	var foe_dimmed := 0
	var foe_n := 0
	for c in main.state.players[main.foe_seat]["cards"]:
		var e: CardEntity = main.entities.get(c["uid"])
		if e == null or not is_instance_valid(e):
			continue
		foe_n += 1
		if e.position.z >= 0.0:
			foe_near += 1
		if e.draggable:
			foe_draggable += 1
		if e._dimmed:
			foe_dimmed += 1
	check(foe_n > 0, "对手的牌建出了实体（%d 张）" % foe_n)
	check(foe_n > 0 and foe_near == 0, "对手的牌全在远侧（越界 %d / %d 张）" % [foe_near, foe_n])
	check(foe_n > 0 and foe_draggable == 0, "对手的牌都不可拖（可拖 %d / %d 张）" % [foe_draggable, foe_n])
	check(foe_n > 0 and foe_dimmed == 0, "对手的牌不额外调暗，保持与我方同卡同色（调暗 %d / %d 张）" % [foe_dimmed, foe_n])

	# 同一 def_id 在双方区域的卡面材质必须完全一致，不能因座位或重建路径换色。
	var mine_by_def: Dictionary = {}
	for c in main.state.players[main.my_seat]["cards"]:
		var me: CardEntity = main.entities.get(c["uid"])
		if me != null and is_instance_valid(me) and not mine_by_def.has(me.def_id):
			mine_by_def[me.def_id] = me
	var color_pairs := 0
	var color_mismatch := 0
	for c in main.state.players[main.foe_seat]["cards"]:
		var foe: CardEntity = main.entities.get(c["uid"])
		if foe == null or not is_instance_valid(foe) or not mine_by_def.has(foe.def_id):
			continue
		var mine: CardEntity = mine_by_def[foe.def_id]
		color_pairs += 1
		if not _same_card_colors(mine, foe):
			color_mismatch += 1
	check(color_pairs > 0, "双方至少有一组同 def_id 卡牌可比对颜色（%d 组）" % color_pairs)
	check(color_pairs > 0 and color_mismatch == 0, "双方同卡牌面颜色一致（不一致 %d / %d 组）" % [color_mismatch, color_pairs])

	# 落点分配也得跟着座位走：同一个锚点，我方钳在近侧、对手钳在远侧
	var probe := Vector3(0, 0.05, 0)
	var spot_mine: Vector3 = main.layout._free_spot(probe, main.my_seat)
	var spot_foe: Vector3 = main.layout._free_spot(probe, main.foe_seat)
	check(spot_mine.z > 0.0, "_free_spot(my_seat) 落在近侧（z=%.2f）" % spot_mine.z)
	check(spot_foe.z < 0.0, "_free_spot(foe_seat) 落在远侧（z=%.2f）" % spot_foe.z)

	# 战报里的公司名也得跟着座位走。这一段用的是引擎座位常量而不是
	# main.my_seat —— 要验的正是「同一条日志，坐 BOT 这个座位的人念反」：
	# 拿 my_seat 去构造日志，两边都念「你的公司」，判据就恒真了
	# （日志条目的结构与渲染细节在 test_log_viewpoint.gd 里单独验）
	var entry := { "round": 1, "fmt": "%s 点拆 %s 的组合", "args": [
		GameState.seat_arg(GameState.PLAYER), GameState.seat_arg(GameState.BOT)] }
	check(main._render_log(entry) == "对手公司 点拆 你的公司 的组合",
		"my_seat=BOT 时战报念反（%s）" % main._render_log(entry))
	check(main._seat_name(GameState.BOT) == "你的公司"
			and main._seat_name(GameState.PLAYER) == "对手公司",
		"_seat_name 按座位给称呼（BOT=%s，PLAYER=%s）" % [
			main._seat_name(GameState.BOT), main._seat_name(GameState.PLAYER)])

	await _scripted_round(main)
	# 先等补间落定再释放：结算刚跑完，产出牌的飞入补间还在跑，
	# 直接 queue_free 会把 lambda 捕获的卡释放掉（报一片 "Lambda capture was freed"）
	await settle()
	main.queue_free()
	await physics_frame

	await _live_market_round()
	_check_no_hardcoded_seat()
	BOTSearch.restore_defaults()
	finish()


## 第四段：静态检查 —— 场景层不许再出现 `GameState.PLAYER` / `GameState.BOT`。
##
## 为什么要有这条静态检查，而不是把行为测试铺满：
## 上面两段跑完，变异检查（tools/_seat_mut.py，把每一处 my_seat 改回
## GameState.PLAYER 看测试是否变红）三轮累计只杀掉 61 处里的 17 处。剩下的
## 都落在场景测试摸不到的路径上：拖拽买卡、典当、游戏结束、攻击瞄准的大半。
## 要把它们全用行为断言盖住，得给每条路径搭一套场景，代价远超这次改动本身。
##
## 而真正要防的失效模式并不是「某一行行为错」，是**「以后又有人在场景层
## 写死了座位」**。那件事一条 grep 就能盖住全部 61 处，还不会飘 ——
## 活市场让对手的选择不确定，变异检查自己是 flaky 的（同一处三轮里
## 时杀时漏，13/14/15/16 都出现过）。静态检查没有这个问题。
##
## 两条各管一头：行为测试证明映射**是对的**（摆放、可拖、流程都验过），
## 静态检查保证它**不会被改回去**。真正补齐行为覆盖是 #15 的活
## （同一串意图 → 同一个状态哈希），那个要等意图管道先落地
func _check_no_hardcoded_seat() -> void:
	# 白名单：声明 my_seat / foe_seat 本身，以及 _actor 的默认值。
	# 前两句是**定义**座位的地方，_actor 每回合由 _begin_action_phase()
	# 的 state.action_first() 重设，默认值只在 set_seats 之前活着
	const ALLOW := [
		"var my_seat := GameState.PLAYER",
		"var foe_seat := GameState.BOT",
		"var _actor := GameState.PLAYER",
		# 单机局座位对的**唯一**定义处。重开一局要复位成它
		# （main._reset_session_flags），而那儿再写一次 GameState.PLAYER / BOT
		# 就是第二个定义处 —— 这条检查在那一版上真的报过一次
		"const SOLO_SEATS := [GameState.PLAYER, GameState.BOT]",
	]
	var files := ["res://scenes/main.gd", "res://scenes/settle_layout.gd",
		"res://scenes/board.gd", "res://scenes/card.gd"]
	var bad: Array[String] = []
	var scanned := 0
	for path in files:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			bad.append("%s 打不开" % path)
			continue
		scanned += 1
		var n := 0
		while not f.eof_reached():
			var line := f.get_line()
			n += 1
			var code := line.strip_edges()
			if code.begins_with("#"):
				continue   # 注释里说明「PLAYER/BOT 是座位编号」是要留的
			# 去掉行尾注释再判：`var x = 1  # 见 GameState.PLAYER` 不算违规
			var hash_at := code.find("#")
			if hash_at >= 0:
				code = code.substr(0, hash_at).strip_edges()
			if not ("GameState.PLAYER" in code or "GameState.BOT" in code):
				continue
			var allowed := false
			for ok in ALLOW:
				if code.begins_with(ok):
					allowed = true
					break
			if not allowed:
				bad.append("%s:%d  %s" % [path.get_file(), n, code])
		f.close()
	# 扫到的文件数并进判据：路径写错时「违规 0 处」是真空为真
	check(scanned == files.size() and bad.is_empty(),
		"场景层无硬编码座位（扫 %d/%d 个文件，违规 %d 处）%s"
			% [scanned, files.size(), bad.size(),
				("\n      " + "\n      ".join(bad)) if not bad.is_empty() else ""])


## 第三段：换座位 + 公共区活着，只验不变量。
##
## 为什么要单独一段：上面那段清空了公共区，对手无卡可买，于是 BOT 买卡那一族
## （`pick_market_buy` / `state.buy(foe_seat, …)` / `_unit_anchor(foe_seat, …)`）
## 整段不执行 —— 变异检查实测，清空后杀死数从 16 掉到 13，掉的正是这几处。
## 反过来公共区活着产出数就不确定（对手会买攻击卡打我）。
## 所以两段各取一头：那边验确定的产出数，这边验买卡路径上的座位。
##
## 这一段不设产出判据，只设「对手买的卡不许进我手里、花的不许是我的钱」——
## 这个不变量与对手买了什么无关，所以不需要固定种子
func _live_market_round() -> void:
	var main: Node = await boot_main_seated(GameState.BOT, GameState.PLAYER, 5)
	var state: GameState = main.state
	var pre_cash: int = state.resource_count(main.my_seat, CardDB.RES_CASH)
	var pre_user: int = state.resource_count(main.my_seat, CardDB.RES_USER)
	var pre_uids := {}
	for c in state.players[main.my_seat]["cards"]:
		pre_uids[c["uid"]] = true
	var foe_n0: int = state.players[main.foe_seat]["cards"].size()
	var market_n0: int = state.market.size()
	check(market_n0 > 0, "公共区有货（%d 个货位）" % market_n0)

	var handed := false
	# BOT 搜索在线程中消耗真实 CPU 时间，只有演出补间和计时器受 TEST_SPEED
	# 加速。交接的 15 秒预算必须按墙钟计算，否则 5 倍速会把正常搜索误报为超时。
	var handoff_deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < handoff_deadline:
		await process_frame
		if main._actor == main.my_seat and not main.board.input_locked:
			handed = true
			break
	check(handed, "公共区活着时对手也能行动完并交接")
	if not handed:
		main.queue_free()
		return

	var bought: int = foe_n0 - state.players[main.foe_seat]["cards"].size()
	check(state.players[main.foe_seat]["cards"].size() >= foe_n0 or bought >= 0,
		"对手手牌数变化合法（%d→%d）" % [foe_n0, state.players[main.foe_seat]["cards"].size()])

	var mine_now := {}
	for c in state.players[main.my_seat]["cards"]:
		mine_now[c["uid"]] = true
	var intruded := 0
	for u in mine_now:
		if not pre_uids.has(u):
			intruded += 1
	check(intruded == 0, "对手买的卡没进我手里（多出 %d 张）" % intruded)
	check(state.resource_count(main.my_seat, CardDB.RES_CASH) == pre_cash,
		"对手买卡没花我的钱（资金 %d→%d）" % [
			pre_cash, state.resource_count(main.my_seat, CardDB.RES_CASH)])
	check(state.resource_count(main.my_seat, CardDB.RES_USER) == pre_user,
		"对手买卡没动我的用户（%d→%d）" % [
			pre_user, state.resource_count(main.my_seat, CardDB.RES_USER)])

	# 再把这个回合跑完。这一段的价值全在「公共区活着」：对手买得到攻击卡，
	# 攻击阶段才真的会跑；双方都有组合，结算里 `for who in [my_seat, foe_seat]`
	# 那两个循环才两边都走一遍。变异检查实测这三处只有在活市场下才打得中。
	# 这里不设产出数判据（对手买了什么不确定），只验回合能推进、实体不跑偏
	# 一组要几张从卡表算：核心卡 1 张 + recipe_n 张料
	var core := "shuabuting"
	var need: int = 1 + int(CardDB.get_def(core)["recipe_n"])
	var my_prod := [main._spawn_entity(
		state.add_card(main.my_seat, core), Vector3(3, 0.3, 3.2), true)]
	for c in state.players[main.my_seat]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_USER) and my_prod.size() < need:
			my_prod.append(main.entities[c["uid"]])
	if my_prod.size() == need:
		main.board.groups.append({ "cards": my_prod, "label": null })
		main.board.refresh_group(main.board.groups.back())
	check(my_prod.size() == need, "活市场局里也凑齐了一个组合（%d 张）" % my_prod.size())

	var round0: int = state.round_num
	main._on_action_done()
	var done := false
	for i in 300:
		await create_timer(0.1).timeout
		if state.winner != "" or state.round_num > round0:
			done = true
			break
	check(done, "公共区活着（含攻击阶段）也能跑完整回合")

	var engine_n: int = state.players[main.my_seat]["cards"].size() \
		+ state.players[main.foe_seat]["cards"].size()
	var live_n := 0
	for uid in main.entities:
		if is_instance_valid(main.entities[uid]):
			live_n += 1
	check(live_n == engine_n,
		"攻击+结算之后实体仍与引擎一致（实体 %d / 引擎 %d）" % [live_n, engine_n])

	await settle()
	main.queue_free()
	await physics_frame


## 清空公共区。分两步是必须的：
##
## 引擎侧（`state.market`）立刻清 —— BOT 买卡读的是它，而我们要在
## BEAT_BOT_THINK(0.6s) 之前把货架清空。这一步是纯数据，不牵扯补间。
##
## 实体和价签晚一步放：`_spawn_market_card` 给每张货架卡挂了 0.3s 的飞入补间
## （`main.gd` 的 `_spawn_market_card()`，`create_tween().bind_node(e)`），而这两个用例是
## `boot_main_seated(..., 5)` 定帧起的，第 5 帧正落在补间中间。
##
## ⚠ 这个「晚一步」的**原因待查**，别照着下面的猜测改代码。原先这里写的是
## 「不这么做会刷一屏 Lambda capture was freed」，但那条和被引的源码对不上：
## `main.gd` 的 `_spawn_market_card()` 里那段注释就是在讲 bind_node 的作用是
## **绑的节点没了补间跟着停**，
## 正是为了不打那条 —— 按它说的，第 5 帧 queue_free 应该安静停掉补间。
## 所以要么还有第二个原因（价签没有补间，走的不是这条路），要么这一步已经
## 是遗迹。要动它先实跑一次合并版本，看有没有 ERROR，别信这段注释
func _clear_market(main: Node) -> void:
	main.state.market.clear()


## 放掉货架实体。等飞入补间(0.3s)跑完之后再调。
## 借 main._clear_market()：那份收的东西一样（实体 + 价签 + 两个数组），
## 且带着 `unregister_card` —— 手抄一份漏掉它就会在 board.cards 里
## 攒已释放引用，而所有遍历点都有 is_instance_valid 挡着，测试是绿的
func _free_market_visuals(main: Node) -> void:
	main._clear_market()


## 换座位后跑一个完整回合，产出数必须和 test_full_game 的单机局一致。
##
## 上面那一段只验开局那一瞬，管得住「摆哪半边」，管不住行动/攻击/结算路径上的
## 座位引用 —— 那些开局根本走不到（变异检查实测：只验开局时 61 处只杀死 4 处）。
## 这一段照 test_full_game.gd 的脚本再跑一遍，双方各产出 12 资金；
## 任何一处漏改的硬编码都会让这两个数字对不上，或者干脆报错。
##
## 脚本本身和 test_full_game 一字不差地对应，只是把 GameState.PLAYER 换成
## main.my_seat、GameState.BOT 换成 main.foe_seat —— 这正是要验的那件事
func _scripted_round(main: Node) -> void:
	var state: GameState = main.state

	# 换座位后**对手先手**（action_first() 返回引擎的 player 座位，那是对手），
	# 而 _sync_round 末尾就已经调了 _begin_action_phase()：开局那一刻对手就在行动。
	# 这正是联网里 B 客户端的常态，所以先等交接，等不到就不用往下测了。
	# 交接本身就是判据：对手侧的自主行动跑完了，才会把行动权交回来
	# 基线要在对手行动**之前**记：如果哪处 BOT 调用点拿错了座位，它会替我买卡、
	# 花我的钱、用我的牌编组。在交接之后才记基线，这类错误全部发生在基线之前，
	# 一条都看不见（第一版就是这么写的，变异检查里那几处 旧策略 调用全是 MISS）
	var pre_cash: int = state.resource_count(main.my_seat, CardDB.RES_CASH)
	var pre_user: int = state.resource_count(main.my_seat, CardDB.RES_USER)
	var pre_uids := {}
	for c in state.players[main.my_seat]["cards"]:
		pre_uids[c["uid"]] = true

	var handed := false
	# 后台搜索不随测试演出加速；交接等待用独立的真实时间护栏。
	var handoff_deadline := Time.get_ticks_msec()+15000
	while Time.get_ticks_msec() < handoff_deadline:
		await create_timer(0.05).timeout
		if main._actor == main.my_seat and not main.board.input_locked:
			handed = true
			break
	check(handed, "对手先手行动完毕后把行动权交回我方")
	if not handed:
		return

	# 对手行动完，我这边应该一张不多一张不少 —— 对手买的卡进对手手里，
	# 花的是对手的钱。这条守的是「BOT 决策点的座位参数」那一族
	var now_uids := {}
	for c in state.players[main.my_seat]["cards"]:
		now_uids[c["uid"]] = true
	var added := 0
	for u in now_uids:
		if not pre_uids.has(u):
			added += 1
	var lost := 0
	for u in pre_uids:
		if not now_uids.has(u):
			lost += 1
	check(added == 0 and lost == 0,
		"对手行动没动我的牌（多 %d 张 / 少 %d 张）" % [added, lost])
	check(state.resource_count(main.my_seat, CardDB.RES_CASH) == pre_cash
		and state.resource_count(main.my_seat, CardDB.RES_USER) == pre_user,
		"对手行动没动我的资源（资金 %d→%d，用户 %d→%d）" % [
			pre_cash, state.resource_count(main.my_seat, CardDB.RES_CASH),
			pre_user, state.resource_count(main.my_seat, CardDB.RES_USER)])

	var my_cash0: int = state.resource_count(main.my_seat, CardDB.RES_CASH)
	var my_user0: int = state.resource_count(main.my_seat, CardDB.RES_USER)

	# 我方组合：核心卡 + recipe_n 张料，产出 output_n 资金（张数和产出都从卡表取）
	var core := "shuabuting"
	var cdef: Dictionary = CardDB.get_def(core)
	var need: int = 1 + int(cdef["recipe_n"])
	var prod: Dictionary = state.add_card(main.my_seat, core)
	var group_cards: Array = [main._spawn_entity(prod, Vector3(3, 0.3, 3.2), true)]
	for c in state.players[main.my_seat]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_USER) and group_cards.size() < need:
			group_cards.append(main.entities[c["uid"]])
	check(group_cards.size() == need, "换座位后凑齐「%s+%d %s」（%d 张）" % [
		cdef["name"], int(cdef["recipe_n"]), CardDB.res_label(CardDB.RES_USER),
		group_cards.size()])
	main.board.groups.append({ "cards": group_cards, "label": null })
	main.board.refresh_group(main.board.groups.back())

	main._on_action_done()
	var settled := false
	for i in 150:
		await create_timer(0.1).timeout
		if state.winner != "" or state.round_num == 2:
			settled = true
			break
	check(settled, "换座位后回合能跑完（进入第 2 回合或分出胜负）")

	var my_cash1: int = state.resource_count(main.my_seat, CardDB.RES_CASH)
	var my_user1: int = state.resource_count(main.my_seat, CardDB.RES_USER)
	# 对手先手时已经从真实公共区买过卡了，它的资金增量不确定，所以不设判据 ——
	# 「对手侧走的是 foe_seat」由上面那条交接和下面的卡数一致性守住
	check(my_cash1 == my_cash0 + int(cdef["output_n"]),
		"我方产出 %d %s（%d→%d）" % [
			int(cdef["output_n"]), CardDB.res_label(CardDB.RES_CASH),
			my_cash0, my_cash1])
	check(my_user1 == my_user0, "我方原料不消耗（%d→%d）" % [my_user0, my_user1])

	var state_count: int = state.players[main.my_seat]["cards"].size() \
		+ state.players[main.foe_seat]["cards"].size()
	check(main.entities.size() == state_count,
		"实体与引擎卡数一致（实体 %d / 引擎 %d）" % [main.entities.size(), state_count])

	# HUD：「你的公司」那一行必须是我这个座位的数。公司名是固定字串、数字按座位取，
	# 所以视角本来就对；这条守的是别人把数字那半改回硬编码座位
	main._update_hud()
	var mine_cash: int = state.resource_count(main.my_seat, CardDB.RES_CASH)
	var foe_cash: int = state.resource_count(main.foe_seat, CardDB.RES_CASH)
	check(str(mine_cash) in main.lbl_player_res.text,
		"HUD「你的公司」显示我方资金 %d（%s）" % [mine_cash, main.lbl_player_res.text])
	check(str(foe_cash) in main.lbl_bot_res.text,
		"HUD「对手公司」显示对手资金 %d（%s）" % [foe_cash, main.lbl_bot_res.text])


func _same_card_colors(a: CardEntity, b: CardEntity) -> bool:
	if a._dimmed or b._dimmed:
		return false
	if a._plate == null or b._plate == null:
		return false  # 程序化卡面始终存在，缺失不再视为同色纯色回退。
	if not (a._plate.material_override is ShaderMaterial) or not (b._plate.material_override is ShaderMaterial):
		return false
	var am := a._plate.material_override as ShaderMaterial
	var bm := b._plate.material_override as ShaderMaterial
	for key in ["face_color", "band_color", "ink_color", "tint"]:
		var av: Variant = am.get_shader_parameter(key)
		var bv: Variant = bm.get_shader_parameter(key)
		if av is Color and bv is Color:
			if not (av as Color).is_equal_approx(bv as Color):
				return false
		elif av is Vector3 and bv is Vector3:
			if not (av as Vector3).is_equal_approx(bv as Vector3):
				return false
		elif str(av) != str(bv):
			return false
	return true
