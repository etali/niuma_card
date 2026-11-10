# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_purchase_dispatch()
	_boss_chain_rebinds()
	_coffee_chain_rebinds()
	_active_coffee_line_staffing()
	_purchased_strike_keeps_opponent_target()
	_completed_or_invalid()
	_compression_and_observation_boundary()
	_paid_plan_survives_checkpoint()
	_independent_dispatch_passes_unfunded_recipe()
	_consumption_identifies_the_published_step()
	_selected_wait_keeps_the_real_tail()
	_waits_become_dispatch_times()
	_legacy_wait_expires_without_an_action()
	_same_first_command_replaces_suffix()
	_explicit_prefix_keeps_scored_dispatch_tail()
	finish()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":2,"work":200}]
	config.rules.initial.money=40
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.bot.think_seconds=6.0
	var world := OffWorkState.new(config)
	world.new_game(736)
	world.offers.clear()
	return world

func _target(world: OffWorkState) -> int:
	return int(world.cards[world._owner_type(0,"work")[0]].group)

func _offer(world: OffWorkState, kind: String) -> Dictionary:
	var offer := {"id":world._next_offer,"type":kind,"price":int(world.config.cards[kind].price)}
	world._next_offer+=1
	world.offers.append(offer)
	return {"kind":"buy","offer":int(offer.id),"card_type":kind,"intent":"buy"}

func _report(world: OffWorkState, commands: Array) -> Dictionary:
	return {"observed_card_end":world._next_card,"observed_group_end":world._next_group,"forecast_root_offset_seconds":0.0,
		"evaluation":{"sides":[{"production_chain":{"kind":"sustained_growth","complete":true,"owner":0,"commands":commands}},{}]}}

func _describe_command(world: OffWorkState, at: float, action: Dictionary) -> Dictionary:
	return {"at":at,"action":action.duplicate(true),"binding":Execution.describe(world,0,action)}

func _purchase_dispatch() -> void:
	var world := _world()
	var buy := _offer(world,"employee")
	var predicted := world._next_card
	var target := _target(world)
	var report := {"forecast_root_offset_seconds":3.0,"evaluation":{"sides":[{"forecast_commands":[
		{"at":3.0,"kind":"worker","group":target,"id":predicted,"unit":{"role":"employee","count":1}}
	]},{}]}}
	var context := Execution.prepare(world,0,buy,report,world.config.rules.bot)
	check(not context.is_empty(), "普通物理评估购买员工也保留已计分的派工动作")
	check(not context.steps[0].items[0].has("id"), "尚未实际购买的预测员工ID不写入持久上下文")
	check(Actions.apply_action(world,0,buy), "真实购买员工")
	check(Execution.resolve(world,0,context,-1).action.kind=="wait", "下一行动槽前不提前部署")
	var overtime := world.add_card("overtime",0)
	world.advance(6.0)
	var before := var_to_bytes(world.cards)
	var next := Execution.resolve(world,0,context,-1)
	check(before==var_to_bytes(world.cards), "解析生产承诺不会提前移动、支付或推进规则")
	check(next.action.kind=="move" and next.action.ids.has(predicted) and next.action.ids.has(overtime), "一次真实派工同时部署员工与空闲加班")
	check(Actions.apply_action(world,0,next.action), "承诺派工可通过正式规则执行")
	check(world.tasks.get(predicted,{}).get("kind","")=="work", "购买得到的员工真正投入工作")
	check(Execution.consumed(context,next.action).is_empty(), "已兑现的单步承诺清除")
	check(Execution.resolve(world,0,context,-1).context.is_empty(), "按角色绑定的重复派工已完成时也清除，不能永久等待")

