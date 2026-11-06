# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node3D
## Isolated fixtures, driven by the viewer's clock. Every visible object and
## effect is the production implementation; no BOT, save path or live input.
const CATALOG := "res://data/animation_preview.json"
const OriginalTable = preload("res://scenes/table_scene.gd")
const Conveyor = preload("res://scenes/work_conveyor.gd")
const Effects = preload("res://scenes/work_effects.gd")
const Materials = preload("res://scenes/effect_materials.gd")
const UIDemo = preload("res://scenes/work_animation_ui_demo.gd")

class PreviewHands extends "res://scenes/table_hands.gd":
	var native_cursor_requests := 0
	func _set_shape_cursor(_image: Image, _shape: int, _hotspot: Vector2) -> void:
		# This preview can paint the original hand, never acquire the OS cursor.
		native_cursor_requests += 1


var catalog: Dictionary
var entry: Dictionary = {}
var selected_id := ""
var state: WorkState
var board: WorkBoard
var camera: Camera3D
var conveyor: Node3D
var effects: Control
var _world: Node3D
var _ui_demo: Node
var _hands: PreviewHands
var _hand_card := -1
var _settings: Dictionary
var _groups: Dictionary = {}
var _owned_tweens: Array[Tween] = []
var _owned_tween_ids: Dictionary = {}
var _finished_tweens: Dictionary = {}
var _elapsed := 0.0
var _sync_age := 0.0
var _action_index := 0
var _events: Array = []
var _positions: Dictionary = {}
var _rng_state := 0
var _win_at := -1.0
var _database: Dictionary = {}
var _defaults: Dictionary
var _side_drag: Dictionary = {}

func _init() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED
	catalog = UIConfig.read_json(CATALOG, true)["scenarios"]
	_defaults = UIConfig.read_section("defaults")
	_settings = UIConfig.read_section("presentation")

func load_scenario(id: String) -> void:
	var matches: Array = catalog.scenarios.filter(func(item): return str(item.id) == id)
	if matches.is_empty(): return
	_clear()
	selected_id = id
	entry = matches[0].duplicate(true)
	_elapsed = 0.0
	_sync_age = 0.0
	_action_index = 0
	_win_at = -1.0
	_events.clear()
	_positions.clear()
	_groups.clear()
	var random := RandomNumberGenerator.new()
	random.seed = int(catalog.runtime.seed)
	_rng_state = random.state
	_scoped(_build)

func duration() -> float: return float(entry.get("duration", 0.0))
func time() -> float: return _elapsed

func is_ready() -> bool:
	if _world == null: return false
	if board == null: return true
	for card in board.by_uid.values() + board.offers_by_id.values():
		if not card.illustration_ready(): return false
	return true

func advance(delta: float) -> void:
	if _world == null or delta <= 0.0: return
	_scoped(_advance_to.bind(minf(duration(), _elapsed + delta)))

## 多步 seek 同步运行在同一调用栈；仅在进入和离开时保存外部牌局上下文。
func _advance_to(finish: float) -> void:
	while _elapsed < finish - 0.0000001:
		var step := minf(float(catalog.runtime.fixed_step), finish - _elapsed)
		if _action_index < entry.get("actions", []).size():
			var until_action := float(entry.actions[_action_index].at) - _elapsed
			if until_action > 0.0000001: step = minf(step, until_action)
		_step(step)

func seek(seconds: float) -> void:
	if selected_id.is_empty(): return
	var target := clampf(seconds, 0.0, duration())
	if target > _elapsed:
		advance(target - _elapsed)
		return
	if is_equal_approx(target, _elapsed) and target > 0.0: return
	var id := selected_id
	load_scenario(id)
	advance(target)

