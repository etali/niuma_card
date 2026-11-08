extends SceneTree

var game: Node
var checks := 0
var errors: Array[String] = []

func _initialize() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.audio.muted = true
	game.sfx.user_muted = true
	game._new_game()
	await _settle()
	var enemy_before := _owner_cards(1)
	var offer_before: int = game.state.offers[0].id
	_tick(30.0)
	_check(not game.bot.is_started() and _owner_cards(1) == enemy_before, "opening can wait indefinitely without BOT grouping, buying or working")
	_check(game.state.offers[0].id != offer_before, "conveyor continues while BOT waits for player")
	game.hud._open_utility(7)
	game.hud.close_panels()
	game._on_selected(_owned("employee"))
	game.board.toggle_compact(game.board.by_uid[_owned("work")])
	_check(not game.bot.is_started(), "rules, selection and stack expansion do not count as play")
	game._on_buy(-1234)
	_check(not game.bot.is_started(), "missing offer purchase cannot start BOT")
	var offer: Dictionary = game.state.offers[0]
	var price: int = offer.price
	offer.price = game.state.money(0) + 1
	game._on_buy(int(offer.id))
	_check(not game.bot.is_started(), "unaffordable purchase cannot start BOT")
	offer.price = price
	var employee := _owned("employee")
	var employee_group: int = game.state.cards[employee].group
	game.state.move_cards([_owned("overtime")], employee_group)
	game.board.work_groups_changed.emit()
	_check(not game.bot.is_started(), "person and passive buff without work is not an effective task")
	game._activate(_owned("overtime"), employee_group)
	_check(not game.bot.is_started(), "passive no-op activation cannot start BOT")
	game._new_game()
	await _settle()
	employee = _owned("employee")
	var work_group: int = game.state.cards[_owned("work")].group
	await _drag_original(game.board.by_uid[employee], game.board.get_group_position(work_group))
	_check(game.state.tasks.has(employee), "original Board drop forms a real work task")
	_check(game.bot.is_started(), "successful original grouping unlocks BOT")
	var first_think: float = game.bot._next_think
	game.bot.start()
	_check(game.bot._next_think == first_think, "later actions do not postpone or restart BOT")
	_tick(0.02)
	_check(game.bot.decision_serial == 1 and game.bot.last_decision.applied, "default zero delay lets BOT execute a real command on next logical update")
	game._new_game()
	await _settle()
	_check(not game.bot.is_started() and is_inf(game.bot._next_think), "restart resets gate and old scheduling")
	# Explicit fixture: moving a pre-existing valid pile must not count as a new
	# combination, even though its person already owns a genuine task.
	employee = _owned("employee")
	work_group = game.state.cards[_owned("work")].group
	game.state.move_cards([employee], work_group)
	game.board.sync_state(game.state)
	game._remember_player_activity()
	await _settle()
	var pile: Dictionary = game.board.group_of(game.board.by_uid[employee])
	var members: Array = game.state.group_cards(work_group)
	await _drag_original(pile.cards[0], Vector3(-1.6, Board.DRAG_HEIGHT, 4.8))
	_check(not game.bot.is_started(), "original whole-pile relocation does not unlock BOT")
	_check(game.state.group_cards(int(game.state.cards[employee].group)) == members, "whole-pile gesture preserves actual combination")
	game._new_game()
	await _settle()
	# Direct success through the production purchase callback, with the original
	# selected-wallet path retained by _on_buy.
	var cash_before: int = game.state.money(0)
	offer = game.state.offers[0].duplicate()
	game._on_buy(int(offer.id))
	_check(game.bot.is_started() and game.state.money(0) == cash_before - int(offer.price), "successful purchase charges once and unlocks BOT")
	# Configurable reaction time starts at that action, never at game creation.
	game.state.config.rules.bot.first_action_seconds = 2.0
	game._new_game()
	_tick(20.0)
	var action_time: float = game.state.time
	var affordable: Array = game.state.offers.filter(func(item): return not item.is_empty() and int(item.price) <= game.state.money(0))
	_check(not affordable.is_empty(), "delayed opening exposes a genuinely affordable purchase")
	if affordable.is_empty():
		quit(1)
		return
	game._on_buy(int(affordable[0].id))
	_check(is_equal_approx(game.bot._next_think, action_time + 2.0), "configured delay is measured from successful player action")
	_tick(1.8)
	_check(game.bot.decision_serial == 0, "BOT respects remaining post-action delay")
	_tick(0.3)
	_check(game.bot.decision_serial == 1 and game.bot.last_decision.applied,
		"BOT executes its first legal command after configured reaction time, including a useful purchase")
	game.state.config.rules.bot.first_action_seconds = 0.0
	game._new_game()
	var tool: int = game.state.add_card("outsource", 0)
	work_group = game.state.cards[_owned("work")].group
	game.state.move_cards([_owned("money")], work_group)
	game.board.sync_state(game.state)
	game._remember_player_activity()
	work_group = game.state.cards[_owned("work")].group
	game.state.move_cards([tool], work_group)
	game.board.work_groups_changed.emit()
	_check(game.bot.is_started() and game.state.cards[tool].status == "active", "starting a funded outsourcing timer also counts as player action")
	game._new_game()
	tool = game.state.add_card("outsource", 1)
	var enemy_work_group: int = game.state.cards[_owned("work", 1)].group
	game.state.move_cards([_owned("money", 1), tool], enemy_work_group)
	game.board.sync_state(game.state)
	game._remember_player_activity()
	game._activate(tool, int(game.state.cards[_owned("work", 1)].group))
	_check(not game.bot.is_started(), "opponent-owned successful command cannot unlock opponent")
	game._new_game()
	tool = game.state.add_card("strike", 0)
	game.board.sync_state(game.state)
	game._on_activate(tool, int(game.state.cards[tool].group))
	_check(game.board.attack_mode and not game.bot.is_started(), "entering tool targeting does not count as a completed action")
	var foe := _owned("employee", 1)
	game._on_selected(foe)
	_check(not game.bot.is_started(), "failed targeted tool does not unlock BOT")
	game.state.move_cards([foe], int(game.state.cards[_owned("work", 1)].group))
	game.board.sync_state(game.state)
	game._on_selected(foe)
	_check(game.bot.is_started() and game.state.pending_strikes.has(tool), "successful strike launch unlocks BOT while the opponent can still defend")
	game._new_game()
	game.hud.drawer_window.collapse_now()
	await create_timer(0.05, true).timeout
	_check(paused and not game.bot.is_started(), "closing drawer does not unlock BOT")
	game.hud.drawer_window.activate_handle()
	game.hud.drawer_window.pin()
	await create_timer(0.05, true).timeout
	_check(not paused and not game.bot.is_started(), "opening drawer does not unlock BOT")
	game._new_game()
	employee = _owned("employee")
	var coffee := _owned("coffee")
	var employee_gid: int = game.state.cards[employee].group
	game.state.move_cards([coffee], employee_gid, employee)
	game.board.work_groups_changed.emit()
	_check(game.state.cards[employee].type == "employee" and game.state.cards[coffee].status == "active", "coffee combination starts a timer and preserves the employee and material")
	_check(game.state.tasks[employee].kind == "coffee" and game.bot.is_started(), "starting an upgrade without any work still unlocks BOT")
	game.state.advance(game.state.config.number("coffee", "seconds"))
	_check(game.state.cards[employee].type == "grinder" and not game.state.cards.has(coffee), "upgrade completes only after its configured time")
	game._new_game()
	var overtime: int = game.state.add_card("overtime", 0)
	game.board.sync_state(game.state)
	game._remember_player_activity()
	game._activate(overtime, int(game.state.cards[overtime].group))
	_check(not game.bot.is_started(), "passive overtime on an empty pile cannot unlock BOT")
	employee = _owned("employee")
	game.state.move_cards([overtime], int(game.state.cards[employee].group))
	game.board.work_groups_changed.emit()
	_check(not game.bot.is_started(), "employee and permanent overtime without work is still waiting")
	game._new_game()
	var leader: int = game.state.add_card("leader", 0)
	coffee = _owned("coffee")
	game.board.sync_state(game.state)
	game._remember_player_activity()
	game._activate(coffee, int(game.state.cards[leader].group), leader)
	_check(game.state.cards.has(coffee) and game.state.cards[leader].type == "leader", "invalid coffee upgrade preserves material and personnel")
	_check(not game.bot.is_started(), "invalid coffee target cannot unlock BOT")
	game.queue_free()
	await process_frame
	for error in errors: printerr("FAIL ", error)
	print("PLAYER_STARTS_BOT ", "PASS" if errors.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if errors.is_empty() else 1)

func _tick(seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		var step := minf(left, 0.2)
		game._process(step)
		left -= step

func _owned(kind: String, owner := 0) -> int:
	for id in game.state.cards:
		if game.state.cards[id].type == kind and int(game.state.cards[id].owner) == owner: return int(id)
	return -1

func _owner_cards(owner: int) -> String:
	return JSON.stringify(game.state.cards.values().filter(func(card): return int(card.owner) == owner))

func _owner_has_task(owner: int) -> bool:
	for id in game.state.tasks:
		if int(game.state.cards[id].owner) == owner: return true
	return false

func _drag_original(card: CardEntity, destination: Vector3) -> void:
	game.board._on_card_clicked(card)
	_check(not game.board._drag_cards.is_empty(), "original Board pickup owns a drag")
	if game.board._drag_cards.is_empty(): return
	var offset: Vector3 = destination - game.board._drag_cards[0].global_position
	for member in game.board._drag_cards: member.global_position += offset
	game.board._end_drag()
	await _settle()

func _settle() -> void:
	await create_timer(0.25).timeout
	await process_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)
