# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Context = preload("res://engine/bot_context.gd")
const Evaluator = preload("res://engine/bot_evaluation.gd")
const FIXTURE := "res://tests/fixtures/bot_features_frozen.json"

## 夹具保留旧库存与规则组合；资产/升级/资源特征仍与独立参考逐位核对。
## 产能和总分已修复贪心分配及重复计值，不冻结旧错误策略；这里核验有无缓存
## 与复用对方特征的逐位等价，真实收益正确性见 test_bot_evaluation_quality。
var _fixture: Dictionary

func _initialize() -> void:
	CardDB.ensure_loaded()
	var original_path := CardDB.loaded_from
	_fixture = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	_install_fixture()
	_test_frozen_features()
	_test_feature_cache()
	_install_fixture()
	_test_context_queries()
	_test_rule_changes()
	_test_same_path_reload()
	_install_fixture()
	_test_parallel_contexts()
	CardDB.load_from(original_path)
	finish()

func _install_fixture() -> void:
	CardDB.CARDS = _fixture["cards"].duplicate(true)
	CardDB.GAME = _fixture["game"].duplicate(true)
	CardDB.UPGRADE = _fixture["upgrade"].duplicate(true)
	CardDB.UNITS = {"cash": "cash", "user": "user"}

func _state(sample: Dictionary) -> GameState:
	var state := GameState.new()
	state.players = {GameState.PLAYER: {"cards": []}, GameState.BOT: {"cards": []}}
	for who in [GameState.PLAYER, GameState.BOT]:
		for id in sample["cards"][who]:
			state.add_card(who, str(id))
	state.winner = sample.get("winner", "")
	return state

func _bits(value: float) -> String:
	return PackedFloat64Array([value]).to_byte_array().hex_encode()

func _observed(state: GameState, who: String, p: Dictionary) -> Dictionary:
	var values := Evaluator.features(state, who, p)
	var bits := {}
	for key in values:
		bits[key] = _bits(float(values[key]))
	bits["standalone_capacity"] = _bits(Evaluator.capacity(state, who, p))
	bits["standalone_user_price"] = _bits(Evaluator.user_price(state, who))
	bits["score"] = _bits(Evaluator.score(state, who, p))
	return bits

func _test_frozen_features() -> void:
	for sample in _fixture["cases"]:
		CardDB.GAME = _fixture["game"].duplicate(true)
		CardDB.GAME.merge(sample.get("game_overrides", {}), true)
		var state := _state(sample)
		var before := StateCodec.canon(StateCodec.snapshot(state))
		var parameters: Dictionary = sample["parameters"].duplicate(true)
		var parameters_before := StateCodec.canon(parameters)
		var cached := parameters.duplicate()
		cached["_context"] = Context.new()
		for who in [GameState.PLAYER, GameState.BOT]:
			var label := "%s/%s" % [sample["name"], who]
			var expected: Dictionary = sample["expected_bits"][who]
			var observed := _observed(state, who, parameters)
			var unchanged := true
			for key in ["asset","option","risk","cash","users","standalone_user_price"]:
				unchanged = unchanged and observed[key] == expected[key]
			check(unchanged,"%s 资产/升级/资源特征与独立参考逐位一致" % label)
			check(_observed(state, who, cached) == observed,
				"%s 复用上下文与无缓存的全部特征/评分逐位一致" % label)
			var opposing := Evaluator.features(state, GameState.opponent(who), cached)
			check(_bits(Evaluator.score(state, who, cached, opposing)) == observed["score"],
				"%s 复用对方特征与完整评分逐位一致" % label)
		check(StateCodec.canon(StateCodec.snapshot(state)) == before,
			"%s 评估不改变状态、UID 或随机流" % sample["name"])
		check(StateCodec.canon(parameters) == parameters_before,
			"%s 不向外部参数字典注入上下文" % sample["name"])
	var terminal := GameState.new()
	terminal.winner = GameState.PLAYER
	terminal.players = {}
	check(Evaluator.score(terminal, GameState.PLAYER, {}, {"total": -999.0}) == 1000000.0
		and Evaluator.score(terminal, GameState.BOT, {}, {"total": 999.0}) == -1000000.0,
		"缓存对方特征不绕过终局判断，终局无需再访问双方手牌")

