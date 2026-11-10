# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Keep the real commands which paid for a forecast, not its hypothetical world.
## Descriptions made in a search branch are sanitized against the live observation:
## future identities become role/count requirements and are rebound at dispatch.
static func describe(world: OffWorkState, owner: int, action: Dictionary) -> Dictionary:
	var result := {"kind":action.get("kind","wait"),"intent":action.get("intent",""),
		"growth_intent":action.get("growth_intent",""),"items":[],"group":{},"person":{},"tool":{}}
	for id in action.get("ids",[]):
		if world.cards.has(id) and int(world.cards[id].owner)==owner: result.items.append(_card(world,int(id)))
	for key in ["person","tool"]:
		if world.cards.has(action.get(key,-1)): result[key]=_card(world,int(action[key]))
	var gid := int(action.get("group",-1))
	if world.groups.has(gid):
		result.group={"id":gid,"owner":int(world.groups[gid].owner),"mode":str(world.groups[gid].get("function","")),"anchors":[]}
		var anchor := {}
		for id in world.groups[gid].cards:
			var kind := str(world.cards[id].type)
			if kind in ["boss","slack","meeting","transfer","outsource"]:
				anchor=_card(world,int(id));break
			if anchor.is_empty() and world.config.is_person(kind): anchor=_card(world,int(id))
		if not anchor.is_empty(): result.group.anchors.append(anchor)
	result.items=_coalesce(result.items)
	if action.kind=="buy": result.merge({"offer":action.get("offer",-1),"card_type":action.get("card_type","")})
	return result

static func _coalesce(items: Array) -> Array:
	var merged := []
	var keys := {}
	for original in items:
		var item: Dictionary=original.duplicate(true)
		if item.get("type","")=="money": item.erase("id")
		if item.has("id"):
			merged.append(item);continue
		var key := str([item.get("type",""),item.get("job",""),item.get("status",""),item.get("physical_material",false)])
		if keys.has(key): merged[int(keys[key])].count+=int(item.get("count",1))
		else:
			keys[key]=merged.size()
			merged.append(item)
	return merged

static func _card(world: OffWorkState, id: int) -> Dictionary:
	var card: Dictionary = world.cards[id]
	return {"id":id,"type":str(card.type),"count":int(card.get("amount",1)) if card.type=="money" else 1,
		"job":str(world.tasks.get(id,{}).get("kind","")),"status":str(card.status)}

## Called BEFORE the command is applied: IDs which merely coincide with a later
## real arrival can never turn into a trusted reference.
static func prepare(world: OffWorkState, owner: int, action: Dictionary, report: Dictionary, policy: Dictionary) -> Dictionary:
	var detail: Dictionary = report.get("evaluation",{})
	var sides: Array = detail.get("sides",[])
	if sides.size()!=2: return {}
	var own: Dictionary = sides[owner]
	var period := float(policy.get("think_seconds",6.0))
	var offset := float(report.get("forecast_root_offset_seconds",period*0.5))
	var commands: Array = []
	var chain: Dictionary = own.get("production_chain",{})
	# A chosen executable route may begin by waiting for wages or a recipe.
	# Its later real commands still need to survive the next decision. A plain
	# unplanned wait does not manufacture an execution context from its tail.
	if action.get("kind","")=="wait" and chain.get("commands",[]).is_empty(): return {}
	if not chain.get("commands",[]).is_empty():
		commands=chain.commands.duplicate(true)
		if _same(commands[0].action,action) and float(commands[0].get("at",INF))<=1e-8:
			commands.pop_front()
			offset=0.0
	elif int(detail.get("purchase_chain",{}).get("owner",-1))==owner:
		commands=detail.purchase_chain.get("commands",[]).duplicate(true)
	var steps := []
	var source_kind := "forecast"
	for command in commands:
		# Waiting is already represented by the next command's absolute
		# ready_at. Persisting it as an executable head would block that command
		# forever: the bot only submits meaningful non-wait continuations.
		if command.action.get("kind","")=="wait": continue
		var binding: Dictionary = command.get("binding",{})
		if binding.is_empty(): binding=_fallback_description(world,owner,command.action,action)
		if binding.is_empty(): break
		var step := _sanitize(world,owner,binding,int(report.get("observed_card_end",world._next_card)),int(report.get("observed_group_end",world._next_group)))
		step["ready_at"]=world.time+offset+float(command.at)
		steps.append(step)
		source_kind="executable"
	# The evaluated tail can require paid workers to return AFTER a nonempty
	# explicit prefix. Those commands are part of its claimed completion time,
	# not optional metadata: preserve them as well as the investment commands.
	var tail: Array=own.get("forecast_steps",[]).duplicate(true) if own.has("forecast_steps") else physical_steps(world,owner,own.get("forecast_commands",[]),offset,action)
	for original in tail:
		var step := _sanitize(world,owner,original,int(report.get("observed_card_end",world._next_card)),int(report.get("observed_group_end",world._next_group)))
		if not steps.has(step): steps.append(step)
	steps.sort_custom(func(a,b):return float(a.ready_at)<float(b.ready_at))
	if steps.is_empty(): return {}
	return {"observed_at":float(world.time),"steps":steps,"origin":str(action.get("intent",action.kind)),"source":source_kind}

