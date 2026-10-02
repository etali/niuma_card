# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## AI 卡表无关性审计。
##
## 这组判据不要求某张卡存在，也不冻结当前卡表的数值。它检查两条更基本的契约：
## 1. AI 的策略对象不能通过 v1 的策略对象间接获得卡表专属阈值；
## 2. AI 评估和方案选择不能读取 behavior 段中的历史启发式参数。
##
## 卡面和环境规则通过 CardDB / ComboRules 查询，卡面变化时结果随规则重算。

const EVAL_PATH := "res://engine/ai_evaluation.gd"

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_no_v1_strategy_import()
	_test_no_v1_strategy_calls()
	_test_no_behavior_dependency()
	_test_read_only()
	_test_renaming_and_table_order()
	_test_recipe_output_and_buff_mutation()
	finish()

func _sources() -> String:
	var text := ""
	for name in ["ai_actions.gd", "ai_context.gd", "ai_environment.gd", "ai_evaluation.gd",
			"ai_turn_plan.gd", "ai_turn_strategy.gd"]:
		text += FileAccess.get_file_as_string("res://engine/" + name) + "\n"
	return text

func _test_no_v1_strategy_import() -> void:
	var plan := _sources()
	var ev := FileAccess.get_file_as_string(EVAL_PATH)
	var forbidden := []
	for token in ["ai_plan.gd", "ai_player.gd"]:
		if plan.contains(token) or ev.contains(token):
			forbidden.append(token)
	check(forbidden.is_empty(),
		"AI 不导入 v1 策略模块（发现 %s）" % [forbidden])

func _test_no_v1_strategy_calls() -> void:
	var src := _sources()
	var forbidden := []
	for token in ["V1_PLAN", "AIPlayer.", "AIEvaluation.", "AIPlan."]:
		if src.contains(token):
			forbidden.append(token)
	check(forbidden.is_empty(),
		"AI 不通过 v1 策略对象间接执行（发现 %s）" % [forbidden])

func _test_no_behavior_dependency() -> void:
	var src := _sources()
	var forbidden := []
	for token in ["CardDB.ai_rules()", "ai_rules()", "seat_value", "keep_user_floor",
			"buff_min_output", "output_weight_cash", "output_weight_user"]:
		if src.contains(token):
			forbidden.append(token)
	check(forbidden.is_empty(),
		"AI 不读取 v1 behavior 历史参数（发现 %s）" % [forbidden])

func _test_read_only() -> void:
	var state := GameState.new()
	state.set_seed(20260917)
	state.new_game()
	var before := StateCodec.canon(StateCodec.snapshot(state))
	var cfg := AISearch.from_model("ai", 0.0)
	var plan := AIPlan.choose_plan(state, GameState.AI, cfg)
	var score := preload("res://engine/ai_evaluation.gd").score(state, GameState.AI)
	check(plan is Dictionary and is_finite(score), "AI 方案与评估均可运行")
	check(StateCodec.canon(StateCodec.snapshot(state)) == before,
		"AI 方案/评估不修改状态、UID 或随机流")


## 同构重命名和卡表反序不能改变当前策略的动作语义。
func _test_renaming_and_table_order() -> void:
	var old_cards := CardDB.CARDS.duplicate(true)
	var old_units := CardDB.UNITS.duplicate(true)
	var state := _fixture()
	var cfg := AISearch.from_model("ai", 0.0)
	var original := _act(state, cfg)
	var original_score: float = preload("res://engine/ai_evaluation.gd").score(state, GameState.AI)
	var forward := {}
	var backward := {}
	var keys: Array = old_cards.keys()
	for i in keys.size():
		var new_id := "renamed_%03d" % (keys.size() - i)
		forward[str(keys[i])] = new_id
		backward[new_id] = str(keys[i])
	var renamed := {}
	keys.reverse()
	for old_id in keys:
		var def: Dictionary = old_cards[old_id].duplicate(true)
		def["name"] = "Renamed card %s" % forward[old_id]
		if forward.has(str(def.get("upgrade_from", ""))):
			def["upgrade_from"] = forward[str(def["upgrade_from"])]
		renamed[forward[old_id]] = def
	CardDB.CARDS = renamed
	CardDB.UNITS = {}
	for res in old_units:
		CardDB.UNITS[res] = forward[str(old_units[res])]
	var renamed_state := _remap_state(state, forward)
	var renamed_score: float = preload("res://engine/ai_evaluation.gd").score(renamed_state, GameState.AI)
	var renamed_result := _act(renamed_state, cfg)
	var restored_result := _remap_state(renamed_result, backward)
	CardDB.CARDS = old_cards
	CardDB.UNITS = old_units
	check(is_equal_approx(original_score, renamed_score),
		"全部卡名/ID 重命名并反序卡表后，AI 评分不变")
	check(_semantic(original) == _semantic(restored_result),
		"全部卡名/ID 重命名并反序卡表后，AI 真实动作语义不变")

