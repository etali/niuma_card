# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkBoard
extends Board

## 原 Board 处理拖拽、拆摞、收拢和边界；适配器收紧实时牌桌的目标命中。
const CardView = preload("res://scenes/off_work_card.gd")
const PriceTag = preload("res://scenes/off_work_price_tag.gd")
const PileSolver = preload("res://engine/pile_solver.gd")
const SpawnPlacement = preload("res://engine/off_work_spawn_placement.gd")
const OpponentLayout = preload("res://engine/off_work_opponent_layout.gd")
const ComicFx = preload("res://scenes/comic_fx.gd")
const InteractionPreferences = preload("res://engine/off_work_interaction_preferences.gd")
const DebugPreferences = preload("res://engine/off_work_debug_preferences.gd")
const ProgressClock = preload("res://engine/off_work_progress_clock.gd")
const SideExtract = preload("res://engine/off_work_side_extract.gd")
const StackLayout = preload("res://engine/off_work_stack_layout.gd")
const PaperDisposal = preload("res://scenes/off_work_paper_disposal.gd")
# The opponent uses the same original Board. Income and meeting visits own
# temporary motion; all pointer/group behavior remains inherited.
class IncomeBoard extends Board:
	func _init() -> void:
		card_catalog = OffWorkCardDB
		combo_rules = OffWorkComboRules
		native_recipe_progress_enabled = false

	var income_move: Callable
	var income_side: Callable
	var front_order: Callable
	var stack_layout: Callable
	var stack_changed: Callable
	var side_refresh_deferred: Callable
	var compact_sync_layout: Callable
	var rest_height: float
	var defer_record_refresh := false
	var terminal_sides_hidden := false
	func group_mods(group_cards: Array) -> Dictionary:
		return OffWorkBoard.balance_group_mods(group_cards)
	func refresh_group(group, top_pos := Vector3.INF) -> bool:
		if stack_changed.is_valid(): stack_changed.call()
		return false if defer_record_refresh else super.refresh_group(group, top_pos)
	func _core_first(group) -> void:
		super._core_first(group)
		if front_order.is_valid(): group.cards = front_order.call(group)
	func _layout_group(group, origin := Vector3.INF) -> bool:
		if stack_changed.is_valid(): stack_changed.call()
		if front_order.is_valid():
			var ordered: Array = front_order.call(group)
			if ordered != group.cards and origin == Vector3.INF:
				origin = rest_origin(group)
				origin.y = rest_height
			group.cards = ordered
		if compact_sync_layout.is_valid():
			var result: Variant = compact_sync_layout.call(self, group, origin)
			if result != null: return bool(result)
		return super._layout_group(group, origin)
	func _move_to(card: CardEntity, destination: Vector3) -> void:
		if income_move.is_valid() and bool(income_move.call(card, destination)): return
		super._move_to(card, destination)
	func _stack_offset(group, index: int) -> Vector3:
		if stack_layout.is_valid(): return stack_layout.call(group, index, self)
		return super._stack_offset(group, index)
	func _layout_side(group, at: Vector3, pin_y := false) -> void:
		if side_refresh_deferred.is_valid() and bool(side_refresh_deferred.call()): return
		if terminal_sides_hidden:
			_clear_side(group)
			return
		super._layout_side(group, at, pin_y)
		if income_side.is_valid(): income_side.call(group)

signal work_groups_changed()
signal tool_activated(id: int, target_group: int)
signal strike_delivered(id: int, target_group: int)
signal offer_bought(offer_id: int)
signal dismiss_requested(ids: Array)
signal ingredient_requested(id: int, target_group: int, person: int)
signal card_selected(id: int)
signal card_hovered(id: int)
signal action_rejected(message: String)

var network_drop: Callable
var by_uid: Dictionary = {}
var offers_by_id: Dictionary = {}
var purchase_payment_ids: Array = [] # 仅购买信号同步处理期间有效；空数组沿用自动付款。
var enemy_board: Board
var conveyor: Node3D
var group_overrides: Dictionary = {}
var drawer_mode := false
var _state: Object
var _settings: Dictionary = UIConfig.read_section("board")
var _interaction_preferences: RefCounted
var _debug_preferences: RefCounted
var _prices: Dictionary = {}
var _origin_by_gid: Dictionary = {}
var _compact_by_gid: Dictionary = {}
var _stack_occluded: Dictionary = {}
var _placing_snapshot := false
var _assembling := false
var _stack_representatives: Dictionary = {}
var _thin_stack_cards: Dictionary = {}
var _muted_stack_titles: Dictionary = {}
var _stack_layout_revision := 0
var _stack_occlusion_dependencies: Array = []
var _record_sync_key: Array = []
var _record_cards: Dictionary = {}
var _record_groups: Dictionary = {}
var _group_progress_cards: Dictionary = {}
var _debug_timer_cards: Dictionary = {}
var _spawned_by_owner: Dictionary = {}
var _picked_ids: Array = []
var _dismiss_pick_snapshot: Dictionary = {}
var _drop_pending := false
var _resolving_drop := false
var _drop_target_person := -1
var _meeting_visitors: Dictionary = {}
var _strike_dancers: Dictionary = {}
var _strike_attacks: Dictionary = {}
var _paper_disposal: Node3D
var _transfer_departures := {}
var _delivery_flights: Dictionary = {}
var _meeting_centers: Dictionary = {}
var _meeting_home_order: Dictionary = {}
var _was_interacting := false
var _previous_positions: Dictionary = {}
var _retired_cards: Dictionary = {}
var _effect_tweens: Array[Tween] = []
var _pending_buy_position := Vector3.INF
var _motion: Node
var _cash_flights: Dictionary = {}
var _cash_emission_serial: Dictionary = {}
var _cash_stream_width: Dictionary = {}

static func balance_group_mods(group_cards: Array) -> Dictionary:
	var amount := 0
	for card in group_cards:
		if is_instance_valid(card) and card.def_id == "money": amount += int(card.record.get("amount", 1))
	return {"off_work_money_amount": amount}

func group_mods(group_cards: Array) -> Dictionary:
	return balance_group_mods(group_cards)
var _opening_counts: Dictionary = {}
var _opening_layout_enabled := false
var _opponent_layout_signature := ""
var _opponent_layout_passes := 0
var _terminal_pose_locked := false
var side_extract: RefCounted
var _defer_record_refresh := false
var _record_removal_groups: Array = []
var _defer_side_refresh := false
var _syncing_structure := false

func _init(read_user_preferences := true) -> void:
	align_stack_layers = _align_stack_layers
	card_catalog = OffWorkCardDB
	combo_rules = OffWorkComboRules
	native_recipe_progress_enabled = false
	_interaction_preferences = InteractionPreferences.new(_settings.snapping, read_user_preferences)
	_debug_preferences = DebugPreferences.new(_settings.debug_mode, read_user_preferences)

## Preview boards can opt into inspection without touching persistent settings.
func set_debug_mode(enabled: bool, persist := false) -> bool:
	_debug_preferences.enabled = enabled
	_sync_debug_timers()
	return _debug_preferences.save() if persist else true

func get_debug_mode() -> bool:
	return bool(_debug_preferences.enabled)

func _ready() -> void:
	_ensure_enemy_board()
	side_extract = SideExtract.new(self, _settings.side_extract)
	card_pick_started.connect(_remember_pick_origin)
	card_picked.connect(_remember_picked_cards)
	card_dropped_table.connect(_queue_commit_drop)
	dropped_on_market.connect(_purchase)
	dropped_on_pawn.connect(_dismiss_dragged)
	attack_clicked.connect(func(card: CardEntity): card_selected.emit(card.uid))

func _ensure_enemy_board() -> void:
	if is_instance_valid(enemy_board): return
	enemy_board = IncomeBoard.new()
	enemy_board.align_stack_layers = _align_stack_layers
	(enemy_board as IncomeBoard).income_move = _preserve_income_motion
	(enemy_board as IncomeBoard).income_side = _update_cash_side
	(enemy_board as IncomeBoard).front_order = _stack_face_order
	(enemy_board as IncomeBoard).stack_layout = _work_stack_offset
	(enemy_board as IncomeBoard).stack_changed = _invalidate_stack_occlusion
	(enemy_board as IncomeBoard).side_refresh_deferred = _side_refresh_is_deferred
	(enemy_board as IncomeBoard).compact_sync_layout = _try_compact_sync_layout
	(enemy_board as IncomeBoard).rest_height = float(_settings.rest_y)
	enemy_board.name = "OpponentOriginalBoard"
	add_child(enemy_board)
	enemy_board.input_locked = true
	enemy_board.hover_description_enabled = false
	enemy_board.set_process(false)
	enemy_board.set_physics_process(false)
	enemy_board.set_process_input(false)
	enemy_board.set_process_unhandled_input(false)

func _side_refresh_is_deferred() -> bool:
	return _defer_side_refresh

func setup(view_camera: Camera3D, drawer := false) -> void:
	_ensure_enemy_board()
	camera = view_camera
	drawer_mode = drawer
	enemy_board.camera = view_camera
	cancel_anim = _cancel_external_motion
	enemy_board.cancel_anim = cancel_anim
	var count: int = int(OffWorkCardDB.game_rules()["market_size"])
	var mine := TableRegions.zone_rect(true, drawer_mode, count)
	var theirs := TableRegions.zone_rect(false, drawer_mode, count)
	set_playable_bounds(mine.merge(theirs), mine)
	enemy_board.set_playable_bounds(mine.merge(theirs), theirs)
	pawn_pos = TableRegions.facility_position(count, drawer_mode)

func bind_motion(motion: Node) -> void:
	_motion = motion
	cancel_anim = _cancel_external_motion
	enemy_board.cancel_anim = cancel_anim

func set_targeting(enabled: bool) -> void:
	cancel_pointer()
	attack_mode = enabled

func is_dragging() -> bool:
	return not _drag_cards.is_empty()

func _interacting() -> bool:
	return is_dragging() or not _press_snap.is_empty()

func _input(event: InputEvent) -> void:
	if side_extract != null and side_extract.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	super._input(event)
	if event is InputEventMouseMotion and not _press_snap.is_empty() \
		and not _press_snap.get("price_tag", false) and not _drag_cards.is_empty() \
		and not _drag_cards[0].is_market and event.position.distance_to(_press_snap.at) > Board.CLICK_SLOP:
		_press_snap["work_drag_moved"] = true

func release_pointer(at: Vector2) -> void:
	# The fan already waited for a real drag. Its handoff point must not become
	# a second click threshold that silently restores the extracted cards.
	if _press_snap.get("side_extract", false) and not _interaction_is_blocked() and not input_locked and not attack_mode and not view_gesture:
		_press_snap = {}
		_reset_click_track()
	# A real drag can return close to its press point over a different pile.
	# Keep native click/double-click restoration unless it crossed the native
	# movement threshold AND now has a different, valid stacking target.
	if _press_snap.get("work_drag_moved", false) and not _drag_cards.is_empty() \
		and not _interaction_is_blocked() and not input_locked and not attack_mode and not view_gesture:
		if touch_mode: _pointer_at = at
		_process(0.0)
		if not _drag_cards.is_empty():
			var group: Variant = _nearest_group(_drag_cards[0].global_position, _drag_cards)
			var other_group: bool = group != null and not is_same(group, _press_snap.get("group"))
			var loose := _nearest_loose_card(_drag_cards[0].global_position, _drag_cards) if group == null else null
			if other_group or loose != null:
				_press_snap = {}
				_reset_click_track()
	super.release_pointer(at)

func _process(delta: float) -> void:
	if _assembling: return
	super._process(delta)
	_sync_stack_occlusion()
	_advance_cash_flights(delta)
	_advance_meeting_visitors(delta)
	_advance_strike_dancers(delta)
	_advance_strike_attacks(delta)
	_advance_paper_disposal(delta)
	_advance_deliveries(delta)
	var active := _interacting()
	if _was_interacting and not active and not _drop_pending and _state != null:
		_picked_ids.clear()
		_dismiss_pick_snapshot.clear()
		sync_state(_state)
	_was_interacting = active

func _pick_card(screen_pos: Vector2) -> CardEntity:
	var card := super._pick_card(screen_pos)
	if card != null and _stack_occluded.has(card.uid):
		# Dense expanded layers still pick their actual representative UID, so
		# the inherited suffix cut starts where the player sees a card edge.
		var representative := int(_stack_representatives.get(card.uid, -1))
		if by_uid.has(representative): return by_uid[representative]
		var group: Variant = _presenter(card.card_owner).group_of(card)
		return group.cards[_top_index(group)] if group != null and not group.cards.is_empty() else null
	return card

func _pick_price_tag(screen_pos: Vector2) -> CardEntity:
	# Only offers have price tags. Hidden work still has a real physics identity,
	# but must not be visited once per mouse-hover frame to look for a shop tag.
	for card in offers_by_id.values():
		if _price_tag_contains(card, screen_pos): return card
	return null

func _set_hover_card(card: CardEntity) -> void:
	if side_extract != null and side_extract.is_open(): card = null
	var changed := card != _hover_card
	super._set_hover_card(card)
	if changed: card_hovered.emit(card.uid if is_instance_valid(card) and not card.is_market else -1)

func describe_def(def_id: String, _mods: Dictionary = {}) -> String:
	return str(OffWorkCardDB.get_def(def_id).get("description", ""))

func hover_desc_text(def_id: String, mods: Dictionary = {}) -> String:
	return describe_def(def_id, mods)

func _remember_pick_origin(card: CardEntity) -> void:
	if card.is_market or _state == null or not _state.cards.has(card.uid): return
	var group: Variant = group_of(card)
	_origin_by_gid[int(_state.cards[card.uid].group)] = rest_origin(group) if group != null else rest_pos(card)
	_compact_by_gid[int(_state.cards[card.uid].group)] = bool(group.get("compact", false)) if group != null else false

func _remember_picked_cards(card: CardEntity) -> void:
	_drop_target_person = -1
	_picked_ids.clear()
	# 原 Board 松手后把快照交还给桌面；设施交易要保留它，以便未出售的牌精确归位。
	_dismiss_pick_snapshot = _press_snap.duplicate()
	if _dismiss_pick_snapshot.has("cards"):
		_dismiss_pick_snapshot.cards = _press_snap.cards.duplicate()
	for member in _drag_cards:
		# 会已结束的返程人员若被原整摞手势带起，位置立即交还原拖拽。
		if _meeting_visitors.has(member.uid) and _meeting_visitors[member.uid].phase == "return":
			_release_meeting_motion(member.uid, false)
		if not member.is_market: _picked_ids.append(member.uid)
	if not card.is_market: card_selected.emit(card.uid)

func _dismiss_dragged(dragged: Array) -> void:
	if _state == null: return
	var people: Array = []
	var valid := not dragged.is_empty()
	for card in dragged:
		if not is_instance_valid(card): continue
		if card.is_market or not by_uid.has(card.uid) or by_uid[card.uid] != card:
			valid = false
			break
		# 实时任务可能已经摘走工作；只校验仍然存在的牌，绝不把对方人员算进来。
		if not _state.cards.has(card.uid): continue
		var record: Dictionary = _state.cards[card.uid]
		if int(record.owner) != int(_settings.local_owner):
			valid = false
			break
		if _state.config.is_person(str(record.type)): people.append(card.uid)
	_drop_pending = false
	_picked_ids.clear()
	# Main 同步结算且先缓存屏幕位置；人物节点仍停在松手点，现金沿现有 fire 演出飞出。
	if valid and not people.is_empty():
		dismiss_requested.emit(people)
	else:
		action_rejected.emit(str(_settings.dismiss_zone.invalid_drop_message))
	_restore_dismiss_pick()
	sync_state(_state)

func _restore_dismiss_pick() -> void:
	var snap := _dismiss_pick_snapshot
	_dismiss_pick_snapshot = {}
	if not snap.is_empty():
		var alive: Array = []
		for card in snap.get("cards", []):
			if is_instance_valid(card) and by_uid.has(card.uid) and _state.cards.has(card.uid) \
				and int(_state.cards[card.uid].owner) == int(_settings.local_owner): alive.append(card)
		if snap.get("group") != null:
			snap.cards = alive
			if not alive.is_empty(): snap.card = alive[0]
			else: snap = {}
		else:
			var card: Variant = snap.get("card")
			if not is_instance_valid(card) or not by_uid.has(card.uid) or not _state.cards.has(card.uid) \
				or int(_state.cards[card.uid].owner) != int(_settings.local_owner): snap = {}
	_press_snap = snap
	cancel_pointer()

func _release_keeps_frozen(_card: CardEntity) -> bool:
	return true

func cancel_pointer() -> void:
	if side_extract != null: side_extract.close()
	var loose: Variant = _press_snap.get("card") if _press_snap.get("group") == null else null
	super.cancel_pointer()
	# 实时牌由状态和原 CardMotion 定位；原 Board 的散卡取消分支会恢复物理，
	# 这里保留实时牌原有的冻结状态，避免拒绝开除后被相邻牌再次挤走。
	if is_instance_valid(loose) and not loose.is_market and by_uid.has(loose.uid): loose.freeze = true
	_dismiss_pick_snapshot.clear()

func _snapshot_press(card: CardEntity, at: Vector2) -> void:
	# 被强行带走的人仍可接收指向性的咖啡，但不能生成原生拖动快照。
	if _meeting_visitors.has(card.uid) or _strike_in_flight(card.uid) or card.has_meta("income_flight") or card.has_meta("delivery_flight"): return
	super._snapshot_press(card, at)

