# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name NetServer
extends RefCounted

## 专服的**壳**：认连接、搬字节、按房间码分流；游戏裁决交给 NetRoom。
##
## 这个文件里没有一条游戏规则 —— 规则在 engine/，房间逻辑在 net/room.gd。
##
## 为什么从 tools/pvp_server.gd 里拆出来（和当初把 room.gd 拆出来是同一个理由）：
## 那个文件 `extends SceneTree`，而**一个测试自己就是 SceneTree** ——
## 一个进程里装不下两个。于是「真开一个端口，两个 NetTransport 连上去」
## 这条判据就无法直接写进 tests/test_net_socket.gd。
## 拆成 RefCounted 之后：start(port) + 每帧 poll()，谁来 poll 都行 ——
## 无头服务器由 SceneTree 的 _process 调，测试里由测试自己调。
##
## C1 和 C2（远程）的差别只在这一层：换监听地址、加 TLS，
## 房间和引擎一行不用动

## 固定牌序：所有新房间都用这个种子。0 = 每局随机
var fixed_seed := 0
var verbose := false
var port := 0

var rooms: Dictionary = {}           ## room code -> NetRoom
var peer_room: Dictionary = {}       ## peer id -> room code

## peer id -> 最后一次收到他消息的时刻（毫秒）。判活用，见 _sweep_silent
var peer_seen: Dictionary = {}

## 一个连接多久没声音就把他踢下线（判活，见 Protocol.PING）。
##
## 为什么服务器这一侧也要判：座位是**服务器**在记的（NetRoom.occupants）。
## 对手的网络断了（不是进程走了）时那条 socket 停在 STATE_OPEN，
## 服务器不知道他没了 —— 于是
##   - 留下的那一位收不到 foe_left：他看到的是「对手忽然不动了」
##   - 更要紧的是**座位一直被占着**。那位重连回来时如果手里那串令牌没了
##     （进程重启过，令牌只在内存里），走的是 free_seat 那条路 ——
##     而座位没腾空，他拿到的是 room_full：**「无法重连」的一种真实成因**
##
## 30 秒 ≈ NetTransport.SILENT_SEC 的三倍。次序是故意的：客户端先判死
## （10 秒）→ 他去接管开房；服务器这一侧的 30 秒是**兜底**，
## 管的是「客户端那一侧也判不出来」的情形（比如他整个进程被 SIGSTOP 挂住）。
## 反过来（服务器先踢）的话，被踢的人还以为自己在线上
const PEER_SILENT_SEC := 30.0

## 多久扫一次。每帧扫没有意义（判据的粒度是 30 秒），
## 而 rooms/peer_seen 都要遍历
const SWEEP_EVERY_SEC := 1.0

## 这两个的**实际取值**，_sweep_silent 只读这一对（上面两个 const 是默认值）。
## 能改的理由和 NetTransport.silent_sec 一样：判死只能靠墙钟验，
## 而回归套里没有哪条判据等得起 30 秒
var peer_silent_sec := PEER_SILENT_SEC
var sweep_every_sec := SWEEP_EVERY_SEC

var _swept_at := 0

var _peer := WebSocketMultiplayerPeer.new()
var _table_hash := ""

func _init(seed_value := 0, verbose_net := false) -> void:
	fixed_seed = seed_value
	verbose = verbose_net

## 开端口。返回 { ok: true, port } 或 { ok: false, code, reason }
func start(listen_port: int) -> Dictionary:
	# 专服无条件使用内置默认卡表，不能继承桌面端的单机自定义配置。
	CardDB.load_default()
	_table_hash = StateCodec.table_hash()
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	var err := _peer.create_server(listen_port)
	if err != OK:
		return Protocol.err("listen_failed", "开不了端口 %d：%s" % [
			listen_port, error_string(err)])
	port = listen_port
	return { "ok": true, "port": listen_port }

func table_hash() -> String:
	return _table_hash

## 每帧调一次。WebSocketMultiplayerPeer 是轮询式的 —— 不调就什么都不发生。
##
## **排空之后不用再补一次 poll**。查延迟的时候试过（以为 put_packet 只是入队、
## 回话要躺到下一帧），量下来收益 0：服务器只 poll 一次，转发出去的帧对面
## 同一轮就收到了。想加之前先看 net_transport._send 那段 —— 那儿记着当时
## 是怎么把「读得早一帧」误当成「写得早一帧」的
func poll() -> void:
	_peer.poll()
	while _peer.get_available_packet_count() > 0:
		var from := _peer.get_packet_peer()
		var text := _peer.get_packet().get_string_from_utf8()
		_on_text(from, text)
	_sweep_silent()

