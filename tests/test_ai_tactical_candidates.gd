# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Env = preload("res://engine/ai_environment.gd")
const Cap = preload("res://engine/ai_capabilities.gd")
const Plan = preload("res://engine/ai_turn_plan.gd")
var fixture: Dictionary

func _initialize() -> void:
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_tactical_coverage.json"))
	var path := "user://tactical_candidates_cards.json"
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(fixture.cards))
	file.close()
	CardDB.load_from(path)
	_test_payment_and_cache()
	_test_holding_protection()
	_test_independent_switch()
	finish()

func _state(row: Dictionary) -> GameState:
	var state := GameState.new()
	StateCodec.restore(state,row.state)
	return state

func _profile() -> Dictionary:
	var p := Plan._fast_profile(fixture.parameters)
	p["_context"] = AIActions.Context.new()
	return p

func _node(state: GameState, intents: Array, rank := 0.0) -> Dictionary:
	return {"state":state,"intents":intents,"rank":rank}

func _test_payment_and_cache() -> void:
	var state := _state(fixture.actual)
	var before := StateCodec.state_hash(state)
	var p := _profile()
	var original := _node(state,[])
	check(int(Cap._holding_tactics(original,"ai",p).attack_user) == 0,
		"配方现金不足的攻击核心不会被摘要当成可支付攻击")
	var financed := Env.copy(state)
	var sale: Array = [fixture.actual.attack[0]]
	check(Env.replay(financed,sale),"真实典当提供攻击所需的现金融资")
	var node := _node(financed,sale)
	var financed_before := StateCodec.state_hash(financed)
	var tactics := Cap._holding_tactics(node,"ai",p)
	check(int(tactics.attack_user) == 4,"融资后的共享常规配方与真实装弹识别四用户攻击")
	check(Cap._holding_tactics(node,"ai",p) == tactics and StateCodec.state_hash(financed) == financed_before,
		"重复摘要读取缓存，原持牌节点不被建组或扣费修改")
	var completed := Env.copy(state)
	check(Env.replay(completed,fixture.actual.attack),"攻击完整动作经过真实规则裁决")
	var complete_node := _node(completed,fixture.actual.attack)
	var completed_before := StateCodec.state_hash(completed)
	check(AIActions.attack_pools(complete_node,"ai").user == 4 and StateCodec.state_hash(completed) == completed_before,
		"完整攻击代表在副本装弹，原节点现金及已开火标记保持不变")
	var switched := p.duplicate()
	switched.tactical_extension = 0
	switched.formation_mode = 0
	check(Cap._holding_tactics(node,"ai",switched).values().all(func(v):return v == 0),
		"关闭能力后不复用先前开启时的战术摘要")
	check(StateCodec.state_hash(state) == before,"原始录像状态在所有摘要计算后保持一致")

func _test_holding_protection() -> void:
	var p := _profile()
	for index in [1,2]:
		var row: Dictionary = fixture.samples[index]
		var state := _state(row)
		check(Env.replay(state,row.attack),"采样%d先真实提交攻击，再比较回应持牌" % index)
		var ordinary := _node(state,[],100.0)
		var defense := Env.copy(state)
		var prefix: Array = []
		for intent in row.defenses[0]:
			if intent.op == "create_combo": break
			prefix.append(intent)
		check(Env.replay(defense,prefix),"采样%d护盾融资购买前缀合法" % index)
		var guarded := _node(defense,prefix,-100.0)
		check(int(Cap._holding_tactics(guarded,"player",p).guard_user) > 0,
			"采样%d识别实际可组且可支付的用户护盾能力" % index)
		var selected := Cap._select_holdings([ordinary,guarded],1,"player",p)
		check(selected.has(ordinary) and selected.has(guarded),
			"采样%d护盾代表与普通最高分并集，不被材料规模名额或静态分挤掉" % index)
		check(selected.size() <= 5 and guarded.rank == -100.0 and ordinary.rank == 100.0,
			"采样%d持牌额外代表有界，且保留不篡改分数" % index)
		var plain := p.duplicate()
		plain.formation_mode = 0
		plain.tactical_extension = 0
		check(Cap._select_holdings([ordinary,guarded],1,"player",plain) == [ordinary],
			"采样%d关闭两种能力后仍遵守原持牌宽度" % index)

func _test_independent_switch() -> void:
	var state := _state(fixture.actual)
	check(Env.replay(state,[fixture.actual.attack[0]]),"独立开关对照从已合法融资的同一持牌开始")
	var p := _profile()
	for key in ["financing_mode","resale_mode","allocation_mode","formation_mode","candidate_dedup","tactical_extension"]:
		p[key] = 0
	p["generation_budget"] = 2048
	var basic := AIActions.generate_with_status(state,"ai",p)
	p.tactical_extension = 1
	var result := AIActions.generate_with_status(state,"ai",p)
	check(result.baseline.map(func(n):return Cap.signature(n.state)) == basic.nodes.map(func(n):return Cap.signature(n.state)),
		"仅开启战术覆盖也保持基础层原有方案和顺序")
	check(result.generation_stages.size() == 1 and result.generation_stages[0].financing_mode == 0,
		"独立战术开关建立单独扩展阶段，不冒用基础层标签")
	check(result.generation_stages[0].holdings > 0 and result.generation_stages[0].tactical_candidates >= 0 and result.generation_stages[0].tactical_candidates <= 2,
		"阶段诊断记录实际编组来源及最多两个追加攻击代表")
	check(result.nodes.all(func(n):return n.get("baseline",false) == (int(n.generation_stage) == 0)),
		"战术扩展只标所属生成阶段，基础深化保护不被污染")
	check(result.nodes.size() <= result.baseline.size()+int(p.plans)+2,
		"单个战术阶段最多追加普通plans与现金用户各一个攻击代表")
	check(result.nodes.any(func(n):return int(AIActions.attack_pools(n,"ai").user) > 0),
		"仅开启战术参数亦能保留真实可支付用户攻击")
