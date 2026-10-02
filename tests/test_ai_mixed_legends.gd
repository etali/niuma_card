# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Context = preload("res://engine/ai_context.gd")
const Actions = preload("res://engine/ai_actions.gd")
const Evaluator = preload("res://engine/ai_evaluation.gd")
const Env = preload("res://engine/ai_environment.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	var original := CardDB.loaded_from
	_install()
	_test_six_upgrades()
	_test_bounds_and_locks()
	_test_two_material_orders()
	_test_joint_value()
	_test_contexts()
	_test_identity()
	CardDB.load_from(original)
	finish()

func _install() -> void:
	CardDB.CARDS = {
		"cash": {"kind":"unit", "res":"cash", "name":"Cash"},
		"user": {"kind":"unit", "res":"user", "name":"User"},
		"intruder": {"kind":"attack", "tier":1, "price":1, "pawn":0,
			"recipe_res":"user", "recipe_n":99, "attack_res":"cash", "attack_n":1},
		"buff": {"kind":"buff", "tier":1, "price":1, "pawn":0, "buff_type":"output_x2"},
	}
	for tier in [1, 2]:
		for i in 32:
			CardDB.CARDS["p%d_%d" % [tier, i]] = {"kind":"product", "tier":tier,
				"name":"Material %d %d" % [tier, i], "price":1, "weight":1, "pawn":0,
				"recipe_res":"user", "recipe_n":99, "output_res":"cash", "output_n":1}
	CardDB.CARDS["p2_0"]["upgrade_from"] = "p1_0"
	CardDB.CARDS["p2_0"]["upgrade_dup_n"] = 2
	for i in 3:
		CardDB.CARDS["prize%d" % i] = {"kind":"legend", "tier":3, "name":"Prize %d" % i,
			"price":-1, "pawn":[30,70,110][i], "upgrade_from":"pool", "upgrade_dup_n":i+2}
	CardDB.UNITS = {"cash":"cash", "user":"user"}
	CardDB.GAME = {"win_cash":1000, "start_cash":15, "start_user":8, "market_size":8,
		"pawn_rate":2, "pawn_user":1, "attack_cost_per_card":1,
		"buff_mult":{"output_x2":2, "attack_x2":2, "user_fill":2}}
	CardDB.UPGRADE = {"dup_key":"pool", "routes":[
		{"kind":"product", "tier":2, "key":"dup_key", "per":1},
		{"kind":"product", "tier":1, "key":"self", "per":1},
		{"kind":"product", "tier":1, "key":"dup_key", "per":2}]}

func _state(ids: Array) -> GameState:
	var state := GameState.new()
	state.set_seed(381)
	state.players = {GameState.PLAYER:{"cards":[]}, GameState.AI:{"cards":[]}}
	for who in [GameState.PLAYER, GameState.AI]:
		state.add_card(who, "cash")
		state.add_card(who, "cash")
		state.add_card(who, "user")
	for id in ids: state.add_card(GameState.AI, str(id))
	state.market = []
	return state

func _ids(tier: int, count: int) -> Array:
	var ids: Array = []
	for i in count: ids.append("p%d_%d" % [tier, i])
	return ids

func _options(state: GameState, processed: Dictionary = {}) -> Array:
	var core: Dictionary = state.players[GameState.AI]["cards"][3]
	return Actions._core_options(state, GameState.AI, core, processed, AITurnPlan.profile(0.0))

func _target(state: GameState, option: Dictionary) -> String:
	var ids: Array = []
	for uid in option["uids"]: ids.append(str(state.find_card(GameState.AI, uid)["def_id"]))
	return ComboRules.upgrade_target_for_ids(ids)

func _test_six_upgrades() -> void:
	for tier in [1, 2]:
		for size in [2, 3, 4]:
			var count: int = size * (2 if tier == 1 else 1)
			var state := _state(_ids(tier, count))
			var before := StateCodec.canon(StateCodec.snapshot(state))
			var target := "prize%d" % (size - 2)
			var found := false
			for option in _options(state):
				if option["uids"].size() == count and _target(state, option) == target: found = true
			check(found, "T%d 异名 %d 张候选产生正确传说" % [tier, count])
			var cfg := AISearch.from_model("ai", 0.0)
			var plan := AITurnPlan.choose_plan(state, GameState.AI, cfg)
			check(Env.replay(state, plan["intents"]), "T%d×%d 实际 AI 方案可重放" % [tier, count])
			var selected := false
			var used := {}
			var unique_locked := true
			for combo in state.combos:
				if combo["eval"].get("output_card", "") == target: selected = true
				for uid in combo["uids"]:
					unique_locked = unique_locked and not used.has(uid) and bool(state.find_card(GameState.AI, uid)["locked"])
					used[uid] = true
			check(selected and unique_locked, "T%d×%d AI 采用异名传说且 UID 正确独占锁定" % [tier, count])
			Settle.produce(state)
			var produced := false
			for card in state.players[GameState.AI]["cards"]:
				if card["def_id"] == target: produced = true
			check(produced, "T%d×%d 真实结算得到对应传说" % [tier, count])
			var again := _state(_ids(tier, count))
			var second := AITurnPlan.choose_plan(again, GameState.AI, cfg)
			check(plan["intents"] == second["intents"] and StateCodec.canon(StateCodec.snapshot(again)) == before,
				"T%d×%d 决策可复现且不修改输入状态/随机流" % [tier, count])
	# 普通同名路线仍然存在，且潜力不能被另一条传说路线夺走。
	CardDB.CARDS["p2_0"]["pawn"] = 20
	var ordinary := _state(["p1_0", "p1_0"])
	var plan := AITurnPlan.choose_plan(ordinary, GameState.AI, AISearch.from_model("ai", 0.0))
	Env.replay(ordinary, plan["intents"])
	Settle.produce(ordinary)
	check(ordinary.players[GameState.AI]["cards"].any(func(c): return c["def_id"] == "p2_0"),
		"2 张同名 T1 仍可由 AI 升成对应 T2")
	_install()

func _test_bounds_and_locks() -> void:
	var insufficient := _state(["p1_0", "p1_1", "p1_2", "p2_0", "intruder", "buff", "prize0"])
	check(_options(insufficient).is_empty(), "不足 4 张 T1 不用 T2/攻击/Buff/传说或资源凑数")
	var state := _state(_ids(1, 8))
	state.players[GameState.AI]["cards"][4]["locked"] = true
	var ignored := {int(state.players[GameState.AI]["cards"][5]["uid"]):true}
	var legal := true
	for option in _options(state, ignored):
		legal = legal and option["uids"].size() in [4, 6]
		for uid in option["uids"]:
			legal = legal and not ignored.has(uid) and not state.find_card(GameState.AI, uid)["locked"]
	check(legal, "已锁定/已处理材料不参与候选，8 张实际仅余 6 张")
	var many := _state(_ids(1, 32))
	# 两种排序各给每个合法档一个前缀，不枚举 32 选 4/6/8 的组合。
	var options := _options(many)
	var sets := {}
	for option in options:
		var sorted: Array = option["uids"].duplicate()
		sorted.sort()
		sets[str(sorted)] = true
	check(options.size() <= 6 and options.size() == sets.size(), "32 张异名材料候选至多 6 组且 UID 集合去重")
	var p := AITurnPlan.profile(0.0)
	p["_work"] = [3]
	Actions.generate(many, GameState.AI, p)
	check(int(p["_work"][0]) == 0, "混合传说候选仍服从共享节点额度")

func _test_two_material_orders() -> void:
	var state := _state(_ids(1, 7))
	for i in range(1, 7):
		CardDB.CARDS["p1_%d" % i]["pawn"] = 1 if i <= 3 else 10
		CardDB.CARDS["p1_%d" % i]["output_n"] = 10 if i <= 3 else 1
	var groups: Array = []
	for option in _options(state):
		if option["uids"].size() != 4: continue
		var ids: Array = []
		for uid in option["uids"]: ids.append(state.find_card(GameState.AI, uid)["def_id"])
		ids.sort()
		groups.append(ids)
	check(groups.size() == 2 and groups.has(["p1_0", "p1_1", "p1_2", "p1_3"])
		and groups.has(["p1_0", "p1_4", "p1_5", "p1_6"]),
		"材料出售价值与生产效率冲突时，同时保留两种不同牺牲方案")
	_install()

## 独立穷举小库存中的实体子集，真实规则决定每组目标；产物不回填。
## 与生产代码按数量卷积的 DP 不同，可发现同一份材料被普通/传说重复加价。
func _oracle(ids: Array, mask: int, memo: Dictionary) -> float:
	if mask == 0: return 0.0
	if memo.has(mask): return memo[mask]
	var first := 0
	while (mask & (1 << first)) == 0: first += 1
	var best := _oracle(ids, mask ^ (1 << first), memo)
	var sub := mask
	while sub > 0:
		if (sub & (1 << first)) != 0:
			var group: Array = []
			var cost := 0
			for i in ids.size():
				if (sub & (1 << i)) != 0:
					group.append(ids[i])
					cost += CardDB.pawn_value(ids[i])
			var target := ComboRules.upgrade_target_for_ids(group)
			if target != "":
				best = maxf(best, CardDB.pawn_value(target) - cost + _oracle(ids, mask ^ sub, memo))
		sub = (sub - 1) & mask
	memo[mask] = best
	return best

func _inventory(ids: Array) -> Dictionary:
	var out := {}
	for id in ids: out[id] = int(out.get(id, 0)) + 1
	return out

func _test_joint_value() -> void:
	_install()
	for id in CardDB.CARDS:
		if CardDB.CARDS[id]["kind"] == "product": CardDB.CARDS[id]["pawn"] = 1
	CardDB.CARDS["p2_0"]["pawn"] = 12
	var samples: Array = [[], ["p1_0"], ["p1_0", "p1_0"], _ids(1, 4), _ids(1, 8),
		["p1_0", "p1_0", "p1_0", "p1_0"], ["p1_0", "p1_1", "p1_2", "p2_0"],
		["p1_0", "p1_0", "p1_1", "p1_2", "p2_1", "p2_2"]]
	var context := Context.new()
	for ids in samples:
		var expected := _oracle(ids, (1 << ids.size()) - 1, {})
		check(context.inventory_upgrade_value(_inventory(ids)) == expected,
			"联合升级估值与独立实体穷举一致 %s" % [ids])
	check(context.inventory_upgrade_value({"p1_0":4}) == 26,
		"4 张同名材料取传说净增值 26，不再叠加两次普通升级的 20")
	CardDB.CARDS["p2_0"]["pawn"] = 30
	CardDB.CARDS["prize1"]["pawn"] = 35
	var ids: Array = ["p1_0", "p1_0", "p1_1", "p1_2", "p1_3", "p1_4"]
	var expected := _oracle(ids, 63, {})
	check(expected == 54 and Context.new().inventory_upgrade_value(_inventory(ids)) == expected,
		"联合分配可同时保留 2 张普通升级和另 4 张传说，收益为 28+26")
	_install()

func _test_contexts() -> void:
	var ids := _ids(1, 6)
	var inventory := _inventory(ids)
	var first := Context.new()
	var expected := first.inventory_upgrade_value(inventory)
	CardDB.CARDS["prize1"]["pawn"] = 91
	var second := Context.new()
	check(second.inventory_upgrade_value(inventory) == 91 and first.inventory_upgrade_value(inventory) == expected,
		"新 Context 读取新的传说出售价格，已有 Context 的相同库存缓存独立")
	CardDB.UPGRADE["routes"][2]["per"] = 3
	check(Context.new().inventory_upgrade_value(inventory) == 30, "新 Context 按变化后的路线材料数重建池化估值")
	_install()
	check(Context.new().inventory_upgrade_value(inventory) == expected, "卡表 A→B→A 不串池化缓存")
	var reordered := inventory.keys()
	reordered.reverse()
	var reverse_inventory := {}
	for id in reordered: reverse_inventory[id] = inventory[id]
	check(first.inventory_upgrade_value(reverse_inventory) == expected and first._pooled_values.size() == 1,
		"同一整数库存签名的不同插入顺序复用一项缓存")
	var threads: Array[Thread] = []
	for i in 2:
		var thread := Thread.new()
		thread.start(func(): return Context.new().inventory_upgrade_value(inventory))
		threads.append(thread)
	for thread in threads:
		check(thread.wait_to_finish() == expected, "并行决策各用本地 Context，池化结果一致")

func _test_identity() -> void:
	var state := _state(_ids(1, 6))
	var cfg := AISearch.from_model("ai", 0.0)
	var original := AITurnPlan.choose_plan(state, GameState.AI, cfg)
	var score := Evaluator.score(state, GameState.AI)
	var mapping := {}
	var keys: Array = CardDB.CARDS.keys()
	for i in keys.size(): mapping[keys[i]] = "arbitrary_%d" % (keys.size() - i)
	keys.reverse()
	var table := {}
	for id in keys:
		var d: Dictionary = CardDB.CARDS[id].duplicate(true)
		d["name"] = "Different name"
		if mapping.has(d.get("upgrade_from", "")): d["upgrade_from"] = mapping[d["upgrade_from"]]
		table[mapping[id]] = d
	CardDB.CARDS = table
	for key in CardDB.UNITS: CardDB.UNITS[key] = mapping[CardDB.UNITS[key]]
	for who in state.players:
		for card in state.players[who]["cards"]: card["def_id"] = mapping[card["def_id"]]
	var renamed := AITurnPlan.choose_plan(state, GameState.AI, cfg)
	check(original["intents"] == renamed["intents"] and Evaluator.score(state, GameState.AI) == score,
		"混合传说在所有 ID/展示名替换、卡表反序后评分与完整动作不变")
	_install()
