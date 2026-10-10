# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name TutorialSession
extends RefCounted

## 独立教学牌局。起点由课程配置提供；购买、典当、编组、攻击和结算复用真实规则。
var state: GameState
var applier: IntentApply
var phase := "action"
var course_id := ""
var step_index := 0
var step_complete := false
var completed := false
var skipped := false
var seen_demo := false
var demo_active := false
var generation := 0
var initial_groups: Array = []
var events: Array = []
var feedback := ""
var course_data: Dictionary = {}
var _scenario_id := ""
var _scenario: Dictionary = {}
var _groups: Array = []
var _split_uids: Dictionary = {}
var _attack_cursor := 0
var _demo_snapshot: Dictionary = {}
var _preview_cache: GameState
var _step_round_floor := 1
var _step_event_floor := 0
var _ready_on_entry := false

func _init(id: String = "") -> void:
	if id != "": start(id)

func start(id: String) -> bool:
	course_data = TutorialCatalog.course(id)
	if course_data.is_empty():
		feedback = TutorialCatalog.ui("invalid_course")
		return false
	course_id = id
	step_index = 0
	completed = false
	skipped = false
	seen_demo = false
	demo_active = false
	_demo_snapshot.clear()
	_scenario_id = ""
	_enter_step()
	return true

func current_step() -> Dictionary:
	var steps: Array = course_data.get("steps", [])
	if step_index < 0 or step_index >= steps.size(): return {}
	var step: Dictionary = steps[step_index].duplicate(true)
	var lesson_vars := {}
	for alias in ["business", "growth"]:
		var selected := _lesson_business("cash" if alias == "business" else "user")
		for key in selected:
			lesson_vars["lesson.%s.%s" % [alias, key]] = selected[key]
	for field in ["goal", "instruction", "explanation", "hint", "ready_goal", "completion_goal"]:
		if step.has(field):
			step[field] = TutorialCatalog.format_text(str(step[field]), lesson_vars)
	if state != null and (_ready_on_entry or step.get("read_when_ready", false)) and _matches(step.get("condition", {})):
		step["kind"] = "read"
		step["goal"] = str(step.get("ready_goal", step.get("goal", "")))
	return step

func _lesson_business(resource: String) -> Dictionary:
	for event in events:
		if event.get("op") == Intent.OP_BUY and event.get("seat") == GameState.PLAYER:
			var definition := CardDB.get_def(str(event.get("def_id", "")))
			if definition.get("output_res") == resource: return definition
	return CardDB.get_def("yunketang" if resource == "cash" else "ditui")

func _enter_step(from_round := -1) -> void:
	_ready_on_entry = false
	var step := current_step()
	var scenario_id := str(step.get("scenario", ""))
	if scenario_id != "" and scenario_id != _scenario_id:
		_load_scenario(scenario_id)
		_step_round_floor = 1
	else:
		_step_round_floor = state.round_num if from_round < 0 else from_round
	_step_event_floor = events.size()
	_evaluate()
	_mark_ready_on_entry()

func _mark_ready_on_entry() -> void:
	# 玩家上一手可能已做得更多；保留真实结果，改成观察确认，避免等待一次无意义操作。
	var condition: Dictionary = course_data.get("steps", [])[step_index].get("condition", {})
	_ready_on_entry = step_complete and condition.get("kind") != "confirm"

func _load_scenario(id: String) -> void:
	_scenario_id = id
	_preview_cache = null
	_scenario = TutorialCatalog.scenario(id)
	state = GameState.new()
	state.set_seed(41008)
	state.players = {GameState.PLAYER: {"cards": []}, GameState.BOT: {"cards": []}}
	state.draw_first = str(_scenario.get("first", GameState.PLAYER))
	for seat in [GameState.PLAYER, GameState.BOT]:
		var counts: Dictionary = _scenario.get(seat, {})
		for def_id in counts:
			for _i in int(counts[def_id]): state.add_card(seat, str(def_id))
	state.market = _scenario.get("market", []).duplicate()
	applier = IntentApply.new(state)
	phase = "action"
	events.clear()
	_split_uids.clear()
	_attack_cursor = 0
	_groups = _groups_for_specs(_scenario.get("player_groups", []))
	initial_groups = _uid_groups(_groups)
	_commit_bot_groups()
	generation += 1
	feedback = TutorialCatalog.ui("scenario_changed", {"title": _scenario.get("title", "")})

func _commit_bot_groups() -> void:
	var used := {}
	for spec in _scenario.get("bot_groups", []):
		var cards := _select_cards(GameState.BOT, spec, used)
		if ComboRules.evaluate(cards).get("valid", false):
			applier.apply(Intent.create_combo(GameState.BOT, _uids(cards)))

func _select_cards(seat: String, spec: Dictionary, used: Dictionary) -> Array:
	var out: Array = []
	for id in spec:
		var needed := int(spec[id])
		for card in state.players[seat]["cards"]:
			if needed <= 0: break
			var uid := int(card["uid"])
			if str(card["def_id"]) == str(id) and not used.has(uid):
				out.append(card)
				used[uid] = true
				needed -= 1
	return out

func _groups_for_specs(specs: Array, preserve_unrelated := false) -> Array:
	var used := {}
	var out: Array = []
	if preserve_unrelated:
		var relevant := _target_core_ids(specs)
		for group in _normalize_groups(_groups):
			if group.size() <= 1 or _pure_resource(_counts(group)) != "": continue
			if group.any(func(card): return relevant.has(card["def_id"])): continue
			out.append(group)
			for card in group: used[int(card["uid"])] = true
	for spec in specs:
		var cards := _select_cards(GameState.PLAYER, spec, used)
		if not cards.is_empty(): out.append(cards)
	var loose := {}
	for card in state.players[GameState.PLAYER]["cards"]:
		if used.has(int(card["uid"])): continue
		var key := str(card["def_id"]) if card["def_id"] in ["cash", "user"] else str(card["uid"])
		if not loose.has(key): loose[key] = []
		loose[key].append(card)
	for pile in loose.values(): out.append(pile)
	return out

func _uids(cards: Array) -> Array:
	var out: Array = []
	for card in cards: out.append(int(card["uid"]))
	return out

func _uid_groups(groups: Array) -> Array:
	var out: Array = []
	for group in groups: out.append(_uids(group))
	return out

