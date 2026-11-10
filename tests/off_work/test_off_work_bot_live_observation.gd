# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Live = preload("res://engine/off_work_bot_live.gd")
const Search = preload("res://engine/off_work_bot_search.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Emergency = preload("res://engine/off_work_bot_emergency.gd")
const Session = preload("res://engine/off_work_session.gd")
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	await _background_prediction(false)
	await _background_prediction(true)
	_root_only_filter()
	_emergency_publication()
	_entity_bounds()
	_continuation_observation_bounds()
	_live_execution_context_commit()
	_live_independent_dispatch_consumption()
	_live_failed_commit_restores_context()
	finish()

func _market_state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1,"work":80}]
	config.rules.initial.money = 20
	config.rules.conveyor.slots = 2
	config.rules.conveyor.interval_seconds = 1.0
	config.rules.conveyor.pool = {"employee":1}
	config.rules.bot.first_action_seconds = 1.0
	config.rules.bot.think_seconds = 2.8
	config.rules.bot.decision_budget_ratio = 0.5
	config.rules.bot.search_max_depth = 1
	var state := OffWorkState.new(config)
	state.new_game(9137)
	state.offers = [state._make_offer("coffee"), state._make_offer("overtime")]
	return state

func _background_prediction(recorded: bool) -> void:
	var state := _market_state()
	if recorded: state.config.rules.bot.live_snapshot_card_limit = 1
	var bot := OffWorkBot.new(state,0)
	bot.start()
	var driver := Live.new()
	var boundary := state._next_offer
	var before := var_to_bytes([state.cards,state.groups,state.tasks,state.offers,state.time,state._rng.state])
	driver.tick(bot,0.01,_frame(state) if recorded else {})
	check(driver._task >= 0,"真实后台启动并预测到未来行动点，关键帧模式=%s" % recorded)
	var until := Time.get_ticks_usec()+2000000
	while driver._task >= 0 and not WorkerThreadPool.is_task_completed(driver._task) and Time.get_ticks_usec()<until:
		await process_frame
	driver._collect()
	check(driver._ready != null,"后台在时限内发布完整可见根方案")
	if driver._ready == null:
		driver.close(self)
		return
	var source = driver._ready
	var packet: Dictionary = source.latest()
	check(before == var_to_bytes([state.cards,state.groups,state.tasks,state.offers,state.time,state._rng.state]),
		"预测补牌没有修改真实状态或随机流")
	check(source.world._next_offer>boundary and source.world.offers.all(func(offer): return offer.is_empty() or int(offer.id)<boundary),
		"预测时钟正常推进，但所有未知报价在搜索和估值之前被遮蔽")
	check(packet.report.root_complete,
		"只有实际已公开报价参与完整根比较")
	check(source.uses_observed_entities(packet.action) and packet.report.candidates.all(func(row): return int(row.get("offer",-1))<boundary),
		"所有已发布根候选只引用启动时已公开的实体")
	# On the real next observation the new card is now public. It must enter
	# normal current-state search, rather than remaining hidden permanently.
	state.advance(bot.next_action_time()-state.time)
	var headless := OffWorkBot.new(state,0,bot._policy.duplicate(true))
	var current_root := {"new_offer":false}
	var observe := func(_action: Dictionary, report: Dictionary):
		# A later common-response continuation publishes its selected row.
		# Inspect the completed ordinary layer where every legal root competes.
		if report.get("root_complete",false) and int(report.get("search_depth",0))==1 \
			and float(report.get("forecast_root_offset_seconds",0.0))>0.0:
			current_root.new_offer=current_root.new_offer or report.candidates.any(func(row):return int(row.get("offer",-1))>=boundary)
	headless.decide_action(Time.get_ticks_usec()+2000000,Callable(),true,observe)
	check(headless.last_decision.root_complete and current_root.new_offer,
		"无头当前局面的完整根动作仍保留新报价")
	check(source.still_legal(state,packet.action),"即使真实市场同编号到货，选出的已知方案仍可提交")
	driver.tick(bot,0.0)
	check(bot.decision_serial==1 and bot.last_decision.root_complete and not bot.last_decision.get("live_fallback",false),
		"行动点直接提交完整后台结果，不因未知报价退回紧急等待")
	driver.close(self)

func _frame(state: OffWorkState) -> Dictionary:
	var world := {}
	for key in OffWorkState.WORLD_FIELDS: world[key]=state.get(key)
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key]={}
	var raw := var_to_bytes({"world":world,"layout":layout,"events":[],"rng":state._rng.state})
	return {"t":state.time,"size":raw.size(),"data":Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD))}

