# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node3D

## 借用正式对局的同一张牌桌。Context保管原局；本层只接管原Board的教学输入。
## 不创建视口、相机、Board或桌面环境，所有规则操作仍由TutorialSession裁决。
const CardMotion = preload("res://scenes/card_motion.gd")
const TableActions = preload("res://scenes/table_actions.gd")
const TableSnapshot = preload("res://scenes/table_snapshot.gd")
const UIMotion = preload("res://scenes/ui_motion.gd")
const Regions = preload("res://scenes/table_regions.gd")
const Catalog = preload("res://engine/tutorial_catalog.gd")
const ResultPresentation = preload("res://scenes/result_presentation.gd")
const PLAYER_ZONE_Z := Regions.PLAYER_ZONE_Z
const BOT_ZONE_Z := Regions.BOT_ZONE_Z
const MARKET_Z := Regions.DRAWER_MARKET_Z

signal changed
signal action_result(result: Dictionary)
signal operation_finished(result: Dictionary)

const ROLLBACK_DELAY := 0.25
var operation_pending := false

var session: RefCounted
var state: GameState
var board: Board
var camera: Camera3D
var layout: Node
var sfx: Sfx
var entities: Dictionary = {}
var market_cards: Array[CardEntity] = []
var market_price_labels: Array = []
var my_seat := GameState.PLAYER
var foe_seat := GameState.BOT
var foe_piles: Array = []
var _table_scene: RefCounted
var _card_motion: Node
var _table_actions: Node
var _market_ids: Array = []
var _generation := -1
var _split_uid := -1
var _split_source_uids: Array = []
var _refresh_queued := false
var _syncing_state := false
var _transition_busy := false
var _restoring_operation := false
var _operation_before: Dictionary = {}
var _operation_picked_uids: Array = []
var _operation_epoch := 0
var _operation_generation := -1
var _pending_rollback: Dictionary = {}
var _rollback_timer: Tween
var _settlement_presenting := false
var _result_view: Dictionary = {}
var _main: Node3D
var _released := false
var _signals: Array = []

func configure_on_table(main: Node3D, lesson: RefCounted) -> void:
	_main = main
	process_mode = Node.PROCESS_MODE_ALWAYS
	session = lesson
	state = session.state
	board = main.board
	camera = board.camera
	_table_scene = main._table_scene
	# 只更换实体生成的父节点，仍复用既有TableScene、Board、World和相机。
	_table_scene.host = self
	main._tutorial_arena = self
	sfx = main.sfx
	board.hover_description_enabled = false
	board.touch_mode = main.mobile_mode
	layout = _table_scene.create_layout()
	_card_motion = CardMotion.new()
	add_child(_card_motion)
	_card_motion.bind(board, sfx, _table_scene.drawer_mode)
	_table_actions = TableActions.new()
	add_child(_table_actions)
	_table_actions.bind(self, false)
	board.cancel_anim = _cancel_fly
	_connect_board("card_pick_started", _pick_started)
	_connect_board("dropped_on_market", _purchase)
	_connect_board("dropped_on_pawn", _pawn)
	_connect_board("attack_clicked", _attack)
	_connect_board("card_picked", _picked)
	_connect_board("card_dropped_table", _layout_changed)
	_connect_board("card_stacked", func(_completed): _layout_changed())
	_connect_board("pile_toggled", _view_changed)
	_connect_board("group_formed", _group_ready)
	_signals.append_array(TableActions.bind_board_sounds(board, _play_board_sound))
	Palette.bus().changed.connect(_palette_changed)
	sync_state(true)

func _connect_board(signal_name: String, callback: Callable) -> void:
	board.connect(signal_name, callback)
	_signals.append([signal_name, callback])

func _play_board_sound(action: String) -> void:
	if not _released and not _syncing_state:
		_main._table_actions.play_board_sound(action)

func _group_ready(cards: Array) -> void:
	if not _released and not _syncing_state:
		_table_actions.group_ready(cards)

func set_transition_busy(value: bool) -> void:
	_transition_busy = value
	_sync_interaction()

func _sync_interaction() -> void:
	if _released or not is_instance_valid(board) or session == null:
		return
	var blocked: bool = operation_pending or _transition_busy or session.demo_active
	board.attack_mode = not blocked and session.phase == "attack"
	board.input_locked = blocked or session.phase != "action" or session.completed
	_main._refresh_attack_panel()

