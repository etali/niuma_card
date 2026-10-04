# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 可选动作能力；关闭时不进入这些分支，旧候选次序/评分/额度原样保留。
## 搜索额度只截断探索，不改变任何游戏规则。所有变更经 IntentApply 复核。
const Work = preload("res://engine/ai_work_budget.gd")
const Cancellation = preload("res://engine/ai_cancellation.gd")
const Env = preload("res://engine/ai_environment.gd")
const Eval = preload("res://engine/ai_evaluation.gd")

static func signature(s: GameState) -> String:
	var seats := {}
	for who in s.players:
		var counts := {}
		for c in s.players[who]["cards"]:
			var k := str([c["def_id"],c.get("locked",false),c.get("fired_round",-1),c.get("worked_round",-1)])
			counts[k] = int(counts.get(k, 0)) + 1
		var combos: Array = []
		for combo in s.combos:
			if combo["owner"] != who: continue
			var cards: Array = []
			for uid in combo["uids"]:
				var c: Dictionary = s.find_card(who, int(uid)).duplicate()
				c.erase("uid")
				cards.append(c)
			# 组合内部顺序影响保护额度，不能排序掉。组合顺序影响付款，也保留。
			combos.append({"cards":cards,"eval":combo["eval"]})
		seats[who] = {"cards":counts,"combos":combos}
	var market := s.market.duplicate()
	market.sort()
	return StateCodec.canon({"players":seats,"market":market,"winner":s.winner,
		"round":s.round_num,"first":s.draw_first})

## 只在防御布局能力开启时给严格同分的方案确定的简洁偏好。
## 关闭能力仍用原比较器，不能改变默认强度的候选次序。
static func compare_nodes(a: Dictionary, b: Dictionary, who: String, field: String, p: Dictionary) -> bool:
	if a[field] != b[field]: return a[field] > b[field]
	if int(p.get("formation_mode",0)) == 0: return false
	var left: Dictionary = a.get("node",a)
	var right: Dictionary = b.get("node",b)
	var ac := _node_complexity(left,who)
	var bc := _node_complexity(right,who)
	if ac[0] != bc[0]: return ac[0] < bc[0]
	if ac[1] != bc[1]: return ac[1] < bc[1]
	return _node_intent_key(left) < _node_intent_key(right)

static func _node_intent_key(node: Dictionary) -> String:
	if not node.has("_formation_intent_key"):
		node["_formation_intent_key"] = StateCodec.canon(node.get("intents",[]))
	return node["_formation_intent_key"]

static func _node_complexity(node: Dictionary, who: String) -> Array:
	if node.has("_formation_complexity"): return node["_formation_complexity"]
	var extra := 0
	var units := 0
	var state: GameState = node["state"]
	for combo in state.combos:
		if combo["owner"] != who: continue
		var counts := _unit_complexity(state.combo_survivors(who,combo),combo["eval"])
		extra += counts[0]
		units += counts[1]
	node["_formation_complexity"] = [extra,units]
	return node["_formation_complexity"]

static func _unit_complexity(cards: Array, ev: Dictionary) -> Array:
	var units := 0
	var recipe_units := 0
	for c in cards:
		var d := CardDB.get_def(c["def_id"])
		if d.get("kind") != CardDB.KIND_UNIT: continue
		units += 1
		if d.get("res") == ev.get("recipe_res"): recipe_units += 1
	var required := mini(recipe_units,_minimum_recipe_cards(cards,ev))
	return [units-required,units]

static func _minimum_recipe_cards(cards: Array, ev: Dictionary) -> int:
	if ev.get("type") == "upgrade": return 0
	if ev.get("recipe_res") == CardDB.RES_USER:
		for c in cards:
			var d := CardDB.get_def(c["def_id"])
			if d.get("kind") == CardDB.KIND_BUFF and d.get("buff_type") == "user_fill": return 1
	return int(CardDB.get_def(ev.get("leader","")).get("recipe_n",0))