## 把太久没声音的连接踢下线（判活，见 PEER_SILENT_SEC）。
##
## 「踢」走的是 disconnect_peer，于是 _on_peer_disconnected 照常跑 ——
## 座位腾空、房间留着、给留下的那位发 foe_left。也就是说这里**不重复**
## 任何一行断开逻辑，只是替一条已经死了但没人宣告的 socket 说出那句话
func _sweep_silent() -> void:
	var now := Time.get_ticks_msec()
	if now - _swept_at < int(sweep_every_sec * 1000.0):
		return
	_swept_at = now
	var limit := int(peer_silent_sec * 1000.0)
	# 先收集再断：disconnect_peer 会同步触发 _on_peer_disconnected，
	# 而那里会改 peer_room —— 边遍历边改字典
	var dead: Array = []
	for id in peer_seen:
		if now - int(peer_seen[id]) >= limit:
			dead.append(int(id))
	for id in dead:
		_log("连接 %d 已经 %.0f 秒没声音，按掉线处理" % [id, peer_silent_sec])
		peer_seen.erase(id)
		_peer.disconnect_peer(id)

func stop() -> void:
	_peer.close()

func room_count() -> int:
	return rooms.size()

## 先把一间**打到一半**的房摆好，再等人连进来（主机易位，scenes/main.gd 的 _take_over_host）。
##
## 必须在任何人 join 之前调：_on_join 见房间不存在就现开一间新的（空局），
## 那一位于是拿到一手新牌，而他屏幕上还是上一局的桌子。
##
## 房间码原样用 —— 用户那句「保持密码不变」说的就是这个：
## 对手手里那串码不用改，他重连时填的还是原来那个
func adopt_room(code: String, snap: Dictionary, phase_name: String,
		actor_seat: String, my_seat: String, my_token: String) -> NetRoom:
	var room := NetRoom.new(code, fixed_seed)
	room.adopt(snap, phase_name, actor_seat, my_seat, my_token)
	rooms[code] = room
	_log("接管房间 %s（%s / %s 行动）" % [code, phase_name, actor_seat])
	return room

func _on_peer_connected(id: int) -> void:
	# 判活的起点是**连上那一刻**，不是第一条消息：握了手却一条都不发的连接
	# （客户端卡在启动、或者是个扫端口的）也要能被扫走
	peer_seen[id] = Time.get_ticks_msec()
	_log("连接 %d 进来了，等 join" % id)

func _on_peer_disconnected(id: int) -> void:
	var code := str(peer_room.get(id, ""))
	peer_room.erase(id)
	peer_seen.erase(id)
	if code == "" or not rooms.has(code):
		return
	var room: NetRoom = rooms[code]
	var seat := room.drop_peer(id)
	_log("连接 %d 断开（房间 %s 座位 %s）" % [id, code, seat])
	# 重连令牌已把座位交给新连接，旧连接此时退出不代表任何玩家离线。
	if seat == "":
		return
	# 房间**不删**（scenes/main.gd 的 _offer_reconnect / _on_net_down：没有隐藏信息，重连很便宜）。
	# 只有两边都走了才回收 —— 否则一方刷新页面就把局面弄丢了
	if room.empty():
		rooms.erase(code)
		_log("房间 %s 两边都走了，回收" % code)
		return
	_send_to(room.peers(), Protocol.foe_left())

func _on_text(from: int, text: String) -> void:
	# 判活那一笔记在**最前面**：读不懂的包也证明这条连接活着
	# （同 net_transport._on_text 里那一笔）。记在 match 里的话，
	# 一个版本漂了的客户端会一边被回 rejected 一边被当成掉线踢掉
	peer_seen[from] = Time.get_ticks_msec()
	var dec: Dictionary = Protocol.decode(text)
	if not dec["ok"]:
		_send_one(from, Protocol.rejected(dec["code"], dec["reason"]))
		return
	var msg: Dictionary = dec["msg"]
	var t: String = msg["t"]
	# 客户端只能发白名单里那几种。伪造 seated / applied 要在这里挡住 ——
	# 挡不住的话，一个改过的客户端能给对手发一份假快照
	if not Protocol.is_client_msg(t):
		_send_one(from, Protocol.rejected("not_client_msg", "客户端发不了 %s" % t))
		return
	# 心跳不记日志：每个客户端每 3 秒一条，--verbose-net 的输出会被它刷成
	# 一整屏 ping/pong，而那正是出问题时要去读的地方
	if t != Protocol.PING:
		_log("← %d %s" % [from, Protocol.brief(msg)])
	match t:
		Protocol.PING:
			# 原样回一条。**不看他进没进房间**（不走 _dispatch）：
			# 判活比房间早 —— 一条连上了还没 join 的连接也该量得出往返
			_send_one(from, Protocol.pong(int(msg.get("at", 0))))
		Protocol.JOIN:
			_on_join(from, msg)
		Protocol.INTENT:
			_dispatch(from, func(r): return r.handle_intent(from, msg["intent"]))
		Protocol.DRAG:
			_dispatch(from, func(r): return r.handle_drag(from, msg))
		Protocol.PILES:
			_dispatch(from, func(r): return r.handle_piles(from, msg))
		Protocol.REMATCH:
			_dispatch(from, func(r): return r.handle_rematch(from))

