# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

const Codec = preload("res://engine/state_codec.gd")
const TableSnapshot = preload("res://scenes/table_snapshot.gd")
var main: Node
var player: Control
var stage: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 简约牌桌教学：真实操作、确认结果、单手撤销 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原对局启动成功"): return
	# 到货仍使用正式随机挑空位；固定整条操作路线的表现RNG以便复现。
	seed(444)
	var p: Node = main.drawer_presentation
	p._learning_invitation.hide()
	var original_state: GameState = main.state
	var original_board: Board = main.board
	var original_camera: Camera3D = main.board.camera
	var original_world: World3D = main.get_world_3d()
	var original_cards: Array = main.board.cards.duplicate()
	var original_snapshot := Codec.snapshot(original_state)
	main._flush_record_view()
	var tape_snapshot: Dictionary = main.tape.to_dict().duplicate(true)
	var pass_button: Button = main.btn_pass
	var initial_view := _table_view()
	check(p.start_tutorial("income"), "从原牌桌开始一个回合的上手引导")
	player = p.tutorial
	stage = player.arena
	await create_timer(0.4).timeout
	check(stage.board == original_board and stage.camera == original_camera and stage.get_world_3d() == original_world,
		"整个教学复用原Board、相机和世界")
	check(stage.sfx == main.sfx, "直接复用正式牌桌音效对象")
	check(_same_table_view(initial_view), "开课只叠加小人，原牌桌六个世界点投影保持不变")
	check(player.find_children("*", "Button", true, false).size() == 1,
		"对话只保留退出按钮，不出现下一步、更多、演示菜单")
	check(player.session.current_step().get("kind") == "buy" and not player._goal.text.is_empty(), "开课直接显示买牌目标")
	var muted_before: bool = main.sfx.user_muted
	await _click_button(p._sound_button)
	check(main.sfx.user_muted == not muted_before and stage.sfx.user_muted == main.sfx.user_muted, "原声音开关控制唯一音效服务")
	await _click_button(p._sound_button)
	check(main.sfx.user_muted == muted_before, "原声音开关可恢复偏好")
	stage.board.touch_mode = true

	# 买错牌仍实际操作；整手撤销后资金、随机数、UID和原目标均保持。
	var before_wrong := Codec.snapshot(stage.state)
	var wrong_market: CardEntity = stage.market_cards[1]
	var cash_group: Dictionary = stage.board.group_of(_card("cash"))
	await _drag_pointer(cash_group["cards"][0], wrong_market.position)
	check(Codec.snapshot(stage.state) == before_wrong and _card("baoyue") == null,
		"买错业务后自动退回这一手，资源与随机状态完整恢复")
	check(player.session.current_step().get("kind") == "buy", "错误操作不推进目标")
	check(_same_table_view(initial_view), "回滚不挪动牌桌或重置镜头")

	var market: CardEntity = stage.market_cards[0]
	var price := int(CardDB.get_def(market.def_id)["price"])
	var cash_before: int = stage.state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	cash_group = stage.board.group_of(_card("cash"))
	await _drag_pointer(cash_group["cards"][0], market.position)
	await _wait_operation("split")
	check(stage.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before - price and _card("yunketang") != null,
		"真实买牌只扣一次费用，直接进入拆牌目标")
	check(Codec.snapshot(original_state) == original_snapshot and main.tape.to_dict() == tape_snapshot, "购买不写原局或录像")

	var users: Dictionary = stage.board.group_of(_card("user"))
	if users.get("compact", false): stage.board.toggle_compact(users["cards"][0])
	await create_timer(0.3).timeout
	await _drag_pointer(users["cards"][-1], Vector3(0.0, 0.05, 1.8))
	await _wait_operation("group")
	check(player.session.current_step().get("kind") == "group", "真实拆出一张用户后直接进入配牌目标")
	var business: CardEntity = _card("yunketang")
	for i in 3:
		var material := _unassigned_user(business)
		var group: Variant = stage.board.group_of(material)
		if group != null and group.get("compact", false):
			stage.board.toggle_compact(group["cards"][0])
			await create_timer(0.25).timeout
		await _drag_pointer(material, business.position)
		business = _card("yunketang")
		if i < 2:
			check(player.session.current_step().get("kind") == "group" and _business_user_count(business) == i + 1,
				"分次放入%d张用户保留正确的中间进展" % (i + 1))
	await _wait_operation("resolution")
	check(_business_user_count(business) == 3, "配齐三张用户后直接进入结算目标")
	var cash_at_settle: int = stage.state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var users_at_settle: int = stage.state.resource_count(GameState.PLAYER, CardDB.RES_USER)
	await _click_button(main.btn_pass)
	await _wait_operation("confirm")
	check(main.btn_pass == pass_button and stage.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_at_settle + 4,
		"点击原完成按钮真实产出4现金")
	check(stage.state.resource_count(GameState.PLAYER, CardDB.RES_USER) == users_at_settle and player.session.phase == "review"
		and stage.state.round_num == 1, "看收入步骤保留第一回合结果，不提前跳到下一回合")
	check(_same_table_view(initial_view), "按牌桌操作走到首次课末，始终不改变牌桌构图")
	await _check_course_clicks()
	check(p.tutorial == player and player.session.course_id == "growth" and player.arena == stage
		and not p._utility.visible, "首课点小人后直接接上扩大生意，继续使用同一教学牌桌")
	check(p._end_tutorial_button.visible and p._end_tutorial_button.text == "结束教程",
		"连续教学时怎么玩旁提供结束教程")
	await _click_button(p._end_tutorial_button)
	check(p.tutorial == null and not main._tutorial_active and not p._utility.visible,
		"结束教程按钮直接恢复原牌桌，不弹课程页")
	check(main.state == original_state and main.board.cards == original_cards
		and Codec.snapshot(original_state) == original_snapshot and main.tape.to_dict() == tape_snapshot,
		"完整教学结束后原局、原实体及录像保持原样")

	check(p.start_tutorial("income"), "可以再次从原桌开启引导")
	player = p.tutorial
	stage = player.arena
	await create_timer(0.3).timeout
	var before_early := Codec.snapshot(stage.state)
	await _click_button(main.btn_pass)
	await create_timer(0.8).timeout
	check(Codec.snapshot(stage.state) == before_early and player.session.phase == "action",
		"提前结束行动实际执行后自动回到操作前，而非错过当前目标")
	await _check_view_and_bounds()
	await _check_floating_dialogue()
	var center: Vector2 = p.content_rect().get_center()
	p.camera_view.change(1.6, center, center + Vector2(-40, 20))
	var view_before_exit := _table_view()
	stage.board._on_card_clicked(_card("cash"))
	stage._layout_changed()
	p.finish_tutorial()
	stage.sync_state(true)
	stage.highlight_focus()
	for frame in 8: await process_frame
	check(main.board == original_board and main.board.cards == original_cards and main.board._drag_cards.is_empty(), "退出与晚到回调不遗留教学拖牌")
	check(main.state == original_state and Codec.snapshot(original_state) == original_snapshot
		and main.tape.to_dict() == tape_snapshot, "退出后的延迟回调不能覆盖正式对局")
	check(_same_table_view(view_before_exit), "退出保留用户主动调整的视角")
	await dispose_drawer(main)
	finish()

