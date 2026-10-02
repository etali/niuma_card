# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 配方消耗演出 + HUD 拆分（scenes/main.gd 的 _resolve_combo_visual / _update_hud）。
##
## 这几条规格是**可见度**：规则一条没动，动的全是「玩家看不看得见」。
## 所以判据也全是「那句话在不在、写的是不是那个数」——
## 没有一条能靠末态哈希抓到（memory: green-mutation-means-no-observer 的反面：
## 这里的观察点就是屏幕上那行字，得有人去读它）
##
## 牌摞级提示（原先的「装机中」）已整层撤掉，本文件里对应的两节跟着删了 ——
## 对应的悬浮提示已移除；当前只检验配方消耗演出和资源读数。
##
## 变异提示（登记在 tools/mutate_check.py 末尾那一段）。
## 其中一条第一版是**等价变异**（改了代码没改行为，MISS 背后没有真缺陷）：
## `pending_pay` 的 valid 那一跳被「evaluate 只在 valid 分支里填 recipe_pay_n」兜住了。
## 那种 MISS 的修法是**换锚点**，不是收紧判据：
##   game_state.gd `pending_pay` 的待付改按卡面 `recipe_n` 取
##       → 「用户配方的摞待付 0」红（席位被当成每回合的成本）
##   game_state.gd `on_duty += mini(seats, have)` 改成 `+= have`
##       → 「富余不算」红（富余用户被记成在岗 = 警报算成健康）
##   main.gd 去掉待付括号 / 给在岗括号加 `if on_duty > 0`
##       → 「HUD 写出『本回合待付』」「没有任何在岗时照旧写括号」红
##   game_state.gd `recipe_pay_uids` 去掉「只取现金卡」那一判
##       → 「名单里全是这一组内的现金卡」红（屏幕上飞走一张核心卡）

const T1_USER := "shuabuting"     # 配方 用户×3（下面查）


func _initialize() -> void:
	print("=== 配方消耗 / HUD 测试 ===")
	_check_fixtures()
	await _t_consume_visual()
	await _t_consume_rhythm()
	await _t_sync_drop_is_immediate()
	await _t_hud_split()
	finish()


## 先验卡表里那张卡还是这个形状 —— 下面的 HUD 那一节建在它上面。
## 卡表是可调的（tools/tune_sweep.py 会改数值），配方数变了造局就造不出那个形状，
## 而那时报出来的是一条看不懂的断言失败
func _check_fixtures() -> void:
	var d: Dictionary = CardDB.get_def(T1_USER)
	check(str(d.get("recipe_res", "")) == CardDB.RES_USER
		and int(d.get("recipe_n", 0)) >= 2,
		"%s 是用户配方且需求 ≥2（现为 %s×%d）" % [
			str(d.get("name", T1_USER)), str(d.get("recipe_res", "")),
			int(d.get("recipe_n", 0))])


func _find_cash_core() -> String:
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") == CardDB.KIND_PRODUCT \
				and str(d.get("recipe_res", "")) == CardDB.RES_CASH \
				and int(d.get("recipe_n", 0)) > 0:
			return def_id
	return ""


## 同时在引擎和桌面上造一张卡，返回实体。
## 两边都要：提示的保护查询走 state.find_card，而位置判据读的是实体
func _spawn_both(main: Node, def_id: String, at: Vector3) -> CardEntity:
	var c: Dictionary = main.state.add_card(main.my_seat, def_id)
	return main._spawn_entity(c, at, true)


# ---------- 1. 配方消耗演出（scenes/main.gd 的 _resolve_combo_visual） ----------

