extends SceneTree

const SavePaths = preload("res://engine/save_paths.gd")

var issues: Array[String] = []
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, detail: String) -> void:
	checks += 1
	if not ok: issues.append(detail)

func run() -> void:
	var host: Node = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(host)
	await process_frame
	host.set_process(false)
	var live: OffWorkState = host.state
	var uid := live.add_card("coffee", 0)
	host._process(0.75)
	var path: String = host.replay.save(host)
	check(FileAccess.file_exists(path), "writes realtime recording")
	host._process(1.0)
	var parked_time := live.time
	var parked_cards := live.cards.duplicate(true)
	var loaded: Dictionary = host._load_replay(path)
	check(loaded.ok, "can load own recording")
	if loaded.ok:
		check(host.replay.playing and host.state != live, "parks the live game")
		host._process(5.0)
		check(host.state.cards.has(uid), "replays the new card")
		check(is_equal_approx(host.state.time, parked_time - 1.0), "ends at saved clock")
		host.replay.seek(host, 0.25)
		check(is_equal_approx(host.state.time, 0.25), "can seek to an earlier time between actions")
		host.stop_replay()
		check(host.state == live and live.cards == parked_cards and live.time == parked_time, "restores exact game and clock")
	host.begin_practice()
	check(not host.practice.is_empty() and host.state != live, "practice uses separate state")
	var person := -1
	var work := -1
	for id in host.state.cards:
		var card: Dictionary = host.state.cards[id]
		if card.owner != 0: continue
		if card.type == "employee": person = id
		if card.type == "work": work = id
	host.state.move_cards([person], host.state.cards[work].group, work)
	host._process(0.1)
	check(host.practice_stage == 1, "recognizes forming a working group")
	host._process(2.0)
	check(host.practice_stage == 2, "recognizes first real income")
	host._on_buy(host.state.offers[0].id)
	host._process(0.1)
	check(host.practice_stage == 3, "recognizes an actual purchase")
	host.finish_practice()
	check(host.state == live and host.state.time == parked_time, "practice restores the parked table")
	host.hud._open_utility(host.hud.UTILITY_CARDS)
	var config_path := SavePaths.recordings_dir().path_join("custom-work-cards.json")
	var document := live.config.balance_document() as Dictionary
	document.rules.conveyor.slots = 4
	document.rules.conveyor.opening = document.rules.conveyor.opening.slice(0, 4)
	var store := preload("res://engine/json_store.gd")
	store.save(config_path, document)
	check(host.hud.handle_card_config_files(PackedStringArray([config_path])), "accepts named card file")
	check(host.choose_card_config(config_path).ok and host.apply_selected_card_config().ok, "starts with selected layout")
	check(host.state.offers.size() == 4 and host.conveyor._count == 4, "market cloth and conveyor use new configuration")
	host.choose_card_config("")
	DirAccess.remove_absolute(config_path)
	DirAccess.remove_absolute(path)
	host.queue_free()
	await process_frame
	for issue in issues: push_error(issue)
	print("WORK_REPLAY %s (%d checks)" % ["PASS" if issues.is_empty() else "FAIL", checks])
	quit(0 if issues.is_empty() else 1)