func _on_card_clicked(card: CardEntity, notify_started := true) -> void:
	if card.has_meta("income_flight") or card.has_meta("delivery_flight") or _strike_in_flight(card.uid): return
	var group: Variant = group_of(card)
	if group != null:
		# Deliberately picking the settled bank collects its incoming income at
		# the bank first. Native drag offsets must never include an airborne
		# note's distant visual position.
		for member in group.cards:
			if _delivery_flights.has(member.uid):
				member.global_position = _delivery_flights[member.uid].to
				_release_delivery(member.uid)
			if not _cash_flights.has(member.uid): continue
			var destination: Vector3 = _cash_flights[member.uid].to
			_cancel_cash_flight(member)
			member.global_position = destination
	super._on_card_clicked(card, notify_started)

func side_extract_entries(group_id: int) -> Array:
	return side_extract.entries(group_id) if side_extract != null else []

func open_side_extract(group_id: int, kind: String, anchor := Vector2.INF) -> bool:
	return side_extract != null and side_extract.open_group(group_id, kind, anchor)

func begin_side_extract(ids: Array, at: Vector2) -> bool:
	if side_extract == null or ids.is_empty() or is_dragging() or _interaction_is_blocked() or input_locked or attack_mode or view_gesture: return false
	var selected: Array = []
	var seen: Dictionary = {}
	var gid := -1
	var kind := ""
	for uid in ids:
		if seen.has(uid) or not side_extract.eligible(int(uid)): return false
		seen[uid] = true
		var record: Dictionary = _state.cards[uid]
		if selected.is_empty():
			gid = int(record.group)
			kind = str(record.type)
		elif int(record.group) != gid or str(record.type) != kind: return false
		selected.append(by_uid[uid])
	var first: CardEntity = selected[0]
	var source: Variant = group_of(first)
	if selected.any(func(card): return not is_same(group_of(card), source)): return false
	side_extract.close()
	card_pick_started.emit(first)
	_snapshot_press(first, at)
	if _press_snap.is_empty(): return false
	var original := _press_snap.duplicate()
	var remaining: Array = []
	if source != null:
		remaining = source.cards.filter(func(card): return not selected.has(card))
		# Only the temporary visual list changes. The native suffix picker does
		# the detach, and the simulation changes only at the ordinary drop.
		source.cards = remaining + selected
		source.compact = false
	super._on_card_clicked(first, false)
	if source != null and not remaining.is_empty():
		source.compact = bool(original.compact) and remaining.size() > 1
		_layout_group(source, original.origin)
	_drag_compact = selected.size() > 1
	_drag_start_origin = Vector3.INF
	_drag_start_anchor = Vector3.INF
	_drag_offsets.clear()
	var layers: int = int(_settings.stack_display.money_visible_layers) if kind == "money" else Board.BOUNDED_COMPACT_LAYERS
	var head := Board.capped_offset(selected.size(), 0, layers)
	for index in selected.size():
		var offset := Board.capped_offset(selected.size(), index, layers)
		offset.x -= head.x
		offset.z -= head.z
		_drag_offsets.append(offset)
	_grab_offset = Vector3.ZERO
	if touch_mode: _pointer_at = at
	_press_snap["side_extract"] = true
	_was_interacting = true
	_process(0.0)
	return true

## Live, per-board preference; saving and reset use work_game's isolated store.
func get_snap_hit_fraction() -> float:
	return _interaction_preferences.get_hit_fraction()

func set_snap_hit_fraction(value: float) -> void:
	_interaction_preferences.set_hit_fraction(value)
	clear_hover_group()

func save_interaction_preferences() -> bool:
	return _interaction_preferences.save()

func reset_interaction_preferences() -> bool:
	var saved: bool = _interaction_preferences.reset()
	clear_hover_group()
	return saved

## Prefer the face visibly under the held card. Also accept its vertical
## landing point: the inherited drag lift is presentation, not extra distance
## from a pile. Both paths use the same configured central face region.
func _snap_distance(at: Vector3, card: CardEntity) -> float:
	if not is_instance_valid(card) or card.is_market or card.dragging or not card.draggable \
		or _stack_occluded.has(card.uid) or card.has_meta("income_flight") or card.has_meta("delivery_flight") or _meeting_visitors.has(card.uid) or _strike_dancers.has(card.uid): return INF
	var visible := _face_hit_distance(at, card)
	if is_finite(visible): return visible
	# Do not extend idle queries or airborne-income picking. The drop flag
	# also covers Board's single-card release, which clears _drag_cards before
	# try_merge asks for a loose target.
	if _drag_cards.is_empty() and not _resolving_drop: return INF
	if not _drag_cards.is_empty() and _drag_cards[0].is_market: return INF
	var plane := Plane(card.global_basis.y, card.global_position)
	var landing: Variant = plane.intersects_ray(at, Vector3.DOWN)
	if landing == null: return INF
	# A visible hit's normalized squared distance is at most 2. Landing-only
	# candidates must never steal the target already visibly under the card.
	return _face_region_distance(landing, card) + Vector2.ONE.length_squared() + 1.0

## Attack targeting uses the same visible-face geometry as ordinary stacking,
## while opponent ownership still forbids picking up their cards.
func _face_hit_distance(at: Vector3, card: CardEntity) -> float:
	if _stack_occluded.has(card.uid): return INF
	var point := at
	if camera != null:
		var screen := camera.unproject_position(at)
		var plane := Plane(card.global_basis.y, card.global_position)
		var hit: Variant = plane.intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
		if hit == null: return INF
		point = hit
	return _face_region_distance(point, card)

func _face_region_distance(point: Vector3, card: CardEntity) -> float:
	var local := card.to_local(point)
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5
	half *= get_snap_hit_fraction()
	var offset := Vector2(local.x, local.z) / half
	return offset.length_squared() if absf(offset.x) <= 1.0 and absf(offset.y) <= 1.0 else INF

func _nearest_group(pos: Vector3, exclude: Array):
	if _drag_cards.any(func(card): return _is_striking_card(card)) or exclude.any(func(card): return _is_striking_card(card)): return null
	# Both the inherited hover and release paths use exactly the same anchor.
	var at: Vector3 = _drag_cards[0].global_position if not _drag_cards.is_empty() else pos
	if _drag_cards.size() == 1 and _drag_cards[0].def_id == "strike":
		var attack: Variant = _nearest_strike_group(at)
		if attack != null: return attack
	var best: Variant = null
	var best_distance := INF
	var excluded := {}
	for card in exclude: excluded[card] = true
	for group in groups:
		if group.cards.any(func(card): return excluded.has(card)): continue
		var targets: Array = group.cards
		if bool(group.get("compact", false)):
			# Buried cards must not extend the visible top card's snap region.
			# Incoming cash is away from the pile, so its next settled member
			# is the visible front until it lands.
			targets = _settled_front(targets)
		for card in targets:
			var distance := _snap_distance(at, card)
			if distance < best_distance:
				best_distance = distance
				best = group
	if best != null and best_distance > Vector2.ONE.length_squared():
		# Preserve a visibly targeted loose card too: the inherited release
		# asks for groups first, then loose cards only when this returns null.
		var loose := _nearest_loose_card(at, exclude)
		if loose != null and is_finite(_face_hit_distance(at, loose)): return null
	return best

func _nearest_loose_card(pos: Vector3, exclude: Array) -> CardEntity:
	if _drag_cards.any(func(card): return _is_striking_card(card)) or exclude.any(func(card): return _is_striking_card(card)): return null
	var at: Vector3 = _drag_cards[0].global_position if not _drag_cards.is_empty() else pos
	var best: CardEntity = null
	var best_distance := INF
	var excluded := {}
	for card in exclude: excluded[card] = true
	# group_of() scans the whole pile for each card. A membership set keeps a
	# loose-card query linear even while dragging beside thousands of work UIDs.
	var grouped := {}
	for group in groups:
		for card in group.cards: grouped[card] = true
	for card in cards:
		if excluded.has(card) or not is_instance_valid(card) or grouped.has(card): continue
		var distance := _snap_distance(at, card)
		if distance < best_distance:
			best_distance = distance
			best = card
	return best

func _settled_front(members: Array) -> Array:
	for card in members:
		if is_instance_valid(card) and not card.has_meta("income_flight") and not card.has_meta("delivery_flight"):
			return [card]
	return []

func try_merge(card: CardEntity) -> Dictionary:
	if card.has_meta("income_flight") or card.has_meta("delivery_flight") or _is_striking_card(card): return {"merged": false, "completed": false}
	return super.try_merge(card)

func _is_striking_card(card: CardEntity) -> bool:
	return is_instance_valid(card) and _state != null and _state.is_striking(card.uid)

func _strike_in_flight(uid: int) -> bool:
	return _strike_attacks.has(uid) or (_strike_dancers.has(uid) and not bool(_strike_dancers[uid].get("landed", false)))

func _strike_drop_conflict(at: Vector3) -> bool:
	var moving_striker := _drag_cards.any(func(card): return _is_striking_card(card))
	for card in cards:
		if not is_instance_valid(card) or card.is_market or _drag_cards.has(card): continue
		if not moving_striker and not _is_striking_card(card): continue
		if card.has_meta("in_flight") or _meeting_visitors.has(card.uid): continue
		var group: Variant = group_of(card)
		if group != null and bool(group.get("compact", false)) and group.cards[_top_index(group)] != card: continue
		if is_finite(_face_hit_distance(at, card)): return true
	return false

func _nearest_strike_group(at: Vector3) -> Variant:
	if _state == null: return null
	var best: Variant = null
	var nearest := INF
	for group in enemy_board.groups:
		var gid := int(group.get("work_group_id", -1))
		if not _state.can_strike_group(gid, int(_settings.local_owner)): continue
		var targets: Array = group.cards
		if bool(group.get("compact", false)):
			targets = _settled_front(targets)
		for card in targets:
			if not is_instance_valid(card) or _meeting_visitors.has(card.uid) or _strike_dancers.has(card.uid) \
				or card.has_meta("income_flight") or card.has_meta("delivery_flight"): continue
			var distance := _face_hit_distance(at, card)
			if distance < nearest:
				nearest = distance
				best = group
	return best

func _end_drag() -> void:
	_drop_target_person = -1
	if not _drag_cards.is_empty() and _state != null and not _drag_cards[0].is_market:
		var drop: Vector3 = _drag_cards[0].global_position
		if _strike_drop_conflict(drop):
			_restore_dismiss_pick()
			action_rejected.emit(str(_settings.strike_motion.combination_blocked_message))
			sync_state(_state)
			return
		var opponent_region := TableRegions.zone_rect(false, drawer_mode, _state.offers.size())
		if _drag_cards.any(func(card): return card.def_id == "strike") and opponent_region.has_point(Vector2(drop.x, drop.z)):
			var attack: Variant = _nearest_strike_group(drop) if _drag_cards.size() == 1 else null
			if attack == null:
				_restore_dismiss_pick()
				action_rejected.emit(str(_settings.strike_motion.invalid_drop_message))
				sync_state(_state)
				return
			var strike_id: int = _drag_cards[0].uid
			var target_gid := int(attack.work_group_id)
			_detach_drag()
			_picked_ids.clear()
			_begin_strike_attack(strike_id, int(_state.cards[strike_id].group), target_gid, true, "pending")
			strike_delivered.emit(strike_id, target_gid)
			var awaiting_ack: bool = _strike_attacks.get(strike_id, {}).get("awaiting_ack", false)
			if _state.cards.has(strike_id) and not _state.pending_strikes.has(strike_id) and not awaiting_ack:
				_release_strike_attack(strike_id, false)
				_restore_dismiss_pick()
			else: _dismiss_pick_snapshot.clear()
			sync_state(_state)
			return
		# 到访者不属于本桌可组合牌；咖啡仍可准确递给被拉走的己方员工。
		if _drag_cards.size() == 1 and str(_drag_cards[0].def_id) == "coffee":
			var visit := _nearest_meeting_person(drop)
			if visit >= 0:
				var coffee: int = _drag_cards[0].uid
				var gid: int = int(_state.cards[visit].group)
				cancel_pointer()
				ingredient_requested.emit(coffee, gid, visit)
				return
		var target: Variant = _nearest_group(drop, _drag_cards)
		var candidates: Array = target.cards if target != null else []
		if target == null:
			var loose := _nearest_loose_card(drop, _drag_cards)
			if loose != null: candidates = [loose]
		var distance := INF
		for card in candidates:
			if not _state.cards.has(card.uid) or not _state.config.is_person(str(_state.cards[card.uid].type)): continue
			var offset := Vector2(card.global_position.x - drop.x, card.global_position.z - drop.z)
			if offset.length_squared() < distance:
				distance = offset.length_squared()
				_drop_target_person = card.uid
	_resolving_drop = not _drag_cards.is_empty()
	super._end_drag()
	_resolving_drop = false

func _nearest_meeting_person(at: Vector3) -> int:
	var result := -1
	var nearest := float(_settings.meeting_motion.ingredient_radius)
	for uid in _meeting_visitors:
		if not by_uid.has(uid) or not _state.cards.has(uid) or int(_state.cards[uid].owner) != int(_settings.local_owner): continue
		var card: CardEntity = by_uid[uid]
		var distance := Vector2(at.x - card.global_position.x, at.z - card.global_position.z).length()
		if distance < nearest:
			nearest = distance
			result = int(uid)
	return result

func _queue_commit_drop() -> void:
	_drop_pending = true
	_commit_drop.call_deferred()

func _commit_drop() -> void:
	if not _drop_pending: return
	_drop_pending = false
	_dismiss_pick_snapshot.clear()
	if _state == null: return
	var alive: Array = _picked_ids.filter(func(uid):
		return by_uid.has(uid) and _state.cards.has(uid) and int(_state.cards[uid].owner) == int(_settings.local_owner))
	_picked_ids.clear()
	if alive.is_empty():
		sync_state(_state)
		return
	var visual: Variant = group_of(by_uid[alive[0]])
	var target := -1
	if visual != null:
		for member in visual.cards:
			if not alive.has(member.uid) and _state.cards.has(member.uid):
				target = int(_state.cards[member.uid].group)
				break
	var at: Vector3 = rest_origin(visual) if visual != null else rest_pos(by_uid[alive[0]])
	# 下班散卡始终冻结，原 Board 的松手分支不会靠重力把它降回桌面。
	# 在保存或提交联机落点前安排归位，也修正曾经叠到悬空散卡上的牌堆。
	var raised := not is_equal_approx(at.y, float(_settings.rest_y))
	at.y = float(_settings.rest_y)
	if visual == null:
		_move_to(by_uid[alive[0]], at)
	elif raised:
		_layout_group(visual, at)
	# 参会者只是暂离展示；搬动剩余整摞仍是原组的空间移动。
	var gid := _relocated_meeting_group(alive) if target < 0 else -1
	if gid < 0 and network_drop.is_valid() and network_drop.call(alive, target, _drop_target_person, at):
		_drop_target_person = -1
		sync_state(_state)
		return
	if gid < 0: gid = _state.move_cards(alive, target, _drop_target_person)
	_drop_target_person = -1
	if gid < 0:
		action_rejected.emit(str(_state.last_error))
	else:
		_origin_by_gid[gid] = at
		group_overrides[gid] = at
		for uid in alive:
			if _strike_dancers.has(uid) and bool(_strike_dancers[uid].get("landed", false)): _strike_dancers[uid].to = at
		if visual != null: visual["work_group_id"] = gid
	sync_state(_state)
	work_groups_changed.emit()

func _relocated_meeting_group(moved: Array) -> int:
	if _state.winner >= 0 or moved.is_empty(): return -1
	var gid := int(_state.cards[moved[0]].group)
	var visible: Array = []
	var has_visitor := false
	for uid in _state.group_cards(gid):
		if _meeting_visitors.has(uid): has_visitor = true
		else: visible.append(uid)
	if not has_visitor or visible.size() != moved.size(): return -1
	for uid in moved:
		if int(_state.cards[uid].group) != gid or not visible.has(uid): return -1
	return gid

func _purchase(payment: Array, market: CardEntity) -> void:
	_dismiss_pick_snapshot.clear()
	if _state == null or not is_instance_valid(market): return
	var placement: Dictionary = market.get_meta("purchase_placement", {})
	market.remove_meta("purchase_placement")
	if payment.is_empty() and placement.has("position"):
		var cash: Variant = _cash_at(placement.position, market)
		if cash != null: payment = cash.cards.duplicate()
	if not payment.is_empty() and not payment.all(func(card): return card.def_id == OffWorkCardDB.RES_CASH):
		action_rejected.emit(str(_settings.non_cash_purchase_message))
		_picked_ids.clear()
		_restore_payment_cards(payment)
		sync_state(_state)
		return
	var offer_id: int = int(market.get_meta("offer_id", -1))
	if not payment.is_empty() and _payment_amount(payment) < int(OffWorkCardDB.get_def(market.def_id).get("price", 0)):
		action_rejected.emit(str(_settings.insufficient_stack_money_message))
		_picked_ids.clear()
		market.global_position = market.get_meta("market_slot", market.global_position)
		_sync_market_tag(market)
		_restore_payment_cards(payment)
		sync_state(_state)
		return
	_pending_buy_position = placement.get("position", Vector3.INF)
	purchase_payment_ids = payment.map(func(card): return card.uid)
	# main 的唯一购买入口同步调用 OffWorkState.buy；三种原交互共享付款规则。
	offer_bought.emit(offer_id)
	purchase_payment_ids.clear()
	_picked_ids.clear()
	_pending_buy_position = Vector3.INF
	if is_instance_valid(market) and offers_by_id.has(offer_id):
		_stop_move(market, false)
		market.global_position = market.get_meta("market_slot", market.global_position)
		_sync_market_tag(market)
	_restore_payment_cards(payment)
	sync_state(_state)

func _restore_payment_cards(payment: Array) -> void:
	for card in payment:
		if not is_instance_valid(card) or not _state.cards.has(card.uid): continue
		var gid: int = int(_state.cards[card.uid].group)
		if _state.group_cards(gid).size() == 1 and group_of(card) == null:
			card.freeze = true
			_move_to(card, _origin_by_gid.get(gid, card.global_position))

