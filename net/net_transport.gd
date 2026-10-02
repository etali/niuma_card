# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name NetTransport
extends Transport

## 联网传输：通过 WebSocket 把意图交给 NetServer / NetRoom 裁决。
##
## 和 LocalTransport 换着用，场景层一行不用改：这是 Transport 那层抽象存在的
## 全部理由（见 engine/transport.gd 文件头「submit 一定是 coroutine」那段）。
##
## 客户端侧**没有裁决器**。applier() / state() 在这里是「服务器说了算的那份的副本」：
##   - state 有：客户端要画牌，必须有一份状态
##   - applier 没有：它是权威，客户端持有一份就等于在本地又判了一次，
##     两处判定必然某天分叉（正是 README.md §「3. 文件目录结构」要避免的）
## 所以 applier() 返回一个**只读用途**的裁决器：pools() / production_count()
## 这些查询方法要用，但它的 apply() 不该被客户端调 —— submit 走网络

signal connected(my_seat: String, foe_seat: String)
signal disconnected(code: String, reason: String)
signal recorded_step(result: Dictionary, snapshot: Dictionary)

signal foe_left()
## 对手回来了（见 Protocol.FOE_BACK）。和 foe_left 成对 ——
## 只有 foe_left 的话，掉线提示挂上去就摘不下来了
signal foe_back()
signal phase_changed(phase: String, actor: String)
signal foe_drag(msg: Dictionary)
## 对手的摞分组变了（见 Protocol.PILES）。和 foe_drag 分开：
## 拖拽是「手里正拿着」的那几十帧，分组是松手之后的**归宿**
signal foe_piles(msg: Dictionary)
## 服务器回放**我自己**上一次声明的摞（见 Protocol.MY_PILES）。
## 只在重连进一间已经开着局的房时来一条 —— 平时我这边的摞是我自己的实况，
## 服务器没有话要说
signal my_piles(msg: Dictionary)
## 再来一局的投票进度变了。votes 是座位名单，收方拿自己的 my_seat 去比
signal rematch_voted(votes: Array)
## 新局开始了（双方都点了）。座位**可能变**（先手轮换），所以带着一起发 ——
## 收方要按新座位重摆桌子，不能沿用上一局那对
signal rematch_started(my_seat: String, foe_seat: String)

## 一次往返最多等多久。超时不是「网络慢」的兜底 ——
## 卡在 await 上的场景层是**按钮全灰、什么都点不了**，
## 那比报一句「服务器没回话」糟糕得多
const TIMEOUT_SEC := 8.0

var socket := WebSocketPeer.new()
var my_seat := ""
var foe_seat := ""
var room := ""
var url := ""
## 重连令牌：服务器在 seated 里给的，断线重连时带回去证明「我是原来那个座位」
var resume_token := ""

var _state := GameState.new()
var _applier: IntentApply
var _phase := ""
var _actor := ""
## 独立于动画用 state；每份都由服务端一次事务原子生成。
var _recovery: Dictionary = {}
## 在线连接恢复后，同批其余 APPLIED/PHASE 仍可能在 socket 路上。
## 它们已包含在检查点里，不能再入展示队列或覆盖阶段。
var _restored_seq := -1
## 候选连接仍属于等待面板时，牌局事件先留在这里；主场景接管后再派发。
## 握手、阶段与心跳继续处理，不能因玩家还在原局操作而断线。
var _defer_scene_events := false
var _scene_events: Array[Dictionary] = []
## 已发出但还没等到回音的那条。一次只允许一条在飞 ——
## 玩家的输入本来就是串行的（点一下等一下），允许并发只会让
## 「哪条 applied 对应哪条 submit」变成一个要靠 seq 猜的问题
var _pending := false
var _last_result: Dictionary = {}
var _closed := false
## 拖拽帧序号。UDP 那套「丢弃过期包」的做法在 WebSocket 上也要有：
## TCP 保序但**不保时效**，卡顿之后会一次到一批，只该画最后那一帧
var _drag_seq := 0

