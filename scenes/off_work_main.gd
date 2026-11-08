# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node3D

const ConfigData = preload("res://engine/config_data.gd")
const State = preload("res://engine/off_work_state.gd")
const Bot = preload("res://engine/off_work_bot.gd")
const BotPreferences = preload("res://engine/off_work_bot_preferences.gd")
const BoardView = preload("res://scenes/off_work_board.gd")
const Audio = preload("res://scenes/off_work_audio.gd")
const Effects = preload("res://scenes/off_work_effects.gd")
const OriginalTable = preload("res://scenes/table_scene.gd")
const OriginalMotion = preload("res://scenes/card_motion.gd")
const HandsView = preload("res://scenes/table_hands.gd")
const HUDView = preload("res://scenes/off_work_hud.gd")
const ConveyorView = preload("res://scenes/off_work_conveyor.gd")

var state
var bot
var _live_bot := preload("res://engine/off_work_bot_live.gd").new()
var board
var audio
var effects
var _effect_layer: CanvasLayer
var settings: Dictionary
var hud
var drawer_presentation
var table_hands
var conveyor
var mobile_mode := false
var _attack_hl: Array = []
var _player_attack_busy := 0
var camera: Camera3D
var sfx: Sfx
var _table_scene
var _card_motion
var mine: Label
var opponent: Label
var message: Label
var result_layer: CanvasLayer
var _selected_tool := -1
var _message_age := 0.0
var _refresh_age := 0.0
var _result_age := 0.0
var _result_started := false
var _positions: Dictionary = {}
var _activity_group_cache := {}
var _activity_group_revision := -1
var _activity_group_membership := -1
var _activity_group_state := 0
var _shot_elapsed := 0.0
var _shot_pending := false
var _shot_spec: PackedStringArray
var _player_activity_snapshot: Dictionary = {}
const ShiftSession = preload("res://engine/off_work_session.gd")
const SavePaths = preload("res://engine/save_paths.gd")
const JsonStore = preload("res://engine/json_store.gd")
var lan
var replay := preload("res://engine/off_work_replay.gd").new()
var _selected_config := ""
var _active_config := ""
var _replay_picker: CanvasLayer
var _launch_config := ""
var practice := {}
var practice_stage := 0
var lesson := preload("res://engine/off_work_tutorial.gd").new()
var _shift_enabled := false
var _shift_hidden := false
var _shift_save_elapsed := 0.0

func save_shift_session() -> bool:
	return not _shift_enabled or not practice.is_empty() or replay.playing or (lan != null and lan.live()) or ShiftSession.save_session(self)

func _exit_tree() -> void:
	_live_bot.close(get_tree())
	if _shift_enabled and is_instance_valid(hud):
		save_shift_session()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_PAUSED, NOTIFICATION_APPLICATION_PAUSED]: _live_bot.cancel()
	if _shift_enabled and what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED]:
		save_shift_session()


