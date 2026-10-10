# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

class PresentationBeat extends Node:
	signal finished
	func complete() -> void:
		finished.emit()

## 交易与组合的表现入口。正式对局和教学牌桌均传入真实裁决结果，
## 共用卡牌回收、落位、反馈和动作音效，不在演示层另写交易动画。
const Motion = preload("res://scenes/ui_motion.gd")
const Feedback = preload("res://scenes/table_feedback.gd")
const Regions = preload("res://scenes/table_regions.gd")
var host: Node3D
signal pawn_finished
var _pawn_moves: Array[Dictionary] = []

## 正式与教学实体使用同一边界、登记和产出飞入入口。
func spawn_card(record: Dictionary, at: Vector3, draggable: bool,
		from_pos = null, index := 0, total := 1) -> CardEntity:
	if host._table_scene.drawer_mode and is_instance_valid(host.layout):
		var safe: Rect2 = host.layout._center_bounds(host.my_seat if draggable else host.foe_seat)
		if safe.has_area():
			at.x = clampf(at.x, safe.position.x, safe.end.x)
			at.z = clampf(at.z, safe.position.y, safe.end.y)
		if draggable: at = host.board.clamp_player_position(at)
	var card: CardEntity = host._table_scene.spawn_card(host.board, record, at, draggable)
	host.entities[card.uid] = card
	if from_pos != null: _motion()._fly_from(card, from_pos, at, index, total)
	return card

func bind(table: Node3D, connect_board := true) -> void:
	host = table
	set_process(false)
	if not connect_board:
		return
	bind_board_sounds(host.board, play_board_sound)
	host.board.group_formed.connect(group_ready)

## 正式牌桌与教程只共用这份输入声音映射；并组不另配音，落桌和凑组各自发声。
## 返回连接用于临时接管牌桌后完整解除，保留原局既有连接。
static func bind_board_sounds(board: Board, play: Callable) -> Array:
	var connections: Array = []
	for entry in [["card_picked", "card_pickup", 1], ["pile_toggled", "pile_toggle", 0],
		["card_dropped_table", "card_drop", 0], ["group_completed", "combo_complete", 0]]:
		var callback := play.bind(entry[1])
		if entry[2] > 0:
			callback = callback.unbind(entry[2])
		board.connect(entry[0], callback)
		connections.append([entry[0], callback])
	return connections

func play_board_sound(action: String) -> void:
	host.sfx.play(action)

## 商品反拖的落点只属于本次本地输入；入口立即取走，避免失败后污染下一次点击购买。
func take_purchase_placement(card: CardEntity) -> Dictionary:
	if not is_instance_valid(card) or not card.has_meta("purchase_placement"): return {}
	var placement: Dictionary = card.get_meta("purchase_placement", {})
	card.remove_meta("purchase_placement")
	return placement

func cancel_purchase_placement(card: CardEntity, placement: Dictionary) -> void:
	if placement.is_empty() or not is_instance_valid(card) or not card.is_market \
		or not host.market_cards.has(card):
		return
	card.global_position = placement["shelf_position"]
	card.rotation_degrees = placement["shelf_rotation"]
	card.freeze = true
	host.board._sync_market_tag(card)

## 自动付款避开玩家刚摆好的有效业务/攻击配方；卡组是否有效只问共享规则。
## 仍交给原购买意图检查价格、所有权及现金不能归零，不在表现层扣款。
func purchase_payment(cards: Array, price: int) -> Dictionary:
	if not cards.is_empty():
		return {"uids": cards.map(func(card): return card.uid), "issue": {}}
	var reserved := {}
	for group in host.board.groups:
		var records: Array = []
		for card in group["cards"]:
			if not is_instance_valid(card): continue
			var record: Dictionary = host.state.find_card(host.my_seat, card.uid)
			if not record.is_empty(): records.append(record)
		var evaluation := ComboRules.evaluate(records)
		if evaluation.get("valid", false) and evaluation.get("type") in ["production", "attack"]:
			for record in records: reserved[record["uid"]] = true
	var available: Array = host.state._loose_unit_uids(host.my_seat, CardDB.RES_CASH)
	available = available.filter(func(uid): return not reserved.has(uid))
	# 空数组在引擎里表示“自动选钱”，所以没有可用现金时不能再传空数组兜底。
	if available.is_empty() and price > 0:
		return {"uids": [], "issue": {"ok": false, "code": "short", "reason": "没有可用于购买的现金，请先从组合中拆出现金"}}
	return {"uids": available, "issue": {}}

