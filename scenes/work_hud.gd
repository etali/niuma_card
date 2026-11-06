# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://scenes/drawer_presentation.gd"

## New rules adapter for the actual niuma_card DrawerPresentation.
## Reuses the original typography, icons, panels and camera fitting; the footer
## retains the same construction with only the actions used by this game.
signal resign_requested
var _resign_timer: Timer
class RealtimeDrawerWindow extends DrawerWindow:
	# Keep the original pointer, focus, dragging and edge-attachment input. Escape
	# first belongs to the HUD (close a panel / cancel targeting), then folds.
	func _input(event: InputEvent) -> void:
		if event is InputEventKey and event.keycode == KEY_ESCAPE: return
		super._input(event)
const BotPreferences = preload("res://engine/work_bot_preferences.gd")
const ResourceView = preload("res://scenes/resource_hud.gd")
const LogView = preload("res://scenes/msg_log.gd")
const ColorView = preload("res://scenes/palette_panel.gd")
const BotView = preload("res://scenes/bot_panel.gd")
var host: Node
var board: Node
var state: RefCounted
var sfx: Node
var hud_config: Dictionary
var drawer_window: Node = null
var drawer_ui_scale := 1.0
var mobile_mode := false
var table_hud: CanvasLayer
var msg_log: CanvasLayer
var save_notice: CanvasLayer = null
var lbl_round: Label
var lbl_player_res: Label
var lbl_bot_res: Label
var lbl_msg: Label
var btn_net: Button
var btn_save: Button
var btn_resign: Button
var btn_pass: Button # Unused original-main compatibility slot for refresh_button_roles.
var btn_pause: Button
var _replay_time: HSlider
var mine: Label
var opponent: Label
var message: Label
var result_layer: CanvasLayer
var _palette_revision := 0
var _drawer_owns_pause := false
var _drawer_suspended := false
var _manual_paused := false
var _fixed_view := false
var _snap_hit_slider: HSlider
var _snap_hit_value: Label

func bind(game: Node) -> void:
	host = game
	mobile_mode = game.mobile_mode
	board = game.board
	state = game.state
	sfx = game.sfx
	hud_config = UIConfig.read_section("hud")
	_main = self
	_setup_window_controller()
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 4
	name = "DrawerPresentation"
	_viewport_pixels = get_viewport().get_visible_rect().size
	_last_size = _viewport_pixels
	BotPreferences.bind(state, state.config.bot_preferences)
	_setup_source_controls()
	board.table_bounds = WORLD_RECT
	board.player_bounds = PLAYER_RECT
	board.player_min_z = PLAYER_RECT.position.y
	board.player_max_z = PLAYER_RECT.end.y
	board.hover_description_enabled = false
	_build_header()
	_build_debug_option()
	lbl_round.minimum_size_changed.connect(_sync_header_status)
	_sync_header_status()
	_build_footer()
	_build_utility()
	_build_details()
	if drawer_window != null: _bind_window_handle()
	mine = lbl_player_res
	opponent = lbl_bot_res
	message = lbl_msg
	for panel in [_header, _footer, _detail, table_hud]: _guard_table_panel(panel, false)
	for panel in [_utility, msg_log]: _guard_table_panel(panel, true)
	sfx.user_muted_changed.connect(func(muted: bool): host.audio.muted = muted)
	host.audio.muted = sfx.user_muted
	Palette.bus().changed.connect(_on_palette_changed)
	get_viewport().size_changed.connect(_on_size_changed)
	refresh(state, -1)
	relayout()
	call_deferred("relayout")
	if not game.get_meta("shift_enter_expanded",false) and drawer_window != null and not _fixed_view and not bool(hud_config.drawer.start_expanded):
		_start_drawer.call_deferred()

func _start_drawer() -> void:
	# Same startup as niuma_card: build the full table, prewarm the native view,
	# then expose only the original mascot. No simulation runs behind this entry.
	_pause_drawer(true)
	drawer_window.start_collapsed(bool(hud_config.drawer.prewarm_on_start))