static func select(nodes: Array, limit: int, who: String, field := "rank", diverse := false, p: Dictionary = {}) -> Array:
	nodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return compare_nodes(a,b,who,field,p))
	var unique: Array = []
	var seen := {}
	for n in nodes:
		if not n.has("_signature"): n["_signature"] = signature(n["state"])
		var k: String = n["_signature"]
		if seen.has(k): continue
		seen[k] = true
		unique.append(n)
	if not diverse: return unique.slice(0, limit)
	if int(p.get("formation_mode",0)) > 0:
		return _select_defensive(unique,limit,who,field,p)
	# 以可用生产材料数量分道，避免融资买材料的中间步骤被成熟引擎挤光。
	var out: Array = []
	var lanes := {}
	var rest: Array = []
	for n in unique:
		var lane := _strategy_lane(n["state"],who)
		if lanes.has(lane): rest.append(n)
		else:
			lanes[lane] = true
			out.append(n)
	out.append_array(rest)
	return out.slice(0,limit)

static func _strategy_lane(s: GameState, who: String) -> String:
	var tiers := {}
	for c in s.players[who]["cards"]:
		var d := CardDB.get_def(c["def_id"])
		if d.get("kind") == CardDB.KIND_PRODUCT and not c.get("locked",false):
			var tier := str(d.get("tier",0))
			tiers[tier] = int(tiers.get(tier,0))+1
	var goals: Array = []
	for combo in s.combos:
		if combo["owner"] == who:
			goals.append([combo["eval"]["type"],combo["eval"].get("output_card",""),combo["eval"].get("leader","")])
	return StateCodec.canon([tiers,goals])

## 每条生产/升级路线交错保留最高分与防御代表，再填其余不同防御形态。
## 不能让一长串静态产出较高、实际会被拆掉的中间阵型占满所有名额。
## 防御代表只是探索保留策略，不修改 rank/merit，也不作为结算后的评价分。
static func _select_defensive(nodes: Array, limit: int, who: String, field: String, p: Dictionary) -> Array:
	var groups := {}
	var core_defenders := {"recipe":{},"batch":{}}
	var metadata := {}
	for n in nodes:
		var data := _node_formation_data(n,who)
		var lane: String = data["lane"]
		if not groups.has(lane): groups[lane] = {"best":n,"defenders":{}}
		# 同一摘要的两种探索目的：最简抗拆优先，跨资源 batch 另留代表，不能互相顶掉。
		for purpose in ["recipe","batch"]:
			var field_key := "priority" if purpose == "recipe" else "batch_priority"
			var priority: Array = data[field_key]
			if not priority.is_empty():
				_retain_defender(groups[lane]["defenders"],purpose,n,priority,who,field,p)
			for core in data["cores"]:
				var local_priority: Array = core[field_key]
				if not local_priority.is_empty():
					_retain_defender(core_defenders[purpose],core["key"],n,local_priority,who,field,p)
		metadata[n["_signature"]] = data["shape"]
	var out: Array = []
	var used := {}
	var shapes := {}
	# 买卖路径会产生许多相同核心的生产目标组合。先为真正不同的核心防御
	# 留代表，不能让它再次被这些完整方案分道挤出最终根预算。
	var priority_nodes: Array = nodes.slice(0,1)
	for purpose in ["recipe","batch"]:
		var defenders: Array = []
		for core_key in core_defenders[purpose]:
			var defender: Dictionary = core_defenders[purpose][core_key]
			if purpose == "batch" or int(defender["priority"][0]) > 0 or _priority_greater(defender["priority"],defender["baseline"]):
				defenders.append(defender)
		# 不同核心也使用同一防御摘要比较：能够保住配方的代表先于仅多扛
		# 几次、仍会被拆掉的代表。同防御效果再沿用原评分与简洁次序。
		defenders.sort_custom(func(a: Dictionary,b: Dictionary)->bool:
			if a["priority"] != b["priority"]: return _priority_greater(a["priority"],b["priority"])
			return compare_nodes(a["node"],b["node"],who,field,p))
		for defender in defenders: priority_nodes.append(defender["node"])
	for node in priority_nodes:
		if used.has(node["_signature"]): continue
		out.append(node)
		used[node["_signature"]] = true
		shapes[metadata[node["_signature"]]] = true
	for lane in groups:
		var representatives: Array = [groups[lane]["best"]]
		for purpose in ["recipe","batch"]:
			if groups[lane]["defenders"].has(purpose): representatives.append(groups[lane]["defenders"][purpose]["node"])
		for node in representatives:
			if used.has(node["_signature"]): continue
			out.append(node)
			used[node["_signature"]] = true
			shapes[metadata[node["_signature"]]] = true
	var rest: Array = []
	for n in nodes:
		if used.has(n["_signature"]): continue
		var shape: String = metadata[n["_signature"]]
		if shapes.has(shape): rest.append(n)
		else:
			shapes[shape] = true
			out.append(n)
	out.append_array(rest)
	return out.slice(0,limit)