## 交易余牌和拒绝后的退牌保持同一落点、收摞状态与物理行为。
func return_purchase_payment(cards: Array) -> void:
	# 现金拖向商品时已从原组摘下，需要退回；反拖商品时现金仍在原组，
	# 付款由 CardMotion / Board.drop_card 收走实际张数，仍在原组的现金不重复退回。
	return_cards(cards.filter(func(card): return is_instance_valid(card) and host.board.group_of(card) == null))

func return_cards(cards: Array, anchor := Vector3.INF, compact = null) -> void:
	var remaining := cards.filter(func(card): return is_instance_valid(card) and not host.state.find_card(host.my_seat, card.uid).is_empty())
	if remaining.is_empty(): return
	var anchored := anchor != Vector3.INF
	var ignore := {}
	for card in remaining:
		host.board._detach_from_group(card)
		ignore[card.uid] = true
	# 摘牌会给原组余牌排补间；全部摘完后取消，不能再被旧补间拉回原摞。
	for card in remaining: host.board._stop_move(card, false)
	if anchor == Vector3.INF:
		anchor = Vector3(clampf(remaining[0].global_position.x, -8.0, 8.0), 0.2, Regions.PLAYER_ZONE_Z + 2.2)
	var base: Vector3 = host.layout._free_spot(anchor, host.my_seat, [], ignore)
	base.y = 0.2
	remaining[0].global_position = base
	if remaining.size() > 1:
		var group: Dictionary = host.board.make_group(remaining, host.board.last_drag_compact if compact == null else bool(compact))
		host.board.groups.append(group)
		host.board._layout_group(group, base if anchored else Vector3.INF)
	else:
		remaining[0].freeze = false

func purchase(index: int, card: CardEntity, result: Dictionary, placement: Dictionary = {}) -> void:
	var motion: Node = _motion()
	for uid in result["removed_uids"]:
		if host.entities.has(uid):
			motion._suck_into(host.entities[uid], card.position + Vector3(0, 0.2, 0))
			host.entities.erase(uid)
	host.market_cards.remove_at(index)
	_drop_price(index)
	# 直接拖商品时保留松手处；点击价签/拖现金仍由原占用规则选择到货位置。
	var target: Vector3
	if placement.is_empty():
		target = host.layout._free_spot(
			Vector3(randf_range(-5, 5), 0.2, Regions.PLAYER_ZONE_Z + 1.6), host.my_seat)
	else:
		target = card.get_parent().to_local(placement["position"])
	target.y = 0.2
	card.is_market = false
	card.draggable = true
	card.freeze = true
	card.uid = int(result["new_uid"])
	host.entities[card.uid] = card
	# 等现金吸收后再完成到货，直接拖入的商品也沿用同一付款节奏。
	motion.move_above_table(card, target, Motion.TRANSFER)
	if not placement.is_empty():
		# 商品先登记落点，再用原避让/组牌逻辑挪开遮挡它的余款；购买本身不编成业务配方。
		var remaining: Array = []
		for uid in placement["payment_uids"]:
			if host.entities.has(uid): remaining.append(host.entities[uid])
		var footprint := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z)
		var occupied := Rect2(Vector2(target.x, target.z) - footprint * 0.5, footprint)
		if remaining.any(func(c):
			var at: Vector3 = host.board.rest_pos(c)
			return occupied.intersects(Rect2(Vector2(at.x, at.z) - footprint * 0.5, footprint))):
			return_cards(remaining, placement["payment_origin"], placement["payment_compact"])
	card.pulse_feedback("arrive", Color.TRANSPARENT, Motion.TRANSFER)
	host.sfx.play("buy")
	host._event_feedback("purchase", card.global_position + Vector3(0, 0.5, 0), Palette.semantic("cash"), 12)

