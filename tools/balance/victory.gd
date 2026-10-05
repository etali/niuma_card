# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 只读观测真实终局；不解析面向玩家的文案，不改写引擎胜负判定。
static func categories() -> Array:
	var result: Array = [
		{"id":"cash_threshold", "label":"普通现金达标"},
		{"id":"cash_depletion", "label":"对手现金清零"},
		{"id":"user_depletion", "label":"对手用户清零"},
	]
	var legends := 0
	for id in CardDB.all_cards():
		if CardDB.get_def(id).get("kind") == CardDB.KIND_LEGEND and CardDB.pawn_value(id) > 0:
			result.append({"id":"legend_cashout:"+str(id), "label":CardDB.card_name(id)+"变现达标"})
			legends += 1
	if legends >= 2:
		result.append({"id":"legend_cashout:mixed", "label":"多种传说共同变现达标"})
	return result

## 行动前保存传说 UID；典当完成时该牌已离开状态，不能再从终局手牌反推。
static func legend_uids(state: GameState, who: String) -> Dictionary:
	var ids := {}
	for card in state.players[who]["cards"]:
		if CardDB.get_def(card["def_id"]).get("kind") == CardDB.KIND_LEGEND:
			ids[int(card["uid"])] = str(card["def_id"])
	return ids

static func sold_legends(intent: Dictionary, known: Dictionary) -> Array:
	var found: Array = []
	for uid in intent.get("uids", []):
		var id := str(known.get(int(uid), ""))
		if id != "" and not found.has(id): found.append(id)
	return found

## 与 check_victory 的同一胜者内优先级一致：资金达标 > 对手现金清零 > 用户清零。
## pawn_legends 只能来自「已经触发获胜」的那次典当；此前变现不作致胜归因。
static func classify(state: GameState, pawn_legends: Array = []) -> Dictionary:
	if state.winner not in [GameState.PLAYER, GameState.BOT]: return {}
	var other := GameState.opponent(state.winner)
	var id := ""
	if state.resource_count(state.winner, CardDB.RES_CASH) >= int(CardDB.game_rules()["win_cash"]):
		id = "cash_threshold"
		if pawn_legends.size() == 1: id = "legend_cashout:"+str(pawn_legends[0])
		elif pawn_legends.size() > 1: id = "legend_cashout:mixed"
	elif state.resource_count(other, CardDB.RES_CASH) <= 0:
		id = "cash_depletion"
	elif state.resource_count(other, CardDB.RES_USER) <= 0:
		id = "user_depletion"
	for category in categories():
		if category["id"] == id: return category
	return {}
