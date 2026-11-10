# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

class ObservedSearch extends "res://engine/off_work_bot_search.gd":
	var observed_seed := {}
	var observed_world: OffWorkState

	func _growth_pass(_root: Dictionary) -> bool:
		growth_reserve_us=0
		return false

	func _continuation_seed(root: Dictionary, action: Dictionary, line: Array, value: Dictionary) -> Dictionary:
		var seed: Dictionary=super._continuation_seed(root,action,line,value)
		if observed_seed.is_empty() and action.kind=="buy" and not seed.replies.is_empty():
			observed_seed=seed.duplicate(true)
			observed_world=root.world.fork_search_node()
		return seed

func _initialize() -> void:
	_run.call_deferred()

func _fixture(with_tool := true, funds := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":200},{"leader":1},{"outsource":1}]
	if with_tool: config.rules.initial.groups.append({"slack":1})
	config.rules.initial.money = funds
	var world := OffWorkState.new(config)
	world.new_game(185)
	world.offers.clear()
	return world

func _run() -> void:
	var world := _fixture()
	var bot := Bot.new(world,0)
	check(OffWorkConfig.decision_budget_ms(bot._policy)==700, "行为回归使用真实默认700毫秒预算")
	var before := Time.get_ticks_usec()
	var action: Dictionary = bot.decide_action()
	print("PRODUCTION_FIRST ",JSON.stringify({"action":action,"depth":bot.last_decision.get("search_depth"),
		"root_complete":bot.last_decision.get("root_complete"),"ms":(Time.get_ticks_usec()-before)/1000.0}))
	check(action.get("intent","") in ["slack","slack_staff"], "有空闲领导与长期工作时，真实BOT选择摸鱼生产链")
	if action.get("intent","") in ["slack","slack_staff"]:
		check(bot.commit_action(action,bot.last_decision), "真实BOT提交组堆命令")
		var generated := false
		var upgraded := false
		var returned := false
		# The bot may fund all three real promotion stages before returning.
		# Allow one minute of the unchanged six-second command clock.
		for index in 10:
			world.advance(float(bot._policy.think_seconds))
			world.offers.clear()
			generated = generated or not world._owner_type(0,"coffee").is_empty()
			action = bot.decide_action()
			check(bot.commit_action(action,bot.last_decision), "生产链下一步通过正常BOT与真实规则提交")
			print("PRODUCTION_STEP ",JSON.stringify({"time":world.time,"action":action,"coffee":world._owner_type(0,"coffee").size(),
				"people":world.activity_card_ids(0).filter(func(id): return world.config.is_person(world.cards[id].type)).map(func(id): return [id,world.cards[id].type,world.tasks.get(id,{})])}))
			for person in world.activity_card_ids(0):
				if not world.config.can_work(str(world.cards[person].type)) or world.config.coffee_rank(str(world.cards[person].type))<=0: continue
				upgraded = true
				returned = returned or world.tasks.get(person,{}).get("kind","") == "work"
			if returned: break
		check(generated and upgraded and returned, "BOT走完产出真实咖啡、升级及返岗，无脚本代办")
	var ordinary: Dictionary = Evaluation.new().evaluate(world,0,bot._policy,-1,[0.0,0.0],false)
	var optional: Dictionary = Evaluation.new().extend_production(world,0,bot._policy,Time.get_ticks_usec()-1,[0.0,0.0],ordinary)
	check(optional.complete and optional.score==ordinary.score and optional.detail==ordinary.detail,
		"扩展预算到期仍保留完整普通ETA，不发布半条链的增益")
	optional = Evaluation.new().extend_production(world,0,bot._policy,-1,[0.0,0.0],ordinary,{},func(): return true)
	check(optional.complete and optional.score==ordinary.score and optional.detail==ordinary.detail,
		"取消传至规则链执行器，仍保留已完成普通估值")
	_purchase_behavior()
	_joint_quote_and_opponent_clock()
	_purchase_survives_reply()
	_search_preserves_purchased_tool()
	finish()

func _purchase_behavior() -> void:
	var world := _fixture(false,5)
	world.offers = [{},{},{},{},{},world._make_offer("slack")]
	var bot := Bot.new(world,0)
	var action: Dictionary = bot.decide_action()
	print("PRODUCTION_BUY ",JSON.stringify({"action":action,"depth":bot.last_decision.get("search_depth")}))
	if not need(action.kind=="buy" and action.get("card_type","")=="slack", "默认700ms BOT愿为真实完整生产链购买当前公开摸鱼"): return
	check(bot.commit_action(action,bot.last_decision) and world.money(0)==0, "购买先支付真实5元，不预支升级后的工资")
	world.advance(6.0)
	world.offers.clear()
	action = bot.decide_action()
	check(action.get("intent","") in ["slack","slack_staff"] and bot.commit_action(action,bot.last_decision),
		"下一真实行动槽才将买来的摸鱼投入生产")

func _joint_quote_and_opponent_clock() -> void:
	var world := _fixture(false,5)
	world.offers = [{},{},{},{},{},world._make_offer("slack")]
	var quote: int = world.offers[-1].id
	var evaluator := Evaluation.new()
	var ordinary: Dictionary = evaluator.evaluate(world,0,world.config.rules.bot,-1,[0.0,0.0],false)
	var projected: Dictionary = evaluator.extend_production(world,0,world.config.rules.bot,-1,[0.0,0.0],ordinary)
	var sides: Array = projected.detail.sides
	check(projected.complete and projected.production_extension.complete, "双方完整生产链前瞻完成")
	check(sides.any(func(side): return side.has("production_chain")), "有利生产链确实进入ETA，竞争用例不是空断言")
	check(not (sides[0].forecast_purchases.has(quote) and sides[1].forecast_purchases.has(quote)),
		"双方不能同时获得同一个公开摸鱼报价")
	for side in 2:
		check(float(sides[side].eta)<=float(ordinary.detail.sides[side].eta)+1e-8,
			"等待生产链不能把对手当作停止操作而抬高其ETA")
		if sides[side].has("production_chain"):
			check(sides[side].production_chain.opponent_assumption.contains("natural events"), "明确披露prefix自然事件假设与对手保守界限")

func _purchase_survives_reply() -> void:
	var world := _fixture(false,5)
	world.offers = [{},{},{},{},{},world._make_offer("slack")]
	var quote: int = world.offers[-1].id
	var tool := world.buy(quote,0)
	check(tool>=0, "深层回归先通过正式规则支付并取得摸鱼")
	var commitments := {tool:0}
	var evaluator := Evaluation.new()
	var ordinary: Dictionary = evaluator.evaluate(world,0,world.config.rules.bot,-1,[6.0,0.0],false)
	var after_buy: Dictionary = evaluator.extend_production(world,0,world.config.rules.bot,-1,[6.0,0.0],ordinary,
		{"kind":"buy","card_type":"slack","actor":0},Callable(),commitments)
	if not need(after_buy.detail.sides[0].has("production_chain"), "买入后的真实闲置摸鱼存在完整组堆续接"): return
	# The opponent's intervening wait advances the real search half-period.
	# The bought UID survives, even though the most recent action is no longer buy.
	world.advance(3.0)
	world.offers.clear()
	ordinary = evaluator.evaluate(world,0,world.config.rules.bot,-1,[3.0,6.0],false)
	var after_reply: Dictionary = evaluator.extend_production(world,0,world.config.rules.bot,-1,[3.0,6.0],ordinary,
		{"kind":"wait","actor":1},Callable(),commitments)
	if not need(after_reply.detail.sides[0].has("production_chain"), "对手wait后更深叶子仍记得已购摸鱼的真实收益"): return
	var first: Dictionary = after_buy.detail.sides[0].production_chain
	var second: Dictionary = after_reply.detail.sides[0].production_chain
	check(first.commands[0].action.kind=="move" and second.commands[0].action.kind=="move"
		and first.commands[0].action.ids.has(tool) and second.commands[0].action.ids.has(tool)
		and first.commands[0].action.ids.size()>1 and second.commands[0].action.ids.size()>1,
		"两层都必须付出真实组堆动作，不能免费开始生产")
	check(is_equal_approx(float(first.commands[0].at),float(second.commands[0].at)+3.0),
		"经过对手回合，组堆仍落在原时钟同一个6秒己方行动槽")
	check(float(after_reply.detail.sides[0].eta)+3.0<=float(after_buy.detail.sides[0].eta)+1e-7,
		"更深层不能丢失同一已付款生产链而倒退到旧估值")

func _search_preserves_purchased_tool() -> void:
	var world := _fixture(false,5)
	world.offers = [{},{},{},{},{},world._make_offer("slack")]
	var search := ObservedSearch.new()
	var observer: WeakRef = weakref(search)
	search.search(world,0,world.config.rules.bot,Time.get_ticks_usec()+5000000,
		func():return not observer.get_ref().observed_seed.is_empty(),Callable(),true,
		func(action):return action.kind=="buy" and action.get("card_type","")=="slack")
	if not need(not search.observed_seed.is_empty(),"真实短搜索产生包含对手回应的购买joint seed"): return
	var seed: Dictionary=search.observed_seed
	var source: OffWorkState=search.observed_world
	var replay := source.fork_search_node()
	var timeline: Array=[]
	for command in seed.commands: timeline.append(command.merged({"actor":0}))
	for command in seed.replies: timeline.append(command.merged({"actor":1}))
	timeline.sort_custom(func(a,b):return float(a.at)<float(b.at))
	var bought := -1
	var legal := true
	for command in timeline:
		replay.advance_for_search(float(command.at)+source.time-replay.time,-1)
		var before: Array=replay._owner_type(0,"slack").duplicate()
		legal=Actions.apply_search_action(replay,int(command.actor),command.action) and legal
		if int(command.actor)==0 and command.action.kind=="buy":
			var added: Array=replay._owner_type(0,"slack").filter(func(id):return not before.has(id))
			if added.size()==1: bought=int(added[0])
	check(legal and bought>=0 and replay.cards.has(bought) and replay.money(0)==0,
		"购买支付真实资金，对手回应之后仍持有同一真实摸鱼UID，未靠测试代填承诺")
	var evidence := {"assembled":false,"first":INF,"replies":false}
	Continuations.visit(source,0,source.config.rules.bot,-1,[0.0,3.0],func(plan):
		evidence.replies=evidence.replies or not plan.replies.is_empty()
		if not plan.world.cards.has(bought): return
		var group: int=plan.world.cards[bought].group
		if plan.world.groups[group].get("function","")!="slack" or plan.world.group_people(group).is_empty(): return
		evidence.assembled=true
		for command in plan.commands.slice(1):
			if command.action.get("ids",[]).has(bought): evidence.first=minf(float(evidence.first),float(command.at)),
		Callable(),{"root_candidates":[seed],"root_action_filter":func(_action):return false,
			"expansion_limit":24,"depth_limit":4})
	check(evidence.assembled and evidence.replies,"统一续搜保留真实对手回应，并从付费UID继续组建摸鱼生产")
	check(is_equal_approx(float(evidence.first),float(seed.next_action)),
		"后续组堆占用原定下个己方行动槽，不能买入或对手回应时免费启动")