func pawn(cards: Array, uids: Array, owner := "") -> void:
	var motion: Node = _motion()
	var who: String = host.my_seat if owner == "" else owner
	var mine: bool = who == host.my_seat
	var counter: Vector3 = host._pawn_position() + Vector3(0, 0.8, 0)
	var sold: Array = cards.filter(func(card): return is_instance_valid(card) and uids.has(card.uid))
	var spread := minf(Motion.ACT, Motion.STAGGER * maxi(0, sold.size() - 1))
	var back := Vector3.INF
	for i in sold.size():
		var card: CardEntity = sold[i]
		if back == Vector3.INF:
			back = card.global_position
		host.entities.erase(card.uid)
		if mine:
			motion._suck_into(card, counter)
		else:
			host.layout.kill_bot_move(card.uid)
			var tween: Tween = motion.pawn_into(card, counter, spread * float(i) / maxf(1, sold.size() - 1))
			_pawn_moves.append({"card": card, "tween": tween, "retired": true})
	if back == Vector3.INF:
		back = host.layout._free_spot(host.layout.PLAYER_PILE_CASH_ANCHOR, host.my_seat)
	back.y = 0.05
	# 现金回到可操作牌区，不能沿用柜台落点而遮住购牌栏。
	back = host.board.clamp_player_position(back) if mine else host.layout._unit_anchor(who, "cash")
	var fresh: Array = []
	for record in host.state.players[who]["cards"]:
		if not host.entities.has(record["uid"]):
			fresh.append(host._spawn_entity(record, back, mine))
	if mine:
		host.layout._stack_arrivals(fresh, back, 0, true, 1)
	else:
		# 先登记完整到账状态并让现有布局确定归宿，动画只搬这批持有的实体。
		host.layout._layout_bot_idle()
		for i in fresh.size():
			var card: CardEntity = fresh[i]
			var target: Vector3 = host.layout._bot_flight.get(card.uid, {}).get("at", card.position)
			host.layout.kill_bot_move(card.uid)
			var tween: Tween = motion._fly_from(card, counter, target, i, fresh.size(), motion.PAWN_TRAVEL_TIME + spread)
			_pawn_moves.append({"card": card, "tween": tween, "retired": false, "at": target})
		set_process(pawn_busy())
	host.sfx.play("pawn")
	host._event_feedback("pawn", host._pawn_position() + Vector3(0, 1.0, 0), Palette.semantic("cash"), 12)

func pawn_busy() -> bool:
	return _pawn_moves.any(func(move):
		var tween: Tween = move["tween"]
		return tween != null and tween.is_valid() and tween.is_running())

func _process(_delta: float) -> void:
	if not pawn_busy():
		_pawn_moves.clear()
		set_process(false)
		pawn_finished.emit()

## 换局/认输立即结束表现；钱已由裁决到账，收束实体不再扫描或修改业务状态。
func cancel_pawn() -> void:
	if _pawn_moves.is_empty():
		return
	for move in _pawn_moves:
		var card: CardEntity = move["card"] if is_instance_valid(move["card"]) else null
		var tween: Tween = move["tween"]
		if tween == null or not tween.is_valid() or not tween.is_running():
			continue
		if card == null:
			tween.kill()
			continue
		if move["retired"]:
			tween.kill()
			card.queue_free()
		elif card.get_meta("fly_tw", null) == tween:
			_motion()._cancel_fly(card)
			card.position = move["at"]
		else:
			tween.kill()
	_pawn_moves.clear()
	set_process(false)
	pawn_finished.emit()

func pay_recipe(uids: Array, at: Vector3) -> int:
	var motion: Node = _motion()
	var count := 0
	var first := Vector3.INF
	for uid in uids:
		if not host.entities.has(uid) or not is_instance_valid(host.entities[uid]):
			continue
		var card: CardEntity = host.entities[uid]
		if first == Vector3.INF:
			first = card.position
		motion._cancel_fly(card)
		var delay := float(count) * Motion.STAGGER
		motion._suck_into(card, at + Vector3(0, 0.3, 0), delay)
		motion.delayed_sound("pay", delay)
		host.entities.erase(uid)
		count += 1
	if count > 0 and _visible():
		Feedback.trace(host, "payment", first, at + Vector3.UP * 0.3, Palette.semantic("cash"), Motion.TRANSFER)
	return count