func preview_groups(groups: Array) -> void:
	if phase != "action" or state == null: return
	_groups = _normalize_groups(groups)
	_preview_cache = null
	_evaluate()

func _normalize_groups(groups: Array) -> Array:
	var out: Array = []
	var used := {}
	for group in groups:
		var entries: Array = group.get("uids", []) if group is Dictionary else group
		var cards: Array = []
		for entry in entries:
			var uid := int(entry.get("uid", -1)) if entry is Dictionary else int(entry)
			var real := state.find_card(GameState.PLAYER, uid)
			if real.is_empty() or used.has(uid): continue
			used[uid] = true
			cards.append(real)
		if not cards.is_empty(): out.append(cards)
	return out

func notify_split(uid: int) -> void:
	var card := state.find_card(GameState.PLAYER, uid)
	if not card.is_empty() and card.get("def_id") == "user":
		_split_uids[uid] = true
		_evaluate()

func _reject(key: String) -> Dictionary:
	feedback = TutorialCatalog.ui(key)
	return {"ok": false, "reason": feedback}

func _apply(intent: Dictionary) -> Dictionary:
	var pawn_ids: Array = []
	var existing_uids := {}
	if intent.get("op") == Intent.OP_PRODUCE:
		for seat in [GameState.PLAYER, GameState.BOT]:
			for card in state.players[seat]["cards"]: existing_uids[int(card["uid"])] = true
	if intent.get("op") == Intent.OP_PAWN:
		for uid in intent.get("uids", []):
			pawn_ids.append(state.find_card(str(intent["seat"]), int(uid)).get("def_id", ""))
	var result := applier.apply(intent)
	_preview_cache = null
	if result.get("ok", false):
		var event := result.duplicate(true)
		event["round"] = state.round_num
		if not pawn_ids.is_empty(): event["pawn_cards"] = pawn_ids
		if result.get("op") == Intent.OP_ARM:
			# 只记录引擎本轮实际装弹成功的攻击组合，不拿历史编组冒充强化生效。
			event["fired_combos"] = []
			var seat := str(result.get("seat", ""))
			for combo in state.combos:
				if combo["owner"] != seat or combo["eval"].get("type") != "attack": continue
				var fired := false
				for uid in combo["uids"]:
					var card := state.find_card(seat, int(uid))
					if CardDB.get_def(str(card.get("def_id", ""))).get("kind") == CardDB.KIND_ATTACK and int(card.get("fired_round", -1)) == state.round_num: fired = true
				if fired:
					event["fired_combos"].append({"owner": seat, "uids": combo["uids"].duplicate(),
						"eval": combo["eval"].duplicate(true), "card_counts": _counts_from_uids(combo["uids"], seat)})
		if result.get("op") == Intent.OP_PRODUCE:
			event["card_counts"] = _counts_from_uids(result.get("combo", {}).get("uids", []), str(result.get("seat", "")))
			# 升级材料已消失；Buff仍在，因此这里记录Buff足够用于实际生效校验。
			# 每组独立保留引擎实际新增的实体；后续结算可能再次消耗这些牌。
			event["produced_cards"] = []
			for seat in [GameState.PLAYER, GameState.BOT]:
				for card in state.players[seat]["cards"]:
					if not existing_uids.has(int(card["uid"])):
						event["produced_cards"].append({"seat": seat, "card": card.duplicate(true)})
		events.append(event)
	else:
		feedback = str(result.get("reason", ""))
	return result

func buy(index: int, pay_uids: Array = []) -> Dictionary:
	if phase != "action": return _reject("wait_action")
	var result := _apply(Intent.buy(GameState.PLAYER, index, pay_uids))
	if result.get("ok", false):
		var id := str(result["def_id"])
		feedback = TutorialCatalog.ui("result_purchase", {"name": CardDB.card_name(id), "count": CardDB.get_def(id).get("price", 0)})
		_reconcile_groups()
	_evaluate()
	return result

func pawn(uids: Array) -> Dictionary:
	if phase != "action": return _reject("wait_action")
	var result := _apply(Intent.pawn(GameState.PLAYER, uids))
	if result.get("ok", false):
		feedback = TutorialCatalog.ui("result_pawn", {"count": result.get("total", 0)})
		_reconcile_groups()
		if state.winner != "": phase = "over"
	_evaluate()
	return result

func finish_action(groups: Array = []) -> Dictionary:
	if phase == "review":
		_next_round()
		return {"ok": true}
	if phase != "action": return _reject("wait_action")
	if not groups.is_empty(): preview_groups(groups)
	var piles: Array = []
	for group in _groups: piles.append({"uids": _uids(group)})
	var checked := Settle.check_action_completion(state, GameState.PLAYER, piles)
	if not checked.get("ok", false):
		feedback = str(checked.get("reason", ""))
		return checked
	for group in _groups:
		if ComboRules.evaluate(group).get("valid", false):
			var result := _apply(Intent.create_combo(GameState.PLAYER, _uids(group)))
			if not result.get("ok", false): return result
	_apply(Intent.action_done(GameState.PLAYER))
	_apply(Intent.action_done(GameState.BOT))
	_attack_cursor = 0
	_drive_attacks()
	_evaluate()
	return {"ok": true, "phase": phase}

func _drive_attacks() -> void:
	var order := state.action_order()
	while _attack_cursor < order.size():
		if state.winner != "":
			_settle()
			return
		var seat := str(order[_attack_cursor])
		if not applier.armed(seat): _apply(Intent.arm_attacks(seat))
		if seat == GameState.PLAYER and not applier.pool_empty(seat):
			phase = "attack"
			return
		if seat == GameState.BOT and _scenario.get("bot_attack", false):
			var guard := 0
			while not applier.pool_empty(seat) and state.winner == "" and guard < 100:
				var targets := applier.affordable_targets(seat)
				if targets.is_empty(): break
				_apply(Intent.apply_attack(seat, targets[0]))
				guard += 1
		if state.winner == "": _apply(Intent.attack_done(seat))
		_attack_cursor += 1
	_settle()

func attack(target: Dictionary) -> Dictionary:
	if phase != "attack": return _reject("wait_attack")
	var result := _apply(Intent.apply_attack(GameState.PLAYER, target))
	if result.get("ok", false):
		feedback = TutorialCatalog.ui("result_attack", {"count": result.get("removed", []).size(), "resource": CardDB.card_label(str(target.get("res", "")))})
		if state.winner != "":
			_settle()
	_evaluate()
	return result

