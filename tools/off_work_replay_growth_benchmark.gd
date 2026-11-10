# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

## Behavior benchmark: real decisions, command clocks and rules, not a macro
## generator test. Run this same absolute script against two frozen runtimes.
## --request=/absolute/request.json --output=/absolute/result.json
const Config = preload("res://engine/off_work_config.gd")
const Bot = preload("res://engine/off_work_bot.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")
const Scripted = preload("res://tools/balance/off_work_scripted_baseline.gd")

var world: OffWorkState
var observations: Array = []
var stats: Array = []
var start_time := 0.0
var trace: FileAccess
var engine_source_sha256 := ""
var engine_source_files: Array = []

func _initialize() -> void:
	# Freeze the identity before any simulation. Reading sources at the end
	# would mislabel a running process when another agent edits the checkout.
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	var names := DirAccess.get_files_at("res://engine")
	names.sort()
	for name in names:
		if not name.begins_with("off_work") or not name.ends_with(".gd"): continue
		var relative := "engine/"+name
		engine_source_files.append(relative)
		digest.update((relative+"\n").to_utf8_buffer())
		digest.update(FileAccess.get_file_as_bytes("res://"+relative))
		digest.update(PackedByteArray([0]))
	engine_source_sha256=digest.finish().hex_encode()
	_run.call_deferred()

func _run() -> void:
	var request_path := ""
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--request="): request_path=arg.trim_prefix("--request=")
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
	if request_path.is_empty() or output.is_empty():
		printerr("Need --request and --output")
		quit(1)
		return
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	var result := _evaluate(request, output) if request is Dictionary else {"error":"invalid request"}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null:
		printerr("Cannot write result: ",output)
		quit(1)
		return
	file.store_string(JSON.stringify(result,"\t",false,true))
	file.close()
	if trace!=null: trace.close()
	print("OFF_WORK_GROWTH_RESULT ",output)
	quit(1 if result.has("error") else 0)

