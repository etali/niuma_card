# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## Economic certificates, not a required production recipe. Every comparison
## starts from the same recorded card table and explicitly declared fixture.
## A longer plan must buy earlier completion with real payments and worker
## time; counts, salaries, ranks and inventory are never success criteria.
## This bounded logical test is separate from real-budget BOT benchmarks.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
var fixture: Dictionary
var recorded_cards: Dictionary

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	fixture=JSON.parse_string(FileAccess.get_file_as_string("res://tests/off_work/fixtures/long_return_objective_20261110.json"))
	recorded_cards=JSON.parse_string(FileAccess.get_file_as_string(fixture.base_cards_fixture)).cards
	print("LONG_RETURN_SCOPE bounded logical certification; not a production-budget benchmark")
	if OS.get_cmdline_user_args().has("--horizon-only"):
		_horizon_tail_certificates()
		finish()
		return
	_near_finish()
	_zero_return_upgrade()
	if OS.get_cmdline_user_args().has("--negative-roots-only"):
		finish()
		return
	_expensive_slow_recruitment()
	for name in ["long_800","long_2000"]: _positive_reinvestment(name)
	_horizon_tail_certificates()
	finish()

func _world(name: String) -> OffWorkState:
	var spec: Dictionary=fixture.cases[name]
	var config := OffWorkConfig.new(recorded_cards)
	var working: Dictionary=spec.staff.duplicate(true)
	working.work=int(spec.work)
	if spec.has("overtime"): working.overtime=int(spec.overtime)
	config.rules.initial.groups=[working,{"boss":1}]
	for kind in ["coffee","outsource"]:
		if int(spec.get(kind,0))>0: config.rules.initial.groups.append({kind:int(spec[kind])})
	config.rules.initial.money=int(spec.money)
	config.rules.conveyor.pool=fixture.public_supply.duplicate(true)
	config.rules.bot.think_seconds=float(fixture.think_seconds)
	config.rules.bot.evaluation_max_seconds=float(fixture.evaluation_max_seconds)
	if spec.has("all_work_income_multiplier"):
		for kind in ["employee","grinder","workaholic","work_emperor"]:
			config.roles[kind].work_income_multiplier=float(spec.all_work_income_multiplier)
	if spec.has("recruitment_cost"): config.rules.recruitment.cost_per_employee=int(spec.recruitment_cost)
	if spec.has("recruitment_seconds"): config.rules.recruitment.seconds=float(spec.recruitment_seconds)
	var world := OffWorkState.new(config)
	world.new_game(int(fixture.seed))
	if not need(config.errors.is_empty(),"%s夹具通过正式卡表校验"%name): return world
	var other: Array=[]
	for person in world.activity_card_ids(1):
		if world.can_person_work(person): other.append(person)
	check(world.move_cards(other,-1)>=0,"%s对方保持静止，只认证本方完工时间"%name)
	world.drain_events()
	return world

func _work_group(world: OffWorkState) -> int:
	return int(world.cards[world._owner_type(0,"work")[0]].group)

func _move(ids: Array, group := -1, intent := "certificate") -> Dictionary:
	return {"kind":"move","ids":ids,"group":group,"intent":intent}

func _apply(world: OffWorkState, action: Dictionary, at: float, commands: Array) -> bool:
	var period: float=fixture.think_seconds
	var legal_clock := is_equal_approx(at/period,roundf(at/period)) \
		and (commands.is_empty() or at>=float(commands[-1].at)+period-1e-8)
	if not legal_clock or at<world.time-1e-8: return false
	world.advance(at-world.time)
	if not Actions.apply_action(world,0,action): return false
	commands.append({"at":at,"action":action.duplicate(true)})
	return true

func _eta(world: OffWorkState, next := 0.0) -> float:
	if world.winner>=0: return world.time if world.winner==0 else INF
	var value: Dictionary=Evaluation.new().evaluate_current(world,0,world.config.rules.bot,
		Time.get_ticks_usec()+5000000,[next,1.0])
	if not need(value.get("complete",false),"统一当前完工评价完成（逻辑预算）"): return INF
	return world.time+float(value.detail.sides[0].eta)

