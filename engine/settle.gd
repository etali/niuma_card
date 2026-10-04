# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Settle
extends RefCounted

## 结算流水线（对应设计文档 4.3 / 4.4）
## 攻击阶段：先手先攻，点数池 + 点选目标（互动模式由场景层逐次驱动，无头/AI 走自动选靶）
## 结算阶段：只结算产出/升级组合，先手方先结算；被拆散的组合整组作废

## target_picker: Callable(state, attacker, targets, pools) -> Dictionary（{} = 停止）
## 不传则使用 AIPlan.target_picker（无头模拟器双方同款策略）
## 每次点选后立即判定胜负：对方现金/用户被清零 → 攻击阶段当场结束（清零即胜）
static func attack_phase(state: GameState, who: String, target_picker: Callable = Callable(),
		observe: Callable = Callable()) -> void:
	# arm_attacks 而不是 attack_pool：这一句就是「装弹」，配方现金在这里被吃掉
	var pools: Dictionary = state.arm_attacks(who)
	if int(pools[CardDB.RES_CASH]) <= 0 and int(pools[CardDB.RES_USER]) <= 0:
		return
	state.log_fmt("—— %s 的攻击阶段：%s攻击×%d %s攻击×%d ——", [
		GameState.seat_arg(who),
		CardDB.card_label(CardDB.RES_CASH), pools[CardDB.RES_CASH],
		CardDB.card_label(CardDB.RES_USER), pools[CardDB.RES_USER]])
	spend_pool(state, who, pools, target_picker, observe)

## 把一个**已经装好弹**的点数池打完。
##
## 从 `attack_phase` 里分出来是给选靶搜索用的（`AITurnPlan.target_picker`）：
## 试算要在快照上「点这一张，剩下的按基线点完」，而它不能再调 `attack_phase` ——
## 那会 `arm_attacks` 第二遍，把配方现金再吃一次、点数池凭空翻倍。
## 装弹和花点是两件事，这个签名就是那条缝
static func spend_pool(state: GameState, who: String, pools: Dictionary,
		target_picker: Callable = Callable(), observe: Callable = Callable()) -> void:
	if target_picker.is_null():
		target_picker = AIPlan.target_picker()
	var victim := GameState.opponent(who)
	while state.winner == "" and (int(pools[CardDB.RES_CASH]) > 0 or int(pools[CardDB.RES_USER]) > 0):
		var affordable: Array = state.affordable_targets(victim, pools)
		if affordable.is_empty():
			state.log_fmt("%s 剩余点数（%s）点不起任何目标，余点作废", [
				GameState.seat_arg(who), GameState.pool_text(pools)])
			break
		var target: Dictionary = target_picker.call(state, who, affordable, pools)
		if target.is_empty():
			break
		if observe.is_valid():
			observe.call("before_attack", state, {"owner": who, "target": target})
		var r: Dictionary = state.apply_attack(who, target, pools)
		if not r["ok"]:
			state.log_msg("⚔ 点选失败：%s" % r["reason"])
			break
		if observe.is_valid():
			observe.call("attack", state, {"owner": who, "target": target, "result": r})
		state.check_victory()   # 清零即胜：现金/用户被打到 0，攻击当场结束

## 结算阶段：先手方的产出/升级组合先结算，后手方后结算（攻击组合已在攻击阶段生效）
static func produce(state: GameState, observe: Callable = Callable()) -> void:
	for combo in ordered_production_combos(state):
		var result := _resolve_combo(state, combo)
		if observe.is_valid():
			observe.call("production", state, {"combo": combo, "result": result})

## 一次性跑完：先手攻击 → 后手攻击 → 产出结算 → 收尾（无头模拟器用）
## 清零即胜：任一攻击阶段把对方打到 0，后续阶段直接跳过
##
## cfgs：`{座位: AISearch}`，与 MatchSimulator.run_rounds 使用同一参数。
## 缺少座位配置时由 AIPlan 选择默认配置；双方各用自己的共享选靶入口。
static func run(state: GameState, cfgs: Dictionary = {}, observe: Callable = Callable()) -> void:
	var order := state.action_order()
	attack_phase(state, order[0], AIPlan.target_picker(cfgs.get(order[0])), observe)
	if state.winner == "":
		attack_phase(state, order[1], AIPlan.target_picker(cfgs.get(order[1])), observe)
	if state.winner == "":
		produce(state, observe)
	finalize(state)

