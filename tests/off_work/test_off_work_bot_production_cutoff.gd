# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Search = preload("res://engine/off_work_bot_search.gd")

# Observe a real completed tail, then cancel the NEXT enumeration operation.
# No fixture supplies scores, forecasts or production commands to the evaluator.
class TailBoundary extends "res://engine/off_work_bot_evaluator.gd":
	static var tail_reached := false
	static var interrupt_tail := false

	func _evaluate_existing(world: OffWorkState, owner: int, policy: Dictionary, until: int, next_actions: Array) -> Dictionary:
		var is_tail := world.time > 6.0
		var value := super._evaluate_existing(world,owner,policy,
			Time.get_ticks_usec()-1 if is_tail and interrupt_tail else until,next_actions)
		if is_tail: tail_reached = true
		return value

func _initialize() -> void:
	_run.call_deferred()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":200},{"leader":1},{"outsource":1},{"slack":1}]
	config.rules.initial.money = 0
	var world := OffWorkState.new(config)
	world.new_game(185)
	world.offers.clear()
	var group: int = world.move_cards(world._owner_type(0,"slack")+world._owner_type(0,"employee"))
	check(group>=0 and world.groups[group].function=="slack", "边界用例通过真实规则启动摸鱼生产")
	return world

func _run() -> void:
	var world := _world()
	for unfinished in [false,true]:
		TailBoundary.tail_reached = false
		TailBoundary.interrupt_tail = unfinished
		var evaluator := TailBoundary.new()
		var ordinary: Dictionary = evaluator.evaluate(world,0,world.config.rules.bot,-1,[0.0,0.0],false)
		var value: Dictionary = evaluator.extend_production(world,0,world.config.rules.bot,-1,[0.0,0.0],ordinary,
			{"kind":"wait"},func(): return TailBoundary.tail_reached)
		check(TailBoundary.tail_reached and not value.production_extension.complete, "精准停止在第一条尾估值之后，后续枚举未完成")
		check(value.complete, "枚举截止不撤销完整可用估值")
		if unfinished:
			check(value.score==ordinary.score and value.detail==ordinary.detail, "尾估值本身未完成时不发布该生产链收益")
		else:
			check(value.score>ordinary.score and value.detail.sides[0].has("production_chain"),
				"后续枚举截止保留此前已完成且胜出的真实生产链")
	TailBoundary.tail_reached = false
	TailBoundary.interrupt_tail = false
	var search := Search.new()
	search.evaluator = TailBoundary.new()
	var published := []
	var result: Dictionary = search.search(world,0,world.config.rules.bot,Time.get_ticks_usec()+700000,
		func(): return TailBoundary.tail_reached,func(row): published.append(row),true,
		func(action): return action.kind=="wait")
	check(result.cutoff and result.root_complete and result.search_nodes==1, "真实搜索先完成普通层，再于第一根候选的后续枚举立即停止")
	check(result.evaluation.sides[0].has("production_chain"), "截止后搜索结果保留已完整计算的链收益")
	check(published.size()>=2 and published.back().evaluation.sides[0].has("production_chain"),
		"发布器先发布普通结果，再保留完成链，截止不会吞掉最后有效发布")
	finish()