## 正式牌桌与教学共用一组结算演出；裁决与实体差分由调用方提供。
## 每次等待后先验证所属局面，旧演出不得继续写新局或恢复后的正式牌桌。
func present_combo(combo: Dictionary, resolve: Callable, current: Callable,
		synchronize: Callable, timer: Callable, announce: Callable,
		show_time := 0.5, done_time := 0.7) -> Dictionary:
	if not current.is_valid() or not current.call(): return _presentation_cancelled()
	var owner: String = combo["owner"]
	var effect: Dictionary = combo["eval"]
	var members := _members(combo["uids"])
	for card in members: card.set_highlight(true)
	prepare_combo(combo)
	if announce.is_valid(): announce.call("prepare", {})
	await _wait_presentation(timer.call(show_time).timeout)
	if not current.is_valid() or not current.call(): return _presentation_cancelled()
	# 升级会吃掉材料，中心必须在裁决/同步之前取；保留正式演出的中心算法。
	var center := Vector3(0, 0.6, 0)
	var alive := 0
	for card in members:
		if is_instance_valid(card):
			center += card.global_position
			alive += 1
	if alive > 0: center /= float(alive)
	var settled: Dictionary = await resolve.call()
	if not current.is_valid() or not current.call(): return _presentation_cancelled()
	var resolution: Dictionary = settled.get("resolution", {})
	if not settled.get("ok", false) or resolution.is_empty():
		for card in members:
			if is_instance_valid(card): card.set_highlight(false)
		if announce.is_valid(): announce.call("error", settled)
		synchronize.call(settled, null)
		return settled
	var resolved: bool = resolution.get("resolved", false)
	if resolved:
		var pay: Array = resolution.get("paid_uids", [])
		var paid := pay_recipe(pay, payment_animation_target(owner, combo)) if not pay.is_empty() else 0
		if paid > 0:
			await _wait_presentation(timer.call(suck_batch_time(paid)).timeout)
			if not current.is_valid() or not current.call(): return _presentation_cancelled()
		if effect["type"] == "upgrade":
			var consumed := consume_upgrade(combo, center)
			if consumed > 0:
				await _wait_presentation(timer.call(suck_batch_time(consumed)).timeout)
				if not current.is_valid() or not current.call(): return _presentation_cancelled()
	var stamped: CardEntity = null
	if not resolved:
		host.sfx.play("combo_broken")
		for card in members:
			if is_instance_valid(card):
				card.set_highlight(true, Color(1.3, 0.5, 0.5))
				if card.def_id == str(effect["leader"]) and stamped == null:
					stamped = card
		if stamped != null: stamped.set_void_stamp(true)
	else:
		combo_feedback(effect, center + Vector3(0, 0.6, 0), combo)
	if announce.is_valid(): announce.call("result", settled)
	# 调用方只能同步本次裁决的产出；成功的新卡从原组合飞出。
	var known: Dictionary = host.entities.duplicate()
	synchronize.call(settled, center if resolved and effect["type"] != "attack" else null)
	var arrivals: Array = []
	for uid in host.entities:
		if not known.has(uid): arrivals.append(host.entities[uid])
	await _wait_presentation(timer.call(done_time).timeout)
	if not current.is_valid() or not current.call(): return _presentation_cancelled()
	# 固定结果节拍之外，还要等这批真正落地；不能靠估算动画时长推进教学。
	while _arrival_motions_pending(arrivals):
		await _wait_presentation(get_tree().process_frame)
		if not current.is_valid() or not current.call(): return _presentation_cancelled()
	for card in members:
		if is_instance_valid(card): card.set_highlight(false)
	if is_instance_valid(stamped): stamped.set_void_stamp(false)
	return settled

func _wait_presentation(source: Signal) -> void:
	# SceneTreeTimer会活过牌桌。经子节点转发后，销毁本呈现器会自动断开源信号，
	# 不会让旧协程在所属脚本已销毁后恢复（那时current检查也已经来不及）。
	var beat := PresentationBeat.new()
	add_child(beat)
	source.connect(beat.complete, CONNECT_ONE_SHOT)
	await beat.finished
	beat.queue_free()

func _arrival_motions_pending(cards: Array) -> bool:
	for card in cards:
		if not is_instance_valid(card) or not card.has_meta("fly_tw"): continue
		var tween: Variant = card.get_meta("fly_tw")
		if tween is Tween and tween.is_valid() and tween.is_running(): return true
	return false

func _presentation_cancelled() -> Dictionary:
	return {"ok": false, "code": "cancelled", "reason": "牌局已切换"}

