# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

class GuardMain extends "res://scenes/main.gd":
	var handed_to_foe := false
	func _foe_action() -> void:
		handed_to_foe = true  # 只观察交接，避免测试后半段启动无关BOT。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	_check_engine_preview()
	await _check_button()
	await _check_inactive_piles()
	await _check_corrected_pile()
	await _check_network()
	finish()

func _bare(who := GameState.PLAYER) -> GameState:
	var state := GameState.new()
	state.set_seed(227)
	state.new_game()
	state.players[who]["cards"].clear()
	state.draw_first = who
	state.add_card(who, CardDB.unit_id(CardDB.RES_USER))
	return state

func _pile(state: GameState, who: String, id: String) -> Dictionary:
	var def := CardDB.get_def(id)
	var uids: Array = [state.add_card(who, id)["uid"]]
	for i in int(def["recipe_n"]):
		uids.append(state.add_card(who, CardDB.unit_id(def["recipe_res"]))["uid"])
	return {"uids": uids}

func _check_engine_preview() -> void:
	for who in [GameState.PLAYER, GameState.BOT]:
		for id in CardDB.all_cards():
			var def := CardDB.get_def(id)
			if def.get("recipe_res") != CardDB.RES_CASH or int(def.get("recipe_n", 0)) <= 0:
				continue
			var state := _bare(who)
			var pile := _pile(state, who, id)
			var before := StateCodec.snapshot(state)
			var result := Settle.check_action_completion(state, who, [pile])
			check(not result["ok"] and result["resource"] == CardDB.RES_CASH, "%s %s花光资金被提前拦截" % [who, id])
			check(StateCodec.snapshot(state) == before and state.combos.is_empty(), "预检不改卡牌、锁定、战报、随机数或胜负")
			state.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
			check(Settle.check_action_completion(state, who, [pile])["ok"], "付完还有1份资源即可完成行动")
	var state := _bare()
	var pay := _pile(state, GameState.PLAYER, "chunwan")
	var income := _pile(state, GameState.PLAYER, "yunketang")
	check(Settle.check_action_completion(state, GameState.PLAYER, [pay, income])["ok"], "现金生产先到账，可支付稍后的生产配方，与摆摞先后无关")
	state = _bare()
	var a := _pile(state, GameState.PLAYER, "butie")
	var b := _pile(state, GameState.PLAYER, "butie")
	check(not Settle.check_action_completion(state, GameState.PLAYER, [a, b])["ok"], "两组单独付得起，累计装弹会归零也要拦")
	income = _pile(state, GameState.PLAYER, "yunketang")
	check(not Settle.check_action_completion(state, GameState.PLAYER, [income, a, b])["ok"], "尚未到账的生产收入不能抵扣此前的攻击弹药")
	state = _bare()
	a = _pile(state, GameState.PLAYER, "chunwan")
	b = _pile(state, GameState.PLAYER, "chunwan")
	check(not Settle.check_action_completion(state, GameState.PLAYER, [a, b])["ok"], "多组生产累计耗尽也要拦")
	state = _bare()
	state.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
	var seats := _pile(state, GameState.PLAYER, "yunketang")
	check(Settle.check_action_completion(state, GameState.PLAYER, [seats])["ok"], "用户作为席位不消耗，不误拦仅剩这些用户的组合")
	check(Settle.check_action_completion(state, GameState.PLAYER, [{"uids": [seats["uids"][0]]}])["ok"], "未成立的残缺组合没有消费，不强迫玩家完成配方")
	var old: Dictionary = CardDB.CARDS["chunwan"].duplicate(true)
	CardDB.CARDS["chunwan"]["recipe_n"] = int(old["recipe_n"]) + 2
	state = _bare()
	pay = _pile(state, GameState.PLAYER, "chunwan")
	check(not Settle.check_action_completion(state, GameState.PLAYER, [pay])["ok"], "预检付款数量随cards配置改变，没有另写阈值")
	CardDB.CARDS["chunwan"]["output_res"] = CardDB.RES_CASH
	CardDB.CARDS["chunwan"]["output_n"] = int(CardDB.CARDS["chunwan"]["recipe_n"]) + 5
	check(not Settle.check_action_completion(state, GameState.PLAYER, [pay])["ok"], "同一组先消耗至零再产现金，即使净收益为正也拒绝")
	state.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
	check(Settle.check_action_completion(state, GameState.PLAYER, [pay])["ok"], "同组付款时有余额，才可接着产出")
	CardDB.CARDS["chunwan"] = old

