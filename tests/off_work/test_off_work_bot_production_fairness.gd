# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Search = preload("res://engine/off_work_bot_search.gd")

class ObservedEvaluation extends "res://engine/off_work_bot_evaluator.gd":
	var rows: Array = []
	var stop_after := -1
	func evaluate_current(world: OffWorkState, owner: int, policy: Dictionary, until: int = -1,
			clock: Array = []) -> Dictionary:
		if stop_after>=0 and rows.size()>=stop_after:
			# An unfinished calculation may carry transient values. None of them
			# is comparable to a completed candidate from this same ETA model.
			return {"complete":false,"score":123456789.0,"tie_score":99999.0}
		var value: Dictionary=super.evaluate_current(world,owner,policy,until,clock)
		if value.get("complete",false): rows.append({"time":world.time,"clock":clock.duplicate(),"score":value.score})
		return value

func _initialize() -> void: _run.call_deferred()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":3,"work":200},{"leader":1},{"outsource":1},{"slack":1}]
	config.rules.initial.money=0
	var world := OffWorkState.new(config)
	world.new_game(185)
	world.offers.clear()
	world.move_cards(world._owner_type(0,"slack")+world._owner_type(0,"employee"))
	return world

func _run() -> void:
	_same_clock_root_coverage()
	_incomplete_candidate_is_not_a_score()
	_ready_coffee()
	finish()

func _same_clock_root_coverage() -> void:
	var world := _world()
	world.advance(14.0)
	world.offers.clear()
	var evaluator := ObservedEvaluation.new()
	var search := Search.new()
	search.evaluator=evaluator
	var publications := []
	var result: Dictionary=search.search(world,0,world.config.rules.bot,Time.get_ticks_usec()+700000,Callable(),
		func(row):publications.append(row.duplicate(true)),false)
	check(result.root_complete and result.root_coverage_complete and result.completed_candidates==result.root_candidates,
		"只运行共同根评价时覆盖所有普通合法动作，包含已产出咖啡的后置动作")
	check(evaluator.rows.size()==result.root_candidates and evaluator.rows.size()>1,
		"根覆盖计数对应实际完成的统一评价，而不是候选初始化次数")
	var half := float(world.config.rules.bot.think_seconds)*0.5
	check(evaluator.rows.all(func(row):return is_equal_approx(float(row.time),world.time+half) and row.clock==[half,0.0]),
		"所有根动作都从同一半周期状态和双方下次行动钟进行比较")
	var same_values := not publications.is_empty()
	for row in publications:
		same_values=same_values and row.evaluation_layer=="current"
		for candidate in row.candidates:
			var matched := false
			for value in evaluator.rows:
				matched=matched or absf(float(value.score)-float(candidate.score))<0.000001
			same_values=same_values and matched
	check(same_values,
		"所有已发布分数都来自同口径已完成ETA，不混入探索优先级或私有生产路线分数")
	check(result.root_evaluated_intents.has("coffee") and result.root_evaluated_intents.has("split_work"),
		"当前咖啡升级与返岗均实际获评，不被等待动作提前终止")

func _incomplete_candidate_is_not_a_score() -> void:
	var world := _world()
	var evaluator := ObservedEvaluation.new()
	evaluator.stop_after=1
	var search := Search.new()
	search.evaluator=evaluator
	var publications := []
	var result: Dictionary=search.search(world,0,world.config.rules.bot,Time.get_ticks_usec()+700000,Callable(),
		func(row):publications.append(row.duplicate(true)),false)
	check(result.cutoff and result.completed_candidates==1 and result.root_candidates>1
		and not result.root_complete and not result.root_coverage_complete,
		"一个前缀算完但第二个中断时明确保留未覆盖根状态")
	check(result.has("action") and not publications.is_empty(),"后续截止不会撤销已有的合法动作及完整评价")
	check(publications.all(func(row):return not row.root_complete and row.candidates.all(func(candidate):
		return absf(float(candidate.score)-float(evaluator.rows[0].score))<0.000001)),
		"未完成候选的极高临时分数不会进入任何排名或替换已完成结果")

func _ready_coffee() -> void:
	var world := _world()
	# Twenty real batches create 60 cups while three workers stay on slack.
	# This reproduces the observed stockpile without injecting coffee rewards.
	world.advance(280.0)
	world.offers.clear()
	check(world._owner_type(0,"coffee").size()>=60, "通过真实摸鱼规则积累大量咖啡")
	var bot := Bot.new(world,0)
	var first: Dictionary = bot.decide_action()
	var diagnostic: Dictionary = bot.last_decision
	print("PRODUCTION_FAIRNESS ",JSON.stringify({"action":first,"elapsed_us":diagnostic.get("elapsed_us",0),
		"coverage":diagnostic.get("root_coverage_complete",false),"candidates":diagnostic.get("root_candidates",0),
		"completed":diagnostic.get("completed_candidates",0),"intents":diagnostic.get("root_evaluated_intents",{}),
		"continuation":diagnostic.get("root_continuation",{})}))
	check(diagnostic.root_complete and diagnostic.completed_candidates==diagnostic.root_candidates,
		"真实默认700ms多咖啡局面先覆盖全部普通候选")
	check(diagnostic.root_evaluated_intents.has("coffee") and diagnostic.root_evaluated_intents.has("split_work"),
		"后置升级与返岗动作均获得评价，不被首个wait生产链吞预算")
	check(first.get("intent","")=="coffee" and bot.commit_action(first,diagnostic), "大量现成咖啡时BOT主动开始真实升级，不持续等待")
	var returned := false
	for index in 10:
		world.advance(6.0)
		world.offers.clear()
		var action: Dictionary = bot.decide_action()
		check(bot.commit_action(action,bot.last_decision), "积杯局面后续BOT命令通过正式规则")
		for person in world.activity_card_ids(0):
			if world.config.coffee_rank(str(world.cards[person].type))>0 and world.tasks.get(person,{}).get("kind","")=="work": returned=true
		if returned: break
	check(returned, "积杯局面真实完成升级并把更高阶员工送回工作")
