# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Continuations = preload("res://engine/off_work_bot_purchase_continuations.gd")

# Observe completed rule-state leaves through the common search path. The
# structural test isolates short plies; the real 700ms BOT case remains below.
class ObservedSearch extends "res://engine/off_work_bot_search.gd":
	var purchase := {}
	var reply := {}
	var assembly := {}

	func _rank(node: Dictionary, root := false) -> bool:
		if root: growth_reserve_us=0
		return super._rank(node,root)

	func _growth_pass(_root: Dictionary) -> bool:
		return false

	func _evaluate(node: Dictionary) -> bool:
		if not super._evaluate(node): return false
		var world: OffWorkState=node.world
		var ids: Array=world._owner_type(0,"union")
		if ids.size()!=1: return true
		var id: int=ids[0]
		var assembled: bool=not world.group_work(int(world.cards[id].group)).is_empty()
		var snapshot := {"id":id,"cash":world.money(0),"time":world.time,"assembled":assembled,
			"mode":node.value.get("evaluation_mode",""),"value":node.value.duplicate(true)}
		if is_equal_approx(world.time,3.0): purchase=snapshot
		elif is_equal_approx(world.time,6.0) and world._owner_type(1,"strike").is_empty() and world.money(1)==7:
			reply=snapshot
		elif is_equal_approx(world.time,9.0) and assembled:
			assembly=snapshot
		return true

# Expire the real evaluator exactly at the first post-assembly leaf. No score
# or synthetic production chain is supplied by the test.
class IncompleteAssembly extends "res://engine/off_work_bot_evaluator.gd":
	var reached := false
	func evaluate_current(world: OffWorkState, owner: int, policy: Dictionary, until: int = -1,
			next_actions: Array = []) -> Dictionary:
		var assembled: bool=world._owner_type(owner,"union").any(func(id):
			return not world.group_work(int(world.cards[id].group)).is_empty())
		if world.time>=9.0 and assembled: reached=true
		return super.evaluate_current(world,owner,policy,Time.get_ticks_usec()-1 if reached else until,next_actions)

# Stop only after reaching the actual tail evaluator. The incomplete variant
# uses its real expired-deadline return, never an injected score or plan.
class TailBoundary extends "res://engine/off_work_bot_evaluator.gd":
	static var reached := false
	static var unfinished := false

	func evaluate_tactical(world: OffWorkState, owner: int, policy: Dictionary, until: int = -1,
			next_actions: Array = []) -> Dictionary:
		var value := super.evaluate_tactical(world,owner,policy,
			Time.get_ticks_usec()-1 if unfinished else until,next_actions)
		reached=true
		return value

func _initialize() -> void:
	_run.call_deferred()

func _fixture() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"work":1000,"employee":2}]
	config.rules.initial.money=1
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.conveyor.pool={"union":1,"strike":1}
	config.cards.union.price=1
	config.cards.employee.refund=0
	config.rules.strike.duration_seconds=90.0
	var world := OffWorkState.new(config)
	world.new_game(17)
	check(config.errors.is_empty() and world.work_count(0)==1000,"公开购买时钟夹具来自合法1000工作卡表")
	check(is_equal_approx(config.rules.strike.flight_seconds,1.2),"公开威胁使用正式默认1.2秒飞行，不延长响应窗口")
	world._credit(1,6)
	world.offers=[world._make_offer("union"),world._make_offer("strike")]
	return world

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := []
	for key in OffWorkState.WORLD_FIELDS: fields.append(world.get(key))
	fields.append(world._rng.state)
	return var_to_bytes(fields)

func _public_defence() -> void:
	var world := _fixture()
	var quote: int = world.offers[1].id
	var group: int = world.cards[world._owner_type(0,"employee")[0]].group
	var bot := Bot.new(world,0)
	check(OffWorkConfig.decision_budget_ms(bot._policy)==700 and is_equal_approx(bot._policy.think_seconds,6.0),
		"公开预防购买使用原有700ms和6秒策略")
	var before := _snapshot(world)
	var action := bot.decide_action()
	check(before==_snapshot(world),"BOT只推演公开报价，不提前购买或改变真实随机流")
	print("PUBLIC_UNION_BUY ",JSON.stringify({"action":action,"depth":bot.last_decision.get("search_depth"),
		"layer":bot.last_decision.get("evaluation_layer"),"elapsed_us":bot.last_decision.get("elapsed_us")}))
	if not need(action.kind=="buy" and action.get("card_type","")=="union",
		"BOT会购买工会预防对手随后购买公开罢工，而非只识别延长飞行的在途威胁"): return
	check(bot.commit_action(action,bot.last_decision) and world.money(0)==0,"t0真实支付工会价格")
	var union: int = world._owner_type(0,"union")[0]
	world.advance(3.0)
	var strike := world.buy(quote,1)
	check(strike>=0 and world.money(1)==0,"t3对手真实支付7元购买罢工")
	check(world.pending_strikes.is_empty(),"购买罢工不能同时免费发射")
	world.advance(3.0)
	world.offers.clear()
	action=bot.decide_action()
	if not need(action.kind=="move" and union in action.get("ids",[]) and action.get("group",-1)==group,
		"t6己方BOT自己选择把工会组装到受威胁工作组"): return
	check(bot.commit_action(action,bot.last_decision),"t6组装由真实规则提交")
	world.advance(3.0)
	check(not world.activate(strike,group),"t9对手的首次合法使用时机已被工会阻止")
	check(world.cards.has(strike) and world.pending_strikes.is_empty(),"被防守后不虚构消耗或在途罢工")