func _init(server_url := "", room_code := "") -> void:
	_remote = true          # 见 Transport 文件头：submit 要真的挂起
	url = server_url
	room = room_code
	_applier = IntentApply.new(_state)

# ---------- 连接 ----------

func connect_to_server() -> Dictionary:
	var err := socket.connect_to_url(url)
	if err != OK:
		return Protocol.err("connect_failed", "连不上 %s：%s" % [url, error_string(err)])
	return { "ok": true }

## 每帧调（场景层的 _process 里）。
##
## 为什么不用信号驱动：WebSocketPeer 是**轮询式**的，没有「收到包」信号。
## 这个方法就是它的心跳 —— 不调就什么都不会发生（连不上、收不到、也不报错）
func poll() -> void:
	socket.poll()
	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			ever_open = true
			if not _sent_join:
				_sent_join = true
				_seen_at = Time.get_ticks_msec()   # 判活的起点是**握手那一刻**
				_send(Protocol.join(room, StateCodec.table_hash(), resume_token))
			while socket.get_available_packet_count() > 0:
				_on_packet(socket.get_packet())
			_beat()
		WebSocketPeer.STATE_CLOSED:
			if not _closed:
				_closed = true
				_emit_closed()

var _sent_join := false

# ---------- 判活（心跳）----------

## 隔多久发一条 ping。3 秒是「不吵」和「发现得够快」之间的折中：
## 一局棋里每 3 秒一条 20 字节的包可以忽略，而最坏情况下
## SILENT_SEC 那个上限也只会晚一个间隔
const PING_EVERY_SEC := 3.0

## 多久没有任何回音就认为这条连接死了。
##
## 取值要**明显大于** PING_EVERY_SEC 的几倍：一次 GC 卡顿、一次切后台、
## 手机热点抖一下都可能吞掉一两个来回，为此判死等于自己造断线。
## 10 秒 ≈ 三个间隔都没回音 —— 那不是抖动，那是对端没了。
##
## 也要**明显小于** NetServer.PEER_SILENT_SEC（30 秒）：两头都在判对方的活，
## 客户端先判死才是对的次序 —— 他判死之后会接管开房，
## 而那间新房要能立刻接受对手连进来。反过来（服务器先踢）的话，
## 留下那位的座位在他自己还没意识到断线时就被腾空了
const SILENT_SEC := 10.0

## 这两个的**实际取值**，判活只读这一对。上面那两个 const 是默认值。
##
## 为什么要能改：判死这件事本身只能靠**墙钟**验（它的定义就是「过了多少秒
## 还没有回音」），而回归套里没有哪条判据等得起 10 秒。
## 测试把它调到 0.4 秒，量的是同一段代码、同一条路径 ——
## 换成「注入一个假时钟」的话，被测的就不再是真跑那条路了。
##
## 不用 const + 测试改源码的办法：那等于每次跑变异都要改回来
var silent_sec := SILENT_SEC
var ping_every_sec := PING_EVERY_SEC

## 最后一次**收到任何东西**的时刻（毫秒）。0 = 还没握手
var _seen_at := 0
var _ping_at := 0

## 心跳一步：该发就发，太久没回音就当断线处理。
##
## 「太久没回音」为什么必须由这一层判 —— TCP 保序但**不保活**。
## 对端进程被 kill 时操作系统会替它关 fd（对手 0.00 秒就收到 no_server，
## 实测见 Protocol.PING 那段），可**网络断了 / 机器睡了**的时候
## 一个字节都不会来：socket 停在 STATE_OPEN，get_close_code() 没有值，
## 6 秒、6 分钟都一样。那一刻双方各自停在「对手忽然不动了」，
## 而接管那条路（main._can_take_over_host）挂在 disconnected 上 ——
## 不自己判活的话它永远等不到那个码
func _beat() -> void:
	var now := Time.get_ticks_msec()
	if _seen_at != 0 and now - _seen_at >= int(silent_sec * 1000.0):
		# 走 close() + 自己发那条码，**不等 socket 变 CLOSED**：
		# 它可能永远不变（对端网络断了的话关闭帧发不出去也收不到）。
		# 码借 no_server 那个而不是新造一个：接管白名单
		# （main.TAKEOVER_CODES）认的就是它，而这两件事对玩家是同一件 ——
		# 「对面那个服务器没了」
		_closed = true
		close()
		disconnected.emit("no_server",
			"服务器 %.0f 秒没有回音（%s）" % [silent_sec, url])
		return
	if now - _ping_at >= int(ping_every_sec * 1000.0):
		_ping_at = now
		_send(Protocol.ping(now))

