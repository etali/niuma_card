extends "res://tests/harness.gd"
const Motion = preload("res://scenes/card_motion.gd")
const Boot = preload("res://scenes/boot.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	check(Boot.entry_scene([]) == "res://scenes/main.tscn", "默认启动仍进入正式游戏")
	check(Boot.entry_scene(["--animation-preview"]) == "res://scenes/animation_preview.tscn", "独立入口直接选择预览，不启动牌局")
	UIConfig.save_preferences({"hover_animation_speed": 0.5})
	UIConfig.set_hover_animation_speed(0.5)
	var saved_preferences := FileAccess.get_file_as_string(UIConfig.USER_PATH)
	var engine_speed := Engine.time_scale
	var preview: Node = load("res://scenes/animation_preview.tscn").instantiate()
	root.add_child(preview)
	preview.set_process(false)
	await physics_frame
	check(preview._ids.size() == 31 and preview._buttons.size() == 31, "独立入口列出全部 31 张牌")
	check(preview._motion.get_script() == Motion, "预览与正式对局使用同一运动实现")
	check(not preview.table_hands.cursor_enabled, "悬停页使用小光标，避免遮挡主图动作")
	await _check_hover_speed(preview)
	for id in preview._ids:
		preview.show_card(id)
		await physics_frame
		await physics_frame
		var card: CardEntity = preview._cards[0]
		var original := card._icon.texture
		var pointer: Vector2 = preview._camera.unproject_position(card.global_position)
		check(preview.board._pick_card(pointer) == card, "%s 能通过真实射线选中" % id)
		preview._update_hover(pointer)
		for attempt in 500:
			if not CardArt.hover_frames(id).is_empty():
				break
			await create_timer(0.01).timeout
		card._process(0)
		card._process(0.7)
		check(card._icon.texture == card._hover_frames[card._hover_frame] and card._icon.material_override == null, "%s 使用完整帧或兼容图集，不运行分层运动" % id)
		check(preview._hover_controls.visible and preview._hover_seek.max_value == card.hover_animation_duration, "%s 可用暂停、慢放、逐帧时间轴" % id)
		preview._update_hover(Vector2.ZERO)
		check(card._icon.texture == original, "%s 移开恢复现有原图" % id)
		if id == "yunketang":
			preview._hover_seek.value = 0.50
			check(card.hover_animation_paused and card._hover_frame == 6, "拖动时间轴准确定位并暂停第 7 帧")
			preview._hover_original.button_pressed = true
			check(card._icon.texture == original, "暂停时可切换原静止图对照")
			preview._hover_original.button_pressed = false
			check(card._icon.texture == card._hover_frames[6], "退出原图对照恢复暂停帧")
			preview._hover_pause.button_pressed = false
			preview._update_hover(Vector2.ZERO)
			check(card._icon.texture == original and not card.is_processing(), "暂停后移开鼠标停止帧播放")
	preview.set_page(1)
	check(preview.table_hands.cursor_enabled, "撕牌页启用游戏中的手形光标")
	for count in [1, 5, 10]:
		preview.set_hover_animation_speed(2.0 if count == 1 else 0.5)
		preview._count.value = count
		preview._spread.button_pressed = count == 5
		preview._resource.select(1 if count == 10 else 0)
		preview.reset_attack()
		await physics_frame
		var targets: Array = preview._cards.duplicate()
		var batches: int = preview.table_hands.batch_count
		preview.play_attack()
		check(preview._player_attack_busy == 1 and preview._play.disabled, "播放期间锁住重复输入")
		preview.play_attack()
		preview.set_page(0)
		check(preview._page == 1 and preview.table_hands.batch_count == batches + 1, "%d 张只有一个批次，重复点击不叠加" % count)
		check(preview.table_hands._batches.back().count == count, "一双手持有完整 %d 张牌" % count)
		check(preview.board.cards.is_empty(), "抓握开始就撤掉被攻击牌的交互")
		if count == 1:
			await create_timer(Motion.BATCH_DURATION * 0.6).timeout
			check(preview._player_attack_busy == 1, "二倍插画速度不提前结束撕牌动作")
			await create_timer(Motion.BATCH_DURATION * 0.4 + 0.06).timeout
		else:
			await create_timer(Motion.BATCH_DURATION + 0.06).timeout
		check(preview._player_attack_busy == 0 and not preview._play.disabled, "播完解锁，可再次测试")
		check(targets.all(func(card): return not is_instance_valid(card)), "%d 张均通过正式撕牌动画退场" % count)
	preview.play_attack()
	check(preview._cards.size() == 10, "播放按钮自动补回同样的牌，便于反复比较")
	await create_timer(Motion.BATCH_DURATION + 0.06).timeout
	preview.set_page(0)
	check(preview._cards.size() == 1 and not preview.board.attack_mode, "返回悬停页恢复单卡预览")
	check(preview._hover_speed_slider.value == 0.5 and preview._cards[0].hover_animation_speed == 0.5,
		"切换到撕牌页再返回仍保留选定插画速度")
	check(Engine.time_scale == engine_speed and UIConfig.get_hover_animation_speed() == 0.5
		and FileAccess.get_file_as_string(UIConfig.USER_PATH) == saved_preferences,
		"预览调速不改变全局时间、游戏实时速度或游戏偏好文件")
	preview.queue_free()
	await process_frame
	var previous_batch := OS.get_environment("CARD_PREVIEW_BATCH")
	OS.set_environment("CARD_PREVIEW_BATCH", "baoyue,pinshaoshao,shuabuting,ditui,waimai,invalid,baoyue")
	var batch: Node = load("res://scenes/animation_preview.tscn").instantiate()
	root.add_child(batch)
	OS.set_environment("CARD_PREVIEW_BATCH", previous_batch)
	check(batch._ids == ["baoyue", "pinshaoshao", "shuabuting", "ditui", "waimai"], "本批预览只列指定五张，过滤未知和重复 ID")
	check(batch._buttons.size() == 5 and batch._selection == 0, "本批入口直接显示第一张，不回落到未列出的用户牌")
	batch.queue_free()
	await process_frame
	UIConfig.restore_preferences()
	finish()

func _check_hover_speed(preview: Node) -> void:
	var slider: HSlider = preview.get("_hover_speed_slider")
	var value: Label = preview.get("_hover_speed_value")
	if not need(slider != null and value != null, "独立预览提供动画速度滑块和倍速读数"):
		return
	check(slider.min_value == 0.5 and slider.max_value == 2.0 and is_equal_approx(slider.step, 0.1),
		"独立预览沿用UI配置中的速度范围和步进")
	check(slider.value == 2.0 and value.text.contains("2.0")
		and preview._cards[0].hover_animation_speed == 2.0,
		"预览默认二倍速来自UI默认值，不读取游戏已保存的半速")
	preview.show_card("user")
	await physics_frame
	await physics_frame
	var card: CardEntity = preview._cards[0]
	var pointer: Vector2 = preview._camera.unproject_position(card.global_position)
	preview._update_hover(pointer)
	card.set_process(false)
	var deadline := Time.get_ticks_msec() + 10000
	while CardArt.hover_frames("user").is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	card._process(0)
	if not need(not card._hover_frames.is_empty(), "调速检查使用已加载的真实用户牌动画"):
		return
	card._process(0.3)
	check(is_equal_approx(card._hover_elapsed, 0.6), "预览默认二倍速不再乘游戏的半速设置")
	var elapsed: float = card._hover_elapsed
	var frame: int = card._hover_frame
	var texture: Texture2D = card._icon.texture
	slider.value = 1.5
	check(card._hover_elapsed == elapsed and card._hover_frame == frame and card._icon.texture == texture,
		"拖动预览速度滑块保留当前播放进度与当前帧")
	card._process(0.2)
	check(is_equal_approx(card._hover_elapsed, elapsed + 0.3) and card._hover_frame == 9
		and card._icon.texture == card._hover_frames[9] and value.text.contains("1.5"),
		"预览下一次更新立即按一点五倍速度前进到准确帧")
	preview._hover_slow.button_pressed = true
	elapsed = card._hover_elapsed
	card._process(0.4)
	preview._update_hover(pointer)
	check(is_equal_approx(card.hover_animation_speed, 0.375)
		and is_equal_approx(card._hover_elapsed, elapsed + 0.15),
		"四分之一慢放乘当前选定倍率，一点五倍的慢放实际为0.375倍")
	check(preview._status.text.contains("0.375") and preview._status.text.contains("¼"),
		"预览底部显示当前实际倍率及慢放状态：%s" % preview._status.text)
	preview._hover_pause.button_pressed = true
	elapsed = card._hover_elapsed
	frame = card._hover_frame
	slider.value = 2.0
	card._process(0.4)
	check(card.hover_animation_paused and card._hover_elapsed == elapsed and card._hover_frame == frame
		and card.hover_animation_speed == 0.5,
		"暂停中调速保留画面，新的倍率为恢复播放做好准备")
	preview._hover_replay.pressed.emit()
	card.set_process(false)
	check(not card.hover_animation_paused and card._hover_elapsed == 0.0
		and slider.value == 2.0 and preview._hover_slow.button_pressed and card.hover_animation_speed == 0.5,
		"重新播放只复位动作，保留选定倍率与四分之一慢放")
	card._process(0.4)
	check(is_equal_approx(card._hover_elapsed, 0.2), "重新播放立即采用保留下来的实际半速")
	preview.show_card("cash")
	check(slider.value == 2.0 and preview._hover_slow.button_pressed
		and preview._cards[0].hover_animation_speed == 0.5,
		"更换卡牌继续使用选定倍率与慢放，不恢复默认速度")
	preview._hover_slow.button_pressed = false
	slider.value = 1.5
	check(preview._cards[0].hover_animation_speed == 1.5, "关闭慢放回到当前选定的一点五倍速")
