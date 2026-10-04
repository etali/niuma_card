# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIActions
extends RefCounted

const Cancellation = preload("res://engine/ai_cancellation.gd")

const Env = preload("res://engine/ai_environment.gd")
const Eval = preload("res://engine/ai_evaluation.gd")
const Capabilities = preload("res://engine/ai_capabilities.gd")
const Context = preload("res://engine/ai_context.gd")
const WORK_COUNTERS := ["_work","_generation_work","_stage_work"]

## 宏动作生成器。返回 {state,intents,rank}；state 只属于搜索，真实局面仅重放 intents。
static func generate(state: GameState, who: String, profile: Dictionary) -> Array:
	return generate_with_status(state,who,profile)["nodes"]

## 基础运营先形成完整方案，再用余下额度扩展融资、防御与材料分配。
## 基础与扩展共用买卖、编组及评分入口；基础方案不再参加扩展池的截断。
## complete 表示本次预定的有限扩展未被额度打断，不表示穷举了合法动作。
static func generate_with_status(state: GameState, who: String, profile: Dictionary) -> Dictionary:
	# 浅拷贝隔离局部评分快照，规则缓存和展开额度仍与整个搜索共享。
	profile = profile.duplicate()
	profile.erase("_generation_limited")
	if int(profile.get("generation_budget",0)) > 0:
		profile["_generation_work"] = [int(profile["generation_budget"])]
	if not profile.has("_context"):
		profile["_context"] = Context.new()
	var immediate := winning_pawn(state, who, profile["_context"])
	if not immediate.is_empty():
		var won := Env.copy(state)
		Env.replay(won, immediate)
		var node := {"state":won,"intents":immediate,"rank":Eval.TERMINAL_SCORE,"baseline":true,"generation_stage":0}
		return {"nodes":[node],"baseline":[node],"complete":true,"baseline_complete":true,
			"rescue":[],"rescue_complete":true,"rescue_work":0}
	var expanded := false
	for key in ["financing_mode","resale_mode","allocation_mode","formation_mode","candidate_dedup","tactical_extension"]:
		expanded = expanded or int(profile.get(key,0)) > 0
	var basic := profile.duplicate()
	if expanded:
		# 同一基础搜索在不同调用中仍遵守更小的回应/前推宽度。
		var widths := {"buy_beam":12,"build_beam":8,"plans":16}
		for key in widths: basic[key] = mini(int(basic[key]),int(widths[key]))
		for key in ["financing_mode","resale_mode","allocation_mode","formation_mode","candidate_dedup","tactical_extension"]:
			basic[key] = 0
	# 先完成原持牌运营，避免交易耗尽额度或静态排序把停购路线挤出最终池。
	var initial := {"state":Env.copy(state),"intents":[],"rank":_score(state,who,basic)}
	var operating := _build(initial,who,basic)
	var protected := operating.duplicate()
	if _payable_plan(initial["state"],who): protected.append(initial)
	var baseline := _generate_candidates(state,who,basic,operating)
	var baseline_complete := not exhausted(basic)
	# 保护只决定是否参与比较，不改变分数；优先评价原持牌路线后再评价交易。
	protected = _retain_nodes(baseline,protected)
	baseline = protected + baseline.filter(func(n):return not protected.has(n))
	for node in baseline:
		node["baseline"] = true
		node["generation_stage"] = 0
	if not expanded or not baseline_complete:
		return {"nodes":baseline,"baseline":baseline,"complete":baseline_complete,"baseline_complete":baseline_complete,
			"rescue":[],"rescue_complete":baseline_complete or int(profile.get("tactical_extension",0)) == 0,"rescue_work":0}
	# 普通基础先完成，再为市场阻断或现金缓冲预留有限单步交易。
	# 后备不进入普通排名；搜索仅在普通方案均判败时按相同规格补评。
	var rescue := _rescue_transactions(state,who,profile) if int(profile.get("tactical_extension",0)) > 0 else {"nodes":[],"complete":true,"work":0}
	# 逐级扩展复用同一生成器；更大的融资空间不能挤掉较小空间已形成的路线。
	# 各层共享总额度和规则缓存，只对整条合法方案按语义去重。
	var modes: Array = [int(profile.get("financing_mode",0))]
	if modes[0] > 1: modes.push_front(1)
	var nodes: Array = []
	baseline = _retain_nodes(nodes,baseline)
	var stages: Array = []
	var complete := true
	var stage_index := 0
	for mode in modes:
		stage_index += 1
		var stage := profile.duplicate()
		stage["financing_mode"] = mode
		stage.erase("_generation_limited")
		stage["_generation_holdings"] = 0
		stage["_generation_tactical_candidates"] = 0
		var before := remaining_work(stage)
		var expanded_nodes := _generate_candidates(state,who,stage) if not exhausted(stage) else []
		for node in expanded_nodes: node["generation_stage"] = stage_index
		var stage_complete: bool = not exhausted(stage) and not stage.get("_generation_limited",false)
		stages.append({"stage":stage_index,"financing_mode":mode,"complete":stage_complete,"candidates":expanded_nodes.size(),
			"work":maxi(0,before-remaining_work(stage)),"holdings":int(stage["_generation_holdings"]),
			"tactical_candidates":int(stage["_generation_tactical_candidates"])})
		complete = complete and stage_complete
		# 保留先完成层的顺序，有限评价额度也应先比较它们。
		_retain_nodes(nodes,expanded_nodes)
	return {"nodes":nodes,"baseline":baseline,"complete":complete,"baseline_complete":true,
		"generation_stages":stages,"rescue":rescue["nodes"],"rescue_complete":rescue["complete"],"rescue_work":rescue["work"]}

