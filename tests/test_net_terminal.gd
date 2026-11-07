# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 致胜攻击必须仍给客户端提供收尾回执；胜负后不再接受 ATTACK_DONE。
func _initialize() -> void:
	OnWorkCardDB.load_default()
	for attacker in [OnWorkState.PLAYER, OnWorkState.BOT]:
		await _winning_attack(attacker)
	finish()

func _winning_attack(attacker: String) -> void:
	var room := OnWorkRoom.new("TERMINAL", 517)
	room.seat_peer(11)
	room.seat_peer(12)
	room.start_if_ready()
	var victim := OnWorkState.opponent(attacker)
	# PLAYER 先攻、BOT 后攻，两种座位分别覆盖两条结束位置。
	room.state.draw_first = OnWorkState.PLAYER
	room.phase.reset_for_round()
	var recipe: Array = [room.state.add_card(attacker, "heigongguan")["uid"]]
	recipe.append_array(room.state._loose_unit_uids(attacker, OnWorkCardDB.RES_CASH).slice(0, 4))
	if not need(room.state.create_combo(attacker, recipe).get("ok", false), "致胜测试的攻击组成立：%s" % attacker):
		return
	# 对手只余一个散用户，攻击结束仍留有弹药；不能靠耗尽分支收尾。
	var users := room.state._loose_unit_uids(victim, OnWorkCardDB.RES_USER)
	for uid in users.slice(1): room.state.remove_card(victim, uid)
	for seat in room.state.action_order():
		room.handle_intent(int(room.occupants[seat]), OnWorkIntent.action_done(seat))
	if not need(room.phase.phase == OnWorkPhaseMachine.ATTACK and room.phase.actor == attacker, "房间进入攻击回合"):
		return
	var local := OnWorkState.new()
	OnWorkStateCodec.restore(local, room.snapshot())
	var local_applier := OnWorkIntentApply.new(local)
	local_applier.pools_restore(room.applier.pools_snapshot())
	var client := NetTransport.new()
	client._on_text(Protocol.encode(room.seated_msg(attacker)))
	var target: Dictionary = {}
	for candidate in room.applier.affordable_targets(attacker):
		if candidate["res"] == OnWorkCardDB.RES_USER:
			target = candidate
			break
	if not need(not target.is_empty(), "能选中最后一个用户"):
		return
	var intent := OnWorkIntent.apply_attack(attacker, target)
	local_applier.apply(intent, attacker)
	local_applier.apply(OnWorkIntent.finalize())
	var messages := room.handle_intent(int(room.occupants[attacker]), intent)
	var operations: Array = []
	for item in messages:
		var message: Dictionary = item["msg"]
		if message["t"] == Protocol.APPLIED:
			operations.append(message["result"]["op"])
		client._on_text(Protocol.encode(message))
	check(room.state.winner == attacker and room.phase.phase == OnWorkPhaseMachine.OVER, "致胜攻击立即确定胜者")
	check(operations == [OnWorkIntent.OP_ATTACK, OnWorkIntent.OP_FINALIZE], "终局只发攻击与收尾，不产出、不抽下一回合")
	check(OnWorkStateCodec.state_hash(room.state) == OnWorkStateCodec.state_hash(local), "联网终态与本地攻击后收尾一致")
	check(room.state.combos.is_empty(), "终局组合清空")
	var locked := false
	for seat in room.state.players:
		for card in room.state.players[seat]["cards"]:
			locked = locked or card["locked"]
	check(not locked, "终局卡牌解锁")
	# 未修复时队列为空；先验队列避免回归本身消耗完整网络超时窗口。
	if need(client._inbox.size() == 1, "客户端有可消费的 FINALIZE，胜负动画不会等待超时"):
		var result := await client.finalize()
		check(result.get("ok", false), "客户端正常取回收尾结果")
		check(OnWorkStateCodec.state_hash(client.state()) == OnWorkStateCodec.state_hash(room.state), "收尾后客户端与权威状态一致")
	var recovery := client.recovery_checkpoint()
	check(OnWorkStateCodec.canon_hash(recovery) == OnWorkStateCodec.canon_hash(room.recovery_checkpoint()), "终局检查点包含完整收尾与最终序号")