static func _sanitize(world: OffWorkState, owner: int, description: Dictionary, card_end: int, group_end: int) -> Dictionary:
	var result := description.duplicate(true)
	for item in result.get("items",[]): _sanitize_card(world,owner,item,card_end)
	result.items=_coalesce(result.get("items",[]))
	for key in ["person","tool"]: _sanitize_card(world,owner,result.get(key,{}),card_end)
	_sanitize_group(world,owner,result.get("group",{}),card_end,group_end)
	for requirement in result.get("material_sources",{}).values():
		_sanitize_group(world,owner,requirement.get("group",{}),card_end,group_end)
	return result

static func _sanitize_group(world: OffWorkState, owner: int, group: Dictionary, card_end: int, group_end: int) -> void:
	var destination_owner := int(group.get("owner",owner))
	if group.has("id") and (int(group.id)>=group_end or not world.groups.has(int(group.id)) or int(world.groups[int(group.id)].owner)!=destination_owner): group.erase("id")
	for anchor in group.get("anchors",[]): _sanitize_card(world,destination_owner,anchor,card_end)

static func _sanitize_card(world: OffWorkState, owner: int, item: Dictionary, card_end: int) -> void:
	if item.has("id") and (int(item.id)>=card_end or not world.cards.has(int(item.id)) or int(world.cards[int(item.id)].owner)!=owner): item.erase("id")
	# Wallet identities change when wages are paid and are never a reservation.
	if item.get("type","")=="money": item.erase("id")

static func _fallback_description(world: OffWorkState, owner: int, command: Dictionary, paid: Dictionary) -> Dictionary:
	var result := describe(world,owner,command)
	var missing: int = command.get("ids",[]).filter(func(id):return not world.cards.has(id)).size()
	if missing>0:
		# A purchase-use prefix knows the acquired role even before its real ID
		# exists. Other future entities need the prefix's explicit binding.
		if paid.get("kind","")!="buy" or missing!=1: return {}
		result.items.append({"type":str(paid.get("card_type","")),"count":1,"job":""})
	return result

static func _forecast_steps(world: OffWorkState, owner: int, commands: Array, offset: float, paid: Dictionary, until := -1) -> Array:
	var steps := []
	for command in commands:
		if until>=0 and Time.get_ticks_usec()>=until: return steps
		var kind := str(command.get("kind",""))
		if kind not in ["worker","overtime"]: continue
		var gid := int(command.get("group",-1))
		if not world.groups.has(gid) or int(world.groups[gid].owner)!=owner: continue
		var ready := world.time+offset+float(command.get("at",0.0))
		var step := {}
		for existing in steps:
			if int(existing.group.get("id",-1))==gid and is_equal_approx(float(existing.ready_at),ready): step=existing;break
		if step.is_empty():
			step={"kind":"move","intent":"assemble_work","growth_intent":"","group":_physical_group(world,owner,gid,until),
				"items":[],"person":{},"tool":{},"ready_at":ready,"all_idle":true}
			steps.append(step)
		if kind=="overtime": step.items.append({"type":"overtime","count":int(command.get("amount",1)),"job":""})
		else:
			var unit: Dictionary = command.get("unit",{})
			var item := {"type":str(unit.get("role",paid.get("card_type","employee"))),"count":int(unit.get("count",1)),"job":""}
			var id: Variant = command.get("id",-1)
			if id is int and world.cards.has(id) and int(world.cards[id].owner)==owner:
				item["id"]=id
				# These ongoing jobs do not naturally become idle. A worker event
				# explicitly redeploys their current person; bind that exact source
				# job. Coffee, meetings and a finishing work pile still require the
				# existing idle binding after their paid task actually completes.
				var job := str(world.tasks.get(id,{}).get("kind",""))
				if job in ["slack","transfer"] and str(world.cards[id].type)==str(item.type): item.job=job
			step.items.append(item)
	steps.sort_custom(func(a,b):return float(a.ready_at)<float(b.ready_at))
	return steps