func _sync_header_status() -> void:
	if not is_instance_valid(lbl_round) or not is_instance_valid(_title_row): return
	var show_status := not lbl_round.text.strip_edges().is_empty()
	var in_header := lbl_round.get_parent() == _title_row
	lbl_round.visible = show_status
	if show_status == in_header: return
	# No empty status node in the HBox: the original header counts its children
	# when reserving gaps. Explicit demonstration captions can still opt in.
	lbl_round.reparent(_title_row if show_status else self)
	if show_status: _title_row.move_child(lbl_round, 2)
	relayout.call_deferred()

func _setup_source_controls() -> void:
	# Original main._setup_res_panel creates these controls before DrawerPresentation
	# adopts the actual Label/Button instances into its header and footer.
	table_hud = CanvasLayer.new()
	table_hud.name = "TableHUD"
	add_child(table_hud)
	var old_panel := PanelContainer.new()
	old_panel.name = "ResPanel"
	table_hud.add_child(old_panel)
	var row := HBoxContainer.new()
	row.name = "ResourceHeaderRow"
	old_panel.add_child(row)
	lbl_round = _label(str(hud_config.live_status), 20)
	lbl_round.name = "RoundStatus"
	row.add_child(lbl_round)
	var player_card := ResourceView.new()
	player_card.card_catalog = WorkCardDB
	row.add_child(player_card)
	player_card.setup(str(hud_config.sides[0]), "player", true)
	lbl_player_res = player_card.summary
	var opponent_card := ResourceView.new()
	opponent_card.card_catalog = WorkCardDB
	row.add_child(opponent_card)
	opponent_card.setup(str(hud_config.sides[1]), "bot", true)
	lbl_bot_res = opponent_card.summary
	lbl_msg = _label("", 17)
	lbl_msg.name = "StatusMessage"
	row.add_child(lbl_msg)
	msg_log = LogView.new()
	msg_log.group_unit = "条"
	table_hud.add_child(msg_log)
	var palette := ColorView.new()
	table_hud.add_child(palette)
	var bot_panel := BotView.new()
	bot_panel.preferences = BotPreferences
	bot_panel.help_text = BotPreferences.help_text()
	bot_panel.above = palette
	table_hud.add_child(bot_panel)
	btn_net = _button("局域网对战")
	btn_save = _button("存录像")
	btn_resign = _button("认输")
	btn_resign.tooltip_text = "再次点击确认认输"
	_resign_timer = Timer.new()
	_resign_timer.one_shot = true
	_resign_timer.wait_time = 3.0
	add_child(_resign_timer)
	_resign_timer.timeout.connect(reset_resign)
	btn_resign.set_meta("ui_role", "danger")
	btn_resign.pressed.connect(_request_resign)
	for button in [btn_net, btn_save, btn_resign]: table_hud.add_child(button)

func reset_resign() -> void:
	_resign_timer.stop()
	btn_resign.text = "认输"
	btn_resign.set_meta("danger_armed", false)
	refresh_button_roles()

func _request_resign() -> void:
	if not host.practice.is_empty():
		host.finish_practice()
		return
	if host.replay != null and host.replay.playing:
		host.stop_replay()
		return
	if state.winner >= 0: return
	if _resign_timer.is_stopped():
		btn_resign.text = "确认认输"
		btn_resign.set_meta("danger_armed", true)
		refresh_button_roles()
		_resign_timer.start()
		return
	reset_resign()
	close_panels()
	resign_requested.emit()

func _build_mode_actions(row: HBoxContainer) -> void:
	_replay_time = HSlider.new()
	_replay_time.name = "ReplayTime"
	_replay_time.accessibility_name = "录像时间"
	_replay_time.custom_minimum_size = Vector2(100, 0)
	_replay_time.step = 0.1
	_replay_time.hide()
	_replay_time.value_changed.connect(func(value: float): host.replay.seek(host, value))
	row.add_child(_replay_time)
	_rulebook_button = _button("怎么玩")
	_rulebook_button.pressed.connect(_open_utility.bind(UTILITY_RULEBOOK))
	row.add_child(_rulebook_button)
	btn_pause = _button(str(hud_config.pause.label))
	btn_pause.name = "PauseButton"
	btn_pause.toggle_mode = true
	_style_primary_table_action(btn_pause)
	btn_pause.pressed.connect(func(): set_manual_paused(not _manual_paused))
	row.add_child(btn_pause)

