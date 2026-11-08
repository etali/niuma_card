extends SceneTree

## Exercises migrated controls through Viewport mouse/key input, including their
## real callbacks. Fixtures may construct a board state; assertions never emit UI signals.
var game: Node
var hud: CanvasLayer
var hud_checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	root.size = Vector2i(1440, 810)
	root.gui_embed_subwindows = true
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(5)
	game.set_process(false)
	hud = game.hud
	game.board.touch_mode = true
	_check(is_instance_valid(hud._header) and hud._header.name == "DrawerHeader", "uses original DrawerHeader")
	_check(is_instance_valid(hud._footer) and hud._footer.name == "DrawerFooter", "uses original DrawerFooter")
	_check(hud.mine.get_parent().get_parent() == hud._resources, "source resource labels are reparented into original header")
	_check(hud.lbl_round.text.is_empty() and not hud.lbl_round.visible and hud.lbl_round.get_parent() != hud._title_row, "default header omits status wording and empty HBox gap")
	var header_children: int = hud._title_row.get_child_count()
	hud.set_process(false)
	hud.lbl_round.text = "演出测试 · 自动操作"
	hud.refresh(game.state)
	await _frames(3)
	_check(hud.lbl_round.visible and hud.lbl_round.get_parent() == hud._title_row, "explicit demo caption remains available without HUD processing")
	hud.lbl_round.text = ""
	hud.refresh(game.state)
	await _frames(3)
	_check(not hud.lbl_round.visible and hud._title_row.get_child_count() == header_children, "clearing demo caption removes its spacing again")
	hud.set_process(true)
	var was_muted: bool = game.sfx.user_muted
	await _click(hud._sound_button)
	_check(game.sfx.user_muted != was_muted and game.audio.muted == game.sfx.user_muted, "sound icon toggles both audio systems")
	await _click(hud._sound_button)
	game.sfx.set_drawer_suspended(true) # avoid asynchronous dummy-driver playback in the input harness
	await _click(hud._pin)
	_check(not hud.drawer_window.is_pinned() and not hud._pin.button_pressed, "pin icon updates original window state")
	await _click(hud._pin)
	_check(hud.drawer_window.is_pinned() and hud._pin.button_pressed, "pin icon restores pinned window")
	await _open_menu(3)
	_check(hud._utility.visible and hud._active_utility_id == 3, "gear menu opens original UI page")
	var ratio_grid: GridContainer = hud._utility_body.get_child(1)
	await _click(ratio_grid.get_child(0))
	_check(is_equal_approx(hud.drawer_window.get_size_ratio(), 0.75), "original size preset updates window controller")
	await _click(ratio_grid.get_child(3))
	var old_angle: float = hud.perspective_angle
	var slider: HSlider = hud._perspective_slider
	slider.grab_focus()
	await _key(KEY_LEFT)
	_check(hud.perspective_angle < old_angle, "perspective keyboard input changes camera angle")
	var save_button: Button = hud._ui_footer.get_node("SaveUISettings")
	await _click(save_button)
	_check(hud._ui_status.text == "已保存", "original UI save writes isolated settings")
	# ColorPickerButton is the original panel's actual control and popup.
	var picker: ColorPickerButton = hud._palette._pickers[0].btn
	hud._utility_scroll.ensure_control_visible(picker)
	await _frames(3)
	await _click(picker)
	_check(picker.get_popup().visible, "original color picker opens by mouse")
	var hex_edit: LineEdit = _find_hex_edit(picker.get_picker())
	_check(hex_edit != null, "native picker exposes editable hexadecimal color")
	var old_hex := hex_edit.text
	await _click_at(Vector2(picker.get_popup().position) + hex_edit.get_global_rect().get_center())
	await _type_replace("415263")
	_check(picker.color.to_html(false) == "415263", "typing hexadecimal updates original color picker")
	var binding: Dictionary = hud._palette._pickers[0]
	var actual := Palette.plate_color(binding.slot, binding.key) if str(binding.slot) != "" else Palette.get_color(binding.section, binding.key)
	_check(actual.to_html(false) == "415263", "original picker callback updates live Palette")
	await _type_replace(old_hex)
	await _key(KEY_ESCAPE)
	await _close_utility()
	await _open_menu(1)
	_check(hud._utility.visible and hud._utility.get_meta("source") == hud._bot, "BOT page mounts original BOTPanel Frame")
	var old_think: float = game.state.config.rules.bot.think_seconds
	hud._bot._slider.grab_focus()
	await _key(KEY_END)
	_check(OffWorkConfig.decision_budget_ms(game.state.config.rules.bot) == 1800, "strength slider applies the mapped real decision deadline")
	_check(is_equal_approx(game.state.config.rules.bot.think_seconds, 2.0)
		and game.state.config.rules.bot.think_seconds < old_think
		and is_equal_approx(game.state.config.rules.bot.decision_budget_ratio, 0.9),
		"maximum strength updates the real action interval and budget")
	var budget_label: Label
	var interval: SpinBox
	for row in hud._bot._rows:
		if row.key == "budget_readout": budget_label = row.node
		if row.key == "think_seconds": interval = row.node
	_check(budget_label != null and budget_label.text == "1800 毫秒", "native settings show the derived allowance in milliseconds")
	if interval != null and budget_label != null:
		interval.value = 0.2
		_check(budget_label.text == "180 毫秒", "editing the interval immediately refreshes the native allowance")
		interval.value = old_think
	hud._bot._slider.grab_focus()
	await _key(KEY_HOME)
	for _step in 37: await _key(KEY_RIGHT)
	# 0.37 is 48% between the installed 0.25 (12 s / 500 ms) and
	# 0.50 (6 s / 700 ms) anchors. Native controls must retain this fraction.
	_check(is_equal_approx(hud._bot._slider.value, 0.37)
		and is_equal_approx(game.state.config.rules.bot.think_seconds, 9.12)
		and is_equal_approx(game.state.config.rules.bot.decision_budget_ratio, 596.0 / 9120.0)
		and OffWorkConfig.decision_budget_ms(game.state.config.rules.bot) == 596,
		"intermediate keyboard strength preserves exact mapped values through native control refresh")
	await _close_utility()
	game._notify("HUD 真实输入测试")
	await _open_menu(2)
	_check(hud.msg_log.plain_text().contains("HUD 真实输入测试"), "message log retains current message")
	var drag_count: int = game.board._drag_cards.size()
	await _click(hud._utility)
	_check(game.board._drag_cards.size() == drag_count, "utility consumes mouse without picking cards underneath")
	await _close_utility()
	await _mode_entries()
	# The primary action is gone: dragging coffee onto an employee must start
	# the combination on its own, while card hover details stay available.
	var upgraded_person := -1
	for id in game.state.cards:
		if int(game.state.cards[id].owner) == 0 and str(game.state.cards[id].type) == "employee":
			upgraded_person = int(id)
			break
	var group_id: int = game.state.cards[upgraded_person].group
	var coffee: int = game.state.add_card("coffee", 0)
	game.board.sync_state(game.state)
	await _frames(25)
	await physics_frame
	await physics_frame
	var before_work: int = game.state.work_count(0)
	var at := _visible_card_point(game.board.by_uid[coffee])
	_check(at != Vector2.INF, "fresh coffee exposes a clickable face")
	await _pointer(at)
	await _frames(2)
	_check(hud._detail.visible and hud._detail_title.text == "咖啡", "hover uses original detail panel with new card data")
	await _drag_to(at, _visible_card_point(game.board.by_uid[upgraded_person]))
	_check(game.state.cards[coffee].group == group_id and game.state.cards[coffee].status == "active", "pointer combination starts upgrade without a primary button")
	_check(game.state.work_count(0) == before_work and game.state.cards[upgraded_person].type == "employee", "upgrade waits for progress without immediately consuming coffee or completing work")
	game.state.advance(game.state.config.number("coffee", "seconds"))
	game._process(0.0)
	_check(game.state.work_count(0) == before_work and not game.state.cards.has(coffee) and game.state.cards[upgraded_person].type == "grinder", "completed upgrade consumes coffee and changes the employee without completing work")
	for size in [Vector2i(1440, 810), Vector2i(1024, 640), Vector2i(960, 540)]:
		root.size = size
		await _frames(4)
		_check(hud._header.position.x >= -1 and hud._header.get_global_rect().end.x <= size.x + 1, "header fits " + str(size))
		_check(hud._footer.position.y >= 0 and hud._footer.get_global_rect().end.y <= size.y + 1, "footer fits " + str(size))
		_check(hud.content_rect().size.y > 0 and not hud._header.get_global_rect().intersects(hud._footer.get_global_rect()), "table remains between bars " + str(size))
	await _click(hud.btn_resign)
	_check(game.state.winner == -1 and hud.btn_resign.text == "确认认输", "first press asks for confirmation")
	await _click(hud.btn_resign)
	_check(game.state.winner == 1, "confirming awards the opponent the win")
	game._new_game()
	await _key(KEY_ESCAPE)
	_check(not hud.drawer_window.is_expanded() and paused and not hud._header.visible and hud._handle.visible, "Escape collapses original window and pauses both players")
	var hit: Rect2 = hud._handle.get_icon_hit_rect()
	await _click_at(hud._handle.global_position + hit.get_center())
	_check(hud.drawer_window.is_expanded() and not paused and hud._header.visible, "original mascot click reopens window and resumes game")
	hud.drawer_window.set_pinned(true)
	if failures.is_empty(): print("HUD_INPUT PASS (%d checks)" % hud_checks)
	else:
		for failure in failures: push_error(failure)
	game.queue_free()
	await _frames(3)
	quit(0 if failures.is_empty() else 1)

