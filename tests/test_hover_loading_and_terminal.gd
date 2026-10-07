extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _wait_loads() -> void:
	for attempt in 500:
		if CardArt._hover_loading.is_empty() and CardArt._hover_pending.is_empty():
			return
		await create_timer(0.01).timeout
	check(false, "后台请求应在超时前完成")

func _run() -> void:
	var card := CardEntity.new()
	root.add_child(card)
	card.setup(990101, "user")
	var original := card._icon.texture
	check(CardArt.hover_config("user").get("codec", "") == "hdelta-v1", "用户动画使用正式差分文件")
	check(original.get_width() <= 384 and original.get_height() <= 384, "静止原图已使用正式 384 小图")
	check(card._hover_frames.is_empty() and CardArt._hover_loading.is_empty(), "创建卡面不加载动画")
	card.set_hover_visual(true, false)
	check(card._icon.texture == original and not CardArt._hover_loading.is_empty(), "首次悬停后台请求，原图立即可见")
	var other := CardEntity.new()
	root.add_child(other)
	other.setup(990102, "user")
	other.set_face_down(true)
	check(CardArt._hover_pending.has("user"), "同类未悬停卡翻面不会取消当前卡的后台加载")
	other.set_face_down(false)
	other.set_hover_visual(true, false)
	card.set_hover_visual(false, false)
	check(CardArt._hover_pending.has("user"), "共享序列仍有使用者时不取消加载")
	other.set_hover_visual(false, false)
	check(not CardArt._hover_pending.has("user"), "快速移开取消未完成序列的使用")
	other.queue_free()
	await _wait_loads()
	check(CardArt._hover_loading.is_empty() and CardArt.hover_frames("user").is_empty(), "放弃的后台结果取出并释放，不滞留整套解码帧")
	card.set_hover_visual(true, false)
	await _wait_loads()
	card.set_process(false)
	card._process(0)
	check(card._hover_frames.size() == 36, "重新悬停仍能完整加载36帧")
	if card._hover_frames.size() != 36:
		card.queue_free()
		await process_frame
		finish()
		return
	check(card._hover_frames[0] == original, "差分初始停顿复用静止图纹理，不闪换")
	check(card._hover_frames.all(func(frame): return frame.get_size() == original.get_size()), "全部解码动作帧维持静止小图尺寸")
	var final_pose: Texture2D = card._hover_frames[12]
	var config := CardArt.hover_config("user")
	# 用已验收完整帧建立一个不可逆动作夹具，检验最终姿势不会被替换为原图。
	config.play_mode = "once"
	card._hover_frames = [original, final_pose]
	card.hover_animation_duration = 2.0 / CardArt.hover_fps()
	card._hover_elapsed = 10.0
	card._process(0)
	check(card._hover_frame == 1 and card._icon.texture == final_pose, "一次播放越过终点后保留最后完整帧")
	card._process(5.0)
	check(card._hover_frame == 1 and card._icon.texture == final_pose, "继续悬停不会倒放或循环重置")
	card.set_hover_visual(false, false)
	check(card._icon.texture == original and card._hover_frames.is_empty(), "移开恢复原图，卡面释放动作帧引用")
	config.play_mode = "loop"
	card.queue_free()
	await process_frame
	finish()
