extends SceneTree

## Capture the actual preview timeline, including the middle of its opening
## animation. No fabricated card geometry, UI state or logical groups.
const Runner = preload("res://scenes/off_work_animation_scenario.gd")

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var viewport := SubViewport.new()
	viewport.size = root.size
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var runner := Runner.new()
	viewport.add_child(runner)
	runner.load_scenario("side_extract")
	await process_frame
	for shot in [
		{"time": 1.08, "name": "opening"},
		{"time": 1.5, "name": "personnel"},
		{"time": 2.5, "name": "cut"},
		{"time": 7.5, "name": "work"},
	]:
		runner.seek(float(shot.time))
		await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		var result := viewport.get_texture().get_image().save_png("res://reports/side-extract-vertical-%s.png" % shot.name)
		print("SIDE_EXTRACT_ANIMATION_CAPTURE ", shot.name, " result=", result)
	viewport.queue_free()
	await process_frame
	await process_frame
	quit()
