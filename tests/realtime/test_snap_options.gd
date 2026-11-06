extends "res://tests/realtime/test_work_hud.gd"

## The options, slider and footer are exercised through real Viewport input.
## WORK_DATA_DIR isolates both interaction preferences and the inherited UI page.
var checks := 0

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	if OS.get_environment("WORK_DATA_DIR").is_empty():
		OS.set_environment("WORK_DATA_DIR", "/tmp/work-snap-options-%d" % OS.get_process_id())
	root.size = Vector2i(1440, 810)
	root.gui_embed_subwindows = true
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(8)
	game.set_process(false)
	game.audio.muted = true
	game.sfx.set_drawer_suspended(true)
	hud = game.hud
	game.board.touch_mode = true
	var board: WorkBoard = game.board
	var id: int = int(hud.hud_config.snap_distance.ui_page_id)
	var popup: PopupMenu = hud._menu.get_popup()
	_check(popup.get_item_index(11) == -1, "separate hyperparameters menu item is removed")
	var labels: Array = []
	for index in popup.item_count: labels.append(popup.get_item_text(index))
	_check(not labels.has("超参数") and not labels.has("吸附距离"), "options exposes only the original UI entry for this setting")
	await _open_menu(id)
	_check(hud._utility.visible and hud._active_utility_id == id, "real menu input opens the inherited UI page")
	if not is_instance_valid(hud._snap_hit_slider):
		printerr("OPTIONS_FIXTURE viewport=%s menu=%s" % [root.get_visible_rect(), hud._menu.get_global_rect()])
		game.queue_free()
		await _frames(3)
		_finish()
		return
	_check(hud._utility_title.text == "UI" and hud._snap_hit_slider.get_parent().get_parent() == hud._utility_body,
		"snap slider is embedded directly in the original UI content")
	_check(hud._snap_hit_slider.accessibility_name == "吸附距离" and
		hud._snap_hit_slider.get_parent().get_child(0).get_child(0).text == "吸附距离", "visible label and accessibility name both say 吸附距离")
	_check(hud._snap_hit_slider.get_parent().get_index() < hud._hover_speed_slider.get_index(), "snap distance appears before the other UI sliders")
	_assert_value(75.0, "default")
	_check(hud._snap_hit_slider.name == "SnapHitRegion" and
		is_equal_approx(hud._snap_hit_slider.min_value, 10.0) and
		is_equal_approx(hud._snap_hit_slider.max_value, 100.0) and
		is_equal_approx(hud._snap_hit_slider.step, 5.0), "slider uses configured range and step")
	var target: CardEntity
	for uid in game.state.cards:
		var info: Dictionary = game.state.cards[uid]
		if int(info.owner) == 0 and str(info.type) == "employee":
			target = board.by_uid[uid]
			break
	_check(is_instance_valid(target), "opening has a local employee to probe")
	if not is_instance_valid(target):
		_finish()
		return
	await _frames(30)
	var probe := target.to_global(Vector3(CardEntity.CARD_SIZE.x * 0.35, 0.0, 0.0))
	_check(is_finite(board._snap_distance(probe, target)), "75% accepts a point at 70% of the card half-width")
	hud._snap_hit_slider.grab_focus()
	for _i in 5: await _key(KEY_LEFT)
	_assert_value(50.0, "keyboard input")
	_check(not is_finite(board._snap_distance(probe, target)), "50% immediately excludes the same point")
	hud._utility_scroll.ensure_control_visible(hud._snap_hit_slider)
	await _frames(3)
	var slider_rect: Rect2 = hud._snap_hit_slider.get_global_rect()
	await _click_at(Vector2(slider_rect.end.x - 2.0, slider_rect.get_center().y))
	_assert_value(100.0, "pointer input")
	hud._snap_hit_slider.grab_focus()
	for _i in 10: await _key(KEY_LEFT)
	_assert_value(50.0, "keyboard after pointer input")
	await _close_utility()
	_check(not hud._utility.visible, "close button dismisses the combined UI page")
	await _open_menu(id)
	_assert_value(50.0, "reopening keeps unsaved value")
	_check(is_equal_approx(_reloaded_fraction(), 0.75), "unsaved input leaves new board at disk default")
	await _click(hud._ui_footer.get_node("SaveUISettings"))
	_check(hud._ui_status.text == str(hud.hud_config.snap_distance.saved), "save button reports saved preferences")
	_check(is_equal_approx(_reloaded_fraction(), 0.5), "saved slider value reloads in a new board")
	await _close_utility()
	await _open_menu(3)
	_check(hud._active_utility_id == 3, "reopening the same UI page preserves the original controls")
	var old_angle: float = hud.perspective_angle
	hud._perspective_slider.grab_focus()
	await _key(KEY_LEFT)
	_check(hud.perspective_angle < old_angle, "original UI slider still updates perspective")
	await _click(hud._ui_footer.get_node("SaveUISettings"))
	_check(hud._ui_status.text == "已保存", "original UI save callback is preserved")
	_check(is_equal_approx(_reloaded_fraction(), 0.5), "common UI save preserves the current snap value alongside display preferences")
	await _close_utility()
	await _open_menu(id)
	await _click(hud._ui_footer.get_node("ResetUISettings"))
	_assert_value(75.0, "restore defaults")
	_check(hud._ui_status.text == str(hud.hud_config.snap_distance.restored), "restore button reports success")
	_check(is_equal_approx(_reloaded_fraction(), 0.75), "restored default persists for a new board")
	probe = target.to_global(Vector3(CardEntity.CARD_SIZE.x * 0.35, 0.0, 0.0))
	_check(is_finite(board._snap_distance(probe, target)), "restoring defaults immediately restores the wider hit region")
	await _close_utility()
	for dimensions in [Vector2i(960, 540), Vector2i(1440, 810)]:
		root.size = dimensions
		hud.relayout()
		await _frames(8)
		await _open_menu(id)
		hud._utility_scroll.ensure_control_visible(hud._snap_hit_slider)
		await _frames(3)
		var viewport_rect := root.get_visible_rect()
		var close: Button = hud._utility.get_child(0).get_child(0).get_child(1)
		for control in [hud._snap_hit_slider, hud._ui_footer.get_node("SaveUISettings"),
			hud._ui_footer.get_node("ResetUISettings"), close]:
			_check(viewport_rect.encloses(control.get_global_rect()), "%s fits within %s" % [control.name, dimensions])
		await _click(hud._ui_footer.get_node("SaveUISettings"))
		_check(hud._ui_status.text == str(hud.hud_config.snap_distance.saved), "save remains clickable at %s" % dimensions)
		await _close_utility()
		_check(not hud._utility.visible, "close remains clickable at %s" % dimensions)
	await _open_menu(id)
	if OS.get_environment("WORK_SNAP_OPTIONS_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await _pointer(Vector2(20.0, 450.0))
		await _frames(3)
		RenderingServer.force_draw(false)
		var path := "res://reports/snap-distance-ui.png"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))
		var result := root.get_texture().get_image().save_png(path)
		_check(result == OK, "GPU screenshot saved")
		print("SNAP_OPTIONS_SCREENSHOT " + ProjectSettings.globalize_path(path))
	await _close_utility()
	game.queue_free()
	await _frames(3)
	_finish()

func _assert_value(expected: float, context: String) -> void:
	_check(is_equal_approx(game.board.get_snap_hit_fraction(), expected / 100.0)
		and is_equal_approx(hud._snap_hit_slider.value, expected)
		and hud._snap_hit_value.text == "%d%%" % roundi(expected), "%s: board, slider and label agree on %d%%" % [context, roundi(expected)])

func _reloaded_fraction() -> float:
	var fresh := WorkBoard.new()
	var value := fresh.get_snap_hit_fraction()
	fresh.free()
	return value

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		printerr("FAIL " + message)

func _finish() -> void:
	print("SNAP_OPTIONS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
