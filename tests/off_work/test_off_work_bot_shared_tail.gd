# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Growth = preload("res://engine/off_work_bot_growth_search.gd")

func _initialize() -> void:
	_own_return_is_saved()
	_slack_worker_tail_uses_its_real_job()
	_future_material_group_is_rebound()
	_root_reply_clock()
	_terminal_before_enemy_slot()
	_terminal_value(0)
	_terminal_value(1)
	_public_reply_use(0)
	_public_reply_use(1)
	_terminal_before_pending_use()
	finish()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":80}]
	config.rules.initial.money=0
	config.rules.conveyor.interval_seconds=10000.0
	config.rules.bot.think_seconds=6.0
	var world := OffWorkState.new(config)
	world.new_game(11911)
	world.offers.clear()
	return world

func _target(world: OffWorkState) -> int:
	return int(world.cards[world._owner_type(0,"work")[0]].group)

func _own_return_is_saved() -> void:
	var world := _world()
	var returning := world.add_card("employee",0)
	world.add_card("work",0,int(world.cards[returning].group))
	var material := world.add_card("work",0)
	var action := {"kind":"move","ids":[material],"group":_target(world)}
	var leaf := world.fork_for_bot(91)
	check(Actions.apply_action(leaf,0,action),"真实首步把孤立工作加入主工作堆")
	var value := Evaluation.new().evaluate_current(leaf,0,world.config.rules.bot,-1,[6.0,3.0])
	var commands: Array=value.detail.sides[0].forecast_commands
	check(commands.any(func(command):return command.kind=="return_workers"),"真实评价尾需要小堆完工后的人员回流")
	value.detail.sides[0].forecast_steps=Execution.physical_steps(leaf,0,commands)
	var context := Execution.prepare(world,0,action,{"evaluation":value.detail,"forecast_root_offset_seconds":0.0},world.config.rules.bot)
	check(context.get("steps",[]).any(func(step):return step.items.any(func(item):return int(item.get("id",-1))==returning)),"己方保存同一小堆回流责任，不再仅保留worker/overtime")
	check(Actions.apply_action(world,0,action),"真实提交被评价的首步")
	var at: float=context.steps[0].ready_at
	world.advance(at)
	var next: Dictionary=Execution.resolve(world,0,context,-1)
	check(next.action.kind=="move" and next.action.ids.has(returning) and Actions.apply_action(world,0,next.action),"原预测合法格执行保存的回流命令")
	world.advance(10000.0)
	check(world.winner==0 and is_equal_approx(world.time,float(value.detail.sides[0].eta)),"保存并执行评价尾后，真实完工时间等于ETA")

func _future_material_group_is_rebound() -> void:
	var world := _world()
	var material: int=world._owner_type(0,"work")[-1]
	var target := _target(world)
	var split := {"kind":"move","ids":[material],"group":-1}
	var leaf := world.fork_for_bot(92)
	var binding := Execution.describe(leaf,0,split)
	check(Actions.apply_action(leaf,0,split),"预测前缀建立未来材料组")
	var predicted: int=leaf.cards[material].group
	var tail := Execution.physical_steps(leaf,0,[{"kind":"move_work","from":predicted,"group":target,"at":12.0}])
	var report := {"observed_card_end":world._next_card,"observed_group_end":world._next_group,"forecast_root_offset_seconds":0.0,
		"evaluation":{"sides":[{"production_chain":{"commands":[{"at":0.0,"action":{"kind":"wait"}},{"at":6.0,"action":split,"binding":binding}]},"forecast_steps":tail},{}]}}
	var context := Execution.prepare(world,0,{"kind":"wait"},report,world.config.rules.bot)
	var saved: Dictionary=context.steps[-1].material_sources.values()[0].group
	check(not saved.has("id") and saved.anchors[0].id==material,"未来来源组去除预测ID，以根时已观察材料身份绑定")
	world.add_card("employee",0) # Occupies the predicted group identity.
	world.advance(6.0)
	var first: Dictionary=Execution.resolve(world,0,context,-1)
	check(Actions.apply_action(world,0,first.action),"真实前缀在不同组编号下执行")
	context=Execution.consumed(first.context,first.action)
	check(int(world.cards[material].group)!=predicted,"真实材料组编号确实不同于预测编号")
	world.advance(6.0)
	var next: Dictionary=Execution.resolve(world,0,context,-1)
	check(next.action.kind=="move" and next.action.ids.has(material) and Actions.apply_action(world,0,next.action),"材料尾按实际来源重绑，不误搬占用预测编号的新员工")
	check(int(world.cards[material].group)==target,"材料实际回到被评价的主工作堆")

