extends "res://tests/harness.gd"
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	# 帧序列回归按一倍速计算时间点，产品默认倍率由UI配置测试负责。
	UIConfig.set_hover_animation_speed(1.0)
	var art: Dictionary = UIConfig.read_section("art")
	check(art.hover.cards.size() == 31, "31 张牌均登记小图差分动画")
	check(art.hover.cards.values().all(func(config): return config.get("codec", "") == "hdelta-v1" and config.has("file") and not config.has("files")), "全部正式卡牌使用单文件差分动画")
	check(art.hover.cards.values().all(func(config): return config.frame_size.max() <= 384), "全部正式动作最长边不超过 384 像素")
	check(not art.has("motions"), "分层动画配置已移除")
	check(CardArt.hover_fps() == 12.0, "动作完整帧按 12 fps 播放")
	var holder := Node3D.new()
	root.add_child(holder)
	check(CardArt._hover_cache.is_empty() and CardArt._hover_loading.is_empty(), "没有悬停时不预载动作素材")
	for id in CardDB.all_cards():
		var card := CardEntity.new()
		card.freeze = true
		holder.add_child(card)
		card.setup(990001, id)
		var texture := card._icon.texture
		var geometry := card.transform
		var pixel_size := card._icon.pixel_size
		check(card._hover_frames.is_empty() and card._icon.material_override == null, "%s 创建时只有静止图，不同步加载动画" % id)
		card.set_hover_visual(true, false)
		card.set_process(false)
		check(card._icon.texture == texture, "%s 首次准备帧期间保持原图" % id)
		for attempt in 500:
			if not CardArt.hover_frames(id).is_empty():
				break
			await create_timer(0.01).timeout
		card._process(0)
		var config := CardArt.hover_config(id)
		check(card._hover_frames.size() == config.frames, "%s 按登记的实际帧数加载" % id)
		if card._hover_frames.size() != int(config.frames):
			card.queue_free()
			await process_frame
			finish()
			return
		check(CardArt.hover_frames(id) == card._hover_frames, "%s 多张牌共用同一组帧缓存" % id)
		card._process(.10)
		check(card._icon.texture == texture and card._hover_frame == 0, "%s 快速扫过仍显示原图" % id)
		card._process(.30)
		check(card._hover_frame == 3 and card._icon.texture == card._hover_frames[3], "%s 到 0.25 秒准确显示第 4 帧，不混帧" % id)
		check(card._icon.texture.get_size() == texture.get_size(), "%s 解码完整帧与静止小图同分辨率" % id)
		check(texture.get_width() <= 384 and texture.get_height() <= 384, "%s 静止小图最长边不超过 384" % id)
		check(card._icon.pixel_size == pixel_size, "%s 完整帧没有逐帧缩放与居中补偿" % id)
		var first_image := card._hover_frames[0].get_image() as Image
		var still_image := texture.get_image()
		if first_image.has_mipmaps():
			first_image.clear_mipmaps()
		if still_image.has_mipmaps():
			still_image.clear_mipmaps()
		check(first_image.get_data() == still_image.get_data(), "%s 差分首帧像素与静止小图完全一致" % id)
		check(card.transform == geometry, "%s 帧播放不移动卡牌或碰撞体" % id)
		card.hover_animation_paused = true
		card._process(.5)
		check(card._hover_frame == 3, "%s 暂停后保持当前帧" % id)
		card.hover_animation_paused = false
		card.seek_hover_animation(card.hover_animation_duration)
		if config.get("play_mode", "loop") == "once":
			check(card._icon.texture == card._hover_frames.back() and card._icon.pixel_size == pixel_size, "%s 一次动作结束保持原尺寸终态" % id)
		else:
			check(card._icon.texture == texture and card._icon.pixel_size == pixel_size, "%s 循环动作结束使用原尺寸原图" % id)
		card.set_hover_visual(false, false)
		check(not card.is_processing() and card._hover_elapsed == 0.0 and card._icon.texture == texture, "%s 移开后恢复原图并停止播放" % id)
		card.set_hover_visual(true, false)
		card._process(.8)
		card.set_drag_visual(true)
		check(not card.is_processing() and card._icon.texture == texture, "%s 拖动停止动画" % id)
		card.reset_interaction_visual()
		card.set_hover_visual(true, false)
		card._process(.8)
		card.set_face_down(true)
		check(not card.is_processing() and card._icon.texture == texture, "%s 翻面停止动画" % id)
		card.queue_free()
		check(CardArt._hover_cache.size() <= 3, "近期序列缓存不超过三个")
	await process_frame
	finish()