## 把一条消息交给发送方所在的房间处理，然后把房间要发的东西发出去
func _dispatch(from: int, work: Callable) -> void:
	var code := str(peer_room.get(from, ""))
	if code == "" or not rooms.has(code):
		_send_one(from, Protocol.rejected("no_room", "你还没进房间"))
		return
	var room: NetRoom = rooms[code]
	_flush(room, work.call(room))

func _on_join(from: int, msg: Dictionary) -> void:
	# 协议版本先看：形状不一样的两端连上之后，报出来的错会长得像玩法 bug
	if int(msg.get("version", 0)) != Protocol.VERSION:
		_kick(from, Protocol.CLOSE_VERSION,
			"协议版本不一致（服务器 v%d，你 v%d），换同一个版本的客户端" % [
				Protocol.VERSION, int(msg.get("version", 0))])
		return
	# 比较 StateCodec.table_hash() 生成的完整规则指纹，不一致就拒连：
	# 一份旧 cards.json 落在可执行文件旁边，两个人会玩不同价格的同一个游戏，
	# 而且不报错。所以宁可拒连
	var theirs := str(msg.get("table_hash", ""))
	if theirs != "" and theirs != _table_hash:
		_kick(from, Protocol.CLOSE_TABLE_MISMATCH,
			"卡表不一致（服务器 %s，你 %s）：cards.json 不是同一份" % [
				_table_hash.substr(0, 8), theirs.substr(0, 8)])
		return

	var code := str(msg["room"])
	if not Protocol.valid_room(code):
		_kick(from, Protocol.CLOSE_BAD_ROOM, Protocol.room_rule_text())
		return
	# 一条连接只属于一间房。重复入同房幂等；换房要先断开旧连接，不能覆盖反向索引。
	var previous := str(peer_room.get(from, ""))
	if previous != "":
		if previous != code:
			_send_one(from, Protocol.rejected("already_joined", "连接已在房间 %s，请断开后再加入其他房间" % previous))
			return
		var existing: NetRoom = rooms[previous]
		var own_seat := existing.seat_of(from)
		if own_seat == "":
			_send_one(from, Protocol.rejected("no_seat", "此连接的座位已由重连连接接替"))
			return
		_send_one(from, existing.seated_msg(own_seat))
		if existing.started():
			_send_one(from, existing.phase_msg())
		return
	if not rooms.has(code):
		rooms[code] = NetRoom.new(code, fixed_seed)
		_log("现开房间 %s" % code)
	var room: NetRoom = rooms[code]
	var r: Dictionary = room.seat_peer(from, str(msg.get("resume_token", "")))
	if not r["ok"]:
		_kick(from, r["code"], r["reason"])
		return
	var seat: String = r["seat"]
	peer_room[from] = code
	# 「对面又有人了」要在开局判定**之前**问：start_if_ready 之后满座恒真，
	# 分不出这是第一次凑齐还是掉线后补回来。开过局的房间才发 ——
	# 第一次凑齐走的是 fresh 那条路（两边都收全量快照），
	# 再补一条 foe_back 等于告诉先进来的那位「对手回来了」，而他还没走过
	var refilled := room.started() and room.full()
	# 满座才开局。seated 里带快照 —— 先进来的那位收到的是**开局前**的空局面，
	# 所以开局之后要再给他补一份（下面那条 _send_to）
	var fresh := room.start_if_ready()
	_send_one(from, room.seated_msg(seat))
	if room.started() and not room.full():
		# 快照保留双方的牌，不代表对手仍在线。重连/接管后只有自己在场时，
		# 先入座再补当前离线状态；候选连接会等场景接管后回放这条消息。
		_send_one(from, Protocol.foe_left())
	if refilled:
		# 只发给**留下的那一位**：刚进来的这个自己知道自己在哪，
		# 他要的是上面那条 seated（带全量快照）
		for p in room.peers():
			if int(p) != from:
				_send_one(int(p), Protocol.foe_back())
	_log("→ %d 入座 %s（房间 %s%s）" % [from, seat, code,
		"，重连" if r.get("resumed", false) else ""])
	# 进了一间**已经开着局**的房：补一条 phase。
	#
	# seated 里没有阶段（Protocol.SEATED 的载荷是 my_seat/foe_seat/snapshot/token），
	# 而快照里也没有 —— 阶段是 PhaseMachine 的量，不是 GameState 的字段。
	# 于是不补的话这一位的 _phase 是**空串**：他不知道现在该谁动，
	# 场景层那些 `phase != PHASE_ACTION` 的门全部关着，症状是
	# 「连上了、牌也摆好了，但一步都走不了，也不报错」
	#
	# 这条补的是两种人：重连回来的（原先就漏，只是没有自动重连的入口所以碰不上）、
	# 和主机易位之后连进来的那位（scenes/main.gd 的 _take_over_host —— 那间房是 adopt 出来的，
	# 对他来说 fresh 恒为 false，phase 只能从这里来）
	if not fresh and room.started():
		_send_one(from, room.phase_msg())
		# 摞分组回放（见 Protocol.MY_PILES）。**两份都要**，各修一半症状：
		#   my_piles  —— 他自己还没收手的那些摞。摞是纯表现，快照里没有，
		#     不回放的话理牌把它们当散卡摊回资源堆：「我摆了半天的阵型没了」
		#   foe_piles —— 对手那些摞。留下的那一位**不会**重发（他的
		#     _push_piles 比指纹去重，分组没变就一条都不发），于是这一位
		#     的 foe_piles 是空的，_layout_bot_zone 只能按「共几摞」现算成
		#     整行居中 —— 对手明明把组合拖到了桌角
		var mine: Array = room.piles_of(seat)
		if not mine.is_empty():
			_send_one(from, Protocol.my_piles(mine))
		var foe_of_his: Array = room.piles_of(GameState.opponent(seat))
		if not foe_of_his.is_empty():
			_send_one(from, Protocol.foe_piles(Protocol.piles(foe_of_his)))
	if fresh:
		# 开局：两边都要拿到同一份初始快照 + 第一个阶段
		for p in room.peers():
			_send_one(p, room.seated_msg(room.seat_of(p)))
		_send_to(room.peers(), room.phase_msg())
		_log("房间 %s 开局，先手 %s" % [code, room.phase.actor])

