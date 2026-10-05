# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 收起后的状态来自真实回合交接；单机BOT继续走，远端通过真实socket收手。
const PORT_BASE := 48520
var _pump_done := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 收起抽屉时的对手状态回归 ===")
	# 只改当前进程的搜索偏好；不保存、不碰玩家的偏好文件。
	BOTSearch.set_pref_strength(0.0)
	await _opening_purchase_switches()
	await _bot_first_hands_over()
	await _bot_second_crosses_round()
	await _attack_hands_over()
	await _pawn_win_finishes_collapsed()
	await _net_opening_purchase_switches(GameState.PLAYER)
	await _net_opening_purchase_switches(GameState.BOT)
	await _net_hands_over(GameState.PLAYER)
	await _net_hands_over(GameState.BOT)
	net_stop()
	finish()

func _opening_purchase_switches() -> void:
	var main := await _boot_drawer()
	main.drawer_window.collapse_now()
	_check_opening_hover(main, "首回合尚未行动")
	check(paused, "开场邀请时收起仍暂停等待玩家")
	main.drawer_window.pin()
	main.drawer_window.collapse_now()
	_check_opening_hover(main, "仅展开收起不算开始行动")
	main.drawer_window.pin()
	var choice := -1
	var cash: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	for i in main.state.market.size():
		if int(CardDB.get_def(main.state.market[i]).get("price", 0)) < cash:
			choice = i
			break
	if not need(choice >= 0, "首回合市场中有玩家买得起的卡"):
		await _dispose(main)
		return
	var wrong_pay: Array = []
	for card in main.state.players[main.my_seat]["cards"]:
		if str(card["def_id"]) == CardDB.unit_id(CardDB.RES_USER):
			wrong_pay.append(card["uid"])
			break
	var rejected: Dictionary = await main._try_buy(choice, wrong_pay)
	check(not rejected.get("ok", false), "用用户卡支付的真实购买被拒")
	main.drawer_window.collapse_now()
	_check_opening_hover(main, "购卡失败仍保留开场邀请")
	main.drawer_window.pin()
	var purchased: Dictionary = await main._try_buy(choice)
	check(purchased.get("ok", false), "首次真实购卡成功")
	main.drawer_window.collapse_now()
	_check_status(main, "your_turn", "轮到你行动", "首次购卡后")
	var handle: DrawerMascot = main.drawer_presentation._handle
	handle.mouse_entered.emit()
	handle.greet()
	check(handle._greeting_label.text == "轮到你行动"
		and not "来摸一局" in handle.tooltip_text, "已首次购牌后悬停和招呼事件都不恢复邀请")
	handle.mouse_exited.emit()
	main.drawer_window.pin()
	main.drawer_window.collapse_now()
	_check_status(main, "your_turn", "轮到你行动", "已行动后再次收起")
	await _dispose(main)

func _bot_first_hands_over() -> void:
	var main := await _boot_drawer()
	_small_local_fixture(main)
	main.state.draw_first = main.foe_seat
	main._begin_action_phase()
	main.drawer_window.collapse_now()
	check(not paused, "BOT先手：收起后场景继续推进")
	_check_status(main, "foe_acting", "等待对手行动", "BOT先手")
	var completed := await _until(func():
		return (main.phase == main.PHASE_ACTION and main._actor == main.my_seat
			and not main.board.input_locked and paused))
	check(completed, "BOT先手：实际搜索与意图落地在收起状态完成，并停在玩家后手")
	_check_status(main, "foe_done", "等待你行动", "BOT交棒")
	check(not main.drawer_window.is_expanded(), "BOT完成不擅自展开抽屉")
	_advance_motion(main.drawer_presentation._handle, 0.35)
	check(main.drawer_presentation._handle._bubble.modulate.a > 0.95,
		"暂停等待玩家时，等待你行动气泡仍可见且不需悬停")
	main.drawer_window.pin()
	main.drawer_window.collapse_now()
	_check_status(main, "foe_done", "等待你行动", "再收起保留本回合完成状态")
	await _check_priorities_and_restart(main)
	await _dispose(main)