func _finish(world: OffWorkState, commands: Array, eta: float) -> Dictionary:
	world.advance(float(fixture.evaluation_max_seconds))
	var result := {"time":world.time,"winner":world.winner,"remaining":world.work_count(0),"eta":eta,
		"work":0,"outsource_work":0,"wages":0,"spent":0,"hired":0,"recruited_work":0,"upgrades":0,"commands":commands}
	var hired := {}
	for event in world.drain_events():
		if int(event.get("owner",-1))!=0: continue
		match str(event.kind):
			"work_complete":
				result.work+=event.ids.size()
				result.wages+=int(event.amount)
				for person in event.get("participants",[]): result.recruited_work+=int(hired.has(person))
			"recruitment_complete":
				result.spent+=int(event.spent)
				result.hired+=int(event.count)
				for person in event.person_ids: hired[person]=true
			"coffee_upgrade": result.upgrades+=1
			"outsource": result.outsource_work+=int(event.amount)
	result.completed_work=int(result.work)+int(result.outsource_work)
	check(result.winner==0 and result.remaining==0,"真实规则推进到本方完成，不把预测ETA充作实际结果")
	check(absf(float(result.time)-eta)<0.00001,"该证书统一ETA与实际规则完工时刻一致，未把未兑现资产算作收益")
	return result

func _upgrade_route(name: String) -> Dictionary:
	var world := _world(name)
	var commands: Array=[]
	var person: int=world._owner_type(0,"employee")[0]
	var target := _work_group(world)
	check(_apply(world,_move([person]+world._owner_type(0,"coffee"),-1,"coffee"),0.0,commands),
		"升级真实拆出工作人员并占用行动时隙")
	var started_eta := _eta(world,2.0)
	check(_apply(world,_move([person],target,"staff"),6.0,commands),"升级后在第一个合法2秒时隙返岗")
	check(world.cards[person].type=="grinder" and world._owner_type(0,"coffee").is_empty(),"升级实际消耗咖啡并改变人员牌型")
	return _finish(world,commands,started_eta)

func _near_finish() -> void:
	var direct := _world("near_finish")
	var baseline := _finish(direct,[],_eta(direct))
	var upgrade := _upgrade_route("near_finish")
	print("LONG_RETURN_NEAR_FINISH ",JSON.stringify({"direct":_summary(baseline),"upgrade":_summary(upgrade)}))
	check(upgrade.time>baseline.time and upgrade.eta>baseline.eta,
		"最后一份工作时即使升级提高工资，真实停工和统一ETA都比直接完工更差")
	_compare_continuation_roots("near_finish")

func _zero_return_upgrade() -> void:
	var direct := _world("coffee_zero_return")
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		check(direct.config.work_batch_size(kind,80)==1 and direct.config.roles[kind].work_income_multiplier==1.0,
			"零收益变体%s没有容量或工资提升"%kind)
	var baseline := _finish(direct,[],_eta(direct))
	var upgrade := _upgrade_route("coffee_zero_return")
	print("LONG_RETURN_ZERO_COFFEE ",JSON.stringify({"direct":_summary(baseline),"upgrade":_summary(upgrade)}))
	check(upgrade.time>baseline.time and upgrade.eta>=baseline.eta,
		"无工资容量收益的咖啡升级不能靠人物等级加分抵消真实停工")
	_compare_continuation_roots("coffee_zero_return")