func _test_feature_cache() -> void:
	_install_fixture()
	var sample: Dictionary = _fixture["cases"][1]
	var state := _state(sample)
	var p: Dictionary = sample["parameters"].duplicate()
	var context := Context.new()
	p["_context"] = context
	var expected := Evaluator.features(state,GameState.PLAYER,sample["parameters"])
	var returned := Evaluator.features(state,GameState.PLAYER,p)
	returned["total"] = -99999.0
	returned["engine"] = -99999.0
	check(Evaluator.features(state,GameState.PLAYER,p) == expected and context.feature_hits == 1,
		"调用方修改返回字典不会污染特征缓存")
	var hits := context.feature_hits
	for who in state.players:
		for card in state.players[who]["cards"]:
			card["uid"] += 1000
			card["locked"] = not card.get("locked",false)
	check(Evaluator.features(state,GameState.PLAYER,p) == expected and context.feature_hits == hits+1,
		"特征缓存忽略不参与保有能力估计的UID和编组锁定")
	for id in ["cash","user","attack"]:
		var changed := BOTEnvironment.copy(state)
		changed.add_card(GameState.BOT,id)
		hits = context.feature_hits
		check(Evaluator.features(changed,GameState.PLAYER,p) == Evaluator.features(changed,GameState.PLAYER,sample["parameters"])
			and context.feature_hits == hits,"对方新增%s时重新估计风险，不误用原特征" % id)
	for field in ["engine_horizon","upgrade_weight","risk_weight","attack_discount"]:
		var precise: Dictionary = p.duplicate()
		precise[field] = float(precise[field])+0.000000000001
		var independent := precise.duplicate()
		independent.erase("_context")
		hits = context.feature_hits
		Evaluator.features(state,GameState.PLAYER,precise)
		var missed := context.feature_hits == hits
		check(missed and _observed(state,GameState.PLAYER,precise) == _observed(state,GameState.PLAYER,independent),
			"%s低于十位小数的变化仍与独立评估逐位一致" % field)
	# 直接使用攻击产能，防止其他生产路线遮住攻击折扣缓存串值。
	var attack := _state({"cards":{"player":["cash","user","user","attack"],"bot":["cash","user"]}})
	var base: Dictionary = sample["parameters"].duplicate()
	base["_context"] = Context.new()
	var before := Evaluator.capacity(attack,GameState.PLAYER,base)
	var close := base.duplicate()
	close["attack_discount"] = float(close["attack_discount"])+0.000000000001
	var independent := close.duplicate()
	independent.erase("_context")
	check(_bits(Evaluator.capacity(attack,GameState.PLAYER,close)) == _bits(Evaluator.capacity(attack,GameState.PLAYER,independent))
		and _bits(before) != _bits(Evaluator.capacity(attack,GameState.PLAYER,close)),
		"资源DP缓存同样保留攻击折扣完整精度")
	var override := {"total":17.0}
	var expected_score := clampf((float(expected["total"])-17.0)/float(CardDB.game_rules()["win_cash"]),-100.0,100.0)
	check(_bits(Evaluator.score(state,GameState.PLAYER,p,override)) == _bits(expected_score),
		"缓存仍尊重调用方提供的对方特征")
	var reordered := BOTEnvironment.copy(state)
	reordered.players[GameState.PLAYER]["cards"].reverse()
	check(_observed(reordered,GameState.PLAYER,p) == _observed(reordered,GameState.PLAYER,sample["parameters"]),
		"交换持牌顺序后按新的逐牌求和顺序估值")
	for case in _fixture["cases"]:
		if case["name"] != "float_order": continue
		var ordered := _state(case)
		var ordered_p: Dictionary = case["parameters"].duplicate()
		ordered_p["_context"] = Context.new()
		Evaluator.features(ordered,GameState.PLAYER,ordered_p)
		ordered.players[GameState.PLAYER]["cards"].reverse()
		check(_observed(ordered,GameState.PLAYER,ordered_p) == _observed(ordered,GameState.PLAYER,case["parameters"]),
			"巨大和微小典当值混合时缓存也不改变浮点求和顺序")

func _test_context_queries() -> void:
	var context := Context.new()
	check(context.max_upgrade_n() == CardDB.max_upgrade_n(), "上下文升级上界与当前规则一致")
	var ids: Array = CardDB.CARDS.keys() + ["missing"]
	for id in ids:
		check(context.pawn_value(id) == CardDB.pawn_value(id), "%s 出售价格缓存一致" % id)
		var targets_match := true
		for count in range(2, CardDB.max_upgrade_n() + 1):
			targets_match = targets_match and context.upgrade_target(id, count) == ComboRules.upgrade_target(id, count)
		check(targets_match, "%s 升级目标缓存保持原规则" % id)
		var dp_matches := true
		for count in [0, 1, 2, 4, 3, 12, 6, 17, 4]:
			dp_matches = dp_matches and _bits(context.upgrade_value(id, count)) == _bits(_reference_upgrade(id, count))
		check(dp_matches, "%s DP 扩展、缩小查询及重复查询逐位一致" % id)
		check(context.semantic_key(id) == _reference_semantic(id), "%s 语义键保持字段与升级顺序" % id)
	CardDB.CARDS["second_upgrade"] = CardDB.CARDS["upgraded"].duplicate(true)
	check(Context.new().upgrade_target("producer", 2) == "upgraded", "同路线目标以卡表首次匹配为准")
	var reversed := {"second_upgrade": CardDB.CARDS["second_upgrade"]}
	reversed.merge(CardDB.CARDS)
	CardDB.CARDS = reversed
	check(Context.new().upgrade_target("producer", 2) == "second_upgrade", "新上下文遵循更换卡表后的首次匹配顺序")
	_install_fixture()