func _ready() -> void:
	var setup: RefCounted = get_meta("shift_setup") if has_meta("shift_setup") else null
	mobile_mode = PlatformMode.is_mobile() or PlatformMode.force_mobile()
	settings = UIConfig.read_section("presentation")
	var playtest_path := ""
	var playtest_hash := ""
	var flags := LaunchConfig.read_desktop()
	if get_meta("read_playtest_cards", true) and flags.has("cards-config"):
		playtest_path = ConfigData.bundled_path(str(flags["cards-config"]))
		var file := FileAccess.open(playtest_path, FileAccess.READ)
		if file == null:
			push_error("无法读取试玩卡表：" + playtest_path)
			get_tree().quit(1)
			return
		var source := file.get_as_text()
		var document: Variant = JSON.parse_string(source)
		if not document is Dictionary:
			push_error("试玩卡表必须为 JSON 对象：" + playtest_path)
			get_tree().quit(1)
			return
		state = State.new(OffWorkConfig.new(document))
		playtest_hash = source.sha256_text()
	_launch_config = playtest_path
	var pref := SavePaths.settings_file("work_card_selection.json")
	if FileAccess.file_exists(pref):
		var selected: Variant = JSON.parse_string(FileAccess.get_file_as_string(pref))
		if selected is String:
			_selected_config = ConfigData.bundled_path(selected)
			if _selected_config != selected:
				JsonStore.save(pref, _selected_config)
	if state == null:
		var selected := _read_card_config(_selected_config)
		state = State.new(selected.get("config"))
		_active_config = _selected_config if selected.ok else ""
	else:
		_active_config = playtest_path
	if not state.config.errors.is_empty():
		push_error("\n".join(state.config.errors))
		get_tree().quit(1)
		return
	_shift_enabled = bool(get_meta("shift_session_enabled", false)) and playtest_path.is_empty()
	var saved := ShiftSession.read_session(self) if _shift_enabled else {}
	if setup: await setup.checkpoint(get_tree())
	OffWorkCardDB.configure(state.config)
	_live_bot.bind_config(state.config)
	if not playtest_path.is_empty():
		OffWorkCardDB.loaded_from = playtest_path
	_table_scene = OriginalTable.new(self, true, int(state.config.rules.conveyor.slots))
	OriginalTable.RenderWarmup.prepare(self)
	OffWorkCard.prewarm_event_stamps()
	_table_scene._setup_environment()
	_table_scene._setup_table()
	camera = _table_scene.camera
	# 保留原设施位置、卡框与分隔线，接入专门的开除插画。
	_setup_dismissal_facility()
	if setup: await setup.checkpoint(get_tree())
	board = BoardView.new()
	add_child(board)
	board.setup(camera, true)
	conveyor = ConveyorView.new()
	add_child(conveyor)
	conveyor.setup(board, self)
	get_node("PlayerZoneTray").bind_board(board)
	get_node("FoeZoneTray").bind_board(board.enemy_board)
	for presenter in [board, board.enemy_board]:
		var lighting := TableLighting.new()
		add_child(lighting)
		lighting.bind(presenter)
	board.work_groups_changed.connect(_on_groups_changed)
	board.offer_bought.connect(_on_buy)
	board.dismiss_requested.connect(_on_dismiss)
	board.tool_activated.connect(_activate)
	board.strike_delivered.connect(_deliver_strike)
	board.ingredient_requested.connect(_activate)
	board.card_selected.connect(_on_selected)
	if board.has_signal("action_rejected"):
		board.action_rejected.connect(func(reason: String): _notify(reason, true))
	audio = Audio.new()
	add_child(audio)
	audio.setup(settings.audio)
	sfx = Sfx.new()
	add_child(sfx)
	audio.muted = sfx.user_muted
	sfx.user_muted_changed.connect(func(value: bool):
		audio.muted = value
		if value: audio.stop_all())
	_card_motion = OriginalMotion.new()
	add_child(_card_motion)
	_card_motion.bind(board, sfx, true)
	board.bind_motion(_card_motion)
	board.card_picked.connect(func(_card): sfx.play("card_pickup"))
	board.card_dropped_table.connect(func(): sfx.play("card_drop"))
	board.pile_toggled.connect(func(): sfx.play("pile_toggle"))
	_effect_layer = CanvasLayer.new()
	_effect_layer.layer = 4
	add_child(_effect_layer)
	effects = Effects.new()
	_effect_layer.add_child(effects)
	settings.effects.transfer_duration = float(board._settings.transfer_motion.travel_seconds)
	effects.setup(settings.effects, settings.text)
	effects.card_position_provider = board.screen_position
	if setup: await setup.checkpoint(get_tree())
	hud = HUDView.new()
	add_child(hud)
	hud.bind(self)
	drawer_presentation = hud
	board.interaction_blocked = _drawer_input_blocked
	board.hover_blocked = func(): return hud.pointer_over_panels(board.pointer_position())
	table_hands = HandsView.new()
	add_child(table_hands)
	table_hands.bind(self)
	hud.resign_requested.connect(_resign)
	mine = hud.mine
	opponent = hud.opponent
	message = hud.message
	Palette.bus().changed.connect(_on_palette_changed)
	if setup: await setup.checkpoint(get_tree())
	if not saved.is_empty():
		replay.frames = saved.get("replay_frames", [])
		_active_config = ConfigData.bundled_path(str(saved.get("active_config", "")))
		await ShiftSession.restore_view(self, saved, setup)
		replay.record(self, [], true)
	elif not await _new_game(setup):
		get_tree().quit(1)
		return
	lan = preload("res://net/off_work_lan.gd").new()
	add_child(lan)
	lan.bind(self)
	get_window().files_dropped.connect(func(files: PackedStringArray):
		if can_process() and is_visible_in_tree(): hud.handle_card_config_files(files))
	if not playtest_hash.is_empty():
		LaunchConfig.report_playtest_ready("WORK_PLAYTEST_READY " + playtest_hash)
	if OS.has_environment("WORK_SHOT"):
		_shot_spec = OS.get_environment("WORK_SHOT").split(",")
	if setup: setup.finish(self)

