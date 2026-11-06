extends SceneTree

## Real shipped opening, then one legal grouping command. Capture actual task
## values and original stack layouts; the caption explicitly labels automation.
var game: Node
var elapsed := 0.0
var person := -1
var income_at := -1.0
var shots: Dictionary = {}
var expanded := false
var ended := false

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_start.call_deferred()

func _start() -> void:
	game = load("res://scenes/work_main.tscn").instantiate()
	root.add_child(game)
	game.state.config.rules.bot.enabled = false
	game.hud.lbl_round.text = "界面演示 · 自动编组"
	game.hud.set_process(false)
	game.hud._detail.hide()

func _process(delta: float) -> bool:
	if game == null: return false
	elapsed += delta
	if elapsed > 0.6 and not shots.has("opening"): _capture("opening")
	if elapsed > 1.0 and person < 0:
		var work := -1
		for id in game.state.cards:
			var card: Dictionary = game.state.cards[id]
			if int(card.owner) != 0: continue
			if card.type == "employee": person = int(id)
			if card.type == "work" and work < 0: work = int(card.group)
		game.state.move_cards([person], work)
	if person < 0: return false
	var progress := float(game.state.cards[person].progress)
	if income_at < 0.0:
		if progress >= 0.25 and not shots.has("quarter"): _capture("quarter")
		if progress >= 0.45 and not expanded:
			expanded = true
			game.board.toggle_compact(game.board.by_uid[person])
		if progress >= 0.5 and not shots.has("expanded"): _capture("expanded")
		if progress >= 0.6 and expanded:
			var group: Dictionary = game.board.group_of(game.board.by_uid[person])
			if not group.compact: game.board.toggle_compact(game.board.by_uid[person])
		if progress >= 0.75 and not shots.has("three-quarter"): _capture("three-quarter")
		if game.state.money(0) > int(game.state.config.rules.initial.money):
			income_at = elapsed
			_capture("completed")
	elif elapsed - income_at >= 0.35 and not ended:
		ended = true
		_capture("next")
		_end.call_deferred()
	return false

func _capture(label: String) -> void:
	shots[label] = true
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png("res://reports/progress-%s.png" % label)
	print("PROGRESS_REVIEW ", label, " result=", result)
	if person >= 0:
		var group: Variant = game.board.group_of(game.board.by_uid[person])
		if group != null:
			var top: WorkCard = group.cards[game.board._top_index(group)]
			print("PROGRESS_SAMPLE ", label, " top=", top.type,
				" value=", top._task_progress_value, " active=", top._task_progress_active,
				" displayed=", top.task_progress_display_value(), " visible=", top._task_progress.visible)

func _end() -> void:
	await process_frame
	quit()
