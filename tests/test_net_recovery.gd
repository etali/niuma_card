# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 真 socket + 正式 JoinPanel/回合流程；接管会走 start_local_host_takeover。
const BASE := 48540
const ReplaySession = preload("res://engine/replay_session.gd")

func _initialize() -> void:
	CardDB.load_default()
	_checkpoint_packet_boundary()
	for mine in [0, 1]:
		await _reconnect_action(mine)
	for actor_index in [0, 1]:
		for mine in [0, 1]:
			await _reconnect_attack(actor_index, mine)
	await _takeover_during_settlement()
	await _takeover_before_buy_presentation()
	net_stop()
	finish()

func _client_for(clients: Array, seat: String) -> NetTransport:
	return clients[0] if clients[0].my_seat == seat else clients[1]

func _give_attack(room: NetRoom, seat: String) -> void:
	var uids: Array = [room.state.add_card(seat, "heigongguan")["uid"]]
	uids.append_array(room.state._loose_unit_uids(seat, CardDB.RES_CASH).slice(0, 4))
	check(room.state.create_combo(seat, uids).get("ok", false), "准备攻击组 %s" % seat)

func _join_again(clients: Array, room: NetRoom, seat: String) -> Node:
	var old := _client_for(clients, seat)
	old.close()
	if not need(await net_until(clients, func(): return int(room.occupants[seat]) == 0), "真实断线空出旧座位"):
		return null
	var main := await boot_main()
	var panel: JoinPanel = main._open_join_panel()
	panel._connect("ws://127.0.0.1:%d" % _port, room.code)
	if not need(await net_until(clients, func(): return main._net != null and main.my_seat == seat), "正式面板重连回原座位"):
		return main
	check(not is_instance_valid(panel), "入座后等待面板释放")
	return main

func _dispose(main: Node, clients: Array) -> void:
	if is_instance_valid(main):
		main._invalidate_session()
		if main._net != null:
			main._detach_net_signals(main._net)
			main._net.close()
			main._net.poll()
		main._net = null
		main.stop_local_host()
		main.set_process(false)
	for client in clients:
		client.close()
		client.poll()
	net_stop()
	await settle()
	if is_instance_valid(main): main.queue_free()
	await process_frame

func _reconnect_action(mine_index: int) -> void:
	print("-- 后手 ACTION 重连，恢复座位 index=%d --" % mine_index)
	var clients := await net_seated_pair(BASE, 719, "ACTIONRESUME")
	if clients.is_empty(): return
	var room: NetRoom = _srv.rooms["ACTIONRESUME"]
	var order := room.state.action_order()
	_client_for(clients, order[0])._send(Protocol.intent(Intent.action_done(order[0])))
	if not need(await net_until(clients, func(): return room.phase.actor == order[1]), "服务端轮到后手"):
		await _dispose(null, clients)
		return
	var main := await _join_again(clients, room, order[mine_index])
	if main == null: return
	check(main._actor == order[1], "恢复服务端当前 actor，不退回先手")
	check(main.board.input_locked == (mine_index == 0), "只有当前行动方输入开放")
	if mine_index == 1:
		main._on_action_done()
	else:
		_client_for(clients, order[1])._send(Protocol.intent(Intent.action_done(order[1])))
	check(await net_until(clients, func(): return main.state.round_num == 2 and main.phase == PhaseMachine.ACTION, 8000), "后手完成后真正推进下一回合")
	check(StateCodec.state_hash(main.state) == StateCodec.state_hash(room.state), "重连后的下一回合与服务器一致")
	await _dispose(main, clients)

