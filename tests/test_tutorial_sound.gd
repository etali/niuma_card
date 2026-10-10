# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

class RecordedSound extends Sfx:
	var events: Array = []
	func play(action_name: String, pitch := 1.0) -> void:
		var index := _next
		super.play(action_name, pitch)
		if index != _next:
			events.append({"action": action_name, "spec": Sfx.action(action_name).duplicate(true),
				"stream": _players[index].stream, "db": _players[index].volume_db,
				"pitch": _players[index].pitch_scale})

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	var original_rules := CardDB.SFX
	CardDB.SFX = original_rules.duplicate(true)
	CardDB.SFX["actions"]["pile_toggle"] = {"sound": "drop", "db": -13.0, "pitch": 1.31}
	var customized_rules := CardDB.SFX
	var sound := RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	var original_mode := sound.process_mode
	var original_streams := sound._streams.duplicate()
	var sound_count := main.find_children("*", "Sfx", true, false).size()
	var original_pile: CardEntity = _resource_pile(main.board)
	var before: Array = await _toggle_pair(main.board, sound, original_pile)
	check(_actions(before) == ["pile_toggle", "pile_toggle"], "正式对局收摞与展开各发一声原pile_toggle")
	check(main.drawer_presentation.start_tutorial("income"), "在原牌桌进入教学")
	var arena: Node = main._tutorial_arena
	check(arena.sfx == sound and arena._card_motion.sfx == sound
		and main.find_children("*", "Sfx", true, false).size() == sound_count,
		"教程动作及动画直接共用原Sfx实例，没有新建播放器")
	check(is_same(CardDB.SFX, customized_rules) and sound._streams == original_streams,
		"标准教学卡表不覆盖当前音效配置或已加载的音源")
	check(sound.process_mode == Node.PROCESS_MODE_ALWAYS and sound._players[0].can_process(),
		"原播放器在教学暂停期间仍可处理声音")
	check(sound.events == before, "初始教学编组不额外播放凑组提示")
	var lesson_pile: CardEntity = _resource_pile(main.board)
	var during: Array = await _toggle_pair(main.board, sound, lesson_pile)
	check(_actions(during) == ["pile_toggle", "pile_toggle"] and during[0].spec == before[0].spec
		and during[0].stream == before[0].stream and during[0].db == before[0].db,
		"教学收摞和展开沿用同一动作、音源、音量与自定义音高配置")
	check(absf(float(during[0].pitch) / 1.31 - 1.0) <= 0.041,
		"教学保留原音高配置及原有微随机范围")
	await _check_drop_and_combo(arena, sound)
	sound.events.clear()
	arena.session.retry()
	arena.sync_state(true)
	check(sound.events.is_empty(), "重试自动重建牌组不会冒充玩家凑组发声")
	lesson_pile = _resource_pile(main.board)
	main.drawer_presentation._toggle_sound()
	main.board.toggle_compact(lesson_pile)
	check(sound.user_muted and sound.events.is_empty(), "原喇叭静音立即作用于教程摞牌")
	main.drawer_presentation._toggle_sound()
	sound.set_drawer_suspended(true)
	main.board.toggle_compact(lesson_pile)
	check(sound.events.is_empty(), "抽屉挂起仍会抑制普通摞牌声音")
	sound.set_drawer_suspended(false)
	main.board.toggle_compact(lesson_pile)
	check(_actions(sound.events) == ["pile_toggle"], "展开抽屉后只恢复一条摞牌声音路由")
	main.drawer_presentation.finish_tutorial(false)
	check(sound.process_mode == original_mode and main.sfx == sound and is_same(CardDB.SFX, customized_rules),
		"退出保留原声音实例和配置，恢复播放器处理模式")
	var after: Array = await _toggle_pair(main.board, sound, original_pile)
	check(_actions(after) == ["pile_toggle", "pile_toggle"] and after[0].spec == before[0].spec
		and after[0].stream == before[0].stream,
		"回到正式对局后收摞与展开仍是原配置且各只响一次")
	CardDB.SFX = original_rules
	await dispose_drawer(main)
	finish()

func _resource_pile(board: Board) -> CardEntity:
	for group in board.groups:
		if group["cards"].size() > 1 and group["cards"][0].draggable and group["cards"][0].def_id == "cash":
			return group["cards"][0]
	return null

func _toggle_pair(board: Board, sound: RecordedSound, card: CardEntity) -> Array:
	sound.events.clear()
	board.toggle_compact(card)
	await create_timer(0.25).timeout
	board.toggle_compact(card)
	await create_timer(0.25).timeout
	return sound.events.duplicate(true)

func _actions(events: Array) -> Array:
	return events.map(func(event): return event.action)

func _check_drop_and_combo(arena: Node, sound: RecordedSound) -> void:
	var board: Board = arena.board
	var user: CardEntity
	for card in arena.entities.values():
		if card.draggable and card.def_id == "user": user = card; break
	board._detach_from_group(user)
	sound.events.clear()
	board._on_card_clicked(user)
	user.global_position = Vector3(0, Board.DRAG_HEIGHT, 4.0)
	board._end_drag()
	await process_frame
	check(_actions(sound.events) == ["card_pickup", "card_drop"], "真实拿牌落桌只播放一次拿牌和一次原落牌声")
	arena.session.buy(0)
	arena.sync_state()
	var core: CardEntity
	var material: Array = []
	for card in arena.entities.values():
		if card.draggable and card.def_id == "yunketang": core = card
		if card.draggable and card.def_id == "user": material.append(card)
	if not need(core != null and material.size() >= 3, "存在真实业务与三张材料用于合组音效检查"): return
	arena.apply_groups([[core.uid, material[0].uid, material[1].uid]])
	board._detach_from_group(material[2])
	await create_timer(0.25).timeout
	sound.events.clear()
	board._on_card_clicked(material[2])
	material[2].global_position = core.global_position + Vector3(0, Board.DRAG_HEIGHT, 0)
	board._end_drag()
	await process_frame
	var actions := _actions(sound.events)
	check(actions.count("combo_complete") == 1 and actions.count("card_drop") == 1
		and actions.count("card_pickup") == 1 and not actions.has("pile_toggle"),
		"真实凑组与落桌各发一声，card_stacked不重复播放收摞声")
