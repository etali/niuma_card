# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkBot
extends RefCounted

const Config = preload("res://engine/off_work_config.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Search = preload("res://engine/off_work_bot_search.gd")
const Emergency = preload("res://engine/off_work_bot_emergency.gd")
const GrowthCommitment = preload("res://engine/off_work_bot_growth_commitment.gd")
const ExecutionPlan = preload("res://engine/off_work_bot_execution_plan.gd")

var state: RefCounted
var owner: int
var decision_serial := 0
var last_decision: Dictionary = {}
var _decision_context := {}
var _next_think: float = INF
var _started := false
var _rng := RandomNumberGenerator.new()
var _policy: Dictionary

func _init(game_state: RefCounted, player: int = 1, policy: Dictionary = {}, match_seed: int = 0) -> void:
	state = game_state
	owner = player
	# Timing/search overrides use the installed model. Obsolete purchasing
	# gates cannot silently restrict the new legal action space.
	_policy = state.config.rules.bot if policy.is_empty() else Config.merge_bot_policy(state.config.rules.bot, policy)
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
	var follows_execution: bool = bool(report.get("execution_continuation",false)) or bool(action.get("execution_continuation",false))
	var prepared: Dictionary = ExecutionPlan.prepare(state,owner,action,report,_policy)
	if not Actions.apply_action(state, owner, action): return false
	if follows_execution:
		var remaining: Dictionary = ExecutionPlan.consumed(_decision_context.get("execution_plan",{}),action)
		if remaining.is_empty(): _decision_context.erase("execution_plan")
		else: _decision_context.execution_plan=remaining
	# A freshly scored complete suffix replaces the old suffix even when its
	# first command happens to match the previously saved step.
	if not prepared.is_empty():
		_decision_context["execution_plan"]=ExecutionPlan.adopt(_decision_context.get("execution_plan",{}),prepared)
		_decision_context.erase("growth_return")
	if report.get("growth_continuation",false): _decision_context.erase("growth_return")
	# All newly selected investments use the same execution plan. The old
	# growth_return reader below only drains contexts imported from older live
	# workers; it is no longer a second producer of production obligations.
	last_decision = report
	last_decision["applied"] = true
	last_decision["action"] = action.duplicate(true)
	decision_serial += 1
	return true

## Only bounded dispatch context crosses live-worker/session boundaries. Search
## trees and hypothetical market states never become persistent game state.
func export_decision_context() -> Dictionary:
	return _decision_context.duplicate(true)

func import_decision_context(context: Dictionary) -> void:
	_decision_context = context.duplicate(true)

## Every full decision uses the same race-search pipeline. The bounded
## emergency action exists only so a late UI worker cannot stall the game.
func decide_action(deadline_usec: int = -1, cancelled: Callable = Callable(), search_tree := true,
		on_choice: Callable = Callable(), root_action_filter: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var budget_ms := Config.decision_budget_ms(_policy)
	var cutoff := started + budget_ms * 1000
	if deadline_usec >= 0: cutoff = mini(cutoff, deadline_usec)
	var available := maxi(0, cutoff - started)
	var reserve := mini(int(_policy.decision_publish_reserve_us), ceili(available * float(_policy.decision_publish_reserve_ratio)))
	var until := cutoff - reserve
	var incumbent := {"action":{"kind":"wait"}, "report":{"algorithm":"completion_search_v3", "kind":"wait",
		"reason":"等待有效决策", "budget_ms":budget_ms, "selected_after_us":0, "elapsed_us":0,
		"overrun":false, "fallback":true, "cutoff":true, "discarded_late":false,
		"candidates":[], "evaluated":0, "depth":0, "search_depth":0, "search_nodes":0,
		"principal_variation":[], "root_complete":false}}
	if Time.get_ticks_usec() < until and not (cancelled.is_valid() and cancelled.call()):
		# Saved steps are legal candidates, with no privileged investment policy.
		# Every continuation must win the same completion-time comparison.
		var continuing_action := {}
		if _decision_context.has("execution_plan"):
			var follow: Dictionary = ExecutionPlan.resolve(state,owner,_decision_context.execution_plan,
				mini(until,started+maxi(0,available/8)))
			if follow.context.is_empty(): _decision_context.erase("execution_plan")
			else: _decision_context.execution_plan=follow.context
			if follow.action.kind!="wait" and (not root_action_filter.is_valid() or root_action_filter.call(follow.action)):
				continuing_action=follow.action
		if continuing_action.is_empty() and _decision_context.has("growth_return"):
			var follow: Dictionary = GrowthCommitment.resolve(state,owner,_decision_context.growth_return,
				mini(until,started+maxi(0,available/16)))
			if follow.context.is_empty(): _decision_context.erase("growth_return")
			else: _decision_context.growth_return=follow.context
			if follow.action.kind!="wait" and (not root_action_filter.is_valid() or root_action_filter.call(follow.action)):
				continuing_action=follow.action
		var quick_until := mini(until, started + mini(200, maxi(20, available / 8)))
		var quick: Dictionary = Emergency.choose(state, owner, quick_until, _decision_context)
		_decision_context.merge(quick.context,true)
		if quick.action.kind != "wait" and (not root_action_filter.is_valid() or root_action_filter.call(quick.action)):
			_publish(incumbent, quick.action, {"reason":quick.action.reason}, started, cutoff, on_choice)
		var publish := func(layer: Dictionary):
			_publish(incumbent, layer.action, layer.merged({"growth_continuation":false,"execution_continuation":false}), started, cutoff, on_choice)
		var search := Search.new()
		var completed: Dictionary = search.search(state, owner, _policy, until, cancelled, publish, search_tree, root_action_filter, continuing_action, _decision_context.get("execution_plan",{}))
		# Include forecast-cache destruction in the reported/end-to-end budget.
		search = null
		incumbent.report.search_nodes = completed.search_nodes
		incumbent.report.evaluated = completed.evaluated
		incumbent.report.cutoff = completed.cutoff
		incumbent.report.root_complete = completed.root_complete
		incumbent.report.root_candidates = completed.root_candidates
		incumbent.report.completed_candidates = completed.completed_candidates
		incumbent.report.root_unobserved = completed.root_unobserved
		incumbent.report.cleanup_reserve_us = completed.cleanup_reserve_us
		if completed.has("root_growth"): incumbent.report["root_growth"]=completed.root_growth
		if completed.has("root_continuation"): incumbent.report["root_continuation"]=completed.root_continuation
		incumbent.report["root_coverage_complete"]=completed.get("root_coverage_complete",false)
		for key in ["short_search_depth","short_search_nodes","short_root_candidates","root_ordinary_us","root_production_us","root_production_candidates","root_production_serviced",
				"root_production_complete","root_evaluated_intents","root_economic_us","root_economic_completed","evaluation_layer"]:
			incumbent.report[key] = completed[key]
	var report: Dictionary = incumbent.report
	report.elapsed_us = Time.get_ticks_usec() - started
	report.overrun = int(report.elapsed_us) > available
	report["action"] = incumbent.action.duplicate(true)
	last_decision = report
	return incumbent.action

func _publish(incumbent: Dictionary, action: Dictionary, evidence: Dictionary, started: int, until: int,
		on_choice: Callable) -> bool:
	var ready := Time.get_ticks_usec()
	if ready >= until:
		incumbent.report.discarded_late = true
		incumbent.report.cutoff = true
		return false
	var report: Dictionary = incumbent.report.merged(evidence, true)
	report.erase("action")
	report.kind = action.kind
	report.selected_after_us = ready - started
	report.elapsed_us = report.selected_after_us
	incumbent.action = action
	incumbent.report = report
	if on_choice.is_valid(): on_choice.call(action, report.duplicate(true))
	return true