## 上一条 ping 的往返延迟（毫秒）。-1 = 还没量到。只给 HUD/日志看，不进判定
var rtt_ms := -1

## 这条连接**曾经**握手成功过吗。
##
## 为什么需要它：no_server 那个码（get_close_code() == -1）盖了两件事 ——
## 「压根没连上」和「连上了但对端进程被 kill / 网线被拔」。关闭帧都没有，
## 两者在 socket 层长得一模一样。而对主机易位来说这两件事是反的：
##   连上过再断  → 那一局是真的，接管救得回来
##   从没连上    → 地址/端口打错了，接管等于「自己开一间房自己坐着」，
##                 对手照着他手上那个错地址永远也连不过来
##
## 判 STATE_OPEN 而不是「收到过 seated」：seated 是**服务器**给的，
## 而这里要答的是「网线通没通」。测试里常直接喂 _on_text(seated_msg)
## 造局面（tests/test_rematch.gd 的 `_t5_scene_keeps_connection()`），那种连接一次都没 OPEN 过 ——
## 拿 seated 当判据的话它们会被误判成「真连过」
var ever_open := false

## 断线时把「为什么」说清楚。三种要分开，因为玩家要做的事不一样：
##   - no_server：根本没连上（对面没开）→ 去把服务器开起来 / 看端口
##   - 认得出的拒连码 → 原因在关闭帧里，照着办（换 cards.json、换版本、换房间码）
##   - 认不出 → 只能报个码，那是正常关闭或网络断
##
## 原因取关闭帧里的那句而不是等一条 closed 消息：数据帧会随关闭一起丢
## （见 Protocol.CLOSE_CODES 上面那段实测）
func _emit_closed() -> void:
	var num := socket.get_close_code()
	if num == -1:
		disconnected.emit("no_server", "连不上服务器（%s）" % url)
		return
	var name := Protocol.close_code_name(num)
	if name == "":
		disconnected.emit("closed", "连接已断开（code %d）" % num)
		return
	var why := socket.get_close_reason()
	disconnected.emit(name, why if why != "" else "被拒：%s" % name)

## 主动断开。**CONNECTING 也要关** —— 握手途中放弃（入座超时、玩家点了「单机继续」）
## 时 socket 还没 OPEN，只判 OPEN 的话那条连接会**一直挂在后台**：
## 它稍后连上、发出 join、占掉房间的一个座位，而这一侧已经没人在 poll 它了。
## 症状是「点了取消再重连，服务器说房间满了」
func close() -> void:
	var st := socket.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN or st == WebSocketPeer.STATE_CONNECTING:
		socket.close()

# ---------- Transport 接口 ----------

func applier() -> IntentApply:
	return _applier

func state() -> GameState:
	return _state

## 入座消息也可能是空房。只有双方都在快照里，才有可以切换过去的对局。
func has_dealt_state() -> bool:
	return _state != null and _state.players.has(my_seat) and _state.players.has(foe_seat)

func defer_scene_events() -> void:
	_defer_scene_events = true

func resume_scene_events() -> void:
	_defer_scene_events = false
	var waiting := _scene_events
	_scene_events = []
	for msg in waiting:
		_dispatch_message(msg)

func recovery_checkpoint() -> Dictionary:
	return _recovery.duplicate(true)

