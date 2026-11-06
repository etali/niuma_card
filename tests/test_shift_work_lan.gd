# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var host: Node
var visitor: WorkTransport

func _initialize() -> void:
	_run.call_deferred()

func _switch(mode: int) -> bool:
	host.switch_mode(mode)
	var peers := [visitor] if visitor != null else []
	return await net_until(peers, func(): return not host.switching and host.active == mode, 12000)

func _run() -> void:
	root.size = Vector2i(1600, 900)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for _i in 12: await process_frame
	host = current_scene
	if not need(await _switch(1), "通过原生双班牌桌进入下班"):
		finish()
		return
	var off: Node = host.tables[1]
	var panel: JoinPanel = off.lan.open_panel()
	panel._room_edit.text = "WORK"
	panel._on_host()
	if not need(await net_until([], func(): return panel.has_pending_connection() and panel._net.my_seat != ""), "房主从牌桌入座等待"):
		finish()
		return
	var solo: RefCounted = off.state
	if not need(await _switch(0), "等对手时可从下班切到上班"):
		finish()
		return
	paused = true
	var frozen_solo_time: float = off.state.time
	visitor = WorkTransport.new(off.lan._host.url(), "WORK")
	visitor.balance_hash = JSON.stringify(off.state.config.balance_document()).sha256_text()
	visitor.connect_to_server()
	if not need(await net_until([visitor], func(): return visitor.has_dealt_state()), "前台暂停时后台的下班房主仍可完成握手并发牌"):
		paused = false
		finish()
		return
	check(visitor.latest.paused and off.state == solo and not off.lan.live(), "后台客人入座后等候房主回桌，不替换单机牌局")
	var t: float = visitor.latest.world.time
	await net_pump_for([visitor], 450)
	check(off.state.time == frozen_solo_time and visitor.latest.world.time == t, "等候期间单机和联机两份时间都冻结")
	paused = false
	if not need(await _switch(1), "等待中的房主实际回到下班"):
		finish()
		return
	check(await net_until([visitor], func(): return off.lan.live() and off.state.time > t and visitor.latest.world.time > t), "回桌后接管已握手的连接，双方开始同一局")
	var joined: RefCounted = off.state
	var seat: String = visitor.my_seat
	if not need(await _switch(0), "正在进行的下班联机局切回上班"):
		finish()
		return
	check(await net_until([visitor], func(): return visitor.latest.paused), "对手收到实际换班发出的离桌通知")
	paused = true
	t = visitor.latest.world.time
	await net_pump_for([visitor], 450)
	check(off.state.time == t and off.lan._host.server.rooms.WORK.world.time == t and visitor.latest.world.time == t, "一方离桌时主机、客户端和权威时钟停在同一刻")
	paused = false
	check(await _switch(1), "再从上班招牌回到对局")
	check(await net_until([visitor], func(): return not visitor.latest.paused and visitor.latest.world.time > t and off.state.time > t), "实际换回下班后双方时钟继续")
	check(off.state == joined and visitor.my_seat == seat and visitor.latest.round == 1, "双方仍在原房间、原局、原座位")
	visitor.close()
	off.lan._leave()
	finish()
