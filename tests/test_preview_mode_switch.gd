# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Boot = preload("res://scenes/boot.gd")
const LARGER_WINDOW := Vector2i(1920, 1080)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	check(Boot.entry_scene(["--off-work-playtest", "--cards-config=example"]) == "res://scenes/shift_host.tscn", "下班试玩使用可切换的游戏宿主")
	check(Boot.entry_scene(["--cards-config=example"]) == "res://scenes/shift_host.tscn", "上班试玩使用可切换的游戏宿主")
	if not need(DisplayServer.get_name() != "headless", "逐帧检查使用桌面渲染器"):
		finish()
		return
	change_scene_to_file(Boot.entry_scene(["--animation-preview"]))
	await scene_changed
	var host := current_scene
	root.size = LARGER_WINDOW
	for i in 4: await RenderingServer.frame_post_draw
	var native_size := root.size
	var start := root.get_texture().get_image()
	var mode_switch := host.find_child("PreviewModeSwitch", true, false)
	if not need(mode_switch and mode_switch.get_node("OnWork").button_pressed and host._ids.size() > 0,
			"独立入口打开上班完整预览"):
		finish()
		return
	check(native_size.x > 1440 and start.get_width() == native_size.x, "实际渲染窗口已放大")
	var controls := [host._sidebar, host._heading, host._hover_seek, host._hover_pause, host._hover_speed_slider, host._hover_original]
	# Include the newly exposed right and bottom regions beyond the original window.
	var probes: Array[Vector2i] = [
		Vector2i(3, 3), Vector2i(native_size.x - 5, 5),
		Vector2i(native_size.x - 5, native_size.y / 2), Vector2i(native_size.x / 2, native_size.y - 5),
		Vector2i(native_size.x - 4, native_size.y - 4)]
	for index in 4:
		var destination := "OffWork" if index % 2 == 0 else "OnWork"
		if index == 2:
			_click(host._magnify)
			check(host._large.visible, "大窗中的放大插画可从真实控件打开")
		_click(mode_switch.get_node(destination))
		var clean := true
		for i in 10:
			await RenderingServer.frame_post_draw
			var frame := root.get_texture().get_image()
			if frame.get_size() != native_size or root.size != native_size or _has_blank_patch(frame):
				clean = false
				continue
			for point in probes:
				if frame.get_pixelv(point) != start.get_pixelv(point): clean = false
		check(clean, destination + " 切换全程保留大窗尺寸与背景，未出现透明或黑色块")
		if not need(current_scene == host and is_instance_valid(mode_switch), "切换沿用原预览场景与班次按钮"):
			finish()
			return
		check(host.off_duty == (destination == "OffWork") and mode_switch.get_node(destination).button_pressed, "鼠标点击切换到对应班次")
		check(controls == [host._sidebar, host._heading, host._hover_seek, host._hover_pause, host._hover_speed_slider, host._hover_original],
			"两种玩法使用同一侧栏、标题与播放控制实例")
		if host.off_duty:
			if not need(is_instance_valid(host.work_preview) and not host.work_preview.entries.is_empty(), "下班完整动作目录可选"):
				finish()
				return
		check(_has_artwork(root.get_texture().get_image(), host._surface),
			"切换后预览台实际绘制%s" % ("放大插画" if index >= 2 else "完整牌面"))
		if index >= 2:
			check(host._large.visible and host._large.texture != null, "切换班次后保持放大状态和对应贴图")
	finish()

func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.position = point
		e.pressed = pressed
		root.push_input(e, true)

## Catch a black subviewport in the interior even when the sidebar and other
## shell controls kept drawing. A few dark pixels on printed text are expected.
func _has_blank_patch(image: Image) -> bool:
	var pixels := image.get_size()
	var blank_runs := PackedInt32Array()
	blank_runs.resize(48)
	for y in 30:
		var horizontal := 0
		for x in blank_runs.size():
			var sample := image.get_pixel((x + 0.5) * pixels.x / 48.0, (y + 0.5) * pixels.y / 30.0)
			var blank := sample.a < 0.1 or maxf(maxf(sample.r, sample.g), sample.b) < 0.055
			blank_runs[x] = blank_runs[x] + 1 if blank else 0
			horizontal = horizontal + 1 if blank_runs[x] >= 3 else 0
			if horizontal >= 3: return true
	return false

func _has_artwork(image: Image, area: Rect2) -> bool:
	var background := image.get_pixel(3, 3)
	var ink := 0
	for row in 16:
		for col in 16:
			var p := area.position + area.size * Vector2((col + 0.5) / 16.0, (row + 0.5) / 16.0)
			var colour := image.get_pixelv(Vector2i(p))
			if colour.a > 0.9 and absf(colour.r - background.r) + absf(colour.g - background.g) + absf(colour.b - background.b) > 0.12:
				ink += 1
	return ink >= 4