func recovery_pending() -> bool:
	return not _recovery.is_empty() and StateCodec.canon_hash(_recovery["snapshot"]) != StateCodec.canon_hash(_display_snapshot())

## 进场/接管时直接恢复当前权威状态，不等待已过去的 ARM 或重新播放旧回合。
## 接管先逐条录入已经收齐的回执；检查点比回执更靠前时，另记显式恢复快照。
func restore_checkpoint(record_pending := false) -> bool:
	if _recovery.is_empty(): return false
	if record_pending:
		for msg in _inbox:
			if not msg.has("snapshot"): continue
			_adopt(msg["snapshot"])
			seq = int(msg.get("seq", seq))
			recorded_step.emit(msg["result"], msg["snapshot"])
	var changed := StateCodec.canon_hash(_recovery["snapshot"]) != StateCodec.canon_hash(_display_snapshot())
	_adopt(_recovery["snapshot"])
	seq = int(_recovery["seq"])
	_restored_seq = seq
	_phase = str(_recovery["phase"])
	_actor = str(_recovery["actor"])
	if record_pending and changed:
		recorded_step.emit({"ok": true, "op": Protocol.RECOVERY_STEP,
			"phase": _phase, "actor": _actor, "seq": seq}, _recovery["snapshot"])
	_inbox.clear()
	_scene_events = _scene_events.filter(func(msg): return msg["t"] != Protocol.APPLIED)
	_pending = false
	_last_result = Intent.err("cancelled", "连接已恢复")
	return true

func _display_snapshot() -> Dictionary:
	var snap := StateCodec.snapshot(_state)
	snap["pools"] = _applier.pools_snapshot()
	return snap

## 发一条意图并等服务器回音。
##
## from_seat 在这里**不发出去**：服务器按连接认身份（见 net/room.gd）。
## 参数留着是为了和 LocalTransport 同签名 —— 场景层的调用点是同一份代码
func submit(intent, _from_seat := "") -> Dictionary:
	var it: Dictionary = intent if intent is Dictionary else {}
	if intent is String:
		var dec: Dictionary = Intent.decode(intent)
		if not dec["ok"]:
			return _publish(dec)
		it = dec["intent"]
	if _closed or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return _publish(Intent.err("offline", "还没连上服务器"))
	if _pending:
		# 上一条还在飞。这不是网络错误，是**界面没锁住**：
		# 玩家能在等回音的时候再点一次。报出来而不是排队，
		# 排队会让第二次点击在几百毫秒后突然生效，手感上像误触
		return _publish(Intent.err("busy", "上一步还在等服务器回话"))
	_pending = true
	_last_result = {}
	_send(Protocol.intent(it))
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	# 安全阀开启的时刻。**不是一进循环就开**：队头压着一条服务器操作是
	# 正常状态（那是给演出留的节拍，见 _inbox），一进来就放行等于把
	# 结算演出全跳过。等到超时窗口的一半还没回音，才算真卡住
	var valve_at := Time.get_ticks_msec() + int(TIMEOUT_SEC * 500.0)
	while _pending and not _closed and Time.get_ticks_msec() < deadline:
		await _next_frame()
		# 我这条回音**不许**被一条压着的服务器操作挡死。场景层此刻正 await 在
		# 这个 submit 上，它不会再去取队头 —— 两边互相等着，症状是按钮全灰
		# 8 秒然后报「服务器没回话」，而服务器其实早就回了
		if _pending and Time.get_ticks_msec() >= valve_at and not _inbox.is_empty():
			var head: Dictionary = _inbox[0]
			var head_op := str((head["result"] as Dictionary).get("op", ""))
			if not Intent.is_client_op(head_op):
				push_warning("回音被服务器的 %s 挡着 —— 放行，这一步没有演出" % head_op)
				_inbox.pop_front()
				_apply(head)
				_drain()
	if _pending:
		_pending = false
		return _publish(Intent.err("timeout", "服务器没回话（%.0f 秒）" % TIMEOUT_SEC))
	return _publish(_last_result)