static func _physical_group(world: OffWorkState, owner: int, gid: int, until := -1) -> Dictionary:
	var group := {"id":gid,"owner":owner,"mode":str(world.groups[gid].get("function","")),"anchors":[]}
	var anchor := {}
	for id in world.groups[gid].cards:
		if until>=0 and Time.get_ticks_usec()>=until: return group
		var kind := str(world.cards[id].type)
		if anchor.is_empty(): anchor=_card(world,int(id))
		if world.config.is_person(kind):
			anchor=_card(world,int(id))
			break
	if not anchor.is_empty(): group.anchors.append(anchor)
	return group

static func physical_steps(world: OffWorkState, owner: int, commands: Array, offset := 0.0, paid: Dictionary = {}, until := -1) -> Array:
	var steps: Array=_forecast_steps(world,owner,commands,offset,paid,until)
	for command in commands:
		if until>=0 and Time.get_ticks_usec()>=until: break
		var kind := str(command.get("kind",""))
		if kind not in ["return_workers","move_work","strike_return","strike_feed"]: continue
		var target := int(command.get("group",-1))
		var origin := int(command.get("from",-1))
		if kind in ["strike_return","strike_feed"]:
			origin=int(world.pending_strikes.get(command.get("flight",-1),{}).get("target_group",-1))
		if not world.groups.has(origin) or not world.groups.has(target): continue
		if int(world.groups[origin].owner)!=owner or int(world.groups[target].owner)!=owner: continue
		var items := []
		for id in world.groups[origin].cards:
			if until>=0 and Time.get_ticks_usec()>=until: return steps
			var card: Dictionary=world.cards[id]
			var selected: bool=world.config.can_work(str(card.type)) if kind in ["return_workers","strike_return"] \
				else (card.type=="work" or (kind=="strike_feed" and card.type=="overtime" and not world.group_has_union(target)))
			if kind=="strike_return": selected=selected and world.can_person_be_struck(int(id))
			if selected: items.append({"id":int(id),"type":str(card.type),"count":1,"job":""})
		if items.is_empty(): continue
		var step := {"kind":"move","intent":"assemble_work","growth_intent":"",
			"group":_physical_group(world,owner,target,until),"items":items,"person":{},"tool":{},
			"ready_at":world.time+offset+float(command.at),"independent":true}
		# A launched strike may miss or leave immune workers in the source.
		# Its material consolidation is owed only if that pile was abandoned.
		if kind in ["move_work","strike_feed"]:
			step["material_sources"]={origin:{"idle":kind=="strike_feed","overtime":kind=="strike_feed" and not world.group_has_union(target),"group":_physical_group(world,owner,origin,until)}}
			step["material_ids"]=items.map(func(item):return int(item.id))
			for item in items: item["physical_material"]=true
		merge_physical_step(steps,step)
	steps.sort_custom(func(a,b):return float(a.ready_at)<float(b.ready_at))
	return steps

static func same_destination(a: Dictionary, b: Dictionary) -> bool:
	if a.has("id") and b.has("id"):
		return int(a.id)==int(b.id) and int(a.get("owner",-1))==int(b.get("owner",-1))
	return a==b

static func merge_physical_step(steps: Array, step: Dictionary) -> void:
	# The evaluator charges one assembly command for materials and workers
	# reaching the same destination in one slot. Execute that same command.
	for existing in steps:
		if not same_destination(existing.group,step.group) or not is_equal_approx(float(existing.ready_at),float(step.ready_at)): continue
		for item in step.items:
			if not existing.items.has(item): existing.items.append(item)
		if step.get("all_idle",false): existing.all_idle=true
		var materials: Dictionary=existing.get("material_sources",{})
		materials.merge(step.get("material_sources",{}),true)
		if not materials.is_empty():
			existing.material_sources=materials
			existing.material_ids=existing.get("material_ids",[])+step.get("material_ids",[])
		return
	steps.append(step)

