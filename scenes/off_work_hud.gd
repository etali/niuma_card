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
const BotPreferences = preload("res://engine/off_work_bot_preferences.gd")
const ResourceView = preload("res://scenes/resource_hud.gd")
const LogView = preload("res://scenes/msg_log.gd")
const ColorView = preload("res://scenes/palette_panel.gd")
const BotView = preload("res://scenes/bot_panel.gd")
const OffWorkResultFx = preload("res://scenes/off_work_result_fx.gd")
const OffWorkResultHero = preload("res://scenes/off_work_result_hero.gd")
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
var _replay_speed: OptionButton
var mine: Label
var opponent: Label
var message: Label
var result_layer: CanvasLayer
var _off_work_finale_layer: CanvasLayer
var _off_work_finale: Control
var _off_work_result_animation: Tween
var _practice_panel: PanelContainer
var _practice_gesture: WorkLessonGesture

class WorkLessonGesture extends "res://scenes/tutorial_gesture.gd":
	var hud: CanvasLayer

	func active() -> bool:
		return is_instance_valid(hud) and hud.is_visible() and hud.host.is_visible_in_tree() and not hud.host.practice.is_empty() \
			and not hud._collapsed and not hud._utility.visible and hud.board._drag_cards.is_empty() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	func anchor(node: Node) -> Vector2:
		if node == hud.board.side_extract.view:
			return node.screen_point_for_index(0)
		if node is Control: return node.get_global_rect().get_center()
		return hud.board.camera.unproject_position(node.global_position)

	func source_rect(node: Node) -> Rect2:
		if node == hud.board.side_extract.view:
			return node._card_rects.get(0, Rect2())
		return super.source_rect(node)

	func world_anchor(at: Vector3) -> Vector2:
		return hud.board.camera.unproject_position(at)

	func presentation_factor() -> float:
		return maxf(0.8, hud._responsive_factor())
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
	_invitation_offered = TutorialProgress.invitation_seen(true)
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
	player_card.card_catalog = OffWorkCardDB
	row.add_child(player_card)
	player_card.setup(str(hud_config.sides[0]), "player", true)
	lbl_player_res = player_card.summary
	var opponent_card := ResourceView.new()
	opponent_card.card_catalog = OffWorkCardDB
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
	btn_save.pressed.connect(_save_replay)
	save_notice = SaveNotice.new()
	save_notice.count_unit = "个关键帧"
	add_child(save_notice)
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
	_replay_time.custom_minimum_size = Vector2(240, 36)
	_replay_time.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_replay_time.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replay_time.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_replay_time.step = 0.1
	_replay_time.hide()
	_replay_time.value_changed.connect(func(value: float): host.replay.seek(host, value))
	row.add_child(_replay_time)
	_replay_speed = OptionButton.new()
	_replay_speed.name = "ReplaySpeed"
	_replay_speed.custom_minimum_size = Vector2(88, 38)
	_replay_speed.tooltip_text = "录像播放速度"
	for speed in host.replay.SPEEDS:
		_replay_speed.add_item("%s×" % str(speed).trim_suffix(".0"))
		_replay_speed.set_item_metadata(_replay_speed.item_count - 1, speed)
	_replay_speed.select(host.replay.SPEEDS.find(1.0))
	_replay_speed.item_selected.connect(func(index: int): host.replay.set_speed(float(_replay_speed.get_item_metadata(index))))
	_replay_speed.hide()
	row.add_child(_replay_speed)
	_rulebook_button = _button("怎么玩")
	_rulebook_button.pressed.connect(_open_utility.bind(UTILITY_RULEBOOK))
	row.add_child(_rulebook_button)
	btn_pause = _button(str(hud_config.pause.label))
	btn_pause.name = "PauseButton"
	btn_pause.toggle_mode = true
	_style_primary_table_action(btn_pause)
	btn_pause.pressed.connect(func(): set_manual_paused(not _manual_paused))
	row.add_child(btn_pause)

