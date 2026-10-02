# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 外部输入的负向契约：拒绝后状态不变，处理器仍能接收下一条合法消息。
class CapturingServer extends NetServer:
	var sent: Array = []
	func _send_one(peer: int, msg: Dictionary) -> void:
		sent.append({"peer": peer, "msg": msg})
	func _kick(peer: int, code: String, reason: String) -> void:
		_send_one(peer, Protocol.closed(code, reason))

func _initialize() -> void:
	CardDB.load_default()
	_duplicate_references()
	_join_invariants()
	_intent_types()
	_protocol_types()
	_snapshot_types()
	_rule_fingerprint_and_recordings()
	finish()

func _game() -> GameState:
	var state := GameState.new()
	state.set_seed(91)
	state.new_game()
	return state

func _refused(result: Dictionary, label: String) -> void:
	check(result.get("ok") == false and result.get("reason") is String and not result["reason"].is_empty(), label)

func _duplicate_references() -> void:
	var s := _game()
	s.market = ["yunketang"]
	var cash: Array = s._loose_unit_uids(GameState.PLAYER, CardDB.RES_CASH)
	var card := s.add_card(GameState.PLAYER, "yunketang")
	var ap := IntentApply.new(s)
	var events: Array = []
	ap.landed.connect(func(r: Dictionary): events.append(r))
	var before := StateCodec.snapshot(s)
	var repeated: Array = []
	for i in int(CardDB.get_def("yunketang")["price"]): repeated.append(cash[0])
	for intent in [Intent.buy(GameState.PLAYER, 0, repeated), Intent.pawn(GameState.PLAYER, [card["uid"], card["uid"]]),
		Intent.create_combo(GameState.PLAYER, [card["uid"], card["uid"]])]:
		var r := ap.apply(Intent.encode(intent), GameState.PLAYER)
		check(r.get("code") == "duplicate_uid", "%s 拒绝重复实体" % intent["op"])
		check(StateCodec.snapshot(s) == before and events.is_empty(), "拒绝%s没有扣牌、增资、写战报或广播" % intent["op"])
	check(s.buy(GameState.PLAYER, 0, repeated).get("code") == "duplicate_uid", "直接购买入口同样检查重复")
	check(s.pawn(GameState.PLAYER, [card["uid"], card["uid"]]).get("code") == "duplicate_uid", "直接典当入口同样检查重复")
	cash.reverse()
	var price := int(CardDB.get_def("yunketang")["price"])
	var bought := ap.apply(Intent.buy(GameState.PLAYER, 0, cash), GameState.PLAYER)
	check(bought.get("ok", false) and bought["removed_uids"] == cash.slice(0, price), "合法付款保留玩家指定顺序")
	var sold := ap.apply(Intent.pawn(GameState.PLAYER, [card["uid"]]), GameState.PLAYER)
	check(sold.get("total") == CardDB.pawn_value("yunketang"), "合法单卡典当只支付一份售价")

func _join_invariants() -> void:
	var server := CapturingServer.new(17)
	server._table_hash = StateCodec.table_hash()
	var join := Protocol.join("AAA", StateCodec.table_hash())
	server._on_text(101, Protocol.encode(join))
	server._on_text(101, Protocol.encode(join))
	var room: NetRoom = server.rooms["AAA"]
	check(room.peers() == [101] and not room.started(), "同一连接重复 JOIN 同房不会占双座或开局")
	var first_seat := room.seat_of(101)
	check(room.seat_peer(101, room.tokens[GameState.opponent(first_seat)])["seat"] == first_seat,
		"房间入口也保持同一连接一个座位")
	server._on_text(101, Protocol.encode(Protocol.join("BBB", StateCodec.table_hash())))
	check(server.sent[-1]["msg"].get("code") == "already_joined", "跨房重复 JOIN 明确拒绝")
	check(server.rooms.keys() == ["AAA"] and server.peer_room[101] == "AAA", "拒绝换房不创建幽灵房间或覆盖反向索引")
	server._on_text(102, Protocol.encode(join))
	check(room.full() and room.peers() == [101, 102], "新连接仍可正常进入另一个座位")
	var token: String = room.tokens[first_seat]
	server._on_text(103, Protocol.encode(Protocol.join("AAA", StateCodec.table_hash(), token)))
	check(room.seat_of(103) == first_seat and room.seat_of(101) == "", "重连令牌仍可接替旧连接")
	server._on_peer_disconnected(101)
	check(room.seat_of(103) == first_seat, "旧连接退出不清理已接替的新座位")
	server._on_peer_disconnected(102)
	server._on_peer_disconnected(103)
	check(server.rooms.is_empty() and server.peer_room.is_empty(), "最后一个连接退出后完整回收")