## 按结算顺序返回产出/升级组合（先手方先结算）
##
## 每个座位内部再分两拨：**不吃现金的先结，吃现金的后结**。
## 因为 `_pay_recipe` 的归零护栏念的是「此刻手上的全部现金」，而进账的组合
## 也在同一次 produce 里。按编组次序结的话，同样两摞牌只因为玩家先摞了哪一摞，
## 一摞会活一摞会废 —— 收益在后面排着队，付款的那摞却先撞上护栏作废了。
##
## 排序键只用建组时就冻住的 `recipe_pay_n` 和 `order`，不看当前现金：
## `IntentApply._produce` 每结一组都重算一次这张表，键要是随现金变，
## 结到一半下标就会错位到别的组上
static func ordered_production_combos(state: GameState) -> Array:
	var out: Array = []
	for owner in state.action_order():
		for pays_cash in [false, true]:
			for combo in state.combos:
				if combo["owner"] != owner or combo["eval"].get("type") == "attack":
					continue
				if (int(combo["eval"].get("recipe_pay_n", 0)) > 0) == pays_cash:
					out.append(combo)
	return out

## 收尾：解锁、清空组合、胜负检查（防御 Buff 不折旧：在组合中即永久生效）
static func finalize(state: GameState) -> void:
	for who in [GameState.PLAYER, GameState.AI]:
		for c in state.players[who]["cards"]:
			c["locked"] = false
	state.combos.clear()
	state.check_victory()

## 单个产出/升级组合的结算（齐整检查 → 效果）；场景演出也调这个
static func _resolve_combo(state: GameState, combo: Dictionary) -> Dictionary:
	var owner: String = combo["owner"]
	var eval: Dictionary = combo["eval"]
	var leader_name := CardDB.card_name(eval["leader"])

	# 第 1 步：齐整检查
	if not state.combo_intact(owner, combo):
		state.log_fmt("✂ %s 的组合「%s」已被拆散，整组作废！", [GameState.seat_arg(owner), leader_name])
		return { "resolved": false, "reason": "已被拆散", "paid_uids": [] }

	# 第 2 步：入组即保护，只报告配方齐整且仍有对应防御 Buff 的组合。
	if not state.protected_uids(owner, combo, CardDB.RES_USER).is_empty() \
			or not state.protected_uids(owner, combo, CardDB.RES_CASH).is_empty():
		state.log_fmt("🛡 %s 的组合「%s」受防御 Buff 保护", [GameState.seat_arg(owner), leader_name])

	# 第 3 步：付配方现金（README.md §「2.6 组合与结算」 —— 在自己结算的这一刻付，不是回合开始）。
	# 付不起或付完归零 → 整组作废，走的是和齐整检查失败同一条表现路径。
	# 用户配方不走这里：配方里的用户是永久席位，不是成本
	# 成功后这些 UID 已从状态移除，先保留只读名单供本地与联网共用付款演出。
	var paid_uids := state.recipe_pay_uids(owner, combo)
	var paid := _pay_recipe(state, combo, eval)
	if not paid["ok"]:
		state.log_fmt("✂ %s 的组合「%s」%s，整组作废！", [
			GameState.seat_arg(owner), leader_name, paid["reason"]])
		return { "resolved": false, "reason": paid["reason"], "paid_uids": [] }

	# 付款成功后记录 Buff 的实际生效回合；该标记不构成 AI 的禁售条件。
	state.mark_buff_worked(owner, combo)

	# 第 4 步：组合效果
	match eval["type"]:
		"production":
			for i in eval["output_n"]:
				state.add_card(owner, CardDB.unit_id(eval["output_res"]), true)
			state.log_fmt("⚙ %s「%s」%s%s+%d", [
				GameState.seat_arg(owner), leader_name,
				paid["net_prefix"],
				CardDB.res_label(eval["output_res"]),
				eval["output_n"],
			])
		"upgrade":
			_consume_upgrade_materials(state, combo, eval)
			state.add_card(owner, eval["output_card"], true)
			state.log_fmt("⬆ %s 升级成功，获得「%s」！", [
				GameState.seat_arg(owner), CardDB.card_name(eval["output_card"]),
			])
	return { "resolved": true, "reason": "", "paid_uids": paid_uids }

