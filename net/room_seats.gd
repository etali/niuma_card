# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name RoomSeats
extends RefCounted

const SEATS := [GameState.PLAYER, GameState.BOT]

var code := ""
## seat -> peer id（0 = 空座）。断线时置 0 但**保留房间**，等重连
var occupants: Dictionary = {}
## seat -> 重连令牌。断线的人拿它证明「我是原来那个座位」，
## 否则第三个人连进来就能顶掉刚掉线的那位
var tokens: Dictionary = {}
var seq := 0

## 这一局结束后点了「再来一局」的座位。**两个都点齐才重开**（net/room.gd 的 rematch 投票与重开）。
##
## 为什么要投票而不是一方点了就重开：终局面板是玩家读战报的地方，
## 对手单方面重开会把它从屏幕上抽走 —— 那一刻他连自己为什么输都还没看完。
## 局间是这个游戏唯一的「非实时」时刻，等一下不花成本
var rematch_votes: Dictionary = {}
## 已经开过几局（第一局是 1）。发给客户端只为提示语里那个数
var game_num := 1

var _rng := RandomNumberGenerator.new()

func _init(room_code: String, _seed_value := 0) -> void:
	code = room_code
	_rng.randomize()
	for s in SEATS:
		occupants[s] = 0
		tokens[s] = _make_token()

func _make_token() -> String:
	return "%d-%d" % [_rng.randi(), Time.get_ticks_usec()]

# ---------- 入座 ----------

func free_seat() -> String:
	for s in SEATS:
		if int(occupants[s]) == 0:
			return s
	return ""

func full() -> bool:
	return free_seat() == ""

func seat_of(peer: int) -> String:
	for s in SEATS:
		if int(occupants[s]) == peer:
			return s
	return ""

## 令牌对得上的那个座位（重连用）。对不上返回 ""
func seat_for_token(token: String) -> String:
	if token == "":
		return ""
	for s in SEATS:
		if str(tokens[s]) == token:
			return s
	return ""

## 让一个连接入座。token 非空且对得上就是**重连**（回原座位），
## 否则占一个空位。返回 { ok, seat } 或 { ok=false, code, reason }
func seat_peer(peer: int, token := "") -> Dictionary:
	var existing := seat_of(peer)
	if existing != "":
		return { "ok": true, "seat": existing, "resumed": true }
	var resumed := seat_for_token(token)
	if resumed != "":
		# 重连不看座位是否被占：占着的只可能是自己（令牌是一对一的），
		# 或者是一个已经掉线但服务器还没收到断开通知的旧连接
		occupants[resumed] = peer
		return { "ok": true, "seat": resumed, "resumed": true }
	var s := free_seat()
	if s == "":
		return Protocol.err(Protocol.CLOSE_ROOM_FULL, "房间 %s 已经满了" % code)
	occupants[s] = peer
	return { "ok": true, "seat": s, "resumed": false }

## 连接断开：座位置空但**不删房间**（scenes/main.gd 的 _offer_reconnect / _on_net_down：没有隐藏信息，重连很便宜）。
## 令牌留着，原来那个人拿它能回来
func drop_peer(peer: int) -> String:
	var s := seat_of(peer)
	if s != "":
		occupants[s] = 0
		# 掉线**撤票**。留着的后果是这一票会记在座位上而不是人身上：
		# 投了票的人走掉之后，另一位一点就直接开新局 —— 而他等的那个人不在了，
		# 新局第一个对手回合停在等一条永远不来的 action_done（scenes/main.gd 的 _offer_reconnect / _on_net_down 处理的断线状态）。
		# 重连回来的人自己再点一次就是了：终局面板本来就还在他屏幕上
		rematch_votes.erase(s)
	return s

func empty() -> bool:
	for s in SEATS:
		if int(occupants[s]) != 0:
			return false
	return true

func peers() -> Array:
	var out: Array = []
	for s in SEATS:
		var p := int(occupants[s])
		if p != 0:
			out.append(p)
	return out

## 一个座位点了「再来一局」。返回要广播的消息列表。
##
## 三道拦：不在座位上、局还没结束、已经投过。中间那道是要紧的 ——
## 局中收到 rematch 就重开等于**任何一方随时能掀桌**，
## 而它长得像个正常操作（客户端只要发一条空消息）。
## 所以「什么时候能投」由服务器判，不由客户端的按钮可见性判：
## 按钮藏起来只是让人点不到，不是让人发不出
func handle_rematch(peer: int) -> Array:
	var seat := seat_of(peer)
	if seat == "":
		return [_to(peer, Protocol.rejected("no_seat", "你不在这个房间的座位上"))]
	if not match_finished():
		return [_to(peer, Protocol.rejected("not_over", "这一局还没结束"))]
	if bool(rematch_votes.get(seat, false)):
		return [_to(peer, Protocol.rejected("already_voted", "你已经点过再来一局了"))]
	rematch_votes[seat] = true
	# 进度先广播出去：对手要立刻看到「对手想再来一局」，
	# 而不是等他自己也点了才知道有人在等他
	var out: Array = [_all(Protocol.rematch_state(voted_seats()))]
	if voted_seats().size() < SEATS.size():
		return out
	out.append_array(reset_for_rematch())
	return out

## 已投票的座位，**按 SEATS 的次序**。次序固定是为了让它能进判据：
## 拿 Dictionary 的键序当返回值的话，同一份投票在两次运行里可能顺序不同
func voted_seats() -> Array:
	var out: Array = []
	for s in SEATS:
		if bool(rematch_votes.get(s, false)):
			out.append(s)
	return out

func match_finished() -> bool:
	return false

func reset_for_rematch() -> Array:
	return []

func _all(msg: Dictionary) -> Dictionary:
	return {"to": 0, "msg": msg}

func _to(peer: int, msg: Dictionary) -> Dictionary:
	return {"to": peer, "msg": msg}
