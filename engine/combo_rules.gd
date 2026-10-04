# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name ComboRules
extends RefCounted

## 组合验证（对应设计文档第六节）
## 输入一组卡牌实例，判定组合类型并计算有效效果（含 Buff 修饰）
## 产出唯一原则：一个组合只产出一种东西（新卡 / 单一资源 / 攻击）

## 传说卡当领头卡和当升级材料，走的是两条判定分支，报的是同一句话
const REASON_LEGEND_INERT := "传说卡是战果不是发动机（只能典当变现）"
const REASON_DUPLICATE_CARD := "同一张卡不能在一个组合中重复使用"

## 评估结果结构：
## {
##   valid: bool, type: "production"|"attack"|"upgrade"|"invalid",
##   leader: def_id, reason: String,
##   output_res/output_n: 有效产出（已含996翻倍）,
##   output_card: 升级产物 def_id,
##   attack_res/attack_n: 有效攻击（已含热搜翻倍）,
##   protect_user/protect_cash: 防御Buff标记,
##   recipe_res/recipe_pay_n: 结算时要被吃掉的配方料（用户配方为 0，见下）,
##   filled_by_fission: 这一组的用户配方是靠裂变鬼才补满的,
## }
##
## 资源不对称（重构后）：**配方里的现金会被吃掉，配方里的用户永久驻场。**
## 所以 recipe_pay_n 只在 recipe_res == cash 时非零；用户配方是席位不是成本。

## 同类数值 Buff 逐张相乘；不同类型分别作用于产出、攻击。
## 卡面在配方凑满之前也要显示这组未来的倍率，因此它不依赖 evaluate().valid。
## evaluate() 直接使用同一结果，避免卡面和结算各自计算出现分歧。
## 规则描述允许不带 UID；实体牌带 UID 时，同一张牌至多计算一次。
static func effect_multipliers(cards: Array) -> Dictionary:
	var out := {"output": 1, "attack": 1}
	var seen := {}
	for c in cards:
		if not c is Dictionary:
			continue
		if c.has("uid"):
			var uid := int(c["uid"])
			if seen.has(uid): continue
			seen[uid] = true
		var def: Dictionary = CardDB.get_def(str(c.get("def_id", "")))
		if def.get("kind", "") != CardDB.KIND_BUFF:
			continue
		var bt := str(def.get("buff_type", ""))
		match bt:
			"output_x2": out["output"] *= CardDB.buff_mult(bt)
			"attack_x2": out["attack"] *= CardDB.buff_mult(bt)
	return out

## 供按数量分配 Buff 的 AI 使用，和逐张应用规则一致；不限制可叠加张数。
static func stacked_multiplier(buff_type: String, count: int) -> int:
	var multiplier := 1
	var per_card := CardDB.buff_mult(buff_type)
	for _i in count:
		multiplier *= per_card
	return multiplier


