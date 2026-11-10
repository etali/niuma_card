# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
var fixture: Dictionary

func _initialize() -> void: _run.call_deferred()

func _restore() -> OffWorkState:
	var config := OffWorkConfig.new(fixture.cards)
	config.rules.bot=fixture.policy.duplicate(true)
	var world := OffWorkState.new(config)
	var raw := Marshalls.base64_to_raw(fixture.snapshot.data).decompress(int(fixture.snapshot.size),FileAccess.COMPRESSION_ZSTD)
	var entry: Dictionary=bytes_to_var(raw)
	for key in OffWorkState.WORLD_FIELDS: world.set(key,entry.world[key])
	world._rng.state=entry.rng
	world._invalidate_group_index()
	world.drain_events()
	return world

func _run() -> void:
	fixture=JSON.parse_string(FileAccess.get_file_as_string("res://tests/off_work/fixtures/off_work_growth_market_choice_20261110.json"))
	var world := _restore()
	check(world.time==40.0 and world.available_money(1)==4,"真实40秒局面保留4钱，没有补发资金")
	check(OffWorkConfig.decision_budget_ms(world.config.rules.bot)==1800 and world.config.rules.bot.think_seconds==2.0,
		"使用录像实际1档的1800毫秒预算和2秒操作间隔")
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		check(world.config.work_batch_size(kind,800)==1,"升级%s仍每轮一份，不修改容量"%kind)
	_market_certificate(world)
	var actual := _restore()
	var bot := Bot.new(actual,1,actual.config.rules.bot,20261110)
	var action: Dictionary=bot.decide_action()
	var report: Dictionary=bot.last_decision
	var sides: Array=report.get("evaluation",{}).get("sides",[])
	print("MARKET_ACTUAL ",JSON.stringify({"action":action,"budget_ms":report.budget_ms,"elapsed_us":report.elapsed_us,
		"layer":report.get("evaluation_layer"),"root_growth":report.get("root_growth",{}),
		"eta":sides.map(func(side):return side.get("eta")),
		"selected_growth":sides[1].get("production_chain",{}).get("growth",{}) if sides.size()==2 else {}}))
	check(not report.get("overrun",true),"实际完整BOT决策没有超出1800毫秒")
	check(bot.commit_action(action,report),"实际所选路线通过真实规则；不强迫首步必须买员工")
	_replay_bot_decision(_restore(),report)
	finish()

# An explicit legal certificate exercises purchase accounting and a multi-step
# consequence. It is not a BOT prescription or a demand that a particular
# low-level planner find this route before its wall-clock deadline.
func _market_certificate(world: OffWorkState) -> void:
	var baseline: Dictionary=Evaluation.new().evaluate_current(world,1,world.config.rules.bot,-1,[1.0,0.0])
	if not need(baseline.get("complete",false),"同局面的静态尾估值完成"): return
	var branch := _restore()
	var commands := []
	var generated: Dictionary=Actions.generate(branch,1,branch.config.rules.bot,-1)
	var buys: Array=generated.actions.filter(func(action):return action.kind=="buy" and action.get("card_type","")=="employee")
	if not need(not buys.is_empty(),"原始4钱局面确有可支付的公开员工报价"): return
	var before: Array=branch._owner_type(1,"employee").duplicate()
	if not need(_certificate_command(branch,buys[0],0.0,commands),"证书先通过真实购买规则付款"): return
	var added: Array=branch._owner_type(1,"employee").filter(func(id):return not before.has(id))
	if not need(added.size()==1 and branch.available_money(1)==0,"购买支付真实4钱，不预支后续工资"): return
	var bought: int=added[0]
	branch.advance(2.0)
	generated=Actions.generate(branch,1,branch.config.rules.bot,-1)
	var placements: Array=generated.actions.filter(func(action):return action.kind=="move" and action.get("ids",[]).has(bought) \
		and branch.groups.has(int(action.get("group",-1))) and not branch.group_work(int(action.group)).is_empty())
	if not need(not placements.is_empty() and _certificate_command(branch,placements[0],2.0,commands),
		"购买后的下个真实行动槽存在合法派工，不免费部署"): return
	check(branch.tasks.get(bought,{}).get("kind","")=="work","新买员工真正开始处理工作")
	branch.advance(2.0)
	generated=Actions.generate(branch,1,branch.config.rules.bot,-1)
	var upgrades: Array=generated.actions.filter(func(action):return action.get("intent","")=="coffee" \
		and world.cards.has(int(action.get("person",-1))))
	upgrades.sort_custom(func(a,b):return a.ids.size()<b.ids.size())
	if not need(not upgrades.is_empty() and _certificate_command(branch,upgrades[0],4.0,commands),
		"采购及派工之后仍可通过普通动作开始现有员工的真实升级"): return
	var person: int=upgrades[0].person
	var rank: int = world.config.coffee_rank(str(world.cards[person].type))
	var at := 6.0
	while at<=40.0:
		branch.advance(world.time+at-branch.time)
		if branch.config.coffee_rank(str(branch.cards[person].type))>rank: break
		at+=2.0
	if not need(at<=40.0,"升级实际完成，没有用预计产物替代真实人员"): return
	generated=Actions.generate(branch,1,branch.config.rules.bot,-1)
	var returns: Array=generated.actions.filter(func(action):return action.kind=="move" and action.get("ids",[]).has(person) \
		and branch.groups.has(int(action.get("group",-1))) and not branch.group_work(int(action.group)).is_empty())
	if not need(not returns.is_empty() and _certificate_command(branch,returns[0],at,commands),"升级完成后的合法行动槽返岗"): return
	check(branch.tasks.get(person,{}).get("kind","")=="work","升级的人实际返回工作，没有把库存或等级充作收益")
	var value: Dictionary=Evaluation.new().evaluate_current(branch,1,branch.config.rules.bot,-1,[1.0,2.0])
	if not need(value.get("complete",false),"完整采购前缀使用公共完工时间评价"): return
	var eta := at+float(value.detail.sides[1].eta)
	check(eta<float(baseline.detail.sides[1].eta),"真实采购、派工与升级证书改善同根时钟ETA，没有人员资产加分")
	var replay := _restore()
	var legal := true
	for command in commands:
		replay.advance(world.time+float(command.at)-replay.time)
		legal=Actions.apply_action(replay,1,command.action) and legal
	check(legal,"证书每条指令独立从原始观察重放，不调用BOT或代替真实付款")
	check([replay.work_count(0),replay.work_count(1),replay.money(0),replay.money(1)] \
		==[branch.work_count(0),branch.work_count(1),branch.money(0),branch.money(1)],"重放的工作与现金等于证书状态")
	var fresh: Dictionary=Evaluation.new().evaluate_current(replay,1,replay.config.rules.bot,-1,[1.0,2.0])
	check(fresh.complete and is_equal_approx(at+float(fresh.detail.sides[1].eta),eta),"独立重放后公共ETA一致")
	print("MARKET_CERTIFICATE ",JSON.stringify({"base_eta":baseline.detail.sides[1].eta,"eta":eta,"commands":commands}))

