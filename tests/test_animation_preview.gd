extends "res://tests/harness.gd"
const Motion = preload("res://scenes/card_motion.gd")
const Boot = preload("res://scenes/boot.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	check(Boot.entry_scene([]) == "res://scenes/main.tscn", "默认启动仍进入正式游戏")
	check(Boot.entry_scene(["--animation-preview"]) == "res://scenes/animation_preview.tscn", "独立入口直接选择预览，不启动牌局")
	var preview: Node = load("res://scenes/animation_preview.tscn").instantiate()
	root.add_child(preview)
	preview.set_process(false)
	await physics_frame
	check(preview._ids.size() == 31 and preview._buttons.size() == 31, "独立入口列出全部 31 张牌")
	check(preview._motion.get_script() == Motion, "预览与正式对局使用同一运动实现")
	check(not preview.table_hands.cursor_enabled, "悬停页使用小光标，避免遮挡主图动作")
	for id in preview._ids:
		preview.show_card(id)
		await physics_frame
		await physics_frame
		var card: CardEntity = preview._cards[0]
		var original := card._icon.texture
		var pointer: Vector2 = preview._camera.unproject_position(card.global_position)
		check(preview.board._pick_card(pointer) == card, "%s 能通过真实射线选中" % id)
		preview._update_hover(pointer)
		card._process(0.7)
		check(card._icon.texture is AtlasTexture and card._icon.material_override == null, "%s 使用原动作图集播放" % id)
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
		await create_timer(Motion.BATCH_DURATION + 0.06).timeout
		check(preview._player_attack_busy == 0 and not preview._play.disabled, "播完解锁，可再次测试")
		check(targets.all(func(card): return not is_instance_valid(card)), "%d 张均通过正式撕牌动画退场" % count)
	preview.play_attack()
	check(preview._cards.size() == 10, "播放按钮自动补回同样的牌，便于反复比较")
	await create_timer(Motion.BATCH_DURATION + 0.06).timeout
	preview.set_page(0)
	check(preview._cards.size() == 1 and not preview.board.attack_mode, "返回悬停页恢复单卡预览")
	finish()