func payment_animation_target(owner: String, combo: Dictionary) -> Vector3:
	# 现金换用户时，付款与新用户共用下一张到货的落点；preview不改到货台账。
	var effect: Dictionary = combo.get("eval", {})
	if effect.get("type", "") == "production" and effect.get("output_res", "") == CardDB.RES_USER \
		and host.layout.has_method("preview_arrival_spot"):
		return host.layout.preview_arrival_spot(owner, {"def_id": CardDB.unit_id(CardDB.RES_USER)})
	return host.layout.payment_spot(owner, CardDB.RES_CASH)

func suck_batch_time(count: int) -> float:
	return Motion.STAGGER * float(count - 1) + Motion.TRANSFER if count > 0 else 0.0

func combo_feedback(effect: Dictionary, at: Vector3, combo: Dictionary = {}) -> void:
	var members := _members(combo.get("uids", []))
	if not members.is_empty():
		for card in members:
			if card.def_id == effect.get("leader", "") or (effect["type"] == "production" and card.def_id == "yinqing996"):
				card.pulse_feedback("produce" if effect["type"] == "production" else "upgrade")
	match effect["type"]:
		"production":
			var color := Palette.semantic("cash" if effect["output_res"] == CardDB.RES_CASH else "user")
			host._event_feedback("production", at, color, 12)
			if _visible():
				Feedback.receipt(host, "production", at, "+%d %s" % [int(effect["output_n"]), CardDB.res_label(effect["output_res"])], color)
		"upgrade":
			host.sfx.play("upgrade")
			host._event_feedback("upgrade", at, Palette.plate_color("plate_t3", "band"))
			if _visible():
				Feedback.outline(host, "upgrade", at, Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z), Palette.semantic("cash"))
				Feedback.receipt(host, "upgrade", at, "升级完成", Palette.semantic("cash"))
		"attack":
			host.sfx.play("attack")

func attack_feedback(at: Vector3, attacker := "", resource := "", round_num := -1, attack_combos: Array = []) -> void:
	host.sfx.play("attack")
	if at == Vector3.INF:
		return
	host._event_feedback("attack", at, Palette.semantic("danger"), 14)
	if not _visible():
		return
	Feedback.outline(host, "impact", at, Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z), Palette.semantic("danger"), Motion.TEAR)
	Feedback.receipt(host, "attack", at, "竞争打击", Palette.semantic("danger"))
	# 点数可能由多组武器汇合，每张真实的对应武器响应，不能凭空造一个攻击起点。
	for combo in host.state.combos if attack_combos.is_empty() else attack_combos:
		var effect: Dictionary = combo["eval"]
		if combo["owner"] != attacker or effect.get("type") != "attack":
			continue
		if resource != "" and effect.get("attack_res") != resource:
			continue
		for card in _members(combo["uids"]):
			if card.def_id == effect.get("leader", ""):
				var record: Dictionary = host.state.find_card(attacker, card.uid)
				if int(record.get("fired_round", -1)) != (host.state.round_num if round_num < 0 else round_num):
					continue
				card.pulse_feedback("attack")
				break

## 一次点摞沿用正式牌局的挑靶顺序：先拆配方，再打同摞富余单位。
## 每次裁决之后重新查询，不能缓存已经被上一击破坏的组合目标。
func pile_attack_target(key: String, pools: Dictionary) -> Dictionary:
	var uids: Array = host.layout._bot_pile_uids.get(key, [])
	if key == "" or uids.is_empty(): return {}
	var core := {}
	var spare := {}
	for target: Dictionary in host.state.attack_targets(host.foe_seat):
		if not target["uids"].any(func(uid): return uids.has(uid)) \
			or not GameState.target_affordable(target, pools): continue
		if target["kind"] == "combo":
			if core.is_empty(): core = target
		elif spare.is_empty(): spare = target
	return core if not core.is_empty() else spare