## 原手势与命中路径不变。实时版一张现金记录可承载多元，门槛读取金额而非牌数。
func _market_payment_group(market: CardEntity, pos: Vector3) -> Variant:
	var cash: Variant = _cash_at(pos, market)
	if cash == null or not _market_drop_is_own(pos): return null
	return cash if _payment_amount(cash.cards) >= int(OffWorkCardDB.get_def(market.def_id).get("price", 0)) else null

func _cash_at(pos: Vector3, market: CardEntity) -> Variant:
	var group: Variant = _nearest_group(pos, [market])
	if _is_cash_group(group): return group
	var loose := _nearest_loose_card(pos, [market])
	if loose != null and loose.def_id == OffWorkCardDB.RES_CASH and loose.draggable:
		return make_group([loose])
	return null

func _is_cash_group(group: Variant) -> bool:
	if group == null or group.cards.is_empty(): return false
	# A landed wallet remains usable while newly earned money travels to it.
	# Only the visible wallet can be targeted; the incoming notes cannot.
	return group.cards.all(func(card):
		return is_instance_valid(card) and not card.is_market and card.def_id == OffWorkCardDB.RES_CASH \
			and card.card_owner == int(_settings.local_owner)) \
		and group.cards.any(func(card): return card.draggable and not card.has_meta("income_flight"))

func _payment_amount(payment: Array) -> int:
	var amount := 0
	for card in payment:
		if _state.cards.has(card.uid) and int(_state.cards[card.uid].owner) == int(_settings.local_owner):
			amount += _state.available_cash_amount(int(card.uid))
	return amount

func _record_structure_key() -> Array:
	var actors: Array = []
	for uid in _state.activity_card_ids():
		var card: Dictionary = _state.cards[uid]
		actors.append([uid, card.type, card.owner, card.group, card.status, card.activity])
	var visitors: Array = []
	for uid in _meeting_visitors: visitors.append([uid, _meeting_visitors[uid].phase == "return"])
	return [_state.get_instance_id(), _state.config.get_instance_id(), _state.revision, _state.membership_version(),
		_state.cards.size(), _state.groups.size(), _state.winner, _settings.local_owner,
		groups.size(), enemy_board.groups.size(),
		player_bounds, enemy_board.player_bounds, _settings.opponent_layout.hash(),
		actors, visitors, _strike_dancers.keys(), _strike_attacks.keys(),
		_interacting(), _drop_pending, _stack_layout_revision]

func _update_record(card: OffWorkCard, record: Dictionary) -> void:
	card.update_record(record)
	card.draggable = _state.winner < 0 and int(record.owner) == int(_settings.local_owner) and not _cash_flights.has(card.uid) and not _delivery_flights.has(card.uid) and not _strike_in_flight(card.uid)
	card.is_market = false

func sync_state(state: Object, setup: RefCounted = null) -> void:
	var rebuilding := _state == null
	if _state == null:
		_opening_layout_enabled = _has_uncombined_opening(state)
	_state = state
	if not is_inside_tree(): return
	_ensure_enemy_board()
	# Timers do not change membership. Keep personnel/tools and real group bars
	# live without revisiting thousands of unchanged work entities every 100 ms.
	# Dictionary identity also detects a replay/LAN snapshot replacing records
	# while retaining the same State instance and revision.
	if setup == null and is_same(_record_cards, state.cards) and is_same(_record_groups, state.groups) \
		and _record_structure_key() == _record_sync_key:
		for uid in state.activity_card_ids():
			if by_uid.has(uid): _update_record(by_uid[uid], state.cards[uid])
		_sync_live_presentation()
		return
	if state.winner >= 0: _freeze_terminal_layout()
	_effect_tweens = _effect_tweens.filter(func(tween): return tween != null and tween.is_valid())
	# A single production tick can retire hundreds of files. Unregister all
	# affected cards first, then close each surviving stack only once.
	_record_removal_groups.clear()
	_defer_record_refresh = state.winner < 0
	_defer_side_refresh = state.winner < 0
	(enemy_board as IncomeBoard).defer_record_refresh = _defer_record_refresh
	for uid in by_uid.keys():
		var card: OffWorkCard = by_uid[uid]
		_previous_positions[uid] = card.global_position
		if not state.cards.has(uid):
			card.set_meta("retire_in_stack", _retirement_overlaps_stack(card))
			_stack_occluded.erase(uid)
			_transfer_departures.erase(uid)
			_cancel_cash_flight(card)
			_release_delivery(uid)
			_release_strike_motion(uid, false)
			_release_strike_attack(uid, false)
			_meeting_visitors.erase(uid)
			_meeting_centers.erase(uid)
			_forget_press_card(card)
			if state.winner >= 0:
				_presenter(card.card_owner).unregister_card(card)
			else:
				_unregister_record_card(card)
			card.collision_layer = 0
			card.collision_mask = 0
			card.freeze = true
			card.set_process(false)
			by_uid.erase(uid)
			_retired_cards[uid] = card
			if state.winner >= 0:
				# No upward retirement through the still-closed winning stack.
				card.hide()
				_dispose_terminal_card.call_deferred(uid, card)
			else:
				_retire(card)
	_assembling = setup != null
	for uid in state.cards:
		if setup: await setup.checkpoint(get_tree())
		var record: Dictionary = state.cards[uid]
		var card: OffWorkCard = by_uid.get(uid)
		if card == null:
			_invalidate_stack_occlusion()
			card = CardView.new()
			var defer_face: bool = record.type in ["work", "money"] and state.winner < 0 and state.groups[record.group].cards.size() > int(_settings.stack_display.expanded_visible_layers)
			card.configure(record, state.config.cards[record.type], false, defer_face)
			# Enter the physics world as the stationary body this table actually
			# owns, not as a temporary dynamic body overlapping every prior UID.
			card.freeze = true
			if defer_face: _stack_occluded[uid] = true
			add_child(card)
			by_uid[uid] = card
			_presenter(int(record.owner)).register_card(card)
			card.freeze = true
			if _pending_buy_position != Vector3.INF and int(record.owner) == int(_settings.local_owner):
				_origin_by_gid[int(record.group)] = _free_spawn_position(int(record.group), int(record.owner), _pending_buy_position)
			card.global_position = _origin_for(int(record.group), int(record.owner))
		elif card.card_owner != int(record.owner):
			# Network snapshots can sync again before their transfer event is presented.
			_transfer_departures[uid] = card.global_position
			_release_delivery(uid)
			_forget_press_card(card)
			if state.winner >= 0:
				_presenter(card.card_owner).unregister_card(card)
				card.global_position = _origin_for(int(record.group), int(record.owner))
			else:
				_unregister_record_card(card)
			_presenter(int(record.owner)).register_card(card)
		if _cash_flights.has(uid) and int(_cash_flights[uid].group) != int(record.group):
			_cancel_cash_flight(card)
		if card.group_id != int(record.group) or card.type != str(record.type): _invalidate_stack_occlusion()
		_update_record(card, record)
	_assembling = false
	_defer_record_refresh = false
	(enemy_board as IncomeBoard).defer_record_refresh = false
	_syncing_structure = true
	for pending in _record_removal_groups:
		var presenter: Board = pending.presenter
		var group: Dictionary = pending.group
		if not group.cards.is_empty() and group in presenter.groups:
			presenter._layout_group(group, pending.origin)
	_record_removal_groups.clear()
	if state.winner >= 0:
		_syncing_structure = false
		_sync_group_task_progress()
		_restore_terminal_stationary_faces()
		return
	_sync_meeting_visitors()
	_sync_strike_dancers()
	_sync_strike_attacks()
	_placing_snapshot = rebuilding
	if not _interacting() and not _drop_pending: _sync_owner_groups(int(_settings.local_owner), self)
	_sync_owner_groups(int(_settings.opponent_owner), enemy_board)
	_placing_snapshot = false
	_syncing_structure = false
	# Membership/layout may have changed more than once while retiring cards and
	# reconciling authoritative groups. Resolve side counts and height once,
	# after every destination is known, as the ordinary final resync already did.
	_defer_side_refresh = false
	for presenter in [self, enemy_board]: presenter.resync_sides()
	_sync_live_presentation()
	_record_cards = state.cards
	_record_groups = state.groups
	_record_sync_key = _record_structure_key()

func _sync_live_presentation() -> void:
	_sync_stack_occlusion()
	_sync_market()
	_sync_group_task_progress()
	if side_extract != null: side_extract.sync_state()
	_advance_meeting_visitors(0.0)
	_advance_strike_dancers(0.0)
	_advance_strike_attacks(0.0)
	_advance_deliveries(0.0)

func refresh_group(group, top_pos := Vector3.INF) -> bool:
	_invalidate_stack_occlusion()
	return false if _defer_record_refresh else super.refresh_group(group, top_pos)

func _unregister_record_card(card: OffWorkCard) -> void:
	var presenter := _presenter(card.card_owner)
	var group: Variant = presenter.group_of(card)
	if group != null:
		var recorded := false
		for pending in _record_removal_groups:
			if is_same(pending.group, group):
				recorded = true
				break
		if not recorded:
			_record_removal_groups.append({"presenter": presenter, "group": group,
				"origin": presenter.rest_origin(group)})
	# Keep the original interaction, drag-array and move-tween cleanup. Only
	# its repeated recipe refresh is deferred until the whole batch is known.
	presenter.unregister_card(card)

## A terminal sync must not close the gaps left by the final consumed files or
## restore a pointer snapshot before the exit animation has captured the pose.
func _freeze_terminal_layout() -> void:
	if _terminal_pose_locked: return
	_terminal_pose_locked = true
	(enemy_board as IncomeBoard).terminal_sides_hidden = true
	var poses: Dictionary = {}
	for uid in by_uid:
		var card: OffWorkCard = by_uid[uid]
		poses[uid] = {"card": card.global_transform, "visual": card._visual.transform}
	for tween in _effect_tweens:
		if tween != null and tween.is_valid(): tween.kill()
	_effect_tweens.clear()
	for uid in _retired_cards:
		var card: OffWorkCard = _retired_cards[uid]
		if is_instance_valid(card):
			card.hide()
			_dispose_terminal_card.call_deferred(uid, card)
	cancel_pointer()
	_set_hover_card(null)
	input_locked = true
	for uid in by_uid:
		var card: OffWorkCard = by_uid[uid]
		_release_meeting_motion(uid, false)
		_release_strike_motion(uid, false)
		_release_strike_attack(uid, false)
		# Already-airborne income and coffee may finish their independent arc.
		if not _cash_flights.has(uid) and not _delivery_flights.has(uid):
			_presenter(card.card_owner)._stop_move(card, false)
		card.reset_interaction_visual()
		card.global_transform = poses[uid].card
		card._visual.transform = poses[uid].visual
		card.freeze = true
		card.dragging = false
		card.draggable = false
		card.input_ray_pickable = false
	_meeting_centers.clear()
	_clear_terminal_sides()

func _clear_terminal_sides() -> void:
	# Logical personnel remain in the match record after their cards go home.
	# Their old side list must not become a floating, empty "combination".
	for presenter in [self, enemy_board]:
		for group in presenter.groups + presenter._ext_side.values():
			for node in group.get("side", []):
				if is_instance_valid(node): node.hide()
			presenter._clear_side(group)
			group["extract_rows"] = []
		presenter.clear_side_badges()

func _restore_terminal_stationary_faces() -> void:
	if not _terminal_pose_locked: return
	for presenter in [self, enemy_board]:
		for group in presenter.groups:
			var departed := false
			var leaving := false
			for card: OffWorkCard in group.cards:
				if not card._retired: continue
				departed = true
				if card.visible: leaving = true
			if not departed or leaving: continue
			# Overflow used to stay hidden behind a person who has now left.
			# Reveal one remaining face at each frozen position, never reflow
			# the stack or expose several coincident faces through one another.
			var occupied: Dictionary = {}
			for card: OffWorkCard in group.cards:
				if card._retired or not card.visible or not _state.cards.has(card.uid): continue
				var at := card._visual.global_position
				card._visual.visible = not occupied.has(at)
				if occupied.has(at): _stack_occluded[card.uid] = true
				else:
					occupied[at] = true
					_stack_occluded.erase(card.uid)

func _dispose_terminal_card(uid: int, card: Variant) -> void:
	_retired_cards.erase(uid)
	if is_instance_valid(card): card.queue_free()

func _departure_clearance(card: OffWorkCard) -> float:
	var direction: float = float(OffWorkUI.section("animation").leave_direction_by_owner[str(card.card_owner)])
	var group: Variant = _presenter(card.card_owner).group_of(card)
	var members: Array = group.cards if group != null else [card]
	var start := card._visual.global_position.x
	var edge := start
	for member: OffWorkCard in members:
		# Rotation may be present during hover/meeting handoff, so project the
		# face corners rather than assuming an axis-aligned unit-sized card.
		for x in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var point := member._visual.to_global(Vector3(CardEntity.CARD_SIZE.x * x, 0.0, CardEntity.CARD_SIZE.z * z))
				edge = maxf(edge, point.x) if direction > 0.0 else minf(edge, point.x)
	var half_width := CardEntity.CARD_SIZE.x * card._visual.global_basis.get_scale().x * OffWorkUI.number("animation", "leave_clearance_scale") * 0.5
	return edge - start + direction * (half_width + OffWorkUI.number("animation", "leave_clearance_padding"))

## Repeated material shares bounded visual slots. Every actual UID stays in
## the group; only one real face draws at each slot, including a held suffix.
func _invalidate_stack_occlusion() -> void:
	_stack_layout_revision += 1

func _occlusion_dependencies() -> Array:
	# Moving an intact pile changes world positions, not its relative slots.
	# Layout/recipe entry points invalidate membership/order. Only the small
	# moving sets and a held suffix need inspection between structural changes.
	return [_stack_layout_revision, by_uid.size(), groups.size(),
		enemy_board.groups.size() if is_instance_valid(enemy_board) else 0,
		player_bounds, enemy_board.player_bounds if is_instance_valid(enemy_board) else Rect2(),
		_settings.stack_display.hash(), _drag_compact, _drag_cards.hash(), _drag_offsets.hash(),
		_cash_flights.keys(), _delivery_flights.keys(), _meeting_visitors.keys(),
		_strike_dancers.keys(), _strike_attacks.keys()]

func _sync_stack_occlusion() -> void:
	if _terminal_pose_locked: return
	var dependencies := _occlusion_dependencies()
	if dependencies == _stack_occlusion_dependencies: return
	_stack_occlusion_dependencies = dependencies
	var hidden: Dictionary = {}
	var representatives: Dictionary = {}
	var thin: Dictionary = {}
	var muted_titles: Dictionary = {}
	for presenter in [self, enemy_board]:
		if not is_instance_valid(presenter): continue
		for group in presenter.groups:
			var compact := bool(group.get("compact", false))
			var dense: bool = not compact and group.cards.size() > int(_settings.stack_display.expanded_visible_layers)
			if not compact and not dense: continue
			var offsets: Array = []
			var preferred: Dictionary = {}
			for index in group.cards.size():
				offsets.append(presenter._stack_offset(group, index))
			if dense:
				for index in group.work_expanded_indices: preferred[group.cards[index].uid] = true
				for card in group.cards:
					if not _has_external_pose(card.uid): thin[card.uid] = true
				for slot in group.work_expanded_indices.size() - 1:
					var index: int = group.work_expanded_indices[slot]
					var next: int = group.work_expanded_indices[slot + 1]
					if not _has_external_pose(group.cards[index].uid) and offsets[next].z - offsets[index].z < float(_settings.stack_display.expanded_title_min_gap):
						if not _has_external_pose(group.cards[index].uid): muted_titles[group.cards[index].uid] = true
			var head := int(group.cards[0].uid) if compact and not group.cards.is_empty() else -1
			_collect_stack_visibility(group.cards, offsets, preferred, hidden, representatives, head)
	if not _drag_cards.is_empty():
		var preferred: Dictionary = {}
		for card in _drag_cards:
			if not _stack_occluded.has(card.uid): preferred[card.uid] = true
			if not _drag_compact and _muted_stack_titles.has(card.uid): muted_titles[card.uid] = true
			if not _drag_compact and (_drag_cards.size() > int(_settings.stack_display.expanded_visible_layers) or _thin_stack_cards.has(card.uid)):
				thin[card.uid] = true
		_collect_stack_visibility(_drag_cards, _drag_offsets, preferred, hidden, representatives)
	for uid in _stack_occluded:
		if not hidden.has(uid) and by_uid.has(uid): by_uid[uid].reveal_stack_face()
	for uid in hidden:
		if by_uid.has(uid): by_uid[uid]._visual.hide()
	for uid in _thin_stack_cards:
		if not thin.has(uid) and by_uid.has(uid) and not by_uid[uid]._retired and not by_uid[uid].face_deferred: by_uid[uid].card_mesh.show()
	for uid in thin:
		if by_uid.has(uid) and not by_uid[uid].face_deferred: by_uid[uid].card_mesh.hide()
	for uid in _muted_stack_titles:
		if not muted_titles.has(uid) and by_uid.has(uid): by_uid[uid].label.show()
	for uid in muted_titles:
		if by_uid.has(uid): by_uid[uid].label.hide()
	_stack_occluded = hidden
	_stack_representatives = representatives
	_thin_stack_cards = thin
	_muted_stack_titles = muted_titles

