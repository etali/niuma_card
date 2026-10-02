# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIAgent
extends RefCounted

## 场景与无头共用的行动驱动：搜索只读副本，真实落地逐条经过 IntentApply。
## 每个实现返回 {intents, diagnostics}，驱动不识别任何特定模型。
const STEP_PAWN := "pawn"
const STEP_BUY := "buy"
const STEP_BUY_DONE := "buy_done"
const STEP_COMBO := "combo"
const STEP_THINK := "think"
const STEP_DONE := ""

var think: Callable = Callable()
## 由会话宿主提供；只在驱动线程查询，不让旧计划跨越重开/退出继续落地。
var cancelled: Callable = Callable()
var _t: Transport
var _seat: String
var _cfg: AISearch
var _plan: Dictionary = {}
var _asked_think := false
var _ready := false
var _intents: Array = []
var _buy_done := false
var _replans := 0
const MAX_REPLANS := 3

func _init(transport: Transport, seat: String, cfg: AISearch = null) -> void:
	_t = transport
	_seat = seat
	_cfg = cfg if cfg != null else AISearch.default_config()
	if _t.applier() == null:
		push_error("AIAgent 需要本地裁决器")

func state() -> GameState:
	return _t.state()

func applier() -> IntentApply:
	return _t.applier()

func is_cancelled() -> bool:
	return cancelled.is_valid() and bool(cancelled.call())

func run_action_phase_sync() -> void:
	while true:
		var step := next_step()
		if step == STEP_DONE:
			return
		if step == STEP_THINK:
			_plan = plan_job().call()
			if is_cancelled():
				return

func run_action_phase(beat: Callable = Callable()) -> void:
	while true:
		var step := next_step()
		if step == STEP_DONE:
			return
		if step == STEP_THINK:
			var job := plan_job()
			if think.is_valid():
				_plan = await think.call(job)
			else:
				_plan = job.call()
			if is_cancelled():
				return
		if beat.is_valid():
			var result = beat.call(step)
			if result is Signal:
				await result
			if is_cancelled():
				return

func plan_job() -> Callable:
	# 在调用线程冻结输入，工作线程不会与认输/换局共同读写同一牌局。
	var st := AIEnvironment.copy(state())
	var seat := _seat
	var cfg := AISearch.new()
	cfg.model = _cfg.model
	cfg.strength = _cfg.strength
	cfg.parameters = _cfg.resolved_parameters()
	return func() -> Variant: return AIPlan.choose_plan(st, seat, cfg)

func next_step() -> String:
	if is_cancelled() or state().winner != "" or _replans >= MAX_REPLANS:
		return STEP_DONE
	if not _ready:
		if _plan.is_empty():
			if not _asked_think:
				_asked_think = true
				return STEP_THINK
			_plan = plan_job().call() # 同步手动步进者也能推进。
			if is_cancelled():
				return STEP_DONE
		_intents = _plan.get("intents", []).duplicate(true)
		_plan = {}
		_ready = true
		_asked_think = false
	if _intents.is_empty():
		return STEP_DONE
	var intent: Dictionary = _intents[0]
	if intent["op"] == Intent.OP_COMBO and not _buy_done:
		_buy_done = true
		return STEP_BUY_DONE
	_intents.pop_front()
	var result := applier().apply(intent)
	if not bool(result.get("ok", false)):
		_ready = false
		_intents.clear()
		_replans += 1
		return STEP_THINK
	match intent["op"]:
		Intent.OP_PAWN: return STEP_PAWN
		Intent.OP_BUY: return STEP_BUY
		Intent.OP_COMBO: return STEP_COMBO
	return STEP_DONE