func _scoped(operation: Callable) -> void:
	var before := get_tree().get_processed_tweens()
	var previous_database := _database_snapshot()
	if not _database.is_empty(): _database_apply(_database)
	var rng := Materials.rng()
	var previous_rng := rng.state
	rng.state = _rng_state
	var previous_speed := UIConfig._hover_animation_speed
	var previous_shake := UIConfig._screen_shake
	UIConfig._hover_animation_speed = float(_defaults.hover_animation_speed)
	UIConfig._screen_shake = float(_defaults.screen_shake)
	for tween in _owned_tweens:
		if tween != null and tween.is_valid(): tween.play()
	operation.call()
	_database = _database_snapshot()
	_database_apply(previous_database)
	_rng_state = rng.state
	rng.state = previous_rng
	UIConfig._hover_animation_speed = previous_speed
	UIConfig._screen_shake = previous_shake
	_capture_tweens(before)
	for tween in _owned_tweens:
		if tween != null and tween.is_valid(): tween.pause()

func _database_snapshot() -> Dictionary:
	return {"cards": WorkCardDB.CARDS, "game": WorkCardDB.GAME, "upgrade": WorkCardDB.UPGRADE,
		"sfx": WorkCardDB.SFX, "sim": WorkCardDB.SIM, "roles": WorkCardDB.ROLES, "units": WorkCardDB.UNITS,
		"source": WorkCardDB.loaded_from, "config": WorkCardDB.config, "display": WorkCardDB.display}

func _database_apply(data: Dictionary) -> void:
	WorkCardDB.CARDS = data.cards
	WorkCardDB.GAME = data.game
	WorkCardDB.UPGRADE = data.upgrade
	WorkCardDB.SFX = data.sfx
	WorkCardDB.SIM = data.sim
	WorkCardDB.ROLES = data.roles
	WorkCardDB.UNITS = data.units
	WorkCardDB.loaded_from = data.source
	WorkCardDB.config = data.config
	WorkCardDB.display = data.display

func _finish_tween(tween: Tween) -> void:
	_finished_tweens[tween.get_instance_id()] = true
	_owned_tween_ids.erase(tween.get_instance_id())
	_owned_tweens.erase(tween)
	tween.kill()

func _capture_tweens(before: Array) -> void:
	# Natural completion removes membership in _finish_tween. Native Board
	# moves can also kill a superseded Tween without emitting finished; only
	# rebuild the ID set when that pruning actually changes the owned list.
	var active: Array[Tween] = _owned_tweens.filter(func(tween): return tween != null and tween.is_valid())
	if active.size() != _owned_tweens.size():
		_owned_tweens = active
		_owned_tween_ids.clear()
		for tween in _owned_tweens: _owned_tween_ids[tween.get_instance_id()] = true
	# Usually every processed Tween is already ours. Do not rebuild the
	# potentially huge "before" set until an unowned live Tween is encountered.
	var before_ids: Dictionary = {}
	var before_ready := false
	for tween in get_tree().get_processed_tweens():
		if not tween.is_valid(): continue
		var id := tween.get_instance_id()
		if _owned_tween_ids.has(id) or _finished_tweens.has(id): continue
		if not before_ready:
			for previous in before:
				if previous != null: before_ids[previous.get_instance_id()] = true
			before_ready = true
		if before_ids.has(id): continue
		_owned_tweens.append(tween)
		_owned_tween_ids[id] = true
		var callback := _finish_tween.bind(tween)
		if not tween.finished.is_connected(callback): tween.finished.connect(callback, CONNECT_ONE_SHOT)