## 等一帧，并且**顺手 poll 一次**。
##
## 为什么自己 poll 而不是等场景层：submit 挂在这个循环上，
## 而唤醒它的回音只有 poll 才能收到。靠场景层每帧调 poll() 的话，
## 「谁忘了调」的后果是 submit 永远卡住 —— 而卡住的表现是按钮全灰，
## 看起来像网络问题，查起来要翻到 _process 里去。这里自己转就不存在这个洞。
##
## Engine.get_main_loop() 拿 SceneTree：这个类是 RefCounted，没有节点，
## 但 process_frame 是 SceneTree 的信号，从任何地方都能 await
func _next_frame() -> void:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		await (loop as SceneTree).process_frame
	poll()

# ---------- 收包 ----------

## 服务器给这条连接分配的 id。服务器那边用 WebSocketMultiplayerPeer，
## 它在握手完成时先发一个 4 字节的 peer id ——
## 那是 MultiplayerPeer 自己的协议，不是我们的消息
var peer_id := 0

## 一个包。先分流再解码：**不是每个包都是我们的消息**。
##
## 服务器用的是 WebSocketMultiplayerPeer，它握手完会先塞一个 4 字节的 peer id
## 过来。拿它去 JSON.parse 的结果是每连一次就刷一屏
## 「Unicode parsing error / Parse JSON failed」加一条 push_warning ——
## 而那一屏里混着真解不开的包时，谁都不会再去看。
## 所以按「JSON 对象一定以 { 开头」分流：认得出的噪声悄悄吃掉，
## 剩下的仍然要吵（那种才是协议对不上，要人去看）
func _on_packet(pkt: PackedByteArray) -> void:
	if pkt.size() == 4:
		peer_id = pkt.decode_s32(0)
		return
	if pkt.is_empty() or pkt[0] != 0x7b:      # '{'
		push_warning("收到一个不是 JSON 对象的包（%d 字节，首字节 0x%02x）" % [
			pkt.size(), 0 if pkt.is_empty() else pkt[0]])
		return
	_on_text(pkt.get_string_from_utf8())

func _on_text(text: String) -> void:
	# 判活的那一笔记在**最外面**：读不懂的消息（版本漂了、中间人塞了个包）
	# 也证明对端活着。记在 match 里的话「服务器只回得出 rejected」这种情形
	# 会被判成掉线，而那时候真该做的是把那句拒绝显示出来
	_seen_at = Time.get_ticks_msec()
	var dec: Dictionary = Protocol.decode(text)
	if not dec["ok"]:
		push_warning("收到读不懂的消息：%s" % dec["reason"])
		return
	var msg: Dictionary = dec["msg"]
	if _restored_seq >= 0 and msg["t"] in [Protocol.APPLIED, Protocol.PHASE] \
			and int(msg.get("seq", -1)) <= _restored_seq:
		return
	if msg.has("recovery"):
		_recovery = msg["recovery"].duplicate(true)
	_dispatch_message(msg)