func set_shift_hidden(hidden: bool) -> void:
	_shift_hidden = hidden
	if is_instance_valid(hud): hud.set_off_work_finale_hidden(hidden)
	if hidden: _live_bot.cancel()
	if is_instance_valid(table_hands): table_hands.set_shift_hidden(hidden)
	if is_instance_valid(_effect_layer): _effect_layer.visible = not hidden
	if lan != null: lan.set_away(hidden)
	if not hidden and is_instance_valid(hud): hud._sync_pause()
	if hidden and is_instance_valid(board): board.cancel_pointer()
	var silent: bool = hidden or (hud.drawer_window != null and not hud.drawer_window.is_expanded())
	sfx.set_drawer_suspended(silent)
	audio.muted = silent or sfx.user_muted
	if hidden: audio.stop_all()

func _drawer_input_blocked() -> bool:
	return replay.playing or get_tree().paused or hud == null or (hud.drawer_window != null and (not hud.drawer_window.is_expanded() or hud.drawer_window.is_transitioning()))

func _setup_dismissal_facility() -> void:
	var facility := get_node("MarketFacility")
	for label in settings.dismiss_zone:
		facility.get_node(str(label)).text = str(settings.dismiss_zone[label])
	_setup_dismissal_illustration(facility)

func _setup_dismissal_illustration(facility: Node3D) -> void:
	var spec: Dictionary = settings.dismiss_illustration
	var plate := facility.get_node("PawnshopFacilityCard") as MeshInstance3D
	var material := plate.material_override as ShaderMaterial
	# The original full-card artwork contains a pawnshop balance and no alpha
	# blending. Keep its palette-driven frame, then overlay the new GPT cutout.
	material.set_shader_parameter("has_artwork", false)
	material.set_shader_parameter("artwork", null)
	facility.get_node("FacilityBadge").visible = bool(spec.show_category)
	var art := Sprite3D.new()
	art.name = "DismissalIllustration"
	art.texture = load(str(spec.texture))
	art.pixel_size = float(spec.width) / float(art.texture.get_width())
	art.rotation_degrees.x = -90.0
	art.position = Vector3(0.0, CardEntity.Y_ICON, float(spec.center_z))
	art.shaded = false
	art.double_sided = true
	art.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	art.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	facility.add_child(art)

func _on_palette_changed(_section: String, _key: String, _color: Color = Color.WHITE) -> void:
	_table_scene.refresh_palette()
	for card in board.by_uid.values() + board.offers_by_id.values():
		if is_instance_valid(card): card.refresh_palette()
	for presenter in [board, board.enemy_board]:
		for group in presenter.groups:
			presenter.refresh_group(group)
	effects.setup(settings.effects, settings.text)

func _on_groups_changed() -> void:
	_live_bot.replan(bot)
	if bot != null and not bot.is_started():
		var current := _capture_player_activity()
		var meaningful := false
		var old_members: Array = _player_activity_snapshot.get("groups", {}).values()
		for members in current.groups.values():
			if not old_members.has(members):
				meaningful = true
		for id in current.people:
			var previous_type := str(_player_activity_snapshot.get("people", {}).get(id, ""))
			var upgrade: Dictionary = state.config.coffee_upgrade(previous_type)
			if not upgrade.is_empty() and current.people[id] == str(upgrade.to):
				meaningful = true
		for id in current.tools:
			if current.tools[id] in ["active", "recovering"] and current.tools[id] != _player_activity_snapshot.get("tools", {}).get(id, "ready"):
				meaningful = true
		if meaningful: _start_opponent_after_action(int(board._settings.local_owner))
		_player_activity_snapshot = current
	board.sync_state(state)
	_update_hud()