func _build_group(main: Node, pile: Dictionary) -> Dictionary:
	var cards: Array = []
	for uid in pile["uids"]:
		var card: CardEntity = main.entities[int(uid)]
		main.board._detach_from_group(card)
		cards.append(card)
	var group: Dictionary = main.board.make_group(cards, true)
	main.board.groups.append(group)
	main.board._layout_group(group, Vector3(0, 0.05, 3.8))
	return group

func _check_button() -> void:
	paused = false
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main := GuardMain.new()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.state = _bare()
	var pile := _pile(main.state, main.my_seat, "chunwan")
	main._rebuild_pipe()
	main._respawn_all()
	main._actor = main.my_seat
	main.phase = main.PHASE_ACTION
	main.board.input_locked = false
	main.btn_pass.disabled = false
	main._set_button(main.TXT_ACTION_DONE, main._on_action_done)
	var group := _build_group(main, pile)
	await settle()
	var initial := StateCodec.snapshot(main.state)
	var card_order: Array = group["cards"].map(func(c): return c.uid)
	var before_tape: int = main.tape.size()
	var pos: Vector2 = main.btn_pass.position
	var deny_stream: Resource = main.sfx._streams[Sfx.action("deny")["sound"]]
	check(deny_stream.resource_path.ends_with("deny.wav"), "拒绝音取自现有deny.wav配置")
	for attempt in 2:
		var next: int = main.sfx._next
		main.btn_pass.pressed.emit()
		check(main.sfx._next == (next + 1) % Sfx.POOL_SIZE and main.sfx._players[next].stream == deny_stream, "被拒时真实音效池播放deny.wav")
		var tween: Tween = main.btn_pass.get_meta("deny_tween")
		tween.pause()
		tween.custom_step(0.04)
		check(absf(main.btn_pass.rotation) > 0.001, "完成行动按钮真实产生震动")
		tween.play()
		await tween.finished
		check(is_zero_approx(main.btn_pass.rotation) and main.btn_pass.position.is_equal_approx(pos), "震动后按钮归位且连续点击不漂移")
		check(main.phase == main.PHASE_ACTION and main._actor == main.my_seat and not main.btn_pass.disabled and not main.board.input_locked, "拒绝后仍可拖牌调整，行动权不交接")
		check(main.tape.size() == before_tape and StateCodec.snapshot(main.state) == initial, "拒绝不注册组合、不消耗牌、不新增录像操作")
		check(group["cards"].map(func(c): return c.uid) == card_order and not main.handed_to_foe, "拒绝不擅自拆组合或触发BOT")
	main.sfx.set_user_muted(true)
	var muted_slot: int = main.sfx._next
	main.btn_pass.pressed.emit()
	check(main.sfx._next == muted_slot and main.btn_pass.has_meta("deny_tween"), "静音时保留拒绝和震动，遵守喇叭开关")
	await (main.btn_pass.get_meta("deny_tween") as Tween).finished
	main.sfx.set_user_muted(false)
	# 真正取消这摞后，再点按钮才交接；不重新开局、不改资源。
	main.board._remove_group(group)
	await main._on_action_done()
	check(main.handed_to_foe and main._actor == main.foe_seat, "取消危险组合后完成行动正常交接")
	check(main.tape.steps.any(func(e): return e["intent"]["op"] == Intent.OP_ACTION_DONE), "安全提交保留正常录像流程")
	main.queue_free()
	await process_frame