func _business_user_count(card: CardEntity) -> int:
	var group: Variant = stage.board.group_of(card)
	return 0 if group == null else group["cards"].filter(func(c): return c.def_id == "user").size()

func _wait_operation(kind: String) -> void:
	for i in 300:
		if player.session.current_step().get("kind") == kind and not stage.operation_pending: break
		await create_timer(0.025).timeout
	if not need(player.session.current_step().get("kind") == kind and not stage.operation_pending
		and not player._awaiting_result, "普通操作及演出完成直接衔接%s，无需点对白" % kind): return
	var step: int = player.session.step_index
	var snapshot: Dictionary = player.session.capture_operation()
	await create_timer(0.65).timeout
	check(player.session.step_index == step and player.session.capture_operation() == snapshot,
		"下一目标空闲时稳定停留，不以计时器连跳")
	if kind == "resolution":
		check(not main.btn_pass.disabled and not stage.board.input_locked,
			"配好材料后原完成行动按钮直接可用，无额外确认")

func _check_course_clicks() -> void:
	# 检查点来自上面的真实买牌、拆牌、组牌和结算，只有准备重复输入用例才恢复它。
	var checkpoint: Dictionary = player.session.capture_operation()
	var visual := TableSnapshot.capture(main)
	var view := _table_view()
	var scope: RefCounted = main._tutorial_context
	var next_id := TutorialCatalog.next_course_id(str(player.session.course_id))
	var next_title := str(TutorialCatalog.course(next_id)["title"])
	for touch in [false, true]:
		if player.session.course_id != checkpoint["course_id"]:
			await _restore_reading_checkpoint(checkpoint, visual)
		var mode := "触摸" if touch else "鼠标"
		check(player._goal.text == "点我继续教程：" + next_title,
			"%s：跨课提示显示下一课真实标题" % mode)
		var outside: Vector2 = main.lbl_round.get_global_rect().get_center()
		for control in [player._mascot, player._goal]:
			var target: Vector2 = control.get_global_rect().get_center()
			await _pointer_sequence(outside, target, touch)
			check(player.session.course_id == checkpoint["course_id"] and player.session.step_index == checkpoint["step_index"],
				"%s：在对白外按下、在%s上释放不继续" % [mode, "小人" if control == player._mascot else "气泡"])
		var source: Vector2 = player._mascot.get_global_rect().get_center()
		var target := source + Vector2(-60, -45)
		var position_before: Vector2 = player.position
		await _pointer_sequence(source, target, touch, [target])
		check(player.position.distance_to(position_before) > 1 and player.session.course_id == checkpoint["course_id"]
			and player.session.step_index == checkpoint["step_index"] and player._pressed_control == null,
			"%s：拖小人移动对白，实际释放事件不触发继续" % mode)
		source = player._mascot.get_global_rect().get_center()
		target = source + Vector2(60, -35)
		await _pointer_sequence(source, source, touch, [target, source])
		check(player.session.course_id == checkpoint["course_id"] and player.session.step_index == checkpoint["step_index"]
			and player._pressed_control == null, "%s：拖过再回到起点释放也不算点击" % mode)
		source = player._goal.get_global_rect().get_center()
		target = source + Vector2(28, 0)
		position_before = player.position
		await _pointer_sequence(source, target, touch, [target])
		check(player.session.course_id == checkpoint["course_id"] and player.position.is_equal_approx(position_before),
			"%s：在气泡内拖动不继续，也不移动对白" % mode)
		if touch:
			for control in [player._mascot, player._goal]:
				var name := "小人" if control == player._mascot else "气泡"
				source = control.get_global_rect().get_center()
				await _pointer_sequence(source, source, true, [], true)
				check(player.session.course_id == checkpoint["course_id"] and player._pressed_control == null,
					"%s触摸取消释放清理手势，不继续教程" % name)
				await _push_touch(source, true, 0)
				await _push_touch(source, true, 1)
				await _push_touch(source, false, 1)
				check(player.session.course_id == checkpoint["course_id"],
					"%s上的第二根手指释放不能确认第一根手指的按下" % name)
				await _push_touch(source, false, 0, true)
				check(player.session.course_id == checkpoint["course_id"] and player._pressed_control == null,
					"%s双指后的原触摸取消不会遗留继续手势" % name)
		check(Codec.snapshot(stage.state) == checkpoint["state"] and stage.board._drag_cards.is_empty()
			and _same_table_view(view), "%s：对白手势不改牌局或镜头，也不留下牌桌拖拽" % mode)
		await _pointer_sequence(player._mascot.get_global_rect().get_center(), player._mascot.get_global_rect().get_center(), touch)
		check(player.session.course_id == next_id and player.session.step_index == 0 and player.arena == stage
			and main._tutorial_context == scope and player._pressed_control == null,
			"%s：真实点击小人由输入释放链继续到下一课，复用原教学现场" % mode)
		await _restore_reading_checkpoint(checkpoint, visual)
		await _pointer_sequence(player._goal.get_global_rect().get_center(), player._goal.get_global_rect().get_center(), touch)
		check(player.session.course_id == next_id and player.session.step_index == 0 and player.arena == stage
			and main._tutorial_context == scope, "%s：真实点击气泡和点击小人继续效果相同" % mode)

