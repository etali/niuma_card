# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Env = preload("res://engine/bot_environment.gd")
var next_uid := 0

func _initialize() -> void:
	_test_rules()
	_test_production()
	_test_attack_pool()
	_test_bot_options()
	_test_external_multiplier()
	finish()

func card(id: String) -> Dictionary:
	next_uid += 1
	return {"uid":next_uid,"def_id":id,"locked":false}

func recipe(id: String) -> Array:
	var d := CardDB.get_def(id)
	var cards: Array = [card(id)]
	for _i in int(d["recipe_n"]): cards.append(card(CardDB.unit_id(d["recipe_res"])))
	return cards

func fresh() -> GameState:
	var state := GameState.new()
	state.players = {"player":{"cards":[]},"bot":{"cards":[]}}
	for who in state.players:
		state.add_card(who,"cash")
		state.add_card(who,"user")
	return state

func place(state: GameState, id: String, buff_id: String, count: int) -> Array:
	var d := CardDB.get_def(id)
	var ids: Array = [state.add_card("player",id)["uid"]]
	for _i in int(d["recipe_n"]): ids.append(state.add_card("player",CardDB.unit_id(d["recipe_res"]))["uid"])
	for _i in count: ids.append(state.add_card("player",buff_id)["uid"])
	return ids

func _test_rules() -> void:
	for core in ["ditui","butie"]:
		var production: bool = core == "ditui"
		var key := "output_n" if production else "attack_n"
		var base := int(CardDB.get_def(core)[key])
		for count in [2,3]:
			var cards := recipe(core)
			for _i in count: cards.append(card("yinqing996" if production else "resou"))
			# 两种数值 Buff 同组时互不串台。
			for _i in 2: cards.append(card("resou" if production else "yinqing996"))
			var ev := ComboRules.evaluate(cards)
			var expected := base * (4 if count == 2 else 8)
			check(ev["valid"] and int(ev[key]) == expected,"%s 同类 %d 张叠乘且不受另一类影响" % [core,count])
			cards.pop_back()
			check(ComboRules.evaluate(cards)[key] == expected,"移除另一类 Buff 不改变本类倍率")
	var buff := card("yinqing996")
	check(ComboRules.effect_multipliers([buff,buff.duplicate()])["output"] == 2,"卡面倍率不重复计算同一 UID")
	var duplicate := recipe("ditui") + [buff,buff.duplicate()]
	check(not ComboRules.evaluate(duplicate)["valid"],"真实组合拒绝同一 UID 重复计入")
	check(ComboRules.effect_multipliers([{"def_id":"yinqing996"},{"def_id":"yinqing996"}])["output"] == 4,"无 UID 的规则描述仍按两张牌计算")
	var filled: Array = [card("yunketang"),card("user"),card("liebian"),card("liebian"),card("tuisong"),card("tuisong")]
	var ev := ComboRules.evaluate(filled)
	check(ev["valid"] and ev["filled_by_fission"] and ev["protect_user"],"重复填充和保护 Buff 仍为状态，不重复倍增产出")
	check(ev["output_n"] == CardDB.get_def("yunketang")["output_n"],"填充和保护不影响数值倍率")

func _test_production() -> void:
	var resources := {}
	for id in CardDB.all_cards():
		var d := CardDB.get_def(id)
		if d.get("kind") != CardDB.KIND_PRODUCT: continue
		for count in [2,3]:
			var s := fresh()
			var ids := place(s,id,"yinqing996",count)
			var applier := IntentApply.new(s)
			var cr := applier.apply(Intent.create_combo("player",ids),"player")
			if not need(cr["ok"],"%s + %d 引擎真实编组" % [id,count]): continue
			var before := s.resource_count("player",d["output_res"])
			var result := applier.apply(Intent.produce(0))
			var got := s.resource_count("player",d["output_res"]) - before
			var pay := int(d["recipe_n"]) if d["recipe_res"] == "cash" and d["output_res"] == "cash" else 0
			check(result["ok"] and got == int(d["output_n"])*(4 if count == 2 else 8)-pay,"%s + %d 引擎实际产出按张数叠乘" % [id,count])
			resources[d["output_res"]] = true
	check(resources.has("cash") and resources.has("user"),"真实生产覆盖现金和用户两种产出")

func _test_attack_pool() -> void:
	for count in [2,3]:
		var s := fresh()
		var ids := place(s,"butie","resou",count)
		var applier := IntentApply.new(s)
		check(applier.apply(Intent.create_combo("player",ids),"player")["ok"],"多张热搜经意图入口编组")
		var expected := int(CardDB.get_def("butie")["attack_n"]) * (4 if count == 2 else 8)
		check(s.attack_pool("player")["user"] == expected,"未装弹攻击池预览包含完整叠乘")
		var before := s.resource_count("player","cash")
		check(applier.apply(Intent.arm_attacks("player"))["ok"],"真实装弹成功")
		check(applier.pools("player")["user"] == expected,"装弹后实际攻击池包含完整叠乘")
		check(s.resource_count("player","cash") == before-int(CardDB.get_def("butie")["recipe_n"]),"多张热搜不重复消耗配方现金")
		# 真打出一次攻击，剩余点数来自叠乘后的实际池。
		var targets := applier.affordable_targets("player")
		if need(not targets.is_empty(),"叠乘攻击池可以选择合法目标"):
			var target: Dictionary = targets[0]
			var cost := int(target["cost"])
			check(applier.apply(Intent.apply_attack("player",target),"player")["ok"],"叠乘攻击经实际目标裁决落地")
			check(applier.pools("player")["user"] == expected-cost,"实际攻击扣除对应点数，保留其余叠乘点数")