## 基于原局面的一次购买或单卡种一张典当，不展开完整交易树或重复编组。
## 每条尝试照常扣共享额度；付款与能否结束行动均由正式规则验证。
static func _rescue_transactions(state: GameState, who: String, profile: Dictionary) -> Dictionary:
	if state.winner != "": return {"nodes":[],"complete":true,"work":0}
	var choices: Array = []
	var market_seen := {}
	for index in state.market.size():
		var id := str(state.market[index])
		if market_seen.has(id): continue
		market_seen[id] = true
		choices.append({"key":"buy:"+semantic_key(id,profile.get("_context")),"intent":Intent.buy(who,index)})
	var sales := {}
	for card in state.players[who]["cards"]:
		var id := str(card["def_id"])
		var d := CardDB.get_def(id)
		if d.get("kind") == CardDB.KIND_UNIT and d.get("res") == CardDB.RES_CASH: continue
		if CardDB.pawn_value(id) <= 0: continue
		# 同种牌优先出售未入组的一张；只有已入组牌时仍交给真实裁决。
		if not sales.has(id) or (sales[id].get("locked",false) and not card.get("locked",false)):
			sales[id] = card
	for id in sales:
		choices.append({"key":"pawn:"+semantic_key(id,profile.get("_context")),"intent":Intent.pawn(who,[sales[id]["uid"]])})
	choices.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return a["key"]<b["key"])
	var out: Array = []
	var work := 0
	for choice in choices:
		if not spend(profile): return {"nodes":out,"complete":false,"work":work}
		work += 1
		var next := Env.copy(state)
		var intents: Array = [choice["intent"]]
		if not Env.replay(next,intents) or not _payable_plan(next,who): continue
		var node := {"state":next,"intents":intents,"rank":_score(next,who,profile),
			"generation_stage":1,"baseline":false}
		_retain_nodes(out,[node])
	return {"nodes":out,"complete":true,"work":work}