func _dispatch_message(msg: Dictionary) -> void:
	if _defer_scene_events and not str(msg["t"]) in [Protocol.PONG, Protocol.SEATED, Protocol.PHASE, Protocol.CLOSED]:
		_scene_events.append(msg)
		return
	match str(msg["t"]):
		Protocol.PONG:
			# 心跳的回音。判活那一笔上面已经记了，这里只把延迟量出来
			var at := int(msg.get("at", 0))
			if at > 0:
				rtt_ms = Time.get_ticks_msec() - at
			return
		Protocol.SEATED:
			my_seat = str(msg["my_seat"])
			foe_seat = str(msg["foe_seat"])
			resume_token = str(msg.get("resume_token", ""))
			_adopt(msg["snapshot"])
			if msg.has("recovery"):
				_phase = str(msg["recovery"]["phase"])
				_actor = str(msg["recovery"]["actor"])
				seq = int(msg["recovery"]["seq"])
				_restored_seq = seq
				_inbox = _inbox.filter(func(queued): return int(queued.get("seq", -1)) > _restored_seq)
				_scene_events = _scene_events.filter(func(queued): return queued["t"] != Protocol.APPLIED or int(queued.get("seq", -1)) > _restored_seq)
			connected.emit(my_seat, foe_seat)
		Protocol.APPLIED:
			_on_applied(msg)
		Protocol.REJECTED:
			# 被拒的可能是我这条，也可能是别的（比如没进房间就发意图）。
			# _pending 时按「我这条被拒了」处理，否则只广播
			var r: Dictionary = Intent.err(str(msg["code"]), str(msg["reason"]))
			if _pending:
				_last_result = r
				_pending = false
			else:
				rejected.emit(r)
		Protocol.PHASE:
			_phase = str(msg["phase"])
			_actor = str(msg.get("actor", ""))
			phase_changed.emit(_phase, _actor)
		Protocol.FOE_DRAG:
			foe_drag.emit(msg)
		Protocol.FOE_PILES:
			foe_piles.emit(msg)
		Protocol.MY_PILES:
			my_piles.emit(msg)
		Protocol.FOE_LEFT:
			foe_left.emit()
		Protocol.FOE_BACK:
			foe_back.emit()
		Protocol.REMATCH_STATE:
			rematch_voted.emit(Array(msg["votes"]))
		Protocol.REMATCH_START:
			_on_rematch_start(msg)
		Protocol.CLOSED:
			# 留着，但**拒连不走这条**了：数据帧会随关闭一起丢，
			# 原因改走关闭帧（见 _emit_closed 和 Protocol.CLOSE_CODES）。
			# 这条是给「说完还不马上断」的场合备的 ——
			# 谁要把拒连接回这里，先看那两段实测
			_closed = true
			disconnected.emit(str(msg["code"]), str(msg["reason"]))

## 一条落地结果。**双方**的意图都会到这里 —— 对手那条没有「调用方」
## 可以返回给，所以走 applied 信号（net/protocol.gd的广播语义）。
##
## 客户端在这里**不重算状态**：它只把服务器的结果记下来，让场景层去演出。
## 重算就是又跑了一遍规则，那条路一分叉就再也合不回来
func _on_applied(msg: Dictionary) -> void:
	_inbox.append(msg)
	_drain()

## 收到的 applied 还没处理完的那些，**到达次序**。
##
## 为什么要排队而不是收到就处理：服务器是**一口气**把一整段推完的 ——
## net/room.gd 的 _settle 一次返回 produce×n + finalize + next_round，
## 这一串会在同一次 poll 里全部到达。而每条都带全量快照，
## 收到就合上的话客户端的状态在场景层演第 0 组之前就已经跳到**下一回合**了：
##   - _resolve_combo_visual(0) 去 Settle.ordered_production_combos(state) 取第 0 组，
##     而那时 state.combos 已经被 finalize 清空 —— 下标越界，崩在结算演出的第一行
##   - 侥幸不崩的话也是「产出动画演的是下一回合的局面」
## 都不报错，因为服务器那边一切正常。
##
## 所以规矩是：**状态的推进速度由场景层的演出决定**。队头是服务器专属操作
## （arm/produce/finalize/next_round）时就停住，等场景层来取
var _inbox: Array = []

## 把队头能处理的都处理掉。停在第一条**服务器专属操作**上 ——
## 那一条要等场景层 await 到对应的方法里来取（见 _await_server_op）。
##
## 客户端操作（自己的回音、对手的动作）不停：它们没有演出节拍要对齐，
## 而且自己那条回音停在这里就是 submit 卡死
func _drain() -> void:
	while not _inbox.is_empty():
		var msg: Dictionary = _inbox[0]
		var op := str((msg["result"] as Dictionary).get("op", ""))
		if not Intent.is_client_op(op):
			return
		_inbox.pop_front()
		_apply(msg)

