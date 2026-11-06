extends SceneTree

var main: Node

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-side-fan-review-%d" % OS.get_process_id())
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	main.state.config.rules.bot.enabled = false
	main.state.config.rules.initial.groups = [{"work": 200, "employee": 5, "overtime": 3}]
	main._new_game()
	main.state.drain_events()
	await create_timer(0.8).timeout
	var group := -1
	for uid in main.state.cards:
		if int(main.state.cards[uid].owner) == 0 and main.state.cards[uid].type == "employee":
			group = int(main.state.cards[uid].group)
			break
	for kind in ["employee", "work"]:
		main.board.open_side_extract(group, kind)
		var fan: Control = main.board.side_extract.view
		var motion := InputEventMouseMotion.new()
		fan._process(0.6)
		motion.position = fan.screen_point_for_index(2 if kind == "employee" else 100)
		fan.handle_pointer_event(motion)
		await process_frame
		await process_frame
		await create_timer(0.3).timeout
		RenderingServer.force_draw(false)
		var error := root.get_texture().get_image().save_png("res://reports/side-extract-table-%s.png" % kind)
		print("SIDE_EXTRACT_REVIEW ", kind, " save=", error, " actual_count=", fan.records.size(), " drawn=", fan.preview_cards.size())
		main.board.side_extract.close()
	main.queue_free()
	await process_frame
	await process_frame
	quit()
