# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

const ResultPresentation = preload("res://scenes/result_presentation.gd")

class RecordedSound extends Sfx:
	var events: Array[String] = []
	func play(action: String, _pitch := 1.0) -> void:
		if not user_muted and (not drawer_suspended or Sfx.action(action).get("notification", false)):
			events.append(action)

var main: Node
var player: Control
var arena: Node3D
var sound: RecordedSound
var final_events: Array = []
var completed_courses: Array = []
var original_state: GameState
var original_snapshot: Dictionary
var original_cards: Array
var original_tape: Dictionary
var original_camera: Transform3D
var reference_controls: Dictionary = {}
var reference_surface: Color
var reference_sizes: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 教程胜利：真实最后一手、共享演出、结束后续课、取消隔离 ===")
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "原牌桌正常启动"): return
	main.drawer_presentation._learning_invitation.hide()
	original_state = main.state
	original_snapshot = StateCodec.snapshot(main.state)
	original_cards = main.board.cards.duplicate()
	original_camera = main.board.camera.global_transform
	main._flush_record_view()
	original_tape = main.tape.to_dict().duplicate(true)
	sound = RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	await _capture_shared_result_reference()
	await _victory_case("attack", "attack.win")
	await _victory_case("cashout", "cashout.win")
	await _cancel_during_result("attack", "attack.win", false)
	await _cancel_during_result("cashout", "cashout.win", true)
	check(_restored(), "全部胜利演出回归结束后原局、实体、录像和镜头保持原样")
	await dispose_drawer(main)
	finish()

func _capture_shared_result_reference() -> void:
	# 建立正式结果组件的结构/主题基准，不修改正在保管的正式牌局。
	var ended := GameState.new()
	StateCodec.restore(ended, original_snapshot)
	ended.winner = GameState.PLAYER
	ended.win_reason = "共享胜利视图基准"
	var view := ResultPresentation.create(main, ended, GameState.PLAYER, sound, func(): pass)
	ResultPresentation.present(view, main.drawer_presentation)
	await relayout_drawer(main)
	for key in ["ResultMascot", "ResultTitle", "ResultMessage", "ResultReason"]:
		var control: Control = view["panel"].find_child(key, true, false)
		reference_controls[key] = {"class": control.get_class(), "font": control.get_theme_font_size("font_size")}
	reference_surface = view["panel"].get_theme_stylebox("panel").bg_color
	check(view.get("animation") is Tween and view["panel"].find_child("ResultRestart", true, false) != null,
		"正式共用结果组件提供动画，且保留正常对局的重开入口")
	for pixels in [Vector2i(1280, 800), Vector2i(1600, 1000)]:
		root.size = pixels
		await _relayout_result()
		var fonts := {}
		for key: String in reference_controls:
			fonts[key] = view["panel"].find_child(key, true, false).get_theme_font_size("font_size")
		reference_sizes[str(pixels)] = fonts
		_check_geometry(view, "正式结果基准 %s" % pixels)
	var result_id: int = view["layer"].get_instance_id()
	ResultPresentation.close(view)
	await process_frame
	_check_unregistered(result_id, "共享close清理正式结果基准")
	root.size = Vector2i(1280, 800)
	await _relayout_result()