func _apply_tree_theme(control: Control) -> void:
	super._apply_tree_theme(control)
	if control == _replay_speed:
		_replay_speed.accessibility_name = "录像播放速度"
	if control != _replay_time or not is_instance_valid(_replay_time): return
	var ink := Palette.get_color("card", "frame")
	var gold := Palette.plate_color("plate_cash", "band")
	for entry in [["slider", Palette.get_color("world", "background")], ["grabber_area", gold], ["grabber_area_highlight", Palette.plate_color("plate_cash", "face")]]:
		var track := _style(entry[1], 0)
		track.content_margin_top = _px(13)
		track.content_margin_bottom = _px(13)
		_replay_time.add_theme_stylebox_override(entry[0], track)
	for entry in [["grabber", gold], ["grabber_highlight", Palette.plate_color("plate_cash", "face")], ["grabber_disabled", Palette.semantic("disabled")]]:
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="34" viewBox="0 0 24 34"><rect x="1" y="1" width="22" height="32" rx="8" fill="#%s" stroke="#%s" stroke-width="2"/><path d="M9 12v10M15 12v10" stroke="#%s" stroke-width="2" stroke-linecap="round"/></svg>' % [entry[1].to_html(false), ink.to_html(false), ink.to_html(false)]
		var image := Image.new()
		image.load_svg_from_string(svg, _responsive_factor())
		_replay_time.add_theme_icon_override(entry[0], ImageTexture.create_from_image(image))
	_replay_time.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, 0, 2, Palette.semantic("focus")))

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
	_replay_speed.visible = host.replay.playing
	_rulebook_button.visible = not host.replay.playing
	btn_resign.disabled = state.winner >= 0
	if host.replay != null and host.replay.playing:
		btn_resign.disabled = false
		btn_resign.text = "退出录像"
		_replay_time.min_value = host.replay.playback.front().t
		_replay_time.max_value = maxf(_replay_time.min_value, host.replay.playback.back().t)
		_replay_time.set_value_no_signal(host.replay.clock)
		_replay_speed.select(host.replay.SPEEDS.find(host.replay.speed))
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
	if host._shift_enabled and not host._shift_hidden:
		_offer_learning_invitation()
	if is_instance_valid(_practice_panel):
		_practice_panel.visible = not _utility.visible
		if is_instance_valid(_practice_gesture) and not host.lesson.complete():
			var target: String = host.lesson.lesson.steps[host.lesson.step][0]
			if target in ["inspect_type", "extract_type", "transfer_start", "transfer_resume", "separate_worker"]:
				_practice_gesture.set_cue(_lesson_cue(target))
		_position_practice_panel()
	if _utility.visible and _utility.has_meta("source") and _utility.get_meta("source") == _bot:
		_utility_title.text = "BOT 强度 · %s" % _bot._slider_val.text
	if _preview_detail_source != null:
		var source: Control = _preview_detail_source.get_ref()
		var preview: CardEntity = _preview_detail_card.get_ref() if _preview_detail_card != null else null
		var preview_pointer := get_viewport().get_mouse_position()
		if is_instance_valid(source) and is_instance_valid(preview) and _preview_contains_pointer(source, preview_pointer):
			show_card_detail(preview, preview_pointer)
			return
		hide_preview_card_detail()
	var pointer: Vector2 = board.pointer_position()
	if pointer_over_panels(pointer) or not board._drag_cards.is_empty() or not content_rect().has_point(pointer) \
			or (board.side_extract != null and board.side_extract.is_open()):
		_detail.hide()
		return
	var card: CardEntity = board._pick_card(pointer)
	if card == null: _detail.hide()
	else: show_card_detail(card, pointer)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F5 and host.is_visible_in_tree():
		_save_replay()
		get_viewport().set_input_as_handled()
		return
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
		elif is_learning_invitation_open():
			_dismiss_learning_invitation("skip")
			get_viewport().set_input_as_handled()
		elif not host.practice.is_empty():
			host.finish_practice()
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
		_detail_text.text = str(OffWorkCardDB.get_def(id).description)
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
	if is_learning_invitation_open(): _dismiss_learning_invitation("skip")
	if id == UTILITY_ROLE: return
	if id == 1 and (host.shift_network_live() or host.replay.playing or not host.practice.is_empty()):
		host._notify("BOT 强度在单机对局中调整")
		return
	if id == UTILITY_RULEBOOK:
		close_panels()
		_active_utility_id = id
		_utility_title.text = "下班 · 学习中心"
		_utility_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_utility_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_rulebook = preload("res://scenes/off_work_rulebook.gd").new()
		_utility_body.add_child(_rulebook)
		_rulebook.bind(self)
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