## 扣掉这一组的配方现金。返回 {ok, reason, net_prefix}
##
## `net_prefix` 是给战报用的净额前缀（「−现金3 → 」），付 0 时为空串。
## 战报写成净额是因为 `_resolve_combo_visual` 直接显示结算战报的最后一条，
## 净额写在这里，场景层不用改
##
## 两条拦法，对应 README.md §「1.1 资源与决策」：
##   - 桌面上的现金凑不够这一组的配方 → 整组作废
##   - 付完自己资金归零 → 整组作废（归零是败北条件，不能让玩家自己走进去，
##     和 buy() 的 zero_out、pawn_would_zero_user 是同一条原则）
static func _pay_recipe(state: GameState, combo: Dictionary, eval: Dictionary) -> Dictionary:
	var owner: String = combo["owner"]
	var need := int(eval.get("recipe_pay_n", 0))
	if need <= 0:
		return { "ok": true, "reason": "", "net_prefix": "" }

	var payment := state.recipe_payment_check(owner, combo)
	if not payment["ok"]:
		payment["net_prefix"] = ""
		return payment
	var pay: Array = payment["paid_uids"]

	for u in pay:
		state.remove_card(owner, u)
	return { "ok": true, "reason": "",
		"net_prefix": "−%s%d → " % [CardDB.res_label(CardDB.RES_CASH), need] }

## 升级消耗：吃掉全部参与材料；同档生产卡升传说时可以异名
## 升级是纯卡面合成，不吃现金也不吃用户，所以这里没有单位卡要清
static func _consume_upgrade_materials(state: GameState, combo: Dictionary, _eval: Dictionary) -> void:
	var owner: String = combo["owner"]
	for u in combo["uids"]:
		var c := state.find_card(owner, u)
		if c.is_empty():
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_LEGEND]:
			state.remove_card(owner, u)

## 玩家点击完成行动前在副本上预演自己的消耗与产出。
## 不假设对手未来攻击会替玩家拆掉危险组合，不发送意图、不锁真实卡，也不写录像。
static func check_action_completion(state: GameState, who: String, piles: Array) -> Dictionary:
	var preview := GameState.new()
	StateCodec.restore(preview, StateCodec.snapshot(state))
	preview.combos.clear()
	for pile in piles:
		preview.create_combo(who, pile.get("uids", []))
	# 攻击弹药在所有生产之前支付，不能用尚未发生的生产收入填补。
	for combo in preview.combos:
		if combo["eval"].get("type") != "attack" or not preview.combo_intact(who, combo):
			continue
		var checked := _check_action_payment(preview, who, combo)
		if not checked["ok"]:
			return checked
		preview._attack_recipe_payable(who, combo, true)
	# 直接复用实际生产顺序及结算实现，包含BUFF倍率、升级和前一组产出。
	for combo in ordered_production_combos(preview):
		if not preview.combo_intact(who, combo):
			continue
		var checked := _check_action_payment(preview, who, combo)
		if not checked["ok"]:
			return checked
		_resolve_combo(preview, combo)
	return {"ok": true}

static func _check_action_payment(state: GameState, who: String, combo: Dictionary) -> Dictionary:
	var payment := state.recipe_payment_check(who, combo)
	if payment.get("code", "") != "resource_zero":
		return {"ok": true}
	return {"ok": false, "code": "resource_zero", "resource": payment["resource"],
		"uids": combo["uids"].duplicate(), "leader": combo["eval"]["leader"],
		"reason": "「%s」消耗后%s会归零，请拆开或调整组合" % [
			CardDB.card_name(combo["eval"]["leader"]), CardDB.res_label(payment["resource"])]}
