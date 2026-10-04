# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AITurnPlan
extends RefCounted

const Cancellation = preload("res://engine/ai_cancellation.gd")

const Env = preload("res://engine/ai_environment.gd")
const Actions = preload("res://engine/ai_actions.gd")
const Eval = preload("res://engine/ai_evaluation.gd")
const Capabilities = preload("res://engine/ai_capabilities.gd")
const Context = preload("res://engine/ai_context.gd")

## 完整行动方案 -> 有限对手回应 -> 真实攻击/结算 -> 保有能力评估。
## 搜索不改环境规则；AI 所有强度共用这条路径。
static func profile(strength: float) -> Dictionary:
	return AISearch.from_model("ai", strength).resolved_parameters()

static func choose_plan(state: GameState, who: String, cfg: AISearch) -> Dictionary:
	var p := cfg.resolved_parameters()
	if cfg.cancelled_check.is_valid(): p["_cancelled"] = cfg.cancelled_check
	var started := Time.get_ticks_usec()
	p["_deadline_usec"] = started + int(p.get("think_time_ms",5000))*1000
	p["_context"] = Context.new()
	p["_work"] = [int(p["node_budget"])]
	var generation_profile := p.duplicate()
	# 候选生成只用前三分之一，给真实当前评价留出时间。
	generation_profile["_deadline_usec"] = started + maxi(1,int(p.get("think_time_ms",5000))*1000/3)
	var generated := Actions.generate_with_status(state,who,generation_profile)
	var after_generation := int(p["_work"][0])
	var roots: Array = generated["nodes"]
	var baseline: Array = generated.get("baseline",[])
	# 基础完整方案先接受同一对手模型评价；增强方案只有比较通过后才能替换它。
	var ordered: Array = []
	var seen := {}
	for node in baseline+roots:
		if not node.has("_signature"): node["_signature"] = Capabilities.signature(node["state"])
		if seen.has(node["_signature"]): continue
		seen[node["_signature"]] = true
		ordered.append(node)
	var fallback: Dictionary = _fallback(ordered,state,who,p)
	var current := _evaluate_candidates(ordered,generated.get("rescue",[]),who,p)
	var ranked: Array = current["ranked"]
	var after_current := int(p["_work"][0])
	ranked.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return Capabilities.compare_nodes(a,b,who,"score",p))
	var best: Dictionary = ranked[0] if not ranked.is_empty() else {"node":fallback,"score":null}
	var future := {"complete_layers":0,"depth":0,"samples":0,"reply_limit":0,"evaluations":0,"incomplete":false,"trace":[]}
	if not ranked.is_empty() and int(p["future_rounds"]) > 0 and absf(float(best["score"])) < Eval.TERMINAL_SCORE:
		var contenders := _finalists(ranked,int(p["finalists"]),p,who)
		future = _deepen(state,who,contenders,p)
		if future.has("best"): best = future["best"]
	var used := int(p["node_budget"])-int(p["_work"][0])
	var exhausted := int(p["_work"][0]) <= 0
	var timed_out := Cancellation.expired(p)
	p.erase("_work")
	p.erase("_context")
	p.erase("_cancelled")
	p.erase("_deadline_usec")
	return {"intents":best["node"]["intents"],"diagnostics":{
		"model":"ai","profile":p,"root_candidates":current["candidates"],"evaluations":current["evaluations"],
		"evaluated_roots":ranked.size(),"current_attempted":current["attempted"],"current_complete":ranked.size(),
		"current_incomplete":current["incomplete"],"current_unvisited":current["unvisited"],
		"current_coverage_limited":current["coverage_limited"],"generation_complete":generated.get("complete",false),
		"rescue_candidates":current["rescue_candidates"],"rescue_evaluated":current["rescue_evaluated"],
		"rescue_available":generated.get("rescue",[]).size(),"rescue_work":generated.get("rescue_work",0),
		"rescue_complete":generated.get("rescue_complete",true),
		"current_rescue_generation_incomplete":current["rescue_generation_incomplete"],
		"generation_stages":generated.get("generation_stages",[]),
		"baseline_candidates":baseline.size(),"selected_evaluation_complete":not ranked.is_empty(),
		"score":best["score"],"expanded_nodes":used,"budget_exhausted":exhausted,"time_limit_reached":timed_out,
		"fallback_used":ranked.is_empty(),
		"generation_nodes":int(p["node_budget"])-after_generation,
		"current_nodes":after_generation-after_current,"future_nodes":after_current-(int(p["node_budget"])-used),
		"future_complete_layers":future["complete_layers"],"future_depth":future["depth"],
		"future_samples":future["samples"],"future_reply_limit":future["reply_limit"],
		"future_evaluations":future["evaluations"],"future_incomplete":future["incomplete"],"future_layers":future["trace"],
		"future_value":future.get("value"),"future_response_counts":future.get("response_counts",[]),
		"elapsed_ms":(Time.get_ticks_usec()-started)/1000.0}}

