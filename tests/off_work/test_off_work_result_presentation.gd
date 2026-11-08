# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 真实终局入口的气氛衔接、抽屉隐藏、布局与重开生命周期。
## 图形运行时可设 OFF_WORK_RESULT_CAPTURE_DIR，保存同一组真实结算截图。
const Game = preload("res://scenes/off_work_main.tscn")
var game: Node
var capture_dir := ""

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	capture_dir = OS.get_environment("OFF_WORK_RESULT_CAPTURE_DIR")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1600, 900)
	game = Game.instantiate()
	root.add_child(game)
	game.set_process(false)
	game.state.config.rules.bot.enabled = false
	game.audio.muted = true
	game.sfx.user_muted = true
	await _frames(3)
	await _terminal_event()
	await _hidden_result()
	await _hidden_shift()
	await _restart()
	await _result_variants()
	await _compact_layout()
	finish()

func _terminal_event() -> void:
	var state = game.state
	var rng_before: int = state._rng.state
	check(state.resign(1), "对手认输触发真实胜利事件")
	game._process(0.0)
	var backdrop = game.hud._off_work_finale
	check(is_instance_valid(backdrop), "胜负落定即开始牌桌气氛演出")
	check(not is_instance_valid(game.result_layer), "员工离场期间不提前遮住牌桌")
	check(backdrop.get_meta("pointer_passthrough", false), "气氛层不阻断抽屉的指针判断")
	var cards_before: Dictionary = state.cards.duplicate(true)
	await create_timer(0.1).timeout
	var age_before: float = backdrop.age
	game._process(float(game.settings.result.delay))
	check(is_instance_valid(game.result_layer), "离场结束后显示结果与重开按钮")
	check(game.hud._off_work_finale == backdrop and backdrop.age >= age_before, "结果出现沿用离场气氛，不重建或倒退时间")
	check(state.cards == cards_before and state._rng.state == rng_before, "终局演出不改卡牌和供牌随机序列")
	var shown_layer: CanvasLayer = game.result_layer
	game.hud.begin_off_work_finale(0)
	check(game.hud.result_layer == shown_layer and game.hud._off_work_finale == backdrop, "重复终局事件保留已显示面板与气氛")
	await _frames(3)
	var hero: Control = game.result_layer.find_child("OffWorkResultHero", true, false)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	hero.gui_input.emit(click)
	check(game.state.winner == 0 and is_instance_valid(game.result_layer), "点击主视觉只落定演出，不误触重开")
	check(backdrop.age >= 4.8, "跳过后纸屑进入完整终帧")

func _hidden_result() -> void:
	# 通过抽屉自己的面板挂起入口隐藏；树仍运行，才能捕获隐藏漏播。
	game.hud.clear_result()
	game._show_result()
	await _frames(2)
	var layer: CanvasLayer = game.result_layer
	var backdrop_layer: CanvasLayer = game.hud._off_work_finale_layer
	var backdrop = game.hud._off_work_finale
	var hero = layer.find_child("OffWorkResultHero", true, false)
	game.hud.suspend_panels()
	check(not layer.visible and not backdrop_layer.visible, "抽屉挂起同时隐藏结果和牌桌气氛")
	var backdrop_age: float = backdrop.age
	var hero_age: float = hero.age
	await create_timer(0.2, true).timeout
	check(is_equal_approx(backdrop.age, backdrop_age) and is_equal_approx(hero.age, hero_age), "隐藏结算时两段动画都暂停，后台不漏播")
	game.hud.resume_panels()
	await create_timer(0.08).timeout
	check(layer.visible and backdrop_layer.visible, "恢复抽屉同时恢复结果与气氛")
	check(backdrop.age > backdrop_age and hero.age > hero_age, "恢复后从隐藏前的时刻继续演出")

