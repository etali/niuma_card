# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

class RejectingScene extends "res://scenes/on_work_main.gd":
	func _drive_bot_attack(_who: String, _pools: Dictionary) -> Dictionary:
		return OnWorkIntent.err("rejected", "测试：攻击提交失败")

## 真正实例化 main 并跑演出，再与无头 Transport 对比；不以两条无头路径代替场景。
func _initialize() -> void:
	OnWorkCardDB.ensure_loaded()
	await _compare_round(OnWorkState.PLAYER)
	await _compare_round(OnWorkState.BOT)
	await _hook_rejection()
	finish()

func _cheapest(kind: String, recipe: String) -> String:
	var best := ""
	var count := 999
	for id in OnWorkCardDB.all_cards():
		var def := OnWorkCardDB.get_def(id)
		if def.get("kind") == kind and def.get("recipe_res") == recipe and int(def.get("recipe_n", 0)) < count:
			best = id
			count = int(def["recipe_n"])
	return best

func _combo(state: OnWorkState, seat: String, id: String) -> void:
	var def := OnWorkCardDB.get_def(id)
	var uids: Array = [state.add_card(seat, id)["uid"]]
	for i in int(def["recipe_n"]):
		uids.append(state.add_card(seat, OnWorkCardDB.unit_id(def["recipe_res"]))["uid"])
	check(state.create_combo(seat, uids).get("ok", false), "%s测试组合成立" % seat)

func _compare_round(first: String) -> void:
	var main: Node = await boot_main()
	var state := OnWorkState.new()
	state.set_seed(12057)
	state.new_game(first)
	var attack := _cheapest(OnWorkCardDB.KIND_ATTACK, OnWorkCardDB.RES_CASH)
	var production := _cheapest(OnWorkCardDB.KIND_PRODUCT, OnWorkCardDB.RES_CASH)
	if not need(attack != "" and production != "", "卡表有可比较的攻击/生产组合"):
		return
	for seat in [OnWorkState.PLAYER, OnWorkState.BOT]:
		_combo(state, seat, production)
	# 对手有真实攻击；玩家空攻击回合也必须按相同顺序装弹并跳过。
	_combo(state, main.foe_seat, attack)
	main._invalidate_session()
	main.state = state
	main._rebuild_pipe()
	main._respawn_all()
	var reference := OnWorkState.new()
	OnWorkStateCodec.restore(reference, OnWorkStateCodec.snapshot(state))
	var pipe := OnWorkLocalTransport.new(OnWorkIntentApply.new(reference))
	var visible_ops: Array = []
	var headless_ops: Array = []
	main.pipe.applied.connect(func(result): visible_ops.append([result["op"], result.get("seat", ""), result.get("combo_idx", -1)]))
	pipe.applied.connect(func(result): headless_ops.append([result["op"], result.get("seat", ""), result.get("combo_idx", -1)]))
	await pipe.run_round(OnWorkBOTPlan.target_picker(OnWorkBOTSearch.prefs()))
	await pipe.next_round()
	await main._run_attacks()
	check(visible_ops == headless_ops, "%s先手：场景与无头意图序列一致\n场景%s\n无头%s" % [first, visible_ops, headless_ops])
	check(OnWorkStateCodec.state_hash(main.state) == OnWorkStateCodec.state_hash(reference),
		"%s先手：真实场景与无头整回合最终状态和战报一致" % first)
	check(visible_ops.any(func(op): return op[0] == OnWorkIntent.OP_ATTACK) and visible_ops.any(func(op): return op[0] == OnWorkIntent.OP_PRODUCE),
		"比较确实经过攻击和产出，不是空回合")
	main._invalidate_session()
	main.queue_free()
	await process_frame

func _hook_rejection() -> void:
	var main := RejectingScene.new()
	root.add_child(main)
	await process_frame
	_combo(main.state, main.foe_seat, _cheapest(OnWorkCardDB.KIND_ATTACK, OnWorkCardDB.RES_CASH))
	_combo(main.state, main.my_seat, _cheapest(OnWorkCardDB.KIND_PRODUCT, OnWorkCardDB.RES_CASH))
	main._sync_entities()
	var operations: Array = []
	main.pipe.applied.connect(func(result): operations.append(result["op"]))
	await main._run_attacks()
	check(main.lbl_msg.text.contains("攻击提交失败"), "攻击回调的失败回执传回场景显示")
	check(not operations.has(OnWorkIntent.OP_PRODUCE) and not operations.has(OnWorkIntent.OP_FINALIZE),
		"攻击回调失败后，统一驱动不会继续产出或结算")
	main._invalidate_session()
	main.queue_free()
	await process_frame
