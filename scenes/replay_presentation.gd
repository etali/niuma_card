# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

## 录像前进使用正式对局的表现入口；后退恢复已校验的步骤和精确牌桌快照。
const Snapshot = preload("res://scenes/table_snapshot.gd")
const Motion = preload("res://scenes/ui_motion.gd")
var host: Node

func bind(main: Node) -> void:
	host = main

func play_group(frames: Array) -> void:
	# 录像中的同摞连续意图也是一次整批撕纸，不把逐条裁决变成 N 次动作。
	if frames.size() > 1 and frames.all(func(frame): return frame.intent.op == Intent.OP_ATTACK):
		var merged: Dictionary = frames.back().duplicate()
		merged.result = frames.front().result.duplicate(true)
		merged.result.removed = []
		for frame in frames:
			merged.result.removed.append_array(frame.result.get("removed", []))
		host.state = merged.state
		host.pipe = LocalTransport.new(merged.applier)
		host._update_hud()
		await play(merged, frames.front().before_state)
		return
	for index in frames.size():
		var frame: Dictionary = frames[index]
		host.state = frame["state"]
		host.pipe = LocalTransport.new(frame["applier"])
		# 索引已走到整段末尾，但屏幕必须显示正在演的这一击，不能先跳到最终金额。
		if host.drawer_presentation:
			host.drawer_presentation.compact_header_resources()
		await play(frame, frame["before_state"], index == frames.size() - 1)

func play(advanced: Dictionary, before: GameState, finish_action := true) -> void:
	var result: Dictionary = advanced["result"]
	var intent: Dictionary = advanced["intent"]
	var entry: Dictionary = advanced.get("entry", {})
	var op := str(intent["op"])
	var seat := str(intent.get("seat", result.get("seat", "")))
	await _play_gesture(entry.get("gesture", {}))
	match op:
		Protocol.RECOVERY_STEP:
			# 检查点可能跳过尚未送达的结算包；旧动画捕获的 view 不能覆盖权威状态。
			host._sync_entities()
			if result["phase"] == PhaseMachine.ACTION:
				host._respawn_market()
			else:
				host._clear_market()
		"layout":
			Snapshot.restore(host, entry.get("view", {}), true)
			host.sfx.play("card_drop")
		Intent.OP_BUY:
			if seat == host.my_seat:
				var index := int(result["market_idx"])
				if index < host.market_cards.size():
					host._table_actions.purchase(index, host.market_cards[index], result)
			else:
				host._render_foe_buy(result)
		Intent.OP_PAWN:
			if seat == host.my_seat:
				var cards: Array = []
				for uid in result.get("uids", []):
					if host.entities.has(int(uid)):
						cards.append(host.entities[int(uid)])
				host._table_actions.pawn(cards, result.get("uids", []))
			else:
				host._render_foe_pawn(result)
		Intent.OP_COMBO:
			if seat == host.my_seat:
				var cards: Array = []
				for uid in intent.get("uids", result.get("uids", [])):
					if host.entities.has(int(uid)):
						cards.append(host.entities[int(uid)])
				if not cards.is_empty():
					var at: Vector3 = host.board.rest_pos(cards[0])
					for card in cards:
						host.board._detach_from_group(card)
					var group: Dictionary = host.board.make_group(cards, true, false)
					host.board.groups.append(group)
					host.board._layout_group(group, at)
			else:
				host._render_foe_combo(result)
		Intent.OP_ARM:
			var paid: Array = []
			for record in before.players[seat]["cards"]:
				if host.state.find_card(seat, int(record["uid"])).is_empty():
					paid.append(int(record["uid"]))
			host._table_actions.pay_recipe(paid, host.layout.payment_spot(seat, CardDB.RES_CASH))
		Intent.OP_ATTACK:
			host._impact_once(host._target_center(result.get("target", {})), seat, str(result.get("target", {}).get("res", "")))
			await host._await_removed(result.get("removed", []), seat == host.foe_seat)
			if finish_action and seat == host.my_seat:
				# 与正式对局的攻击收尾一致：整摞撕完后收拢空层并刷新侧边张数。
				host.layout._layout_bot_zone()
		Intent.OP_PRODUCE:
			await host._resolve_combo_visual(int(result.get("combo_idx", intent.get("combo_idx", 0))), result)
		Intent.OP_NEXT_ROUND:
			host._respawn_market()
			host.layout._layout_bot_idle()
		Intent.OP_ACTION_DONE:
			host.sfx.play("confirm_turn")
		Intent.OP_FINALIZE, Intent.OP_ATTACK_DONE, Intent.OP_RESIGN:
			pass
	# 每步都等正在运行的真实Tween结束，防止下一次点击吞掉中间过程。
	await _wait_for_cards()
	if op not in ["layout", Protocol.RECOVERY_STEP] and not entry.get("view", {}).is_empty():
		Snapshot.restore(host, entry["view"], true)
		await _wait_for_cards()
	host.board.prune_groups()
	host._update_hud()

func _wait_for_cards() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		var busy: bool = host._card_motion.transferring()
		for card in host.board.cards:
			if not is_instance_valid(card):
				continue
			var tween: Variant = card.get_meta("fly_tw") if card.has_meta("fly_tw") else null
			if tween is Tween and tween.is_valid() and tween.is_running():
				busy = true
		for rec in host.board._move_tw.values():
			var tween: Tween = rec["tw"]
			if tween != null and tween.is_valid() and tween.is_running():
				busy = true
		busy = busy or host.layout.bot_moving()
		if not busy:
			break
		await get_tree().process_frame
	await host._tears_drained()

func _play_gesture(gesture: Dictionary) -> void:
	var cards: Array = []
	for uid in gesture.get("uids", []):
		if host.entities.has(int(uid)):
			cards.append(host.entities[int(uid)])
	if cards.is_empty() or gesture.get("points", []).is_empty():
		return
	host.sfx.play("card_pickup")
	var points: Array = gesture["points"]
	var start: Array = points[0]["at"]
	host._card_motion.drag_stack(cards, Vector3(start[0], start[1], start[2]))
	await _wait_for_cards()
	var previous_ms := int(points[0]["ms"])
	for point in points.slice(1):
		var position: Array = point["at"]
		var at := Vector3(position[0], position[1], position[2])
		var elapsed := clampf(float(int(point["ms"]) - previous_ms) / 1000.0, 0.016, 0.15)
		previous_ms = int(point["ms"])
		var origin: Vector3 = cards[0].position
		var tween := create_tween().set_parallel(true)
		for card in cards:
			tween.tween_property(card, "position", at + card.position - origin, elapsed)
		await tween.finished
