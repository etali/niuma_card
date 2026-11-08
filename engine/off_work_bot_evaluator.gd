# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## One completion-time scale for both candidate ordering and search leaves.
## Existing batches and explicit public plans keep their real clocks. Economic
## closure prices earned wages against a fully funded final outsource batch;
## an unseen supplier adds a distribution-based wait, never a fabricated quote.
## No money, person, ingredient or tool receives an independent asset bonus.
const WIN := 1000000.0
const AttackPlans = preload("res://engine/off_work_bot_attack_plans.gd")
const Economy = preload("res://engine/off_work_bot_economy.gd")
var _deadline := -1
var _complete := true
var _config: RefCounted
var _period := 1.0
var _horizon := 1800.0
var _base_cycle := 10.0
var _next_actions: Array = []
# Scoped to this evaluator (one search). Exact serialized keys avoid hash-only
# collision assumptions. Cached results never escape without a deep copy.
var _rules_key := PackedByteArray()
var _forecast_cache: Array = [{}, {}]
var _projection_cache: Array = [{}, {}]
var _finish_cache: Array = [{}, {}]
var cache_hits := 0
var cache_misses := 0
var _cashout_enabled := true
var _supply_wait := INF

func evaluate(world: OffWorkState, owner: int, policy: Dictionary, until: int = -1, next_actions: Array = []) -> Dictionary:
	_deadline = until
	_complete = true
	_config = world.config
	var rules_key := var_to_bytes([_config.cards,_config.roles,_config.rules])
	if rules_key != _rules_key:
		_forecast_cache = [{}, {}]
		_projection_cache = [{}, {}]
		_finish_cache = [{}, {}]
		_rules_key = rules_key
	_period = maxf(0.001, float(policy.get("think_seconds", world.config.rules.bot.think_seconds)))
	_next_actions = next_actions.duplicate() if next_actions.size() == 2 else [_period, _period]
	_horizon = maxf(_period, float(policy.get("evaluation_max_seconds", 1800.0)))
	_base_cycle = maxf(0.001, float(_config.roles.employee.work_seconds))
	if world.winner >= 0:
		var score := 0.0
		if world.winner != _config.integer("simulation", "tie_winner"):
			score = (WIN - minf(1000.0, world.time * 0.001)) * (1.0 if world.winner == owner else -1.0)
		return {"score":score, "tie_score":0.0, "complete":true, "detail":{"terminal":true, "winner":world.winner}}
	if not _open(): return _incomplete()
	var index := _index(world)
	if not _complete: return _incomplete()
	var models := [_model(world, 0, index), _model(world, 1, index)]
	if not _complete: return _incomplete()
	_cashout_enabled = true
	for model in models:
		for group in model.groups.values():
			if group.mode=="transfer" and not group.workers.is_empty(): _cashout_enabled=false
	_supply_wait=Economy.expected_supply_wait(_config,"outsource")
	var forecasts := _economic_continuations(world,models)
	if not _complete: return _incomplete()
	var continuation := [forecasts[0]._continuation,forecasts[1]._continuation]
	var base_pair := _forecast_pair(continuation)
	if not _complete: return _incomplete()
	for side in 2: forecasts[side].merge(base_pair[side],true)
	forecasts = _attack_continuations(world,models,continuation,forecasts)
	for forecast in forecasts:
		forecast.erase("_continuation")
		forecast.erase("_required_commands")
		forecast.erase("_payments")
	if not _complete: return _incomplete()
	var score := 1000.0 * _race(forecasts,owner)
	return {"score":clampf(score, -WIN * 0.5, WIN * 0.5),
		"tie_score":int(forecasts[1-owner].required_actions) - int(forecasts[owner].required_actions), "complete":true,
		"detail":{"terminal":false, "sides":forecasts, "scale":"relative completion time", "projection_seconds":_horizon}}

func _open() -> bool:
	if _deadline >= 0 and Time.get_ticks_usec() >= _deadline: _complete = false
	return _complete

func _incomplete() -> Dictionary:
	return {"score":0.0, "tie_score":0.0, "complete":false, "detail":{"reason":"evaluation deadline"}}

func _index(world: OffWorkState) -> Dictionary:
	var groups := {}
	for gid in world.groups:
		if not _open(): return {}
		var source: Dictionary = world.groups[gid]
		groups[gid] = {"owner":int(source.owner), "work":0, "cash":0, "overtime":0, "union":false,
			"people":[], "tools":[], "types":{}, "mode":str(source.get("function", source.get("job", "work"))),
			"progress":float(source.get("work_progress", 0.0)), "transfer_progress":float(source.get("transfer_progress", 0.0))}
	for id in world.cards:
		if not _open(): return {}
		var card: Dictionary = world.cards[id]
		if not groups.has(card.group): continue
		var row: Dictionary = groups[card.group]
		row.types[card.type] = int(row.types.get(card.type, 0)) + 1
		match str(card.type):
			"work": row.work += 1
			"money": row.cash += int(card.amount)
			"overtime": row.overtime += 1
			"union": row.union = true
		if _config.category(str(card.type)) == "tool": row.tools.append(id)
	# Work assignment uses the stack's visible order, not allocation/UID order.
	# This matters when heterogeneous capacities exhaust the last few files.
	for gid in world.groups:
		for id in world.groups[gid].cards:
			if not _open(): return {}
			if world.cards.has(id) and _config.is_person(str(world.cards[id].type)): groups[gid].people.append(id)
	var paused := {}
	for meeting in world.meetings.values():
		if not _open(): return {}
		for id in meeting.targets: paused[id] = maxf(float(paused.get(id, 0.0)), float(meeting.remaining))
	return {"groups":groups, "paused":paused}

func _group(mode := "work", work := 0, progress := 0.0, overtime := 0, union := false) -> Dictionary:
	return {"mode":mode, "work":work, "progress":progress, "overtime":overtime, "union":union, "workers":{}, "present":{}, "strike_until":0.0}

func _unit(kind: String, count: int, union: bool, transfer: bool) -> Dictionary:
	var original_kind := kind
	if union and _config.can_work(kind): kind = str(_config.rules.union.work_role)
	var role: Dictionary = _config.roles[kind]
	return {"role":original_kind, "count":count, "capacity":int(role.transfer_capacity if transfer else role.work_capacity),
		"speed":1.0 / maxf(0.001,float(_config.rules.transfer.seconds if transfer else role.work_seconds)),
		"income":0 if transfer else _config.income_per_work(kind), "strikeable":bool(_config.roles[original_kind].get("can_be_strike_target",true))}