func _evaluate(request: Dictionary, output: String) -> Dictionary:
	var tape: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(request.get("replay",""))))
	if not tape is Dictionary or not tape.get("cards") is Dictionary or not tape.get("frames") is Array:
		return {"error":"replay requires the original card document and compressed frames"}
	var config := Config.new(tape.cards)
	if not config.errors.is_empty(): return {"error":str(config.errors)}
	var owner := int(request.get("owner",1))
	var strength := float(request.get("strength",0.5))
	var duration := float(request.get("seconds",60.0))
	if owner not in [0,1] or strength<0.0 or strength>1.0 or duration<=0.0:
		return {"error":"invalid owner, strength or duration"}
	var policy := Config.merge_bot_policy(config.rules.bot,
		Preferences.strength_parameters(strength,config.rules.bot,config.bot_preferences))
	config.rules.bot=policy.duplicate(true)
	world=OffWorkState.new(config)
	var seed_value := int(request.get("seed",20261110))
	var fixture: Dictionary = request.get("fixture",{})
	var restored_frame := -1
	if fixture.is_empty():
		var desired := float(request.get("start",0.0))
		for index in tape.frames.size():
			if float(tape.frames[index].t)<=desired: restored_frame=index
		if restored_frame<0: return {"error":"no frame at or before requested start"}
		var frame: Dictionary = tape.frames[restored_frame]
		var bytes := Marshalls.base64_to_raw(frame.data).decompress(int(frame.size),FileAccess.COMPRESSION_ZSTD)
		var entry: Variant = bytes_to_var(bytes)
		if not entry is Dictionary or not entry.get("world") is Dictionary: return {"error":"invalid replay frame"}
		for key in OffWorkState.WORLD_FIELDS:
			if not entry.world.has(key): return {"error":"missing replay field: "+str(key)}
			world.set(key,entry.world[key])
		world._rng.state=entry.rng
		world._invalidate_group_index()
		# Start at the requested timestamp under unchanged natural rules; the
		# old human/BOT actions after the restored frame are intentionally absent.
		world.advance(maxf(0.0,desired-world.time))
	else:
		# Capability fixture changes only initial placement/materials. Every
		# price, recipe, role capacity and income multiplier remains in the tape.
		config.rules.initial.groups=fixture.get("groups",config.rules.initial.groups).duplicate(true)
		config.rules.initial.money=int(fixture.get("money",config.rules.initial.money))
		if fixture.has("conveyor_pool"): config.rules.conveyor.pool=fixture.conveyor_pool.duplicate(true)
		world.new_game(seed_value)
		if fixture.get("clear_market",false): world.offers.clear()
	if world.winner>=0: return {"error":"starting state is terminal"}
	request=request.duplicate(true)
	request["supply_conditions"]={"recorded_conveyor":tape.cards.rules.conveyor.duplicate(true),
		"effective_conveyor":config.rules.conveyor.duplicate(true),
		"initial_market_cleared":bool(fixture.get("clear_market",false)),
		"market_cleared_before_each_decision":bool(fixture.get("disable_market",false)),
		"diagnostic_only":bool(fixture.get("disable_market",false))}
	request["simulation_assumptions"]={"controller_context":"cold_start","opponent":str(request.get("opponent","inactive")),
		"inactive_opponent":"continues existing natural production; receives no new commands",
		"action_clock":"configured game-time interval; computation does not advance game time",
		"decision_budget":"unmodified installed strength mapping",
		"market_rng":"recorded RNG for replay starts; requested seed for capability fixtures; never exposed to search",
		"sampling_seconds":0.5,"future_supply":"evaluator sees the effective public conveyor rules"}
	start_time=world.time
	trace=FileAccess.open(output+".jsonl",FileAccess.WRITE)
	if trace==null: return {"error":"cannot write trace"}
	stats=[_new_stats(0),_new_stats(1)]
	_observe()
	world.drain_events()
	var controllers: Array = [null,null]
	controllers[owner]=Bot.new(world,owner,policy,seed_value)
	var opponent := str(request.get("opponent","inactive"))
	if opponent=="bot": controllers[1-owner]=Bot.new(world,1-owner,policy,seed_value)
	elif opponent=="script":
		controllers[1-owner]=Scripted.new(world,1-owner,{"enabled":true,"mode":str(request.get("opponent_mode","growth")),
			"think_seconds":float(request.get("opponent_think_seconds",6.0)),"first_action_seconds":0.0},seed_value)
	elif opponent!="inactive": return {"error":"opponent must be inactive, bot or script"}
	for controller in controllers:
		if controller!=null: controller.start()
	var initial := _summary()
	_write({"type":"opening","request":request,"restored_frame":restored_frame,"start_time":start_time,
		"actual_policy":policy,"cards":config.balance_document(),"state":initial,
		"engine_source_sha256":engine_source_sha256,"engine_source_files":engine_source_files,
		"note":"Cold controller context; original hidden market RNG is used only by the rule engine, never supplied to search."})
	var started := Time.get_ticks_usec()
	var limit := start_time+duration
	while world.winner<0 and world.time<limit-0.000001:
		for seat in 2:
			var controller: RefCounted = controllers[seat]
			if controller==null or world.winner>=0 or world.time+0.000001<controller.next_action_time(): continue
			if fixture.get("disable_market",false): world.offers.clear()
			controller._next_think=world.time+float(controller._policy.think_seconds)
			var action: Dictionary = controller.decide_action()
			var report: Dictionary = controller.last_decision.duplicate(true)
			var applied: bool = controller.commit_action(action,report)
			stats[seat].decisions+=1
			stats[seat].apply_failures+=int(not applied)
			stats[seat].over_budget+=int(report.get("overrun",false))
			stats[seat].decision_us+=int(report.get("elapsed_us",0))
			_consume_events(world.drain_events())
			_observe()
			var diagnostics := {}
			for key in ["algorithm","budget_ms","elapsed_us","root_complete","root_candidates","completed_candidates",
				"search_depth","evaluation_layer","growth_continuation","root_growth","fallback","cutoff"]:
				if report.has(key): diagnostics[key]=report[key]
			_write({"type":"decision","time":world.time,"owner":seat,"action":action,"applied":applied,
				"diagnostics":diagnostics,"selected_evaluation":_selected_evaluation(report,seat),
				"context":controller.export_decision_context() if controller.has_method("export_decision_context") else {},"state":_summary()})
		if world.winner>=0: break
		var until := minf(limit,world.time+0.5)
		for controller in controllers:
			if controller!=null: until=minf(until,controller.next_action_time())
		if until<=world.time: return {"error":"simulation clock stalled"}
		world.advance(until-world.time)
		_consume_events(world.drain_events())
		_observe()
	for seat in 2:
		stats[seat].wages_reinvested_lower_bound=maxi(0,int(stats[seat].purchases_spent)+int(stats[seat].recruitment_spent)-int(stats[seat].initial_money))
		stats[seat].remaining_work=world.work_count(seat)
		stats[seat].remaining_money=world.money(seat)
		for row in stats[seat].purchases:
			row.observed_seconds=world.time-float(row.at)
			row.delay_seconds=float(row.first_use)-float(row.at) if float(row.first_use)>=0.0 else null
			row.work_delay_seconds=float(row.first_work)-float(row.at) if float(row.first_work)>=0.0 else null
		for row in stats[seat].initial_idle_staff:
			row.work_delay_seconds=float(row.first_work)-start_time if float(row.first_work)>=0.0 else null
	var result := {"request":request,"start_time":start_time,"end_time":world.time,"elapsed_game_seconds":world.time-start_time,
		"wall_seconds":float(Time.get_ticks_usec()-started)/1000000.0,"winner":world.winner,
		"actual_policy":policy,"budget_ms":Config.decision_budget_ms(policy),"restored_frame":restored_frame,
		"initial":initial,"final":_summary(),"sides":stats,"timeline":observations,
		"card_document_sha256":str(JSON.stringify(tape.cards)).sha256_text(),"godot":Engine.get_version_info().string,
		"effective_card_document_sha256":str(JSON.stringify(config.balance_document())).sha256_text(),
		"engine_source_sha256":engine_source_sha256,"engine_source_files":engine_source_files,
		"engine_source_hash_encoding":"SHA256 of sorted relative filename + LF + file bytes + NUL, captured at initialization",
		"limitations":["Single scenario/seed is behavior evidence, not win-rate evidence.",
			"First-use observations have at most 0.5 game-second sampling lag for natural completions; command deployments are observed immediately.",
			"Wages reinvested is a conservative cash-flow lower bound, not attribution of individual fungible coins.",
			"The inactive opponent keeps its existing production; it receives no new commands."]}
	_write({"type":"ending","result":result})
	return result

