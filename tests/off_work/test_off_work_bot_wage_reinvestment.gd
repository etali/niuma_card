# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/off_work/test_off_work_bot_growth_forecast.gd"

## A paired economic certificate, not a required BOT recipe. Both worlds
## begin with the same operating coffee line. One spends a real cup and
## action slots on an upgrade; the control keeps the person at work. The
## same later recruitment decision spends only each world's actual cash.
## This certifies the objective and execution, not finite-budget discovery
## or superiority over every possible non-upgrade investment schedule.
func _run() -> void:
	for work in [400,800,2000]:
		var upgraded := _certificate(work,true)
		var control := _certificate(work,false)
		print("WAGE_REINVESTMENT_CERTIFICATE ",JSON.stringify({"work":work,"upgrade":upgraded,"control":control}))
		check(upgraded.before_upgrade_cash==control.before_upgrade_cash and upgraded.before_upgrade_work==control.before_upgrade_work,
			"%d工作：分支从相同初始现金、人员与工作进度开始"%work)
		check(upgraded.cash_at_reinvestment>control.cash_at_reinvestment,
			"%d工作：升级后的工资已真正入账，未把未来现金提前使用"%work)
		check(upgraded.spent_at_reinvestment>control.spent_at_reinvestment,
			"%d工作：同一时刻按同一全额招聘规则花掉实际多出的工资"%work)
		check(upgraded.eta<control.eta and upgraded.finished_at<control.finished_at,
			"%d工作：配对路线的工资再投资改善预计与实际完工时间"%work)
	if OS.get_cmdline_user_args().has("--inspect-search"):
		for with_coffee in [true,false]:
			var best := _project(_wage_world(with_coffee))
			print("WAGE_SEARCH_CERTIFICATE ",JSON.stringify({"with_coffee":with_coffee,
				"eta":best.eta,"elapsed":best.elapsed,"commands":best.commands}))
	finish()

func _certificate(work: int, upgrade: bool) -> Dictionary:
	var world := _world(work,true,true,10)
	var wage := 1
	for kind in ["employee","grinder","workaholic","work_emperor"]:
		world.config.roles[kind].work_capacity=1
		world.config.roles[kind].work_income_multiplier=wage
		wage*=2
	world.config.rules.bot.evaluation_max_seconds=1800.0
	world.drain_events()
	var person: int=world._owner_type(0,"employee")[0]
	var target: int=world.cards[person].group
	var boss: int=world._owner_type(0,"boss")[0]
	var steps := []
	check(_certificate_command(world,{"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1},0.0,steps),
		"首批招聘按真实价格付款，不改变卡表")
	world.advance(10.0-world.time)
	var idle: Array=world._owner_type(0,"employee").filter(func(id):return not world.tasks.has(id))
	check(_certificate_command(world,{"kind":"move","ids":idle,"group":target},10.0,steps),"招聘完成后才将真实新员工派工")
	world.advance(12.0-world.time)
	var before_upgrade_cash := world.available_money(0)
	var before_upgrade_work := world.work_count(0)
	if upgrade:
		var cup: int=world._owner_type(0,"coffee")[0]
		check(_certificate_command(world,{"kind":"move","ids":[person,cup],"group":-1},12.0,steps),
			"升级按真实配方拆出工作人员、消耗已产出的咖啡")
	else:
		check(_certificate_command(world,{"kind":"wait"},12.0,steps),"反事实保留原工人，未暗中补偿咖啡收益")
	world.advance(18.0-world.time)
	check(_certificate_command(world,{"kind":"move","ids":[person],"group":target} if upgrade else {"kind":"wait"},18.0,steps),
		"两路线都占用相同操作槽，升级路线按真实完成时间返岗")
	world.advance(30.0-world.time)
	var cash := world.available_money(0)
	var remaining_at_reinvestment := world.work_count(0)
	check(_certificate_command(world,{"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1},30.0,steps),
		"后续统一使用全部现有资金，招聘数量由真实规则计算")
	var reserved := world.reserved_money(0)
	check(reserved<=cash,"没有为正例预支工资或给反事实增加资金限制")
	world.advance(40.0-world.time)
	var spending := -1
	for event in world.drain_events():
		if event.kind=="recruitment_complete" and int(event.owner)==0 and is_equal_approx(float(event.time),40.0):
			spending=int(event.spent)
	check(spending==reserved,"真实招聘完成事件支出等于此前保留的资金，未仅认证预约")
	idle=world._owner_type(0,"employee").filter(func(id):return not world.tasks.has(id))
	check(_certificate_command(world,{"kind":"move","ids":idle,"group":target},40.0,steps),"第二次招聘完成后才部署新员工")
	var value: Dictionary=Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,[2.0,1.0])
	check(value.get("complete",false) and not value.detail.get("terminal",true),"完工评价完成，没有使用截断或未完成结果")
	var eta := world.time+float(value.detail.sides[0].eta)
	world.advance(eta-world.time+20.0)
	check(world.winner==0 and world.work_count(0)==0,"证书真实推进到完工，不把预测值当实际结果")
	check(is_equal_approx(world.time,eta),"统一评价与实际规则完工时间一致")
	return {"eta":eta,"finished_at":world.time,"cash_at_reinvestment":cash,"spent_at_reinvestment":spending,
		"work_at_reinvestment":remaining_at_reinvestment,"before_upgrade_cash":before_upgrade_cash,
		"before_upgrade_work":before_upgrade_work,"commands":steps}

func _certificate_command(world: OffWorkState, action: Dictionary, at: float, steps: Array) -> bool:
	if at<world.time-1e-8 or (not steps.is_empty() and at<float(steps[-1].at)+2.0-1e-8): return false
	world.advance(at-world.time)
	if not Actions.apply_action(world,0,action): return false
	steps.append({"at":at,"action":action.duplicate(true)})
	return true
