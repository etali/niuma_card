# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

## Reconstruct a recorded benchmark observation using only authoritative
## actions, without invoking a BOT or inspecting hypothetical search state.
const Actions = preload("res://engine/off_work_bot_actions.gd")
var issues: Array[String] = []
var replayed := 0

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var trace_path := "res://reports/off-work-growth-refactor-20261110/verified-opening-script-s1.0.json.jsonl"
	var output := "res://tests/off_work/fixtures/off_work_growth_market_choice_20261110.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--trace="): trace_path=arg.trim_prefix("--trace=")
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
	var lines := FileAccess.get_file_as_string(trace_path).split("\n",false)
	if lines.is_empty(): _fail("missing trace");return
	var opening: Dictionary=JSON.parse_string(lines[0])
	var request: Dictionary=opening.request
	var tape: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(str(request.replay)))
	var config := OffWorkConfig.new(tape.cards)
	config.rules.bot=opening.actual_policy.duplicate(true)
	var world := OffWorkState.new(config)
	var frame: Dictionary=tape.frames[0]
	if not is_zero_approx(float(frame.t)): _fail("expected original t0 frame");return
	var raw := Marshalls.base64_to_raw(frame.data).decompress(int(frame.size),FileAccess.COMPRESSION_ZSTD)
	var entry: Dictionary=bytes_to_var(raw)
	for key in OffWorkState.WORLD_FIELDS: world.set(key,entry.world[key])
	world._rng.state=entry.rng
	world._invalidate_group_index()
	world.drain_events()
	_compare(_summary(world),opening.state,"opening")
	for line in lines.slice(1):
		var row: Dictionary=JSON.parse_string(line)
		if row.get("type","")!="decision": continue
		var at := float(row.time)
		var owner := int(row.owner)
		if at>40.000001: _fail("target owner1 t40 decision missing");return
		while world.time<at-0.000001:
			world.advance(minf(0.5,at-world.time))
			world.drain_events()
		if owner==1 and is_equal_approx(at,40.0):
			_export(world,tape,opening,trace_path,output)
			return
		var action: Dictionary=row.action.duplicate(true)
		if action.has("ids"): action.ids=action.ids.map(func(id):return int(id))
		for key in ["group","person","tool","offer"]:
			if action.has(key): action[key]=int(action[key])
		if not row.get("applied",false) or not Actions.apply_action(world,owner,action):
			_fail("action not reproducibly legal at %.6f owner %d: %s"%[at,owner,str(action)]);return
		replayed+=1
		world.drain_events()
		_compare(_summary(world),row.state,"t%.6f owner%d"%[at,owner])
		if not issues.is_empty(): _fail("trace state mismatch");return
	_fail("target decision not found")

func _compare(actual: Array, expected: Array, label: String) -> void:
	for owner in 2:
		for key in ["work","money","reserved","workers","coffee"]:
			if int(actual[owner][key])!=int(expected[owner][key]):
				issues.append("%s side%d %s: %s != %s"%[label,owner,key,actual[owner][key],expected[owner][key]])
		for key in ["work_rate","income_rate"]:
			if absf(float(actual[owner][key])-float(expected[owner][key]))>0.0000001:
				issues.append("%s side%d %s differs"%[label,owner,key])
		if actual[owner].people.size()!=expected[owner].people.size(): issues.append(label+" role count differs")
		for kind in actual[owner].people:
			if int(actual[owner].people[kind])!=int(expected[owner].people.get(kind,-1)):
				issues.append("%s side%d role%s differs"%[label,owner,kind])

func _export(world: OffWorkState, tape: Dictionary, opening: Dictionary, trace_path: String, output: String) -> void:
	var actual := _summary(world)
	var quotes := []
	for offer in world.offers:
		if not offer.is_empty() and offer.type=="employee" and world.can_acquire("employee",1) and int(offer.price)<=world.available_money(1):
			quotes.append(int(offer.id))
	if world.money(1)!=4 or world.available_money(1)!=4 or int(actual[1].workers)!=1 or not quotes.has(21) or not quotes.has(25):
		_fail("target invariant failed: "+JSON.stringify({"state":actual,"quotes":quotes}));return
	if not issues.is_empty(): _fail("earlier state mismatch");return
	var fields := {}
	for key in OffWorkState.WORLD_FIELDS: fields[key]=world.get(key)
	var bytes := var_to_bytes({"world":fields,"rng":world._rng.state})
	var result := {"source_replay":str(opening.request.replay),"source_trace":ProjectSettings.globalize_path(trace_path),
		"source_trace_sha256":FileAccess.get_sha256(trace_path),"source_engine_sha256":opening.get("engine_source_sha256"),
		"replayed_decisions":replayed,"every_decision_legal":true,"every_recorded_summary_matched":true,
		"cards":tape.cards,"policy":opening.actual_policy,"owner":1,"time":world.time,
		"expected":{"money":4,"available_money":4,"workers":1,"employee_quotes":[21,25]},"summary":actual,
		"snapshot":{"encoding":"godot-variant-zstd-base64","size":bytes.size(),
			"data":Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_ZSTD))}}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: _fail("cannot write fixture");return
	file.store_string(JSON.stringify(result,"\t",false,true))
	file.close()
	print("GROWTH_MARKET_FIXTURE PASS replayed=",replayed," output=",output)
	quit(0)

func _summary(world: OffWorkState) -> Array:
	var sides := []
	for owner in 2:
		var people := {}
		var workers := 0
		var work_rate := 0.0
		var income_rate := 0.0
		for id in world.activity_card_ids(owner):
			var kind: String=world.cards[id].type
			if world.config.is_person(kind): people[kind]=int(people.get(kind,0))+1
		for gid in world.groups:
			if int(world.groups[gid].owner)!=owner: continue
			var rate := world.group_work_rate(gid)
			for person in world.group_work_participants(gid):
				workers+=1
				var role: String=world.effective_work_kind(str(world.cards[person].type),gid)
				var capacity: int=world.config.work_batch_size(role,world.group_work(gid).size())
				work_rate+=rate*capacity
				income_rate+=rate*capacity*world.config.income_per_work(role)
		sides.append({"work":world.work_count(owner),"money":world.money(owner),"reserved":world.reserved_money(owner),
			"people":people,"workers":workers,"work_rate":work_rate,"income_rate":income_rate,"coffee":world._owner_type(owner,"coffee").size()})
	return sides

func _fail(reason: String) -> void:
	for issue in issues: printerr(issue)
	printerr("GROWTH_MARKET_FIXTURE FAIL: ",reason)
	quit(1)
