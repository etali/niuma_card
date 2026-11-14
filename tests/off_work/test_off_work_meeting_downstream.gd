# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Plans = preload("res://engine/off_work_bot_attack_plans.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Forecast = preload("res://engine/off_work_bot_forecast_commands.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Clock = preload("res://engine/off_work_progress_clock.gd")

func _initialize() -> void:
	_existing_group()
	_cooldown_and_occupied_host()
	_staggered_cooldown()
	finish()

func _fixture() -> Dictionary:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":12,"work":200}]
	config.rules.initial.money = 0
	config.rules.conveyor.interval_seconds = 1000.0
	config.rules.meeting.auto_repeat = true
	var world := OffWorkState.new(config)
	world.new_game(419)
	world.offers.clear()
	var group := world.create_group(0)
	var hosts := []
	for kind in ["leader", "employee", "grinder"]: hosts.append(world.add_card(kind,0,group))
	var tools := [world.add_card("meeting",0,group),world.add_card("meeting",0,group)]
	world.drain_events()
	return {"world":world,"group":group,"hosts":hosts,"tools":tools}

func _plan(f: Dictionary) -> Dictionary:
	var plans: Dictionary = Plans.plans(f.world,0)
	var grouped: Array = plans.plans.filter(func(plan):return plan.get("meeting_group",-1)==f.group)
	check(plans.complete and grouped.size()==1, "现有多人多牌组合只生成一个共享会议方案")
	return grouped[0] if grouped.size()==1 else {}

func _candidate(world: OffWorkState, plan: Dictionary) -> Dictionary:
	var evaluator := Evaluation.new()
	var prepared: Dictionary = evaluator._prepare_evaluation(world,0,world.config.rules.bot,-1,[0.0,0.0])
	return evaluator._attack_candidate(world,prepared.models[0],prepared.models[1],plan)

func _existing_group() -> void:
	var f := _fixture()
	var world: OffWorkState = f.world
	var snapshot := var_to_bytes([world.cards,world.groups,world.tasks,world.meetings,world._rng.state])
	var plan := _plan(f)
	if plan.is_empty(): return
	check(var_to_bytes([world.cards,world.groups,world.tasks,world.meetings,world._rng.state])==snapshot,
		"枚举共享方案不改真人局面和私有RNG")
	check(plan.hosts==world.group_meeting_hosts(f.group) and plan.tools==f.tools,
		"方案保留全部真实主持人与开会牌")
	check(plan.targets.size()==world.group_meeting_capacity(f.group) and plan.capacity==8,
		"人数读取共享规则，领导4加两名普通/升级人员各2")
	check(is_equal_approx(plan.duration_seconds,world.group_meeting_duration(f.group)),
		"时长读取共享组合规则，不独立复制叠加公式")
	var candidate := _candidate(world,plan)
	if not need(not candidate.is_empty(), "完整共享方案可进入现有评估器"): return
	var uses: Array = candidate.own.events.filter(func(event):return event.kind=="meeting_host")
	check(uses.size()==1 and uses[0].ids==f.hosts, "一次真实会议占用所有主持人，仍只占一次启动动作")
	var returns: Array = candidate.own.events.filter(func(event):return event.kind=="worker" and f.hosts.has(event.id))
	check(returns.size()==2 and returns.all(func(event):return is_equal_approx(event.lag,plan.duration_seconds+world.config.rules.bot.think_seconds)),
		"两名可工作人员均在共享时长结束后返岗，非工作领导不虚增产能")
	var evaluator := Evaluation.new()
	evaluator._config = world.config
	evaluator._period = world.config.rules.bot.think_seconds
	var context: Dictionary = evaluator._context(candidate.own)
	evaluator._apply_forecast_event(context,uses[0])
	check(context.groups.values().all(func(group):return f.hosts.all(func(id):return not group.present.has(id) and not group.workers.has(id))),
		"会议事件从所有工作/在场集合移出全部主持人")
	var action := {"kind":"activate","tool":f.tools[0],"group":f.group,"person":f.hosts[0],"intent":"meeting"}
	check(Forecast._matches_attack(world,action,plan), "共享预测匹配原组启动动作")
	var split: Dictionary = Plans.plans(world,0).plans.filter(func(row):return row.get("host",-1)==f.hosts[0] and not row.has("meeting_group"))[0]
	check(not Forecast._matches_attack(world,action,split), "不能把多人原组启动冒充单人拆组的成本")
	var generated: Dictionary = Actions.generate(world,0,world.config.rules.bot,-1)
	check(generated.complete and generated.actions.any(func(command):return Forecast._matches_attack(world,command,plan)),
		"预测使用的整组启动在原合法动作生成器中存在")
	world._rng.seed = plan.sample_seed
	check(Actions.apply_action(world,0,action), "共享方案经真实规则成功执行")
	var active: Dictionary = world.meeting_for_tool(f.tools[1])
	check(not active.is_empty() and active.targets==plan.targets and active.hosts.size()==plan.hosts.size(),
		"次要开会牌查询同一会议，实际目标样本/主持数量与预测一致")
	world.advance(2.0)
	check(is_equal_approx(Clock.remaining(world,f.tools[0],"meeting",0.0),Clock.remaining(world,f.tools[1],"meeting",0.0))
		and is_equal_approx(Clock.remaining(world,f.tools[1],"meeting",0.0),world.meeting_for_tool(f.tools[1]).remaining),
		"每张开会牌显示同一个剩余时间，不依赖主tool字典键")