## 结算吃掉的那几张现金要**先飞走再产出**。
##
## 判据是「消耗动画念的名单和引擎吃掉的是同一份」：两边各数一遍的话
## 动画吸走的和引擎删掉的会是不同的牌，而屏幕上看不出区别 ——
## 直到某一张被吸走的牌下一回合还在桌上
func _t_consume_visual() -> void:
	var main: Node = await boot_main()
	var cash_core := _find_cash_core()
	if cash_core == "":
		check(false, "卡表里找不到现金配方的核心卡，跳过消耗一节")
		main.queue_free()
		return
	var need := int(CardDB.get_def(cash_core).get("recipe_n", 0))

	# 直接在引擎里注册一个成立的现金配方组合
	var uids: Array = []
	var core: Dictionary = main.state.add_card(main.my_seat, cash_core)
	uids.append(core["uid"])
	for i in need:
		uids.append(main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))["uid"])
	var made: Dictionary = main.state.create_combo(main.my_seat, uids)
	check(bool(made.get("ok", false)), "注册成一个现金配方组合（%s）" % str(made.get("reason", "")))
	if not bool(made.get("ok", false)):
		main.queue_free()
		return
	var combo: Dictionary = main.state.combos[main.state.combos.size() - 1]

	var pay: Array = main.state.recipe_pay_uids(main.my_seat, combo)
	check(pay.size() == need,
		"要吃掉的名单是 %d 张（实为 %d）" % [need, pay.size()])
	# 名单里全是**现金卡**，而且都在这一组里 —— 吸走组外的牌是另一种 bug
	var all_cash_in_combo := true
	for u in pay:
		var c: Dictionary = main.state.find_card(main.my_seat, u)
		if c.is_empty() or CardDB.get_def(str(c["def_id"])).get("res", "") != CardDB.RES_CASH:
			all_cash_in_combo = false
		if not (combo["uids"] as Array).has(u):
			all_cash_in_combo = false
	check(all_cash_in_combo, "名单里全是这一组内的现金卡")

	# 引擎那边扣款念的是同一份名单：Settle._pay_recipe 走 recipe_pay_uids，
	# 所以「结算后这几张 uid 都不在了」是同一件事的另一面
	var before: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	var paid: Dictionary = Settle._pay_recipe(main.state, combo, combo["eval"])
	check(bool(paid.get("ok", false)),
		"付得起这一笔（%s）" % str(paid.get("reason", "")))
	var gone := 0
	for u in pay:
		if main.state.find_card(main.my_seat, u).is_empty():
			gone += 1
	check(gone == pay.size(),
		"结算吃掉的正是名单里那 %d 张（实为 %d）" % [pay.size(), gone])
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == before - need,
		"资金少了 %d（%d → %d）" % [
			need, before, main.state.resource_count(main.my_seat, CardDB.RES_CASH)])

	main.queue_free()
	await physics_frame


## 消耗的**节奏**要和攻击一个口径：逐张错开 + 等的时长正好等于演的时长。
##
## 判据落在 `_suck_batch_time` 这个纯函数上，不去掐秒表：墙钟计时在忙机器上
## 本来就飘，而「等的是不是一个固定常数」这件事看式子就够 ——
## 固定常数不随张数变，逐张错开的式子必须随张数变。
##
## 为什么这条值得单写一节：从前这里是「全部同时吸走 + 固定等 0.28s」，
## 逻辑上一点问题没有（该吃的牌照样吃），坏的只是**读得出来几张**
## 和每组白挂的那 0.1s 空场 —— 末态哈希、资源读数全都抓不到
func _t_consume_rhythm() -> void:
	var main: Node = await boot_main()
	var stagger: float = main.TEAR_STAGGER
	var suck: float = main.SUCK_TIME

	# 一张：没有错开可言，就是它自己吸完那点时间
	check(is_equal_approx(main._suck_batch_time(1), suck),
		"一张的时长 = SUCK_TIME %.2f（实为 %.2f）" % [suck, main._suck_batch_time(1)])
	# 空名单不等：付 0 的组（用户配方、升级组）走的就是这条
	check(is_equal_approx(main._suck_batch_time(0), 0.0),
		"空名单不等（实为 %.2f）" % main._suck_batch_time(0))
	# 三张：最后一张的起飞时刻 + 它自己吸完 —— 和攻击那边 dur 一个式子
	check(is_equal_approx(main._suck_batch_time(3), stagger * 2.0 + suck),
		"三张的时长 = 2×TEAR_STAGGER + SUCK_TIME %.2f（实为 %.2f）" % [
			stagger * 2.0 + suck, main._suck_batch_time(3)])
	# **随张数单调变长**：这一条才是「不是固定常数」的判据。
	# 改回固定等一个数的话，下面这个差会变成 0
	check(main._suck_batch_time(5) > main._suck_batch_time(2),
		"张数多了要等得久一点（5 张 %.2f > 2 张 %.2f）" % [
			main._suck_batch_time(5), main._suck_batch_time(2)])
	# 和攻击的式子**同构**：错开那一项的系数必须一样，否则两套演出
	# 看着就是两个快慢（用户读作「打人快、付钱慢」）
	var mine: float = main._suck_batch_time(4) - main._suck_batch_time(1)
	check(is_equal_approx(mine, stagger * 3.0),
		"错开的系数和攻击一致：4 张比 1 张多 3×TEAR_STAGGER %.2f（实为 %.2f）" % [
			stagger * 3.0, mine])

	main.queue_free()
	await physics_frame