func _offer_learning_invitation() -> void:
	if not is_instance_valid(_learning_invitation):
		if _invitation_offered or panels_open() or not can_begin_tutorial(): return
		_build_learning_invitation()
		_invitation_offered = false
		# Only the suggestion itself handles clicks; the shared shift sign is always usable.
		_invitation_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_invitation_scrim.color = Color.TRANSPARENT
		_learning_invitation.find_child("InvitationTitle", true, false).text = "下班第一课"
		_learning_invitation.find_child("InvitationBody", true, false).text = "在练习工位试一次派工、收钱和购牌。你的正式牌局会暂存，随时可以回来。"
	super._offer_learning_invitation()

func can_begin_tutorial() -> bool:
	return host.practice.is_empty() and not _manual_paused and not host.shift_network_live() and not host.replay.playing and host.state.winner < 0

func _start_invitation_course() -> void:
	host.begin_practice("first")

func _dismiss_learning_invitation(choice: String) -> void:
	_invitation_offered = true
	_suspended_panels.erase(_learning_invitation)
	_learning_invitation.hide()
	TutorialProgress.dismiss_invitation(choice, true)

func practice_reference_open() -> bool:
	return is_instance_valid(_utility) and _utility.visible

func update_practice_panel() -> void:
	if is_instance_valid(_practice_gesture):
		_practice_gesture.get_parent().remove_child(_practice_gesture)
		_practice_gesture.queue_free()
		_practice_gesture = null
	if is_instance_valid(_practice_panel):
		_practice_panel.get_parent().remove_child(_practice_panel)
		_practice_panel.queue_free()
		_practice_panel = null
	if host.practice.is_empty(): return
	var course: Dictionary = host.lesson.lesson
	var done: bool = host.lesson.complete()
	var failed: bool = host.state.winner >= 0 and not done
	_practice_panel = PanelContainer.new()
	_practice_panel.name = "WorkTutorialCoach"
	_practice_panel.set_meta("drawer_surface", Palette.semantic("surface"))
	_practice_panel.set_meta("drawer_margin_base", 10)
	add_child(_practice_panel)
	var column := VBoxContainer.new()
	_practice_panel.add_child(column)
	var heading := str(course.title) + (" · 已完成" if done else " · %d/%d" % [host.lesson.step+1,course.steps.size()])
	column.add_child(_label(heading, UI_FONT_TITLE))
	var body := ("双方同时下班，重练试试能不能早一步。" if host.state.winner == 2 else "对手先下班了，再试一次。") if failed else str(host.lesson.last_feedback)
	if not done and not failed:
		if not body.is_empty(): body += "\n"
		body += str(course.steps[host.lesson.step][1])
	elif done and host.lesson.used_demo:
		body += " 点重练可以亲手完成。"
	var description := _work_paragraph(body)
	description.name = "WorkLessonHint"
	column.add_child(description)
	var actions := HFlowContainer.new()
	column.add_child(actions)
	if done:
		var list: Array = host.lesson.courses()
		var next: int = list.find(course) + 1
		if next < list.size(): _lesson_button(actions, "下一课", host.begin_practice.bind(list[next].id))
	elif not failed and course.id != "solo":
		_lesson_button(actions, "演示这一步", host.demonstrate_practice_step)
	_lesson_button(actions, "重练", host.begin_practice.bind(course.id))
	_lesson_button(actions, "课程", _open_utility.bind(UTILITY_RULEBOOK))
	_lesson_button(actions, "退出", host.finish_practice)
	_guard_table_panel(_practice_panel, false)
	_apply_tree_theme(_practice_panel)
	if not done and not failed and course.id != "solo":
		_practice_gesture = WorkLessonGesture.new()
		_practice_gesture.hud = self
		add_child(_practice_gesture)
		_practice_gesture.set_cue(_lesson_cue(course.steps[host.lesson.step][0]))
	_position_practice_panel()