func _restart() -> void:
	var layer: CanvasLayer = game.result_layer
	var backdrop_layer: CanvasLayer = game.hud._off_work_finale_layer
	var animation: Tween = game.hud._off_work_result_animation
	var button: Button = layer.find_child("ResultRestart", true, false)
	check(button != null and not button.disabled, "结算阶段可立即再来一局")
	button.pressed.emit()
	game.set_process(false)
	await _frames(2)
	check(game.state.winner == -1 and game.result_layer == null, "重开按钮建立未结束的新对局")
	check(not is_instance_valid(layer) and not is_instance_valid(backdrop_layer), "重开释放旧结果和气氛层")
	check(animation == null or not animation.is_valid(), "重开取消延迟落印音效")
	check(game.hud._off_work_finale == null and game.hud._off_work_finale_layer == null, "新对局不残留终局灯光引用")

func _hidden_shift() -> void:
	game.set_shift_hidden(true)
	check(not game.result_layer.visible and not game.hud._off_work_finale_layer.visible, "切去上班玩法时隐藏下班终局")
	# 网络或存档恢复可能在班次隐藏时重建结果，不能闪到另一张桌面上。
	game._show_result()
	var backdrop = game.hud._off_work_finale
	var hero = game.result_layer.find_child("OffWorkResultHero", true, false)
	check(not game.result_layer.visible and not game.hud._off_work_finale_layer.visible, "隐藏班次里新建结果也保持隐藏")
	var backdrop_age: float = backdrop.age
	var hero_age: float = hero.age
	await create_timer(0.1, true).timeout
	check(is_equal_approx(backdrop.age, backdrop_age) and is_equal_approx(hero.age, hero_age), "其他班次前台运行时下班演出不推进")
	game.set_shift_hidden(false)
	check(game.result_layer.visible and game.hud._off_work_finale_layer.visible, "回到下班玩法恢复终局")

func _result_variants() -> void:
	for winner in [0, 1, 2]:
		var quoted := "所有人都走了，只有工作还在。" if winner == 1 else "今天到这儿。谁喊你全名都别回头。"
		var work_left := 23 if winner == 1 else 0
		await _prepare_terminal(winner, quoted)
		var layer: CanvasLayer = game.result_layer
		await create_timer(0.7).timeout
		await _frames(2)
		var backdrop = game.hud._off_work_finale
		var message: Label = layer.find_child("ResultMessage", true, false)
		var summary: Label = layer.find_child("ResultSummary", true, false)
		check((message == null) if winner == 2 else (message != null and message.text == quoted), "胜负使用给定吐槽，平局保持中性 %d" % winner)
		check(summary.text == (str(game.hud.hud_config.result.remaining) % work_left if winner == 1 else str(game.hud.hud_config.result.complete)), "结果仍显示真实剩余工作 %d" % winner)
		check(backdrop._paper.pieces.is_empty() if winner != 0 else not backdrop._paper.pieces.is_empty(), "纸屑只属于胜利，平局无胜负误导 %d" % winner)
		var celebration: float = backdrop._shade.material.get_shader_parameter("celebration")
		check(is_zero_approx(celebration) if winner == 1 else celebration > 0.0, "失败使用冷光，胜利和平局保持暖色 %d" % winner)
		_check_layout(layer, "常规窗口 %d" % winner)
		await _capture(["win", "lose", "tie"][winner])
		if winner == 0: await _terminal_replay()
	game.hud.clear_result()

func _terminal_replay() -> void:
	var live_state = game.state
	var path: String = game.replay.save(game)
	if not need(not path.is_empty() and FileAccess.file_exists(path), "保存真实胜局录像"): return
	var loaded: Dictionary = game._load_replay(path)
	if not need(loaded.ok, "加载包含终局的真实录像"): return
	var end_time: float = game.replay.playback.back().t
	game._process(end_time + 1.0)
	var first_backdrop: CanvasLayer = game.hud._off_work_finale_layer
	check(game.state.winner == 0 and is_instance_valid(first_backdrop), "录像播至终局出现胜利气氛")
	game.replay.seek(game, 0.0)
	check(game.state.winner == -1 and game.hud._off_work_finale_layer == null and game.result_layer == null,
		"录像倒带回开局清除终局气氛和结果面板")
	await _frames(1)
	check(not is_instance_valid(first_backdrop), "倒带释放上一轮终局背景")
	game._process(end_time + 1.0)
	check(game.state.winner == 0 and is_instance_valid(game.hud._off_work_finale_layer), "倒带后再次播至末端重新生成气氛")
	# 最后一帧由保存动作产生，没有 win 事件；直接定位也应显示终局气氛。
	game.replay.seek(game, end_time)
	check(game.state.winner == 0 and is_instance_valid(game.hud._off_work_finale_layer), "直接定位无事件的终局关键帧也有胜利气氛")
	game.stop_replay()
	check(not game.replay.playing and game.state == live_state and game.state.winner == 0,
		"退出录像恢复原来的已结束牌局")
	check(is_instance_valid(game.result_layer) and is_instance_valid(game.hud._off_work_finale_layer),
		"退出录像恢复原局结果与气氛")