func set_manual_paused(on: bool) -> void:
	if on and ((state.winner >= 0 and not host.replay.playing) or host.shift_network_live()): return
	_manual_paused = on
	_sync_pause()
	refresh(state, int(host.get("_selected_tool")))

func refresh(game_state: RefCounted, _selected_tool := -1) -> void:
	state = game_state
	_sync_header_status()
	for item in [[lbl_player_res, 0], [lbl_bot_res, 1]]:
		var label: Label = item[0]
		var owner: int = item[1]
		var reserved: int = state.reserved_money(owner)
		if reserved > 0:
			label.text = str(hud_config.resources_reserved) % [hud_config.sides[owner], state.work_count(owner), state.people_count(owner), state.available_money(owner), reserved]
			label.tooltip_text = str(hud_config.cash_reservation_help) % [state.money(owner), reserved, state.available_money(owner)]
		else:
			label.text = str(hud_config.resources) % [hud_config.sides[owner], state.work_count(owner), state.people_count(owner), state.money(owner)]
			label.tooltip_text = label.text
	btn_pause.disabled = (state.winner >= 0 and not host.replay.playing) or host.shift_network_live()
	_replay_time.visible = host.replay.playing
	_rulebook_button.visible = not host.replay.playing
	btn_resign.disabled = state.winner >= 0
	if host.replay != null and host.replay.playing:
		btn_resign.disabled = false
		btn_resign.text = "退出录像"
		_replay_time.min_value = host.replay.playback.front().t
		_replay_time.max_value = maxf(_replay_time.min_value, host.replay.playback.back().t)
		_replay_time.set_value_no_signal(host.replay.clock)
		lbl_msg.text = "录像  %d / %d 秒" % [host.replay.clock, _replay_time.max_value]
	elif not host.practice.is_empty():
		btn_resign.disabled = false
		btn_resign.text = "结束练习"
	btn_pause.set_pressed_no_signal(_manual_paused)
	btn_pause.text = str(hud_config.pause.resume if _manual_paused else hud_config.pause.label)
	btn_pause.tooltip_text = str(hud_config.pause.resume_help if _manual_paused else hud_config.pause.help)
	if _last_size.x > 300:
		_fit_header_width(_last_size.x - _px(PAD * 2))
		_header.position.x = roundf((_last_size.x - _header.size.x) * 0.5)

func present_message(text: String, color: Color) -> void:
	super.present_message(text, color)
	if is_instance_valid(msg_log): msg_log.append(text, color, msg_log.total() + 1)

func _show_message(text: String, color: Color) -> void:
	present_message(text, color)

func _process(_delta: float) -> void:
	if not is_instance_valid(host) or not is_instance_valid(board) or not is_instance_valid(_detail): return
	if _collapsed or _window_blocked():
		_detail.hide()
		return
	if get_viewport().get_visible_rect().size != _viewport_pixels: relayout()
	if _utility.visible and _utility.has_meta("source") and _utility.get_meta("source") == _bot:
		_utility_title.text = "BOT 强度 · %s" % _bot._slider_val.text
	var pointer: Vector2 = board.pointer_position()
	if pointer_over_panels(pointer) or not board._drag_cards.is_empty() or not content_rect().has_point(pointer) \
			or (board.side_extract != null and board.side_extract.is_open()):
		_detail.hide()
		return
	var card: CardEntity = board._pick_card(pointer)
	if card == null: _detail.hide()
	else: show_card_detail(card, pointer)

func _input(event: InputEvent) -> void:
	# 固定视口没有原生的 mouse_entered 通知，使用实际的视口指针位置。
	if _fixed_view and drawer_window != null and drawer_window.is_expanded() and event is InputEventMouseMotion:
		if get_viewport().get_visible_rect().has_point(event.position):
			drawer_window._on_mouse_entered()
		else:
			drawer_window._on_mouse_exited()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if board != null and board.side_extract != null and board.side_extract.is_open():
			board.side_extract.close()
			get_viewport().set_input_as_handled()
		elif panels_open():
			close_panels()
			get_viewport().set_input_as_handled()
		elif drawer_window != null and not bool(host.get("_selected_tool") >= 0):
			drawer_window.collapse_now()
			get_viewport().set_input_as_handled()

