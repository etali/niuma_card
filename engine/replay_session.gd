# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 单步回放只通过原裁决器执行，不运行BOT。校验失败时保留上一个完整步骤。
const TableSnapshot = preload("res://scenes/table_snapshot.gd")
const Regions = preload("res://scenes/table_regions.gd")

var view: Dictionary = {}
var market_indices: Array = []
var market_count := 0
var record: Tape
var state: GameState
var applier: IntentApply
var cursor := 0
var action_cursor := 0
var action_groups: Array = []
var phase := PhaseMachine.ACTION
var actor := GameState.PLAYER
var path := ""
var error := ""

static func load_path(file_path: String) -> Dictionary:
	var loaded := Tape.load_from(file_path)
	if not loaded.get("ok", false):
		return loaded
	var tape: Tape = loaded["tape"]
	if (not tape.configuration.is_empty() and not Tape.RecordingConfig.matches(tape.configuration)) \
		or (tape.table != "" and tape.table != StateCodec.table_hash()):
		return {"ok": false, "reason": "卡牌规则不一致，不能载入"}
	if tape.table == "" and tape.configuration.is_empty():
		return {"ok": false, "reason": "录像缺少卡牌规则校验信息，不能载入"}
	if tape.meta.get("my_seat", GameState.PLAYER) not in [GameState.PLAYER, GameState.BOT]:
		return {"ok": false, "reason": "录像的玩家座位无效"}
	var issue := _validate_snapshot(tape)
	if issue != "":
		return {"ok": false, "reason": issue}
	if not TableSnapshot.valid(tape.head_view):
		return {"ok": false, "reason": "录像的牌桌位置数据损坏"}
	for entry in tape.steps:
		if not _valid_gesture(entry.get("gesture", {})):
			return {"ok": false, "reason": "录像的拖牌轨迹损坏"}
		if not TableSnapshot.valid(entry.get("view", {})) or not TableSnapshot.valid(entry.get("before_view", {})):
			return {"ok": false, "reason": "录像的牌桌位置数据损坏"}
		if entry.get("kind", "") == "snapshot":
			var saved := tape.head
			tape.head = entry["snapshot"]
			var invalid := _validate_snapshot(tape)
			tape.head = saved
			if invalid != "":
				return {"ok": false, "reason": invalid}
	var session = new()
	session.record = tape
	session.path = file_path
	var verified: Dictionary = session._build_action_groups()
	if not verified["ok"]:
		return {"ok": false, "reason": "录像无法复现：" + Tape.verdict(verified)}
	session.rewind()
	return {"ok": true, "session": session}

static func _validate_snapshot(tape: Tape) -> String:
	var issue := StateCodec.snapshot_issue(tape.head)
	if issue != "": return issue
	issue = StateCodec.pools_issue(tape.head_pools)
	if issue != "": return issue
	# 网络等候房允许空桌；交互录像必须已经有双方的牌。
	if tape.head["players"].is_empty(): return "录像缺少双方卡牌。"
	return ""

## 从已经校验的裁决结果识别攻击批次。旧录像只有意图，没有 result / batch，
## 仍可由原引擎逐条重放恢复；不按卡名或资源猜测组合，也不改写录像。
func _build_action_groups() -> Dictionary:
	action_groups.clear()
	return Tape.replay(record, -1, _index_action)

func _index_action(index: int, result: Dictionary) -> void:
	var key := _attack_action_key(result)
	if key != "" and not action_groups.is_empty() and action_groups[-1].get("attack_key", "") == key:
		action_groups[-1]["end"] = index + 1
	else:
		action_groups.append({"start": index, "end": index + 1, "attack_key": key})

func _attack_action_key(result: Dictionary) -> String:
	if str(result.get("op", "")) != Intent.OP_ATTACK:
		return ""
	var batch := GameState.target_batch(result.get("target", {}))
	if batch == "":
		return ""
	return "%s:%s" % [str(result.get("seat", "")), batch]

func action_count() -> int:
	return action_groups.size()

func _sync_action_cursor() -> void:
	action_cursor = 0
	for group in action_groups:
		if cursor >= int(group["end"]):
			action_cursor += 1
		else:
			break

