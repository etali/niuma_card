extends SceneTree

## Regressions for the original desktop: fitted bars/table and stable hand placement.
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var main: Node = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await create_timer(0.5).timeout
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	var board: Board = main.board
	var positions: Dictionary = {}
	for group in board.groups:
		positions[int(group.work_group_id)] = board.rest_origin(group)
	# A fresh group must find room without rebuilding the existing tabletop.
	main.state.add_card("employee", 0)
	board.sync_state(main.state)
	await create_timer(0.4).timeout
	for group in board.groups:
		var gid: int = group.work_group_id
		if positions.has(gid):
			_check(board.rest_origin(group).distance_to(positions[gid]) < 0.02, "new card preserves original group position %d" % gid)
	for size in [Vector2i(1600, 900), Vector2i(1280, 800), Vector2i(1024, 768)]:
		root.size = size
		main.hud.relayout()
		await create_timer(0.4).timeout
		var viewport: Rect2 = root.get_visible_rect()
		_check(viewport.encloses(main.hud._header.get_global_rect()), "original header fits %s" % size)
		_check(viewport.encloses(main.hud._footer.get_global_rect()), "original footer fits %s" % size)
		var content: Rect2 = main.hud.content_rect()
		_check(not content.intersects(main.hud._header.get_global_rect()) and not content.intersects(main.hud._footer.get_global_rect()), "table content clears original bars %s" % size)
		for group in board.groups:
			var top: CardEntity = group.cards[0]
			_check(content.has_point(board.camera.unproject_position(top.global_position)), "original pile head stays in content %s" % size)
	main._new_game()
	await create_timer(0.4).timeout
	_check(not board.is_dragging() and not board.attack_mode, "restart clears original pointer and targeting")
	_check(board.by_uid.size() == main.state.cards.size(), "restart rebuilds exactly the live records")
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_LAYOUT ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