func _victory_case(course: String, target: String) -> void:
	if not await _prepare(course, target): return
	var scope: RefCounted = main._tutorial_context
	var generation := int(arena.session.generation)
	await _trigger_victory(course)
	check(arena.operation_pending and final_events.is_empty() and completed_courses.is_empty()
		and not player._awaiting_result, course + "：逻辑获胜后仍等待正式演出，没有抢先完成课程")
	if not need(await _wait_for_result(course, target, generation), course + "：胜利演出在有限时间内真正出现"): return
	var view: Dictionary = arena._result_view
	var layer: CanvasLayer = view["layer"]
	var panel: Control = view["panel"]
	var animation: Tween = view["animation"]
	var result_id := layer.get_instance_id()
	var mascot: Control = panel.find_child("ResultMascot", true, false)
	var presentation: Node = main.drawer_presentation
	check(presentation._external_panels.has(layer) and not presentation._learning_hidden_panels.has(layer),
		course + "：教学胜利登记到正式结果集合，教学聚焦不把它误藏")
	check(layer == _result_layer() and layer.layer == 10 and layer.visible
		and main.find_children("GameOver", "CanvasLayer", true, false).size() == 1,
		course + "：只出现一份真实共享胜利结果层")
	for key: String in reference_controls:
		var control: Control = panel.find_child(key, true, false)
		check(control != null and control.get_class() == reference_controls[key]["class"]
			and control.get_theme_font_size("font_size") == reference_controls[key]["font"],
			course + "：" + key + "复用正式结果控件和统一字号")
	check(panel.get_theme_stylebox("panel").bg_color.is_equal_approx(reference_surface)
		and panel.find_child("ResultTitle", true, false).text == "胜利"
		and panel.find_child("ResultReason", true, false).text == arena.state.win_reason,
		course + "：共享主题与真实胜利原因一致")
	check(panel.find_child("ResultRestart", true, false) == null,
		course + "：确认续课的胜利演出不提供重开正式对局按钮")
	check(arena.sfx == main.sfx and main.sfx == sound and sound.events.count("win") == 1
		and not sound.events.has("lose"), course + "：复用原Sfx，只播放一次正式胜利音效")
	check(animation != null and animation.is_valid() and animation.is_running(),
		course + "：展示由共享Tween驱动，不以静态面板冒充完整动画")
	if course == "attack":
		await _resize_result(view)
		await _collapse_result(view, course, target, generation)
	else:
		await _pause_result(view, course, target, generation)
	var first_alpha := panel.modulate.a
	var first_scale := mascot.scale
	var moved := false
	var held := true
	for attempt in 500:
		if not final_events.is_empty(): break
		held = held and player.session.course_id == course and player.session.current_step().get("id") == target \
			and int(player.session.generation) == generation and arena.operation_pending and main.btn_pass.disabled \
			and arena.board.input_locked and not player._awaiting_result and completed_courses.is_empty()
		if is_instance_valid(panel): moved = moved or not is_equal_approx(panel.modulate.a, first_alpha)
		if is_instance_valid(mascot): moved = moved or not mascot.scale.is_equal_approx(first_scale)
		await create_timer(0.02).timeout
	check(held and moved, course + "：真实淡入/小人动效播放时保持原课程、原步骤与输入锁")
	if not need(final_events.size() == 1, course + "：整段演出结束后只发一次操作完成"): return
	check(not animation.is_valid() or not animation.is_running(), course + "：发accepted前共享胜利Tween已经结束")
	check(final_events[0]["result"].get("expected", false) and not final_events[0]["result"].get("rolled_back", false)
		and final_events[0]["course"] == course and final_events[0]["step"] == target
		and not final_events[0]["result_layer_present"] and arena._result_view.is_empty(),
		course + "：accepted对应本步胜利，结果层先清理才开放确认续课")
	var next_id := TutorialCatalog.next_course_id(course)
	await create_timer(0.8).timeout
	check(player._awaiting_result and player.session.course_id == course and player.session.current_step().get("id") == target
		and completed_courses.is_empty(), course + "：胜利演完保留本课结果，不会计时跳到下一课")
	await _relayout_result()
	await _click(player._bubble.get_global_rect().get_center())
	for attempt in 120:
		if player.session.course_id == next_id: break
		await create_timer(0.025).timeout
	check(player.session.course_id == next_id and player.session.step_index == 0
		and completed_courses == [course] and player.arena == arena and main._tutorial_context == scope,
		course + "：演出完成并点击对白后进入配置中的下一课，继续复用原教学现场")
	check(_result_layer() == null and sound.events.count("win") == 1 and _original_untouched(),
		course + "：续课无胜利面板或重复声音残留，正式对局和录像未被写入")
	_check_unregistered(result_id, course + "确认续课清理胜利注册")

func _relayout_result() -> void:
	# 只等窗口/Container两帧排版；胜利Tween只有约2.3秒，不把resize误测成已播完。
	main.drawer_presentation.relayout()
	await process_frame
	await process_frame