## 尚无完成的当前评价时，选择已生成且完整合法的最高静态分方案。
static func _fallback(nodes: Array, state: GameState, who: String, p: Dictionary) -> Dictionary:
	var best: Dictionary = {"state":state,"intents":[]}
	for node in nodes:
		if not best.has("rank") or Capabilities.compare_nodes(node,best,who,"rank",p): best = node
	return best

## 只有普通有限池全部完成且严格全败，才检查尚未比较的单步补救。
## loss_score 从本次评分方看：己方候选是 -T，对手回应是 +T。
static func _rescue_after_losses(ordinary: Array, rescue: Array, ranked: Array, loss_score: float) -> Array:
	if ordinary.is_empty() or ranked.size() != ordinary.size() or rescue.is_empty(): return []
	if not ranked.all(func(row: Dictionary)->bool: return row["score"] == loss_score): return []
	var seen := {}
	for node in ordinary:
		if not node.has("_signature"): node["_signature"] = Capabilities.signature(node["state"])
		seen[node["_signature"]] = true
	var out: Array = []
	for node in rescue:
		if not node.has("_signature"): node["_signature"] = Capabilities.signature(node["state"])
		if seen.has(node["_signature"]): continue
		seen[node["_signature"]] = true
		out.append(node)
	return out

## 根与未来行动复用评价、触发条件和记账；救援构造已在生成阶段计费。
## 未来只使用分数，仍在任何局部评价不完整时停止，不提交残缺的共同层。
static func _evaluate_candidates(ordinary: Array, rescue: Array, who: String, p: Dictionary, score_only: bool = false) -> Dictionary:
	var result := {"ranked":[],"candidates":ordinary.size(),"attempted":0,"evaluations":0,
		"incomplete":0,"unvisited":0,"coverage_limited":0,"rescue_candidates":0,"rescue_evaluated":0,
		"rescue_generation_incomplete":0}
	for phase in 2:
		var nodes: Array = ordinary if phase == 0 else _rescue_after_losses(ordinary,rescue,result["ranked"],-Eval.TERMINAL_SCORE)
		if phase == 1:
			result["rescue_candidates"] = nodes.size()
			result["candidates"] += nodes.size()
		for node in nodes:
			var resolved := resolve_current(node["state"],who,p,score_only)
			result["attempted"] += 1
			result["evaluations"] += int(resolved["evaluations"])
			if not resolved.get("rescue_complete",true): result["rescue_generation_incomplete"] += 1
			if not resolved["complete"]:
				result["incomplete"] += 1
				if score_only or resolved.get("interrupted",false): break
				continue
			if resolved.get("coverage_limited",false): result["coverage_limited"] += 1
			result["ranked"].append({"node":node,"state":resolved["state"],"score":resolved["score"],
				"responses":resolved["responses"],"baseline":node.get("baseline",false)})
			if phase == 1: result["rescue_evaluated"] += 1
	result["unvisited"] = int(result["candidates"])-int(result["attempted"])
	return result

static func _finalists(ranked: Array, limit: int, p: Dictionary = {}, who: String = GameState.PLAYER) -> Array:
	if ranked.is_empty() or limit <= 0: return []
	# ranked 只含同一规格下完成真实当前评价的节点。固定名额先保留全局最佳，
	# 再保留各较低累计生成层的最佳代表，避免扩展空间把中间层挤出未来比较。
	var selected: Array = [ranked[0]]
	var stages: Array = []
	for candidate in ranked:
		var stage := _finalist_stage(candidate)
		if not stages.has(stage): stages.append(stage)
	stages.sort()
	for stage in stages:
		if selected.size() >= limit or stage == stages[-1]: break
		for candidate in ranked:
			if _finalist_stage(candidate) > int(stage): continue
			if not selected.has(candidate): selected.append(candidate)
			break
	# 非单位持牌构成用于分配探索名额，不是状态等价判据；同道编组仍在普通池。
	if int(p.get("candidate_dedup",0)) > 0 and selected.size() < limit:
		var lanes := {}
		for candidate in selected:
			lanes[Capabilities._holding_lanes(candidate["node"],who)["operating"]] = true
		for candidate in ranked:
			if selected.size() >= limit: break
			var lane: String = Capabilities._holding_lanes(candidate["node"],who)["operating"]
			if lanes.has(lane): continue
			lanes[lane] = true
			selected.append(candidate)
	for candidate in ranked:
		if selected.size() >= limit: break
		if not selected.has(candidate): selected.append(candidate)
	# 入围结果始终按原评分顺序返回；关闭持牌分道时沿用原选择流程。
	return ranked.filter(func(candidate: Dictionary)->bool: return selected.has(candidate))

