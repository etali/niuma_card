# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node3D

## 教学只定义初始局面和操作顺序。摆桌、卡位、交易、落牌、撕牌及音效
## 分别使用正式对局的 TableScene / DrawerTableLayout / TableActions / CardMotion。
const ResultPresentation = preload("res://scenes/result_presentation.gd")
signal replay_requested
var result_panel: PanelContainer

const TableScene = preload("res://scenes/table_scene.gd")
const TableActions = preload("res://scenes/table_actions.gd")
const CardMotion = preload("res://scenes/card_motion.gd")
const Layout = preload("res://scenes/drawer_table_layout.gd")
const Regions = preload("res://scenes/table_regions.gd")
const Motion = preload("res://scenes/ui_motion.gd")
const CameraFit = preload("res://scenes/drawer_camera_fit.gd")
const PLAYER_ZONE_Z := Regions.PLAYER_ZONE_Z
const AI_ZONE_Z := Regions.AI_ZONE_Z
const MARKET_Z := Regions.DRAWER_MARKET_Z

var board: Board
var motions: Node
var _card_motion: Node
var _table_scene: RefCounted
var _table_actions: Node
var layout: Node
var sfx: Sfx
var state: GameState
var applier: IntentApply
var camera: Camera3D
var entities: Dictionary = {}
var market_cards: Array[CardEntity] = []
var market_price_labels: Array = []
var my_seat := GameState.PLAYER
var foe_seat := GameState.AI
var foe_piles: Array = []
var demo: Dictionary
var phase := 0
var elapsed := 0.0
var progress := 0.0
var duration := 6.0
var lanes: Array = []
var _input_cards: Array = []
var _input_batches: Array = []
var _pending_arrivals: Array = []
var _pending_combo_feedback: Array = []
var _attack_targets: Array = []
var _attack_clock := 0.0
var _attack_feedback_sent := false
var _arrival_at := INF
var _stack_at := INF
var _known_before: Dictionary = {}
var _caption := ""
var _victory: Label3D
var _purchase_index := -1
var _combo_at := Vector3.ZERO
var _won_announced := false
var last_result: Dictionary = {}
var _winning_seat := GameState.PLAYER
var _attacking_seat := GameState.PLAYER
var result_styler := Callable()
var _result_view: Dictionary = {}

