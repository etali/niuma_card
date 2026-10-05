# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name DrawerTableLayout
extends "res://scenes/settle_layout.gd"

## 抽屉专用物理布局：卡牌保持原始尺寸，只收紧世界边界与落点网格。
const TableRegions = preload("res://scenes/table_regions.gd")
const DRAWER_WORLD_RECT := Rect2(-10.8, -5.25, 21.6, 11.3)
const DRAWER_PLAYER_RECT := Rect2(-10.0, 1.2, 20.0, 4.5)
const DRAWER_FOE_RECT := Rect2(-10.0, -4.8, 20.0, 2.6)
const DRAWER_MARKET_Z := TableRegions.DRAWER_MARKET_Z
const DRAWER_PLAYER_CASH_ANCHOR := Vector3(-7.6, 0.05, 2.1)
const DRAWER_PLAYER_USER_ANCHOR := Vector3(4.0, 0.05, 2.1)
const DRAWER_FOE_CASH_ANCHOR := Vector3(-7.6, 0.05, -3.6)
const DRAWER_FOE_USER_ANCHOR := Vector3(4.0, 0.05, -3.6)
const DRAWER_PILE_CHUNK := 10
const DRAWER_PILE_CAP := 8
const DRAWER_ROW_Z := [2.1, 4.4]
const DRAWER_FOE_ROW_Z := [-3.65, -2.65]
const DRAWER_SLOT_PITCH := 2.25

var _drawer_arr_count := {}
var _drawer_arr_taken: Array = []
var _drawer_arr_base := {}

func bind(main: Node) -> void:
	super.bind(main)
	if board != null:
		board.table_bounds = DRAWER_WORLD_RECT
		board.player_bounds = DRAWER_PLAYER_RECT
		board.player_min_z = DRAWER_PLAYER_RECT.position.y
		board.player_max_z = DRAWER_PLAYER_RECT.end.y

func _center_bounds(who: String) -> Rect2:
	var raw := board.player_bounds if who == _main.my_seat else DRAWER_FOE_RECT
	var hx := CardEntity.CARD_SIZE.x * 0.5 + 0.04
	var hz := CardEntity.CARD_SIZE.z * 0.5 + 0.04
	return Rect2(raw.position.x + hx, raw.position.y + hz,
		maxf(0.0, raw.size.x - hx * 2.0), maxf(0.0, raw.size.y - hz * 2.0))

func _unit_anchor(who: String, def_id: String) -> Vector3:
	var def := CardDB.get_def(def_id)
	var foe: bool = who == _main.foe_seat
	if def.get("kind") == CardDB.KIND_UNIT:
		if def.get("res") == CardDB.RES_CASH:
			return DRAWER_FOE_CASH_ANCHOR if foe else DRAWER_PLAYER_CASH_ANCHOR
		return DRAWER_FOE_USER_ANCHOR if foe else DRAWER_PLAYER_USER_ANCHOR
	return Vector3(0.0, 0.05, -1.7 if foe else 2.1)

func _free_spot(anchor: Vector3, who: String, claimed: Array = [],
		ignore: Dictionary = {}) -> Vector3:
	var safe := _center_bounds(who)
	if not safe.has_area():
		return anchor
	var x_step: float = maxf(DRAWER_SLOT_PITCH,
		CardEntity.CARD_SIZE.x + Board.SIDE_W + Board.SIDE_GAP + 0.15)
	var z_step: float = CardEntity.CARD_SIZE.z + 0.30
	var blockers := _obstacles(claimed, ignore)
	var best := Vector3(clampf(anchor.x, safe.position.x, safe.end.x), anchor.y,
		clampf(anchor.z, safe.position.y, safe.end.y))
	if who == _main.my_seat:
		best = board.clamp_player_position(best)
	var best_dist := INF
	var cols: int = maxi(1, int(ceil(safe.size.x / x_step)) + 1)
	var rows: int = maxi(1, int(ceil(safe.size.y / z_step)) + 1)
	for row in rows:
		for col in cols:
			var p := Vector3(minf(safe.position.x + float(col) * x_step, safe.end.x),
				anchor.y, minf(safe.position.y + float(row) * z_step, safe.end.y))
			if who == _main.my_seat:
				p = board.clamp_player_position(p)
			if _clash_at(p, blockers):
				continue
			var d := p.distance_squared_to(anchor)
			if d < best_dist:
				best_dist = d
				best = p
	return best

