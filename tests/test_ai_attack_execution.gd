# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Env = preload("res://engine/ai_environment.gd")

class ProbeMain extends "res://scenes/main.gd":
	var searches := 0
	func _think_off_thread(job: Callable) -> Variant:
		searches += 1
		return job.call()

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
	await _test_locked_combo_speed()
	finish()

func _test_locked_combo_speed() -> void:
	AISearch.set_pref_model("ai")
	AISearch.set_pref_strength(1.0)
	var actual := GameState.new()
	actual.players = {"player":{"cards":[]}, "ai":{"cards":[]}}
	for who in actual.players:
		for i in 10: actual.add_card(who,"cash")
		for i in 10: actual.add_card(who,"user")
	_add_combo(actual,"ai","chaping")
	var targets := actual.attack_targets("ai").filter(func(t): return t.kind == "combo")
	var hits := targets.size()
	check(hits > 1, "大组合提供多个需要连续拆除的真实配方靶")
	var pools := {CardDB.RES_CASH:0, CardDB.RES_USER:hits * int(CardDB.game_rules()["attack_cost_per_card"])}
	pools[GameState.ATTACK_LOCK] = GameState.target_batch(targets[0])
	var reference := Env.copy(actual)
	var reference_pools := pools.duplicate(true)
	var reference_picker := AIPlan.target_picker(AISearch.prefs(),reference,"player")
	var main := ProbeMain.new()
	var choose := main._live_ai_target_picker()
	for i in hits:
		var target: Dictionary = await choose.call(actual,"player",actual.affordable_targets("ai",pools),pools)
		var expected: Dictionary = reference_picker.call(reference,"player",reference.affordable_targets("ai",reference_pools),reference_pools)
		check(target == expected, "第%d次确定续击与原搜索选择器一致" % (i + 1))
		check(actual.apply_attack("player",target,pools).get("ok",false), "确定续击仍通过真实规则逐张扣牌扣点")
		reference.apply_attack("player",expected,reference_pools)
		actual.check_victory()
		reference.check_victory()
	check(main.searches == 0, "同组合确定续击不反复启动思考线程")
	check(Env.key(actual) == Env.key(reference) and pools == reference_pools, "快速续击与原路径最终状态及点数完全一致")
	pools = {CardDB.RES_CASH:2, CardDB.RES_USER:2}
	await choose.call(actual,"player",actual.affordable_targets("ai",pools),pools)
	check(main.searches == 1, "组合打完后出现不同目标仍通过工作线程比较")
	main.free()
	AISearch.restore_defaults()

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
