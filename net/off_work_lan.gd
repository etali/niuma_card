# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkLan
extends Node

var game: Node
var drawer_presentation: Node
var _host: EmbeddedHost
var _join_panel: JoinPanel
var net: OffWorkTransport
var _solo_state: RefCounted
var _solo_bot: RefCounted
var _solo_replay: RefCounted
var _solo_layout := {}
var _solo_paused := false
var _round := 0
var _away := false
var _paused := false
var _drop_positions := {}
var _last_room := ""
var _last_url := ""
var _token := ""

func bind(table: Node) -> void:
	game = table
	drawer_presentation = table.hud
	process_mode = Node.PROCESS_MODE_ALWAYS
	game.board.network_drop = _drop
	set_process(false)

func live() -> bool:
	return net != null

func net_live() -> bool:
	return live()

func network_live() -> bool:
	return live() or _host != null or (is_instance_valid(_join_panel) and _join_panel.has_pending_connection())

func open_panel() -> JoinPanel:
	if is_instance_valid(_join_panel): return _join_panel
	_join_panel = JoinPanel.new()
	_join_panel.bind(self)
	_join_panel.joined.connect(_joined)
	add_child(_join_panel)
	game.hud._register_external_panel(_join_panel)
	if live():
		var urls := EmbeddedHost.lan_urls(local_host_port()) if _host != null else []
		var address: String = urls[0] if not urls.is_empty() else net.url
		_join_panel.prefill(net.room, "双方在下班牌桌时，联机时钟才会前进。", address)
		var leave := _join_panel._button("退出房间，继续单机", _leave)
		_join_panel._body.add_child(leave)
	elif _last_room != "":
		_join_panel.prefill(_last_room, "可重新加入刚才的房间")
		_join_panel._url_edit.text = _last_url
	return _join_panel

func make_transport(url: String, room: String) -> OffWorkTransport:
	var transport := OffWorkTransport.new(url, room)
	transport.away = _away
	transport.balance_hash = JSON.stringify(game.state.config.balance_document()).sha256_text()
	if _last_url == url and _last_room == room: transport.resume_token = _token
	return transport

func can_start_pending_net_game() -> bool:
	return not _away

func local_host_port() -> int:
	return _host.port if _host != null else 0

func start_local_host(want_port := 0) -> Dictionary:
	if _host == null:
		_host = EmbeddedHost.new()
		_host.off_work_config = game.state.config
		var result := _host.start(want_port if want_port > 0 else EmbeddedHost.DEFAULT_PORT,
			1 if want_port > 0 else EmbeddedHost.PORT_TRIES)
		if not result.ok:
			_host = null
			return result
	set_process(true)
	return {"ok": true, "url": _host.url(), "port": _host.port}

func stop_local_host() -> void:
	if _host != null: _host.stop()
	_host = null
	set_process(live())

func _joined(connection: NetTransport) -> void:
	_join_panel = null
	game.save_shift_session()
	_solo_state = game.state
	_solo_bot = game.bot
	_solo_replay = game.replay
	game.replay = _solo_replay.get_script().new()
	_solo_paused = game.hud._manual_paused
	for key in OffWorkRoom.Session.BOARD_FIELDS:
		_solo_layout[key] = game.board.get(key).duplicate(true)
	net = connection as OffWorkTransport
	_last_url = net.url
	_last_room = net.room
	_token = net.resume_token
	game.bot = null
	game.state = OffWorkRoom.State.new(_solo_state.config)
	game.hud.set_manual_paused(false)
	_bind_connection()
	_accept(net.latest)
	net.resume_scene_events()
	set_process(true)

func _bind_connection() -> void:
	net.frame_received.connect(_accept)
	net.rejected.connect(func(result: Dictionary):
		_drop_positions.clear()
		game._notify(str(result.reason), true))
	net.foe_left.connect(func(): game._notify("对手已断线，牌局暂停，等待重新加入"))
	net.foe_back.connect(func(): game._notify("对手已重新加入"))
	net.rematch_voted.connect(func(_votes: Array): game._notify("双方选择再来一局后重新发牌"))
	net.disconnected.connect(_disconnected)