func configure(example: Dictionary, sound: Sfx) -> void:
	demo = example
	_winning_seat = foe_seat if demo.get("lose", false) else my_seat
	_attacking_seat = _winning_seat if demo["mode"] == "eliminate" else my_seat
	sfx = sound
	state = GameState.new()
	# 使用真实的发牌器与卡表权重；示例商品替换其中一个卡位。
	state.set_seed(0)
	state.new_game()
	for who in [my_seat, foe_seat]:
		state.players[who]["cards"].clear()
	state.combos.clear()
	state.winner = ""
	applier = IntentApply.new(state)
	_build_table()
	var mode := str(demo["mode"])
	if mode == "purchase" and not state.market.is_empty():
		_purchase_index = state.market.size() / 2
		state.market[_purchase_index] = demo["target_id"]
	for i in state.market.size():
		var entry: Dictionary = _table_scene.spawn_market_card(board, i, state.market[i], _market_slot(i, state.market.size()))
		market_cards.append(entry["card"])
		market_price_labels.append(entry["price"])

	if mode == "upgrade":
		for variant in demo["variants"]:
			var cards: Array = []
			for input in variant.get("inputs", [{"id": demo["source_id"], "count": variant["count"]}]):
				cards.append_array(_cards(str(input["id"]), int(input["count"]), my_seat))
			lanes.append({"spec": variant, "cards": cards, "at": Vector3.ZERO, "combo_index": -1, "result_uid": -1})
			_input_cards.append_array(cards)
	else:
		for input in demo["inputs"]:
			var owner := GameState.opponent(_winning_seat) if mode == "eliminate" else (_winning_seat if mode == "victory" else my_seat)
			var cards := _cards(str(input["id"]), int(input["count"]), owner)
			_input_batches.append(cards)
			_input_cards.append_array(cards)
	if mode == "attack":
		var hits := int(demo["output"]["count"]) / maxi(1, int(demo["cost"]))
		_attack_targets = _cards(str(demo["output"]["id"]), hits, foe_seat)
	# 其余资源使用开局配置。现金支付/典当用户的正数护栏仍交给真实引擎。
	for who in [my_seat, foe_seat]:
		for res in [CardDB.RES_CASH, CardDB.RES_USER]:
			if (mode == "victory" and who == _winning_seat and res == CardDB.RES_CASH) \
				or (mode == "eliminate" and who == GameState.opponent(_winning_seat) and CardDB.unit_id(res) == demo["inputs"][0]["id"]):
				continue
			var target := int(CardDB.game_rules()["start_cash" if res == CardDB.RES_CASH else "start_user"])
			if who == my_seat:
				if mode == "purchase" and res == CardDB.RES_CASH:
					target = maxi(target, int(demo["price"]) + 1)
				elif bool(demo.get("consume", false)) and res == CardDB.RES_CASH:
					target = maxi(target, int(demo["effect"]["recipe_pay_n"]) + 1)
				elif mode == "pawn" and res == CardDB.RES_USER:
					target = maxi(target, state.resource_count(who, res) + 1)
			_cards(CardDB.unit_id(res), maxi(0, target - state.resource_count(who, res)), who)
	layout._tidy_player_idle()
	layout._layout_ai_idle()
	if mode == "upgrade":
		var safe: Rect2 = layout._center_bounds(my_seat)
		var ignores := {}
		for card in _input_cards:
			ignores[card.uid] = true
		for i in lanes.size():
			var lane: Dictionary = lanes[i]
			var at := Vector3(lerpf(safe.position.x, safe.end.x, float(i + 1) / float(lanes.size() + 1)), 0.05, safe.end.y)
			at = layout._free_spot(at, my_seat, [], ignores)
			lane["at"] = at
			_group(lane["cards"], at)
	elif mode not in ["eliminate", "victory"]:
		for i in _input_batches.size():
			var cards: Array = _input_batches[i]
			var ignored := {}
			for card in cards:
				ignored[card.uid] = true
				board._detach_from_group(card)
			var at: Vector3 = layout._free_spot(Vector3(-1.8 + i * 2.6, 0.05, Layout.DRAWER_ROW_Z[0]), my_seat, [], ignored)
			_group(cards, at)
			if i == 0:
				_combo_at = at
	_caption = str(demo["captions"][0])

func _build_table() -> void:
	_table_scene = TableScene.new(self, true)
	_table_scene._setup_environment()
	_table_scene._setup_table()
	camera = _table_scene.camera
	camera.current = true
	board = _table_scene.create_board()
	board.input_locked = true
	board.set_process(false)
	board.set_process_input(false)
	board.set_process_unhandled_input(false)
	layout = _table_scene.create_layout()
	_card_motion = CardMotion.new()
	motions = _card_motion
	add_child(motions)
	motions.bind(board, sfx)
	board.cancel_anim = _cancel_fly
	_table_actions = TableActions.new()
	add_child(_table_actions)
	_table_actions.bind(self)
	_victory = Label3D.new()
	_victory.font = Fonts.zh_bold()
	_victory.font_size = 48
	_victory.pixel_size = 0.012
	_victory.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_victory.position = Vector3(0, 1.2, 1.25)
	_victory.modulate = Palette.semantic("ink")
	_victory.outline_size = 0
	add_child(_victory)
	Palette.bus().changed.connect(_on_palette_changed)

func fit(viewport_size: Vector2, angle: float) -> void:
	if viewport_size.x < 1 or viewport_size.y < 1:
		return
	var count := int(CardDB.game_rules()["market_size"])
	var frame := Regions.zone_rect(false, true, count).merge(Regions.zone_rect(true, true, count)).merge(Regions.market_rect(count, true))
	var fitted := CameraFit.fit_perspective(viewport_size, Rect2(Vector2.ZERO, viewport_size), frame.grow(0.2),
		0.0, 0.55, angle, 44.0, 8.0)
	CameraFit.apply(camera, fitted)
	if not _result_view.is_empty():
		ResultPresentation.fit(_result_view, viewport_size)