## 一次点摞的整批裁决只有这一份。正式传Transport.submit，教学传Session.attack；
## 每击后重新取真实点数与目标，直到摞清空、点数用尽或本局结束。
func apply_pile_attack(key: String, submit: Callable, pools: Callable, current: Callable) -> Dictionary:
	var batch := {"first_target": {}, "center": Vector3.INF, "removed": [],
		"result": {"ok": false}, "cancelled": false}
	while current.call() and host.state.winner == "":
		var target := pile_attack_target(key, pools.call())
		if target.is_empty(): break
		if batch["first_target"].is_empty():
			batch["first_target"] = target
			batch["center"] = attack_target_center(target)
		var result: Dictionary = await submit.call(target)
		if not current.call():
			batch["cancelled"] = true
			return batch
		if not result.get("ok", false):
			if batch["removed"].is_empty(): batch["result"] = result
			break
		batch["result"] = result
		batch["removed"].append_array(result.get("removed", []))
	return batch

func attack_target_center(target: Dictionary) -> Vector3:
	for uid in target.get("uids", []):
		if host.entities.has(uid) and is_instance_valid(host.entities[uid]):
			return host.entities[uid].global_position + Vector3(0, 0.5, 0)
	return Vector3(0, 1, 0)

## 收拢时只点亮摞顶，展开时只点亮真正的资源靶；手势与攻击共用这份集合。
func highlight_attack_targets(pools: Dictionary) -> Array:
	var highlighted: Array = []
	var piles := {}
	for target: Dictionary in host.state.affordable_targets(host.foe_seat, pools):
		for uid in target["uids"]:
			if not host.entities.has(uid) or not is_instance_valid(host.entities[uid]): continue
			var key := str(host.layout._bot_pile_of_uid.get(uid, ""))
			if key != "" and bool(host.layout._bot_pile_compact.get(key, true)):
				piles[key] = true
			else:
				highlighted.append(host.entities[uid])
	for key in piles:
		var uids: Array = host.layout._bot_pile_uids.get(key, [])
		if not uids.is_empty() and host.entities.has(uids[0]) and is_instance_valid(host.entities[uids[0]]):
			highlighted.append(host.entities[uids[0]])
	for card in highlighted: card.set_highlight(true, Color(1.5, 0.55, 0.45))
	return highlighted

## 正式对局、对手回放与教学都先从实体表摘除，再交唯一的整摞撕牌实现。
func animate_removed(removed: Array, toward_ai: bool, hands: Node, held_cards: Array = []) -> float:
	var cards: Array = held_cards.filter(func(card): return is_instance_valid(card))
	for uid in removed:
		if host.entities.has(uid) and is_instance_valid(host.entities[uid]) and not cards.has(host.entities[uid]):
			cards.append(host.entities[uid])
	for card in cards:
		host.entities.erase(card.uid)
		host.layout.kill_bot_move(card.uid)
	return _motion().tear_batch(cards, hands, Vector3(0, 4, -2) if toward_ai else Vector3(0, 4, 2))

## 命中、抓握、撕开和等整批退场是同一条演出链；调用方只负责各自的局面有效期。
func present_attack(removed: Array, center: Vector3, attacker: String, resource: String,
		hands: Node, timer: Callable, current: Callable, held_cards: Array = [], track: Callable = Callable(),
		round_num := -1, attack_combos: Array = []) -> bool:
	if not current.call(): return false
	attack_feedback(center, attacker, resource, round_num, attack_combos)
	var retiring := _members(removed)
	retiring.append_array(held_cards)
	var duration := animate_removed(removed, attacker != host.my_seat, hands, held_cards)
	if track.is_valid(): track.call(duration)
	if duration > 0.0:
		await _wait_presentation(timer.call(duration).timeout)
	while current.call() and retiring.any(func(card): return is_instance_valid(card)):
		await _wait_presentation(get_tree().process_frame)
	return current.call()

## 同步裁决的事件也按正式对手回放的 batch 标识收拢，不能把一摞拆成 N 次演出。
func present_attack_events(events: Array, hands: Node, timer: Callable, current: Callable) -> bool:
	var batches: Array = []
	var armed := {}
	for event: Dictionary in events:
		if event.get("op") == Intent.OP_ARM:
			armed[str(event.get("seat", ""))] = event.get("fired_combos", [])
		if event.get("op") != Intent.OP_ATTACK: continue
		var target: Dictionary = event.get("target", {})
		var key := GameState.target_batch(target)
		if key == "" or batches.is_empty() or batches[-1]["key"] != key \
			or batches[-1]["seat"] != event.get("seat") or batches[-1]["round"] != event.get("round", -1):
			batches.append({"key": key, "seat": str(event.get("seat", "")), "target": target,
				"round": int(event.get("round", -1)), "removed": [], "combos": armed.get(str(event.get("seat", "")), [])})
		batches[-1]["removed"].append_array(event.get("removed", []))
	for batch: Dictionary in batches:
		if not await present_attack(batch["removed"], attack_target_center(batch["target"]),
			batch["seat"], str(batch["target"].get("res", "")), hands, timer, current, [], Callable(), batch["round"], batch["combos"]):
			return false
	return current.call()