static func _finalist_stage(candidate: Dictionary) -> int:
	var node: Dictionary = candidate.get("node",candidate)
	return int(node.get("generation_stage",0 if candidate.get("baseline",node.get("baseline",false)) else 1))

## 固定各根的局部工作规格。总额度不足时不拿剩余碎片伪装成完整评价。
## 局部上限内先完成基础方案、再扩展；扩展有限只是覆盖程度，不改变合法规则。
static func _generate_scope(state: GameState, who: String, p: Dictionary, limit: int) -> Dictionary:
	var cap := maxi(1,limit)
	if Cancellation.requested(p) or (p.has("_work") and int(p["_work"][0]) < cap):
		return {"nodes":[],"rescue":[],"rescue_complete":false,"complete":false,"interrupted":true,"coverage_limited":false}
	var local := p.duplicate()
	local.erase("_generation_work")
	local["generation_budget"] = cap
	local["_work"] = [cap]
	var generated := Actions.generate_with_status(state,who,local)
	if p.has("_work"): p["_work"][0] -= cap-int(local["_work"][0])
	var complete: bool = generated.get("complete",false) or generated.get("baseline_complete",false)
	return {"nodes":generated["nodes"],"rescue":generated.get("rescue",[]),"rescue_complete":generated.get("rescue_complete",true),"complete":complete,"interrupted":false,
		"coverage_limited":not bool(generated.get("complete",false)) or not bool(generated.get("rescue_complete",true))}

## 每一层覆盖所有入围方案、固定回应及相同市场样本。只提交整层完成的决策。
## 上一深度的样本状态可续推一回合；失败层的局部结果不会覆盖上一层。
static func _deepen(state: GameState, who: String, contenders: Array, p: Dictionary) -> Dictionary:
	var result := {"complete_layers":0,"depth":0,"samples":0,"reply_limit":0,"evaluations":0,"incomplete":false,"trace":[]}
	var reply_limit := maxi(1,int(p.get("future_reply_limit",1)))
	var replies: Array = []
	for candidate in contenders:
		replies.append(_future_responses(candidate,p))
	result["response_counts"] = replies.map(func(rows: Array)->int: return rows.size())
	var cache := {}
	var seed_base := int(state.round_num)*1000003+7919
	for depth in range(1,int(p["future_rounds"])+1):
		for sample_count in range(1,int(p["samples"])+1):
			var pending := {}
			var response_mean := func(ci: int, ri: int) -> Dictionary:
				return _future_response_mean(replies[ci][ri],ci,ri,depth,sample_count,seed_base,cache,pending,who,p)
			var preferred := int(result["trace"][-1]["winner"]) if not result["trace"].is_empty() else -1
			var reply_hints: Array = result["trace"][-1]["reply_priority"] if not result["trace"].is_empty() else []
			var bounded_response := func(ci: int, ri: int, cutoff: float) -> Dictionary:
				return _future_response_mean(replies[ci][ri],ci,ri,depth,sample_count,seed_base,cache,pending,who,p,cutoff)
			var layer := _future_layer(contenders,result["response_counts"],who,p,response_mean,preferred,reply_hints,bounded_response)
			result["evaluations"] += int(layer["evaluations"])
			if not layer["complete"] or Cancellation.requested(p):
				result["incomplete"] = true
				return result
			cache.merge(pending,true)
			var winner: int = layer["winner"]
			result["best"] = contenders[winner]
			result["value"] = layer["values"][winner]
			result["complete_layers"] += 1
			result["depth"] = depth
			result["samples"] = sample_count
			result["reply_limit"] = reply_limit
			result["trace"].append({"depth":depth,"samples":sample_count,"candidates":contenders.size(),
				"values":layer["values"],"upper_bounds":layer["upper_bounds"],"value_kinds":layer["value_kinds"],
				"evaluated_responses":layer["evaluated_responses"],"skipped_responses":layer["skipped_responses"],
				"lower_bound_exits":layer["lower_bound_exits"],"evaluation_order":layer["evaluation_order"],"winner":winner,
				"reply_priority":layer["reply_priority"],"response_orders":layer["response_orders"],
				"sample_bound_exits":layer["sample_bound_exits"],"skipped_samples":layer["skipped_samples"]})
	return result

