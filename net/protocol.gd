# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Protocol
extends RefCounted

## 网络消息的信封：消息类型、构造函数和 REQUIRED 字段表均在本文件定义。
##
## 和 engine/intent.gd 是**两层**，别合并：
##   Intent    = 「谁想做什么」，是玩法。单机局也走它，不联网也存在
##   Protocol  = 「这条消息怎么在线上走」，是传输。只有联网才有
## 合成一层的话，单机局会开始依赖只有联网才有的字段（room/table_hash/seq），
## 而那些字段在单机局里必然是空的 —— 于是「本地也走同一条管道」这条就废了。
##
## 这个文件只管**形状**：构造、编解码、字段校验。不碰 GameState，
## 不判断谁能发什么（那是服务器的事，见 tools/pvp_server.gd）。
## 和 Intent 分工一致：形状错说明发包的代码有 bug 或是伪造包，要拒包；
## 玩法错说明这一步走不了，要给玩家看原因

# ---------- 协议版本 ----------

## 只在**消息形状**变化时加（加字段不算，去字段/改语义才算）。
## 卡表哈希管数值一致，这个管协议一致 —— 两件事分开，
## 因为改平衡数值（天天改）不该把所有客户端顶掉
##
## v2：piles 里每一摞从 `[uid...]` 换成 `{uids, compact}`（见 PILES）。
## 这条**必须**加版本，尽管看着只是「加了个字段」：老服务器的 pile_lists 会
## 在 `not (g is Array)` 上把新形状**整份丢掉**，转发出去的是空名单 ——
## 于是新客户端连老服务器时摞一条都过不去，而两端都不报错。
## 加了版本号，这个组合在握手时就被拒掉（server._on_join）
##
## v3：每一摞多带 u/v（这一摞摆在哪，见 PILES）。同样**必须**加版本，
## 同样是因为服务器要原样转：v2 的 pile_lists 只挑 uids/compact 两个字段重排，
## u/v 在转发时被**静默丢掉** —— 新客户端连 v2 服务器时位置一条都过不去，
## 而症状（对手的摞总在行中间）和这条通道从来没有过位置一模一样，
## 没有版本号的话没人分得清是没实现还是被中间人吃了
##
## v4：多一条 foe_back（见 FOE_BACK）。这条**必须**加版本，理由和 v2/v3 同类
## 但不同因：老客户端不是「静默丢掉字段」，而是**整条拒收** ——
## from_dict 拿 REQUIRED 当类型白名单，没登记的 t 直接返回 bad_type，
## NetTransport 那边 push_warning 一句「读不懂的消息」就算完
## （实测：漏登记 REQUIRED 时症状就是这个）。
## 于是新服务器 + 老客户端 = 掉线提示**永久挂在**对手牌区，
## 而对手明明已经回来了、每一步也都在动 ——
## 「提示不消失」和「对手真的没回来」在屏幕上一模一样
##
## v5：多一条 my_piles（见 MY_PILES），且服务器开始**记住**双方最后一次
## piles 声明。这条同样**必须**加版本，因为它是「新客户端连老服务器」
## 会静默退化的那一类：老服务器不记摞，重连回来的人拿不到自己那些摞，
## 也拿不到对手那些 —— 而症状（摆放没恢复成断开时的样子）和这条改动
## 之前一模一样，没有版本号的话没人分得清是「服务器是旧的」
## 还是「这个 bug 没修好」
##
## v6：多一对 ping/pong（见 PING）。这条**必须**加版本，而且是这几条里
## 后果最重的一种静默退化：老服务器认不出 ping，走的是 _on_text 里
## `is_client_msg` 那道 → 回一条 rejected。新客户端于是**每隔 3 秒收到一条拒绝**，
## 而它判活看的是「有没有回音」—— rejected 也算回音，所以判活照样成立、
## 只是日志被刷满。反过来（老客户端 + 新服务器）什么都不发生：
## 老客户端不发 ping，服务器那道扫描器等 30 秒就把他当成掉线**踢下线**，
## 而他自己那条 socket 好得很 —— 症状是「玩着玩着被踹出去，一条错都不报」
##
## v7：produce 的 resolution（是否实际结算、原因、实付 paid_uids）成为必需回执。
## 客户端不再从缺牌或本地余额猜成功，也不在服务器确认前演付款。
## v6 服务器没有这个结果，连上后会丢失结算反馈，因此必须在握手拒绝混用。
## v8：入座和落地回执携带完整 recovery 检查点。状态、阶段和行动方属于同一次
## 服务端事务，恢复不再把尚未播完的展示快照与最新阶段拼在一起。
## v9：同类数值 Buff 按张数叠乘，避免与只应用一次倍率的旧客户端混用。
## v10：对手座位标识统一为 bot，拒绝与旧座位编码的客户端混用。
const VERSION := 10
## 仅录像里的权威快照恢复标记，不是玩家可提交的 Intent。
const RECOVERY_STEP := "recovery"

# ---------- 消息类型 ----------

