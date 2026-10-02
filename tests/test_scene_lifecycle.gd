# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 时间交叉回归：正式场景进入等待后终局/换局，旧协程不能推进新局。
class DelayedTransport extends LocalTransport:
	var pending := false
	var delay_buy := false
	var reject_op := ""
	var seen: Array = []
	func submit(intent, from_seat := "") -> Dictionary:
		seen.append(intent["op"])
		if pending:
			return _publish(Intent.err("busy", "上一步还在等服务器回话"))
		if intent["op"] == reject_op:
			reject_op = ""
			return _publish(Intent.err("rejected", "测试：服务器拒绝了这一步"))
		if delay_buy and intent["op"] == Intent.OP_BUY:
			pending = true
			await (Engine.get_main_loop() as SceneTree).create_timer(0.25).timeout
			pending = false
		return await super.submit(intent, from_seat)

func _initialize() -> void:
	await _restart_during_action()
	await _restart_during_settle()
	await _in_flight_and_rejection()
	await _combo_rejection()
	await _rules_reload_waits_for_search()
	await _detached_rematch()
	finish()

func _close(main: Node) -> void:
	main._invalidate_session()
	main.queue_free()
	await process_frame

func _restart_during_action() -> void:
	var main: Node = await boot_main()
	main._on_action_done()
	main._on_resign_pressed()
	await main._on_resign_pressed()
	check(main.game_over_panel != null, "行动等待中认输确实进入终局")
	main._on_restart()
	var fresh: GameState = main.state
	var fingerprint := StateCodec.state_hash(fresh)
	await create_timer(1.0).timeout
	check(main.state == fresh and StateCodec.state_hash(fresh) == fingerprint,
		"旧行动协程醒来后，新局状态保持不变")
	check(main.pipe.seq == 0 and main.phase == main.PHASE_ACTION and main._actor == main.my_seat,
		"新局没有被旧流程替玩家跳过行动")
	check(main._local_turn_flows == 0, "已取消的行动计数正常收尾")
	await _close(main)

func _restart_during_settle() -> void:
	var main: Node = await boot_main()
	main._run_settle()
	main._on_resign_pressed()
	await main._on_resign_pressed()
	main._on_restart()
	var fingerprint := StateCodec.state_hash(main.state)
	await create_timer(1.0).timeout
	check(StateCodec.state_hash(main.state) == fingerprint and main.pipe.seq == 0,
		"结算等待中重开，不会对新局执行 finalize/next_round")
	await _close(main)

func _in_flight_and_rejection() -> void:
	var main: Node = await boot_main()
	var transport := DelayedTransport.new(main.pipe.applier())
	main.pipe = transport
	main.set_foe_remote(true)
	transport.delay_buy = true
	main._try_buy(0)
	check(transport.pending and main.btn_pass.disabled and main.board.input_locked,
		"购买等待回执期间统一锁住牌桌与完成行动")
	await main._on_action_done()
	check(not transport.seen.has(Intent.OP_ACTION_DONE), "购买等待期间不发送完成行动")
	await create_timer(0.35).timeout
	check(not main.btn_pass.disabled and not main.board.input_locked,
		"购买结束后恢复玩家输入")
	transport.reject_op = Intent.OP_ACTION_DONE
	await main._on_action_done()
	check(main._actor == main.my_seat and main.phase == main.PHASE_ACTION,
		"结束行动被拒绝后保持原行动方与阶段")
	check(not main.btn_pass.disabled and not main.board.input_locked and not main._client_action_pending,
		"拒绝回执释放动作锁，玩家可以重试")
	check(main.lbl_msg.text.contains("服务器拒绝"), "拒绝原因显示给玩家")
	await _close(main)

