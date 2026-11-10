# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Continuations = preload("res://engine/off_work_bot_continuation_plans.gd")
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_clock_grid(0.0,12.0)
	_clock_grid(2.0,14.0)
	_future_context_does_not_block_ordinary_actions()
	finish()

func _fixture(upgrading := true) -> Dictionary:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"work":80},{"employee":1}]
	config.rules.initial.money=0
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.bot.think_seconds=6.0
	config.rules.bot.evaluation_max_seconds=60.0
	config.rules.coffee.seconds=10.0
	config.rules.coffee.upgrades.employee["seconds"]=10.0
	var world := OffWorkState.new(config)
	world.new_game(20261110)
	world.advance(100.0)
	world.offers.clear()
	var employee: int=world._owner_type(0,"employee")[0]
	var group: int=world.cards[world._owner_type(0,"work")[0]].group
	if upgrading:
		var coffee := world.add_card("coffee",0)
		check(Actions.apply_action(world,0,{"kind":"move","ids":[employee,coffee],"group":-1,"person":employee}),
			"通过正式规则开启100到110秒的已付费升级")
	var future := world.fork_for_bot(1906)
	if upgrading: future.advance(10.0)
	var action := {"kind":"move","intent":"assemble_work","ids":[employee],"group":group,"person":-1}
	var step := Execution.describe(future,0,action)
	step.ready_at=110.0 if upgrading else 148.0
	return {"world":world,"context":{"observed_at":100.0,"steps":[step]},"employee":employee,"group":group}

func _clock_grid(first: float, expected: float) -> void:
	var row := _fixture()
	var before := var_to_bytes([row.world.cards,row.world.tasks,row.world.time,row.world._rng.state])
	var observed := {"earliest":INF,"aligned":true,"legal":true,"count":0}
	Continuations.visit(row.world,0,row.world.config.rules.bot,-1,[first,3.0],func(plan):
		var replay: OffWorkState=row.world.fork_for_bot(1906)
		for command in plan.commands:
			var at := float(command.at)
			observed.aligned=observed.aligned and absf((at-first)/6.0-roundf((at-first)/6.0))<1e-8
			replay.advance(100.0+at-replay.time)
			var deploy: bool=command.action.get("ids",[]).has(row.employee) and int(command.action.get("group",-1))==int(row.group)
			if deploy and replay.config.coffee_rank(str(replay.cards[row.employee].type))>0:
				observed.count+=1
				observed.earliest=minf(float(observed.earliest),at)
				observed.legal=observed.legal and replay.tasks.get(row.employee,{}).get("kind","")!="coffee"
			observed.legal=Actions.apply_action(replay,0,command.action) and observed.legal,
		Callable(),{"execution_context":row.context,"expansion_limit":40,"depth_limit":4})
	check(observed.count>0 and is_equal_approx(float(observed.earliest),expected),
		"统一动作树在真实升级结束后的首个合法时隙提供返岗：偏移%s，预期%s"%[first,expected])
	check(observed.aligned and observed.legal,"所有前缀按根行动钟合法重放，完成升级后的返岗不制造额外时隙")
	check(before==var_to_bytes([row.world.cards,row.world.tasks,row.world.time,row.world._rng.state]),"续搜不改原始升级、人员和时钟")

func _future_context_does_not_block_ordinary_actions() -> void:
	var row := _fixture(false)
	var generated: Dictionary=Actions.generate(row.world,0,row.world.config.rules.bot,-1)
	var observed := {"dispatch":false,"plans":0}
	var status: Dictionary=Continuations.visit(row.world,0,row.world.config.rules.bot,-1,[0.0,3.0],func(plan):
		observed.plans+=1
		var action: Dictionary=plan.commands[0].action
		observed.dispatch=observed.dispatch or (action.get("ids",[]).has(row.employee) and int(action.get("group",-1))==int(row.group)),
		Callable(),{"execution_context":row.context,"depth_limit":1,"expansion_limit":generated.actions.size()+2})
	check(observed.dispatch and observed.plans>1 and status.root_serviced>=generated.actions.size(),
		"旧计划远期ready不会独占等待队列：当前可执行的返岗及其他合法根动作仍全部参与同一搜索")
