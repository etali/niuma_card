# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Session = preload("res://engine/off_work_session.gd")
const Slots = preload("res://engine/shift_slot.gd")
const Replay = preload("res://engine/off_work_replay.gd")

class RestoredTable extends Node:
	var state: OffWorkState
	var bot: OffWorkBot
	var replay := Replay.new()

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _saved(state: OffWorkState) -> Dictionary:
	var world := {}
	for key in Session.STATE_FIELDS: world[key] = state.get(key)
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key] = {}
	return {"world": world, "layout": layout, "balance": state.config.balance_document(),
		"bot": {"bot": state.config.rules.bot, "preferences": state.config.bot_preferences},
		"rng": state._rng.state, "bot_rng": 43, "bot_started": false, "bot_next": 0.0,
		"paused": true, "replay_frames": []}

func _run() -> void:
	var sandbox := OS.get_cache_dir().path_join("niuma-tests/coffee-session-%d" % OS.get_process_id())
	OS.set_environment("CARD_DATA_DIR", sandbox)
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "work": 10}]
	var original := OffWorkState.new(config)
	original.new_game(43)
	original.advance(3.5)
	var person: int = original._owner_type(0, "employee")[0]
	var workplace: int = original.cards[person].group
	var resume: Dictionary = original.tasks[person].duplicate(true)
	var cup := original.add_card("coffee", 0, workplace)
	# Reproduce the serialized task format of the former mixed-stack rules.
	original.tasks[person] = {"kind": "coffee", "group": workplace, "tool_id": cup,
		"coffee_ids": [cup], "from_type": "employee", "to_type": "grinder",
		"total": 5.0, "work_id": resume.work_id, "progress": 0.4, "resume_task": resume}
	original.cards[cup].status = "active"
	original.cards[cup].progress = 0.4
	original.cards[cup].remaining = 3.0
	original.cards[cup].total = 5.0
	check(Slots.save(Slots.OFF_WORK, _saved(original)), "write a legacy mixed-stack checkpoint")
	var stored := FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK))
	var table := RestoredTable.new()
	var saved := Session.read_session(table)
	check(not saved.is_empty() and saved.paused, "a paused legacy match remains loadable and paused")
	check(table.state.tasks[person].kind == "work", "restore reconciles mixed coffee before a paused table receives any frame")
	check(table.state.cards[person].type == "employee" and table.state.cards[cup].status == "ready",
		"interrupted promotion returns the existing coffee and retains the employee UID")
	check(table.state.cards[cup].progress == 0.0 and table.state.cards[cup].remaining == 0.0,
		"restored cup has no stale coffee timer")
	check(is_equal_approx(table.state.group_work_progress(workplace), 0.35) and table.state.work_count(0) == 10,
		"work resumes at the original progress without consuming or granting work")
	check(table.state.time == original.time and table.state._rng.state == original._rng.state,
		"loading consumes neither simulated time nor random outcomes")
	check(table.state.drain_events().is_empty(), "migration does not replay effects or rewards")
	check(FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK)) == stored,
		"reading a legacy checkpoint preserves the saved file")
	var workers: Array = [person, cup]
	table.state.move_cards(workers, -1, person)
	table.state.advance(1.0)
	var proper: Dictionary = table.state.tasks[person].duplicate(true)
	check(Slots.save(Slots.OFF_WORK, _saved(table.state)), "save a valid separated promotion")
	var next := RestoredTable.new()
	Session.read_session(next)
	check(next.state.tasks[person] == proper and is_equal_approx(next.state.cards[cup].progress, 0.2),
		"valid independent coffee combinations keep their exact active timer")
	table.free()
	next.free()
	for failure in failures: printerr("FAIL ", failure)
	print("COFFEE_SESSION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