static func resolve(world: OffWorkState, owner: int, context: Dictionary, until: int) -> Dictionary:
	var result := {"action":{"kind":"wait"},"context":context.duplicate(true)}
	if context.is_empty(): return result
	if world.winner>=0 or world.time<float(context.get("observed_at",INF))-1e-8:
		result.context={}; return result
	var steps: Array = result.context.get("steps",[])
	while not steps.is_empty():
		if until>=0 and Time.get_ticks_usec()>=until: return result
		var step: Dictionary = steps[0]
		var bound: Dictionary = {"wait_reason":"scheduled"} if world.time+1e-8<float(step.ready_at) else _bind(world,owner,step,until)
		if bound.get("invalid",false):
			if step.get("independent",false): steps.pop_front()
			else:
				# One causal production chain can be invalidated without erasing
				# unrelated purchases already paid for during its waiting period.
				for index in range(steps.size()-1,-1,-1):
					if not steps[index].get("independent",false): steps.remove_at(index)
			continue
		if bound.get("satisfied",false): steps.pop_front();continue
		if not bound.has("action"):
			var independent := _ready_independent(world,owner,steps,until)
			if independent.has("action"): bound=independent
		if bound.has("wait_reason"):
			result["wait_reason"]=bound.wait_reason
			if bound.has("missing_type"): result["missing_type"]=bound.missing_type
		if bound.has("action"):
			result.action=bound.action
			result.action["execution_continuation"]=true
			# Carry the exact sanitized obligation, not a queue index or hash.
			# A longer search can select an independent step after the initial
			# bounded resolver ran out of time, leaving the live queue unreordered.
			result.action["execution_step"]=steps[0].duplicate(true)
			result.action["reason"]="兑现已计入收益的生产计划，将购置和生产转为实际产能"
		return result
	result.context={}
	return result

## Only separately paid forecast dispatches may pass a blocked head. Later
## recruitment/coffee commands still depend on every earlier step of their
## executable prefix and are never searched out of order here.
static func _ready_independent(world: OffWorkState, owner: int, steps: Array, until: int) -> Dictionary:
	var index := 1
	while index<steps.size():
		if until>=0 and Time.get_ticks_usec()>=until: return {}
		var step: Dictionary=steps[index]
		if not step.get("independent",false) or world.time+1e-8<float(step.ready_at):
			index+=1;continue
		var bound := _bind(world,owner,step,until)
		if bound.get("invalid",false) or bound.get("satisfied",false):
			steps.remove_at(index);continue
		if bound.has("action"):
			steps.remove_at(index)
			steps.push_front(step) # consumed() removes exactly the selected command.
			return bound
		index+=1
	return {}

## A spare action during a paid recipe may buy another worker. Preserve the
## existing executable recipe and add its independently paid dispatch obligation;
## a new complete executable plan is an explicit replacement instead.
static func adopt(existing: Dictionary, prepared: Dictionary) -> Dictionary:
	if existing.is_empty() or prepared.get("source","")!="forecast": return prepared
	var result := existing.duplicate(true)
	for step in prepared.get("steps",[]):
		var independent: Dictionary=step.duplicate(true)
		independent["independent"]=true
		result.steps.append(independent)
	result.steps.sort_custom(func(a,b):return float(a.ready_at)<float(b.ready_at))
	return result

static func consumed(context: Dictionary, executed: Dictionary) -> Dictionary:
	var result := context.duplicate(true)
	var steps: Array=result.get("steps",[])
	var selected: Dictionary=executed.get("execution_step",{})
	if selected.is_empty(): return result
	for index in steps.size():
		if steps[index]==selected:
			steps.remove_at(index)
			break
	# An unmatched publication must never guess that the live head is the
	# same obligation. Preserve it for fresh rule-state revalidation.
	return {} if steps.is_empty() else result

