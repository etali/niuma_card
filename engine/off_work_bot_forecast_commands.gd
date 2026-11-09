# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Translate the evaluator's scheduled commands into existing legal proposals.
## No rule is executed here. The shared prefix cursor owns payment, movement,
## expiry and time advancement; a missing match invalidates that continuation
## instead of pretending the opponent gave up its next action.
const Actions = preload("res://engine/off_work_bot_actions.gd")

static func next_command(world: OffWorkState, side: int, policy: Dictionary,
		forecast: Dictionary, after: float, through: float, until: int) -> Dictionary:
	if until >= 0 and Time.get_ticks_usec() >= until: return {"complete":false}
	var scheduled: Array = forecast.get("forecast_commands",[]).duplicate(true)
	for key in forecast.get("forecast_purchases",{}):
		var purchase: Dictionary = forecast.forecast_purchases[key]
		if int(purchase.owner)!=side: continue
		scheduled.append({"kind":"spend","offer":int(key),"amount":purchase.price,"at":purchase.at})
	var closure: Dictionary = forecast.get("cashout",{})
	if closure.has("funding_at"):
		scheduled.append({"kind":"cashout","at":closure.funding_at})
	var attack: Dictionary = forecast.get("forecast_attack",{})
	if not attack.is_empty() and not bool(attack.get("natural_restart",false)) and attack.has("use_at"):
		scheduled.append({"kind":"commit_attack","at":attack.use_at})
	var at := INF
	for command in scheduled:
		var time := float(command.get("at",INF))
		if time>=after-1e-9 and time<=through+1e-9: at=minf(at,time)
	if not is_finite(at): return {"complete":true,"none":true,"action":{},"at":INF}
	var due: Array = scheduled.filter(func(command): return absf(float(command.get("at",INF))-at)<1e-9)
	var generated: Dictionary = Actions.generate(world,side,policy,until)
	if not generated.complete: return {"complete":false,"at":at}
	var best := {}
	var count := 2147483647
	for action in generated.actions:
		if until>=0 and Time.get_ticks_usec()>=until: return {"complete":false,"at":at}
		if action.kind=="wait": continue
		if not due.all(func(command):return _matches(world,action,command,attack)): continue
		var size: int=action.get("ids",[]).size()
		if size<count:
			best=action
			count=size
	if best.is_empty():
		return {"complete":true,"unsupported":true,"action":{},"at":at,"commands":due,
			"reason":"scheduled command has no matching authoritative action"}
	return {"complete":true,"action":best.duplicate(true),"at":at,"commands":due}

static func _matches(world: OffWorkState, action: Dictionary, command: Dictionary, attack: Dictionary) -> bool:
	var kind := str(command.get("kind",""))
	var ids: Array = action.get("ids",[])
	var target := int(command.get("group",-1))
	match kind:
		"spend":
			if command.has("offer"): return action.kind=="buy" and int(action.get("offer",-1))==int(command.offer)
			if str(command.get("operation","")).begins_with("fund:recruitment"):
				return action.get("intent","") in ["recruitment","recruitment_feed"] and _amount(world,ids,"money")>=int(command.amount)
			return false
		"worker":
			if action.kind!="move" or int(action.get("group",-1))!=target: return false
			var person: Variant=command.get("id",-1)
			if person is int: return ids.has(person)
			# Newly recruited/purchased staff do not have real IDs when the
			# forecast is built. Their role/count is exact; use a current legal
			# idle-staff alternative, not an arbitrary existing working employee.
			var unit: Dictionary=command.get("unit",{})
			var staff := 0
			for id in ids:
				if not world.cards.has(id) or str(world.cards[id].type)!=str(unit.get("role","")): continue
				if str(world.tasks.get(id,{}).get("kind",""))=="work": continue
				staff+=1
			return staff>=int(unit.get("count",1))
		"overtime":
			return action.kind=="move" and int(action.get("group",-1))==target and _amount(world,ids,"overtime")>=int(command.amount)
		"move_work":
			return action.kind=="move" and int(action.get("group",-1))==target and world.group_work(int(command.from)).all(func(id):return ids.has(id))
		"return_workers":
			return action.kind=="move" and int(action.get("group",-1))==target and world.group_people(int(command.from)).all(func(id):return not world.config.can_work(str(world.cards[id].type)) or ids.has(id))
		"coffee_start":
			return action.kind=="move" and action.get("intent","")=="coffee" and ids.has(command.id) and int(action.get("person",-1))==int(command.id)
		"fund_outsource":
			return action.get("intent","") in ["outsource","outsource_feed"] and _amount(world,ids,"work")>=int(command.amount)
		"cashout":
			return action.get("intent","") in ["outsource","outsource_feed"] and _amount(world,ids,"work")>=world.work_count(_action_owner(world,action))
		"commit_attack","meeting_host":
			return _matches_attack(world,action,attack)
	return false

static func _amount(world: OffWorkState, ids: Array, kind: String) -> int:
	var amount := 0
	for id in ids:
		if world.cards.has(id) and str(world.cards[id].type)==kind:
			amount+=int(world.cards[id].get("amount",1)) if kind=="money" else 1
	return amount

static func _action_owner(world: OffWorkState, action: Dictionary) -> int:
	for id in action.get("ids",[]):
		if world.cards.has(id): return int(world.cards[id].owner)
	if world.cards.has(action.get("tool",-1)): return int(world.cards[action.tool].owner)
	return -1

static func _matches_attack(world: OffWorkState, action: Dictionary, attack: Dictionary) -> bool:
	if attack.is_empty(): return false
	var kind := str(attack.kind)
	var tool := int(action.get("tool",-1))
	if tool<0:
		for id in action.get("ids",[]):
			if world.cards.has(id) and str(world.cards[id].type)==kind:
				tool=int(id)
				break
	if not world.cards.has(tool) or str(world.cards[tool].type)!=kind: return false
	if attack.has("tool") and tool!=int(attack.tool): return false
	if kind=="strike": return action.kind=="activate" and int(action.get("group",-1))==int(attack.target_group)
	return kind=="meeting" and action.get("intent","")=="meeting" and int(action.get("person",-1))==int(attack.host)
