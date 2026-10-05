# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Eval = preload("res://engine/bot_evaluation.gd")
const Actions = preload("res://engine/bot_actions.gd")
const Plan = preload("res://engine/bot_turn_plan.gd")
const WHO := GameState.BOT
const FOE := GameState.PLAYER

func _initialize() -> void:
	CardDB.ensure_loaded()
	var original := CardDB.CARDS.duplicate(true)
	CardDB.CARDS["hyper_product"] = {"name":"Synthetic","kind":"product","tier":1,"price":2,
		"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":3}
	CardDB.CARDS["hyper_attack"] = {"name":"Synthetic attack","kind":"attack","price":2,
		"recipe_res":"user","recipe_n":1,"attack_res":"cash","attack_n":10}
	CardDB.CARDS["hyper_upgrade"] = {"name":"Synthetic upgrade","kind":"product","tier":2,"price":-1,
		"pawn":20,"upgrade_from":"hyper_product","upgrade_dup_n":2,
		"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":6}
	CardDB.CARDS["hyper_protect"] = {"name":"Synthetic protect","kind":"buff","price":2,"buff_type":"protect_user"}
	_test_evaluation_coefficients()
	_test_protection_coefficients()
	_test_target_coefficient()
	CardDB.CARDS = original
	finish()

func _state() -> GameState:
	var s := GameState.new()
	s.set_seed(73)
	s.players = {WHO:{"cards":[]},FOE:{"cards":[]}}
	for who in [WHO,FOE]:
		for _n in 20:
			s.add_card(who,CardDB.unit_id(CardDB.RES_CASH))
		for _n in 5:
			s.add_card(who,CardDB.unit_id(CardDB.RES_USER))
	return s

func _cfg(key: String, value: Variant) -> BOTSearch:
	var c := BOTSearch.default_config()
	c.apply_override(key,value)
	return c

func _test_evaluation_coefficients() -> void:
	var s := _state()
	s.add_card(WHO,"hyper_product")
	s.add_card(WHO,"hyper_product")
	var base := _cfg("upgrade_weight",0.0)
	var heavy := _cfg("upgrade_weight",1.0)
	# 升级和保留生产是替代用途；关闭生产估值后单独核验升级系数。
	base.apply_override("engine_horizon",0.0)
	heavy.apply_override("engine_horizon",0.0)
	var features := Eval.features(s,WHO,base.resolved_parameters())
	var gap := BOTPlan.score(s,WHO,heavy) - BOTPlan.score(s,WHO,base)
	check(float(features["option"]) > 0 and is_equal_approx(gap,float(features["option"])/CardDB.game_rules()["win_cash"]),
		"升级权重在通用评估入口按真实升级增量生效")
	base.apply_override("engine_horizon",10.0)
	heavy.apply_override("engine_horizon",10.0)
	check(is_equal_approx(BOTPlan.score(s,WHO,heavy),BOTPlan.score(s,WHO,base)),
		"生产价值更高时不把同批材料的升级收益重复相加")
	base = _cfg("risk_weight",0.0)
	heavy = _cfg("risk_weight",2.0)
	check(BOTPlan.score(s,WHO,heavy) < BOTPlan.score(s,WHO,base),
		"用户安全权重影响真实排序分，不是仅保存字段")
	var a := _state()
	a.add_card(WHO,"hyper_attack")
	base = _cfg("attack_discount",0.0)
	heavy = _cfg("attack_discount",1.0)
	check(Eval.capacity(a,WHO,base.resolved_parameters()) == 0.0
		and Eval.capacity(a,WHO,heavy.resolved_parameters()) > 0.0,
		"攻击产能折扣直接改变capacity")

func _protected_merit(state: GameState, profile: Dictionary, core: Dictionary, buff: Dictionary) -> float:
	for option in Actions._core_options(state,WHO,core,{},profile):
		if option["uids"].has(buff["uid"]):
			return float(option["merit"])
	return -INF

func _test_protection_coefficients() -> void:
	var s := _state()
	var core := s.add_card(WHO,"hyper_product")
	var buff := s.add_card(WHO,"hyper_protect")
	var low := _cfg("protection_bonus",0.0).resolved_parameters()
	var high := _cfg("protection_bonus",0.5).resolved_parameters()
	var immediate := _protected_merit(s,high,core,buff)
	check(immediate > _protected_merit(s,low,core,buff),
		"新防御牌入组即按保护系数参与实际候选排序")
	buff["armed_round"] = s.round_num + 1 # 旧快照遗留字段不影响当前规则。
	check(is_equal_approx(_protected_merit(s,high,core,buff),immediate),
		"旧装机时间不降低即时保护候选收益")
	check(not high.has("install_bonus"), "即时保护移除废弃装机超参数")

func _test_target_coefficient() -> void:
	var s := _state()
	s.draw_first = FOE # 对方攻击已结束；当前为我方后手攻击。
	for id in ["hyper_attack","hyper_product"]:
		var card := s.add_card(FOE,id)
		var units: Array = []
		for c in s.players[FOE]["cards"]:
			if not c["locked"] and str(c["def_id"]) == CardDB.unit_id(CardDB.RES_USER):
				units.append(c["uid"])
				break
		check(Env_apply(s,Intent.create_combo(FOE,[card["uid"]]+units)), "选靶夹具经真实规则编组")
	var pools := {CardDB.RES_CASH:0,CardDB.RES_USER:int(CardDB.game_rules()["attack_cost_per_card"])}
	var targets := s.affordable_targets(FOE,pools)
	var low := _cfg("spent_attack_discount",0.0)
	var high := _cfg("spent_attack_discount",1.0)
	low.apply_override("target_trials",0)
	high.apply_override("target_trials",0)
	var a: Dictionary = BOTPlan.target_picker(low).call(s,WHO,targets,pools)
	var b: Dictionary = BOTPlan.target_picker(high).call(s,WHO,targets,pools)
	check(a.get("leader","") == "hyper_product" and b.get("leader","") == "hyper_attack",
		"目标选择器使用调用方已开火折扣覆盖，0试算预算走真实的参数化续打策略")

func Env_apply(s: GameState, intent: Dictionary) -> bool:
	return bool(IntentApply.new(s).apply(intent).get("ok",false))