func show_card_detail(card: CardEntity, mouse: Vector2) -> void:
	var id := card.def_id
	if not state.config.cards.has(id): return
	var def: Dictionary = state.config.cards[id]
	if _detail_id != id or _detail_market != card.is_market:
		_detail_id = id
		_detail_market = card.is_market
		_detail_title.text = str(def.name)
		_detail_flavor.text = ""
		_detail_flavor.hide()
		_detail_text.text = str(WorkCardDB.get_def(id).description)
		for child in _detail_facts.get_children():
			_detail_facts.remove_child(child)
			child.queue_free()
		if card.is_market and state.config.can_purchase(id): _detail_fact("购买", "%d 金钱" % int(def.price))
	_detail_status.text = ("购买后拖入牌组" if state.config.can_purchase(id) else str(hud_config.unpurchasable)) if card.is_market else card.recipe_status_text()
	if id == "money" and not card.is_market and state.reserved_cash_amount(card.uid) > 0:
		_detail_status.text = str(hud_config.cash_reservation_status) % [state.available_cash_amount(card.uid), state.reserved_cash_amount(card.uid)]
	_detail_status.visible = _detail_status.text != ""
	_place_detail(mouse)

func _build_debug_option() -> void:
	var popup := _menu.get_popup()
	popup.add_check_item(str(hud_config.debug_mode.label), int(hud_config.debug_mode.menu_id))
	popup.about_to_popup.connect(_refresh_debug_option)
	_refresh_debug_option()

func _refresh_debug_option() -> void:
	var popup := _menu.get_popup()
	popup.set_item_checked(popup.get_item_index(int(hud_config.debug_mode.menu_id)), board.get_debug_mode())

func _open_utility(id: int) -> void:
	if id == UTILITY_ROLE: return
	if id == 1 and (host.shift_network_live() or host.replay.playing or not host.practice.is_empty()):
		host._notify("BOT 强度在单机对局中调整")
		return
	if id == UTILITY_RULEBOOK:
		close_panels()
		_active_utility_id = id
		_utility_title.text = "下班 · 游戏说明"
		_utility_body.add_child(_work_paragraph("先清空全部工作的一方下班。把员工拖到工作牌上开始处理，完成工作可获得现金。把现金拖到购牌区购买新牌，或把人员拖到开除区换回现金。"))
		var learn := _button("在牌桌上练习")
		learn.name = "PracticeWork"
		learn.disabled = not host.practice.is_empty() or host.replay.playing or host.shift_network_live()
		learn.pressed.connect(host.begin_practice)
		_utility_body.add_child(learn)
		for kind in state.config.cards:
			var def: Dictionary = state.config.cards[kind]
			_utility_body.add_child(_label(str(def.name), UI_FONT_TITLE))
			_utility_body.add_child(_work_paragraph(str(WorkCardDB.get_def(kind).description)))
		_show_utility_content()
		return
	if id == int(hud_config.debug_mode.menu_id):
		if not board.set_debug_mode(not board.get_debug_mode(), true):
			host._notify(str(hud_config.debug_mode.save_failed))
		_refresh_debug_option()
		return
	super._open_utility(id)
	if id in [0, int(hud_config.snap_distance.ui_page_id)] and _active_utility_id == int(hud_config.snap_distance.ui_page_id):
		_add_snap_distance_control()