func _layout_bot_idle() -> void:
	_layout_bot_zone()

func _layout_bot_zone() -> void:
	board.clear_side_badges()
	_bot_pile_of_uid.clear()
	_bot_pile_uids.clear()
	_bot_pile_compact.clear()
	var piles := _bot_piles()
	var safe := _center_bounds(_main.foe_seat)
	var other: Array = []
	for pile in piles:
		var key := str(pile["key"])
		if key.begins_with("bot_cash"):
			_place_drawer_bot_pile(pile, Vector3(DRAWER_FOE_CASH_ANCHOR.x, 0.05,
				clampf(DRAWER_FOE_CASH_ANCHOR.z, safe.position.y,
					safe.end.y - Board.capped_offset((pile["cards"] as Array).size(), 0, DRAWER_PILE_CAP).z)))
		elif key.begins_with("bot_user"):
			_place_drawer_bot_pile(pile, Vector3(DRAWER_FOE_USER_ANCHOR.x, 0.05,
				clampf(DRAWER_FOE_USER_ANCHOR.z, safe.position.y,
					safe.end.y - Board.capped_offset((pile["cards"] as Array).size(), 0, DRAWER_PILE_CAP).z)))
		else:
			other.append(pile)
	# 资源有固定席位；其他牌按独立列和可见标题行铺开，不把溢出项全压到最后一格。
	var columns := [-9.1, -5.0, -2.4, 0.2, 6.6, 9.1]
	var rows := maxi(1, ceili(float(other.size()) / float(columns.size())))
	for i in other.size():
		var row: int = i / columns.size()
		var pile: Dictionary = other[i]
		var span: float = Board.capped_offset((pile["cards"] as Array).size(), 0, DRAWER_PILE_CAP).z
		var far := safe.position.y
		var near := maxf(far, safe.end.y - span)
		var z := lerpf(far, near, float(row) / float(maxi(rows - 1, 1)))
		_place_drawer_bot_pile(pile, Vector3(float(columns[i % columns.size()]), 0.05, z))
	_flush_bot_moves()

func _place_drawer_bot_pile(pile: Dictionary, at: Vector3) -> void:
	_refresh_bot_pile_progress(pile)
	var cards: Array = pile["cards"]
	var key := str(pile["key"])
	var n := cards.size()
	for j in n:
		var e: CardEntity = cards[j]
		e.freeze = true
		_bot_move(e, at + Board.capped_offset(n, j, DRAWER_PILE_CAP))
		_bot_pile_of_uid[e.uid] = key
	_bot_pile_uids[key] = cards.map(func(c: CardEntity) -> int: return c.uid)
	_bot_pile_compact[key] = true
	if n >= 2:
		board.show_side_badges(key, cards, at + Board.capped_offset(n, 0, DRAWER_PILE_CAP))

func _tidy_player_idle() -> void:
	for g in board.groups.duplicate():
		var pure := true
		for c in g["cards"]:
			if CardDB.get_def(c.def_id).get("kind") != CardDB.KIND_UNIT:
				pure = false
				break
		if pure:
			board._remove_group(g)
	var piles := _collect_idle_units(_main.my_seat)
	_group_pile(piles[0], DRAWER_PLAYER_CASH_ANCHOR)
	_group_pile(piles[1], DRAWER_PLAYER_USER_ANCHOR)

func _group_pile(pile: Array, anchor: Vector3) -> void:
	if pile.is_empty():
		return
	var res: String = str(CardDB.get_def(pile[0].def_id).get("res", CardDB.RES_CASH))
	var cols: Array = _drawer_resource_columns(res)
	var taken: Array = []
	var mine := {}
	for c in pile:
		if is_instance_valid(c):
			mine[c.uid] = true
	# 每 10 张作为一次 compact 组；同一列的更多组由 _pile_host 合并，
	# 因而张数增长只增加清单计数，不把卡片推到世界边界外。
	_stack_arrivals(pile, anchor, DRAWER_PILE_CHUNK, false, 1, cols, taken, false, mine)

func _drawer_resource_columns(res: String) -> Array:
	if res == CardDB.RES_USER:
		return [3.3, 5.95, 8.6]
	return [-7.6, -4.95, -2.3]