static func _bind(world: OffWorkState, owner: int, step: Dictionary, until: int) -> Dictionary:
	# Contexts exported by an older worker may still contain wait steps.
	# resolve() calls this only after ready_at, so elapsed waits are complete
	# without another action slot or any mutation to the real game state.
	if step.kind=="wait": return {"satisfied":true}
	if step.kind=="buy":
		for offer in world.offers:
			if not offer.is_empty() and int(offer.id)==int(step.get("offer",-1)) and str(offer.type)==str(step.get("card_type","")):
				if world.available_money(owner)<int(offer.price): return {"wait_reason":"funds"}
				return {"action":{"kind":"buy","offer":int(offer.id),"card_type":str(offer.type),"intent":"buy"}}
		return {"invalid":true}
	if step.has("material_sources"):
		# Rebind surviving materials at the real paid slot. Keep the saved
		# obligation unchanged so consumed() still identifies the exact step.
		step=step.duplicate(true)
		step.items=step.items.filter(func(item):return not item.get("physical_material",false) and not step.get("material_ids",[]).has(int(item.get("id",-1))))
		for key in step.material_sources:
			if until>=0 and Time.get_ticks_usec()>=until: return {}
			var requirement: Dictionary=step.material_sources[key]
			var source: Dictionary=requirement.get("group",{"id":int(key)})
			var origin := int(source.get("id",-1))
			if origin<0:
				for anchor in source.get("anchors",[]):
					var found := _find(world,owner,anchor,[],until,false)
					if not found.is_empty(): origin=int(world.cards[found[0]].group);break
			if not world.groups.has(origin) or int(world.groups[origin].owner)!=owner: continue
			var active: bool=world.group_people(origin).any(func(id):return world.tasks.get(id,{}).get("kind","") in ["work","transfer","slack"] and not world.is_striking(int(id)))
			if requirement.get("idle",false) and active: continue
			for id in world.groups[origin].cards:
				if until>=0 and Time.get_ticks_usec()>=until: return {}
				var kind: String=world.cards[id].type
				if kind!="work" and not (requirement.get("overtime",false) and kind=="overtime"): continue
				step.items.append({"id":int(id),"type":kind,"count":1,"job":""})
		if step.items.is_empty(): return {"satisfied":true}

	var gid := -1
	var group: Dictionary = step.get("group",{})
	var destination_owner := int(group.get("owner",owner))
	# Purchased strike continuations retain an observed opponent target. Every
	# ordinary production move still requires our own destination; matching a
	# missing enemy group to one of our workers would change the command's side.
	if destination_owner!=owner and not (step.kind=="activate" and step.get("tool",{}).get("type","")=="strike"):
		return {"invalid":true}
	if group.has("id"):
		gid=int(group.id)
		if not world.groups.has(gid) or int(world.groups[gid].owner)!=destination_owner: return {"invalid":true}
	elif not group.is_empty():
		for anchor in group.get("anchors",[]):
			var found := _find(world,destination_owner,anchor,[],until,false)
			if not found.is_empty(): gid=int(world.cards[found[0]].group);break
		if gid<0: return {"wait_reason":"target"}
	if gid>=0:
		if step.kind=="activate" and step.get("tool",{}).get("type","")=="strike" and not world.can_strike_group(gid,owner):
			return {"invalid":true}
		var mode := str(world.groups[gid].get("function",""))
		if str(group.get("mode","")) in ["","work"] and mode not in ["","work"]: return {"invalid":true}
		for id in world.groups[gid].cards:
			if until>=0 and Time.get_ticks_usec()>=until: return {}
			if world.is_striking(int(id)): return {"wait_reason":"timer"}
	var ids := []
	var used := {}
	for item in step.get("items",[]):
		if until>=0 and Time.get_ticks_usec()>=until: return {}
		if item.has("id") and gid>=0 and world.cards.has(int(item.id)) and int(world.cards[int(item.id)].group)==gid:
			ids.append(int(item.id));used[int(item.id)]=true;continue
		var found := _find(world,owner,item,used,until)
		if found.is_empty() and not item.has("id") and gid>=0 and (world.config.can_work(str(item.type)) or item.type=="overtime"):
			# Another real command may already have fulfilled a role-bound return.
			# Do not mistake an unfinished recruitment/upgrade for that case.
			var pending: bool=world.recruitment.values().any(func(batch):return int(batch.owner)==owner)
			pending=pending or world.tasks.keys().any(func(id):return world.cards.has(id) and int(world.cards[id].owner)==owner and world.tasks[id].get("kind","")=="coffee")
			if not pending:
				var present: Array=world._owner_type(owner,str(item.type)).filter(func(id):return int(world.cards[id].group)==gid and not used.has(id))
				if present.size()>=int(item.get("count",1)): found=present.slice(0,int(item.get("count",1)))
		if found.is_empty():
			if item.has("id") and not world.cards.has(int(item.id)): return {"invalid":true}
			return {"wait_reason":"material","missing_type":str(item.get("type",""))}
		ids.append_array(found)
		for id in found: used[int(id)]=true
	if step.get("all_idle",false):
		for id in world.activity_card_ids(owner):
			if until>=0 and Time.get_ticks_usec()>=until: return {}
			var card: Dictionary=world.cards[id]
			if int(card.owner)!=owner or int(card.group)==gid or used.has(id): continue
			if world.config.can_work(str(card.type)) and _movable(world,int(id),""): ids.append(id)
			elif card.type=="overtime" and not world.group_has_union(gid) and world.group_work_participants(int(card.group)).is_empty(): ids.append(id)
	var action := {"kind":step.kind,"intent":step.get("intent",""),"growth_intent":step.get("growth_intent",""),"ids":ids,"group":gid,"person":-1}
	for key in ["person","tool"]:
		var reference: Dictionary=step.get(key,{})
		if reference.is_empty(): continue
		# move() uses person/tool as identity metadata: the tool can already be
		# active in the destination (e.g. adding staff to a running coffee line).
		# Only the actual items above must be movable. Prefer their rebound IDs,
		# then the destination, so a future tool's role does not pick another line.
		var found := []
		if step.kind=="move":
			var preferred: Array=ids.duplicate()
			if gid>=0: preferred.append_array(world.group_actions(gid)+world.group_people(gid))
			for id in preferred:
				if str(world.cards[id].type)!=str(reference.get("type","")): continue
				if reference.has("id") and int(reference.id)!=int(id): continue
				found=[int(id)];break
		if found.is_empty(): found=_find(world,owner,reference,[],until,step.kind!="move")
		if found.is_empty():
			if reference.has("id") and not world.cards.has(int(reference.id)): return {"invalid":true}
			return {"wait_reason":"metadata","missing_type":str(reference.get("type",""))}
		action[key]=int(found[0])
	if step.kind=="move":
		if ids.is_empty(): return {"invalid":true}
		if gid>=0 and ids.all(func(id):return int(world.cards[id].group)==gid): return {"satisfied":true}
		if gid>=0 and world.group_has_union(gid) and ids.any(func(id):return world.cards[id].type=="overtime"): return {"invalid":true}
	return {"action":action}