func _build() -> void:
	if not Palette._loaded:
		Palette._cfg = UIConfig.read_section("palette")
		Palette._loaded = true
	_world = Node3D.new()
	_world.name = "IsolatedAnimationStage"
	_world.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_world)
	if str(entry.get("mode", "")) == "ui":
		_ui_demo = UIDemo.new()
		_world.add_child(_ui_demo)
		_ui_demo.configure(selected_id, get_viewport())
		return
	var config := WorkConfig.new()
	config.rules.initial.groups = [{"work": 1, "employee": 1}]
	config.rules.initial.money = 0
	config.rules.bot.enabled = false
	if not bool(entry.get("conveyor", false)): config.rules.conveyor.interval_seconds = duration() + 1.0
	state = WorkState.new(config)
	state.new_game(int(catalog.runtime.seed))
	state.cards.clear()
	state.groups.clear()
	state.tasks.clear()
	state._next_card = 1
	state._next_group = 1
	for fixture in entry.groups:
		var gid := state.create_group(int(fixture.owner))
		_groups[str(fixture.name)] = gid
		for kind in fixture.cards:
			for index in int(fixture.cards[kind]): state.add_card(str(kind), int(fixture.owner), gid)
	state._sync_schedule()
	state.drain_events()
	WorkCardDB.CARDS = {}
	WorkCardDB.configure(config)
	WorkCard.prewarm_event_stamps()
	var table := OriginalTable.new(_world, true, int(config.rules.conveyor.slots))
	table._setup_environment()
	table._setup_table()
	camera = table.camera
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	var camera_spec: Dictionary = entry.get("camera", {})
	camera.size = float(camera_spec.get("span", catalog.runtime.camera_span))
	camera.position = _vector(camera_spec.get("position", [0.0, catalog.runtime.camera_height, catalog.runtime.camera_z]))
	camera.rotation_degrees.x = float(camera_spec.get("tilt", catalog.runtime.camera_tilt))
	camera.make_current()
	_setup_dismissal()
	board = WorkBoard.new(false)
	_world.add_child(board)
	board.setup(camera, true)
	board.offer_bought.connect(_on_buy)
	board.input_locked = true
	board.hover_description_enabled = false
	board.set_process_input(false)
	board.set_process_unhandled_input(false)
	board.set_physics_process(false)
	board._settings.opponent_layout.enabled = false
	for fixture in entry.groups: board.group_overrides[_groups[str(fixture.name)]] = _vector(fixture.position)
	conveyor = Conveyor.new()
	_world.add_child(conveyor)
	conveyor.setup(board, _world)
	for tray in ["PlayerZoneTray", "FoeZoneTray"]:
		var node := _world.get_node_or_null(tray)
		if node != null: node.bind_board(board if tray == "PlayerZoneTray" else board.enemy_board)
	var layer := CanvasLayer.new()
	_world.add_child(layer)
	effects = Effects.new()
	layer.add_child(effects)
	_settings.effects.transfer_duration = float(board._settings.transfer_motion.travel_seconds)
	effects.setup(_settings.effects, _settings.text)
	effects.card_position_provider = board.screen_position
	board.sync_state(state)
	if bool(entry.get("hands", false)):
		_hands = PreviewHands.new()
		_world.add_child(_hands)
		_hands.host = self
		_hands.layer = 30
		_hands.cursor_enabled = false
		_hands.process_mode = Node.PROCESS_MODE_DISABLED
		_hands.set_process(false)
		_hands._canvas = _hands.HandCanvas.new()
		_hands._canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hands._canvas.hide()
		_hands.add_child(_hands._canvas)
	_run_actions()
	_sync_and_present()
	_ui_demo = UIDemo.new()
	_world.add_child(_ui_demo)
	_ui_demo.configure(selected_id, get_viewport())

func _setup_dismissal() -> void:
	var facility := _world.get_node_or_null("MarketFacility")
	if facility == null: return
	for name in _settings.dismiss_zone: facility.get_node(str(name)).text = str(_settings.dismiss_zone[name])
	var spec: Dictionary = _settings.dismiss_illustration
	var plate := facility.get_node("PawnshopFacilityCard") as MeshInstance3D
	plate.material_override.set_shader_parameter("has_artwork", false)
	plate.material_override.set_shader_parameter("artwork", null)
	facility.get_node("FacilityBadge").visible = bool(spec.show_category)
	var icon := Sprite3D.new()
	icon.texture = load(str(spec.texture))
	icon.pixel_size = float(spec.width) / float(icon.texture.get_width())
	icon.rotation_degrees.x = -90.0
	icon.position = Vector3(0.0, CardEntity.Y_ICON, float(spec.center_z))
	icon.shaded = false
	icon.double_sided = true
	icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	facility.add_child(icon)