func _check_geometry(view: Dictionary, label: String) -> void:
	var panel: Control = view["panel"]
	var layer: CanvasLayer = view["layer"]
	var rect := panel.get_global_rect()
	var available := Rect2(Vector2.ZERO, Vector2(root.size))
	check(available.grow(1.0).encloses(rect) and rect.get_center().distance_to(available.get_center()) < 1.0,
		label + "：Drawer管理居中与窗口边界")
	check(layer.scale.is_equal_approx(Vector2.ONE), label + "：画布保持原生像素，无教程私有fit缩放")

func _resize_result(view: Dictionary) -> void:
	var layer: CanvasLayer = view["layer"]
	var panel: Control = view["panel"]
	var animation: Tween = view["animation"]
	var before_font: int = panel.find_child("ResultTitle", true, false).get_theme_font_size("font_size")
	for pixels in [Vector2i(1600, 1000), Vector2i(1280, 800)]:
		root.size = pixels
		await _relayout_result()
		for key: String in reference_controls:
			var actual: int = panel.find_child(key, true, false).get_theme_font_size("font_size")
			check(actual == reference_sizes[str(pixels)][key], "%s resize：%s字号与正式结果一致" % [pixels, key])
		_check_geometry(view, "教程结果 %s" % pixels)
		if pixels.x == 1600:
			check(panel.find_child("ResultTitle", true, false).get_theme_font_size("font_size") > before_font,
				"真实放大窗口后教学胜利标题也增大，不保留旧窗口字号")
	check(arena._result_view["layer"] == layer and arena._result_view["animation"] == animation
		and animation.is_valid() and animation.is_running() and final_events.is_empty(),
		"窗口往返重排保留同一结果层与进行中的共享动画")

func _collapse_result(view: Dictionary, course: String, step: String, generation: int) -> void:
	var presentation: Node = main.drawer_presentation
	var layer: CanvasLayer = view["layer"]
	var panel: Control = view["panel"]
	var mascot: Control = panel.find_child("ResultMascot", true, false)
	var animation: Tween = view["animation"]
	main.drawer_window.collapse_now()
	var elapsed := animation.get_total_elapsed_time()
	var alpha := panel.modulate.a
	var scale := mascot.scale
	check(not main.drawer_window.is_expanded() and not layer.visible
		and presentation._external_panels.has(layer)
		and not presentation._learning_hidden_panels.has(layer),
		"真实collapse隐藏已登记的教学结果，不误归学习隐藏集合")
	await create_timer(2.6).timeout
	check(animation.is_valid() and is_equal_approx(animation.get_total_elapsed_time(), elapsed)
		and is_equal_approx(panel.modulate.a, alpha) and mascot.scale.is_equal_approx(scale),
		"收起超过完整演出时长，共享胜利Tween与画面精确暂停")
	check(final_events.is_empty() and completed_courses.is_empty() and arena.operation_pending
		and player.session.course_id == course and player.session.current_step().get("id") == step
		and int(player.session.generation) == generation,
		"收起期间未完成当前手、未记课程完成、未偷偷续课")
	main.drawer_window.pin()
	await process_frame
	await process_frame
	check(main.drawer_window.is_expanded() and main.drawer_window.is_pinned() and layer.visible
		and arena._result_view["layer"] == layer and arena._result_view["animation"] == animation
		and not presentation._suspended_panels.has(layer),
		"真实pin恢复同一结果与同一Tween，并清掉待恢复登记")
	check(animation.is_valid() and animation.get_total_elapsed_time() > elapsed and sound.events.count("win") == 1,
		"展开后从暂停处继续胜利动画，声音不重新播放")

func _has_panel_id(panels: Array, result_id: int) -> bool:
	for panel in panels:
		if is_instance_valid(panel) and panel.get_instance_id() == result_id: return true
	return false

func _check_unregistered(result_id: int, label: String) -> void:
	var presentation: Node = main.drawer_presentation
	check(not _has_panel_id(presentation._external_panels, result_id)
		and not _has_panel_id(presentation._suspended_panels, result_id)
		and not _has_panel_id(presentation._learning_hidden_panels, result_id),
		label + "：外部结果、收起待恢复和学习隐藏三集合均无残留")