## 合并时保留池引用最终节点；相同局面不会因不同 UID 或行动前缀重复评价。
static func _retain_nodes(nodes: Array, retained: Array) -> Array:
	var seen := {}
	for node in nodes:
		if not node.has("_signature"): node["_signature"] = Capabilities.signature(node["state"])
		if not seen.has(node["_signature"]): seen[node["_signature"]] = node
	var out: Array = []
	var added := {}
	for node in retained:
		if not node.has("_signature"): node["_signature"] = Capabilities.signature(node["state"])
		var key: String = node["_signature"]
		if added.has(key): continue
		added[key] = true
		if not seen.has(key):
			nodes.append(node)
			seen[key] = node
		out.append(seen[key])
	return out

static func _generate_candidates(state: GameState, who: String, profile: Dictionary, operating: Array = []) -> Array:
	profile["_generation_holdings"] = 0
	profile["_generation_tactical_candidates"] = 0
	var trading := profile
	if int(profile.get("financing_mode",0)) > 0 or int(profile.get("resale_mode",0)) > 0:
		var available := remaining_work(profile)
		if available >= 0:
			# 扩展交易至多先用一半；剩余额度交给同一编组器形成可运营方案。
			# 只增加阶段上限，原生成与搜索总账仍逐次共同扣费。
			trading = profile.duplicate()
			trading["_stage_work"] = [available / 2]
	var holdings := Capabilities.purchases(state, who, trading) if int(profile.get("financing_mode",0)) > 0 else _purchases(state, who, trading)
	if int(profile.get("financing_mode",0)) == 0 and int(profile.get("resale_mode",0)) > 0:
		holdings.append_array(Capabilities.resale_transactions(holdings.duplicate(),who,trading))
	if trading.has("_stage_work") and int(trading["_stage_work"][0]) <= 0:
		profile["_generation_limited"] = true
	var out: Array = []
	for node in holdings:
		if exhausted(profile) and not out.is_empty(): break
		profile["_generation_holdings"] += 1
		out.append_array(operating if node["intents"].is_empty() and not operating.is_empty() else _build(node, who, profile))
	var selected: Array
	if int(profile.get("candidate_dedup",0)) > 0:
		selected = Capabilities.select(out,int(profile["plans"]),who,"rank",true,profile)
	else:
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return Capabilities.compare_nodes(a,b,who,"rank",profile))
		selected = out.slice(0, mini(int(profile["plans"]), out.size()))
	if int(profile.get("tactical_extension",0)) > 0:
		# 静态生产分不能独占最终池。保留实际可支付的两类攻击各一个，
		# 是否致胜仍由同一真实回应结算判断，不在这里增加分数或标记终局。
		var attacks := {}
		for node in out:
			var pools := attack_pools(node,who)
			for res in pools:
				if int(pools[res]) <= 0: continue
				if not attacks.has(res) or int(pools[res]) > int(attack_pools(attacks[res],who)[res]) \
						or (int(pools[res]) == int(attack_pools(attacks[res],who)[res]) and Capabilities.compare_nodes(node,attacks[res],who,"rank",profile)):
					attacks[res] = node
		var ordinary_size := selected.size()
		_retain_nodes(selected,attacks.values())
		profile["_generation_tactical_candidates"] = selected.size()-ordinary_size
	return selected

## 完整节点不可变；真实装弹包含付款顺序和现金归零保护。
static func attack_pools(node: Dictionary, who: String) -> Dictionary:
	if node.has("_attack_pools") and node["_attack_pools"]["who"] == who:
		return node["_attack_pools"]["pools"]
	var pools := {CardDB.RES_CASH:0,CardDB.RES_USER:0}
	for combo in node["state"].combos:
		if combo["owner"] == who and combo["eval"].get("type") == "attack":
			pools = Env.copy(node["state"]).arm_attacks(who)
			break
	node["_attack_pools"] = {"who":who,"pools":pools}
	return pools

