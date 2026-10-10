# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only

extends "res://tests/support/drawer_fixture.gd"

const Codec = preload("res://engine/state_codec.gd")
var main: Node
var p: Node
var original: Dictionary

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 教程入口：查阅继续、结束按钮、退出与四尺寸底栏 ===")
	root.min_size = Vector2i.ZERO
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	p = main.drawer_presentation
	p._learning_invitation.hide()
	main._flush_record_view()
	original = {"state": main.state, "cards": main.board.cards.duplicate(),
		"snapshot": Codec.snapshot(main.state), "tape": main.tape.to_dict().duplicate(true),
		"resign_visible": main.btn_resign.visible}
	for extent in [Vector2i(1280, 800), Vector2i(960, 600), Vector2i(844, 390), Vector2i(390, 844)]:
		root.size = extent
		await relayout_drawer(main)
		var before := _view()
		check(not p._end_tutorial_button.visible, "%s：未教学时隐藏结束按钮" % extent)
		check(p.start_tutorial("income"), "%s：从原牌桌开课" % extent)
		await relayout_drawer(main)
		check(_same_view(before), "%s：开课新增按钮不顶高底栏、不移动牌桌" % extent)
		_check_footer(extent)
		if extent == Vector2i(1280, 800):
			await _reference_lifecycle()
		await _click(p._end_tutorial_button)
		await relayout_drawer(main)
		check(_restored() and not p._end_tutorial_button.visible,
			"%s：真实点击结束按钮恢复原局并隐藏自身" % extent)
		check(_same_view(before), "%s：关课保持原内容区域与相机投影" % extent)

	root.size = Vector2i(1280, 800)
	await relayout_drawer(main)
	check(p.start_tutorial("income"), "再次开课验证小人退出入口")
	await relayout_drawer(main)
	await _click(p.tutorial._close)
	check(_restored() and not p._end_tutorial_button.visible, "小人×恢复原局且同步隐藏结束按钮")
	check(p.start_tutorial("income"), "再次开课验证Esc退出")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	root.push_input(escape)
	await process_frame
	check(_restored() and not p._end_tutorial_button.visible, "Esc恢复原局且同步隐藏结束按钮")
	check(p.start_tutorial("income"), "再次开课验证回滚等待中退出")
	await relayout_drawer(main)
	p.tutorial.arena.finish_action()
	check(p.tutorial.arena.operation_pending, "提前完成行动进入待回滚状态")
	await _click(p._end_tutorial_button)
	await create_timer(0.6).timeout
	check(_restored() and not p._end_tutorial_button.visible,
		"回滚等待时真实点击结束安全，晚到回调不污染原局")
	await dispose_drawer(main)
	finish()