func _model(world: OffWorkState, side: int, index: Dictionary) -> Dictionary:
	var model := {"owner":side, "groups":{}, "events":[], "work":0, "pending_work":0, "free_cash":0.0,
		"target":-1, "incoming_target":-1, "first_action":maxf(0.0, float(_next_actions[side])), "pending_strikes":0, "coffee":0, "upgrade_people":[], "current_rate":0.0, "idle_pending":0, "facilities":[], "types":{}, "card_count":world.cards.size()}
	var largest := -1
	var best_power := -1.0
	var incoming_largest := -1
	for gid in index.groups:
		if not _open(): return model
		var row: Dictionary = index.groups[gid]
		if int(row.owner) != side: continue
		var mode := str(row.mode)
		model.groups[gid] = _group(mode, row.work, row.transfer_progress if mode == "transfer" else row.progress, row.overtime, row.union)
		model.work += int(row.work)
		model.free_cash += float(row.cash)
		for kind in row.types: model.types[kind] = int(model.types.get(kind, 0)) + int(row.types[kind])
		if int(row.work) > incoming_largest:
			incoming_largest = int(row.work)
			model.incoming_target = gid
		if mode in ["", "work"]:
			var production := 0.0
			for id in row.people:
				if world.tasks.get(id, {}).get("kind", "") != "work" or float(index.paused.get(id, 0.0)) > 0.0: continue
				var kind := str(world.cards[id].type)
				if bool(row.union): kind = str(_config.rules.union.work_role)
				production += _config.work_rate(kind, int(row.overtime)) * int(_config.roles[kind].work_capacity)
			if production > best_power or (is_equal_approx(production, best_power) and int(row.work) > largest):
				best_power = production
				largest = int(row.work)
				model.target = gid
	if int(model.target) < 0: model.groups[-1] = _group()
	if int(model.incoming_target) < 0: model.incoming_target = model.target
	var target: Dictionary = model.groups[model.target]
	var reserved := 0.0
	for batch in world.outsourcing.values():
		if not _open(): return model
		if int(batch.owner) != side: continue
		var count: int = batch.work_ids.size()
		model.groups[batch.group].work = maxi(0, int(model.groups[batch.group].work) - count)
		model.groups[batch.group].strike_until = maxf(float(model.groups[batch.group].strike_until),float(batch.remaining))
		model.pending_work += count
		reserved += float(batch.amount)
		model.events.append({"at":maxf(0.0, float(batch.remaining)), "kind":"settle", "amount":count})
	for batch in world.recruitment.values():
		if not _open(): return model
		if int(batch.owner) != side: continue
		reserved += float(batch.amount)
		model.idle_pending += int(batch.count)
		model.events.append({"at":maxf(0.0, float(batch.remaining)) + _period, "kind":"worker", "group":model.target,
			"id":"recruit:%s" % batch.group, "action":true, "unit":_unit("employee", int(batch.count), target.union, false)})
	model.free_cash = maxf(0.0, float(model.free_cash) - reserved)
	for card in world.cards.values():
		if not _open(): return model
		if int(card.owner) == side and card.type == "coffee" and card.status == "ready": model.coffee += 1
	var upgrade_keys := {}
	var loose_overtime := 0
	for gid in index.groups:
		if not _open(): return model
		var row: Dictionary = index.groups[gid]
		if int(row.owner) != side: continue
		var group: Dictionary = model.groups[gid]
		var mode := str(group.mode)
		for id in row.people:
			if not _open(): return model
			var card: Dictionary = world.cards[id]
			var kind := str(card.type)
			var task: Dictionary = world.tasks.get(id, {})
			var job := str(task.get("kind", ""))
			var step: Dictionary = _config.coffee_upgrade(kind)
			var upgrade_key := "%s:%s:%s" % [gid,kind,job]
			if not step.is_empty() and job in ["", "work"] and card.status != "striking" and float(index.paused.get(id,0.0)) <= 0.0 and not upgrade_keys.has(upgrade_key):
				upgrade_keys[upgrade_key] = true
				model.upgrade_people.append({"id":id,"kind":kind,"to":str(step.to),"cost":int(step.cost),"seconds":_config.coffee_seconds(kind)})
			var pause := maxf(float(index.paused.get(id, 0.0)), float(card.remaining) if card.status == "striking" else 0.0)
			if pause <= 0.0:
				group.present[id] = _unit(kind,1,bool(group.union),false)
			if job == "slack": group.strike_until = INF
			var delay := pause
			var destination: int = gid
			var needs_action := false
			var transfer := mode == "transfer" and job in ["", "transfer"]
			if job == "coffee":
				kind = str(task.to_type)
				delay += maxf(0.0, float(task.total) * (1.0 - float(task.progress)))
				# The current highest eligible person immediately continues any
				# already funded stages in this same stack. Recognize that exact
				# queue before and after each boundary, not only the current cup.
				var cups: int = int(row.types.get("coffee",0))-task.coffee_ids.size()
				var next: Dictionary = _config.coffee_upgrade(kind)
				while not next.is_empty() and cups>=int(next.cost):
					if not _open(): return model
					cups-=int(next.cost)
					delay+=_config.coffee_seconds(kind)
					kind=str(next.to)
					next=_config.coffee_upgrade(kind)
				delay += _period
				needs_action = true
				destination = int(model.target)
			elif not transfer and (mode not in ["", "work"] or int(group.work) == 0 or job not in ["", "work"]):
				if job == "meeting" and world.meetings.has(task.tool_id): delay += float(world.meetings[task.tool_id].remaining)
				delay += _period
				needs_action = true
				destination = int(model.target)
			elif not transfer and not world.tasks.has(id) and mode != "work":
				delay += _period
				needs_action = true
				destination = int(model.target)
			if not transfer and not _config.can_work(kind): continue
			var unit := _unit(kind, 1, bool(model.groups[destination].union), transfer)
			if delay <= 0.0:
				model.groups[destination].workers[id] = unit
			else:
				model.idle_pending += 1
				model.events.append({"at":delay, "kind":"worker", "group":destination, "id":id, "unit":unit, "action":needs_action})
		if gid != model.target and int(group.work) > 0 and (mode not in ["work", "transfer"] or row.people.is_empty()):
			model.events.append({"at":_period, "kind":"move_work", "from":gid, "group":model.target, "action":true})
		if gid != model.target and group.workers.is_empty() and mode in ["", "work"]:
			loose_overtime += int(group.overtime)
			group.overtime = 0
		for id in row.tools:
			var card: Dictionary = world.cards[id]
			if card.type == "outsource":
				var ready := float(card.remaining) if card.status == "recovering" else 0.0
				if world.outsourcing.has(id): ready = float(world.outsourcing[id].remaining) + _config.number("outsource", "recovery_seconds")
				model.facilities.append({"kind":"outsource", "ready":ready})
		for id in row.people:
			if world.cards[id].type == "boss" and not world.recruitment.has(id): model.facilities.append({"kind":"recruitment", "ready":0.0})
	if loose_overtime > 0 and not target.union:
		model.events.append({"at":_period, "kind":"overtime", "group":model.target, "amount":loose_overtime, "action":true})
	for gid in model.groups:
		if not _open(): return model
		var group: Dictionary = model.groups[gid]
		var stats := _stats(group)
		model.current_rate += float(stats.rate) * int(stats.batch)
		if gid != model.target and group.mode == "work" and int(group.work) > 0 and not group.workers.is_empty():
			var sample: Dictionary = group.duplicate(true)
			var finished := _advance_group(sample, _horizon)
			if int(sample.work) == 0:
				model.events.append({"at":float(finished.finish) + _period, "kind":"return_workers", "from":gid, "group":model.target, "action":true})
	# Already launched attacks are public commitments. Their impact is checked
	# again at arrival against the projected target, just like the real rule.
	for tool in world.pending_strikes:
		if not _open(): return model
		var flight: Dictionary = world.pending_strikes[tool]
		var gid := int(flight.target_group)
		if not world.cards.has(tool) or not model.groups.has(gid) or bool(model.groups[gid].union): continue
		if int(flight.owner) == side: continue
		var landing := maxf(0.0, float(flight.remaining))
		var recovery := _strike_recovery_target(model,landing,gid,tool)
		model.events.append({"at":landing, "kind":"strike", "group":gid, "flight":tool})
		if gid!=recovery: model.events.append({"at":landing+_period,"kind":"strike_feed","group":recovery,"flight":tool,"action":true})
		model.events.append({"at":landing + _config.number("strike", "duration_seconds") + _period,
			"kind":"strike_return", "group":recovery, "flight":tool, "action":true})
		model.pending_strikes += 1
	model["unreachable"] = _provably_unreachable(world,model)
	return model

## A sufficient resource proof, not a personnel cap. Keep every legal action:
## dismissing the last employee remains valid when it can fund a real escape.
## A slow projection or mutual transfers are not themselves a proof of loss.
func _provably_unreachable(world: OffWorkState, model: Dictionary) -> bool:
	var left := int(model.work)-int(model.pending_work)
	if left <= 0: return false
	var side := int(model.owner)
	for kind in model.types:
		if _config.is_person(str(kind)) and int(model.types[kind])>0: return false
	for batch in world.recruitment.values():
		if int(batch.owner)==side and int(batch.count)>0: return false
	var funds := float(model.free_cash)
	var cheapest_person := INF
	var outsource_price := 0.0 if int(model.types.get("outsource",0))>0 else INF
	for kind in _config.cards:
		if not _config.can_purchase(str(kind)) or not world.can_acquire(str(kind),side): continue
		if _config.is_person(str(kind)): cheapest_person=minf(cheapest_person,float(_config.cards[kind].price))
		if kind=="outsource": outsource_price=minf(outsource_price,float(_config.cards[kind].price))
	for offer in world.offers:
		if offer.is_empty() or not _config.can_purchase(str(offer.type)) or not world.can_acquire(str(offer.type),side): continue
		if _config.is_person(str(offer.type)): cheapest_person=minf(cheapest_person,float(offer.price))
		if offer.type=="outsource": outsource_price=minf(outsource_price,float(offer.price))
	return funds<cheapest_person and funds<outsource_price+left*_config.number("outsource","cost_per_work")