func _intent_types() -> void:
	var invalid: Array = [null, true, "1", [], {}, 1.5, INF, NAN, -INF, 9007199254740992.0]
	for field in ["market_idx", "combo_idx"]:
		for value in invalid:
			var raw := Intent.buy(GameState.PLAYER, 0) if field == "market_idx" else Intent.produce(0)
			raw[field] = value
			_refused(Intent.from_dict(raw), "意图 %s 拒绝 %s" % [field, str(value)])
	for value in invalid + [-1]:
		for op in [Intent.OP_BUY, Intent.OP_PAWN, Intent.OP_COMBO, Intent.OP_ATTACK]:
			var raw := {"op": op, "seat": GameState.PLAYER, "market_idx": 0, "pay_uids": [value], "uids": [value],
				"target": {"kind": "card", "res": "cash", "uids": [value]}}
			_refused(Intent.from_dict(raw), "%s 拒绝无效 UID %s" % [op, str(value)])
	for field in ["op", "seat", "why"]:
		var raw := Intent.attack_done(GameState.PLAYER)
		raw[field] = {}
		_refused(Intent.from_dict(raw), "意图文本字段 %s 不强转对象" % field)
	_refused(Intent.decode('{"op":"buy","seat":"player","market_idx":{},"pay_uids":[]}'), "原始畸形 JSON 结构化拒绝")
	check(Intent.decode('{"op":"buy","seat":"player","market_idx":0.0,"pay_uids":[0.0,1.0]}').get("ok", false),
		"JSON 整值浮点仍可正常恢复为整数")

func _protocol_types() -> void:
	var invalid: Array = [null, true, "1", [], {}, 1.5, INF, NAN, -INF, -1, 9007199254740992.0]
	for template in [Protocol.join("AAA"), Protocol.ping(1), Protocol.drag(1, Protocol.DRAG_MOVE, [0])]:
		var field := "version" if template["t"] == Protocol.JOIN else ("at" if template["t"] == Protocol.PING else "seq")
		for value in invalid:
			var raw: Dictionary = template.duplicate(true)
			raw[field] = value
			_refused(Protocol.from_dict(raw), "协议 %s 拒绝无效 %s" % [template["t"], field])
	for value in [null, true, "0.5", {}, [], INF, NAN]:
		var drag := Protocol.drag(1, Protocol.DRAG_MOVE, [0])
		drag["u"] = value
		_refused(Protocol.from_dict(drag), "拖拽坐标拒绝非有限数字")
		_refused(Protocol.from_dict({"t": Protocol.PILES, "piles": [{"uids": [0], "u": value, "v": 0.5}]}), "摞坐标共用有限数字校验")
	for value in [null, {}, "player", 1, [GameState.PLAYER, GameState.PLAYER], [{}]]:
		_refused(Protocol.from_dict({"t": Protocol.REMATCH_STATE, "votes": value}), "投票名单拒绝错误类型或重复座位")
	for value in [true, "0", {}, -1, 0.5]:
		_refused(Protocol.from_dict({"t": Protocol.PILES, "piles": [{"uids": [value]}]}), "摞编号拒绝无效 UID")
	_refused(Protocol.from_dict({"t": Protocol.PILES, "piles": [{"uids": [0], "compact": "false"}]}), "收拢状态不能由字符串隐式转真")
	var result := {"ok": true, "op": Intent.OP_BUY, "market_idx": 0, "new_uid": 2, "removed_uids": [0]}
	for field in ["new_uid", "market_idx", "removed_uids", "ok"]:
		var broken: Dictionary = result.duplicate(true)
		broken[field] = {}
		_refused(Protocol.from_dict(Protocol.applied(broken, 1)), "回执拒绝错误字段 %s" % field)
	var nested := result.duplicate(true)
	nested["target"] = {"uids": [{}]}
	_refused(Protocol.from_dict(Protocol.applied(nested, 1)), "嵌套回执编号同样校验")
	var server := CapturingServer.new()
	server._on_text(1, '{"t":"join","room":"AAA","version":{}}')
	check(server.sent[-1]["msg"]["t"] == Protocol.REJECTED, "真实服务器处理路径返回拒绝包")
	server._on_text(1, Protocol.encode(Protocol.ping(42)))
	check(server.sent[-1]["msg"] == Protocol.pong(42), "坏包之后处理器继续接收合法心跳")