## 确定冲线覆盖全部可典当非现金牌，保证至少保留一用户；由环境复核。
static func winning_pawn(state: GameState, who: String, context = null) -> Array:
	var cash := state.resource_count(who, CardDB.RES_CASH)
	var threshold := int(CardDB.game_rules()["win_cash"])
	if cash >= threshold:
		return []
	var cards: Array = []
	var users_left := state.resource_count(who, CardDB.RES_USER)
	for c in state.players[who]["cards"]:
		if bool(c.get("locked", false)):
			continue
		var price: int = context.pawn_value(str(c["def_id"])) if context != null else CardDB.pawn_value(str(c["def_id"]))
		if price > 0:
			cards.append({"c": c, "price": price})
	cards.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["price"] > b["price"])
	var uids: Array = []
	for item in cards:
		var c: Dictionary = item["c"]
		var d := CardDB.get_def(str(c["def_id"]))
		if d.get("kind") == CardDB.KIND_UNIT and d.get("res") == CardDB.RES_USER:
			if users_left <= 1:
				continue
			users_left -= 1
		uids.append(int(c["uid"]))
		cash += int(item["price"])
		if cash >= threshold:
			return [Intent.pawn(who, uids)]
	return []

static func _purchases(state: GameState, who: String, profile: Dictionary) -> Array:
	var sources: Array = [{"state": Env.copy(state), "intents": [], "rank": _score(state, who, profile)}]
	# 有限单卡变现候选，按变现后的能力变化排序，不设旧版救急阈值。
	var sales: Array = []
	var seen_sales := {}
	for card in state.players[who]["cards"] if int(profile["sales"]) > 0 else []:
		if not spend(profile):
			break
		var id := str(card["def_id"])
		if bool(card.get("locked", false)) or seen_sales.has(id) or profile["_context"].pawn_value(id) <= 0:
			continue
		seen_sales[id] = true
		var s := Env.copy(state)
		var intent := Intent.pawn(who, [card["uid"]])
		if Env.replay(s, [intent]):
			sales.append({"state": s, "intents": [intent], "rank": _score(s, who, profile)})
	sales.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["rank"] > b["rank"])
	sources.append_array(sales.slice(0, mini(int(profile["sales"]), sales.size())))
	var beam := sources
	# 按卡牌语义固定遍历次序，展示顺序/ID重命名不能改变有损截断顺序。
	var slots: Array = []
	for idx in state.market.size():
		slots.append({"index": idx, "key": semantic_key(str(state.market[idx]), profile["_context"])})
	slots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["key"] < b["key"])
	for slot in slots:
		if exhausted(profile):
			break
		var next: Array = []
		for node in beam:
			next.append(node)
			if not spend(profile):
				continue
			var src: GameState = node["state"]
			var s := Env.copy(src)
			var original_idx := int(slot["index"])
			var bought_slots: Array = node.get("slots", []).duplicate()
			var actual_idx := original_idx
			for bought_idx in bought_slots:
				if int(bought_idx) < original_idx:
					actual_idx -= 1
			var intent := Intent.buy(who, actual_idx)
			if not Env.replay(s, [intent]):
				continue
			var intents: Array = node["intents"].duplicate()
			intents.append(intent)
			bought_slots.append(original_idx)
			next.append({"state": s, "intents": intents, "rank": _score(s, who, profile), "slots": bought_slots})
		next.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["rank"] > b["rank"])
		beam = Capabilities._select_holdings(next,int(profile["buy_beam"]),who,profile) if int(profile.get("tactical_extension",0)) > 0 or int(profile.get("formation_mode",0)) > 0 else next.slice(0, mini(int(profile["buy_beam"]), next.size()))
	# 停购永远存在；截断后仍保留，可防止购买排序把保守路线删除。
	beam.append(sources[0])
	var dedup: Array = []
	var seen := {}
	for n in beam:
		var key := str(n["intents"])
		if not seen.has(key):
			seen[key] = true
			dedup.append(n)
	return dedup