func _root_reply_clock() -> void:
	var source := _world()
	var leaf := source.fork_for_bot(93)
	leaf.advance(3.0)
	var planner := Continuations.Planner.new()
	planner.source=source
	planner.owner=0
	var cursor := {"world":leaf,"commands":[{"at":0.0,"action":{"kind":"wait"}}],"replies":[{"at":3.0,"action":{"kind":"wait"}}]}
	var first := {"detail":{"terminal":false,"sides":[{"eta":1.0,"required_actions":0},{"eta":2.0,"required_actions":0}]}}
	var second := {"detail":{"terminal":false,"sides":[{"eta":100.0,"required_actions":0},{"eta":150.0,"required_actions":0}]}}
	var a: Array=planner._reply_utility(first,cursor)
	var b: Array=planner._reply_utility(second,cursor)
	check(log(2.0)>log(1.5) and float(a[0])<float(b[0]),"敌最坏回复按根时钟比较，修复局部ETA比例与根比例排序翻转")
	cursor.replies[0].action={"kind":"move"}
	check(planner._reply_utility(first,cursor)[1]==1,"敌首槽的非等待动作仍是根时钟下的一条未来责任")

func _terminal_value(winner: int) -> void:
	var world := _world()
	var extra := world.add_card("employee",winner)
	var target: int=world.cards[world._owner_type(winner,"work")[0]].group
	var action := {"kind":"move","ids":[extra],"group":target}
	check(Actions.apply_action(world,winner,action),"建立第%d方真实生产优势"%winner)
	var base := Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,[0.0,3.0])
	var leaf := world.fork_for_bot(94)
	leaf.advance(10000.0)
	var terminal := Evaluation.new().evaluate_current(leaf,0,world.config.rules.bot,-1,[0.0,3.0])
	var run := Growth.Refinement.new()
	run.world=world
	run.owner=0
	run.policy=world.config.rules.bot
	run.source_base=base
	run.ordinary=base
	var commands := [{"at":0.0,"action":{"kind":"wait"}}]
	run._record({"world":leaf,"commands":commands,"replies":[],"purchases":{},"elapsed":leaf.time,"next_actions":[0.0,3.0],"kind":"legal_continuation","evaluation":terminal},0)
	if not need(run.rows[0].size()==1,"真实胜负均保留为完整结果，不把负终局当缺失分支"): return
	var value: Dictionary=run._joint_value(run.rows[0][0])
	check(value.score==terminal.score and value.detail.terminal and value.detail.winner==winner,"长期终局使用统一真实终局分数，不拼接源世界敌ETA")
	check(value.detail.sides[0].production_chain.commands==commands,"终局证据仍保留当前首步后的执行链")

func _terminal_before_enemy_slot() -> void:
	for winner in 2:
		var config := OffWorkConfig.new()
		config.rules.initial.groups=[{"employee":1,"work":1}]
		config.rules.conveyor.interval_seconds=10000.0
		config.rules.bot.think_seconds=6.0
		var world := OffWorkState.new(config)
		world.new_game(95)
		var loser := 1-winner
		world.add_card("work",loser,int(world.cards[world._owner_type(loser,"employee")[0]].group))
		world.advance(9.0)
		var planner := Continuations.Planner.new()
		planner.source=world
		planner.owner=0
		planner.policy=config.rules.bot
		planner.period=6.0
		planner.horizon=1800.0
		planner.next_actions=[0.0,3.0]
		planner.options={"physical_opponent":true,"root_replies":[{"kind":"wait"}]}
		var cursor: Dictionary=planner._cursor(world)
		planner._command(cursor,{"kind":"wait"})
		var response: Dictionary=planner._root_response(cursor)
		check(not response.is_empty() and response.value.detail.terminal and response.value.detail.winner==winner \
			and response.cursor.replies.is_empty(),"第%d方在敌首槽前真实完工，保留终局而不制造回应或丢弃分支"%winner)

func _slack_worker_tail_uses_its_real_job() -> void:
	var world := _world()
	var worker := world.add_card("grinder",0)
	var tool := world.add_card("slack",0)
	check(world.move_cards([worker,tool],-1)>=0 and world.tasks[worker].kind=="slack","真实工作人员正在持续生产咖啡，并非闲置人员")
	var material := world.add_card("work",0)
	var action := {"kind":"move","ids":[material],"group":_target(world)}
	var leaf := world.fork_for_bot(96)
	Actions.apply_action(leaf,0,action)
	var value := Evaluation.new().evaluate_current(leaf,0,world.config.rules.bot,-1,[6.0,3.0])
	value.detail.sides[0].forecast_steps=Execution.physical_steps(leaf,0,value.detail.sides[0].forecast_commands)
	var context := Execution.prepare(world,0,action,{"evaluation":value.detail,"forecast_root_offset_seconds":0.0},world.config.rules.bot)
	check(context.steps[0].items.any(func(item):return int(item.get("id",-1))==worker and item.job=="slack"),"已评分主动返岗保留真实slack来源任务，不伪称自然空闲")
	Actions.apply_action(world,0,action)
	check(Execution.resolve(world,0,context,-1).action.kind=="wait","来源任务绑定不绕过已评分的合法行动时间")
	world.advance(float(context.steps[0].ready_at))
	var next: Dictionary=Execution.resolve(world,0,context,-1)
	check(next.action.kind=="move" and next.action.ids.has(worker) and Actions.apply_action(world,0,next.action),"到合法格后真实结束摸鱼并返岗，不因missing grinder永久卡住队列")
	world.advance(10000.0)
	check(world.winner==0 and is_equal_approx(world.time,float(value.detail.sides[0].eta)),"主动返岗物理尾的真实完工时间等于已评分ETA")