func _boss_chain_rebinds() -> void:
	var world := _world()
	var buy := _offer(world,"boss")
	var branch := world.fork_for_bot(77)
	var commands := [_describe_command(branch,0.0,buy)]
	check(Actions.apply_search_action(branch,0,buy), "老板候选真实支付")
	var boss: int=branch._owner_type(0,"boss")[0]
	var recruit := {"kind":"move","ids":[boss]+branch._owner_type(0,"money"),"group":-1,"person":-1,"intent":"recruitment","growth_intent":"growth_recruit"}
	commands.append(_describe_command(branch,6.0,recruit))
	branch.advance_for_search(6.0,-1)
	check(Actions.apply_search_action(branch,0,recruit), "老板候选真实组队招聘")
	branch.advance_for_search(12.0,-1)
	var recruited: Array=branch._owner_type(0,"employee").filter(func(id):return not world.cards.has(id))
	var deploy := {"kind":"move","ids":recruited,"group":_target(world),"person":-1,"intent":"staff_batch","growth_intent":"growth_return"}
	commands.append(_describe_command(branch,18.0,deploy))
	var context := Execution.prepare(world,0,buy,_report(world,commands),world.config.rules.bot)
	check(context.steps.size()==2, "买老板后的招聘、员工投产保留为同一个完整后续")
	check(context.steps[0].items.filter(func(item):return item.type=="boss").all(func(item):return not item.has("id")), "预测老板身份以角色绑定")
	world.add_card("coffee",1)
	check(Actions.apply_action(world,0,buy), "有其它真实造物插入时仍正常买老板")
	world.advance(6.0)
	var hire := Execution.resolve(world,0,context,-1)
	var actual_boss: int=world._owner_type(0,"boss")[0]
	check(hire.action.kind=="move" and hire.action.ids.has(actual_boss) and actual_boss!=boss, "招聘命令使用真实老板身份而非预测UID")
	check(Actions.apply_action(world,0,hire.action) and world.recruitment.has(actual_boss), "执行承诺真正启动招聘")
	context=Execution.consumed(hire.context,hire.action)
	world.add_card("coffee",1)
	world.advance(12.0)
	var returning := Execution.resolve(world,0,context,-1)
	check(returning.action.kind=="move" and returning.action.ids.size()==recruited.size(), "新员工身份变化后按招聘数量重绑投产")
	check(returning.action.ids.all(func(id):return world.cards[id].owner==0 and world.cards[id].type=="employee"), "重绑不能选敌方或错误牌种")
	check(Actions.apply_action(world,0,returning.action), "整条老板购买、招聘、投产链能用真实规则执行")

func _coffee_chain_rebinds() -> void:
	var world := _world()
	var buy := _offer(world,"slack")
	var branch := world.fork_for_bot(78)
	var commands := [_describe_command(branch,0.0,buy)]
	Actions.apply_search_action(branch,0,buy)
	var tool: int=branch._owner_type(0,"slack")[0]
	var person: int=branch._owner_type(0,"employee")[0]
	var staffing := {"kind":"move","ids":[tool,person],"group":-1,"person":-1,"tool":tool,"intent":"slack","growth_intent":"growth_staff"}
	commands.append(_describe_command(branch,6.0,staffing))
	var context := Execution.prepare(world,0,buy,_report(world,commands),world.config.rules.bot)
	world.add_card("money",1)
	Actions.apply_action(world,0,buy)
	world.advance(6.0)
	var next := Execution.resolve(world,0,context,-1)
	check(next.action.kind=="move" and int(next.action.tool)!=tool, "购买摸鱼后按真实工具身份重绑配人命令")
	check(Actions.apply_action(world,0,next.action), "购买摸鱼、配置生产人员能执行")
	check(world.tasks.get(person,{}).get("kind","")=="slack", "已购买摸鱼投入真实咖啡生产")

func _completed_or_invalid() -> void:
	var world := _world()
	var person := world.add_card("employee",0)
	var target := _target(world)
	var action := {"kind":"move","ids":[person],"group":target,"person":-1,"intent":"staff_batch"}
	var step := Execution.describe(world,0,action)
	step["ready_at"]=0.0
	var context := {"observed_at":0.0,"steps":[step]}
	Actions.apply_action(world,0,action)
	check(Execution.resolve(world,0,context,-1).context.is_empty(), "人员已由其它合法动作投入目标组时清除承诺而不永久等待")
	var pending := context.duplicate(true)
	pending.observed_at=3.0
	check(Execution.resolve(world,0,pending,-1).context.is_empty(), "重开局时钟回退清空上局执行计划")
	check(not Execution.resolve(world,0,context,Time.get_ticks_usec()-1).context.is_empty(), "解析预算到期不能遗失有效承诺")

