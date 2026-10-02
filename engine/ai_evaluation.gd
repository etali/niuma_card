# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIEvaluator
extends RefCounted

const Context = preload("res://engine/ai_context.gd")

## 所有经济量来自当前规则。固定系数只表示估计时域、风险等算法偏好。
const TERMINAL_SCORE := 1000000.0

## 传入 opponent_features 时，调用方须保证规则、参数及对方手牌都未变。
## 该复用只省去对方特征计算，不能替代每次评分前的胜负检查。
static func score(state: GameState, who: String, parameters: Dictionary = {}, opponent_features: Dictionary = {}) -> float:
	var p := _parameters(parameters)
	if state.winner != "":
		return TERMINAL_SCORE if state.winner == who else -TERMINAL_SCORE
	var context := _context(p)
	var a := _features(state, who, p, context)
	var b := opponent_features if not opponent_features.is_empty() else _features(state, GameState.opponent(who), p, context)
	var scale := maxf(1.0, float(CardDB.game_rules()["win_cash"]))
	return clampf((float(a["total"]) - float(b["total"])) / scale, -100.0, 100.0)

static func features(state: GameState, who: String, parameters: Dictionary = {}) -> Dictionary:
	var p := _parameters(parameters)
	return _features(state, who, p, _context(p))

static func _features(state: GameState, who: String, p: Dictionary, context: Context) -> Dictionary:
	var summary := _summary(state, who)
	var cash := int(summary["cash"])
	var users := int(summary["users"])
	var inventory: Dictionary = summary["inventory"]
	var assets := float(cash + maxi(0, users - 1) * CardDB.pawn_user())
	# 保留逐牌相加及原顺序，不能改成同名数量乘单价，避免浮点结合顺序变化。
	for id in summary["nonunits"]:
		assets += context.pawn_value(str(id))
	var engine := _capacity(summary, p)
	# 引擎是未来净现金流，不重复加核心购价。升级只加超过当前典当底价的增量。
	var upgrade := context.inventory_upgrade_value(inventory)
	# 平滑资源安全项：只惩罚接近清零，不用旧固定现金/用户保留线。
	var unit_value := float(summary["user_price"])
	var risk := unit_value / maxf(float(users), 1.0)
	var total := assets + float(p["engine_horizon"]) * engine + float(p["upgrade_weight"]) * upgrade - float(p["risk_weight"]) * risk
	return {"asset": assets, "engine": engine, "option": upgrade, "risk": risk,
		"cash": cash, "users": users, "total": total}

## 用户的影子价格来自手中用户驻场引擎的单位收益；无用用户只有典当底价。
static func user_price(state: GameState, who: String) -> float:
	var price := float(CardDB.pawn_user())
	for c in state.players[who]["cards"]:
		var d := CardDB.get_def(str(c["def_id"]))
		if d.get("recipe_res", "") != CardDB.RES_USER:
			continue
		var need := maxi(1, int(d.get("recipe_n", 0)))
		var income := float(d.get("output_n", 0)) if d.get("output_res", "") == CardDB.RES_CASH else 0.0
		if d.get("kind") == CardDB.KIND_ATTACK:
			income = floorf(float(d.get("attack_n", 0)) / maxf(1, CardDB.game_rules()["attack_cost_per_card"]))
		price = maxf(price, income / need)
	return price

## 结算后也从保有卡牌估计下一回合能力。共享资源按容量分配，不逐张重复计值。
static func capacity(state: GameState, who: String, parameters: Dictionary = {}) -> float:
	var p := _parameters(parameters)
	return _capacity(_summary(state, who), p)

