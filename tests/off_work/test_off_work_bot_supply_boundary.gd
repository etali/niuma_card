# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Evaluation=preload("res://engine/off_work_bot_evaluator.gd")

func _initialize() -> void: _run.call_deferred()

func _world(work:=120, funds:=12, people:=1) -> OffWorkState:
    var config:=OffWorkConfig.new()
    config.rules.initial.groups=[{"employee":people,"work":work}]
    config.rules.initial.money=funds
    config.rules.bot.think_seconds=6.0
    config.rules.bot.evaluation_max_seconds=1800.0
    var world:=OffWorkState.new(config)
    world.new_game(11011)
    world.offers.clear()
    return world

func _value(world:OffWorkState, physical:=false) -> Dictionary:
    return Evaluation.new().evaluate_current(world,0,world.config.rules.bot,-1,[0.0,3.0]) if physical else Evaluation.new().evaluate(world,0,world.config.rules.bot,-1,[0.0,3.0])

func _run() -> void:
    _unknown_supply_is_neutral()
    _real_tools_keep_their_return()
    _unspent_wages_are_not_production()
    _wages_can_fund_owned_recruitment()
    finish()

func _unknown_supply_is_neutral() -> void:
    for physical in [true,false]:
        var world:=_world()
        var evaluator:=Evaluation.new()
        # Public entry points must reset any old search's supply estimate.
        evaluator._supply_wait=0.0
        var original:=var_to_bytes([world.cards,world.groups,world.time,world._rng.state])
        var baseline:Dictionary=evaluator.evaluate_current(world,0,world.config.rules.bot,-1,[0.0,3.0]) if physical else evaluator.evaluate(world,0,world.config.rules.bot,-1,[0.0,3.0])
        world.config.rules.conveyor.pool={"outsource":100000.0,"employee":1.0}
        var weighted:=_value(world,physical)
        check(baseline.complete and weighted.complete,"public %s evaluation completes" % ("physical" if physical else "economic"))
        check(is_equal_approx(baseline.detail.sides[0].eta,weighted.detail.sides[0].eta),"changing unseen outsource draw weight cannot improve public %s ETA" % ("physical" if physical else "economic"))
        check(not baseline.detail.sides[0].has("cashout") and not weighted.detail.sides[0].has("cashout"),"neither public lens invents an unobserved final outsource tool")
        check(var_to_bytes([world.cards,world.groups,world.time,world._rng.state])==original,"supply comparison does not read or mutate the real future market")

func _real_tools_keep_their_return() -> void:
    var world:=_world()
    var base:=_value(world,true)
    world.add_card("outsource",0)
    var owned:=_value(world,true)
    check(owned.detail.sides[0].eta<base.detail.sides[0].eta and owned.detail.sides[0].has("cashout"),"an actually owned tool still converts real wages to earlier completion")
    check(not owned.detail.sides[0].cashout.future_supply,"owned-tool closure contains no unseen-supplier credit")
    var market:=_world()
    var before:=_value(market)
    var offer:Dictionary=market._make_offer("outsource")
    market.offers=[{},{},{},{},{},offer]
    var visible:=_value(market)
    check(visible.detail.sides[0].eta<before.detail.sides[0].eta,"a current affordable public outsource offer retains its real paid return")
    check(visible.detail.sides[0].public_investment.get("kind","")=="outsource" and visible.detail.sides[0].forecast_purchases.has(int(offer.id)),"public-tool improvement is tied to the observed quote and its payment")
    var poor:=_world(120,0)
    var poor_before:=_value(poor)
    poor.offers=[{},{},{},{},{},poor._make_offer("outsource")]
    var unaffordable:=_value(poor)
    check(is_equal_approx(unaffordable.detail.sides[0].eta,poor_before.detail.sides[0].eta),"a quote expiring before its real price can be earned grants no tool")

func _unspent_wages_are_not_production() -> void:
    var world:=_world()
    var baseline:=_value(world,true)
    var worker:int=world._owner_type(0,"employee")[0]
    var cup:=world.add_card("coffee",0)
    var recipe:=_value(world)
    check(not recipe.detail.sides[0].public_investment.get("kind","")=="coffee","unused higher wages alone cannot beat the same real work throughput")
    check(world.move_cards([worker,cup],-1)>=0,"counterfactual pays the actual coffee recipe and removes the worker from production")
    var upgrading:=_value(world,true)
    check(upgrading.detail.sides[0].eta>baseline.detail.sides[0].eta,"equal-capacity upgrade with no executable use for extra wages includes its lost work time")

func _wages_can_fund_owned_recruitment() -> void:
    var outcomes:=[]
    for upgraded in [false,true]:
        var world:=_world(800,15,3)
        var target:int=world.cards[world._owner_type(0,"work")[0]].group
        var worker:int=world._owner_type(0,"employee")[0]
        var boss:=world.add_card("boss",0)
        var cup:=world.add_card("coffee",0)
        check(world.move_cards([boss]+world._owner_type(0,"money"),-1)>=0,"owned boss starts a recruitment batch with real funds")
        world.advance(12.0)
        var newcomers:Array=world._owner_type(0,"employee").filter(func(id):return not world.tasks.has(id))
        check(world.move_cards(newcomers,target)>=0,"paid recruits are actually deployed at their own six-second action slot")
        world.advance(6.0)
        if upgraded: check(world.move_cards([worker,cup],-1)>=0,"wage-investment branch pays for an actual upgrade")
        world.advance(6.0)
        if upgraded: check(world.move_cards([worker],target)>=0,"upgraded worker returns through the real rule engine")
        world.advance(36.0)
        var cash:=world.available_money(0)
        check(world.move_cards([boss]+world._owner_type(0,"money"),-1)>=0,"both branches reinvest only their own cash at the same time")
        var reserved:=world.reserved_money(0)
        check(reserved<=cash,"recruitment never spends projected future income")
        world.advance(12.0)
        newcomers=world._owner_type(0,"employee").filter(func(id):return not world.tasks.has(id))
        check(world.move_cards(newcomers,target)>=0,"second paid batch becomes real working staff")
        var value:=_value(world,true)
        var eta:float=world.time+float(value.detail.sides[0].eta)
        outcomes.append({"cash":cash,"reserved":reserved,"eta":eta})
        world.advance(eta-world.time+10.0)
        check(world.winner==0 and is_equal_approx(world.time,eta),"public physical ETA agrees with actual completion after funded reinvestment")
    check(outcomes[1].cash>outcomes[0].cash and outcomes[1].reserved>outcomes[0].reserved,"real higher wages can fund more recruits through an already owned boss")
    check(outcomes[1].eta<outcomes[0].eta,"removing unseen supply preserves the real long-term completion benefit of coffee plus recruitment")