func _can_operate() -> bool:
	return not _released and not operation_pending and not _transition_busy and not session.demo_active

func _capture_operation() -> Dictionary:
	session.preview_groups(current_groups())
	return {"logic": session.capture_operation(), "visual": TableSnapshot.capture(_main),
		"generation": int(session.generation), "step": int(session.step_index)}

func _pick_started(_card: CardEntity) -> void:
	if not _can_operate() or _syncing_state:
		return
	_operation_epoch += 1
	_operation_before = _capture_operation()
	_operation_picked_uids = []

func _begin_operation(use_drag := false) -> Dictionary:
	var before := _operation_before if use_drag else {}
	if before.is_empty() or before["generation"] != int(session.generation) \
		or before["step"] != int(session.step_index):
		before = _capture_operation()
	_operation_before = {}
	operation_pending = true
	_operation_generation = int(session.generation)
	_sync_interaction()
	return before

func _complete_operation(before: Dictionary, action: String, result: Dictionary, detail: Dictionary = {}) -> void:
	if _released:
		return
	session.preview_groups(current_groups())
	detail["result"] = result
	var reviewed: Dictionary = session.review_operation(before["logic"], action, detail)
	var expected: bool = reviewed.get("expected", false) and result.get("ok", true)
	var reason: String = str(reviewed.get("reason", result.get("reason", "")))
	_split_uid = -1
	_split_source_uids.clear()
	_operation_picked_uids = []
	if expected:
		_finish_accepted_operation(action, result, reason,
			before["logic"]["state"].get("winner", "") == "" and state.winner != "")
		return
	_pending_rollback = {"before": before, "action": action, "reason": reason, "result": result}
	_sync_interaction()
	_rollback_timer = create_tween()
	_rollback_timer.tween_interval(ROLLBACK_DELAY)
	_rollback_timer.tween_callback(_rollback_operation.bind(_operation_epoch, _operation_generation))

func _accept_operation(action: String, result: Dictionary, reason: String) -> void:
	operation_pending = false
	_sync_interaction()
	action_result.emit(result)
	operation_finished.emit({"expected": true, "rolled_back": false, "reason": reason,
		"action": action, "result": result})

func _finish_accepted_operation(action: String, result: Dictionary, reason: String, victory: bool) -> void:
	var epoch := _operation_epoch
	var generation := int(session.generation)
	var current := func(): return not _released and _operation_epoch == epoch and int(session.generation) == generation
	# 买牌到货、典当到账和编组归位也必须先结束，才能更新当前目标或显示结果确认。
	# 直接观察共用组件的补间状态，不另设教学等待时长或复制动画。
	while current.call() and (_card_motion.transferring() or _table_actions.pawn_busy() \
		or board.cards_moving()):
		await _presentation_timer(0.02).timeout
	if not current.call(): return
	if not victory:
		_accept_operation(action, result, reason)
		return
	_result_view = ResultPresentation.create(self, state, my_seat, sfx, Callable(), "", true, true)
	ResultPresentation.present(_result_view, _main.drawer_presentation, func():
		if not current.call(): return
		_accept_operation(action, result, reason))
	changed.emit()

func set_presentation_active(value: bool) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS if value else Node.PROCESS_MODE_DISABLED
	_card_motion.set_tear_active(value)
	ResultPresentation.set_active(_result_view, value)

func _rollback_operation(epoch: int, generation: int) -> void:
	if _released or epoch != _operation_epoch or _pending_rollback.is_empty():
		return
	if generation != int(session.generation):
		cancel_pending_operation()
		return
	var rejected := _pending_rollback
	_pending_rollback = {}
	_rollback_timer = null
	_restoring_operation = true
	_syncing_state = true
	_cancel_operation_visuals()
	board.cancel_pointer()
	session.restore_operation(rejected["before"]["logic"])
	sync_state(true, rejected["before"]["visual"])
	_restoring_operation = false
	operation_pending = false
	_sync_interaction()
	# 原动作声音照常表达已经发生的动作；只有回滚完成时补一声轻提示。
	sfx.play("deny_quiet")
	changed.emit()
	action_result.emit(rejected["result"])
	operation_finished.emit({"expected": false, "rolled_back": true, "reason": rejected["reason"],
		"action": rejected["action"], "result": rejected["result"]})

