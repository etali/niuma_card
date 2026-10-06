extends "res://tests/harness.gd"
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var art: Dictionary = UIConfig.read_section("art")
	check(art.hover.cards.size() == 31, "31 张牌均恢复上一版多帧图集")
	check(not art.has("motions"), "分层动画配置已移除")
	check(CardArt.hover_fps() == 12.0, "动作图集按 12 fps 播放")
	var holder := Node3D.new()
	root.add_child(holder)
	for id in CardDB.all_cards():
		var card := CardEntity.new()
		holder.add_child(card)
		card.setup(990001, id)
		var texture := card._icon.texture
		var geometry := card.transform
		var pixel_size := card._icon.pixel_size
		check(card._hover_frames.size() == 16 and card._icon.material_override == null, "%s 已恢复 16 帧，使用原图而非分层材质" % id)
		check(CardArt.hover_frames(id) == card._hover_frames, "%s 多张牌共用同一组帧缓存" % id)
		card.set_hover_visual(true, false)
		card._process(.10)
		check(card._icon.texture == texture and card._hover_frame == 0, "%s 快速扫过仍显示原图" % id)
		card._process(.30)
		check(card._hover_frame == 3 and card._icon.texture == card._hover_frames[3], "%s 到 0.25 秒准确显示第 4 帧，不混帧" % id)
		var config := CardArt.hover_config(id)
		var frame: AtlasTexture = card._icon.texture
		check(frame.region.position == Vector2(3 * config.cell_size[0], 0) and frame.filter_clip, "%s 取出对应格子且不串到邻帧" % id)
		check(is_equal_approx(card._icon.pixel_size * config.content_size[0], pixel_size * texture.get_width()), "%s 透明留白不改变主图显示比例" % id)
		check(card.transform == geometry, "%s 帧播放不移动卡牌或碰撞体" % id)
		card.hover_animation_paused = true
		card._process(.5)
		check(card._hover_frame == 3, "%s 暂停后保持当前帧" % id)
		card.hover_animation_paused = false
		card.seek_hover_animation(card.hover_animation_duration)
		check(card._icon.texture == texture and card._icon.pixel_size == pixel_size, "%s 动作结束使用原尺寸原图" % id)
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
	await process_frame
	finish()
