# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Growth = preload("res://engine/off_work_bot_growth_plans.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Bot = preload("res://engine/off_work_bot.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_recruitment_reinvestment()
	_continuous_coffee()
	_combined_production()
	_long_and_short_returns()
	_wages_finance_recruitment()
	_deadline_and_cancellation()
	_bounded_evaluation()
	_live_behavior()
	finish()

# These are in-memory scenario rules, not replacements for the game's card
# table. Equal wages isolate productivity from the final outsource shortcut.
func _world(work := 400, boss := true, slack := true, funds := 10) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":work}]
	config.rules.initial.money = funds
	config.rules.bot.think_seconds = 2.0
	config.rules.bot.evaluation_max_seconds = 120.0
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 1000.0
	config.rules.recruitment.cost_per_employee = 5
	config.rules.recruitment.seconds = 10.0
	config.rules.slack.seconds = 6.0
	config.rules.slack.coffee_per_person = 1
	var capacity := 1
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		config.roles[kind].work_capacity = capacity
		config.roles[kind].work_income_multiplier = 1
		capacity *= 2
	var world := OffWorkState.new(config)
	world.new_game(814)
	world.offers.clear()
	if boss: world.add_card("boss",0)
	if slack:
		var tool := world.add_card("slack",0)
		var leader := world.add_card("leader",0)
		# Starting from an operating line checks its continuing value directly;
		# assembling and buying are covered by the ordinary production tests.
		world.move_cards([leader],int(world.cards[tool].group))
	return world

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := []
	for key in OffWorkState.WORLD_FIELDS: fields.append(world.get(key))
	return var_to_bytes([fields,world._rng.state,world._events,world.config.rules,world.config.roles,world.config.cards])

func _plans(world: OffWorkState) -> Array:
	var rows := []
	var before := _snapshot(world)
	var status: Dictionary = Growth.visit(world,0,world.config.rules.bot,-1,[0.0,0.0],func(plan):
		# Visitors may consume checkpoints immediately while a single rollout
		# continues. Retain our own immutable checkpoint for later replay.
		var captured: Dictionary = plan.duplicate(true)
		captured.world = plan.world.fork_search_node()
		rows.append(captured))
	check(status.complete,"持续生产前瞻完成，未把半截计划标作完成")
	check(before==_snapshot(world),"持续生产前瞻不改变原世界、参数或随机流")
	check(rows.all(func(plan): return plan.complete and plan.kind=="sustained_growth"),"只发布可执行的完整持续生产计划")
	return rows

func _people(world: OffWorkState) -> int:
	return world.activity_card_ids(0).filter(func(id): return world.config.can_work(str(world.cards[id].type))).size()

func _ranks(world: OffWorkState) -> int:
	var result := 0
	for id in world.activity_card_ids(0):
		result += maxi(0,world.config.coffee_rank(str(world.cards[id].type)))
	return result

func _most(rows: Array, value: Callable) -> Dictionary:
	var best := {}
	for row in rows:
		if best.is_empty() or value.call(row)>value.call(best): best=row
	return best

func _recruitment_reinvestment() -> void:
	var world := _world(400,true,false,10)
	var rows := _plans(world)
	var plan := _most(rows,func(row): return _people(row.world))
	if not need(not plan.is_empty(),"老板和资金能生成持续招聘计划"): return
	check(_people(plan.world)>5,"新增员工超出初始10元能招的2人，后续工作收入被再投资")
	var replay := _replay(world,plan)
	var batches: Array = replay.events.filter(func(event): return event.kind=="recruitment_complete" and event.owner==0)
	check(batches.size()>=2,"真实重放至少完成两批招聘，不止估算一次招聘")
	var spent := 0
	var recruited := 0
	for batch in batches:
		spent += int(batch.spent)
		recruited += int(batch.count)
	check(spent==recruited*5 and _people(replay.world)==3+recruited,"每个新增员工都由真实招聘支付5元，没有赠送员工")
	check(plan.commands.all(func(command): return command.action.kind!="buy"),"持续招聘不使用未来未知市场员工")

