extends SceneTree
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
	runner.load_scenario("huge_stack_extract")
	await process_frame
	var stages: Array = ["initial", "expanded", "personnel_cut", "personnel_dropped", "work_cut", "work_dropped", "finished"]
	if OS.has_environment("WORK_HUGE_RENDER_STAGES"): stages = OS.get_environment("WORK_HUGE_RENDER_STAGES").split(",")
	for stage in stages:
		runner.seek(float(runner.entry.preview_checks[stage]))
		await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		var result := viewport.get_texture().get_image().save_png("res://reports/huge-stack-preview-%s.png" % stage)
		print("HUGE_STACK_CAPTURE ", stage, " result=", result, " time=", runner.time())
	viewport.queue_free()
	await process_frame
	await process_frame
	quit()
