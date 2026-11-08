extends "res://tests/harness.gd"

func _initialize() -> void:
	OS.set_environment("WORK_DATA_DIR", _test_data_dir.path_join("off_work"))
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 900)
	var host: Node = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(host)
	await process_frame
	host.set_process(false)
	var hud: CanvasLayer = host.hud
	var live: RefCounted = host.state
	var notice: SaveNotice = hud.save_notice
	if not need(notice != null, "下班牌使用共用SaveNotice面板"):
		host.queue_free()
		finish()
		return
	hud._open_utility(5)
	var save: Button = hud._utility_body.get_child(0)
	check(save.text == "保存当前对局", "保存入口与上班牌一致")
	save.pressed.emit()
	var first: String = notice._path_edit.text
	check(FileAccess.file_exists(first), "保存真实录像并显示其路径")
	check(notice._title.text.begins_with("录像已存") and notice.visible, "保存后显示录像已存")
	check(notice._copy_btn.text == "复制路径" and not notice._copy_btn.disabled, "保存后提供复制路径按钮")
	check(notice._path_edit.selecting_enabled and not notice._path_edit.editable, "路径只读且可选中")
	check(hud._utility.get_meta("frame").get_parent() == hud._utility_body, "回执嵌入选项保存页")
	check(host.state == live and not host.replay.playing, "保存不会替换或停止原局")
	if OS.has_environment("OFF_WORK_SAVE_SHOT"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("OFF_WORK_SAVE_SHOT"))
	var desktop := DisplayServer.get_name() != "headless"
	var previous_clipboard := DisplayServer.clipboard_get() if desktop else ""
	notice._copy_btn.pressed.emit()
	check(notice._copy_btn.text == "已复制 ✓", "复制动作提供可见反馈")
	if desktop:
		check(DisplayServer.clipboard_get() == first, "系统剪贴板得到完整录像路径")
		DisplayServer.clipboard_set(previous_clipboard)
	await create_timer(1.45).timeout
	hud.close_panels()
	check(notice.get_node("Frame").get_parent() == notice and not notice.visible, "关闭选项恢复共用回执供再次使用")
	hud.set_manual_paused(true)
	var recordings_before := DirAccess.get_files_at(SavePaths.recordings_dir()).size()
	var key := InputEventKey.new()
	key.keycode = KEY_F5
	key.pressed = true
	root.push_input(key)
	var second: String = notice._path_edit.text
	check(second != first and FileAccess.file_exists(second)
		and DirAccess.get_files_at(SavePaths.recordings_dir()).size() == recordings_before + 1,
		"暂停时真实F5输入仅保存一份独立录像")
	check(hud._utility.visible and notice._title.text.begins_with("录像已存"), "F5使用相同回执")
	hud.close_panels()
	var loaded: Dictionary = host._load_replay(first)
	check(loaded.ok, "可以读取刚保存的录像")
	if loaded.ok:
		host.save_work_replay()
		check(notice._path_edit.text == first and notice._title.text.begins_with("录像已存"), "回放中保存显示源录像路径，与上班牌一致")
		hud.close_panels()
		host.stop_replay()
	var failed_dir := _test_data_dir.path_join("blocked")
	var file := FileAccess.open(failed_dir, FileAccess.WRITE)
	file.store_string("file")
	file.close()
	SavePaths.recordings_override = failed_dir
	host.save_work_replay()
	check(notice._title.text == "录像存不下来" and notice._path_edit.text == failed_dir, "失败回执显示明确原因和目标目录")
	hud.close_panels()
	host.queue_free()
	await process_frame
	finish()
