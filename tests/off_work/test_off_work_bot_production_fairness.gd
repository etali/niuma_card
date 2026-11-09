# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Search = preload("res://engine/off_work_bot_search.gd")

class LocalCutoff extends "res://engine/off_work_bot_evaluator.gd":
	var received: Array = []

	func extend_production(world: OffWorkState, owner: int, policy: Dictionary, until: int,
			next_actions: Array, ordinary: Dictionary, root_action: Dictionary = {}, cancelled: Callable = Callable(),
			production_commitments: Dictionary = {}, _current_only := false) -> Dictionary:
		received.append({"action":root_action.duplicate(true),"until":until,"now":Time.get_ticks_usec()})
		# Model a local task that cannot complete its next indivisible branch.
		# Its existing complete ordinary value must not cancel other tasks.
		var value := ordinary.duplicate(true)
		value.production_extension = {"complete":false,"plans":0,"examined":0}
		return value

class PartialEconomicLayer extends "res://engine/off_work_bot_evaluator.gd":
	var calls := 0
	func _evaluate_existing(world: OffWorkState, owner: int, policy: Dictionary, until: int, clock: Array) -> Dictionary:
		calls+=1
		if calls>1: return {"complete":false}
		var value := super._evaluate_existing(world,owner,policy,until,clock)
		# Deliberately poison one COMPLETE richer value. If its peer is missing,
		# this incompatible layer must never displace any fair current ranking.
		if value.complete: value.score=123456789.0
		return value

class PartialTacticalLayer extends PartialEconomicLayer:
	var tactical_calls := 0
	func evaluate_tactical(world: OffWorkState, owner: int, policy: Dictionary, until: int = -1,
			clock: Array = []) -> Dictionary:
		tactical_calls+=1
		if tactical_calls>1: return {"complete":false}
		var value := super.evaluate_tactical(world,owner,policy,until,clock)
		if value.complete: value.score=987654321.0
		return value

class ObservedLayers extends "res://engine/off_work_bot_search.gd":
	var layers: Array = []
	func _publish_ranking(node: Dictionary, retain_completed := false) -> void:
		layers.append({"layer":result.evaluation_layer,
			"entries":node.ranked.map(func(option): return {
				"mode":option.child.value.get("evaluation_mode","economic"),
				"score":option.child.value.score})})
		super._publish_ranking(node,retain_completed)

func _initialize() -> void:
	_run.call_deferred()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":200},{"leader":1},{"outsource":1},{"slack":1}]
	config.rules.initial.money = 0
	var world := OffWorkState.new(config)
	world.new_game(185)
	world.offers.clear()
	world.move_cards(world._owner_type(0,"slack")+world._owner_type(0,"employee"))
	return world

func _run() -> void:
	_fair_queue()
	_partial_economic_layer()
	_ready_coffee()
	finish()

func _fair_queue() -> void:
	var world := _world()
	world.advance(14.0)
	world.offers.clear()
	var search := Search.new()
	var evaluator := LocalCutoff.new()
	search.evaluator = evaluator
	var seen_before_extension := {"complete":false}
	var result: Dictionary = search.search(world,0,world.config.rules.bot,Time.get_ticks_usec()+700000,Callable(),
		func(row):
			if row.root_complete and evaluator.received.is_empty(): seen_before_extension.complete=true,
		false)
	check(seen_before_extension.complete, "所有普通动作的完整排名在任何生产链扩展前发布")
	check(result.root_complete and result.completed_candidates==result.root_candidates,
		"局部生产截止不会阻止普通合法动作全部评价")
	check(result.root_production_candidates>1 and result.root_production_serviced==result.root_production_candidates
		and evaluator.received.size()==result.root_production_candidates, "每个未剪枝生产候选都被服务，首项局部截止不会饿死后项")
	check(not result.cutoff and result.root_production_complete==0, "局部枚举未完成与全局截止分开记录")
	check(evaluator.received[-1].until>evaluator.received[0].until,
		"未使用时间动态留给后续候选，无固定毫秒上限")

func _partial_economic_layer() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"work":100},{"employee":1},{"coffee":1}]
	config.rules.initial.money=0
	var world := OffWorkState.new(config)
	world.new_game(185)
	world.offers.clear()
	for partial_tactical in [false,true]:
		var search := ObservedLayers.new()
		var evaluator: RefCounted = PartialTacticalLayer.new() if partial_tactical else PartialEconomicLayer.new()
		search.evaluator=evaluator
		var published := []
		var result: Dictionary = search.search(world,0,config.rules.bot,Time.get_ticks_usec()+700000,Callable(),
			func(row): published.append(row.duplicate(true)),false)
		check(evaluator.calls==2 and result.root_economic_completed==1 and result.evaluation_layer!="economic",
			"后续rich候选未完成时整层弃用，不能采用单个rich毒分")
		if partial_tactical:
			check(evaluator.tactical_calls==2 and result.root_tactical_completed==1 and result.evaluation_layer=="current",
				"tactical也只完成首个毒分时整层弃用，保持完整current层")
		else:
			check(result.root_tactical_completed==result.root_candidates and result.evaluation_layer=="tactical",
				"rich失败后允许所有候选完整完成的tactical层整体替换current")
		check(published.all(func(row): return row.candidates.all(func(candidate): return absf(float(candidate.score))<123456789.0)),
			"rich和tactical部分极高分均不混入任何已发布排名")
		check(not search.layers.is_empty() and search.layers.all(func(layer):
			return not layer.entries.is_empty() and layer.entries.all(func(value):
				return value.mode==layer.layer and absf(float(value.score))<123456789.0)),
			"每次完整排名全部候选真实使用同一估值层，不能仅修改诊断字符串过关")

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
	print("PRODUCTION_FAIRNESS ",JSON.stringify({"action":first,"diagnostic":diagnostic}))
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
