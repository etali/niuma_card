extends "res://tests/off_work/test_work_ui.gd"

## Actual moving price-tag clicks must never spend an ongoing outsource batch.
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
	state.config.rules.initial.groups = [{"employee": 1}, {"work": 12}, {"outsource": 1}]
	state.config.rules.initial.money = 8
	main._new_game()
	var tool := _owned("outsource")
	var wallet := _owned("money")
	var reserved_cards: Array = _owned_ids("money")
	var work := _owned("work")
	var gid: int = state.cards[work].group
	state.move_cards(reserved_cards, gid)
	state.move_cards([tool], gid)
	state.advance(4.0)
	board.sync_state(state)
	main._update_hud()
	await _settle()
	var timer: float = state.cards[tool].remaining
	_check(state.outsourcing.has(tool) and state.reserved_money(0) == 8 and state.available_money(0) == 0, "outsource has reserved eight and no shopping balance")
	_check(main.hud.lbl_player_res.text.contains("可用0") and main.hud.lbl_player_res.text.contains("预留8"), "header distinguishes shopping balance from reserved cash")
	_check(board._payment_amount([board.by_uid[wallet]]) == 0, "drag-purchase gate excludes reserved wallet money")
	main.hud.show_card_detail(board.by_uid[wallet], Vector2(500, 500))
	_check(main.hud._detail_status.text.replace(" ", "").contains("外包预留1"), "hover explains why this individual money card is reserved")
	main.hud.show_card_detail(board.by_uid[tool], Vector2(500, 500))
	_check(main.hud._detail_status.text.contains("外包中") and main.hud._detail_status.text.contains("预留"), "active outsource hover reports the protected batch without an invalid status lookup")
	main.hud._detail.hide()
	var offer: Dictionary = state.offers[0].duplicate()
	var people := state.people_count(0)
	var owned_before: int = state.cards.values().filter(func(item): return int(item.owner) == 0 and str(item.type) == str(offer.type)).size()
	await _buy_offer(int(offer.id))
	_check(state.people_count(0) == people and state.offers[0].id == offer.id, "price click refuses to buy with reserved cash only")
	_check(state.outsourcing.has(tool) and is_equal_approx(float(state.cards[tool].remaining), timer), "rejected purchase leaves the real outsource timer unchanged")
	_check(state.money(0) == 8 and state.work_count(0) == 12, "rejected purchase consumes neither money nor work")
	_check(main.message.text.contains("预留"), "failed purchase gives the reservation reason")
	var active_group: Dictionary = board.group_of(board.by_uid[tool])
	await _click(_point(active_group.cards[board._top_index(active_group)]), true)
	await _drag(board.by_uid[wallet], _point(board.offers_by_id[int(offer.id)]))
	_check(state.outsourcing.has(tool) and is_equal_approx(float(state.cards[tool].remaining), timer), "dragging reserved cash onto an offer also preserves outsourcing")
	_check(int(state.cards[wallet].group) == gid and int(state.cards[wallet].amount) == 1 and reserved_cards.all(func(uid): return state.cards.has(uid) and state.cards[uid].group == gid) and state.offers[0].id == offer.id, "rejected drag restores all the same reserved money cards to the original group")
	active_group = board.group_of(board.by_uid[tool])
	if not active_group.compact: board.toggle_compact(active_group.cards[board._top_index(active_group)])
	var free_cash: Array = state._credit(0, 8)
	board.sync_state(state)
	main._update_hud()
	await _settle()
	await _buy_offer(int(offer.id))
	var owned_after: int = state.cards.values().filter(func(item): return int(item.owner) == 0 and str(item.type) == str(offer.type)).size()
	_check(owned_after == owned_before + 1 and state.offers[0].is_empty(), "same actual price click purchases the current conveyor card when unreserved cash exists")
	var remaining_free: Array = free_cash.filter(func(uid): return state.cards.has(uid))
	_check(remaining_free == free_cash.slice(int(offer.price)) and reserved_cards.all(func(uid): return state.cards.has(uid) and state.cards[uid].amount == 1 and state.reserved_cash_amount(uid) == 1), "purchase consumes only outside unit cards and preserves every reserved identity")
	_check(state.outsourcing.has(tool) and is_equal_approx(float(state.cards[tool].remaining), timer), "successful purchase neither cancels nor restarts outsourcing")
	_check(is_equal_approx(board.by_uid[tool].task_progress_display_value(), 0.4), "visible outsource bar stays at the original forty percent")
	if OS.has_environment("WORK_OUTSOURCE_PURCHASE_CAPTURE"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://reports/outsource-uninterrupted-purchase.png")
	for viewport_size in [Vector2i(1440, 810), Vector2i(960, 540)]:
		root.size = viewport_size
		main.hud.relayout()
		await process_frame
		_check(root.get_visible_rect().encloses(main.hud._header.get_global_rect()), "reservation header fits " + str(viewport_size))
	state.advance(timer)
	board.sync_state(state)
	main._update_hud()
	_check(state.work_count(0) == 4 and state.money(0) == 8 - int(offer.price), "outsource completes its original batch and charges reserved money exactly once")
	_check(state.reserved_money(0) == 0 and not state.outsourcing.has(tool), "completion releases all reserved balance")
	_check(not main.hud.lbl_player_res.text.contains("预留"), "header returns to normal after reservation ends")
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("OUTSOURCE_PURCHASE_UI %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _buy_offer(id: int) -> void:
	var card: CardEntity = board.offers_by_id[id]
	var tag: Node3D = card.get_meta("price_tag").get_ref()
	await _click(board.camera.unproject_position(tag._paper.global_position))

func _point(card: CardEntity) -> Vector2:
	var ordinary := super._point(card)
	if ordinary != Vector2.INF: return ordinary
	# Twenty-one actual cards expose a narrower header than the former
	# fourteen-card wallet fixture. Target its real visible strip, not a
	# hidden face or a direct business-method substitute for pointer input.
	for z in [-0.49, -0.47, -0.45]:
		var at := board.camera.unproject_position(card.global_position + Vector3(0.0, CardEntity.Y_TEXT, z * CardEntity.CARD_SIZE.z))
		if main.hud.content_rect().has_point(at) and board._pick_card(at) == card: return at
	return Vector2.INF