func _bot_second_crosses_round() -> void:
	var main := await _boot_drawer()
	_small_local_fixture(main)
	main.drawer_window.collapse_now()
	_check_opening_hover(main, "玩家先手尚未行动")
	check(paused, "玩家先手：收起暂停等待玩家")
	main.drawer_window.pin()
	var round_before: int = main.state.round_num
	main._on_action_done()
	check(not main._opening_action_pending, "首次点击完成行动结束开场邀请，即使没有购买")
	main.drawer_window.collapse_now()
	check(not paused, "玩家收手后：BOT后手时收起不暂停")
	_check_status(main, "foe_acting", "等待对手行动", "BOT后手")
	var saw_settling := false
	var saw_new_round_acting := false
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		var current: String = main.drawer_presentation._handle.state()
		if main.phase == main.PHASE_SETTLING:
			saw_settling = saw_settling or current == "resolving"
		if main.state.round_num > round_before and main._actor == main.foe_seat:
			saw_new_round_acting = saw_new_round_acting or current == "foe_acting"
		if main.state.round_num > round_before and main._actor == main.my_seat and paused:
			break
		await process_frame
	check(saw_settling, "BOT后手完成后，收起状态经过自动结算并提示结算中")
	check(saw_new_round_acting, "新回合BOT先手时提示重新变为等待对手，未沿用上回合完成")
	check(main.state.round_num == round_before + 1 and main._actor == main.my_seat and paused,
		"无攻击的整回合在后台推进，下一次需要玩家操作时自动暂停")
	_check_status(main, "foe_done", "等待你行动", "下一回合BOT完成")
	await _dispose(main)

func _attack_hands_over() -> void:
	var main := await _boot_drawer()
	var core := ""
	var cheapest := 2147483647
	for id in CardDB.all_cards():
		var candidate: Dictionary = CardDB.get_def(id)
		if (candidate.get("kind") == CardDB.KIND_ATTACK
				and candidate.get("recipe_res") == CardDB.RES_USER
				and candidate.get("attack_res") == CardDB.RES_CASH
				and int(candidate.get("recipe_n", 0)) < cheapest):
			core = str(id)
			cheapest = int(candidate["recipe_n"])
	if not need(core != "", "攻击夹具有用户配方、攻击现金的核心卡"):
		await _dispose(main)
		return
	var definition: Dictionary = CardDB.get_def(core)
	var attack_n := int(definition["attack_n"])
	main.state.market.clear()
	main.state.combos.clear()
	for who in [main.my_seat, main.foe_seat]:
		main.state.players[who]["cards"].clear()
		var uids: Array = [main.state.add_card(who, core)["uid"]]
		for i in cheapest:
			uids.append(main.state.add_card(who, "user")["uid"])
		for i in attack_n + 2:
			main.state.add_card(who, "cash")
		check(main.state.create_combo(who, uids).get("ok", false),
			"%s座位具备真实攻击组合" % who)
	main.state.draw_first = main.foe_seat
	main._respawn_all()
	main._run_attacks()
	main.drawer_window.collapse_now()
	check(not paused, "BOT攻击期间收起仍继续选靶和结算")
	_check_status(main, "foe_attacking", "对手攻击中…", "BOT攻击")
	var player_ready := await _until(func(): return main.board.attack_mode and paused)
	check(player_ready, "BOT实际攻击完毕后交给玩家攻击，并在收起状态暂停")
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == 2,
		"收起期间BOT攻击确实扣除了配置指定的现金数量")
	_check_status(main, "your_attack", "轮到你攻击", "玩家攻击")
	main.drawer_window.pin()
	var targets: Array = main.pipe.applier().affordable_targets(main.my_seat)
	if not need(not targets.is_empty(), "玩家有可点击的真实对手目标"):
		await _dispose(main)
		return
	var victim: CardEntity = main.entities[targets[0]["uids"][0]]
	main._on_attack_clicked(victim)
	main.drawer_window.collapse_now()
	check(not paused, "玩家点下最后一击后收起，等待撕牌的协程不会被冻结")
	var next_round := await _until(func():
		return main.state.round_num == 2 and main._actor == main.my_seat and paused)
	check(next_round, "玩家最后一击在后台收尾、结算并进入下一回合")
	_check_status(main, "your_turn", "轮到你行动", "攻击结束后新回合")
	await _dispose(main)