func _stats(group: Dictionary) -> Dictionary:
	if int(group.work) <= 0 or str(group.mode) not in ["", "work", "transfer"]:
		return {"rate":0.0, "batch":0, "income":0.0}
	var left := int(group.work)
	var people := 0
	var speed := 0.0
	var batch := 0
	var income := 0.0
	for unit in group.workers.values():
		if not _open(): return {"rate":0.0, "batch":0, "income":0.0}
		if left <= 0: break
		var count := mini(int(unit.count), ceili(float(left) / maxi(1, int(unit.capacity))))
		var output := mini(left, count * int(unit.capacity))
		people += count
		speed += count * float(unit.speed)
		batch += output
		income += output * float(unit.income)
		left -= output
	var multiplier := 1.0
	if group.mode != "transfer" and not group.union:
		# Every actual overtime card participates. Exponent clipping only avoids
		# floating overflow; it is far beyond the allocation limit's useful speed.
		multiplier = exp(minf(600.0, int(group.overtime) * log(_config.number("overtime", "speed_multiplier"))))
	return {"rate":speed / maxi(1, people) * multiplier, "batch":batch, "income":income}

func _advance_group(group: Dictionary, seconds: float) -> Dictionary:
	var stats := _stats(group)
	if not _complete or float(stats.rate) <= 0.0 or int(stats.batch) <= 0:
		return {"income":0.0, "done":0, "finish":0.0}
	var before := int(group.work)
	var progress := clampf(float(group.progress), 0.0, 1.0)
	var batch := int(stats.batch)
	# Keep the final (possibly partial) batch separate: fewer participants can
	# change its shared clock, particularly with custom heterogeneous roles.
	var full := maxi(0, ceili(float(before) / batch) - 1)
	var cycles := mini(full, maxi(0, floori(progress + seconds * float(stats.rate) + 1e-9)))
	var used := 0.0
	var income := cycles * float(stats.income)
	group.work -= cycles * batch
	if cycles > 0: used = maxf(0.0, (cycles - progress) / float(stats.rate))
	if cycles < full:
		group.progress = progress + seconds * float(stats.rate) - cycles
		return {"income":income, "done":before - int(group.work), "finish":0.0}
	var final := _stats(group)
	var final_progress := progress if cycles == 0 else 0.0
	var remaining := maxf(0.0, (1.0 - final_progress) / maxf(1e-300, float(final.rate)))
	if used + remaining <= seconds + 1e-9:
		income += float(final.income)
		group.work = 0
		group.progress = 0.0
		return {"income":income, "done":before, "finish":used + remaining}
	group.progress = final_progress + maxf(0.0, seconds - used) * float(final.rate)
	return {"income":income, "done":before - int(group.work), "finish":0.0}

## All hypothetical commands share one action clock. Material/staff modifiers
## for the same production destination can travel in one legal assemble_work
## command. Purchasing and facility funding consume separate action slots.
func _schedule(source: Array, first: float) -> Dictionary:
	var events: Array = source.duplicate(true)
	for index in events.size(): events[index]["schedule_order"]=index
	events.sort_custom(func(a, b):
		if float(a.at)!=float(b.at): return float(a.at)<float(b.at)
		# A funded purchase can use this action immediately; dispatching idle
		# people first is not a rule prerequisite. Buy first, then combine the
		# existing idle staff and the new hire in the same legal assembly slot.
		# Stable source order otherwise preserves event/dependency ordering.
		if (a.kind=="spend")!=(b.kind=="spend"): return a.kind=="spend"
		return int(a.schedule_order)<int(b.schedule_order))
	for index in events.size(): events[index].schedule_order=index
	var operations := {}
	var assembly := {}
	var commands := {}
	var last := first - _period
	for event in events:
		if not _open(): break
		var dependency := str(event.get("after", ""))
		if not dependency.is_empty(): event.at = maxf(float(event.at), float(operations.get(dependency, 0.0)) + float(event.lag))
		if not bool(event.get("action", false)):
			if event.has("operation"):
				operations[str(event.operation)]=float(event.at)
				commands[str(event.operation)]=event
			continue
		var operation := str(event.get("operation", "assemble:%s" % event.get("group", -1)))
		var ready := maxf(0.0, float(event.at) - _period)
		var combined := -1.0
		if operation.begins_with("assemble:"):
			for slot in assembly.get(operation, []):
				if float(slot) >= ready and (dependency.is_empty() or float(slot) > float(operations.get(dependency, 0.0))):
					combined = float(slot)
					break
		if combined >= 0.0:
			event.at = combined
		else:
			var earliest := maxf(ready, last + _period)
			if not dependency.is_empty(): earliest = maxf(earliest, float(operations.get(dependency, 0.0)) + _period)
			event.at = first + maxf(0.0, ceil((earliest - first - 1e-9) / _period)) * _period
			last = float(event.at)
			if operation.begins_with("assemble:"):
				if not assembly.has(operation): assembly[operation] = []
				assembly[operation].append(last)
		event["action_key"] = "%s@%.9f" % [operation, float(event.at)]
		commands[operation] = event
		operations[operation] = float(event.at)
	events.sort_custom(func(a, b):
		return float(a.at)<float(b.at) if float(a.at)!=float(b.at) else int(a.schedule_order)<int(b.schedule_order))
	return {"events":events, "operations":operations, "commands":commands}

func _context(model: Dictionary) -> Dictionary:
	return {"model":model,"groups":model.groups.duplicate(true),"scheduled":_schedule(model.events,float(model.first_action)),
		"pending":int(model.pending_work),"funded":{},"displaced":{},"displaced_sources":{},"struck":{},"required":{},"failed":{},"paused":{},"meetings":{},"purchases":{},"payments":{},
		"time":0.0,"finish":0.0,"earned":0.0,"spent":0.0,"transferred":0,"cursor":0}

func _advance_context(context: Dictionary, until: float) -> int:
	var transferred := 0
	for group in context.groups.values():
		if not _open(): break
		var result := _advance_group(group,until-float(context.time))
		context.earned += float(result.income)
		if group.mode == "transfer": transferred += int(result.done)
		if float(result.finish) > 0.0: context.finish=maxf(float(context.finish),float(context.time)+float(result.finish))
	context.transferred += transferred
	context.time = until
	return transferred

func _remaining(context: Dictionary) -> int:
	var count := int(context.pending)
	for group in context.groups.values(): count += int(group.work)
	return count

func _forecast_result(context: Dictionary, eta: float, remaining: int) -> Dictionary:
	return {"eta":eta,"remaining":remaining,"income":context.earned,
		"uncommitted":maxi(0,remaining-int(context.pending)),
		"cash":float(context.model.free_cash)+float(context.earned)-float(context.spent),
		"transferred":context.transferred,"stalled":remaining>0,"unreachable":context.model.get("unreachable",false),
		"required_actions":context.required.size(),"_required_commands":context.required.duplicate(),
		"_payments":context.payments.duplicate(true),
		"forecast_purchases":context.purchases.duplicate(true)}

func _forecast(model: Dictionary, horizon: float = -1.0) -> Dictionary:
	if horizon < 0.0: horizon = _horizon
	if not _open(): return {"eta":0.0,"cash":0.0,"required_actions":0}
	var key := Marshalls.raw_to_base64(var_to_bytes([model,horizon,_period,_base_cycle]))
	var cache: Dictionary = _projection_cache[int(model.owner)]
	if cache.has(key): return cache[key].duplicate(true)
	var result := _forecast_uncached(model,horizon)
	if _open(): cache[key]=result.duplicate(true)
	return result

func _forecast_uncached(model: Dictionary, horizon: float = -1.0) -> Dictionary:
	if horizon < 0.0: horizon = _horizon
	var context := _context(model)
	var events: Array = context.scheduled.events.duplicate()
	events.append({"at":horizon,"kind":"end"})
	for event in events:
		if not _open(): break
		_advance_context(context,minf(horizon,maxf(float(context.time),float(event.at))))
		if float(event.at) > horizon: break
		_apply_forecast_event(context,event)
		if _remaining(context) <= 0: return _forecast_result(context,float(context.finish),0)
		if float(context.time) >= horizon: break
	var left := _remaining(context)
	return _forecast_result(context,horizon+left*_base_cycle,left)