func _prepare_terminal(winner: int, quoted: String) -> void:
	game.state.config.rules.initial.groups = [{"employee": 1}, {"work": 23}]
	game._new_game()
	game.set_process(false)
	var state = game.state
	for owner in [0, 1]:
		if winner != 2 and owner != winner: continue
		var employee := -1
		var work_group := -1
		for uid in state.cards:
			var card: Dictionary = state.cards[uid]
			if int(card.owner) != owner: continue
			if card.type == "employee": employee = int(uid)
			if card.type == "work": work_group = int(card.group)
		state.move_cards([employee], work_group)
	game.board.sync_state(state)
	state.drain_events()
	state.advance(10000.0)
	game._process(0.0)
	check(state.winner == winner, "自然清空工作得到预期胜负 %d" % winner)
	game.replay.result_taunt = quoted if winner != 2 else ""
	await create_timer(float(game.settings.result.delay)).timeout
	game._process(float(game.settings.result.delay))

func _compact_layout() -> void:
	# 手机横屏与较小桌面窗口都必须容纳完整主视觉、文案和操作。
	await _prepare_terminal(1, str(game.hud.hud_config.result.lose_taunts[0]))
	for mobile in [false, true]:
		game.mobile_mode = mobile
		game.hud.mobile_mode = mobile
		root.size = Vector2i(800, 450)
		await _frames(3)
		game.hud.relayout()
		game._show_result()
		var layer: CanvasLayer = game.result_layer
		await _frames(4)
		_check_layout(layer, "手机横屏" if mobile else "小窗口")
		var backdrop = game.hud._off_work_finale
		var focus: Vector2 = backdrop._shade.material.get_shader_parameter("focus")
		var expected: Vector2 = game.hud._off_work_result_focus()
		check((focus * root.get_visible_rect().size).distance_to(expected) < 0.5,
			"%s：缩放后冷光对准相机当前投影的待办堆" % ("手机横屏" if mobile else "小窗口"))
		await _capture("compact-mobile" if mobile else "compact-desktop")
		game.hud.clear_result()
	game.mobile_mode = false
	game.hud.mobile_mode = false

func _check_layout(layer: CanvasLayer, label: String) -> void:
	var viewport := root.get_visible_rect().grow(1.0)
	for node_name in ["ResultPanel", "OffWorkResultHero", "ResultTitle", "ResultSummary", "ResultRestart"]:
		var control: Control = layer.find_child(node_name, true, false)
		var contained := control != null and viewport.encloses(control.get_global_rect())
		var detail := "" if contained else "（%s / %s）" % [control.get_global_rect() if control != null else Rect2(), viewport]
		check(contained, "%s：%s 完整可见%s" % [label, node_name, detail])
	var message: Label = layer.find_child("ResultMessage", true, false)
	if message != null:
		check(viewport.encloses(message.get_global_rect()) and message.autowrap_mode != TextServer.AUTOWRAP_OFF, "%s：吐槽可换行且没有溢出" % label)
	var hero: Control = layer.find_child("OffWorkResultHero", true, false)
	var receipt: Control = layer.find_child("OffWorkResultReceipt", true, false)
	check(not hero.get_global_rect().intersects(receipt.get_global_rect()), "%s：主视觉与结果文字不重叠" % label)

func _frames(count: int) -> void:
	for i in count: await process_frame

func _capture(label: String) -> void:
	if capture_dir.is_empty() or DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute(capture_dir)
	await RenderingServer.frame_post_draw
	var path := capture_dir.path_join("off-work-result-%s.png" % label)
	check(root.get_texture().get_image().save_png(path) == OK, "保存真实结算截图 " + label)