func _continuous_coffee() -> void:
	var world := _world(400,false,true,0)
	var plan := _most(_plans(world),func(row): return _ranks(row.world))
	if not need(not plan.is_empty(),"在产摸鱼能产生持续咖啡升级计划"): return
	check(_ranks(plan.world)>=2,"生产收益跨过第一次升级，覆盖多次或多级升级")
	var replay := _replay(world,plan)
	var batches: Array = replay.events.filter(func(event): return event.kind=="slack_complete" and event.owner==0)
	var upgrades: Array = replay.events.filter(func(event): return event.kind=="coffee_upgrade" and event.owner==0)
	check(batches.size()>=2 and upgrades.size()>=2,"真实重放连续产咖啡并完成至少两次升级")
	var produced := 0
	var consumed := 0
	for batch in batches: produced += int(batch.amount)
	for upgrade in upgrades: consumed += int(upgrade.amount)
	check(produced-consumed==replay.world._owner_type(0,"coffee").size(),"咖啡累计产出减升级消耗等于真实库存，不预支未来咖啡")
	var slow := _world(400,false,true,0)
	slow.config.rules.slack.seconds = 200.0
	var slow_plan := _most(_plans(slow),func(row): return _ranks(row.world))
	check(slow_plan.is_empty() or _ranks(slow_plan.world)==0,"120秒视野内无一批咖啡时不能假造升级收益")

func _combined_production() -> void:
	var world := _world()
	var candidates: Array = _plans(world).filter(func(row): return _people(row.world)>3 and _ranks(row.world)>=2)
	if not need(not candidates.is_empty(),"同一可执行计划串起工资招聘、员工投入生产、咖啡连续升级"): return
	var plan := _most(candidates,func(row): return _people(row.world)+_ranks(row.world))
	var replay := _replay(world,plan)
	check(replay.events.any(func(event): return event.kind=="recruitment_complete" and event.owner==0)
		and replay.events.any(func(event): return event.kind=="coffee_upgrade" and event.owner==0),
		"联合增长的员工与升级都来自真实引擎事件")
	check(replay.world.money(0)>=replay.world.reserved_money(0),"招聘预留资金仍受真实钱包约束，无双重花费")

func _long_and_short_returns() -> void:
	for work in [400,3]:
		var world := _world(work)
		# The entire ordinary finish fits inside this view: the comparison must
		# measure growth rather than the fallback penalty at the view boundary.
		world.config.rules.bot.evaluation_max_seconds = 1800.0
		var before := _snapshot(world)
		var ordinary: Dictionary = Evaluation.new().evaluate(world,0,world.config.rules.bot,-1,[0.0,0.0],false)
		var richer: Dictionary = Evaluation.new().evaluate(world,0,world.config.rules.bot,-1,[0.0,0.0])
		if not need(ordinary.complete and richer.complete,"长短局完整计算同一完工时间指标"): continue
		check(before==_snapshot(world),"增长估值不直接操作真实牌局或改参数")
		var plain_eta: float = ordinary.detail.sides[0].eta
		var growth_eta: float = richer.detail.sides[0].eta
		print("GROWTH_ETA ",JSON.stringify({"work":work,"ordinary":plain_eta,"growth":growth_eta}))
		if work==400:
			check(growth_eta<plain_eta-1e-6,"长期工作下持续招聘与升级确实缩短预计完工时间")
		else:
			check(is_equal_approx(growth_eta,plain_eta),"只剩一个工作批次时维持完工，不为产线给虚假资产加分")
	var cheap := _world(400,true,false,10)
	var expensive := _world(400,true,false,10)
	expensive.config.rules.recruitment.cost_per_employee = 5000
	var cheap_value: Dictionary = Evaluation.new().evaluate(cheap,0,cheap.config.rules.bot,-1,[0.0,0.0])
	var expensive_value: Dictionary = Evaluation.new().evaluate(expensive,0,expensive.config.rules.bot,-1,[0.0,0.0])
	check(cheap_value.complete and expensive_value.complete and cheap_value.detail.sides[0].eta<expensive_value.detail.sides[0].eta,
		"招聘价格改变真实增长回报，付不起的老板不能获得同等收益")

func _wage_world(with_coffee := true) -> OffWorkState:
	var world := _world(400,true,with_coffee,10)
	var wages := 1
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		world.config.roles[kind].work_capacity = 1
		world.config.roles[kind].work_income_multiplier = wages
		wages *= 2
	world.config.rules.bot.evaluation_max_seconds = 1800.0
	return world