func _snapshot_types() -> void:
	var source := StateCodec.snapshot(_game())
	var cases: Array = []
	for field in ["players", "market", "combos", "rng", "log", "round_num", "uid", "winner"]:
		var snap := source.duplicate(true)
		snap[field] = null
		cases.append(snap)
	for field in ["uid", "def_id", "locked"]:
		var snap := source.duplicate(true)
		snap["players"][GameState.PLAYER]["cards"][0][field] = {}
		cases.append(snap)
	var duplicate := source.duplicate(true)
	duplicate["players"][GameState.PLAYER]["cards"].append(duplicate["players"][GameState.PLAYER]["cards"][0].duplicate())
	cases.append(duplicate)
	var pools := source.duplicate(true)
	pools["pools"] = {GameState.PLAYER: {"cash": {}, "user": 0}}
	cases.append(pools)
	var rng := source.duplicate(true)
	rng["rng"]["seed"] = "999999999999999999999999999"
	cases.append(rng)
	for entry in [{"fmt": "%d", "args": ["no number"]}, {"fmt": "%s%s", "args": ["one"]}, {"fmt": "%q", "args": [1]}, {"fmt": "%..s", "args": ["bad"]}]:
		var bad_log := source.duplicate(true)
		bad_log["log"] = [entry]
		cases.append(bad_log)
	var combo := source.duplicate(true)
	combo["combos"] = [{"owner": GameState.PLAYER, "uids": [0], "eval": {"type": "production", "leader": "yunketang", "output_res": "cash", "output_n": {}}}]
	cases.append(combo)
	for snap in cases:
		for message in [Protocol.seated(GameState.PLAYER, GameState.AI, snap), Protocol.applied({"ok":true,"op":Intent.OP_ACTION_DONE}, 1, snap),
			Protocol.rematch_start(GameState.PLAYER, GameState.AI, snap)]:
			_refused(Protocol.from_dict(message), "%s 在覆盖状态前拒绝损坏快照" % message["t"])
	check(Protocol.decode(Protocol.encode(Protocol.seated(GameState.PLAYER, GameState.AI, source))).get("ok", false), "真实完整快照可以往返")
	check(Protocol.decode(Protocol.encode(Protocol.seated(GameState.PLAYER, GameState.AI, StateCodec.snapshot(GameState.new())))).get("ok", false), "等候对手时的空桌快照可以往返")

func _rule_fingerprint_and_recordings() -> void:
	var ap := IntentApply.new(_game())
	var tape := Tape.new()
	tape.start(ap)
	tape.stop()
	var saved := tape.to_dict().duplicate(true)
	var original := StateCodec.table_hash()
	var legacy := StateCodec.legacy_table_hash()
	CardDB.CARDS["yunketang"]["price"] += 1
	check(StateCodec.table_hash() != original, "卡牌价格改变规则指纹")
	CardDB.CARDS["yunketang"]["price"] -= 1
	CardDB.GAME["win_cash"] += 1
	check(StateCodec.table_hash() != original, "胜利规则改变规则指纹")
	CardDB.GAME["win_cash"] -= 1
	var old_v2 := saved.duplicate(true)
	old_v2["table"] = legacy
	var loaded := Tape.from_dict(old_v2)
	check(loaded.get("ok", false) and loaded["tape"].table == original, "保存了完整规则证据的旧 v2 录像可迁移指纹")
	var rules := CardDB.UPGRADE.duplicate(true)
	CardDB.UPGRADE["routes"][2]["per"] = 3
	check(StateCodec.table_hash() != original and ComboRules.legend_upgrade_target(1, 4) == "", "升级折算率变化同时改变合法动作和规则指纹")
	loaded = Tape.from_dict(old_v2)
	check(loaded.get("ok", false) and loaded["tape"].table != StateCodec.table_hash(), "升级规则不一致的旧录像不能获准迁移")
	CardDB.UPGRADE = rules
	var old_v1 := saved.duplicate(true)
	old_v1["version"] = 1
	old_v1["table"] = legacy
	old_v1.erase("configuration")
	loaded = Tape.from_dict(old_v1)
	check(loaded.get("ok", false) and loaded["tape"].table == legacy, "无完整规则证据的 v1 不伪装成新指纹")
	var broken := saved.duplicate(true)
	broken["steps"] = [{"intent":{"op":"buy","seat":GameState.PLAYER,"market_idx":{},"pay_uids":[]}}]
	_refused(Tape.from_dict(broken), "录像意图复用网络严格校验")
	broken = saved.duplicate(true)
	broken["head"]["players"][GameState.PLAYER]["cards"][0]["uid"] = []
	_refused(Tape.from_dict(broken), "录像开局快照也在还原前校验")
