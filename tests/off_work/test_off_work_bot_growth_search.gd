# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Search = preload("res://engine/off_work_bot_search.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_actual_enemy_reply_stays_in_the_world()
	_public_quote_is_exclusive()
	_future_funding_is_paid_in_the_world()
	finish()

func _world(groups: Array = [{"employee":1,"work":80}], funds := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=groups.duplicate(true)
	config.rules.initial.money=funds
	config.rules.conveyor.pool={"employee":1}
	config.rules.conveyor.interval_seconds=10000.0
	config.rules.bot.think_seconds=6.0
	config.rules.bot.evaluation_max_seconds=180.0
	config.rules.bot.search_max_depth=2
	config.rules.bot.search_root_width=4
	config.rules.bot.search_reply_width=4
	config.rules.strike.flight_seconds=0.0
	config.rules.strike.duration_seconds=30.0
	var world := OffWorkState.new(config)
	world.new_game(814)
	world.offers.clear()
	return world

func _search(world: OffWorkState, filter: Callable = Callable()) -> Dictionary:
	var before := var_to_bytes([world.cards,world.groups,world.tasks,world.offers,world.time,world._rng.state])
	# The generic tree must never be enumerated to exhaustion with until=-1.
	var result := Search.new().search(world,0,world.config.rules.bot,Time.get_ticks_usec()+3000000,
		Callable(),Callable(),true,filter)
	check(result.root_coverage_complete and result.short_search_depth==2,
		"有限搜索完成真实根覆盖及对手回应层")
	var status: Dictionary=result.get("root_continuation",{})
	check(status.get("opponent_model","")=="common_first_reply_resource_use_and_paid_physical_tail" \
		and int(status.get("reply_candidates",0))>0 and status.get("incumbent_rechecked",false),"长期树用共同有限回复集，并先在同一模型复核原方案")
	var sides: Array=status.get("sides_evaluated",[0,0])
	check(int(sides[0])>0 and int(sides[1])==0,
		"长期只扩展己方计划，对手来自实际短回应和已付费物理尾")
	check(before==var_to_bytes([world.cards,world.groups,world.tasks,world.offers,world.time,world._rng.state]),
		"完整搜索不消费原局面的资金、报价、工具或随机流")
	return result

func _replay(world: OffWorkState, result: Dictionary) -> OffWorkState:
	var replay := world.fork_for_bot(815)
	# The search fork suppresses event history. This independent rules replay
	# must retain actual wages/payments so the economic certificate is nonempty.
	replay._bot_branch=false
	var period := float(world.config.rules.bot.think_seconds)
	var next := [0.0,period*0.5]
	var clocks_valid := true
	var commands_valid := true
	for command in result.principal_variation:
		var actor := int(command.seat)
		var at := float(command.seconds)-world.time
		var slot := (at-actor*period*0.5)/period
		clocks_valid=clocks_valid and at>=float(next[actor])-1e-8 and is_equal_approx(slot,roundf(slot))
		replay.advance(world.time+at-replay.time)
		commands_valid=Actions.apply_action(replay,actor,command) and commands_valid
		next[actor]=at+period
	check(clocks_valid,"双方命令使用各自真实行动时隙，不把长前缀强行解释成交替一步")
	check(commands_valid,"同一真实状态顺序执行双方全部主变化命令")
	var chain: Dictionary=result.evaluation.sides[0].get("production_chain",{})
	var offset := float(result.forecast_root_offset_seconds)
	var elapsed := float(chain.get("elapsed",offset))
	if not need(elapsed>=replay.time-world.time-1e-8,"估值尾部不早于最后一条真实命令"): return replay
	replay.advance(maxf(0.0,world.time+elapsed-replay.time))
	var clock: Array=chain.get("next_actions",[]).duplicate()
	if clock.is_empty():
		for actor in 2:
			var at := float(next[actor])
			if at<elapsed: at+=ceil((elapsed-at)/period)*period
			clock.append(maxf(0.0,at-elapsed))
	var actual := Evaluation.new().evaluate_current(replay,0,world.config.rules.bot,-1,clock)
	if not need(actual.complete,"真实主变化尾部仍可完整复算统一评价"): return replay
	if actual.detail.terminal:
		var reported := {"terminal":result.evaluation.get("terminal",false),"winner":result.evaluation.get("winner",-1)}
		check(replay.winner==0 and reported==actual.detail,
			"完整主变化实际获胜时，报告终局与赢家严格等于真实统一评价")
		var rows: Array=result.get("candidates",[])
		check(not rows.is_empty() and is_equal_approx(float(rows[0].score),float(actual.score)) \
			and is_equal_approx(float(rows[0].get("tie_score",0.0)),float(actual.get("tie_score",0.0))),
			"报告的终局分数和破同分值来自同一真实终局，不沿用此前ETA评分")
		var completed_at := replay.time-world.time
		check(replay.work_count(0)==0 and is_equal_approx(completed_at,elapsed) \
			and is_equal_approx(completed_at,offset+float(result.evaluation.sides[0].eta)),
			"胜方报告ETA、前缀结束时刻和实际完工时钟完全一致")
		return replay
	if not need(not result.evaluation.get("terminal",false),"未终局的真实重放不能被报告为已完成胜负"): return replay
	for actor in 2:
		var reported := offset+float(result.evaluation.sides[actor].eta)
		var replayed := elapsed+float(actual.detail.sides[actor].eta)
		check(is_equal_approx(reported,replayed),"第%d方根ETA来自同一个可执行世界，不拼接另一棵独立树"%actor)
	return replay

func _actual_enemy_reply_stays_in_the_world() -> void:
	var world := _world([{"employee":3,"work":120},{"employee":1,"work":30}])
	var strike := world.add_card("strike",1)
	var result := _search(world)
	check(result.principal_variation.any(func(step):return int(step.seat)==1 and int(step.get("tool",-1))==strike),
		"长期方案仍保留实际对手罢工，不能在己方增长世界中抹掉攻击")
	var replay := _replay(world,result)
	check(not replay.cards.has(strike) or replay.cards[strike].status!="ready",
		"共同状态真实消耗敌方罢工工具")

func _public_quote_is_exclusive() -> void:
	var world := _world()
	var money := world.add_card("money",1)
	world.cards[money].amount=30
	var quote: Dictionary=world._make_offer("employee")
	world.offers=[quote]
	var result := _search(world,func(action):return action.kind=="wait")
	check(result.action.kind=="wait" and result.principal_variation.any(func(step):
		return int(step.seat)==1 and step.kind=="buy" and int(step.offer)==int(quote.id)),
		"当前没钱的己方等待，对方在真实回应中先支付唯一公开报价")
	var replay := _replay(world,result)
	check(replay.buy(int(quote.id),0)<0 and not replay.offers.any(func(offer):return not offer.is_empty() and int(offer.id)==int(quote.id)),
		"真实共同世界已消费报价，己方后来拿到工资也不能重复购买")
	var own: Dictionary=result.evaluation.sides[0].get("forecast_purchases",{})
	var other: Dictionary=result.evaluation.sides[1].get("forecast_purchases",{})
	check(not own.keys().any(func(id):return other.has(id)),"最终双方尾部不会共享同一公开报价")

func _future_funding_is_paid_in_the_world() -> void:
	var world := _world()
	world.add_card("boss",0)
	var baseline := Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,[0.0,3.0])
	var result := _search(world,func(action):return action.kind=="wait")
	check(world.available_money(0)==0 and result.action.kind=="wait", "零现金局面无法在当前时隙提前支付未来工资")
	var replay := _replay(world,result)
	var events: Array=replay.drain_events()
	var wages := 0
	var paid := 0
	for event in events:
		if int(event.get("owner",-1))!=0: continue
		if event.kind=="work_complete": wages+=int(event.amount)
		if event.kind=="recruitment_complete": paid+=int(event.spent)
	check(paid<=wages and replay.available_money(0)>=0,
		"完整前缀所有已完成招聘由真实工资支付，没有从独立预测搬入现金")
	check(paid>0 and float(result.evaluation.sides[0].eta)+float(result.forecast_root_offset_seconds)<float(baseline.detail.sides[0].eta),
		"工资到账后的实际付费计划确实缩短完工，资金验证不是空等待的恒真断言")
	print("GROWTH_SEARCH_FUNDING ",JSON.stringify({"wages":wages,"paid":paid,"cash":replay.available_money(0),
		"baseline_eta":baseline.detail.sides[0].eta,"chosen_eta":float(result.evaluation.sides[0].eta)+float(result.forecast_root_offset_seconds)}))