func finish_attack() -> Dictionary:
	if phase != "attack": return _reject("wait_attack")
	var result := _apply(Intent.attack_done(GameState.PLAYER))
	if result.get("ok", false):
		_attack_cursor += 1
		_drive_attacks()
	_evaluate()
	return result

func _settle() -> void:
	var lines: Array[String] = []
	if state.winner == "":
		for index in applier.production_count():
			var result := _apply(Intent.produce(index))
			var evaluation: Dictionary = result.get("combo", {}).get("eval", {})
			var resolution: Dictionary = result.get("resolution", {})
			var name := CardDB.card_name(str(evaluation.get("leader", "")))
			if not resolution.get("resolved", false):
				lines.append(TutorialCatalog.ui("result_void", {"name": name, "reason": resolution.get("reason", "")}))
			elif evaluation.get("type") == "upgrade":
				lines.append(TutorialCatalog.ui("result_upgrade", {"name": CardDB.card_name(str(evaluation.get("output_card", "")))}))
			else:
				lines.append(TutorialCatalog.ui("result_production", {"name": name, "resource": CardDB.card_label(str(evaluation.get("output_res", ""))), "count": evaluation.get("output_n", 0)}))
	_apply(Intent.finalize())
	phase = "review" if state.winner == "" else "over"
	_reconcile_groups()
	feedback = "\n".join(lines) if not lines.is_empty() else TutorialCatalog.ui("result_no_income")
	if state.winner != "": feedback = TutorialCatalog.ui("result_victory" if state.winner == GameState.PLAYER else "result_defeat")

func _next_round() -> void:
	if state.winner != "": return
	_apply(Intent.next_round())
	# 教学市场每回合提供同一类练习条件；价格、购买和刷新仍真实扣款。
	state.market = _scenario.get("market", []).duplicate()
	_commit_bot_groups()
	phase = "action"
	_reconcile_groups()
	_evaluate()

func _reconcile_groups() -> void:
	_groups = _normalize_groups(_groups)
	var seen := {}
	for group in _groups:
		for card in group: seen[int(card["uid"])] = true
	for card in state.players[GameState.PLAYER]["cards"]:
		if seen.has(int(card["uid"])): continue
		var attached := false
		if card["def_id"] in ["cash", "user"]:
			for group in _groups:
				if group.size() > 0 and group.all(func(c): return c["def_id"] == card["def_id"]):
					group.append(card)
					attached = true
					break
		if not attached: _groups.append([card])
	initial_groups = _uid_groups(_groups)

func acknowledge() -> Dictionary:
	if demo_active: return _reject("demo_active")
	_evaluate()
	if not step_complete:
		return {"ok": false, "reason": recovery_reason()}
	var source_round := state.round_num
	step_index += 1
	if step_index >= course_data.get("steps", []).size():
		completed = true
		feedback = TutorialCatalog.ui("course_completed")
		return {"ok": true, "completed": true}
	_enter_step(source_round)
	# 先让结果页停在刚结算的桌面；只有下一目标需要新行动且尚未达成才开下一轮。
	if phase == "review" and not step_complete and _step_needs_action():
		_next_round()
		_step_round_floor = state.round_num
		_step_event_floor = events.size()
		_evaluate()
		_mark_ready_on_entry()
	return {"ok": true, "completed": false}

func _step_needs_action() -> bool:
	for action in current_step().get("demo", []):
		if action.get("op") in ["groups", "buy", "pawn", "auto_product", "split", "round"]: return true
	return false

func retry() -> void:
	var demo_seen := seen_demo
	start(course_id)
	seen_demo = demo_seen
	feedback = TutorialCatalog.ui("reset_hint")

func skip() -> void:
	skipped = true

func mark_demo() -> void:
	seen_demo = true

func _evaluate() -> void:
	if completed or current_step().is_empty(): return
	step_complete = _matches(current_step().get("condition", {}))

func _counts(cards: Array) -> Dictionary:
	var out := {}
	for card in cards:
		var id := str(card.get("def_id", ""))
		out[id] = int(out.get(id, 0)) + 1
	return out

func _counts_from_uids(uids: Array, seat: String) -> Dictionary:
	var cards: Array = []
	for uid in uids:
		var card := state.find_card(seat, int(uid))
		if not card.is_empty(): cards.append(card)
	return _counts(cards)

func _eval_matches(evaluation: Dictionary, counts: Dictionary, filter: Dictionary) -> bool:
	for key in ["type", "leader", "output_res", "output_card", "attack_res", "filled_by_fission", "protect_user", "protect_cash"]:
		if filter.has(key) and evaluation.get(key) != filter[key]: return false
	for key in ["output_n", "attack_n"]:
		if filter.has(key) and int(evaluation.get(key, 0)) < int(filter[key]): return false
	for id in filter.get("buff_count", {}):
		if not _meets_count(int(counts.get(id, 0)), int(filter["buff_count"][id])): return false
	if filter.has("user_count") and not _meets_count(int(counts.get("user", 0)), int(filter["user_count"])): return false
	return true

func _meets_count(actual: int, required: int) -> bool:
	return actual == 0 if required == 0 else actual >= required

func _group_match(filter: Dictionary) -> bool:
	if state.round_num < int(filter.get("min_round", 1)): return false
	# 已点击完成行动时，现金材料可能已经真实消耗；用本轮提交的组合证明曾经完成编组。
	if phase != "action":
		for event in events:
			if event.get("op") == Intent.OP_COMBO and event.get("seat") == GameState.PLAYER and int(event.get("round", 0)) == state.round_num and state.round_num >= _step_round_floor:
				if _eval_matches(event.get("eval", {}), _counts_from_uids(event.get("uids", []), GameState.PLAYER), filter): return true
	for group in _groups:
		var evaluation := ComboRules.evaluate(group)
		if evaluation.get("valid", false) and _eval_matches(evaluation, _counts(group), filter): return true
	return false

func _resolution_match(filter: Dictionary, resolved := true) -> bool:
	for event in events:
		if event.get("op") != Intent.OP_PRODUCE or event.get("seat") != filter.get("seat", GameState.PLAYER): continue
		if int(event.get("round", 0)) < _step_round_floor: continue
		if filter.has("_round") and int(event.get("round", 0)) != int(filter["_round"]): continue
		if bool(event.get("resolution", {}).get("resolved", false)) != resolved: continue
		if _eval_matches(event.get("combo", {}).get("eval", {}), event.get("card_counts", {}), filter): return true
	return false