# C→S
const JOIN := "join"                 ## { room, table_hash, version, resume_token }
const INTENT := "intent"             ## { intent }
const DRAG := "drag"                 ## { seq, phase, uids, u, v }
## 「我把这几张摞在一起了」。**纯表现**，不是玩法：摞不改任何引擎状态
## （玩家的摞要到收手时才由 _register_player_combos 变成 create_combo）。
##
## 为什么非得有这条：对手区的形态是收方**重建**出来的
## （settle_layout._bot_piles 按 state.combos + 闲置资源分堆），
## 而我行动阶段里摞好的那些摞在引擎里根本不存在 —— 于是我摞了半天，
## 对面看见的是牌被拖过去、然后**弹回资源堆**。拖拽广播管不了这个：
## 它只在手里拿着的那几十帧有效，松手之后由 PILES 同步表现分组，并由收方布局重建。
##
## 每一摞带 compact（双击收拢/摊开的那一位，见 board.toggle_compact）。
## 光有 uid 名单不够：收方只有名单时只能**照几何自己猜**摊开还是收拢
## （settle_layout.combo_spread_step），于是同一摞在两边可以一边摊开一边收拢 ——
## 而收拢/摊开是玩家亲手做的一个动作，不是布局的自由度
##
## 还带 u/v = 这一摞**摆在哪**（归一化坐标，和 DRAG 同一套口径，
## 见 main.my_pile_lists）。同一个道理再来一次：只有名单和形态的话，
## 落点由收方的 _layout_bot_zone 按「共几摞」现算成整行居中 ——
## 于是对手把组合拖到哪儿，我看到的都是同一个格子。
## 位置和形态一样是玩家亲手做的事，不是布局的自由度
const PILES := "piles"               ## { piles: [{uids: [uid...], compact: bool, u: float, v: float}, ...] }
## 「再来一局」。**不带任何载荷**：谁发的由连接认（占哪个座位），
## 想不想再来一局是个布尔量。撤销投票没有对应消息 ——
## 点了就等于愿意，改主意的路是退出房间（scenes/main.gd 的 _offer_reconnect / _on_net_down：这游戏重连很便宜，退了再进也便宜）
const REMATCH := "rematch"           ## { }

# S→C
const SEATED := "seated"             ## { my_seat, foe_seat, snapshot, resume_token }
const APPLIED := "applied"           ## { seat, result, seq }
const REJECTED := "rejected"         ## { code, reason }
const FOE_DRAG := "foe_drag"         ## { seq, phase, uids, u, v }
## 对手的摞分组。和 piles 同形，服务器只换类型原样转（它没有布局，也不判形态）
const FOE_PILES := "foe_piles"       ## { piles: [{uids: [uid...], compact: bool, u: float, v: float}, ...] }
## **你自己**上一次声明的摞分组，重连时由服务器回放（形状同 PILES）。
##
## 为什么需要它：摞是纯表现，只活在客户端的 board.groups 里
## （见 PILES）。重连的人是一份新进程 / 一张空桌子 ——
## 快照能把牌和钱还给他（state.combos 里的组合也还得回来，
## 见 main._restore_my_combo_groups），但**还没收手的那些摞**在
## 引擎里根本不存在，于是重连回来后它们被理牌当成散卡摊回资源堆。
## 玩家看到的就是「我摆了半天的阵型，重连之后没了」
##
## 而这条**顺带**修掉了对手侧的一半：重连的人重建自己的摞之后，
## 下一帧 _push_piles 会把它们照原样广播出去（指纹变了），
## 留下的那一位于是也看回原来的样子。
## 反方向那一半靠服务器回放对手那份（server._on_join 里发 FOE_PILES）
##
## 为什么不塞进 seated 而单开一条：seated 的载荷是**权威状态**
## （snapshot 是 state + pools）。摞不是状态，它是这一侧屏幕上的事 ——
## 混进去的话「服务器权威」这条线就模糊了，而且 rematch_start 也带
## snapshot，塞进去等于要在两处都记得把摞清空（新局不该继承旧局的摞）
const MY_PILES := "my_piles"         ## { piles: [{uids: [uid...], compact: bool, u: float, v: float}, ...] }
const PHASE := "phase"               ## { phase, actor }
const FOE_LEFT := "foe_left"         ## { }
## 对手回来了（重连回原座位，或者空座位又被人坐上）。
##
## 收方分不出这两种情况，也**不需要**分：房间是同一个、快照是同一份、
## 座位上的令牌也没换（net/room.gd 的 drop_peer 只把座位置 0）。
## 对留下的那一位来说，「对面又有人了」就是全部信息
##
## 没有载荷的理由同 FOE_LEFT：谁走了 / 谁回来了都只能是对手 —— 两个座位，
## 收到这条的是留下的那个。
## 没载荷所以 from_dict 里也没有对应的 case（同 REMATCH，见那个 match 末尾的说明），
## 但 REQUIRED 里**必须**登记 —— 那张表是类型白名单，漏了就是整条被拒
const FOE_BACK := "foe_back"         ## { }
const CLOSED := "closed"             ## { code, reason }
## 投票进度：谁点了、还差谁。**双方都收**，因为两侧的按钮都要变字
## （自己点完是「等对手…」，对手点了是「对手想再来一局」）。
## 用 votes 这个**名单**而不是「你点了吗 / 他点了吗」两个布尔：
## 座位是收方自己知道的事（my_seat），让服务器按收方裁剪等于同一条消息
## 要发两个版本，而那正是 seated 之外唯一会按人裁剪的东西 —— 不值得
const REMATCH_STATE := "rematch_state"   ## { votes: [seat...] }
## 新局开始。带的东西和 seated 一样多（座位 + 全量快照），但**不是** seated：
##   - seated 是「你入座了」，客户端拿它建整条管道、连信号、藏联网按钮。
##     rematch 时那些都已经连好了，再走一遍会重复连接、还会把
##     _net_phase_seen 那种一次性量的语义搞坏
##   - 而座位**会变**（先手在局间轮换，见 net/room.gd 的 reset_for_rematch），
##     所以又不能只发一个「重开了」了事：收方要按新座位重摆桌子
## resume_token 不带：令牌是跟座位走的，rematch 不换座位归属（换的是先手）
const REMATCH_START := "rematch_start"   ## { my_seat, foe_seat, snapshot }