static func _build(start: Dictionary, who: String, profile: Dictionary) -> Array:
	var initial: GameState = start["state"]
	var cores: Array = []
	for c in initial.players[who]["cards"]:
		var d := CardDB.get_def(str(c["def_id"]))
		if not bool(c.get("locked", false)) and d.get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND]:
			cores.append(c)
	cores.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var av := _core_priority(a)
		var bv := _core_priority(b)
		return av > bv if not is_equal_approx(av, bv) else semantic_key(str(a["def_id"]), profile["_context"]) < semantic_key(str(b["def_id"]), profile["_context"]))
	var beam: Array = [{"state": initial, "intents": start["intents"], "merit": 0.0}]
	var processed := {}
	for core in cores:
		if exhausted(profile):
			break
		var next: Array = []
		for node in beam:
			next.append(node) # 不编这个核心也是候选。
			var s: GameState = node["state"]
			var live := s.find_card(who, int(core["uid"]))
			if live.is_empty() or bool(live.get("locked", false)):
				continue
			for option in _core_options(s, who, live, processed, profile):
				if not spend(profile):
					break
				var ns := Env.copy(s)
				var intent := Intent.create_combo(who, option["uids"])
				if not Env.replay(ns, [intent]):
					continue
				var intents: Array = node["intents"].duplicate()
				intents.append(intent)
				next.append({"state": ns, "intents": intents,
					"merit": float(node["merit"]) + float(option["merit"])})
		next.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return Capabilities.compare_nodes(a,b,who,"merit",profile))
		beam = Capabilities.select(next,int(profile["build_beam"]),who,"merit",true,profile) if int(profile.get("candidate_dedup",0)) > 0 else next.slice(0, mini(int(profile["build_beam"]), next.size()))
		processed[int(core["uid"])] = true
	var out: Array = []
	for node in beam:
		var s: GameState = node["state"]
		# 只在整个编组方案形成后检查付款：后访问的收入组合也可能先结算。
		# 与玩家完成行动共用真实结算预演，不在搜索里复制现金余额公式。
		if not _payable_plan(s, who):
			continue
		out.append({"state": s, "intents": node["intents"],
			"rank": _score(s, who, profile) + float(node["merit"]) / maxf(1, CardDB.game_rules()["win_cash"])})
	if out.is_empty() and _payable_plan(initial,who):
		# 有限 beam 可能只剩不可支付的组合；停编仍保留买卖后的合法局面。
		out.append({"state": initial, "intents": start["intents"], "rank": _score(initial, who, profile)})
	return out

static func _payable_plan(state: GameState, who: String) -> bool:
	var piles: Array = []
	var has_payment := false
	for combo in state.combos:
		if combo["owner"] == who:
			piles.append(combo)
			has_payment = has_payment or int(combo["eval"].get("recipe_pay_n", 0)) > 0
	return not has_payment or bool(Settle.check_action_completion(state, who, piles)["ok"])

static func _score(state: GameState, who: String, profile: Dictionary) -> float:
	# 威胁估值依赖双方持牌；自己买卖攻击牌后不能沿用旧的对方特征。
	return Eval.score(state, who, profile)

static func _core_priority(c: Dictionary) -> float:
	var d := CardDB.get_def(str(c["def_id"]))
	return float(d.get("output_n", d.get("attack_n", 0))) / maxf(1, d.get("recipe_n", 0))