## 本层赢家必须有精确最坏值。已算回应均值的最小值只构成其他候选的上界；
## 严格低于冠军才能淘汰，不能当成该候选精确分，也不能跨层沿用淘汰结果。
static func _future_layer(contenders: Array, response_counts: Array, who: String, p: Dictionary,
		response_mean: Callable, preferred: int = -1, reply_hints: Array = [], bounded_response: Callable = Callable()) -> Dictionary:
	var values: Array = [];values.resize(contenders.size())
	var bounds: Array = [];bounds.resize(contenders.size())
	var kinds: Array = [];kinds.resize(contenders.size());kinds.fill("pending")
	var counts: Array = [];counts.resize(contenders.size());counts.fill(0)
	var hints: Array = [];hints.resize(contenders.size());hints.fill(-1)
	var response_orders: Array = [];response_orders.resize(contenders.size())
	# 顺序索引不替换原ci/ri身份；缓存仍绑定原候选、回应和样本。
	var order := _priority_order(contenders.size(),preferred)
	var result := {"complete":false,"winner":-1,"values":values,"upper_bounds":bounds,"value_kinds":kinds,
		"evaluated_responses":counts,"skipped_responses":0,"lower_bound_exits":0,"evaluations":0,"evaluation_order":order,
		"reply_priority":hints,"response_orders":response_orders,"sample_bound_exits":0,"skipped_samples":0}
	for ci in order:
		if int(response_counts[ci]) <= 0: return result
		var previous_hint := int(reply_hints[ci]) if ci < reply_hints.size() else -1
		var response_order := _priority_order(int(response_counts[ci]),previous_hint)
		response_orders[ci] = response_order
		var value := INF
		var pruned := false
		for position in response_order.size():
			var ri: int = response_order[position]
			var champion: int = result["winner"]
			var cutoff := float(values[champion]) if champion >= 0 else -INF
			var mean: Dictionary = bounded_response.call(ci,ri,cutoff) if bounded_response.is_valid() else response_mean.call(ci,ri)
			result["evaluations"] += int(mean.get("evaluations",0))
			if not mean["complete"]: return result
			counts[ci] += 1
			var upper: float = mean["upper_bound"] if bool(mean.get("bounded",false)) else float(mean["value"])
			if upper < value or (upper == value and (hints[ci] < 0 or ri < hints[ci])): hints[ci] = ri
			value = minf(value,upper)
			bounds[ci] = value
			var remaining: int = response_order.size()-position-1
			if bool(mean.get("bounded",false)):
				# 一条回应的样本均值上界已严格低于精确冠军，候选min也不能获胜。
				# 未完整算完的候选只记录剪枝见证，不冒称已知真正最不利回应。
				assert(champion >= 0 and upper < cutoff)
				kinds[ci] = "upper_bound"
				result["sample_bound_exits"] += 1
				result["skipped_samples"] += int(mean["skipped_samples"])
				result["skipped_responses"] += remaining
				pruned = true
				break
			# 完整回应均值达到全局下界时，即使其他回应未算，min也已精确确定。
			if value == -1.0:
				result["skipped_responses"] += remaining
				result["lower_bound_exits"] += 1
				break
			if remaining > 0 and champion >= 0 and value < cutoff:
				kinds[ci] = "upper_bound"
				result["skipped_responses"] += remaining
				pruned = true
				break
		if pruned: continue
		values[ci] = value
		kinds[ci] = "exact"
		var champion: int = result["winner"]
		if champion < 0 or value > float(values[champion]):
			result["winner"] = ci
		elif value == values[champion]:
			if Capabilities.compare_nodes(contenders[ci],contenders[champion],who,"score",p) or (ci < champion and not Capabilities.compare_nodes(contenders[champion],contenders[ci],who,"score",p)):
				result["winner"] = ci
	result["complete"] = true
	return result