func _fixture() -> GameState:
	var state := GameState.new()
	state.set_seed(307)
	state.players = {GameState.PLAYER: {"cards": []}, GameState.AI: {"cards": []}}
	for who in [GameState.PLAYER, GameState.AI]:
		for i in 12:
			state.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		for i in 6:
			state.add_card(who, CardDB.unit_id(CardDB.RES_USER))
	var products := []
	var buff := ""
	for def_id in CardDB.all_cards():
		var def := CardDB.get_def(str(def_id))
		if def.get("kind") == CardDB.KIND_PRODUCT and def.get("recipe_res") == CardDB.RES_USER:
			products.append(str(def_id))
		if buff == "" and def.get("kind") == CardDB.KIND_BUFF:
			buff = str(def_id)
	products.sort_custom(func(a: String, b: String) -> bool:
		var da := CardDB.get_def(a)
		var db := CardDB.get_def(b)
		return float(da.get("output_n", 0)) > float(db.get("output_n", 0)))
	if not products.is_empty():
		state.add_card(GameState.AI, products[0])
	if buff != "":
		state.add_card(GameState.AI, buff)
	state.market = []
	return state

func _act(state: GameState, cfg: AISearch) -> GameState:
	var copy := GameState.new()
	StateCodec.restore(copy, StateCodec.snapshot(state))
	MatchSimulator.action_phase(copy, GameState.AI, cfg)
	return copy

func _remap_state(state: GameState, mapping: Dictionary) -> GameState:
	var payload := StateCodec.snapshot(state)
	for who in payload["players"]:
		for card in payload["players"][who]["cards"]:
			card["def_id"] = mapping.get(str(card["def_id"]), str(card["def_id"]))
	for i in payload["market"].size():
		payload["market"][i] = mapping.get(str(payload["market"][i]), str(payload["market"][i]))
	for combo in payload["combos"]:
		for key in ["leader", "output_card"]:
			if combo["eval"].has(key):
				combo["eval"][key] = mapping.get(str(combo["eval"][key]), str(combo["eval"][key]))
	var result := GameState.new()
	StateCodec.restore(result, payload)
	return result

func _semantic(state: GameState) -> String:
	var payload := StateCodec.snapshot(state)
	payload.erase("log")
	return StateCodec.canon(payload)


## 合成卡不使用真实 def_id，也不沿用卡表现有配方或产量。改配置后重复同一行动，
## 再从环境认可的组合结果观察实际用料与产量，防止搜索内部保留第二份数值。
func _test_recipe_output_and_buff_mutation() -> void:
	var old_cards := CardDB.CARDS.duplicate(true)
	var old_game := CardDB.GAME.duplicate(true)
	var source := "synthetic_independence_product"
	var output_buff := "synthetic_independence_output"
	CardDB.CARDS[source] = {
		"name": "Synthetic product", "kind": CardDB.KIND_PRODUCT, "tier": 7,
		"price": 3, "weight": 0, "recipe_res": CardDB.RES_USER,
		"recipe_n": 2, "output_res": CardDB.RES_CASH, "output_n": 6,
	}
	CardDB.CARDS[output_buff] = {
		"name": "Synthetic output", "kind": CardDB.KIND_BUFF, "tier": 0,
		"price": 2, "weight": 0, "buff_type": "output_x2",
	}
	var cfg := AISearch.from_model("ai", 0.0)
	var first := _single_product_fixture(source, output_buff)
	var original := _act(first, cfg)
	var original_combo := _find_production(original, source)
	CardDB.CARDS[source]["recipe_n"] = 5
	CardDB.CARDS[source]["output_n"] = 11
	CardDB.GAME["buff_mult"]["output_x2"] = 3
	var changed := _act(_single_product_fixture(source, output_buff), cfg)
	var changed_combo := _find_production(changed, source)
	var original_valid := not original_combo.is_empty()
	var changed_valid := not changed_combo.is_empty()
	check(original_valid and changed_valid,
		"合成卡及改变数值后的卡均能由 AI 生成合法生产组合")
	if original_valid and changed_valid:
		check(_unit_count(original, original_combo, CardDB.RES_USER) == 2
			and _unit_count(changed, changed_combo, CardDB.RES_USER) == 5,
			"配方由 2 改为 5，AI 资源分配随当前卡表变化")
		check(int(original_combo["eval"].get("output_n", 0)) == 6 * int(old_game["buff_mult"]["output_x2"])
			and int(changed_combo["eval"].get("output_n", 0)) == 11 * 3,
			"产量和 Buff 倍率同时变化，AI 使用环境计算的有效产量")
	CardDB.CARDS = old_cards
	CardDB.GAME = old_game

func _single_product_fixture(source: String, output_buff: String) -> GameState:
	var state := GameState.new()
	state.set_seed(733)
	state.players = {GameState.PLAYER: {"cards": []}, GameState.AI: {"cards": []}}
	for who in [GameState.PLAYER, GameState.AI]:
		for i in 12:
			state.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		for i in 6:
			state.add_card(who, CardDB.unit_id(CardDB.RES_USER))
	state.add_card(GameState.AI, source)
	state.add_card(GameState.AI, output_buff)
	return state

func _find_production(state: GameState, leader: String) -> Dictionary:
	for combo in state.combos:
		if combo["owner"] == GameState.AI and combo["eval"].get("leader", "") == leader:
			return combo
	return {}

func _unit_count(state: GameState, combo: Dictionary, res: String) -> int:
	var count := 0
	for uid in combo["uids"]:
		var card := state.find_card(str(combo["owner"]), int(uid))
		var def := CardDB.get_def(str(card.get("def_id", "")))
		if def.get("kind", "") == CardDB.KIND_UNIT and def.get("res", "") == res:
			count += 1
	return count
