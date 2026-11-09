# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Compare only completed executable uses on the root's existing ETA scale.
## The public purchase has already happened in this branch. Its identity and
## cost survive opponent replies; an incomplete use never invents a payoff.
const Plans = preload("res://engine/off_work_bot_use_plans.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
var tail_evaluator := Evaluation.new()

func available(world: OffWorkState, commitments: Dictionary) -> bool:
	return Plans.available(world,commitments)

func extend(world: OffWorkState, owner: int, policy: Dictionary, until: int, clock: Array,
		ordinary: Dictionary, commitments: Dictionary, cancelled: Callable = Callable()) -> Dictionary:
	if not ordinary.get("complete",false) or ordinary.get("detail",{}).get("terminal",true): return ordinary
	var result: Dictionary = ordinary.duplicate(true)
	var status := {"complete":true,"plans":0,"examined":0}
	var prefix := {"world":world,"clock":clock.duplicate(),"elapsed":0.0,
		"forecasts":ordinary.detail.sides.duplicate(true),"commands":[],"purchases":{}}
	var sides := [0,1] if float(clock[0])<=float(clock[1]) else [1,0]
	for side in sides:
		if not commitments.keys().any(func(id): return int(commitments[id])==int(side) and prefix.world.cards.has(id)): continue
		var enemy := 1-int(side)
		var opponent: Dictionary = prefix.forecasts[enemy]
		var chosen := {}
		var elapsed_before := float(prefix.elapsed)
		var prior_commands: Array = prefix.commands.duplicate(true)
		var prior_purchases: Dictionary = prefix.purchases.duplicate(true)
		var observed: Dictionary = Plans.visit(prefix.world,int(side),policy,until,prefix.clock,commitments,opponent,func(plan):
			var value: Dictionary
			if ordinary.get("evaluation_mode","")=="current":
				value=tail_evaluator.evaluate_current(plan.world,owner,policy,until,plan.next_actions)
			elif ordinary.get("evaluation_mode","")=="tactical":
				value=tail_evaluator.evaluate_tactical(plan.world,owner,policy,until,plan.next_actions)
			else:
				value=tail_evaluator.evaluate(plan.world,owner,policy,until,plan.next_actions,false)
			if not value.get("complete",false):
				status.complete=false
				return
			var elapsed := elapsed_before+float(plan.elapsed)
			var commands: Array = prior_commands.duplicate(true)
			for actor in 2:
				for command in plan.commands if actor==int(side) else plan.replies:
					commands.append({"owner":actor,"at":float(command.at)+elapsed_before,"action":command.action.duplicate(true)})
			var purchases: Dictionary = prior_purchases.duplicate(true)
			for quote in plan.purchases:
				var purchase: Dictionary = plan.purchases[quote].duplicate(true)
				purchase.at=float(purchase.at)+elapsed_before
				purchases[quote]=purchase
			var local_forecasts: Array = []
			if not value.detail.get("terminal",false):
				# Keep an unshifted copy for the next side's real prefix. All its
				# attack/investment clocks remain relative to the chosen world.
				local_forecasts=value.detail.sides.duplicate(true)
				for actor in 2:
					var forecast: Dictionary = value.detail.sides[actor]
					tail_evaluator._offset_forecast(forecast,elapsed)
					forecast.required_actions+=commands.filter(func(command): return int(command.owner)==actor).size()
				value.score=clampf(1000.0*tail_evaluator._race(value.detail.sides,owner),-Evaluation.WIN*0.5,Evaluation.WIN*0.5)
				value.tie_score=int(value.detail.sides[1-owner].required_actions)-int(value.detail.sides[owner].required_actions)
			var sign := 1.0 if int(side)==owner else -1.0
			if sign*float(value.score)<=sign*float(result.score)+1e-8: return
			result.score=value.score
			result.tie_score=value.get("tie_score",0.0)
			result.detail=value.detail
			result.detail["purchase_chain"]={"owner":side,"seconds":elapsed,
				"commands":commands.filter(func(command): return int(command.owner)==int(side)),
				"replies":commands.filter(func(command): return int(command.owner)!=int(side)),"scheduled_commands":commands,
				"purchases":purchases,"committed_ids":commitments.duplicate(),
				"opponent_assumption":"visible reply prefix replayed by the rules; same evaluation lens after assembly"}
			chosen.clear()
			chosen.merge({"world":plan.world,"clock":plan.next_actions,"elapsed":elapsed,
				"forecasts":local_forecasts,"commands":commands,"purchases":purchases}),cancelled)
		status.plans+=int(observed.plans)
		status.examined+=int(observed.examined)
		if not chosen.is_empty(): prefix=chosen
		if not observed.complete or not status.complete:
			status.complete=false
			break
		if result.detail.get("terminal",false): break
	result["purchase_extension"]=status
	return result