func _apply_forecast_event(context: Dictionary, event: Dictionary) -> void:
	var groups: Dictionary = context.groups
	var time := float(context.time)
	var dependency := str(event.get("after",""))
	if not dependency.is_empty() and context.failed.has(dependency):
		_fail_operation(context,event)
		return
	match str(event.kind):
		"commit_attack": _require(event,context.required,context.scheduled.commands)
		"meeting_host":
			for group in groups.values():
				group.workers.erase(event.id)
				group.present.erase(event.id)
			_require(event,context.required,context.scheduled.commands)
		"meeting_pause":
			var participants := {}
			for id in event.targets:
				if context.struck.has(id) or context.paused.has(id): continue
				for gid in groups:
					var group: Dictionary = groups[gid]
					if not group.present.has(id): continue
					participants[id]={"group":gid,"unit":group.present[id],"working":group.workers.has(id)}
					group.workers.erase(id)
					group.present.erase(id)
					context.paused[id]=true
			context.meetings[event.meeting]=participants
		"meeting_end":
			for id in context.meetings.get(event.meeting,{}):
				var participant: Dictionary = context.meetings[event.meeting][id]
				context.paused.erase(id)
				groups[participant.group].present[id]=participant.unit
				if participant.working: groups[participant.group].workers[id]=participant.unit
		"meeting_dispatch":
			for id in context.meetings.get(event.meeting,{}):
				var participant: Dictionary = context.meetings[event.meeting][id]
				if participant.working or not _config.can_work(str(participant.unit.role)): continue
				groups[participant.group].present.erase(id)
				groups[event.group].present[id]=participant.unit
				groups[event.group].workers[id]=participant.unit
				if int(groups[event.group].work)>0: _require(event,context.required,context.scheduled.commands)
		"coffee_start":
			for group in groups.values():
				group.workers.erase(event.id)
				group.present.erase(event.id)
		"strike":
			var target: Dictionary = groups[event.group]
			var valid: bool = float(_stats(target).rate) > 0.0 or time < float(target.strike_until)
			if valid and not target.union:
				var affected := {}
				for id in target.present:
					if bool(target.present[id].strikeable):affected[id]=target.present[id]
				context.displaced[event.flight] = affected
				context.displaced_sources[event.flight]=event.group
				for id in affected:
					context.struck[id] = true
					target.workers.erase(id)
					target.present.erase(id)
		"strike_feed":
			var source: int = int(context.displaced_sources.get(event.flight,-1))
			if source>=0 and source!=int(event.group) and groups[source].workers.is_empty() and not context.displaced.get(event.flight,{}).is_empty():
				# A real post-hit model can consolidate abandoned materials now,
				# before the people recover. Price that same command here.
				if int(groups[source].work)>0 or int(groups[source].overtime)>0: _require(event,context.required,context.scheduled.commands)
				groups[event.group].work+=int(groups[source].work)
				groups[source].work=0
				if not groups[event.group].union:
					groups[event.group].overtime+=int(groups[source].overtime)
					groups[source].overtime=0
		"strike_return":
			if not context.displaced.get(event.flight, {}).is_empty() and int(groups[event.group].work) > 0: _require(event, context.required, context.scheduled.commands)
			for id in context.displaced.get(event.flight, {}):
				var worker: Dictionary = context.displaced[event.flight][id]
				context.struck.erase(id)
				groups[event.group].present[id] = _unit(worker.role,int(worker.count),bool(groups[event.group].union),false)
				if _config.can_work(worker.role): groups[event.group].workers[id] = groups[event.group].present[id]
		"worker":
			if context.struck.has(event.id) or context.paused.has(event.id): return
			for group in groups.values(): group.present.erase(event.id)
			groups[event.group].present[event.id] = event.unit
			groups[event.group].workers[event.id] = event.unit
			if int(groups[event.group].work) > 0: _require(event, context.required, context.scheduled.commands)
		"overtime":
			groups[event.group].overtime += int(event.amount)
			if int(groups[event.group].work) > 0: _require(event, context.required, context.scheduled.commands)
		"move_work":
			if int(groups[event.from].work) > 0: _require(event, context.required, context.scheduled.commands)
			groups[event.group].work += int(groups[event.from].work)
			groups[event.from].work = 0
		"return_workers":
			if int(groups[event.from].work) == 0:
				if not groups[event.from].workers.is_empty() and int(groups[event.group].work) > 0: _require(event, context.required, context.scheduled.commands)
				for id in groups[event.from].workers:
					var worker: Dictionary = groups[event.from].workers[id]
					groups[event.group].workers[id] = _unit(worker.role, int(worker.count), bool(groups[event.group].union), false)
					groups[event.group].present[id] = groups[event.group].workers[id]
					groups[event.from].present.erase(id)
				groups[event.from].workers.clear()
		"settle":
			# A future batch exists only after its funding actually succeeded.
			# Already committed real batches have no hypothetical batch key.
			context.pending -= int(context.funded.get(event.batch,0)) if event.has("batch") else int(event.amount)
			context.finish = maxf(context.finish, time)
		"spend":
			if float(context.model.free_cash)+float(context.earned)-float(context.spent)<float(event.amount) or time>=float(event.get("expires",INF)):
				_fail_operation(context,event)
				return
			context.spent += float(event.amount)
			if not str(event.get("operation","")).is_empty(): context.payments[str(event.operation)]={"at":time,"amount":float(event.amount)}
			if event.has("offer"): context.purchases[int(event.offer)]={"at":time,"owner":int(context.model.owner),"price":float(event.amount)}
		"fund_outsource":
			var cash := maxf(0.0,float(context.model.free_cash)+float(context.earned)-float(context.spent))
			var affordable := mini(int(event.amount),floori(cash/float(event.unit_cost)))
			var left := affordable
			for group in groups.values():
				var take := mini(left, int(group.work))
				group.work -= take
				context.pending += take
				left -= take
				if left <= 0: break
			# The same concrete batch is settled, even if natural production
			# reduced the amount before its materials could be moved.
			context.funded[event.batch] = affordable - left
			context.spent += int(context.funded[event.batch]) * float(event.unit_cost)
			if int(context.funded[event.batch]) > 0:
				context.payments[str(event.get("operation",event.batch))]={"at":time,"amount":int(context.funded[event.batch])*float(event.unit_cost)}
				_require(event, context.required, context.scheduled.commands)

func _fail_operation(context: Dictionary, event: Dictionary) -> void:
	var operation := str(event.get("operation",""))
	if not operation.is_empty(): context.failed[operation]=true


## A transferred file remains in the match. Both sides' batch completions and
## committed timed events are settled at the same timestamp before checking
## either clear, so symmetric passing cannot hallucinate two finite finishes.
func _coupled_forecast(models: Array) -> Array:
	var contexts := [_context(models[0]),_context(models[1])]
	var completed := [-1.0,-1.0]
	var time := 0.0
	var cycles := {}
	while time < _horizon and _open():
		var next := _horizon
		for context in contexts:
			var events: Array = context.scheduled.events
			if int(context.cursor)<events.size(): next=minf(next,float(events[int(context.cursor)].at))
			for group in context.groups.values():
				var stats := _stats(group)
				if float(stats.rate)>0.0: next=minf(next,time+maxf(0.0,1.0-float(group.progress))/float(stats.rate))
		next=maxf(time,next)
		var transfers := [_advance_context(contexts[0],next),_advance_context(contexts[1],next)]
		for side in 2:
			var incoming := int(transfers[1-side])
			if incoming>0:
				var target: int = models[side].incoming_target
				var largest := -1
				for gid in contexts[side].groups:
					if int(contexts[side].groups[gid].work)>largest:
						largest=int(contexts[side].groups[gid].work)
						target=int(gid)
				contexts[side].groups[target].work += incoming
			var context: Dictionary = contexts[side]
			var events: Array = context.scheduled.events
			while int(context.cursor)<events.size() and float(events[int(context.cursor)].at)<=next+1e-9:
				_apply_forecast_event(context,events[int(context.cursor)])
				context.cursor += 1
		for side in 2:
			if completed[side]<0.0 and _remaining(contexts[side])<=0: completed[side]=next
		if completed[0]>=0.0 and completed[1]>=0.0: break
		if contexts.all(func(context): return int(context.cursor)>=context.scheduled.events.size()):
			var state_key := Marshalls.raw_to_base64(var_to_bytes([contexts[0].groups,contexts[1].groups,contexts[0].pending,contexts[1].pending]))
			if cycles.has(state_key): break
			cycles[state_key] = true
		if next<=time and next<_horizon:
			# Only sub-float cycles can remain at the same instant after all due
			# commands have been consumed. A numerical epsilon advances them.
			next=minf(_horizon,time+1e-8)
		time=next
	var results := []
	for side in 2:
		var remaining := _remaining(contexts[side])
		var eta := float(completed[side]) if completed[side]>=0.0 else _horizon+remaining*_base_cycle
		var result := _forecast_result(contexts[side],eta,0 if completed[side]>=0.0 else remaining)
		result["coupled_transfer"] = true
		results.append(result)
	return results