func _cooldown_and_occupied_host() -> void:
	var f := _fixture()
	var world: OffWorkState = f.world
	for tool in f.tools:
		world.cards[tool].status="recovering"
		world.cards[tool].remaining=5.0
		world.cards[tool].total=world.config.number("meeting","recovery_seconds")
		world.cards[tool]["meeting_repeat"]=true
	var plan := _plan(f)
	if plan.is_empty(): return
	var candidate := _candidate(world,plan)
	check(not candidate.is_empty() and candidate.detail.natural_restart and candidate.detail.use_at==5.0,
		"共享冷却自然重启保留原真实到期时间")
	var split: Dictionary = Plans.plans(world,0).plans.filter(func(row):return row.get("host",-1)==f.hosts[0] and not row.has("meeting_group"))[0]
	check(_candidate(world,split).is_empty(), "单主持预测不能偷借全组自动重启的容量/时间")
	world.cards[f.hosts[1]].status="striking"
	world.cards[f.hosts[1]].remaining=20.0
	check(_candidate(world,plan).is_empty(), "任一必需主持人被暂停，旧完整共享方案不能继续生效")

func _staggered_cooldown() -> void:
	var f := _fixture()
	var world: OffWorkState = f.world
	var tool: int = f.tools[1]
	world.cards[tool].status="recovering"
	world.cards[tool].remaining=9.0
	world.cards[tool].total=world.config.number("meeting","recovery_seconds")
	world.cards[tool]["meeting_repeat"]=true
	var plan := _plan(f)
	if plan.is_empty(): return
	check(world.cards[plan.tool].status=="ready" and plan.ready_seconds==world.group_meeting_ready_seconds(f.group)
		and plan.ready_seconds==9.0, "代表牌已就绪仍等待整组最后冷却结束")
	var candidate := _candidate(world,plan)
	check(not candidate.is_empty() and candidate.detail.natural_restart and candidate.detail.use_at==9.0,
		"其他开会牌的重复标记使整组到期自然重启，不另付动作延迟")
	world.advance(5.0)
	check(world.meetings.is_empty(), "真实规则不会因第一张已就绪而抢先启动")
	world.advance(4.0)
	var meeting: Dictionary = world.meeting_for_tool(f.tools[0])
	check(not meeting.is_empty() and meeting.tools.size()==2 and is_equal_approx(meeting.remaining,plan.duration_seconds),
		"错开冷却的真实启动时间、共享时长与预测一致")