func _capture_player_activity() -> Dictionary:
	var local_owner := int(board._settings.local_owner)
	var snapshot := {"groups": {}, "tools": {}, "people": {}}
	var membership: int = state.membership_version()
	if _activity_group_state != state.get_instance_id() or _activity_group_revision != state.revision or _activity_group_membership != membership:
		_activity_group_cache.clear()
		_activity_group_state = state.get_instance_id()
		_activity_group_revision = state.revision
		_activity_group_membership = membership
	for person in state.tasks:
		if not state.cards.has(person) or int(state.cards[person].owner) != local_owner: continue
		var gid := int(state.cards[person].group)
		if snapshot.groups.has(gid): continue
		if not _activity_group_cache.has(gid):
			var members: Array = state.group_cards(gid)
			members.sort()
			_activity_group_cache[gid] = members
		snapshot.groups[gid] = _activity_group_cache[gid]
	for id in state.activity_card_ids(local_owner):
		var card: Dictionary = state.cards[id]
		if state.config.is_person(str(card.type)):
			snapshot.people[id] = str(card.type)
		else:
			snapshot.tools[id] = str(card.status)
	return snapshot

func _remember_player_activity() -> void:
	if bot != null and not bot.is_started():
		_player_activity_snapshot = _capture_player_activity()

func _start_opponent_after_action(actor: int) -> void:
	if bot != null and actor == int(board._settings.local_owner) and actor != bot.owner:
		_live_bot.replan(bot)
		bot.start()

func shift_network_live() -> bool:
	return lan != null and lan.network_live()

func _resign() -> void:
	if lan != null and lan.live():
		lan.submit({"op": "resign"})
		return
	hud.set_manual_paused(false)
	state.resign(int(board._settings.local_owner))
	save_shift_session()
	_update_hud()

func _rematch() -> void:
	if not practice.is_empty():
		finish_practice()
		return
	if lan != null and lan.live(): lan.rematch()
	else:
		var result := apply_selected_card_config()
		if not result.ok: _notify(result.reason, true)

func _new_game(setup: RefCounted = null) -> bool:
	replay.reset()
	hud.reset_resign()
	_clear_table_presenters()
	state.new_game(randi())
	if not state.last_error.is_empty():
		push_error(state.last_error)
		return false
	hud.set_manual_paused(false)
	bot = Bot.new(state, int(state.config.rules.bot.owner))
	_player_activity_snapshot = _capture_player_activity()
	await board.sync_state(state, setup)
	_refresh_table_lighting()
	_update_hud()
	message.text = str(settings.text.hint)
	replay.record(self, [], true)
	if _shift_enabled: save_shift_session()
	return true

func _process(delta: float) -> void:
	if has_meta("shift_setup"): return
	if _shift_hidden or state == null or board == null or settings.is_empty(): return
	if not practice.is_empty() and hud.practice_reference_open(): return
	if replay.playing:
		_live_bot.cancel()
		replay.advance(self, delta)
		return
	if _shift_enabled:
		_shift_save_elapsed += delta
		if _shift_save_elapsed >= 5.0:
			_shift_save_elapsed = 0.0
			save_shift_session()
	if state.winner == -1 and (lan == null or not lan.live()):
		# Existing keyframes contain structural events through the previous
		# update. Unrecorded player input invalidates that observation.
		var frozen: Dictionary = {}
		if not replay.frames.is_empty() and replay.last_revision == state.revision and state._events.is_empty():
			frozen = replay.frames.back()
		var game_delta := delta if practice.is_empty() else lesson.clock_delta(state, delta)
		state.advance(game_delta)
		_live_bot.tick(bot, game_delta, frozen)
	else:
		_live_bot.cancel()
	var events: Array = state.drain_events()
	_cache_positions(events)
	replay.record(self, events, _live_bot.needs_keyframe)
	_refresh_age += delta
	if (state.winner == -1 and _refresh_age >= float(settings.hud.refresh_interval)) or not events.is_empty():
		_refresh_age = 0.0
		board.sync_state(state)
		_update_hud()
	for event in _coalesce_events(events):
		_present(event)
	audio.sync_work_groups(state, int(board._settings.local_owner))
	_message_age += delta
	if not practice.is_empty():
		var interaction := {}
		if board.side_extract.is_open():
			interaction = {"source_group": board.side_extract._group_id, "type": board.side_extract._kind, "inspected": true}
		if lesson.observe(state, events, interaction):
			practice_stage = lesson.step
			hud.update_practice_panel()
		if state.winner >= 0 and not _result_started:
			_result_started = true
			hud.update_practice_panel()
	elif _message_age > float(settings.hud.message_hold) and _selected_tool < 0:
		message.text = str(settings.text.hint)
	if state.winner != -1:
		_result_age += delta
		if _result_age >= float(settings.result.delay) and not _result_started:
			_result_started = true
			_show_result()
	_check_shot(delta)
	# Natural task/timer changes are never counted as a later player gesture.
	_remember_player_activity()

