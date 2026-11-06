# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name WorkBot
extends RefCounted

const Config = preload("res://engine/work_config.gd")
const Planner = preload("res://engine/work_bot_planner.gd")
const Reply = preload("res://engine/work_bot_reply.gd")
const TreeSearch = preload("res://engine/work_bot_tree.gd")

var state: RefCounted
var owner: int
var decision_serial := 0
var last_decision: Dictionary = {}
var _planner := Planner.new()
var _next_think: float = INF
var _started := false
var _rng := RandomNumberGenerator.new()
var _policy: Dictionary

func _init(game_state: RefCounted, player: int = 1, policy: Dictionary = {}, match_seed: int = 0) -> void:
	state = game_state
	owner = player
	_policy = state.config.rules.bot if policy.is_empty() else policy
	var base_seed: int = state.config.integer("simulation", "default_seed") if match_seed == 0 else match_seed
	_rng.seed = base_seed + owner

func start() -> void:
	if _started: return
	_started = true
	_next_think = float(state.time) + float(_policy.first_action_seconds)

func is_started() -> bool:
	return _started

func next_action_time() -> float:
	return _next_think if _policy.enabled else INF

## Game seconds determine WHEN to act. Only monotonic wall time limits the
## decision itself. A caller with a tighter absolute deadline can pass it here.
func advance(_delta: float, deadline_usec: int = -1) -> void:
	if not _started or not bool(_policy.enabled) or state.winner >= 0 or state.time < _next_think:
		return
	_next_think = float(state.time) + float(_policy.think_seconds)
	var action := decide_action(deadline_usec)
	if commit_action(action, last_decision): return
	last_decision["applied"] = false
	decision_serial += 1

func commit_action(action: Dictionary, report: Dictionary) -> bool:
	if state.winner >= 0 or not bool(_policy.enabled): return false
	for id in action.get("ids", []):
		if not state.cards.has(id) or state.cards[id].owner != owner: return false
	if action.has("tool") and (not state.cards.has(action.tool) or state.cards[action.tool].owner != owner):
		return false
	if action.get("group", -1) >= 0 and not state.groups.has(action.group): return false
	if not _planner.apply_action(state, owner, action): return false
	last_decision = report
	last_decision["applied"] = true
	decision_serial += 1
	return true

## Planning is read-only. The chosen command is delivered before the game
## executes it, so rule settlement and animations do not consume search time.
func decide_action(deadline_usec: int = -1, cancelled: Callable = Callable(), search_tree := true,
		on_choice: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var budget_ms := Config.decision_budget_ms(_policy)
	var cutoff := started + budget_ms * 1000
	if deadline_usec >= 0: cutoff = mini(cutoff, deadline_usec)
	var available := maxi(0, cutoff - started)
	var reserve := mini(1000, ceili(available * 0.20))
	var until := cutoff - reserve
	var incumbent := {"action":{"kind":"wait"}, "report":{"kind":"wait", "reason":"决策时限已到，保持当前安排",
		"budget_ms":budget_ms, "selected_after_us":0, "elapsed_us":0, "overrun":false,
		"fallback":true, "cutoff":true, "discarded_late":false, "candidates":[], "evaluated":0,
		"depth":0, "search_depth":0, "search_nodes":0, "principal_variation":[]}}
	if Time.get_ticks_usec() < until and not (cancelled.is_valid() and cancelled.call()):
		var ranked := _planner.choose(state, owner, _policy, _rng, until, cancelled)
		var summary: Dictionary = ranked.diagnostics
		summary["depth"] = 0 if summary.fallback else 1
		summary["cutoff"] = summary.timed_out
		if _publish(incumbent, ranked.action, summary, started, cutoff, on_choice) and not summary.cutoff and ranked.finalists.size() > 1:
			var response := Reply.refine(state, owner, _policy, _planner.forecast_context(), ranked.finalists, until)
			if not response.is_empty():
				_publish(incumbent, response.action, {"reason":response.reason, "candidates":response.candidates,
					"depth":1 + int(response.depth)}, started, cutoff, on_choice)
			if search_tree and Time.get_ticks_usec() < until:
				var publish_layer := func(layer: Dictionary) -> void:
					_publish(incumbent, layer.action, {"reason":layer.reason, "candidates":layer.candidates,
						"principal_variation":layer.principal_variation, "search_depth":layer.search_depth,
						"search_nodes":layer.search_nodes}, started, until, on_choice)
				var searched := TreeSearch.new().search(state, owner, _policy, ranked.finalists, until, cancelled, publish_layer)
				incumbent.report.search_nodes = searched.search_nodes
				incumbent.report.cutoff = searched.cutoff
			elif Time.get_ticks_usec() >= until:
				incumbent.report.cutoff = true
	var report: Dictionary = incumbent.report
	report.elapsed_us = Time.get_ticks_usec() - started
	report.overrun = int(report.elapsed_us) > available
	last_decision = report
	return incumbent.action

## A mailbox consumer may use this completed choice even when a subsequent
## layer is still running. No callback receives a mutable search node or live state.
func _publish(incumbent: Dictionary, action: Dictionary, evidence: Dictionary, started: int, until: int,
		on_choice: Callable) -> bool:
	var ready := Time.get_ticks_usec()
	if ready >= until:
		incumbent.report.discarded_late = true
		incumbent.report.cutoff = true
		return false
	var report: Dictionary = incumbent.report.merged(evidence, true)
	report.kind = action.kind
	report.selected_after_us = ready - started
	report.elapsed_us = report.selected_after_us
	incumbent.action = action
	incumbent.report = report
	if on_choice.is_valid(): on_choice.call(action, report.duplicate())
	return true
