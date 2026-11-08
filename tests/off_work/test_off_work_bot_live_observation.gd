# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Live = preload("res://engine/off_work_bot_live.gd")
const Search = preload("res://engine/off_work_bot_search.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Emergency = preload("res://engine/off_work_bot_emergency.gd")
const Session = preload("res://engine/off_work_session.gd")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	await _background_prediction(false)
	await _background_prediction(true)
	_root_only_filter()
	_emergency_publication()
	_entity_bounds()
	finish()

func _market_state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1,"work":80}]
	config.rules.initial.money = 20
	config.rules.conveyor.slots = 2
	config.rules.conveyor.opening = ["coffee","overtime"]
	config.rules.conveyor.interval_seconds = 1.0
	config.rules.conveyor.employee_every = 1
	config.rules.bot.first_action_seconds = 1.0
	config.rules.bot.think_seconds = 2.8
	config.rules.bot.decision_budget_ratio = 0.5
	config.rules.bot.search_max_depth = 1
	var state := OffWorkState.new(config)
	state.new_game(9137)
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
	headless.decide_action(Time.get_ticks_usec()+2000000)
	check(headless.last_decision.root_complete and headless.last_decision.candidates.any(func(row): return int(row.get("offer",-1))>=boundary),
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
	var root_count: int = Actions.generate(state,0,state.config.rules.bot,-1).actions.size()
	var calls := [0]
	var only_wait := func(action: Dictionary):
		calls[0] += 1
		return action.kind=="wait"
	var result: Dictionary = Search.new().search(state,0,state.config.rules.bot,Time.get_ticks_usec()+2000000,
		Callable(),Callable(),true,only_wait)
	check(result.root_complete and result.search_depth==2 and result.action.kind=="wait","根过滤限制首步但仍完成两层搜索")
	check(calls[0]==root_count and result.root_candidates==1,"过滤器恰好检查根候选，不重复施加到对手回应")
	check(result.search_nodes>1 and result.principal_variation.size()==2,"更深节点继续生成和评价真实合法动作")

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