func _new_stats(seat: int) -> Dictionary:
	var idle := []
	for id in world.activity_card_ids(seat):
		if world.can_person_work(id) and not world.tasks.has(id) and not world.is_striking(id) and not world.is_meeting_target(id):
			idle.append({"id":id,"type":world.cards[id].type,"first_work":-1.0})
	return {"owner":seat,"initial_money":world.money(seat),"decisions":0,"decision_us":0,"apply_failures":0,"over_budget":0,
		"purchases":[],"initial_idle_staff":idle,"purchases_spent":0,"work_completed":0,"wages":0,"recruitment_batches":[],"recruitment_spent":0,
		"recruited":0,"coffee_produced":0,"slack_batches":0,"coffee_consumed":0,"upgrades":[],
		"max_workers":0,"max_work_rate":0.0,"max_income_rate":0.0,"max_coffee_rank":0}

func _selected_evaluation(report: Dictionary, owner: int) -> Dictionary:
	var detail := _as_dictionary(report.get("evaluation"))
	var sides := _as_array(detail.get("sides"))
	var result := {"layer":report.get("evaluation_layer",""),"terminal":detail.get("terminal",false),
		"forecast_root_offset_seconds":report.get("forecast_root_offset_seconds",null),"sides":[]}
	for seat in sides.size():
		var forecast := _as_dictionary(sides[seat])
		var chain := _as_dictionary(forecast.get("production_chain"))
		var cashout := _as_dictionary(forecast.get("cashout"))
		var growth := _as_dictionary(chain.get("growth"))
		result.sides.append({"owner":seat,"eta":forecast.get("eta"),"current_rate":forecast.get("current_rate"),
			"required_actions":forecast.get("required_actions"),
			"provenance":{"production_chain_kind":chain.get("kind",""),"growth_policy":growth.get("policy",""),
				"forecast_commands":_as_array(forecast.get("forecast_commands")).size(),"forecast_purchases":_as_dictionary(forecast.get("forecast_purchases")).size(),
				"public_investment_kind":_as_dictionary(forecast.get("public_investment")).get("kind",""),
				"forecast_attack_kind":_as_dictionary(forecast.get("forecast_attack")).get("kind","")},
			"cashout":{"future_supply":cashout.get("future_supply",false),"purchase_at":cashout.get("purchase_at"),
				"funding_at":cashout.get("funding_at"),"eta":cashout.get("eta"),"supply_wait":cashout.get("supply_wait")}})
		if seat!=owner: continue
		var selected: Dictionary=chain
		var purchased := _as_dictionary(detail.get("purchase_chain"))
		if selected.is_empty() and int(purchased.get("owner",-1))==owner: selected=purchased
		var commands := _as_array(selected.get("commands",forecast.get("forecast_commands",[])))
		var head := []
		for command in commands.slice(0,5):
			if not command is Dictionary: continue
			# Rule-cursor commands nest an action dictionary. Economic tail
			# commands instead use action:true to mark a paid command slot.
			var action: Dictionary=command.action if command.get("action") is Dictionary else command
			head.append({"at":command.get("at"),"kind":action.get("kind",""),
				"intent":action.get("intent",action.get("kind","")),"growth_intent":action.get("growth_intent","")})
		result["selected_plan"]={"kind":selected.get("kind","forecast_tail"),"growth":growth.duplicate(true),
			"commands_count":commands.size(),"first_commands":head}
	return result