func _reconnect_attack(actor_index: int, mine_index: int) -> void:
	print("-- ATTACK 重连 actor=%d / mine=%d --" % [actor_index, mine_index])
	var clients := await net_seated_pair(BASE, 719, "ATTACKRESUME")
	if clients.is_empty(): return
	var room: NetRoom = _srv.rooms["ATTACKRESUME"]
	var order := room.state.action_order()
	for seat in order: _give_attack(room, seat)
	for seat in order:
		_client_for(clients, seat)._send(Protocol.intent(Intent.action_done(seat)))
		await net_pump(clients, 5)
	if not need(await net_until(clients, func(): return room.phase.phase == PhaseMachine.ATTACK), "服务端进入有弹药的攻击阶段"):
		await _dispose(null, clients)
		return
	if actor_index == 1:
		_client_for(clients, order[0])._send(Protocol.intent(Intent.attack_done(order[0])))
		check(await net_until(clients, func(): return room.phase.actor == order[1]), "先攻已经完成")
	var before := room.snapshot()
	var main := await _join_again(clients, room, order[mine_index])
	if main == null: return
	check(await net_until(clients, func(): return main._attack_actor == order[actor_index]), "攻击互动从当前攻击者恢复")
	check(StateCodec.canon_hash(room.snapshot()) == StateCodec.canon_hash(before), "恢复本身不重复装弹或扣费")
	for index in range(actor_index, order.size()):
		var seat: String = order[index]
		if seat == main.my_seat:
			if need(await net_until(clients, func(): return main.board.attack_mode), "恢复方出现可操作攻击目标"):
				var targets: Array = main.pipe.applier().affordable_targets(seat)
				if need(not targets.is_empty(), "恢复方有合法攻击目标"):
					var uid: int = targets[0]["uids"][0]
					main._on_attack_clicked(main.entities[uid])
					check(await net_until(clients, func(): return room.state.find_card(main.foe_seat, uid).is_empty()), "恢复后真实点击攻击被服务端采纳")
					await net_until(clients, func(): return not main._client_action_pending)
				if room.phase.phase == PhaseMachine.ATTACK and room.phase.actor == seat:
					main._finish_player_attack()
		else:
			_client_for(clients, seat)._send(Protocol.intent(Intent.attack_done(seat)))
		check(await net_until(clients, func(): return room.phase.phase != PhaseMachine.ATTACK or room.phase.actor != seat), "当前攻击者收手，服务端继续")
	check(await net_until(clients, func(): return main.state.round_num == 2 and main.phase == PhaseMachine.ACTION, 8000), "两方攻击结束后重连场景进入下一回合")
	check(StateCodec.state_hash(main.state) == StateCodec.state_hash(room.state), "攻击恢复后的最终状态一致")
	await _dispose(main, clients)