## 心跳：客户端每隔几秒发一条，服务器**原样回一条 pong**（见 net/server.gd）。
##
## 为什么非要有它 —— TCP **保序但不保活**。一条 socket 上没有数据要走的时候，
## 它和一条对端已经消失的 socket 在本地看起来一模一样：STATE_OPEN、
## 没有关闭帧、没有错误。当时写了两条一次性探针量这个，量完就删了
## （结论记在这儿和 net/net_transport.gd 的心跳与超时处理，那才是它该留下的东西）：
##   - 主机进程被 kill  → 操作系统替它关 fd，对手 0.00 秒就收到 no_server ✔
##   - 主机**网络断了 / 机器睡了**（进程还活着）→ 6 秒过去
##     socket 还是 STATE_OPEN，disconnected 一条都没发 ✘
## 后一种正是玩家那句「对手处也没有自动建立新的服务端」的成因：
## 接管那条路挂在 disconnected 上，而这个码永远不来 ——
## 双方都停在「对手忽然不动了」，而那和「他在想」在屏幕上是同一个样子。
##
## 载荷是发出去那一刻的毫秒数，**原样回来**。有两个用途：
##   - 往返延迟（拿它减一下就是 RTT）
##   - 认得出「这条 pong 是回哪条 ping 的」—— 虽然现在只看「有回音」，
##     不带的话往后想量延迟就得改协议版本
const PING := "ping"                 ## { at: int 毫秒 }
const PONG := "pong"                 ## { at: int 毫秒（原样回） }

## 客户端**能发**的消息类型。白名单而不是黑名单：
## 以后加新消息忘了登记，只会「发不出去」，不会「客户端能伪造 seated」
const CLIENT_MSGS := [JOIN, INTENT, DRAG, PILES, REMATCH, PING]

const REQUIRED := {
	JOIN: ["room"],
	INTENT: ["intent"],
	DRAG: ["seq", "phase"],
	PILES: ["piles"],
	REMATCH: [],
	SEATED: ["my_seat", "foe_seat", "snapshot"],
	APPLIED: ["result"],
	REJECTED: ["code"],
	FOE_DRAG: ["seq", "phase"],
	FOE_PILES: ["piles"],
	MY_PILES: ["piles"],
	PHASE: ["phase"],
	FOE_LEFT: [],
	FOE_BACK: [],
	CLOSED: ["code"],
	REMATCH_STATE: ["votes"],
	REMATCH_START: ["my_seat", "foe_seat", "snapshot"],
	PING: [],
	PONG: [],
}

# ---------- 拖拽阶段 ----------
## 「拿起 / 移动 / 松手」三态。松手是权威事件，不走 drag ——
## 买牌、编组等规则变化由对应的 intent 落地后广播，不能依赖最后一帧 drag。
## 所以这里只有三个：拿起、移动中、取消（放回原处）
const DRAG_PICKUP := "pickup"
const DRAG_MOVE := "move"
const DRAG_CANCEL := "cancel"
const DRAG_PHASES := [DRAG_PICKUP, DRAG_MOVE, DRAG_CANCEL]

# ---------- 拒连原因 ----------
## 分开成码而不是只发一句话：客户端要按它决定「重试」还是「让玩家去更新」
const CLOSE_TABLE_MISMATCH := "table_mismatch"
const CLOSE_VERSION := "bad_version"
const CLOSE_ROOM_FULL := "room_full"
const CLOSE_BAD_ROOM := "bad_room"

## 拒连原因走**关闭帧**，不走数据帧。
##
## 第一版是「发一条 closed 消息，然后断」。实测那条消息会整个丢掉：
## 服务器 put_packet 之后断线，客户端只要晚 poll 一帧，
## 读到的就是「状态=CLOSED，包数=0」—— 排队的入站包随关闭一起没了。
## 而拒连原因是**一次性**的，丢了没有第二次机会补发，
## 玩家看到的就只剩「连不上」，而卡表不一致和端口写错要做的事完全不同。
##
## 关闭码是握手的一部分，晚 poll 也读得到（实测：客户端整段不 poll，
## 最后仍拿到码 4001 + 原因）。所以机器读的部分放这里。
## 4000-4999 是 WebSocket 给应用自己用的区间
const CLOSE_CODES := {
	CLOSE_TABLE_MISMATCH: 4001,
	CLOSE_VERSION: 4002,
	CLOSE_ROOM_FULL: 4003,
	CLOSE_BAD_ROOM: 4004,
}

## 关闭帧原因的字节上限。**超一个字节 close() 就什么都不做** ——
## 不报错、不断线，连接一直挂着 OPEN（实测 170 字节的中文原因就是这样）。
## 中文一个字三字节，40 个字就顶到头了，所以必须截
const CLOSE_REASON_MAX := 123

## 关闭码 → 我们的字符串码。认不出的返回 ""（正常关闭、网络断、老版本服务器）
static func close_code_name(num: int) -> String:
	for name in CLOSE_CODES:
		if int(CLOSE_CODES[name]) == num:
			return name
	return ""

## 按**字符边界**截到上限以内。按字节切会把一个汉字劈成半个，
## 那种字符串塞进关闭帧是 close() 静默失败的另一条路
static func clip_reason(text: String, limit := CLOSE_REASON_MAX) -> String:
	if text.to_utf8_buffer().size() <= limit:
		return text
	var out := ""
	for i in text.length():
		var next := out + text[i]
		if next.to_utf8_buffer().size() > limit:
			break
		out = next
	return out

# ---------- 房间码 ----------
## 字母 + 数字，**字母不分大小写**（归一化统一成大写）。
##
## 原先这里是 31 个字符的「不会认错」字母表（去掉 0/1/I/L/O，固定 4 位），
## 理由是房间码要念给对面听。那个理由对**随机生成**的码成立，
## 对**玩家自己起的**码不成立 —— 而后者是实际用法：
## 玩家想用 "ROOM1" 或 "LILI" 当约定的房间密码，照着打进去却被
## 「只用 23456789ABC…」这种提示挡在门外，而挡的是一串完全正常的字符。
## 归一化又是**丢字符**而不是纠错，于是 "LILI" 变成空串、"ROOM1" 变成 "RM"，
## 玩家看到的是「我填的码没错，服务器说房号不合法」。
##
## 现在的规矩只剩两条：字母数字、长度在 1..ROOM_MAX_LEN 之间。
## 易混字符的问题退回它本来的位置 —— make_room_code **生成**时避开
## （见 ROOM_GEN_ALPHABET），玩家自己打的一律收下
const ROOM_ALPHABET := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

