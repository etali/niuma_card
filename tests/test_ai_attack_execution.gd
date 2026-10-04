# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Env = preload("res://engine/ai_environment.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	var original := GameState.new()
	original.players = {"player":{"cards":[]}, "ai":{"cards":[]}}
	for seat in original.players:
		for i in 10: original.add_card(seat,"cash")
		for i in 4: original.add_card(seat,"user")
	_add_combo(original,"player","chaping")
	_add_combo(original,"ai","yunketang")
	var simulated := Env.copy(original)
	var visible := Env.copy(original)
	var simulated_targets: Array = []
	var visible_targets: Array = []
	Settle.attack_phase(simulated,"player",_picker(simulated_targets))
	var pipe := LocalTransport.new(IntentApply.new(visible))
	var result: Dictionary = await pipe.round_flow().run_attack_turn("player",Callable(),_picker(visible_targets))
	check(result.get("ok",false),"实际Intent驱动完成合法攻击")
	check(simulated_targets == ["card","combo","combo"],"真实规则允许先点散卡，再用余点拆组合")
	check(visible_targets == simulated_targets,"App攻击驱动不为散卡附加模拟中不存在的同摞锁")
	check(Env.key(simulated) == Env.key(visible),"相同选靶策略在模拟与App驱动产生相同实际状态")
	Settle.produce(simulated)
	Settle.produce(visible)
	check(simulated.resource_count("ai","cash") == 10 and visible.resource_count("ai","cash") == 10,
		"两条路径均真正拆掉云课堂，不能因错误连批放任其生产")
	finish()

func _add_combo(state: GameState, who: String, id: String) -> void:
	var d := CardDB.get_def(id)
	var ids: Array = [state.add_card(who,id).uid]
	for i in int(d.recipe_n): ids.append(state.add_card(who,CardDB.unit_id(d.recipe_res)).uid)
	check(state.create_combo(who,ids).get("ok",false),"实际规则建立测试组合 %s" % id)

func _picker(trace: Array) -> Callable:
	return func(_state: GameState, _who: String, targets: Array, _pools: Dictionary) -> Dictionary:
		var kind := "card" if trace.is_empty() else "combo"
		for target in targets:
			if target.kind == kind:
				trace.append(target.kind)
				return target
		trace.append(targets[0].kind)
		return targets[0]