func _checkpoint_packet_boundary() -> void:
	print("-- 在结算第一包截断，恢复检查点和录像 --")
	var room := NetRoom.new("PACKET", 719)
	room.seat_peer(11)
	room.seat_peer(12)
	room.start_if_ready()
	var net := NetTransport.new()
	net._on_text(Protocol.encode(room.seated_msg(GameState.PLAYER)))
	var tape := Tape.new()
	tape.start_remote(net)
	tape.view_provider = func(): return {"phase": PhaseMachine.SETTLING, "actor": ""}
	var order := room.state.action_order()
	var first_peer: int = room.occupants[order[0]]
	for item in room.handle_intent(first_peer, Intent.action_done(order[0])):
		net._on_text(Protocol.encode(item["msg"]))
	var out := room.handle_intent(int(room.occupants[order[1]]), Intent.action_done(order[1]))
	# 第二人收手的第一条回执已经包含整个事务的最终检查点，后面的包全部丢弃。
	net.defer_scene_events()
	net._on_text(Protocol.encode(out[0]["msg"]))
	check(net.state().round_num == 1 and room.state.round_num == 2, "展示仍在旧回合，服务端事务已结束")
	check(net.restore_checkpoint(true), "第一包足以恢复完整事务")
	net.resume_scene_events()
	check(StateCodec.canon_hash(net.recovery_checkpoint()) == StateCodec.canon_hash(room.recovery_checkpoint()), "快照、阶段、actor、seq 同属最终事务")
	check(StateCodec.state_hash(net.state()) == StateCodec.state_hash(room.state), "包边界恢复没有丢失已确认进度")
	# 在线候选连接还会收到同一批剩余包，不能把已恢复的 round 2 再退回 round 1。
	var restored_seq := net.seq
	for index in range(1, out.size()):
		net._on_text(Protocol.encode(out[index]["msg"]))
		check(net._inbox.is_empty() and net.seq == restored_seq and net.phase() == room.phase.phase \
			and net.actor() == room.phase.actor and StateCodec.state_hash(net.state()) == StateCodec.state_hash(room.state),
			"检查点之后的迟到 %s 不回退状态、序号或阶段" % out[index]["msg"]["t"])
	check(tape.steps[-1]["result"]["op"] == Protocol.RECOVERY_STEP, "缺失的逐步回执记录为明确的恢复快照")
	check(not Intent.from_dict({"op": Protocol.RECOVERY_STEP}).get("ok", false), "恢复标记不能被当作玩家意图提交")
	var path := tape.save("packet-recovery.json")
	var loaded := Tape.load_from(path)
	check(loaded.get("ok", false), "带恢复步骤的录像可保存读回")
	if loaded.get("ok", false):
		var replay := Tape.replay(loaded["tape"])
		check(replay.get("ok", false) and StateCodec.state_hash(replay["state"]) == StateCodec.state_hash(room.state), "逐步重放哈希与权威终态一致")
		var session := ReplaySession.load_path(path)
		check(session.get("ok", false), "交互回放可载入恢复快照")
		if session.get("ok", false):
			var player = session["session"]
			check(player.seek(tape.size()).get("ok", false) and player.phase == room.phase.phase and player.actor == room.phase.actor, "回放还原恢复时的阶段与行动方")
	var bad := net.recovery_checkpoint()
	bad["seq"] = "2"
	var message := room.seated_msg(GameState.PLAYER)
	message["recovery"] = bad
	check(not Protocol.from_dict(message).get("ok", false), "坏检查点结构化拒绝")
	for broken in [null, [], {"phase": PhaseMachine.ATTACK}, {"snapshot": [], "phase": PhaseMachine.ACTION, "actor": GameState.PLAYER, "seq": 1}]:
		message["recovery"] = broken
		check(not Protocol.from_dict(message).get("ok", false), "畸形检查点不会进入恢复路径")
	tape.stop()
	# 水位仅屏蔽旧事务；后续合法操作以及再来一局不能被它吞掉。
	var actor := room.phase.actor
	for item in room.handle_intent(int(room.occupants[actor]), Intent.action_done(actor)):
		net._on_text(Protocol.encode(item["msg"]))
	check(net.seq > restored_seq and net.actor() == room.phase.actor, "恢复后新的 ACTION_DONE 仍正常落地")
	for item in room.handle_intent(int(room.occupants[actor]), Intent.resign(actor)):
		net._on_text(Protocol.encode(item["msg"]))
	net.restore_checkpoint()
	for item in room.reset_for_rematch():
		if int(item["to"]) in [0, 11]: net._on_text(Protocol.encode(item["msg"]))
	check(net.phase() == PhaseMachine.ACTION and net.actor() == room.phase.actor, "再来一局重置恢复水位，新阶段正常到达")
	actor = room.phase.actor
	for item in room.handle_intent(int(room.occupants[actor]), Intent.action_done(actor)):
		net._on_text(Protocol.encode(item["msg"]))
	check(net.seq == room.seq and net.actor() == room.phase.actor, "再来一局的首次行动仍可推进")

