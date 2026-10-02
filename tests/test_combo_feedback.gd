# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 结算反馈必须跟随实际裁决，状态提示要至少跨帧可见，不能只验节点被创建。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 组合结算反馈与空心光环 ===")
	_test_hollow_glow()
	await _test_legacy_protocol()
	var main: Node = await boot_main()
	main.set_foe_remote(true)
	main.set_process(false)
	main.sfx.set_muted(true)
	await _test_broken_group(main)
	await _test_payment_refused(main)
	await _test_spare_loss(main)
	await _test_network_result(main, false)
	await _test_network_result(main, true)
	await _test_buff_activity(main)
	await _test_defense_and_fission(main)
	await _test_local_defense_shields(main)
	_test_defense_reports()
	main.queue_free()
	await process_frame
	finish()

func _test_hollow_glow() -> void:
	var texture := CardEntity._make_buff_glow_fallback()
	var image := texture.get_image()
	check(image.get_pixel(image.get_width() / 2, image.get_height() / 2).a == 0.0,
		"光环中心完全透明，卡面不被整片染色")
	check(image.get_pixel(0, 0).a == 0.0, "光环圆角之外透明")
	var max_alpha := 0.0
	for x in image.get_width() / 2:
		max_alpha = maxf(max_alpha, image.get_pixel(x, image.get_height() / 2).a)
	check(max_alpha > 0.8, "空心光环保留清晰轮廓")

func _reset(main: Node) -> void:
	main._clear_table()
	await process_frame
	for owner in [main.my_seat, main.foe_seat]:
		main.state.players[owner]["cards"] = []
	main.state.combos.clear()
	main.state.log.clear()
	main.state.market.clear()
	main.state.winner = ""
	main.state.draw_first = main.my_seat
	main.phase = main.PHASE_SETTLING
	main.pipe = LocalTransport.new(IntentApply.new(main.state))
	main.layout.end_arrivals()
	main.layout.begin_arrivals()

func _card(main: Node, id: String, owner := "") -> CardEntity:
	if owner == "":
		owner = main.my_seat
	var data: Dictionary = main.state.add_card(owner, id)
	var entity: CardEntity = main._spawn_entity(data, Vector3(-3.0 + main.entities.size() * 0.2, 0.05, 3.0), owner == main.my_seat)
	entity.freeze = true
	return entity

func _pile(main: Node, core_id: String, extra := 0) -> Array:
	var core := _card(main, core_id)
	var cards: Array = [core]
	var uids: Array = [core.uid]
	var def := CardDB.get_def(core_id)
	for i in int(def["recipe_n"]) + extra:
		var card := _card(main, str(def["recipe_res"]))
		cards.append(card)
		uids.append(card.uid)
	check(main.state.create_combo(main.my_seat, uids)["ok"], "反馈测试组合成立：" + core_id)
	return cards

func _remove(main: Node, card: CardEntity) -> void:
	main.state.remove_card(main.my_seat, card.uid)
	main.entities.erase(card.uid)
	main.board.unregister_card(card)
	card.queue_free()
	await process_frame

func _play(main: Node, done: Array) -> void:
	await main._resolve_combo_visual(0)
	done[0] = true

func _wait_stamp(main: Node, core: CardEntity, done: Array) -> bool:
	var elapsed := 0.0
	while elapsed < 4.0 and not done[0]:
		if core._void_on and core._void_stamp != null and core._void_stamp.visible:
			return true
		await physics_frame
		elapsed += 1.0 / 60.0
	return false

func _finish_play(done: Array) -> void:
	var elapsed := 0.0
	while not done[0] and elapsed < 6.0:
		await physics_frame
		elapsed += 1.0 / 60.0
	check(done[0], "结算演出完成")

func _assert_stamp_lifecycle(main: Node, cards: Array, reason: String) -> void:
	var core: CardEntity = cards[0]
	var done := [false]
	_play(main, done)
	var visible := await _wait_stamp(main, core, done)
	check(visible, "作废核心盖章跨帧可见：" + reason)
	if visible:
		var count := 0
		for e in main.entities.values():
			if e._void_on:
				count += 1
		check(count == 1, "整组仅核心有一个作废章")
		check(core._void_label != null and core._void_label.text == "作废", "空章框有可读的作废文字")
		check(core.label.text == CardDB.card_name(core.def_id), "作废状态保留核心卡名")
		await create_timer(0.25).timeout
		check(core._void_stamp.visible, "盖章保持足够时间阅读，不在同帧清除")
		check(main.lbl_msg.text.contains(reason), "结果提示使用实际作废原因")
	await _finish_play(done)
	check(not core._void_on and not core._void_stamp.visible, "结果停顿结束后清除盖章")
	check(not core.highlighted, "作废高亮在演出结束后恢复")