## 每次调用独立收集；资源数、资产顺序、核心次序和材料首次出现次序保持不变。
static func _summary(state: GameState, who: String) -> Dictionary:
	var users := 0
	var cash := 0
	var inventory := {}
	var nonunits: Array = []
	var cores: Array = []
	var mults := {"output_x2": 0, "attack_x2": 0, "user_fill": 0}
	var demand := 0
	var shadow := float(CardDB.pawn_user())
	for c in state.players[who]["cards"]:
		var id := str(c["def_id"])
		var d := CardDB.get_def(id)
		if d.get("kind") == CardDB.KIND_UNIT:
			if d.get("res") == CardDB.RES_CASH:
				cash += 1
			elif d.get("res") == CardDB.RES_USER:
				users += 1
		else:
			nonunits.append(id)
			inventory[id] = int(inventory.get(id, 0)) + 1
		var bt := str(d.get("buff_type", ""))
		if mults.has(bt):
			mults[bt] += 1
		if d.get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]:
			cores.append(d)
			if d.get("recipe_res", "") == CardDB.RES_USER:
				demand += int(d.get("recipe_n", 0))
		if d.get("recipe_res", "") == CardDB.RES_USER:
			var need := maxi(1, int(d.get("recipe_n", 0)))
			var income := float(d.get("output_n", 0)) if d.get("output_res", "") == CardDB.RES_CASH else 0.0
			if d.get("kind") == CardDB.KIND_ATTACK:
				income = floorf(float(d.get("attack_n", 0)) / maxf(1, CardDB.game_rules()["attack_cost_per_card"]))
			shadow = maxf(shadow, income / need)
	return {"cash":cash,"users":users,"inventory":inventory,"nonunits":nonunits,
		"cores":cores,"mults":mults,"demand":demand,"user_price":shadow}

static func _capacity(summary: Dictionary, p: Dictionary) -> float:
	var users := int(summary["users"])
	var cash := maxi(0, int(summary["cash"]) - 1)
	var cores: Array = summary["cores"]
	var mults: Dictionary = summary["mults"].duplicate()
	var demand := int(summary["demand"])
	var missing := maxi(0, demand - users)
	var shadow := float(summary["user_price"])
	var rows: Array = []
	for d in cores:
		var kind := str(d.get("kind"))
		var output := float(d.get("output_n", 0))
		var res := str(d.get("recipe_res", ""))
		var need := int(d.get("recipe_n", 0))
		var value := output
		if kind == CardDB.KIND_ATTACK:
			value = floorf(float(d.get("attack_n", 0)) / maxf(1, CardDB.game_rules()["attack_cost_per_card"])) * float(p["attack_discount"])
		elif d.get("output_res") == CardDB.RES_USER:
			value = minf(output, missing) * shadow + maxf(0.0, output - missing) * CardDB.pawn_user()
		if res == CardDB.RES_CASH:
			value -= need
		rows.append({"d": d, "value": value, "ratio": value / maxf(1, need)})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["ratio"] > b["ratio"])
	var total := 0.0
	for row in rows:
		var d: Dictionary = row["d"]
		var need := int(d.get("recipe_n", 0))
		var user_recipe: bool = d.get("recipe_res") == CardDB.RES_USER
		var fill := user_recipe and int(mults["user_fill"]) > 0 and need > 1
		if fill:
			need = 1
		if need > (users if user_recipe else cash):
			continue
		var value := float(row["value"])
		var bt := "attack_x2" if d.get("kind") == CardDB.KIND_ATTACK else "output_x2"
		var pay := 0 if user_recipe else need
		var multiplier := CardDB.buff_mult(bt) if int(mults[bt]) > 0 else 1
		var user_output := 0
		if d.get("kind") == CardDB.KIND_ATTACK:
			value = floorf(float(d.get("attack_n", 0)) * multiplier / maxf(1, CardDB.game_rules()["attack_cost_per_card"])) * float(p["attack_discount"]) - pay
		elif d.get("output_res") == CardDB.RES_USER:
			user_output = int(d.get("output_n", 0)) * multiplier
			value = minf(user_output, missing) * shadow + maxf(0, user_output - missing) * CardDB.pawn_user() - pay
		else:
			value = (value + pay) * multiplier - pay
		if value <= 0:
			continue
		if user_recipe:
			users -= need
		else:
			cash -= need
		if fill:
			mults["user_fill"] -= 1
		if int(mults[bt]) > 0:
			mults[bt] -= 1
		missing = maxi(0, missing - user_output)
		total += value
	return total


static func _parameters(p: Dictionary) -> Dictionary:
	return p if not p.is_empty() else AISearch.from_model("ai", 0.0).resolved_parameters()

static func _context(p: Dictionary) -> Context:
	var context: Variant = p.get("_context")
	return context if context is Context else Context.new()
