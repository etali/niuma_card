extends "res://tests/off_work/test_work_ui.gd"

## 买不起的价签变灰，钱刚够的那一刻弹一下；键盘 1–6 买传送带上对应的那一格（自动付款），
## 空格暂停或继续，Esc 先把手上的牌放回去。
func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	root.size = Vector2i(1440, 810)
	main = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_process(false)
	main.audio.muted = true
	main.sfx.user_muted = true
	board = main.board
	board.touch_mode = true
	state = main.state
	state.config.rules.bot.enabled = false
	state.config.rules.initial.groups = [{"employee": 1, "work": 40}]
	state.config.rules.initial.money = 5
	state.config.rules.conveyor.pool = {"employee": 1, "boss": 1}
	state.config.rules.conveyor.interval_seconds = 1000.0
	main._new_game()
	await _settle()
	await _tags()
	await _keys()
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("KEYS_AND_TAGS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event)
	await process_frame

func _tag(slot: int) -> Node3D:
	return board._prices[int(state.offers[slot].id)]

func _tags() -> void:
	var cheap := -1
	var dear := -1
	for slot in state.offers.size():
		if state.offers[slot].is_empty(): continue
		if int(state.offers[slot].price) <= 5 and cheap < 0: cheap = slot
		if int(state.offers[slot].price) > 5 and dear < 0: dear = slot
	if not _check(cheap >= 0 and dear >= 0, "the conveyor shows something payable and something too dear for five cash"): return
	_check(_tag(cheap).is_affordable() and not _tag(dear).is_affordable(), "the tags know which price can be paid")
	_check(_tag(dear)._label.modulate.a < 0.5 and _tag(cheap)._label.modulate.a > 0.95, "a price that cannot be paid is greyed; a payable one is in full ink")
	# The moment there is enough money the tag gives a hop and takes its full ink.
	var tag: Node3D = _tag(dear)
	state._credit(0, int(state.offers[dear].price))
	board.sync_state(state)
	_check(tag.is_affordable() and tag._label.modulate.a > 0.95, "with enough cash the grey is lifted")
	_check(tag._motion != null and tag._motion.is_valid() and tag._motion.is_running(), "and the tag gives a hop")
	# Spending it greys the tag again, without a hop.
	var spend: Array = state._owner_type(0, "money").slice(0, int(state.offers[dear].price))
	state._spend(0, int(state.offers[dear].price), spend)
	board.sync_state(state)
	_check(not _tag(dear).is_affordable() and _tag(dear)._label.modulate.a < 0.5, "when the cash is gone the tag is grey again")

func _keys() -> void:
	var slot := -1
	for index in state.offers.size():
		if not state.offers[index].is_empty() and int(state.offers[index].price) <= state.money(0): slot = index
	if not _check(slot >= 0, "a payable slot exists"): return
	var offer: Dictionary = state.offers[slot].duplicate()
	var cash: int = state.money(0)
	var cards: int = state.cards.size()
	await _key(KEY_1 + slot)
	await _settle()
	_check(state.offers[slot].is_empty() and state.money(0) == cash - int(offer.price), "key %d buys conveyor slot %d and pays its price once" % [slot + 1, slot + 1])
	# The same key on the now empty slot buys nothing and says so.
	cash = state.money(0)
	await _key(KEY_1 + slot)
	_check(state.money(0) == cash and main.message.text.contains("第 %d 格" % (slot + 1)), "an empty slot buys nothing and the tip says which slot was empty")
	# Space pauses and resumes.
	_check(not main.hud._manual_paused, "the game runs")
	await _key(KEY_SPACE)
	_check(main.hud._manual_paused, "Space pauses")
	var other := -1
	for index in state.offers.size():
		if not state.offers[index].is_empty() and int(state.offers[index].price) <= state.money(0): other = index
	if other >= 0:
		cash = state.money(0)
		await _key(KEY_1 + other)
		_check(state.money(0) == cash, "number keys do not buy while paused")
	await _key(KEY_SPACE)
	_check(not main.hud._manual_paused, "Space resumes")
	# Esc first puts back what is in the hand.
	var worker := _owned("employee")
	var home: Vector3 = board.rest_pos(board.by_uid[worker])
	var group: int = state.cards[worker].group
	await _button(_point(board.by_uid[_owned("work")]), true)
	var event := InputEventMouseMotion.new()
	event.position = pointer + Vector2(60, 40)
	event.global_position = event.position
	event.relative = Vector2(60, 40)
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event)
	await process_frame
	if _check(board.is_dragging(), "a pile is in the hand"):
		await _key(KEY_ESCAPE)
		await _settle()
		_check(not board.is_dragging(), "Esc lets go of what was in the hand (dragging=%s)" % board.is_dragging())
		_check(state.cards[worker].group == group, "nothing was regrouped (%s -> %s)" % [group, state.cards[worker].group])
		_check(main.hud.drawer_window == null or main.hud.drawer_window.is_expanded(), "and that Esc did nothing else: the table is still open")