func _compare_continuation_roots(name: String) -> void:
	var world := _world(name)
	var person: int=world._owner_type(0,"employee")[0]
	var actions := [{"kind":"wait","intent":"wait"},_move([person]+world._owner_type(0,"coffee"),-1,"coffee")]
	var seeds: Array=[]
	var best := [INF,INF]
	var visited := {}
	for index in actions.size():
		var branch := world.fork_for_bot(int(fixture.seed))
		check(Actions.apply_search_action(branch,0,actions[index]),"负例根动作经真实规则验证")
		branch.advance_for_search(1.0,-1)
		var value: Dictionary=Evaluation.new().evaluate_current(branch,0,world.config.rules.bot,-1,[1.0,0.0])
		seeds.append({"action":actions[index],"value":value,"elapsed":1.0,"next_actions":[1.0,0.0]})
		best[index]=1.0+float(value.detail.sides[0].eta)
	var status: Dictionary=Continuations.visit(world,0,world.config.rules.bot,Time.get_ticks_usec()+5000000,[0.0,1.0],func(plan):
		var index: int=plan.growth.root_index
		# Seeding reuses already evaluated actions; it does not remove other
		# legal root choices from the universal planner.
		if index<0 or index>=best.size(): return
		visited[index]=true
		var eta: float=plan.elapsed
		if not plan.evaluation.detail.get("terminal",false): eta+=float(plan.evaluation.detail.sides[0].eta)
		elif int(plan.evaluation.detail.get("winner",-1))!=0: eta=INF
		best[index]=minf(best[index],eta),Callable(),{"root_candidates":seeds,"expansion_limit":18,"depth_limit":3})
	print("LONG_RETURN_NEGATIVE_ROOTS ",JSON.stringify({"case":name,"best_wait":best[0],"best_upgrade":best[1],"status":status}))
	check(status.root_serviced>=2 and visited.size()==2,"两个负例首步使用同一续搜机制和完工指标，其余合法根仍可探索")
	check(best[0]<=best[1]+1e-8,"续搜没有给无回本的咖啡路线单独加分；允许随时取消错误投资")

func _expensive_slow_recruitment() -> void:
	var direct := _world("expensive_slow_recruitment")
	var target := _work_group(direct)
	var commands: Array=[]
	check(_apply(direct,_move(direct._owner_type(0,"outsource")+direct._owner_type(0,"money")+direct._owner_type(0,"work"),-1,"outsource"),0.0,commands),
		"短尾现金按真实每份价格直接外包")
	var baseline := _finish(direct,commands,_eta(direct,2.0))
	var recruit := _world("expensive_slow_recruitment")
	commands=[]
	check(_apply(recruit,_move(recruit._owner_type(0,"boss")+recruit._owner_type(0,"money"),-1,"recruitment"),0.0,commands),
		"昂贵招聘真实锁定100钱，未将其同时用于外包")
	check(recruit.reserved_money(0)==100 and recruit.available_money(0)==0,"招聘机会成本进入真实可用现金")
	var bad_eta := _eta(recruit,2.0)
	recruit.advance(120.0)
	var idle: Array=recruit._owner_type(0,"employee").filter(func(id):return not recruit.tasks.has(id))
	check(_apply(recruit,_move(idle,target,"staff"),120.0,commands),"等待昂贵慢招聘真实结束后才部署新员工")
	# Finish with the same existing outsource tool as soon as this branch can
	# actually fund it; this gives the bad branch its best immediate cash-out.
	while recruit.winner<0 and recruit.available_money(0)<recruit.work_count(0): recruit.advance(2.0)
	if recruit.winner<0:
		var at: float=maxf(122.0,ceilf(recruit.time/2.0)*2.0)
		check(_apply(recruit,_move(recruit._owner_type(0,"outsource")+recruit._owner_type(0,"money")+recruit._owner_type(0,"work"),-1,"outsource"),at,commands),
			"招聘分支仍享有同一实际可支付外包机会")
	var invested := _finish(recruit,commands,bad_eta)
	print("LONG_RETURN_BAD_RECRUIT ",JSON.stringify({"direct":_summary(baseline),"recruit":_summary(invested)}))
	check(invested.time>baseline.time and invested.eta>baseline.eta,
		"贵慢招聘即使真实增加员工也不能胜过已可支付的直接完成")