static func _priority_order(size: int, preferred: int) -> Array:
	var order: Array = []
	if preferred >= 0 and preferred < size: order.append(preferred)
	for index in size:
		if index != preferred: order.append(index)
	return order

## 样本保持原顺序。已算前缀后把剩余样本逐个按+1累加，得到同浮点求和顺序的
## 上界；严格低于精确冠军才可省略。返回上界时value为空，不能作为精确均值。
static func _sample_mean(samples: int, cutoff: float, evaluate_sample: Callable) -> Dictionary:
	var total := 0.0
	var evaluations := 0
	for sample in samples:
		var row: Dictionary = evaluate_sample.call(sample)
		evaluations += int(row.get("evaluations",0))
		if not row["complete"]: return {"complete":false,"evaluations":evaluations}
		var value: float = row["value"]
		assert(is_finite(value) and value >= -1.0 and value <= 1.0)
		total += value
		var remaining := samples-sample-1
		if remaining > 0 and cutoff > -INF:
			var optimistic := total
			for _unused in remaining: optimistic += 1.0
			var upper := optimistic/float(samples)
			if upper < cutoff:
				return {"complete":true,"bounded":true,"value":null,"upper_bound":upper,
					"evaluations":evaluations,"skipped_samples":remaining}
	return {"complete":true,"bounded":false,"value":total/float(samples),"evaluations":evaluations,"skipped_samples":0}

static func _future_response_mean(initial: GameState, ci: int, ri: int, depth: int, samples: int,
		seed_base: int, cache: Dictionary, pending: Dictionary, who: String, p: Dictionary, cutoff: float = -INF) -> Dictionary:
	var evaluate_sample := func(sample: int) -> Dictionary:
		var continued := _future_continuation(initial,ci,ri,sample,depth,seed_base,cache,pending,p)
		if not continued["complete"]: return continued
		var value := bounded_score(continued["state"],who,p)
		return {"complete":not Cancellation.requested(p),"evaluations":continued["evaluations"],"value":value}
	return _sample_mean(samples,cutoff,evaluate_sample)

## 剪枝留下的缓存空洞不是较浅的已完成局面。只从相同候选/回应/样本的最近
## 已算深度续推；从原回应开始时无论目标深度是多少，都重设统一市场样本种子。
static func _future_continuation(initial: GameState, ci: int, ri: int, sample: int, depth: int,
		seed_base: int, cache: Dictionary, pending: Dictionary, p: Dictionary) -> Dictionary:
	var next: GameState
	var reached := 0
	for previous in range(depth,0,-1):
		var key := str([ci,ri,sample,previous])
		if pending.has(key) or cache.has(key):
			next = pending[key] if pending.has(key) else cache[key]
			reached = previous
			break
	if reached == 0:
		next = Env.copy(initial)
		next.set_seed(seed_base+sample*104729)
	var evaluations := 0
	for step in range(reached+1,depth+1):
		# 已保存的较浅状态不可被下一次 _rollout 原地修改。
		next = Env.copy(next)
		var rollout := _rollout(next,1,p)
		evaluations += 1
		if not rollout["complete"]: return {"complete":false,"evaluations":evaluations}
		pending[str([ci,ri,sample,step])] = next
	return {"complete":true,"state":next,"evaluations":evaluations}

## 先按完整后续依赖去重，再截取计算额度允许的独立回应；足够高的额度覆盖全池。
## Env.key 保留牌与组合次序、运行时属性、市场和 UID；随机状态也必须相同。
static func _future_responses(candidate: Dictionary, p: Dictionary) -> Array:
	var responses: Array = candidate["responses"] if int(p.get("reply_mode",0)) > 0 else [candidate["state"]]
	if responses.is_empty(): responses = [candidate["state"]]
	var out: Array = []
	var seen := {}
	for state in responses:
		var key := StateCodec.canon([Env.key(state),state.rng_snapshot(),state.win_reason])
		if seen.has(key): continue
		seen[key] = true
		out.append(state)
	return out.slice(0,maxi(1,int(p.get("future_reply_limit",1))))

static func bounded_score(state: GameState, who: String, parameters: Dictionary = {}) -> float:
	var value := settled_score(state, who, parameters)
	if int(parameters.get("tactical_extension",0)) > 0 and absf(value) >= Eval.TERMINAL_SCORE:
		return signf(value)
	if state.winner != "":
		return 1.0 if state.winner == who else -1.0
	return value / (1.0 + absf(value))

