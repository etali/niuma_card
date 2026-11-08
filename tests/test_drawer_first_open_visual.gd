# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## Use the real boot/shift compositor. A direct main-scene test skips the
## unbound native display that previously produced an empty warmup snapshot.
func _initialize() -> void:
	_run.call_deferred()

func _initial_mode() -> int:
	return 0

func _run() -> void:
	if not need(DisplayServer.get_name() != "headless", "首次展开检查使用真实桌面渲染器"):
		finish()
		return
	OS.set_environment("CARD_DRAWER_SIZE", "1280x800")
	var mode := _initial_mode()
	preload("res://engine/shift_slot.gd").save("last_mode", {"mode": mode})
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	while current_scene == null or not current_scene.has_method("switch_mode"):
		await process_frame
	var host := current_scene
	while not is_instance_valid(host.sign) or host.display.texture == null:
		await process_frame
	var drawer: DrawerWindow = host._drawer(host.tables[host.active])
	while drawer._warming:
		await process_frame
	check(host.active == mode and not drawer.is_expanded(), "班次 %d 从真实收起入口启动" % mode)
	if not need(drawer._snapshot != null, "首次展开已有预热快照"):
		finish()
		return
	var snapshot := drawer._snapshot.get_image()
	check(snapshot.get_size() == drawer.get_expanded_size(), "首次快照使用完整牌桌尺寸，不能捕获入口窗口")
	check(_opaque_interior(snapshot), "首次快照包含不透明桌布，不能只有上下操作条")
	drawer.pin()
	var tween := drawer._transition_tween
	if not need(tween != null, "首次点击保留原生展开动画"):
		finish()
		return
	tween.pause()
	for index in 7:
		if index > 0: tween.custom_step(DrawerWindow.EXPAND_DURATION * 0.12)
		await process_frame
		await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		var opaque := _opaque_interior(picture)
		check(drawer.is_transitioning() and opaque,
			"班次 %d 首次展开中间帧 %d：桌布与操作条同时呈现，中央无透明空洞" % [mode, index])
		if not opaque:
			DirAccess.make_dir_recursive_absolute("res://reports/drawer-first-open")
			picture.save_png("res://reports/drawer-first-open/mode-%d-frame-%d.png" % [mode, index])
	tween.custom_step(1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	check(drawer.is_expanded() and not drawer.is_transitioning() and _opaque_interior(root.get_texture().get_image()),
		"首次展开结束后完整牌桌继续显示")
	# The host preloads the other table in the background. Let that real task
	# finish before the harness frees the scripts it may still be compiling.
	await preload("res://scenes/boot.gd").packed_scene(self,
		preload("res://scenes/boot.gd").TABLE_SCENES[1 - mode])
	finish()

func _opaque_interior(picture: Image) -> bool:
	if picture == null or picture.is_empty(): return false
	# Several interior points catch a blank centre even when live GUI strips
	# above/below it are opaque; rounded outer corners remain unconstrained.
	for y in [0.25, 0.5, 0.75]:
		for x in [0.25, 0.5, 0.75]:
			if picture.get_pixel(int(picture.get_width() * x), int(picture.get_height() * y)).a < 0.99:
				return false
	return true