func _takeover_during_settlement() -> void:
	print("-- 正式结算演出中停服接管 --")
	var clients := await net_seated_pair(BASE, 719, "TAKERESUME")
	if clients.is_empty(): return
	var room: NetRoom = _srv.rooms["TAKERESUME"]
	var a := _client_for(clients, room.phase.actor)
	var b := _client_for(clients, GameState.opponent(a.my_seat))
	var uids: Array = [room.state.add_card(a.my_seat, "yunketang")["uid"]]
	uids.append_array(room.state._loose_unit_uids(a.my_seat, CardDB.RES_USER).slice(0, 3))
	check(room.state.create_combo(a.my_seat, uids).get("ok", false), "准备有实际产出的生产组")
	for peer in room.peers(): _srv._send_one(peer, room.seated_msg(room.seat_of(peer)))
	await net_until(clients, func(): return a.state().combos.size() == 1)
	var main := await boot_main()
	main.begin_net_game(a)
	main._on_action_done()
	await net_until(clients, func(): return room.phase.actor == b.my_seat)
	b._send(Protocol.intent(Intent.action_done(b.my_seat)))
	if not need(await net_until(clients, func(): return main.phase == PhaseMachine.SETTLING and a._inbox.size() >= 2), "真实收包队列尚有结算步骤"):
		await _dispose(main, clients)
		return
	var authority := room.recovery_checkpoint()
	check(room.state.round_num == 2 and main.state.round_num == 1, "捕捉服务器已经到下回合、画面尚未到达的窗口")
	net_stop()
	if not need(await net_until(clients, func(): return main._net != a and main._host != null and main._net.online(), 6000), "真实停服触发正式主机接管"):
		await _dispose(main, clients)
		return
	var adopted: NetRoom = main._host.server.rooms["TAKERESUME"]
	check(StateCodec.canon_hash(adopted.recovery_checkpoint()) == StateCodec.canon_hash(authority), "接管保留最新状态、弹药池、阶段、actor 和序号")
	check(main.state.round_num == 2 and main.phase == PhaseMachine.ACTION, "旧演出取消，场景直接恢复正确回合")
	var other := NetTransport.new(main._host.url(), "TAKERESUME")
	other.resume_token = b.resume_token
	other.connect_to_server()
	check(await net_until([other], func(): return other.has_dealt_state()), "对手能够连接接管后的房间")
	for seat in adopted.state.action_order():
		if seat == main.my_seat:
			await net_until([other], func(): return main._actor == seat and not main.board.input_locked)
			main._on_action_done()
		else:
			other._send(Protocol.intent(Intent.action_done(seat)))
		await net_until([other], func(): return adopted.phase.actor != seat or adopted.state.round_num > 2)
	check(await net_until([other], func(): return main.state.round_num == 3 and main.phase == PhaseMachine.ACTION, 8000), "接管后双方还能真正走完下一回合")
	check(StateCodec.state_hash(main.state) == StateCodec.state_hash(adopted.state), "恢复后继续游戏没有旧协程覆盖新状态")
	var replay := Tape.replay(main.tape)
	check(replay.get("ok", false) and StateCodec.state_hash(replay["state"]) == StateCodec.state_hash(main.state), "接管前后录像连续且终态一致")
	await _dispose(main, clients + [other])

func _takeover_before_buy_presentation() -> void:
	print("-- 购买回执已收、输入协程还没呈现时接管 --")
	var clients := await net_seated_pair(BASE, 719, "BUYRESUME")
	if clients.is_empty(): return
	var room: NetRoom = _srv.rooms["BUYRESUME"]
	var a := _client_for(clients, room.phase.actor)
	var main := await boot_main()
	main.begin_net_game(a)
	var observed := {}
	var on_receipt := func(result: Dictionary, _snapshot: Dictionary):
		if result.get("op") != Intent.OP_BUY: return
		observed["uid"] = int(result["new_uid"])
		observed["pending"] = main._client_action_pending and not main.entities.has(observed["uid"])
		# 精确控制断线通知落在 ACK 和购买协程恢复之间；状态仍来自真实服务器回执。
		net_stop()
		main._on_net_down("no_server", "购买回执后服务端断开")
	a.recorded_step.connect(on_receipt)
	var index := -1
	for i in room.state.market.size():
		if int(CardDB.get_def(room.state.market[i]).get("price", 0)) <= room.state.resource_count(a.my_seat, CardDB.RES_CASH):
			index = i
			break
	if not need(index >= 0, "存在可以买的市场卡"):
		await _dispose(main, clients)
		return
	main._try_buy(index)
	check(await net_until(clients, func(): return main._net != a and main._net.online(), 6000), "ACK 窗口接管成功")
	check(observed.get("pending", false), "断线时购买回执已落地、实体尚未生成")
	if observed.has("uid"):
		check(main.entities.has(observed["uid"]), "接管补出已购卡实体")
		check(main.market_cards.size() == main.state.market.size(), "市场实体同步已完成的购买")
	check(not main._client_action_pending and not main.board.input_locked, "旧购买协程取消，后续输入可继续")
	a.recorded_step.disconnect(on_receipt)
	await _dispose(main, clients)
