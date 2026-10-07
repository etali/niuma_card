extends "res://tests/harness.gd"

const Resolution = preload("res://scenes/preview_art_resolution.gd")

func _initialize() -> void:
	call_deferred("_run")

func _wait_resolution(preview: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while preview._resolution_busy and Time.get_ticks_msec() < deadline:
		await process_frame
	return need(not preview._resolution_busy, "当前卡牌的分辨率准备能正常结束")

func _world_icon_width(card: CardEntity) -> float:
	return float(card._icon.texture.get_width()) * card._icon.pixel_size \
		* card._icon.global_transform.basis.x.length()

func _wait_attack(preview: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while preview._player_attack_busy != 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	return need(preview._player_attack_busy == 0, "撕牌结束后正常回到可播放状态")

func _check_quick_changes_and_attack(preview: Node) -> void:
	# 故意在后台处理旧卡时换牌、再改档位，不等旧请求完成。
	preview.set_resolution(0)
	preview.show_card("yunketang")
	var cloud_original: Texture2D = preview._cards[0]._hover_original
	preview.set_resolution(256)
	preview.show_card("cash")
	preview.set_resolution(256)
	check(preview._hover_pause.disabled and not preview._hover_seek.editable,
		"准备期间禁止暂停和拖动时间轴，避免操作被旧状态覆盖")
	if not await _wait_resolution(preview):
		return
	var cash: CardEntity = preview._cards[0]
	var cash_size := Vector2(Resolution.target_size(Vector2i(cash._hover_original.get_size()), 256))
	check(cash.def_id == "cash" and preview._resolution.get_selected_id() == 256 \
		and cash._icon.texture.get_size() == cash_size,
		"快速换牌和切档后显示最后选择的现金 256，不被旧请求覆盖")
	var mapping: Dictionary = cash.get("_preview_textures")
	var only_cash := mapping.has(cash._hover_original)
	var cash_frames: Array = CardArt.hover_frames("cash")
	for texture in mapping:
		only_cash = only_cash and (texture == cash._hover_original or cash_frames.has(texture))
	check(only_cash and not mapping.has(cloud_original),
		"完成的预览纹理只属于当前现金牌，没有混入云课堂")
	check(not preview._hover_pause.disabled and preview._hover_seek.editable,
		"当前档位准备完毕后恢复动作控制")

	preview._count.value = 2
	preview.set_page(1)
	if not await _wait_resolution(preview):
		return
	var attacked: CardEntity = preview._cards.back()
	attacked.set_hover_visual(true, false)
	attacked.hover_animation_paused = true
	attacked._process(0)
	attacked.seek_hover_animation(0.5)
	check(attacked._hover_frame == 6 and attacked._icon.texture.get_size() == cash_size,
		"攻击页悬停到非首帧仍使用所选尺寸，动画不会突然跳回原图")
	preview.play_attack()
	if not await _wait_attack(preview):
		return
	check(preview._cards.is_empty(), "第一轮撕牌完成后可重新补牌")
	var batches: int = preview.table_hands.batch_count
	preview.play_attack()
	check(preview._resolution_busy and preview._player_attack_busy == 0 \
		and preview.table_hands.batch_count == batches,
		"再次播放先准备新卡的缩小纹理，准备期间不抢先撕原图")
	preview.play_attack()
	var start_deadline := Time.get_ticks_msec() + 30000
	while preview._player_attack_busy == 0 and Time.get_ticks_msec() < start_deadline:
		await process_frame
	if not need(preview._player_attack_busy != 0, "缩小纹理准备完毕后自动开始第二轮撕牌"):
		return
	var all_small: bool = preview._cards.size() == 2
	for target in preview._cards:
		all_small = all_small and target._icon.texture.get_size() == cash_size
	check(all_small and not preview._resolution_busy \
		and preview.table_hands.batch_count == batches + 1,
		"重复点击只启动一批撕牌，补回的两张牌均已采用所选分辨率")
	if not await _wait_attack(preview):
		return

	# 使用真实后台缩放任务检查退出，不额外创建全库预览或模拟任务。
	preview.set_resolution(0)
	preview.set_page(0)
	preview.show_card("yunketang")
	preview.set_resolution(256)
	var task_deadline := Time.get_ticks_msec() + 5000
	while preview._resolution_tasks.is_empty() and preview._resolution_busy \
		and Time.get_ticks_msec() < task_deadline:
		await process_frame
	check(not preview._resolution_tasks.is_empty(), "退出回归覆盖真正正在处理的缩放任务")
	root.remove_child(preview)
	check(preview._resolution_tasks.is_empty(), "关闭准备中的预览会等待并回收后台任务")
	preview.free()
	await process_frame

func _run() -> void:
	check(Resolution.target_size(Vector2i(1254, 1254), 0) == Vector2i(1254, 1254),
		"原图档保持原生尺寸")
	check(Resolution.target_size(Vector2i(1254, 1254), 512) == Vector2i(512, 512),
		"正方形图片按所选长边缩小")
	check(Resolution.target_size(Vector2i(1310, 1201), 512) == Vector2i(512, 469),
		"连续包月的非方形图片保持长宽比并四舍五入")
	check(Resolution.target_size(Vector2i(600, 1200), 384) == Vector2i(192, 384),
		"纵向图片同样按长边限制尺寸")
	check(Resolution.target_size(Vector2i(128, 64), 512) == Vector2i(128, 64),
		"较小图片不会被放大")
	check(Resolution.option_label(Vector2i(384, 384), 1024) == "1024（保持 384）" \
		and Resolution.option_label(Vector2i(384, 384), 0) == "正式原图（384）",
		"分辨率选项明确显示正式源图尺寸，不把小图称作高清图")
	var source := Image.create(12, 6, false, Image.FORMAT_RGBA8)
	source.fill(Color(0.9, 0.7, 0.2, 0.6))
	source.set_pixel(0, 0, Color.TRANSPARENT)
	var source_bytes := source.get_data()
	var reduced: Image = Resolution.resize_image(source, 8)
	check(reduced != source and reduced.get_size() == Vector2i(8, 4),
		"缩小生成独立 Image，避免改写共享原图")
	check(reduced.has_mipmaps(), "缩小后的预览仍具有稳定缩放需要的采样图")
	check(source.get_size() == Vector2i(12, 6) and not source.has_mipmaps() \
		and source.get_data() == source_bytes, "缩小过程不改变源图尺寸、采样图或像素")

	var previous_card := OS.get_environment("CARD_PREVIEW_CARD")
	var previous_batch := OS.get_environment("CARD_PREVIEW_BATCH")
	var previous_resolution := OS.get_environment("CARD_PREVIEW_RESOLUTION")
	OS.set_environment("CARD_PREVIEW_CARD", "yunketang")
	OS.set_environment("CARD_PREVIEW_BATCH", "yunketang,cash")
	OS.set_environment("CARD_PREVIEW_RESOLUTION", "")
	var preview: Node = load("res://scenes/animation_preview.tscn").instantiate()
	root.add_child(preview)
	OS.set_environment("CARD_PREVIEW_CARD", previous_card)
	OS.set_environment("CARD_PREVIEW_BATCH", previous_batch)
	OS.set_environment("CARD_PREVIEW_RESOLUTION", previous_resolution)
	preview.set_process(false)
	await physics_frame
	await physics_frame
	if not need(preview.has_method("set_resolution") and preview.get("_resolution") != null,
			"独立预览提供分辨率控制"):
		preview.queue_free()
		finish()
		return
	var limits: Array[int] = []
	for index in preview._resolution.item_count:
		limits.append(preview._resolution.get_item_id(index))
	check(limits == [0, 1024, 768, 512, 384, 256], "预览提供原图到 256 的六个分辨率档位")
	check(preview._resolution.get_selected_id() == 0, "默认显示正式原图，不额外缩放")
	var card: CardEntity = preview._cards[0]
	var original: Texture2D = card._hover_original
	check(card.def_id == "yunketang" and card._icon.texture == original,
		"默认原图档使用现有云课堂静止插画")
	var original_width := _world_icon_width(card)
	var original_size := original.get_size()
	var reduced_size := Vector2(Resolution.target_size(Vector2i(original_size), 256))
	preview.set_resolution(1024)
	check(not preview._resolution_busy and preview._resolution_tasks.is_empty() \
		and card._icon.texture == original and preview._resolution_cache.is_empty(),
		"高于正式源图的档位直接使用原纹理，不加载或生成假高清动画")
	check(preview._resolution_note.text.contains("不放大") \
		and preview._resolution_note.text.contains("%d × %d" % [original_size.x, original_size.y]),
		"高档位说明显示真实像素尺寸，并明确不放大")
	check(not preview._hint.text.contains("待修复"), "差分动画在预览中正常识别为已完成动画")
	preview.set_resolution(0)
	preview._hover_seek.value = 0.5
	var load_deadline := Time.get_ticks_msec() + 30000
	while card._hover_frames.is_empty() and Time.get_ticks_msec() < load_deadline:
		await process_frame
	if not need(not card._hover_frames.is_empty(), "云课堂完整动画帧能够加载"):
		preview.queue_free()
		finish()
		return
	card.seek_hover_animation(0.5)
	var frames: Array = card._hover_frames.duplicate()
	var elapsed: float = card._hover_elapsed
	var frame_index: int = card._hover_frame
	var frame_texture: Texture2D = card._hover_frames[frame_index]
	var frame_size := frame_texture.get_size()
	check(card.hover_animation_paused and frame_index == 6, "比较前将动作固定在第 7 帧")
	preview.set_resolution(256)
	if not await _wait_resolution(preview):
		preview.queue_free()
		finish()
		return
	check(card._icon.texture.get_size() == reduced_size, "当前动画帧实际换成所选 256 档纹理")
	check(card._hover_frame == frame_index and is_equal_approx(card._hover_elapsed, elapsed) \
		and card.hover_animation_paused, "切档保持同一动画帧、时间和暂停状态")
	check(is_equal_approx(_world_icon_width(card), original_width),
		"降分辨率只改变清晰度，卡上插画的显示大小不变")
	check(card._hover_original == original and original.get_size() == original_size \
		and frame_texture.get_size() == frame_size, "原图和原始动画 Texture 均保持原尺寸")
	check(CardArt.hover_frames("yunketang") == frames and card._hover_frames == frames,
		"预览专用纹理不改写 CardArt 缓存或正式动画序列")
	preview.set_resolution(0)
	if not await _wait_resolution(preview):
		preview.queue_free()
		finish()
		return
	check(card._icon.texture == frame_texture and card._hover_frame == frame_index \
		and card.hover_animation_paused and is_equal_approx(card._hover_elapsed, elapsed),
		"暂停中切回原图恢复同一动画帧，不重新开始动作")
	preview.set_resolution(256)
	if not await _wait_resolution(preview):
		preview.queue_free()
		finish()
		return
	preview._hover_pause.button_pressed = false
	preview._update_hover(Vector2.ZERO)
	check(card._icon.texture.get_size() == reduced_size and card._hover_frames.is_empty(),
		"鼠标移开后静止插画仍采用所选分辨率")
	check(is_equal_approx(_world_icon_width(card), original_width),
		"静止状态的插画尺寸也不因分辨率变化而跳动")
	preview.set_resolution(0)
	if not await _wait_resolution(preview):
		preview.queue_free()
		finish()
		return
	check(card._icon.texture == original and card._hover_original == original,
		"切回原图恢复最初的静止纹理对象")
	check(is_equal_approx(_world_icon_width(card), original_width), "切回原图不改变插画显示大小")
	preview.set_resolution(256)
	if not await _wait_resolution(preview):
		preview.queue_free()
		finish()
		return
	var native_cash_size: Vector2 = CardArt.icon_texture("cash").get_size()
	preview.show_card("cash")
	if not await _wait_resolution(preview):
		preview.queue_free()
		finish()
		return
	var cash: CardEntity = preview._cards[0]
	check(preview._resolution.get_selected_id() == 256 and cash.def_id == "cash" \
		and cash._icon.texture.get_size() == Vector2(Resolution.target_size(Vector2i(native_cash_size), 256)),
		"切换卡牌后继续沿用所选分辨率")
	check(cash._hover_original.get_size() == native_cash_size,
		"换牌时现金原图仍保持原生尺寸")
	await _check_quick_changes_and_attack(preview)
	if is_instance_valid(preview):
		preview.queue_free()
	await process_frame
	finish()
