# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var peers: Array = []
var received: Array = [[], []]
var denied: Array = [[], []]
var room: OffWorkRoom

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not await _open_room():
		_close_room()
		finish()
		return
	await _invalid_deliveries()
	await _paused_delivery()
	for index in 2:
		await _manual_delivery(index)
	_close_room()
	if await _open_room():
		await _ordinary_activation()
	_close_room()
	finish()

func _open_room() -> bool:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":2, "work":30}, {"employee":1, "work":30},
		{"strike":1}, {"strike":1}, {"coffee":1}, {"employee":1}, {"union":1}]
	config.rules.bot.enabled = false
	var server := EmbeddedHost.new(83291)
	server.off_work_config = config
	if not need(server.start_random().ok, "真实下班服务器启动"):
		return false
	_srv = server
	received = [[], []]
	denied = [[], []]
	for index in 2:
		var peer := OffWorkTransport.new(server.url(), "DROP")
		peer.balance_hash = JSON.stringify(config.balance_document()).sha256_text()
		peer.frame_received.connect(_on_frame.bind(index))
		peer.rejected.connect(_on_rejected.bind(index))
		peers.append(peer)
		peer.connect_to_server()
	if not need(await net_until(peers, func(): return peers.all(func(peer): return peer.has_dealt_state())),
			"两个真实 WebSocket 客户端收到发牌"):
		return false
	room = server.server.rooms.DROP
	check(peers[0].my_seat != peers[1].my_seat, "两客户端处于不同权威座位")
	check(is_equal_approx(float(room.world.config.rules.strike.flight_seconds), 1.2),
		"测试保留真实 1.2 秒自动飞行配置")
	return true

func _close_room() -> void:
	for peer in peers: peer.close()
	peers.clear()
	room = null
	net_stop()

func _on_frame(frame: Dictionary, index: int) -> void:
	received[index].append(frame.duplicate(true))

func _on_rejected(result: Dictionary, index: int) -> void:
	denied[index].append(result.duplicate(true))

func _owner(index: int) -> int:
	return OffWorkRoom.SEATS.find(peers[index].my_seat)

func _card(owner: int, kind: String) -> int:
	for uid in room.world.cards:
		var card: Dictionary = room.world.cards[uid]
		if int(card.owner) == owner and card.type == kind and card.status == "ready": return int(uid)
	return -1

func _productive_group(owner: int, people: int = 2) -> int:
	for gid in room.world.groups:
		if int(room.world.groups[gid].owner) == owner and room.world.group_people(int(gid)).size() == people \
				and not room.world.group_work(int(gid)).is_empty(): return int(gid)
	return -1

func _reject(index: int, action: Dictionary, label: String) -> void:
	var count: int = denied[index].size()
	var strike_events: int = _event_count(index, "strike")
	var id := int(action.get("id", -1))
	var existed: bool = room.world.cards.has(id)
	var kind := str(room.world.cards[id].type) if existed else ""
	var group := int(room.world.cards[id].group) if existed else -1
	peers[index].send_action(action)
	if not need(await net_until(peers, func(): return denied[index].size() > count), label + "：服务器明确拒绝"):
		return
	check(room.world.cards.has(id) == existed and (not existed or (room.world.cards[id].type == kind \
		and int(room.world.cards[id].group) == group)), label + "：拒绝不消耗或移动所指定的牌")
	check(_event_count(index, "strike") == strike_events, label + "：没有伪造命中事件")

func _invalid_deliveries() -> void:
	for index in 2:
		var owner := _owner(index)
		var strike := _card(owner, "strike")
		var target := _productive_group(1 - owner)
		await _reject(index, {"op":"deliver_strike", "id":_card(1 - owner, "strike"), "group":_productive_group(owner)}, "座位%d冒用对方罢工" % owner)
		await _reject(index, {"op":"deliver_strike", "id":_card(owner, "coffee"), "group":target}, "座位%d用非罢工牌送达" % owner)
		await _reject(index, {"op":"deliver_strike", "id":strike, "group":999999}, "座位%d目标已不存在" % owner)
		await _reject(index, {"op":"deliver_strike", "id":strike, "group":_productive_group(owner)}, "座位%d不能攻击己方" % owner)
		var idle := -1
		for gid in room.world.groups:
			if int(room.world.groups[gid].owner) == 1 - owner and room.world.group_people(int(gid)).size() == 1 \
					and room.world.group_work(int(gid)).is_empty(): idle = int(gid)
		await _reject(index, {"op":"deliver_strike", "id":strike, "group":idle}, "座位%d目标人员并未生产" % owner)
		# Protection is installed through the opponent's real network command.
		var defender: int = 1 - index
		var protected_group := _productive_group(1 - owner, 1)
		var union := _card(1 - owner, "union")
		peers[defender].send_action({"op":"move", "ids":[union], "group":protected_group})
		check(await net_until(peers, func(): return room.world.group_has_union(protected_group)), "对手通过网络安装工会")
		await _reject(index, {"op":"deliver_strike", "id":strike, "group":protected_group}, "座位%d不能绕过工会" % owner)
	check(room.world.pending_strikes.is_empty(), "全部非法送达没有创建飞行任务")