func _cache_positions(events: Array = []) -> void:
	# Effects need the previous position of their actual sources and targets,
	# not a projection of every buried sheet on every render frame. Capture
	# before sync_state retires/moves those views; newly created money resolves
	# from the board after that sync. The board retains retired world positions.
	_positions.clear()
	var ids := {}
	for event in events:
		for key in ["source", "person", "money_id"]:
			var id := int(event.get(key, -1))
			if id >= 0: ids[id] = true
		for id in event.get("targets", []): ids[int(id)] = true
	for id in ids:
		if board.by_uid.has(id) or board._previous_positions.has(id):
			_positions[id] = board.screen_position(id)

func _coalesce_events(events: Array) -> Array:
	# Simultaneous members of one transfer share a single visual batch. Their
	# real state was already committed; this only fans out the actual card nodes.
	var result: Array = []
	var batches: Dictionary = {}
	for event in events:
		if str(event.kind) != "transfer":
			result.append(event)
			continue
		var key := "%s/%s/%s" % [event.time, event.source, event.target_group]
		if batches.has(key):
			result[batches[key]].ids.append_array(event.ids)
		else:
			batches[key] = result.size()
			result.append(event.duplicate(true))
	return result

func _at(id: int, group := -1) -> Vector2:
	if _positions.has(id): return _positions[id]
	if board.by_uid.has(id) or board._previous_positions.has(id): return board.screen_position(id)
	if group >= 0:
		return board.camera.unproject_position(board.get_group_position(group))
	return get_viewport().get_visible_rect().size * 0.5

func _present(event: Dictionary) -> void:
	var kind: String = str(event.kind)
	if kind == "win":
		audio.stop_all()
		if practice.is_empty(): hud.begin_off_work_finale(int(state.winner))
		# 赢方响下班铃；输方先留白，泄气尾音留到加班章落定。
		if state.winner != 1: audio.play("win")
		elif not practice.is_empty(): audio.play("lose")
		if board.has_method("play_event"): board.play_event(event)
		return
	if kind in ["conveyor", "new_game"]: return
	var source: int = int(event.get("source", -1))
	var group: int = int(event.get("group", -1))
	var start := _at(source, group)
	var end := start
	var ids: Array = event.get("ids", [])
	var targets: Array = []
	for id in event.get("targets", []): targets.append(_at(int(id)))
	if kind == "work_complete":
		# 收入由 Board 移动真实现金卡；不再另画一枚飞向 HUD 的假金币。
		start = _at(source, group)
		end = _at(int(event.get("money_id", -1)), int(event.get("money_group", -1)))
	elif kind == "transfer":
		end = board.camera.unproject_position(board.get_group_position(int(event.get("target_group", -1))))
	elif kind == "strike":
		start = _at(-1, int(event.get("target_group", -1)))
	elif kind == "meeting_start":
		start = _at(source, group)
	elif kind == "coffee_upgrade":
		start = _at(int(event.get("person", -1)), group)
	elif kind == "outsource":
		end = Vector2(get_viewport().get_visible_rect().size.x, start.y)
	effects.emit_effect(kind, start, end, maxi(ids.size(), 1), targets,
		source if kind == "meeting_start" else -1, event.get("targets", []) if kind == "meeting_start" else [])
	if kind == "transfer":
		audio.schedule(kind, float(board._settings.transfer_motion.travel_seconds))
	elif kind != "work_complete" or int(event.owner) == int(board._settings.local_owner):
		audio.play(kind)
	if board.has_method("play_event"): board.play_event(event)

