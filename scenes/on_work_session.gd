# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

const Slots = preload("res://engine/shift_slot.gd")
const View = preload("res://scenes/on_work_table_snapshot.gd")

static func eligible(game: Node) -> bool:
	return bool(game.get_meta("shift_session_enabled", false)) and game.replay_session == null \
		and not game._tutorial_active and game._net == null and game._host == null \
		and not OnWorkCardConfig.has_launch_override() and not OS.has_environment("CARD_SHOT")

## A bot's search coroutine or a partially presented settlement cannot resume at an
## arbitrary instruction. Those transitions retain the last whole decision point.
static func save_session(game: Node, phase_entry := false) -> bool:
	if not eligible(game) or game.state == null or game.pipe == null or not is_instance_valid(game.board): return true
	var actor: String = game._actor
	if game.state.winner == "":
		if game.phase == game.PHASE_ACTION:
			if not phase_entry and (actor != game.my_seat or game.board.input_locked or not game.board._drag_cards.is_empty()):
				return true
		elif game.phase == game.PHASE_ATTACK:
			actor = game._attack_actor
			if not phase_entry and (actor != game.my_seat or not game.board.attack_mode or game._player_attack_busy > 0):
				return true
		else: return true
	# Children may already have left the tree during a programmatic quit. Their
	# last recorded positions remain usable alongside the final rule state.
	var view: Dictionary = game.tape._last_view
	if game.board.is_inside_tree():
		game._flush_record_view()
		view = View.capture(game)
	return Slots.save(Slots.ON_WORK, {"state": OnWorkStateCodec.snapshot(game.state), "view": view,
		"pools": game.pipe.applier().pools_snapshot(), "phase": game.phase, "actor": actor,
		"turn_opening": game._opening_action_pending, "foe_completed": game._foe_completed_round,
		"seat": game.my_seat, "table": game.tape.table, "tape": game.tape.to_dict()})

static func restore(game: Node) -> bool:
	if not eligible(game): return false
	var saved := Slots.load_slot(Slots.ON_WORK)
	if saved.is_empty() or saved.get("table") != OnWorkStateCodec.table_hash(): return false
	if not OnWorkStateCodec.snapshot_issue(saved.get("state")).is_empty() or not OnWorkStateCodec.pools_issue(saved.get("pools")).is_empty(): return false
	if not View.valid(saved.get("view")) or not saved.get("tape") is Dictionary: return false
	if saved.get("seat") not in [OnWorkState.PLAYER, OnWorkState.BOT] or saved.get("actor") not in [OnWorkState.PLAYER, OnWorkState.BOT]: return false
	var recording := OnWorkTape.from_dict(saved.tape)
	if not recording.ok: return false
	game.set_seats(saved.seat, OnWorkState.opponent(saved.seat))
	OnWorkStateCodec.restore(game.state, saved.state)
	game._rebuild_pipe()
	game.pipe.applier().pools_restore(saved.pools)
	# _rebuild_pipe bound the live recorder to the new applier. Keep its wiring and
	# restore the prefix so F5 still exports the entire game, including earlier runs.
	for key in ["table", "meta", "head", "head_pools", "configuration", "head_view", "steps", "hash_encoding"]:
		game.tape.set(key, recording.tape.get(key))
	game._opening_action_pending = saved.turn_opening
	game._foe_completed_round = saved.foe_completed
	game._respawn_all()
	View.restore(game, saved.view)
	if game.state.winner != "":
		game._show_game_over()
	elif saved.phase == game.PHASE_ATTACK:
		game._clear_market()
		game._run_attacks(saved.actor)
	else:
		game._begin_action_phase(saved.actor)
	return true