func _pawn_win_finishes_collapsed() -> void:
	var main := await _boot_drawer()
	_small_local_fixture(main)
	var legend_id := ""
	var pawn_value := 0
	for id in CardDB.all_cards():
		if (CardDB.get_def(id).get("kind") == CardDB.KIND_LEGEND
				and CardDB.pawn_value(id) > pawn_value):
			legend_id = str(id)
			pawn_value = CardDB.pawn_value(id)
	if not need(legend_id != "", "典当终局夹具包含可兑现的传说卡"):
		await _dispose(main)
		return
	var win_cash := int(CardDB.game_rules()["win_cash"])
	var initial_cash := maxi(1, win_cash - pawn_value)
	for i in initial_cash - main.state.resource_count(main.my_seat, CardDB.RES_CASH):
		main.state.add_card(main.my_seat, "cash")
	var legend: Dictionary = main.state.add_card(main.my_seat, legend_id)
	main._respawn_all()
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) < win_cash,
		"典当前现金尚未达到配置胜利线")
	var entity: CardEntity = main.entities[legend["uid"]]
	main._on_dropped_on_pawn([entity])
	check(main.state.winner == main.my_seat and main.phase == main.PHASE_ACTION,
		"真实典当裁决已触发胜利，终局演出仍未结束")
	main.drawer_window.collapse_now()
	check(not paused, "典当冲线到终局提示之间收起，不会冻结终局演出")
	_check_status(main, "success", "做得漂亮！", "典当冲线")
	var finished := await _until(func():
		return main.phase == main.PHASE_OVER and main.game_over_panel != null and paused)
	check(finished, "收起期间典当演出正常进入终局，随后暂停并保留胜利提示")
	check(not main.drawer_window.is_expanded(), "典当终局不强制展开抽屉")
	await _dispose(main)

func _net_opening_purchase_switches(mine: String) -> void:
	var main := await _boot_drawer()
	# 先在原单机局开始行动，验证入座联网新局始终不出现单机邀请。
	var solo_buy: Dictionary = await main._try_buy(0)
	check(solo_buy.get("ok", false), "%s视角：入座前单机局已有实际购买" % mine)
	var room_code := "OPENING" + mine.to_upper()
	var pair := await net_seated_pair(PORT_BASE, 20260918, room_code)
	if not need(pair.size() == 2, "%s视角：首回合购卡夹具双方入座" % mine):
		await _dispose(main)
		return
	var local: NetTransport = pair[0] if pair[0].my_seat == mine else pair[1]
	var room: NetRoom = _srv.rooms[room_code]
	room.state.draw_first = mine
	room.phase.reset_for_round()
	for peer in room.peers():
		_srv._send_one(peer, room.seated_msg(room.seat_of(peer)))
		_srv._send_one(peer, Protocol.phase(room.phase.phase, room.phase.actor))
	check(await net_until(pair, func(): return local.actor() == mine),
		"%s视角：服务器明确当前玩家为首回合先手" % mine)
	main.begin_net_game(local)
	check(await net_until(pair, func():
		return main._actor == mine and not main.board.input_locked),
		"%s视角：新联网牌局等待当前玩家开始行动" % mine)
	main.drawer_window.collapse_now()
	_check_status(main, "your_turn", "轮到你行动", "%s视角联网尚未行动也不显示单机邀请" % mine)
	var handle: DrawerMascot = main.drawer_presentation._handle
	handle.mouse_entered.emit()
	handle.greet()
	check(handle._greeting_label.text == "轮到你行动"
		and not "来摸一局" in handle.tooltip_text, "%s视角联网悬停不出现邀请" % mine)
	handle.mouse_exited.emit()
	main.drawer_window.pin()
	_pump_done = false
	net_pump_until(pair, func(): return _pump_done)
	var purchase: Dictionary = await main._try_buy(0)
	_pump_done = true
	check(purchase.get("ok", false), "%s视角：真实socket购买通过服务器裁决" % mine)
	main.drawer_window.collapse_now()
	_check_status(main, "your_turn", "轮到你行动", "%s视角联网首次购买后" % mine)
	net_stop()
	await _dispose(main)