func _mode_entries() -> void:
	var original_size := root.size
	var original_scale: float = hud._ui_scale
	for spec in [[Vector2i(1440, 810), 1.0], [Vector2i(1440, 810), 2.0], [Vector2i(960, 540), 2.0]]:
		root.size = spec[0]
		hud._ui_scale = float(spec[1])
		hud.relayout()
		await _frames(6)
		var label := "%s @%sx" % [spec[0], spec[1]]
		var row: HBoxContainer = hud.btn_resign.get_parent()
		_check(row.get_children().filter(func(node): return node.visible) == [hud.btn_resign, hud.lbl_msg, hud._rulebook_button, hud.btn_pause], "shared footer fits realtime actions " + label)
		var popup: PopupMenu = hud._menu.get_popup()
		for id in [5, 6, 8, 9]:
			_check(popup.get_item_index(id) >= 0, "replay, LAN and cards are accessible through options " + label)
		hud._open_utility(7)
		_check(hud._utility.visible and hud._utility_title.text.contains("下班"), "opens realtime rules")
		hud.close_panels()
	root.size = original_size
	hud._ui_scale = original_scale
	hud.relayout()
	await _frames(6)

func _check(condition: bool, message: String) -> void:
	hud_checks += 1
	print(("PASS " if condition else "FAIL ") + message)
	if not condition: failures.append(message)

