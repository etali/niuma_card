# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Execution = preload("res://engine/off_work_bot_execution_plan.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_late_recruitment_retains_dispatch()
	finish()

func _late_recruitment_retains_dispatch() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":80},{"boss":1}]
	config.rules.initial.money=10
	config.rules.conveyor.interval_seconds=10000.0
	config.rules.bot.think_seconds=6.0
	config.rules.bot.evaluation_max_seconds=30.0
	config.rules.recruitment.seconds=36.0
	var world := OffWorkState.new(config)
	world.new_game(20261110)
	world.offers.clear()
	var recruit := {"kind":"move","ids":world._owner_type(0,"boss")+world._owner_type(0,"money"),"group":-1}
	var root := world.fork_for_bot(20261110)
	if not need(Actions.apply_action(world,0,recruit),"真实支付招聘，人员将在30秒采样窗口之后产生"): return
	var before := var_to_bytes([world.cards,world.groups,world.tasks,world.time,world._rng.state])
	var evaluator := Evaluation.new()
	var prepared: Dictionary=evaluator._prepare_evaluation(world,0,config.rules.bot,-1,[6.0,3.0])
	var model: Dictionary=prepared.models[0]
	var model_before := var_to_bytes(model)
	var sampled: Dictionary=evaluator._forecast(model,30.0)
	var full: Dictionary=evaluator._forecast(model,120.0)
	check(sampled.get("eta_exact",false) and is_equal_approx(float(sampled.eta),float(full.eta)),
		"30秒和120秒采样使用相同已付费招聘尾，完工ETA一致")
	check(sampled.required_actions==full.required_actions and sampled.required_actions>0 \
		and sampled.forecast_commands==full.forecast_commands,
		"窗口后必要派工保留与长窗口完全相同的命令及动作责任")
	check(sampled.forecast_commands.any(func(command):return command.kind=="worker" and float(command.at)>=36.0),
		"执行证据明确含36秒招聘完毕后的真实人员派工")
	check(before==var_to_bytes([world.cards,world.groups,world.tasks,world.time,world._rng.state]) \
		and model_before==var_to_bytes(model),"外推命令证据不修改原状态或采样模型")
	var value: Dictionary=Evaluation.new().evaluate_current(world,0,config.rules.bot,-1,[6.0,3.0])
	var report := {"evaluation":value.detail,"forecast_root_offset_seconds":0.0}
	var context: Dictionary=Execution.prepare(root,0,recruit,report,config.rules.bot)
	check(not context.get("steps",[]).is_empty(),"BOT提交招聘时保存窗口之后的已付费返岗责任")
	world.advance(30.0)
	check(world.work_count(0)==int(sampled.remaining) and world.available_money(0)==int(sampled.cash),
		"30秒样本现金和剩余工作仍等于同一时刻的真实规则，没有混入未来收入")
	world.advance(6.0)
	var resolved: Dictionary=Execution.resolve(world,0,context,-1)
	check(resolved.action.kind=="move" and Actions.apply_action(world,0,resolved.action),
		"在36秒直接重绑并执行预测保存的派工，不依赖测试手写返岗命令")
	world.advance(10000.0)
	check(world.winner==0 and is_equal_approx(world.time,float(sampled.eta)),
		"保存的窗口后命令按真实规则完成，实际完工时间等于预测ETA")