## 两种保留目的共用更新逻辑；只是选择探索代表，绝不修改原 rank/merit。
static func _retain_defender(representatives: Dictionary, key: String, node: Dictionary, priority: Array,
		who: String, field: String, p: Dictionary) -> void:
	if not representatives.has(key):
		representatives[key] = {"node":node,"priority":priority,"baseline":priority}
		return
	var old: Dictionary = representatives[key]
	if _priority_greater(priority,old["priority"]) or (priority == old["priority"] and compare_nodes(node,old["node"],who,field,p)):
		old["node"] = node
		old["priority"] = priority

## 与 _signature 一样，仅缓存不可变搜索节点的派生数据；评分字段不参与缓存。
## 同一节点跨编组阶段复用，避免重复扫描卡牌、装弹副本与序列化。
static func _node_formation_data(node: Dictionary, who: String) -> Dictionary:
	if node.has("_formation_data") and node["_formation_data"]["who"] == who:
		return node["_formation_data"]
	var state: GameState = node["state"]
	var lane := _strategy_lane(state,who)
	var combos: Array = []
	var needs_threats := false
	for combo in state.combos:
		if combo["owner"] != who: continue
		combos.append(combo)
		needs_threats = needs_threats or combo["eval"].get("type") != "upgrade"
	# 购牌/典当中间节点通常还没有组合，升级组也没有防御摘要。
	var threats := formation_threats(state,who) if needs_threats else {CardDB.RES_CASH:0,CardDB.RES_USER:0}
	var defense: Array = []
	var priority := [0,0]
	var absorption := 0
	var has_cross_resource := false
	var cores: Array = []
	for combo in combos:
		var shape: Array = []
		if combo["eval"].get("type") != "upgrade" and (int(threats[CardDB.RES_CASH]) > 0 or int(threats[CardDB.RES_USER]) > 0):
			shape = _defense_summary(state.combo_survivors(who,combo),combo["eval"],threats)
		defense.append(shape)
		# 可攻击的额外资源只区分 batch 形态，不代表收益：资源留作散牌也会吸收攻击。
		# 抗拆代表只比较配方存活；相同抗性沿用原分数与简洁次序。
		var local_priority := [0,0]
		var local_absorption := 0
		var cross_resource := false
		for row in shape:
			if row[0] == combo["eval"].get("recipe_res"):
				local_priority[0] += 1 if int(row[1]) > int(threats[row[0]]) else 0
				local_priority[1] += int(row[1])
			elif int(row[2]) > 0 and int(threats.get(combo["eval"].get("recipe_res",""),0)) > 0:
				cross_resource = true
			local_absorption += int(row[2])
		for i in priority.size(): priority[i] += local_priority[i]
		absorption += local_absorption
		has_cross_resource = has_cross_resource or cross_resource
		if not shape.is_empty():
			cores.append({"key":StateCodec.canon([combo["eval"]["type"],combo["eval"]["leader"],combo["eval"].get("output_card","")]),
				"priority":local_priority,"batch_priority":local_priority+[local_absorption] if cross_resource else []})
	node["_formation_data"] = {"who":who,"lane":lane,"shape":StateCodec.canon([lane,defense]),"priority":priority,
		"batch_priority":priority+[absorption] if has_cross_resource else [],"cores":cores}
	return node["_formation_data"]

