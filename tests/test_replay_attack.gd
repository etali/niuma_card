# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 用当前卡表现录现播：同一现金摞的连续攻击只点一次，逐击更新动画和资源栏。
const Replay = preload("res://engine/replay_session.gd")
const PATH := "user://replay-attack-test.json"

class ObservedSound extends Sfx:
	var host: Node
	var hits: Array = []
	func play(action: String, _pitch := 1.0) -> void:
		if action == "attack_tear":
			hits.append({"points": int(host.pipe.applier().pools(host.my_seat)[CardDB.RES_CASH]),
				"cash": host.state.resource_count(host.foe_seat, CardDB.RES_CASH), "hud": host.lbl_bot_res.text})

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	var record := _record()
	if record == null:
		finish()
		return
	var original := JSON.stringify(record.to_dict())
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	file.store_string(original)
	file.close()
	var loaded := Replay.load_path(PATH)
	if not need(loaded.get("ok", false), "读入当前卡表录制的连续攻击：%s" % loaded.get("reason", "")):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
		finish()
		return
	var session: RefCounted = loaded["session"]
	check(session.seek(1).get("ok", false), "回放真实装弹步骤，重新生成攻击来源")
	var attack_start := 1
	var hits := record.size() - 2  # 装弹、攻击阶段结束分别独立计步。
	var points := int(session.applier.pools(GameState.PLAYER)[CardDB.RES_CASH])
	var cash: int = session.state.resource_count(GameState.BOT, CardDB.RES_CASH)
	var cost := int(CardDB.game_rules()["attack_cost_per_card"])
	var sources: Array = session.state.players[GameState.PLAYER]["cards"].filter(
		func(card): return int(card.get("fired_round", -1)) == session.state.round_num).map(func(card): return card["uid"])
	check(not sources.is_empty(), "录像保留实际装弹武器的攻击来源")
	check(session.action_count() == 3 and session.action_groups[1]["start"] == attack_start
		and session.action_groups[1]["end"] == attack_start + hits, "同摞连续攻击合并为一个行动")
	var action: Dictionary = session.advance_action()
	check(action.get("ok", false) and action.get("frames", []).size() == hits and session.cursor == attack_start + hits,
		"一次前进包含全部逐击状态")
	for i in action.get("frames", []).size():
		var frame: Dictionary = action["frames"][i]
		var state: GameState = frame["state"]
		check(frame["applier"].pools(GameState.PLAYER)[CardDB.RES_CASH] == points - cost * (i + 1)
			and state.resource_count(GameState.BOT, CardDB.RES_CASH) == cash - i - 1, "第%d击的独立状态与攻击点一致" % (i + 1))
		check(sources.all(func(uid): return int(state.find_card(GameState.PLAYER, uid).get("fired_round", -1)) == state.round_num),
			"逐击克隆状态后保留真实攻击来源")
	var previous: Dictionary = session.previous_action()
	check(previous.get("ok", false) and session.cursor == attack_start and session.applier.pools(GameState.PLAYER)[CardDB.RES_CASH] == points,
		"一次后退恢复整摞攻击之前")
	check(sources.all(func(uid): return int(session.state.find_card(GameState.PLAYER, uid).get("fired_round", -1)) == session.state.round_num),
		"后退再播放仍可复原攻击来源")
	check(session.seek_action(2).get("ok", false) and session.cursor == attack_start + hits
			and session.state.resource_count(GameState.BOT, CardDB.RES_CASH) == cash - hits,
		"输入行动步2直达整摞攻击结束，不落到原始第2条意图的第一击")
	check(session.seek_action(1).get("ok", false) and session.cursor == attack_start,
		"输入行动步1完整恢复攻击前状态")

	paused = false
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.replay_session = session
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	await settle()
	var sound := ObservedSound.new()
	sound.host = main
	main.add_child(sound)
	main.sfx = sound
	var targets := {}
	for index in range(attack_start, attack_start + hits):
		var uid := int(session.record.steps[index]["intent"]["target"]["uids"][0])
		targets[uid] = main.entities[uid]
	var torn := {}
	main.btn_pass.pressed.emit()  # 整段攻击只有这一次按钮输入。
	var locked := true
	var deadline := Time.get_ticks_msec() + 20000
	while main._replay_busy and Time.get_ticks_msec() < deadline:
		locked = locked and main.btn_pass.disabled and main._replay_previous_button.disabled \
			and main._replay_jump_button.disabled and not main._replay_step_input.editable
		for uid in targets:
			if is_instance_valid(targets[uid]) and targets[uid]._visual_retired:
				torn[uid] = true
		await process_frame
	check(not main._replay_busy, "一次点击自动播完整段攻击，无需第二次输入")
	check(locked, "全部攻击动画结束前前后步进与跳转控件一直锁定")
	check(torn.size() == hits, "每张受击卡实际进入正式撕牌动画")
	check(sound.hits.size() == 1, "同摞录像只发出一次整批撕纸声音")
	if not sound.hits.is_empty():
		check(sound.hits[0]["points"] == points - cost * hits and sound.hits[0]["cash"] == cash - hits,
			"整批撕纸时点数与移除数量对应完整裁决结果")
		check(("%s%d" % [CardDB.res_label(CardDB.RES_CASH), cash - hits]) in sound.hits[0]["hud"],
			"整批动画的资源栏显示本次攻击结算金额")
	check(session.cursor == attack_start + hits and session.action_cursor == 2 and main.state.resource_count(main.foe_seat, CardDB.RES_CASH) == cash - hits,
		"一次点击后真实牌桌停在整摞攻击结束处")
	check(main.pipe.applier().pools(main.my_seat)[CardDB.RES_CASH] == points - cost * hits and not main.btn_pass.disabled,
		"当前行动消耗正确点数，下一步等待新输入")
	var shown_cash := 0
	for key in main.layout._bot_pile_uids:
		if str(key).begins_with("bot_cash"):
			shown_cash += main.layout._bot_pile_uids[key].size()
	check(shown_cash == cash - hits, "对手现金摞及侧边张数同步更新")
	check(not "同一组合" in main.lbl_msg.text, "提示不把现金堆误称为规则组合")
	main._replay_previous_button.pressed.emit()
	await settle()
	check(session.cursor == attack_start and main.state.resource_count(main.foe_seat, CardDB.RES_CASH) == cash
		and targets.keys().all(func(uid): return main.entities.has(uid)), "真实上一步按钮恢复全部受击卡和攻击前现金")
	check(FileAccess.get_file_as_string(PATH) == original, "回放没有改写录像文件")
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()