## `_sync_entities` 兜底路径（升级吃配方卡、配方吃用户卡）：撕开的演出错开，
## 但**摘登记不能跟着错开**。
##
## 这是错开那一版最容易带出来的 bug：牌在错开的那几十毫秒里还留在
## `board.cards`，于是点得到、射线打得着、理牌还会把它排进摞 ——
## 而引擎里它已经不存在了。攻击那条路一直是「当场 drop_card、只延迟演出」，
## 这一条抄的是同一份写法
func _t_sync_drop_is_immediate() -> void:
	var main: Node = await boot_main()
	var board: Board = main.board

	# 造几张玩家的牌，拿到实体，然后**只从引擎里删掉**，
	# 让 _sync_entities 走它的兜底路径（不在 state 里的都要撕掉）
	var uids: Array = []
	for i in 4:
		uids.append(int(main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))["uid"]))
	main._sync_entities()
	await settle()

	var ents: Array = []
	for u in uids:
		if main.entities.has(u) and is_instance_valid(main.entities[u]):
			ents.append(main.entities[u])
	check(ents.size() == uids.size(),
		"先拿到这 %d 张的实体（实为 %d）" % [uids.size(), ents.size()])
	var registered := 0
	for e in ents:
		if board.cards.has(e):
			registered += 1
	check(registered == ents.size(),
		"删之前它们都在 board.cards（实为 %d/%d）" % [registered, ents.size()])

	# 从引擎里摘掉这几张，再同步一次
	var keep: Array = []
	for c in main.state.players[main.my_seat]["cards"]:
		if not uids.has(int(c["uid"])):
			keep.append(c)
	main.state.players[main.my_seat]["cards"] = keep
	main._sync_entities()

	# **不等**：就在同步返回的这一刻问。错开的是撕开的演出，摘登记是当场的
	var still := 0
	for e in ents:
		if is_instance_valid(e) and board.cards.has(e):
			still += 1
	check(still == 0,
		"同步一回来它们就不在 board.cards 了（还剩 %d 张）" % still)
	var in_entities := 0
	for u in uids:
		if main.entities.has(u):
			in_entities += 1
	check(in_entities == 0, "entities 里也一并摘了（还剩 %d 张）" % in_entities)
	# 撕开的演出还在跑，而且登记进了 _tear_until_ms —— 结算重画桌子前会等它
	# （见 _tears_drained：这条路没有调用方 await 它）
	check(main._tear_until_ms > Time.get_ticks_msec(),
		"这一批登记进了 _tear_until_ms（撕完之前别重画桌子）")

	# 等撕完再收场景：撕开是把卡拆成两片子节点、各自补间跑完才 queue_free。
	# 这里直接 queue_free(main) 的话那几片还没排到释放，退出时报 ObjectDB 泄漏
	await main._tears_drained()
	await settle()
	main.queue_free()
	await physics_frame


# ---------- 2. HUD 拆分（scenes/main.gd 的 HUD 与面板实现） ----------