func _collect_stack_visibility(members: Array, offsets: Array, preferred: Dictionary, hidden: Dictionary, representatives: Dictionary, compact_head := -1) -> void:
	var occupied: Dictionary = {}
	for index in mini(members.size(), offsets.size()):
		var card: CardEntity = members[index]
		if _has_external_pose(card.uid): continue
		var at: Vector3 = offsets[index]
		if not occupied.has(at):
			occupied[at] = card.uid
		elif preferred.has(card.uid):
			hidden[occupied[at]] = true
			occupied[at] = card.uid
		else:
			hidden[card.uid] = true
	for index in mini(members.size(), offsets.size()):
		var uid: int = members[index].uid
		if hidden.has(uid): representatives[uid] = compact_head if compact_head >= 0 else occupied[offsets[index]]

func _has_external_pose(uid: int) -> bool:
	return _cash_flights.has(uid) or _delivery_flights.has(uid) or _meeting_visitors.has(uid) or _strike_dancers.has(uid) or _strike_attacks.has(uid)

## Keep source stacking order and expose one authoritative work bar per group.
## Meeting/coffee retain their own timers; they never borrow a work countdown.
func _sync_group_task_progress() -> void:
	for uid in _group_progress_cards:
		if by_uid.has(uid) and _state.cards.has(uid): by_uid[uid].update_record(_state.cards[uid])
	_group_progress_cards.clear()
	if _state != null and _state.winner >= 0:
		_clear_terminal_progress()
		return
	for presenter in [self, enemy_board]:
		for group in presenter.groups:
			if group.cards.is_empty(): continue
			var top: OffWorkCard = group.cards[presenter._top_index(group)]
			var outsource := -1
			for tool in _state.group_actions(top.group_id):
				if str(_state.cards[tool].type) == "outsource" and str(_state.cards[tool].status) == "active": outsource = tool
			if outsource >= 0:
				if not top.has_dedicated_progress():
					var timer: Dictionary = _state.cards[outsource]
					_set_group_progress(top, 1.0 - float(timer.remaining) / float(timer.total), false, "outsource")
				continue
			var gid := int(top.group_id)
			if _state.groups.has(gid) and str(_state.groups[gid].job) == "slack":
				var representative := _work_progress_card(group, presenter, "slack")
				if representative != null:
					_set_group_progress(representative, _state.group_slack_progress(gid),
						_state.group_slack_participants(gid).is_empty(), "slack")
				continue
			if _state.groups.has(gid) and str(_state.groups[gid].job) == "transfer":
				var representative := _work_progress_card(group, presenter, "transfer")
				if representative != null and not _state.group_work(gid).is_empty():
					_set_group_progress(representative, _state.group_transfer_progress(gid),
						_state.group_transfer_participants(gid).is_empty(), "transfer")
				continue
			var work_person := -1
			var has_work: bool = not _state.group_work(top.group_id).is_empty()
			for person in _state.group_people(top.group_id):
				if _state.is_meeting_target(person) and _state.config.can_work(str(_state.cards[person].type)) and has_work:
					if work_person < 0: work_person = person
				if not _state.tasks.has(person) or str(_state.tasks[person].kind) != "work": continue
				if work_person < 0: work_person = person
				if not bool(_state.cards[person].paused): work_person = person
			if work_person >= 0:
				var representative := _work_progress_card(group, presenter)
				if representative != null:
					var work_group := int(_state.cards[work_person].group)
					_set_group_progress(representative, _state.group_work_progress(work_group),
						_state.group_work_participants(work_group).is_empty(), "work")
				continue
			if _state.tasks.has(top.uid) or top.has_dedicated_progress(): continue
			var participant := -1
			for member in group.cards:
				if not _state.tasks.has(member.uid) or not _state.cards.has(member.uid): continue
				if member.is_meeting_participant(): continue
				var data: Dictionary = _state.cards[member.uid]
				if int(data.group) != top.group_id: continue
				if participant < 0: participant = member.uid
				if not bool(data.paused):
					participant = member.uid
					break
			if participant >= 0:
				var data: Dictionary = _state.cards[participant]
				_set_group_progress(top, float(data.progress), bool(data.paused), str(data.activity), participant)
	_sync_debug_timers()

func _set_group_progress(card: OffWorkCard, progress: float, paused: bool, phase: String, source := -1) -> void:
	card.set_task_progress(progress, true, paused, phase, source)
	_group_progress_cards[card.uid] = true

func _clear_terminal_progress() -> void:
	# Both sides stop at the result, including the opponent's unfinished jobs.
	# Clearing completion hold also prevents a final settlement flash reopening it.
	for card: OffWorkCard in by_uid.values():
		card._task_completion_hold = 0.0
		card.set_task_progress(0.0, false)
		card.set_debug_timer(false, -1.0)

func _sync_debug_timers() -> void:
	var enabled := get_debug_mode() and _state != null and int(_state.winner) < 0
	var current := _group_progress_cards.duplicate()
	if _state != null:
		for uid in _state.activity_card_ids(): current[uid] = true
	for uid in _debug_timer_cards:
		if not current.has(uid) and by_uid.has(uid): by_uid[uid].set_debug_timer(false, -1.0)
	for uid in current:
		if not by_uid.has(uid): continue
		var card: OffWorkCard = by_uid[uid]
		var remaining := -1.0
		if enabled and card._task_progress_active:
			remaining = ProgressClock.remaining(_state, card._task_progress_source, card._task_progress_phase, card._task_progress_value)
		card.set_debug_timer(enabled, remaining)
	_debug_timer_cards = current

func _work_progress_card(group: Dictionary, presenter: Board, kind := "work") -> OffWorkCard:
	var candidates: Array = [group.cards[presenter._top_index(group)]] + group.cards
	for card: OffWorkCard in candidates:
		if _settings.stack_display.back_cards.has(card.def_id): continue
		if card.has_dedicated_progress() or card.is_meeting_participant(): continue
		if _state.tasks.has(card.uid) and str(_state.tasks[card.uid].kind) != kind: continue
		return card
	return null

func _flash_group_task_completion(source: int, kind := "work") -> void:
	if not by_uid.has(source): return
	var card: OffWorkCard = by_uid[source]
	var presenter := _presenter(card.card_owner)
	var group: Variant = presenter.group_of(card)
	if group == null or group.cards.is_empty(): return
	var representative := _work_progress_card(group, presenter, kind)
	if representative != null: representative.flash_task_completion()

func _forget_press_card(card: CardEntity) -> void:
	_picked_ids.erase(card.uid)
	if _press_snap.has("cards"):
		_press_snap.cards.erase(card)
		if _press_snap.get("card") == card and not _press_snap.cards.is_empty():
			_press_snap.card = _press_snap.cards[0]

func _presenter(owner_value: int) -> Board:
	return self if owner_value == int(_settings.local_owner) else enemy_board

func _stack_offset(group, index: int) -> Vector3:
	return _work_stack_offset(group, index, self)

## XYZ 一起补间会让展开、收拢的相反层序在半途穿过彼此。先沿镜头射线
## 切换到目的层，屏幕上的牌心不动，再将整摞按共同的高度差飞到各自落点。
func _align_stack_layers(members: Array, offsets: Array) -> void:
	if _placing_snapshot: return
	var base_y := INF
	for i in members.size():
		var card: CardEntity = members[i]
		if not _has_external_pose(card.uid):
			base_y = minf(base_y, card.global_position.y - (offsets[i] as Vector3).y)
	if base_y == INF: return
	base_y = maxf(base_y, float(_settings.rest_y))
	_align_stack_layers_at(members, offsets, base_y)

func _align_stack_layers_at(members: Array, offsets: Array, base_y: float) -> void:
	for i in members.size():
		var card: CardEntity = members[i]
		if _has_external_pose(card.uid): continue
		var pos := card.global_position
		var target_y := base_y + (offsets[i] as Vector3).y
		if is_equal_approx(pos.y, target_y): continue
		var ray := Vector3.DOWN
		if is_instance_valid(camera):
			ray = camera.global_basis.z if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else pos - camera.global_position
		if not is_zero_approx(ray.y):
			pos += ray * ((target_y - pos.y) / ray.y)
		pos.y = target_y
		card.global_position = pos

func _work_stack_offset(group: Dictionary, index: int, presenter: Board) -> Vector3:
	if index == 0:
		_configure_cash_layers(group, presenter)
	if not bool(group.get("compact", false)) and group.cards.size() > int(_settings.stack_display.expanded_visible_layers):
		if index == 0: StackLayout.prepare(group, _settings.stack_display)
		var available := float(_settings.stack_display.expanded_max_span)
		if Board.has_table_bounds(presenter.player_bounds):
			available = maxf(0.0, presenter.player_bounds.size.y - CardEntity.CARD_SIZE.z - Board.BOUNDS_PAD * 2.0)
		return StackLayout.offset(group, index, _settings.stack_display, available)
	return Board._stack_offset_of(group, index)

func _configure_cash_layers(group: Dictionary, presenter: Board) -> void:
	if not bool(group.get("compact", false)) or group.cards.is_empty(): return
	if not group.cards.all(func(card): return card.def_id == "money"): return
	# Small money piles expose each real unit; larger piles retain the original
	# bounded footprint and can still be expanded/split with native gestures.
	var cap := int(_settings.stack_display.money_visible_layers)
	if Board.has_table_bounds(presenter.player_bounds):
		var available := maxf(0.0, presenter.player_bounds.size.y - CardEntity.CARD_SIZE.z - Board.BOUNDS_PAD * 2.0)
		cap = mini(cap, maxi(1, int(floor(available / Board.COMPACT_GAP.z)) + 1))
	group.bounded_compact_cap = cap

## 正在执行的组合露出自己的工具牌；收拢时队首在上，展开时队尾在上。
## 只改变显示顺序，OffWorkState 中的成员、任务与生产进度保持各自的原顺序。
func _stack_face_order(group: Dictionary) -> Array:
	var back: Array = []
	var regular: Array = []
	var work_front: Array = []
	var production := false
	var meeting_group := false
	if not group.cards.is_empty() and _state != null:
		var gid := int(group.cards[0].group_id)
		production = _state.groups.has(gid) and str(_state.groups[gid].job) == "work" and not _state.group_people(gid).is_empty()
		if _state.groups.has(gid):
			meeting_group = str(_state.groups[gid].get("function", _state.groups[gid].job)) == "meeting"
	var front: CardEntity = null
	var front_priority := 0
	var meeting_type := str(_settings.meeting_motion.front_card)
	for card: CardEntity in group.cards:
		if production and card.def_id == "work": work_front.append(card)
		elif _settings.stack_display.back_cards.has(card.def_id): back.append(card)
		else: regular.append(card)
		var priority := 0
		# An unused meeting added to a working group must not cover its work bar.
		# The meeting function remains selected throughout its cooldown.
		if card.def_id == meeting_type and meeting_group:
			priority = 3 if _state != null and _state.meetings.has(card.uid) else 1
		elif card.def_id == "slack" and _state != null and _state.cards.has(card.uid):
			if _state.cards[card.uid].status == "active": priority = 2
		elif card.def_id == "boss" and _state != null and _state.cards.has(card.uid):
			if _state.cards[card.uid].activity == "recruitment": priority = 3
		# 多张工具共用同一生产批次。刷新、折叠、重连时都选同一张实际卡牌。
		if priority > front_priority or (priority > 0 and priority == front_priority and card.uid < front.uid):
			front = card
			front_priority = priority
	var compact := bool(group.get("compact", false))
	var ordered := regular + back if compact else back + regular
	# Keep all files contiguous, so dragging the exposed work suffix still
	# separates work from personnel after reversing the top-facing order.
	ordered = work_front + ordered if compact else ordered + work_front
	if front != null:
		ordered.erase(front)
		if compact: ordered.push_front(front)
		else: ordered.append(front)
	return ordered

func _core_first(group) -> void:
	super._core_first(group)
	group.cards = _stack_face_order(group)

func _layout_group(group, origin := Vector3.INF) -> bool:
	_invalidate_stack_occlusion()
	var ordered := _stack_face_order(group)
	if ordered != group.cards and origin == Vector3.INF:
		origin = rest_origin(group)
		origin.y = float(_settings.rest_y)
	group.cards = ordered
	var result: Variant = _try_compact_sync_layout(self, group, origin)
	if result != null: return bool(result)
	return super._layout_group(group, origin)

## During authoritative reconciliation a capped pile usually loses only a few
## sheets. Its thousands of covered UIDs retain exactly the same bottom slot.
## Reuse the original clamp/alignment/motion rules, but apply them only to cards
## whose position or motion actually differs. Pointer edits and expanded piles
## continue through the full shared Board layout.
func _try_compact_sync_layout(presenter: Board, group: Dictionary, origin: Vector3) -> Variant:
	if not _syncing_structure or _placing_snapshot or _interacting() or _drop_pending \
		or origin == Vector3.INF or not bool(group.get("compact", false)) \
		or presenter.align_stack_layers != _align_stack_layers \
		or not Board.has_table_bounds(presenter.player_bounds) \
		or absf(origin.y - float(_settings.rest_y)) > 0.0000001: return null
	var members: Array = group.cards
	var count := members.size()
	var available := maxf(0.0, presenter.player_bounds.size.y - CardEntity.CARD_SIZE.z - Board.BOUNDS_PAD * 2.0)
	var cap := mini(Board.BOUNDED_COMPACT_LAYERS, maxi(1, int(floor(available / Board.COMPACT_GAP.z)) + 1))
	if not members.is_empty() and members[0].def_id == "money" and members.all(func(card): return card.def_id == "money"):
		cap = mini(int(_settings.stack_display.money_visible_layers), maxi(1, int(floor(available / Board.COMPACT_GAP.z)) + 1))
	if count <= cap: return null
	group.z_gap = minf(Board.STACK_GAP.z, available / maxf(count - 1, 1))
	group.bounded_compact_cap = cap
	var distinct: Array = []
	for index in cap: distinct.append(Board.capped_offset(count, index, cap))
	var base := origin
	# Recover the canonical table height after float32 top-minus-offset
	# cancellation (e.g. 0.0500000119 instead of 0.05). The guard admits only
	# sub-micrometre roundoff; raised piles keep the ordinary full layout.
	base.y = float(_settings.rest_y)
	base = presenter.clamp_player_position(base, distinct)
	var changed: Array = []
	var changed_offsets: Array = []
	var base_y := INF
	for index in count:
		var card: CardEntity = members[index]
		var offset: Vector3 = distinct[index] if index < cap else Vector3.ZERO
		var at := card.global_position
		var external := _has_external_pose(card.uid)
		# Board retains completed tween records for rest-position queries. Their
		# presence alone does not mean this settled UID needs motion again.
		var move: Variant = presenter._move_tw.get(card)
		var moving: bool = move != null and move.tw != null and is_instance_valid(move.tw) and move.tw.is_running()
		if not external: base_y = minf(base_y, at.y - offset.y)
		if at != base + offset or not card.freeze or moving \
			or external or card.has_meta("dest_pos") or card.has_meta("fly_tw"):
			changed.append(card)
			changed_offsets.append(offset)
	if base_y != INF and not changed.is_empty():
		_align_stack_layers_at(changed, changed_offsets, maxf(base_y, float(_settings.rest_y)))
	for index in changed.size():
		var card: CardEntity = changed[index]
		card.freeze = true
		presenter._move_to(card, base + (changed_offsets[index] as Vector3))
	return presenter.refresh_group(group, base + (distinct[0] as Vector3))

func _sync_owner_groups(owner_value: int, presenter: Board) -> void:
	var desired: Dictionary = {}
	for gid in _state.groups:
		if int(_state.groups[gid].owner) != owner_value: continue
		var members: Array = []
		for uid in _state.groups[gid].cards:
			if by_uid.has(uid) and not _strike_dancers.has(uid) and not _strike_attacks.has(uid) and (not _meeting_visitors.has(uid) or _meeting_visitors[uid].phase == "return"): members.append(by_uid[uid])
		if not members.is_empty(): desired[gid] = members
	var matched: Dictionary = {}
	var claimed: Array = []
	for gid in desired:
		for group in presenter.groups:
			if int(group.get("work_group_id", -1)) == int(gid) and not group in claimed:
				matched[gid] = group
				claimed.append(group)
				break
	for gid in desired:
		if matched.has(gid): continue
		for member in desired[gid]:
			var group: Variant = presenter.group_of(member)
			if group != null and not group in claimed:
				matched[gid] = group
				claimed.append(group)
				break
	for group in presenter.groups.duplicate():
		if not group in claimed: presenter._remove_group(group)
	# Capture every old anchor before laying out any destination. A transferred
	# source head can belong to a later group in this loop: once its destination
	# tween is scheduled, rest_origin(source) would read the other pile's slot.
	var previous_origins: Dictionary = {}
	for gid in matched: previous_origins[gid] = presenter.rest_origin(matched[gid])
	for gid in desired:
		var members: Array = desired[gid]
		var group: Variant = matched.get(gid)
		if group != null:
			var at: Vector3 = previous_origins[gid]
			# Membership is a set, but presentation order is retained. Linear
			# Array.has scans here made every HUD sync quadratic for huge piles.
			var member_ids: Dictionary = {}
			for card in members: member_ids[card.uid] = true
			var ordered: Array = []
			for card in group.cards:
				if member_ids.has(card.uid):
					ordered.append(card)
					member_ids.erase(card.uid)
			for card in members:
				if member_ids.has(card.uid): ordered.append(card)
			if _meeting_home_order.has(gid):
				var home_order: Array = _meeting_home_order[gid]
				var home_indices: Dictionary = {}
				for index in home_order.size(): home_indices[home_order[index]] = index
				ordered.sort_custom(func(a, b):
					var a_index: int = home_indices.get(a.uid, -1)
					var b_index: int = home_indices.get(b.uid, -1)
					return a_index < b_index if a_index >= 0 and b_index >= 0 else a_index >= 0)
			ordered = _stack_face_order({"cards": ordered, "compact": group.get("compact", false)})
			var same: bool = ordered == group.cards
			group["work_group_id"] = gid
			_origin_by_gid[gid] = at
			if not same:
				group.cards = ordered
				if bool(group.get("compact", false)): presenter._core_first(group)
				presenter._layout_group(group, at)
			# An unchanged composition needs neither native recipe evaluation nor
			# another layout. Real task bars and side labels sync below once.
		elif members.size() > 1:
			var at := _origin_for(int(gid), owner_value)
			group = presenter.make_group(members, bool(_compact_by_gid.get(gid, _settings.default_compact)))
			group["work_group_id"] = gid
			presenter.groups.append(group)
			presenter._layout_group(group, at)
		else:
			var single: CardEntity = members[0]
			if not _origin_by_gid.has(gid) or _meeting_visitors.has(single.uid):
				single.freeze = true
				presenter._move_to(single, _origin_for(int(gid), owner_value))
	if owner_value == int(_settings.opponent_owner): _arrange_opponent_groups()
	presenter.resync_sides()

