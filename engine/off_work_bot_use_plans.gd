# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Follow a paid identity with a real use at its next action slot. No card
## receives a utility bonus: staffing, ejection, locks and lost production
## are resolved by the same action generator and OffWorkState as live play.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const ForecastCommands = preload("res://engine/off_work_bot_forecast_commands.gd")

static func available(world: OffWorkState, commitments: Dictionary) -> bool:
	return commitments.keys().any(func(id): return world.cards.has(id) and int(world.cards[id].owner)==int(commitments[id]) and str(world.cards[id].type)!="slack")

static func visit(world: OffWorkState, side: int, policy: Dictionary, until: int,
		clock: Array, commitments: Dictionary, opponent_forecast: Dictionary, visitor: Callable,
		cancelled: Callable = Callable()) -> Dictionary:
	var planner := Planner.new()
	planner.source=world
	planner.owner=side
	planner.policy=policy
	planner.until=until
	planner.cancelled=cancelled
	planner.period=maxf(0.001,float(policy.get("think_seconds",world.config.rules.bot.think_seconds)))
	planner.horizon=maxf(planner.period,float(policy.get("evaluation_max_seconds",1800.0)))
	planner.next_actions=clock.duplicate()
	planner.commitments=commitments
	planner.forecast=opponent_forecast
	planner.visitor=visitor
	return planner.run()

class Planner extends "res://engine/off_work_bot_plan_cursor.gd":
	var commitments: Dictionary
	var forecast: Dictionary
	var visitor: Callable
	var examined := 0
	var emitted := 0

	func run() -> Dictionary:
		var root := _cursor(source)
		if root.is_empty(): return _result()
		# A future defence cannot erase a reply that happens before assembly.
		# Replay the visible opponent plan on the real clock, including payment,
		# quote expiry, attack flight, natural tasks and staffing interruption.
		if not _replies(root): return _result()
		if not _slot(root): return _result()
		var generated: Dictionary = Actions.generate(root.world,owner,policy,until,cancelled)
		if not generated.complete:
			complete=false
			return _result()
		for action in generated.actions:
			if not _open(): break
			if action.kind not in ["move","activate"] or not _uses(action,root.world): continue
			examined+=1
			var trial := _cursor(root.world,root)
			if trial.is_empty(): break
			if not _command(trial,action): continue
			emitted+=1
			visitor.call(_plan(trial,"purchase_use"))
		return _result()

	func _uses(action: Dictionary, world: OffWorkState) -> bool:
		for id in commitments:
			if int(commitments[id])!=owner or not world.cards.has(id): continue
			if action.get("ids",[]).has(id) or int(action.get("tool",-1))==int(id) or int(action.get("person",-1))==int(id): return true
		return false

	func _before_own(at: float, own: float) -> bool:
		return at < own-1e-9 or (is_equal_approx(at,own) and 1-owner < owner)

	func _replies(cursor: Dictionary) -> bool:
		var enemy := 1-owner
		var through := float(cursor.next) if enemy<owner else float(cursor.next)-1e-7
		var after := float(next_actions[enemy])
		while after<=through:
			var reply: Dictionary = ForecastCommands.next_command(cursor.world,enemy,policy,forecast,after,through,until)
			if not reply.complete:
				complete=false
				return false
			if reply.get("none",false): return true
			if reply.get("unsupported",false): return false
			if not _reply(cursor,enemy,reply.action,float(reply.at)): return false
			after=float(reply.at)+period
		return true

	func _result() -> Dictionary:
		return {"complete":complete,"plans":emitted,"examined":examined}