func _net_hands_over(mine: String) -> void:
	var main := await _boot_drawer()
	var room_code := "DRAWER" + mine.to_upper()
	var pair := await net_seated_pair(PORT_BASE, 20260918, room_code)
	if not need(pair.size() == 2, "%s视角：两个真实WebSocket入座" % mine):
		await _dispose(main)
		return
	var local: NetTransport = pair[0] if pair[0].my_seat == mine else pair[1]
	var remote: NetTransport = pair[1] if pair[0].my_seat == mine else pair[0]
	var room: NetRoom = _srv.rooms[room_code]
	# 固定双方轮换视角的起点，快照和阶段都经真实socket送达客户端。
	room.state.draw_first = remote.my_seat
	room.phase.reset_for_round()
	for peer in room.peers():
		_srv._send_one(peer, room.seated_msg(room.seat_of(peer)))
		_srv._send_one(peer, Protocol.phase(room.phase.phase, room.phase.actor))
	check(await net_until(pair, func():
		return local.state().draw_first == remote.my_seat and local.actor() == remote.my_seat),
		"%s视角：确定的先手快照和阶段通过socket到达" % mine)
	main.begin_net_game(local)
	var ready := await net_until(pair, func():
		return (main._net_table_drawn and main.phase == main.PHASE_ACTION
			and main._actor == remote.my_seat))
	check(ready, "%s视角：远端作为当前行动方进入真实场景" % mine)
	main.drawer_window.collapse_now()
	check(not paused, "%s视角：联网收起仍轮询网络" % mine)
	_check_status(main, "foe_acting", "等待对手行动", "%s视角远端行动" % mine)
	_pump_done = false
	net_pump_until(pair, func(): return _pump_done)
	var result: Dictionary = await remote.submit(Intent.action_done(remote.my_seat))
	_pump_done = true
	check(result.get("ok", false), "%s视角：远端真实socket提交完成行动成功" % mine)
	var handed_over := await net_until(pair, func():
		return (main._actor == main.my_seat and not main.board.input_locked
			and main.drawer_presentation._handle.state() == "foe_done"))
	check(handed_over, "%s视角：收起期间收到远端action_done并交棒，未靠手动设状态" % mine)
	_check_status(main, "foe_done", "等待你行动", "%s视角远端完成" % mine)
	check(not paused and not main.drawer_window.is_expanded(),
		"%s视角：远端完成后保持收起并继续联网" % mine)
	remote.close()
	var offline := await net_until(pair, func():
		return not main._foe_online and main.drawer_presentation._handle.state() == "foe_offline")
	check(offline, "%s视角：收到真实socket断线广播" % mine)
	await process_frame
	_check_status(main, "foe_offline", "对手已断开", "%s视角断线优先" % mine)
	var resumed := net_client(room_code, remote.resume_token)
	check(await net_until([local, resumed], func():
		return (resumed.my_seat == remote.my_seat and main._foe_online
			and main.drawer_presentation._handle.state() == "foe_done")),
		"%s视角：对手用原令牌重连，真实foe_back恢复当前行动完成提示" % mine)
	_check_status(main, "foe_done", "等待你行动", "%s视角重连恢复" % mine)
	resumed.close()
	check(await net_until([local, resumed], func(): return not main._foe_online),
		"%s视角：退出前再次收到对手离线，验证会话清理" % mine)
	main._reset_session_flags()
	check(main._foe_online and main._connection_mascot_state == "idle"
		and main._foe_completed_round == -1,
		"%s视角：会话清理移除对手离线、连接状态和旧回合完成标记" % mine)
	net_stop()
	await _dispose(main)