static func evaluate(cards: Array) -> Dictionary:
	var result := {
		"valid": false, "type": "invalid", "leader": "", "reason": "",
		"output_res": "", "output_n": 0, "output_card": "",
		"attack_res": "", "attack_n": 0,
		"protect_user": false, "protect_cash": false,
		"recipe_res": "", "recipe_pay_n": 0, "filled_by_fission": false,
	}
	if cards.is_empty():
		result["reason"] = "空编组"
		return result

	# 分类统计
	var leaders: Array = []   # 组合卡（product/attack/legend）
	var buffs: Array = []     # Buff 卡
	var units: Array = []     # 单位卡
	var seen_uids := {}
	for c in cards:
		if not c is Dictionary or not c.get("def_id") is String:
			result["reason"] = "编组含未知卡牌"
			return result
		# 纯规则描述可以不带 UID；一旦提供实体身份，就不能重复计为多张材料。
		if c.has("uid"):
			var uid := int(c["uid"])
			if seen_uids.has(uid):
				result["reason"] = REASON_DUPLICATE_CARD
				return result
			seen_uids[uid] = true
		var def: Dictionary = CardDB.get_def(c["def_id"])
		match def.get("kind", ""):
			CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND:
				leaders.append(c)
			CardDB.KIND_BUFF:
				buffs.append(c)
			CardDB.KIND_UNIT:
				units.append(c)
			_:
				result["reason"] = "编组含未知卡牌：%s" % str(c["def_id"])
				return result

	# Buff 统计
	# 裂变鬼才：只要组里有 ≥1 张用户卡、且核心卡的配方要用户，用户就算补满。
	# 不是翻倍——翻倍在大配方上要先自己凑一半，补满是「有一张就够」
	var user_fill := false
	var multipliers := effect_multipliers(buffs)
	for b in buffs:
		match CardDB.get_def(b["def_id"]).get("buff_type", ""):
			"user_fill": user_fill = true
			"protect_user": result["protect_user"] = true
			"protect_cash": result["protect_cash"] = true

	var cash_n := _count_res(units, CardDB.RES_CASH)
	var user_n := _count_res(units, CardDB.RES_USER)

	# ---------- 多核心：纯生产卡升级 ----------
	# 同名 T1 可升对应 T2；同档生产卡可混名升传说。张数、产物统一问共享规则。
	if leaders.size() >= 2:
		if not units.is_empty() or not buffs.is_empty():
			result["reason"] = "升级组合里不能有别的卡（只放同档生产卡）"
			return result
		var ids: Array = []
		for leader in leaders: ids.append(str(leader["def_id"]))
		var target := upgrade_target_for_ids(ids)
		if target == "":
			result["reason"] = _upgrade_ids_miss_reason(ids)
			return result
		result["valid"] = true
		result["type"] = "upgrade"
		result["leader"] = ids[0]
		result["output_card"] = target
		return result

	if leaders.is_empty():
		result["reason"] = "组合需要一张核心卡（组合卡）"
		return result

	# ---------- 单核心 ----------
	var leader_id: String = leaders[0]["def_id"]
	var ldef: Dictionary = CardDB.get_def(leader_id)
	result["leader"] = leader_id

	# 生产和攻击的配方检查是同一条规则，只有产出字段不同
	if ldef["kind"] == CardDB.KIND_PRODUCT or ldef["kind"] == CardDB.KIND_ATTACK:
		var fills := _fission_fills(ldef, user_n, user_fill)
		var miss := _recipe_miss_reason(ldef, cash_n, user_n, fills)
		if miss != "":
			result["reason"] = miss
			return result
		result["valid"] = true
		result["filled_by_fission"] = fills
		# 只有现金配方会被吃掉；用户配方是永久席位
		result["recipe_res"] = ldef["recipe_res"]
		if ldef["recipe_res"] == CardDB.RES_CASH:
			result["recipe_pay_n"] = int(ldef["recipe_n"])
		if ldef["kind"] == CardDB.KIND_PRODUCT:
			# 单张 T2 只会生产。升级走的是纯生产卡那条路，跟资源无关，
			# 所以这里没有「升级判定抢在生产前面」的先后问题
			result["type"] = "production"
			result["output_res"] = ldef["output_res"]
			result["output_n"] = ldef["output_n"] * int(multipliers["output"])
		else:
			result["type"] = "attack"
			result["attack_res"] = ldef["attack_res"]
			result["attack_n"] = ldef["attack_n"] * int(multipliers["attack"])
		return result

	if ldef["kind"] == CardDB.KIND_LEGEND:
		result["reason"] = REASON_LEGEND_INERT
	return result

## 裂变鬼才这一组算不算「补满」。
## 三条同时成立才算：带裂变、核心卡吃用户、组里至少一张用户卡。
## 「至少一张」是硬门槛——裂变自己变不出用户，它只放大已有的那一张。
static func _fission_fills(ldef: Dictionary, user_n: int, user_fill: bool) -> bool:
	if not user_fill:
		return false
	if ldef["recipe_res"] != CardDB.RES_USER:
		return false
	if user_n < 1:
		return false
	# 本来就够的组不叫补满，席位占用与保护额度仍按完整配方计算
	return user_n < int(ldef["recipe_n"])

## 配方材料够不够。够返回空串，不够返回给玩家看的原因
static func _recipe_miss_reason(
	ldef: Dictionary, cash_n: int, user_n: int, filled_by_fission: bool
) -> String:
	if filled_by_fission:
		return ""
	var need: int = ldef["recipe_n"]
	var have := cash_n if ldef["recipe_res"] == CardDB.RES_CASH else user_n
	if have >= need:
		return ""
	# 用户配方差料且一张用户都没有：裂变也救不了，说清门槛在哪
	if ldef["recipe_res"] == CardDB.RES_USER and user_n == 0:
		return "配方不足：%s 需要 %s×%d，至少要放一张（裂变鬼才才能补满）" % [
			ldef["name"],
			CardDB.card_label(ldef["recipe_res"]),
			need,
		]
	# 配方里躺的是具体的牌 → 卡名（现金）
	return "配方不足：%s 需要 %s×%d（现有 %d）" % [
		ldef["name"],
		CardDB.card_label(ldef["recipe_res"]),
		need, have,
	]

static func _count_res(units: Array, res: String) -> int:
	var n := 0
	for u in units:
		var def: Dictionary = CardDB.get_def(u["def_id"])
		if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == res:
			n += 1
	return n

## 同名生产卡查询：保留 T1→对应 T2，并共享同档生产卡→传说的路线规则。
## 路线顺序、产物与精确张数全部来自 routes 和 upgrade_dup_n，不在代码中写档位表。
static func upgrade_target(dup_id: String, n: int) -> String:
	var src: Dictionary = CardDB.get_def(dup_id)
	if src.get("kind") != CardDB.KIND_PRODUCT or int(src.get("tier",0)) not in [1,2] or n < 2:
		return ""
	for r in _routes_for(src):
		var target := ""
		if str(r.get("key","")) == "dup_key":
			target = _route_target(CardDB.dup_key(),n,r,CardDB.KIND_LEGEND)
		elif str(r.get("key","")) == "self" and int(src.get("tier",0)) == 1:
			target = _route_target(dup_id,n,r,CardDB.KIND_PRODUCT,2)
		if target != "": return target
	return ""