func _reset_view() -> void:
	game.board.cancel_pointer()
	game.board.reset_view()
	game.table_hands.clear()
	game.effects.clear()
	game.audio.stop_all()
	game.conveyor.reset()
	game.hud.clear_result()
	game.result_layer = null
	game._result_age = 0.0
	game._result_started = false
	game.hud.reset_resign()
	game._selected_tool = -1
	game._positions.clear()
	_drop_positions.clear()

func _accept(frame: Dictionary) -> void:
	if _round != int(frame.round):
		_round = int(frame.round)
		game.replay.reset()
		_reset_view()
	var state: RefCounted = game.state
	for key in OffWorkRoom.Session.STATE_FIELDS: state.set(key, frame.world[key])
	state._rng.state = frame.rng
	state._invalidate_group_index()
	for event in frame.events:
		if event.kind == "net_drop":
			if int(event.owner) == 0 and not event.ids.is_empty():
				var uid := int(event.ids[0])
				if _drop_positions.has(uid):
					game.board.group_overrides[event.group] = _drop_positions[uid]
					game.board._origin_by_gid[event.group] = _drop_positions[uid]
					_drop_positions.erase(uid)
		else: state._events.append(event)
	if _paused != bool(frame.paused):
		_paused = frame.paused
		game._notify("等待双方返回下班牌桌" if _paused else "双方已就位，继续对局")
	game.board.sync_state(state)
	game._update_hud()

func _process(_delta: float) -> void:
	if _host != null: _host.poll()
	if live(): net.poll()

func submit(action: Dictionary) -> void:
	if live(): net.send_action(action)

func _drop(ids: Array, group: int, target: int, at: Vector3) -> bool:
	if not live(): return false
	_drop_positions[ids[0]] = at
	submit({"op": "move", "ids": ids, "group": group, "target": target})
	return true

func rematch() -> void:
	if live(): net.request_rematch()

func set_away(hidden: bool) -> void:
	_away = hidden
	var connection := net
	if connection == null and is_instance_valid(_join_panel):
		connection = _join_panel._net as OffWorkTransport
	if connection != null:
		connection.away = hidden
		if connection.my_seat != "": connection.send_action({"op": "away", "value": hidden})

func _disconnected(code: String, reason: String) -> void:
	if code in ["closed", "no_server"] and _host == null and not net.checkpoint.is_empty() and game.state.winner < 0:
		if _take_over_host(): return
	_leave()
	game._notify("联机中断，已回到单机牌局。%s" % reason, true)

# The remaining player can host at the last acknowledged authoritative instant.
# Keep the unmirrored world, RNG stream, seat and room code so the former host can rejoin.
func _take_over_host() -> bool:
	_host = EmbeddedHost.new()
	_host.off_work_config = game.state.config
	if not _host.start_takeover().ok:
		_host = null
		return false
	var old := net
	var room := OffWorkRoom.new(old.room, 0, _host.off_work_config)
	room.adopt(old.checkpoint, old.my_seat, old.resume_token)
	_host.server.rooms[old.room] = room
	var replacement := make_transport(_host.url(), old.room)
	replacement.resume_token = old.resume_token
	if not replacement.connect_to_server().ok:
		stop_local_host()
		return false
	net = replacement
	_bind_connection()
	net.connected.connect(func(_mine, _foe):
		_accept(net.latest)
		_last_url = net.url
		var addresses := EmbeddedHost.lan_urls(_host.port)
		var address := net.url if addresses.is_empty() else str(addresses[0])
		game._notify("已接管牌局，等待对手连接 %s，房间 %s" % [address, net.room]), CONNECT_ONE_SHOT)
	return true

func _leave() -> void:
	if is_instance_valid(_join_panel): _join_panel._on_cancel()
	if not live(): return
	net.close()
	net = null
	stop_local_host()
	_reset_view()
	game.state = _solo_state
	game.bot = _solo_bot
	game.replay = _solo_replay
	for key in _solo_layout: game.board.set(key, _solo_layout[key])
	_solo_layout.clear()
	game.board.sync_state(game.state)
	game._update_hud()
	game.hud.set_manual_paused(_solo_paused)
	if game.state.winner >= 0:
		game._result_started = true
		game._show_result()
	_round = 0
	_paused = false

func _exit_tree() -> void:
	if live(): net.close()
	if _host != null: _host.stop()