## 长度上限。不是玩法限制，是**服务器侧的护栏**：房间码进了 rooms 这个字典当键
## （net/server.gd），不设上限的话一个改过的客户端能拿一条 join 开出一个
## 几兆长键的房间。24 位足够长到当密码用
const ROOM_MAX_LEN := 24

## 随机生成时用的字母表和长度。**只管生成**，不参与合法性判断 ——
## 生成的码是要念给对面听的（"零还是欧" 在电话里分不出来），
## 玩家自己打的码没这个问题（他是复制粘贴或者两边照着同一个约定打）
const ROOM_GEN_ALPHABET := "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
const ROOM_GEN_LEN := 4

static func make_room_code(rng: RandomNumberGenerator) -> String:
	var out := ""
	for i in ROOM_GEN_LEN:
		out += ROOM_GEN_ALPHABET[rng.randi_range(0, ROOM_GEN_ALPHABET.length() - 1)]
	return out

## 输入规范化：玩家会打小写、会带空格和连字符。
## 在**进比对之前**统一，否则「码是对的但连不上」，而且两端都觉得自己没错。
##
## 非字母数字（空格、连字符、下划线）照旧**丢掉**而不是拒掉：
## 玩家会照着念的节奏打 "AB-23"，那和 "ab23" 该进同一间
static func normalize_room(text: String) -> String:
	var out := ""
	for ch in text.strip_edges().to_upper():
		if ROOM_ALPHABET.contains(ch):
			out += ch
	return out

static func valid_room(code: String) -> bool:
	return code.length() >= 1 and code.length() <= ROOM_MAX_LEN \
		and normalize_room(code) == code

## 提示语里那句「房间码该长什么样」。**一处定义**：
## 服务器的拒连原因（net/server.gd）和客户端的输入校验（scenes/join_panel.gd）
## 都用这一句，两处各写一份的话改了规则只会改动一处，
## 而另一处会继续教玩家一个已经不成立的规矩
static func room_rule_text() -> String:
	return "房间码只用字母和数字（不分大小写），1-%d 位" % ROOM_MAX_LEN

# ---------- 构造 ----------

## 加入房间。table_hash 由 StateCodec.table_hash() 给 ——
## 客户端不该自己算一套口径（两套口径就会出现「哈希不等但两份表其实一样」）
static func join(room: String, table_hash := "", resume_token := "") -> Dictionary:
	var m := { "t": JOIN, "version": VERSION,
		"room": normalize_room(room), "table_hash": str(table_hash) }
	if resume_token != "":
		m["resume_token"] = str(resume_token)
	return m

static func seated(my_seat: String, foe_seat: String, snapshot: Dictionary,
		resume_token := "") -> Dictionary:
	return { "t": SEATED, "version": VERSION,
		"my_seat": str(my_seat), "foe_seat": str(foe_seat),
		"snapshot": snapshot, "resume_token": str(resume_token) }

## 客户端发意图。座位不在信封里 —— 服务器按**连接**认身份
## （IntentApply 的 from_seat）。放在信封里就等于让客户端自称是谁
static func intent(it: Dictionary) -> Dictionary:
	return { "t": INTENT, "intent": it }

## 落地结果广播给双方。seq 是 Transport 那个序号，客户端拿它对齐。
##
## APPLIED 的 snapshot 每条都带**全量状态**，不是可选的优化：
## 客户端侧没有裁决器（见 net_transport.gd 文件头），result 里只有
## 「这一步做了什么」——「做完之后局面是什么样」它自己算不出来。
## 不带的话客户端那份 state 从 seated 那一刻起就冻住了：手牌张数、
## 公共区、点数池全停在开局，而画面全是从 state 读的 —— 于是**画面不动**，
## 一条错都不报：单机和联网表现不同。
##
## 为什么不发增量：状态就几十张卡，全量让 desync「结构上不存在」；
## 增量是把它重新引进来。省下的那几 KB 换不来这个
static func applied(result: Dictionary, seq: int, snapshot: Dictionary = {}) -> Dictionary:
	var m := { "t": APPLIED, "result": result, "seq": int(seq) }
	if not snapshot.is_empty():
		m["snapshot"] = snapshot
	return m

static func rejected(code: String, reason: String) -> Dictionary:
	return { "t": REJECTED, "code": str(code), "reason": str(reason) }

## 拖拽广播；接收与租约处理见 scenes/main.gd 的 on_foe_drag。
##
## 坐标是**归一化的 (u,v)**，不是世界坐标：两端窗口大小和布局都不同，
## 传世界坐标等于假设对面和我同一套布局。uids 让接收端知道拖的是哪几张，
## 但**不含光标**：接收端只显示移动中的牌，不复刻对手的鼠标。
static func drag(seq: int, phase: String, uids: Array, u := 0.0, v := 0.0) -> Dictionary:
	return { "t": DRAG, "seq": int(seq), "phase": str(phase),
		"uids": Intent.ints(uids), "u": float(u), "v": float(v) }

