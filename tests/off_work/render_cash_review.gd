extends SceneTree

## Visual review using the real shipped opening and legal group commands.
## Auto-arranging is labelled on screen; no animation substitutes for rule output.
var game: Node
var elapsed := 0.0
var first_income := -1.0
var arranged := false
var shots: Dictionary = {}
var finished := false

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_start.call_deferred()

func _start() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.state.config.rules.bot.enabled = false
	game.hud.lbl_round.text = "现金演出 · 自动操作"
	game.hud.set_process(false)
	game.hud._detail.hide()

func _process(delta: float) -> bool:
	if game == null: return false
	elapsed += delta
	if elapsed > 0.55 and not shots.has("opening"):
		_capture("opening")
	if elapsed > 1.0 and not arranged:
		arranged = true
		var people: Array = []
		var work_groups: Array = []
		for id in game.state.cards:
			var card: Dictionary = game.state.cards[id]
			if int(card.owner) == 0 and card.type == "employee": people.append(id)
		for group in game.state.groups:
			if game.state.groups[group].owner == 0 and not game.state.group_work(group).is_empty(): work_groups.append(group)
		for i in mini(people.size(), work_groups.size()):
			game.state.move_cards([people[i]], work_groups[i])
	if first_income < 0.0 and game.state.money(0) > int(game.state.config.rules.initial.money):
		first_income = elapsed
	if first_income >= 0.0:
		for spec in [[0.1, "pop"], [0.42, "flight"], [1.5, "landed"]]:
			if elapsed - first_income >= float(spec[0]) and not shots.has(spec[1]): _capture(spec[1])
		if elapsed - first_income > 1.8 and not finished:
			finished = true
			_end.call_deferred()
	return false

func _capture(label: String) -> void:
	shots[label] = true
	await RenderingServer.frame_post_draw
	var target := "res://reports/cash-%s.png" % label
	var result := root.get_texture().get_image().save_png(target)
	print("CASH_REVIEW ", label, " ", result)

func _end() -> void:
	await process_frame
	quit()
