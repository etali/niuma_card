extends SceneTree

## Exercise the original drawer state machine with the real realtime scene.
## Headless geometry uses DrawerWindow.setup(false); pointer opening still goes
## through the original mascot and Viewport input.
var game: Node
var hud: CanvasLayer
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	root.size = Vector2i(1440, 810)
	root.gui_embed_subwindows = true
	_run.call_deferred()

func _run() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await _frames(4)
	hud = game.hud
	var drawer: DrawerWindow = hud.drawer_window
	_check(drawer is DrawerWindow, "realtime adapter inherits the original drawer controller")
	_check(not hud.hud_config.drawer.start_expanded and not hud.hud_config.drawer.start_pinned, "desktop defaults match collapsed unpinned source startup")
	_check(hud.hud_config.drawer.prewarm_on_start, "native startup keeps original prewarm")
	# Fixed-view harness normally starts open. Invoke the exact desktop startup
	# bridge now; setup(false) makes native prewarm finish synchronously.
	hud._start_drawer()
	_check(paused and not drawer.is_expanded() and hud._handle.visible, "startup entry pauses the local game")
	_check(not game.effects.visible, "collapsed entry hides the frozen tabletop effect canvas")
	var initial_clock: float = game.state.time
	await create_timer(0.10, true).timeout
	_check(game.state.time == initial_clock, "startup entry cannot run the opponent in the background")
	await _click_handle()
	_check(drawer.is_expanded() and not paused, "original mascot opens while tree is paused")
	_check(game.effects.visible, "opening restores tabletop effects without clearing them")
	drawer.pin()
	game.set_process(false)
	# Build valid work for both sides, then start a real income flight before
	# hiding the drawer. New rules have one initial employee per side.
	var people: Array = []
	for owner in [0, 1]:
		var person := -1
		var work_group := -1
		for id in game.state.cards:
			var card: Dictionary = game.state.cards[id]
			if int(card.owner) != owner: continue
			if person < 0 and game.state.config.is_person(card.type): person = int(id)
			if work_group < 0 and card.type == "work": work_group = int(card.group)
		game.state.move_cards([person], work_group)
		people.append(person)
	game.state.advance(10.0)
	var events: Array = game.state.drain_events()
	game.board.sync_state(game.state)
	for event in events:
		if event.kind == "work_complete": game.board.play_event(event)
	game.effects.emit_effect("work_complete", Vector2(200, 200), Vector2(400, 200))
	game.set_process(true)
	await _frames(2)
	await _key(KEY_ESCAPE)
	_check(paused and not drawer.is_expanded(), "Escape collapses and pauses actual simulation")
	var snapshot := _snapshot(people)
	await create_timer(0.25, true).timeout
	var after := _snapshot(people)
	for key in snapshot:
		_check(snapshot[key] == after[key], "collapsed freeze: " + key)
	_check(not hud._detail.visible and not hud._header.visible and hud._handle.visible, "only the original entry UI remains exposed")
	_check(not game.effects.visible, "collapsing during active income hides its frozen effect lines")
	_check(not drawer.is_pinned(), "manual collapse releases the original pin")
	await _click_handle()
	_check(drawer.is_expanded() and not paused, "clicking original entry resumes both players")
	drawer.pin()
	await create_timer(0.06, true).timeout
	_check(game.state.time > snapshot.time and game.state.time - snapshot.time < 0.20, "resume advances current frame time without catching up hidden time")
	for person in people:
		_check(game.state.cards[person].progress > snapshot["progress_" + str(person)], "owner resumes from saved work progress")
	# Source hover behavior: hover greets while collapsed; only click opens.
	drawer.collapse_now()
	drawer._update_hover(drawer._geometry.get_center(), Time.get_ticks_msec())
	_check(not drawer.is_expanded() and paused, "hovering the entry does not open or resume")
	await _click_handle()
	# Source leave timer: pin protects the table, unpin enables automatic fold;
	# an active card drag prevents the pending fold until the pointer releases.
	drawer.pin()
	var now := Time.get_ticks_msec()
	drawer._update_hover(drawer._geometry.end + Vector2i(100, 100), now)
	drawer._tick_at(now + 1000)
	_check(drawer.is_expanded() and not paused, "pinned drawer ignores pointer leave")
	drawer.set_pinned(false)
	game.board._drag_cards.append(game.board.by_uid[people[0]])
	drawer._update_hover(drawer._geometry.end + Vector2i(100, 100), now)
	drawer._tick_at(now + 1000)
	_check(drawer.is_expanded() and not paused, "original leave request waits for card drag")
	game.board._drag_cards.clear()
	drawer._tick_at(now + 1001)
	_check(not drawer.is_expanded() and paused, "released pointer lets original auto-collapse pause game")
	# Original handle dragging and edge attachment stay available while paused.
	var start: Vector2i = drawer._geometry.get_center()
	drawer.start_drag(start)
	var end := Vector2i(0, start.y)
	drawer.drag_to(end)
	drawer.end_drag(end)
	_check(drawer.anchor_edge == "left" and not drawer.is_expanded() and paused, "original handle can move and attach to another screen edge while paused")
	await _click_handle()
	drawer.pin()
	# This adapter must only release a pause it owns.
	paused = true
	hud._drawer_owns_pause = false
	drawer.collapse_now()
	await _click_handle()
	_check(paused and not hud._drawer_owns_pause, "opening does not steal an unrelated pause")
	paused = false
	drawer.pin()
	game.queue_free()
	await _frames(3)
	for message in failures: push_error(message)
	print("DRAWER_PAUSE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _snapshot(people: Array) -> Dictionary:
	var result := {"time": game.state.time, "conveyor": game.state.conveyor_progress,
		"bot_schedule": game.bot._next_think, "tasks": game.state.tasks.duplicate(true),
		"cards": game.state.cards.duplicate(true), "offers": game.state.offers.duplicate(true),
		"effects": game.effects.items.duplicate(true), "cash_flights": game.board._cash_flights.duplicate(true)}
	for person in people:
		result["progress_" + str(person)] = game.state.cards[person].progress
		result["person_animation_" + str(person)] = game.board.by_uid[person]._elapsed
	for id in game.board._cash_flights:
		result["cash_position_" + str(id)] = game.board.by_uid[id].position
	return result

func _click_handle() -> void:
	var at: Vector2 = hud._handle.global_position + hud._handle.get_icon_hit_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = pressed
		root.push_input(event, true)
		await _frames(2)

func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = pressed
		root.push_input(event, true)
		await _frames(1)

func _frames(count: int) -> void:
	for index in count: await process_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