func _test_broken_group(main: Node) -> void:
	await _reset(main)
	var cards := _pile(main, "yunketang")
	var last: CardEntity = cards.pop_back()
	await _remove(main, last)
	await _assert_stamp_lifecycle(main, cards, "已被拆散")
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == 0, "被拆散组合不产出")

func _test_payment_refused(main: Node) -> void:
	await _reset(main)
	var cards := _pile(main, "chunwan")
	var cash_before: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	await _assert_stamp_lifecycle(main, cards, "会让资金归零")
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash_before, "拒付不扣现金")
	check(main.state.resource_count(main.my_seat, CardDB.RES_USER) == 0, "拒付不产用户")
	for card in cards:
		check(is_instance_valid(card) and main.entities.has(card.uid), "拒付原有卡实体完整保留")
	var particles := 0
	for child in main.get_children():
		if child is CPUParticles3D:
			particles += 1
	check(particles == 0, "拒付不播放成功粒子")

func _test_spare_loss(main: Node) -> void:
	await _reset(main)
	var cards := _pile(main, "yunketang", 1)
	var spare: CardEntity = cards.pop_back()
	await _remove(main, spare)
	check(main.state.combo_intact(main.my_seat, main.state.combos[0]), "丢富余牌后配方仍成立")
	await main._resolve_combo_visual(0)
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == int(CardDB.get_def("yunketang")["output_n"]), "丢富余牌仍正常产出")
	check(cards[0]._void_stamp == null, "丢富余牌不误盖作废章")
	check(not main.lbl_msg.text.contains("作废"), "丢富余牌不误报作废消息")
	await create_timer(0.2).timeout

func _test_network_result(main: Node, succeeds: bool) -> void:
	await _reset(main)
	var cards := _pile(main, "chunwan")
	var spare := _card(main, "cash")
	var server := GameState.new()
	StateCodec.restore(server, StateCodec.snapshot(main.state))
	if not succeeds:
		# 客户端此刻仍以为多一块能付，服务器已知那块消失：必须服从回执。
		server.remove_card(main.my_seat, spare.uid)
	var applied := IntentApply.new(server).apply(Intent.produce(0))
	check(applied.get("resolution", {}).get("resolved", false) == succeeds, "实际裁决返回成功/拒付状态")
	var decoded := Protocol.decode(Protocol.encode(Protocol.applied(applied, 1, StateCodec.snapshot(server))))
	check(decoded["ok"], "结算回执经过真实协议编解码")
	var received: Dictionary = decoded["msg"]["result"]["resolution"]
	if succeeds:
		check(not received["paid_uids"].is_empty(), "服务器成功回执带实付名单")
		for uid in received["paid_uids"]:
			check(typeof(uid) == TYPE_INT, "网络实付UID恢复为int，能查到原实体")
	var net := NetTransport.new()
	net._state = main.state
	net._applier = IntentApply.new(main.state)
	net._inbox.append(decoded["msg"])
	net.applied.connect(main._on_intent_applied)
	var at_receipt := [0]
	net.applied.connect(func(_result: Dictionary):
		for uid in received["paid_uids"]:
			if main.entities.has(uid):
				at_receipt[0] += 1)
	main.pipe = net
	if succeeds:
		var done := [false]
		_play(main, done)
		var elapsed := 0.0
		while not net._inbox.is_empty() and elapsed < 4.0:
			await physics_frame
			elapsed += 1.0 / 60.0
		check(at_receipt[0] == received["paid_uids"].size(), "网络快照落地/广播后仍保留待吸走现金实体")
		await create_timer(0.08).timeout
		check(is_instance_valid(cards[1]) and cards[1].has_meta("dest_pos"), "实付现金进入吸入补间，未被提前差分撕掉")
		var users_on_table := 0
		for card in main.entities.values():
			if card.def_id == "user":
				users_on_table += 1
		check(users_on_table == 0 and not done[0], "付款动画未完时不提前生成用户产出")
		await _finish_play(done)
		check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == 1, "服务器实付后仅余一块现金")
		for uid in received["paid_uids"]:
			check(not main.entities.has(uid), "实付的旧现金实体按服务器名单移除")
		check(main.state.resource_count(main.my_seat, CardDB.RES_USER) > 0, "网络成功结算产出到账")
	else:
		await _assert_stamp_lifecycle(main, cards, "会让资金归零")
		for card in cards:
			check(is_instance_valid(card) and main.entities.has(card.uid), "服务器拒付没有按本地预测吸走配方")
	main.pipe = LocalTransport.new(IntentApply.new(main.state))
	await create_timer(0.2).timeout