func _certificate_command(world: OffWorkState, action: Dictionary, at: float, commands: Array) -> bool:
	if not is_equal_approx(world.time,float(fixture.time)+at) or (not commands.is_empty() and at<float(commands[-1].at)+2.0-1e-8): return false
	if not Actions.apply_action(world,1,action): return false
	commands.append({"at":at,"action":action.duplicate(true)})
	return true

func _replay_bot_decision(source: OffWorkState, report: Dictionary) -> void:
	var line: Array=report.get("principal_variation",[])
	if not need(not line.is_empty() and not report.get("fallback",true),"完整BOT入口发布实际所选动作的完整评价与合法前缀"): return
	# Use the same declared simulation sample, never the hidden future market.
	# Every subsequent command is replayed through the authoritative rules.
	var sample_seed := hash([1,int(source.time*1000.0),source._supply_count,source._next_offer,87121])
	var actual := source.fork_for_bot(sample_seed)
	var next := [source.time+1.0,source.time]
	var legal := true
	for step in line:
		var actor := int(step.seat)
		var at := float(step.seconds)
		if actor not in [0,1] or at<float(next[actor])-1e-8: legal=false;break
		var slot := (at-source.time-(1.0 if actor==0 else 0.0))/2.0
		if not is_equal_approx(slot,roundf(slot)): legal=false;break
		legal=actual.advance_for_search(at-actual.time,-1) and legal
		actual.mask_search_market(source._next_offer)
		legal=Actions.apply_action(actual,actor,step) and legal
		next[actor]=at+2.0
	check(legal,"完整BOT选择的双方前缀逐条合法重放，双方操作都占真实时隙")
	if not legal: return
	var detail: Dictionary=report.evaluation
	var sides: Array=detail.get("sides",[])
	var chain: Dictionary=sides[1].get("production_chain",{}) if sides.size()==2 else {}
	var offset := float(report.get("forecast_root_offset_seconds",1.0))
	var elapsed := float(chain.elapsed) if not chain.is_empty() else offset
	if actual.winner<0: actual.advance_for_search(maxf(0.0,source.time+elapsed-actual.time),-1)
	actual.mask_search_market(source._next_offer)
	var clock: Array=chain.get("next_actions",[maxf(0.0,float(next[0])-actual.time),maxf(0.0,float(next[1])-actual.time)])
	var fresh: Dictionary=Evaluation.new().evaluate_current(actual,1,source.config.rules.bot,-1,clock)
	if not need(fresh.get("complete",false),"BOT实际前缀尾部完成同口径重评，没有使用半截搜索分数"): return
	if detail.get("terminal",false):
		check(actual.winner==int(detail.winner),"已认证终局能够通过真实前缀重现")
	elif sides.size()==2 and not fresh.detail.get("terminal",false):
		for seat in 2:
			check(is_equal_approx(elapsed+float(fresh.detail.sides[seat].eta),offset+float(sides[seat].eta)),
				"BOT所选路线的座位%d完工收益与同根时钟真实重放一致"%seat)