## Arrange only the opponent's final visual groups. Native stack geometry
## remains authoritative, and moving a whole visual pile never calls a rule
## command or resets its shared production timer.
func _arrange_opponent_groups() -> void:
	if not bool(_settings.opponent_layout.enabled) or _state.winner >= 0: return
	var snapshot := _opponent_layout_snapshot()
	var signature := _opponent_geometry_signature(snapshot)
	if signature == _opponent_layout_signature: return
	_opponent_layout_passes += 1
	var positions := OpponentLayout.arrange(snapshot.entries, enemy_board.player_bounds.grow(-Board.BOUNDS_PAD), snapshot.reserved, _settings.opponent_layout)
	for entry in snapshot.entries:
		var destination: Vector3 = positions[entry.id]
		if destination.distance_to(entry.at) <= float(_settings.opponent_layout.position_tolerance): continue
		var delta: Vector3 = destination - entry.at
		_origin_by_gid[entry.id] = destination
		group_overrides[entry.id] = destination
		if entry.group != null: enemy_board._layout_group(entry.group, destination)
		else: enemy_board._move_to(entry.members[0], destination)
		# A guest remains physically at the other table, but its return slot
		# moves with the source pile. Never reserve its foreign orbit position.
		for visit in _meeting_visitors.values():
			if int(visit.home_group) == int(entry.id): visit.home += delta
	_opponent_layout_signature = _opponent_geometry_signature(_opponent_layout_snapshot())

func _opponent_geometry_signature(snapshot: Dictionary) -> String:
	var rows: Array = [enemy_board.player_bounds]
	for entry in snapshot.entries: rows.append([entry.id, entry.at, entry.shape, entry.fixed])
	rows.append(snapshot.reserved)
	return JSON.stringify(rows)

func _opponent_layout_snapshot() -> Dictionary:
	var entries: Array = []
	var reserved: Array[Rect2] = []
	var owner_value := int(_settings.opponent_owner)
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5
	var bounds := enemy_board.player_bounds
	for gid in _state.groups:
		if int(_state.groups[gid].owner) != owner_value: continue
		var members: Array = []
		var absent: Array = []
		for uid in _state.group_cards(int(gid)):
			if not by_uid.has(uid) or _strike_dancers.has(uid) or _strike_attacks.has(uid): continue
			if _meeting_visitors.has(uid) and _meeting_visitors[uid].phase != "return":
				absent.append(uid)
			else: members.append(by_uid[uid])
		if members.is_empty():
			for uid in absent:
				var home: Vector3 = _meeting_visitors[uid].home
				if bounds.has_point(Vector2(home.x, home.z)):
					reserved.append(Rect2(Vector2(home.x, home.z) - half, half * 2.0))
			continue
		var group: Variant = enemy_board.group_of(members[0])
		var at: Vector3 = enemy_board.rest_origin(group) if group != null else enemy_board.rest_pos(members[0])
		at.y = float(_settings.rest_y)
		var shape := Rect2(-half, half * 2.0)
		if group != null:
			for index in group.cards.size():
				var offset: Vector3 = enemy_board._stack_offset(group, index)
				shape = shape.merge(Rect2(Vector2(offset.x, offset.z) - half, half * 2.0))
			if group.cards.size() > 1:
				var top_offset: Vector3 = enemy_board._stack_offset(group, enemy_board._top_index(group))
				var rows := maxi(1, int(group.get("side", []).size() / 2))
				var depth := mini(rows, Board.SIDE_MAX_ROWS) * Board.SIDE_ROW_Z
				var side_z := _opponent_side_center_z(at.z + top_offset.z, depth) - at.z
				shape = shape.merge(Rect2(Vector2(half.x, side_z - depth * 0.5),
					Vector2(float(_settings.opponent_layout.side_label_padding), depth)))
		for uid in absent:
			var home: Vector3 = _meeting_visitors[uid].home
			if bounds.has_point(Vector2(home.x, home.z)):
				shape = shape.merge(Rect2(Vector2(home.x - at.x, home.z - at.z) - half, half * 2.0))
		var fixed := false
		for member in members:
			if not _state.meetings.has(member.uid): continue
			fixed = true
			var centre: Vector3 = enemy_board.rest_pos(member)
			var spec: Dictionary = _settings.meeting_motion
			var guest_half := half * float(spec.orbit_scale) + Vector2.ONE * float(spec.seat_padding)
			var radius := Vector2(float(spec.orbit_radius_x), float(spec.orbit_radius_z)) + guest_half
			var ring := Rect2(Vector2(centre.x, centre.z) - radius, radius * 2.0).intersection(bounds)
			shape = shape.merge(Rect2(ring.position - Vector2(at.x, at.z), ring.size))
		entries.append({"id": int(gid), "at": at, "shape": shape, "group": group, "members": members, "fixed": fixed})
	for uid in _strike_dancers:
		if not by_uid.has(uid) or by_uid[uid].card_owner != owner_value: continue
		var destination: Vector3 = _strike_dancers[uid].to
		var margin := Vector2.ZERO
		reserved.append(Rect2(Vector2(destination.x, destination.z) - half - margin, (half + margin) * 2.0))
	return {"entries": entries, "reserved": reserved}

func _origin_for(gid: int, owner_value: int) -> Vector3:
	if group_overrides.has(gid) or _origin_by_gid.has(gid):
		# 旧存档可能保存了松手时的拖拽高度；组锚点只记录桌面位置，
		# 牌堆自身的层高仍由 _stack_offset 负责。
		var restored: Vector3 = group_overrides.get(gid, _origin_by_gid.get(gid, Vector3.ZERO))
		restored.y = float(_settings.rest_y)
		_origin_by_gid[gid] = restored
		if group_overrides.has(gid): group_overrides[gid] = restored
		return restored
	var count: int = int(_state.offers.size()) if _state != null else int(OffWorkCardDB.game_rules()["market_size"])
	var region := TableRegions.zone_rect(owner_value == int(_settings.local_owner), drawer_mode, count)
	if _opening_layout_enabled:
		var designated := _opening_origin(gid, owner_value, region)
		if designated != Vector3.INF:
			designated = _free_spawn_position(gid, owner_value, designated)
			_origin_by_gid[gid] = designated
			return designated
	var columns: Array = _settings.spawn_columns
	var index: int = int(_spawned_by_owner.get(owner_value, 0))
	_spawned_by_owner[owner_value] = index + 1
	var shift := region.position.y + CardEntity.CARD_SIZE.z * 0.5 + float(_settings.zone_inset)
	var origin := Vector3(float(columns[index % columns.size()]), float(_settings.rest_y), shift)
	origin = _free_spawn_position(gid, owner_value, origin)
	_origin_by_gid[gid] = origin
	return origin

func _spawn_obstacles(gid: int, owner_value: int) -> Array[Rect2]:
	var footprints: Dictionary = {}
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5
	for uid in by_uid:
		var member: OffWorkCard = by_uid[uid]
		if not _state.cards.has(uid) or member.card_owner != owner_value or member.group_id == gid: continue
		# rest_pos reads dest_pos first: in-flight income, coffee and scattered
		# personnel reserve their landing places, not their temporary air position.
		var at := _presenter(owner_value).rest_pos(member)
		if _cash_flights.has(uid): at = _cash_flights[uid].to
		var rect := Rect2(Vector2(at.x, at.z) - half, half * 2.0)
		var key: int = member.group_id
		footprints[key] = (footprints[key] as Rect2).merge(rect) if footprints.has(key) else rect
	var result: Array[Rect2] = []
	for rectangle in footprints.values(): result.append(rectangle)
	return result

func _free_spawn_position(gid: int, owner_value: int, anchor: Vector3) -> Vector3:
	var presenter := _presenter(owner_value)
	var region := presenter.player_bounds
	if not Board.has_table_bounds(region):
		region = TableRegions.zone_rect(owner_value == int(_settings.local_owner), drawer_mode, _state.offers.size())
	anchor.y = float(_settings.rest_y)
	return SpawnPlacement.pick(anchor, region, Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z),
		_spawn_obstacles(gid, owner_value), _settings.placement, presenter.clamp_player_position)

func _has_uncombined_opening(state: Object) -> bool:
	for entry in state.config.rules.initial.groups:
		var people := false
		var work := false
		for kind in entry:
			people = people or state.config.is_person(str(kind))
			work = work or str(kind) == "work"
		if people and work: return false
	return true

func _opening_origin(gid: int, owner_value: int, region: Rect2) -> Vector3:
	if not _state.groups.has(gid): return Vector3.INF
	var family := ""
	for uid in _state.groups[gid].cards:
		var kind := str(_state.cards[uid].type)
		var category := str(_state.config.cards[kind].category)
		if family == "": family = category
		elif family != category: return Vector3.INF
	var layout: Dictionary = _settings.opening_layout
	if not layout.has(family): return Vector3.INF
	var key := "%d/%s" % [owner_value, family]
	var index := int(_opening_counts.get(key, 0))
	var slots: Array = layout[family]
	# A completely spent cash pile releases its reserved bank position.
	if family == "money":
		var another_cash := false
		for other in _state.groups:
			if int(other) == gid or int(_state.groups[other].owner) != owner_value: continue
			var records: Array = _state.group_cards(int(other))
			if not records.is_empty() and records.all(func(uid): return _state.cards[uid].type == "money"):
				another_cash = true
		if not another_cash: index = 0
	if index >= slots.size(): return Vector3.INF
	_opening_counts[key] = index + 1
	var slot: Array = slots[index]
	var inset := CardEntity.CARD_SIZE.z * 0.5 + float(layout.edge_padding)
	var near := region.end.y - inset
	if family in ["work", "money"]: near -= float(layout.cash_stack_reserve)
	var at := Vector3(float(slot[0]), float(_settings.rest_y), lerpf(region.position.y + inset, near, float(slot[1])))
	return _presenter(owner_value).clamp_player_position(at)

func _sync_market() -> void:
	if is_instance_valid(conveyor): conveyor.sync_market(_state.offers, int(_state._supply_count))
	var live: Dictionary = {}
	for index in _state.offers.size():
		var offer: Dictionary = _state.offers[index]
		if offer.is_empty(): continue
		var id: int = int(offer.id)
		live[id] = true
		var slot := TableRegions.market_slot(index, _state.offers.size(), drawer_mode)
		var card: OffWorkCard = offers_by_id.get(id)
		if card == null:
			card = CardView.new()
			card.configure({"id": int(_settings.market_uid_base) - id, "type": offer.type,
				"owner": -1, "group": -1, "status": "ready", "progress": 0.0}, _state.config.cards[offer.type], true)
			add_child(card)
			card.draggable = false
			card.is_market = true
			card.freeze = true
			register_card(card)
			offers_by_id[id] = card
			card.set_meta("offer_id", id)
			card.set_meta("market_slot", slot)
			card.global_position = conveyor.position_for_slot(index) if is_instance_valid(conveyor) else slot + _setting_vector("market_entry_offset")
			var tag := PriceTag.new()
			card.add_child(tag)
			tag.position = _setting_vector("price_tag_offset")
			tag.configure(int(offer.price), card, self)
			card.set_meta("price_tag", weakref(tag))
			_prices[id] = tag
			if not is_instance_valid(conveyor): _move_market(card, slot)
		elif not card.dragging and card.get_meta("market_slot", Vector3.INF) != slot:
			card.set_meta("market_slot", slot)
			if not is_instance_valid(conveyor): _move_market(card, slot)
		if is_instance_valid(conveyor): conveyor.attach_offer(id, card, index)
	for id in offers_by_id.keys():
		if live.has(id): continue
		var card: CardEntity = offers_by_id[id]
		unregister_card(card)
		var exiting: bool = is_instance_valid(conveyor) and conveyor.release_offer(int(id), card)
		if not exiting:
			card.hide()
			card.queue_free()
		offers_by_id.erase(id)
		if _prices.has(id):
			if not exiting: _prices[id].queue_free()
			_prices.erase(id)

func _move_market(card: CardEntity, slot: Vector3) -> void:
	_stop_move(card, false)
	var tween := card.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "global_position", slot, float(_settings.market_move_seconds))
	_move_tw[card] = {"tw": tween, "to": slot}

## Native ray picking is disabled for hidden arrivals; the cash-drop path
## also needs to ignore them because it uses distance rather than a ray.
func _market_card_near(pos: Vector3) -> CardEntity:
	var best: CardEntity = null
	var distance := float(_settings.conveyor_visual.cash_drop_radius)
	for card: CardEntity in offers_by_id.values():
		if not is_instance_valid(card) or not card.is_visible_in_tree(): continue
		var candidate := Vector2(card.global_position.x - pos.x, card.global_position.z - pos.z).length()
		if candidate < distance:
			distance = candidate
			best = card
	return best

func _setting_vector(key: String) -> Vector3:
	var values: Array = _settings[key]
	return Vector3(values[0], values[1], values[2])

func get_card_position(uid: int) -> Vector3:
	return by_uid[uid].global_position if by_uid.has(uid) else _previous_positions.get(uid, Vector3.ZERO)

func get_group_position(gid: int) -> Vector3:
	if _state != null and _state.groups.has(gid):
		for uid in _state.groups[gid].cards:
			if by_uid.has(uid) and not _meeting_visitors.has(uid):
				var presenter := _presenter(by_uid[uid].card_owner)
				var group: Variant = presenter.group_of(by_uid[uid])
				return presenter.rest_origin(group) if group != null else presenter.rest_pos(by_uid[uid])
	return _origin_by_gid.get(gid, Vector3.ZERO)

func screen_position(uid: int) -> Vector2:
	return camera.unproject_position(get_card_position(uid)) if is_instance_valid(camera) else Vector2.ZERO

func _retirement_overlaps_stack(card: OffWorkCard) -> bool:
	var group: Variant = _presenter(card.card_owner).group_of(card)
	if group == null: return false
	if camera == null: return group.cards.size() > 1
	var face := _cash_note_screen_bounds(card._visual)
	for member: OffWorkCard in group.cards:
		if member != card and face.intersects(_cash_note_screen_bounds(member._visual)):
			return true
	return false

func _retire(card: OffWorkCard) -> void:
	# A consumed card is no longer a physical member. Letting its old face
	# rise through a still-working pile intersects both staff and refill cards.
	# The existing group stamp, paper burst and cash arc carry this settlement.
	if bool(card.get_meta("retire_in_stack", false)): card.hide()
	var tween := card.create_tween()
	_effect_tweens.append(tween)
	tween.tween_interval(OffWorkUI.number("animation", "retire_wait"))
	tween.tween_property(card, "scale", Vector3.ONE * OffWorkUI.number("animation", "retire_scale"), OffWorkUI.number("animation", "retire_duration"))
	tween.parallel().tween_property(card, "position:y", card.position.y + OffWorkUI.number("animation", "retire_distance"), OffWorkUI.number("animation", "retire_duration"))
	tween.tween_callback(func():
		_retired_cards.erase(card.uid)
		card.queue_free())

func play_event(event: Dictionary) -> void:
	var kind := str(event.get("kind", ""))
	if kind in ["work_complete", "outsource"]: _queue_disposed_work(event)
	var actors: Array = []
	if kind == "work_complete":
		# A batch has one visible completion, just like its shared progress bar.
		# The inherited stamp draws above neighbors, so stamping every buried
		# participant made their ink pierce the top employee simultaneously.
		var source: OffWorkCard = by_uid.get(int(event.get("source", -1)))
		if source != null:
			var presenter := _presenter(source.card_owner)
			var group: Variant = presenter.group_of(source)
			var representative: OffWorkCard = _work_progress_card(group, presenter) if group != null else source
			if representative != null: actors = [representative.uid]
	else:
		actors = [int(event.get("source", -1)), int(event.get("host", -1))]
	for uid in actors:
		if by_uid.has(uid): by_uid[uid].play_event(kind)
	if kind == "win":
		_clear_terminal_progress()
		_freeze_terminal_layout()
		var winning_owner: int = int(event.get("winner", _state.winner))
		for uid in by_uid:
			var card: OffWorkCard = by_uid[uid]
			if winning_owner != 2 and card.card_owner != winning_owner: continue
			if card._is_person():
				# A winner can still be visiting the other table. Hand off motion
				# before departure so the meeting return cannot reopen its card.
				var departure_pose := card._visual.transform
				_release_meeting_motion(uid, false)
				_release_strike_motion(uid, false)
				card._visual.transform = departure_pose
				_presenter(card.card_owner)._stop_move(card, false)
				card.leave(_departure_clearance(card))
				if card._leave_tween != null and card._leave_tween.is_valid() and not card._leave_tween.finished.is_connected(_restore_terminal_stationary_faces):
					card._leave_tween.finished.connect(_restore_terminal_stationary_faces, CONNECT_ONE_SHOT)
		_restore_terminal_stationary_faces()
		ComicFx.shake(camera, ComicFx.shake_amount("final"))
	elif kind == "strike_launch":
		_sync_strike_attacks()
		_advance_strike_attacks(0.0)
	elif kind == "strike_blocked":
		_return_strike_attack(int(event.get("source", -1)))
	elif kind == "transfer":
		_start_delivery(event, true)
	elif kind == "work_complete":
		_flash_group_task_completion(int(event.get("source", -1)))
		_start_cash_flight(event)
		for uid in event.get("ids", []):
			if _retired_cards.has(uid): _retired_cards[uid].play_event(kind)
	elif kind == "fire":
		_start_cash_flight(event)
	elif kind == "slack_complete":
		_flash_group_task_completion(int(event.get("source", -1)), "slack")
		_start_delivery(event, false)
	elif kind == "recruitment_complete":
		_start_delivery(event, false)
	elif kind == "coffee_upgrade":
		var person := int(event.get("person", -1))
		if by_uid.has(person): by_uid[person].play_event(kind)
	elif kind in ["meeting_start", "strike"]:
		for uid in event.get("targets", []):
			if by_uid.has(uid): by_uid[uid].play_event(kind)