func _pile_slot(anchor: Vector3, taken: Array, skip: Dictionary = {},
		col_xs: Array = []) -> Vector3:
	var cols: Array = col_xs if not col_xs.is_empty() else _drawer_resource_columns(CardDB.RES_CASH)
	var safe := _center_bounds(_main.my_seat)
	var best := Vector3(clampf(anchor.x, safe.position.x, safe.end.x), 0.05,
		clampf(anchor.z, safe.position.y, safe.end.y))
	best = board.clamp_player_position(best)
	for x in cols:
		for z in DRAWER_ROW_Z:
			var candidate := Vector3(clampf(float(x), safe.position.x, safe.end.x), 0.05,
				clampf(float(z), safe.position.y, safe.end.y))
			candidate = board.clamp_player_position(candidate)
			var blocked := false
			for t in taken:
				if absf((t as Vector3).x - candidate.x) < 1.35 and absf((t as Vector3).z - candidate.z) < 2.25:
					blocked = true
					break
			if blocked:
				continue
			for g in board.groups:
				if not bool(g.get("compact", false)) or g["cards"].is_empty():
					continue
				var origin := board.rest_origin(g)
				if absf(origin.x - candidate.x) < 1.35 and absf(origin.z - candidate.z) < 2.25:
					blocked = true
					break
			if not blocked:
				return candidate
	return best

func _pile_host(spot: Vector3, def_id: String) -> Variant:
	for g in board.groups:
		if not bool(g.get("compact", false)) or g["cards"].is_empty():
			continue
		var origin := board.rest_origin(g)
		if absf(origin.x - spot.x) >= 1.35 or absf(origin.z - spot.z) >= 2.25:
			continue
		var core: CardEntity = g["cards"][0]
		if is_instance_valid(core) and core.def_id == def_id:
			return g
	return null

func begin_arrivals() -> void:
	_drawer_arr_count.clear()
	_drawer_arr_taken.clear()
	_drawer_arr_base.clear()
	_arr_open = true
	_arr_claimed.clear()
	_arr_mine.clear()

func end_arrivals() -> void:
	_arr_open = false
	_drawer_arr_count.clear()
	_drawer_arr_taken.clear()
	_drawer_arr_base.clear()
	_arr_claimed.clear()
	_arr_mine.clear()

func arrival_spot(who: String, card: Dictionary) -> Vector3:
	var def := CardDB.get_def(card["def_id"])
	var anchor := _unit_anchor(who, card["def_id"])
	if not _arr_open or who != _main.my_seat or def.get("kind") != CardDB.KIND_UNIT:
		return _free_spot(anchor, who, _arr_claimed)
	var res: String = str(def.get("res", CardDB.RES_CASH))
	var cols: Array = _drawer_resource_columns(res)
	var idx: int = int(_drawer_arr_count.get(res, 0))
	_drawer_arr_count[res] = idx + 1
	var part: int = idx / DRAWER_PILE_CHUNK
	var key := "%s:%d" % [res, part]
	if not _drawer_arr_base.has(key):
		_drawer_arr_base[key] = _pile_slot(anchor, _drawer_arr_taken, _arr_mine, cols)
		_drawer_arr_taken.append(_drawer_arr_base[key])
	var spot: Vector3 = _drawer_arr_base[key] + Board.compact_offset(DRAWER_PILE_CHUNK, idx % DRAWER_PILE_CHUNK)
	_arr_draw_claim(spot, card)
	return spot

func _arr_draw_claim(spot: Vector3, card: Dictionary) -> void:
	_arr_claimed.append(spot)
	_arr_mine[card["uid"]] = true

func _stack_settled(known: Dictionary) -> void:
	var cash: Array = []
	var user: Array = []
	for rec in _main.state.players[_main.my_seat]["cards"]:
		var uid := int(rec["uid"])
		if known.has(uid) or not entities.has(uid):
			continue
		var e: CardEntity = entities[uid]
		if not is_instance_valid(e):
			continue
		var def := CardDB.get_def(rec["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT:
			continue
		(cash if def.get("res") == CardDB.RES_CASH else user).append(e)
	var taken: Array = []
	if not cash.is_empty():
		_stack_arrivals(cash, DRAWER_PLAYER_CASH_ANCHOR, DRAWER_PILE_CHUNK, false, 1,
			_drawer_resource_columns(CardDB.RES_CASH), taken, false, {})
	if not user.is_empty():
		_stack_arrivals(user, DRAWER_PLAYER_USER_ANCHOR, DRAWER_PILE_CHUNK, false, 1,
			_drawer_resource_columns(CardDB.RES_USER), taken, false, {})