func _test_buff_activity(main: Node) -> void:
	await _reset(main)
	var core := _card(main, "yunketang")
	var buff := _card(main, "yinqing996")
	var group: Dictionary = main.board.make_group([core, buff], false)
	main.board.groups.append(group)
	main.board.refresh_group(group)
	main._refresh_shields()
	check(not buff._glow_on, "配方未满时没有生效光环")
	check(core.effect_mult() > 1, "配方未满仍保留卡面预期倍率")
	for i in int(CardDB.get_def("yunketang")["recipe_n"]):
		group["cards"].append(_card(main, "user"))
	main.board.refresh_group(group)
	main._refresh_shields()
	check(buff._glow_on and buff._glow.visible, "有效产出组合里的996光环可见")
	var wrong := _card(main, "resou")
	group["cards"].append(wrong)
	main._refresh_shields()
	check(not wrong._glow_on, "攻击翻倍Buff放在生产组不亮")
	main.board._detach_from_group(buff)
	main._refresh_shields()
	check(not buff._glow_on and not buff._glow.visible, "Buff离组后光环关闭")
	await _reset(main)
	var foe_cards: Array = []
	var foe_uids: Array = []
	for id in ["yunketang", "yinqing996"]:
		var c := _card(main, id, main.foe_seat)
		foe_cards.append(c)
		foe_uids.append(c.uid)
	for i in int(CardDB.get_def("yunketang")["recipe_n"]):
		foe_uids.append(_card(main, "user", main.foe_seat).uid)
	check(main.state.create_combo(main.foe_seat, foe_uids)["ok"], "对手有效组合成立")
	main._refresh_shields()
	check(foe_cards[1]._glow_on, "对手通过权威组合也显示有效Buff光环")

func _test_defense_and_fission(main: Node) -> void:
	await _reset(main)
	var core := _card(main, "yunketang")
	var shield := _card(main, "tuisong")
	var uids: Array = [core.uid, shield.uid]
	for i in int(CardDB.get_def("yunketang")["recipe_n"]):
		uids.append(_card(main, "user").uid)
	check(main.state.create_combo(main.my_seat, uids)["ok"], "防御组合成立")
	main._refresh_shields()
	check(shield._glow_on, "防御Buff入组当回合立即亮起生效光环")
	main.state.round_num += 1
	main._refresh_shields()
	check(shield._glow_on, "防御Buff跨回合仍保护有效配方")
	await _reset(main)
	core = _card(main, "yunketang")
	var fission := _card(main, "liebian")
	shield = _card(main, "tuisong")
	var user := _card(main, "user")
	uids = [core.uid, fission.uid, shield.uid, user.uid]
	check(main.state.create_combo(main.my_seat, uids)["ok"], "裂变补满组合成立")
	main._refresh_shields()
	check(fission._glow_on, "裂变实际补足缺少配方时发光")
	check(shield._glow_on and user._shield_on, "防御入组即保护裂变补满组的用户")
	main.state.combos.clear()
	for i in int(CardDB.get_def("yunketang")["recipe_n"]) - 1:
		uids.append(_card(main, "user").uid)
	check(main.state.create_combo(main.my_seat, uids)["ok"], "补足真实用户后重新建组")
	main._refresh_shields()
	check(not fission._glow_on, "用户本就足够时裂变不误标生效")

## 沿用 socket 回归的裸连接/关闭帧方式，确认旧协议在进入房间之前被拒绝。
func _test_legacy_protocol() -> void:
	check(Protocol.VERSION >= 7, "权威结算回执要求协议v7及以上")
	if not net_boot(47940):
		return
	var raw := WebSocketPeer.new()
	raw.connect_to_url("ws://127.0.0.1:%d" % _port)
	var opened := await net_until([], func():
		raw.poll()
		return raw.get_ready_state() == WebSocketPeer.STATE_OPEN)
	if not need(opened, "旧协议裸socket连接建立"):
		net_stop()
		return
	var old_join := Protocol.join("LEGACY", StateCodec.table_hash())
	old_join["version"] = 6
	raw.send_text(Protocol.encode(old_join))
	var closed := await net_until([], func():
		raw.poll()
		while raw.get_available_packet_count() > 0:
			raw.get_packet()
		return raw.get_ready_state() == WebSocketPeer.STATE_CLOSED)
	check(closed and Protocol.close_code_name(raw.get_close_code()) == Protocol.CLOSE_VERSION,
		"旧v6协议在握手被拒绝，不进入缺少resolution的对局")
	check(_srv.room_count() == 0, "旧协议拒连未创建游戏房间")
	net_stop()