func _hits(filter: Dictionary = {}) -> Array:
	var out: Array = []
	for event in events:
		if event.get("op") != Intent.OP_ATTACK or event.get("seat") != GameState.PLAYER: continue
		if int(event.get("round", 0)) < _step_round_floor: continue
		var target: Dictionary = event.get("target", {})
		if filter.has("res") and target.get("res") != filter["res"]: continue
		if filter.has("leader") and target.get("leader") != filter["leader"]: continue
		out.append(event)
	return out

func _matches(condition: Dictionary) -> bool:
	match str(condition.get("kind", "")):
		"confirm": return true
		"split":
			for group in _groups:
				if group.size() == 1 and _split_uids.has(int(group[0]["uid"])): return true
			return false
		"buy":
			for event in events:
				if event.get("op") != Intent.OP_BUY or event.get("seat") != GameState.PLAYER: continue
				if _purchase_matches(str(event.get("def_id", "")), condition): return true
		"group": return _group_match(condition)
		"groups":
			for requirement in condition.get("requirements", []):
				if not _group_match(requirement): return false
			return true
		"resolution": return _resolution_match(condition)
		"resolutions":
			var rounds := {}
			for event in events:
				if event.get("op") == Intent.OP_PRODUCE: rounds[int(event.get("round", 0))] = true
			for round_num in rounds:
				var all_resolved := true
				for requirement in condition.get("requirements", []):
					var matching: Dictionary = requirement.duplicate(true)
					matching["_round"] = round_num
					if not _resolution_match(matching): all_resolved = false
				if all_resolved: return true
		"void": return _resolution_match(condition, false)
		"pawn":
			for event in events:
				if event.get("op") == Intent.OP_PAWN and event.get("pawn_cards", []).has(condition.get("card")): return true
		"victory": return state.winner == GameState.PLAYER
		"armed":
			for event in events:
				if event.get("op") == Intent.OP_ARM and event.get("seat") == GameState.PLAYER and int(event.get("pools", {}).get(condition.get("res"), 0)) > 0: return true
		"attack":
			var hits := _hits(condition)
			if not condition.has("requires_buff"): return hits.size() >= int(condition.get("count", 1))
			var qualified := 0
			for hit in hits:
				var amplified := false
				for event in events:
					if event.get("op") != Intent.OP_ARM or event.get("seat") != GameState.PLAYER or int(event.get("round", 0)) != int(hit.get("round", 0)): continue
					for combo in event.get("fired_combos", []):
						if combo.get("eval", {}).get("attack_res") == hit.get("target", {}).get("res") and int(combo.get("card_counts", {}).get(condition["requires_buff"], 0)) > 0: amplified = true
				if amplified: qualified += 1
			return qualified >= int(condition.get("count", 1))
		"attack_types": return not _hits({"res": "cash"}).is_empty() and not _hits({"res": "user"}).is_empty()
		"attack_batches":
			var rounds := {}
			for hit in _hits():
				var batch := GameState.target_batch(hit["target"])
				if batch == "" or not GameState.batch_locks(hit["target"]): continue
				var round_num := int(hit.get("round", 0))
				if not rounds.has(round_num): rounds[round_num] = {}
				rounds[round_num][batch] = true
				if rounds[round_num].size() >= int(condition.get("count", 2)): return true
		"enemy_disarmed":
			if _hits({"leader": condition.get("leader")}).is_empty(): return false
			for event in events:
				if event.get("op") == Intent.OP_ARM and event.get("seat") == GameState.BOT and event.get("empty", false): return true
		"invalid_group":
			for group in _groups:
				var counts := _counts(group)
				if counts.has(condition.get("leader")) and counts.has(condition.get("buff")) and int(counts.get("user", 0)) == int(condition.get("user_count", 0)):
					if not ComboRules.evaluate(group).get("valid", false): return true
		"protection":
			var preview := _preview_state()
			for combo in preview.combos:
				if combo["owner"] != GameState.PLAYER: continue
				var res := str(condition.get("res", "user"))
				var protected := preview.protected_uids(GameState.PLAYER, combo, res)
				var counts := _counts_from_uids(combo["uids"], GameState.PLAYER)
				if protected.size() == int(condition.get("protected", 0)) and int(counts.get(res, 0)) - protected.size() >= int(condition.get("exposed", 1)): return true
		"unprotected_group":
			var preview := _preview_state()
			for combo in preview.combos:
				if combo["owner"] == GameState.PLAYER and combo["eval"].get("leader") == condition.get("leader") and preview.protected_uids(GameState.PLAYER, combo, str(condition.get("res", "user"))).is_empty(): return true
	return false

## 购牌是否推进目标与是否完成目标共用同一条件，示例只负责演示一种选择。
func _purchase_matches(id: String, condition: Dictionary) -> bool:
	if condition.get("kind") != "buy": return false
	if condition.has("card") and id != condition["card"]: return false
	var definition := CardDB.get_def(id)
	return definition.get("kind") == CardDB.KIND_PRODUCT \
		and (not condition.has("output_res") or definition.get("output_res") == condition["output_res"])

func _preview_state() -> GameState:
	if _preview_cache != null: return _preview_cache
	var preview := GameState.new()
	StateCodec.restore(preview, StateCodec.snapshot(state))
	preview.combos = preview.combos.filter(func(combo): return combo.get("owner") != GameState.PLAYER)
	for group in _groups:
		if ComboRules.evaluate(group).get("valid", false): preview.create_combo(GameState.PLAYER, _uids(group))
	_preview_cache = preview
	return preview

func preview_protected(uid: int, res: String) -> bool:
	if phase != "action": return state.is_protected(GameState.PLAYER, uid, res)
	return _preview_state().is_protected(GameState.PLAYER, uid, res)