func cancel_pending_operation() -> void:
	_operation_epoch += 1
	if is_instance_valid(_card_motion): _card_motion.cancel_tears()
	ResultPresentation.close(_result_view)
	if _settlement_presenting and is_instance_valid(layout):
		layout.end_arrivals()
	_settlement_presenting = false
	if _rollback_timer != null and _rollback_timer.is_valid():
		_rollback_timer.kill()
	_rollback_timer = null
	_pending_rollback = {}
	_operation_before = {}
	_operation_picked_uids = []
	_refresh_queued = false
	operation_pending = false
	_transition_busy = false
	_sync_interaction()

func _cancel_operation_visuals() -> void:
	if is_instance_valid(_table_actions):
		_table_actions.cancel_pawn()
	if is_instance_valid(_card_motion):
		_card_motion.cancel_transfers()
	for child in get_children():
		if child is CardEntity:
			_cancel_fly(child)
			if not board.cards.has(child): child.queue_free()
		elif child.has_meta("motion_event"):
			child.queue_free()

func release_table(shutting_down := false) -> void:
	if _released:
		return
	_released = true
	cancel_pending_operation()
	for entry in _signals:
		if is_instance_valid(board) and board.is_connected(entry[0], entry[1]):
			board.disconnect(entry[0], entry[1])
	_signals.clear()
	if Palette.bus().changed.is_connected(_palette_changed):
		Palette.bus().changed.disconnect(_palette_changed)
	if shutting_down or not is_instance_valid(board) or not board.is_inside_tree():
		# 本节点及其教学卡由主场景销毁；退树后不能再走会读取世界坐标的拖牌清理。
		entities.clear()
		market_cards.clear()
		market_price_labels.clear()
		_table_scene.host = _main
		process_mode = Node.PROCESS_MODE_DISABLED
		return
	_cancel_operation_visuals()
	board.cancel_pointer()
	for card in board.cards.duplicate():
		_remove_entity(card)
	for label in market_price_labels:
		if is_instance_valid(label): label.queue_free()
	for group in board.groups.duplicate(): board._remove_group(group)
	board.clear_side_badges()
	board.cards = []
	board.groups = []
	board._move_tw = {}
	entities.clear()
	market_cards.clear()
	market_price_labels.clear()
	_table_scene.host = _main
	process_mode = Node.PROCESS_MODE_DISABLED

func _sync_main() -> void:
	if _released or not is_instance_valid(_main):
		return
	_main.state = state
	if _main.pipe == null or _main.pipe.applier() != session.applier:
		_main.pipe = LocalTransport.new(session.applier)
	_main.entities = entities
	_main.market_cards = market_cards
	_main.market_price_labels = market_price_labels
	_main.layout = layout
	_main.foe_piles = []
	_main.my_seat = my_seat
	_main.foe_seat = foe_seat
	_main.phase = _main.PHASE_ATTACK if session.phase == "attack" else _main.PHASE_ACTION
	_main._actor = my_seat
	_main._update_hud()
	_main._refresh_attack_panel()

func current_groups() -> Array:
	if _released: return []
	var out: Array = []
	var seen := {}
	for group in board.groups:
		var records: Array = []
		for card in group["cards"]:
			if not is_instance_valid(card):
				continue
			var record := state.find_card(my_seat, card.uid)
			if not record.is_empty():
				records.append(record)
				seen[card.uid] = true
		if not records.is_empty():
			out.append(records)
	for record in state.players[my_seat]["cards"]:
		if not seen.has(record["uid"]):
			out.append([record])
	return out

func _picked(card: CardEntity) -> void:
	if _released: return
	_operation_picked_uids = board._drag_cards.map(func(member): return member.uid)
	# Board 发出 picked 时已经拆分；只有确实从一组中抽出部分牌才记候选。
	_split_uid = card.uid if board._drag_src_group != null and board._drag_cards.size() == 1 else -1
	_split_source_uids.clear()
	if _split_uid >= 0:
		for member in board._drag_src_group["cards"] + board._drag_cards:
			_split_source_uids.append(member.uid)

