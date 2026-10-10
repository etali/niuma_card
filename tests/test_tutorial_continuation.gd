# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/support/drawer_fixture.gd"

const Progress = preload("res://engine/tutorial_progress.gd")
const OBSERVATION_TIME := 0.65
var main: Node
var presentation: Node
var completed_courses: Array = []
var visited_steps: Array = []
var confirmed_results: Array = []
var reading_count := 0
var automatic_steps: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌正常启动"): return
	presentation = main.drawer_presentation
	if is_instance_valid(presentation._learning_invitation): presentation._learning_invitation.hide()
	var original_state: GameState = main.state
	var original_cards: Array = main.board.cards.duplicate()
	var center: Vector2 = presentation.content_rect().get_center()
	presentation.camera_view.change(1.3, center, center + Vector2(24, -18))
	main._flush_record_view()
	var original_tape: Dictionary = main.tape.to_dict().duplicate(true)
	var original_hash := StateCodec.state_hash(main.state)
	var view := _view()
	check(presentation.start_tutorial("income"), "从第一课开启连续教学")
	var player: Node = presentation.tutorial
	var arena: Node = player.arena
	var scope: RefCounted = main._tutorial_context
	var board: Board = main.board
	player.course_completed.connect(func(id): completed_courses.append(id))
	var order: Array = TutorialCatalog.courses().map(func(course): return course["id"])
	for id in order:
		if not need(is_instance_valid(presentation.tutorial) and player.session.course_id == id, "%s 按配置顺序进入" % id):
			await dispose_drawer(main)
			finish()
			return
		await _complete_course(player)
		check(completed_courses.count(id) == 1 and Progress.course(id).get("status") == "completed", "%s 完成信号只发一次，并保存本课完成记录" % id)
		var next_id := TutorialCatalog.next_course_id(id)
		if not next_id.is_empty():
			check(presentation.tutorial == player and player.session.course_id == next_id and main._tutorial_context == scope
				and player.arena == arena and main.board == board and main._tutorial_active,
				"%s 完成后直接在同一Context、Arena、Board继续%s" % [id, next_id])
			check(not presentation._utility.visible and not arena.operation_pending and not arena._transition_busy
				and not player._awaiting_result and player._notice.is_empty(), "连续切课不会回首页，也不留下旧操作锁、确认状态或提示")
			check(_same_view(view), "连续切课保持原牌桌区域、相机、用户缩放和平移")
	check(completed_courses == order and presentation.tutorial == null and not main._tutorial_active, "只有八课全部学完并点击末课小人后才结束教程")
	check(visited_steps.size() == 42 and visited_steps.all(func(id): return visited_steps.count(id) == 1)
		and confirmed_results.size() + reading_count + automatic_steps.size() == 42
		and automatic_steps.size() == 15,
		"连续42步各完成一次：15项操作直接衔接，关键结果和阅读步骤点击继续")
	check(main.state == original_state and main.board.cards == original_cards and StateCodec.state_hash(main.state) == original_hash
		and main.tape.to_dict() == original_tape and _same_view(view), "连续八课后完整恢复原对局、原卡、录像和用户视角")
	await process_frame
	await _test_reference_and_switch()
	await _test_result_wait_lifecycle()
	await _test_middle_start()
	await _test_stop_during_transition()
	await dispose_drawer(main)
	finish()

