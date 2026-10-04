# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Plan = preload("res://engine/ai_turn_plan.gd")
const Env = preload("res://engine/ai_environment.gd")

func _profile(tactical: int = 1) -> Dictionary:
	var p := Plan.profile(0.5)
	p.merge({"sales":0,"replies":16,"reply_generation_budget":4096,
		"tactical_extension":tactical,"future_reply_limit":2,"reply_mode":1},true)
	p["_context"] = AIActions.Context.new()
	p["_work"] = [100000]
	return p

func _state(own_cash: int, own_users: int, foe_cash: int, foe_users: int) -> GameState:
	var s := GameState.new()
	s.players={"ai":{"cards":[]},"player":{"cards":[]}}
	s.draw_first="ai"
	for who in ["ai","player"]:
		for i in (own_cash if who=="ai" else foe_cash):s.add_card(who,"cash")
		for i in (own_users if who=="ai" else foe_users):s.add_card(who,"user")
	return s

func _keys(states: Array) -> Array:
	return states.map(func(s):return [Env.key(s),s.rng_snapshot(),s.win_reason])

func _compare(s: GameState, label: String, terminal: bool, tactical: int = 1) -> Dictionary:
	var before := StateCodec.state_hash(s)
	var complete_p := _profile(tactical)
	var short_p := _profile(tactical)
	var complete := Plan.resolve_current(s,"ai",complete_p)
	var short := Plan.resolve_current(s,"ai",short_p,true)
	check(complete.complete and short.complete,label+"：完整循环与只读分数调用都完成评价")
	check(var_to_bytes(complete.score)==var_to_bytes(short.score),label+"：提前结束保持评分逐位相等")
	check(complete_p._work[0]==short_p._work[0],label+"：回应生成消耗完全相同，没有退还或赠送节点")
	check(complete.coverage_limited==short.coverage_limited,label+"：候选覆盖标记保持原值")
	if terminal:
		check(short.score==-AIEvaluator.TERMINAL_SCORE and short.evaluations<complete.evaluations,
			label+"：只在确定下界省去后续真实结算")
	else:
		check(absf(short.score)<AIEvaluator.TERMINAL_SCORE and short.evaluations==complete.evaluations
			and _keys(short.responses)==_keys(complete.responses),label+"：非终局危险分不截断")
	var repeated := Plan.resolve_current(s,"ai",short_p)
	check(_keys(repeated.responses)==_keys(complete.responses),label+"：默认入口仍返回全部回应，缓存热度不改变结果")
	check(StateCodec.state_hash(s)==before,label+"：原局面只读")
	print("TERMINAL_CUTOFF ",JSON.stringify({"case":label,"score":short.score,"full":complete.evaluations,
		"score_only":short.evaluations,"generation_work":100000-int(complete_p._work[0])}))
	return short

func _initialize() -> void:
	CardDB.load_default()
	var attack := _state(10,1,10,6)
	attack.add_card("player","chaping")
	var killed := _compare(attack,"攻击清零",true)
	check(killed.state.winner=="player" and killed.state.resource_count("ai","user")==0,
		"攻击下界来自真实用户清零")
	var upgrade := _state(10,1,1,1)
	for i in 8:upgrade.add_card("player","yunketang")
	var cashout := _compare(upgrade,"下一先手冲现",true)
	check(cashout.state.winner=="", "冲现下界没有伪造当前winner")
	var next := Env.copy(cashout.state)
	next.end_round();next.start_round()
	check(next.action_first()=="player" and Env.replay(next,AIActions.winning_pawn(next,"player"))
		and next.winner=="player","下一先手冲现通过真实典当获胜")
	_compare(upgrade,"关闭冲现扩展",false,0)
	var dangerous := _state(1,1,10,8)
	dangerous.add_card("player","yunketang")
	var live := _compare(dangerous,"仍可存活的低分",false)
	check(live.score<0 and live.state.winner=="","低分对照确实不利但未输")
	var insufficient := _profile()
	insufficient._work=[0]
	var unresolved := Plan.resolve_current(attack,"ai",insufficient,true)
	check(not unresolved.complete and unresolved.score==null and unresolved.evaluations==0,
		"只读分数调用也不能跳过回应生成完整性")
	finish()
