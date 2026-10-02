# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AITurnPlan
extends RefCounted

const Env = preload("res://engine/ai_environment.gd")
const Actions = preload("res://engine/ai_actions.gd")
const Eval = preload("res://engine/ai_evaluation.gd")
const Context = preload("res://engine/ai_context.gd")

## 完整行动方案 -> 有限对手回应 -> 真实攻击/结算 -> 保有能力评估。
## 搜索不改环境规则；AI 所有强度共用这条路径。
static func profile(strength: float) -> Dictionary:
	return AISearch.from_model("ai", strength).resolved_parameters()

static func choose_plan(state: GameState, who: String, cfg: AISearch) -> Dictionary:
	var p := cfg.resolved_parameters()
	var started := Time.get_ticks_usec()
	# 仅本次决策共享规则派生值，不随参数持久化，也不跨卡表加载复用。
	p["_context"] = Context.new()
	var budget := [int(p["node_budget"])]
	p["_work"] = budget
	var roots := Actions.generate(state, who, p)
	var ranked: Array = []
	var evaluations := 0
	for node in roots:
		if Actions.exhausted(p) and not ranked.is_empty():
			break
		var resolved := resolve_current(node["state"], who, p)
		evaluations += int(resolved["evaluations"])
		ranked.append({"node": node, "state": resolved["state"], "score": resolved["score"]})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"])
	if ranked.is_empty():
		return {"intents": [], "diagnostics": {"evaluations": 0}}
	var best: Dictionary = ranked[0]
	var ranked_count := ranked.size()
	# 只深化当前回合的前几名。所有方案第 r 个样本共享相同市场随机流。
	if int(p["future_rounds"]) > 0 and absf(float(best["score"])) < Eval.TERMINAL_SCORE:
		var best_value := -INF
		var seed_base := int(state.round_num) * 1000003 + 7919
		for candidate in ranked.slice(0, mini(int(p["finalists"]), ranked.size())):
			if Actions.exhausted(p):
				break
			var total := 0.0
			for r in int(p["samples"]):
				var next := Env.copy(candidate["state"])
				next.set_seed(seed_base + r * 104729)
				_rollout(next, int(p["future_rounds"]), p)
				total += bounded_score(next, who, p)
			if Actions.exhausted(p):
				break # 未完成的样本轮不覆盖上一个完整决策。
			var value := total / int(p["samples"])
			if value > best_value:
				best_value = value
				best = candidate
	p.erase("_work")
	p.erase("_context")
	return {"intents": best["node"]["intents"], "diagnostics": {
		"model": "ai", "root_candidates": roots.size(), "evaluations": evaluations,
		"score": best["score"], "profile": p, "evaluated_roots": ranked_count,
		"expanded_nodes": int(p["node_budget"]) - int(budget[0]), "budget_exhausted": int(budget[0]) <= 0,
		"elapsed_ms": (Time.get_ticks_usec() - started) / 1000.0}}

static func bounded_score(state: GameState, who: String, parameters: Dictionary = {}) -> float:
	var value := Eval.score(state, who, parameters)
	if state.winner != "":
		return 1.0 if state.winner == who else -1.0
	return value / (1.0 + absf(value))

## 输入是 who 本回合刚行动完的局面。后手不再给已经行动的对手额外行动。
static func resolve_current(leaf: GameState, who: String, p: Dictionary) -> Dictionary:
	var replies: Array = []
	if leaf.winner == "" and who == leaf.action_first():
		var rp := _fast_profile(p)
		rp["plans"] = int(p["replies"])
		if p.has("_work"):
			rp["_work"] = p["_work"]
		rp["buy_beam"] = maxi(3, int(p["replies"]))
		rp["build_beam"] = maxi(2, int(p["replies"]))
		replies = Actions.generate(leaf, GameState.opponent(who), rp)
	else:
		replies = [{"state": leaf}]
	var worst := INF
	var result: GameState = null
	for reply in replies:
		var settled := Env.copy(reply["state"])
		if settled.winner == "":
			Env.settle(settled, _target_policy(p))
		var value := Eval.score(settled, who, p)
		if result == null or value < worst:
			worst = value
			result = settled
	return {"state": result, "score": worst, "evaluations": replies.size()}

static func _fast_profile(context: Dictionary) -> Dictionary:
	var result := context.duplicate()
	result.merge({"buy_beam": 3, "build_beam": 2, "plans": 2, "sales": 0}, true)
	return result