## 输入是 who 本回合刚行动完的局面。后手不再给已经行动的对手额外行动。
## score_only 仅供不使用回应状态的调用方；确定达到下界后可结束结算，根评价仍保留完整回应。
static func resolve_current(leaf: GameState, who: String, p: Dictionary, score_only: bool = false) -> Dictionary:
	if Cancellation.requested(p): return _interrupted_resolution(leaf,0,false,true)
	var replies: Array = [{"state":leaf}]
	var rescue: Array = []
	var rescue_complete := true
	var rescue_candidates := 0
	var rescue_evaluated := 0
	var limited := false
	if leaf.winner == "" and who == leaf.action_first():
		# 当前回应继承调用方动作能力；未来调用方已经明确传入局部规格。
		var rp := p.duplicate()
		rp["plans"] = int(p["replies"])
		rp["buy_beam"] = maxi(3,int(p["replies"]))
		rp["build_beam"] = maxi(2,int(p["replies"]))
		var generated := _generate_scope(leaf,GameState.opponent(who),rp,int(p.get("reply_generation_budget",1024)))
		if not generated["complete"]:
			return {"state":leaf,"score":null,"evaluations":0,"responses":[],"complete":false,
				"interrupted":generated["interrupted"],"coverage_limited":generated["coverage_limited"],
				"rescue_complete":generated["rescue_complete"],"rescue_candidates":0,"rescue_evaluated":0}
		replies = generated["nodes"]
		rescue = generated["rescue"]
		rescue_complete = generated["rescue_complete"]
		limited = generated["coverage_limited"]
	var ranked: Array = []
	for phase in 2:
		# 对方普通回应从本方看全为 +T，才给对方同样的近端补查机会。
		var nodes: Array = replies if phase == 0 else _rescue_after_losses(replies,rescue,ranked,Eval.TERMINAL_SCORE)
		if phase == 1: rescue_candidates = nodes.size()
		for reply in nodes:
			if Cancellation.requested(p):
				return _interrupted_resolution(leaf,ranked.size(),limited,rescue_complete)
			var settled := Env.copy(reply["state"])
			if settled.winner == "": Env.settle(settled,_target_policy(p))
			var score := settled_score(settled,who,p)
			if Cancellation.requested(p):
				return _interrupted_resolution(leaf,ranked.size(),limited,rescue_complete)
			ranked.append({"state":settled,"score":score})
			if phase == 1: rescue_evaluated += 1
			if score_only and ranked[-1]["score"] == -Eval.TERMINAL_SCORE:
				break
	if ranked.is_empty():
		return {"state":leaf,"score":null,"evaluations":0,"responses":[],"complete":false,"interrupted":false,"coverage_limited":limited,
			"rescue_complete":rescue_complete,"rescue_candidates":rescue_candidates,"rescue_evaluated":rescue_evaluated}
	ranked.sort_custom(func(a: Dictionary,b: Dictionary)->bool: return a["score"]<b["score"])
	return {"state":ranked[0]["state"],"score":ranked[0]["score"],"evaluations":ranked.size(),
		"responses":ranked.map(func(row: Dictionary)->GameState: return row["state"]),
		"complete":true,"interrupted":false,"coverage_limited":limited,
		"rescue_complete":rescue_complete,"rescue_candidates":rescue_candidates,"rescue_evaluated":rescue_evaluated}

static func settled_score(state: GameState, who: String, p: Dictionary) -> float:
	if state.winner != "": return Eval.score(state,who,p)
	if int(p.get("tactical_extension",0)) > 0:
		var winner := Capabilities.cashout_winner_after_round(state)
		if winner != "": return Eval.TERMINAL_SCORE if winner == who else -Eval.TERMINAL_SCORE
	return Eval.score(state,who,p)

static func _fast_profile(context: Dictionary) -> Dictionary:
	var result := context.duplicate()
	result.merge({"buy_beam":int(context.get("rollout_buy_beam",3)),
		"build_beam":int(context.get("rollout_build_beam",2)),
		"plans":int(context.get("rollout_plans",2)),
		"replies":mini(int(context.get("replies",2)),int(context.get("rollout_plans",2))),
		"reply_generation_budget":mini(int(context.get("reply_generation_budget",1024)),int(context.get("rollout_step_budget",512)))},true)
	if int(context.get("rollout_capabilities",0)) == 0:
		result.merge({"sales":0,"financing_mode":0,"resale_mode":0,"allocation_mode":0,"formation_mode":0},true)
	return result

