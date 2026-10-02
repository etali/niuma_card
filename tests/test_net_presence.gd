# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 入座快照不含对手在线状态；重连须另收现有的离场/回来消息。
const PORT_BASE := 48560

class ObservedServer extends NetServer:
	var sent: Array = []
	func _send_to(peers: Array, msg: Dictionary) -> void:
		sent.append({"peers": peers, "msg": msg})

func _replaced_connection_is_not_departure() -> void:
	var server := ObservedServer.new()
	var room := NetRoom.new("REPLACED", 778)
	room.seat_peer(101)
	room.seat_peer(102)
	room.start_if_ready()
	var token: String = room.tokens[room.seat_of(101)]
	room.seat_peer(103, token)
	server.rooms[room.code] = room
	server.peer_room[101] = room.code
	server.peer_room[103] = room.code
	server._on_peer_disconnected(101)
	check(server.sent.is_empty() and room.full(), "旧连接退出不广播对手离线，新连接继续占座")
	server._on_peer_disconnected(103)
	check(server.sent.size() == 1 and not room.full(), "当前占座连接真的退出仍广播离线")

func _initialize() -> void:
	print("=== 入座后的对手在线状态测试 ===")
	CardDB.ensure_loaded()
	_replaced_connection_is_not_departure()
	await _reconnect_while_foe_absent()
	net_stop()
	finish()

func _reconnect_while_foe_absent() -> void:
	if not net_boot(PORT_BASE, 20260918):
		return
	var room_code := "PRESENCE"
	var first := net_client(room_code)
	var first_presence: Array[String] = []
	first.foe_left.connect(func(): first_presence.append("left"))
	first.foe_back.connect(func(): first_presence.append("back"))
	if not need(await net_until([first], func(): return first.my_seat != ""),
			"首次进入空房成功入座"):
		return
	check(first_presence.is_empty(), "尚未开局的空房不会把等待对手误报成对手断开")

	var foe := net_client(room_code)
	var foe_presence: Array[String] = []
	foe.foe_left.connect(func(): foe_presence.append("left"))
	foe.foe_back.connect(func(): foe_presence.append("back"))
	if not need(await net_until([first, foe], func():
		return first.phase() != "" and foe.phase() != ""), "双方首次到齐并收到行动阶段"):
		return
	check(first_presence.is_empty() and foe_presence.is_empty(),
		"首次满房发牌不会额外广播离线或回来")

	var my_seat := first.my_seat
	var my_token := first.resume_token
	var foe_seat := foe.my_seat
	var foe_token := foe.resume_token
	var room: NetRoom = _srv.rooms[room_code]
	foe.close()
	if not need(await net_until([first, foe], func():
		return first_presence == ["left"] and room.free_seat() == foe_seat),
		"对手真实断开后留守方收到离线，对手座位腾空"):
		return

	# 与重连面板一致：先用令牌建立候选连接，入座后再关旧连接。
	# 两边都关闭会回收房间，不能用那条路径伪造可重连的旧局。
	var resumed := net_client(room_code, my_token)
	resumed.defer_scene_events()
	var resumed_events: Array[String] = []
	resumed.connected.connect(func(_mine: String, _foe: String): resumed_events.append("seated"))
	resumed.foe_left.connect(func(): resumed_events.append("left"))
	resumed.foe_back.connect(func(): resumed_events.append("back"))
	if not need(await net_until([first, resumed], func(): return resumed.phase() != ""),
			"持令牌重连到缺少对手的已开局房间"):
		return
	check(resumed.my_seat == my_seat and resumed.has_dealt_state(),
		"重连坐回原座并保留双方牌面，未另开新局")
	check(resumed_events == ["seated"], "候选连接先完成入座，离线状态等待场景接管")
	resumed.resume_scene_events()
	check(resumed_events == ["seated", "left"],
		"场景接管后恰好回放一次当前对手离线，且在入座之后")
	resumed.resume_scene_events()
	check(resumed_events == ["seated", "left"], "重复接管不会重复回放离线状态")

	first.close()
	if not need(await net_until([first, resumed], func():
		return not _srv.peer_room.has(first.peer_id)), "新连接就绪后旧连接完成退出"):
		return
	resumed_events.clear()
	var returned := net_client(room_code, foe_token)
	var returned_presence: Array[String] = []
	returned.foe_left.connect(func(): returned_presence.append("left"))
	returned.foe_back.connect(func(): returned_presence.append("back"))
	if not need(await net_until([resumed, returned], func():
		return returned.phase() != "" and resumed_events.has("back")),
		"对手持令牌回来后，留守的新连接收到回来消息"):
		return
	check(returned.my_seat == foe_seat and room.full(), "对手回到原座，房间恢复满座")
	check(resumed_events == ["back"], "留守方只收到一次回来，不再误报离线")
	check(returned_presence.is_empty(), "回来的那方不接收只属于留守者的回来消息")
	first.close()
	foe.close()
	resumed.close()
	returned.close()