func _wages_finance_recruitment() -> void:
	var combined := _wage_world()
	var recruitment := _wage_world(false)
	var plain: Dictionary = Evaluation.new().evaluate(combined,0,combined.config.rules.bot,-1,[0.0,0.0],false)
	var value: Dictionary = Evaluation.new().evaluate(combined,0,combined.config.rules.bot,-1,[0.0,0.0])
	var recruitment_value: Dictionary = Evaluation.new().evaluate(recruitment,0,recruitment.config.rules.bot,-1,[0.0,0.0])
	if not need(plain.complete and value.complete and recruitment_value.complete,"默认升级属性下完整比较工资、招聘与生产链"): return
	print("GROWTH_WAGES_ETA ",JSON.stringify({"ordinary":plain.detail.sides[0].eta,
		"recruitment":recruitment_value.detail.sides[0].eta,"combined":value.detail.sides[0].eta}))
	check(value.detail.sides[0].eta<recruitment_value.detail.sides[0].eta,
		"升级不直接增加工作容量时，咖啡提高工资仍能通过老板招聘缩短完工")
	check(value.detail.sides[0].eta<plain.detail.sides[0].eta,"间接生产力收益进入最终局面估值")
	var chain: Dictionary = value.detail.sides[0].get("production_chain",{})
	check(chain.get("kind","")=="sustained_growth", "默认升级属性的最优续接实际采用持续增长模型")

func _bounded_evaluation() -> void:
	var world := _wage_world()
	# Reuse the installed standard timing and ratio, not a larger test budget.
	world.config.rules.bot.think_seconds = 6.0
	check(OffWorkConfig.decision_budget_ms(world.config.rules.bot)==700,"有限预算回归使用标准700毫秒与6秒行动时钟")
	var before := _snapshot(world)
	var started := Time.get_ticks_usec()
	var value: Dictionary = Evaluation.new().evaluate(world,0,world.config.rules.bot,started+700000,[0.0,0.0])
	var elapsed := Time.get_ticks_usec()-started
	var chain: Dictionary = value.get("detail",{}).get("sides",[{},{}])[0].get("production_chain",{})
	print("GROWTH_BUDGET ",JSON.stringify({"elapsed_ms":elapsed/1000.0,"kind":chain.get("kind",""),
		"eta":value.get("detail",{}).get("sides",[{},{}])[0].get("eta",-1)}))
	check(value.complete and chain.get("kind","")=="sustained_growth","标准预算内持续增长确实进入已发布评价")
	check(before==_snapshot(world),"有限预算的生产预测同样不修改真实对局")

func _live_behavior() -> void:
	# With these default wage-only promotions and a six-second command clock,
	# complete same-lens rollouts prefer recruitment (190s) over combined
	# growth (220s). Requiring coffee here would force a weaker policy.
	var recruitment := _wage_world()
	var recruitment_evidence := _observe_live(recruitment,"wage_recruitment")
	check(recruitment_evidence.recruitment_complete>=2,"默认预算BOT实际重复招聘，后续工资继续投入员工生产")
	# Here promotion directly multiplies throughput and there is no boss:
	# continuous coffee has an independently demonstrated completion payoff.
	var coffee := _world(400,false,true,0)
	coffee.config.rules.bot.evaluation_max_seconds = 1800.0
	var coffee_evidence := _observe_live(coffee,"coffee_productivity")
	check(coffee_evidence.coffee_upgrade>=2,"默认预算BOT实际多次升级，消费持续生产的咖啡")
	var promoted_at_work := coffee.activity_card_ids(0).any(func(id):
		return coffee.config.coffee_rank(str(coffee.cards[id].type))>=2 and coffee.tasks.get(id,{}).get("kind","")=="work")
	check(promoted_at_work,"更高阶人员实际回到工作中，把咖啡生产转为生产力")