func _reference_lifecycle() -> void:
	var player: Control = p.tutorial
	var arena: Node = player.arena
	var session: RefCounted = player.session
	var context: RefCounted = p._tutorial_context
	var cash: Array = []
	for card in arena.entities.values():
		if card.draggable and card.def_id == "cash": cash.append(card)
	var purchase_results: Array = []
	var record_purchase := func(result): purchase_results.append(result)
	arena.operation_finished.connect(record_purchase)
	arena._purchase(cash, arena.market_cards[0])
	for attempt in 150:
		if not purchase_results.is_empty(): break
		await create_timer(0.02).timeout
	arena.operation_finished.disconnect(record_purchase)
	if not need(purchase_results.size() == 1 and purchase_results[0].get("expected", false)
		and not arena.operation_pending, "真实购牌演出结束后收到一次成功事件"): return
	check(session.current_step()["id"] == "income.split" and not player._awaiting_result, "正确买牌直接衔接拆牌，无需再确认购牌")
	await _click(p._rulebook_button)
	await relayout_drawer(main)
	var step: int = session.step_index
	await create_timer(0.65).timeout
	check(p.tutorial == player and player.session == session and player.arena == arena
		and p._tutorial_context == context and player._reference_open,
		"打开课程列表保留同一个教学现场")
	check(session.step_index == step and not player._awaiting_result
		and main.btn_pass.disabled and main.board.input_locked and arena.finish_action().get("code") == "busy",
		"查看列表时保留当前拆牌目标并锁住原完成行动")
	var book: Node = p._rulebook
	check(book.find_child("StartTutorial", true, false).text == TutorialCatalog.ui("hub.continue_active", {"title": session.course_data.title}),
		"首页主按钮准确显示继续当前教学")
	var course_width: float = p._utility.size.x
	var reference_view := _view()
	await _click(book.find_child("Learning_cards", true, false))
	await relayout_drawer(main)
	check(book.current_page == "cards" and p.tutorial == player and player._reference_open and main.btn_pass.disabled,
		"卡牌图鉴只暂停教学，不退出或重建教程")
	var atlas_width: float = p._utility.size.x
	check(atlas_width > course_width * 1.5 and is_equal_approx(atlas_width, p.content_rect().size.x),
		"课程使用窄面板，切到卡牌总览后展开为完整可用宽度")
	await _click(book.find_child("Learning_upgrades", true, false))
	await relayout_drawer(main)
	check(book.current_page == "upgrades" and p._tutorial_context == context and main.btn_pass.disabled
		and is_equal_approx(p._utility.size.x, atlas_width),
		"升级关系沿用宽面板和同一教学上下文")
	await _click(book.find_child("Learning_home", true, false))
	await relayout_drawer(main)
	check(book.current_page == "home" and is_equal_approx(p._utility.size.x, course_width) and _same_view(reference_view),
		"切回课程恢复窄面板，查阅页宽度变化不移动牌桌")
	p.close_panels()
	await create_timer(0.65).timeout
	check(not player._reference_open and session.step_index == step and not player._awaiting_result
		and not main.btn_pass.disabled and not main.board.input_locked, "关闭查阅页恢复同一步操作，空闲不会再推进")
	await _click(player._goal)
	check(session.step_index == step and not player._awaiting_result, "未完成的拆牌目标不能靠点击对白跳过")
	var snapshot: Dictionary = session.capture_operation()
	await _click(p._rulebook_button)
	await relayout_drawer(main)
	await _click(p._rulebook.find_child("Course_income", true, false))
	check(p.tutorial == player and not p._utility.visible and Codec.canon(session.capture_operation()) == Codec.canon(snapshot),
		"直接点击当前课程继续，不重置已买牌、当前步骤或随机状态")
	await _click(p._rulebook_button)
	await relayout_drawer(main)
	await _click(p._rulebook.find_child("Course_growth", true, false))
	check(p.tutorial == player and player.arena == arena and p._tutorial_context == context
		and session.course_id == "growth" and not p._utility.visible,
		"直接点击其他课程开始，复用同一原牌桌教学现场")

func _check_footer(extent: Vector2i) -> void:
	var screen := Rect2(Vector2.ZERO, Vector2(extent)).grow(1)
	var button: Button = p._end_tutorial_button
	check(button.is_visible_in_tree() and not button.disabled and button.get_parent() == p._rulebook_button.get_parent()
		and button.get_index() == p._rulebook_button.get_index() + 1,
		"%s：结束教程紧邻怎么玩且可点击" % extent)
	for control in p._footer.find_children("*", "Button", true, false):
		if not control.is_visible_in_tree(): continue
		check(screen.encloses(control.get_global_rect()), "%s：底栏按钮在屏幕内：%s %s" % [extent, control.text, control.get_global_rect()])

func _restored() -> bool:
	return p.tutorial == null and not main._tutorial_active and main.state == original.state \
		and main.board.cards == original.cards and Codec.snapshot(main.state) == original.snapshot \
		and main.tape.to_dict() == original.tape and main.btn_resign.visible == original.resign_visible

func _view() -> Dictionary:
	var camera: Camera3D = main.board.camera
	var points: Array = []
	for point in [Vector3.ZERO, Vector3(-9, 0.05, -6), Vector3(9, 0.05, -6), Vector3(-9, 0.05, 6), Vector3(9, 0.05, 6)]:
		points.append(camera.unproject_position(point))
	return {"content": p.content_rect(), "transform": camera.transform, "projection": camera.projection,
		"fov": camera.fov, "size": camera.size, "zoom": p.camera_view.zoom, "offset": p.camera_view.offset, "points": points}

func _same_view(before: Dictionary) -> bool:
	var actual := _view()
	if not actual.content.is_equal_approx(before.content) or not actual.transform.is_equal_approx(before.transform): return false
	if actual.projection != before.projection or not actual.offset.is_equal_approx(before.offset): return false
	for key in ["fov", "size", "zoom"]:
		if not is_equal_approx(actual[key], before[key]): return false
	for index in actual.points.size():
		if actual.points[index].distance_to(before.points[index]) > 0.02: return false
	return true

func _click(control: Control) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = control.get_global_rect().get_center()
	root.push_input(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)
	await process_frame