## 处理一条 applied：合状态 → 唤醒 submit / 广播。
##
## 状态先合上，**再**发信号。次序不能反：表现层的每个 _render_foe_*
## 都要从 state 里查刚落地的那张卡（_render_foe_buy 就是
## state.find_card(foe_seat, r["new_uid"])）。先发信号的话它查到空字典，
## 在 state_card["uid"] 上崩 —— 而那是信号回调里的脚本错误，
## 调用方不失败、测试里隐形（memory: callback-script-error-doesnt-fail-test）
func _apply(msg: Dictionary) -> void:
	var r: Dictionary = msg["result"]
	seq = int(msg.get("seq", seq))
	if msg.has("snapshot"):
		_adopt(msg["snapshot"])
	# 录制早于返回自己操作的回音，也覆盖服务器阶段步骤和对手操作。
	if msg.has("snapshot"):
		recorded_step.emit(r, msg["snapshot"])
	if _pending and str(r.get("seat", "")) == my_seat and Intent.is_client_op(str(r.get("op", ""))):
		_last_result = r
		_pending = false
		return
	# 对手的动作，或者阶段推进 —— 两种都要广播，表现层按 op 分派
	applied.emit(r)

## 把服务器那份快照合进本地。**seated 和 applied 走同一个函数** ——
## 它们带的是同一种快照（net/room.gd 的 snapshot()）。
##
## pools 单独一步是因为点数池不在 GameState 上，它是裁决器的成员
## （见 engine/intent_apply.gd 的 pools_snapshot 那段说明）。
## 漏这一步的症状：状态全对、画面全对，但攻击回合**整段被跳过** ——
## pool_empty() 一上来就是真，而这条路径上没有任何一处会报错
func _adopt(snap: Dictionary) -> void:
	StateCodec.restore(_state, snap)
	_applier.pools_restore(snap.get("pools", {}))

# ---------- 阶段推进：等服务器发，不自己发 ----------

## 取一条服务器推进的结果 —— 也就是**放行队头那一条**。
## 已经到了就当场处理并返回，没到就等（超时口径和 submit 一致：
## 卡在 await 上的场景层是按钮全灰，那比报一句「服务器没回话」糟糕得多）。
##
## 认包只看 op，不看 seq：客户端不知道服务器给这一步排了几号，
## 而同一个 op 在一段里的次序**就是**场景层要它们的次序
## （produce 0,1,2… 是 room._settle 逐组发的那个顺序）。
##
## 队头是**另一个**服务器操作时照样放行（并且不返回它）：那说明两端
## 对「这一段有几步」的理解已经不一致了 —— 比如客户端算出 0 组产出
## 而服务器发了 2 条 produce。这时候硬等只会超时（8 秒全灰然后整局卡住），
## 而放过去至少让状态跟上、局面继续走。少演一段动画是能看出来的，
## 卡死不是。**次序仍然不变**：只是没人为它插演出
func _await_server_op(op: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SEC * 1000.0)
	while true:
		_drain()          # 队头攒着的客户端操作先处理掉（对手趁演出期间动了）
		if not _inbox.is_empty():
			var msg: Dictionary = _inbox.pop_front()
			var r: Dictionary = msg["result"]
			var got := str(r.get("op", ""))
			_apply(msg)
			if got != op:
				push_warning("等的是服务器的 %s，队头是 %s —— 放行，这一步没有演出" % [op, got])
			_drain()      # 它后面跟着的客户端操作也一并处理，别拖到下一帧
			if got == op:
				return r
			continue
		if _closed:
			return Intent.err("offline", "连接断了，没等到服务器的 %s" % op)
		if Time.get_ticks_msec() >= deadline:
			return Intent.err("timeout", "服务器没发来 %s（%.0f 秒）" % [op, TIMEOUT_SEC])
		await _next_frame()
	return Intent.err("unreachable", "")