func _forecast_pair(models: Array) -> Array:
	for model in models:
		for group in model.groups.values():
			if group.mode=="transfer" and not group.workers.is_empty(): return _coupled_forecast(models)
	return [_finish_forecast(models[0]),_finish_forecast(models[1])]

## Closing the economic loop gives wages their actual purpose: paying to
## finish remaining documents. Cash itself receives no bonus. We compare
## natural completion with the first fully funded final outsource batch.
## A future unseen tool is only an estimate, charged its public price, an
## expected supply wait and separate buy/fund commands; it creates no quote,
## claim, worker or command that can be committed on the real table.
func _finish_forecast(model: Dictionary) -> Dictionary:
	if not _open(): return {"eta":0.0,"required_actions":0}
	var key := Marshalls.raw_to_base64(var_to_bytes([model,_period,_horizon,_base_cycle,_cashout_enabled,_supply_wait]))
	var cache: Dictionary = _finish_cache[int(model.owner)]
	if cache.has(key): return cache[key].duplicate(true)
	var result := _finish_forecast_uncached(model)
	if _open(): cache[key]=result.duplicate(true)
	return result

func _finish_forecast_uncached(model: Dictionary) -> Dictionary:
	var natural := _forecast(model)
	if not _cashout_enabled or not _open() or bool(model.get("unreachable",false)): return natural
	var best := _finish_with_facilities(model,natural)
	if not _open(): return best
	var may_buy: bool = is_finite(_supply_wait) and (not _config.cards.outsource.has("max_per_owner") \
		or int(model.types.get("outsource",0))<int(_config.cards.outsource.max_per_owner))
	# An already owned tool ready before estimated supply dominates buying
	# another tool for the same final batch: no extra price or command needed.
	for facility in model.facilities:
		if facility.kind=="outsource" and not facility.has("after") and float(facility.ready)<=_supply_wait:
			may_buy=false
	if not may_buy: return best
	var purchased := _supply_purchase_model(model,minf(_horizon,float(best.eta)-_config.number("outsource","seconds")-_period),_last_payment(natural))
	if purchased.is_empty() or not _open(): return best
	var projected := _finish_with_facilities(purchased,_forecast(purchased))
	if _open() and projected.get("cashout",{}).get("future_supply",false) and float(projected.eta)<float(best.eta): return projected
	return best

## Owned and statistically supplied facilities use exactly the same funding
## path. A supplied tool is present only after its own successful payment.
func _finish_with_facilities(model: Dictionary, natural: Dictionary) -> Dictionary:
	if not _open(): return natural
	var facilities := []
	for facility in model.facilities:
		if facility.kind=="outsource": facilities.append(facility)
	if facilities.is_empty(): return natural
	var context := _context(model)
	var events: Array = context.scheduled.events.duplicate()
	events.append({"at":minf(_horizon,float(natural.eta)),"kind":"end"})
	var best: Dictionary = natural
	var unit_cost: float = _config.number("outsource","cost_per_work")
	var duration: float = _config.number("outsource","seconds")
	# Economic closure follows the selected investment's financial prefix.
	# Otherwise funding all work could spend cash that an already evaluated
	# later attack/recipe purchase still needs, while retaining its benefits.
	var financed := _last_payment(natural)
	for event in events:
		if not _open(): return best
		var end := minf(float(event.at),minf(_horizon,float(best.eta)-duration))
		if end<float(context.time): break
		for facility in facilities:
			if not _open(): return best
			var dependency := str(facility.get("after",""))
			if not dependency.is_empty() and not context.payments.has(dependency): continue
			var future: bool = facility.get("future_supply",false)
			var start := maxf(financed,maxf(float(context.time),float(facility.ready)))
			if start>end: continue
			var tail: Dictionary = context.duplicate(true)
			_advance_context(tail,end)
			if not _can_cash_out(tail,unit_cost,0.0): continue
			# Within one scheduled-event interval, earned cash grows and work
			# shrinks monotonically. Search actual command slots, not an
			# approximate continuous threshold: rounding a slightly late binary
			# estimate up can otherwise charge a whole extra action interval.
			var first := float(model.first_action)
			var low := maxi(0,int(ceil((start-first-1e-8)/_period)))
			var high := maxi(low,int(ceil((end-first-1e-8)/_period)))
			while low<high:
				if not _open(): return best
				var middle := low+int((high-low)/2.0)
				var probe: Dictionary = context.duplicate(true)
				_advance_context(probe,clampf(first+middle*_period,start,end))
				if _can_cash_out(probe,unit_cost,0.0): high=middle
				else: low=middle+1
			var funding := _free_action_slot(context.scheduled.events,first+low*_period,first)
			# Buy, fund and every earlier planned command use the same clock.
			var eta := funding+duration
			for settlement in events:
				if settlement.kind=="settle" and not settlement.has("batch"): eta=maxf(eta,float(settlement.at))
			if eta>=float(best.eta): continue
			var funded := _forecast(model,funding)
			if not _open(): return best
			var payment := int(funded.uncommitted)*unit_cost
			if float(funded.cash)+1e-8<payment: continue
			best=funded.duplicate(true)
			best.eta=eta
			best.remaining=0
			best.uncommitted=0
			best.stalled=false
			best.cash-=payment
			_require({"action_key":"cashout@%.9f"%funding,"after":dependency},best._required_commands,context.scheduled.commands)
			best.required_actions=best._required_commands.size()
			best["cashout"]={"funding_at":funding,"eta":eta,"future_supply":future,
				"supply_wait":_supply_wait if future else 0.0,"tool_price":float(_config.cards.outsource.price) if future else 0.0}
			if future: best.cashout["purchase_at"]=float(facility.purchase_at)
		if float(event.at)>=minf(_horizon,float(best.eta)): break
		_advance_context(context,float(event.at))
		_apply_forecast_event(context,event)
		if _remaining(context)<=0: break
	return best

func _can_cash_out(context: Dictionary, unit_cost: float, price: float) -> bool:
	var cash := float(context.model.free_cash)+float(context.earned)-float(context.spent)
	return cash+1e-8>=price+maxi(0,_remaining(context)-int(context.pending))*unit_cost

func _free_action_slot(events: Array, at: float, first: float) -> float:
	var slot := first+maxf(0.0,ceil((at-first-1e-8)/_period))*_period
	# Scheduled events retain every assembly action; the operation dictionary
	# can contain only the final occurrence of a repeated operation name.
	for event in events:
		if event.has("action_key") and float(event.at)<=slot+1e-9:
			slot=maxf(slot,float(event.at)+_period)
	return slot

## Estimate availability, then finance a real purchase at a free action slot.
## Earlier spending can make cash non-monotonic, so search only between
## scheduled events and apply every intervening payment before continuing.
## The existing attack/return plan keeps its already evaluated action times.
func _last_payment(forecast: Dictionary) -> float:
	var latest := 0.0
	for payment in forecast.get("_payments",{}).values(): latest=maxf(latest,float(payment.at))
	return latest