func _layout_changed() -> void:
	if _released or _syncing_state or operation_pending or _refresh_queued:
		return
	_refresh_queued = true
	# 收牌信号仍在 Board 的落牌调用栈里；先锁住下一次按下，再等本次布局落定。
	# 否则同帧的新拖拽会覆盖操作前快照，让延迟审查失效。
	operation_pending = true
	_operation_generation = int(session.generation)
	_sync_interaction()
	_finish_layout_change.call_deferred(_operation_epoch)

func _finish_layout_change(epoch := -1) -> void:
	if _released or not is_instance_valid(board) or session == null \
		or (epoch >= 0 and epoch != _operation_epoch):
		return
	_refresh_queued = false
	if _transition_busy or session.demo_active or not board._drag_cards.is_empty():
		operation_pending = false
		_sync_interaction()
		return
	var before := _begin_operation(true)
	var split_uid := -1
	if _split_uid >= 0 and board._drag_cards.is_empty():
		var card: CardEntity = entities.get(_split_uid)
		var group: Variant = board.group_of(card) if card != null else null
		var still_together: bool = group != null and _split_source_uids.all(func(uid): return group["cards"].any(func(member): return member.uid == uid))
		if not still_together:
			session.notify_split(_split_uid)
			split_uid = _split_uid
		_split_uid = -1
		_split_source_uids.clear()
	session.preview_groups(current_groups())
	_refresh_protection()
	_sync_main()
	changed.emit()
	var groups := current_groups()
	_complete_operation(before, "layout", {"ok": true}, {"picked_uids": _operation_picked_uids,
		"split_uid": split_uid, "groups": groups, "preview_groups": groups})

func _view_changed() -> void:
	if _released or _syncing_state or operation_pending:
		return
	# 展开/收摞只是查看方式；结束上一次轻点快照，不审查也不回滚。
	_operation_before = {}
	_operation_picked_uids = []
	_split_uid = -1
	_split_source_uids.clear()
	changed.emit()

func _purchase(cards: Array, market: CardEntity) -> void:
	var placement: Dictionary = _table_actions.take_purchase_placement(market)
	if not _can_operate():
		_table_actions.cancel_purchase_placement(market, placement)
		return
	var idx := market_cards.find(market)
	if idx < 0:
		_table_actions.cancel_purchase_placement(market, placement)
		return
	var before := _begin_operation(true)
	var picked_uids := cards.map(func(card): return card.uid)
	var definition := market.def_id
	var payment: Dictionary = _table_actions.purchase_payment(cards, int(CardDB.get_def(definition).get("price", -1)))
	var result: Dictionary = payment["issue"]
	if result.is_empty():
		result = session.buy(idx, payment["uids"])
	state = session.state
	if result.get("ok", false):
		_table_actions.purchase(idx, market, result, placement)
		_market_ids = state.market.duplicate()
	else:
		_table_actions.cancel_purchase_placement(market, placement)
	if placement.is_empty(): _table_actions.return_purchase_payment(cards)
	sync_state()
	_complete_operation(before, "buy", result, {"index": idx, "def_id": definition, "picked_uids": picked_uids})

func _pawn(cards: Array) -> void:
	if not _can_operate(): return
	var before := _begin_operation(true)
	var uids: Array = []
	for card in cards:
		if CardDB.pawn_value(card.def_id) > 0:
			uids.append(card.uid)
	var result: Dictionary = session.pawn(uids)
	state = session.state
	if result.get("ok", false):
		_table_actions.pawn(cards, uids)
	_return_cards(cards)
	sync_state()
	_complete_operation(before, "pawn", result, {"picked_uids": cards.map(func(card): return card.uid), "uids": uids})