func _frames(count: int) -> void:
	for _i in count: await process_frame

func _pointer(at: Vector2, viewport: Viewport = root) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	viewport.push_input(motion, true)
	await _frames(2)

func _click(control: Control) -> void:
	await _click_at(control.get_global_rect().get_center())

func _click_at(at: Vector2, viewport: Viewport = root) -> void:
	await _pointer(at, viewport)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = pressed
		viewport.push_input(event, true)
		await _frames(2)

func _drag_to(start: Vector2, destination: Vector2) -> void:
	if start == Vector2.INF or destination == Vector2.INF:
		_check(false, "drag endpoints expose card faces")
		return
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = start
	press.global_position = start
	press.pressed = true
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(press, true)
	await _frames(2)
	var previous := start
	for step in range(1, 13):
		var motion := InputEventMouseMotion.new()
		motion.position = start.lerp(destination, float(step) / 12.0)
		motion.global_position = motion.position
		motion.relative = motion.position - previous
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		previous = motion.position
		root.push_input(motion, true)
		await _frames(2)
	_check(game.board.is_dragging(), "original pointer path begins coffee drag")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = destination
	release.global_position = destination
	root.push_input(release, true)
	await _frames(25)

func _key(code: Key, viewport: Viewport = root) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		viewport.push_input(event, true)
		await _frames(1)

func _open_menu(id: int) -> void:
	await _click(hud._menu)
	var popup: PopupMenu = hud._menu.get_popup()
	_check(popup.visible, "gear click opens PopupMenu")
	var index := popup.get_item_index(id)
	# PopupMenu rows use the actual popup/theme extent, and are clicked in the
	# popup Viewport's local coordinates; no selection callback is invoked directly.
	var style: StyleBox = popup.get_theme_stylebox("panel")
	var row_height: float = (float(popup.size.y) - style.get_minimum_size().y) / float(popup.item_count)
	var hit := Vector2(float(popup.size.x) * 0.5, style.get_content_margin(SIDE_TOP) + (float(index) + 0.5) * row_height)
	await _click_at(Vector2(popup.position) + hit)
	await _frames(3)

func _close_utility() -> void:
	var close: Button = hud._utility.get_child(0).get_child(0).get_child(1)
	if not root.get_visible_rect().encloses(close.get_global_rect()):
		_check(false, "utility close button must be physically clickable within window")
		await _key(KEY_ESCAPE)
		return
	await _click(close)
	await _frames(2)

func _double_click_at(at: Vector2) -> void:
	await _click_at(at)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = pressed
		event.double_click = pressed
		root.push_input(event, true)
		await _frames(2)

func _visible_card_point(card: CardEntity) -> Vector2:
	for z in [-0.44, -0.3, 0.0, 0.3, 0.44]:
		for x in [-0.35, 0.0, 0.35]:
			var at: Vector2 = game.board.camera.unproject_position(card.global_position + Vector3(x * CardEntity.CARD_SIZE.x, 0.02, z * CardEntity.CARD_SIZE.z))
			if game.board._pick_card(at) == card: return at
	return Vector2.INF

func _find_hex_edit(node: Node) -> LineEdit:
	for child in node.get_children(true):
		if child is LineEdit and child.is_visible_in_tree() and child.text.length() in [6, 8] and child.text.is_valid_hex_number(): return child
		var nested := _find_hex_edit(child)
		if nested != null: return nested
	return null

func _type_replace(value: String) -> void:
	for pressed in [true, false]:
		var select := InputEventKey.new()
		select.keycode = KEY_A
		select.pressed = pressed
		select.meta_pressed = OS.get_name() == "macOS"
		select.ctrl_pressed = OS.get_name() != "macOS"
		root.push_input(select, true)
		await _frames(1)
	for character in value:
		var typed := InputEventKey.new()
		typed.unicode = character.unicode_at(0)
		typed.pressed = true
		root.push_input(typed, true)
		await _frames(1)
	await _key(KEY_ENTER)