func _check_network() -> void:
	var clients: Array = await net_seated_pair(48740, 552, "ACTIONGUARD")
	if clients.is_empty():
		return
	var a: NetTransport = clients[0]
	var b: NetTransport = clients[1]
	await net_until(clients, func(): return a.phase() != "")
	var room: NetRoom = _srv.rooms["ACTIONGUARD"]
	var active: NetTransport = a if a.actor() == a.my_seat else b
	var who := active.my_seat
	room.state.players[who]["cards"].clear()
	room.state.add_card(who, CardDB.unit_id(CardDB.RES_USER))
	var pile := _pile(room.state, who, "chunwan")
	# 夹具改了服务器状态后也要经正式消息同步权威检查点；只改显示快照会在
	# begin_net_game 的恢复流程中被旧检查点正确覆盖，并非这组牌已真正入座。
	for peer in room.peers():
		_srv._send_one(peer, room.seated_msg(room.seat_of(peer)))
	var checkpoint_hash := StateCodec.canon_hash(room.recovery_checkpoint())
	if not need(await net_until(clients, func():
		return StateCodec.canon_hash(a.recovery_checkpoint()) == checkpoint_hash \
			and StateCodec.canon_hash(b.recovery_checkpoint()) == checkpoint_hash),
		"联网夹具通过服务器消息同步状态与权威恢复检查点"):
		for client in clients:
			client.close()
		net_stop()
		return
	var main: Node = await boot_main()
	main.begin_net_game(active)
	await net_until(clients, func(): return main._actor == who and not main.board.input_locked)
	_build_group(main, pile)
	await settle()
	var before := StateCodec.state_hash(room.state)
	var seq: int = active.seq
	main.btn_pass.pressed.emit()
	await net_pump_for(clients, 120)
	check(StateCodec.state_hash(room.state) == before and active.seq == seq, "联网完成行动被拒时不提交组合或action_done到服务器")
	check(room.phase.actor == who and not room.phase.is_done(who) and not main.board.input_locked, "联网被拒后服务器仍等本玩家，客户端仍可修改组合")
	main.queue_free()
	await process_frame
	for client in clients:
		client.close()
	net_stop()

## 未成立的牌摞不阻止后面的有效组合，也不阻止完成行动。
func _check_inactive_piles() -> void:
	for with_valid in [false, true]:
		var main := GuardMain.new()
		main.force_drawer_layout = true
		root.add_child(main)
		_booted = main
		main.drawer_window.set_process(false)
		main.drawer_window.animations_enabled = false
		main.drawer_window.pin()
		main.state = _bare()
		main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))
		var invalid := _pile(main.state, main.my_seat, "shuabuting")
		invalid["uids"].pop_back()
		var valid := _pile(main.state, main.my_seat, "yunketang") if with_valid else {}
		main._rebuild_pipe()
		main._respawn_all()
		main._actor = main.my_seat
		main.phase = main.PHASE_ACTION
		main.board.input_locked = false
		main.btn_pass.disabled = false
		_build_group(main, invalid)
		if with_valid:
			_build_group(main, valid)
		await main._on_action_done()
		check(main.handed_to_foe and main._actor == main.foe_seat, "存在无效编组仍可完成行动（含有效组=%s）" % with_valid)
		check(main.state.combos.size() == (1 if with_valid else 0), "跳过无效编组并继续注册后续有效组")
		check(not main.state.find_card(main.my_seat, invalid["uids"][0])["locked"], "无效编组保持闲置，不锁牌")
		check(main.tape.steps.any(func(e): return e["intent"]["op"] == Intent.OP_ACTION_DONE), "无效编组不阻止记录完成行动")
		main.queue_free()
		await process_frame

func _check_corrected_pile() -> void:
	for complete_recipe in [false, true]:
		var main := GuardMain.new()
		main.force_drawer_layout = true
		root.add_child(main)
		_booted = main
		main.drawer_window.set_process(false)
		main.drawer_window.animations_enabled = false
		main.drawer_window.pin()
		main.state = _bare()
		var pile := _pile(main.state, main.my_seat, "chunwan")
		main._rebuild_pipe()
		main._respawn_all()
		main._actor = main.my_seat
		main.phase = main.PHASE_ACTION
		main.board.input_locked = false
		main.btn_pass.disabled = false
		_build_group(main, pile)
		await main._on_action_done()
		check(not main.handed_to_foe and (CardDB.res_label(CardDB.RES_CASH) + "会归零") in main.lbl_msg.text, "危险组合阻止完成行动并准确提示现金归零")
		if complete_recipe:
			# 保留配方，增加余款后不再耗尽资源。
			main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))
		else:
			# 从原摞取出一张材料，配方不成立，因此不会发生消费。
			main.board._detach_from_group(main.entities[pile["uids"][-1]])
		await main._on_action_done()
		check(main.handed_to_foe, "修正原牌摞后重新计算，允许完成行动（配方完整=%s）" % complete_recipe)
		check(main.state.combos.size() == (1 if complete_recipe else 0), "仅修正后成立的组合生效")
		check(main.lbl_msg.text == "已完成行动", "修正成功后替换旧错误提示")
		main.queue_free()
		await process_frame