func _on_activate(id: int, target_group: int) -> void:
	if state.winner != -1 or not state.cards.has(id): return
	if str(state.cards[id].type) == "strike":
		_selected_tool = id
		board.set_targeting(true)
		_notify(str(settings.text.target))
		return
	_activate(id, target_group)

func _deliver_strike(id: int, group: int) -> void:
	_activate(id, group, -1, true)

func _activate(id: int, group: int, target_card := -1, delivered := false) -> void:
	if replay.playing: return
	if lan != null and lan.live():
		if delivered: board.await_manual_strike_ack(id)
		lan.submit({"op":"deliver_strike" if delivered else "activate", "id":id, "group":group, "target":target_card})
		return
	if get_tree().paused: return
	var actor := int(state.cards[id].owner) if state.cards.has(id) else -1
	var kind := str(state.cards[id].type) if state.cards.has(id) else ""
	var activated := false
	# A coffee handed to a visiting employee must still join that person's
	# authoritative group. It cannot upgrade someone across the table remotely.
	if not delivered and kind == "coffee" and str(state.cards[id].status) == "ready" and int(state.cards[id].group) != group \
			and state.cards.has(target_card) and int(state.cards[target_card].group) == group \
			and int(state.cards[target_card].owner) == actor \
			and not state.config.coffee_upgrade(str(state.cards[target_card].type)).is_empty():
		if state.move_cards([id], group, target_card) >= 0:
			activated = state.cards.has(id) and str(state.cards[id].status) == "active"
	if not activated:
		activated = state.deliver_strike(id, group) if delivered else state.activate(id, group, target_card)
	if not activated: _notify(_error_text(), true)
	else:
		# Involution is passive; its no-op activation on an idle pile is not play.
		var has_task := false
		for person in state.group_people(group):
			has_task = has_task or state.tasks.has(person)
		if kind != "overtime" or has_task: _start_opponent_after_action(actor)
		board.set_targeting(false)
		_message_age = float(settings.hud.message_hold)
	_remember_player_activity()
	_cache_positions(state._events)
	board.sync_state(state)
	_update_hud()

func _on_selected(id: int) -> void:
	if not state.cards.has(id): return
	if board.attack_mode and _selected_tool >= 0 and state.cards.has(_selected_tool) and str(state.cards[_selected_tool].type) == "strike" and int(state.cards[id].owner) == 1:
		_activate(_selected_tool, int(state.cards[id].group), id)
		return
	if int(state.cards[id].owner) == 0:
		_selected_tool = id if str(state.config.cards[state.cards[id].type].category) in ["tool", "ingredient"] else -1
		_update_hud()

func _on_buy(offer_id: int) -> void:
	if replay.playing: return
	if lan != null and lan.live():
		lan.submit({"op":"buy", "id":offer_id, "ids":board.purchase_payment_ids})
		return
	if state.winner != -1: return
	var id: int = state.buy(offer_id, 0, board.purchase_payment_ids)
	if id < 0: _notify(_error_text(), true)
	else:
		_start_opponent_after_action(int(state.cards[id].owner))
		_notify(str(settings.text.buy_ok) % str(state.config.cards[state.cards[id].type].name))
	_remember_player_activity()
	board.sync_state(state)
	_update_hud()

func _on_dismiss(ids: Array) -> void:
	if replay.playing: return
	if lan != null and lan.live():
		lan.submit({"op":"dismiss", "ids":ids})
		return
	if state.winner != -1: return
	var owner := int(board._settings.local_owner)
	var before: int = state.money(owner)
	if state.dismiss_people(ids, owner):
		_start_opponent_after_action(owner)
		_notify(str(settings.text.dismiss_ok) % [ids.size(), state.money(owner) - before])
	else:
		_notify(_error_text(), true)
	_remember_player_activity()
	_update_hud()

func _error_text() -> String:
	return state.last_error if not state.last_error.is_empty() else str(settings.text.action_fail)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F5:
		save_work_replay()
	if _selected_tool >= 0 and ((event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE) or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)):
		_selected_tool = -1
		board.set_targeting(false)
		_update_hud()
		message.text = str(settings.text.hint)

func _notify(text: String, deny := false) -> void:
	hud.present_message(text, Palette.semantic("danger") if deny else Palette.semantic("ink"))
	_message_age = 0.0
	if deny: audio.play("deny")

