# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Replay = preload("res://engine/on_work_replay_session.gd")
var _path := "user://replay-player-test.json"

class PlainReplay:
	extends "res://scenes/on_work_main.gd"
	func _setup_drawer_window() -> void:
		pass

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var source := _record()
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(source.to_dict()))
	f.close()
	var loaded := Replay.load_path(_path)
	if not need(loaded.get("ok", false), "读取真实保存的录像"):
		finish()
		return
	var session: RefCounted = loaded["session"]
	check(session.cursor == 0 and OnWorkStateCodec.state_hash(session.state) == OnWorkStateCodec.state_hash(OnWorkTape.replay(source, 0)["state"]), "读入时仅显示开局快照")
	var grouped_real: bool = session.action_groups.any(func(group): return int(group["end"]) - int(group["start"]) > 1)
	check(grouped_real, "真实录像中同一组合连续攻击合并为一个行动")
	for loaded_entry in session.record.steps:
		if loaded_entry.get("intent", {}).get("op", "") == OnWorkIntent.OP_ATTACK:
			check(loaded_entry.get("result", {}).get("removed", []).all(func(uid): return uid is int), "读入录像后的攻击UID保持整数，动画能找到被移除的卡")
	var grouped_session := Replay.new()
	var indexed_results := [
		{"op": OnWorkIntent.OP_ARM, "seat": OnWorkState.PLAYER},
		{"op": OnWorkIntent.OP_ATTACK, "seat": OnWorkState.PLAYER, "target": {"batch": "combo_0"}},
		{"op": OnWorkIntent.OP_ATTACK, "seat": OnWorkState.PLAYER, "target": {"batch": "combo_0"}},
		{"op": OnWorkIntent.OP_ATTACK, "seat": OnWorkState.PLAYER, "target": {"batch": "combo_1"}},
		{"op": OnWorkIntent.OP_ATTACK_DONE, "seat": OnWorkState.PLAYER},
		{"op": OnWorkIntent.OP_ATTACK, "seat": OnWorkState.BOT, "target": {"batch": "combo_1"}},
	]
	for index in indexed_results.size():
		grouped_session._index_action(index, indexed_results[index])
	check(grouped_session.action_count() == 5 and grouped_session.action_groups[1]["end"] - grouped_session.action_groups[1]["start"] == 2,
		"同摞连续攻击合并，换目标、结束攻击或换攻击方时独立计步")
	var first_frame: Dictionary = {}
	var first_frame_before := ""
	var first_frame_after := ""
	var before_states_match := true
	for step in source.size():
		var prior_hash := OnWorkStateCodec.state_hash(session.state)
		var result: Dictionary = session.advance()
		var expected := OnWorkTape.replay(source, step + 1)
		check(result.get("ok", false) and session.cursor == step + 1, "每次执行且仅执行一步：%d" % (step + 1))
		before_states_match = before_states_match and OnWorkStateCodec.state_hash(result["before_state"]) == prior_hash
		check(OnWorkStateCodec.state_hash(session.state) == OnWorkStateCodec.state_hash(expected["state"])
			and session.applier.pools_snapshot() == expected["applier"].pools_snapshot(), "第%d步资源、组合、攻击点与原录像一致" % (step + 1))
		if step == 0:
			first_frame = result
			first_frame_before = prior_hash
			first_frame_after = OnWorkStateCodec.state_hash(result["state"])
	check(before_states_match, "每步演出保留推进前的状态")
	check(OnWorkStateCodec.state_hash(first_frame["before_state"]) == first_frame_before
		and OnWorkStateCodec.state_hash(first_frame["state"]) == first_frame_after, "后续播放不修改已返回帧的前后状态")
	var final_hash := OnWorkStateCodec.state_hash(session.state)
	check(not session.advance()["ok"] and OnWorkStateCodec.state_hash(session.state) == final_hash, "播放完毕后继续点击不改变末态")
	_check_seek_actions(session, source)
	session.rewind()
	check(session.cursor == 0, "重播回到快照起点")
	# 损坏的单步不能污染上一个完整步骤。
	session.record.steps[0]["hash"] = "invalid"
	var before := OnWorkStateCodec.state_hash(session.state)
	check(not session.advance()["ok"] and session.cursor == 0 and OnWorkStateCodec.state_hash(session.state) == before,
		"回放不一致时停在上一步，不发布错误状态")
	for bad in [{}, {"version": OnWorkTape.VERSION, "head": {}, "steps": "broken"},
		{"version": OnWorkTape.VERSION, "head": {"players": []}, "steps": []}]:
		var file := FileAccess.open("user://replay-player-bad.json", FileAccess.WRITE)
		file.store_string(JSON.stringify(bad))
		file.close()
		check(not Replay.load_path("user://replay-player-bad.json")["ok"], "错误录像被明确拒绝")
	var mismatch := source.to_dict().duplicate(true)
	mismatch["table"] = "old-table"
	var file := FileAccess.open("user://replay-player-bad.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(mismatch))
	file.close()
	check(not Replay.load_path("user://replay-player-bad.json")["ok"], "卡表不一致不进入回放")

	paused = false
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/on_work_main.tscn").instantiate()
	main.force_drawer_layout = true
	main.replay_session = Replay.load_path(_path)["session"]
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	await settle()
	var default_size := root.size
	_check_navigation_layout(main, "默认抽屉")
	root.size = Vector2i(1280, 900)
	main.drawer_presentation.relayout()
	await settle()
	_check_navigation_layout(main, "1280宽抽屉")
	root.size = default_size
	main.drawer_presentation.relayout()
	await settle()
	check(main.btn_pass.text == "录像下一步" and not main.btn_pass.disabled, "读入后主按钮为录像下一步")
	check(not main.tape.recording() and not main._thinking and main.board.input_locked, "回放不录制、不运行BOT，禁止改动牌桌")
	var popup: PopupMenu = main.drawer_presentation._menu.get_popup()
	check(popup.get_item_text(popup.get_item_index(8)) == "读入录像", "选项菜单提供读入录像入口")
	var same: OnWorkState = main.state
	var bad_load: Dictionary = main._load_replay("user://replay-player-missing.json")
	check(not bad_load["ok"] and main.state == same, "读取失败保持当前牌桌")
	var action_total: int = main.replay_session.action_count()
	await _check_seek_controls(main, source)
	for action_index in action_total:
		var group: Dictionary = main.replay_session.action_groups[action_index]
		var last_raw: int = int(group["end"]) - 1
		if action_index == 0:
			await _click(main.btn_pass)
		else:
			main.btn_pass.pressed.emit()
		if action_index == 0:
			check(main._replay_busy and main._replay_jump_button.disabled and not main._replay_step_input.editable,
				"动画播放期间跳转按钮和步数输入禁用")
			var before_busy: int = main.replay_session.cursor
			main._replay_step_input.text = str(action_total)
			main._replay_jump_button.pressed.emit()
			main._replay_step_input.text_submitted.emit(str(action_total))
			check(main.replay_session.cursor == before_busy,
				"播放正忙时即使触发跳转信号，也不接受过期跳步请求")
		await _await_step(main)
		check(main.replay_session.cursor == last_raw + 1 and OnWorkStateCodec.state_hash(main.state) == source.steps[last_raw]["hash"], "真实按钮逐行动复现第%d个行动" % (action_index + 1))
		check(main._replay_step_input.text == str(action_index + 1) and main._replay_step_input.editable
				and not main._replay_jump_button.disabled, "动画完成后步数同步且跳转恢复可用")
		check(main.entities.size() == main.state.players[main.my_seat]["cards"].size() + main.state.players[main.foe_seat]["cards"].size(), "每个行动后牌桌实体数量匹配录像状态")
	check(main.btn_pass.disabled and main.btn_pass.text == "录像下一步" and "播放完毕" in main.lbl_msg.text, "末步明确提示播放完毕并禁用下一步")
	check(main.game_over_panel == null, "录像终局不弹出真实对局重开流程")
	check(not (await main._try_buy(0)).get("ok", false), "回放期间不能购买")
	# 后退逐步恢复状态；再次前进仍走正式动画，没有跳到录像结尾。
	for action_index in range(action_total - 1, -1, -1):
		main._replay_previous_button.pressed.emit()
		await settle()
		var start_raw: int = int(main.replay_session.action_groups[action_index]["start"])
		check(main.replay_session.cursor == start_raw and OnWorkStateCodec.state_hash(main.state) == OnWorkStateCodec.state_hash(OnWorkTape.replay(source, start_raw)["state"]), "上一步恢复第%d个行动" % action_index)
	check(main._replay_previous_button.disabled and not main.btn_pass.disabled, "录像起点禁止后退但允许重新前进")
	main.drawer_window.set_pinned(false)
	# 真实退出按钮恢复普通对局模式。
	main.btn_resign.pressed.emit()
	await process_frame
	await process_frame
	var normal: Node = null
	for child in root.get_children():
		if child is Node3D and child.get("board") != null:
			normal = child
	check(normal != null and normal.replay_session == null and normal.btn_pass.text != "录像下一步", "退出录像后正常开新对局")
	check(normal != null and not normal.drawer_window.is_pinned(), "退出录像也保留未钉住状态")
	if normal:
		_booted = normal
		normal.drawer_presentation._menu.get_popup().id_pressed.emit(8)
		await process_frame
		check(normal._replay_picker != null and normal._replay_picker.visible,
			"点击选项读入录像打开文件选择器")
		normal._replay_picker._path_edit.text = ProjectSettings.globalize_path(_path)
		await _click(normal._replay_picker.find_child("ReplayLoad", true, false))
		await process_frame
		await process_frame
		for child in root.get_children():
			if child is Node3D and child.get("board") != null:
				check(child.replay_session != null and child.btn_pass.text == "录像下一步", "切换后的场景从录像首步等待")
				check(not child.drawer_window.is_pinned(), "通过读入录像按钮进入后不自动钉住")
				child.queue_free()
	await process_frame
	await _check_plain_layout()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://replay-player-bad.json"))
	finish()

func _check_navigation_layout(main: Node, label: String) -> void:
	var bounds := Rect2(Vector2.ZERO, Vector2(root.size))
	var controls: Array[Control] = [main.btn_resign, main._replay_previous_button, main.btn_pass,
		main._replay_step_input, main._replay_jump_button, main._replay_step_range]
	var inside := true
	var separate := true
	for i in controls.size():
		var rect := controls[i].get_global_rect()
		inside = inside and controls[i].is_visible_in_tree() and bounds.grow(1).encloses(rect)
		for j in range(i + 1, controls.size()):
			separate = separate and not rect.intersects(controls[j].get_global_rect())
		if main.drawer_presentation:
			inside = inside and main.drawer_presentation._footer.get_global_rect().grow(1).encloses(rect)
		elif is_instance_valid(main.hud_status_panel):
			separate = separate and not rect.intersects(main.hud_status_panel.get_global_rect())
	check(inside, label + "退出、前后步进、跳转输入和范围提示完整可见且未出屏")
	check(separate, label + "全部录像控件互不重叠，普通消息栏也未被覆盖")

func _check_plain_layout() -> void:
	root.size = Vector2i(1280, 900)
	var plain := PlainReplay.new()
	plain.replay_session = Replay.load_path(_path)["session"]
	root.add_child(plain)
	_booted = plain
	await settle()
	check(plain.drawer_presentation == null, "普通牌桌布局独立验证")
	_check_navigation_layout(plain, "1280宽普通牌桌")
	root.size = Vector2i(1100, 800)
	await settle()
	_check_navigation_layout(plain, "缩放后普通牌桌")
	plain.queue_free()
	await process_frame

func _check_seek_actions(session: RefCounted, source: OnWorkTape) -> void:
	var total: int = session.action_count()
	for step in [total / 2, total, 0, 1]:
		var result: Dictionary = session.seek_action(step)
		var raw_step := 0 if int(step) == 0 else int(session.action_groups[int(step) - 1]["end"])
		var expected := OnWorkTape.replay(source, raw_step)
		check(result.get("ok", false) and session.action_cursor == int(step) and session.cursor == raw_step
				and OnWorkStateCodec.state_hash(session.state) == OnWorkStateCodec.state_hash(expected["state"])
				and session.applier.pools_snapshot() == expected["applier"].pools_snapshot(),
			"按显示行动步跳至 %d，资源/组合/攻击点与顺序重放一致" % int(step))
	var state: OnWorkState = session.state
	var current: int = session.action_cursor
	var repeat: Dictionary = session.seek_action(current)
	check(repeat.get("ok", false) and not repeat.get("changed", true) and session.state == state,
		"重复跳当前步不重算也不替换当前局面")
	for step in [-1, total + 1, 0.5, NAN, INF, "1", true]:
		check(not session.seek_action(step).get("ok", false) and session.state == state
				and session.action_cursor == current, "无效行动步不改变会话：%s" % str(step))
	check(not session.seek(-1).get("ok", false) and not session.seek(source.size() + 1).get("ok", false)
			and session.state == state, "原始步骤越界也不会静默夹取后改变局面")
	var original_hash: String = session.record.steps[0]["hash"]
	session.record.steps[0]["hash"] = "corrupt-seek"
	check(not session.seek_action(total).get("ok", false) and session.state == state
			and session.action_cursor == current and session.error == "", "跳转中途校验失败保留原完整步骤")
	session.record.steps[0]["hash"] = original_hash

func _check_seek_controls(main: Node, source: OnWorkTape) -> void:
	var total: int = main.replay_session.action_count()
	check(main._replay_step_range.text == "行动步（0～%d）" % total
			and main._replay_step_input.text == "0", "输入显示当前步并明确标注 0～总行动步数")
	for step in [total / 2, total, 0]:
		main._replay_step_input.text = str(step)
		if int(step) == total:
			main._replay_step_input.text_submitted.emit(str(step))
		else:
			main._replay_jump_button.pressed.emit()
		await settle()
		var raw_step := 0 if int(step) == 0 else int(main.replay_session.action_groups[int(step) - 1]["end"])
		var expected := OnWorkTape.replay(source, raw_step)
		check(main.replay_session.action_cursor == int(step) and main.replay_session.cursor == raw_step
				and OnWorkStateCodec.state_hash(main.state) == OnWorkStateCodec.state_hash(expected["state"])
				and main.pipe.applier().pools_snapshot() == expected["applier"].pools_snapshot(),
			"按钮/回车直接跳到 %d，牌桌资源与攻击点正确" % int(step))
		check(main.entities.size() == main.state.players[main.my_seat]["cards"].size()
				+ main.state.players[main.foe_seat]["cards"].size()
				and main.phase == main.replay_session.phase and main._actor == main.replay_session.actor,
			"跳转后可见卡牌、阶段与行动方一致")
		check(main._replay_step_input.text == str(step) and ("行动 %d / %d" % [step, total]) in main.lbl_round.text,
			"输入步数与标题显示采用同一行动计数")
	var state: OnWorkState = main.state
	var entities: Dictionary = main.entities.duplicate()
	for invalid in ["", "-1", "1.5", "abc", str(total + 1), "999999999999999999999999999999999999999"]:
		main._replay_step_input.text = invalid
		main._replay_jump_button.pressed.emit()
		check(main.state == state and main.entities == entities and main.replay_session.action_cursor == 0,
			"非法跳步输入保留原牌桌：%s" % invalid)
	main._replay_step_input.text = "0"
	main._replay_jump_button.pressed.emit()
	check(main.state == state and main.entities == entities, "重复跳当前步不重建可见牌桌")

func _record() -> OnWorkTape:
	var state := OnWorkState.new()
	state.set_seed(9271)
	state.new_game()
	state.market = ["yunketang"]
	var weapon := state.add_card(OnWorkState.BOT, "butie")
	var ap := OnWorkIntentApply.new(state)
	var record := OnWorkTape.new()
	record.start(ap)
	var buy := ap.apply(OnWorkIntent.buy(OnWorkState.PLAYER, 0), OnWorkState.PLAYER)
	var uids: Array = [buy["new_uid"]]
	var need := int(OnWorkCardDB.get_def("yunketang")["recipe_n"])
	for card in state.players[OnWorkState.PLAYER]["cards"]:
		if card["def_id"] == OnWorkCardDB.unit_id(OnWorkCardDB.RES_USER) and uids.size() <= need:
			uids.append(card["uid"])
	ap.apply(OnWorkIntent.create_combo(OnWorkState.PLAYER, uids), OnWorkState.PLAYER)
	ap.apply(OnWorkIntent.action_done(OnWorkState.PLAYER), OnWorkState.PLAYER)
	var attack_uids: Array = [weapon["uid"]]
	for card in state.players[OnWorkState.BOT]["cards"]:
		if card["def_id"] == OnWorkCardDB.unit_id(OnWorkCardDB.RES_CASH) and attack_uids.size() <= int(OnWorkCardDB.get_def("butie")["recipe_n"]):
			attack_uids.append(card["uid"])
	ap.apply(OnWorkIntent.create_combo(OnWorkState.BOT, attack_uids), OnWorkState.BOT)
	ap.apply(OnWorkIntent.action_done(OnWorkState.BOT), OnWorkState.BOT)
	ap.apply(OnWorkIntent.arm_attacks(OnWorkState.PLAYER))
	ap.apply(OnWorkIntent.attack_done(OnWorkState.PLAYER), OnWorkState.PLAYER)
	ap.apply(OnWorkIntent.arm_attacks(OnWorkState.BOT))
	var targets: Array = ap.affordable_targets(OnWorkState.BOT)
	# 攻击闲置用户，后续产出仍成立：同一录像覆盖撕牌和新增资源动画。
	var idle_targets := targets.filter(func(target): return target["uids"].all(func(uid): return not uids.has(uid)))
	if not idle_targets.is_empty():
		var first_attack: Dictionary = ap.apply(OnWorkIntent.apply_attack(OnWorkState.BOT, idle_targets[0]), OnWorkState.BOT)
		# 同一组合的第二张目标仍在同一 attack batch：录像保留两次逐击状态，回放界面应合并成一个行动。
		var batch := str(first_attack.get("target", {}).get("batch", ""))
		if batch != "":
			for target in ap.affordable_targets(OnWorkState.BOT):
				if str(target.get("batch", "")) == batch:
					ap.apply(OnWorkIntent.apply_attack(OnWorkState.BOT, target), OnWorkState.BOT)
					break
	ap.apply(OnWorkIntent.attack_done(OnWorkState.BOT), OnWorkState.BOT)
	ap.apply(OnWorkIntent.produce(0))
	ap.apply(OnWorkIntent.finalize())
	ap.apply(OnWorkIntent.next_round())
	ap.apply(OnWorkIntent.resign(OnWorkState.BOT), OnWorkState.BOT)
	record.stop()
	return record

func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.pressed = pressed
		root.push_input(event)
		await process_frame

func _await_step(main: Node) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while main._replay_busy and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not main._replay_busy, "一步完整动画在期限内结束")
