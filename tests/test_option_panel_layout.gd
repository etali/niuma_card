# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	await settle()
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	var page: Node = main.drawer_presentation
	for window_size in [Vector2i(1600, 900), Vector2i(960, 640)]:
		root.size = window_size
		await process_frame
		page.relayout()
		for id in [0, 1, 2, 3, 4, 5, 7, 9]:
			page._open_utility(id)
			for frame in 4:
				await process_frame
			page._relayout_utility()
			var rect: Rect2 = page._utility.get_global_rect()
			var header: Rect2 = page._header.get_global_rect()
			var footer: Rect2 = page._footer.get_global_rect()
			check(rect.position.y > header.end.y and rect.end.y < footer.position.y,
				"%s 页%d不遮挡上下横条并保留缝隙" % [window_size, id])
			check(absf(rect.position.y - page._content.position.y) < 1.0
				and absf(rect.end.x - page._content.end.x) < 1.0,
				"%s 页%d右上角起点一致" % [window_size, id])
			if id == 3:
				check(page._utility_scroll.get_v_scroll_bar().max_value > page._utility_scroll.size.y,
					"长UI页通过面板内部滚动查看")
		page.close_panels()

	page._open_utility(5)
	var save_button: Button
	for child in page._utility_body.get_children():
		if child is Button:
			save_button = child
	save_button.pressed.emit()
	await process_frame
	check(page._active_utility_id == 5 and page._utility.visible and save_button.is_inside_tree(),
		"保存后仍停留在原保存录像页")
	var notice: SaveNotice = main.save_notice
	check(notice._path_edit.is_visible_in_tree() and page._utility_body.is_ancestor_of(notice._path_edit),
		"录像结果及路径显示在原选项页内部")
	check(FileAccess.file_exists(notice._path_edit.text) and notice._path_edit.selecting_enabled,
		"原页显示真实可复制的录像路径")
	check(not notice._close_btn.visible, "嵌入后只保留选项页的关闭按钮")
	page.show_record_result("/tmp/record-unwritable", 0, true)
	check(page._active_utility_id == 5 and notice._hint.is_visible_in_tree(), "保存失败同样在原页说明")
	page.close_panels()
	check(not notice.visible and notice.get_node_or_null("Frame") != null, "关闭后恢复通知节点并隐藏")
	main.queue_free()
	await process_frame
	finish()
