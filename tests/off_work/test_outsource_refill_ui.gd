extends "res://tests/off_work/test_work_ui.gd"

## Reproduce a well-funded stack waiting through recovery, then refill its
## active batch without restarting the visible timer or exposing its funds.
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
	state.config.rules.initial.groups = [{"employee": 1}, {"work": 27}, {"work": 12}, {"outsource": 1}]
	state.config.rules.initial.money = 3
	main._new_game()
	var tool := _owned("outsource")
	var work := _owned("work")
	var group: int = state.cards[work].group
	var spare_group := -1
	for gid in state.groups:
		if int(state.groups[gid].owner) == 0 and state.group_work(gid).size() == 12: spare_group = gid
	state.move_cards(_owned_ids("money") + [tool], group)
	_check(state.outsourcing.has(tool), "valid ordinary stacking automatically starts outsourcing")
	state.advance(state.config.number("outsource", "seconds"))
	_check(state.group_work(group).size() == 24 and state.cards[tool].status == "recovering", "first real batch leaves 24 work and enters recovery")
	var funds: Array = state._credit(0, 156)
	state.move_cards(funds, group)
	_refresh_view()
	await _settle()
	var card: OffWorkCard = board.by_uid[tool]
	_check(card._task_progress.visible and card._task_progress_phase == "recovering", "funded stack visibly explains recovery instead of showing no bar")
	_check(is_equal_approx(card.task_progress_display_value(), 1.0), "recovery bar begins full")
	state.advance(state.config.number("outsource", "recovery_seconds") * 0.5)
	_refresh_view()
	_check(is_equal_approx(card.task_progress_display_value(), 0.5), "recovery bar drains toward readiness")
	state.advance(state.config.number("outsource", "recovery_seconds") * 0.5)
	_refresh_view()
	_check(state.outsourcing.has(tool) and card._task_progress.visible and card._task_progress_phase == "outsource", "same 24-work 156-money stack automatically starts when recovered")
	state.advance(4.0)
	_refresh_view()
	_check(is_equal_approx(card.task_progress_display_value(), 0.4), "real outsourcing progress is visible at forty percent")
	var remaining: float = state.cards[tool].remaining
	var added: Array = state.group_work(spare_group).slice(0, 7)
	state.move_cards(added, group)
	_refresh_view()
	await _settle()
	_check(is_equal_approx(float(state.cards[tool].remaining), remaining), "refilling keeps the existing deadline")
	_check(is_equal_approx(card.task_progress_display_value(), 0.4) and card._task_progress.visible, "refilling keeps the visible progress instead of restarting or hiding it")
	_check(state.reserved_money(0) == 31 and state.available_money(0) == 125, "newly included work reserves only its matching funds")
	_check(main.hud.lbl_player_res.text.contains("预留31"), "HUD immediately exposes the expanded reservation")
	if OS.get_environment("WORK_OUTSOURCE_REFILL_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await _frames_for_capture()
		DirAccess.make_dir_recursive_absolute("res://reports")
		_check(root.get_texture().get_image().save_png("res://reports/outsource-refill-progress.png") == OK, "real active refill screenshot saved")
	state.drain_events()
	state.advance(remaining)
	_refresh_view()
	var completed: Array = state.drain_events().filter(func(event): return event.kind == "outsource" and int(event.source) == tool)
	_check(completed.size() == 1, "expanded batch completes once at its original deadline")
	_check(state.group_work(group).is_empty() and state.work_count(0) == 5, "all 24 original plus 7 added work are cleared together")
	_check(state.money(0) == 125 and state.reserved_money(0) == 0, "expanded batch charges 31 exactly once without income")
	_check(card._task_progress.visible and card._task_progress_phase == "recovering", "completion immediately exposes the recovery timer")
	main.queue_free()
	await process_frame
	await process_frame
	for failure in failures: push_error(failure)
	print("OUTSOURCE_REFILL_UI %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _refresh_view() -> void:
	board.sync_state(state)
	main._update_hud()

func _frames_for_capture() -> void:
	await process_frame
	await process_frame
	RenderingServer.force_draw(false)
