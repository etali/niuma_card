# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

## 交易与组合的表现入口。正式对局和教学牌桌均传入真实裁决结果，
## 共用卡牌回收、落位、反馈和动作音效，不在演示层另写交易动画。
const Motion = preload("res://scenes/ui_motion.gd")
const Feedback = preload("res://scenes/table_feedback.gd")
const Regions = preload("res://scenes/table_regions.gd")
var host: Node3D
signal pawn_finished
var _pawn_moves: Array[Dictionary] = []

func bind(table: Node3D) -> void:
	host = table
	set_process(false)
	host.board.card_picked.connect(func(_card): host.sfx.play("card_pickup"))
	host.board.pile_toggled.connect(func(): host.sfx.play("pile_toggle"))
	host.board.card_dropped_table.connect(func(): host.sfx.play("card_drop"))
	host.board.group_completed.connect(func(): host.sfx.play("combo_complete"))
	host.board.group_formed.connect(group_ready)

func purchase(index: int, card: CardEntity, result: Dictionary) -> void:
	var motion: Node = _motion()
	for uid in result["removed_uids"]:
		if host.entities.has(uid):
			motion._suck_into(host.entities[uid], card.position + Vector3(0, 0.2, 0))
			host.entities.erase(uid)
	host.market_cards.remove_at(index)
	_drop_price(index)
	# 到货位置由同一套占用/避让规则选定，在登记买到的实体之前计算。
	var target: Vector3 = host.layout._free_spot(
		Vector3(randf_range(-5, 5), 0.2, Regions.PLAYER_ZONE_Z + 1.6), host.my_seat)
	target.y = 0.2
	card.is_market = false
	card.draggable = true
	card.freeze = true
	card.uid = int(result["new_uid"])
	host.entities[card.uid] = card
	# 现金完全吸收后商品才抬起，不能向上穿过仍在付款的现金摞。
	motion.move_above_table(card, target, Motion.TRANSFER)
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

func combo_feedback(effect: Dictionary, at: Vector3, combo: Dictionary = {}) -> void:
	var members := _members(combo.get("uids", []))
	if not members.is_empty():
		for card in members:
			if card.def_id == effect.get("leader", ""):
				card.pulse_feedback("produce" if effect["type"] == "production" else "upgrade")
	match effect["type"]:
		"production":
			var color := Palette.semantic("cash" if effect["output_res"] == CardDB.RES_CASH else "user")
			host._event_feedback("production", at, color, 12)
		"upgrade":
			host.sfx.play("upgrade")
			host._event_feedback("upgrade", at, Palette.plate_color("plate_t3", "band"))
			if _visible():
				Feedback.outline(host, "upgrade", at, Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z), Palette.semantic("cash"))
		"attack":
			host.sfx.play("attack")

func attack_feedback(at: Vector3, attacker := "", resource := "") -> void:
	host.sfx.play("attack")
	if at == Vector3.INF:
		return
	host._event_feedback("attack", at, Palette.semantic("danger"), 14)
	if not _visible():
		return
	Feedback.outline(host, "impact", at, Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z), Palette.semantic("danger"), Motion.TEAR)
	# 点数可能由多组武器汇合，每张真实的对应武器响应，不能凭空造一个攻击起点。
	for combo in host.state.combos:
		var effect: Dictionary = combo["eval"]
		if combo["owner"] != attacker or effect.get("type") != "attack":
			continue
		if resource != "" and effect.get("attack_res") != resource:
			continue
		for card in _members(combo["uids"]):
			if card.def_id == effect.get("leader", ""):
				var record: Dictionary = host.state.find_card(attacker, card.uid)
				if int(record.get("fired_round", -1)) != host.state.round_num:
					continue
				card.pulse_feedback("attack")
				Feedback.trace(host, "attack", host.board.rest_pos(card) + Vector3.UP * 0.12,
					at + Vector3.UP * 0.10, Palette.semantic("danger"), Motion.ANTICIPATE + Motion.STAGGER)
				break

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
		label.queue_free()
	host.market_price_labels.remove_at(index)

func _motion() -> Node:
	# main.sfx可由测试替身或声音设置更新，调用时读取当前的音效对象。
	host._card_motion.sfx = host.sfx
	return host._card_motion
