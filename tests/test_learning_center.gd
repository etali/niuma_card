# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

const Catalog = preload("res://engine/tutorial_catalog.gd")
const Progress = preload("res://engine/tutorial_progress.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "主场景成功启动"): return
	var presentation: Node = main.drawer_presentation
	check(Catalog.ui("hub.invitation") == "第一次玩牛马牌？", "邀请语使用最新确认文案")
	presentation._invitation_offered = false
	presentation._offer_learning_invitation()
	check(presentation._learning_invitation.visible, "首次安全行动时显示简短邀请")
	presentation._learning_invitation.find_child("InvitationSkip", true, false).pressed.emit()
	check(Progress.invitation_seen() and not presentation._learning_invitation.visible, "直接开局关闭邀请并保存选择")
	check(Progress.record("income", 1, "viewed") and Progress.course("income").get("status") == "viewed", "演示与亲手完成分开记录")
	Progress.record("income", 2, "started")
	check(Progress.course("income").get("seen_demo", false), "继续练习保留演示记录")
	Progress.record("income", Catalog.course("income")["steps"].size(), "completed")
	Progress.record("income", 0, "started")
	check(Progress.course("income").get("status") == "completed", "重练不抹掉完成记录")
	presentation._rulebook_button.pressed.emit()
	await relayout_drawer(main)
	var book: Node = presentation._rulebook
	check(book.find_child("StartTutorial", true, false).text == Catalog.ui("hub.next_course", {"title": "扩大生意"}), "学完后推荐下一门课程")

	var original_rules: Dictionary = CardDB.GAME
	var original_source: String = CardDB.loaded_from
	CardDB.GAME = CardDB.GAME.duplicate(true)
	CardDB.GAME["win_cash"] = 137
	CardDB.loaded_from = "test-custom-rules"
	var original_state: GameState = main.state
	var original_pipe: RefCounted = main.pipe
	var original_tape: RefCounted = main.tape
	var original_board: Board = main.board
	var original_camera: Camera3D = main.board.camera
	var original_world: World3D = main.get_world_3d()
	var original_cards: Array = main.board.cards.duplicate()
	var original_groups: Array = main.board.groups
	var group_view := _group_state(main.board)
	var subviewports := _count_subviewports(root)
	var header: Control = presentation._header
	var footer: Control = presentation._footer
	var pass_button: Button = main.btn_pass
	var pass_before: bool = pass_button.disabled
	var original_mode: int = main.board.process_mode
	var original_touch: bool = main.board.touch_mode
	var original_attack: bool = main.board.attack_mode
	var original_locked: bool = main.board.input_locked
	var signals_before := _board_connections(main.board)
	var hash_before := StateCodec.state_hash(original_state)
	var join: Node = main._open_join_panel()
	check(join.visible and not main._network_join_pending(), "未连接的联机面板可与原局并存")
	var view_center: Vector2 = presentation.content_rect().get_center()
	presentation.camera_view.change(1.45, view_center, view_center + Vector2(50, -30))
	await relayout_drawer(main)
	check(presentation.camera_view.zoom > 1.0 and not presentation.camera_view.offset.is_zero_approx(), "开课前已有用户主动缩放和平移的观察位置")
	var view_before := _table_view(presentation)
	# 模拟尚未落稳的实体，教学要借用牌桌但保管完整原牌局。
	var airborne: CardEntity = original_cards[0]
	airborne.freeze = false
	airborne.sleeping = false
	airborne.position.y = 3.0
	airborne.linear_velocity = Vector3(0.6, -0.25, 0.2)
	airborne.angular_velocity = Vector3(0.0, 0.1, 0.0)
	var physical_before := _physics_state(airborne)
	var resting: CardEntity = original_cards[1]
	resting.freeze = true
	resting.sleeping = true
	var resting_before := _physics_state(resting)
	main._flush_record_view()
	var tape_before: Dictionary = main.tape.to_dict().duplicate(true)
	var saved_path: String = main.tape.save("before-tutorial.json")
	var saved_text := FileAccess.get_file_as_string(saved_path)
	book.find_child("Course_income", true, false).pressed.emit()
	await relayout_drawer(main)
	if need(presentation.tutorial != null and presentation.tutorial.session.course_id == "income",
		"点击课程名称直接启动所选教学，无需进入详情页"):
		var tutorial: Node = presentation.tutorial
		check(main.board == original_board and tutorial.arena.board == original_board, "整个教学复用进入前的原Board")
		check(main.board.camera == original_camera and tutorial.arena.get_world_3d() == original_world, "教学复用原相机和原World3D")
		check(_same_table_view(presentation, view_before), "开课浮层不移动牌桌：区域、镜头缩放偏移与六个世界点投影保持不变")
		check(_count_subviewports(root) == subviewports, "教学不创建任何SubViewport")
		check(not presentation._utility.visible, "开课关闭学习中心面板，不用新界面承载练习")
		check(presentation._header == header and presentation._footer == footer and header.visible and footer.visible, "原顶栏和底栏原位保留")
		check(main.btn_pass == pass_button and pass_button.visible and not pass_button.disabled, "原完成行动按钮继续可用")
		check(main._tutorial_active and not main._drawer_input_blocked(), "教学接管原局规则路由，同时允许原牌桌输入")
		check(not join.visible, "原联机弹层临时隐藏，不遮挡牌桌教学")
		var mascot: TextureRect = tutorial.find_child("TutorialMascot", true, false)
		var handle_source := _texture_source(main.drawer_window.get_handle_texture())
		check(mascot != null and not handle_source.is_empty() and _texture_source(mascot.texture) == handle_source,
			"对话小人与原抽屉入口同源，允许AtlasTexture裁去留白")
		var goal: Label = tutorial.find_child("TutorialGoal", true, false)
		check(goal != null and goal.is_visible_in_tree() and not goal.text.is_empty(), "小人旁常驻当前步骤的明确目标")
		check(PhysicsServer3D.space_is_active(original_world.space), "原世界保持物理拾取能力")
		for _frame in 40: await physics_frame
		check(_physics_state(airborne) == physical_before and _physics_state(resting) == resting_before,
			"原卡离场保管40物理帧，位置、冻结、睡眠、速度和碰撞仍完整保留")
		check(CardDB.loaded_from == CardDB.BUILTIN_PATH and int(CardDB.GAME["win_cash"]) == 100, "练习使用标准规则")
		check(main.state == tutorial.session.state and main.state != original_state, "原牌桌临时显示教学状态，原局对象另行保管")
		check(tutorial.find_children("*", "Button", true, false).size() == 1,
			"教学只保留退出按钮，没有下一步、更多、演示或重试面板")
		main.btn_pass.pressed.emit()
		await create_timer(0.8).timeout
		check(_same_table_view(presentation, view_before), "提前结束自动撤销也不改变牌桌位置、缩放和六点投影")
		tutorial.retry()
		await relayout_drawer(main)
		check(_same_table_view(presentation, view_before), "重试只重置练习，不重置用户原有镜头")
		check(StateCodec.state_hash(original_state) == hash_before and main.tape == original_tape and main.tape.to_dict() == tape_before,
			"重试不改原局状态、随机数或录像")
		check(FileAccess.get_file_as_string(saved_path) == saved_text, "教学不覆写已有存档")
		var escape := InputEventKey.new()
		escape.pressed = true
		escape.keycode = KEY_ESCAPE
		root.push_input(escape)
		check(not main._tutorial_active and presentation.tutorial == null, "Esc可直接结束小人教学")
		check(main.state == original_state and main.pipe == original_pipe and main.tape == original_tape, "退出恢复原state、pipe与录像对象")
		check(main.board == original_board and main.board.camera == original_camera and main.get_world_3d() == original_world, "退出始终保持原Board、相机和世界对象")
		check(_same_table_view(presentation, view_before), "退出关闭浮层时牌桌区域、缩放偏移与投影均不跳动")
		check(main.board.cards == original_cards and is_same(main.board.groups, original_groups) and _group_state(main.board) == group_view,
			"退出恢复原CardEntity引用、视觉组字典、顺序和展开形态")
		check(_physics_state(airborne) == physical_before and _physics_state(resting) == resting_before, "退出当帧精确恢复原卡所有物理参数")
		check(_board_connections(main.board) == signals_before, "退出恢复原Board信号，不遗留教学回调或重复交易")
		check(main.board.process_mode == original_mode and main.board.touch_mode == original_touch and main.board.attack_mode == original_attack and main.board.input_locked == original_locked,
			"退出恢复原Board输入模式与锁定状态")
		check(join.visible and main.btn_pass == pass_button and main.btn_pass.disabled == pass_before, "恢复原有弹层与行动按钮状态")
		check(CardDB.loaded_from == "test-custom-rules" and int(CardDB.GAME["win_cash"]) == 137, "退出恢复原自定义卡表的内存快照")
		check(StateCodec.state_hash(original_state) == hash_before and main.tape.to_dict() == tape_before, "退出未重开原局，录像不含教学事件")
	join._on_cancel()
	for _frame in 10: await physics_frame
	check(airborne.position != physical_before["transform"].origin, "退出后原来正在运动的卡继续运动")
	CardDB.GAME = original_rules
	CardDB.loaded_from = original_source
	# 直接关窗口也要释放离树保管的原牌，而非只能从对话退出。
	var stored_cards: Array = main.board.cards.map(func(card): return weakref(card))
	var cards_before_shutdown: Dictionary = CardDB.CARDS
	check(presentation.start_tutorial("income"), "正常退出后可再次开课以验证直接关闭场景")
	var arena_ref: WeakRef = weakref(main._tutorial_arena)
	var lesson_cards: Array = main.board.cards.map(func(card): return weakref(card))
	var context: RefCounted = main._tutorial_context
	await dispose_drawer(main)
	check(stored_cards.all(func(card): return not is_instance_valid(card.get_ref())), "直接关闭教学场景时释放全部离树保管的原牌")
	check(lesson_cards.all(func(card): return not is_instance_valid(card.get_ref())) and not is_instance_valid(arena_ref.get_ref()),
		"直接关闭时全部教学卡与Arena完整释放")
	check(not context.active and is_same(CardDB.CARDS, cards_before_shutdown) and is_same(CardDB.GAME, original_rules) and CardDB.loaded_from == original_source,
		"直接关闭清理教学上下文并恢复全局卡表")
	finish()

func _texture_source(texture: Texture2D) -> String:
	while texture is AtlasTexture:
		texture = texture.atlas
	return texture.resource_path if texture != null else ""

func _table_view(presentation: Node) -> Dictionary:
	var camera: Camera3D = presentation._main.board.camera
	var points: Array = []
	for point in [Vector3.ZERO, Vector3(-9, 0.05, -6), Vector3(9, 0.05, -6), Vector3(-9, 0.05, 6), Vector3(9, 0.05, 6), Vector3(0, 1, 0)]:
		points.append(camera.unproject_position(point))
	return {"content": presentation.content_rect(), "transform": camera.global_transform, "projection": camera.projection,
		"fov": camera.fov, "size": camera.size, "frustum": camera.frustum_offset,
		"zoom": presentation.camera_view.zoom, "offset": presentation.camera_view.offset, "points": points}

func _same_table_view(presentation: Node, expected: Dictionary) -> bool:
	var actual := _table_view(presentation)
	if not actual["content"].is_equal_approx(expected["content"]) or not actual["transform"].is_equal_approx(expected["transform"]): return false
	if actual["projection"] != expected["projection"] or not actual["frustum"].is_equal_approx(expected["frustum"]): return false
	for key in ["fov", "size", "zoom"]:
		if not is_equal_approx(float(actual[key]), float(expected[key])): return false
	if not actual["offset"].is_equal_approx(expected["offset"]): return false
	for index in actual["points"].size():
		if actual["points"][index].distance_to(expected["points"][index]) > 0.02: return false
	return true

func _group_state(board: Board) -> Array:
	var result: Array = []
	for group in board.groups:
		result.append({"uids": group["cards"].map(func(card): return card.uid), "compact": group.get("compact", false)})
	return result

func _count_subviewports(node: Node) -> int:
	var count := 1 if node is SubViewport else 0
	for child in node.get_children(): count += _count_subviewports(child)
	return count

func _board_connections(board: Board) -> Dictionary:
	var result := {}
	for signal_name in ["card_picked", "card_stacked", "card_dropped_table", "group_formed", "group_completed", "pile_toggled", "dropped_on_market", "dropped_on_pawn", "attack_clicked", "drag_broadcast"]:
		result[signal_name] = board.get_signal_connection_list(signal_name).map(func(connection): return connection["callable"])
	return result

func _physics_state(card: CardEntity) -> Dictionary:
	return {"transform": card.transform, "freeze": card.freeze, "sleeping": card.sleeping,
		"linear_velocity": card.linear_velocity, "angular_velocity": card.angular_velocity,
		"collision_layer": card.collision_layer, "collision_mask": card.collision_mask}
