# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

## Read-only trace inspection. Run with --path pointing at the run's frozen
## runtime so the metrics use exactly the rules under which it was played.
const Config = preload("res://engine/off_work_config.gd")

func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var result := _inspect(path)
		var file := FileAccess.open(path + ".analysis.json", FileAccess.WRITE)
		if file == null or result.has("error"):
			printerr(result.get("error", "cannot save inspection"))
			quit(1)
			return
		file.store_string(JSON.stringify(result, "", false, true))
		file.close()
		print(path + ".analysis.json")
	quit()

func _inspect(path: String) -> Dictionary:
	var result := {"trace":path, "trace_sha256":FileAccess.get_sha256(path), "decisions":[]}
	var world: OffWorkState
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var entry: Dictionary = JSON.parse_string(line)
		if entry.type == "opening":
			world = OffWorkState.new(Config.new(entry.rules))
			result.seed = entry.seed
			result.a_seat = entry.a_seat
			result.scenario = entry.scenario
		if not entry.has("snapshot"): continue
		var bytes := Marshalls.base64_to_raw(entry.snapshot.data).decompress(int(entry.snapshot.size), FileAccess.COMPRESSION_ZSTD)
		var checksum := HashingContext.new()
		checksum.start(HashingContext.HASH_SHA256)
		checksum.update(bytes)
		if checksum.finish().hex_encode() != entry.snapshot.sha256: return {"error":"snapshot checksum mismatch: " + path}
		var restored: Dictionary = bytes_to_var(bytes)
		for key in restored.world: world.set(key, restored.world[key])
		world._rng.state = restored.rng
		if entry.type == "ending":
			result.ending = entry.result
			result.final_stats = [_stats(world, result.a_seat), _stats(world, 1 - result.a_seat)]
		if entry.type != "decision": continue
		var action: Dictionary = entry.action.duplicate(true)
		var card_types := {}
		for id in action.get("ids", []):
			var kind: String = world.cards[int(id)].type if world.cards.has(int(id)) else "absent"
			card_types[kind] = int(card_types.get(kind, 0)) + 1
		action.id_count = action.get("ids", []).size()
		action.id_types = card_types
		action.erase("ids")
		result.decisions.append({"t":entry.t, "side":entry.side, "seat":entry.seat, "action":action,
			"a":_stats(world, result.a_seat), "b":_stats(world, 1 - result.a_seat), "offers":world.offers.duplicate(true),
			"diagnostics":entry.diagnostics, "events":entry.events})
	return result

func _stats(world: OffWorkState, owner: int) -> Dictionary:
	var active := 0
	var installed := 0
	var rate := 0.0
	var groups := []
	var types := {}
	var batches := []
	for card in world.cards.values():
		if int(card.owner) == owner: types[card.type] = int(types.get(card.type, 0)) + 1
	for gid in world.groups:
		if world.groups[gid].owner != owner: continue
		var workers := world.group_work_participants(gid).size()
		var overtime := 0
		for id in world.group_tools(gid):
			if world.cards[id].type == "overtime": overtime += 1
		var per_second := world.group_work_rate(gid) * workers
		active += workers
		if workers > 0: installed += overtime
		rate += per_second
		if workers > 0 or overtime > 0:
			groups.append({"id":gid, "work":world.group_work(gid).size(), "active_people":workers,
				"overtime":overtime, "rate":per_second, "progress":world.group_work_progress(gid)})
	for batch in world.outsourcing.values():
		if int(batch.owner) == owner: batches.append({"work":batch.work_ids.size(), "remaining":batch.remaining})
	return {"people":world.people_count(owner), "active_people":active,
		"overtime":types.get("overtime", 0), "installed_overtime":installed,
		"rate":rate, "money":world.money(owner), "free_cash":world.available_money(owner),
		"work":world.work_count(owner), "card_types":types, "groups":groups, "outsourcing":batches}
