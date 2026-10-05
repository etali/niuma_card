# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

signal resume_think
signal resume_beat

var _entered := false
var _done := false
var _pending_plan := {}

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_frozen_job()
	await _test_cancel_thinking()
	await _test_cancel_between_actions()
	finish()

func _transport() -> LocalTransport:
	var s := GameState.new()
	s.set_seed(7919)
	s.new_game()
	s.market = []
	return LocalTransport.new(IntentApply.new(s))

func _pawn_plan(s: GameState) -> Dictionary:
	var users: Array = []
	for c in s.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_USER):
			users.append(c["uid"])
	return {"intents": [Intent.pawn(GameState.PLAYER, [users[0]]), Intent.pawn(GameState.PLAYER, [users[1]])]}

func _test_frozen_job() -> void:
	var t := _transport()
	var cfg := BOTSearch.from_model("bot", 0.0)
	var agent := BOTAgent.new(t, GameState.PLAYER, cfg)
	var original := BOTEnvironment.copy(t.state())
	var expected := BOTPlan.choose_plan(original, GameState.PLAYER, cfg)
	var job := agent.plan_job()
	# 创建任务后改变宿主局面和参数，后台任务仍应读取创建时的快照。
	t.state().winner = GameState.BOT
	cfg.model = "unregistered_after_capture"
	var result: Dictionary = job.call()
	check(result["intents"] == expected["intents"], "计划任务使用创建时的局面和参数快照")
	check(t.state().winner == GameState.BOT, "计划计算不覆盖宿主之后的修改")
	check(t.seq == 0, "单独计算计划不会落地意图")

func _think(_job: Callable) -> Dictionary:
	_entered = true
	await resume_think
	return _pending_plan

func _beat(_step: String) -> Signal:
	_entered = true
	return resume_beat

func _drive(agent: BOTAgent, beat := Callable()) -> void:
	await agent.run_action_phase(beat)
	_done = true

func _wait_entered() -> void:
	for _i in 30:
		if _entered:
			return
		await process_frame

func _test_cancel_thinking() -> void:
	var t := _transport()
	var agent := BOTAgent.new(t, GameState.PLAYER)
	var flag := [false]
	agent.cancelled = func() -> bool: return flag[0]
	agent.think = _think
	_pending_plan = _pawn_plan(t.state())
	var before := StateCodec.state_hash(t.state())
	_entered = false
	_done = false
	_drive.call_deferred(agent)
	await _wait_entered()
	check(_entered and not _done, "行动驱动正等待思考返回")
	flag[0] = true
	resume_think.emit()
	check(_done, "思考返回时结束已取消的行动")
	check(t.seq == 0 and StateCodec.state_hash(t.state()) == before, "已取消的思考结果不落地任何意图")
	check(agent.next_step() == BOTAgent.STEP_DONE, "同步步进也遵守取消信号")

func _test_cancel_between_actions() -> void:
	var t := _transport()
	var agent := BOTAgent.new(t, GameState.PLAYER)
	var flag := [false]
	agent.cancelled = func() -> bool: return flag[0]
	agent._plan = _pawn_plan(t.state())
	_entered = false
	_done = false
	_drive.call_deferred(agent, _beat)
	await _wait_entered()
	check(_entered and t.seq == 1 and not _done, "首条意图落地后正等待演出")
	var after_first := StateCodec.state_hash(t.state())
	flag[0] = true
	resume_beat.emit()
	check(_done, "演出返回时结束已取消的行动")
	check(t.seq == 1 and StateCodec.state_hash(t.state()) == after_first, "取消后不会继续落地计划中的第二条意图")