## 房间吐出来的 [{to, msg}] 发出去。to = 0 表示广播
func _flush(room: NetRoom, out) -> void:
	if not (out is Array):
		return
	for item in out:
		var to := int((item as Dictionary).get("to", 0))
		var msg: Dictionary = (item as Dictionary)["msg"]
		if to == 0:
			_send_to(room.peers(), msg)
		else:
			_send_one(to, msg)

func _send_to(peers: Array, msg: Dictionary) -> void:
	for p in peers:
		_send_one(int(p), msg)

## 发一条给某个连接。**要先看它还开着没有** ——
## 对一个正在关闭的连接 put_packet 会在引擎层打一条 ERROR，
## 而这个局面完全正常（对手刚断，广播 foe_left 时另一位可能也在关）。
## 不看就发的话，日志里那条 ERROR 会被当成 bug 查
func _send_one(peer: int, msg: Dictionary) -> void:
	var p := _peer.get_peer(peer)
	if p == null or p.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_log("→ %d %s" % [peer, Protocol.brief(msg)])
	_peer.set_target_peer(peer)
	_peer.put_packet(Protocol.encode(msg).to_utf8_buffer())

## 拒连：原因走**关闭帧**。不说原因的话客户端只知道「连不上」，
## 而「卡表不一致」和「端口写错了」要玩家做的事完全不同。
##
## 走关闭帧而不是发一条 closed 消息 —— 这条绕了两版才对：
##   1. put_packet + disconnect_peer：客户端只收到关闭帧，那条消息一字节没上线
##      （_kick 是从 poll() → _on_text 里调的，中间那次 _peer.poll() 是重入，
##      冲不出去；紧跟着的 disconnect_peer 把队列一起扔了）
##   2. 延后两帧再断：本地跑得过，但**判据在变异跑里偶发红**。
##      探针量到根因：客户端晚 poll 一帧，读到的就是「状态=CLOSED 包数=0」——
##      排队的入站包随关闭一起丢。靠帧数留余量的设计只是把概率调小了
## 关闭码是握手的一部分，客户端整段不 poll 也读得到（实测）。
## 拒连原因是一次性的，丢了没有第二次机会 —— 所以它必须走不会丢的那条路。
##
## disconnect_peer 也不用了：close() 之后服务器侧自己会收到
## peer_disconnected（实测 1 次），房间清理照走 _on_peer_disconnected
func _kick(peer: int, code: String, reason: String) -> void:
	var p := _peer.get_peer(peer)
	if p != null:
		# 原因要截：超 123 字节 close() 会静默什么都不做，连接挂着不断
		p.close(int(Protocol.CLOSE_CODES.get(code, 4000)),
			Protocol.clip_reason(reason))
	printerr("拒连 %d：%s（%s）" % [peer, reason, code])

func _log(text: String) -> void:
	if verbose:
		print(text)