func _position_practice_panel() -> void:
	var pos := Vector2(_content.get_center().x - _practice_panel.size.x * 0.5, _header.position.y + _header.size.y + _px(6))
	var protected: Array[Rect2] = []
	if is_instance_valid(_practice_gesture):
		for key in ["source", "target"]:
			var node: Node = _practice_gesture.cue.get(key)
			if not is_instance_valid(node): continue
			var bounds := _practice_gesture.source_rect(node)
			if not bounds.has_area(): bounds = Rect2(_practice_gesture.anchor(node) - Vector2.ONE * _px(30), Vector2.ONE * _px(60))
			protected.append(bounds.grow(_px(10)))
		if _practice_gesture.cue.has("target_world"):
			var at := _practice_gesture.world_anchor(_practice_gesture.cue.target_world)
			protected.append(Rect2(at - Vector2.ONE * _px(35), Vector2.ONE * _px(70)))
	if board.side_extract.is_open():
		protected.append(board.side_extract.view._view_rect.grow(_px(10)))
	var best_score := INF
	for x in [pos.x, _content.position.x + _px(10), _content.end.x - _practice_panel.size.x - _px(10)]:
		var candidate := Vector2(x, pos.y)
		var footprint := Rect2(candidate, _practice_panel.size)
		var score := 0.0
		for bounds in protected: score += footprint.intersection(bounds).get_area()
		if score < best_score:
			best_score = score
			pos = candidate
	_practice_panel.position = pos

func _lesson_cue(target: String) -> Dictionary:
	if target in ["inspect_type", "extract_type"]:
		return _type_extraction_cue(host.lesson.source_group(), "employee", target == "extract_type")
	if target == "transfer_start":
		var tools: Array = state._owner_type(0, "transfer")
		var people: Array = host.lesson.workers(state, 0)
		var jobs: Array = state._owner_type(0, "work")
		if tools.is_empty() or people.is_empty() or jobs.is_empty(): return {}
		var person_group: int = state.cards[people[0]].group
		if not state.group_work(person_group).is_empty():
			return _type_extraction_cue(person_group, "employee", true)
		var tool_group: int = state.cards[tools[0]].group
		var source: int = people[0] if not state.group_work(tool_group).is_empty() else tools[0]
		var destination: int = tools[0] if source == people[0] else jobs[0]
		if not board.by_uid.has(source) or not board.by_uid.has(destination): return {}
		var target_card: Node3D = board.by_uid[destination]
		var group = board.group_of(target_card)
		if group != null and not group.cards.is_empty(): target_card = group.cards[board._top_index(group)]
		return {"source":board.by_uid[source], "target":target_card, "gesture":"drag"}
	if target == "transfer_resume":
		var tools: Array = state._owner_type(0, "transfer")
		if tools.is_empty(): return {}
		var group_id: int = state.cards[tools[0]].group
		if state.group_work(group_id).is_empty(): return {}
		return _type_extraction_cue(group_id, "transfer", true)
	if target == "separate_worker":
		var people: Array = host.lesson.workers(state, 0)
		if people.is_empty(): return {}
		return _type_extraction_cue(int(state.cards[people[0]].group), "employee", true)
	if target == "buy":
		for offer in state.offers:
			if offer.is_empty() or offer.type != "employee": continue
			var card: Node = board.offers_by_id.get(offer.id)
			if not is_instance_valid(card) or not card.has_meta("price_tag"): continue
			var tag: Node = card.get_meta("price_tag").get_ref()
			if is_instance_valid(tag) and is_instance_valid(tag._paper):
				return {"source":tag._paper, "gesture":"tap"}
		return {}
	var pairs := {"assign":["employee","work",0], "own_income":["employee","work",0],
		"overtime":["overtime","employee",0], "coffee":["coffee","employee",0], "strike":["strike","employee",1],
		"meeting_start":["meeting","leader",0]}
	if not pairs.has(target): return {}
	var pair: Array = pairs[target]
	var source: Array = state._owner_type(0, pair[0])
	var destination: Array = state._owner_type(pair[2], pair[1])
	if pair[0] == "employee": source = host.lesson.workers(state, 0)
	if pair[1] == "employee": destination = host.lesson.workers(state, pair[2])
	if source.is_empty() or destination.is_empty() or not board.by_uid.has(source[0]) or not board.by_uid.has(destination[0]): return {}
	var destination_card: Node3D = board.by_uid[destination[0]]
	var group = board.group_of(destination_card)
	if group != null and not group.cards.is_empty():
		destination_card = group.cards[board._top_index(group)]
	return {"source":board.by_uid[source[0]], "target":destination_card, "gesture":"drag"}

