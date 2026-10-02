# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## M3 经济循环：买卡扣钱、公共区补货、回合推进、悬停说明念的词


func _initialize() -> void:
	print("=== M3 经济循环测试 ===")
	var main: Node = await boot_main()

	var state: GameState = main.state
	check(state != null, "引擎状态已装配")
	check(main.market_cards.size() == CardDB.game_rules()["market_size"],
		"公共区 %d 张实体卡就位" % CardDB.game_rules()["market_size"])

	var p_cash := state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var p_user := state.resource_count(GameState.PLAYER, CardDB.RES_USER)
	print("       玩家初始：资金 %d 用户 %d" % [p_cash, p_user])
	# 数从配置读，不写死：被测的是「开局到账、之后没有回合配给」，不是那两个数字
	# （曾经把两个数直接写在断言里，rebalance 一调 start_cash 就一直是红的）
	var rules: Dictionary = CardDB.game_rules()
	check(p_cash == int(rules["start_cash"]) and p_user == int(rules["start_user"]),
		"初始资源到账（资金%d 用户%d，无回合配给）" % [
			int(rules["start_cash"]), int(rules["start_user"])])

	var def_id: String = state.market[0]
	var price: int = CardDB.get_def(def_id).get("price", 0)
	var market_before: int = state.market.size()
	var r: Dictionary = await main._try_buy(0)
	check(r["ok"], "购买「%s」成功（标价%d）" % [CardDB.card_name(def_id), price])
	check(state.market.size() == market_before - 1, "公共区减少一张")
	check(state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == p_cash - price,
		"支付现金 %d → %d" % [p_cash, p_cash - price])
	check(main.market_cards.size() == CardDB.game_rules()["market_size"] - 1, "公共区实体同步减少")
	check(main.entities.has(r.get("new_uid", -1)), "购入卡实体已映射")

	# 走一遍 AI 采购再推回合，为的是让下面几条判据落在「两边都动过」的局面上。
	# 买没买成不判：AI 手上钱不够就该什么都不买，两种结果都合法。
	# 直接驱动 AIAgent 的买卡段（原先调的 main._ai_buy_once 已经不在仓里了，
	# 决策次序整段搬去了 engine/ai_agent.gd）：next_step 一步一步走，
	# 走到 STEP_BUY_DONE 就是「不买了」
	var buy_agent := AIAgent.new(main.pipe, main.foe_seat, AISearch.from_strength(0.0))
	while true:
		var st := buy_agent.next_step()
		# STEP_DONE 也要出来：典当冲线定了 winner 的话根本走不到买卡那步，
		# 只等 STEP_BUY_DONE 就死循环了
		if st == AIAgent.STEP_BUY_DONE or st == AIAgent.STEP_DONE:
			break

	var round_before: int = state.round_num
	await main._next_round()
	for i in 10:
		await physics_frame
	check(state.round_num == round_before + 1, "回合数 +1")
	check(state.market.size() == CardDB.game_rules()["market_size"],
		"新公共区 %d 张" % CardDB.game_rules()["market_size"])
	check(main.market_cards.size() == CardDB.game_rules()["market_size"], "新公共区实体就位")
	check(str(round_before + 1) in main.lbl_round.text, "HUD 更新：%s" % main.lbl_round.text)

	# 换货架要把旧卡从 board.cards 里注销掉。漏注销**不崩也不报错** ——
	# 所有遍历点都拿 is_instance_valid 挡着，于是症状是那个数组无界增长：
	# 原先 _next_round 自己抄了一份清理、独独漏了 unregister_card，
	# 实测每回合攒下整整一货架（`_game.market_size` 张）的死引用，几个回合就翻一倍。
	# 判据取「一条都没有」而不是某个长度：长度会随开局配置变，而死引用应当恒为 0
	var dead := 0
	for c in main.board.cards:
		if not is_instance_valid(c):
			dead += 1
	check(dead == 0, "换货架后 board.cards 里没有已释放引用（%d 条）" % dead)

	# 悬停说明只留效果一句：卡名在标题带上、标价在牌外价签上、进度在 D 位墨团上，
	# 提示框再抄一遍就是让玩家读三处相同信息
	var d_shua: Dictionary = CardDB.get_def("shuabuting")
	var hint: String = main.board.hover_desc_text("shuabuting")
	print("       刷不停说明：%s" % hint)
	check("用户" in hint and "资金" in hint, "说明含配方资源与产出资源")
	check(not "标价" in hint, "说明不含标价（已在牌外价签）")
	var progress := "0/%d" % int(d_shua["recipe_n"])
	check(not "配方进度" in hint and not progress in hint,
		"说明不含配方进度（%s 已在 D 位墨团）" % progress)
	check(not CardDB.card_name("shuabuting") in hint, "说明不含卡名（已在标题带）")

	# 计量名 vs 卡名（CardDB.card_label / CardDB.res_label：「现金 = 1 份资金」）：
	# 配方里躺的是现金卡 → 配方段说「现金×N」；每回合产出涨的是资金总量 →
	# 产出段说「资金+N」。悬停一律用计量名的话，同一个配方在悬停里叫「资金×N」、
	# 在「配方不足」的报错里叫「现金×N」，玩家得自己猜是同一回事
	var shua_out := "%s+%d" % [CardDB.res_label(str(d_shua["output_res"])), int(d_shua["output_n"])]
	check(shua_out in hint, "每回合产出段用计量名（%s）" % shua_out)
	# 必须挑一张配方是现金的生产卡：刷不停的配方是用户，
	# 而用户的计量名和卡名同字（都叫「用户」），拿它量不出两者换着用的差别
	# 数量从 CardDB 取，不硬写：这几条量的是「配方段说卡名、产出段说计量名」这条规范，
	# 数值是谁不影响规范成不成立。硬写的话每轮调数值都要来改一遍，
	# 而红的原因和规范无关，久了就会被当成噪音顺手改掉
	var d_prod: Dictionary = CardDB.get_def("waimai")
	var hint_prod: String = main.board.hover_desc_text("waimai")
	print("       外卖补贴说明：%s" % hint_prod.replace("\n", " / "))
	var want_recipe := "现金×%d" % int(d_prod["recipe_n"])
	check(want_recipe in hint_prod, "生产卡配方段用卡名（外卖补贴：%s）" % want_recipe)
	var want_out := "用户+%d" % int(d_prod["output_n"])
	check(want_out in hint_prod, "生产卡产出段用计量名（%s）" % want_out)
	var d_atk: Dictionary = CardDB.get_def("butie")
	var hint_cash: String = main.board.hover_desc_text("butie")
	print("       补贴大战说明：%s" % hint_cash.replace("\n", " / "))
	var want_pay := "现金×%d" % int(d_atk["recipe_n"])
	check(want_pay in hint_cash, "补贴大战配方段：%s（卡名，跟配方不足的报错一致）" % want_pay)
	# 攻击段：卡名 + ×N。补贴大战本轮从打现金改成打用户，所以币种也从卡表取
	var want_atk := "移除对方%s×%d" % [CardDB.card_name(d_atk["attack_res"]), int(d_atk["attack_n"])]
	check(want_atk in hint_cash, "攻击段用卡名：移除的是牌不是计量（%s）" % want_atk)
	check(not "资金" in hint_cash, "补贴大战全是按卡算的，不出现计量名")
	# 报错和悬停必须念同一个词
	var miss: String = ComboRules.evaluate([{ "uid": 0, "def_id": "butie" }]).get("reason", "")
	print("       配方不足报错：%s" % miss)
	check(want_pay in miss, "配方不足的报错也说「%s」，与悬停同词" % want_pay)
	var buff_hint: String = main.board.hover_desc_text("tuisong")
	check("用户" in buff_hint, "buff 卡说明含效果描述")
	check(main.board.hover_desc_text("user") != "", "单位卡也有说明（配方材料）")

	finish()