static func _core_options(state: GameState, who: String, core: Dictionary, processed: Dictionary,
		profile: Dictionary = {}) -> Array:
	var parameters := profile if profile.has("protection_bonus") else AISearch.from_model("ai", 0.0).resolved_parameters()
	var context = parameters.get("_context")
	if context == null:
		context = Context.new()
	parameters = parameters.duplicate()
	parameters["_context"] = context
	var id := str(core["def_id"])
	var d := CardDB.get_def(id)
	var same: Array = [int(core["uid"])]
	var peers: Array = []
	for c in state.players[who]["cards"]:
		if bool(c.get("locked", false)):
			continue
		var cd := CardDB.get_def(str(c["def_id"]))
		if str(c["def_id"]) == id and int(c["uid"]) != int(core["uid"]) and not processed.has(int(c["uid"])):
			same.append(int(c["uid"]))
		if cd.get("kind") == CardDB.KIND_PRODUCT and cd.get("tier") == d.get("tier") \
				and int(c["uid"]) != int(core["uid"]) and not processed.has(int(c["uid"])):
			peers.append(c)
	var out: Array = []
	var upgrade_seen := {}
	for n in range(2, mini(same.size(), context.max_upgrade_n()) + 1):
		var target: String = context.upgrade_target(id, n)
		if target != "":
			_append_upgrade(out, upgrade_seen, state, who, same.slice(0, n), target, context)
	if d.get("kind") == CardDB.KIND_PRODUCT and int(d.get("tier", 0)) in [1, 2]:
		# 每档材料数至多两个选择：少牺牲出售价值，或少牺牲生产能力。
		# 核心仍是当前遍历的锚点；已处理/已锁定的牌不能再投入另一组。
		for preserve_engine in [false, true]:
			peers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var av := _core_priority(a) if preserve_engine else float(context.pawn_value(str(a["def_id"])))
				var bv := _core_priority(b) if preserve_engine else float(context.pawn_value(str(b["def_id"])))
				if av != bv: return av < bv
				var ak: String = context.semantic_key(str(a["def_id"]))
				var bk: String = context.semantic_key(str(b["def_id"]))
				return int(a["uid"]) < int(b["uid"]) if ak == bk else ak < bk)
			for n in range(2, mini(peers.size() + 1, context.max_upgrade_n()) + 1):
				var target: String = context.legend_upgrade_target(int(d["tier"]), n)
				if target == "": continue
				var uids: Array = [int(core["uid"])]
				for peer in peers.slice(0, n - 1): uids.append(int(peer["uid"]))
				_append_upgrade(out, upgrade_seen, state, who, uids, target, context)
	if int(profile.get("allocation_mode",0)) > 0:
		for uids in Capabilities.allocations(state,who,core,peers,parameters):
			var ids: Array = []
			for uid in uids: ids.append(str(state.find_card(who,uid)["def_id"]))
			var target := ComboRules.upgrade_target_for_ids(ids)
			if target != "": _append_upgrade(out,upgrade_seen,state,who,uids,target,context)
	out.append_array(recipe_options(state,who,core,parameters))
	if int(profile.get("formation_mode",0)) > 0:
		out.append_array(Capabilities.formations(state,who,out,parameters))
	return out