static func _priority_greater(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]: return a[i] > b[i]
	return false

static func purchases(state: GameState, who: String, p: Dictionary) -> Array:
	var cash := state.resource_count(who, CardDB.RES_CASH)
	var sale_groups := {}
	for c in state.players[who]["cards"]:
		var id := str(c["def_id"])
		if c.get("locked",false) or p["_context"].pawn_value(id) <= 0: continue
		if not sale_groups.has(id): sale_groups[id] = []
		sale_groups[id].append(c["uid"])
	var sources: Array = [{"state":Env.copy(state),"intents":[],"rank":Eval.score(state,who,p)}]
	var original: Dictionary = sources[0]
	for id in sale_groups:
		if AIActions.exhausted(p): break
		var ids: Array = sale_groups[id]
		var is_user: bool = CardDB.get_def(id).get("res","") == CardDB.RES_USER
		var max_count := ids.size() - (1 if is_user else 0)
		if int(p.get("financing_mode",0)) == 1 and not is_user: max_count = mini(1,max_count)
		var next: Array = sources.duplicate()
		var bases: Array = sources if int(p.get("financing_mode",0)) == 2 else [original]
		for base in bases:
			for n in range(1,max_count+1):
				if not AIActions.spend(p): break
				var s := Env.copy(base["state"])
				var it := Intent.pawn(who,ids.slice(0,n))
				if Env.replay(s,[it]):
					next.append({"state":s,"intents":base["intents"]+[it],"rank":Eval.score(s,who,p)})
		# 每个融资金额至少先留一个，随后补充同金额不同资产配置。
		next.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return a["rank"]>b["rank"])
		var seen := {}
		var rest: Array = []
		sources = []
		for node in next:
			var amount: int = node["state"].resource_count(who,CardDB.RES_CASH)-cash
			if seen.has(amount): rest.append(node)
			else:
				seen[amount] = true
				sources.append(node)
		sources.append_array(rest)
		sources = sources.slice(0,int(p.get("financing_beam",64)))
	# 融资后停购也是完整的交易选择，不能用空购物篮的前两名代替。
	# 卖出少量资产保留现金缓冲，和继续花掉现金购买，是不同的运营路线。
	var holdings: Array = sources.duplicate()
	if not holdings.has(original): holdings.append(original)
	holdings.append_array(_financed_purchases(sources,who,p))
	if int(p.get("resale_mode",0)) > 0:
		holdings.append_array(resale_transactions(sources,who,p))
	return _select_holdings(holdings,int(p["buy_beam"]),who,p)

## 同一来源的购买子集共享前缀，一次真实 buy 生成一个新子集。
## 每个购物篮按买齐后的状态保留融资代表，不按购前的临时产能裁掉路线。
## 每个来源展开后即可释放前缀；跨来源只保留每篮的有限代表。
static func _financed_purchases(sources: Array, who: String, p: Dictionary) -> Array:
	var baskets := {}
	for source in sources:
		if AIActions.exhausted(p): break
		var frontier: Array = [{"state":source["state"],"intents":source["intents"],"slots":[]}]
		for index in source["state"].market.size():
			var price := int(CardDB.get_def(source["state"].market[index]).get("price",-1))
			if price < 0: continue
			var size := frontier.size()
			for i in size:
				var parent: Dictionary = frontier[i]
				if parent["state"].resource_count(who,CardDB.RES_CASH) <= price: continue
				if not AIActions.spend(p): break
				var s := Env.copy(parent["state"])
				var buy := Intent.buy(who,index-parent["slots"].size())
				if not Env.replay(s,[buy]): continue
				var node := {"state":s,"intents":parent["intents"]+[buy],
					"slots":parent["slots"]+[index],"rank":Eval.score(s,who,p)}
				frontier.append(node)
				var key := StateCodec.canon(node["slots"])
				var alternatives: Array = baskets.get(key,[])
				alternatives.append(node)
				baskets[key] = _select_holdings(alternatives,int(p.get("financing_choices",2)),who,p)
			if AIActions.exhausted(p): break
	var out: Array = []
	for rows in baskets.values(): out.append_array(rows)
	return out