func _cards(def_id: String, count: int, who: String) -> Array:
	var out: Array = []
	for i in count:
		var record := state.add_card(who, def_id)
		out.append(_spawn_entity(record, layout._unit_anchor(who, def_id), who == my_seat))
	return out

func _spawn_entity(record: Dictionary, at: Vector3, draggable: bool, from_pos = null, index := 0, total := 1) -> CardEntity:
	var card: CardEntity = _table_scene.spawn_card(board, record, at, draggable)
	card.freeze = true
	card.collision_layer = 0
	card.collision_mask = 0
	entities[card.uid] = card
	if from_pos != null:
		motions._fly_from(card, from_pos, at, index, total)
	return card

func _group(cards: Array, at: Vector3) -> Dictionary:
	if cards.is_empty():
		return {}
	var group: Dictionary = board.make_group(Board.core_first_order(cards), true)
	board.groups.append(group)
	board._layout_group(group, at)
	return group

func advance_time(delta: float) -> void:
	elapsed += delta
	progress = clampf(elapsed / duration, 0.0, 1.0)
	if phase == 0 and elapsed >= 0.9:
		assemble()
	if phase == 1 and elapsed >= 2.2:
		resolve()
	if elapsed >= _arrival_at:
		_arrive()
	if elapsed >= _stack_at:
		layout.end_arrivals()
		layout._stack_settled(_known_before)
		_stack_at = INF
	if phase >= 2 and not _attack_targets.is_empty():
		_attack_clock += delta
		if _attack_clock >= Motion.STAGGER * 2:
			_attack_clock = 0
			_attack_one()
	if elapsed >= duration and _attack_targets.is_empty() and _pending_arrivals.is_empty():
		phase = 3

func assemble() -> void:
	phase = 1
	_caption = str(demo["captions"][1])
	var mode := str(demo["mode"])
	if mode == "upgrade":
		for lane in lanes:
			var uids: Array = lane["cards"].map(func(card): return card.uid)
			lane["combo_index"] = state.combos.size()
			var result := state.create_combo(my_seat, uids)
			if not result["ok"]:
				_caption = str(result.get("reason", ""))
			else:
				_table_actions.group_ready(lane["cards"])
	elif mode in ["production", "attack", "protect"]:
		for card in _input_cards:
			board._detach_from_group(card)
		_group(_input_cards, _combo_at)
		last_result = state.create_combo(my_seat, _input_cards.map(func(card): return card.uid))
		if not last_result.get("ok", false):
			_caption = str(last_result.get("reason", "组合未成立"))
		_refresh_protection()
		if last_result.get("ok", false):
			_table_actions.group_ready(_input_cards)
	elif mode in ["purchase", "pawn"] and not _input_cards.is_empty():
		var at := _pawn_position() if mode == "pawn" else _market_slot(_purchase_index, state.market.size())
		board.card_picked.emit(_input_cards[0])
		motions.drag_stack(_input_cards, at)

