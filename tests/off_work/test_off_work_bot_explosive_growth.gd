# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## End-to-end acceptance on the losing replay's actual card table. No mocked
## plan choice, free moves, free money, faster recipe, or promoted work capacity.
## Default is the replay's 0.5 strength (700 ms / 6 s); --strength=1 separately
## checks the actual 1,800 ms / 2 s endpoint, without slowing ordinary suites.
const Bot = preload("res://engine/off_work_bot.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")
var fixture: Dictionary
var strength := 0.5
var logic_budget_ms := -1

func _initialize() -> void: _run.call_deferred()

func _config() -> OffWorkConfig:
	var config := OffWorkConfig.new(fixture.cards)
	config.rules.bot=OffWorkConfig.merge_bot_policy(config.rules.bot,
		Preferences.strength_parameters(strength,config.rules.bot,config.bot_preferences))
	# Optional generous budget isolates decision logic from a busy CI host.
	# Real 0.5/1.0 budget acceptance belongs to the benchmark, never this override.
	if logic_budget_ms>0:
		config.rules.bot.erase("decision_budget_ratio")
		config.rules.bot.decision_budget_ms=logic_budget_ms
	return config

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--strength="): strength=float(arg.trim_prefix("--strength="))
		if arg.begins_with("--budget-ms="): logic_budget_ms=int(arg.trim_prefix("--budget-ms="))
	fixture=JSON.parse_string(FileAccess.get_file_as_string("res://tests/off_work/fixtures/recorded_growth_20261109.json"))
	check(strength in [0.5,1.0], "行为回归只使用声明的真实0.5或1.0强度")
	var config := _config()
	var expected_budget := logic_budget_ms if logic_budget_ms>0 else (700 if strength==0.5 else 1800)
	check(OffWorkConfig.decision_budget_ms(config.rules.bot)==expected_budget, "预算与声明一致；逻辑放宽档不冒充真实强度验收")
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		check(config.work_batch_size(kind,800)==1, "录像卡表%s每轮仍只处理1份，不靠改升级容量伪造增长"%kind)
	_dispatch_recorded_purchase()
	_self_sustaining_economy()
	finish()

func _dispatch_recorded_purchase() -> void:
	var world := OffWorkState.new(_config())
	var frame: Dictionary = fixture.frame
	var raw := Marshalls.base64_to_raw(frame.data).decompress(int(frame.size),FileAccess.COMPRESSION_ZSTD)
	var entry: Dictionary = bytes_to_var(raw)
	for key in OffWorkState.WORLD_FIELDS: world.set(key,entry.world[key])
	world._rng.state=entry.rng
	world._invalidate_group_index()
	world.advance(float(fixture.requested_time)-world.time)
	var idle: Array = world.activity_card_ids(1).filter(func(id):
		return world.can_person_work(id) and not world.tasks.has(id) and not world.is_striking(id) and not world.is_meeting_target(id))
	if not need(not idle.is_empty(), "真实128秒快照包含早已付款但仍闲置的员工"): return
	var bot := Bot.new(world,1,world.config.rules.bot,20261110)
	bot.start()
	var before := world.work_count(1)
	var returned := {}
	for turn in 3:
		world.advance(maxf(0.0,bot.next_action_time()-world.time))
		bot._next_think=world.time+float(bot._policy.think_seconds)
		var action: Dictionary = bot.decide_action()
		check(bot.commit_action(action,bot.last_decision), "录像连续决策%d经正式规则执行"%turn)
		for person in idle:
			if world.tasks.get(person,{}).get("kind","")=="work": returned[person]=world.time
		print("GROWTH_DISPATCH ",JSON.stringify({"strength":strength,"time":world.time,"action":action,"returned":returned,
			"evaluation":bot.last_decision.get("evaluation",{}),
			"continuation":bot.last_decision.get("root_continuation",{}),
			"plan":bot.export_decision_context().get("execution_plan",{})}))
	world.advance(float(bot._policy.think_seconds))
	check(returned.size()==idle.size(), "历史闲置员工在三个真实动作槽内确实上工，不再反复承诺下一轮部署")
	check(world.work_count(1)<before, "验证真实工作减少，而非仅生成返岗宏")

