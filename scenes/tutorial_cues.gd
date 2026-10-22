# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 只读实际桌面：先找到下一手需要的实体，再决定整摞拖动、展开或取后缀。
const Catalog = preload("res://engine/tutorial_catalog.gd")

static func resolve(arena: Node, finish: Button) -> Dictionary:
	var session: RefCounted = arena.session
	if session.completed or session.step_complete: return {}
	var step: Dictionary = session.current_step()
	if session.phase == "attack":
		if "attack" in step.get("guide", {}).get("actions", []):
			for planned in step.get("demo", []):
				if planned.get("op") != "attack": continue
				for target in session.applier.affordable_targets(arena.my_seat):
					if planned.has("leader") and target.get("leader") != planned["leader"]: continue
					if planned.has("res") and target.get("res") != planned["res"]: continue
					for uid in target.get("uids", []):
						var card: CardEntity = arena.entities.get(int(uid))
						if card != null:
							# 对手组合点核心牌即可攻击下面的资源。
							var leader := find_card(arena, str(target.get("leader", "")), false)
							if leader != null: card = leader
							return {"gesture": "click", "source": card, "text": Catalog.ui("gesture.attack", {"name": CardDB.card_name(card.def_id)})}
		return finish_cue(finish, Catalog.ui("finish_attack"))
	if session.phase != "action": return {}
	if step.get("id") == "reserve.recipe" and not session._step_rejected:
		return finish_cue(finish, Catalog.ui("complete_action"))
	if step.get("condition", {}).get("kind") == "buy":
		var market: CardEntity
		for card in arena.market_cards:
			if session._purchase_matches(card.def_id, step.get("condition", {})):
				market = card
				break
		if market == null: return {}
		if step.get("id") == "reserve.buy" and session._step_rejected \
				and session.state.resource_count(arena.my_seat, "cash") <= int(CardDB.get_def(market.def_id)["price"]):
			return pawn_cue(arena, "user")
		var payment := transfer(arena, "cash", 999, market, CardDB.card_name(market.def_id), true)
		if int(payment.get("count", 0)) < int(CardDB.get_def(market.def_id)["price"]) and payment.has("source"):
			var merge := transfer(arena, "cash", 999, payment["source"], CardDB.card_name("cash"), true)
			if not merge.is_empty(): return merge
		return payment
	var specs: Array = session._guide_groups()
	for spec in specs:
		var core_id := ""
		for id in spec:
			if id not in ["cash", "user"]: core_id = id; break
		var core := find_card(arena, core_id)
		if core == null: continue
		var group: Variant = arena.board.group_of(core)
		var members: Array = group["cards"] if group != null else [core]
		var counts := {}
		for card in members: counts[card.def_id] = int(counts.get(card.def_id, 0)) + 1
		if session._target_ready(counts, spec): continue
		# 配方保底选修：把不该投入的现金拿回空处，保留另一项业务。
		for res in ["cash", "user"]:
			if spec.has(res): continue
			var extra := members.filter(func(card): return card.def_id == res)
			if not extra.is_empty():
				return take_from(arena, extra, extra.size(), null, Catalog.ui("gesture.empty"))
		for id in spec:
			var missing: int = int(spec[id]) - members.filter(func(card): return card.def_id == id).size()
			if missing > 0:
				return transfer(arena, id, missing, core, CardDB.card_name(core_id), step.get("id") == "income.group")
	for planned in step.get("demo", []):
		if planned.get("op") == "pawn": return pawn_cue(arena, str(planned["card"]))
	if "finish_action" in step.get("guide", {}).get("actions", []): return finish_cue(finish, Catalog.ui("complete_action"))
	return {}

static func find_card(arena: Node, id: String, mine := true) -> CardEntity:
	for card in arena.entities.values():
		if is_instance_valid(card) and card.def_id == id and card.draggable == mine: return card
	return null

static func finish_cue(button: Button, caption: String) -> Dictionary:
	return {"gesture": "click", "source": button, "text": Catalog.ui("gesture.finish", {"action": caption})}

static func pawn_cue(arena: Node, id: String) -> Dictionary:
	var cue := transfer(arena, id, 1, null, Catalog.ui("gesture.pawn"))
	if not cue.is_empty(): cue["target_world"] = arena.board.pawn_pos
	return cue

static func transfer(arena: Node, id: String, needed: int, target: CardEntity, target_name: String, whole := false) -> Dictionary:
	var candidates: Array = []
	var seen := {}
	for card in arena.entities.values():
		if not is_instance_valid(card) or not card.draggable or card.def_id != id: continue
		var group: Variant = arena.board.group_of(card)
		var members: Array = group["cards"] if group != null else [card]
		if target in members or seen.has(members[0].uid): continue
		seen[members[0].uid] = true
		var available: Array = []
		# 拖动会带走后面的牌，只选真正位于后缀的同类牌。
		for i in range(members.size() - 1, -1, -1):
			if members[i].def_id != id: break
			available.push_front(members[i])
		if available.is_empty(): continue
		var pure := available.size() == members.size()
		if not pure:
			var definition := CardDB.get_def(members[0].def_id)
			if definition.get("recipe_res") == id:
				var spare := maxi(0, available.size() - int(definition.get("recipe_n", 0)))
				available = available.slice(available.size() - spare)
		if not available.is_empty(): candidates.append({"cards": available, "pure": pure})
	candidates.sort_custom(func(a, b): return a["cards"].size() > b["cards"].size() if a["pure"] == b["pure"] else a["pure"])
	if candidates.is_empty(): return {}
	var source: Array = candidates[0]["cards"]
	return take_from(arena, source, source.size() if whole else mini(needed, source.size()), target, target_name)

static func take_from(arena: Node, source: Array, amount: int, target: CardEntity, target_name: String) -> Dictionary:
	var card: CardEntity = source[source.size() - amount]
	var group: Variant = arena.board.group_of(card)
	var total: int = group["cards"].size() if group != null else 1
	if group != null and group.get("compact", false) and amount < total:
		return {"gesture": "double_click", "source": group["cards"][0], "text": Catalog.ui("gesture.expand")}
	var key := "gesture.single" if amount == 1 else ("gesture.pile" if amount == total else "gesture.suffix")
	var cue := {"gesture": "drag", "source": card, "target": target,
		"text": Catalog.ui(key, {"resource": CardDB.card_name(card.def_id), "count": amount - 1, "target": target_name}), "count": amount}
	if target == null:
		cue["target_world"] = arena.layout._free_spot(arena.board.rest_pos(card) + Vector3(2.0, 0, 0), arena.my_seat)
	return cue