func rewind() -> void:
	var initial := Tape.replay(record, 0)
	state = initial["state"]
	applier = initial["applier"]
	cursor = 0
	action_cursor = 0
	error = ""
	view = record.head_view.duplicate(true)
	market_count = maxi(int(CardDB.game_rules()["market_size"]), state.market.size())
	market_indices = range(state.market.size())
	actor = state.action_first()
	phase = PhaseMachine.OVER if state.winner != "" else PhaseMachine.ACTION
	for who in [GameState.PLAYER, GameState.BOT]:
		if not applier.pool_empty(who):
			phase = PhaseMachine.ATTACK
			actor = who
			break
	if not view.is_empty():
		phase = str(view.get("phase", phase))
		actor = str(view.get("actor", actor))

func advance() -> Dictionary:
	if cursor >= record.size() or error != "":
		return {"ok": false, "reason": "录像已结束。" if error == "" else error}
	var before_state := GameState.new()
	StateCodec.restore(before_state, StateCodec.snapshot(state))
	var next_state := GameState.new()
	StateCodec.restore(next_state, StateCodec.snapshot(state))
	var next_applier := IntentApply.new(next_state)
	next_applier.pools_restore(applier.pools_snapshot())
	var entry: Dictionary = record.steps[cursor]
	var intent: Dictionary = entry["intent"]
	var result := Tape.apply_entry(next_applier, entry)
	if not result.get("ok", false):
		error = "第 %d 步无法执行：%s" % [cursor + 1, result.get("reason", "")]
		return {"ok": false, "reason": error}
	if entry.get("hash", "") != "" and record.recorded_state_hash(next_state) != entry["hash"]:
		error = "第 %d 步与录制结果不一致，已停止。" % (cursor + 1)
		return {"ok": false, "reason": error}
	if intent["op"] == Intent.OP_BUY:
		var index := int(result.get("market_idx", intent.get("market_idx", -1)))
		if index >= 0 and index < market_indices.size():
			market_indices.remove_at(index)
	elif intent["op"] == Intent.OP_NEXT_ROUND:
		market_count = maxi(int(CardDB.game_rules()["market_size"]), next_state.market.size())
		market_indices = range(next_state.market.size())
	state = next_state
	applier = next_applier
	cursor += 1
	_sync_action_cursor()
	view = entry.get("view", {}).duplicate(true)
	actor = str(intent.get("seat", actor))
	match str(intent["op"]):
		Protocol.RECOVERY_STEP:
			# 恢复是已验证的权威快照，不重新提交任何玩家意图。
			view = {} # 旧演出可能还停在上一回合，重建时按权威快照摆牌。
			phase = str(result["phase"])
			actor = str(result["actor"])
			market_count = state.market.size()
			market_indices = range(market_count)
		"layout":
			phase = str(view.get("phase", phase))
			actor = str(view.get("actor", actor))
		Intent.OP_ARM, Intent.OP_ATTACK, Intent.OP_ATTACK_DONE:
			phase = PhaseMachine.ATTACK
		Intent.OP_PRODUCE, Intent.OP_FINALIZE:
			phase = PhaseMachine.SETTLING
		Intent.OP_NEXT_ROUND:
			phase = PhaseMachine.ACTION
			actor = state.action_first()
		Intent.OP_ACTION_DONE:
			phase = PhaseMachine.ACTION
			actor = GameState.opponent(str(intent["seat"]))
		_:
			phase = PhaseMachine.ACTION
	if state.winner != "":
		phase = PhaseMachine.OVER
	return {"ok": true, "result": result, "intent": intent, "entry": entry,
		"before_state": before_state, "state": next_state, "applier": next_applier}

func advance_action() -> Dictionary:
	if action_groups.is_empty():
		var verified := _build_action_groups()
		if not verified["ok"]:
			error = "录像无法复现：" + Tape.verdict(verified)
	if action_cursor >= action_groups.size() or error != "":
		return {"ok": false, "reason": "录像已结束。" if error == "" else error}
	var group: Dictionary = action_groups[action_cursor]
	var frames: Array = []
	while cursor < int(group["end"]):
		var frame := advance()
		if not frame.get("ok", false):
			return frame
		frames.append(frame)
	var last: Dictionary = frames.back()
	return {"ok": true, "result": last["result"], "intent": last["intent"], "entry": last["entry"],
		"before_state": frames[0]["before_state"], "state": last["state"],
		"frames": frames, "group_size": frames.size()}