func _type_extraction_cue(group_id: int, kind: String, allow_drag: bool) -> Dictionary:
	var extract = board.side_extract
	if allow_drag and extract.is_open() and extract._group_id == group_id and extract._kind == kind:
		var records: Array = extract.view.records
		if records.is_empty(): return {}
		var card: Node3D = board.by_uid.get(int(records[0].id))
		if not is_instance_valid(card): return {}
		# Use clear space below the opening piles, away from the inspection fan.
		var area: Rect2 = board.player_bounds
		var at := area.position + area.size * Vector2(0.48, 0.72)
		var landing: Vector3 = board._free_spawn_position(-1, 0, Vector3(at.x, card.global_position.y, at.y))
		return {"source": extract.view, "target_world": landing, "gesture": "drag"}
	for group in board.groups:
		if int(group.get("work_group_id", -1)) != group_id: continue
		var rows: Array = group.get("extract_rows", [])
		var nodes: Array = group.get("side", [])
		for index in rows.size():
			if str(rows[index].kind) != kind or index * 2 + 1 >= nodes.size(): continue
			var label: Node = nodes[index * 2 + 1]
			if is_instance_valid(label): return {"source": label, "gesture": "tap"}
	return {}

func _lesson_button(row: Container, text: String, callback: Callable) -> void:
	var button := _button(text, UI_FONT_SMALL, true)
	button.pressed.connect(callback)
	row.add_child(button)

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

func draw_result_taunt(winner: int) -> String:
	if winner not in [0, 1]: return ""
	var key := "win_taunts" if winner == 0 else "lose_taunts"
	var lines: Array = hud_config.result[key]
	var path := preload("res://engine/save_paths.gd").off_work_settings_file("result_taunts.json")
	var history := {}
	if FileAccess.file_exists(path):
		var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if saved is Dictionary: history = saved
	var seen: Array = history[key] if history.get(key) is Array else []
	var available := lines.filter(func(line): return not seen.has(line))
	if available.is_empty():
		available = lines.duplicate()
		if available.size() > 1 and not seen.is_empty(): available.erase(seen.back())
		seen.clear()
	var line := str(available[RandomNumberGenerator.new().randi_range(0, available.size() - 1)])
	seen.append(line)
	history[key] = seen
	preload("res://engine/json_store.gd").save(path, history)
	return line

func begin_off_work_finale(winner: int) -> void:
	if is_instance_valid(_off_work_finale) and _off_work_finale.winner == winner: return
	clear_result()
	close_panels()
	_off_work_finale_layer = CanvasLayer.new()
	_off_work_finale_layer.name = "OffWorkFinale"
	_off_work_finale_layer.layer = 8
	host.add_child(_off_work_finale_layer)
	_off_work_finale = OffWorkResultFx.new()
	_off_work_finale_layer.add_child(_off_work_finale)
	_off_work_finale.configure(winner, _off_work_result_focus)
	register_result_panel(_off_work_finale_layer)
	if host._shift_hidden: _suspend_panel(_off_work_finale_layer)

func set_off_work_finale_hidden(hidden: bool) -> void:
	for canvas in [_off_work_finale_layer, result_layer]:
		if not is_instance_valid(canvas): continue
		if hidden and canvas.visible:
			_suspend_panel(canvas)
		elif not hidden and not _table_panels_blocked() and canvas in _suspended_panels:
			_suspended_panels.erase(canvas)
			canvas.show()

func _off_work_result_focus() -> Vector2:
	# 失败时把冷光留在最大的真实待办堆上；不改牌局和卡牌位置。
	var target := -1
	var largest := 0
	for gid in state.groups:
		if int(state.groups[gid].owner) != 0: continue
		var count: int = state.group_work(int(gid)).size()
		if count > largest:
			largest = count
			target = int(gid)
	if target >= 0: return host.board.camera.unproject_position(host.board.get_group_position(target))
	return get_viewport().get_visible_rect().size * Vector2(0.5, 0.72)