func _queue_disposed_work(event: Dictionary) -> void:
	if _paper_disposal == null:
		_paper_disposal = PaperDisposal.new()
		add_child(_paper_disposal)
		_paper_disposal.setup(_settings.paper_disposal)
	var origin := get_group_position(int(event.get("group", -1)))
	var source_face: OffWorkCard
	for uid in event.get("ids", []):
		var previous: Vector3 = _previous_positions.get(uid, origin)
		if previous.y >= origin.y:
			origin = previous
			source_face = _retired_cards.get(uid, by_uid.get(uid))
	var frame := OffWorkUI.section("frame")
	var source_size := Vector2.ZERO
	if is_instance_valid(source_face) and is_instance_valid(source_face._icon):
		var icon: Sprite3D = source_face._icon
		origin = icon.global_position
		source_size = Vector2(icon.texture.get_width(), icon.texture.get_height()) * icon.pixel_size
		source_size *= Vector2(icon.global_basis.x.length(), icon.global_basis.y.length())
	else:
		# Deep-stack faces can be deferred; use the exact same frame placement
		# as OffWorkCard._center_illustration rather than a smaller fake icon.
		origin += Vector3((float(frame.art_cx) - 0.5) * CardEntity.CARD_SIZE.x,
			CardEntity.Y_ICON, (float(frame.art_cy) - 0.5) * CardEntity.CARD_SIZE.z)
	origin.y += float(_settings.paper_disposal.source_height)
	var texture := CardArt.illustration_texture("work", OffWorkCardDB)
	for uid in event.get("ids", []):
		var card: OffWorkCard = _retired_cards.get(uid, by_uid.get(uid))
		# Deep stacks deliberately defer card-face allocation. Those real work
		# UIDs still deserve a paper; use the shared artwork, not a face node.
		if is_instance_valid(card) and card.def_id != "work": continue
		_paper_disposal.enqueue(texture, origin, int(event.get("owner", 0)), source_size)
	_advance_paper_disposal(0.0)

func _advance_paper_disposal(delta: float) -> void:
	if is_instance_valid(_paper_disposal): _paper_disposal.advance(delta)

func _layout_side(group, at: Vector3, pin_y := false) -> void:
	if _defer_side_refresh: return
	if _terminal_pose_locked:
		_clear_side(group)
		group["extract_rows"] = []
		return
	if side_extract == null:
		super._layout_side(group, at, pin_y)
		_update_cash_side(group)
		return
	if not group.get("compact", false) or group.cards.size() < 2 or at == Vector3.INF:
		_clear_side(group)
		group["extract_rows"] = []
		return
	var rows: Array = side_extract.side_rows(group)
	if rows.is_empty():
		_clear_side(group)
		group["extract_rows"] = []
		return
	var signature := ""
	for row in rows: signature += str(row.kind) + ":" + str(row.text) + "|"
	if group.get("side_sig", "") != signature:
		var before: Dictionary = group.get("side_counts", {})
		_clear_side(group)
		group["side"] = _build_side(group, rows)
		group["side_sig"] = signature
		group["side_counts"] = _side_counts(rows)
		if not before.is_empty():
			for index in rows.size():
				var key := _side_key(rows[index])
				if int(group.side_counts.get(key, 0)) > int(before.get(key, 0)): _pop_side_row(group.side, index)
	group["extract_rows"] = rows
	var rows_per_column := int(_settings.side_extract.side_rows_per_column)
	var columns := ceili(float(rows.size()) / float(rows_per_column))
	var pitch := SIDE_W + float(_settings.side_extract.side_column_gap)
	var width := float(columns) * pitch - float(_settings.side_extract.side_column_gap)
	var left := at.x + CardEntity.CARD_SIZE.x * 0.5 + SIDE_GAP
	if has_table_bounds(table_bounds):
		if left + width > table_bounds.end.x - BOUNDS_PAD: left = at.x - CardEntity.CARD_SIZE.x * 0.5 - SIDE_GAP - width
		left = clampf(left, table_bounds.position.x + BOUNDS_PAD, table_bounds.end.x - width - BOUNDS_PAD)
	for column in columns:
		var begin := column * rows_per_column
		var count := mini(rows_per_column, rows.size() - begin)
		var nodes: Array = group.side.slice(begin * 2, (begin + count) * 2)
		_place_side(nodes, count, at, pin_y)
		var label: Label3D = nodes[1]
		var shift := left + float(column) * pitch - (label.global_position.x - SIDE_ICON - float(_settings.side_extract.side_text_gap))
		for node in nodes:
			if is_instance_valid(node): node.global_position.x += shift
	_update_cash_side(group)

func _update_cash_side(group: Dictionary) -> void:
	if _state == null: return
	var amount := 0
	for card in group.get("cards", []):
		if _state.cards.has(card.uid) and _state.cards[card.uid].type == "money":
			amount += int(_state.cards[card.uid].amount)
	var nodes: Array = group.get("side", [])
	var cash_texture := CardArt.res_icon_texture(OffWorkCardDB.RES_CASH, OffWorkCardDB)
	for index in range(0, nodes.size() - 1, 2):
		if is_instance_valid(nodes[index]) and nodes[index] is Sprite3D and nodes[index].texture == cash_texture and nodes[index + 1] is Label3D:
			nodes[index + 1].text = str(OffWorkCardDB.display._realtime.money_amount_format) % amount
	var gid := int(group.get("work_group_id", -1))
	if _state.groups.has(gid) and int(_state.groups[gid].owner) == int(_settings.opponent_owner):
		_contain_opponent_side(nodes)

func _opponent_side_center_z(at: float, depth: float) -> float:
	var bounds := enemy_board.player_bounds.grow(-Board.BOUNDS_PAD)
	return clampf(at, bounds.position.y + depth * 0.5, bounds.end.y - depth * 0.5)

## The original side column is retained. Its vertical clamp uses this desk,
## so a long expanded BOT stack cannot push its lower labels into the belt.
func _contain_opponent_side(nodes: Array) -> void:
	if nodes.size() < 2: return
	var first: Label3D = nodes[1]
	var last: Label3D = nodes[nodes.size() - 1]
	if not is_instance_valid(first) or not is_instance_valid(last): return
	var centre := (first.global_position.z + last.global_position.z) * 0.5
	var depth := float(nodes.size() / 2) * Board.SIDE_ROW_Z
	var delta := _opponent_side_center_z(centre, depth) - centre
	if absf(delta) <= float(_settings.opponent_layout.position_tolerance): return
	for node in nodes:
		if is_instance_valid(node): node.global_position.z += delta

func _move_to(card: CardEntity, destination: Vector3) -> void:
	if _preserve_income_motion(card, destination): return
	super._move_to(card, destination)

func _preserve_income_motion(card: CardEntity, destination: Vector3) -> bool:
	# A rebuilt snapshot is already at rest, including an elapsed/paused match
	# restored after practice. Only edits to an existing table need reflow motion.
	if _placing_snapshot:
		card.global_position = destination
		return true
	if _strike_in_flight(card.uid): return true
	if _delivery_flights.has(card.uid):
		_delivery_flights[card.uid].to = destination
		card.set_meta("dest_pos", destination)
		return true
	if _meeting_visitors.has(card.uid):
		var visit: Dictionary = _meeting_visitors[card.uid]
		if visit.phase == "return":
			visit.home = destination
			card.set_meta("dest_pos", destination)
		return true
	if not _cash_flights.has(card.uid): return false
	var flight: Dictionary = _cash_flights[card.uid]
	if _state == null or not _state.cards.has(card.uid) or int(_state.cards[card.uid].group) != int(flight.group):
		_cancel_cash_flight(card)
		return false
	# A growing/moved cash pile can revise its destination without overwriting
	# the current arc. Rest-position queries still read the real target.
	flight.to = destination
	card.set_meta("dest_pos", destination)
	return true

func _cancel_external_motion(card: CardEntity) -> void:
	if is_instance_valid(card) and (_meeting_visitors.has(card.uid) or _strike_in_flight(card.uid) or _delivery_flights.has(card.uid)): return
	_cancel_cash_flight(card)
	if is_instance_valid(_motion):
		_motion._cancel_fly(card)
	elif is_instance_valid(card):
		if card.has_meta("fly_tw"):
			var tween: Variant = card.get_meta("fly_tw")
			if tween is Tween and tween.is_valid(): tween.kill()
			card.remove_meta("fly_tw")
		card.remove_meta("dest_pos")

func _cancel_cash_flight(card: CardEntity) -> void:
	if not is_instance_valid(card) or not _cash_flights.has(card.uid): return
	var flight: Dictionary = _cash_flights[card.uid]
	for sample in flight.samples:
		if is_instance_valid(sample.node):
			sample.node.get_parent().remove_child(sample.node)
			sample.node.queue_free()
	card.collision_layer = int(flight.collision_layer)
	card.collision_mask = int(flight.collision_mask)
	card.input_ray_pickable = bool(flight.input_ray_pickable)
	card.draggable = bool(flight.draggable)
	card._visual.visible = true
	_restore_cash_opacity(card._visual)
	_cash_flights.erase(card.uid)
	card.remove_meta("income_flight")
	card.remove_meta("in_flight")
	card.remove_meta("dest_pos")
	card.reset_interaction_visual()

## Each decorative note is an independent projectile, never a fan attached to
## another card. They have no UID/collider and cannot alter settled currency.
func _make_cash_note(card: OffWorkCard) -> Node3D:
	var note := Node3D.new()
	note.name = "IncomeNote"
	note.set_meta("motion_event", "income")
	add_child(note, true)
	for source in [card.card_mesh, card._plate, card._icon, card.label]:
		if source != null: note.add_child(source.duplicate(0))
	_prepare_cash_opacity(note)
	note.visible = false
	return note

func _start_cash_flight(event: Dictionary) -> void:
	# A shared production cycle is one event, but each currency unit is a real
	# draggable card. All of those UIDs must follow the same protected stream.
	var counts := _cash_flight_counts()
	for uid in event.get("money_ids", [int(event.get("money_id", -1))]):
		_start_cash_card_flight(event, int(uid), counts)

func _cash_flight_counts() -> Dictionary:
	var counts := {}
	for flight in _cash_flights.values():
		var owner_value := int(flight.owner)
		if not counts.has(owner_value): counts[owner_value] = {"active": 0, "decorations": 0}
		counts[owner_value].active += 1
		counts[owner_value].decorations += flight.samples.size()
	return counts

func _start_cash_card_flight(event: Dictionary, uid: int, counts: Dictionary = {}) -> void:
	if not by_uid.has(uid) or _state == null or not _state.cards.has(uid): return
	var card: OffWorkCard = by_uid[uid]
	if card.dragging or card.type != "money" or _cash_flights.has(uid): return
	# Income has an actual moving face even when it is destined for a covered
	# cash slot. Build it before capturing the original opacity materials.
	card.reveal_stack_face()
	var owner_value := int(event.get("owner", card.card_owner))
	var source := int(event.get("source", -1))
	var from: Vector3 = _previous_positions.get(source, get_card_position(source))
	var presenter := _presenter(owner_value)
	var destination := presenter.rest_pos(card)
	presenter._stop_move(card, false)
	var spec: Dictionary = _settings.income_motion
	if counts.is_empty(): counts.merge(_cash_flight_counts())
	if not counts.has(owner_value): counts[owner_value] = {"active": 0, "decorations": 0}
	var active := int(counts[owner_value].active)
	var decorations := int(counts[owner_value].decorations)
	if active == 0:
		_cash_emission_serial[owner_value] = 0
		_cash_stream_width[owner_value] = 0.0
	var amount := maxi(1, int(_state.cards[uid].amount))
	var count := mini(amount, int(spec.max_samples_per_payment))
	count = mini(count, 1 + maxi(0, int(spec.max_decorative_cards_per_owner) - decorations))
	var serial := int(_cash_emission_serial.get(owner_value, 0))
	var first_delay := fposmod(float(serial) * float(spec.emission_interval_seconds), float(spec.max_emission_window_seconds))
	var delays: Array = []
	for index in count:
		delays.append(first_delay + float(index) * float(spec.emission_interval_seconds))
	_cash_emission_serial[owner_value] = serial + count
	from.y += float(spec.spawn_height)
	var path := destination - from
	var sideways := Vector3(-path.z, 0.0, path.x).normalized()
	if sideways.is_zero_approx(): sideways = camera.global_basis.x.normalized()
	var samples: Array = []
	for index in range(1, count):
		samples.append({"node": _make_cash_note(card), "delay": delays[index], "sequence": serial + index})
	counts[owner_value].active += 1
	counts[owner_value].decorations += samples.size()
	var flight := {"group": int(_state.cards[uid].group), "owner": owner_value,
		"kind": str(event.get("kind", "work_complete")), "from": from, "to": destination,
		"elapsed": 0.0, "delay": delays[0], "last_delay": delays.max(), "sequence": serial,
		"samples": samples, "amount": amount, "sideways": sideways,
		"collision_layer": card.collision_layer, "collision_mask": card.collision_mask,
		"input_ray_pickable": card.input_ray_pickable, "draggable": card.draggable, "width": 0.0}
	_cash_flights[uid] = flight
	_prepare_cash_opacity(card._visual)
	card.set_meta("income_flight", true)
	card.set_meta("in_flight", true)
	card.set_meta("dest_pos", destination)
	card.freeze = true
	card.collision_layer = 0
	card.collision_mask = 0
	card.input_ray_pickable = false
	card.draggable = false
	card.position = from
	card._visual.scale = Vector3.ONE * float(spec.launch_scale)
	card._visual.visible = is_zero_approx(float(flight.delay))

func _cash_screen_region(owner_value: int, from_facility := false) -> Rect2:
	var area: Rect2 = table_bounds if from_facility else _presenter(owner_value).player_bounds
	var points := PackedVector2Array()
	for x in [area.position.x, area.end.x]:
		for z in [area.position.y, area.end.y]:
			points.append(camera.unproject_position(Vector3(x, float(_settings.rest_y), z)))
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point in points: bounds = bounds.expand(point)
	return bounds.grow(-float(_settings.income_motion.screen_padding_pixels))

func _cash_note_screen_bounds(visual: Node3D) -> Rect2:
	var bounds := Rect2()
	var first := true
	for x in [-CardEntity.CARD_SIZE.x * 0.5, CardEntity.CARD_SIZE.x * 0.5]:
		for z in [-CardEntity.CARD_SIZE.z * 0.5, CardEntity.CARD_SIZE.z * 0.5]:
			var point := camera.unproject_position(visual.to_global(Vector3(x, CardEntity.Y_TEXT, z)))
			if first: bounds = Rect2(point, Vector2.ZERO); first = false
			else: bounds = bounds.expand(point)
	return bounds

func _contain_cash_note(visual: Node3D, mover: Node3D, flight: Dictionary) -> void:
	var region := _cash_screen_region(int(flight.owner), str(flight.kind) == "fire")
	var bounds := _cash_note_screen_bounds(visual)
	var shift := Vector2.ZERO
	if bounds.position.x < region.position.x: shift.x += region.position.x - bounds.position.x
	if bounds.end.x > region.end.x: shift.x += region.end.x - bounds.end.x
	if bounds.position.y < region.position.y: shift.y += region.position.y - bounds.position.y
	if bounds.end.y > region.end.y: shift.y += region.end.y - bounds.end.y
	if shift.is_zero_approx(): return
	var point := camera.unproject_position(mover.global_position) + shift
	var ray := camera.project_ray_normal(point)
	var origin := camera.project_ray_origin(point)
	if not is_zero_approx(ray.y): mover.global_position = origin + ray * ((mover.global_position.y - origin.y) / ray.y)

func _cash_parabola(flight: Dictionary, progress: float, sequence: int) -> Vector3:
	var spec: Dictionary = _settings.income_motion
	var t := clampf(progress, 0.0, 1.0)
	var arch := 4.0 * t * (1.0 - t)
	var lateral := fposmod(float(sequence) * float(spec.spread_sequence), 1.0) - 0.5
	var destination: Vector3 = flight.to
	return (flight.from as Vector3).lerp(destination, t) + arch * (Vector3.UP * float(spec.arc_height) + (flight.sideways as Vector3) * lateral * float(flight.width))

func _cash_note_scale(progress: float) -> float:
	var spec: Dictionary = _settings.income_motion
	var t := smoothstep(0.0, float(spec.scale_rise_fraction), progress)
	return lerpf(float(spec.launch_scale), float(spec.flight_scale), t)

