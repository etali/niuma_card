extends "res://tests/off_work/test_work_ui.gd"

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
	for buff_first in [true, false]:
		for compact in [true, false]: await _both_sides(buff_first, compact)
	await _slack_top()
	await _dedicated_progress()
	await _pure_buffs()
	await _original_drag()
	main.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("BUFF_STACK_ORDER %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _owner_id(kind: String, owner: int) -> int:
	for id in state.cards:
		if state.cards[id].type == kind and int(state.cards[id].owner) == owner: return int(id)
	return -1

func _back(card: CardEntity) -> bool:
	return board._settings.stack_display.back_cards.has(card.def_id)

func _assert_partition(group: Dictionary, presenter: Board) -> void:
	var top: OffWorkCard = group.cards[presenter._top_index(group)]
	_check(not _back(top), "visible top is not a configured buff")
	var nonbuff_seen := false
	var list: Array = group.cards.duplicate()
	if bool(group.compact): list.reverse()
	for card: OffWorkCard in list:
		if not _back(card): nonbuff_seen = true
		elif nonbuff_seen: _check(false, "all buffs are behind all non-buffs")
	var regular: Array = group.cards.filter(func(card): return not _back(card))
	var buffs: Array = group.cards.filter(_back)
	var ordered: Array = board._stack_face_order(group)
	_check(ordered.filter(func(card): return not _back(card)) == regular and ordered.filter(_back) == buffs, "partition is stable inside both card classes")
	_check(ordered == group.cards, "reapplying display priority does not reshuffle the stack")

func _both_sides(buff_first: bool, compact: bool) -> void:
	state.config.rules.initial.groups = [{"employee": 2, "work": 30}]
	main._new_game()
	state.advance(1.0)
	var logical := {}
	var progress := {}
	for owner in [0, 1]:
		var person := _owner_id("employee", owner)
		var group: int = state.cards[person].group
		var additions: Array = []
		for type in ["overtime", "overtime", "overtime"]: additions.append(state.add_card(type, owner))
		if buff_first:
			var first: int = state.cards[additions[0]].group
			state.move_cards(state.group_cards(group) + additions.slice(1), first)
			group = first
		else:
			state.move_cards(additions, group)
		logical[group] = state.group_cards(group).duplicate()
		progress[group] = state.group_work_progress(group)
	board.sync_state(state)
	await _settle()
	for owner in [0, 1]:
		var presenter: Board = board._presenter(owner)
		var person := _owner_id("employee", owner)
		var group: Dictionary = presenter.group_of(board.by_uid[person])
		if bool(group.compact) != compact: presenter.toggle_compact(group.cards[presenter._top_index(group)])
	board.sync_state(state)
	await _settle()
	for owner in [0, 1]:
		var presenter: Board = board._presenter(owner)
		var person := _owner_id("employee", owner)
		var group: Dictionary = presenter.group_of(board.by_uid[person])
		var gid: int = state.cards[person].group
		_assert_partition(group, presenter)
		var top: OffWorkCard = group.cards[presenter._top_index(group)]
		_check(top.type in ["employee", "work"], "production exposes its people or work instead of overtime")
		_check(top._task_progress.visible and is_equal_approx(top._task_progress_value, progress[gid]), "visible face keeps the actual shared work bar")
		_check(state.group_cards(gid) == logical[gid] and is_equal_approx(state.group_work_progress(gid), progress[gid]), "visual ordering preserves simulation order and progress")
		_check(group.cards.filter(_back).all(func(card): return not card._task_progress.visible), "hidden buffs do not borrow a work progress bar")
		var visual_order: Array = group.cards.duplicate()
		board.sync_state(state)
		_check(group.cards == visual_order, "periodic syncing preserves the stable buff partition")
	await _capture_order("compact" if compact else "expanded")

func _slack_top() -> void:
	state.config.rules.initial.groups = [{"employee": 1}, {"slack": 2}, {"work": 4}]
	main._new_game()
	await _settle()
	for owner in [0, 1]:
		var person := _owner_id("employee", owner)
		var tool := _owner_id("slack", owner)
		# 一个座位将人员放到摸鱼上，另一个座位将摸鱼放到人员上。
		if owner == 0:
			var target: Dictionary = board.group_of(board.by_uid[tool])
			await _drag(board.by_uid[person], _point(target.cards[board._top_index(target)]))
		else:
			state.move_cards(state.group_cards(state.cards[tool].group), state.cards[person].group)
	state.advance(1.0)
	board.sync_state(state)
	for owner in [0, 1]:
		var tool := _owner_id("slack", owner)
		var presenter: Board = board._presenter(owner)
		var group: Dictionary = presenter.group_of(board.by_uid[tool])
		var gid: int = state.cards[tool].group
		var logical: Array = state.group_cards(gid).duplicate()
		_check(state.groups[gid].job == "slack", "人员与摸鱼组成实际的生产组合")
		for compact in [true, false, true]:
			# 对方桌面禁止本地输入，但可按持久化的 compact 值还原两种形态。
			if owner == 0:
				if group.compact != compact:
					presenter.toggle_compact(group.cards[presenter._top_index(group)])
			else:
				var origin := presenter.rest_origin(group)
				group.compact = compact
				presenter._layout_group(group, origin)
			board.sync_state(state)
			await _settle()
			var top: OffWorkCard = group.cards[presenter._top_index(group)]
			_check(top.uid == tool and top._visual.is_visible_in_tree(), "多张摸鱼稳定露出同一张顶牌")
			_check(group.cards.all(func(card): return card == top or card.global_position.y < top.global_position.y),
				"摸鱼的真实牌面位于其他成员上方")
			_check(top._task_progress.visible and is_equal_approx(top._task_progress_value, state.group_slack_progress(gid)),
				"摸鱼顶牌显示同一批次的真实生产进度")
			_check(state.group_cards(gid) == logical, "牌桌排序保留记录中的成员顺序")

func _dedicated_progress() -> void:
	state.config.rules.initial.groups = [{"leader": 1, "meeting": 1, "overtime": 3}, {"employee": 3, "work": 100}]
	main._new_game()
	for owner in [0, 1]:
		var meeting := _owner_id("meeting", owner)
		_check(state.activate(meeting), "leader can start meeting in a buff-heavy stack")
	state.advance(1.0)
	board.sync_state(state)
	for compact in [true, false]:
		for owner in [0, 1]:
			var meeting := _owner_id("meeting", owner)
			var presenter: Board = board._presenter(owner)
			var group: Dictionary = presenter.group_of(board.by_uid[meeting])
			if bool(group.compact) != compact: presenter.toggle_compact(group.cards[presenter._top_index(group)])
		board.sync_state(state)
		for owner in [0, 1]:
			var meeting := _owner_id("meeting", owner)
			var presenter: Board = board._presenter(owner)
			var group: Dictionary = presenter.group_of(board.by_uid[meeting])
			_assert_partition(group, presenter)
			_check(group.cards[presenter._top_index(group)].uid == meeting, "meeting remains visibly first in both stack shapes and both sides")
			_check(board.by_uid[meeting]._task_progress.visible and is_equal_approx(board.by_uid[meeting]._task_progress_value, state.cards[meeting].progress), "meeting retains its own real dedicated timer")
	state.config.rules.initial.groups = [{"overtime": 2, "employee": 1, "coffee": 1}, {"overtime": 2, "employee": 1, "work": 50}]
	main._new_game()
	for owner in [0, 1]: state.activate(_owner_id("coffee", owner))
	state.advance(1.0)
	board.sync_state(state)
	for owner in [0, 1]:
		var coffee := _owner_id("coffee", owner)
		var presenter: Board = board._presenter(owner)
		var group: Dictionary = presenter.group_of(board.by_uid[coffee])
		if bool(group.compact): presenter.toggle_compact(group.cards[presenter._top_index(group)])
	board.sync_state(state)
	for owner in [0, 1]:
		var coffee := _owner_id("coffee", owner)
		var presenter: Board = board._presenter(owner)
		var group: Dictionary = presenter.group_of(board.by_uid[coffee])
		_assert_partition(group, presenter)
		_check(board.by_uid[coffee]._task_progress.visible and is_equal_approx(board.by_uid[coffee]._task_progress_value, state.cards[coffee].progress), "coffee progress remains its own upgrade timer")
		_check(board._work_progress_card(group, presenter) == null, "independent coffee stack has no fabricated work timer")
		var production: Dictionary = presenter.group_of(board.by_uid[_owner_id("work", owner)])
		var representative: OffWorkCard = board._work_progress_card(production, presenter)
		_check(representative != null and representative.type in ["employee", "work"] and not representative.has_dedicated_progress(), "ordinary work uses personnel or work, never the coffee or buff face")
		_check(group.cards.filter(_back).all(func(card): return not card._task_progress.visible), "coffee's neighboring buffs never show a borrowed work timer")

func _pure_buffs() -> void:
	state.config.rules.initial.groups = [{"employee": 1, "work": 30}, {"overtime": 4}]
	main._new_game()
	for compact in [true, false]:
		for owner in [0, 1]:
			var presenter: Board = board._presenter(owner)
			var group: Dictionary = presenter.group_of(board.by_uid[_owner_id("overtime", owner)])
			if bool(group.compact) != compact: presenter.toggle_compact(group.cards[presenter._top_index(group)])
		board.sync_state(state)
		for owner in [0, 1]:
			var presenter: Board = board._presenter(owner)
			var group: Dictionary = presenter.group_of(board.by_uid[_owner_id("overtime", owner)])
			var top: OffWorkCard = group.cards[presenter._top_index(group)]
			_check(group.cards.size() == 4 and top.visible and top._icon.visible and top._icon.texture != null, "pure buff stack retains a visible complete top face")
			_check(board._work_progress_card(group, presenter) == null and group.cards.all(func(card): return not card._task_progress.visible), "pure buffs have no fabricated production progress")

func _original_drag() -> void:
	state.config.rules.initial.groups = [{"employee": 2, "work": 4}, {"overtime": 1}, {"overtime": 1}]
	main._new_game()
	board.set_process(true)
	await _settle()
	var person := _owned("employee")
	var gid: int = state.cards[person].group
	for tool in state.cards.keys().filter(func(id): return state.cards[id].type == "overtime" and state.cards[id].owner == 0):
		var group: Dictionary = board.group_of(board.by_uid[person])
		var top: OffWorkCard = group.cards[board._top_index(group)]
		await _drag(board.by_uid[tool], _point(top))
		_check(state.cards[tool].group == gid, "real pointer drag combines the buff")
		_assert_partition(board.group_of(board.by_uid[person]), board)
	var group: Dictionary = board.group_of(board.by_uid[person])
	await _click(_point(group.cards[board._top_index(group)]), true)
	_check(not group.compact, "original double click still expands the buff-bearing stack")
	var members: Array = group.cards.duplicate()
	var cut := members.size() - 2
	var expected: Array = members.slice(cut).map(func(card): return card.uid)
	await _drag(members[cut], _empty_point(), true)
	var actual: Array = state.group_cards(state.cards[expected[0]].group)
	expected.sort(); actual.sort()
	_check(actual == expected and state.group_cards(gid).size() == cut, "dragging a middle card still moves exactly its displayed suffix")

func _capture_order(label: String) -> void:
	if OS.get_environment("WORK_BUFF_ORDER_CAPTURE") != "1" or DisplayServer.get_name() == "headless": return
	main._update_hud()
	main.hud._detail.hide()
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png("res://reports/buff-stack-%s.png" % label) == OK, "captures " + label + " buff order")