## 持牌相同但现金/用户缓冲不同的方案交错保留；先覆盖可运营的资产配置，
## 再补同配置的资源余量。实际编组与真实对手回应仍由后续搜索比较。
static func _select_holdings(nodes: Array, limit: int, who: String, p: Dictionary) -> Array:
	var unique := select(nodes,nodes.size(),who,"rank",false,p)
	var lanes := {}
	var routes := {}
	var used := {}
	var out: Array = []
	for node in unique:
		# 先保留不同材料规模，不能让许多成熟引擎的换牌变体挤掉融资升级。
		var layout := _holding_lanes(node,who)
		var route: String = layout["route"]
		if not routes.has(route):
			routes[route] = true
			out.append(node)
			used[node["_signature"]] = true
			if out.size() >= limit: break
		var lane: String = layout["operating"]
		if not lanes.has(lane): lanes[lane] = []
		lanes[lane].append(node)
	var depth := 0
	while out.size() < limit:
		var available := false
		for lane in lanes:
			if depth >= lanes[lane].size(): continue
			available = true
			var node: Dictionary = lanes[lane][depth]
			if used.has(node["_signature"]): continue
			out.append(node)
			used[node["_signature"]] = true
			if out.size() >= limit: break
		if not available: break
		depth += 1
	return _retain_tactical_holdings(out,unique,who,p)

## 普通材料分道之外，各资源至多补一个攻击融资与护盾编组代表。
## 先编这些已验证的持牌路线，防止有限编组额度再次被普通分道占满。
static func _retain_tactical_holdings(ordinary: Array, nodes: Array, who: String, p: Dictionary) -> Array:
	if nodes.size() <= ordinary.size() or (int(p.get("tactical_extension",0)) == 0 and int(p.get("formation_mode",0)) == 0):
		return ordinary
	var representatives := {}
	for node in nodes:
		var tactics := _holding_tactics(node,who,p)
		for key in tactics:
			if int(tactics[key]) <= 0: continue
			if not representatives.has(key) or int(tactics[key]) > int(_holding_tactics(representatives[key],who,p)[key]) \
					or (int(tactics[key]) == int(_holding_tactics(representatives[key],who,p)[key]) and compare_nodes(node,representatives[key],who,"rank",p)):
				representatives[key] = node
	var out: Array = []
	AIActions._retain_nodes(out,representatives.values())
	AIActions._retain_nodes(out,ordinary)
	return out