func resolve() -> void:
	phase = 2
	_caption = str(demo["captions"][2])
	for card in _input_cards:
		if is_instance_valid(card):
			board._stop_move(card)
	for uid in entities:
		_known_before[uid] = true
	var mode := str(demo["mode"])
	match mode:
		"purchase":
			if _purchase_index < 0:
				return
			var card: CardEntity = market_cards[_purchase_index]
			last_result = applier.apply(Intent.buy(my_seat, _purchase_index, _input_cards.map(func(c): return c.uid)), my_seat)
			if last_result.get("ok", false):
				_table_actions.purchase(_purchase_index, card, last_result)
			else:
				_caption = str(last_result.get("reason", ""))
		"pawn":
			var uids: Array = _input_cards.map(func(card): return card.uid)
			last_result = applier.apply(Intent.pawn(my_seat, uids), my_seat)
			if last_result.get("ok", false):
				_table_actions.pawn(_input_cards, uids)
				_announce_victory()
			else:
				_caption = str(last_result.get("reason", ""))
		"production":
			layout.begin_arrivals()
			_resolve_combo(0, _combo_at)
		"upgrade":
			# 各档同屏并行，按真实组合分别裁决，产物回到各自来源摞的位置。
			for lane in lanes:
				_resolve_combo(int(lane["combo_index"]), lane["at"], lane)
		"attack":
			last_result = applier.apply(Intent.arm_attacks(my_seat))
			var paid: Array = []
			for uid in entities:
				if state.find_card(my_seat, uid).is_empty() and state.find_card(foe_seat, uid).is_empty():
					paid.append(uid)
			_table_actions.pay_recipe(paid, layout.payment_spot(my_seat, CardDB.RES_CASH))
			_attack_clock = -float(paid.size()) * Motion.STAGGER
		"protect":
			_refresh_protection()
			sfx.play("deny_quiet")
			_table_actions.shield_feedback(_input_cards)
			_victory.text = "保护生效"
		"victory":
			layout.begin_arrivals()
			for i in int(demo["after"]) - int(demo["before"]):
				_pending_arrivals.append({"card": state.add_card(_winning_seat, CardDB.unit_id(CardDB.RES_CASH)), "owner": _winning_seat, "from": Vector3(0, 0.4, 2.1)})
			_arrival_at = elapsed
		"eliminate":
			_attack_targets = _input_cards.duplicate()
			var res := str(CardDB.get_def(_input_cards[0].def_id)["res"])
			var budget := {CardDB.RES_CASH: 0, CardDB.RES_USER: 0}
			budget[res] = _attack_targets.size() * int(CardDB.game_rules()["attack_cost_per_card"])
			applier.pools_restore({_attacking_seat: budget})
			duration = maxf(duration, elapsed + _attack_targets.size() * Motion.STAGGER * 2 + CardMotion.TEAR_TIME + 0.5)

func _resolve_combo(index: int, at: Vector3, lane: Dictionary = {}) -> void:
	var combo: Dictionary = Settle.ordered_production_combos(state)[index]
	var known := entities.keys()
	_table_actions.prepare_combo(combo)
	last_result = applier.apply(Intent.produce(index))
	var resolution: Dictionary = last_result.get("resolution", {})
	if not last_result.get("ok", false) or not resolution.get("resolved", false):
		_caption = str(resolution.get("reason", "组合未生效"))
		return
	var paid: Array = resolution.get("paid_uids", [])
	var payment: Vector3 = layout.preview_arrival_spot(my_seat, {"def_id": CardDB.unit_id(CardDB.RES_USER)}) \
		if combo["eval"].get("output_res") == CardDB.RES_USER else layout.payment_spot(my_seat, CardDB.RES_CASH)
	var count: int = _table_actions.pay_recipe(paid, payment)
	if combo["eval"]["type"] == "upgrade":
		count = _table_actions.consume_upgrade(combo, at)
	var removed := 0
	for uid in known:
		if not entities.has(uid) or not state.find_card(my_seat, uid).is_empty() or not state.find_card(foe_seat, uid).is_empty():
			continue
		var card: CardEntity = entities[uid]
		board.drop_card(card)
		entities.erase(uid)
		motions.delayed_tear(card, Vector3.FORWARD, removed * Motion.STAGGER, false)
		removed += 1
	_pending_combo_feedback.append({"combo": combo, "at": at + Vector3(0, 0.6, 0)})
	for record in state.players[my_seat]["cards"]:
		if entities.has(record["uid"]) or _pending_arrivals.any(func(item): return item["card"]["uid"] == record["uid"]):
			continue
		var item := {"card": record, "from": at + Vector3(0, 0.4, 0)}
		if not lane.is_empty():
			item["at"] = at
			lane["result_uid"] = record["uid"]
		_pending_arrivals.append(item)
	var wait := count * Motion.STAGGER + CardMotion.SUCK_TIME
	if removed > 0:
		wait = maxf(wait, (removed - 1) * Motion.STAGGER + CardMotion.TEAR_TIME)
	_arrival_at = maxf(0.0 if _arrival_at == INF else _arrival_at, elapsed + wait)
	duration = maxf(duration, _arrival_at + CardMotion.SPAWN_FLY_TIME + CardMotion.SPAWN_FLY_SPREAD + 1.0)