func _attack(card: CardEntity) -> void:
	if not _can_operate(): return
	if session.phase != "attack" or state.find_card(foe_seat, card.uid).is_empty():
		return
	var before := _begin_operation()
	var epoch := _operation_epoch
	var generation := int(session.generation)
	var current := func(): return not _released and epoch == _operation_epoch and int(session.generation) == generation
	var key := str(layout._bot_pile_of_uid.get(card.uid, ""))
	var pile: Array = layout._bot_pile_uids.get(key, [card.uid]).duplicate()
	var first_target := {}
	var center := Vector3.INF
	var removed: Array = []
	var result := {"ok": false, "reason": Catalog.ui("invalid_target")}
	if key != "":
		var batch: Dictionary = await _table_actions.apply_pile_attack(key, session.attack,
			func(): return session.applier.pools(my_seat), current)
		if not current.call(): return
		first_target = batch["first_target"]
		center = batch["center"]
		removed = batch["removed"]
		if not removed.is_empty() or batch["result"].has("reason"): result = batch["result"]
	else:
		for candidate in session.applier.affordable_targets(my_seat):
			if not candidate.get("uids", []).has(card.uid): continue
			first_target = candidate
			center = _table_actions.attack_target_center(candidate)
			result = session.attack(candidate)
			if result.get("ok", false): removed.append_array(result.get("removed", []))
			break
	if not removed.is_empty():
		result = result.duplicate(true)
		result["removed"] = removed
		for target_card in entities.values(): target_card.set_highlight(false)
		if not await _table_actions.present_attack(removed, center, my_seat, str(first_target.get("res", "")),
			_main.table_hands, _presentation_timer, current, [], Callable(), int(before["logic"]["state"]["round_num"]),
			before["logic"]["state"]["combos"]): return
	else:
		_table_actions.shield_feedback(_table_actions._members(pile))
	if not current.call(): return
	sync_state()
	_complete_operation(before, "attack", result, {"target": first_target, "pile_uids": pile})

func finish_action() -> Dictionary:
	if not _can_operate(): return {"ok": false, "code": "busy"}
	board.cancel_pointer()
	var before := _begin_operation()
	var action := "finish_attack" if session.phase == "attack" else "finish_action"
	var result: Dictionary = session.finish_attack() if action == "finish_attack" else session.finish_action(current_groups())
	var events: Array = session.events.slice(before["logic"]["events"].size())
	var produced: Array = events.filter(func(event): return event.get("op") == Intent.OP_PRODUCE)
	var attacks: Array = events.filter(func(event): return event.get("op") == Intent.OP_ATTACK)
	if not attacks.is_empty() or not produced.is_empty():
		# 裁决仍只执行一次；逐组展示真实产出，最后一张牌落地后才通知小人推进。
		# 对手造成的实际伤害也必须先演完；错误结束行动随后才回滚，不能直接闪掉卡。
		_present_settlement(before, action, result, produced, events if not attacks.is_empty() else [])
		return result
	sync_state()
	_complete_operation(before, action, result)
	return result

func _present_settlement(before: Dictionary, action: String, result: Dictionary, produced: Array, attacks: Array = []) -> void:
	_settlement_presenting = true
	var epoch := _operation_epoch
	var generation := int(session.generation)
	var current := func(): return not _released and _operation_epoch == epoch and int(session.generation) == generation
	var known := {}
	for uid in entities: known[uid] = true
	if not attacks.is_empty():
		if not await _table_actions.present_attack_events(attacks, _main.table_hands, _presentation_timer, current): return
	# 付款和升级材料交给共用动画消耗；此前受攻击移除的牌不能继续留在组合里。
	var consumed := {}
	for event in produced:
		for uid in event.get("resolution", {}).get("paid_uids", []): consumed[int(uid)] = true
		if event.get("resolution", {}).get("resolved", false) and event.get("combo", {}).get("eval", {}).get("type") == "upgrade":
			for uid in event["combo"]["uids"]: consumed[int(uid)] = true
	for uid in entities.keys():
		var card: CardEntity = entities[uid]
		if not consumed.has(uid) and state.find_card(my_seat if card.draggable else foe_seat, uid).is_empty():
			_remove_entity(card)
			entities.erase(uid)
	layout.begin_arrivals()
	changed.emit()
	for event: Dictionary in produced:
		var resolve := func(): return event
		await _table_actions.present_combo(event["combo"], resolve, current, _present_produced,
			_presentation_timer, Callable())
		if not current.call(): return
	layout.end_arrivals()
	_settlement_presenting = false
	sync_state()
	_syncing_state = true
	layout._stack_settled(known)
	_syncing_state = false
	# 收摞也复用正式布局；等位移动画停止，避免下一课清桌吃掉最后一拍。
	while current.call() and entities.values().any(func(card):
		var tween: Tween = card.get_meta("fly_tw") if card.has_meta("fly_tw") else null
		return tween != null and tween.is_valid() and tween.is_running()):
		await _presentation_timer(0.02).timeout
	if not current.call(): return
	_complete_operation(before, action, result)