static func _find(world: OffWorkState, owner: int, item: Dictionary, used: Variant, until: int, movable := true) -> Array:
	var result := []
	var needed := int(item.get("count",1))
	var candidates: Array = [int(item.id)] if item.has("id") else world._owner_type(owner,str(item.get("type","")))
	for id in candidates:
		if until>=0 and Time.get_ticks_usec()>=until: return []
		if used.has(id) or not world.cards.has(id): continue
		var card: Dictionary=world.cards[id]
		if int(card.owner)!=owner or str(card.type)!=str(item.get("type","")): continue
		if movable and not _movable(world,int(id),str(item.get("job","")),str(item.get("status",""))): continue
		result.append(int(id))
		needed-=int(card.get("amount",1)) if card.type=="money" else 1
		if needed<=0: return result
	return []

static func _movable(world: OffWorkState, id: int, job: String, expected_status := "") -> bool:
	if world.is_striking(id) or world.is_meeting_target(id) or world.pending_strikes.has(id): return false
	var card: Dictionary=world.cards[id]
	if card.type=="money": return world.available_cash_amount(id)==int(card.amount)
	if world.config.is_person(str(card.type)): return str(world.tasks.get(id,{}).get("kind",""))==job
	return str(card.status)==(expected_status if not expected_status.is_empty() else "ready") or card.type in ["overtime","work"]

static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.get("kind","")!=b.get("kind",""): return false
	for key in ["group","person","tool","offer"]:
		if int(a.get(key,-1))!=int(b.get(key,-1)): return false
	var left: Array=a.get("ids",[]).duplicate()
	var right: Array=b.get("ids",[]).duplicate()
	left.sort();right.sort()
	return left==right