func _root_only_filter() -> void:
	var state := _market_state()
	state.config.rules.bot.search_max_depth=2
	state.config.rules.conveyor.interval_seconds=1000.0
	state.offers.clear()
	var strike := state.add_card("strike",1)
	var root_count: int = Actions.generate(state,0,state.config.rules.bot,-1).actions.size()
	var inspected := {"calls":0,"enemy":false}
	var only_wait := func(action: Dictionary):
		inspected.calls += 1
		inspected.enemy=inspected.enemy or int(action.get("tool",-1))==strike
		return action.kind=="wait"
	var result: Dictionary = Search.new().search(state,0,state.config.rules.bot,Time.get_ticks_usec()+2000000,
		Callable(),Callable(),true,only_wait)
	check(result.root_coverage_complete and result.short_search_depth==2 and result.action.kind=="wait","根过滤限制首步但仍完成两层搜索")
	# The long tree may inspect the same root again. Count rejected root
	# candidates, and prove the enemy-only tool never reaches the root filter.
	check(inspected.calls>=root_count and not inspected.enemy and result.root_candidates==1 \
		and result.root_unobserved==root_count-1,"过滤器可以重新检查首步，但不会过滤对手真实回应")
	var reply: Array=result.principal_variation.filter(func(step):return int(step.seat)==1 and int(step.get("tool",-1))==strike)
	check(result.short_search_nodes>1 and not reply.is_empty(),"等待首步的限制不阻止更深节点真实使用罢工")

func _emergency_publication() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"work":20},{"leader":1}]
	config.rules.initial.money=0
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.bot.search_max_depth=1
	var state := OffWorkState.new(config)
	state.new_game(56)
	state.offers.clear()
	var source := Live.Search.new()
	source.world=state
	source.visible_card_end=state._next_card
	source.visible_group_end=state._next_group
	source.visible_offer_end=state._next_offer
	var future_worker := state.add_card("employee",0)
	var work: int = state._owner_type(0,"work")[0]
	var context := {"group_cursor":1,"worker":future_worker,"work":work}
	var quick: Dictionary = Emergency.choose(state,0,Time.get_ticks_usec()+100000,context)
	check(quick.action.kind=="move" and not source.uses_observed_entities(quick.action),"保底确实能发现预测中新出现的员工，必须另行检查可见性")
	var publications: Array = []
	var observer := func(action: Dictionary, _report: Dictionary): publications.append(action.duplicate(true))
	var bot := OffWorkBot.new(state,0)
	bot.import_decision_context(context)
	var selected := bot.decide_action(Time.get_ticks_usec()+2000000,Callable(),true,observer,source.uses_observed_entities)
	check(not publications.is_empty() and publications.all(func(action): return source.uses_observed_entities(action)),
		"紧急方案与完整层的每次发布都遵守同一观察边界")
	check(source.uses_observed_entities(selected),"最终命令不会引用尚未公开的人员")

func _entity_bounds() -> void:
	var source := Live.Search.new()
	source.visible_offer_end=10
	source.visible_card_end=20
	source.visible_group_end=30
	for action in [{"kind":"buy","offer":10},{"kind":"move","group":30},
			{"kind":"activate","tool":20},{"kind":"move","person":20},{"kind":"move","ids":[19,20]}]:
		check(not source.uses_observed_entities(action),"报价、目标组、工具、人员和批量材料均受观察边界约束："+str(action))
	check(source.uses_observed_entities({"kind":"move","ids":[19],"group":-1,"person":-1}),"已知牌新建组合仍是合法的信息来源，不被新组边界误杀")
	check(source.uses_observed_entities({"kind":"wait"}),"等待无需引用实体")

func _continuation_observation_bounds() -> void:
	var state := _market_state()
	var source := Live.Search.new()
	source.world=state
	source.worker=OffWorkBot.new(state,0)
	source.deadline=Time.get_ticks_usec()+1000000
	source.visible_card_end=state._next_card
	source.visible_group_end=state._next_group
	state.add_card("employee",0)
	var report := {"observed_card_end":state._next_card,"observed_group_end":state._next_group}
	source.publish({"kind":"wait"},report)
	var published: Dictionary=source.latest().report
	check(published.observed_card_end==source.visible_card_end and published.observed_group_end==source.visible_group_end,
		"后续计划绑定使用原始公开快照边界，不把提前推进产生的预测身份当成已观察身份")
	check(report.observed_card_end==state._next_card,"发布报告的边界清洗不修改搜索持有的原始结果")

func _execution_state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":100}]
	config.rules.initial.money=20
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.bot.first_action_seconds=0.0
	config.rules.bot.think_seconds=6.0
	var state := OffWorkState.new(config)
	state.new_game(971)
	state.offers.clear()
	return state

func _execution_source(bot: OffWorkBot) -> Live.Search:
	var source := Live.Search.new()
	source.world=bot.state.fork_for_bot(972)
	source.visible_card_end=bot.state._next_card
	source.visible_group_end=bot.state._next_group
	source.visible_offer_end=bot.state._next_offer
	source.bot_id=bot.get_instance_id()
	source.due=bot.next_action_time()
	source.policy_hash=hash(bot._policy)
	return source