func _step(delta: float) -> void:
	var before := get_tree().get_processed_tweens()
	if state != null:
		_positions.clear()
		for uid in board.by_uid: _positions[uid] = board.screen_position(uid)
		if state.winner < 0: state.advance(delta)
	_elapsed += delta
	_run_actions()
	if state != null:
		_sync_age += delta
		_sync_and_present()
		if state.winner < 0: board._sync_group_task_progress()
		board._advance_cash_flights(delta)
		board._advance_meeting_visitors(delta)
		board._advance_strike_dancers(delta)
		board._advance_deliveries(delta)
		_advance_side_extract(delta)
		for card in board.by_uid.values() + board.offers_by_id.values(): card._process(delta)
		effects._process(delta)
	if _ui_demo != null:
		_ui_demo.advance(delta)
		if state != null and state.winner >= 0 and _win_at >= 0.0 and _elapsed - _win_at >= float(_settings.result.delay):
			_ui_demo.reveal_result(state.winner, state.work_count(0))
	_capture_tweens(before)
	for tween in _owned_tweens.duplicate():
		if tween != null and tween.is_valid() and not tween.custom_step(delta): _finish_tween(tween)
	_capture_tweens(before)
	if conveyor != null: conveyor._process(delta)
	_update_scripted_hand()

func _sync_and_present() -> void:
	var events := state.drain_events()
	if (state.winner < 0 and _sync_age >= float(catalog.runtime.sync_interval)) or not events.is_empty():
		board.sync_state(state)
		_sync_age = 0.0
	for event in events:
		var recorded: Dictionary = event.duplicate(true)
		recorded["time"] = _elapsed
		_events.append(recorded)
		_present(event)

func _at(uid: int, group := -1) -> Vector2:
	if _positions.has(uid): return _positions[uid]
	if board.by_uid.has(uid): return board.screen_position(uid)
	if group >= 0: return camera.unproject_position(board.get_group_position(group))
	return get_viewport().get_visible_rect().size * 0.5

func _present(event: Dictionary) -> void:
	var kind := str(event.kind)
	if kind == "win":
		_win_at = _elapsed
		board.play_event(event)
		return
	if kind in ["new_game", "conveyor"]: return
	var source := int(event.get("source", -1))
	var group := int(event.get("group", -1))
	var start := _at(source, group)
	var finish := start
	var targets: Array = []
	for uid in event.get("targets", []): targets.append(_at(int(uid)))
	if kind == "work_complete": finish = _at(int(event.get("money_id", -1)), int(event.get("money_group", -1)))
	elif kind == "transfer": finish = camera.unproject_position(board.get_group_position(int(event.get("target_group", -1))))
	elif kind == "strike": start = _at(-1, int(event.get("target_group", -1)))
	elif kind == "coffee_upgrade": start = _at(int(event.get("person", -1)), group)
	elif kind == "outsource": finish = Vector2(get_viewport().get_visible_rect().size.x, start.y)
	effects.emit_effect(kind, start, finish, maxi(event.get("ids", []).size(), 1), targets,
		source if kind == "meeting_start" else -1, event.get("targets", []) if kind == "meeting_start" else [])
	board.play_event(event)

func _select(selector: Dictionary) -> Array:
	var result: Array = []
	for uid in state.cards:
		var card: Dictionary = state.cards[uid]
		if int(card.owner) != int(selector.get("owner", 0)): continue
		var kind := str(selector.get("type", ""))
		if kind == "person":
			if not state.config.is_person(str(card.type)): continue
		elif str(card.type) != kind: continue
		result.append(uid)
	if bool(selector.get("all", false)): return result
	var index := int(selector.get("index", 0))
	return [result[index]] if index >= 0 and index < result.size() else []

func _run_actions() -> void:
	var actions: Array = entry.get("actions", [])
	while _action_index < actions.size() and float(actions[_action_index].at) <= _elapsed + 0.0000001:
		_action(actions[_action_index])
		_action_index += 1