func _test_bot_options() -> void:
	for core_id in ["ditui","butie"]:
		var s := fresh()
		var buff_id := "yinqing996" if core_id == "ditui" else "resou"
		var ids := place(s,core_id,buff_id,12)
		var core := s.find_card("player",ids[0])
		var p := BOTSearch.from_model("bot",0.5).resolved_parameters()
		var before := StateCodec.state_hash(s)
		var choices := BOTActions._core_options(s,"player",core,{},p)
		check(choices.size() == 13,"%s 的 12 张同类 Buff 仅按数量生成 13 种选择，无隐性张数上限或 UID 子集爆炸" % core_id)
		var counts := {}
		for choice in choices:
			var count := 0
			for uid in choice["uids"]:
				if s.find_card("player",uid)["def_id"] == buff_id: count += 1
			counts[count] = true
			check(Env.replay(Env.copy(s),[Intent.create_combo("player",choice["uids"])]),"BOT 叠加 %d 张方案经真实规则可执行" % count)
		for count in 13: check(counts.has(count),"候选包含叠加 %d 张 %s" % [count,buff_id])
		check(StateCodec.state_hash(s) == before,"候选枚举不修改原局面")
	# 已有两张倍率卡时，容量评分必须反映同组四倍，且不能再次分给其他核心。
	var s := fresh()
	place(s,"yunketang","yinqing996",2)
	var p := BOTSearch.from_model("bot",0.5).resolved_parameters()
	check(is_equal_approx(BOTEvaluator.capacity(s,"player",p),float(CardDB.get_def("yunketang")["output_n"])*4),"BOT 现金产能估值计入两张同组倍率")
	s.add_card("player","yunketang")
	for _i in int(CardDB.get_def("yunketang")["recipe_n"]): s.add_card("player","user")
	check(is_equal_approx(BOTEvaluator.capacity(s,"player",p),float(CardDB.get_def("yunketang")["output_n"])*5),"多核心估值不会把已用的两张倍率卡重复分配")
	var attack := fresh()
	place(attack,"butie","resou",2)
	var attack_points := float(CardDB.get_def("butie")["attack_n"])*4
	var expected: float = floorf(attack_points/float(CardDB.game_rules()["attack_cost_per_card"]))*p["attack_discount"]-CardDB.get_def("butie")["recipe_n"]
	check(is_equal_approx(BOTEvaluator.capacity(attack,"player",p),maxf(0,expected)),"BOT 攻击产能使用四倍攻击量")
	var summary := BOTEvaluator._summary(attack,"player")
	var Allocation = preload("res://engine/bot_resource_allocation.gd")
	var threat := Allocation.value(summary,[0.0,1.0],false,{}, {})
	check(is_equal_approx(threat,floorf(attack_points/float(CardDB.game_rules()["attack_cost_per_card"]))),"BOT 可行威胁分配识别叠加热搜攻击量")
	var boosted: float = BOTEvaluator.features(attack,"bot",p).total
	var unboosted := Env.copy(attack)
	for c in unboosted.players.player.cards.duplicate():
		if c.def_id == "resou": unboosted.remove_card("player",c.uid)
	check(boosted < BOTEvaluator.features(unboosted,"bot",p).total,"对方叠加热搜提高威胁、降低本方估值")

func _test_external_multiplier() -> void:
	var path := "user://stacking-cards.json"
	var contents: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cards.json"))
	if not contents.has("_game"): contents["_game"] = {}
	contents["_game"]["buff_mult"] = {"output_x2":3,"attack_x2":4}
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(contents));file.close()
	check(CardDB.load_from(path),"加载外置 Buff 倍率配置")
	for core in ["ditui","butie"]:
		var production: bool = core == "ditui"
		var cards := recipe(core)
		for _i in 2: cards.append(card("yinqing996" if production else "resou"))
		var key := "output_n" if production else "attack_n"
		var multiplier := 9 if production else 16
		check(ComboRules.effect_multipliers(cards)["output" if production else "attack"] == multiplier,"卡面叠加使用外置倍率")
		check(ComboRules.evaluate(cards)[key] == int(CardDB.get_def(core)[key])*multiplier,"结算叠加使用外置倍率")
		check(ComboRules.stacked_multiplier("output_x2" if production else "attack_x2",2) == multiplier,"BOT 数量倍率使用同一外置配置")
	CardDB.load_from("res://data/cards.json")