func _pause_result(view: Dictionary, course: String, step: String, generation: int) -> void:
	var presentation: Node = main.drawer_presentation
	var layer: CanvasLayer = view["layer"]
	var panel: Control = view["panel"]
	var mascot: Control = panel.find_child("ResultMascot", true, false)
	var animation: Tween = view["animation"]
	presentation._open_utility(presentation.UTILITY_RULEBOOK)
	presentation._rulebook.show_atlas("cards")
	var elapsed := animation.get_total_elapsed_time()
	var alpha := panel.modulate.a
	var scale := mascot.scale
	check(player._reference_open and not layer.visible and arena.operation_pending
		and presentation._external_panels.has(layer) and not presentation._learning_hidden_panels.has(layer),
		"胜利演出中打开真实图鉴，隐藏结果层并保持本手未完成")
	await create_timer(3.0).timeout
	check(animation.is_valid() and is_equal_approx(animation.get_total_elapsed_time(), elapsed)
		and is_equal_approx(panel.modulate.a, alpha) and mascot.scale.is_equal_approx(scale),
		"查阅时间超过胜利完整展示时长，动画进度和画面仍精确暂停")
	check(final_events.is_empty() and completed_courses.is_empty() and player.session.course_id == course
		and player.session.current_step().get("id") == step and int(player.session.generation) == generation,
		"查阅胜利画面期间不会后台完成或偷偷进入下一课")
	presentation.close_panels()
	check(not player._reference_open and layer.visible and arena._result_view["layer"] == layer,
		"关闭图鉴后恢复同一胜利画面与剩余动画，不重新播放声音")

func _cancel_during_result(course: String, target: String, exiting: bool) -> void:
	if not await _prepare(course, target): return
	await _trigger_victory(course)
	if not need(await _wait_for_result(course, target, int(arena.session.generation)), "取消测试确实在真实胜利演出中"): return
	var old_arena: WeakRef = weakref(arena)
	var layer: WeakRef = weakref(arena._result_view["layer"])
	var result_id: int = arena._result_view["layer"].get_instance_id()
	var animation: Tween = arena._result_view["animation"]
	if exiting:
		await _click(main.drawer_presentation._end_tutorial_button.get_global_rect().get_center())
		check(main.drawer_presentation.tutorial == null and not main._tutorial_active, "胜利演出途中真实结束按钮仍能退出教学")
	else:
		main.drawer_window.collapse_now()
		check(not main.drawer_window.is_expanded() and not layer.get_ref().visible
			and main.drawer_presentation._external_panels.has(layer.get_ref()), "切课前真实收起，旧结果隐藏并仍登记在展示管理中")
		check(main.drawer_presentation.start_tutorial("income"), "胜利演出中允许明确切换其他课程")
		check(main.drawer_presentation.tutorial == player and player.arena == arena
			and arena.session.course_id == "income", "切课复用同一教学牌桌，取消旧胜利演出")
	await process_frame
	_check_unregistered(result_id, "显式取消胜利结果")
	if not exiting:
		main.drawer_window.pin()
		await process_frame
		check(_result_layer() == null, "取消后再pin展开不会从待恢复集合唤回旧结果")
	var new_state := StateCodec.snapshot(main.state)
	await create_timer(6.0).timeout
	check(layer.get_ref() == null and (not animation.is_valid() or not animation.is_running())
		and _result_layer() == null, "等待超过旧演出时长后，不残留面板、动画或晚到弹窗")
	check(final_events.is_empty() and completed_courses.is_empty(), "取消后的旧演出不发accepted，也不把旧课程记成完成")
	check(sound.events.count("win") == 1 and _original_untouched(), "取消后不重播胜利声音，不写原局或录像")
	if exiting:
		check(old_arena.get_ref() == null and _restored(), "演出中退出释放整套教学现场并完整恢复正式牌桌")
	else:
		check(arena.session.course_id == "income" and arena.session.step_index == 0
			and StateCodec.snapshot(main.state) == new_state and arena._result_view.is_empty(),
			"旧胜利回调不会覆盖新课程、改变其进度或重建旧面板")
		main.drawer_presentation.finish_tutorial(false)
		await process_frame
		await process_frame

func _wait_for_result(course: String, step: String, generation: int) -> bool:
	for attempt in 300:
		if not final_events.is_empty() or player.session.course_id != course \
			or player.session.current_step().get("id") != step or int(player.session.generation) != generation: return false
		if not arena._result_view.is_empty() and _result_layer() != null: return true
		await create_timer(0.02).timeout
	return false