func _action(action: Dictionary) -> void:
	if state == null: return
	var kind := str(action.kind)
	var gid := int(_groups.get(str(action.get("group", "")), -1))
	var selected: Array = _select(action.card) if action.has("card") else []
	var uid: int = int(selected[0]) if not selected.is_empty() else -1
	var card: WorkCard = board.by_uid.get(uid)
	match kind:
		"camera":
			var tween := camera.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
			tween.tween_property(camera, "size", float(action.span), float(action.seconds))
			tween.tween_property(camera, "position", _vector(action.position), float(action.seconds))
		"combine":
			var ids: Array = []
			for selector in action.cards: ids.append_array(_select(selector))
			state.move_cards(ids, gid)
		"activate":
			if uid >= 0 and state.cards[uid].status == "ready": state.activate(uid, gid)
		"move_from_group":
			state.move_cards(state.group_cards(int(_groups[action.source])).slice(0, int(action.count)), gid)
		"add":
			for index in int(action.count): state.add_card(str(action.type), int(action.owner), gid)
			state._sync_schedule()
		"dismiss":
			if uid >= 0: state.dismiss_people([uid], int(action.card.get("owner", 0)))
		"buy":
			var slot := int(action.slot)
			if slot < state.offers.size() and not state.offers[slot].is_empty():
				var offer: Dictionary = state.offers[slot]
				var market: WorkCard = board.offers_by_id.get(int(offer.id))
				if market != null: board._purchase([], market)
		"hover":
			if card != null: card.set_hovered(bool(action.on))
		"select":
			if card != null: card.set_selected(bool(action.on))
		"drag_visual":
			if card != null:
				card.set_drag_visual(bool(action.on))
				_hand_card = uid if bool(action.on) else -1
		"move_card", "move_to_facility":
			if card != null:
				var destination := board.pawn_pos if kind == "move_to_facility" else _vector(action.position)
				board.group_overrides[card.group_id] = destination
				board._origin_by_gid[card.group_id] = destination
				board._move_to(card, destination)
		"land":
			if card != null: card.pulse_landed()
		"toggle_stack":
			var members := state.group_cards(gid)
			if not members.is_empty(): board.toggle_compact(board.by_uid[members[0]])
		"split":
			var source := int(_groups[action.source])
			var members: Array = state.group_cards(source).filter(func(id): return str(state.cards[id].type) == str(action.type)).slice(0, int(action.count))
			var created := state.move_cards(members, -1)
			_groups[str(action.name)] = created
			board.group_overrides[created] = _vector(action.position)
		"merge_group":
			state.move_cards(state.group_cards(int(_groups[action.source])), gid)
		"side_open":
			# The preview invokes the same side hit-test and pointer handler used
			# in play; it never fabricates a separate logical group for the fan.
			board.input_locked = false
			var first: WorkCard = board.by_uid.get(state.group_cards(gid)[0])
			var visual: Variant = board.group_of(first)
			if visual != null:
				var rows: Array = board.side_extract.side_rows(visual)
				for row in rows.size():
					if str(rows[row].kind) != str(action.type): continue
					var label: Label3D = visual.side[row * 2 + 1]
					var at := camera.unproject_position(label.global_position)
					_side_button(at, true)
					_side_button(at, false)
					break
		"side_hover", "side_begin":
			var fan: Control = board.side_extract.view
			if is_instance_valid(fan) and fan.is_open():
				var requested := int(action.get("index", 0))
				if action.has("fraction"):
					requested = roundi(clampf(float(action.fraction), 0.0, 1.0) * float(maxi(fan.records.size() - 1, 0)))
				var index := clampi(requested, 0, fan.records.size() - 1)
				# Use the same exposed edge as a real pointer. The inspection may
				# animate or sample hundreds of cards, so its geometry owns this map.
				var at: Vector2 = fan.screen_point_for_index(index)
				var hover := InputEventMouseMotion.new()
				hover.position = at
				board.side_extract.handle_input(hover)
				if kind == "side_begin":
					_side_button(at, true)
					var motion := InputEventMouseMotion.new()
					motion.position = at + Vector2(float(board._settings.side_extract.drag_threshold) + float(action.get("edge_inset", 5.0)), 0)
					motion.button_mask = MOUSE_BUTTON_MASK_LEFT
					board.side_extract.handle_input(motion)
					if board.is_dragging():
						_hand_card = board._drag_cards[0].uid
						_side_drag = {"start": _elapsed, "duration": float(action.seconds), "from": board._drag_cards[0].global_position, "to": _vector(action.position)}
		"side_drop":
			if not _side_drag.is_empty() and board.is_dragging():
				var held_ids: Array = board._drag_cards.map(func(held): return held.uid)
				_move_side_pointer(_side_drag.to)
				board.release_pointer(board._pointer_at)
				board._commit_drop()
				if action.has("name") and not held_ids.is_empty() and state.cards.has(held_ids[0]):
					_groups[str(action.name)] = int(state.cards[held_ids[0]].group)
			_side_drag.clear()
			_hand_card = -1
		"side_close":
			board.side_extract.close()
	board.sync_state(state)