func _add_snap_distance_control() -> void:
	# Mount inside the inherited UI page, before animation and camera controls.
	# Keep the original utility, scrolling, palette and common footer intact.
	var section := VBoxContainer.new()
	section.name = "SnapDistanceControls"
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_utility_body.add_child(section)
	var insertion := _hover_speed_slider.get_index() - 1 if is_instance_valid(_hover_speed_slider) else 0
	_utility_body.move_child(section, maxi(0, insertion))
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(row)
	var title := _label(str(hud_config.snap_distance.label))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	_snap_hit_value = _label("")
	_snap_hit_value.name = "SnapHitRegionValue"
	row.add_child(_snap_hit_value)
	var control: Dictionary = board._settings.snapping
	_snap_hit_slider = HSlider.new()
	_snap_hit_slider.name = "SnapHitRegion"
	_snap_hit_slider.min_value = float(control.min_hit_fraction) * 100.0
	_snap_hit_slider.max_value = float(control.max_hit_fraction) * 100.0
	_snap_hit_slider.step = float(control.step) * 100.0
	_snap_hit_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_snap_hit_slider.custom_minimum_size = Vector2(float(hud_config.content_width), UI_BUTTON_MIN.y)
	_snap_hit_slider.accessibility_name = str(hud_config.snap_distance.label)
	_snap_hit_slider.tooltip_text = str(hud_config.snap_distance.help)
	_snap_hit_slider.value_changed.connect(_set_snap_hit_percent)
	section.add_child(_snap_hit_slider)
	section.add_child(_work_paragraph(str(hud_config.snap_distance.help)))
	_refresh_snap_hit_control()
	_apply_tree_theme(section)
	_relayout_utility()

func _set_snap_hit_percent(percent: float) -> void:
	board.set_snap_hit_fraction(percent / 100.0)
	_refresh_snap_hit_control()
	_ui_status.text = str(hud_config.snap_distance.live_help)

func _refresh_snap_hit_control() -> void:
	var percent: float = board.get_snap_hit_fraction() * 100.0
	if is_instance_valid(_snap_hit_slider): _snap_hit_slider.set_value_no_signal(percent)
	if is_instance_valid(_snap_hit_value): _snap_hit_value.text = "%d%%" % roundi(percent)

func _save_ui_settings() -> void:
	super._save_ui_settings()
	if _active_utility_id != int(hud_config.snap_distance.ui_page_id): return
	var display_saved: bool = _ui_status.text == str(hud_config.snap_distance.saved)
	var snap_saved: bool = board.save_interaction_preferences()
	_ui_status.text = str(hud_config.snap_distance.saved if display_saved and snap_saved else hud_config.snap_distance.save_failed)

func _reset_ui_settings() -> void:
	var reset_snap := _active_utility_id == int(hud_config.snap_distance.ui_page_id)
	var snap_saved: bool = board.reset_interaction_preferences() if reset_snap else true
	# The inherited reset rebuilds the whole UI page, including this live slider.
	super._reset_ui_settings()
	if reset_snap:
		_refresh_snap_hit_control()
		_ui_status.text = str(hud_config.snap_distance.restored if snap_saved else hud_config.snap_distance.save_failed)

func _work_paragraph(text: String) -> Label:
	var label := _label(text)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Original _apply_tree_theme scales drawer_min_base. Store logical pixels here;
	# pre-scaling with _px applies Retina scale twice and pushes Close off screen.
	label.custom_minimum_size.x = float(hud_config.content_width)
	return label

func _show_utility_content() -> void:
	_utility.show()
	_apply_tree_theme(_utility)
	_relayout_utility()

func open_replay_picker() -> void: host.open_replay_picker()
func _open_join_panel() -> void:
	if host.replay.playing or not host.practice.is_empty():
		host._notify("请先退出录像或结束练习", true)
		return
	host.lan.open_panel()

func _save_replay() -> void: host.save_work_replay()
func card_config_info() -> Dictionary: return host.card_config_info()
func choose_card_config(path: String) -> Dictionary: return host.choose_card_config(path)
func clear_card_config() -> Dictionary: return host.choose_card_config("")
func apply_selected_card_config() -> Dictionary: return host.apply_selected_card_config()

func _on_palette_changed(_section: String = "", _key: String = "", _color: Color = Color.WHITE) -> void:
	_palette_revision += 1
	relayout()

func show_result(winner: int, work_left: int, restart: Callable) -> CanvasLayer:
	clear_result()
	close_panels()
	result_layer = CanvasLayer.new()
	result_layer.layer = 10
	host.add_child(result_layer)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result_layer.add_child(center)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", _style(Palette.get_color("world", "table_frame"), int(hud_config.result.margin)))
	center.add_child(frame)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", int(hud_config.result.gap))
	frame.add_child(column)
	var title := _label(str(hud_config.result.win) if winner == 0 else (str(hud_config.result.tie) if winner == 2 else str(hud_config.result.lose)), int(hud_config.result.title_font))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var summary := _label(str(hud_config.result.complete) if work_left == 0 else str(hud_config.result.remaining) % work_left)
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(summary)
	var again := _button(str(hud_config.restart))
	again.set_meta("ui_role", "primary")
	again.pressed.connect(restart)
	column.add_child(again)
	register_result_panel(result_layer)
	return result_layer

