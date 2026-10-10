# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 暂借正式牌桌。原局实体离树保管，退出还原同一批对象、牌组、物理状态与信号。
## 不重建正式对局、不重放录像，也不创建第二个 Board、相机或 World3D。
const BOARD_SIGNALS := ["card_picked", "card_stacked", "card_dropped_table", "group_formed",
	"group_completed", "pile_toggled", "dropped_on_market", "dropped_on_pawn", "attack_clicked", "drag_broadcast"]
const BOARD_FIELDS := ["cards", "groups", "_ext_side", "_move_tw", "_desc", "_desc_panel", "_desc_edge",
	"input_locked", "attack_mode", "touch_mode", "view_gesture", "cancel_anim", "interaction_blocked", "hover_blocked",
	"hover_description_enabled", "player_min_z", "player_max_z", "table_bounds", "player_bounds",
	"screen_position_clamper", "process_mode", "_playable_bounds_pending"]
const MAIN_FIELDS := ["state", "pipe", "entities", "market_cards", "market_slots", "market_price_labels", "layout",
	"phase", "_actor", "foe_piles", "my_seat", "foe_seat", "_attack_hl", "_player_attack_busy"]
var _main: WeakRef
var _rules: Dictionary = {}
var _saved_main: Dictionary = {}
var _saved_board: Dictionary = {}
var _signals: Array = []
var _nodes: Array = []
var _buttons: Array = []
var _labels: Array = []
var _attack_panel_visible := false
var _visual_processes: Array = []
var _sfx_process_mode := Node.PROCESS_MODE_INHERIT
var active := false

func begin(main: Node) -> bool:
	if active or not main.can_begin_tutorial():
		return false
	_main = weakref(main)
	_rules = {"cards": CardDB.CARDS, "game": CardDB.GAME, "upgrade": CardDB.UPGRADE,
		"units": CardDB.UNITS, "sfx": CardDB.SFX, "sim": CardDB.SIM, "source": CardDB.loaded_from}
	for key in MAIN_FIELDS:
		_saved_main[key] = main.get(key)
	var board: Board = main.board
	board.cancel_pointer()
	board._set_hover_card(null)
	for key in BOARD_FIELDS:
		_saved_board[key] = board.get(key)
	for signal_name in BOARD_SIGNALS:
		for entry in board.get_signal_connection_list(signal_name):
			_signals.append({"signal": signal_name, "callable": entry["callable"], "flags": entry["flags"]})
			board.disconnect(signal_name, entry["callable"])
	# 先暂停正式协程，再离树保管实体；隐藏实体仍会挡射线，所以不能只hide。
	main.set_tutorial_active(true)
	_sfx_process_mode = main.sfx.process_mode
	main.sfx.process_mode = Node.PROCESS_MODE_ALWAYS
	for node in main.get_children():
		var script: Script = node.get_script()
		if script == null or script.resource_path not in ["res://scenes/table_lighting.gd", "res://scenes/table_surface.gd", "res://scenes/table_touch_input.gd"]:
			continue
		var visual := {"node": weakref(node), "process_mode": node.process_mode}
		if script.resource_path == "res://scenes/table_touch_input.gd":
			visual["touch_input"] = true
			# 菜单中进入课程时结束旧触点，教学继续使用原长按和双指控制器。
			node._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
		if script.resource_path == "res://scenes/table_surface.gd":
			visual["feedback"] = node._feedback
			visual["feedback_target"] = node._feedback_target
		_visual_processes.append(visual)
		node.process_mode = Node.PROCESS_MODE_ALWAYS
	for node in board.cards + main.market_price_labels + board.get_children():
		_stash(node)
	board.cards = []
	board.groups = []
	board._ext_side = {}
	board._move_tw = {}
	board._desc = null
	board._desc_panel = null
	board._desc_edge = null
	board._reset_click_track()
	board.process_mode = Node.PROCESS_MODE_ALWAYS
	board.hover_description_enabled = false
	main._tutorial_context = self
	for button in [main.btn_pass, main.btn_resign, main.btn_net, main.btn_save, main.drawer_presentation._menu]:
		_buttons.append({"node": weakref(button), "disabled": button.disabled, "text": button.text,
			"accessibility": button.accessibility_name, "connections": button.pressed.get_connections(),
			"tooltip": button.tooltip_text, "role": button.get_meta("ui_role") if button.has_meta("ui_role") else null})
		button.disabled = true
	for label in [main.lbl_round, main.lbl_player_res, main.lbl_bot_res, main.lbl_msg, main.lbl_attack, main.attack_pool_text, main.attack_target_text]:
		if not is_instance_valid(label): continue
		_labels.append({"node": weakref(label), "text": label.text, "tooltip": label.tooltip_text,
			"visible": label.visible, "minimum": label.custom_minimum_size, "base_minimum": label.get_meta("drawer_min_base") if label.has_meta("drawer_min_base") else null})
	_attack_panel_visible = main.attack_panel.visible
	if not CardDB.load_default():
		release()
		return false
	# 教学只借标准卡牌规则，音色/响度/音高继续沿用当前牌桌的声音配置。
	CardDB.SFX = _rules["sfx"]
	main._set_button(TutorialCatalog.ui("complete_action"), main._on_action_done)
	active = true
	# 仍是原来的物理空间；原牌已离树，只有教学牌能响应拾取与碰撞。
	PhysicsServer3D.set_active(true)
	return true