## 缓存不可变交易节点的近端能力。只验证已有攻击核心和匹配盾的常规配方，
## 不为每个购物篮再运行整套编组搜索；后续完整编组仍照常消耗共享展开额度。
static func _holding_tactics(node: Dictionary, who: String, p: Dictionary) -> Dictionary:
	var attack := int(p.get("tactical_extension",0)) > 0
	var guard := int(p.get("formation_mode",0)) > 0
	var key := [who,attack,guard]
	if node.has("_holding_tactics") and node["_holding_tactics"]["key"] == key:
		return node["_holding_tactics"]["values"]
	var values := {"attack_cash":0,"attack_user":0,"guard_cash":0,"guard_user":0}
	var state: GameState = node["state"]
	var shields := {}
	if guard:
		for card in state.players[who]["cards"]:
			if card.get("locked",false): continue
			var d := CardDB.get_def(card["def_id"])
			if d.get("kind") == CardDB.KIND_BUFF: shields[d.get("buff_type","")] = true
	var seen := {}
	for core in state.players[who]["cards"]:
		if core.get("locked",false) or seen.has(core["def_id"]): continue
		seen[core["def_id"]] = true
		var d := CardDB.get_def(core["def_id"])
		var attacks: bool = attack and d.get("kind") == CardDB.KIND_ATTACK
		var protects: bool = guard and d.get("kind") in [CardDB.KIND_PRODUCT,CardDB.KIND_ATTACK] and shields.has(CardDB.protect_key(str(d.get("recipe_res",""))))
		if not attacks and not protects: continue
		for option in AIActions.recipe_options(state,who,core,p):
			if not Work.charge(p,Work.state_cost(state),"tactics"): return values
			var candidate := Env.copy(state)
			if not Env.replay(candidate,[Intent.create_combo(who,option["uids"])]) or not AIActions._payable_plan(candidate,who,p): continue
			var combo: Dictionary = candidate.combos.back()
			if protects:
				for res in [CardDB.RES_CASH,CardDB.RES_USER]:
					values["guard_"+res] = maxi(values["guard_"+res],candidate.protected_uids(who,combo,res).size())
			if attacks:
				var pools := candidate.arm_attacks(who)
				for res in pools: values["attack_"+res] = maxi(values["attack_"+res],int(pools[res]))
	if Cancellation.requested(p): return values
	node["_holding_tactics"] = {"key":key,"values":values}
	return values

## 同一不可变交易节点会在购物篮择源与最终持牌筛选中多次出现。
## 缓存两种分道键，避免每次比较都重扫牌表；状态改变必须创建新节点。
static func _holding_lanes(node: Dictionary, who: String) -> Dictionary:
	if node.has("_holding_lanes") and node["_holding_lanes"]["who"] == who:
		return node["_holding_lanes"]
	var counts := {}
	for card in node["state"].players[who]["cards"]:
		var id := str(card["def_id"])
		if CardDB.get_def(id).get("kind") != CardDB.KIND_UNIT:
			counts[id] = int(counts.get(id,0))+1
	node["_holding_lanes"] = {"who":who,"route":_strategy_lane(node["state"],who),"operating":StateCodec.canon(counts)}
	return node["_holding_lanes"]

## 枚举材料卡种的数量向量，避免把相同 UID 的排列当成新方案。
static func allocations(state: GameState, who: String, core: Dictionary, peers: Array, p: Dictionary) -> Array:
	var groups := {}
	for c in peers:
		if not groups.has(c["def_id"]): groups[c["def_id"]] = []
		groups[c["def_id"]].append(c["uid"])
	var vectors: Array = [[core["uid"]]]
	var limit := int(p.get("allocation_budget",64))
	for id in groups:
		var next: Array = []
		for v in vectors:
			for count in range(mini(groups[id].size(),p["_context"].max_upgrade_n()-v.size())+1):
				if not AIActions.spend(p): return vectors
				next.append(v+groups[id].slice(0,count))
		vectors = next.slice(0,limit)
	return vectors

