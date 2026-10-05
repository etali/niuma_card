# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 典当行测试：回收非现金卡 → 现金；现金卡拒收；购买付款为吸入动画


func _initialize() -> void:
	print("=== 典当行 测试 ===")
	var main: Node = await boot_main()

	var state: GameState = main.state
	var cash0: int = state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var user0: int = state.resource_count(GameState.PLAYER, CardDB.RES_USER)

	# --- 引擎层：典当两张用户卡 + 一张生产卡 ---
	# 回收价一律走 CardDB.pawn_value：这一节量的是「典当这条路通不通」，
	# 每张值几块是价目表的事（下面「典当价目」那一节专门量价目表本身）
	var n_user := 2                      # 典几张用户卡是判据自己的规模
	var prod_id := "pinshaoshao"
	var want_gain := CardDB.pawn_value("user") * n_user + CardDB.pawn_value(prod_id)
	var pawn_uids: Array = []
	var pawn_entities: Array = []
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "user" and pawn_uids.size() < n_user:
			pawn_uids.append(c["uid"])
			pawn_entities.append(main.entities[c["uid"]])
	var prod: Dictionary = state.add_card(GameState.PLAYER, prod_id)
	pawn_uids.append(prod["uid"])
	pawn_entities.append(main._spawn_entity(prod, Vector3(9, 0.3, 3.5), true))

	await main._on_dropped_on_pawn(pawn_entities)
	await create_timer(0.4).timeout
	for i in 10:
		await physics_frame

	check(state.resource_count(GameState.PLAYER, CardDB.RES_USER) == user0 - n_user,
		"典当后用户 -%d（%d→%d）" % [
			n_user, user0, state.resource_count(GameState.PLAYER, CardDB.RES_USER)])
	check(state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash0 + want_gain,
		"回收现金 +%d（用户 %d 张 + %s）" % [
			want_gain, n_user, CardDB.card_name(prod_id)])
	var freed := true
	for e in pawn_entities:
		if is_instance_valid(e):
			freed = false
	check(freed, "被典当的卡已吸入柜台消失")

	# --- 现金卡拒收 ---
	var cash_card: CardEntity = null
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "cash":
			cash_card = main.entities[c["uid"]]
			break
	var cash_before: int = state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	await main._on_dropped_on_pawn([cash_card])
	await create_timer(0.2).timeout
	check(state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before,
		"现金卡拒收，现金不变")
	check(is_instance_valid(cash_card), "被拒的现金卡退回，未销毁")

	# --- 典当价目：量的是**定价规则**，不是抄一遍价目表 ---
	# 四条规则各自能独立坏掉，所以分开量。期望值一律按规则从卡表现算：
	# 抄数字的话每轮调价都要回来改一遍，而红的原因和规则无关
	#
	# 折价率也从配置取（`_game.pawn_rate`），不写 2.0。**这换掉了这几条守的东西**：
	# 调折价率不再让这一节红（`_game.pawn_rate` 是配置项，调它是合法的），
	# 红的条件变成「代码没按配置那个率折」—— 比如有人把 / pawn_rate() 改回 / 2.0
	# 而配置里是 3.0。散文里那几句「÷2」由 tools/check_balance_numbers.py 盯，
	# 两边合起来才盖住「率改了」的全部后果
	var rate := CardDB.pawn_rate()
	check(CardDB.pawn_value("user") == CardDB.pawn_user(),
		"用户卡回收价 %d（`_game.pawn_user`，一张换这么些现金）" % CardDB.pawn_user())
	check(CardDB.pawn_value("cash") == 0, "现金卡不可典当")
	# T1：round(标价 / 折价率)，至少 1
	for id in ["pinshaoshao", "ditui"]:
		var price := int(CardDB.get_def(id)["price"])
		var want := maxi(1, roundi(price / rate))
		# 率用 %s 印，不用 %g：GDScript 的 % 运算符不认 %g，
		# 而右操作数是运行时数组、常量折叠不到，于是不报 Parse Error ——
		# 断言照旧在判，只有消息印成裸格式串（这一条实际撞过）
		check(CardDB.pawn_value(id) == want, "%s（标价%d）回收 %d = round(标价/%s)" % [
			CardDB.card_name(id), price, want, rate])
	# T2：升级改成「同名×upgrade_dup_n、不吃资源」之后，
	# 回收价 = round(下级卡购牌价 × dup_n / 折价率)
	for id in ["xinxijianfang", "baiyibutie", "banxiaoshi", "tuanzhang", "liulianghe", "jiaolv", "xufei"]:
		var d: Dictionary = CardDB.get_def(id)
		var from_id := str(d["upgrade_from"])
		var dup := maxi(2, int(d.get("upgrade_dup_n", 2)))
		var want := maxi(1, roundi(int(CardDB.get_def(from_id)["price"]) * dup / rate))
		check(CardDB.pawn_value(id) == want,
			"%s（T2，%s %d×%d÷%s）成本回收 %d" % [
				CardDB.card_name(id), CardDB.card_name(from_id),
				int(CardDB.get_def(from_id)["price"]), dup, rate, want])
	# 材料售价覆盖不能改变升级成本；先合计购价再折价、四舍五入。
	var saved_source: Dictionary = CardDB.CARDS["ditui"].duplicate(true)
	var saved_rate = CardDB.GAME["pawn_rate"]
	CardDB.CARDS["ditui"]["pawn"] = 99
	CardDB.GAME["pawn_rate"] = 4.0
	check(CardDB.pawn_value("ditui") == 99 and CardDB.pawn_value("tuanzhang") == 2,
		"材料固定售价不影响升级成本：两张购价3的地推扫码，6÷4四舍五入回收2")
	check(CardDB.pawn_value("dujiaoshou") == 30 and CardDB.pawn_value("guomin") == 70
		and CardDB.pawn_value("shangshi") == 100, "材料成本规则与折价率变化不影响传说固定价格")
	CardDB.CARDS["ditui"] = saved_source
	CardDB.GAME["pawn_rate"] = saved_rate
	# 传说卡不走上面两条公式，读卡表里写死的 `pawn` 字段 —— 那是平衡旋钮
	# （压过一轮，为的是掐掉「攒传说 → 一次换钱破百」这条捷径）。
	# 判据钉的是「有没有绕开公式」：值取自 pawn 字段，且确实不等于公式会给的数
	for id in ["dujiaoshou", "guomin", "shangshi"]:
		var d: Dictionary = CardDB.get_def(id)
		check(d.has("pawn"), "%s 在卡表里写死了 pawn（传说卡不走公式）" % CardDB.card_name(id))
		check(CardDB.pawn_value(id) == int(d["pawn"]),
			"%s 回收 %d，取的是卡表的 pawn 字段" % [CardDB.card_name(id), int(d["pawn"])])
		# 这个字段是承重的，不是给公式加的糖：传说卡没有标价（price ≤ 0），
		# upgrade_from 又指着 `dup_t2` 这种占位符而不是某张真卡，
		# 两条公式都走不通 —— 删掉 pawn 它就一分不值了
		check(int(d.get("price", -1)) <= 0, "%s 没有标价（买不到，只能升上来）" % CardDB.card_name(id))
		check(not CardDB.all_cards().has(str(d.get("upgrade_from", ""))),
			"%s 的 upgrade_from 不是某张真卡，递归公式走不通" % CardDB.card_name(id))

	# --- 自杀护栏：用户归零 = 当场判负，引擎层必须自己拦住 ---
	# 走纯引擎（不经场景层）：这条原先只有玩家拖拽那条路上有，
	# AI 侧靠 _ai 段的 keep_user_floor 挡着 —— 那是策略旋钮，配成 0 就能违反规则
	var s := GameState.new()
	s.new_game()
	var users: Array = []
	for c in s.players[GameState.PLAYER]["cards"]:
		var d: Dictionary = CardDB.get_def(c["def_id"])
		if d.get("kind") == CardDB.KIND_UNIT and d.get("res") == CardDB.RES_USER:
			users.append(c["uid"])
	check(users.size() >= 2, "开局用户卡够做这条判据（%d 张）" % users.size())
	# 当掉除最后一个以外的全部：合法
	var all_but_one: Array = users.slice(0, users.size() - 1)
	var r_ok: Dictionary = s.pawn(GameState.PLAYER, all_but_one)
	check(r_ok["ok"], "留 1 个用户的典当放行")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == 1, "只剩 1 个用户")
	# 再当掉最后一个：拦下，且状态一点没动
	var cash_hold: int = s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var r_no: Dictionary = s.pawn(GameState.PLAYER, [users[users.size() - 1]])
	check(not r_no["ok"], "当掉最后一个用户被引擎拦下")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == 1, "被拦后用户还在（没先当掉再报错）")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_hold, "被拦后没有回收到现金")
	check(s.winner == "", "被拦后没有判负")
	# 判定函数本身：纯判定，问过不改状态
	check(s.pawn_would_zero_user(GameState.PLAYER, [users[users.size() - 1]]),
		"pawn_would_zero_user 认出这一笔会归零")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == 1, "问判定没有动状态")

	finish()