func _combo_rejection() -> void:
	var main: Node = await boot_main()
	var members: Array = []
	var ids: Array = ["yunketang"]
	for i in int(CardDB.get_def("yunketang")["recipe_n"]):
		ids.append(CardDB.unit_id(CardDB.RES_USER))
	for id in ids:
		var record: Dictionary = main.state.add_card(main.my_seat, id)
		members.append(main._spawn_entity(record, Vector3.ZERO, true))
	main.board.groups.append(main.board.make_group(members, true))
	var transport := DelayedTransport.new(main.pipe.applier())
	transport.reject_op = Intent.OP_COMBO
	main.pipe = transport
	await main._on_action_done()
	check(transport.seen.has(Intent.OP_COMBO) and not transport.seen.has(Intent.OP_ACTION_DONE),
		"编组提交失败时，不再偷偷结束行动")
	check(main._actor == main.my_seat and not main.board.input_locked and not main.btn_pass.disabled,
		"编组失败后玩家仍可修正牌组")
	await _close(main)

func _rules_reload_waits_for_search() -> void:
	var main: Node = await boot_main()
	var default_price := int(CardDB.get_def("yunketang")["price"])
	var custom: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CardConfig.DEFAULT_PATH))
	custom["yunketang"]["price"] = default_price + 1
	var path := ProjectSettings.globalize_path("user://reload-during-search.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(custom))
	file.close()
	check(main.choose_card_config(path).get("ok", false), "准备下一局的自定义规则")
	main.state.winner = GameState.PLAYER
	main._show_game_over()
	var observed: Array = []
	main._think_off_thread(func():
		OS.delay_msec(80)
		observed.append(int(CardDB.get_def("yunketang")["price"]))
		return {})
	check(main._think.busy(), "重开前确有后台搜索正在读取全局规则")
	main._on_restart()
	check(observed == [default_price] and not main._think.busy(),
		"重开先等待旧搜索读完原规则，再重载卡表")
	check(int(CardDB.get_def("yunketang")["price"]) == default_price + 1,
		"搜索收尾后新局实际应用所选规则")
	await process_frame
	var live_state: GameState = main.state
	var state_before := StateCodec.state_hash(main.state)
	var rules_before := StateCodec.table_hash()
	var tape_head: Dictionary = main.tape.head.duplicate(true)
	var tape_steps: Array = main.tape.steps.duplicate(true)
	var prepared: Dictionary = main.prepare_network_cards()
	var hosted: Dictionary = main.start_local_host()
	check(not prepared.get("ok", true) and not hosted.get("ok", true) and main._host == null,
		"自定义规则局明确拒绝加入或开启联网等待")
	check(main.state == live_state and StateCodec.state_hash(main.state) == state_before
		and StateCodec.table_hash() == rules_before and main.tape.head == tape_head
		and main.tape.steps == tape_steps, "拒绝联网后原局、规则和录像完整保留")
	main.clear_card_config()
	check(main.apply_selected_card_config().get("ok", false), "恢复默认并开新局后可再次联网")
	var joined: Array = []
	main._think_off_thread(func():
		OS.delay_msec(80)
		joined.append(true)
		return {})
	prepared = main.prepare_network_cards()
	check(prepared.get("ok", false) and joined == [true] and not main._think.busy(),
		"默认规则局联网准备也收完搜索，保护内嵌服务器重载")
	await process_frame
	await _close(main)

func _detached_rematch() -> void:
	var main: Node = await boot_main()
	var old := NetTransport.new("ws://127.0.0.1:1", "OLD")
	old.rematch_voted.connect(main._on_rematch_voted)
	old.rematch_started.connect(main._on_rematch_started)
	main._detach_net_signals(old)
	check(not old.rematch_voted.is_connected(main._on_rematch_voted)
		and not old.rematch_started.is_connected(main._on_rematch_started),
		"换连接完整断开旧连接的重开投票与开始信号")
	main.state.winner = GameState.PLAYER
	main._show_game_over()
	var panel: Control = main.game_over_panel
	var fingerprint := StateCodec.state_hash(main.state)
	old.rematch_started.emit(GameState.AI, GameState.PLAYER)
	main._on_rematch_started(GameState.AI, GameState.PLAYER)
	check(main.game_over_panel == panel and StateCodec.state_hash(main.state) == fingerprint,
		"旧连接的迟到重开不会拆掉当前单机终局或改牌局")
	await _close(main)