func _as_dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}

func _as_array(value: Variant) -> Array:
	return value if value is Array else []

func _consume_events(events: Array) -> void:
	for event in events:
		var seat := int(event.get("owner",-1))
		if seat not in [0,1]: continue
		var item: Dictionary = stats[seat]
		match str(event.kind):
			"buy":
				item.purchases.append({"id":event.source,"type":event.card_type,"at":event.time,"first_use":-1.0,"first_work":-1.0})
				item.purchases_spent+=int(world.config.cards[event.card_type].price)
			"work_complete":
				item.work_completed+=event.ids.size()
				item.wages+=int(event.amount)
				for batch in item.recruitment_batches:
					for person in event.participants:
						if batch.ids.has(person): batch.work_participations+=1
			"recruitment_complete":
				item.recruitment_batches.append(event.duplicate(true).merged({"work_participations":0,"first_work":-1.0}))
				item.recruited+=int(event.count)
				item.recruitment_spent+=int(event.spent)
			"slack_complete":
				item.slack_batches+=1
				item.coffee_produced+=int(event.amount)
			"coffee_upgrade":
				item.coffee_consumed+=int(event.amount)
				item.upgrades.append(event.duplicate(true))
		if str(event.kind) in ["coffee_start","coffee_upgrade"]:
			for row in item.purchases:
				if float(row.first_use)<0.0 and event.get("coffee_ids",[]).has(int(row.id)): row.first_use=float(event.time)
	if not events.is_empty(): _write({"type":"events","time":world.time,"events":events})

func _active(id: int) -> bool:
	if not world.cards.has(id): return false
	var card: Dictionary = world.cards[id]
	if world.tasks.has(id): return true
	var group := int(card.group)
	if str(card.type)=="overtime": return not world.group_work_participants(group).is_empty()
	if str(card.type)=="slack": return str(world.groups[group].get("function",""))=="slack" and not world.group_people(group).is_empty()
	if str(card.type)=="boss": return world.recruitment.has(group)
	return str(card.get("status","")) in ["active","recovering"]

func _observe() -> void:
	for seat in 2:
		for row in stats[seat].purchases:
			if float(row.first_use)<0.0 and _active(int(row.id)): row.first_use=world.time
			if float(row.first_work)<0.0 and world.tasks.get(int(row.id),{}).get("kind","")=="work": row.first_work=world.time
		for row in stats[seat].initial_idle_staff:
			if float(row.first_work)<0.0 and world.tasks.get(int(row.id),{}).get("kind","")=="work": row.first_work=world.time
		for batch in stats[seat].recruitment_batches:
			if float(batch.first_work)>=0.0: continue
			for person in batch.ids:
				if world.tasks.get(int(person),{}).get("kind","")=="work":
					batch.first_work=world.time
					break
		var current := _side(seat)
		stats[seat].max_workers=maxi(int(stats[seat].max_workers),int(current.workers))
		stats[seat].max_work_rate=maxf(float(stats[seat].max_work_rate),float(current.work_rate))
		stats[seat].max_income_rate=maxf(float(stats[seat].max_income_rate),float(current.income_rate))
		for kind in current.people:
			stats[seat].max_coffee_rank=maxi(int(stats[seat].max_coffee_rank),world.config.coffee_rank(str(kind)))
	if observations.is_empty() or world.time-float(observations[-1].time)>=10.0 or world.winner>=0:
		observations.append({"time":world.time,"sides":_summary()})

func _summary() -> Array:
	return [_side(0),_side(1)]

func _side(seat: int) -> Dictionary:
	var counts := {}
	var workers := 0
	var work_rate := 0.0
	var income_rate := 0.0
	for id in world.activity_card_ids(seat):
		var kind: String = world.cards[id].type
		if world.config.is_person(kind): counts[kind]=int(counts.get(kind,0))+1
	for group in world.groups:
		if int(world.groups[group].owner)!=seat: continue
		var rate := world.group_work_rate(group)
		for person in world.group_work_participants(group):
			workers+=1
			var kind: String = world.effective_work_kind(str(world.cards[person].type),group)
			var capacity: int = world.config.work_batch_size(kind,world.group_work(group).size())
			work_rate+=rate*capacity
			income_rate+=rate*capacity*world.config.income_per_work(kind)
	return {"work":world.work_count(seat),"money":world.money(seat),"reserved":world.reserved_money(seat),
		"people":counts,"workers":workers,"work_rate":work_rate,"income_rate":income_rate,
		"coffee":world._owner_type(seat,"coffee").size()}

func _write(row: Dictionary) -> void:
	if trace==null: return
	trace.store_line(JSON.stringify(row,"",false,true))
	trace.flush()
