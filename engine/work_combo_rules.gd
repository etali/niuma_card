# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name WorkComboRules
extends RefCounted

## Original Board's composition/highlight protocol, backed by the realtime card
## pool. Only returns presentation data; WorkState owns all changes and timing.
static func effect_multipliers(_cards: Array) -> Dictionary:
	return {"output": 1, "attack": 1}

static func recipe_need(def: Dictionary, _mods: Dictionary = {}) -> int:
	return int(def.get("recipe_n", 0))

static func scaled_output(base: int, _res: String, _mods: Dictionary = {}) -> int:
	return base

static func is_wild(_def_id: String) -> bool: return false
static func upgrade_target(_dup_id: String, _n: int) -> String: return ""
static func legend_upgrade_target(_tier: int, _n: int) -> String: return ""
static func upgrade_target_for_ids(_ids: Array) -> String: return ""
static func _fission_fills(_def: Dictionary, _n: int, _fill: bool, _need := -1) -> bool: return false

static func evaluate(cards: Array, _mods: Dictionary = {}) -> Dictionary:
	var result := {"valid": false, "type": "invalid", "leader": "", "reason": "",
		"output_res": "", "output_n": 0, "output_card": "", "attack_res": "", "attack_n": 0,
		"protect_user": false, "protect_cash": false, "recipe_res": "", "recipe_pay_n": 0,
		"filled_by_fission": false}
	var people := 0
	var workers: Array[String] = []
	var upgrade_recipes: Array[Dictionary] = []
	var ingredients: Array[String] = []
	var work := 0
	var tools: Array[String] = []
	var seen: Dictionary = {}
	for card in cards:
		if not card is Dictionary: continue
		if card.has("uid"):
			if seen.has(card.uid):
				result.reason = "同一张卡不能重复编组"
				return result
			seen[card.uid] = true
		var id := str(card.get("def_id", card.get("type", "")))
		var def := WorkCardDB.get_def(id)
		match def.get("category", ""):
			"person":
				people += 1
				var upgrade := WorkCardDB.config.coffee_upgrade(id)
				if not upgrade.is_empty(): upgrade_recipes.append(upgrade)
				if WorkCardDB.config.can_work(id):
					workers.append(id)
				if result.leader == "": result.leader = id
			"work": work += 1
			"tool": tools.append(id)
			"ingredient": ingredients.append(id)
	var upgrade_target_kind := ""
	for upgrade in upgrade_recipes:
		if ingredients.count("coffee") >= int(upgrade.cost):
			upgrade_target_kind = str(upgrade.to)
			break
	if not upgrade_target_kind.is_empty():
		result.valid = true
		result.type = "upgrade"
		result.output_card = upgrade_target_kind
	elif people > 0 and ((work > 0 and tools.has("transfer")) or tools.has("meeting") or tools.has("slack")):
		result.valid = true
		result.type = "activity"
	elif not workers.is_empty() and work > 0:
		result.valid = true
		result.type = "production"
		result.output_res = WorkCardDB.RES_CASH
		for kind in workers:
			var count := WorkCardDB.config.work_batch_size(kind, work)
			result.output_n += count * WorkCardDB.config.income_per_work(kind)
			result.recipe_pay_n += count
			work -= count
			if work == 0: break
		result.recipe_res = WorkCardDB.RES_USER
	elif work > 0 and tools.has("outsource"):
		result.valid = true
		result.type = "activity"
	else:
		result.reason = "把工作叠给人员，或加入工具组成分工小组"
	return result
