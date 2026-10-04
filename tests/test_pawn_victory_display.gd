# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Replay = preload("res://engine/replay_session.gd")
const Snapshot = preload("res://scenes/table_snapshot.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	AISearch.set_pref_strength(0.0)
	var main := await boot_main()
	var state: GameState = main.state
	state.combos.clear()
	state.players[main.foe_seat]["cards"].clear()
	var threshold := int(CardDB.game_rules()["win_cash"])
	for i in threshold - 5:
		state.add_card(main.foe_seat, "cash")
	state.add_card(main.foe_seat, "user")
	var pawned: Array = []
	for i in 2:
		pawned.append(state.add_card(main.foe_seat, "yinqing996")["uid"])
	state.draw_first = main.foe_seat
	main._actor = main.foe_seat
	main._respawn_all()
	await settle()
	main.tape.start(main.pipe.applier(), "典当冲线画面回归")
	main.tape.update_view()
	var before: Dictionary = Snapshot.capture(main)["positions"]
	# 真实 AI 选择确定获胜的典当，经过落地广播及正常终局入口。
	main._run_foe_action()
	var deadline := Time.get_ticks_msec() + 5000
	while state.winner == "" and Time.get_ticks_msec() < deadline:
		await process_frame
	check(state.winner == main.foe_seat and main._table_actions.pawn_busy()
		and main.phase != PhaseMachine.OVER, "胜负已裁决时仍先演完典当，不提前遮住到账过程")
	if main._table_actions.pawn_busy():
		await main._table_actions.pawn_finished
	await process_frame
	await settle()
	var expected := threshold + 1
	check(state.winner == main.foe_seat and state.resource_count(main.foe_seat, CardDB.RES_CASH) == expected,
		"两张 996 典当后现金从 %d 到 %d，按真实规则获胜" % [threshold - 5, expected])
	check(main.phase == PhaseMachine.OVER and is_instance_valid(main.game_over_panel),
		"真实 AI 典当冲线后正常进入结局")
	_check_cash(main, expected, "实时典当获胜")
	check(pawned.all(func(uid): return not main.entities.has(uid)), "已典当的卡全部从牌桌撤下")
	check(main.lbl_msg.text.contains(str(expected)) and not main.lbl_msg.text.contains("在即"),
		"胜利提示给出已经到账的实际现金")
	main.tape.update_view()
	var saved: Dictionary = main.tape.to_dict().duplicate(true)
	var view: Dictionary = saved["steps"][-1]["view"]
	var fresh: Array = []
	for card in state.players[main.foe_seat]["cards"]:
		if not before.has(str(card["uid"])):
			fresh.append(str(card["uid"]))
	check(fresh.size() == 6 and fresh.all(func(uid): return view["positions"].has(uid)),
		"新录像的结尾牌桌位置包括全部六张典当所得现金")
	# 旧录像只记下卖牌后的旧卡位，缺少六张新现金；保持权威状态及哈希完整。
	for uid in fresh:
		view["positions"].erase(uid)
	var path := "user://pawn-victory-missing-positions.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(saved))
	file.close()
	main.queue_free()
	_booted = null
	await process_frame
	await process_frame
	var loaded := Replay.load_path(path)
	if not need(loaded.get("ok", false), "缺少新现金位置的旧录像仍能校验并读入"):
		finish()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.replay_session = loaded["session"]
	root.add_child(main)
	_booted = main
	await settle()
	await main._replay_next()
	_check_cash(main, expected, "旧录像逐步播放典当获胜")
	main._replay_previous()
	await settle()
	_check_cash(main, threshold - 5, "旧录像退回典当前")
	main._replay_step_input.text = str(main.replay_session.action_count())
	var jumped: Dictionary = main._replay_jump()
	await settle()
	check(jumped.get("ok", false), "旧录像直接跳转到获胜步")
	_check_cash(main, expected, "旧录像直接跳转末态")
	AISearch.restore_defaults()
	finish()

func _check_cash(main: Node, expected: int, label: String) -> void:
	var displayed := 0
	var piled := 0
	for card in main.state.players[main.foe_seat]["cards"]:
		if card["def_id"] != "cash":
			continue
		var uid: int = card["uid"]
		if main.entities.has(uid) and is_instance_valid(main.entities[uid]):
			displayed += 1
			if main.entities[uid].position.z < 0 and main.layout._ai_pile_of_uid.has(uid):
				piled += 1
	check(displayed == expected and piled == expected,
		"%s：%d 张现金均有实体并归入对手资源摞（实际 %d / %d）" % [label, expected, displayed, piled])
	check(main.lbl_ai_res.text.contains("%s %d" % [CardDB.res_label(CardDB.RES_CASH), expected])
		and main.hud_ai_card.cash_value.text == str(expected), "%s：两种 HUD 的现金读数与牌桌一致" % label)
