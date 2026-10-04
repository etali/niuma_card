# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Env = preload("res://engine/ai_environment.gd")
const Plan = preload("res://engine/ai_turn_plan.gd")
const Cap = preload("res://engine/ai_capabilities.gd")

func _parameters(replies: int, budget: int) -> Dictionary:
	var p := AISearch.from_model("ai",1.0).resolved_parameters()
	p.merge({"replies":replies,"reply_generation_budget":budget,"target_trials":36},true)
	p["_context"] = AIActions.Context.new()
	p["_work"] = [100000]
	return p

func _resources_match(s: GameState, expected: Dictionary) -> bool:
	for who in expected:
		for resource in expected[who]:
			if s.resource_count(who,resource) != int(expected[who][resource]): return false
	return true

func _initialize() -> void:
	CardDB.load_default()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_reply_coverage.json"))
	var s := GameState.new()
	StateCodec.restore(s,fixture.state)
	var before := StateCodec.state_hash(s)
	var p := _parameters(16,2048)
	var actual := Env.copy(s)
	check(Env.replay(actual,fixture.reply_intents),"123004：默认强度实际使用的差评与推送保护回应合法")
	check(actual.combos.any(func(c):return c.owner == "ai" and c.eval.get("protect_user",false)),
		"真实回应确实把用户保护与差评编在同组")
	Env.settle(actual,Plan._target_policy(p))
	check(actual.winner == "" and _resources_match(actual,fixture.settled_resources),
		"真实结算为先手4现金3用户、后手2现金6用户，本回合尚未分胜负")
	var actual_key := Cap.signature(actual)
	var resolved := Plan.resolve_current(s,"player",p)
	check(resolved.complete and not resolved.responses.is_empty(),"16条回应与2048额度完成当前有限回应比较")
	if not resolved.responses.is_empty():
		check(Cap.signature(resolved.responses[0]) == actual_key,
			"实际护盾回应进入已结算池并排在最危险位置，不能只预测无盾生产")
		check(_resources_match(resolved.state,fixture.settled_resources)
			and resolved.score == Plan.settled_score(actual,"player",p),
			"最坏状态的资源与评分来自同一真实护盾结算")
	check(100000-int(p._work[0]) <= int(p.reply_generation_budget),"补齐真实回应仍遵守每根固定计算额度")
	check(StateCodec.state_hash(s) == before,"实际回应重放和搜索比较都不改输入起点")
	# 仅记录旧窄配置的覆盖，今后改进它也不应让回归失败。
	var narrow := Plan.resolve_current(s,"player",_parameters(5,1024))
	var narrow_has_actual: bool = narrow.responses.any(func(r):return Cap.signature(r) == actual_key)
	print("REPLY_COVERAGE narrow_actual=",narrow_has_actual," narrow_count=",narrow.responses.size(),
		" wide_count=",resolved.responses.size()," wide_score=",resolved.score)
	# 这一资源劣势有直接战术含义：下回合轮到持盾方先攻，现有差评就足以清零。
	actual.end_round()
	actual.start_round()
	var ids: Array = []
	for card in actual.players.ai.cards:
		if card.def_id in ["chaping","tuisong","user"]: ids.append(card.uid)
	check(actual.action_first() == "ai" and Env.replay(actual,[Intent.create_combo("ai",ids)]),
		"护盾回应之后对手下一先手无需购买即可再次合法编成差评")
	Settle.attack_phase(actual,"ai",Plan.greedy_target)
	check(actual.winner == "ai" and actual.resource_count("player","user") == 0,
		"真实攻击验证遗漏的回应会在下一回合先攻清空3用户")
	finish()
