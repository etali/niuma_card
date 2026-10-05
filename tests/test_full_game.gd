# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## M4 整场对局冒烟测试：玩家行动 → BOT 行动 → 攻击阶段 → 结算演出 → 回合推进
## 清空公共区保证确定性（双方都不买卡、均无攻击卡）


func _initialize() -> void:
	print("=== M4 整场对局测试 ===")
	# 本测试验证编组→结算→推进的账目。固定即时策略，避免未来随机市场的
	# 前推评价改变本回合是否生产；高强度策略的可执行性由BOT专门测试覆盖。
	BOTSearch.set_pref_strength(0.0)
	BOTSearch.set_override("sales", 0)
	var main: Node = await boot_main()

	var state: GameState = main.state
	check(state != null, "引擎状态已装配")

	var cash0: int = state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var user0: int = state.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var bot_cash0: int = state.resource_count(GameState.BOT, CardDB.RES_CASH)

	# --- 清空公共区：BOT 无卡可买，保证确定性 ---
	# 借 main 自己那份收货架（_clear_market），不在这儿手抄一遍：抄的那份漏了
	# `board.unregister_card`，于是每张货架卡都在 board.cards 里留下一条已释放引用。
	# 遍历点都有 is_instance_valid 挡着，所以测试照样绿 —— 症状只在数组长度上
	# （同一个漏法在 _next_round 里真出过事，判据见 test_market.gd）
	state.market.clear()
	main._clear_market()

	# --- 注入玩家组合：一张核心卡 + 一份配方的用户（产出记在卡表里） ---
	# 配方量和产出都读卡表：这一节冒烟走的是「组合→结算→推回合」整条链，
	# 数值是谁不影响链通不通
	var core_id := "shuabuting"
	var core_def: Dictionary = CardDB.get_def(core_id)
	var seats := int(core_def["recipe_n"])
	var out_n := int(core_def["output_n"])
	var group_want := seats + 1          # 核心 1 张 + 一份配方
	var prod: Dictionary = state.add_card(GameState.PLAYER, core_id)
	var e_prod: CardEntity = main._spawn_entity(prod, Vector3(3, 0.3, 3.2), true)
	var group_cards: Array = [e_prod]
	for c in state.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == "user" and group_cards.size() < group_want:
			group_cards.append(main.entities[c["uid"]])
	check(group_cards.size() == group_want, "凑齐「%s + %s×%d」（实际 %d 张）" % [
		core_def["name"], CardDB.card_name("user"), seats, group_cards.size()])
	main.board.groups.append({ "cards": group_cards, "label": null })
	main.board.refresh_group(main.board.groups.back())

	# --- 给 BOT 一张同款核心卡，验证 BOT 组卡决策（BOT 开局的用户够凑一份配方） ---
	check(int(CardDB.game_rules()["start_user"]) >= seats,
		"牌桌前提：开局用户数够 BOT 自己凑出一份 %s 的配方（要 %d 张）" % [
			core_def["name"], seats])
	state.add_card(GameState.BOT, core_id)

	# --- 玩家完成行动：注册组合 → BOT 行动 → 整理 → 攻击 → 结算 ---
	var round0: int = state.round_num
	# 新策略可以典当闲置资产；“无配给”应排除有明确意图的交易收入。
	var pawn_income := [0]
	var purchased := [0]
	main.pipe.applier().landed.connect(func(result: Dictionary):
		if result.get("seat", "") != GameState.BOT:
			return
		if result.get("op", "") == Intent.OP_PAWN:
			pawn_income[0] += int(result.get("total", 0))
		if result.get("op", "") == Intent.OP_BUY:
			purchased[0] += 1)
	main._on_action_done()

	# --- 等结算跑完：回合推进或分出胜负 ---
	# BOT 搜索在工作线程消耗真实时间，不能让 TEST_SPEED 同时缩短等待预算。
	# 上限保持 15 秒墙钟；按真实状态提前退出，避免并行测试时仍在搜索就读产出。
	var settled := false
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if state.winner != "" or state.round_num == round0 + 1:
			settled = true
			break
		await create_timer(0.1, true, false, true).timeout
	check(settled, "结算完成并进入第 %d 回合（或分出胜负）" % (round0 + 1))
	check(state.combos.is_empty(), "结算后组合队列已清空")

	var cash1: int = state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var user1: int = state.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var bot_cash1: int = state.resource_count(GameState.BOT, CardDB.RES_CASH)
	print("       玩家：%d资金/%d用户 → %d资金/%d用户" % [cash0, user0, cash1, user1])
	print("       对手：%d资金 → %d资金" % [bot_cash0, bot_cash1])

	check(cash1 == cash0 + out_n, "玩家：%s 产出 %d，无回合配给（%d→%d）" % [
		core_def["name"], out_n, cash0, cash1])
	check(user1 == user0, "玩家：原料不消耗，无配给（%d→%d）" % [user0, user1])
	check(purchased[0] == 0, "空市场没有购买意图")
	check(bot_cash1 == bot_cash0 + out_n + int(pawn_income[0]),
		"对手资金增量等于规则产出%d加实际典当%d，无额外配给（%d→%d）" % [
			out_n, int(pawn_income[0]), bot_cash0, bot_cash1])

	# --- 实体与引擎状态一致 ---
	var state_count: int = state.players[GameState.PLAYER]["cards"].size() \
		+ state.players[GameState.BOT]["cards"].size()
	check(main.entities.size() == state_count,
		"实体与引擎卡数一致（实体 %d / 引擎 %d）" % [main.entities.size(), state_count])
	check(main.phase == "action", "已回到行动阶段，等待玩家操作")

	finish()