func _positive_reinvestment(name: String) -> void:
	var direct := _world(name)
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		check(direct.config.work_batch_size(kind,int(fixture.cases[name].work))==1,"%s%s仍每轮一份工作"%[name,kind])
	var baseline := _finish(direct,[],_eta(direct))
	var routes: Array=[]
	for upgrade_first in [false,true]: routes.append(_reinvest_route(name,upgrade_first))
	print("LONG_RETURN_POSITIVE ",JSON.stringify({"case":name,"direct":_summary(baseline),"routes":routes.map(_summary)}))
	var best_time := INF
	var best_eta := INF
	for route in routes:
		best_time=minf(best_time,float(route.time))
		best_eta=minf(best_eta,float(route.eta))
		check(route.spent>int(fixture.cases[name].money) and route.recruited_work>0,
			"工资真实再次付款且新员工实际完成工作，不把招聘开始/人数当收益")
	check(best_time<float(baseline.time) and best_eta<float(baseline.eta),
		"%s至少一条真实支付和再投资路线更早完成；不强迫咖啡、等级或招聘次数"%name)

func _reinvest_route(name: String, upgrade_first: bool) -> Dictionary:
	var world := _world(name)
	var target := _work_group(world)
	var commands: Array=[]
	var next := 0.0
	if upgrade_first:
		var person: int=world._owner_type(0,"employee")[0]
		check(_apply(world,_move([person]+world._owner_type(0,"coffee"),-1,"coffee"),0.0,commands),"正例升级同样支付停工和配方成本")
		check(_apply(world,_move([person],target,"staff"),6.0,commands),"正例升级后按真实行动槽返岗")
		next=8.0
	for round_index in 2:
		world.advance(next-world.time)
		while world.available_money(0)<10 and world.winner<0: world.advance(2.0)
		var at: float=ceilf(world.time/2.0)*2.0
		check(_apply(world,_move(world._owner_type(0,"boss")+world._owner_type(0,"money"),-1,"recruitment"),at,commands),
			"正例第%d次投资只花当前真实可用工资与现金"%(round_index+1))
		var deploy_at := at+float(world.config.rules.recruitment.seconds)
		world.advance(deploy_at-world.time)
		var idle: Array=world._owner_type(0,"employee").filter(func(id):return not world.tasks.has(id))
		check(not idle.is_empty() and _apply(world,_move(idle,target,"staff"),deploy_at,commands),"真实招聘完成后新增员工才投入工作")
		next=deploy_at+2.0
	var eta := _eta(world,2.0)
	var result := _finish(world,commands,eta)
	result.upgrade_first=upgrade_first
	return result

func _summary(result: Dictionary) -> Dictionary:
	var compact := result.duplicate(true)
	compact.commands=result.commands.map(func(command):return {"at":command.at,
		"kind":command.action.kind,"intent":command.action.get("intent",""),"cards":command.action.get("ids",[]).size()})
	return compact

func _horizon_tail_certificates() -> void:
	# The real installed horizon is deliberately shorter than these games.
	# Moving an otherwise unchanged observation forward must not purchase a
	# better objective merely by sliding that horizon further into the future.
	for name in ["long_800","long_2000"]:
		var world := _world(name)
		world.config.rules.bot.evaluation_max_seconds=1800.0
		var initial_eta := _eta(world)
		var observations := []
		for at in [0.125,7.13,200.0,499.75]:
			world.advance(float(at)-world.time)
			var root_eta := _eta(world)
			observations.append({"time":world.time,"root_eta":root_eta,"work":world.work_count(0)})
			check(absf(root_eta-initial_eta)<0.00001,"%s纯等待至%.3f秒保持同一根完工时间，不奖励扩大视野"%[name,at])
		world.advance(7200.0)
		check(world.winner==0 and absf(world.time-initial_eta)<0.00001,
			"%s在1800秒预测窗口外的ETA仍与真实离散完工一致"%name)
		print("LONG_RETURN_HORIZON ",JSON.stringify({"case":name,"initial_eta":initial_eta,"actual_finish":world.time,"observations":observations}))
	_cash_flow_sample_keeps_its_time()
	_known_recruitment_after_horizon()
	_known_settlement_after_horizon()