## 这四个是**服务器专属**的操作（Intent.CLIENT_OPS 里没有它们）。
## 客户端调 submit 会被 PhaseMachine 的 not_client_op 拒掉 ——
## 所以这一侧的语义反过来：不是「我发一条」，而是「我等服务器那条」。
##
## 场景层的调用点因此一行不用改：它照样写 `await pipe.arm(who)`，
## 单机局那是本地裁决，联网局那是「等服务器装弹完广播过来」。
## 这正是 Transport 那层抽象存在的理由（见 engine/transport.gd 文件头）
func arm(_seat: String) -> Dictionary:
	return await _await_server_op(Intent.OP_ARM)

func produce(_combo_idx: int) -> Dictionary:
	return await _await_server_op(Intent.OP_PRODUCE)

func finalize() -> Dictionary:
	return await _await_server_op(Intent.OP_FINALIZE)

func next_round() -> Dictionary:
	return await _await_server_op(Intent.OP_NEXT_ROUND)

# ---------- 再来一局 ----------

## 投一票。不等回音（没有「投票成功」这回事）—— 服务器会广播 rematch_state，
## 两侧的按钮都靠那条改字。发不出去（已经断了）时静默：终局面板上
## 那个按钮点了没反应，比弹一句「连接已断」好 —— 断线本身已经报过一次了
func request_rematch() -> void:
	if _closed or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send(Protocol.rematch())

## 新局开始。**收件箱要清空**：里面攒着的是上一局的 applied
## （产出/收尾那一串，客户端按演出节拍逐条取，见 _drain）。
## 不清的话新局第一次 await pipe.arm() 会立刻拿到上一局排在队头的那条 ——
## 场景层于是按上一局的结果演新局的攻击阶段，而状态早已是新局的：
## 演出和状态各说各话，一条错都不报。
##
## _pending 也要落地：终局那一刻如果还有一条意图在飞，它的回音已经不会来了
## （服务器在 game_over 之后拒一切），留着 true 会让新局第一条 submit
## 一进来就撞上「一次只允许一条在飞」那道判断
func _on_rematch_start(msg: Dictionary) -> void:
	_inbox.clear()
	_restored_seq = -1
	_pending = false
	_last_result = {}
	my_seat = str(msg["my_seat"])
	foe_seat = str(msg["foe_seat"])
	_adopt(msg["snapshot"])
	rematch_started.emit(my_seat, foe_seat)

# ---------- 发包 ----------

## 发一条消息。
##
## **发完不用补 poll()**。查延迟的时候在这儿试过「发完立刻冲一次队列」，
## 量下来收益是 0：写了个探针让发方从头到尾一次不 poll，对面照样在同一轮收到 ——
## WebSocketPeer.send_text 是当场写进 socket 的，不是入队等下一次 poll。
## （当时以为省了 8ms，是探针本身的锅：它在「冲」的那一支把服务器 poll 调了
## 两次，省下的是**读得早一帧**，跟写没关系。）
##
## 所以别再往这儿加 poll()：收益 0，而从收包循环里调 poll() 是重入 ——
## 冲不出去，还会把入站队列在半路又抽一遍（net/server.gd 的 _kick 有实测经过）
func _send(msg: Dictionary) -> void:
	socket.send_text(Protocol.encode(msg))

## 广播一帧拖拽。归一化坐标由 scenes/main.gd 提供，传输层不知道布局。
## 失败不报错：拖拽是展示通道，丢一帧只是画面抖一下
func send_drag(phase_name: String, uids: Array, u := 0.0, v := 0.0) -> void:
	if _closed or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_drag_seq += 1
	_send(Protocol.drag(_drag_seq, phase_name, uids, u, v))

## 广播我这边的摞分组（见 Protocol.PILES）。全量名单，调用方给
## [[uid...]...]。和 send_drag 一样是展示通道：断线时静默不发
func send_piles(groups: Array) -> void:
	if _closed or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send(Protocol.piles(groups))

# ---------- 查询 ----------

func phase() -> String:
	return _phase

func actor() -> String:
	return _actor

func my_turn() -> bool:
	return _actor == my_seat

func online() -> bool:
	return not _closed and socket.get_ready_state() == WebSocketPeer.STATE_OPEN