static func _rollout(state: GameState, rounds: int, context: Dictionary) -> void:
	var fast := _fast_profile(context)
	if context.has("_work"):
		fast["_work"] = context["_work"]
	for _r in rounds:
		if Actions.exhausted(context):
			return
		if state.winner != "":
			return
		state.end_round()
		state.start_round()
		for who in state.action_order():
			if state.winner != "":
				break
			var nodes := Actions.generate(state, who, fast)
			# 低成本策略用同一个评估目标，选在真实结算投影中最好的候选。
			var chosen: Dictionary = nodes[0]
			var best := -INF
			for n in nodes:
				var s := Env.copy(n["state"])
				Env.settle(s, _target_policy(context))
				var value := Eval.score(s, who, context)
				if value > best:
					best = value
					chosen = n
			Env.replay(state, chosen["intents"])
		if state.winner == "":
			Env.settle(state, _target_policy(context))

## 攻击排序只读实际配方/产出/成本及当前目标。
static func greedy_target(state: GameState, attacker: String, targets: Array, pools: Dictionary,
		parameters: Dictionary = {}) -> Dictionary:
	var p := parameters if not parameters.is_empty() else profile(0.0)
	var best := -INF
	var picked := {}
	var victim := GameState.opponent(attacker)
	for t in distinct_targets(targets):
		var res := str(t["res"])
		var remaining := state.resource_count(victim, res)
		var cost := maxf(float(t["cost"]), 1.0)
		var score := 1.0 / maxf(remaining, 1)
		if remaining * cost <= float(pools.get(res, 0)):
			score += float(CardDB.game_rules()["win_cash"])
		if t.get("kind") == "combo" and bool(t.get("intact", false)):
			for combo in state.combos:
				if combo["owner"] != victim or not combo["uids"].has(t["uids"][0]):
					continue
				var ev: Dictionary = combo["eval"]
				var value := Actions._combo_value(state, victim, ev) - int(ev.get("recipe_pay_n", 0))
				# 后手的未开火攻击组被拆会失去还击，先手已开过火则只剩远期能力。
				if ev["type"] == "attack" and attacker != state.action_first():
					value *= float(p["spent_attack_discount"])
				score += maxf(0.0, value)
				break
		if score > best:
			best = score
			picked = t
	return picked

static func distinct_targets(targets: Array) -> Array:
	var out: Array = []
	var seen := {}
	for t in targets:
		var key := "%s|%s|%s" % [GameState.target_batch(t), t["kind"], t["res"]]
		if not seen.has(key):
			seen[key] = true
			out.append(t)
	return out

static func target_picker(cfg) -> Callable:
	var parameters: Dictionary = cfg.resolved_parameters()
	var budget := [int(parameters["target_trials"])]
	return func(state: GameState, attacker: String, targets: Array, pools: Dictionary) -> Dictionary:
		# 选靶 Callable 可被外部保留；每次调用建立缓存，额度仍由整个攻击阶段共享。
		var p_eval := parameters.duplicate()
		p_eval["_context"] = Context.new()
		var policy := _target_policy(p_eval)
		var choices := distinct_targets(targets)
		if choices.size() <= 1 or int(budget[0]) <= 0:
			return policy.call(state, attacker, targets, pools)
		var best := -INF
		var pick: Dictionary = policy.call(state, attacker, targets, pools)
		for target in choices:
			if int(budget[0]) <= 0:
				break
			budget[0] -= 1
			var s := Env.copy(state)
			var p: Dictionary = pools.duplicate(true)
			if not bool(s.apply_attack(attacker, target, p).get("ok", false)):
				continue
			s.check_victory()
			Settle.spend_pool(s, attacker, p, policy)
			if s.winner == "" and attacker == s.action_first():
				Settle.attack_phase(s, GameState.opponent(attacker), policy)
			if s.winner == "":
				Settle.produce(s)
			Settle.finalize(s)
			var value := Eval.score(s, attacker, p_eval)
			if value > best:
				best = value
				pick = target
		return pick


static func _target_policy(parameters: Dictionary) -> Callable:
	return func(state: GameState, attacker: String, targets: Array, pools: Dictionary) -> Dictionary:
		return greedy_target(state, attacker, targets, pools, parameters)