func _self_sustaining_economy() -> void:
	var config := _config()
	# The late-game capability arena has existing facilities and a modest
	# bankroll. The PUBLIC supply rule only delivers bosses (both sides already
	# own their one allowed boss). Thus no hidden clearing of valid market
	# arrivals invalidates the evaluator's expected future outsource supply.
	config.rules.initial.groups=[{"employee":5,"grinder":1,"work":800,"overtime":1},{"boss":1},{"slack":1}]
	config.rules.initial.money=25
	config.rules.conveyor.pool={"boss":1}
	var world := OffWorkState.new(config)
	world.new_game(20261110)
	world.drain_events()
	var control := world.fork_for_bot(20261110)
	control._bot_branch=false
	control._rng.state=world._rng.state
	var bot := Bot.new(world,1,config.rules.bot,20261110)
	bot.start()
	var metrics := {"batches":0,"hired":0,"recruitment_spent":0,"slack_batches":0,"coffee":0,
		"consumed":0,"upgrades":0,"rank":0,"wages":0,"work":0,"peak_workers":0,"overruns":0,"failures":0,
		"refunds":0,"purchases_spent":0,"cash_valid":true}
	while true:
		if world.winner<0 and world.time<120.0 and world.time+0.000001>=bot.next_action_time():
			bot._next_think=world.time+float(bot._policy.think_seconds)
			var action: Dictionary = bot.decide_action()
			metrics.overruns+=int(bot.last_decision.get("overrun",false))
			var before_cash := world.money(1)
			metrics.failures+=int(not bot.commit_action(action,bot.last_decision))
			if action.kind=="buy": metrics.purchases_spent+=before_cash-world.money(1)
			print("GROWTH_ECONOMY ",JSON.stringify({"strength":strength,"time":world.time,"action":action,"money":world.money(1)}))
		for event in world.drain_events():
			if int(event.get("owner",-1))!=1: continue
			match str(event.kind):
				"recruitment_complete":
					metrics.batches+=1
					metrics.hired+=int(event.count)
					metrics.recruitment_spent+=int(event.spent)
				"slack_complete":
					metrics.slack_batches+=1
					metrics.coffee+=int(event.amount)
				"coffee_upgrade":
					metrics.upgrades+=1
					metrics.consumed+=int(event.amount)
					metrics.rank=maxi(int(metrics.rank),config.coffee_rank(str(event.to_type)))
				"work_complete":
					metrics.work+=event.ids.size()
					metrics.wages+=int(event.amount)
				"fire": metrics.refunds+=int(event.amount)
		metrics.cash_valid=metrics.cash_valid and world.money(1)>=world.reserved_money(1) \
			and world.money(1)==25+int(metrics.wages)+int(metrics.refunds)-int(metrics.recruitment_spent)-int(metrics.purchases_spent)
		var working := 0
		for person in world.activity_card_ids(1):
			working+=int(world.tasks.get(person,{}).get("kind","")=="work")
		metrics.peak_workers=maxi(int(metrics.peak_workers),working)
		if world.winner>=0 or world.time>=120.0: break
		world.advance(minf(120.0-world.time,minf(0.5,bot.next_action_time()-world.time)))
	control.advance(world.time-control.time)
	metrics["control_remaining_work"]=control.work_count(1)
	metrics["remaining_work"]=world.work_count(1)
	metrics["observed_seconds"]=world.time
	print("GROWTH_ECONOMY_RESULT ",JSON.stringify(metrics))
	check(metrics.failures==0 and metrics.overruns==0, "连续实战决策合法且遵守本档真实预算")
	check(is_equal_approx(world.time,control.time) and world.work_count(1)<control.work_count(1),
		"同初始状态、同真实时钟下净完工收益超过仅自然生产对照，不以招聘或咖啡次数作为目标")
	check(metrics.cash_valid,"招聘与购牌累计支出均由真实初始现金、工资或退款支付，预约资金未透支")
