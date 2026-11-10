# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var host: Node

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1440, 900)
	host = load("res://scenes/off_work_main.tscn").instantiate()
	host.set_meta("shift_enter_expanded", true)
	host.process_mode = Node.PROCESS_MODE_PAUSABLE
	root.add_child(host)
	await _frames(3)
	host.set_process(false)
	host.audio.muted = true
	host.sfx.user_muted = true
	host.state.config.rules.initial.groups = [{"employee": 2, "work": 12}]
	host.state.config.rules.bot.enabled = false
	host._new_game()
	host.hud.drawer_window.pin()
	var live: OffWorkState = host.state
	var bot: RefCounted = host.bot
	live.advance(2.0)
	host.board.sync_state(live)
	# Keep a nonempty, real-card binding in the parked BOT context. The picker
	# must preserve this opaque continuation, not merely an empty dictionary.
	var employee := int(live._owner_type(1, "employee")[0])
	# The UI treats context as opaque; do not couple this pause regression to
	# either the released BOT's plan format or the experimental search model.
	bot.import_decision_context({"observed_at":live.time, "owner":1, "people":[employee]})
	var context: Dictionary = bot.export_decision_context()
	var path: String = host.replay.save(host)
	check(not path.is_empty() and host.replay.frames.size() >= 2, "夹具由实际牌局保存短录像")
	var directory := SavePaths.recordings_dir()
	var subdir := directory.path_join("picker-subdir")
	check(DirAccess.make_dir_recursive_absolute(subdir) == OK, "夹具目录创建成功")
	var bad_path := subdir.path_join("invalid.json")
	var bad_file := FileAccess.open(bad_path, FileAccess.WRITE)
	bad_file.store_string("{}")
	bad_file.close()
	host.set_process(true)
	await _frames(3)
	await _click(host.hud.btn_pause)
	check(paused and host.hud._manual_paused, "真实暂停按钮暂停牌局")
	var snapshot := _world_bytes(live)
	var picker: Node = await _open_picker()
	if not is_instance_valid(picker):
		await _finish_test()
		return
	check(picker.can_process() and picker._files.can_process(), "暂停牌局中录像列表仍处理输入")
	await _select_entry(picker, subdir)
	await _click(picker.find_child("ReplayLoad", true, false))
	check(picker._directory == subdir, "暂停时点击目录并读入可进入目录")
	await _select_entry(picker, bad_path)
	await _click(picker.find_child("ReplayLoad", true, false))
	check(not picker._status.text.is_empty() and not host.replay.playing, "暂停时读入无效录像显示错误并保留选择器")
	await _click(_button_named(picker, "上一级"))
	check(picker._directory == directory, "错误后上一级按钮仍可使用")
	await _click(picker._path_edit)
	await _replace_text("missing-replay.json")
	check(picker._path_edit.text == "missing-replay.json", "暂停时路径框接收真实键盘输入")
	await _click(picker.find_child("ReplayLoad", true, false))
	check(picker._status.text == "找不到这份录像", "不存在的路径通过读入按钮显示错误")
	_check_parked(live, bot, snapshot, context, "目录和坏路径操作")
	await _click(_button_named(picker, "取消"))
	check(not is_instance_valid(picker) and not is_instance_valid(host._replay_picker), "暂停时真实取消按钮关闭列表")
	_check_parked(live, bot, snapshot, context, "取消列表")

	# Use the same menu/list/load route for a valid file, then the real stop
	# button. Loading temporarily unpauses playback; stopping restores pause.
	picker = await _open_picker()
	if not is_instance_valid(picker):
		await _finish_test()
		return
	await _select_entry(picker, path)
	await _click(picker.find_child("ReplayLoad", true, false))
	check(host.replay.playing and not is_instance_valid(picker) and host.state != live, "真实读入按钮开始短录像并关闭选择器")
	check(not paused and not host.hud._manual_paused, "录像播放暂时解除原局手动暂停")
	check(_world_bytes(live) == snapshot and bot.export_decision_context() == context, "播放期间暂存原局和BOT上下文不改变")
	await _click(host.hud.btn_resign)
	check(not host.replay.playing, "真实退出录像按钮结束播放")
	_check_parked(live, bot, snapshot, context, "退出录像")

	await _click(host.hud.btn_pause)
	check(not paused and not host.hud._manual_paused, "再次点击暂停按钮恢复牌局")
	picker = await _open_picker()
	if not is_instance_valid(picker):
		await _finish_test()
		return
	var before_cancel := live.time
	await _click(_button_named(picker, "取消"))
	await create_timer(0.05, true).timeout
	check(not is_instance_valid(picker) and not paused and not host.hud._manual_paused, "未暂停时取消列表不会留下暂停")
	check(host.state == live and live.time > before_cancel and host.bot == bot, "未暂停取消后原牌局继续推进")
	check(bot.export_decision_context() == context, "未暂停取消也保留BOT上下文")
	await _finish_test()