func shield_feedback(cards: Array) -> void:
	var protected := cards.filter(func(card): return is_instance_valid(card) and card._shield_on)
	if protected.is_empty() or not _visible():
		return
	# 一摞只画一个拒挡轮廓，每张真正受保护的卡同步响应。
	for card in protected:
		card.pulse_feedback("shield")
	var outline_cards: Array = protected.duplicate()
	# 受保护单位可能压在核心下方；轮廓围住真实牌摞，不能画在被遮挡的底层。
	for group in host.board.groups:
		if group["cards"].any(func(card): return protected.has(card)):
			outline_cards = group["cards"]
			break
	for combo in host.state.combos:
		if combo["uids"].any(func(uid): return protected.any(func(card): return card.uid == int(uid))):
			outline_cards = _members(combo["uids"])
			break
	_outline_cards("shield", outline_cards, Palette.semantic("info"))

func group_ready(cards: Array) -> void:
	if cards.is_empty() or not _visible():
		return
	var data: Array = []
	for card in cards:
		if is_instance_valid(card):
			data.append({"uid": card.uid, "def_id": card.def_id})
	var effect := ComboRules.evaluate(data)
	if not effect.get("valid", false):
		return
	for card in cards:
		if is_instance_valid(card):
			card.pulse_feedback("ready")
	_outline_cards("ready", cards, Palette.semantic("success"))

func _outline_cards(event: String, cards: Array, color: Color) -> void:
	var lower := Vector3.INF
	var upper := -Vector3.INF
	for card in cards:
		if is_instance_valid(card):
			var at: Vector3 = host.board.rest_pos(card)
			lower = lower.min(at)
			upper = upper.max(at)
	if lower == Vector3.INF:
		return
	var center := (lower + upper) * 0.5
	center.y = upper.y
	var extent := Vector2(upper.x - lower.x + CardEntity.CARD_SIZE.x, upper.z - lower.z + CardEntity.CARD_SIZE.z)
	Feedback.outline(host, event, center, extent, color)

func prepare_combo(combo: Dictionary) -> void:
	if not _visible():
		return
	var effect: Dictionary = combo["eval"]
	var members := _members(combo["uids"])
	for card in members:
		if card.def_id == effect.get("leader", ""):
			card.pulse_feedback("ready", Palette.semantic("pending"))
		else:
			card.pulse_feedback("ready", CardArt.accent_color(card.def_id))

## 升级材料收束到原组合，区别于受击撕毁。真实裁决已决定移除哪些材料。
func consume_upgrade(combo: Dictionary, center: Vector3) -> int:
	var motion := _motion()
	var count := 0
	for card in _members(combo.get("uids", [])):
		if not host.state.find_card(combo["owner"], card.uid).is_empty():
			continue
		motion._suck_into(card, center + Vector3.UP * 0.2, count * Motion.STAGGER)
		host.entities.erase(card.uid)
		count += 1
	return count

func _members(uids: Array) -> Array:
	var cards: Array = []
	for uid in uids:
		if host.entities.has(int(uid)) and is_instance_valid(host.entities[int(uid)]):
			cards.append(host.entities[int(uid)])
	return cards

func _visible() -> bool:
	return not host.get_viewport().disable_3d

func _drop_price(index: int) -> void:
	if index < 0 or index >= host.market_price_labels.size():
		return
	var label: Node = host.market_price_labels[index]
	if is_instance_valid(label):
		if label.has_method("retire"):
			label.retire()
		else:
			label.queue_free()
	host.market_price_labels.remove_at(index)

func _motion() -> Node:
	# main.sfx可由测试替身或声音设置更新，调用时读取当前的音效对象。
	host._card_motion.sfx = host.sfx
	return host._card_motion