func _update_hud() -> void:
	if _selected_tool >= 0 and not state.cards.has(_selected_tool): _selected_tool = -1
	if hud == null: return
	hud.refresh(state, _selected_tool)

func _show_result() -> void:
	if state.winner in [0, 1] and replay.result_taunt.is_empty():
		replay.result_taunt = hud.draw_result_taunt(state.winner)
		save_shift_session()
	result_layer = hud.show_result(state.winner, state.work_count(0), _rematch, replay.result_taunt)

func _check_shot(delta: float) -> void:
	if _shot_spec.is_empty() or _shot_pending: return
	_shot_elapsed += delta
	if _shot_spec.size() < 2 or _shot_elapsed < float(_shot_spec[1]): return
	_shot_pending = true
	_save_shot.call_deferred()

func _save_shot() -> void:
	hud.set_process(false)
	hud._detail.hide()
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_shot_spec[0].get_base_dir())
	var error := image.save_png(_shot_spec[0])
	print("WORK_SHOT ", _shot_spec[0], " result=", error)
	get_tree().quit(0 if error == OK else 1)


func save_work_replay() -> void:
	if not practice.is_empty():
		_notify("练习结束后可保存正式对局录像")
		return
	var path := replay.save(self)
	var count: int = replay.playback.size() if replay.playing else replay.frames.size()
	hud.show_record_result(ProjectSettings.globalize_path(path) if not path.is_empty() else SavePaths.recordings_dir(), count, path.is_empty())

func open_replay_picker() -> void:
	if not practice.is_empty() or shift_network_live() or replay.playing:
		_notify("请先结束练习、录像或联机对局", true)
		return
	if is_instance_valid(_replay_picker):
		_replay_picker.show()
		return
	var picker := preload("res://scenes/replay_picker.gd").new()
	_replay_picker = picker
	picker.bind(self)
	add_child(picker)
	picker.file_selected.connect(func(_path): picker.queue_free())

func _load_replay(path: String) -> Dictionary:
	if not practice.is_empty(): return {"ok": false, "reason": "请先结束练习"}
	return replay.begin(self, path)

func stop_replay() -> void:
	replay.end(self)

func _read_card_config(path: String) -> Dictionary:
	if path == "": return {"ok": true, "config": OffWorkConfig.new()}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file: return {"ok": false, "reason": "无法打开 " + path}
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary: return {"ok": false, "reason": "文件不是有效的卡表"}
	var config := OffWorkConfig.new(data)
	if not config.errors.is_empty(): return {"ok": false, "reason": "\n".join(config.errors)}
	return {"ok": true, "config": config}

func card_config_info() -> Dictionary:
	return {"selected": _launch_config if _launch_config != "" else _selected_config, "active": _active_config,
		"pending": _selected_config != _active_config, "network_locked": shift_network_live(),
		"launch_locked": _launch_config != "", "replay_locked": replay.playing, "practice_locked": not practice.is_empty(),
		"filename": OffWorkConfig.FILES.cards.get_file(), "description": "可以选用自定义下班卡表。联机双方使用同一份配置；新选择从下一局生效。"}

func choose_card_config(path: String) -> Dictionary:
	if not practice.is_empty() or replay.playing or shift_network_live() or _launch_config != "":
		return {"ok": false, "reason": "当前对局已锁定卡表"}
	path = ConfigData.bundled_path(path)
	var check := _read_card_config(path)
	if not check.ok: return check
	if not JsonStore.save(SavePaths.settings_file("work_card_selection.json"), path):
		return {"ok": false, "reason": "保存卡表选择失败"}
	_selected_config = path
	return {"ok": true, "path": path, "reason": "已选择，下一局生效"}

func apply_selected_card_config() -> Dictionary:
	if not practice.is_empty() or replay.playing or shift_network_live(): return {"ok": false, "reason": "当前对局已锁定卡表"}
	var path := _selected_config if _launch_config.is_empty() else _launch_config
	var check := _read_card_config(path)
	if not check.ok: return check
	var selection := BotPreferences.selection_snapshot()
	# A rematch changes the card table, not the user's active BOT settings.
	check.config.rules.bot = state.config.rules.bot.duplicate(true)
	check.config.bot_preferences = state.config.bot_preferences.duplicate(true)
	state.config = check.config
	_active_config = path
	_use_table_config(check.config, selection)
	_new_game()
	return {"ok": true, "reason": "已使用所选卡表开局"}