func _prepare(course: String, target: String) -> bool:
	var presentation: Node = main.drawer_presentation
	if presentation.tutorial != null:
		presentation.finish_tutorial(false)
		await process_frame
	if not need(presentation.start_tutorial(course), "开启胜利课程 " + course): return false
	player = presentation.tutorial
	arena = player.arena
	# 仅用已有课程计划完成前置；胜利的最后一击/典当必须走真实根Viewport输入。
	for attempt in 42:
		if arena.session.current_step().get("id") == target: break
		var prepared: Dictionary = arena.session.run_example()
		if not prepared.get("ok", false) or not arena.session.step_complete: break
		arena.session.acknowledge()
	if not need(arena.session.current_step().get("id") == target, "真实规则前置抵达 " + target): return false
	if course == "attack":
		for action: Dictionary in arena.session.current_step().get("demo", []):
			if action.get("op") in ["groups", "round"]: arena.session._example_action(action)
	arena.sync_state(true)
	arena.board.touch_mode = true
	await create_timer(0.45).timeout
	if not need(arena.state.winner == "" and not arena.session.step_complete,
		"待测最后一手尚未获胜，目标没有被夹具预先完成"): return false
	final_events.clear()
	completed_courses.clear()
	sound.events.clear()
	arena.operation_finished.connect(_operation_finished)
	player.course_completed.connect(func(id): completed_courses.append(id))
	return true

func _trigger_victory(course: String) -> void:
	if course == "attack":
		var targets: Array = arena.session.applier.affordable_targets(GameState.PLAYER)
		var cash_targets: Array = targets.filter(func(target): return target.get("res") == CardDB.RES_CASH)
		if not need(cash_targets.size() == 1 and arena.state.resource_count(GameState.BOT, CardDB.RES_CASH) == 1,
			"真实攻击池只能命中对手最后一张现金"): return
		var card: CardEntity = arena.entities[int(cash_targets[0]["uids"][0])]
		await _click(main.board.camera.unproject_position(card.global_position))
	else:
		var legends: Array = arena.entities.values().filter(func(card): return card.draggable and card.def_id == "dujiaoshou")
		if not need(legends.size() == 1 and arena.session.phase == "action"
			and arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 70,
			"真实合成后的独角兽可在下一行动阶段典当，当前现金70"): return
		await _drag(legends[0], main.board.pawn_pos)
	check(arena.state.winner == GameState.PLAYER, course + "：最后一手由真实裁决产生胜者")
	if course == "cashout":
		check(arena.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == int(CardDB.game_rules()["win_cash"]),
			"典当真实支付三十现金并达到胜利线")

func _operation_finished(result: Dictionary) -> void:
	final_events.append({"result": result.duplicate(true), "course": arena.session.course_id,
		"step": arena.session.current_step().get("id"), "generation": int(arena.session.generation),
		"result_layer_present": _result_layer() != null})

func _result_layer() -> CanvasLayer:
	var layers: Array = main.find_children("GameOver", "CanvasLayer", true, false)
	for layer: CanvasLayer in layers:
		if not layer.is_queued_for_deletion(): return layer
	return null

func _original_untouched() -> bool:
	return StateCodec.snapshot(original_state) == original_snapshot and main.tape.to_dict() == original_tape

func _restored() -> bool:
	return main.state == original_state and main.board.cards == original_cards and _original_untouched() \
		and main.board.camera.global_transform.is_equal_approx(original_camera) and _result_layer() == null

func _click(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	root.push_input(press)
	await process_frame
	press.pressed = false
	root.push_input(press)
	await process_frame

func _drag(card: CardEntity, target: Vector3) -> void:
	main.board._reset_click_track()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = main.board.camera.unproject_position(card.global_position)
	press.global_position = press.position
	root.push_input(press)
	await process_frame
	check(main.board._drag_cards.has(card), "原Viewport按下真实独角兽，开始典当拖拽")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = main.board.camera.unproject_position(Vector3(target.x, Board.DRAG_HEIGHT, target.z) - main.board._grab_offset)
	motion.global_position = motion.position
	root.push_input(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = motion.position
	release.global_position = motion.position
	root.push_input(release)
	await process_frame