func _paused_delivery() -> void:
	peers[1].send_action({"op":"away", "value":true})
	if not need(await net_until(peers, func(): return peers.all(func(peer): return peer.latest.paused)), "双方收到离桌暂停"):
		return
	var before := var_to_bytes(_world())
	await _reject(0, {"op":"deliver_strike", "id":_card(_owner(0), "strike"), "group":_productive_group(1 - _owner(0))}, "暂停时送达")
	check(var_to_bytes(_world()) == before, "暂停拒绝保持完整世界及 RNG 不变")
	peers[1].send_action({"op":"away", "value":false})
	check(await net_until(peers, func(): return peers.all(func(peer): return not peer.latest.paused)), "双方回桌后继续")

func _manual_delivery(index: int) -> void:
	var owner := _owner(index)
	var strike := _card(owner, "strike")
	var target := _productive_group(1 - owner)
	var people: Array = room.world.group_people(target).duplicate()
	peers[index].send_action({"op":"deliver_strike", "id":strike, "group":target})
	if not need(await net_until(peers, func(): return peers.all(func(peer): return not peer.latest.world.cards.has(strike))),
			"座位%d合法送达在两端确认消费" % owner): return
	for viewer in 2:
		var impacts := _event_frames(viewer, "strike", strike)
		if not need(impacts.size() == 1, "座位%d的送达在视角%d恰好命中一次" % [owner, viewer]): continue
		var frame: Dictionary = impacts[0]
		check(not frame.world.pending_strikes.has(strike) and _event_frames(viewer, "strike_launch", strike).is_empty(),
			"手动送达直接命中，没有第二次起飞或飞行等待")
		check(people.all(func(uid): return frame.world.cards[uid].status == "striking" \
			and is_equal_approx(float(frame.world.cards[uid].remaining), 20.0)),
			"权威确认帧当场开始完整20秒罢工，未提前消耗时长")
		check(people.all(func(uid): return int(frame.world.cards[uid].owner) == (1 if viewer == index else 0)),
			"镜像只旋转所有权，双方命中同一批人员")
	await _reject(index, {"op":"deliver_strike", "id":strike, "group":target}, "重复提交已消费罢工")

func _ordinary_activation() -> void:
	var owner := _owner(0)
	var strike := _card(owner, "strike")
	var target := _productive_group(1 - owner)
	var people: Array = room.world.group_people(target).duplicate()
	peers[0].send_action({"op":"activate", "id":strike, "group":target})
	if not need(await net_until(peers, func(): return not _event_frames(0, "strike_launch", strike).is_empty()),
			"普通点击激活仍产生权威起飞事件"): return
	var launch: Dictionary = _event_frames(0, "strike_launch", strike)[0]
	check(launch.world.pending_strikes.has(strike) and is_equal_approx(float(launch.world.pending_strikes[strike].remaining), 1.2),
		"普通 activate 保留完整1.2秒飞行任务")
	check(people.all(func(uid): return launch.world.cards[uid].status != "striking"), "自动起飞确认帧不提前伤害目标")
	await _reject(0, {"op":"deliver_strike", "id":strike, "group":target}, "飞行中的牌不能改成即时送达")
	if not need(await net_until(peers, func(): return not _event_frames(0, "strike", strike).is_empty()),
			"普通飞行随后按真实时钟命中"): return
	var impact: Dictionary = _event_frames(0, "strike", strike)[0]
	check(float(impact.world.time) >= float(launch.world.time) + 1.2 - 0.000001, "普通命中不早于原定飞行截止时间")
	peers[0].send_action({"op":"resign"})
	check(await net_until(peers, func(): return room.world.winner >= 0), "服务器确认对局结束")
	await _reject(0, {"op":"deliver_strike", "id":_card(owner, "strike"), "group":_productive_group(1 - owner, 1)}, "终局后送达")

func _event_frames(index: int, kind: String, source: int) -> Array:
	return received[index].filter(func(frame): return frame.events.any(func(event): return event.kind == kind and int(event.source) == source))

func _event_count(index: int, kind: String) -> int:
	var count := 0
	for frame in received[index]:
		for event in frame.events:
			if event.kind == kind: count += 1
	return count

func _world() -> Dictionary:
	var result := {"rng":room.world._rng.state}
	for field in OffWorkState.WORLD_FIELDS: result[field] = room.world.get(field)
	return result