func dynamic_progress() -> String:
	if step_complete: return TutorialCatalog.ui("progress_ready")
	if phase == "over": return TutorialCatalog.ui("recovery_over")
	var condition: Dictionary = current_step().get("condition", {})
	var kind := str(condition.get("kind", ""))
	if kind == "buy":
		return TutorialCatalog.ui("progress_buy_target", {"resource": CardDB.card_label(str(condition.get("output_res", "cash")))})
	if kind in ["attack", "attack_types", "attack_batches", "enemy_disarmed"]:
		return TutorialCatalog.ui("progress_attack_types", {"cash": _hits({"res": "cash"}).size(), "user": _hits({"res": "user"}).size()})
	if kind == "split": return str(current_step().get("instruction", ""))
	if recovery_reason() == TutorialCatalog.ui("recovery_lost"): return TutorialCatalog.ui("progress_restart_required")
	if kind == "protection":
		var preview := _preview_state()
		var res := str(condition.get("res", "user"))
		for combo in preview.combos:
			if combo["owner"] != GameState.PLAYER: continue
			var protected := preview.protected_uids(GameState.PLAYER, combo, res).size()
			var counts := _counts_from_uids(combo["uids"], GameState.PLAYER)
			return TutorialCatalog.ui("progress_protection", {"protected": protected, "exposed": maxi(0, int(counts.get(res, 0)) - protected), "resource": CardDB.card_label(res)})
	var valid := 0
	for group in _groups:
		var evaluation := ComboRules.evaluate(group)
		if evaluation.get("valid", false):
			valid += 1
			continue
		for card in group:
			var definition := CardDB.get_def(str(card["def_id"]))
			if definition.get("kind") not in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]: continue
			if condition.has("leader") and card["def_id"] != condition["leader"]: continue
			if condition.has("output_res") and definition.get("output_res") != condition["output_res"]: continue
			var res := str(definition.get("recipe_res", ""))
			var missing := int(definition.get("recipe_n", 0)) - int(_counts(group).get(res, 0))
			if missing > 0:
				return TutorialCatalog.ui("progress_missing", {"name": definition.get("name", ""), "count": missing, "resource": CardDB.card_label(res)})
			return TutorialCatalog.ui("preview_missing", {"name": definition.get("name", ""), "reason": evaluation.get("reason", "")})
	if valid > 0 and kind in ["resolution", "resolutions", "armed"]: return TutorialCatalog.ui("progress_wait_settle")
	return TutorialCatalog.ui("progress_groups", {"count": valid}) if valid > 0 else TutorialCatalog.ui("progress_no_group")

func recovery_reason() -> String:
	if state.winner != "": return TutorialCatalog.ui("recovery_over")
	var required := str(current_step().get("condition", {}).get("leader", ""))
	if required != "" and not state.market.has(required):
		var found := false
		for card in state.players[GameState.PLAYER]["cards"]:
			if card.get("def_id") == required: found = true
		if not found: return TutorialCatalog.ui("recovery_lost")
	return TutorialCatalog.ui("recovery_retry")

func progress() -> Dictionary:
	return {"current": step_index + 1, "total": course_data.get("steps", []).size(), "goal": current_step().get("goal", ""), "instruction": current_step().get("instruction", ""), "progress": dynamic_progress(), "hint": current_step().get("hint", ""), "result": feedback, "completed": completed}

## 演示与错误操作共享完整逻辑快照；视觉位置由原牌桌单独保管，不触碰镜头。
func capture_operation() -> Dictionary:
	return {"state": StateCodec.snapshot(state), "stats": state.stats.duplicate(true),
		"bot_work_sessions": state.bot_work_sessions.duplicate(true), "pools": applier.pools_snapshot(),
		"phase": phase, "groups": _uid_groups(_groups), "initial_groups": initial_groups.duplicate(true),
		"events": events.duplicate(true), "step_index": step_index, "step_complete": step_complete,
		"completed": completed, "skipped": skipped, "seen_demo": seen_demo, "demo_active": demo_active,
		"feedback": feedback, "attack_cursor": _attack_cursor, "split": _split_uids.duplicate(true),
		"round_floor": _step_round_floor, "event_floor": _step_event_floor, "course_id": course_id,
		"ready_on_entry": _ready_on_entry,
		"course_data": course_data.duplicate(true), "scenario_id": _scenario_id,
		"scenario": _scenario.duplicate(true), "demo_snapshot": _demo_snapshot.duplicate(true)}

func restore_operation(before: Dictionary) -> void:
	StateCodec.restore(state, before["state"])
	state.stats = before["stats"].duplicate(true)
	state.bot_work_sessions = before["bot_work_sessions"].duplicate(true)
	applier = IntentApply.new(state)
	applier.pools_restore(before["pools"])
	phase = str(before["phase"])
	_groups = _normalize_groups(before["groups"])
	initial_groups = before["initial_groups"].duplicate(true)
	events = before["events"].duplicate(true)
	step_index = int(before["step_index"])
	step_complete = bool(before["step_complete"])
	completed = bool(before["completed"])
	skipped = bool(before["skipped"])
	seen_demo = bool(before["seen_demo"])
	demo_active = bool(before["demo_active"])
	feedback = str(before["feedback"])
	_attack_cursor = int(before["attack_cursor"])
	_split_uids = before["split"].duplicate(true)
	_step_round_floor = int(before["round_floor"])
	_step_event_floor = int(before["event_floor"])
	_ready_on_entry = bool(before.get("ready_on_entry", false))
	course_id = str(before["course_id"])
	course_data = before["course_data"].duplicate(true)
	_scenario_id = str(before["scenario_id"])
	_scenario = before["scenario"].duplicate(true)
	_demo_snapshot = before["demo_snapshot"].duplicate(true)
	_preview_cache = null
	generation += 1

## 规则引擎先执行；这里只检查这一步是否推进当前学习目标，不修改状态或自动回滚。
func review_operation(before: Dictionary, action: String, detail: Dictionary = {}) -> Dictionary:
	var expected := false
	if before.get("course_id") == course_id and int(before.get("step_index", -1)) == step_index and not demo_active:
		expected = _operation_expected(before, action, detail)
	return {"expected": expected, "reason": "" if expected else TutorialCatalog.ui("operation_rollback", {"goal": current_step().get("goal", "")})}