## 玩家桌面摞必须检查真实生效条件；只测 state.combos 会漏掉桌面预览分支。
func _test_local_defense_shields(main: Node) -> void:
	for swapped in [false, true]:
		await _reset(main)
		main.set_seats(GameState.AI if swapped else GameState.PLAYER,
			GameState.PLAYER if swapped else GameState.AI)
		main.state.round_num = 4
		var cards: Array = []
		var uids: Array = []
		for id in ["yunketang", "tuisong", "user", "user", "user", "user"]:
			var card := _card(main, id)
			cards.append(card)
			uids.append(card.uid)
		var group: Dictionary = main.board.make_group(cards.duplicate(), false)
		main.board.groups.append(group)
		main._refresh_shields()
		check(cards[2]._shield_on and cards[1]._glow_on, "未提交的新防御摞入组立即显示盾牌与光环（换座=%s）" % swapped)
		main.board._detach_from_group(cards[1])
		main._refresh_shields()
		check(not cards[2]._shield_on and not cards[1]._glow_on,
			"未提交防御Buff离组立即撤销原组盾牌与光环")
		group["cards"].append(cards[1])
		main._refresh_shields()
		check(cards[2]._shield_on and cards[1]._glow_on,
			"同回合重新放入有效组立即恢复保护")
		check(main.state.create_combo(main.my_seat, uids)["ok"], "本地防御摞提交成功")
		main._refresh_shields()
		check(cards[2]._shield_on and cards[1]._glow_on,
			"首次编组当回合，用户盾牌与防御光环立即开启")
		main.state.round_num += 1
		main._refresh_shields()
		check(cards[2]._shield_on and cards[3]._shield_on and cards[4]._shield_on,
			"跨回合后，三张配方用户仍显示盾牌")
		check(not cards[5]._shield_on, "第四张富余用户不显示盾牌")
		check(cards[1]._glow_on, "有效防御光环与用户盾牌同时开启")
		# 已移除的牌尚在动画中，不能继续拿它凑配方或为它显示盾牌。
		main.state.remove_card(main.my_seat, cards[5].uid)
		main.state.remove_card(main.my_seat, cards[4].uid)
		main._refresh_shields()
		check(not cards[2]._shield_on and not cards[4]._shield_on and not cards[1]._glow_on,
			"配方被拆散后，存活牌与待消失实体都不误亮盾牌")

	await _reset(main)
	main.set_seats(GameState.PLAYER, GameState.AI)
	main.state.round_num = 4
	var cards: Array = []
	var uids: Array = []
	# 对应录像最后一组：刷不停、裂变、刚买的推送、唯一用户。
	for id in ["shuabuting", "liebian", "tuisong", "user"]:
		var card := _card(main, id)
		cards.append(card)
		uids.append(card.uid)
	var group: Dictionary = main.board.make_group(cards.duplicate(), false)
	main.board.groups.append(group)
	check(main.state.create_combo(main.my_seat, uids)["ok"], "录像中的裂变防御组合成立")
	main._refresh_shields()
	check(cards[3]._shield_on and cards[2]._glow_on,
		"入组当回合：推送加裂变立即显示用户盾牌")
	main.state.round_num += 1
	main._refresh_shields()
	check(cards[3]._shield_on and cards[2]._glow_on,
		"下一回合：推送弹窗仍保护裂变补满组的唯一用户")
	for i in 6:
		var user := _card(main, "user")
		group["cards"].append(user)
		uids.append(user.uid)
	main.state.combos.clear()
	check(main.state.create_combo(main.my_seat, uids)["ok"], "补足七张真实用户后组合成立")
	main._refresh_shields()
	check(cards[3]._shield_on and cards[2]._glow_on and not cards[1]._glow_on,
		"用户数量足够时按完整配方持续保护")

func _test_defense_reports() -> void:
	for fission in [false, true]:
		for next_round in [false, true]:
			var s := GameState.new()
			s.players = {GameState.PLAYER: {"cards": []}, GameState.AI: {"cards": []}}
			var ids: Array = ["shuabuting", "tuisong", "liebian", "user"] if fission else \
				["yunketang", "tuisong", "user", "user", "user"]
			var uids: Array = []
			for id in ids:
				uids.append(s.add_card(GameState.PLAYER, id)["uid"])
			check(s.create_combo(GameState.PLAYER, uids)["ok"], "防御战报测试组合成立")
			if next_round:
				s.round_num += 1
			s.log.clear()
			Settle._resolve_combo(s, s.combos[0])
			var reported := false
			for entry in s.log:
				if GameState.entry_text(entry).contains("受防御 Buff"):
					reported = true
			check(reported,
				"入组当回合及之后均报告实际生效的保护（跨回合=%s，裂变=%s）" % [next_round, fission])