static func _rollout(state: GameState, rounds: int, context: Dictionary) -> Dictionary:
	var fast := _fast_profile(context)
	for _r in rounds:
		if state.winner != "": return {"complete":true}
		state.end_round()
		state.start_round()
		for who in state.action_order():
			if state.winner != "": break
			var generated := _generate_scope(state,who,fast,int(context.get("rollout_step_budget",512)))
			if not generated["complete"]: return {"complete":false}
			var current := _evaluate_candidates(generated["nodes"],generated["rescue"],who,fast,true)
			if int(current["incomplete"]) > 0 or int(current["unvisited"]) > 0: return {"complete":false}
			var chosen: Dictionary = {}
			var best := -INF
			for candidate in current["ranked"]:
				var node: Dictionary = candidate["node"]
				var value := float(candidate["score"])
				if chosen.is_empty() or value > best or (value == best and Capabilities.compare_nodes({"node":node,"value":value},{"node":chosen,"value":best},who,"value",context)):
					best = value
					chosen = node
			if chosen.is_empty() or not Env.replay(state,chosen["intents"]): return {"complete":false}
		if state.winner == "": Env.settle(state,_target_policy(fast))
	return {"complete":true}

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
	return _target_policy(cfg.resolved_parameters())

## 搜索预测与真实执行共用同一选择器；双方攻击阶段各自拥有完整试算额度。
## 搜索叶子只用贪心续打，避免预测对方时无限递归建立新搜索。
static func _target_policy(parameters: Dictionary) -> Callable:
	var budgets := {}
	var plans := {}
	var p := parameters.duplicate()
	if not p.has("_context"): p["_context"] = Context.new()
	return func(state: GameState, attacker: String, targets: Array, pools: Dictionary) -> Dictionary:
		if not budgets.has(attacker): budgets[attacker] = [int(parameters["target_trials"])]
		if not plans.has(attacker): plans[attacker] = {}
		return _choose_target(state,attacker,targets,pools,p,budgets[attacker],plans[attacker])

static func _choose_target(state: GameState, attacker: String, targets: Array, pools: Dictionary,
		p: Dictionary, budget: Array, plan: Dictionary = {}) -> Dictionary:
	var policy := _greedy_policy(p)
	var choices := distinct_targets(targets)
	if int(p.get("attack_mode",0)) > 0 and not plan.is_empty():
		var cached := _planned_target(state,attacker,targets,pools,plan)
		if not cached.is_empty(): return cached
	if Cancellation.requested(p) or choices.size() <= 1 or int(budget[0]) <= 0: return policy.call(state,attacker,targets,pools)
	if int(p.get("attack_mode",0)) > 0:
		var searched := _attack_sequence(state,attacker,pools,p,budget,int(p.get("attack_depth",3)))
		plan.merge({"key":_attack_key(state,pools),"targets":searched["targets"]},true)
		var picked := _planned_target(state,attacker,targets,pools,plan)
		return picked if not picked.is_empty() else policy.call(state,attacker,targets,pools)
	var best := -INF
	var picked: Dictionary = policy.call(state,attacker,targets,pools)
	for target in choices:
		if int(budget[0]) <= 0 or Cancellation.requested(p): break
		budget[0] -= 1
		var next := Env.copy(state)
		var remaining: Dictionary = pools.duplicate(true)
		if not next.apply_attack(attacker,target,remaining).get("ok",false): continue
		next.check_victory()
		var outcome := _finish_attack(next,attacker,remaining,p,policy)
		var value := float(outcome["score"])
		if value > best:
			best = value
			picked = target
	return picked

## 已付费搜索得到的是整段续打，而非只选第一击；真实前态变化时重新规划。
static func _attack_key(state: GameState, pools: Dictionary) -> String:
	return StateCodec.canon([Env.key(state),state.rng_snapshot(),state.win_reason,pools])

static func _planned_target(state: GameState, attacker: String, targets: Array, pools: Dictionary,
		plan: Dictionary) -> Dictionary:
	var moves: Array = plan.get("targets",[])
	if moves.is_empty() or plan.get("key","") != _attack_key(state,pools):
		plan.clear()
		return {}
	var target: Dictionary = {}
	var wanted := Intent.target_ref(moves[0])
	for candidate in targets:
		if Intent.same_target(Intent.target_ref(candidate),wanted):
			target = candidate
			break
	if target.is_empty():
		plan.clear()
		return {}
	var next := Env.copy(state)
	var remaining := pools.duplicate(true)
	if not next.apply_attack(attacker,target,remaining).get("ok",false):
		plan.clear()
		return {}
	next.check_victory()
	moves.pop_front()
	plan["key"] = _attack_key(next,remaining)
	return target