## 能移除的资源张数。后手只面对已提交的本回合攻击；在副本真实装弹，
## 保留多组依次付款与归零保护，不能把每组独立“付得起”误当全部可开火。
## 先手仍为对方回应保留上界：持牌、市场牌及倍率卡都计入，不用当前现金
## 提前排除对手可能通过典当、购买或裂变构成的攻击。
static func formation_threats(state: GameState, who: String) -> Dictionary:
	var out := {CardDB.RES_CASH:0,CardDB.RES_USER:0}
	var foe := GameState.opponent(who)
	var cost := maxf(1,float(CardDB.game_rules()["attack_cost_per_card"]))
	if who != state.action_first():
		var has_attack := false
		for combo in state.combos:
			if combo["owner"] == foe and combo["eval"].get("type") == "attack":
				has_attack = true
				break
		if not has_attack: return out
		var pools := Env.copy(state).arm_attacks(foe)
		for res in out:
			out[res] = mini(state.resource_count(who,res),int(floor(float(pools[res])/cost)))
		return out
	var threats: Array = state.market.duplicate()
	for c in state.players[foe]["cards"]: threats.append(c["def_id"])
	var raw := {CardDB.RES_CASH:0.0,CardDB.RES_USER:0.0}
	var buffs := 0
	for id in threats:
		var d := CardDB.get_def(id)
		if d.get("kind") == CardDB.KIND_BUFF and d.get("buff_type") == "attack_x2": buffs += 1
		if d.get("kind") == CardDB.KIND_ATTACK:
			raw[d["attack_res"]] += float(d.get("attack_n",0))
	var multiplier := pow(float(CardDB.buff_mult("attack_x2")),buffs)
	for res in out:
		if raw[res] > 0:
			# 上界只需覆盖现有资源，避免把极大的潜在倍率转成溢出的整数。
			out[res] = int(minf(state.resource_count(who,res),floor(raw[res]*multiplier/cost)))
	return out

## 低成本的防御差异摘要，只用于分道保留候选，绝不代替真实状态去重或攻防结算。
## 配方至少要打掉多少张才会失效，以及本摞最多吸收多少各类可支付攻击，
## 分别保留同币种缓冲和跨币种 batch 锁效果。裂变与保护按候选实际编组计算。
static func _defense_summary(cards: Array, ev: Dictionary, threats: Dictionary) -> Array:
	var out: Array = []
	if ev.get("type") == "upgrade": return out
	var counts := {CardDB.RES_CASH:0,CardDB.RES_USER:0}
	for c in cards:
		var d := CardDB.get_def(c["def_id"])
		if d.get("kind") == CardDB.KIND_UNIT: counts[d["res"]] += 1
	for res in counts:
		var hits := int(threats[res])
		if hits <= 0: continue
		var is_recipe: bool = res == ev.get("recipe_res")
		var protected_count := mini(int(counts[res]),GameState.protect_quota(ev)) if is_recipe and ev.get(CardDB.protect_key(res),false) else 0
		var attackable := int(counts[res])-protected_count
		var break_at := int(counts[res])-_minimum_recipe_cards(cards,ev)+1 if is_recipe else hits+1
		if attackable < break_at: break_at = hits+1
		out.append([res,mini(break_at,hits+1),mini(attackable,hits)])
	return out

static func _formation_variants(state: GameState, who: String, variants: Array, threats: Dictionary, limit: int) -> Array:
	var rows: Array = []
	for ids in variants:
		var cards: Array = []
		for uid in ids: cards.append(state.find_card(who,uid))
		var ev := ComboRules.evaluate(cards)
		if not ev["valid"]: continue
		rows.append({"uids":ids,"complexity":_unit_complexity(cards,ev),"defense":StateCodec.canon(_defense_summary(cards,ev,threats)),"key":StateCodec.canon(ids)})
	rows.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		if a["complexity"][0] != b["complexity"][0]: return a["complexity"][0] < b["complexity"][0]
		if a["complexity"][1] != b["complexity"][1]: return a["complexity"][1] < b["complexity"][1]
		return a["key"] < b["key"])
	var selected: Array = []
	var rest: Array = []
	var seen := {}
	for row in rows:
		if seen.has(row["defense"]): rest.append(row["uids"])
		else:
			seen[row["defense"]] = true
			selected.append(row["uids"])
	selected.append_array(rest)
	return selected.slice(0,limit)

