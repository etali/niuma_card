# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIActions
extends RefCounted

const Env = preload("res://engine/ai_environment.gd")
const Eval = preload("res://engine/ai_evaluation.gd")
const Context = preload("res://engine/ai_context.gd")

## 宏动作生成器。返回 {state,intents,rank}；state 只属于搜索，真实局面仅重放 intents。
static func generate(state: GameState, who: String, profile: Dictionary) -> Array:
	# 每个生成器只买卖/编组自身手牌；对方特征只在这次调用内复用。
	# 浅拷贝隔离局部评分快照，规则缓存和展开额度仍与整个搜索共享。
	profile = profile.duplicate()
	if not profile.has("_context"):
		profile["_context"] = Context.new()
	var immediate := winning_pawn(state, who, profile["_context"])
	if not immediate.is_empty():
		var won := Env.copy(state)
		Env.replay(won, immediate)
		return [{"state": won, "intents": immediate, "rank": Eval.TERMINAL_SCORE}]
	profile["_opponent_features"] = Eval.features(state, GameState.opponent(who), profile)
	var holdings := _purchases(state, who, profile)
	var out: Array = []
	for node in holdings:
		out.append_array(_build(node, who, profile))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["rank"] > b["rank"])
	return out.slice(0, mini(int(profile["plans"]), out.size()))

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
		beam = next.slice(0, mini(int(profile["buy_beam"]), next.size()))
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
		next.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["merit"] > b["merit"])
		beam = next.slice(0, mini(int(profile["build_beam"]), next.size()))
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
	if out.is_empty():
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
	# 终局判定仍由统一评分入口逐个执行，不能被对方的非终局特征覆盖。
	return Eval.score(state, who, profile, profile.get("_opponent_features", {}))

static func _core_priority(c: Dictionary) -> float:
	var d := CardDB.get_def(str(c["def_id"]))
	return float(d.get("output_n", d.get("attack_n", 0))) / maxf(1, d.get("recipe_n", 0))

static func _core_options(state: GameState, who: String, core: Dictionary, processed: Dictionary,
		profile: Dictionary = {}) -> Array:
	var parameters := profile if profile.has("protection_bonus") else AISearch.from_model("ai", 0.0).resolved_parameters()
	var context = parameters.get("_context")
	if context == null:
		context = Context.new()
	var id := str(core["def_id"])
	var d := CardDB.get_def(id)
	var same: Array = [int(core["uid"])]
	var units: Array = []
	var buffs := {}
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
		if cd.get("kind") == CardDB.KIND_UNIT and cd.get("res") == d.get("recipe_res"):
			units.append(int(c["uid"]))
		if cd.get("kind") == CardDB.KIND_BUFF:
			var bt := str(cd.get("buff_type", ""))
			if not buffs.has(bt):
				buffs[bt] = int(c["uid"])
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
		for enhanced in [false, true]:
			if enhanced and not buffs.has(enhancement):
				continue
			for protected in [false, true]:
				if protected and not buffs.has(protection):
					continue
				var ids: Array = [int(core["uid"])] + units.slice(0, required)
				if use_fill:
					ids.append(buffs["user_fill"])
				if enhanced:
					ids.append(buffs[enhancement])
				if protected:
					ids.append(buffs[protection])
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
	var demand := 0
	for c in state.players[who]["cards"]:
		var d := CardDB.get_def(str(c["def_id"]))
		if d.get("recipe_res", "") == CardDB.RES_USER:
			demand += int(d.get("recipe_n", 0))
	var pending := 0
	for c in state.combos:
		if c["owner"] == who and c["eval"].get("output_res", "") == CardDB.RES_USER:
			pending += int(c["eval"].get("output_n", 0))
	var missing := maxi(0, demand - state.resource_count(who, CardDB.RES_USER) - pending)
	return minf(output, missing) * Eval.user_price(state, who) + maxf(0, output - missing) * CardDB.pawn_user()


static func semantic_key(id: String, context = null) -> String:
	var rules = context if context != null else Context.new()
	return rules.semantic_key(id)


## 节点额度由搜索上下文共享；单独调用生成器可不带额度。
static func spend(profile: Dictionary) -> bool:
	if not profile.has("_work"):
		return true
	var work: Array = profile["_work"]
	if int(work[0]) <= 0:
		return false
	work[0] = int(work[0]) - 1
	return true

static func exhausted(profile: Dictionary) -> bool:
	return profile.has("_work") and int(profile["_work"][0]) <= 0