func _use_table_config(config: OffWorkConfig, selection: Dictionary = {}) -> void:
	BotPreferences.bind(state, config.bot_preferences, selection)
	_live_bot.bind_config(config)
	OffWorkCardDB.configure(config)
	var slots := int(config.rules.conveyor.slots)
	if slots == _table_scene.market_count: return
	conveyor.reset()
	remove_child(conveyor)
	conveyor.queue_free()
	for node in get_children():
		if str(node.name).begins_with("MarketSlot_") or node.name in ["TableSurface_market", "MarketFacilityDivider", "MarketFacility"]:
			remove_child(node)
			node.queue_free()
	_table_scene.market_count = slots
	_table_scene._add_market_tray()
	_table_scene._add_market_slot_frames()
	_table_scene._setup_pawnshop_card()
	_setup_dismissal_facility()
	board.pawn_pos = _table_scene._pawn_position()
	conveyor = ConveyorView.new()
	add_child(conveyor)
	conveyor.setup(board, self)

func park_table() -> Dictionary:
	save_shift_session()
	var layout := {}
	for key in ShiftSession.BOARD_FIELDS: layout[key] = board.get(key).duplicate(true)
	var original := {"state": state, "bot": bot, "layout": layout, "paused": hud._manual_paused, "selected": _selected_tool,
		"bot_preferences": BotPreferences.selection_snapshot()}
	_clear_table_presenters()
	return original

func _clear_table_presenters() -> void:
	_live_bot.cancel()
	hud.set_manual_paused(false)
	hud.clear_result()
	result_layer = null
	_result_started = false
	_result_age = 0
	_selected_tool = -1
	_positions.clear()
	_activity_group_cache.clear()
	_activity_group_revision = -1
	_activity_group_membership = -1
	_activity_group_state = 0
	table_hands.clear()
	effects.clear()
	audio.stop_all()
	conveyor.reset()
	board.reset_view()
	_refresh_table_lighting()

func _refresh_table_lighting() -> void:
	for layer in get_children():
		if layer is TableLighting: layer.refresh()

func restore_table(original: Dictionary) -> void:
	_clear_table_presenters()
	state = original.state
	bot = original.bot
	_use_table_config(state.config, original.get("bot_preferences", {}))
	_selected_tool = original.selected
	for key in ShiftSession.BOARD_FIELDS: board.set(key, original.layout[key])
	board.sync_state(state)
	_refresh_table_lighting()
	_remember_player_activity()
	hud.reset_resign()
	hud.set_manual_paused(original.paused)
	_update_hud()
	if state.winner >= 0:
		_result_started = true
		_show_result()

func begin_practice(id := "first") -> void:
	if shift_network_live() or replay.playing: return
	if not lesson.start(id): return
	if hud.is_learning_invitation_open(): hud._dismiss_learning_invitation("tutorial")
	hud.close_panels()
	if practice.is_empty():
		practice = park_table()
		practice["replay"] = replay
		replay = replay.get_script().new()
	practice_stage = 0
	var config: OffWorkConfig = lesson.make_config()
	state = State.new(config)
	_use_table_config(config)
	_new_game()
	lesson.setup_world(state)
	board.sync_state(state)
	_refresh_table_lighting()
	hud.update_practice_panel()

func demonstrate_practice_step() -> void:
	if practice.is_empty(): return
	if not lesson.complete() and lesson.lesson.steps[lesson.step][0] == "inspect_type":
		if board.side_extract.open_group(lesson.source_group(), "employee"):
			lesson.used_demo = true
			preload("res://engine/tutorial_progress.gd").record(lesson.lesson.id, lesson.step, "viewed", true)
		return
	if lesson.demonstrate(state):
		board.sync_state(state)
		hud.update_practice_panel()
	else:
		_notify("当前牌桌无法演示这一步，可点「重练」恢复本课起点。", true)

func finish_practice() -> void:
	if practice.is_empty(): return
	var original := practice
	practice = {}
	hud.update_practice_panel()
	replay = original.replay
	restore_table(original)
	message.text = str(settings.text.hint)