func _world_bytes(world: OffWorkState) -> PackedByteArray:
	var snapshot := {}
	for field in OffWorkState.WORLD_FIELDS: snapshot[field] = world.get(field)
	snapshot["rng"] = world._rng.state
	return var_to_bytes(snapshot)

func _check_parked(live: OffWorkState, bot: RefCounted, snapshot: PackedByteArray, context: Dictionary, label: String) -> void:
	check(paused and host.hud._manual_paused, label + "保留手动暂停")
	check(host.state == live and _world_bytes(live) == snapshot, label + "保留原牌局身份、时钟和全部规则状态")
	check(host.bot == bot and bot.export_decision_context() == context, label + "保留BOT身份和非空上下文")

func _open_picker() -> Node:
	await _click(host.hud._menu)
	var popup: PopupMenu = host.hud._menu.get_popup()
	check(popup.visible, "真实菜单按钮打开菜单")
	var index := popup.get_item_index(8)
	var style: StyleBox = popup.get_theme_stylebox("panel")
	var height := (float(popup.size.y) - style.get_minimum_size().y) / float(popup.item_count)
	var hit := Vector2(float(popup.size.x) * 0.5, style.get_content_margin(SIDE_TOP) + (float(index) + 0.5) * height)
	await _click_at(Vector2(popup.position) + hit)
	await _frames(3)
	check(is_instance_valid(host._replay_picker) and not popup.visible, "菜单事件结束后创建录像选择器并关闭菜单")
	return host._replay_picker if is_instance_valid(host._replay_picker) else null

func _select_entry(picker: Node, path: String) -> void:
	var index: int = picker._entries.find(path)
	check(index >= 0, "列表包含夹具：" + path.get_file())
	if index < 0: return
	var list: ItemList = picker._files
	await _click_at(list.get_global_transform() * list.get_item_rect(index).get_center())
	check(picker._path_edit.text == path, "真实列表点击更新所选路径")

func _button_named(node: Node, label: String) -> Button:
	if node is Button and node.text == label: return node
	for child in node.get_children():
		var result := _button_named(child, label)
		if result != null: return result
	return null

func _frames(count: int) -> void:
	for _i in count: await process_frame

func _click(control: Control) -> void:
	check(control != null and control.is_visible_in_tree(), "目标控件可见并接收真实点击")
	if control != null: await _click_at(control.get_global_rect().get_center())

func _click_at(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	await _frames(2)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = pressed
		root.push_input(event, true)
		await _frames(2)

func _replace_text(value: String) -> void:
	for pressed in [true, false]:
		var select_all := InputEventKey.new()
		select_all.keycode = KEY_A
		select_all.physical_keycode = KEY_A
		select_all.meta_pressed = OS.get_name() == "macOS"
		select_all.ctrl_pressed = not select_all.meta_pressed
		select_all.pressed = pressed
		root.push_input(select_all, true)
		await _frames(1)
	for character in value:
		var event := InputEventKey.new()
		event.unicode = character.unicode_at(0)
		event.pressed = true
		root.push_input(event, true)
		await _frames(1)

func _finish_test() -> void:
	host.hud.set_manual_paused(false)
	host.queue_free()
	await _frames(2)
	finish()