func _public_reply_use(owner: int) -> void:
	var world := _world()
	var enemy := 1-owner
	var union := world.add_card("union",owner)
	world._credit(enemy,int(world.config.cards.strike.price))
	world.offers=[world._make_offer("strike")]
	var quote: int=world.offers[0].id
	var target: int=world.cards[world._owner_type(owner,"work")[0]].group
	var planner := Continuations.Planner.new()
	planner.source=world
	planner.owner=owner
	planner.policy=world.config.rules.bot
	planner.period=6.0
	planner.horizon=1800.0
	planner.next_actions=[3.0,3.0]
	planner.next_actions[owner]=0.0
	planner.options={"physical_opponent":true,"root_replies":[{"kind":"wait"},{"kind":"buy","offer":quote,"card_type":"strike"}]}
	var cursor: Dictionary=planner._cursor(world)
	planner._command(cursor,{"kind":"wait"})
	var response: Dictionary=planner._root_response(cursor)
	if not need(not response.is_empty() and response.cursor.replies[0].action.kind=="buy",
		"座位%d共同首回复通过真实购后用途评价发现公开威胁"%owner): return
	var bought: Dictionary=response.cursor
	check(bought.world.time==3.0 and bought.world.money(enemy)==0 and bought.replies.size()==1 \
		and planner._plan(bought,"legal_continuation").opponent_use_pending,
		"首回复cursor停在t3且真实付款；t9预演不能提前消耗己方t6或发布半条候选")
	var outcomes := []
	for defend in [false,true]:
		var branch: Dictionary=planner._cursor(bought.world,bought)
		var action := {"kind":"move","ids":[union],"group":target} if defend else {"kind":"wait"}
		check(planner._command(branch,action) and branch.world.time==6.0 \
			and planner._advance_shared(branch,12.0),"己方t6实际回应后，敌方才在t9重新选择合法用途")
		var replies: Array=branch.replies.filter(func(reply):return is_equal_approx(float(reply.at),9.0))
		check(replies.size()==1 and replies[0].action.kind==("wait" if defend else "activate") \
			and not planner._plan(branch,"legal_continuation").opponent_use_pending,
			"每敌槽只执行一次命令；防守改变真实合法用途，无防守则真实发射")
		var value: Dictionary=Evaluation.new().evaluate_current(branch.world,owner,world.config.rules.bot,-1,planner._plan(branch,"legal_continuation").next_actions)
		outcomes.append(float(value.detail.sides[owner].eta))
	check(outcomes[1]<outcomes[0],"同一真实世界的已兑现攻击使及时防守改善统一完工ETA")
	planner.horizon=6.0
	planner.complete=true
	var limited: Dictionary=planner._cursor(world)
	planner._command(limited,{"kind":"wait"})
	check(planner._root_response(limited).is_empty(),"购后使用越过horizon时整组首回复未完成，不拿已评wait冒充完整portfolio")

func _terminal_before_pending_use() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":1}]
	config.cards.work.work_seconds=4.0
	config.rules.initial.money=0
	config.rules.conveyor.interval_seconds=10000.0
	var world := OffWorkState.new(config)
	world.new_game(981)
	world.add_card("work",1,int(world.cards[world._owner_type(1,"work")[0]].group))
	world._credit(1,int(config.cards.strike.price))
	world.offers=[world._make_offer("strike")]
	var wait := {"kind":"wait"}
	var first := world.fork_for_bot(982)
	Actions.apply_action(first,0,wait)
	first.advance(3.0)
	var value: Dictionary=Evaluation.new().evaluate_current(first,0,config.rules.bot,-1,[3.0,0.0])
	var rows := []
	Continuations.visit(world,0,config.rules.bot,-1,[0.0,3.0],func(plan):
		rows.append({"time":plan.world.time,"value":plan.evaluation,"replies":plan.replies.duplicate(true)}),Callable(),
		{"root_candidates":[{"action":wait,"value":value,"elapsed":3.0,"next_action":6.0}],
		"root_replies":[{"kind":"buy","offer":world.offers[0].id,"card_type":"strike"}],
		"physical_opponent":true,"seed_roots_only":true,"expansion_limit":2})
	check(rows.size()==1 and rows[0].value.detail.get("terminal",false) and rows[0].value.detail.winner==0 \
		and is_equal_approx(float(rows[0].time),4.0) and rows[0].replies.size()==1,
		"敌t3已付款、t9用途仍待兑现时，t4自然终局真实发布，不等己方t6或制造终局后动作")
