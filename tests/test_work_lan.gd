# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var game: Node = load("res://scenes/off_work_main.tscn").instantiate()
	game.set_meta("shift_enter_expanded", true)
	root.add_child(game)
	if game.lan == null:
		check(false, "下班联网入口已初始化")
		finish()
		return
	var solo: RefCounted = game.state
	var panel: JoinPanel = game.lan.open_panel()
	panel._room_edit.text = "WORK"
	panel._on_host()
	var port: int = game.lan.local_host_port()
	check(port > 0, "同一联机面板可开房")
	var visitor := game.lan.make_transport("ws://127.0.0.1:%d" % port, "WORK") as OffWorkTransport
	check(await net_until([], func(): return panel._net != null and panel._net.my_seat != ""), "房主就座等候")
	check(game.state == solo and not game.lan.live(), "等候期间保留单人牌局")
	var url := "ws://127.0.0.1:%d" % port
	var wrong_mode := NetTransport.new(url, "WORK")
	var refusal := []
	wrong_mode.disconnected.connect(func(code, why): refusal.append([code, why]))
	wrong_mode.connect_to_server()
	check(await net_until([wrong_mode], func(): return not refusal.is_empty()) and "玩法不同" in str(refusal), "拒绝误入下班房间的上班客户端")
	var wrong_cards := OffWorkTransport.new(url, "WORK")
	wrong_cards.balance_hash = "other"
	refusal.clear()
	wrong_cards.disconnected.connect(func(code, why): refusal.append([code, why]))
	wrong_cards.connect_to_server()
	check(await net_until([wrong_cards], func(): return not refusal.is_empty()) and "卡表不一致" in str(refusal), "拒绝不同卡表的客户端")
	visitor.connect_to_server()
	check(await net_until([visitor], func(): return visitor.has_dealt_state() and game.lan.live()), "第二位加入后双方收到发牌")
	if not game.lan.live() or visitor.latest.is_empty():
		visitor.close()
		game.free()
		finish()
		return
	check(game.bot == null and game.state != solo, "联机局两席均由人控制")
	var cards: Dictionary = visitor.latest.world.cards
	var id: int = cards.keys()[0]
	check(game.state.cards[id].owner == 1 - int(cards[id].owner), "对面视角旋转，卡号一致")
	var funds: int = game.state.money(0)
	var hire: Dictionary = game.state.offers.filter(func(c): return not c.is_empty() and c.type == "employee")[0]
	var mine: Array = game.state.cards.keys()
	game._on_buy(hire.id)
	check(await net_until([visitor], func(): return game.state.money(0) == funds - int(hire.price)), "从牌桌购买并按房主卡表扣款")
	var hired_id: int = game.state.cards.keys().filter(func(uid): return uid not in mine and game.state.cards[uid].type == "employee")[0]
	game._on_dismiss([hired_id])
	check(await net_until([visitor], func(): return not game.state.cards.has(hired_id)), "开除刚购买的员工在两端落地")
	var foreign: int = cards.values().filter(func(c): return c.owner != 0)[0].id
	var denied := []
	visitor.rejected.connect(func(r): denied.append(r))
	visitor.send_action({"op": "move", "ids": [foreign]})
	check(await net_until([visitor], func(): return not denied.is_empty()), "拒绝替另一位移动牌")
	var own_work: Dictionary = cards.values().filter(func(c): return c.owner == 0 and c.type == "work")[0]
	var own_person: Dictionary = cards.values().filter(func(c): return c.owner == 0 and c.type == "employee")[0]
	visitor.send_action({"op": "move", "ids": [own_work.id], "group": own_person.group})
	check(await net_until([visitor], func(): return game.state.cards[own_work.id].group == own_person.group), "对手组合动作在房主桌面落地")
	visitor.send_action({"op": "away", "value": true})
	check(await net_until([visitor], func(): return visitor.latest.paused), "切班同步暂停")
	var t: float = game.state.time
	await net_pump_for([visitor], 400)
	check(game.state.time == t and visitor.latest.world.time == t, "离桌期间双方权威时间冻结")
	visitor.send_action({"op": "away", "value": false})
	check(await net_until([visitor], func(): return game.state.time > t), "返回下班继续原局")
	visitor.send_action({"op": "resign"})
	check(await net_until([visitor], func(): return game.state.winner == 0 and visitor.latest.world.winner == 1), "认输由服务器裁决、双方胜负互补")
	game._show_result()
	var line: Label = game.result_layer.find_child("ResultMessage", true, false)
	check(is_instance_valid(line) and game.hud.hud_config.result.win_taunts.has(line.text), "对方联网认输显示本地胜方调侃")
	visitor.request_rematch()
	game.lan.rematch()
	check(await net_until([visitor], func(): return visitor.latest.round == 2 and game.state.winner < 0), "双方同意后重新发牌")
	check(game.replay.result_taunt.is_empty(), "联机重开清除上一局的结算句")
	var token: String = visitor.resume_token
	var seat: String = visitor.my_seat
	visitor.close()
	check(await net_until([visitor], func(): return not game.lan._host.server.rooms.WORK.full()), "断开后保留房间")
	t = game.state.time
	visitor = game.lan.make_transport("ws://127.0.0.1:%d" % port, "WORK")
	visitor.resume_token = token
	visitor.connect_to_server()
	check(await net_until([visitor], func(): return visitor.has_dealt_state()), "重连原局")
	check(visitor.my_seat == seat and visitor.latest.round == 2 and visitor.latest.world.time >= t, "重连恢复原座位和时间")
	game.lan._leave()
	check(game.state == solo and game.bot != null, "离开房间恢复原单机牌局")
	visitor.close()
	await _takeover(game)
	game.free()
	finish()

func _takeover(game: Node) -> void:
	var remote := EmbeddedHost.new(12345)
	remote.off_work_config = game.state.config
	check(remote.start_random().ok, "外部房主开房")
	_srv = remote
	var former := game.lan.make_transport(remote.url(), "WORK") as OffWorkTransport
	former.connect_to_server()
	check(await net_until([former], func(): return former.my_seat != ""), "外部房主占近席")
	var panel: JoinPanel = game.lan.open_panel()
	panel._room_edit.text = "WORK"
	panel._url_edit.text = remote.url()
	panel._on_connect()
	check(await net_until([former], func(): return game.lan.live() and game.lan.net.my_seat == OnWorkState.BOT), "本机通过面板以远席加入")
	if not game.lan.live():
		net_stop()
		return
	var initial: Dictionary = game.state.cards.duplicate(true)
	var original_rng: int = game.lan.net.checkpoint.rng
	net_stop()
	check(await net_until([], func(): return game.lan.live() and game.lan._host != null and game.lan.net.my_seat == OnWorkState.BOT), "原房主下线后自动接管并保留远席")
	if game.lan._host == null: return
	check(game.state.cards == initial and game.lan._host.server.rooms.WORK.world._rng.state == original_rng, "接管保留卡牌方位与随机数状态")
	var back := game.lan.make_transport(game.lan._host.url(), "WORK") as OffWorkTransport
	back.resume_token = former.resume_token
	back.connect_to_server()
	check(await net_until([back], func(): return back.has_dealt_state()), "原主机能重回相同房号")
	check(back.my_seat == OnWorkState.PLAYER and back.latest.round == 1, "原主机恢复正确的另一席")
	back.close()
	game.lan._leave()

