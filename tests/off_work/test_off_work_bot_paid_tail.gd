extends SceneTree

## A paid investment prefix (upgrade, then back to the coffee line) is followed by a return to
## work that the evaluator credits in its completion time. The saved execution context must
## keep that credited return as a real later command, at its own action slot.
##
## The prefix is built here by hand through the real rules, on a private branch, the way a
## continuation plan records it: each command with its time and its binding taken before it is
## applied. The planner that used to produce it for this test no longer exists.
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
    # The slots below are written for a five-second upgrade and six seconds between actions.
    config.rules.coffee.seconds=5.0
    config.rules.bot.think_seconds=6.0
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
    var cup:=world.add_card("coffee",0)
    check(world.move_cards([worker,tool],-1)>=0 and world.tasks.get(worker,{}).get("kind","")=="slack","real fixture employee starts in a coffee-producing group")
    var line: int=world.cards[worker].group
    var period: float=config.rules.bot.think_seconds

    # Prefix: pay the upgrade now, rejoin the coffee line at the next action slot.
    var upgrade:={"kind":"move","ids":[worker,cup],"group":-1,"person":worker,"intent":"coffee"}
    var leaf:=world.fork_for_bot(11011)
    var prefix:=[{"at":0.0,"action":upgrade.duplicate(true),"binding":Execution.describe(leaf,0,upgrade)}]
    check(Actions.apply_search_action(leaf,0,upgrade) and leaf.tasks.get(worker,{}).get("kind","")=="coffee","the prefix pays the real coffee recipe on its branch")
    leaf.advance_for_search(period,-1)
    check(leaf.cards[worker].type=="grinder","the upgrade completes before the next action slot")
    var resume:={"kind":"move","ids":[worker],"group":line,"intent":"slack_staff"}
    prefix.append({"at":period,"action":resume.duplicate(true),"binding":Execution.describe(leaf,0,resume)})
    check(Actions.apply_search_action(leaf,0,resume) and leaf.tasks.get(worker,{}).get("kind","")=="slack","the prefix returns the upgraded person to the coffee line")
    var evaluator:=Evaluation.new()
    var value:Dictionary=evaluator.evaluate_current(leaf,0,config.rules.bot,-1,[period,period*0.5])
    check(value.complete,"the complete prefix receives a complete common-clock physical forecast")
    if not value.complete: _finish();return
    var own:Dictionary=value.detail.sides[0].duplicate(true)
    # Capture the future rank/source job in the leaf BEFORE translating
    # the numeric ETA to the observation's clock.
    own.forecast_steps=Execution.physical_steps(leaf,0,own.forecast_commands)
    evaluator._offset_forecast(own,period)
    own.production_chain={"kind":"upgrade_resume","commands":prefix.duplicate(true)}
    check(own.forecast_steps.size()==1,"the forecast credits exactly one later return to work")
    if own.forecast_steps.size()!=1: _finish();return

    var report:Dictionary={"evaluation":{"sides":[own,{}]},"forecast_root_offset_seconds":0.0}
    var context:Dictionary=Execution.prepare(world,0,upgrade,report,config.rules.bot)
    check(context.get("steps",[]).size()==2,"nonempty investment prefix preserves its separately credited return-to-work tail")
    if context.get("steps",[]).size()!=2: _finish();return
    check(is_equal_approx(context.steps[0].ready_at,36.0) and is_equal_approx(context.steps[1].ready_at,42.0),"absolute return time is root+12, not leaf+12 or a free immediate action")
    check(context.steps[1].items.any(func(item):return int(item.get("id",-1))==worker and item.type=="grinder" and item.job=="slack"),"leaf binding retains this future grinder and its real ongoing slack job")
    var no_tail_report:Dictionary=report.duplicate(true)
    no_tail_report.evaluation.sides[0].erase("forecast_steps")
    no_tail_report.evaluation.sides[0].erase("forecast_commands")
    var no_tail_context:Dictionary=Execution.prepare(world,0,upgrade,no_tail_report,config.rules.bot)
    check(no_tail_context.steps.size()==1,"a prefix with no credited tail does not invent a forced return command")
    var control:=world.fork_for_bot(11011)
    check(Actions.apply_action(world,0,upgrade) and Actions.apply_action(control,0,upgrade),"both counterfactuals pay the same real upgrade ingredients")
    world.advance(period)
    control.advance(period)
    check(world.cards[worker].type=="grinder" and control.cards[worker].type=="grinder","both branches finish the same actual upgrade")
    var resumed:=Execution.resolve(world,0,context,-1)
    var control_resumed:=Execution.resolve(control,0,no_tail_context,-1)
    check(resumed.action.kind=="move" and control_resumed.action.kind=="move" and Actions.apply_action(world,0,resumed.action) and Actions.apply_action(control,0,control_resumed.action),"both branches legally execute the original resume step")
    context=Execution.consumed(resumed.context,resumed.action)
    no_tail_context=Execution.consumed(control_resumed.context,control_resumed.action)
    check(world.tasks.get(worker,{}).get("kind","")=="slack" and control.tasks.get(worker,{}).get("kind","")=="slack","both branches are back on the coffee line after the resume step")
    check(Execution.resolve(world,0,context,-1).action.kind=="wait","the preserved return cannot bypass its next paid action slot")
    world.advance(period)
    control.advance(period)
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
