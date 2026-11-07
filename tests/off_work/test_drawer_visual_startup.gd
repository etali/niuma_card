extends SceneTree

## Graphical desktop check: engine-created transparent window before any game
## code, native drawer warmup, and effects isolation in the collapsed mascot.
var checks := 0
var failures: Array[String] = []
var game: Node

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("DRAWER_VISUAL_STARTUP requires the actual desktop renderer")
		quit(2)
		return
	_check(root.borderless and root.transparent and root.transparent_bg, "engine-created native window is transparent and borderless before game construction")
	await RenderingServer.frame_post_draw
	var first := root.get_texture().get_image()
	_check(_transparent(first, Rect2i(Vector2i.ZERO, first.get_size())), "first native frame contains no opaque startup rectangle")
	first.save_png("res://reports/drawer-startup-transparent.png")
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.audio.muted = true
	game.sfx.user_muted = true
	await create_timer(0.8, true).timeout
	var drawer: DrawerWindow = game.hud.drawer_window
	_check(drawer._use_os_window and not drawer.is_expanded() and paused, "native startup presents the paused mascot entry")
	_check(game.state.time == 0.0, "warmup does not advance the game")
	_check(root.visible and root.transparent and root.transparent_bg and root.disable_3d, "real entry window remains visible and transparent")
	_check(not game.effects.visible, "startup effect canvas is hidden outside the game table")
	# A frozen burst previously survived the fold and drew crossed lines beside
	# the mascot. Use a left-edge impact so the PNG catches that actual leak.
	game.effects.emit_effect("work_complete", Vector2(5, root.size.y * 0.78), Vector2.ZERO)
	game.effects.items.back().age = float(game.effects.items.back().duration) * 0.45
	game.effects.queue_redraw()
	var snapshot: Array = game.effects.items.duplicate(true)
	await RenderingServer.frame_post_draw
	var collapsed := root.get_texture().get_image()
	_check(_transparent(collapsed, Rect2i(0, int(root.size.y * 0.65), 12, int(root.size.y * 0.3))), "left edge below mascot remains transparent with a queued impact")
	collapsed.save_png("res://reports/drawer-clean-entry.png")
	_check(game.effects.items == snapshot, "hiding effects preserves their paused timeline")
	drawer.pin()
	await create_timer(0.45, true).timeout
	_check(drawer.is_expanded() and not paused and game.effects.visible, "opening restores table and effect drawing")
	_check(not root.disable_3d and root.visible, "normal game content renders in the same visible native window")
	_check(game.effects.items.filter(func(item): return item.kind == "new_game").is_empty(), "initial game event does not create a stray startup burst")
	game._new_game()
	await process_frame
	await process_frame
	_check(game.effects.items.filter(func(item): return item.kind == "new_game").is_empty(), "restarting does not create a source-less burst")
	await create_timer(0.6, true).timeout
	await RenderingServer.frame_post_draw
	var expanded := root.get_texture().get_image()
	_check(expanded.get_pixel(expanded.get_width() / 2, expanded.get_height() / 2).a > 0.9, "expanded game is opaque table content, not a hidden window")
	expanded.save_png("res://reports/drawer-open-after-startup.png")
	drawer.collapse_now()
	await create_timer(0.3, true).timeout
	_check(paused and not game.effects.visible and game.hud._handle.visible, "later folds keep the same clean entry behavior")
	game.queue_free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("DRAWER_VISUAL_STARTUP %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _transparent(image: Image, region: Rect2i) -> bool:
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			if image.get_pixel(x, y).a > 0.01: return false
	return true

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