func _check_priorities_and_restart(main: Node) -> void:
	main._set_connection_mascot_state("connecting")
	_check_status(main, "connecting", "正在连接…", "连接提示优先于行动完成")
	main._set_connection_mascot_state("waiting")
	check(main.drawer_presentation._handle.state() == "waiting", "等待联机提示优先于行动完成")
	main._set_connection_mascot_state("disconnected")
	_check_status(main, "disconnected", "连接已断开", "断线提示优先于行动完成")
	main.state.winner = main.my_seat
	main._refresh_mascot_state()
	check(main.drawer_presentation._handle.state() == "success", "胜利优先于连接与行动状态")
	main.state.winner = main.foe_seat
	main._refresh_mascot_state()
	check(main.drawer_presentation._handle.state() == "defeat", "失败优先于连接与行动状态")
	main._show_game_over()
	main._on_restart()
	await process_frame
	check(main.state.winner == "" and main.phase == main.PHASE_ACTION,
		"收起期间重开进入新局")
	_check_opening_hover(main, "重开恢复邀请，不残留上局行动、断线或胜负")

func _small_local_fixture(main: Node) -> void:
	main.state.set_seed(20260918)
	main.state.market.clear()
	main._clear_market()
	# 双方只留必要资源：BOT仍真正搜索，但不会典当、买卡或生成随机攻击组合。
	for who in [main.my_seat, main.foe_seat]:
		var kept := {}
		for card in main.state.players[who]["cards"].duplicate():
			var id: String = card["def_id"]
			if id not in ["cash", "user"] or kept.has(id):
				main.state.remove_card(who, card["uid"])
			else:
				kept[id] = true
	main._respawn_all()

func _check_opening_hover(main: Node, prefix: String) -> void:
	var mascot: DrawerMascot = main.drawer_presentation._handle
	# 新面板的隐藏会令Viewport重新命中入口；显式移出后再验证无悬停。
	mascot.mouse_exited.emit()
	_check_status(main, "opening", "", prefix + "未悬停")
	check(not mascot._hovered and mascot.tooltip_text.is_empty()
		and mascot._bubble.modulate.a < 0.01, "%s：未悬停没有邀请气泡或工具提示" % prefix)
	var actor_before: String = main._actor
	var round_before: int = main.state.round_num
	mascot.mouse_entered.emit()
	_advance_motion(mascot, 0.3)
	_check_status(main, "opening", "来摸一局？", prefix + "悬停")
	check(mascot._bubble.modulate.a > 0.99, "%s：悬停才显示开场邀请" % prefix)
	mascot.mouse_exited.emit()
	check(mascot._greeting_label.text.is_empty() and mascot._bubble.modulate.a < 0.01,
		"%s：移出立即收起邀请" % prefix)
	check(main._opening_action_pending and main._actor == actor_before
		and main.state.round_num == round_before and not main.drawer_window.is_expanded(),
		"%s：邀请悬停不会购卡、完成行动或展开牌桌" % prefix)

func _check_status(main: Node, state_name: String, text: String, prefix: String) -> void:
	var mascot = main.drawer_presentation._handle
	check(mascot.state() == state_name, "%s：状态为%s（实际%s）" % [prefix, state_name, mascot.state()])
	check(mascot._greeting_label.text == text,
		"%s：入口显示%s（实际%s）" % [prefix, text, mascot._greeting_label.text])

func _boot_drawer() -> Node:
	paused = false
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.sfx.set_muted(true)
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	return main

func _until(condition: Callable, ms := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	return condition.call()

func _advance_motion(mascot: DrawerMascot, seconds: float) -> void:
	var motion: Tween = mascot._motion
	motion.pause()
	motion.custom_step(seconds)

func _dispose(main: Node) -> void:
	paused = false
	main.sfx.set_muted(true)
	main.queue_free()
	for i in 3:
		await process_frame