func _presentation_timer(seconds: float) -> Timer:
	# 正式牌局由Context暂停，借用的教学牌桌仍需播放自己的共用动效。
	# 计时器随借用的牌桌销毁，退出后不会再恢复旧课程的协程。
	var timer := Timer.new()
	timer.one_shot = true
	add_child(timer)
	timer.timeout.connect(timer.queue_free)
	timer.start(maxf(seconds, 0.001))
	return timer

func _present_produced(event: Dictionary, center: Variant) -> void:
	var produced: Array = event.get("produced_cards", [])
	for i in produced.size():
		var entry: Dictionary = produced[i]
		var record: Dictionary = entry["card"]
		var owner := str(entry["seat"])
		_spawn_entity(record, layout.arrival_spot(owner, record), owner == my_seat, center, i, produced.size())
	board.prune_groups()
	# Session已经裁决整轮；等全部实体演完再同步HUD，避免首组就跳到最终总额。

func _return_cards(cards: Array) -> void:
	_table_actions.return_cards(cards)

func sync_state(force := false, restore_view: Dictionary = {}) -> void:
	if _released: return
	if not _restoring_operation and (force or (operation_pending and _operation_generation != int(session.generation))):
		cancel_pending_operation()
	_syncing_state = true
	state = session.state
	var reset: bool = force or _generation != int(session.generation)
	if reset:
		_cancel_operation_visuals()
		board.cancel_pointer()
		_split_uid = -1
		_split_source_uids.clear()
		for group in board.groups.duplicate():
			board._remove_group(group)
		for card in entities.values():
			_remove_entity(card)
		entities.clear()
		_generation = int(session.generation)
	var live := {}
	var fresh: Array = []
	for who in [my_seat, foe_seat]:
		for record in state.players[who]["cards"]:
			var uid := int(record["uid"])
			live[uid] = true
			if not entities.has(uid):
				var anchor: Vector3 = layout._unit_anchor(who, str(record["def_id"]))
				if CardDB.get_def(str(record["def_id"])).get("kind") != CardDB.KIND_UNIT:
					anchor = layout._free_spot(anchor, who)
				var card: CardEntity = _table_scene.spawn_card(board, record, anchor, who == my_seat)
				card.freeze = true
				entities[uid] = card
				fresh.append(card)
	for uid in entities.keys():
		if not live.has(uid):
			_remove_entity(entities[uid])
			entities.erase(uid)
	if reset:
		apply_groups(session.initial_groups)
	if reset or not fresh.is_empty():
		layout._tidy_player_idle()
	layout._layout_bot_idle()
	if reset or _market_ids != state.market:
		_rebuild_market(restore_view.get("market", []))
	if not restore_view.is_empty():
		_sync_main()
		TableSnapshot.restore(_main, restore_view)
	for card in fresh:
		if not reset:
			card.pulse_feedback("arrive")
	_refresh_protection()
	_refresh_attack_targets()
	_sync_interaction()
	_sync_main()
	_syncing_state = false
	changed.emit()

## 场景脚本与演示返回 UID 组；玩家平时的组合直接保留在 Board 上。
func apply_groups(groups: Array) -> void:
	if _released: return
	var was_syncing := _syncing_state
	_syncing_state = true
	for group_data in groups:
		var ids: Array = group_data.get("uids", []) if group_data is Dictionary else group_data
		var members: Array = []
		for value in ids:
			var uid := int(value.get("uid", -1)) if value is Dictionary else int(value)
			if entities.has(uid) and not state.find_card(my_seat, uid).is_empty():
				var card: CardEntity = entities[uid]
				board._detach_from_group(card)
				members.append(card)
		if members.is_empty():
			continue
		var ignore := {}
		for card in members:
			ignore[card.uid] = true
		var at: Vector3 = group_data.get("at", layout._free_spot(Vector3(0.0, 0.05, 2.4), my_seat, [], ignore)) if group_data is Dictionary else layout._free_spot(Vector3(0.0, 0.05, 2.4), my_seat, [], ignore)
		var compact: bool = group_data.get("compact", true) if group_data is Dictionary else true
		var group: Dictionary = board.make_group(Board.core_first_order(members), compact)
		board.groups.append(group)
		board._layout_group(group, at)
	_syncing_state = was_syncing