func _observe_live(world: OffWorkState, scenario: String) -> Dictionary:
	world.config.rules.bot.think_seconds = 6.0
	world.drain_events()
	var bot := Bot.new(world,0)
	check(OffWorkConfig.decision_budget_ms(bot._policy)==700,"真实BOT在标准700ms内给全部合法根动作分配预算")
	var evidence := {"published_growth":0,"applied":true,"recruitment_complete":0,"coffee_upgrade":0}
	for step in 10:
		var action: Dictionary = bot.decide_action(-1,Callable(),true,func(_action,report):
			var chain: Dictionary = report.get("evaluation",{}).get("sides",[{},{}])[0].get("production_chain",{})
			if chain.get("kind","")=="sustained_growth": evidence.published_growth+=1)
		var selected: Dictionary = bot.last_decision.get("evaluation",{}).get("sides",[{},{}])[0].get("production_chain",{})
		print("GROWTH_LIVE ",JSON.stringify({"scenario":scenario,"time":world.time,"action":action.get("intent",action.kind),
			"chain":selected.get("kind",""),"root_candidates":bot.last_decision.get("root_candidates",0),
			"production_serviced":bot.last_decision.get("root_production_serviced",0),
			"production_complete":bot.last_decision.get("root_production_complete",0),
			"growth_search":bot.last_decision.get("root_growth",{}),
			"elapsed_ms":bot.last_decision.get("elapsed_us",0)/1000.0}))
		evidence.applied = bot.commit_action(action,bot.last_decision) and evidence.applied
		world.advance(6.0)
		world.offers.clear()
		for event in world.drain_events():
			if int(event.get("owner",-1))==0 and event.kind in ["recruitment_complete","coffee_upgrade"]:
				evidence[event.kind]+=1
	print("GROWTH_LIVE_TOTALS ",JSON.stringify(evidence.merged({"scenario":scenario,"work":world.work_count(0),"time":world.time})))
	check(evidence.applied,"生产链的真实BOT动作全部正常提交")
	check(world.work_count(0)<400,"持续生产保留实际工作进展，不将全员停工后一直等待")
	check(evidence.published_growth>0,"持续增长进入真实搜索的已发布方案，未被逐候选预算稀释至不可用")
	return evidence

func _deadline_and_cancellation() -> void:
	var world := _world()
	var rows := []
	var result: Dictionary = Growth.visit(world,0,world.config.rules.bot,Time.get_ticks_usec()-1,[0.0,0.0],func(plan): rows.append(plan))
	check(not result.complete and rows.is_empty(),"已过期预算不能发布未执行的增长计划")
	result = Growth.visit(world,0,world.config.rules.bot,-1,[0.0,0.0],func(plan): rows.append(plan),func(): return true)
	check(not result.complete and rows.is_empty(),"取消请求传到持续生产前瞻")
	var ordinary: Dictionary = Evaluation.new().evaluate(world,0,world.config.rules.bot,-1,[0.0,0.0],false)
	var partial: Dictionary = Evaluation.new().extend_production(world,0,world.config.rules.bot,Time.get_ticks_usec()-1,[0.0,0.0],ordinary)
	check(partial.complete and partial.score==ordinary.score and partial.detail==ordinary.detail,
		"增长预算到期保留已完成的普通评价，不发布半截未来收益")

func _replay(world: OffWorkState, plan: Dictionary) -> Dictionary:
	var actual := world.fork_for_bot(814)
	actual._bot_branch = false
	actual.drain_events()
	var previous := -INF
	var spaced := true
	var legal := true
	var commands_have_money := true
	for command in plan.commands:
		spaced = spaced and float(command.at)>=previous+float(world.config.rules.bot.think_seconds)-1e-8
		actual.advance(world.time+float(command.at)-actual.time)
		legal = Actions.apply_action(actual,0,command.action) and legal
		commands_have_money = commands_have_money and actual.money(0)>=actual.reserved_money(0)
		previous = float(command.at)
	actual.advance(world.time+float(plan.elapsed)-actual.time)
	check(spaced,"持续生产中购买、投资、升级、归队逐一占用行动槽")
	check(legal and commands_have_money,"全部增长命令能由真实规则重放，资金从不透支或重复预留")
	check(_same_state(actual.cards,plan.world.cards) and _same_state(actual.groups,plan.world.groups)
		and _same_state(actual.tasks,plan.world.tasks) and _same_state(actual.recruitment,plan.world.recruitment),
		"实际重放与预测的牌、组堆、任务、招聘批次一致")
	check(is_equal_approx(actual.time,plan.world.time) and actual.money(0)==plan.world.money(0),"实际重放与预测的时间和资金一致")
	return {"world":actual,"events":actual.drain_events()}

func _same_state(a: Variant, b: Variant) -> bool:
	if a is float and b is float: return is_equal_approx(a,b)
	if a is Dictionary and b is Dictionary:
		if a.size()!=b.size(): return false
		for key in a:
			if not b.has(key) or not _same_state(a[key],b[key]): return false
		return true
	if a is Array and b is Array:
		if a.size()!=b.size(): return false
		for index in a.size():
			if not _same_state(a[index],b[index]): return false
		return true
	return a==b