## 转发给对手时只换类型，其余原样 —— 服务器不重算坐标（它没有布局）
static func foe_drag(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out["t"] = FOE_DRAG
	return out

## 摞分组广播（见 PILES）。发的是**全量分组**，不是「新增了一摞」：
## 摞会合并、会拆、会因为卡被打掉而消失，增量表述要把这些都编码进去，
## 而全量表述里它们只是「下一份名单和上一份不同」。一份名单几十个整数，
## 和 applied 每条都带全量快照是同一个取舍（见 applied 那段）。
##
## 没有 seq —— 和 drag 不同：drag 每 50ms 一帧、乱序到达要靠水位线丢旧帧，
## 而摞分组只在**分组真的变了**的时候发（见 main._push_piles），
## 而且走的是 TCP（WebSocket），同一条连接上的次序是保证的
static func piles(groups: Array) -> Dictionary:
	return { "t": PILES, "piles": pile_lists(groups) }

static func foe_piles(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out["t"] = FOE_PILES
	return out

## 回放某一侧自己声明过的摞（见 MY_PILES）。参数是**分组数组**而不是一条消息 ——
## 服务器手里存的就是数组（NetRoom.piles_of），不是它当初收到的那条包
static func my_piles(groups: Array) -> Dictionary:
	return { "t": MY_PILES, "piles": pile_lists(groups) }

## 心跳的一去一回（见 PING）。at 是发出那一刻的毫秒数，pong 原样带回来
static func ping(at_ms: int) -> Dictionary:
	return { "t": PING, "at": at_ms }

static func pong(at_ms: int) -> Dictionary:
	return { "t": PONG, "at": at_ms }

## 摞名单的规范化：uid 掰成 int、空摞丢掉、每一摞归一成
## `{uids: [int...], compact: bool}`（外加**可选**的 u/v）。收发两侧共用 ——
## 两处各写一份的话，「发出去的形状」和「收下来的形状」会各自漂移，
## 而症状是对手区少一摞，两端表现不同。
##
## 进来的每一摞**两种形状都收**：
##   - `{uids: [...], compact: bool, u/v}`：v3 的形状，发送端给的就是这个
##   - `[uid...]`：光名单。手写的包、测试里图省事的调用（send_piles([[60,61]])）
##     走这条，compact 当 false —— 「没说」就是「没收拢」，
##     而不是「让收方自己猜」：猜出来的形态和发送端不一致正是这条要治的病
##
## u/v 和 compact 不同，**没说就不出这两个键**（不是补个 0.0）：
## (0,0) 是桌角一个真实的点，补上去等于替发方声明「这一摞在桌角」——
## 于是老形状的包和单机局的摞会全挤到左后角。缺键时收方走它原来那条路
## （整行居中，见 settle_layout._layout_bot_zone），也就是这条改动之前的行为。
## 两个键**一起**给或者一起不给：只有一半的包按没说算，
## 半个坐标没有意义，而补另一半同样是替发方编造位置
##
## 出去的**一律**是字典形状。收方（settle_layout._declared_piles）因此
## 只有一种形状要读 —— 让它兼容两种等于把这份归一化又抄了一遍
static func pile_lists(groups: Array) -> Array:
	var out: Array = []
	if _piles_issue(groups) != "": return out
	for g in groups:
		var uids: Array = []
		var compact := false
		var uv: Variant = null
		if g is Array:
			uids = Intent.ints(g)
		elif g is Dictionary:
			var d := g as Dictionary
			uids = Intent.ints(d.get("uids", []))
			compact = bool(d.get("compact", false))
			if d.has("u") and d.has("v"):
				# 钳在 [0,1]：伪造包能送任意浮点，而收方拿它直接 lerp 到桌面上 ——
				# 不钳的话对手能把牌画到我这半边、画到购牌区上（同 drag 那条，
				# 两道都要有：发送端 my_drag_uv 也钳）
				uv = Vector2(clampf(float(d["u"]), 0.0, 1.0),
					clampf(float(d["v"]), 0.0, 1.0))
		else:
			continue
		if uids.is_empty():
			continue
		var rec := { "uids": uids, "compact": compact }
		if uv != null:
			rec["u"] = (uv as Vector2).x
			rec["v"] = (uv as Vector2).y
		out.append(rec)
	return out

static func phase(name: String, actor := "", sequence := -1) -> Dictionary:
	var msg := { "t": PHASE, "phase": str(name), "actor": str(actor) }
	if sequence >= 0: msg["seq"] = sequence
	return msg

static func foe_left() -> Dictionary:
	return { "t": FOE_LEFT }

static func foe_back() -> Dictionary:
	return { "t": FOE_BACK }

static func closed(code: String, reason: String) -> Dictionary:
	return { "t": CLOSED, "code": str(code), "reason": str(reason) }

## 客户端请求再来一局。空载荷（见 REMATCH 那段）
static func rematch() -> Dictionary:
	return { "t": REMATCH }

## 投票进度。votes 是**座位名单**，两侧收到的是同一份
static func rematch_state(votes: Array) -> Dictionary:
	var out: Array = []
	for s in votes:
		out.append(str(s))
	return { "t": REMATCH_STATE, "votes": out }

## 新局开始，按收方的新座位发。快照是全量的那一份（net/room.gd 的 snapshot）
static func rematch_start(my_seat: String, foe_seat: String,
		snapshot: Dictionary) -> Dictionary:
	return { "t": REMATCH_START, "version": VERSION,
		"my_seat": str(my_seat), "foe_seat": str(foe_seat), "snapshot": snapshot }

# ---------- 编解码 ----------

static func encode(msg: Dictionary) -> String:
	return JSON.stringify(msg)

## 解码 + 形状校验。返回 { ok: true, msg: {...} } 或 { ok: false, code, reason }。
##
## 和 Intent.decode 一样是**重建**而不是原样放行：手写包 / 老版本包
## 少个字段时要在这里拦住，而不是等到某个 `int(msg["seq"])` 上崩。
## intent 内层交给 Intent.from_dict 统一检查并归一化，错误码保持意图层的语义。
## 这样日志摘要和房间分流也只接触已经通过类型检查的数据。
## 用 JSON.new().parse() 而不是 JSON.parse_string()：**后者解不开时
## 会自己打一条引擎 ERROR 加一屏 GDScript 回溯**。而「收到读不懂的包」
## 在服务器上是家常事（版本不对、有人拿 curl 戳、代理插了帧），
## 每来一个就刷一屏的话：真正的 ERROR 会被埋掉，日志也能被外人灌满。
## 实例版是静默的，还顺手给出解析错在哪 —— 那句直接进 reason，
## 省得为了查一个手搓包再去开一遍抓包
static func decode(text: String) -> Dictionary:
	var j := JSON.new()
	if j.parse(text) != OK:
		return err("bad_json", "不是合法 JSON（第 %d 行：%s）" % [
			j.get_error_line(), j.get_error_message()])
	if not (j.data is Dictionary):
		return err("bad_json", "消息不是一个 JSON 对象")
	return from_dict(j.data)

## 落地结果里的 uid 要**掰回 int**。
##
## JSON 的数字全是 double，所以 applied 过一趟网络之后 new_uid 是 60.0 而不是 60。
## 值相等（60 == 60.0 为真）所以 find_card 照样找得到 —— 这条能潜很久。
## 它炸在拿 uid 当**字典键**和 Array.has 的地方，那两处 int 和 float 不是一回事：
##   实测 { 60: x }.has(60.0) = false，[60].has(60.0) = false，hash 也不等
## 而 scenes/main.gd 正好这么用：_commit_buy 里 `entities.has(u)` 查付掉的卡，
## 拖拽买里 `paid.has(c.uid)` 算多付的差集。float 键一律查不中的后果是
## 付掉的现金卡不被吸走、还被当成「多付的」原样退回 —— **联网局白拿一张牌**，
## 单机局一切正常。正是 「一条执行路径修好、另一条漏掉」的分叉。
##
## 为什么按字段名点出来，不做「整值 float 一律转 int」：后者会把某个
## 本该是 float 的字段变成 int，之后 `x / 2` 就成了整数除法 —— 换一个更难找的 bug。
## 新增 uid 类字段忘了登记的话，由 test_net_socket 的 T8 报出来（它扫整个结果）。
##
## `removed` 名字里**没有 uid** 却装着一串 uid（`GameState.apply_attack` 的回执），
## 所以它既漏过了这张白名单，也漏过了 T8 那个「按字段名找 uid」的扫描器 ——
## 两道网都是按名字织的，同一个字眼漏两次。症状是攻击对手的卡时
## `_animate_removed` 里 `entities.has(u)` 一张都查不中（int 键查不到 float），
## 于是不撕、返回 0.0，那几张卡一直挂到结算时才被 `_sync_entities` 的兜底路径
## 收走 —— 「响了一声、红框没了、牌还在」。钉它的是 tests/test_protocol.gd T3
const UID_FIELDS := ["new_uid", "core_uid"]
const UID_LIST_FIELDS := ["uids", "pay_uids", "paid_uids", "removed_uids", "empty_uids", "removed"]

static func restore_uids(r: Dictionary) -> Dictionary:
	var out := r.duplicate(true)
	for f in UID_FIELDS:
		if out.has(f):
			out[f] = int(out[f])
	for f in UID_LIST_FIELDS:
		if out.has(f):
			out[f] = Intent.ints(out[f])
	# 攻击目标与结算实付结果都是嵌套对象，UID 要在同一条解码路径恢复。
	for field in ["target", "resolution", "combo"]:
		if out.get(field, null) is Dictionary:
			out[field] = restore_uids(out[field])
	return out

## 裁决回执的递归字段检查也供录像读取使用；只归一已通过校验的数据。
static func result_issue(value: Variant, depth := 0) -> String:
	if depth > 16 or not value is Dictionary: return "裁决结果嵌套或格式错误"
	var d: Dictionary = value
	if depth == 0:
		if not d.get("ok") is bool or not d["ok"] or not d.get("op") is String or (not Intent.REQUIRED_FIELDS.has(d["op"]) and d["op"] != RECOVERY_STEP):
			return "裁决结果缺少成功标记或有效操作码"
		if d["op"] == RECOVERY_STEP:
			if d.get("phase") not in [PhaseMachine.ACTION, PhaseMachine.ATTACK, PhaseMachine.OVER]: return "恢复阶段无效"
			if d.get("actor") not in ["", GameState.PLAYER, GameState.BOT]: return "恢复行动方无效"
			if d["phase"] != PhaseMachine.OVER and d["actor"] == "": return "恢复行动方缺失"
			if not Intent.valid_integer(d.get("seq"), 0): return "恢复序号无效"
		var required := {
			Intent.OP_BUY: ["new_uid", "market_idx", "removed_uids"],
			Intent.OP_PAWN: ["uids", "total"],
			Intent.OP_COMBO: ["uids", "eval"],
			Intent.OP_ATTACK: ["removed", "target"],
			Intent.OP_PRODUCE: ["combo_idx", "combo", "resolution"],
			Intent.OP_ARM: ["pools", "empty"],
		}
		for key in required.get(d["op"], []):
			if not d.has(key): return "裁决结果缺少 %s" % key
	var issue := Intent.field_types(d,
		["op", "seat", "owner", "code", "reason", "why", "def_id", "kind", "res", "leader", "batch", "winner", "draw_first"],
		UID_FIELDS + ["market_idx", "combo_idx", "cost", "total", "round", "seq"], UID_LIST_FIELDS,
		["ok", "empty", "forfeited", "voided", "intact", "resolved"])
	if issue != "": return issue
	if d.has("seat") and d["seat"] not in ["", GameState.PLAYER, GameState.BOT]: return "裁决座位无效"
	for key in UID_FIELDS + ["cost", "total", "round", "seq"]:
		if d.has(key) and not Intent.valid_integer(d[key], 0): return "%s 必须是非负整数" % key
	for key in ["target", "resolution", "combo"]:
		if d.has(key):
			issue = result_issue(d[key], depth + 1)
			if issue != "": return issue
	if d.has("target"):
		var target: Dictionary = d["target"]
		if target.get("kind") not in ["combo", "spare", "card"] or target.get("res") not in [CardDB.RES_CASH, CardDB.RES_USER] \
			or not target.get("uids") is Array or target["uids"].is_empty(): return "攻击目标不完整"
	if d.has("combo"):
		issue = StateCodec.combo_issue(d["combo"])
		if issue != "": return issue
	if d.has("resolution"):
		if not d["resolution"].get("resolved") is bool or not d["resolution"].has("paid_uids"):
			return "结算回执不完整"
	if d.has("eval"):
		issue = StateCodec.eval_issue(d["eval"])
		if issue != "": return issue
	if d.has("pools"):
		issue = StateCodec.pools_issue({GameState.PLAYER: d["pools"]})
		if issue != "": return issue
	return ""

static func _piles_issue(value: Variant) -> String:
	if not value is Array: return "piles 不是一个数组"
	for pile in value:
		if pile is Array:
			if not Intent.valid_uids(pile): return "摞卡牌编号格式错误"
		elif pile is Dictionary:
			var issue := Intent.field_types(pile, [], [], ["uids"], ["compact"])
			if issue != "": return issue
			for key in ["u", "v"]:
				if pile.has(key) and not Intent.valid_number(pile[key]): return "摞坐标必须是有限数字"
		else:
			return "摞必须是对象或编号数组"
	return ""

static func _shape_issue(d: Dictionary, t: String) -> Dictionary:
	if d.has("recovery"):
		var recovery_error := recovery_issue(d["recovery"])
		if recovery_error != "": return err("bad_recovery", recovery_error)
	var issue := Intent.field_types(d,
		["t", "room", "table_hash", "resume_token", "my_seat", "foe_seat", "code", "reason", "phase", "actor"],
		["version", "seq", "at"], ["uids"])
	if issue != "": return err("bad_field", issue)
	for key in ["version", "seq", "at"]:
		if d.has(key) and not Intent.valid_integer(d[key], 0): return err("bad_field", "%s 必须是非负整数" % key)
	for key in ["u", "v"]:
		if d.has(key) and not Intent.valid_number(d[key]): return err("bad_field", "%s 必须是有限数字" % key)
	if t in [SEATED, REMATCH_START] or (t == APPLIED and d.has("snapshot")):
		issue = StateCodec.snapshot_issue(d.get("snapshot"))
		if issue != "": return err("bad_snapshot", issue)
	if t in [SEATED, REMATCH_START]:
		if d["my_seat"] not in [GameState.PLAYER, GameState.BOT] or d["foe_seat"] != GameState.opponent(d["my_seat"]):
			return err("bad_seat", "双方座位无效")
	if t == APPLIED:
		issue = result_issue(d.get("result"))
		if issue != "": return err("bad_result", issue)
	if t in [PILES, FOE_PILES, MY_PILES]:
		issue = _piles_issue(d["piles"])
		if issue != "": return err("bad_piles", issue)
	if t == REMATCH_STATE:
		if not d["votes"] is Array: return err("bad_votes", "投票名单必须是数组")
		var seen := {}
		for seat in d["votes"]:
			if seat not in [GameState.PLAYER, GameState.BOT] or seen.has(seat): return err("bad_votes", "投票座位无效或重复")
			seen[seat] = true
	if t == PHASE:
		if d["phase"] not in [PhaseMachine.ACTION, PhaseMachine.ATTACK, PhaseMachine.SETTLING, PhaseMachine.OVER]:
			return err("bad_phase", "未知对局阶段")
		if d.get("actor", "") not in ["", GameState.PLAYER, GameState.BOT]: return err("bad_seat", "行动座位无效")
	return {}

## 只在一次服务器同步推进完成后的可交互/终局边界生成检查点。
## SETTLING 的中间快照缺少产出游标，不能作为可恢复状态。
static func recovery_issue(value: Variant) -> String:
	if not value is Dictionary: return "恢复检查点必须是对象"
	for key in ["snapshot", "phase", "actor", "seq"]:
		if not value.has(key): return "恢复检查点缺少 %s" % key
	if value["phase"] not in [PhaseMachine.ACTION, PhaseMachine.ATTACK, PhaseMachine.OVER]:
		return "恢复检查点阶段无效"
	if value["actor"] not in ["", GameState.PLAYER, GameState.BOT]: return "恢复行动方无效"
	if value["phase"] != PhaseMachine.OVER and value["actor"] == "": return "恢复检查点缺少行动方"
	if not Intent.valid_integer(value["seq"], 0): return "恢复序号无效"
	var issue := StateCodec.snapshot_issue(value["snapshot"])
	if issue != "": return issue
	if not value["snapshot"].has("pools"): return "恢复检查点缺少攻击点数池"
	return ""

static func from_dict(d: Dictionary) -> Dictionary:
	if d.has("t") and not d["t"] is String:
		return err("bad_type", "消息类型必须是文本")
	var t := str(d.get("t", ""))
	if not REQUIRED.has(t):
		return err("bad_type", "未知消息类型：%s" % t)
	for f in REQUIRED[t]:
		if not d.has(f):
			return err("missing_field", "%s 缺字段 %s" % [t, f])
	var shape := _shape_issue(d, t)
	if not shape.is_empty(): return shape
	var out := { "t": t }
	match t:
		JOIN:
			out["version"] = int(d.get("version", 0))
			out["room"] = normalize_room(str(d["room"]))
			out["table_hash"] = str(d.get("table_hash", ""))
			out["resume_token"] = str(d.get("resume_token", ""))
			if out["room"] == "":
				return err(CLOSE_BAD_ROOM, "房间码是空的")
		SEATED:
			out["version"] = int(d.get("version", 0))
			out["my_seat"] = str(d["my_seat"])
			out["foe_seat"] = str(d["foe_seat"])
			out["snapshot"] = d["snapshot"]
			out["resume_token"] = str(d.get("resume_token", ""))
		INTENT:
			if not (d["intent"] is Dictionary):
				return err("bad_intent", "intent 不是一个对象")
			var decoded := Intent.from_dict(d["intent"])
			if not decoded["ok"]: return decoded
			out["intent"] = decoded["intent"]
		APPLIED:
			out["result"] = restore_uids(d["result"])
			out["seq"] = int(d.get("seq", 0))
			# 快照可以没有（老服务器 / 手搓的包），但**有就必须是对象** ——
			# 不校验的话一个 "snapshot": 3 会一路传到 StateCodec.restore，
			# 在 d.get("players", {}) 上把整局清空
			if d.has("snapshot"):
				out["snapshot"] = d["snapshot"]
		REJECTED, CLOSED:
			out["code"] = str(d["code"])
			out["reason"] = str(d.get("reason", ""))
		DRAG, FOE_DRAG:
			var ph := str(d["phase"])
			if not DRAG_PHASES.has(ph):
				return err("bad_phase", "未知拖拽阶段：%s" % ph)
			out["seq"] = int(d["seq"])
			out["phase"] = ph
			out["uids"] = Intent.ints(d.get("uids", []))
			# 坐标钳到 [0,1]：归一化坐标越界只能是发送端算错了，
			# 但不值得为此拒包 —— 拒了整条拖拽就断了，钳住只是画在边上
			out["u"] = clampf(float(d.get("u", 0.0)), 0.0, 1.0)
			out["v"] = clampf(float(d.get("v", 0.0)), 0.0, 1.0)
		PILES, FOE_PILES, MY_PILES:
			# 走 pile_lists 而不是原样收下，两件事：
			#   1. uid 过一趟 JSON 全变成 double，而收方拿它当**字典键**用
			#      （settle_layout._bot_pile_of_uid）—— { 60: x }.has(60.0) 是 false，
			#      症状是摞看着摆好了、点不着（和 UID_FIELDS 那段是同一个坑）
			#   2. compact 掰成 bool，并且把老形状（光名单）补齐成字典
			out["piles"] = pile_lists(d["piles"])
		PHASE:
			out["phase"] = str(d["phase"])
			out["actor"] = str(d.get("actor", ""))
			if d.has("seq"): out["seq"] = int(d["seq"])
		REMATCH_STATE:
			# 名单里的座位名逐个 str()：JSON 里它们本来就是字符串，
			# 但这一层的规矩是「出去的字段一律经过自己的类型」——
			# 收方拿它和 my_seat 做 == 比较，一个 float 混进来就永远不等
			var vs: Array = []
			for s in (d["votes"] as Array):
				vs.append(str(s))
			out["votes"] = vs
		REMATCH_START:
			out["version"] = int(d.get("version", 0))
			out["my_seat"] = str(d["my_seat"])
			out["foe_seat"] = str(d["foe_seat"])
			# 和 SEATED 同样的校验：快照不是对象的话一路传到 StateCodec.restore，
			# 在 d.get("players", {}) 上把整局清空
			out["snapshot"] = d["snapshot"]
		PING, PONG:
			# at 只是**原样搬回去**的一个数（发出那一刻的毫秒数）。
			# 缺了不算错：判活看的是「有没有回音」，不是这个数对不对 ——
			# 为一条心跳拒包等于把心跳自己变成断线的成因
			out["at"] = int(d.get("at", 0))
	# REMATCH 故意没有 case：它没有载荷，上面那个 `out := { "t": t }` 就是全部。
	# **不是漏写的** —— 这个 match 是字段白名单，没进来的字段会被**静默丢掉**
	# （REMATCH_STATE 和 REMATCH_START 头一版就是这么漏的：REQUIRED 登记了、
	# 构造函数写了、单元判据全绿，可过一趟 decode 之后 votes 和 my_seat 都不见了，
	# 症状是「投票没反应」而不是报错）。加新类型时这里和 REQUIRED 是**两处**都要改
	if d.has("recovery"):
		out["recovery"] = d["recovery"].duplicate(true)
	return { "ok": true, "msg": out }

static func err(code: String, reason: String) -> Dictionary:
	return { "ok": false, "code": code, "reason": reason }

static func is_client_msg(t: String) -> bool:
	return CLIENT_MSGS.has(t)

## 给日志用的一行摘要。不进协议
static func brief(msg: Dictionary) -> String:
	var t := str(msg.get("t", "?"))
	match t:
		INTENT:
			return "intent " + Intent.brief(msg.get("intent", {}))
		APPLIED:
			var r: Dictionary = msg.get("result", {})
			return "applied #%d %s/%s %s" % [int(msg.get("seq", 0)),
				r.get("seat", "-"), r.get("op", "?"),
				"ok" if r.get("ok", false) else "ng"]
		DRAG, FOE_DRAG:
			return "%s %s #%d %s" % [t, msg.get("phase", "?"),
				int(msg.get("seq", 0)), str(msg.get("uids", []))]
		PILES, FOE_PILES:
			# 打摞数、总张数、收拢了几摞，不打整份名单：这条在行动阶段会发不少次，
			# 名单铺开会把日志刷满 —— 而「几摞几张」足够看出分组有没有在变。
			# 收拢数要打：双击收拢/摊开时**名单一个字都不变**，
			# 日志里没有这个数的话那条广播看起来和上一条一模一样
			var ps: Array = msg.get("piles", [])
			var n := 0
			var k := 0
			for g in ps:
				var uids: Array = (g as Dictionary).get("uids", [])
				n += uids.size()
				if bool((g as Dictionary).get("compact", false)):
					k += 1
			return "%s %d摞/%d张/收拢%d" % [t, ps.size(), n, k]
		JOIN:
			return "join %s" % msg.get("room", "")
		REMATCH_STATE:
			# 名单要打出来：服务器日志上「谁在等谁」是这条协议唯一的可观察量，
			# 只打个 rematch_state 的话「投票丢了」和「对手真没点」长得一模一样
			return "rematch_state %s" % str(msg.get("votes", []))
		REMATCH_START:
			return "rematch_start %s" % msg.get("my_seat", "?")
		_:
			return t