func _arrive() -> void:
	_arrival_at = INF
	for item in _pending_combo_feedback:
		_table_actions.combo_feedback(item["combo"]["eval"], item["at"], item["combo"])
	_pending_combo_feedback.clear()
	for i in _pending_arrivals.size():
		var item: Dictionary = _pending_arrivals[i]
		var record: Dictionary = item["card"]
		var owner: String = item.get("owner", my_seat)
		var at: Vector3 = item.get("at", layout.arrival_spot(owner, record))
		_spawn_entity(record, at, owner == my_seat, item["from"], i, _pending_arrivals.size())
	_stack_at = elapsed + CardMotion.SPAWN_FLY_TIME + CardMotion.SPAWN_FLY_SPREAD
	_pending_arrivals.clear()
	state.check_victory()
	_announce_victory()

func _attack_one() -> void:
	var card: CardEntity = _attack_targets.pop_front()
	if not is_instance_valid(card):
		return
	var target := {}
	for candidate in applier.affordable_targets(_attacking_seat):
		if candidate["uids"].has(card.uid):
			target = candidate
			break
	if target.is_empty():
		return
	last_result = applier.apply(Intent.apply_attack(_attacking_seat, target), _attacking_seat)
	if not last_result.get("ok", false):
		return
	if not _attack_feedback_sent:
		_attack_feedback_sent = true
		_table_actions.attack_feedback(card.position, _attacking_seat, str(target.get("res", "")))
	board.drop_card(card)
	entities.erase(card.uid)
	motions.delayed_tear(card, Vector3.BACK, 0.0, true)
	_announce_victory()

func _announce_victory() -> void:
	if state.winner != "" and not _won_announced:
		_won_announced = true
		var result := ResultPresentation.create(self, state, my_seat, sfx, func(): replay_requested.emit(), "重播演示")
		_result_view = result
		result["layer"].process_mode = Node.PROCESS_MODE_ALWAYS
		result_panel = result["panel"]
		if result_styler.is_valid():
			result_styler.call(result_panel)
		ResultPresentation.fit(result, Vector2(get_viewport().size))

func _refresh_protection() -> void:
	for card in _input_cards:
		if not is_instance_valid(card):
			continue
		var def := CardDB.get_def(card.def_id)
		if def.get("kind") == CardDB.KIND_UNIT:
			card.set_shield(state.is_protected(my_seat, card.uid, str(def.get("res", ""))))
		if def.get("kind") == CardDB.KIND_BUFF:
			card.set_buff_glow(true, Palette.semantic("info"))

func caption() -> String:
	return _caption

func _on_palette_changed(_section: String, _key: String) -> void:
	_table_scene.refresh_palette()
	for card in board.cards:
		if is_instance_valid(card):
			card.refresh_palette()

# 布局器与动作组件的共同宿主接口，转发到同一份代码。
func _cancel_fly(card: CardEntity) -> void: motions._cancel_fly(card)
func _clear_dest(card: CardEntity) -> void: motions._clear_dest(card)
func _market_slot(index: int, count: int) -> Vector3: return Regions.market_slot(index, count, true)
func _pawn_position() -> Vector3: return Regions.facility_position(int(CardDB.game_rules()["market_size"]), true)
func is_drag_leased(_uid: int) -> bool: return false
func foe_anchor_of(_uid: int) -> Variant: return null
func foe_pile_point(_x: float, _y: float) -> Vector3: return Vector3.ZERO
func foe_compact_of(_uid: int) -> Variant: return null
func _event_feedback(event: String, at: Vector3, color: Color, amount := 16) -> void:
	Motion.play(self, event, at, color, amount)