func _supply_purchase_model(model: Dictionary, until: float, financed: float = 0.0) -> Dictionary:
	var available := maxf(_supply_wait,financed)
	if available>until or not _open(): return {}
	var context := _context(model)
	var events: Array = context.scheduled.events.duplicate()
	events.append({"at":until,"kind":"end"})
	var first := float(model.first_action)
	var price := float(_config.cards.outsource.price)
	for event in events:
		if not _open(): return {}
		# At an event boundary, finish all existing events before spending.
		var end := minf(until,float(event.at)-(0.0 if event.kind=="end" else 1e-8))
		var start := _free_action_slot(context.scheduled.events,maxf(available,float(context.time)),first)
		if start<=end:
			var tail: Dictionary = context.duplicate(true)
			_advance_context(tail,end)
			if float(model.free_cash)+float(tail.earned)-float(tail.spent)>=price:
				var low := maxi(0,ceili((start-first-1e-9)/_period))
				var high := maxi(low,floori((end-first+1e-9)/_period))
				while low<high:
					if not _open(): return {}
					var middle := low+int((high-low)/2.0)
					var probe: Dictionary = context.duplicate(true)
					_advance_context(probe,first+middle*_period)
					if float(model.free_cash)+float(probe.earned)-float(probe.spent)>=price: high=middle
					else: low=middle+1
				var purchase := _free_action_slot(context.scheduled.events,first+low*_period,first)
				if purchase<=end:
					var funded: Dictionary = context.duplicate(true)
					_advance_context(funded,purchase)
					if float(model.free_cash)+float(funded.earned)-float(funded.spent)>=price:
						var result: Dictionary = model.duplicate(true)
						var operation := "supply:outsource"
						# This free slot is already validated. Register its command
						# and payment without rescheduling the existing plan.
						result.events.append({"at":purchase,"kind":"spend","amount":price,"action":false,
							"operation":operation,"action_key":"%s@%.9f"%[operation,purchase]})
						result.types.outsource=int(result.types.get("outsource",0))+1
						result.facilities.append({"kind":"outsource","ready":purchase+_period,"after":operation,
							"future_supply":true,"purchase_at":purchase})
						return result
		if float(event.at)>=until: break
		_advance_context(context,float(event.at))
		_apply_forecast_event(context,event)
	return {}

func _race(forecasts: Array, owner: int) -> float:
	var own_dead: bool = forecasts[owner].get("unreachable",false)
	var other_dead: bool = forecasts[1-owner].get("unreachable",false)
	# Relative finishing order is the objective. Subtracting reciprocal ETAs
	# can prefer making an already-losing side even slower: both paces then
	# approach zero, disguising a larger actual and proportional deficit.
	var time_race := log(maxf(0.000001,float(forecasts[1-owner].eta)) \
		/maxf(0.000001,float(forecasts[owner].eta)))
	if own_dead or other_dead:
		if own_dead==other_dead: return 0.0
		# Keep completing faster preferable inside the winning/losing class.
		# Otherwise an already helpless opponent could make destroying our own
		# productive arrangements appear equally good as actually finishing.
		return (-400.0 if own_dead else 400.0)+clampf(time_race,-99.0,99.0)
	return clampf(time_race,-250.0,250.0)

func _attack_continuations(world: OffWorkState, original: Array, continuation: Array, forecasts: Array, forced_order: Array = []) -> Array:
	var initial_forecasts: Array = forecasts.duplicate(true)
	var models: Array = continuation.duplicate(true)
	var claimed := {}
	var order := forced_order if not forced_order.is_empty() else ([0,1] if float(_next_actions[0])<=float(_next_actions[1]) else [1,0])
	for side in order:
		if not _open(): return forecasts
		var generated: Dictionary = AttackPlans.plans(world,int(side),_deadline)
		if not generated.complete:
			_complete=false
			return forecasts
		var best_score := _race(forecasts,side)
		var selected := {}
		for plan in generated.plans:
			if not _open(): return forecasts
			# One optional investment is replaced by this concrete attack plan;
			# earlier opposing attacks remain part of the physical continuation.
			var own: Dictionary = original[side].duplicate(true)
			for event in models[side].events:
				if bool(event.get("attack_effect",false)): own.events.append(event.duplicate(true))
			var candidate := _attack_candidate(world,own,models[1-side],plan)
			if candidate.is_empty(): continue
			if plan.has("offer") and claimed.has(plan.offer):
				if forced_order.is_empty() and float(candidate.detail.purchase_at)<float(claimed[plan.offer].purchase_at)-1e-9:
					return _attack_continuations(world,original,continuation,initial_forecasts,[side,1-side])
				continue
			var pair := [candidate.own,candidate.other] if side==0 else [candidate.other,candidate.own]
			pair=_gate_attacks(pair)
			if not pair[side].has("_attack_plan"): continue
			var projected := _forecast_pair(pair)
			if not _complete: return forecasts
			var score := _race(projected,side)
			if score>best_score+1e-9:
				best_score=score
				selected={"models":pair,"forecast":projected,"plan":candidate.detail}
		if not selected.is_empty():
			models=selected.models
			claimed.clear()
			for owner in 2:
				forecasts[owner].merge(selected.forecast[owner],true)
				if models[owner].has("_attack_plan"):
					var attack: Dictionary = models[owner]._attack_plan
					forecasts[owner].public_investment=attack
					forecasts[owner]["forecast_attack"]=attack
					if attack.has("offer"): claimed[attack.offer]=attack
				elif forecasts[owner].has("forecast_attack"):
					forecasts[owner].erase("forecast_attack")
					forecasts[owner].public_investment={}

	return forecasts

## A later opposing plan may interrupt the earnings or host that an earlier
## plan relied on. Recheck the actual command prefix and remove its cross-side
## effect when that purchase/use no longer happens; paid purchases stay spent.
func _gate_attacks(source: Array) -> Array:
	var models: Array = source.duplicate(true)
	for side in 2:
		if not _open(): return models
		if not models[side].has("_attack_plan"): continue
		var plan: Dictionary = models[side]._attack_plan
		var context := _context(models[side])
		if not _open(): return models
		var valid := true
		for event in context.scheduled.events:
			if not _open(): return models
			if float(event.at)>float(plan.use_at)+1e-9: break
			_advance_context(context,float(event.at))
			if str(event.get("operation",""))==str(plan.operation):
				if context.failed.has(str(plan.purchase_operation)):valid=false
				if plan.kind=="meeting":
					valid=valid and not context.struck.has(plan.host) and not context.paused.has(plan.host)
					valid=valid and context.groups.values().any(func(group):return group.present.has(plan.host))
				break
			_apply_forecast_event(context,event)
		if valid: continue
		var replacement: Dictionary = models[side]._without_attack.duplicate(true)
		# Keep newly introduced enemy effects and any money already committed.
		replacement.events=replacement.events.filter(func(event):return not bool(event.get("attack_effect",false)))
		for event in models[side].events:
			if bool(event.get("attack_effect",false)) or (not str(plan.purchase_operation).is_empty() and str(event.get("operation",""))==str(plan.purchase_operation)):
				replacement.events.append(event.duplicate(true))
		models[side]=replacement
		models[1-side].events=models[1-side].events.filter(func(event):return int(event.get("attack_owner",-1))!=side)
	return models

## Re-evaluate the surviving production destination at impact. Keeping the
## pre-hit destination makes an imagined future strike and the same already-hit
## public world use different recovery plans.
func _strike_recovery_target(model: Dictionary, impact: float, target: int, flight: Variant) -> int:
	var context := _context(model)
	for event in context.scheduled.events:
		if not _open(): return int(model.target)
		if float(event.at)>impact: break
		_advance_context(context,float(event.at))
		_apply_forecast_event(context,event)
	_advance_context(context,impact)
	_apply_forecast_event(context,{"at":impact,"kind":"strike","group":target,"flight":flight})
	var best := int(model.target)
	var power := -1.0
	var largest := -1
	for gid in context.groups:
		var group: Dictionary = context.groups[gid]
		if str(group.mode) not in ["","work"]: continue
		var stats := _stats(group)
		var rate := float(stats.rate)*int(stats.batch)
		if rate>power or (is_equal_approx(rate,power) and int(group.work)>largest):
			best=int(gid)
			power=rate
			largest=int(group.work)
	return best

