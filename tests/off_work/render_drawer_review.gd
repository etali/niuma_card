extends SceneTree
## Desktop-only review of the original native window transitions and pause bridge.
## Opens and folds automatically, then saves the actual transparent mascot view.
var game: Node
var failed := false
func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Native drawer review needs the graphical desktop driver")
		quit(2)
		return
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await create_timer(0.8, true).timeout
	var drawer: DrawerWindow = game.hud.drawer_window
	_check(drawer._use_os_window and drawer.is_processing_input(), "native source pointer processing is enabled")
	_check(paused and not drawer.is_expanded() and not drawer.is_pinned(), "native startup is collapsed, unpinned and paused")
	_check(game.state.time == 0.0, "native startup performs no background simulation")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://reports/drawer-collapsed.png")
	drawer.pin()
	await create_timer(0.5, true).timeout
	_check(drawer.is_expanded() and not paused and game.state.time > 0.0, "native source expansion restores simulation")
	var before: float = game.state.time
	drawer.collapse_now()
	_check(paused and drawer.is_transitioning(), "native closing transition immediately pauses simulation")
	await create_timer(0.3, true).timeout
	_check(paused and not drawer.is_expanded() and game.state.time == before, "native collapsed window preserves clock")
	drawer.pin()
	_check(paused and drawer.is_transitioning(), "native opening waits for transition before resuming")
	await create_timer(0.4, true).timeout
	_check(not paused and drawer.is_expanded() and game.state.time - before < 0.25, "native reopening has no hidden-time catch-up")
	game.queue_free()
	await process_frame
	print("NATIVE_DRAWER ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
func _check(value: bool, label: String) -> void:
	print("PASS " if value else "FAIL ", label)
	failed = failed or not value