func _operation_expected(before: Dictionary, action: String, detail: Dictionary) -> bool:
	if detail.get("view_only", false): return true
	if action == "layout" and _same_partition(before["groups"], _uid_groups(_groups)): return true
	var step := current_step()
	if action not in step.get("guide", {}).get("actions", []): return false
	var new_events: Array = events.slice(before["events"].size())
	match action:
		"layout":
			if phase != "action" or before["phase"] != "action": return false
			if step.get("condition", {}).get("kind") == "split": return _expected_split(before, detail)
			var targets := _guide_groups()
			if targets.is_empty(): return false
			var old_groups := _snapshot_groups(before)
			if not _preserves_other_groups(old_groups, targets): return false
			if _preparing_removal(old_groups, targets): return true
			var prior := _layout_quality(old_groups, targets)
			var after := _layout_quality(_groups, targets)
			if int(after["bad"]) > int(prior["bad"]): return false
			if int(after["bad"]) < int(prior["bad"]): return true
			if int(after["ready"]) < int(prior["ready"]): return false
			if int(after["ready"]) > int(prior["ready"]): return true
			if int(after["progress"]) < int(prior["progress"]): return false
			if int(after["progress"]) > int(prior["progress"]): return true
			return _compatible_relayout(old_groups, targets) or _preparing_material(before, detail, targets)
		"buy":
			if before["step_complete"]: return false
			var buys := _events_of(new_events, Intent.OP_BUY)
			if buys.size() != 1: return false
			return _purchase_matches(str(buys[0].get("def_id", "")), step.get("condition", {}))
		"pawn":
			if before["step_complete"]: return false
			var pawns := _events_of(new_events, Intent.OP_PAWN)
			if pawns.size() != 1 or pawns[0].get("pawn_cards", []).size() != 1: return false
			for planned in step.get("demo", []):
				if planned.get("op") == "pawn" and pawns[0]["pawn_cards"][0] == planned.get("card"):
					return _planned_event_count(before["events"], Intent.OP_PAWN, planned) == 0
		"finish_action":
			if before["phase"] != "action" or before["step_complete"]: return false
			var targets := _guide_groups()
			if not targets.is_empty() and int(_layout_quality(_snapshot_groups(before), targets)["ready"]) != targets.size(): return false
			if _events_of(new_events, Intent.OP_ACTION_DONE).is_empty(): return false
			return step_complete or (phase == "attack" and "attack" in step.get("guide", {}).get("actions", []))
		"finish_attack":
			return before["phase"] == "attack" and not _events_of(new_events, Intent.OP_ATTACK_DONE).is_empty() and step_complete
		"attack":
			if before["phase"] != "attack" or before["step_complete"]: return false
			var hits := _events_of(new_events, Intent.OP_ATTACK)
			return _expected_attack(before, hits, detail, step)
	return false

func _expected_attack(before: Dictionary, hits: Array, detail: Dictionary, step: Dictionary) -> bool:
	if hits.is_empty(): return false
	var selected: Dictionary = detail.get("target", {})
	var pile: Dictionary = Intent.uid_set(detail.get("pile_uids", []))
	# 正式牌桌的一次点击可以连续命中整摞；示例的单击仍可没有视觉摞信息。
	if hits.size() > 1 and (selected.is_empty() or pile.is_empty()): return false
	if not selected.is_empty() and not Intent.same_target(selected, hits[0]["target"]): return false
	var batch := GameState.target_batch(hits[0]["target"])
	for hit in hits:
		var target: Dictionary = hit["target"]
		if hits.size() > 1 and (batch == "" or GameState.target_batch(target) != batch): return false
		if not pile.is_empty():
			for uid in target.get("uids", []):
				if not pile.has(int(uid)): return false
		var allowed := false
		for planned in step.get("demo", []):
			if planned.get("op") not in ["attack", "attack_all"] or not _planned_attack_matches(hit, planned): continue
			# 一手里的后续命中属于同次选择；此前另一手已完成的类型不能冒充新进展。
			if planned.get("op") == "attack_all" or _planned_event_count(before["events"], Intent.OP_ATTACK, planned) == 0:
				allowed = true
				break
		if not allowed: return false
	return true

func _events_of(source: Array, op: String) -> Array:
	return source.filter(func(event): return event.get("op") == op and event.get("seat") == GameState.PLAYER)

func _planned_attack_matches(event: Dictionary, planned: Dictionary) -> bool:
	var target: Dictionary = event.get("target", {})
	for key in ["leader", "res"]:
		if planned.has(key) and target.get(key) != planned[key]: return false
	return not planned.get("combo_only", false) or GameState.batch_locks(target)

func _planned_event_count(source: Array, op: String, planned: Dictionary) -> int:
	var count := 0
	for event in source.slice(_step_event_floor):
		if event.get("op") != op or event.get("seat") != GameState.PLAYER: continue
		if op == Intent.OP_ATTACK and _planned_attack_matches(event, planned): count += 1
		if op == Intent.OP_PAWN and event.get("pawn_cards", []).has(planned.get("card")): count += 1
	return count

func _guide_groups() -> Array:
	for planned in current_step().get("demo", []):
		if planned.get("op") == "groups": return _adapt_demo_specs(planned.get("groups", []))
		if planned.get("op") == "auto_product":
			for card in state.players[GameState.PLAYER]["cards"]:
				var definition := CardDB.get_def(str(card["def_id"]))
				if definition.get("kind") == CardDB.KIND_PRODUCT:
					return [{str(card["def_id"]): 1, str(definition["recipe_res"]): int(definition["recipe_n"])}]
	return []

func _snapshot_groups(before: Dictionary) -> Array:
	var by_uid := {}
	for card in before["state"]["players"][GameState.PLAYER]["cards"]: by_uid[int(card["uid"])] = card
	var out: Array = []
	for group in before["groups"]:
		var cards: Array = []
		for uid in group:
			if by_uid.has(int(uid)): cards.append(by_uid[int(uid)])
		if not cards.is_empty(): out.append(cards)
	return out

func _partition(groups: Array) -> Array:
	var out: Array = []
	for group in groups:
		var ids: Array = group.duplicate()
		ids.sort()
		out.append(str(ids))
	out.sort()
	return out

func _same_partition(first: Array, second: Array) -> bool:
	return _partition(first) == _partition(second)

func _pure_resource(counts: Dictionary) -> String:
	if counts.size() == 1 and str(counts.keys()[0]) in [CardDB.RES_CASH, CardDB.RES_USER]: return str(counts.keys()[0])
	return ""