## 任意同档生产卡的传说目标；不接受混档，不借 self 路线返回普通生产卡。
## dup_t2 保留为旧配置的占位键，只表示传说路线来源，不再限制材料同名。
static func legend_upgrade_target(tier: int, n: int) -> String:
	if tier not in [1,2] or n < 2: return ""
	for r in _routes_for({"kind":CardDB.KIND_PRODUCT,"tier":tier}):
		if str(r.get("key","")) != "dup_key": continue
		var target := _route_target(CardDB.dup_key(),n,r,CardDB.KIND_LEGEND)
		if target != "": return target
	return ""

## 实际材料的唯一升级查询。UI、AI 与 evaluate 均可复用，不各自实现混名/混档判断。
static func upgrade_target_for_ids(ids: Array) -> String:
	if ids.size() < 2: return ""
	var tier := -1
	var same := true
	for id in ids:
		if not id is String: return ""
		var def := CardDB.get_def(id)
		var card_tier := int(def.get("tier",0))
		if def.get("kind") != CardDB.KIND_PRODUCT or card_tier not in [1,2]: return ""
		if tier == -1: tier = card_tier
		if card_tier != tier: return ""
		if id != ids[0]: same = false
	return upgrade_target(str(ids[0]),ids.size()) if same else legend_upgrade_target(tier,ids.size())

## 精确张数是硬约束：即使旧配置 require_multiple=false，也不能截断除法吞掉多余材料。
static func _route_target(source: String,n: int,route: Dictionary,kind: String,tier := -1) -> String:
	var per := int(route.get("per",1))
	if per <= 0 or n % per != 0: return ""
	var want_n: int = n / per
	for id in CardDB.all_cards():
		var def := CardDB.get_def(str(id))
		if def.get("kind") != kind or (tier >= 0 and int(def.get("tier",0)) != tier): continue
		if str(def.get("upgrade_from","")) == source and int(def.get("upgrade_dup_n",0)) == want_n:
			return str(id)
	return ""

## 这张卡对得上哪几条升级路线，按配置里的次序。
## kind/tier 省略 = 不限定那一维（兜底那条两个都省，于是谁都对得上）
static func _routes_for(src: Dictionary) -> Array:
	var out: Array = []
	for r in CardDB.upgrade_rules().get("routes", []):
		if typeof(r) != TYPE_DICTIONARY:
			continue
		if r.has("kind") and str(r["kind"]) != str(src.get("kind", "")):
			continue
		if r.has("tier") and int(r["tier"]) != int(src.get("tier", 0)):
			continue
		out.append(r)
	return out

static func _upgrade_ids_miss_reason(ids: Array) -> String:
	var tier := -1
	var same := true
	for id in ids:
		var def := CardDB.get_def(str(id))
		if def.get("kind") == CardDB.KIND_LEGEND: return REASON_LEGEND_INERT
		if def.get("kind") != CardDB.KIND_PRODUCT or int(def.get("tier",0)) not in [1,2]:
			return "升级只接受 T1 或 T2 生产卡，不能混入其他类型"
		if tier == -1: tier = int(def["tier"])
		if int(def["tier"]) != tier: return "升级要求全部同档，T1/T2 不能混合"
		if id != ids[0]: same = false
	if same: return _upgrade_miss_reason(str(ids[0]),ids.size())
	var counts: Array = []
	for n in range(2,CardDB.max_upgrade_n()+1):
		if legend_upgrade_target(tier,n) != "": counts.append(str(n))
	if counts.is_empty(): return "T%d 生产卡没有传说升级路线" % tier
	return "同档 T%d 生产卡升传说需恰好 %s 张（现有 %d 张）；升对应 T2 仍需同名" % [tier,"/".join(counts),ids.size()]

## 同名材料张数不对：列出它支持的全部档位，区分 T2 与传说对同名的要求。
static func _upgrade_miss_reason(dup_id: String, n: int) -> String:
	var src: Dictionary = CardDB.get_def(dup_id)
	var name: String = src.get("name", dup_id)
	if src.get("kind") == CardDB.KIND_LEGEND:
		return REASON_LEGEND_INERT
	# 上界 = 最长那条路线的张数（CardDB.max_upgrade_n：最高档 × 最大折算率）。
	# 逐个问 upgrade_target 而不是写死 [2,3,4]：T1 认 2/4/6/8、T2 认 2/3/4，
	# 两套张数写死在这里就会和卡表漂开
	var ns: Array = []
	for k in range(2, CardDB.max_upgrade_n() + 1):
		if upgrade_target(dup_id, k) != "":
			ns.append(str(k))
	if ns.is_empty():
		return "%s 没有升级路线（同名也只能各自生产）" % name
	return "%s 可用 %s 张升级：升对应 T2 需同名，升传说只需同档（现有 %d 张）" % [name, "/".join(ns), n]