func _t_hud_split() -> void:
	var main: Node = await boot_main()
	var board: Board = main.board
	var cash_core := _find_cash_core()
	var need_u := int(CardDB.get_def(T1_USER).get("recipe_n", 0))

	# --- 待付：一摞成立的现金配方 → HUD 括号里那个数 = 它的 recipe_n ---
	if cash_core != "":
		var need_c := int(CardDB.get_def(cash_core).get("recipe_n", 0))
		var members: Array = [_spawn_both(main, cash_core, Vector3(-3.0, 0.05, 2.6))]
		for i in need_c:
			members.append(_spawn_both(main, CardDB.unit_id(CardDB.RES_CASH),
				Vector3(-3.0 + 0.05 * i, 0.05, 3.1)))
		isolate(board, members)
		var g: Dictionary = board.make_group(members)
		board.groups.append(g)
		board._layout_group(g)
		await settle()

		var piles: Array = main._core_piles()
		check(main.state.pending_pay(main.my_seat, piles) == need_c,
			"待付 = %d（这一摞的现金配方；实为 %d）" % [
				need_c, main.state.pending_pay(main.my_seat, piles)])
		main._update_hud()
		check(main.lbl_player_res.text.contains("本回合待付 %d" % need_c),
			"HUD 写出「本回合待付 %d」（实为「%s」）" % [need_c, main.lbl_player_res.text])
		# 手上还富余的时候**不能**挂归零预警：这条警报的价值全在「该响时被看见」，
		# 常态挂着就没人读了
		check(not main.lbl_player_res.text.contains("付完归零"),
			"手上够付，不挂归零预警（实为「%s」）" % main.lbl_player_res.text)

		# --- 归零预警：把手上现金削到正好等于待付 ---
		# 这是报障的那个形状（春晚 10 现金配方 + 手上正好 10）：
		# 光写「待付 10」读起来像刚好付得起，而结算时 `Settle._pay_recipe`
		# 会拒付、整组作废。差的就是最后这 1 块
		# 排除的是**这一摞里的**现金卡，不是 `locked` —— 这里的摞只在 board 上，
		# 没走 create_combo，state 里一张都没锁；按 locked 筛会把摞自己的钱也删掉
		var in_pile: Array = []
		for c in g["cards"]:
			in_pile.append(int(c.uid))
		var spare: Array = []
		for c in main.state.players[main.my_seat]["cards"]:
			var cd: Dictionary = CardDB.get_def(c["def_id"])
			if cd.get("kind") == CardDB.KIND_UNIT and cd.get("res") == CardDB.RES_CASH \
					and not in_pile.has(int(c["uid"])):
				spare.append(int(c["uid"]))
		for u in spare:
			main.state.remove_card(main.my_seat, u)
		check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == need_c,
			"手上现金削到正好 %d（实为 %d）" % [
				need_c, main.state.resource_count(main.my_seat, CardDB.RES_CASH)])
		main._update_hud()
		check(main.lbl_player_res.text.contains("付完归零"),
			"手上正好等于待付 → HUD 挂归零预警（实为「%s」）" % main.lbl_player_res.text)

		# 摞**不成立**时待付要退回 0：不成立的组整组作废、一分钱不付（README.md §「2.6 组合与结算」），
		# 记进待付是在预告一笔不会发生的支出
		g["cards"].remove_at(g["cards"].size() - 1)
		board._layout_group(g)
		await settle()
		check(main.state.pending_pay(main.my_seat, main._core_piles()) == 0,
			"摞不成立 → 待付退回 0（整组作废不付钱）")
		main._update_hud()
		check(not main.lbl_player_res.text.contains("本回合待付"),
			"待付 0 不写括号（每回合挂个 0 是噪音；实为「%s」）" % main.lbl_player_res.text)
		board._remove_group(g)
		await physics_frame

	# --- 在岗 / 闲置 ---
	# 一摞成立的用户配方（席位 need_u）+ 富余 2 张用户卡在同一摞里。
	# 富余那 2 张**算闲置**：它们既不产出也拖不走，是闲置的最坏形态
	var u_members: Array = [_spawn_both(main, T1_USER, Vector3(-5.0, 0.05, 2.6))]
	for i in need_u + 2:
		u_members.append(_spawn_both(main, CardDB.unit_id(CardDB.RES_USER),
			Vector3(-5.0 + 0.05 * i, 0.05, 3.1)))
	isolate(board, u_members)
	var g2: Dictionary = board.make_group(u_members)
	board.groups.append(g2)
	board._layout_group(g2)
	await settle()

	# 用户配方的摞**一分钱不付**：席位是永久的，不是每回合的成本（README.md §「2.6 组合与结算」）。
	# 待付这个数只能取 eval 的 recipe_pay_n，不能拿核心卡的 recipe_n ——
	# 后者对用户配方也是 7，屏幕上就成了「本回合待付 7」而它压根不掏钱。
	# 上面那两条现金摞的判据抓不到这个：现金配方两个数恰好相等
	check(main.state.pending_pay(main.my_seat, main._core_piles()) == 0,
		"用户配方的摞待付 0（席位不是成本；实为 %d）"
			% main.state.pending_pay(main.my_seat, main._core_piles()))

	var total_u: int = main.state.resource_count(main.my_seat, CardDB.RES_USER)
	var dep: Dictionary = main.state.user_deployment(main.my_seat, main._core_piles())
	check(int(dep["on_duty"]) == need_u,
		"在岗 = 席位数 %d，富余不算（实为 %d）" % [need_u, int(dep["on_duty"])])
	check(int(dep["on_duty"]) + int(dep["idle"]) == total_u,
		"在岗 + 闲置 = 用户总量 %d（实为 %d + %d）" % [
			total_u, int(dep["on_duty"]), int(dep["idle"])])
	main._update_hud()
	check(main.lbl_player_res.text.contains(
			"（在岗 %d / 闲置 %d）" % [int(dep["on_duty"]), int(dep["idle"])]),
		"HUD 写出「在岗 %d / 闲置 %d」（实为「%s」）" % [
			int(dep["on_duty"]), int(dep["idle"]), main.lbl_player_res.text])

	# 闲置 0 也要写：那是这条读数唯一的好消息，藏掉就分不清
	# 「全部在岗」和「这个读数没算」
	board._remove_group(g2)
	for c in u_members:
		main.state.remove_card(main.my_seat, c.uid)
	await physics_frame
	main._update_hud()
	check(main.lbl_player_res.text.contains("在岗 0 / 闲置"),
		"没有任何在岗时照旧写括号（实为「%s」）" % main.lbl_player_res.text)

	main.queue_free()
	await physics_frame
