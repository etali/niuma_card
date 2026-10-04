# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Env = preload("res://engine/ai_environment.gd")
const Plan = preload("res://engine/ai_turn_plan.gd")
const Cap = preload("res://engine/ai_capabilities.gd")
var fixture: Dictionary

func _initialize() -> void:
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_tactical_coverage.json"))
	var path := "user://tactical_cards.json"
	var f := FileAccess.open(path,FileAccess.WRITE)
	f.store_string(JSON.stringify(fixture.cards))
	f.close()
	CardDB.load_from(path)
	_test_cross_core_defense()
	_test_tactical_coverage()
	finish()

func _state(row: Dictionary) -> GameState:
	var s := GameState.new()
	StateCodec.restore(s,row.state)
	return s

func _fast() -> Dictionary:
	var p := Plan._fast_profile(fixture.parameters)
	p["_context"] = AIActions.Context.new()
	return p

func _settled(s: GameState, p: Dictionary) -> GameState:
	var result := Env.copy(s)
	Env.settle(result,Plan._target_policy(p))
	return result

func _test_cross_core_defense() -> void:
	var row: Dictionary = fixture.samples[1]
	var s := _state(row)
	check(Env.replay(s,row.attack),"跨核心防守对照：补贴攻击经过真实动作裁决")
	var p := _fast()
	var nodes: Array = []
	for recorded in fixture.defense_competitors+fixture.defense_representatives:
		var next := Env.copy(s)
		check(Env.replay(next,recorded.intents),"跨核心防守对照的完整编组可合法重放")
		# 此处使用记录的静态分，只测试有限代表选择，不复制静态估值公式。
		nodes.append({"state":next,"intents":recorded.intents,"rank":float(recorded.rank)})
	var before := nodes.map(func(n):return n.rank)
	var dead: Dictionary = nodes[1]
	var alive: Dictionary = nodes[fixture.defense_competitors.size()]
	check(Cap._node_formation_data(dead,"player").priority == [0,4] and
		Cap._node_formation_data(alive,"player").priority == [1,5],
		"同一防御摘要区分仍可拆的四用户组与配方受保护的三用户组")
	check(_settled(dead.state,p).winner == "ai" and _settled(alive.state,p).winner == "",
		"优先级差异对应真实攻击结果：多用户无盾仍死，云课堂加盾存活")
	var selected := Cap.select(nodes.duplicate(),2,"player","rank",true,p)
	check(selected.size() == 2 and selected[0] == nodes[0],"固定两名额保留原静态最高分普通代表")
	check(selected.any(func(n):return _settled(n.state,p).winner == ""),
		"跨核心优先保留配方能存活的代表，不让较高静态分的无效抗拆占满名额")
	check(nodes.map(func(n):return n.rank) == before,"防守保留不篡改任何静态评分")
	var reversed := nodes.duplicate()
	reversed.reverse()
	var again := Cap.select(reversed,2,"player","rank",true,p)
	check(again.map(func(n):return Cap.signature(n.state)) == selected.map(func(n):return Cap.signature(n.state)),
		"输入次序不改变跨核心防守优先级")
	var disabled := p.duplicate()
	disabled.formation_mode = 0
	var plain := Cap.select(nodes.duplicate(),2,"player","rank",true,disabled)
	check(plain.all(func(n):return n.rank >= float(alive.rank)),"关闭编组能力时不启用新增跨核心防御排序")

func _test_tactical_coverage() -> void:
	var positions: Array = [fixture.actual]+fixture.samples
	for index in positions.size():
		var row: Dictionary = positions[index]
		var label := "实际市场" if index == 0 else "采样市场%d" % (index-1)
		var s := _state(row)
		var original := StateCodec.state_hash(s)
		var p := _fast()
		p["generation_budget"] = int(p.rollout_step_budget)
		p["_work"] = [int(p.rollout_step_budget)]
		var generated := AIActions.generate_with_status(s,"ai",p)
		check(generated.baseline_complete,"%s：有限未来生成先完成基础方案" % label)
		check(generated.nodes.any(func(n):return _settled(n.state,p).winner == "ai"),
			"%s：未来完整候选能表示真实现金融资后的用户清零攻击" % label)
		check(generated.nodes.all(func(n):return absf(float(n.rank)) < AIEvaluator.TERMINAL_SCORE),
			"%s：候选保留不把待回应的攻击直接标为终局胜利" % label)
		check(int(p._work[0]) >= 0 and int(p._work[0]) <= int(p.rollout_step_budget),
			"%s：攻防代表仍共用原有限展开总账" % label)
		var leaf := Env.copy(s)
		check(Env.replay(leaf,row.attack),"%s：同一已持有攻击核心的融资方案不依赖新市场购牌" % label)
		var rp := _fast()
		rp["_work"] = [int(rp.reply_generation_budget)]
		var result := Plan.resolve_current(leaf,"ai",rp)
		check(result.complete,"%s：当前有限防守回应完整完成" % label)
		if index <= 1:
			check(result.responses.all(func(r):return r.winner == "ai") and result.score == AIEvaluator.TERMINAL_SCORE,
				"%s：真实回应仍识别清零败局，不能凭空添加护盾防守" % label)
		else:
			check(result.responses.any(func(r):return r.winner == "" and r.resource_count("player","user") > 0),
				"%s：轻量回应保留合法购盾并组后的真实存活路线" % label)
			check(absf(float(result.score)) < AIEvaluator.TERMINAL_SCORE,
				"%s：补入攻击后仍比较真实防守，不能误报强制必胜" % label)
		check(StateCodec.state_hash(s) == original,"%s：候选与结算不修改输入状态" % label)
