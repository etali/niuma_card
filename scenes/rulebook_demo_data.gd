# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Content = preload("res://scenes/rulebook_content.gd")

## 演示量从当前卡表和真实组合裁决得到；这里只选择示例与讲解步骤。
static func examples(section: String) -> Array:
	CardDB.ensure_loaded()
	var out: Array = []
	match section:
		"victory":
			var win := int(CardDB.game_rules()["win_cash"])
			out.append({"title": "资金达标", "mode": "victory", "inputs": [_card(CardDB.unit_id(CardDB.RES_CASH), win - 1)],
				"output": _card(CardDB.unit_id(CardDB.RES_CASH), win), "before": win - 1, "after": win,
				"captions": ["自己的资金接近胜利线", "产出或典当使资金达到 %d" % win, "资金达标，获胜！"], "result": "获胜"})
			for res in [CardDB.RES_CASH, CardDB.RES_USER]:
				var initial := int(CardDB.game_rules()["start_cash" if res == CardDB.RES_CASH else "start_user"])
				out.append({"title": "对手%s归零" % CardDB.res_label(res), "mode": "eliminate",
					"inputs": [_card(CardDB.unit_id(res), initial)], "output": _card(CardDB.unit_id(res), 0),
					"before": initial, "after": 0, "captions": ["对手还持有%s" % CardDB.card_label(res),
					"用对应攻击点逐张移除，每张消耗 %d 点" % CardDB.game_rules()["attack_cost_per_card"], "对手%s归零，你获胜！" % CardDB.res_label(res)], "result": "获胜"})
			# 失败由相同规则反向触发，不另造一套结算逻辑。
			for won in out.duplicate(true):
				var lost: Dictionary = won.duplicate(true)
				lost["lose"] = true
				lost["result"] = "失败"
				if lost["mode"] == "victory":
					lost["title"] = "对手资金达标"
					lost["captions"] = ["对手资金接近胜利线", "对手资金达到 %d" % win, "对手资金达标，你失败"]
				else:
					var resource := str(CardDB.get_def(lost["inputs"][0]["id"])["res"])
					lost["title"] = "自己%s归零" % CardDB.res_label(resource)
					lost["captions"] = ["自己还持有%s" % CardDB.card_label(resource),
						"对手逐张移除，每张消耗 %d 点" % CardDB.game_rules()["attack_cost_per_card"],
						"自己%s归零，你失败" % CardDB.res_label(resource)]
				out.append(lost)
		"purchase":
			for id in CardDB.all_cards():
				var def := CardDB.get_def(id)
				if int(def.get("price", -1)) < 0 or int(def.get("weight", 0)) <= 0:
					continue
				var price := int(def["price"])
				out.append({"title": CardDB.card_name(id), "mode": "purchase", "target_id": id,
					"inputs": [_card(CardDB.unit_id(CardDB.RES_CASH), price)], "output": _card(id, 1),
					"price": price, "captions": ["从购牌栏选择商品，价格读取卡外价签", "把现金 ×%d 拖到「%s」上" % [price, CardDB.card_name(id)],
						"支付 %d 现金，商品飞入己方牌区；其他商品与典当行保持原位" % price], "result": "购买完成"})
		"combos":
			for id in CardDB.all_cards():
				var def := CardDB.get_def(id)
				if def.get("kind") == CardDB.KIND_PRODUCT:
					var production := _combination(str(id))
					production["title"] += " · 产出"
					out.append(production)
				var paths := Content.upgrade_paths(str(id))
				if paths.is_empty():
					continue
				var variants: Array = []
				var inputs: Array = []
				for path in paths:
					var materials := _upgrade_materials(str(id), path)
					variants.append({"count": int(path["count"]), "target_id": str(path["target_id"]),
						"inputs": materials, "material_label": "同名T%d" % int(path["tier"]) if path["same_name"] else "同档T%d（可异名）" % int(path["tier"]),
						"description": effect_text(str(path["target_id"]))})
					inputs.append_array(materials)
				out.append({"title": "%s · 升级对照" % CardDB.card_name(id), "mode": "upgrade", "source_id": id,
					"inputs": inputs, "variants": variants,
					"captions": ["按当前卡表展示各条合成路线，同时对照材料与结果", "普通升级同名；传说可异名，但须同档、精确张数且不夹杂其他牌", "所有升级结果保留在桌面，可直接比较配方、产出与回收价"], "result": "合成完成"})
		"attack":
			for id in CardDB.all_cards():
				if CardDB.get_def(id).get("kind") == CardDB.KIND_ATTACK:
					out.append(_combination(str(id)))
		"pawn":
			for id in CardDB.all_cards():
				var value := CardDB.pawn_value(id)
				if value <= 0:
					continue
				out.append({"title": CardDB.card_name(id), "mode": "pawn", "inputs": [_card(id, 1)],
					"output": _card(CardDB.unit_id(CardDB.RES_CASH), value),
					"captions": ["自己的行动阶段，把卡拖到典当行", "回收%s，卡牌离场" % CardDB.card_name(id), "立即获得%s ×%d，可继续买牌或冲线" % [CardDB.card_label(CardDB.RES_CASH), value]], "result": "典当完成"})
		"buffs":
			for id in CardDB.all_cards():
				var buff := CardDB.get_def(id)
				if buff.get("kind") != CardDB.KIND_BUFF:
					continue
				var type := str(buff.get("buff_type", ""))
				for core_id in CardDB.all_cards():
					var core := CardDB.get_def(core_id)
					var wanted := CardDB.KIND_ATTACK if type == "attack_x2" else CardDB.KIND_PRODUCT
					if core.get("kind") != wanted:
						continue
					if type == "user_fill" and (core.get("recipe_res") != CardDB.RES_USER or int(core["recipe_n"]) <= 1):
						continue
					if type.begins_with("protect_") and core.get("recipe_res") != type.trim_prefix("protect_"):
						continue
					var demo := _combination(core_id, id)
					demo["title"] = CardDB.card_name(id)
					out.append(demo)
					break
	return out