func _side_button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	board.side_extract.handle_input(event)

func _move_side_pointer(at: Vector3) -> void:
	board.touch_mode = true
	# The real handoff preserves the point grabbed on the exposed header.
	# Move that pointer so the held card, rather than the pointer, reaches at.
	board._pointer_at = camera.unproject_position(Vector3(at.x - board._grab_offset.x, Board.DRAG_HEIGHT, at.z - board._grab_offset.z))
	board._process(0.0)

func _advance_side_extract(delta: float) -> void:
	if not _side_drag.is_empty() and board.is_dragging():
		var weight := clampf((_elapsed - float(_side_drag.start)) / float(_side_drag.duration), 0.0, 1.0)
		_move_side_pointer((_side_drag.from as Vector3).lerp(_side_drag.to, smoothstep(0.0, 1.0, weight)))
	if board.side_extract != null and board.side_extract.is_open():
		var fan: Control = board.side_extract.view
		fan._process(delta)
		for card in fan.preview_cards: card._process(delta)

func _update_scripted_hand() -> void:
	if _hands == null: return
	var card: WorkCard = board.by_uid.get(_hand_card)
	_hands._drag_hand = camera.unproject_position(card._visual.global_position) if card != null else Vector2.INF
	_hands._canvas.visible = card != null
	_hands._canvas.queue_redraw()

func _on_buy(offer_id: int) -> void:
	state.buy(offer_id, 0, board.purchase_payment_ids)
	board.sync_state(state)

func _vector(values: Array) -> Vector3: return Vector3(float(values[0]), float(values[1]), float(values[2]))

func snapshot() -> Dictionary:
	var result := {"id": selected_id, "time": _elapsed, "duration": duration(), "events": _events.duplicate(true), "owned_tweens": _owned_tweens.size()}
	if state != null:
		var poses: Dictionary = {}
		for uid in board.by_uid:
			var card: WorkCard = board.by_uid[uid]
			poses[uid] = [card.type, card.global_position, card._visual.transform, card.illustration_profile(), card.illustration_time()]
		result.merge({"winner": state.winner, "work": [state.work_count(0), state.work_count(1)], "money": [state.money(0), state.money(1)],
			"cards": state.cards.size(), "poses": poses, "cash_flights": board._cash_flights.size(), "coffee_flights": board._delivery_flights.values().filter(func(flight): return not flight.transfer).size(),
			"meeting_visitors": board._meeting_visitors.size(), "strikers": board._strike_dancers.size(),
			"camera": [camera.transform, camera.size, camera.h_offset, camera.v_offset],
			"effects": effects.items.duplicate(true),
			"conveyor": conveyor.carriers.map(func(carrier): return carrier.transform),
			"offers": board.offers_by_id.values().map(func(card): return [card.global_position, card._visual.transform])})
	if _ui_demo != null: result["ui"] = _ui_demo.snapshot()
	if board != null and board.side_extract != null and board.side_extract.is_open():
		var fan: Control = board.side_extract.view
		result["side_extract"] = {"group": fan.group_id, "kind": fan.kind, "ids": fan.records.map(func(record): return record.id), "focus": fan.focus_index}
	if _hands != null:
		result["hand"] = {"position": _hands._drag_hand, "visible": _hands._canvas.visible,
			"native_cursor_requests": _hands.native_cursor_requests}
	return result

func _clear() -> void:
	for tween in _owned_tweens:
		if tween != null and tween.is_valid(): tween.kill()
	_owned_tweens.clear()
	_owned_tween_ids.clear()
	_finished_tweens.clear()
	_database.clear()
	if is_instance_valid(_world): _world.free()
	_world = null
	_ui_demo = null
	_hands = null
	_hand_card = -1
	_side_drag.clear()
	state = null
	board = null
	camera = null
	conveyor = null
	effects = null

func _exit_tree() -> void:
	for tween in _owned_tweens:
		if tween != null and tween.is_valid(): tween.kill()
	_owned_tweens.clear()
	_owned_tween_ids.clear()