## 示例提供目标与必要材料，不限制真实规则允许的富余资源或强化叠加。
func _layout_quality(groups: Array, targets: Array) -> Dictionary:
	var bad := 0
	var progress_count := 0
	var ready := 0
	for group in groups:
		var counts := _counts(group)
		if group.size() <= 1 or _pure_resource(counts) != "": continue
		var least_extra: int = group.size()
		for target in targets:
			if _target_compatible(counts, target):
				least_extra = 0
				break
			if not _anchors_target(counts, target): continue
			var extra := 0
			for id in counts: extra += maxi(0, int(counts[id]) - int(target.get(id, 0)))
			least_extra = mini(least_extra, extra)
		bad += least_extra
	for target in targets:
		var best := 0
		var satisfied := false
		for group in groups:
			var counts := _counts(group)
			# 另一项业务里的资源不能被重复记作本业务的配方进展。
			if not _anchors_target(counts, target): continue
			var matched := 0
			for id in target: matched += mini(int(target[id]), int(counts.get(id, 0)))
			best = maxi(best, matched)
			if _target_ready(counts, target): satisfied = true
		progress_count += best
		if satisfied: ready += 1
	return {"bad": bad, "progress": progress_count, "ready": ready}

func _spec_cards(spec: Dictionary) -> Array:
	var cards: Array = []
	for id in spec:
		for _i in int(spec[id]): cards.append({"def_id": str(id)})
	return cards

func _target_filter(target: Dictionary, expected: Dictionary) -> Dictionary:
	var filter := {"type": expected["type"], "buff_count": {}}
	if expected["type"] == "upgrade":
		filter["output_card"] = expected["output_card"]
	else:
		filter["leader"] = expected["leader"]
		for key in ["output_res", "output_n", "attack_res", "attack_n"]: filter[key] = expected[key]
	for id in target:
		if CardDB.get_def(str(id)).get("kind") == CardDB.KIND_BUFF: filter["buff_count"][id] = int(target[id])
	var condition: Dictionary = current_step().get("condition", {})
	var requirements: Array = condition.get("requirements", [condition])
	for requirement in requirements:
		var belongs := true
		for key in ["type", "leader", "output_res", "output_card"]:
			if requirement.has(key) and requirement[key] != expected.get(key): belongs = false
		if not belongs: continue
		for key in ["user_count", "filled_by_fission"]:
			if requirement.has(key): filter[key] = requirement[key]
		for id in requirement.get("buff_count", {}):
			filter["buff_count"][id] = maxi(int(filter["buff_count"].get(id, 0)), int(requirement["buff_count"][id]))
		if requirement.get("kind") == "unprotected_group": filter["protect_" + str(requirement.get("res", "user"))] = false
	return filter

func _target_ready(counts: Dictionary, target: Dictionary) -> bool:
	var expected := ComboRules.evaluate(_spec_cards(target))
	# 有意拆出无效组合的观察步骤仍按指定条件演示，不能用有效组合代替。
	if not expected.get("valid", false): return _same_counts(counts, target)
	var actual := ComboRules.evaluate(_spec_cards(counts))
	return actual.get("valid", false) and _eval_matches(actual, counts, _target_filter(target, expected))

func _target_compatible(counts: Dictionary, target: Dictionary) -> bool:
	if _target_ready(counts, target): return true
	# 材料可以先叠在一起，核心卡不必先入摞；已有其他业务核心仍不算本步材料。
	var has_core := counts.keys().any(func(id): return CardDB.get_def(str(id)).get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND])
	if has_core and not _anchors_target(counts, target): return false
	# 真实配方已生效时允许富余，即使教学还要求补 Buff；缺配方时错料不算进展。
	# 将这些牌计为错料后，逐张拆出、拆到只剩核心也都能降低错误量。
	if not ComboRules.evaluate(_spec_cards(counts)).get("valid", false):
		for res in [CardDB.RES_CASH, CardDB.RES_USER]:
			if int(counts.get(res, 0)) > 0 and int(target.get(res, 0)) == 0: return false
	# 补齐示例尚缺的牌，再询问同一个规则入口：能补成目标才是合法中间状态。
	var completed_counts := counts.duplicate()
	for id in target: completed_counts[id] = maxi(int(completed_counts.get(id, 0)), int(target[id]))
	return _target_ready(completed_counts, target)

func _anchors_target(counts: Dictionary, target: Dictionary) -> bool:
	for id in target:
		if counts.has(id) and CardDB.get_def(str(id)).get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND]:
			return true
	return false

func _compatible_relayout(old_groups: Array, targets: Array) -> bool:
	var old_partition := _partition(_uid_groups(old_groups))
	var new_partition := _partition(_uid_groups(_groups))
	var changed_target := false
	for group in _groups:
		if old_partition.has(_partition([_uids(group)])[0]): continue
		var counts := _counts(group)
		if group.size() <= 1 or _pure_resource(counts) != "": continue
		var compatible := false
		for target in targets:
			if _target_compatible(counts, target): compatible = true; break
		if not compatible: return false
		changed_target = true
	# 已准备的材料摞也能拆开重组，不能只允许合上却不允许撤回准备动作。
	for group in old_groups:
		if new_partition.has(_partition([_uids(group)])[0]): continue
		if group.size() > 1 and targets.any(func(target): return _target_compatible(_counts(group), target)):
			changed_target = true
	return changed_target

