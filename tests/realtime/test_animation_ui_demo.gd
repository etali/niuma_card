extends SceneTree
const Demo = preload("res://scenes/work_animation_ui_demo.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	Palette._cfg = UIConfig.builtin_section("palette")
	Palette._loaded = true
	var window_size := root.size
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var demo := Demo.new()
	viewport.add_child(demo)
	demo.configure("drawer", viewport)
	check(not demo.drawer._use_os_window, "drawer never controls native window")
	var closed: Rect2i = demo.snapshot().drawer_geometry
	for i in 60: demo.advance(1.0 / 60.0)
	var opening: Rect2i = demo.snapshot().drawer_geometry
	check(opening.size.x > closed.size.x, "drawer starts actual cubic reveal")
	for i in 30: demo.advance(1.0 / 60.0)
	var expanded: Rect2i = demo.snapshot().drawer_geometry
	check(expanded == demo.drawer._rect_for(true), "expanded geometry matches formal drawer")
	check(demo.content.size == Vector2(expanded.size), "clipping never squashes content")
	await capture(viewport, "drawer")
	for i in 105: demo.advance(1.0 / 60.0)
	check(demo.snapshot().drawer_geometry == closed, "collapse returns to original handle geometry")
	check(root.size == window_size, "preview leaves outer window size untouched")
	demo.free()
	demo = Demo.new()
	viewport.add_child(demo)
	demo.configure("drawer_mascot", viewport)
	check(demo.mascot is DrawerMascot, "uses original mascot implementation")
	var tilt_max := 0.0
	for i in 720:
		demo.advance(1.0 / 60.0)
		if demo.mascot._motion and demo.mascot._motion.is_valid():
			demo.mascot._motion.pause()
			demo.mascot._motion.custom_step(1.0 / 60.0)
		tilt_max = maxf(tilt_max, absf(demo.mascot._face_tilt))
	check(tilt_max > 0.02, "real mascot tween waves under preview time")
	check(demo.mascot.state() == "defeat", "preview includes terminal mascot state")
	await capture(viewport, "mascot")
	demo.free()
	for winner in [0, 1, 2]:
		demo = Demo.new()
		viewport.add_child(demo)
		demo.configure("result", viewport)
		demo.reveal_result(winner, 5)
		check(demo.snapshot().result_visible, "real result panel is present for outcome %s" % winner)
		var expected: String = [demo.result_hud.hud_config.result.win, demo.result_hud.hud_config.result.lose, demo.result_hud.hud_config.result.tie][winner]
		var labels := demo.result_hud.result_layer.find_children("*", "Label", true, false)
		check(labels.any(func(label): return label.text == expected), "original result copy for outcome %s" % winner)
		await capture(viewport, "result-%d" % winner)
		demo.free()
	viewport.free()
	await process_frame
	check(not DirAccess.dir_exists_absolute(OS.get_environment("WORK_DATA_DIR")), "UI preview never creates player directory")
	for failure in failures: push_error(failure)
	print("ANIMATION_UI_DEMO: %d 通过 / %d 失败" % [checks - failures.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)

func capture(viewport: SubViewport, suffix: String) -> void:
	if not OS.has_environment("WORK_UI_DEMO_SHOTS"): return
	await process_frame
	RenderingServer.force_draw(false)
	viewport.get_texture().get_image().save_png("res://reports/preview-ui-%s.png" % suffix)