static func formations(state: GameState, who: String, base: Array, p: Dictionary) -> Array:
	var out: Array = []
	var units := {CardDB.RES_CASH:[],CardDB.RES_USER:[]}
	var shields := {}
	var threats := formation_threats(state,who)
	if int(p.get("formation_mode",0)) == 1 and int(threats[CardDB.RES_CASH]) == 0 and int(threats[CardDB.RES_USER]) == 0:
		return out
	for c in state.players[who]["cards"]:
		if c.get("locked",false): continue
		var d := CardDB.get_def(c["def_id"])
		if d.get("kind") == CardDB.KIND_UNIT: units[d["res"]].append(c["uid"])
		if d.get("buff_type","") in ["protect_cash","protect_user"]: shields[d["buff_type"]] = c["uid"]
	for option in base:
		var ids: Array = option["uids"]
		var cards: Array = []
		for uid in ids: cards.append(state.find_card(who,uid))
		var ev := ComboRules.evaluate(cards)
		if ev["type"] == "upgrade": continue
		var variants: Array = [ids]
		for res in units:
			if int(p.get("formation_mode",0)) == 1 and int(threats[res]) <= 0: continue
			var extra: Array = []
			for uid in units[res]:
				if not ids.has(uid): extra.append(uid)
			var next := variants.duplicate()
			for v in variants:
				for n in range(1,extra.size()+1):
					if not AIActions.spend(p): break
					var candidate: Array = v+extra.slice(0,n)
					var shield: int = int(shields.get(CardDB.protect_key(res),-1))
					if shield >= 0 and not candidate.has(shield): candidate.append(shield)
					next.append(candidate)
			variants = _formation_variants(state,who,next,threats,int(p.get("allocation_budget",64)))
		for v in variants:
			if v == ids: continue
			out.append({"uids":v,"merit":option["merit"]})
	return out

## 只用于已结算、即将轮换先手的局面；不把尚未轮到的后手资产认作必胜。
static func cashout_winner_after_round(state: GameState) -> String:
	if state.winner != "": return state.winner
	var next_first := GameState.opponent(state.action_first())
	var next := Env.copy(state)
	next.end_round()
	for who in next.players:
		for c in next.players[who]["cards"]: c["locked"] = false
	var win := AIActions.winning_pawn(next,next_first)
	if win.is_empty(): return ""
	if not Env.replay(next,win): return ""
	return next.winner


## 每一步可选任一剩余市场卡，再选择保留/出售；买后卖能为下一笔购买融资。
## 市场只减不增，有限预算下做广度展开，并合并等价状态，避免交易排列爆炸。
static func resale_transactions(sources: Array, who: String, p: Dictionary) -> Array:
	var work := int(p.get("resale_budget",512))
	var frontier: Array = []
	for source in sources:
		frontier.append({"state":source["state"],"intents":source["intents"],"resold":false})
	var out: Array = []
	var seen := {}
	var cursor := 0
	while cursor < frontier.size() and work > 0 and not AIActions.exhausted(p):
		var node: Dictionary = frontier[cursor]
		cursor += 1
		var s: GameState = node["state"]
		if s.winner != "": continue
		var key := signature(s)
		if seen.has(key): continue
		seen[key] = true
		for index in s.market.size():
			if work <= 0 or not AIActions.spend(p): break
			work -= 1
			var bought := Env.copy(s)
			var buy := Intent.buy(who,index)
			if not Env.replay(bought,[buy]): continue
			var keep := {"state":bought,"intents":node["intents"]+[buy],"resold":node["resold"]}
			frontier.append(keep)
			if node["resold"]: out.append({"state":bought,"intents":keep["intents"],"rank":Eval.score(bought,who,p)})
			var sold := Env.copy(bought)
			var pawn := Intent.pawn(who,[bought.peek_uid()-1])
			if not Env.replay(sold,[pawn]): continue
			var intents: Array = keep["intents"]+[pawn]
			frontier.append({"state":sold,"intents":intents,"resold":true})
			out.append({"state":sold,"intents":intents,"rank":Eval.score(sold,who,p)})
	return out