func _same_counts(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size(): return false
	for id in first:
		if int(first[id]) != int(second.get(id, -1)): return false
	return true

func _target_core_ids(targets: Array) -> Dictionary:
	var relevant := {}
	for target in targets:
		for id in target:
			if id not in [CardDB.RES_CASH, CardDB.RES_USER]: relevant[id] = true
	return relevant

## 原牌桌从所点卡开始拖走整个尾段。移除夹在配方中的牌，可能必须先拆出
## 仍然需要的材料；这只是准备过程，最终目标仍由真实配方和保护状态判定。
func _removal_material(counts: Dictionary, targets: Array) -> bool:
	var removed: Array = current_step().get("guide", {}).get("remove_cards", [])
	if not removed.any(func(id): return counts.has(id)): return false
	return targets.any(func(target): return counts.keys().all(func(id): return target.has(id) or removed.has(id)))

func _preparing_removal(old_groups: Array, targets: Array) -> bool:
	var old_partition := _partition(_uid_groups(old_groups))
	var new_partition := _partition(_uid_groups(_groups))
	var sources: Array = []
	for group in old_groups:
		if new_partition.has(_partition([_uids(group)])[0]): continue
		if not _removal_material(_counts(group), targets): return false
		sources.append(_uids(group))
	if sources.is_empty(): return false
	# 只放行原摞的拆分；合入其他牌或把别组材料拖进来仍走普通质量检查。
	for group in _groups:
		if old_partition.has(_partition([_uids(group)])[0]): continue
		if not sources.any(func(source): return _uids(group).all(func(uid): return source.has(uid))): return false
	return true

func _preserves_other_groups(old_groups: Array, targets: Array) -> bool:
	var relevant := _target_core_ids(targets)
	var current := _partition(_uid_groups(_groups))
	for group in old_groups:
		if group.size() <= 1 or _pure_resource(_counts(group)) != "": continue
		# 既有的另一项业务不是本步的错误材料，不能靠拆掉它降低当前配方的缺项分数。
		if group.any(func(card): return relevant.has(card["def_id"])): continue
		if targets.any(func(target): return _target_compatible(_counts(group), target)): continue
		# 待移除牌连带出来的材料可以再拆开、补回目标配方。
		if _removal_material(_counts(group), targets): continue
		if not current.has(_partition([_uids(group)])[0]): return false
	return true

func _expected_split(before: Dictionary, detail: Dictionary) -> bool:
	var uid := int(detail.get("split_uid", -1))
	if uid < 0:
		for candidate in _split_uids:
			if not before["split"].has(candidate): uid = int(candidate); break
	if uid < 0 or before["split"].has(uid) or not _split_uids.has(uid): return false
	var source: Array = []
	for group in _snapshot_groups(before):
		if group.any(func(card): return int(card["uid"]) == uid): source = group; break
	if source.size() < 2 or _pure_resource(_counts(source)) != CardDB.RES_USER: return false
	for group in _groups:
		if group.size() == 1 and int(group[0]["uid"]) == uid: return true
	return false

func _preparing_material(before: Dictionary, _detail: Dictionary, targets: Array) -> bool:
	# 当前需要的同类纯资源可以任意拆分或合摞；准备数量不是配方上限。
	# 业务配方仍由真实规则检查，这里不允许混入别的材料或拆散已完成的业务。
	var old_groups := _snapshot_groups(before)
	var old_partition := _partition(before["groups"])
	var new_partition := _partition(_uid_groups(_groups))
	var changed: Array = []
	for group in old_groups:
		if not new_partition.has(_partition([_uids(group)])[0]): changed.append(group)
	for group in _groups:
		if not old_partition.has(_partition([_uids(group)])[0]): changed.append(group)
	if changed.is_empty(): return true
	var res := _pure_resource(_counts(changed[0]))
	if res == "" or not changed.all(func(group): return _pure_resource(_counts(group)) == res): return false
	return targets.any(func(target): return int(target.get(res, 0)) > 0)

func demo_action() -> Dictionary:
	if demo_active: return _reject("demo_active")
	_demo_snapshot = capture_operation()
	seen_demo = true
	demo_active = true
	var result := run_example()
	return {"ok": result.get("ok", false), "groups": _uid_groups(_groups), "result": feedback}

## 演示和测试共同使用课程中的操作计划；计划本身不会直接修改资源或胜负。
func run_example() -> Dictionary:
	for action in current_step().get("demo", []):
		var result := _example_action(action)
		if not result.get("ok", false): return result
	_evaluate()
	return {"ok": true}

func _example_action(action: Dictionary) -> Dictionary:
	var operation := str(action.get("op", ""))
	if operation in ["groups", "buy", "pawn", "auto_product", "split"] and phase == "review": _next_round()
	match operation:
		"groups":
			_groups = _groups_for_specs(_adapt_demo_specs(action.get("groups", [])), true)
			_preview_cache = null
			initial_groups = _uid_groups(_groups)
			_evaluate()
		"buy": return buy(state.market.find(action.get("card", "")))
		"pawn":
			for card in state.players[GameState.PLAYER]["cards"]:
				if card.get("def_id") == action.get("card"): return pawn([int(card["uid"])])
			return _reject("demo_unavailable")
		"split":
			_groups = _groups_for_specs([{str(action.get("card", "user")): 1}])
			if not _groups.is_empty(): notify_split(int(_groups[0][0]["uid"]))
			initial_groups = _uid_groups(_groups)
		"round": return finish_action(_groups) if phase == "action" else {"ok": true}
		"finish_attack": return finish_attack() if phase == "attack" else {"ok": true}
		"attack", "attack_all":
			var limit := 100 if operation == "attack_all" else 1
			for _i in limit:
				if phase != "attack" or state.winner != "": break
				var chosen := {}
				for target in applier.affordable_targets(GameState.PLAYER):
					if action.has("leader") and target.get("leader") != action["leader"]: continue
					if action.has("res") and target.get("res") != action["res"]: continue
					if action.get("combo_only", false) and not GameState.batch_locks(target): continue
					chosen = target
					break
				if chosen.is_empty(): break
				var result := attack(chosen)
				if not result.get("ok", false): return result
		"auto_product":
			for card in state.players[GameState.PLAYER]["cards"]:
				var definition := CardDB.get_def(str(card["def_id"]))
				if definition.get("kind") != CardDB.KIND_PRODUCT: continue
				var recipe: Dictionary = {str(card["def_id"]): 1, str(definition.get("recipe_res", "user")): int(definition.get("recipe_n", 0))}
				_groups = _groups_for_specs([recipe], true)
				initial_groups = _uid_groups(_groups)
				_evaluate()
				break
	return {"ok": true}

func _adapt_demo_specs(specs: Array) -> Array:
	var out: Array = specs.duplicate(true)
	# 接受替代业务后，提示和演示也跟随实际卡牌，不会继续指向未购买的牌。
	if course_id not in ["income", "growth"]: return out
	for spec in out:
		for id in spec.keys():
			var definition := CardDB.get_def(str(id))
			if definition.get("kind") != CardDB.KIND_PRODUCT: continue
			var owns := false
			for card in state.players[GameState.PLAYER]["cards"]:
				if card["def_id"] == id: owns = true
			if owns: continue
			for card in state.players[GameState.PLAYER]["cards"]:
				var alternative := CardDB.get_def(str(card["def_id"]))
				if alternative.get("kind") == CardDB.KIND_PRODUCT and alternative.get("output_res") == definition.get("output_res"):
					spec.erase(id)
					spec.erase(str(definition.get("recipe_res", "")))
					spec[str(card["def_id"])] = 1
					spec[str(alternative.get("recipe_res", ""))] = int(alternative.get("recipe_n", 0))
					break
	return out

func end_demo() -> void:
	if not demo_active: return
	var before := _demo_snapshot
	restore_operation(before)
	seen_demo = true
	demo_active = false
	_demo_snapshot.clear()