func _complete_course(player: Node) -> void:
	var id: String = player.session.course_id
	var limit := 24
	while is_instance_valid(presentation.tutorial) and player.session.course_id == id and not player.session.completed and limit > 0:
		limit -= 1
		var step: Dictionary = player.session.current_step()
		var source_index: int = player.session.step_index
		visited_steps.append(step["id"])
		var result: Dictionary = player.session.run_example()
		if not need(result.get("ok", false) and player.session.step_complete, "%s 通过真实牌局目标" % step["id"]): return
		player.arena.sync_state(true)
		# 示例模型的拆牌结果含单张资源；同步后按示例精确恢复组，避免闲置资源整理合摞。
		player.arena.apply_groups(player.session.initial_groups)
		player.session.preview_groups(player.arena.current_groups())
		if player._reading_step():
			reading_count += 1
			if player._final_reading_step() and not TutorialCatalog.next_course_id(id).is_empty():
				var next_id := TutorialCatalog.next_course_id(id)
				check(player._goal.text == "点我继续教程：%s" % TutorialCatalog.course(next_id)["title"], "跨课提示只显示固定格式和下一课实际标题")
				# 改课程配置即可同步改对白，不另存一套继续教程标题。
				for course in TutorialCatalog.data()["courses"]:
					if course["id"] != next_id: continue
					var title: String = course["title"]
					course["title"] = "配置中的新课名"
					player._refresh()
					check(player._goal.text == "点我继续教程：配置中的新课名", "继续教程标题直接跟随课程配置")
					course["title"] = title
					player._refresh()
			await relayout_drawer(main)
			await _tap_goal(player)
		else:
			check(not player._awaiting_result, "%s：规则达标与同步桌面本身不提前触发结果确认" % step["id"])
			player._operation_finished({"expected": true, "rolled_back": false, "reason": ""})
			if str(step.get("advance", "confirm")) == "operation":
				automatic_steps.append(step["id"])
				check(player.session.course_id == id and int(player.session.step_index) == source_index + 1
					and not player._awaiting_result and not player.arena.operation_pending,
					"%s：操作完成事件立即衔接下一目标，不等待计时或多点一次对白" % step["id"])
				var next: Dictionary = player.session.capture_operation()
				var sentence: String = player._goal.text
				await create_timer(OBSERVATION_TIME).timeout
				check(player.session.capture_operation() == next and player._goal.text == sentence,
					"%s：衔接后空闲不会继续推进或自行更换对白" % step["id"])
				if step["id"] in ["income.settle", "cashout.resolve"]:
					var reading_id := "income.result" if step["id"] == "income.settle" else "cashout.value"
					check(player.session.current_step()["id"] == reading_id and player._reading_step() and player._can_tap(),
						"%s：直接进入已有阅读步骤，只保留一次确认" % step["id"])
				continue
			if not need(player._awaiting_result, "%s：关键结果按配置进入点击确认" % step["id"]): return
			confirmed_results.append(step["id"])
			var snapshot: Dictionary = player.session.capture_operation()
			var cards: Array = main.board.cards.duplicate()
			await create_timer(OBSERVATION_TIME).timeout
			check(player.session.current_step()["id"] == step["id"] and player.session.capture_operation() == snapshot
				and main.board.cards == cards and main.btn_pass.disabled and player.arena.board.input_locked and player._can_tap(),
				"%s：等待期间保留同一结果牌桌，时间经过不会自动跳过" % step["id"])
			var current: Dictionary = player.session.current_step()
			check(player._goal.text.contains(str(current.get("completion_goal", current.get("explanation", "")))),
				"%s：可见对白使用配置中的结果说明" % step["id"])
			check(not player._goal.text.contains("{card.") and not player._goal.text.contains("{lesson."),
				"%s：结算说明里的卡牌与当前业务变量全部展开" % step["id"])
			await relayout_drawer(main)
			var index: int = player.session.step_index
			if confirmed_results.size() % 2 == 0:
				await _tap_mascot(player)
			else:
				await _tap_goal(player)
			check(player.session.course_id != id or int(player.session.step_index) == index + 1,
				"%s：真实点击小人或气泡后仅继续一步" % step["id"])
		await process_frame
	if is_instance_valid(presentation.tutorial) and player.session.course_id == id and player.session.completed:
		check(TutorialCatalog.next_course_id(id).is_empty() and player._goal.text == TutorialCatalog.ui("coach.completed"), "非阅读末步完成后只在最终课程显示结束对白")
		await _tap_goal(player)