func _restore_reading_checkpoint(checkpoint: Dictionary, visual: Dictionary) -> void:
	player.switch_course(str(checkpoint["course_id"]))
	player.session.restore_operation(checkpoint)
	stage.sync_state(true, visual)
	await relayout_drawer(main)

func _check_view_and_bounds() -> void:
	var p: Node = main.drawer_presentation
	for extent in [Vector2i(1280, 800), Vector2i(960, 600), Vector2i(844, 390), Vector2i(390, 844)]:
		root.min_size = Vector2i.ZERO
		root.size = extent
		await relayout_drawer(main)
		var before := _table_view()
		var screen := Rect2(Vector2.ZERO, Vector2(extent)).grow(1)
		check(screen.encloses(player._goal.get_global_rect()) and screen.encloses(main.btn_pass.get_global_rect()), "%s：短目标与原完成按钮可见" % extent)
		check(p._header.visible and p._footer.visible, "%s：原有牌桌栏位保留" % extent)
		p.relayout()
		check(_same_table_view(before), "%s：对白布局不改变牌桌范围与投影" % extent)
	root.size = Vector2i(1280, 800)
	await relayout_drawer(main)

func _check_floating_dialogue() -> void:
	var before := _table_view()
	var source: Vector2 = player._mascot.get_global_rect().get_center()
	var target := source + Vector2(-80, -70)
	var position_before: Vector2 = player.position
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = source
	press.global_position = source
	root.push_input(press)
	await process_frame
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = target
	motion.global_position = target
	root.push_input(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = target
	release.global_position = target
	root.push_input(release)
	await relayout_drawer(main)
	check(player.position.distance_to(position_before) > 1 and stage.board._drag_cards.is_empty(), "拖小人只移动对白")
	check(_same_table_view(before), "拖小人不改变牌桌和相机")

func _table_view() -> Dictionary:
	var presentation: Node = main.drawer_presentation
	var camera: Camera3D = main.board.camera
	var points: Array = []
	for point in [Vector3.ZERO, Vector3(-9, 0.05, -6), Vector3(9, 0.05, -6), Vector3(-9, 0.05, 6), Vector3(9, 0.05, 6), Vector3(0, 1, 0)]:
		points.append(camera.unproject_position(point))
	return {"content": presentation.content_rect(), "transform": camera.global_transform, "projection": camera.projection,
		"fov": camera.fov, "size": camera.size, "frustum": camera.frustum_offset,
		"zoom": presentation.camera_view.zoom, "offset": presentation.camera_view.offset, "points": points}

func _same_table_view(expected: Dictionary) -> bool:
	var actual := _table_view()
	if not actual["content"].is_equal_approx(expected["content"]) or not actual["transform"].is_equal_approx(expected["transform"]): return false
	if actual["projection"] != expected["projection"] or not actual["frustum"].is_equal_approx(expected["frustum"]): return false
	for key in ["fov", "size", "zoom"]:
		if not is_equal_approx(float(actual[key]), float(expected[key])): return false
	if not actual["offset"].is_equal_approx(expected["offset"]): return false
	for index in actual["points"].size():
		if actual["points"][index].distance_to(expected["points"][index]) > 0.02: return false
	return true

func _card(def_id: String) -> CardEntity:
	for record in stage.state.players[GameState.PLAYER]["cards"]:
		if record["def_id"] == def_id: return stage.entities.get(record["uid"])
	return null

func _unassigned_user(business: CardEntity) -> CardEntity:
	var business_group: Variant = stage.board.group_of(business)
	for group in stage.board.groups:
		if is_same(group, business_group): continue
		if not group["cards"].is_empty() and group["cards"][-1].def_id == "user": return group["cards"][-1]
	for record in stage.state.players[GameState.PLAYER]["cards"]:
		var card: CardEntity = stage.entities[record["uid"]]
		if card.def_id == "user" and stage.board.group_of(card) == null: return card
	return null

func _drag_pointer(card: CardEntity, at: Vector3) -> void:
	stage.board._reset_click_track()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = stage.camera.unproject_position(card.global_position)
	root.push_input(press)
	await process_frame
	if stage.board._drag_cards.is_empty():
		print("拖牌被阻挡：目标=", card.def_id, " 投影=", press.position, " 教学浮层=", player.get_global_rect())
	check(not stage.board._drag_cards.is_empty(), "原Viewport真实按下事件开始拖拽")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = stage.camera.unproject_position(Vector3(at.x, Board.DRAG_HEIGHT, at.z) - stage.board._grab_offset)
	root.push_input(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = motion.position
	root.push_input(release)
	await create_timer(0.9).timeout

func _click_button(button: Control) -> void:
	var point := button.get_global_rect().get_center()
	await _pointer_sequence(point, point)

## 输入只送根Viewport；必须经过Player._input再到GUI，才能覆盖release被消费的真实路径。
func _pointer_sequence(source: Vector2, target: Vector2, touch := false, moves: Array = [], canceled := false) -> void:
	var press: InputEvent = InputEventScreenTouch.new() if touch else InputEventMouseButton.new()
	if touch:
		press.index = 0
	else:
		press.button_index = MOUSE_BUTTON_LEFT
		press.global_position = source
	press.pressed = true
	press.position = source
	root.push_input(press)
	await process_frame
	var previous := source
	for point: Vector2 in moves:
		var motion: InputEvent = InputEventScreenDrag.new() if touch else InputEventMouseMotion.new()
		motion.position = point
		motion.relative = point - previous
		if touch:
			motion.index = 0
		else:
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			motion.global_position = point
		root.push_input(motion)
		await process_frame
		previous = point
	var release: InputEvent = InputEventScreenTouch.new() if touch else InputEventMouseButton.new()
	if touch:
		release.index = 0
		release.canceled = canceled
	else:
		release.button_index = MOUSE_BUTTON_LEFT
		release.global_position = target
	release.position = target
	root.push_input(release)
	await process_frame

func _push_touch(point: Vector2, pressed: bool, index: int, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.position = point
	event.pressed = pressed
	event.index = index
	event.canceled = canceled
	root.push_input(event)
	await process_frame

func _canonical(groups: Array) -> String:
	var strings: Array = []
	for ids in groups:
		ids.sort()
		strings.append(str(ids))
	strings.sort()
	return str(strings)