func _attack_candidate(world: OffWorkState, model: Dictionary, opponent: Dictionary, plan: Dictionary) -> Dictionary:
	var own: Dictionary = model.duplicate(true)
	var other: Dictionary = opponent.duplicate(true)
	var purchase := ""
	var natural_restart := false
	if plan.kind=="meeting" and plan.has("tool") and float(plan.ready_seconds)>0.0:
		var card: Dictionary = world.cards[plan.tool]
		if bool(card.get("meeting_repeat",false)) and bool(_config.rules.meeting.auto_repeat) and str(world.groups[card.group].get("function","")) in ["","meeting"]:
			var hosts: Array = world._available_people(int(card.group))
			hosts.sort_custom(func(a,b):return float(_config.roles[world.cards[a].type].meeting_multiplier)>float(_config.roles[world.cards[b].type].meeting_multiplier))
			if not hosts.is_empty():
				# Keeping the existing host causes ONE natural restart on ready.
				# A different host cannot actively reuse an already restarted tool.
				if int(hosts[0])!=int(plan.host):return {}
				natural_restart=true
	var at := maxf(float(model.first_action),float(plan.ready_seconds))
	if plan.has("offer"):
		at=_afford_at(own,float(plan.price),float(plan.expires))
		if at<0.0: return {}
		purchase="buy:%s" % plan.offer
		own.events.append({"at":at+_period,"kind":"spend","amount":float(plan.price),"action":true,"operation":purchase,"offer":plan.offer,"expires":plan.expires})
		at+=_period
	var operation := "attack:%s:%s" % [plan.kind,plan.get("tool",plan.get("offer",-1))]
	var use := {"at":at+_period,"kind":"commit_attack","action":true,"operation":operation,"after":purchase,"lag":_period}
	if natural_restart:
		use.at=float(plan.ready_seconds)
		use.action=false
	if plan.kind=="meeting":
		use.kind="meeting_host"
		use["id"]=plan.host
		own.events=own.events.filter(func(event):return not (event.kind=="worker" and str(event.id)==str(plan.host)))
	own.events.append(use)
	var scheduled := _schedule(own.events,float(model.first_action))
	if not _open(): return {}
	if plan.has("offer") and float(scheduled.operations.get(purchase,INF))>=float(plan.expires):return {}
	var use_at := float(scheduled.operations[operation])
	if plan.kind=="meeting":
		var available := _context(own)
		if not _open(): return {}
		for event in available.scheduled.events:
			if not _open(): return {}
			if float(event.at)>use_at or str(event.get("operation",""))==operation: break
			_advance_context(available,float(event.at))
			_apply_forecast_event(available,event)
		if available.struck.has(plan.host) or available.paused.has(plan.host): return {}
		if not available.groups.values().any(func(group):return group.present.has(plan.host)): return {}
	var impact := use_at+float(plan.flight_seconds)
	if impact>=_horizon:return {}
	var duration := float(plan.duration_seconds)
	if plan.kind=="strike":
		var recovery := _strike_recovery_target(other,impact,int(plan.target_group),operation)
		other.events.append({"at":impact,"kind":"strike","group":plan.target_group,"flight":operation,"attack_effect":true,"attack_owner":int(model.owner)})
		if int(plan.target_group)!=recovery: other.events.append({"at":impact+_period,"kind":"strike_feed","group":recovery,"flight":operation,"action":true,"attack_effect":true,"attack_owner":int(model.owner)})
		other.events.append({"at":impact+duration+_period,"kind":"strike_return","group":recovery,"flight":operation,"action":true,"attack_effect":true,"attack_owner":int(model.owner)})
	else:
		var kind := str(world.cards[plan.host].type)
		if _config.can_work(kind):
			own.events.append({"at":use_at+duration+_period,"kind":"worker","id":plan.host,"group":model.target,
				"action":true,"after":operation,"lag":duration+_period,"unit":_unit(kind,1,bool(model.groups[model.target].union),false)})
		other.events.append({"at":impact,"kind":"meeting_pause","meeting":operation,"targets":plan.targets,"attack_effect":true,"attack_owner":int(model.owner)})
		other.events.append({"at":impact+duration,"kind":"meeting_end","meeting":operation,"attack_effect":true,"attack_owner":int(model.owner)})
		other.events.append({"at":impact+duration+_period,"kind":"meeting_dispatch","meeting":operation,"group":other.target,"action":true,"attack_effect":true,"attack_owner":int(model.owner)})
	var detail: Dictionary = plan.duplicate(true)
	detail["source"]="visible_attack" if plan.has("offer") else ("natural_meeting" if natural_restart else "owned_attack")
	detail["natural_restart"]=natural_restart
	detail["use_at"]=use_at
	detail["impact_at"]=impact
	detail["operation"]=operation
	detail["purchase_operation"]=purchase
	if plan.has("offer"): detail["purchase_at"]=scheduled.operations[purchase]
	own["_attack_plan"]=detail
	own["_without_attack"]=model.duplicate(true)
	return {"own":own,"other":other,"detail":detail}

func _require(event: Dictionary, required: Dictionary, commands: Dictionary) -> void:
	if event.has("action_key"): required[event.action_key] = true
	var dependency := str(event.get("after", ""))
	if not dependency.is_empty() and commands.has(dependency):
		_require(commands[dependency], required, commands)

## Each public card can fund only one physical continuation. Recompute the
## losing complete plan (including all cups of a recipe), using the opponent's
## current successful payments. Replacements release every old reservation.
## Earlier payment wins; simultaneous public purchases follow real seat order.
## A repeated pair is an unresolved market-policy cycle, not two free assets:
## conservatively retain only already-owned investments in that case.
func _economic_continuations(world: OffWorkState, models: Array) -> Array:
	var forecasts := [_best_forecast(world,models[0]),_best_forecast(world,models[1])]
	if not _open(): return forecasts
	var seen := {}
	var order := [0,1] if float(_next_actions[0])<=float(_next_actions[1]) else [1,0]
	while _open():
		var key := var_to_bytes([forecasts[0].public_investment,forecasts[0].forecast_purchases,forecasts[1].public_investment,forecasts[1].forecast_purchases])
		if seen.has(key):
			var unavailable := {}
			for offer in world.offers:
				if not offer.is_empty(): unavailable[int(offer.id)]={"at":-INF,"owner":-1}
			for side in 2:
				forecasts[side]=_best_forecast(world,models[side],unavailable)
				forecasts[side]["economic_claim_cycle"]=true
			return forecasts
		seen[key]=true
		var changed := false
		for side in order:
			if not _open(): return forecasts
			var next := _best_forecast(world,models[side],forecasts[1-side].forecast_purchases)
			if not _open(): return forecasts
			if var_to_bytes([next.public_investment,next.forecast_purchases])!=var_to_bytes([forecasts[side].public_investment,forecasts[side].forecast_purchases]): changed=true
			forecasts[side]=next
		if not changed: return forecasts
	return forecasts

func _can_claim(offer: int, at: float, owner: int, claimed: Dictionary) -> bool:
	if not claimed.has(offer): return true
	var earlier: Dictionary = claimed[offer]
	return at<float(earlier.at)-1e-9 or (absf(at-float(earlier.at))<=1e-9 and owner<int(earlier.owner))

func _claims_allowed(projected: Dictionary, owner: int, claimed: Dictionary) -> bool:
	for offer in projected.forecast_purchases:
		if not _can_claim(int(offer),float(projected.forecast_purchases[offer].at),owner,claimed): return false
	return true

func _best_forecast(world: OffWorkState, model: Dictionary, claimed: Dictionary = {}) -> Dictionary:
	if not _open(): return {"eta":0.0,"required_actions":0}
	var key := Marshalls.raw_to_base64(var_to_bytes([model,world.offers,world._conveyor_elapsed,_period,_horizon,_base_cycle,claimed,_cashout_enabled,_supply_wait]))
	var seat_cache: Dictionary = _forecast_cache[int(model.owner)]
	if seat_cache.has(key):
		cache_hits += 1
		return seat_cache[key].duplicate(true)
	cache_misses += 1
	var result := _compute_forecast(world,model,claimed)
	if _open(): seat_cache[key] = result.duplicate(true)
	return result