func _compression_and_observation_boundary() -> void:
	var world := _world()
	var boss := world.add_card("boss",0)
	var action := {"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1,"person":-1,"intent":"recruitment","growth_intent":"growth_recruit"}
	var description := Execution.describe(world,0,action)
	check(description.items.filter(func(item):return item.type=="money").size()==1, "大量工资卡压缩为一个金额需求，不逐张持久化")
	check(description.items.filter(func(item):return item.type=="money")[0].count==40, "资金压缩保持真实招聘金额")
	var end := world._next_card
	var inserted := world.add_card("employee",0)
	var buy := {"kind":"buy","offer":999,"card_type":"employee"}
	var report := {"observed_card_end":end,"forecast_root_offset_seconds":0.0,"evaluation":{"sides":[{"forecast_commands":[
		{"at":6.0,"kind":"worker","group":_target(world),"id":inserted,"unit":{"role":"employee","count":1}}
	]},{}]}}
	var context := Execution.prepare(world,0,buy,report,world.config.rules.bot)
	check(not context.steps[0].items[0].has("id"), "搜索观察后恰好撞上预测UID的真实新牌不能被误认作原身份")

func _paid_plan_survives_checkpoint() -> void:
	var world := _world()
	var buy := _offer(world,"employee")
	var person := world._next_card
	var report := {"forecast_root_offset_seconds":3.0,"evaluation":{"sides":[{"forecast_commands":[
		{"at":3.0,"kind":"worker","group":_target(world),"id":person,"unit":{"role":"employee","count":1}}
	]},{}]}}
	var bot := OffWorkBot.new(world,0)
	check(bot.commit_action(buy,report), "Bot提交购买会保存真实后续计划")
	var context: Dictionary=bot.export_decision_context().get("execution_plan",{})
	check(not context.is_empty(), "执行计划跨搜索轮次导出")
	world.advance(6.0)
	var follow := Execution.resolve(world,0,context,-1)
	# Search may select a one-command checkpoint of the existing plan. The
	# executable action carries its provenance even if a richer report replaces
	# the incumbent's flags; consuming it must not restart or erase later steps.
	var later: Dictionary = context.steps[0].duplicate(true)
	later.ready_at=18.0
	context.steps.append(later)
	bot.import_decision_context({"execution_plan":context})
	check(bot.commit_action(follow.action,{"execution_continuation":false}), "搜索重新选中的继承动作仍作为旧计划执行")
	var remaining: Dictionary=bot.export_decision_context().get("execution_plan",{})
	check(remaining.get("steps",[]).size()==1 and float(remaining.steps[0].ready_at)==18.0, "单checkpoint评分不会遗失或延期旧计划后续")
	var physical := {"source":"forecast","observed_at":6.0,"steps":[later.duplicate(true)]}
	physical.steps[0].ready_at=12.0
	var combined := Execution.adopt(remaining,physical)
	check(combined.steps.size()==2 and float(combined.steps[0].ready_at)==12.0 and float(combined.steps[1].ready_at)==18.0,
		"等待生产时另购员工的派工义务合入原计划，不清空原链")
	var replacement := {"source":"executable","observed_at":6.0,"steps":[later.duplicate(true)]}
	check(Execution.adopt(combined,replacement)==replacement, "完整的新可执行路线可以取代旧计划")

func _active_coffee_line_staffing() -> void:
	var world := _world()
	var tool := world.add_card("slack",0)
	var producer: int=world._owner_type(0,"employee")[0]
	check(world.move_cards([producer],int(world.cards[tool].group))>=0, "建立已在运行的摸鱼生产线")
	world.advance(4.0)
	var target: int=world.cards[tool].group
	var progress := world.group_slack_progress(target)
	var newcomer := world.add_card("employee",0)
	var staffing := {"kind":"move","ids":[newcomer],"group":target,"person":-1,"tool":tool,"intent":"slack","growth_intent":"growth_staff"}
	var step := Execution.describe(world,0,staffing)
	step["ready_at"]=world.time
	check(step.tool.status=="active" and not staffing.ids.has(tool), "补人员命令中的active摸鱼只是目标身份，不是移动材料")
	var context := {"observed_at":world.time,"steps":[step]}
	var next := Execution.resolve(world,0,context,-1)
	check(next.action.kind=="move" and next.action.ids==[newcomer] and int(next.action.tool)==tool,
		"已有摸鱼active状态不阻塞补人员承诺")
	check(Actions.apply_action(world,0,next.action), "已有生产线补人员通过真实规则执行")
	check(is_equal_approx(world.group_slack_progress(target),progress), "补人员不重置原生产周期")
	check(world.group_slack_participants(target).size()==2, "补入人员真正参加咖啡生产")
	world.advance(world.config.number("slack","seconds")-4.0)
	check(world._owner_type(0,"coffee").size()==2, "当前真实周期按两名生产者产出两杯咖啡")
	# A move can also legitimately relocate an active durable tool. Preserve
	# the precondition that was actually validated by the real prefix.
	var destination := world.add_card("employee",0)
	var relocate := {"kind":"move","ids":[tool],"group":int(world.cards[destination].group),"person":-1,"tool":tool,"intent":"slack"}
	step=Execution.describe(world,0,relocate)
	step["ready_at"]=world.time
	next=Execution.resolve(world,0,{"observed_at":world.time,"steps":[step]},-1)
	check(next.action.kind=="move" and next.action.ids==[tool], "前缀合法搬动active耐用工具时按其实际状态绑定")
	check(Actions.apply_action(world,0,next.action) and world.tasks.get(destination,{}).get("kind","")=="slack",
		"active工具的真实移动仍由唯一规则引擎处理")

func _purchased_strike_keeps_opponent_target() -> void:
	var world := _world()
	var buy := _offer(world,"strike")
	var branch := world.fork_for_bot(172)
	Actions.apply_search_action(branch,0,buy)
	var strike: int=branch._owner_type(0,"strike")[0]
	var target: int=branch.cards[branch._owner_type(1,"work")[0]].group
	var attack := {"kind":"activate","tool":strike,"group":target,"person":-1,"intent":"strike"}
	var command := _describe_command(branch,6.0,attack)
	var report := {"observed_card_end":world._next_card,"observed_group_end":world._next_group,"forecast_root_offset_seconds":0.0,
		"evaluation":{"sides":[{},{}],"purchase_chain":{"owner":0,"commands":[command]}}}
	var context := Execution.prepare(world,0,buy,report,world.config.rules.bot)
	check(not context.is_empty() and int(context.steps[0].group.id)==target and int(context.steps[0].group.owner)==1,
		"买罢工的使用前缀保留已观察敌方目标组和归属")
	world.add_card("coffee",1)
	Actions.apply_action(world,0,buy)
	world.advance(6.0)
	var next := Execution.resolve(world,0,context,-1)
	check(next.action.kind=="activate" and int(next.action.group)==target and int(next.action.tool)!=strike,
		"重绑定真实罢工身份时目标仍为原敌方组")
	check(Actions.apply_action(world,0,next.action) and not world.pending_strikes.is_empty(), "继承罢工命令真正飞向敌方")
	world.advance(world.config.number("strike","flight_seconds"))
	check(world._owner_type(1,"employee").all(func(id):return world.is_striking(id)), "继承罢工真实命中敌方人员")
	check(world._owner_type(0,"employee").all(func(id):return not world.is_striking(id)), "不会误绑或误击己方工作组")
	check(Execution.resolve(world,0,context,-1).context.is_empty(), "目标已清空时共享罢工合法性检查释放失效承诺")
	var invalid: Dictionary=context.duplicate(true)
	invalid.steps[0].kind="move"
	check(Execution.resolve(world,0,invalid,-1).context.is_empty(), "敌方目标例外不能扩展为跨阵营移动生产卡")

func _independent_dispatch_passes_unfunded_recipe() -> void:
	var world := _world()
	var boss := world.add_card("boss",0)
	var recruit := {"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1,"person":-1,"intent":"recruitment","growth_intent":"growth_recruit"}
	var head := Execution.describe(world,0,recruit)
	head["ready_at"]=6.0
	for item in head.items:
		if item.type=="money": item.count=100
	var later: Dictionary=head.duplicate(true)
	later.ready_at=24.0
	var original := {"observed_at":0.0,"source":"executable","steps":[head,later]}
	world.advance(12.0)
	var buy := _offer(world,"employee")
	var bought := world._next_card
	var report := {"forecast_root_offset_seconds":0.0,"evaluation":{"sides":[{"forecast_commands":[
		{"at":6.0,"kind":"worker","group":_target(world),"id":bought,"unit":{"role":"employee","count":1}}
	]},{}]}}
	var physical := Execution.prepare(world,0,buy,report,world.config.rules.bot)
	check(Actions.apply_action(world,0,buy), "资金不足招聘期间实际购买独立员工")
	var context := Execution.adopt(original,physical)
	check(context.steps[1].get("independent",false), "仅合入的已付费派工标记独立依赖")
	world.advance(6.0)
	var next := Execution.resolve(world,0,context,-1)
	check(next.action.kind=="move" and next.action.ids.has(bought) and int(next.action.group)==_target(world),
		"18秒招聘仍缺钱时已付费员工可以越过阻塞投入工作")
	check(next.context.steps[0].get("independent",false) and next.context.steps[1].growth_intent=="growth_recruit",
		"只把选中的独立派工移到队首，主生产链顺序保留")
	check(Actions.apply_action(world,0,next.action) and world.tasks.get(bought,{}).get("kind","")=="work",
		"独立派工通过真实规则立即生效")
	var remaining := Execution.consumed(next.context,next.action)
	check(remaining.steps.size()==2 and float(remaining.steps[0].ready_at)==6.0 and float(remaining.steps[1].ready_at)==24.0,
		"消费只移除选中派工，不错误消费招聘或重排生产依赖")
	# An ordinary later command, even executable now, cannot jump the funding
	# step. It is only independent when it came from a separate paid purchase.
	var unrelated := world.add_card("employee",0)
	var deploy := Execution.describe(world,0,{"kind":"move","ids":[unrelated],"group":_target(world),"person":-1,"intent":"assemble_work"})
	deploy["ready_at"]=18.0
	var dependent := original.duplicate(true)
	dependent.steps[1]=deploy
	check(Execution.resolve(world,0,dependent,-1).action.kind=="wait", "未标独立的主链后续步骤不能任意乱序")
	var independent := {"source":"forecast","observed_at":18.0,"steps":[deploy]}
	var preserved := Execution.adopt(original,independent)
	world._consume(boss)
	var freed := Execution.resolve(world,0,preserved,-1)
	check(freed.action.kind=="move" and freed.action.ids.has(unrelated) and freed.context.steps.size()==1,
		"主链老板已消失时仅清理失效主链，保留并执行无关已付费派工")

func _consumption_identifies_the_published_step() -> void:
	var world := _world()
	var boss := world.add_card("boss",0)
	var employee := world.add_card("employee",0)
	var funding := Execution.describe(world,0,{"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1,"person":-1,"intent":"recruitment"})
	funding["ready_at"]=0.0
	for item in funding.items:
		if item.type=="money": item.count=100
	var deploy := Execution.describe(world,0,{"kind":"move","ids":[employee],"group":_target(world),"person":-1,"intent":"assemble_work"})
	deploy["ready_at"]=0.0
	deploy["independent"]=true
	var original := {"observed_at":0.0,"source":"executable","steps":[funding,deploy]}
	# The first bounded resolution times out and cannot publish a reordered
	# context. Later the growth worker obtains a completed independent command.
	var expired := Execution.resolve(world,0,original,Time.get_ticks_usec()-1)
	check(expired.context==original and expired.action.kind=="wait", "预解析超时保持原队列顺序")
	var later := Execution.resolve(world,0,original,-1)
	check(later.action.kind=="move" and later.action.execution_step==deploy, "较长搜索发布精确的独立语义步骤身份")
	var bot := OffWorkBot.new(world,0)
	bot.import_decision_context({"execution_plan":expired.context})
	check(bot.commit_action(later.action,{"execution_continuation":true}), "未收到重排context也能执行后发布的独立命令")
	var remaining: Dictionary=bot.export_decision_context().get("execution_plan",{})
	check(remaining.steps.size()==1 and remaining.steps[0]==funding, "按语义步骤消费实际完成派工，不错误pop原招聘队首")
	var unmatched: Dictionary=later.action.duplicate(true)
	unmatched.execution_step.ready_at=99.0
	check(Execution.consumed(original,unmatched)==original, "找不到精确语义步骤时不猜测、不删除任何原义务")
	check(Execution.consumed(original,{"kind":"move","execution_continuation":true})==original,
		"缺少已发布步骤身份的旧命令也不能错误消费当前队首")
	check(Execution.consumed(later.context,later.action).steps==[funding], "已重排队列和未重排队列消费同一个精确义务")

func _selected_wait_keeps_the_real_tail() -> void:
	var world := _world()
	var employee := world.add_card("employee",0)
	var waiting := {"kind":"wait","intent":"wait"}
	var dispatch := {"kind":"move","ids":[employee],"group":_target(world),"intent":"staff"}
	var commands := [_describe_command(world,0.0,waiting),_describe_command(world,6.0,waiting),
		_describe_command(world,12.0,dispatch)]
	var report := _report(world,commands)
	var bot := OffWorkBot.new(world,0)
	check(bot.commit_action(waiting,report),"选中先等待的完整路线可以提交当前等待")
	var context: Dictionary=bot.export_decision_context().get("execution_plan",{})
	if not need(context.get("steps",[]).size()==1,"首步等待仍保存后续派工，等待本身不占队首"): return
	check(context.source=="executable" and context.steps[0].kind=="move" and context.steps[0].ready_at==12.0,
		"两次等待合入实际动作的原定12秒时刻，不提前后续命令")
	world.advance(6.0)
	var early := Execution.resolve(world,0,context,-1)
	check(early.action.kind=="wait" and early.get("wait_reason","")=="scheduled" and early.context.steps.size()==1,
		"等待未结束时正确保留且阻塞依赖动作")
	world.advance(6.0)
	var ready := Execution.resolve(world,0,early.context,-1)
	check(ready.action.kind=="move" and ready.action.ids==[employee],"到期直接发布真实派工，不再重复等待")
	check(Actions.apply_action(world,0,ready.action) and world.tasks.get(employee,{}).get("kind","")=="work",
		"先等待路线最终使原员工真实投入工作")
	check(Execution.consumed(ready.context,ready.action).is_empty(),"兑现后清理完整等待路线")
	check(Execution.prepare(world,0,waiting,{"evaluation":{"sides":[{},{}]}},world.config.rules.bot).is_empty(),
		"没有被选中完整路线的普通等待不凭空新增承诺")

func _waits_become_dispatch_times() -> void:
	var world := _world()
	var buy := _offer(world,"employee")
	var branch := world.fork_for_bot(721)
	var commands := [_describe_command(branch,0.0,buy)]
	check(Actions.apply_search_action(branch,0,buy),"等待夹具按真实规则先购买员工")
	var employee: int=branch._owner_type(0,"employee").filter(func(id):return not world.cards.has(id))[0]
	commands.append(_describe_command(branch,6.0,{"kind":"wait"}))
	commands.append(_describe_command(branch,12.0,{"kind":"move","ids":[employee],"group":_target(world),"intent":"staff"}))
	var context := Execution.prepare(world,0,buy,_report(world,commands),world.config.rules.bot)
	check(context.steps.size()==1 and context.steps[0].kind=="move" and context.steps[0].ready_at==12.0,
		"购买后的中间等待也只保留在下一真实动作的时刻中")
	# A finite prefix may end with waits while its evaluated physical tail
	# contains a paid employee's dispatch. Removing waits must not drop it.
	var tail_report := _report(world,commands.slice(0,2))
	tail_report.evaluation.sides[0]["forecast_commands"]=[{"at":12.0,"kind":"worker","group":_target(world),
		"id":employee,"unit":{"role":"employee","count":1}}]
	var forecast := Execution.prepare(world,0,buy,tail_report,world.config.rules.bot)
	check(forecast.get("source","")=="forecast" and forecast.get("steps",[]).size()==1 \
		and forecast.steps[0].kind=="move" and forecast.steps[0].ready_at==12.0,
		"只有等待的前缀尾仍保存已付费人员物理预测中的实际派工")
	check(Actions.apply_action(world,0,buy),"中间等待夹具真实付款")
	world.advance(12.0)
	var ready := Execution.resolve(world,0,context,-1)
	check(ready.action.kind=="move" and Actions.apply_action(world,0,ready.action),"购买等待结束后真实人员能按绑定上工")

func _legacy_wait_expires_without_an_action() -> void:
	var world := _world()
	var employee := world.add_card("employee",0)
	var waiting := Execution.describe(world,0,{"kind":"wait"})
	waiting["ready_at"]=6.0
	var dispatch := Execution.describe(world,0,{"kind":"move","ids":[employee],"group":_target(world),"intent":"staff"})
	dispatch["ready_at"]=12.0
	var context := {"observed_at":0.0,"source":"executable","steps":[waiting,dispatch]}
	check(Execution.resolve(world,0,context,-1).context.steps.size()==2,"旧worker导入的未到期待机仍保留时间约束")
	world.advance(6.0)
	var unchanged := var_to_bytes([world.cards,world.groups,world.time])
	var expired := Execution.resolve(world,0,context,Time.get_ticks_usec()-1)
	check(expired.context==context,"解析截止时不提前修改导入计划")
	var next := Execution.resolve(world,0,context,-1)
	check(next.action.kind=="wait" and next.context.steps.size()==1 and next.context.steps[0].kind=="move",
		"旧等待到期自动移除，后续尚未到期的派工继续等到原时刻")
	check(unchanged==var_to_bytes([world.cards,world.groups,world.time]),"退役已到期等待不改牌桌，也不推进游戏时间")
	world.advance(6.0)
	var ready := Execution.resolve(world,0,next.context,-1)
	check(ready.action.kind=="move" and ready.action.ids==[employee],"旧队列的等待不会永久吞掉后续合法动作")

func _same_first_command_replaces_suffix() -> void:
	var world := _world()
	var first := world.add_card("employee",0)
	var second := world.add_card("employee",0)
	var deploy := {"kind":"move","ids":[first],"group":_target(world),"intent":"staff"}
	var old_head := Execution.describe(world,0,deploy)
	old_head["ready_at"]=0.0
	var old_tail := Execution.describe(world,0,{"kind":"move","ids":[first],"group":-1,"intent":"detach"})
	old_tail["ready_at"]=6.0
	var context := {"observed_at":0.0,"source":"executable","steps":[old_head,old_tail]}
	var selected := Execution.resolve(world,0,context,-1)
	check(selected.action.get("execution_continuation",false),"同首步重规划夹具确为旧队列已发布命令")
	var new_tail := {"kind":"move","ids":[second],"group":_target(world),"intent":"staff"}
	var report := _report(world,[_describe_command(world,0.0,deploy),_describe_command(world,6.0,new_tail)])
	var bot := OffWorkBot.new(world,0)
	bot.import_decision_context({"execution_plan":context})
	check(bot.commit_action(selected.action,report),"带旧continuation标记的同首步仍能正常提交")
	var adopted: Dictionary=bot.export_decision_context().get("execution_plan",{})
	check(adopted.get("steps",[]).size()==1 and adopted.steps[0].items[0].get("id",-1)==second,
		"实际被评分选中的新完整尾替换旧尾，不能因首步相同而丢弃")
	world.advance(6.0)
	var follow := Execution.resolve(world,0,adopted,-1)
	check(follow.action.get("ids",[])==[second] and bot.commit_action(follow.action,{"execution_continuation":true}),
		"下一行动执行新方案的第二名员工派工")
	check(world.tasks.has(first) and world.tasks.has(second),"旧计划的撤回动作未被误执行，两名人员实际工作")

func _explicit_prefix_keeps_scored_dispatch_tail() -> void:
	var world := _world()
	var employee := world.add_card("employee",0)
	var coffee := world.add_card("coffee",0)
	var first := {"kind":"wait"}
	var upgrade := {"kind":"move","ids":[coffee,employee],"group":-1,"intent":"coffee"}
	var report := _report(world,[_describe_command(world,0.0,first),_describe_command(world,6.0,upgrade)])
	report.evaluation.sides[0]["forecast_commands"]=[{"at":12.0,"kind":"worker","group":_target(world),
		"id":employee,"unit":{"role":"grinder","count":1}}]
	var plan := Execution.prepare(world,0,first,report,world.config.rules.bot)
	if not need(plan.get("steps",[]).size()==2,"显式升级前缀不能丢掉被尾部ETA计入的返岗"): return
	check(plan.steps[0].ready_at==6.0 and plan.steps[1].ready_at==12.0,"完整收益所需两步保持同一根时钟")
	world.advance(6.0)
	var next := Execution.resolve(world,0,plan,-1)
	check(next.action.kind=="move" and Actions.apply_action(world,0,next.action),"升级在真实行动槽执行")
	plan=Execution.consumed(next.context,next.action)
	world.advance(6.0)
	var returning := Execution.resolve(world,0,plan,-1)
	check(returning.action.kind=="move" and Actions.apply_action(world,0,returning.action),"保留的物理尾返岗可真正执行")
	check(world.tasks.get(employee,{}).get("kind","")=="work","升级收益最终落实到真实工作，不能只保存投资步骤")