func _sample_forecast(world: OffWorkState, horizon: float) -> Dictionary:
	var evaluator := Evaluation.new()
	var prepared: Dictionary=evaluator._prepare_evaluation(world,0,world.config.rules.bot,-1,[0.0,1.0])
	var model: Dictionary=prepared.models[0]
	var before := var_to_bytes(model)
	var result: Dictionary=evaluator._forecast(model,horizon)
	check(before==var_to_bytes(model),"完工外推不修改取样模型的人员、工作或资金")
	return result

func _cash_flow_sample_keeps_its_time() -> void:
	var world := _world("long_800")
	var forecast := _sample_forecast(world,13.25)
	check(forecast.get("eta_exact",false) and forecast.get("eta_method","")=="scheduled_discrete_tail",
		"稳定尾明确标为离散完工外推，不伪称已在采样点完成")
	check(forecast.remaining==797 and forecast.income==4.0 and forecast.cash==14.0,
		"13.25秒现金流样本仍只含当时3份工作和4钱工资，不混入最终收入")
	world.advance(13.25)
	check(world.work_count(0)==int(forecast.remaining) and world.available_money(0)==int(forecast.cash),
		"外推只修改ETA；样本工作/现金与同一真实时刻一致")
	check(absf(float(forecast.eta)-2225.0)<0.00001,"短现金流采样同时得到正确的长期稳定完工时间")

func _known_recruitment_after_horizon() -> void:
	var world := _world("long_800")
	world.config.rules.bot.evaluation_max_seconds=30.0
	world.config.rules.recruitment.seconds=36.0
	var target := _work_group(world)
	var commands: Array=[]
	check(_apply(world,_move(world._owner_type(0,"boss")+world._owner_type(0,"money"),-1,"recruitment"),0.0,commands),
		"建立36秒才完成的真实已付款招聘，超过30秒采样窗口")
	var forecast := _sample_forecast(world,30.0)
	check(forecast.get("eta_exact",false),"超过窗口的已知招聘/派工事件仍参与ETA")
	world.advance(30.0)
	check(world.work_count(0)==int(forecast.remaining) and world.available_money(0)==int(forecast.cash),
		"未来招聘收益不提前进入30秒样本的工作或可用现金")
	world.advance(6.0)
	var idle: Array=world._owner_type(0,"employee").filter(func(id):return not world.tasks.has(id))
	check(not idle.is_empty() and _apply(world,_move(idle,target,"staff"),36.0,commands),
		"按预测的合法36秒时隙真实部署招聘完成的员工")
	world.advance(7200.0)
	check(world.winner==0 and absf(world.time-float(forecast.eta))<0.00001,
		"窗口之后的已知招聘与持续生产，预测完工等于真实执行完工")
	print("LONG_RETURN_LATE_RECRUIT ",JSON.stringify({"eta":forecast.eta,"actual_finish":world.time,
		"sample_remaining":forecast.remaining,"sample_cash":forecast.cash}))

func _known_settlement_after_horizon() -> void:
	var world := _world("expensive_slow_recruitment")
	world.config.rules.bot.evaluation_max_seconds=30.0
	world.config.rules.outsource.seconds=60.0
	var commands: Array=[]
	check(_apply(world,_move(world._owner_type(0,"outsource")+world._owner_type(0,"money")+world._owner_type(0,"work"),-1,"outsource"),0.0,commands),
		"建立60秒才结算的真实外包批次，超过30秒采样窗口")
	var forecast := _sample_forecast(world,30.0)
	check(forecast.get("eta_exact",false) and forecast.eta==60.0 and forecast.remaining==40,
		"已付款晚结算ETA为60秒，但30秒样本仍保留40份待结算工作")
	world.advance(60.0)
	check(world.winner==0 and world.time==float(forecast.eta),"晚于horizon的外包结算与真实终局严格一致")