func _compute_forecast(world: OffWorkState, model: Dictionary, claimed: Dictionary = {}) -> Dictionary:
	var best := _finish_forecast(model)
	var continuation := model
	var investment := {}
	for person in model.upgrade_people:
		if not _open(): break
		if int(model.coffee) < int(person.cost): continue
		var candidate := _coffee(model,person,_period)
		var projected := _finish_forecast(candidate)
		if float(projected.eta) < float(best.eta):
			best = projected
			continuation = candidate
			investment = {"kind":"coffee", "source":"owned_recipe", "person":person.id, "to":person.to, "cost":person.cost}
	for facility in model.facilities:
		if not _open(): break
		var funded := _facility(model, facility.kind, maxf(_period, float(facility.ready) + _period), float(model.free_cash))
		if funded.is_empty(): continue
		var projected := _finish_forecast(funded)
		if float(projected.eta) < float(best.eta):
			best = projected
			continuation = funded
			investment = {"kind":facility.kind, "source":"owned", "at":maxf(_period, float(facility.ready) + _period)}
	for person in model.upgrade_people:
		if not _open(): break
		if int(model.coffee)>=int(person.cost): continue
		var recipe := _public_recipe(world,model,person,claimed)
		if recipe.is_empty(): continue
		var projected := _finish_forecast(recipe.model)
		if not _open(): break
		if not _claims_allowed(projected,int(model.owner),claimed): continue
		if float(projected.eta)<float(best.eta):
			best=projected
			continuation=recipe.model
			investment=recipe.investment
	for index in world.offers.size():
		if not _open(): break
		var offer: Dictionary = world.offers[index]
		if offer.is_empty(): continue
		var kind := str(offer.type)
		if not _config.can_purchase(kind): continue
		if _config.cards[kind].has("max_per_owner") and int(model.types.get(kind, 0)) >= int(_config.cards[kind].max_per_owner): continue
		if int(model.card_count) >= OffWorkConfig.MAX_CARD_ALLOCATION: continue
		var is_worker: bool = _config.is_person(kind) and _config.can_work(kind)
		if not is_worker and kind not in ["overtime", "outsource", "boss"]: continue
		var expires: float = (index + 1) * _config.number("conveyor", "interval_seconds") - world._conveyor_elapsed
		var at := _afford_at(model, float(offer.price), expires)
		if at < 0.0 or not _complete: continue
		var projected_model: Dictionary = model.duplicate(true)
		var purchase := "buy:%s" % offer.id
		projected_model.events.append({"at":at + _period, "kind":"spend", "amount":float(offer.price), "action":true, "operation":purchase,"offer":offer.id,"expires":expires})
		if is_worker:
			projected_model.events.append({"at":at + _period, "kind":"worker", "group":model.target,
				"id":"offer:%s" % offer.id, "action":true, "after":purchase, "lag":_period, "unit":_unit(kind, 1, bool(model.groups[model.target].union), false)})
		elif kind == "overtime":
			if bool(model.groups[model.target].union): continue
			projected_model.events.append({"at":at + _period, "kind":"overtime", "group":model.target, "amount":1, "action":true, "after":purchase, "lag":_period})
		elif kind=="outsource":
			projected_model.types.outsource=int(projected_model.types.get("outsource",0))+1
			projected_model.facilities.append({"kind":"outsource","ready":at+_period,"after":purchase,"offer":offer.id})
		else:
			var funds := maxf(0.0, float(_forecast(model, at).cash) - float(offer.price))
			projected_model = _facility(projected_model, "recruitment" if kind == "boss" else "outsource", at + _period, funds, purchase)
			if projected_model.is_empty(): continue
		var planned := _schedule(projected_model.events, float(model.first_action))
		if not _open(): break
		if float(planned.operations.get(purchase, INF)) >= expires: continue
		if not _can_claim(int(offer.id),float(planned.operations[purchase]),int(model.owner),claimed): continue
		var projected := _finish_forecast(projected_model)
		if not _open(): break
		if float(projected.eta) < float(best.eta):
			best = projected
			continuation = projected_model
			investment = {"kind":kind, "source":"visible_offer", "offer":offer.id, "price":offer.price, "purchase_at":planned.operations[purchase], "usable_at":float(planned.operations[purchase])+_period}
	best["_continuation"] = continuation
	best.merge({"work":model.work, "current_rate":model.current_rate, "idle_pending":model.idle_pending,
		"committed_work":model.pending_work, "pending_strikes":model.pending_strikes, "free_cash":model.free_cash, "public_investment":investment}, true)
	return best

## Complete a recipe only with cards already visible on the conveyor. Every
## cup is separately paid for and occupies an action before its real expiry.
func _public_recipe(world: OffWorkState, model: Dictionary, person: Dictionary, claimed: Dictionary = {}) -> Dictionary:
	var missing := int(person.cost)-int(model.coffee)
	var plan: Dictionary = model.duplicate(true)
	var purchases := []
	var previous := ""
	var last := 0.0
	var cost := 0.0
	for index in world.offers.size():
		if not _open(): return {}
		var offer: Dictionary = world.offers[index]
		if offer.is_empty() or offer.type != "coffee": continue
		var expires: float = (index+1)*_config.number("conveyor","interval_seconds")-world._conveyor_elapsed
		var at := _afford_at(plan,float(offer.price),expires)
		if at<0.0: continue
		var operation := "buy:%s" % offer.id
		var event := {"at":at+_period,"kind":"spend","amount":float(offer.price),"action":true,"operation":operation,"after":previous,"lag":_period,"offer":offer.id,"expires":expires}
		plan.events.append(event)
		var schedule := _schedule(plan.events,float(model.first_action))
		if not _open(): return {}
		if float(schedule.operations.get(operation,INF))>=expires or not _can_claim(int(offer.id),float(schedule.operations.get(operation,INF)),int(model.owner),claimed):
			plan.events.pop_back()
			continue
		last=float(schedule.operations[operation])
		previous=operation
		purchases.append({"offer":offer.id,"price":offer.price,"at":last,"expires":expires})
		cost+=float(offer.price)
		missing-=1
		if missing==0:
			plan=_coffee(plan,person,last+_period,previous)
			return {"model":plan,"investment":{"kind":"coffee","source":"visible_recipe","person":person.id,
				"to":person.to,"cost":person.cost,"price":cost,"purchases":purchases,"purchase_at":float(purchases[0].at)}}
	return {}

## A complete recipe is one real split/assembly command, timed upgrading,
## then a separate return to production. Ingredients receive no asset score.
func _coffee(model: Dictionary, person: Dictionary, at: float, purchase := "") -> Dictionary:
	var result: Dictionary = model.duplicate(true)
	result.events = result.events.filter(func(event): return not (event.kind == "worker" and str(event.id) == str(person.id)))
	var operation := "coffee:%s" % person.id
	result.events.append({"at":at,"kind":"coffee_start","id":person.id,"action":true,"operation":operation,"after":purchase,"lag":_period})
	result.events.append({"at":at + float(person.seconds) + _period,"kind":"worker","id":person.id,"group":model.target,
		"action":true,"after":operation,"lag":float(person.seconds)+_period,"unit":_unit(person.to,1,bool(model.groups[model.target].union),false)})
	return result

func _afford_at(model: Dictionary, price: float, expires: float) -> float:
	var first := float(model.first_action)
	var last := floori((expires - first - 1e-6) / _period)
	if last < 0: return -1.0
	if float(_forecast(model, first + last * _period).cash) < price: return -1.0
	var low := 0
	var high := last
	while low < high:
		if not _open(): return -1.0
		var middle := (low + high) / 2
		if float(_forecast(model, first + middle * _period).cash) >= price: high = middle
		else: low = middle + 1
	return first + low * _period

func _facility(model: Dictionary, kind: String, at: float, funds: float, purchase := "") -> Dictionary:
	var unit: int = _config.integer("recruitment", "cost_per_employee") if kind == "recruitment" else _config.integer("outsource", "cost_per_work")
	var count := floori(funds / unit)
	if kind == "recruitment": count = mini(count, maxi(0, OffWorkConfig.MAX_CARD_ALLOCATION - int(model.card_count)))
	else: count = mini(count, int(model.work) - int(model.pending_work))
	if count <= 0: return {}
	var result: Dictionary = model.duplicate(true)
	var funding := "fund:" + kind
	if kind == "recruitment":
		result.events.append({"at":at, "kind":"spend", "amount":count * unit, "action":true, "operation":funding, "after":purchase, "lag":_period})
		result.events.append({"at":at + _config.number("recruitment", "seconds") + _period, "kind":"worker", "group":model.target,
			"id":"future_recruitment", "action":true, "after":funding, "lag":_config.number("recruitment", "seconds")+_period, "unit":_unit("employee", count, bool(model.groups[model.target].union), false)})
	else:
		var batch := "funded_outsource"
		var settlement := {"at":at + _config.number("outsource", "seconds"), "kind":"settle", "amount":count, "batch":batch, "after":funding, "lag":_config.number("outsource", "seconds")}
		result.events.append({"at":at, "kind":"fund_outsource", "amount":count, "batch":batch, "unit_cost":unit, "action":true, "operation":funding, "after":purchase, "lag":_period})
		result.events.append(settlement)
		var scheduled := _schedule(result.events,float(model.first_action))
		if not _open(): return {}
		for facility in result.facilities:
			if facility.kind=="outsource" and float(facility.ready)<=at:
				facility.ready=float(scheduled.operations.get(funding,at))+_config.number("outsource","seconds")+_config.number("outsource","recovery_seconds")
				break
	return result
