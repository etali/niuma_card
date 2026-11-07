extends SceneTree

## A labelled visual test with real rules and scheduled legal commands.
## This is not a recording of a human match; no simulated outputs are drawn.
var game
var elapsed := 0.0
var commands_done: Dictionary = {}

func _initialize() -> void:
	_start.call_deferred()

func _start() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.state.config.rules.bot.enabled = false
	game.state.config.rules.initial.groups = [
		{"leader": 1, "meeting": 1},
		{"leader": 1, "employee": 3, "work": 10, "transfer": 1},
		{"employee": 1, "work": 8, "overtime": 2, "coffee": 1}
	]
	if OS.get_environment("WORK_SHOWCASE") == "finish":
		game.state.config.rules.initial.groups = [{"grinder": 1, "work": 2, "overtime": 2}]
	game._new_game()
	game.hud.lbl_round.text = "演出测试 · 自动操作"
	game._notify("真实规则演出测试 · 自动操作：领导开会 → 成批甩锅 → 咖啡升级 → 加班赶工")

func _process(delta: float) -> bool:
	if game == null: return false
	elapsed += delta
	for entry in [[0.6, "meeting"], [1.3, "transfer"], [1.8, "overtime"], [8.0, "coffee"]]:
		var kind: String = entry[1]
		if elapsed >= float(entry[0]) and not commands_done.has(kind):
			commands_done[kind] = true
			for id in game.state.cards.keys():
				var card: Dictionary = game.state.cards[id]
				if int(card.owner) == 0 and str(card.type) == kind:
					game.state.activate(int(id), int(card.group))
					break
	return false