func _stash(node: Node) -> void:
	if not is_instance_valid(node) or node.get_parent() == null:
		return
	var item := {"node": node, "parent": node.get_parent(), "index": node.get_index()}
	if node is Node3D:
		item["transform"] = node.transform
	if node is RigidBody3D:
		item["physics"] = {"freeze": node.freeze, "sleeping": node.sleeping,
			"linear_velocity": node.linear_velocity, "angular_velocity": node.angular_velocity,
			"collision_layer": node.collision_layer, "collision_mask": node.collision_mask}
	_nodes.append(item)
	node.get_parent().remove_child(node)

func release(shutting_down := false) -> void:
	if _rules.is_empty():
		return
	var main: Object = _main.get_ref() if _main != null else null
	shutting_down = shutting_down or not is_instance_valid(main)
	if not shutting_down:
		shutting_down = main.is_queued_for_deletion() or not main.is_inside_tree() \
			or not is_instance_valid(main.board) or not main.board.is_inside_tree()
		if is_instance_valid(main._tutorial_arena):
			shutting_down = shutting_down or not main._tutorial_arena.is_inside_tree()
	if is_instance_valid(main) and is_instance_valid(main._tutorial_arena):
		main._tutorial_arena.release_table(shutting_down)
		main._tutorial_arena.queue_free()
		main._tutorial_arena = null
	CardDB.CARDS = _rules["cards"]
	CardDB.GAME = _rules["game"]
	CardDB.UPGRADE = _rules["upgrade"]
	CardDB.UNITS = _rules["units"]
	CardDB.SFX = _rules["sfx"]
	CardDB.SIM = _rules["sim"]
	CardDB.loaded_from = _rules["source"]
	_rules.clear()
	if shutting_down:
		# 应用退树时卡牌已不在物理世界；不再恢复牌桌或读取global_transform。
		# 归档原牌已离树，必须单独释放，否则不会随主场景销毁。
		if is_instance_valid(main):
			main._tutorial_context = null
			main._tutorial_active = false
		for item in _nodes:
			if is_instance_valid(item["node"]): item["node"].free()
		_nodes.clear()
		_signals.clear()
		_buttons.clear()
		_labels.clear()
		_visual_processes.clear()
		_saved_main.clear()
		_saved_board.clear()
		active = false
		return
	var board: Board = main.board
	# 清理教学产生的组标签/悬停说明，原标签仍在归档里。
	for child in board.get_children():
		board.remove_child(child)
		child.queue_free()
	for key in MAIN_FIELDS:
		main.set(key, _saved_main[key])
	for key in BOARD_FIELDS:
		board.set(key, _saved_board[key])
	for item in _nodes:
		var node: Node = item["node"]
		var parent: Node = item["parent"]
		if not is_instance_valid(node) or not is_instance_valid(parent): continue
		parent.add_child(node)
		parent.move_child(node, mini(int(item["index"]), parent.get_child_count() - 1))
		if node is Node3D: node.transform = item["transform"]
		if item.has("physics"):
			for key in item["physics"]: node.set(key, item["physics"][key])
	_nodes.clear()
	for entry in _signals:
		if entry["callable"].is_valid() and not board.is_connected(entry["signal"], entry["callable"]):
			board.connect(entry["signal"], entry["callable"], int(entry["flags"]))
	_signals.clear()
	for item in _buttons:
		var button: Object = item["node"].get_ref()
		if not is_instance_valid(button): continue
		for connection in button.pressed.get_connections(): button.pressed.disconnect(connection["callable"])
		for connection in item["connections"]:
			if connection["callable"].is_valid(): button.pressed.connect(connection["callable"], int(connection["flags"]))
		button.text = item["text"]
		button.accessibility_name = item["accessibility"]
		button.disabled = item["disabled"]
		button.tooltip_text = item["tooltip"]
		if item["role"] == null: button.remove_meta("ui_role")
		else: button.set_meta("ui_role", item["role"])
	_buttons.clear()
	main._tutorial_context = null
	active = false
	# 同一张牌桌沿用玩家当前镜头；进入、重试或退出课程都不自动移动视角。
	main._update_hud()
	main._refresh_attack_panel()
	for item in _labels:
		var label: Object = item["node"].get_ref()
		if not is_instance_valid(label): continue
		label.text = item["text"]
		label.tooltip_text = item["tooltip"]
		label.visible = item["visible"]
		label.custom_minimum_size = item["minimum"]
		if item["base_minimum"] == null: label.remove_meta("drawer_min_base")
		else: label.set_meta("drawer_min_base", item["base_minimum"])
	main.attack_panel.visible = _attack_panel_visible
	_labels.clear()
	# 阴影和托盘继续服务同一Board；退出当帧即切回原牌，而不是残留教学接触影。
	for item in _visual_processes:
		var node: Object = item["node"].get_ref()
		if not is_instance_valid(node): continue
		if item.has("feedback"):
			node._feedback = item["feedback"]
			node._feedback_target = item["feedback_target"]
		if item.get("touch_input", false):
			# 课程退出不能把教学卡的长按或双指状态带回正式对局。
			node._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
		else:
			node._process(0.0)
		node.process_mode = item["process_mode"]
	_visual_processes.clear()
	main.sfx.process_mode = _sfx_process_mode
	main.set_tutorial_active(false)
	if main.is_inside_tree(): PhysicsServer3D.set_active(not main.get_tree().paused)
	_saved_main.clear()
	_saved_board.clear()