func _advance_cash_flights(delta: float) -> void:
	if _cash_flights.is_empty(): return
	var spec: Dictionary = _settings.income_motion
	var travel := float(spec.travel_seconds)
	var land := float(spec.land_seconds)
	var amounts: Dictionary = {}
	for flight in _cash_flights.values():
		amounts[flight.owner] = int(amounts.get(flight.owner, 0)) + int(flight.amount)
	for owner in amounts:
		var target := minf(float(spec.max_stream_width), maxf(0.0, float(amounts[owner] - 1)) * float(spec.width_per_card))
		_cash_stream_width[owner] = move_toward(float(_cash_stream_width.get(owner, 0.0)), target, float(spec.width_change_speed) * delta)
	var candidates: Array = []
	for uid in _cash_flights.keys():
		if not by_uid.has(uid): continue
		var card: OffWorkCard = by_uid[uid]
		var flight: Dictionary = _cash_flights[uid]
		if card.dragging or _state == null or not _state.cards.has(uid) or int(_state.cards[uid].group) != int(flight.group):
			_cancel_cash_flight(card)
			continue
		flight.elapsed += delta
		flight.width = float(_cash_stream_width.get(flight.owner, 0.0))
		var age := float(flight.elapsed) - float(flight.delay)
		if age < 0.0:
			card._visual.visible = false
			card.collision_layer = 0
		elif age < travel:
			var t := age / travel
			card.position = _cash_parabola(flight, t, int(flight.sequence))
			card._visual.scale = Vector3.ONE * _cash_note_scale(t)
			card._visual.rotation_degrees.y = 0.0
			card._visual.visible = true
			_contain_cash_note(card._visual, card, flight)
			candidates.append({"visual": card._visual, "card": card, "owner": flight.owner, "progress": t, "collision_layer": flight.collision_layer})
		else:
			card.position = flight.to
			_set_cash_opacity(card._visual, move_toward(float(card._visual.get_meta("income_opacity", 1.0)), 1.0, delta / float(spec.density_fade_seconds)))
			var t := clampf((age - travel) / land, 0.0, 1.0)
			card._visual.scale = Vector3.ONE * lerpf(float(spec.flight_scale), 1.0, t)
			card._visual.rotation_degrees.y = 0.0
		for sample in flight.samples:
			var note: Node3D = sample.node
			var t := (float(flight.elapsed) - float(sample.delay)) / travel
			note.visible = t >= 0.0 and t < 1.0
			if not note.visible: continue
			note.global_position = _cash_parabola(flight, t, int(sample.sequence))
			note.scale = Vector3.ONE * _cash_note_scale(t)
			_contain_cash_note(note, note, flight)
			candidates.append({"visual": note, "card": null, "owner": flight.owner, "progress": t})
		if float(flight.elapsed) >= float(flight.last_delay) + travel + land:
			_cancel_cash_flight(card)
			card.pulse_landed()
			if is_instance_valid(_motion) and is_instance_valid(_motion.sfx): _motion.sfx.play("produce_land")
	_limit_cash_density(candidates, delta)

## Occlusion sampling only: every authoritative card still follows its complete
## trajectory. Nearby notes are visually redundant, so do not overdraw them.
func _limit_cash_density(candidates: Array, delta: float) -> void:
	var spec: Dictionary = _settings.income_motion
	candidates.sort_custom(func(a, b):
		if (a.card != null) != (b.card != null): return a.card != null
		return float(a.progress) > float(b.progress))
	var points: Dictionary = {}
	for item in candidates:
		if not is_instance_valid(item.visual): continue
		if not points.has(item.owner): points[item.owner] = []
		var screen := camera.unproject_position(item.visual.global_position)
		var visible: bool = points[item.owner].size() < int(spec.max_visible_notes_per_owner)
		for other in points[item.owner]:
			if screen.distance_to(other) < float(spec.minimum_separation_pixels): visible = false; break
		var opacity := move_toward(float(item.visual.get_meta("income_opacity", 0.0)), 1.0 if visible else 0.0, delta / float(spec.density_fade_seconds))
		_set_cash_opacity(item.visual, opacity)
		if visible: points[item.owner].append(screen)

## Compatibility rendering does not support GeometryInstance3D.transparency.
## Give only travelling cash a private alpha material, preserving the inherited
## card-face shader and restoring the exact original material after landing.
func _prepare_cash_opacity(visual: Node3D) -> void:
	var originals: Array = []
	for child in visual.get_children():
		if child is MeshInstance3D and child.material_override != null:
			var original: Material = child.material_override
			var material: Material = original.duplicate()
			if material is ShaderMaterial:
				material.shader = preload("res://shaders/off_work_cash_face.gdshader")
				material.render_priority = -1
			elif material is BaseMaterial3D:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				material.render_priority = -2
			originals.append({"node": child, "material": original})
			child.material_override = material
		elif child is Sprite3D or child is Label3D:
			originals.append({"node": child, "color": child.modulate})
	visual.set_meta("income_originals", originals)
	_set_cash_opacity(visual, 0.0)

func _set_cash_opacity(visual: Node3D, opacity: float) -> void:
	visual.set_meta("income_opacity", opacity)
	visual.visible = opacity > float(_settings.income_motion.opacity_visibility_threshold)
	for entry in visual.get_meta("income_originals", []):
		var node: Node = entry.node
		if entry.has("material"):
			var material: Material = node.material_override
			if material is ShaderMaterial: material.set_shader_parameter("income_opacity", opacity)
			elif material is BaseMaterial3D: material.albedo_color.a = opacity
		else: node.modulate.a = (entry.color as Color).a * opacity

func _restore_cash_opacity(visual: Node3D) -> void:
	for entry in visual.get_meta("income_originals", []):
		if entry.has("material"): entry.node.material_override = entry.material
		else: entry.node.modulate = entry.color
	visual.remove_meta("income_originals")
	visual.remove_meta("income_opacity")

## 会议移动的是原人员实体。逻辑分组和归属保持不变，原工作在原桌暂停。
func _sync_meeting_visitors() -> void:
	_sync_meeting_centers()
	var wanted: Dictionary = {}
	if _state.winner < 0:
		for meeting_id in _state.meetings:
			var meeting: Dictionary = _state.meetings[meeting_id]
			for index in meeting.targets.size():
				var uid := int(meeting.targets[index])
				if by_uid.has(uid): wanted[uid] = {"meeting": int(meeting_id), "host": int(meeting.host), "index": index, "total": meeting.targets.size()}
	# 被会议选中的在手人员必须先按原按下快照放下，不能靠拖住牌逃会。
	var interrupted := false
	for card in _drag_cards + _press_snap.get("cards", []):
		if is_instance_valid(card) and wanted.has(card.uid): interrupted = true
	var pressed: Variant = _press_snap.get("card")
	if is_instance_valid(pressed) and wanted.has(pressed.uid): interrupted = true
	if interrupted: cancel_pointer()
	for uid in wanted:
		var card: OffWorkCard = by_uid[uid]
		var info: Dictionary = wanted[uid]
		card.set_meeting_participant(true)
		if _meeting_visitors.has(uid) and _meeting_visitors[uid].phase != "return" and int(_meeting_visitors[uid].meeting) == int(info.meeting):
			_meeting_visitors[uid].merge(info, true)
			card.draggable = false
			continue
		var presenter := _presenter(card.card_owner)
		var group: Variant = presenter.group_of(card)
		var gid := int(_state.cards[uid].group)
		var home: Vector3 = _meeting_visitors[uid].home if _meeting_visitors.has(uid) else presenter.rest_pos(card)
		if group != null:
			_origin_by_gid[gid] = presenter.rest_origin(group)
			_compact_by_gid[gid] = bool(group.get("compact", false))
			if not _meeting_home_order.has(gid): _meeting_home_order[gid] = group.cards.map(func(member): return member.uid)
		elif not _origin_by_gid.has(gid):
			_origin_by_gid[gid] = home
		var from := card.global_position
		var from_scale := card._visual.scale
		_meeting_visitors.erase(uid)
		presenter.drop_card(card)
		card.global_position = from
		info.merge({"phase": "pull", "home": home, "from": from, "from_scale": from_scale, "elapsed": 0.0, "home_group": gid}, true)
		_meeting_visitors[uid] = info
		card.draggable = false
		card.freeze = true
		card.set_meta("meeting_visit", true)
		card.set_meta("in_flight", true)
	for uid in _meeting_visitors.keys():
		if not by_uid.has(uid) or not _state.cards.has(uid):
			_meeting_visitors.erase(uid)
			continue
		var visit: Dictionary = _meeting_visitors[uid]
		var card: OffWorkCard = by_uid[uid]
		card.draggable = false
		if wanted.has(uid) or visit.phase == "return": continue
		visit.phase = "return"
		visit.elapsed = 0.0
		visit.from = card.global_position
		visit.from_scale = card._visual.scale
		visit.home = _origin_by_gid.get(int(_state.cards[uid].group), visit.home)
		var presenter := _presenter(card.card_owner)
		if not presenter.cards.has(card): presenter.register_card(card)
		card.set_meta("dest_pos", visit.home)

## The meeting card stays on the native stack. Only visitors are animated;
## keeping the original Board in charge avoids a second lift/return controller
## fighting a freshly merged stack or leaking an elevated origin into it.
func _sync_meeting_centers() -> void:
	var active: Dictionary = _state.meetings if _state.winner < 0 else {}
	for id in active:
		if not by_uid.has(id): continue
		if not _meeting_centers.has(id):
			_meeting_centers[id] = {"elapsed": 0.0}
		_meeting_centers[id].host = int(active[id].host)
		_meeting_centers[id].total = active[id].targets.size()
	for id in _meeting_centers.keys():
		if not by_uid.has(id) or not active.has(id): _meeting_centers.erase(id)

func _meeting_geometry(id: int) -> Dictionary:
	var spec: Dictionary = _settings.meeting_motion
	var card: OffWorkCard = by_uid[id]
	var region := TableRegions.zone_rect(card.card_owner == int(_settings.local_owner), drawer_mode, _state.offers.size())
	var anchor := card.global_position
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * (float(spec.orbit_scale) * 0.5) + Vector2.ONE * float(spec.seat_padding)
	var radius := Vector2(float(spec.orbit_radius_x), float(spec.orbit_radius_z))
	# Near an edge only compress the blocked half of the orbit. Compressing
	# both halves made four guests disappear behind a shallow horizontal line.
	var negative := Vector2(minf(radius.x, maxf(0.0, anchor.x - region.position.x - half.x)),
		minf(radius.y, maxf(0.0, anchor.z - region.position.y - half.y)))
	var positive := Vector2(minf(radius.x, maxf(0.0, region.end.x - anchor.x - half.x)),
		minf(radius.y, maxf(0.0, region.end.y - anchor.z - half.y)))
	return {"center": anchor, "negative_radius": negative, "positive_radius": positive, "region": region}

func _advance_meeting_centers(delta: float) -> void:
	for id in _meeting_centers:
		_meeting_centers[id].elapsed += delta

func _meeting_orbit_angle(visit: Dictionary) -> float:
	var spec: Dictionary = _settings.meeting_motion
	var elapsed := float(_meeting_centers.get(int(visit.meeting), {}).get("elapsed", visit.elapsed))
	return float(spec.orbit_start_angle) + TAU * (float(visit.index) / float(maxi(int(visit.total), 1)) + elapsed / float(spec.orbit_period_seconds))

func _meeting_seat(visit: Dictionary) -> Vector3:
	var spec: Dictionary = _settings.meeting_motion
	var id := int(visit.meeting)
	if not by_uid.has(id) or not _meeting_centers.has(id): return visit.home
	var geometry := _meeting_geometry(id)
	var anchor: Vector3 = by_uid[id].global_position
	var angle := _meeting_orbit_angle(visit)
	var direction := Vector2(cos(angle), sin(angle))
	var radius := Vector2(geometry.positive_radius.x if direction.x >= 0.0 else geometry.negative_radius.x,
		geometry.positive_radius.y if direction.y >= 0.0 else geometry.negative_radius.y)
	var shared: Vector2 = geometry.positive_radius.min(geometry.negative_radius)
	# Both half-orbits share their tangent at each axis. Expand cubically into
	# the available room, rather than changing speed abruptly at an edge.
	radius = shared + (radius - shared) * direction * direction
	# Visitors orbit the actual top card, below its face so the only meeting
	# timer stays readable. The host stack itself never leaves its native slot.
	var destination: Vector3 = anchor + Vector3(direction.x * radius.x, -float(spec.orbit_below_center), direction.y * radius.y)
	destination.y = maxf(float(spec.seat_height), destination.y)
	return destination

func _advance_meeting_visitors(delta: float) -> void:
	_advance_meeting_centers(delta)
	if _meeting_visitors.is_empty(): return
	var spec: Dictionary = _settings.meeting_motion
	var landed: Array = []
	for uid in _meeting_visitors.keys():
		if not by_uid.has(uid):
			_meeting_visitors.erase(uid)
			continue
		var card: OffWorkCard = by_uid[uid]
		var visit: Dictionary = _meeting_visitors[uid]
		visit.elapsed += delta
		var returning: bool = visit.phase == "return"
		var destination: Vector3 = visit.home if returning else _meeting_seat(visit)
		var duration := float(spec.return_seconds if returning else spec.pull_seconds)
		var delay := 0.0 if returning else int(visit.index) * float(spec.stagger_seconds)
		var age := maxf(0.0, float(visit.elapsed) - delay)
		card.set_meta("dest_pos", destination)
		if age < duration:
			var t := age / duration
			var eased := t * t * (3.0 - 2.0 * t)
			var arc := float(spec.return_arc_height if returning else spec.arc_height)
			var fan := (float(visit.index) - float(visit.total - 1) * 0.5) * float(spec.fan_width)
			card.global_position = (visit.from as Vector3).lerp(destination, eased) + sin(t * PI) * Vector3(fan, arc, 0)
			card._visual.rotation_degrees.y = sin(t * PI) * float(spec.tilt_degrees) * (-1.0 if int(visit.index) % 2 == 0 else 1.0)
			var start_scale: Vector3 = visit.get("from_scale", Vector3.ONE)
			var end_scale := Vector3.ONE if returning else Vector3.ONE * float(spec.orbit_scale)
			card._visual.scale = start_scale.lerp(end_scale, eased)
		elif not returning:
			visit.phase = "orbit"
			card.global_position = destination
			card._visual.scale = Vector3.ONE * float(spec.orbit_scale)
			card._visual.rotation_degrees.y = sin(_meeting_orbit_angle(visit)) * float(spec.orbit_tilt_degrees)
		else:
			var landing := clampf((age - duration) / float(spec.landing_seconds), 0.0, 1.0)
			card.global_position = destination + Vector3.UP * sin(landing * PI) * float(spec.landing_height)
			card._visual.rotation_degrees.y = 0.0
			card._visual.scale = Vector3.ONE
			if landing >= 1.0: landed.append(uid)
	for uid in landed: _release_meeting_motion(uid, true)

func _release_meeting_motion(uid: int, landed: bool) -> void:
	if not _meeting_visitors.has(uid) or not by_uid.has(uid): return
	var card: OffWorkCard = by_uid[uid]
	var gid := int(_meeting_visitors[uid].home_group)
	_meeting_visitors.erase(uid)
	card.set_meeting_participant(false)
	card._visual.scale = Vector3.ONE
	card._visual.rotation_degrees.y = 0.0
	card.remove_meta("meeting_visit")
	card.remove_meta("in_flight")
	card.remove_meta("dest_pos")
	card.draggable = card.card_owner == int(_settings.local_owner)
	if landed:
		card.reset_interaction_visual()
		card.pulse_landed()
	var still_away := false
	for visit in _meeting_visitors.values(): still_away = still_away or int(visit.home_group) == gid
	if not still_away: _meeting_home_order.erase(gid)

## 终局会冻结两桌的既有牌位。最后甩出的文件仍落在接收摞顶。
func _terminal_transfer_top(event: Dictionary) -> Vector3:
	var group := int(event.target_group)
	var owner_value := int(event.target_owner)
	var top := _origin_for(group, owner_value)
	for uid in _state.group_cards(group):
		if _transfer_departures.has(uid) or not by_uid.has(uid) or _has_external_pose(uid): continue
		var card: OffWorkCard = by_uid[uid]
		if card._visual.is_visible_in_tree() and card.global_position.y >= top.y:
			top = card.global_position
	return top

## 真实工作牌、咖啡或新员工暂时独占飞行位置；堆叠只更新它的落点。
func _start_delivery(event: Dictionary, transfer: bool) -> void:
	var ids: Array = event.get("coffee_ids", event.get("ids", [event.get("coffee_id", -1)]))
	ids = ids.filter(func(uid): return by_uid.has(uid))
	var spec: Dictionary = _settings.transfer_motion if transfer else _settings.coffee_motion
	var source := int(event.get("source", -1))
	var source_position: Vector3 = _previous_positions.get(source, get_card_position(source))
	var terminal_top := _terminal_transfer_top(event) if transfer and _terminal_pose_locked else Vector3.INF
	var window := minf(float(spec.emission_interval_seconds) * maxi(ids.size() - 1, 0), float(spec.max_emission_window_seconds))
	var width := minf(float(spec.spread_per_card) * maxi(ids.size() - 1, 0), float(spec.max_spread_width))
	for index in ids.size():
		var uid := int(ids[index])
		if _delivery_flights.has(uid): continue
		var card: OffWorkCard = by_uid[uid]
		var destination := _presenter(card.card_owner).rest_pos(card)
		_presenter(card.card_owner)._stop_move(card, false)
		if terminal_top != Vector3.INF:
			destination = terminal_top + Board.COMPACT_GAP * mini(index + 1, Board.BOUNDED_COMPACT_LAYERS)
		var launch: Vector3 = _transfer_departures.get(uid, source_position) if transfer else source_position
		_transfer_departures.erase(uid)
		var fraction := float(index) / float(maxi(ids.size() - 1, 1))
		var flight := _motion_lock(card)
		flight.merge({"spec": spec, "transfer": transfer, "last": index == ids.size() - 1,
			"land_visible": terminal_top == Vector3.INF or index < Board.BOUNDED_COMPACT_LAYERS,
			"from": launch, "to": destination, "elapsed": 0.0, "group": card.group_id,
			"delay": window * fraction, "spread": (fraction - 0.5) * width})
		_delivery_flights[uid] = flight
		card.set_meta("delivery_flight", true)
		card.set_meta("in_flight", true)
		card.set_meta("dest_pos", destination)
	_advance_deliveries(0.0)