static func _greedy_policy(parameters: Dictionary) -> Callable:
	return func(state: GameState, attacker: String, targets: Array, pools: Dictionary) -> Dictionary:
		return greedy_target(state, attacker, targets, pools, parameters)


## 共享真实结算入口；只记录己方续打，对方叶子回应始终使用同一贪心策略。
static func _finish_attack(leaf: GameState, attacker: String, pools: Dictionary,
		p: Dictionary, policy: Callable) -> Dictionary:
	var moves: Array = []
	var recorded := func(s: GameState, who: String, choices: Array, remaining: Dictionary) -> Dictionary:
		var target: Dictionary = policy.call(s,who,choices,remaining)
		if not target.is_empty(): moves.append(target.duplicate(true))
		return target
	if leaf.winner == "": Settle.spend_pool(leaf,attacker,pools,recorded)
	if leaf.winner == "" and attacker == leaf.action_first(): Settle.attack_phase(leaf,GameState.opponent(attacker),_greedy_policy(p))
	if leaf.winner == "": Settle.produce(leaf)
	Settle.finalize(leaf)
	return {"target":moves[0] if not moves.is_empty() else {},"targets":moves,"score":settled_score(leaf,attacker,p)}

## 先执行同一低深度选择器得到完整基线；它与随后深化严格共用试算额度。
static func _attack_baseline(state: GameState, attacker: String, pools: Dictionary,
		p: Dictionary, budget: Array) -> Dictionary:
	var basic := p.duplicate()
	basic["attack_mode"] = 0
	var policy := func(s: GameState, who: String, targets: Array, remaining: Dictionary) -> Dictionary:
		return _choose_target(s,who,targets,remaining,basic,budget)
	return _finish_attack(Env.copy(state),attacker,pools.duplicate(true),p,policy)

## 有界攻击序列搜索。每层先比较首击的完整贪心后缀，再用余量深化；
## 已完成的整段路线始终作为 incumbent，有限深化不能把更好基线丢掉。
static func _attack_sequence(state: GameState, attacker: String, pools: Dictionary,
		p: Dictionary, budget: Array, depth: int, incumbent: Dictionary = {}) -> Dictionary:
	var policy := _greedy_policy(p)
	var targets := distinct_targets(state.affordable_targets(GameState.opponent(attacker),pools))
	if state.winner != "" or targets.is_empty() or depth <= 0 or int(budget[0]) <= 0:
		return incumbent if not incumbent.is_empty() else _finish_attack(Env.copy(state),attacker,pools.duplicate(true),p,policy)
	var best := incumbent if not incumbent.is_empty() else _attack_baseline(state,attacker,pools,p,budget)
	var branches: Array = []
	for target in targets:
		if int(budget[0]) <= 0 or Cancellation.requested(p): break
		budget[0] -= 1
		var next := Env.copy(state)
		var remaining := pools.duplicate(true)
		if not next.apply_attack(attacker,target,remaining).get("ok",false): continue
		next.check_victory()
		var outcome := _finish_attack(Env.copy(next),attacker,remaining.duplicate(true),p,policy)
		branches.append({"state":next,"pools":remaining,"target":target,"outcome":outcome})
		if float(outcome["score"]) > float(best["score"]):
			best = {"target":target,"targets":[target.duplicate(true)]+outcome["targets"],"score":outcome["score"]}
	for branch in branches:
		if int(budget[0]) <= 0 or Cancellation.requested(p): break
		var outcome := _attack_sequence(branch["state"],attacker,branch["pools"],p,budget,depth-1,branch["outcome"])
		if float(outcome["score"]) > float(best["score"]):
			best = {"target":branch["target"],"targets":[branch["target"].duplicate(true)]+outcome["targets"],"score":outcome["score"]}
	return best

static func _interrupted_resolution(leaf: GameState, evaluations: int, limited: bool, rescue_complete: bool) -> Dictionary:
	return {"state":leaf,"score":null,"evaluations":evaluations,"responses":[],"complete":false,
		"interrupted":true,"coverage_limited":limited,"rescue_complete":rescue_complete}
