# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	CardDB.ensure_loaded()
	var attacks := 0
	for seed_value in [207,1001,27]:
		var cfgs := BOTSearch.duel_seats(BOTSearch.from_strength(0),BOTSearch.from_strength(0),false)
		var plain := MatchSimulator.run_rounds(10,seed_value,Callable(),Callable(),Callable(),cfgs)
		var tape := Tape.new()
		var checkpoints := [0]
		var recorded := MatchSimulator.run_rounds(10,seed_value,Callable(),Callable(),Callable(),cfgs,"",{
			"tape":tape,"decision":tape.record_bot_decision,
			"checkpoint":func(_s: GameState) -> void: checkpoints[0] += 1})
		check(StateCodec.state_hash(plain) == StateCodec.state_hash(recorded),"录制不改变同种子对局的最终状态")
		check(checkpoints[0] > 1 and not tape.meta.get("bot_decisions",[]).is_empty(),"每回合保存检查点且录像携带BOT决策")
		var loaded := Tape.from_dict(JSON.parse_string(JSON.stringify(tape.to_dict())))
		if need(loaded.ok,"录像经过JSON存取仍能加载"):
			var replay := Tape.replay(loaded.tape)
			check(replay.ok,"所有操作、攻击、结算和回合推进可逐步重放")
			if replay.ok: check(StateCodec.state_hash(replay.state) == StateCodec.state_hash(recorded),"重放终态与真实模拟一致")
		for step in tape.steps:
			if step.intent.op == Intent.OP_ATTACK: attacks += 1
		tape.stop()
	attacks += _attack_recording()
	check(attacks > 0,"回放验证包含实际攻击步骤")
	finish()

func _attack_recording() -> int:
	var state := GameState.new()
	state.set_seed(29)
	state.new_game()
	for who in [GameState.PLAYER,GameState.BOT]:
		for index in 30: state.add_card(who,CardDB.unit_id(CardDB.RES_CASH))
		for kind in [CardDB.KIND_ATTACK,CardDB.KIND_PRODUCT]:
			for card_id in CardDB.all_cards():
				var spec: Dictionary = CardDB.get_def(card_id)
				if spec.get("kind") != kind or spec.get("recipe_res") != CardDB.RES_CASH: continue
				var uids: Array = [state.add_card(who,card_id)["uid"]]
				for index in int(spec["recipe_n"]): uids.append(state.add_card(who,CardDB.unit_id(CardDB.RES_CASH))["uid"])
				check(state.create_combo(who,uids).ok,"构建真实攻击和生产组合")
				break
	var plain := BOTEnvironment.copy(state)
	var tape := Tape.new()
	var applier := IntentApply.new(state)
	tape.start(applier)
	Settle.run(plain)
	Settle.run(state,{},Callable(),applier)
	check(StateCodec.state_hash(plain) == StateCodec.state_hash(state),"带真实攻击的录制结算与原模拟一致")
	var replay := Tape.replay(tape)
	check(replay.ok and StateCodec.state_hash(replay.state) == StateCodec.state_hash(state),"真实攻击及产出结算的录像可逐步重放")
	var attacks := 0
	for step in tape.steps:
		if step.intent.op == Intent.OP_ATTACK: attacks += 1
	tape.stop()
	return attacks