func _advance_deliveries(delta: float) -> void:
	for uid in _delivery_flights.keys():
		if not by_uid.has(uid):
			_delivery_flights.erase(uid)
			continue
		var flight: Dictionary = _delivery_flights[uid]
		var spec: Dictionary = flight.spec
		var card: OffWorkCard = by_uid[uid]
		flight.elapsed += delta
		var elapsed := float(flight.elapsed) - float(flight.delay)
		card._visual.visible = elapsed >= 0.0
		var t := clampf(elapsed / float(spec.travel_seconds), 0.0, 1.0)
		var direction: Vector3 = (flight.to as Vector3) - (flight.from as Vector3)
		var side := Vector3(direction.z, 0.0, -direction.x).normalized()
		card.global_position = (flight.from as Vector3).lerp(flight.to, t) + Vector3.UP * (4.0 * t * (1.0 - t) * float(spec.arc_height)) \
			+ side * (sin(t * PI) * float(flight.spread))
		card._visual.scale = Vector3.ONE * lerpf(float(spec.launch_scale), 1.0, t)
		card._visual.rotation_degrees.y = sin(t * TAU) * float(spec.flight_tilt_degrees)
		if t < 1.0: continue
		var landing := clampf((elapsed - float(spec.travel_seconds)) / float(spec.land_seconds), 0.0, 1.0) if float(spec.land_seconds) > 0.0 else 1.0
		card.global_position.y += sin(landing * PI) * float(spec.landing_height)
		if landing >= 1.0:
			_release_delivery(uid)
			if flight.transfer:
				card.play_event("transfer")
				card.impact()
				if flight.last: ComicFx.shake(camera, ComicFx.shake_amount("big"))

func _release_delivery(uid: int) -> void:
	if not _delivery_flights.has(uid): return
	var flight: Dictionary = _delivery_flights[uid]
	_delivery_flights.erase(uid)
	if not by_uid.has(uid): return
	var card: OffWorkCard = by_uid[uid]
	card.global_position = flight.to
	card._visual.visible = flight.land_visible
	_motion_unlock(card, flight)
	card.remove_meta("delivery_flight")

func _motion_lock(card: OffWorkCard) -> Dictionary:
	var saved := {"collision_layer": card.collision_layer, "collision_mask": card.collision_mask,
		"input_ray_pickable": card.input_ray_pickable}
	card.collision_layer = 0
	card.collision_mask = 0
	card.input_ray_pickable = false
	card.draggable = false
	card.freeze = true
	card.dragging = false
	card.set_selected(false)
	card.reset_interaction_visual()
	return saved

func _motion_unlock(card: OffWorkCard, saved: Dictionary) -> void:
	card.collision_layer = int(saved.collision_layer)
	card.collision_mask = int(saved.collision_mask)
	card.input_ray_pickable = not _terminal_pose_locked and bool(saved.input_ray_pickable)
	card.draggable = not _terminal_pose_locked and card.card_owner == int(_settings.local_owner)
	card._visual.scale = Vector3.ONE
	card._visual.rotation = Vector3.ZERO
	card.remove_meta("in_flight")
	card.remove_meta("dest_pos")
	card.reset_interaction_visual()

## Attack travel uses the authoritative game clock. It never settles damage
## in a Tween callback: pausing, LAN snapshots and a mid-flight union all see
## the same response window. The complete card face travels as one object.
func _sync_strike_attacks() -> void:
	for uid in _strike_attacks.keys():
		if not _state.pending_strikes.has(uid) and str(_strike_attacks[uid].phase) == "attack":
			_return_strike_attack(int(uid))
		elif str(_strike_attacks[uid].phase) == "pending" and not _state.groups.has(int(_strike_attacks[uid].target_group)):
			_return_strike_attack(int(uid))
	for uid in _state.pending_strikes:
		if not by_uid.has(uid): continue
		var attack: Dictionary = _state.pending_strikes[uid]
		var card: OffWorkCard = by_uid[uid]
		if _strike_attacks.has(uid):
			var existing: Dictionary = _strike_attacks[uid]
			if existing.phase == "pending":
				# Preserve an already delivered pose if an older in-flight snapshot
				# is restored. New manual deliveries settle in the authority's reply.
				existing.phase = "attack"
				existing.awaiting_ack = false
				existing.to = _strike_attack_target(int(attack.target_group))
			elif existing.phase == "return":
				# A new authoritative launch may interrupt the purely visual
				# rebound (e.g. a BOT selects another unprotected target).
				existing.phase = "attack"
				existing.delivered = false
				existing.from = card.global_position
				existing.target_group = int(attack.target_group)
				existing.to = _strike_attack_target(int(attack.target_group))
			continue
		_begin_strike_attack(int(uid), int(attack.group), int(attack.target_group))

func _begin_strike_attack(uid: int, source_group: int, target_group: int, delivered := false, phase := "attack") -> void:
	var card: OffWorkCard = by_uid[uid]
	var presenter := _presenter(card.card_owner)
	var home: Vector3 = _origin_by_gid.get(source_group, _origin_for(source_group, card.card_owner))
	var target := _strike_attack_target(target_group)
	presenter.drop_card(card)
	presenter._stop_move(card, false)
	var flight := _motion_lock(card)
	flight.merge({"from": target if delivered else home, "home": home, "to": target,
		"target_group": target_group, "phase": phase, "elapsed": 0.0, "delivered": delivered, "awaiting_ack": false})
	_strike_attacks[uid] = flight
	card.reveal_stack_face()
	card.card_mesh.show()
	card.label.show()
	card.set_meta("strike_attack", true)
	card.set_meta("in_flight", true)
	card.set_meta("dest_pos", target)
	card.global_position = flight.from

func await_manual_strike_ack(uid: int) -> void:
	if _strike_attacks.has(uid) and _strike_attacks[uid].phase == "pending":
		_strike_attacks[uid].awaiting_ack = true

func reject_manual_strike_drops() -> void:
	for uid in _strike_attacks:
		if _strike_attacks[uid].phase == "pending": _return_strike_attack(int(uid))

func _strike_attack_target(group: int) -> Vector3:
	var target := get_group_position(group)
	return target + Vector3.UP * float(_settings.strike_attack_motion.landing_height)

func _return_strike_attack(uid: int) -> void:
	if not _strike_attacks.has(uid) or not by_uid.has(uid): return
	var flight: Dictionary = _strike_attacks[uid]
	if flight.phase == "return": return
	flight.phase = "return"
	flight.elapsed = 0.0
	flight.from = flight.to
	by_uid[uid].global_position = flight.from
	flight.to = flight.home
	by_uid[uid].set_meta("dest_pos", flight.to)

func _advance_strike_attacks(delta: float) -> void:
	if _strike_attacks.is_empty() or _state == null or _terminal_pose_locked: return
	var spec: Dictionary = _settings.strike_attack_motion
	var landed := false
	for uid in _strike_attacks.keys():
		if not by_uid.has(uid):
			_strike_attacks.erase(uid)
			continue
		var flight: Dictionary = _strike_attacks[uid]
		var card: OffWorkCard = by_uid[uid]
		var returning: bool = flight.phase == "return"
		var progress := 0.0
		if flight.phase == "pending":
			card.global_position = flight.to
			continue
		elif returning:
			flight.elapsed += delta
			progress = clampf(float(flight.elapsed) / float(spec.return_seconds), 0.0, 1.0)
		elif _state.pending_strikes.has(uid):
			var attack: Dictionary = _state.pending_strikes[uid]
			progress = clampf(1.0 - float(attack.remaining) / float(attack.total), 0.0, 1.0)
			if bool(flight.get("delivered", false)): progress = 1.0
			if _state.groups.has(int(flight.target_group)):
				flight.to = _strike_attack_target(int(flight.target_group))
		else:
			continue
		var eased := progress * progress * (3.0 - 2.0 * progress)
		var arc := float(spec.return_arc_height if returning else spec.arc_height)
		card.global_position = (flight.from as Vector3).lerp(flight.to, eased) + Vector3.UP * sin(progress * PI) * arc
		card._visual.rotation_degrees.y = sin(progress * PI) * float(spec.flight_tilt_degrees) * (-1.0 if returning else 1.0)
		card.set_meta("dest_pos", flight.to)
		if returning and progress >= 1.0:
			_release_strike_attack(int(uid), true)
			landed = true
	if landed and not _interacting(): sync_state(_state)

func _release_strike_attack(uid: int, land: bool) -> void:
	if not _strike_attacks.has(uid): return
	var flight: Dictionary = _strike_attacks[uid]
	_strike_attacks.erase(uid)
	if not by_uid.has(uid): return
	var card: OffWorkCard = by_uid[uid]
	# A successfully consumed attack retires at its target, never halfway over
	# the table. A failed attack returns to its original owner's source pile.
	if land or not _state.cards.has(uid): card.global_position = flight.to
	_motion_unlock(card, flight)
	card.remove_meta("strike_attack")

## Strike owns position only during ejection. After landing the original drag
## path owns the loose card; the rule timer still blocks combinations.
func _sync_strike_dancers() -> void:
	var wanted: Array = []
	if _state.winner < 0:
		for uid in _state.cards:
			if _state.is_striking(int(uid)): wanted.append(uid)
	var interrupted := false
	for card in _drag_cards + _press_snap.get("cards", []):
		if is_instance_valid(card) and wanted.has(card.uid) and (not _strike_dancers.has(card.uid) or _strike_in_flight(card.uid)): interrupted = true
	var pressed: Variant = _press_snap.get("card")
	if is_instance_valid(pressed) and wanted.has(pressed.uid) and (not _strike_dancers.has(pressed.uid) or _strike_in_flight(pressed.uid)): interrupted = true
	if interrupted: cancel_pointer()
	for uid in _strike_dancers.keys():
		if not wanted.has(uid): _release_strike_motion(uid, true)
	var index := 0
	for uid in wanted:
		if not by_uid.has(uid): continue
		var card: OffWorkCard = by_uid[uid]
		if _strike_dancers.has(uid):
			if _strike_in_flight(uid): card.draggable = false
			continue
		var from: Vector3 = _previous_positions.get(uid, card.global_position)
		var presenter := _presenter(card.card_owner)
		_release_meeting_motion(uid, false)
		presenter.drop_card(card)
		presenter._stop_move(card, false)
		var destination := _strike_destination(uid, from)
		_origin_by_gid[card.group_id] = destination
		group_overrides[card.group_id] = destination
		var dance := _motion_lock(card)
		dance.merge({"from": from, "to": destination, "elapsed": 0.0, "index": index, "landed": false})
		_strike_dancers[uid] = dance
		card.set_strike_participant(true)
		card.set_meta("strike_dance", true)
		card.set_meta("in_flight", true)
		card.set_meta("dest_pos", destination)
		card.global_position = from
		index += 1

func _strike_destination(uid: int, origin: Vector3) -> Vector3:
	var spec: Dictionary = _settings.strike_motion
	var card: OffWorkCard = by_uid[uid]
	var region := TableRegions.zone_rect(card.card_owner == int(_settings.local_owner), drawer_mode, _state.offers.size())
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5 + Vector2.ONE * float(spec.scatter_padding)
	var usable := Rect2(region.position + half, region.size - half * 2.0)
	var obstacles: Array[Vector3] = []
	for other in by_uid:
		if other == uid or by_uid[other].card_owner != card.card_owner: continue
		if _strike_dancers.has(other): obstacles.append(_strike_dancers[other].to)
		elif not _state.is_striking(int(other)):
			obstacles.append(_presenter(card.card_owner).rest_pos(by_uid[other]))
	var best := _presenter(card.card_owner).clamp_player_position(origin)
	var best_score := -INF
	var step := float(spec.scatter_grid_step)
	var rows := maxi(1, int(ceil(usable.size.y / step)))
	var columns := maxi(1, int(ceil(usable.size.x / step)))
	for row in rows + 1:
		for column in columns + 1:
			var candidate := Vector3(lerpf(usable.position.x, usable.end.x, float(column) / columns), float(_settings.rest_y),
				lerpf(usable.position.y, usable.end.y, float(row) / rows))
			var clearance := INF
			for obstacle in obstacles:
				var separation := Vector2((candidate.x - obstacle.x) / float(spec.clearance_x), (candidate.z - obstacle.z) / float(spec.clearance_z))
				clearance = minf(clearance, separation.length_squared())
			var score := minf(clearance, 2.0) - candidate.distance_squared_to(origin) * float(spec.distance_weight)
			if score > best_score:
				best_score = score
				best = candidate
	return best

func _advance_strike_dancers(delta: float) -> void:
	var spec: Dictionary = _settings.strike_motion
	for uid in _strike_dancers:
		if not by_uid.has(uid) or not _state.cards.has(uid): continue
		var card: OffWorkCard = by_uid[uid]
		var dance: Dictionary = _strike_dancers[uid]
		if bool(dance.landed): continue
		var record: Dictionary = _state.cards[uid]
		dance.elapsed = maxf(float(dance.elapsed) + delta, float(record.total) - float(record.remaining))
		var delay := minf(int(dance.index) * float(spec.stagger_seconds), float(spec.max_stagger_seconds))
		var age := maxf(0.0, float(dance.elapsed) - delay)
		var flight := clampf(age / float(spec.flight_seconds), 0.0, 1.0)
		if flight < 1.0:
			var t := 1.0 - pow(1.0 - flight, 2.0)
			card.global_position = (dance.from as Vector3).lerp(dance.to, t) + Vector3.UP * sin(flight * PI) * float(spec.arc_height)
			card._visual.rotation_degrees.y = sin(flight * TAU) * float(spec.flight_tilt_degrees)
			continue
		card.global_position = dance.to
		dance.landed = true
		_motion_unlock(card, dance)
		var presenter := _presenter(card.card_owner)
		if not presenter.cards.has(card): presenter.register_card(card)
		# The card now belongs to ordinary dragging; only its character dances.
		# Keep the strike marker until the rule timer ends to reject combinations.

func _release_strike_motion(uid: int, landed: bool) -> void:
	if not _strike_dancers.has(uid): return
	var dance: Dictionary = _strike_dancers[uid]
	_strike_dancers.erase(uid)
	if not by_uid.has(uid): return
	var card: OffWorkCard = by_uid[uid]
	if not bool(dance.get("landed", false)):
		if landed: card.global_position = dance.to
		_motion_unlock(card, dance)
	card.set_strike_participant(false)
	card.remove_meta("strike_dance")
	var presenter := _presenter(card.card_owner)
	if not presenter.cards.has(card): presenter.register_card(card)

func reset_view() -> void:
	if is_instance_valid(_paper_disposal): _paper_disposal.clear()
	_terminal_pose_locked = false
	if is_instance_valid(enemy_board): (enemy_board as IncomeBoard).terminal_sides_hidden = false
	if side_extract != null: side_extract.close()
	cancel_pointer()
	for uid in _delivery_flights.keys(): _release_delivery(uid)
	for uid in _strike_dancers.keys(): _release_strike_motion(uid, false)
	for uid in _strike_attacks.keys(): _release_strike_attack(uid, false)
	_delivery_flights.clear()
	_strike_dancers.clear()
	_meeting_visitors.clear()
	_meeting_centers.clear()
	_meeting_home_order.clear()
	_drop_target_person = -1
	for uid in _cash_flights.keys():
		if by_uid.has(uid): _cancel_cash_flight(by_uid[uid])
	_cash_flights.clear()
	_cash_emission_serial.clear()
	_cash_stream_width.clear()
	_opening_counts.clear()
	_opening_layout_enabled = false
	for tween in _effect_tweens:
		if tween != null and tween.is_valid(): tween.kill()
	_effect_tweens.clear()
	# All groups are leaving together. Removing one UID at a time would refresh
	# the shrinking group (labels/layout) for every remaining member: O(n²).
	# Retain unregister_card's per-card interaction/motion cleanup, but empty
	# group and registration indexes once before running that cleanup.
	var registrations := {}
	for group in groups.duplicate(): _remove_group(group)
	for card in cards: registrations[card] = self
	cards.clear()
	if is_instance_valid(enemy_board):
		for group in enemy_board.groups.duplicate(): enemy_board._remove_group(group)
		for card in enemy_board.cards: registrations[card] = enemy_board
		enemy_board.cards.clear()
	for node in by_uid.values() + offers_by_id.values() + _retired_cards.values():
		if is_instance_valid(node):
			if registrations.has(node): registrations[node].unregister_card(node)
			node.hide()
			node.queue_free()
	for tag in _prices.values():
		if is_instance_valid(tag): tag.queue_free()
	by_uid.clear()
	_stack_occluded.clear()
	_stack_occlusion_dependencies.clear()
	_record_sync_key.clear()
	_record_cards = {}
	_record_groups = {}
	_group_progress_cards.clear()
	_debug_timer_cards.clear()
	_stack_representatives.clear()
	_thin_stack_cards.clear()
	_muted_stack_titles.clear()
	offers_by_id.clear()
	_prices.clear()
	_retired_cards.clear()
	_previous_positions.clear()
	_transfer_departures.clear()
	_origin_by_gid.clear()
	_opponent_layout_signature = ""
	_opponent_layout_passes = 0
	_compact_by_gid.clear()
	_spawned_by_owner.clear()
	group_overrides.clear()
	_picked_ids.clear()
	_dismiss_pick_snapshot.clear()
	purchase_payment_ids.clear()
	_drop_pending = false
	_was_interacting = false
	_state = null
	input_locked = false
	attack_mode = false