func _test_reference_and_switch() -> void:
	check(presentation.start_tutorial("income"), "再次开启时仍从指定课开始")
	var player: Node = presentation.tutorial
	var arena: Node = player.arena
	var scope: RefCounted = main._tutorial_context
	var view := _view()
	player.session.buy(0)
	arena.sync_state(true)
	player._operation_finished({"expected": true})
	check(not player._awaiting_result and player.session.current_step()["id"] == "income.split", "正确购牌成功后直接显示拆牌操作")
	player.set_reference_open(true)
	await create_timer(OBSERVATION_TIME).timeout
	check(player.session.course_id == "income" and player.session.step_index == 1 and not player._awaiting_result
		and arena.board.input_locked and main.btn_pass.disabled, "查阅页保留拆牌目标并锁桌面输入，不在后台推进")
	player.set_reference_open(false)
	await create_timer(OBSERVATION_TIME).timeout
	check(player.session.current_step()["id"] == "income.split" and not arena.operation_pending, "关闭查看页直接恢复拆牌操作，不需要确认已完成的购牌")
	var snapshot: Dictionary = player.session.capture_operation()
	check(player.switch_course("income") and player.session.capture_operation() == snapshot, "从列表点当前课继续原步骤，不重开当前课")
	player._notice = "旧错误提示"
	player._has_dragged = true
	player._floating_anchor = Vector2(0.13, 0.34)
	var anchor: Vector2 = player._floating_anchor
	player.set_reference_open(true)
	check(player.switch_course("attack") and player.session.course_id == "attack" and player.session.step_index == 0, "查看列表可直接切到指定课程起点")
	await create_timer(OBSERVATION_TIME).timeout
	check(player.arena == arena and main._tutorial_context == scope and player._floating_anchor == anchor and _same_view(view)
		and player._notice.is_empty() and not player._awaiting_result and arena.board.input_locked, "手动切课复用现场，保留小人位置与镜头，清旧确认和提示并保持查看锁")
	player.set_reference_open(false)
	check(not main.btn_pass.disabled and not arena.board.input_locked, "关闭查看页恢复新课程的第一步")
	player.switch_course("income")
	arena.finish_action()
	check(arena.operation_pending, "错误提前完成已排定旧课程单步回滚")
	check(player.switch_course("growth"), "旧回滚等待时仍可明确切换课程")
	var new_state := StateCodec.state_hash(player.session.state)
	await create_timer(arena.ROLLBACK_DELAY + 0.15).timeout
	check(player.session.course_id == "growth" and StateCodec.state_hash(player.session.state) == new_state and not arena.operation_pending,
		"切课使旧回滚失效，不把新课程还原成上一课")
	player.session.run_example()
	arena.sync_state(true)
	player._operation_finished({"expected": true})
	check(not player._awaiting_result and player.session.current_step()["id"] == "growth.groups"
		and player.switch_course("cashout"), "购牌事件已衔接下一目标时仍可切到另一课")
	await create_timer(OBSERVATION_TIME).timeout
	check(player.session.course_id == "cashout" and player.session.step_index == 0 and not player._awaiting_result, "旧结果等待不能跳过新课首步")
	var invalid_before: Dictionary = player.session.capture_operation()
	check(not player.switch_course("missing") and player.session.capture_operation() == invalid_before, "不存在的课程不会破坏当前教学")
	player.set_reference_open(true)
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	root.push_input(escape)
	check(presentation.tutorial == null and not main._tutorial_active, "查看暂停中也能随时按Esc结束教程")
	await process_frame

func _test_middle_start() -> void:
	var seen: Array = []
	check(presentation.start_tutorial("tactics"), "允许从指定中段课程进入连续教学")
	var player: Node = presentation.tutorial
	player.course_completed.connect(func(id): seen.append(id))
	await _complete_course(player)
	check(presentation.tutorial == player and player.session.course_id == "independent", "从取舍课完成后自动接自己经营，不退回前面课程")
	await _complete_course(player)
	check(seen == ["tactics", "independent"] and presentation.tutorial == null, "中段进入只沿配置顺序教完后续课程")
	await process_frame

