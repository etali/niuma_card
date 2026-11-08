# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Session = preload("res://engine/off_work_session.gd")
const Replay = preload("res://engine/off_work_replay.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1,"work":100}]
	config.rules.initial.money = 0
	var room := OffWorkRoom.new("UNION",71,config)
	room.world.new_game(71)
	var state: OffWorkState = room.world
	var target: int = state.cards[state._owner_type(0,"employee")[0]].group
	var shield := state.add_card("union",0)
	var attack := state.add_card("strike",1)
	check(state.activate(attack,target),"attack starts before snapshot")
	var half: float = config.rules.strike.flight_seconds / 2.0
	state.advance(half)
	var boss := state.add_card("boss",1)
	var cash := state._credit(1,21)
	state.move_cards(cash,state.cards[boss].group)
	check(state.recruitment.has(boss),"recruitment starts before snapshot")
	var bytes := Marshalls.base64_to_raw(room._frame(state.drain_events()))
	var frame: Dictionary = bytes_to_var(bytes.decompress_dynamic(16*1024*1024,FileAccess.COMPRESSION_DEFLATE))
	var transport := OffWorkTransport.new()
	check(transport._valid_frame(frame),"network accepts flight and recruitment snapshot")
	transport._mirror(frame)
	check(frame.world.pending_strikes[attack].owner == 0 and frame.world.recruitment[boss].owner == 0,"opposite-seat view mirrors both running jobs")
	check(frame.world.cards[shield].owner == 1 and frame.world.groups[target].owner == 1,"defender and protected group retain shared IDs on opposite side")
	var restored := OffWorkState.new(config)
	for key in Session.STATE_FIELDS: restored.set(key,frame.world[key])
	restored.move_cards([shield],target)
	restored.advance(half)
	check(restored.cards.has(attack) and restored.pending_strikes.is_empty(),"snapshot continuation blocks and returns the original strike card")
	check(restored.group_people(target).size() == 1 and not restored.is_striking(restored.group_people(target)[0]),"snapshot defender remains at work")
	var before := restored._owner_type(0,"employee").size()
	restored.advance(config.rules.recruitment.seconds)
	check(restored._owner_type(0,"employee").size() == before+4,"recruitment snapshot creates exactly four employees after continuing")
	check(restored.available_money(0) >= 1,"recruitment retains remainder after continuation")

	var world := {}
	for key in Session.STATE_FIELDS: world[key] = restored.get(key)
	world.erase("pending_strikes")
	world.erase("recruitment")
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key] = {}
	var raw := var_to_bytes({"world":world,"layout":layout,"events":[],"rng":restored._rng.state})
	var legacy := {"data":Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD)),"size":raw.size()}
	var decoded := Replay.decode_frame(legacy,OffWorkState.new(config))
	check(not decoded.is_empty() and decoded.world.pending_strikes.is_empty() and decoded.world.recruitment.is_empty(),"legacy replay gains empty jobs without changing recorded cards")
	check(decoded.world.cards == world.cards,"legacy replay migration preserves every card")
	for failure in failures: printerr("FAIL ",failure)
	print("OFF_WORK_ATTACK_SNAPSHOTS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)