func _remove_entity(card: CardEntity) -> void:
	if not is_instance_valid(card):
		return
	layout.kill_bot_move(card.uid)
	_cancel_fly(card)
	card.collision_layer = 0
	card.collision_mask = 0
	board.drop_card(card)
	card.queue_free()

func _rebuild_market(positions: Array = []) -> void:
	for card in market_cards:
		_remove_entity(card)
	for label in market_price_labels:
		if is_instance_valid(label):
			label.queue_free()
	market_cards.clear()
	market_price_labels.clear()
	_market_ids = state.market.duplicate()
	for i in state.market.size():
		var at := _market_slot(i, int(CardDB.game_rules()["market_size"]))
		if i < positions.size() and positions[i] is Array and positions[i].size() == 3:
			at = Vector3(float(positions[i][0]), float(positions[i][1]), float(positions[i][2]))
		var entry: Dictionary = _table_scene.spawn_market_card(board, i, state.market[i], at)
		market_cards.append(entry["card"])
		market_price_labels.append(entry["price"])

func _refresh_protection() -> void:
	# 护盾与 Buff 光环由随后的 _sync_main → _update_hud → _refresh_shields 统一刷新。
	for group in board.groups:
		board.refresh_group(group)

func _refresh_attack_targets() -> void:
	for card in entities.values():
		if not card.draggable: card.set_highlight(false)
	# 不 clear Context 保存的原数组：本课使用新集合，供原 TableHands 识别怒手。
	_main._attack_hl = _table_actions.highlight_attack_targets(session.applier.pools(my_seat)) if session.phase == "attack" else []
	_main._player_attack_busy = 0

func focus_cards() -> Array:
	if _released: return []
	var out: Array = []
	var step: Dictionary = session.current_step()
	var focus: Variant = step.get("focus", [])
	var ids: Array = focus if focus is Array else [focus]
	for card in board.cards:
		var kind: String = str(CardDB.get_def(card.def_id).get("kind", ""))
		var selected: bool = card.def_id in ids or ("market" in ids and card.is_market) \
			or ("resources" in ids and card.draggable and kind == CardDB.KIND_UNIT) \
			or ("board" in ids and card.draggable and kind in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]) \
			or ("opponent" in ids and not card.draggable and not card.is_market)
		if selected:
			out.append(card)
	return out

func highlight_focus() -> void:
	for card in focus_cards():
		card.pulse_feedback("ready", Palette.semantic("info"), 1.5)

func _palette_changed(_section: String, _key: String) -> void:
	if _released: return
	_table_scene.refresh_palette()
	for card in board.cards:
		if is_instance_valid(card):
			card.refresh_palette()

func _cancel_fly(card: CardEntity) -> void: _card_motion._cancel_fly(card)
func _clear_dest(card: CardEntity) -> void: _card_motion._clear_dest(card)
func _pawn_position() -> Vector3: return board.pawn_pos
func _event_feedback(event: String, at: Vector3, color: Color, amount := 16) -> void:
	UIMotion.play(self, event, at, color, amount)

func _spawn_entity(record: Dictionary, at: Vector3, draggable: bool, from_pos = null, index := 0, total := 1) -> CardEntity:
	return _table_actions.spawn_card(record, at, draggable, from_pos, index, total)

func _market_slot(index: int, count: int) -> Vector3:
	# 商品沿用当前牌桌既有槽位；自定义市场大小时也不重新摆一张教学桌。
	if _main != null and index < _main.market_slots.size():
		return _main.market_slots[index]
	return Regions.market_slot(index, count, true)
func is_drag_leased(_uid: int) -> bool: return false
func foe_anchor_of(_uid: int) -> Variant: return null
func foe_pile_point(_x: float, _y: float) -> Vector3: return Vector3.ZERO
func foe_compact_of(_uid: int) -> Variant: return null