func _test_result_wait_lifecycle() -> void:
	var player: Node = await _prepare_result_wait("buffs", "buff.protect_user")
	if not need(player != null, "结果确认生命周期从用户保护实际结算开始"): return
	var snapshot: Dictionary = player.session.capture_operation()
	var arena: Node = player.arena
	var scope: RefCounted = main._tutorial_context
	var view := _view()
	player.set_reference_open(true)
	await create_timer(OBSERVATION_TIME).timeout
	await _tap_goal(player)
	check(player._awaiting_result and player.session.capture_operation() == snapshot and not player._can_tap()
		and main.btn_pass.disabled and arena.board.input_locked, "查看页保留结算等待，点击对白或时间经过均不推进")
	player.set_reference_open(false)
	check(player._awaiting_result and player._can_tap() and main.btn_pass.disabled,
		"关闭查看页恢复同一结果确认，不解锁新回合行动或自动推进")
	check(player.switch_course("growth") and not player._awaiting_result
		and player.session.step_index == 0 and player.arena == arena and main._tutorial_context == scope and _same_view(view),
		"明确切课清掉旧结果等待并复用原桌，不触碰镜头")
	await create_timer(OBSERVATION_TIME).timeout
	await _tap_mascot(player)
	check(player.session.course_id == "growth" and player.session.step_index == 0 and not player._awaiting_result,
		"切课后的旧确认不能通过计时或点击跳过新课购牌目标")
	player = await _prepare_result_wait("buffs", "buff.protect_cash")
	if not need(player != null, "现金保护结算结果也进入确认等待"): return
	player.retry()
	await create_timer(OBSERVATION_TIME).timeout
	check(not player._awaiting_result and player.session.current_step()["id"] == "buff.output"
		and not player.arena.operation_pending and not main.btn_pass.disabled,
		"重试清空结果等待，回到本课起点且可正常操作")
	player = await _prepare_result_wait("tactics", "tactics.reply")
	if not need(player != null, "后手防御结算可等待观察"): return
	var old: WeakRef = weakref(player)
	player._close.pressed.emit()
	await process_frame
	check(presentation.tutorial == null and not main._tutorial_active and old.get_ref() == null,
		"等待结果时小人×直接退出，释放旧等待所属对象")
	check(presentation.start_tutorial("income"), "结束旧结果等待后可以正常重新开启教程")
	player = presentation.tutorial
	await create_timer(OBSERVATION_TIME).timeout
	check(not player._awaiting_result and player.session.current_step()["id"] == "income.buy",
		"重新开启后不继承旧确认或旧结果对白")
	presentation.finish_tutorial(false)
	await process_frame

func _prepare_result_wait(course: String, target: String) -> Node:
	if not presentation.start_tutorial(course): return null
	var player: Node = presentation.tutorial
	for attempt in 42:
		if player.session.current_step().get("id") == target: break
		var result: Dictionary = player.session.run_example()
		if not result.get("ok", false) or not player.session.step_complete: return null
		player.session.acknowledge()
	if player.session.current_step().get("id") != target: return null
	var result: Dictionary = player.session.run_example()
	if not result.get("ok", false) or not player.session.step_complete: return null
	player.arena.sync_state(true)
	player.arena.apply_groups(player.session.initial_groups)
	player.session.preview_groups(player.arena.current_groups())
	player._operation_finished({"expected": true, "rolled_back": false, "reason": ""})
	await relayout_drawer(main)
	return player if player._awaiting_result else null

func _test_stop_during_transition() -> void:
	presentation.start_tutorial("income")
	var player: Node = presentation.tutorial
	var seen: Array = []
	player.course_completed.connect(func(id): seen.append(id))
	player.session.buy(0)
	player.arena.sync_state(true)
	player._operation_finished({"expected": true})
	player._close.pressed.emit()
	await create_timer(OBSERVATION_TIME).timeout
	check(presentation.tutorial == null and not main._tutorial_active and seen.is_empty(), "小人×立即终止，旧等待不会偷偷完成或开启下一课")

func _tap_goal(player: Node) -> void:
	var point: Vector2 = player._goal.get_global_rect().get_center()
	await _tap_point(point)

func _tap_mascot(player: Node) -> void:
	await _tap_point(player._mascot.get_global_rect().get_center())

func _tap_point(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	root.push_input(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = point
	root.push_input(release)
	await process_frame

func _view() -> Dictionary:
	var camera: Camera3D = main.board.camera
	return {"content": presentation.content_rect(), "transform": camera.global_transform, "fov": camera.fov,
		"zoom": presentation.camera_view.zoom, "offset": presentation.camera_view.offset,
		"left": camera.unproject_position(Vector3(-7, 0.05, 3)), "right": camera.unproject_position(Vector3(7, 0.05, -3))}

func _same_view(expected: Dictionary) -> bool:
	var actual := _view()
	return (actual["content"].is_equal_approx(expected["content"]) and actual["transform"].is_equal_approx(expected["transform"])
		and is_equal_approx(actual["fov"], expected["fov"]) and is_equal_approx(actual["zoom"], expected["zoom"])
		and actual["offset"].is_equal_approx(expected["offset"]) and actual["left"].distance_to(expected["left"]) < 0.02
		and actual["right"].distance_to(expected["right"]) < 0.02)