func caption(intent: Dictionary = {}, grouped_size := 1) -> String:
	var progress := "录像行动 %d / %d" % [action_cursor, action_count()]
	if action_cursor == action_count():
		progress += " · 播放完毕"
	if not intent.is_empty():
		var labels := {
			Intent.OP_BUY: "购买卡牌", Intent.OP_PAWN: "典当卡牌", Intent.OP_COMBO: "编成组合",
			Intent.OP_ACTION_DONE: "完成行动", Intent.OP_ARM: "准备攻击", Intent.OP_ATTACK: "发动攻击",
			Intent.OP_ATTACK_DONE: "结束攻击", Intent.OP_PRODUCE: "组合结算", Intent.OP_FINALIZE: "回合结算",
			Intent.OP_NEXT_ROUND: "进入新回合", Intent.OP_RESIGN: "认输", "layout": "移动、拆分或收拢卡牌",
			Protocol.RECOVERY_STEP: "恢复已确认的对局进度", }
		var seat := str(intent.get("seat", ""))
		var action_label := str(labels.get(intent["op"], ""))
		if grouped_size > 1 and intent["op"] == Intent.OP_ATTACK:
			action_label = "同一摞攻击（%d 次扣减）" % grouped_size
		progress += " · " + ("玩家方" if seat == GameState.PLAYER else ("对手方" if seat == GameState.BOT else "")) + action_label
	return progress

func seek(step: int) -> Dictionary:
	if step < 0 or step > record.size():
		return {"ok": false, "reason": "录像步骤超出范围"}
	if step == cursor:
		return {"ok": true, "changed": false}
	# 跳步在独立会话中重放；中途校验失败时，不发布部分结果覆盖当前牌桌。
	var target = new()
	target.record = record
	target.action_groups = action_groups
	target.rewind()
	for i in step:
		var advanced: Dictionary = target.advance()
		if not advanced.get("ok", false):
			return advanced
	state = target.state
	applier = target.applier
	cursor = target.cursor
	action_cursor = target.action_cursor
	view = target.view
	market_indices = target.market_indices
	market_count = target.market_count
	phase = target.phase
	actor = target.actor
	error = ""
	return {"ok": true, "changed": true}

## 界面的“步”与前进、后退共用行动组：同一摞连续攻击只占一步，0 表示初始状态。
func seek_action(step: Variant) -> Dictionary:
	if not Intent.valid_integer(step, 0) or step > action_count():
		return {"ok": false, "reason": "请输入 0～%d 范围内的整数行动步数" % action_count()}
	var raw_step := 0 if int(step) == 0 else int(action_groups[int(step) - 1]["end"])
	return seek(raw_step)

func previous() -> Dictionary:
	if cursor <= 0:
		return {"ok": false, "reason": "已经是录像起点"}
	return seek(cursor - 1)

func previous_action() -> Dictionary:
	if action_cursor <= 0:
		return {"ok": false, "reason": "已经是录像起点"}
	var group: Dictionary = action_groups[action_cursor - 1]
	return seek(int(group["start"]))

func market_position(index: int, drawer: bool) -> Vector3:
	var positions: Array = view.get("market", [])
	if positions.size() == state.market.size() and index < positions.size():
		var p: Array = positions[index]
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	var slot := int(market_indices[index]) if index < market_indices.size() else index
	return Regions.market_slot(slot, market_count, drawer)

static func _valid_gesture(gesture: Variant) -> bool:
	if not gesture is Dictionary or not gesture.get("uids", []) is Array or not gesture.get("points", []) is Array:
		return false
	for uid in gesture.get("uids", []):
		if not uid is int and not uid is float:
			return false
	for point in gesture.get("points", []):
		if not point is Dictionary or not point.get("at") is Array or point["at"].size() != 3:
			return false
		for coordinate in point["at"]:
			if not coordinate is int and not coordinate is float:
				return false
		if not point.get("ms") is int and not point.get("ms") is float:
			return false
	return true