func _live_execution_context_commit() -> void:
	var state := _execution_state()
	var offer: Dictionary=state._make_offer("employee")
	state.offers.append(offer)
	var bot := OffWorkBot.new(state,0)
	bot.start()
	var driver := Live.new()
	var source := _execution_source(bot)
	var bought := state._next_card
	var target: int=state.cards[state._owner_type(0,"work")[0]].group
	var report := {"forecast_root_offset_seconds":0.0,"observed_card_end":state._next_card,"observed_group_end":state._next_group,
		"evaluation":{"sides":[{"forecast_commands":[{"at":6.0,"kind":"worker","group":target,"id":bought,"unit":{"role":"employee","count":1}}]},{}]}}
	var packet := {"action":{"kind":"buy","offer":int(offer.id),"card_type":"employee"},"report":report,
		"rng":bot._rng.state,"hints":bot.export_decision_context()}
	check(driver._commit_packet(bot,source,packet), "live真实提交已发布购买动作")
	var context: Dictionary=bot.export_decision_context()
	check(context.has("execution_plan") and not context.execution_plan.steps.is_empty(), "live购买后的新派工承诺不被提交前worker hints覆盖")
	check(not packet.hints.has("execution_plan"), "提交不反向改写worker发布快照")
	state.advance(6.0)
	bot._next_think=state.time
	source=_execution_source(bot)
	var next: Dictionary=Execution.resolve(state,0,context.execution_plan,-1)
	var hints: Dictionary=context.duplicate(true)
	hints.execution_plan=next.context
	packet={"action":next.action,"report":{"execution_continuation":true},"rng":bot._rng.state,"hints":hints}
	check(driver._commit_packet(bot,source,packet), "live提交继承的实际派工")
	check(state.tasks.get(bought,{}).get("kind","")=="work", "live新购员工真正投入工作")
	check(not bot.export_decision_context().has("execution_plan"), "live消费后不能重新导入旧worker队首，已执行步骤不复活")
	check(not packet.hints.execution_plan.steps.is_empty(), "消费只更新BOT真实上下文，已发布packet仍不可变")

func _live_independent_dispatch_consumption() -> void:
	var state := _execution_state()
	var boss := state.add_card("boss",0)
	var employee := state.add_card("employee",0)
	var target: int=state.cards[state._owner_type(0,"work")[0]].group
	var recruit := Execution.describe(state,0,{"kind":"move","ids":[boss]+state._owner_type(0,"money"),"group":-1,"person":-1,"intent":"recruitment","growth_intent":"growth_recruit"})
	recruit["ready_at"]=0.0
	for item in recruit.items:
		if item.type=="money": item.count=100
	var dispatch := Execution.describe(state,0,{"kind":"move","ids":[employee],"group":target,"person":-1,"intent":"assemble_work"})
	dispatch["ready_at"]=6.0
	var context := Execution.adopt({"observed_at":0.0,"source":"executable","steps":[recruit]},
		{"observed_at":0.0,"source":"forecast","steps":[dispatch]})
	var bot := OffWorkBot.new(state,0)
	bot.start()
	bot.import_decision_context({"execution_plan":context})
	state.advance(6.0)
	bot._next_think=state.time
	var source := _execution_source(bot)
	var worker_selection := Execution.resolve(state,0,context,-1)
	check(worker_selection.context.steps[0].get("independent",false) and not bot.export_decision_context().execution_plan.steps[0].get("independent",false),
		"worker已将独立派工重排，live提交前仍保留原主链队首")
	var packet := {"action":worker_selection.action,"report":{"execution_continuation":true},"rng":bot._rng.state,
		"hints":{"execution_plan":worker_selection.context}}
	check(Live.new()._commit_packet(bot,source,packet), "live先采用worker选中的实际步骤再提交")
	var remaining: Dictionary=bot.export_decision_context().get("execution_plan",{})
	check(remaining.get("steps",[]).size()==1 and remaining.steps[0].growth_intent=="growth_recruit", "live消费选中的独立派工，不错误删除尚未执行的招聘")
	check(state.tasks.get(employee,{}).get("kind","")=="work" and state.recruitment.is_empty(), "独立员工实际工作，未获资金的招聘仍未启动")

func _live_failed_commit_restores_context() -> void:
	var state := _execution_state()
	var offer: Dictionary=state._make_offer("boss")
	offer.price=1000
	state.offers.append(offer)
	var bot := OffWorkBot.new(state,0)
	bot.start()
	var original := {"group_cursor":7,"execution_plan":{"observed_at":0.0,"source":"executable","steps":[{"ready_at":18.0,"kind":"wait"}]}}
	bot.import_decision_context(original)
	var source := _execution_source(bot)
	var action := {"kind":"buy","offer":int(offer.id),"card_type":"boss"}
	var previous_rng := bot._rng.state
	var packet := {"action":action,"report":{},"rng":previous_rng+1,"hints":{"group_cursor":99}}
	check(source.still_legal(state,action), "失败用例通过实体观察验证，由真实资金规则拒绝提交")
	check(not Live.new()._commit_packet(bot,source,packet), "真实规则拒绝资金不足的已发布购买")
	check(bot.export_decision_context()==original, "失败提交回滚worker hints，保留原真实计划")
	check(bot._rng.state==previous_rng and bot.decision_serial==0, "失败提交不更新BOT随机流或决策提交序号")