func _test_rule_changes() -> void:
	var first := Context.new()
	var before := _signature(first)
	CardDB.CARDS["producer"]["pawn"] = 23
	CardDB.CARDS["upgraded"]["upgrade_dup_n"] = 4
	CardDB.UPGRADE["routes"][2]["per"] = 3
	var changed := Context.new()
	check(_signature(changed) != before, "新决策上下文读取变更后的价格、升级张数和路线")
	check(changed.pawn_value("producer") == CardDB.pawn_value("producer")
		and changed.max_upgrade_n() == CardDB.max_upgrade_n()
		and changed.upgrade_target("producer", 2) == ComboRules.upgrade_target("producer", 2)
		and changed.upgrade_value("producer", 12) == _reference_upgrade("producer", 12)
		and changed.semantic_key("producer") == _reference_semantic("producer"),
		"所有缓存查询在新上下文与更改后真实规则一致")
	check(_signature(first) == before, "两个决策实例不共享可变缓存")
	_install_fixture()
	check(_signature(Context.new()) == before, "卡表 A→B→A 后不存在跨决策残留")

func _signature(context: Context) -> Array:
	return [context.pawn_value("producer"), context.max_upgrade_n(),
		context.upgrade_target("producer", 2), context.upgrade_value("producer", 12),
		context.semantic_key("producer")]

func _test_same_path_reload() -> void:
	var path := "user://test_bot_cache_%d.json" % OS.get_process_id()
	var table: Dictionary = _fixture["cards"].duplicate(true)
	table[CardDB.SECTION_GAME] = _fixture["game"].duplicate(true)
	table[CardDB.SECTION_GAME].merge({"market_size": 6, "start_cash": 20, "start_user": 10})
	table[CardDB.SECTION_UPGRADE] = _fixture["upgrade"].duplicate(true)
	_write_table(path, table)
	check(CardDB.load_from(path), "临时外置卡表 A 加载成功")
	var first := _signature(Context.new())
	table["producer"]["pawn"] = 27
	_write_table(path, table)
	check(CardDB.load_from(path), "同路径替换后的卡表 B 加载成功")
	var second := Context.new()
	check(second.pawn_value("producer") == 27 and _signature(second) != first,
		"同路径重新加载不会沿用旧出售价格或语义缓存")
	table["producer"].erase("pawn")
	_write_table(path, table)
	check(CardDB.load_from(path), "同路径恢复卡表 A 成功")
	check(_signature(Context.new()) == first, "同路径 A→B→A 恢复全部派生值")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _write_table(path: String, table: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(table, "", false, true))
	file.close()

func _test_parallel_contexts() -> void:
	var threads: Array[Thread] = []
	for i in 2:
		var thread := Thread.new()
		var count := 10 + i
		thread.start(func() -> Array:
			var context := Context.new()
			return [context.upgrade_value("producer", count), context.semantic_key("producer")])
		threads.append(thread)
	for i in threads.size():
		var result: Array = threads[i].wait_to_finish()
		check(result == [_reference_upgrade("producer", 10 + i), _reference_semantic("producer")],
			"并行决策 %d 使用各自上下文得到相同规则结果" % i)

## 独立保留旧递推作边界判据，尤其覆盖已缓存短前缀再延长的情况。
func _reference_upgrade(id: String, count: int) -> float:
	var dp: Array = [0.0]
	for n in range(1, count + 1):
		var best: float = dp[n - 1]
		for k in range(2, mini(n, CardDB.max_upgrade_n()) + 1):
			var target := ComboRules.upgrade_target(id, k)
			if target == "":
				continue
			var gain := maxf(0.0, CardDB.pawn_value(target) - k * CardDB.pawn_value(id))
			best = maxf(best, float(dp[n - k]) + gain)
		dp.append(best)
	return float(dp[count])

func _reference_semantic(id: String) -> String:
	var d := CardDB.get_def(id)
	var data := {}
	for key in ["kind", "tier", "price", "recipe_res", "recipe_n", "output_res", "output_n", "attack_res", "attack_n", "buff_type"]:
		data[key] = d.get(key)
	data["pawn"] = CardDB.pawn_value(id)
	var upgrades: Array = []
	for n in range(2, CardDB.max_upgrade_n() + 1):
		var target := ComboRules.upgrade_target(id, n)
		if target != "":
			var td := CardDB.get_def(target)
			upgrades.append([n, td.get("kind"), CardDB.pawn_value(target), td.get("recipe_res"), td.get("recipe_n"), td.get("output_res"), td.get("output_n")])
	data["upgrades"] = upgrades
	return StateCodec.canon(data)