## 常规配方与 Buff 的共享枚举；持牌能力摘要复用它，不另写攻击/护盾配方。
static func recipe_options(state: GameState, who: String, core: Dictionary, parameters: Dictionary) -> Array:
	var d := CardDB.get_def(str(core["def_id"]))
	var units: Array = []
	var buffs := {}
	for c in state.players[who]["cards"]:
		if bool(c.get("locked",false)): continue
		var cd := CardDB.get_def(str(c["def_id"]))
		if cd.get("kind") == CardDB.KIND_UNIT and cd.get("res") == d.get("recipe_res"):
			units.append(int(c["uid"]))
		if cd.get("kind") == CardDB.KIND_BUFF:
			var bt := str(cd.get("buff_type",""))
			if not buffs.has(bt): buffs[bt] = []
			buffs[bt].append(int(c["uid"]))
	var out: Array = []
	var need := int(d.get("recipe_n", 0))
	var enhancement := "output_x2" if d.get("kind") == CardDB.KIND_PRODUCT else "attack_x2"
	var protection := CardDB.protect_key(str(d.get("recipe_res", "")))
	var seen := {}
	for use_fill in [false, true]:
		if use_fill and (not buffs.has("user_fill") or d.get("recipe_res") != CardDB.RES_USER or need <= 1):
			continue
		var required := 1 if use_fill else need
		if units.size() < required:
			continue
		# 同类型 Buff 只枚举使用张数，不枚举等价 UID 子集；n 张只有 n+1 条路线。
		for enhancement_count in range(buffs.get(enhancement, []).size() + 1):
			for protected in [false, true]:
				if protected and not buffs.has(protection):
					continue
				var ids: Array = [int(core["uid"])] + units.slice(0, required)
				if use_fill:
					ids.append(buffs["user_fill"][0])
				if enhancement_count > 0:
					ids.append_array(buffs[enhancement].slice(0, enhancement_count))
				if protected:
					ids.append(buffs[protection][0])
				if seen.has(str(ids)):
					continue
				seen[str(ids)] = true
				var cards: Array = []
				for uid in ids:
					cards.append(state.find_card(who, uid))
				var ev := ComboRules.evaluate(cards)
				if not bool(ev.get("valid", false)):
					continue
				var pay := int(ev.get("recipe_pay_n", 0))
				var merit := _combo_value(state, who, ev) - pay
				if protected:
					merit *= 1.0 + float(parameters["protection_bonus"])
				out.append({"uids": ids, "merit": merit})
	return out

static func _append_upgrade(out: Array, seen: Dictionary, state: GameState, who: String,
		uids: Array, target: String, context: Context) -> void:
	var ids: Array = []
	for uid in uids:
		ids.append(str(state.find_card(who, int(uid))["def_id"]))
	# 最终目标仍由真实材料决定，同名普通升级的路线优先级不能被池化候选覆盖。
	if ComboRules.upgrade_target_for_ids(ids) != target: return
	var ordered := uids.duplicate()
	ordered.sort()
	var key := str(ordered)
	if seen.has(key): return
	seen[key] = true
	var gain := float(context.pawn_value(target))
	for uid in uids:
		gain -= context.pawn_value(str(state.find_card(who, int(uid))["def_id"]))
	var d := CardDB.get_def(target)
	if d.get("kind") == CardDB.KIND_PRODUCT:
		gain += float(d.get("output_n", 0))
	out.append({"uids": uids, "merit": gain})

static func _combo_value(state: GameState, who: String, ev: Dictionary) -> float:
	if ev["type"] == "attack":
		var opp := GameState.opponent(who)
		var damage := floorf(float(ev["attack_n"]) / maxf(1, CardDB.game_rules()["attack_cost_per_card"]))
		var amount := minf(damage, state.resource_count(opp, str(ev["attack_res"])))
		var shadow := Eval.user_price(state, opp) if ev["attack_res"] == CardDB.RES_USER else 1.0
		return amount * shadow
	var output := float(ev["output_n"])
	if ev["output_res"] == CardDB.RES_CASH:
		return output
	# 与保有产能估值共用真实典当底价；用户增加不能反向压低同一产出的价值。
	return output * CardDB.pawn_user()


static func semantic_key(id: String, context = null) -> String:
	var rules = context if context != null else Context.new()
	return rules.semantic_key(id)


## 节点额度由搜索上下文共享；单独调用生成器可不带额度。
static func spend(profile: Dictionary) -> bool:
	if exhausted(profile): return false
	for key in WORK_COUNTERS:
		if profile.has(key): profile[key][0] -= 1
	return true

static func exhausted(profile: Dictionary) -> bool:
	return Cancellation.requested(profile) or remaining_work(profile) == 0

## 无计数器表示调用方未设额度；阶段额度只缩小可用工作，不增加总额。
static func remaining_work(profile: Dictionary) -> int:
	var remaining := -1
	for key in WORK_COUNTERS:
		if profile.has(key):
			var value := maxi(0,int(profile[key][0]))
			remaining = value if remaining < 0 else mini(remaining,value)
	return remaining
