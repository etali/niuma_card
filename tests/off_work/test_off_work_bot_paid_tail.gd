extends SceneTree

const Growth=preload("res://engine/off_work_bot_growth_plans.gd")
const Evaluation=preload("res://engine/off_work_bot_evaluator.gd")
const Execution=preload("res://engine/off_work_bot_execution_plan.gd")
const Actions=preload("res://engine/off_work_bot_actions.gd")
var checks:=0
var failures:Array[String]=[]

func _initialize() -> void:
    _run.call_deferred()

func check(ok:bool,message:String) -> void:
    checks+=1
    if not ok: failures.append(message)

func _run() -> void:
    var config:=OffWorkConfig.new()
    config.rules.initial.groups=[{"work":800},{"employee":1}]
    config.rules.initial.money=1
    var world:=OffWorkState.new(config)
    world.new_game(11011)
    check(config.errors.is_empty() and world.last_error.is_empty(),"valid real-rule fixture: %s %s" % [config.errors,world.last_error])
    if world.groups.is_empty(): _finish();return
    world.advance(30.0)
    var target: int=world.groups.keys().filter(func(gid):return world.groups[gid].owner==0 and not world.group_work(gid).is_empty())[0]
    world.add_card("overtime",0,target)
    world.add_card("overtime",0,target)
    var worker: int=world._owner_type(0,"employee")[0]
    var tool:=world.add_card("slack",0)
    world.add_card("coffee",0)
    check(world.move_cards([worker,tool],-1)>=0,"real fixture employee starts in a coffee-producing group")
    var evidence:Dictionary={}
    Growth.visit(world,0,config.rules.bot,-1,[0.0,3.0],func(plan):
        if plan.growth.finish_production or not evidence.is_empty(): return
        var evaluator:=Evaluation.new()
        var value:Dictionary=evaluator.evaluate_current(plan.world,0,config.rules.bot,-1,plan.next_actions)
        check(value.complete,"the complete prefix receives a complete common-clock physical forecast")
        var own:Dictionary=value.detail.sides[0].duplicate(true)
        # Capture the future rank/source job in the leaf BEFORE translating
        # the numeric ETA to the observation's clock.
        own.forecast_steps=Execution.physical_steps(plan.world,0,own.forecast_commands)
        evaluator._offset_forecast(own,plan.elapsed)
        own.production_chain={"kind":plan.kind,"commands":plan.commands.duplicate(true)}
        evidence.merge({"first":plan.commands[0].action.duplicate(true),"own":own,"prefix":plan.commands.duplicate(true)},true),Callable(),
        {"consume_immediately":true,"checkpoint_limit":1,"allow_purchase":false})
    check(not evidence.is_empty(),"real rule planner produces the recorded upgrade/resume kind of prefix")
    if evidence.is_empty(): _finish();return
    check(evidence.prefix.size()==2 and evidence.prefix[0].action.growth_intent=="growth_upgrade" and evidence.prefix[1].action.growth_intent=="growth_resume","the regression has an upgrade followed by a nonempty resume prefix")
    var report:Dictionary={"evaluation":{"sides":[evidence.own,{}]},"forecast_root_offset_seconds":0.0}
    var context:Dictionary=Execution.prepare(world,0,evidence.first,report,config.rules.bot)
    check(context.get("steps",[]).size()==2,"nonempty investment prefix preserves its separately credited return-to-work tail")
    if context.get("steps",[]).size()!=2: _finish();return
    check(is_equal_approx(context.steps[0].ready_at,36.0) and is_equal_approx(context.steps[1].ready_at,42.0),"absolute return time is root+12, not leaf+12 or a free immediate action")
    check(context.steps[1].items.any(func(item):return int(item.get("id",-1))==worker and item.type=="grinder" and item.job=="slack"),"leaf binding retains this future grinder and its real ongoing slack job")
    var no_tail_report:Dictionary=report.duplicate(true)
    no_tail_report.evaluation.sides[0].erase("forecast_steps")
    no_tail_report.evaluation.sides[0].erase("forecast_commands")
    var no_tail_context:Dictionary=Execution.prepare(world,0,evidence.first,no_tail_report,config.rules.bot)
    check(no_tail_context.steps.size()==1,"a prefix with no credited tail does not invent a forced return command")
    var control:=world.fork_for_bot(11011)
    check(Actions.apply_action(world,0,evidence.first) and Actions.apply_action(control,0,evidence.first),"both counterfactuals pay the same real upgrade ingredients")
    world.advance(6.0)
    control.advance(6.0)
    check(world.cards[worker].type=="grinder" and control.cards[worker].type=="grinder","both branches finish the same actual upgrade")
    var resume:=Execution.resolve(world,0,context,-1)
    var control_resume:=Execution.resolve(control,0,no_tail_context,-1)
    check(resume.action.kind=="move" and control_resume.action.kind=="move" and Actions.apply_action(world,0,resume.action) and Actions.apply_action(control,0,control_resume.action),"both branches legally execute the original resume command")
    context=Execution.consumed(resume.context,resume.action)
    no_tail_context=Execution.consumed(control_resume.context,control_resume.action)
    check(Execution.resolve(world,0,context,-1).action.kind=="wait","the preserved return cannot bypass its next paid action slot")
    world.advance(6.0)
    control.advance(6.0)
    var returning:=Execution.resolve(world,0,context,-1)
    check(returning.action.kind=="move" and returning.action.ids.has(worker) and Actions.apply_action(world,0,returning.action),"the credited future return resolves to the same real worker and actually executes")
    check(world.tasks.get(worker,{}).get("kind","")=="work" and control.tasks.get(worker,{}).get("kind","")=="slack","preserving the score's tail changes physical production, not just metadata")
    check(Execution.resolve(control,0,no_tail_context,-1).action.kind=="wait","no-tail counterfactual remains uncommitted, with no card-specific dispatch rule")
    world.advance(10.0)
    control.advance(10.0)
    check(world.work_count(0)<control.work_count(0) and control.work_count(0)==800,"same-clock real remaining work falls only after executing the credited return")
    _finish()

func _finish() -> void:
    for failure in failures: printerr("FAIL ",failure)
    print("OFF_WORK_BOT_PAID_TAIL %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
    quit(0 if failures.is_empty() else 1)