func show_result(winner: int, work_left: int, restart: Callable, taunt := "") -> CanvasLayer:
	# 恢复存档或认输也走同一终帧。已有离场气氛不重新从零播放。
	if not is_instance_valid(_off_work_finale) or _off_work_finale.winner != winner:
		begin_off_work_finale(winner)
	else:
		_clear_off_work_result_panel()
	_off_work_finale.age = maxf(_off_work_finale.age, 1.6)
	close_panels()
	result_layer = CanvasLayer.new()
	result_layer.name = "OffWorkResult"
	result_layer.layer = 10
	host.add_child(result_layer)
	var center := CenterContainer.new()
	center.name = "OffWorkResultCenter"
	# 自动换行的首帧最小高度不能把全屏容器撑大；始终围绕固定中心排版。
	center.use_top_left = true
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result_layer.add_child(center)
	var frame := VBoxContainer.new()
	frame.name = "ResultPanel"
	frame.add_theme_constant_override("separation", 4)
	center.add_child(frame)
	var hero := OffWorkResultHero.new()
	hero.name = "OffWorkResultHero"
	hero.configure(winner)
	frame.add_child(hero)
	var receipt := PanelContainer.new()
	receipt.name = "OffWorkResultReceipt"
	receipt.set_meta("drawer_margin_base", 16)
	frame.add_child(receipt)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	receipt.add_child(column)
	var title := _label(str(hud_config.result.win) if winner == 0 else (str(hud_config.result.tie) if winner == 2 else str(hud_config.result.lose)), 20)
	title.name = "ResultTitle"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var summary := _label(str(hud_config.result.complete) if work_left == 0 else str(hud_config.result.remaining) % work_left, 18)
	summary.name = "ResultSummary"
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(summary)
	if winner in [0, 1]:
		var quote := _label(taunt if not taunt.is_empty() else str(hud_config.result["win_taunts" if winner == 0 else "lose_taunts"][0]))
		quote.name = "ResultMessage"
		quote.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(quote)
	var again := _button(str(hud_config.restart))
	again.name = "ResultRestart"
	again.set_meta("ui_role", "primary")
	again.pressed.connect(restart)
	column.add_child(again)
	register_result_panel(result_layer)
	if host._shift_hidden: _suspend_panel(result_layer)
	# 首次点击主视觉只落定演出，不误触重开；按钮始终可直接使用。
	hero.mouse_filter = Control.MOUSE_FILTER_STOP
	hero.gui_input.connect(func(event: InputEvent) -> void:
		if (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) \
				or (event is InputEventScreenTouch and event.pressed):
			hero.finish()
			_off_work_finale.finish()
			hero.accept_event())
	_off_work_result_animation = result_layer.create_tween()
	_off_work_result_animation.tween_interval(0.18)
	_off_work_result_animation.tween_callback(func(): host.audio.play("off_work_result_stamp"))
	if winner == 1:
		_off_work_result_animation.tween_interval(0.25)
		_off_work_result_animation.tween_callback(func(): host.audio.play("off_work_result_tail"))
	result_layer.visibility_changed.connect(_sync_off_work_result_animation)
	_sync_off_work_result_animation()
	return result_layer

func _sync_off_work_result_animation() -> void:
	if _off_work_result_animation == null or not _off_work_result_animation.is_valid(): return
	if is_instance_valid(result_layer) and result_layer.visible:
		_off_work_result_animation.play()
	else:
		_off_work_result_animation.pause()

func _theme_external_panel(panel: CanvasLayer) -> void:
	super._theme_external_panel(panel)
	if panel == _off_work_finale_layer and is_instance_valid(_off_work_finale):
		# relayout 最后才更新 3D 相机；下一次空闲时再取待办堆的新投影。
		_off_work_finale.call_deferred("refresh_focus")
	if panel != result_layer or not is_instance_valid(result_layer): return
	var center := panel.get_node("OffWorkResultCenter") as CenterContainer
	var frame := center.get_node("ResultPanel") as VBoxContainer
	var hero := frame.get_node("OffWorkResultHero") as Control
	var area := _content
	if area.size.x <= 0 or area.size.y <= 0: area = get_viewport().get_visible_rect()
	center.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	center.position = area.get_center()
	frame.custom_minimum_size.x = minf(_px(540), maxf(180.0, area.size.x - _px(24)))
	hero.custom_minimum_size = Vector2(0, minf(frame.custom_minimum_size.x * 0.43, area.size.y * 0.40))
	frame.queue_sort()

func _clear_off_work_result_panel() -> void:
	if _off_work_result_animation != null and _off_work_result_animation.is_valid(): _off_work_result_animation.kill()
	_off_work_result_animation = null
	if is_instance_valid(result_layer):
		result_layer.get_parent().remove_child(result_layer)
		result_layer.queue_free()
	result_layer = null

func clear_result() -> void:
	_clear_off_work_result_panel()
	if is_instance_valid(_off_work_finale_layer):
		_off_work_finale_layer.get_parent().remove_child(_off_work_finale_layer)
		_off_work_finale_layer.queue_free()
	_off_work_finale_layer = null
	_off_work_finale = null

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