static func _card(id: String, count: int) -> Dictionary:
	return {"id": id, "count": count}

## 传说路线实际摆出两种同档生产卡；普通升级继续展示同名材料。
static func _upgrade_materials(source_id: String, path: Dictionary) -> Array:
	var count := int(path["count"])
	if not bool(path["same_name"]):
		for id in CardDB.all_cards():
			var def := CardDB.get_def(id)
			if id != source_id and def.get("kind", "") == CardDB.KIND_PRODUCT \
				and int(def.get("tier", 0)) == int(path["tier"]):
				return [_card(source_id, count - 1), _card(str(id), 1)]
	return [_card(source_id, count)]

static func _combination(core_id: String, buff_id := "") -> Dictionary:
	var core := CardDB.get_def(core_id)
	var res := str(core["recipe_res"])
	var need := int(core["recipe_n"])
	var buff_type := str(CardDB.get_def(buff_id).get("buff_type", "")) if buff_id != "" else ""
	var actual := 1 if buff_type == "user_fill" else need
	var cards: Array = [{"def_id": core_id}]
	var inputs: Array = [_card(core_id, 1), _card(CardDB.unit_id(res), actual)]
	for i in actual:
		cards.append({"def_id": CardDB.unit_id(res)})
	if buff_id != "":
		cards.append({"def_id": buff_id})
		inputs.append(_card(buff_id, 1))
	var effect := ComboRules.evaluate(cards)
	var is_attack: bool = core["kind"] == CardDB.KIND_ATTACK
	var output_res := str(effect["attack_res"] if is_attack else effect["output_res"])
	var output_n := int(effect["attack_n"] if is_attack else effect["output_n"])
	var title := CardDB.card_name(core_id)
	var captions: Array = ["核心牌与%s ×%d 放在同一摞" % [CardDB.card_label(res), actual],
		"支付配方现金，用户材料则留在桌上" if res == CardDB.RES_CASH else "配方凑齐，用户材料保留，不消耗",
		"获得%s +%d，%s保留" % [CardDB.res_label(output_res), output_n, "核心与 Buff" if buff_id != "" else "核心卡"]]
	var mode := "production"
	if is_attack:
		mode = "attack"
		captions[1] = "装弹得到%s攻击 %d 点" % [CardDB.card_label(output_res), output_n]
		captions[2] = "每张消耗 %d 点；点选同资源目标，余点可继续攻击" % CardDB.game_rules()["attack_cost_per_card"]
	if buff_type == "user_fill":
		captions[1] = "%s补满用户配方（需求 %d）；真实用户数不增加" % [CardDB.card_name(buff_id), need]
	elif buff_type in ["output_x2", "attack_x2"]:
		captions[1] = "%s使%s ×%d，配方消耗不变" % [CardDB.card_name(buff_id), "攻击" if is_attack else "产出", CardDB.buff_mult(buff_type)]
	elif buff_type.begins_with("protect_"):
		mode = "protect"
		captions[1] = "入组立即保护配方所需的%s ×%d" % [CardDB.card_label(res), GameState.protect_quota(effect)]
		captions[2] = "攻击被护盾挡住；富余投料仍可攻击，现金配方仍需支付"
	return {"title": title, "mode": mode, "inputs": inputs, "output": _card(CardDB.unit_id(output_res), output_n),
		"captions": captions, "effect": effect, "consume": res == CardDB.RES_CASH,
		"cost": int(CardDB.game_rules()["attack_cost_per_card"]), "result": "护盾生效" if mode == "protect" else ("发动攻击" if is_attack else "产出到账")}

## 对照标签的规则数值只查询卡表，不另建升级/回收数字表。
static func effect_text(def_id: String) -> String:
	var def := CardDB.get_def(def_id)
	if def.get("kind") == CardDB.KIND_LEGEND:
		return "典当：%s ×%d" % [CardDB.card_label(CardDB.RES_CASH), CardDB.pawn_value(def_id)]
	if def.has("recipe_res") and def.has("output_res"):
		return "%s ×%d → %s +%d" % [CardDB.card_label(str(def["recipe_res"])), int(def["recipe_n"]),
			CardDB.res_label(str(def["output_res"])), int(def["output_n"])]
	return "典当：%s ×%d" % [CardDB.card_label(CardDB.RES_CASH), CardDB.pawn_value(def_id)]