func clear_result() -> void:
	if is_instance_valid(result_layer):
		result_layer.get_parent().remove_child(result_layer)
		result_layer.queue_free()
	result_layer = null

func _setup_window_controller() -> void:
	if mobile_mode:
		_fixed_view = true
		get_window().content_scale_size = Vector2i.ZERO
		get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		get_window().transparent = false
		get_window().transparent_bg = false
		if OS.has_feature("android"): DisplayServer.screen_set_orientation(DisplayServer.SCREEN_LANDSCAPE)
		return
	if not bool(hud_config.drawer.enabled): return
	drawer_window = RealtimeDrawerWindow.new()
	drawer_window.name = "DrawerWindow"
	add_child(drawer_window)
	drawer_window.animations_enabled = bool(hud_config.drawer.animations_enabled)
	drawer_window.can_collapse = func():
		return board._drag_cards.is_empty() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	_fixed_view = DisplayServer.get_name() == "headless" or OS.has_environment("WORK_SHOT") or OS.has_environment("WORK_UI_TEST")
	drawer_ui_scale = drawer_window.setup_table_window(_fixed_view, drawer_ui_scale)
	_ui_scale = drawer_ui_scale
	drawer_window.set_pinned(bool(hud_config.drawer.start_pinned) or _fixed_view)
	# Geometry-only fixtures have no native window origin. Their mascot already
	# delegates pointer press/move/release to the original controller; its global
	# input bridge is needed only for the actual desktop window.
	drawer_window.set_process_input(not _fixed_view)
	drawer_window.transition_started.connect(func(expanded: bool):
		if not expanded:
			suspend_panels()
			_pause_drawer(true))
	drawer_window.expanded_changed.connect(func(expanded: bool):
		set_collapsed(not expanded)
		sfx.set_drawer_suspended(not expanded)
		host.audio.muted = sfx.user_muted or not expanded
		if not expanded: host.audio.stop_all())
	drawer_window.transition_finished.connect(func(expanded: bool):
		if expanded:
			set_collapsed(false)
			relayout()
		_pause_drawer(not expanded))

func _pause_drawer(suspended: bool) -> void:
	_drawer_suspended = suspended and bool(hud_config.drawer.pause_when_collapsed)
	_sync_pause()
	if is_instance_valid(btn_pause): refresh(state, int(host.get("_selected_tool")))

func _sync_pause() -> void:
	if host._shift_hidden: return
	# A manual pause survives folding/reopening. Release only the pause owned
	# by this HUD, so another scene's pause cannot be accidentally cleared.
	var suspended: bool = (_manual_paused or _drawer_suspended) and not host.shift_network_live()
	if suspended and not get_tree().paused:
		if is_instance_valid(board): board.cancel_pointer()
		_drawer_owns_pause = true
		get_tree().paused = true
	elif not suspended and _drawer_owns_pause:
		_drawer_owns_pause = false
		get_tree().paused = false

func set_collapsed(collapsed: bool) -> void:
	_collapsed = collapsed
	_table_ui_suspended = collapsed
	# Pausing freezes the event canvas, but does not hide its last draw commands.
	# Keep tabletop lines/impacts out of the transparent mascot window and resume
	# the same effects (and their saved ages) when the drawer opens again.
	if is_instance_valid(host.effects): host.effects.visible = not collapsed
	_header.visible = not collapsed
	_footer.visible = not collapsed
	_detail.hide()
	if is_instance_valid(_handle):
		_handle.visible = collapsed
		_handle.position = Vector2.ZERO
	if collapsed: suspend_panels()
	else: resume_panels()

func _exit_tree() -> void:
	if _drawer_owns_pause and get_tree() != null: get_tree().paused = false