func _paid_world() -> Dictionary:
	var world := _fixture()
	var union := world.buy(int(world.offers[0].id),0)
	check(union>=0 and world.money(0)==0,"续接测试先通过真实购买取得付费UID")
	return {"world":world,"commitments":{union:0},"union":union}

func _tactical_lens_and_tail_cutoff() -> void:
	var paid := _paid_world()
	var world: OffWorkState=paid.world
	var before := _snapshot(world)
	var clock := [6.0,3.0]
	var ordinary: Dictionary=Evaluation.new().evaluate_tactical(world,0,world.config.rules.bot,-1,clock)
	if not need(ordinary.complete and ordinary.get("evaluation_mode","")=="tactical",
		"轻量tactical层返回完整可比较估值"): return
	var attack: Dictionary=ordinary.detail.sides[1].get("forecast_attack",{})
	if not need(not attack.is_empty() and attack.has("offer"),"tactical层识别对手买入后使用的公开罢工"): return
	check(is_equal_approx(float(attack.purchase_at),3.0) and is_equal_approx(float(attack.use_at),9.0),
		"轻量预测为对手购买和使用保留两个真实行动槽")
	for unfinished in [false,true]:
		TailBoundary.reached=false
		TailBoundary.unfinished=unfinished
		var continuation := Continuations.new()
		continuation.tail_evaluator=TailBoundary.new()
		var value: Dictionary=continuation.extend(world,0,world.config.rules.bot,-1,clock,ordinary,
			paid.commitments,func(): return TailBoundary.reached)
		check(TailBoundary.reached and not value.purchase_extension.complete,"在真实尾估值边界精准截断后续枚举")
		check(value.complete,"购买续接被截断时仍返回完整可用incumbent")
		if unfinished:
			check(value.score==ordinary.score and value.detail==ordinary.detail,
				"尾估值本身未完成不能覆盖完整普通估值或发布半条购买链")
		else:
			if not need(value.score>ordinary.score and value.detail.has("purchase_chain"),
				"此前已完整计算的有利组装不能被后续截止丢弃"): continue
			var chain: Dictionary=value.detail.purchase_chain
			check(chain.committed_ids==paid.commitments and chain.commands.size()==1
				and is_equal_approx(float(chain.commands[0].at),6.0),"轻量续接使用原购买UID并在t6实际组装")
			check(chain.replies.size()==1 and chain.replies[0].action.kind=="buy"
				and is_equal_approx(float(chain.replies[0].at),3.0),"组装前真实重放对手t3付款，不把公开威胁当免费现成工具")
		check(before==_snapshot(world),"尾截止与完整方案均不改真实世界或RNG")
	TailBoundary.reached=false
	TailBoundary.unfinished=false

func _paid_identity_survives_reply(unfinished := false) -> void:
	var world := _fixture()
	var before := _snapshot(world)
	var search := ObservedSearch.new()
	var tail := IncompleteAssembly.new()
	if unfinished: search.evaluator=tail
	var observer: WeakRef=weakref(search)
	var published := []
	# A real root buy is followed by enemy t3 and own t6. Each leaf is observed
	# after its normal half-period advance, at t3, t6 and t9 respectively.
	var result: Dictionary=search.search(world,0,world.config.rules.bot,Time.get_ticks_usec()+5000000,
		func(): return not observer.get_ref().assembly.is_empty(),func(row):published.append(row),true,
		func(action): return action.kind=="buy" and action.get("card_type","")=="union")
	if not need(not search.purchase.is_empty() and not search.reply.is_empty(),
		"通用Search真实执行根购买与对手wait，付费UID来自规则状态"): return
	check(search.purchase.id==search.reply.id and search.purchase.cash==0 and search.reply.cash==0,
		"跨对手回复保留同一付费UID和已付金额，不重复购买或退回现金")
	check(not search.purchase.assembled and not search.reply.assembled 		and search.purchase.time==3.0 and search.reply.time==6.0,
		"t0买入后等待己方t6行动槽，不能在对手t3回复时免费组装")
	check(search.purchase.mode=="current" and search.reply.mode=="current" and result.evaluation_layer=="current",
		"购买与对手回复都使用统一完工评价，不继承已取消的卡种专属层")
	if unfinished:
		check(tail.reached and search.assembly.is_empty() and result.cutoff and result.short_search_depth==2,
			"t6后续动作的真实尾估值截止时，保留已完成的两步短层")
		check(not published.is_empty() and result.evaluation==published.back().evaluation 			and result.principal_variation==published.back().principal_variation 			and result.principal_variation.size()==2,
			"未完成组装叶不能发布收益或覆盖最后完整购买/回应前缀")
	else:
		check(not search.assembly.is_empty() and search.assembly.id==search.purchase.id 			and search.assembly.time==9.0 and search.assembly.mode=="current" 			and search.assembly.value.complete,
			"通用后续搜索在t6真实组装原付费UID，并完整评价其t9规则状态")
	check(before==_snapshot(world),"完整与截止后续搜索均不修改真实牌桌或随机流")

func _run() -> void:
	_public_defence()
	_tactical_lens_and_tail_cutoff()
	_paid_identity_survives_reply()
	_paid_identity_survives_reply(true)
	finish()
