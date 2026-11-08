extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 900)
	var board := Board.new()
	root.add_child(board)
	board.set_process(false)
	var card := CardEntity.new()
	card.freeze = true
	board.add_child(card)
	card.global_position = Vector3(1, 0.05, 2)
	board._move_to(card, card.global_position)
	_check(board._move_tw.is_empty(), "a settled card does not schedule an idle position tween")
	var target := card.global_position + Vector3(0.001, 0, 0)
	board._move_to(card, target)
	_check(board._move_tw.has(card) and board._move_tw[card].to == target,
		"even a small real displacement retains the landing animation")
	var old_tween: Tween = board._move_tw[card].tw
	var callbacks: Array = []
	board.cancel_anim = func(c): callbacks.append(c); c.remove_meta("dest_pos")
	card.set_meta("dest_pos", target + Vector3.ONE)
	var held := card.global_position
	board._move_to(card, held)
	_check(callbacks == [card] and not card.has_meta("dest_pos") and not old_tween.is_running()
		and board._move_tw.is_empty() and card.global_position == held,
		"zero displacement still cancels previous internal/external motion without snapping to a stale destination")
	board.cancel_anim = Callable()
	board._drag_compact = true
	for index in 4000:
		board._drag_offsets.append(Vector3(0.1 * (index % 4), 0.02 * (index % 3), 0.05 * (index % 4)))
	var full := board._drag_offsets.duplicate()
	var unique := board._held_stack_bounds()
	_check(unique.size() == 12 and board._drag_offsets == full,
		"compact bounds deduplicate exact xyz points without changing any of 4000 real offsets")
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, 12, 11)
	camera.look_at(Vector3.ZERO)
	camera.fov = 60
	var screen := Rect2(100, 120, 1240, 700)
	var table := Rect2(-10, -5, 20, 10)
	for point in [Vector3(-20, 1.2, -10), Vector3(20, 1.2, 10), Vector3(0, 1.2, 0)]:
		_check(Board.clamp_stack_anchor(point, unique, table) == Board.clamp_stack_anchor(point, full, table),
			"deduplicated compact geometry preserves exact table bounds")
		_check(DrawerCameraFit.clamp_anchor_to_screen(camera, screen, point, unique, CardEntity.CARD_SIZE, 0.08)
			== DrawerCameraFit.clamp_anchor_to_screen(camera, screen, point, full, CardEntity.CARD_SIZE, 0.08),
			"deduplicated compact geometry preserves exact perspective screen bounds")
	board._drag_offsets[0] += Vector3(0, 0.001, 0)
	_check(board._held_stack_bounds().size() == 13 and board._held_stack_bounds().has(board._drag_offsets[0]),
		"an in-place height change invalidates the cached complete xyz geometry")
	board._drag_compact = false
	_check(board._held_stack_bounds() == [board._drag_offsets[0]],
		"expanded stacks continue to constrain only the grabbed first layer")
	board._drag_offsets.clear()
	board._drag_compact = true
	_check(board._held_stack_bounds().is_empty(), "clearing the held stack clears cached bounds")
	board.queue_free()
	camera.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("BOARD_MOTION_BOUNDS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