func _record() -> Tape:
	var state := GameState.new()
	state.set_seed(9271)
	state.new_game()
	var weapon := state.add_card(GameState.PLAYER, "zuokong")
	var definition := CardDB.get_def("zuokong")
	var uids: Array = [weapon["uid"]]
	for i in int(definition["recipe_n"]):
		uids.append(state.add_card(GameState.PLAYER, CardDB.unit_id(definition["recipe_res"]))["uid"])
	var ap := IntentApply.new(state)
	if not need(ap.apply(Intent.create_combo(GameState.PLAYER, uids), GameState.PLAYER).get("ok", false), "按当前配方组建现金攻击组合"):
		return null
	var count := int(definition["attack_n"]) / int(CardDB.game_rules()["attack_cost_per_card"])
	if not need(count >= 2, "当前卡表提供足够点数验证连续攻击"):
		return null
	while state.resource_count(GameState.BOT, CardDB.RES_CASH) <= count:
		state.add_card(GameState.BOT, CardDB.unit_id(CardDB.RES_CASH))
	var record := Tape.new()
	record.start(ap)
	if not need(ap.apply(Intent.arm_attacks(GameState.PLAYER)).get("ok", false), "通过真实裁决器装弹"):
		record.stop()
		return null
	for i in count:
		var targets := ap.affordable_targets(GameState.PLAYER).filter(func(target): return target["res"] == CardDB.RES_CASH)
		if not need(not targets.is_empty(), "当前规则下存在可攻击的现金卡"):
			record.stop()
			return null
		if not need(ap.apply(Intent.apply_attack(GameState.PLAYER, targets[0]), GameState.PLAYER).get("ok", false), "录制真实现金攻击"):
			record.stop()
			return null
	ap.apply(Intent.attack_done(GameState.PLAYER), GameState.PLAYER)
	record.stop()
	return record
