# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 录像的表现信息独立于游戏规则：精确卡位、牌摞形态和货架空槽都可恢复。
static func capture(host: Node) -> Dictionary:
	var positions := {}
	for uid in host.entities:
		var card: CardEntity = host.entities[uid]
		if is_instance_valid(card):
			var at: Vector3 = host.board.rest_pos(card)
			if host.layout._ai_flight.has(int(uid)) and host.layout._ai_tw.has(int(uid)):
				at = host.layout._ai_flight[int(uid)]["at"]
			positions[str(uid)] = [at.x, at.y, at.z]
	var groups: Array = []
	for group in host.board.groups:
		var uids: Array = []
		for card in group["cards"]:
			if is_instance_valid(card) and host.entities.has(card.uid):
				uids.append(card.uid)
		if not uids.is_empty():
			groups.append({"uids": uids, "compact": bool(group.get("compact", false))})
	var market: Array = []
	for card in host.market_cards:
		if not is_instance_valid(card):
			continue
		# 商品入场动画可能尚在进行，用当前回合的固定槽位而不是半空位置。
		var at: Vector3 = card.get_meta("market_slot", card.position)
		market.append([at.x, at.y, at.z])
	return {"positions": positions, "groups": groups, "market": market,
		"my_seat": host.my_seat, "phase": host.phase, "actor": host._actor}

static func restore(host: Node, view: Dictionary, animated := false) -> void:
	if view.is_empty():
		return
	for group in host.board.groups.duplicate():
		host.board._remove_group(group)
	for entry in view.get("groups", []):
		var cards: Array = []
		for uid in entry.get("uids", []):
			if host.entities.has(int(uid)):
				cards.append(host.entities[int(uid)])
		if not cards.is_empty():
			host.board.groups.append(host.board.make_group(cards, bool(entry.get("compact", false)), true))
	for uid in view.get("positions", {}):
		if not host.entities.has(int(uid)):
			continue
		var pos: Variant = view["positions"][uid]
		if not pos is Array or pos.size() != 3:
			continue
		var card: CardEntity = host.entities[int(uid)]
		var at := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		host.layout.kill_ai_move(card.uid)
		host.board._stop_move(card, false)
		host._card_motion._cancel_fly(card)
		card.freeze = true
		if animated:
			host._card_motion._move_to(card, at)
		else:
			card.position = at
	for group in host.board.groups:
		host.board.refresh_group(group)

static func valid(view: Variant) -> bool:
	if not view is Dictionary:
		return false
	for key in ["positions"]:
		if not view.get(key, {}) is Dictionary:
			return false
	for key in ["groups", "market"]:
		if not view.get(key, []) is Array:
			return false
	for pos in view.get("positions", {}).values() + view.get("market", []):
		if not pos is Array or pos.size() != 3:
			return false
		for value in pos:
			if not value is int and not value is float:
				return false
	for group in view.get("groups", []):
		if not group is Dictionary or not group.get("uids", []) is Array:
			return false
		for uid in group.get("uids", []):
			if not uid is int and not uid is float:
				return false
	return true
