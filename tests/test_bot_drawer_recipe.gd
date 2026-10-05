# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 20260915_105617_24步录像：第8/24步对手地推(63)+现金(43/44/45)
## 已经是合法3/3配方，但对手布局只移动卡牌，D位一直保留生成时的0/3。
## 真正经过编组显示入口，并覆盖收拢/摊开、欠料、退组与Buff移除。
const DrawerLayout = preload("res://scenes/drawer_table_layout.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 对手组合卡面配方进度 ===")
	for drawer in [false, true]:
		await _check_layout(drawer)
	finish()

func _check_layout(drawer: bool) -> void:
	var context := "抽屉" if drawer else "普通牌桌"
	var main: Node = await boot_main()
	if drawer:
		var old_layout: Node = main.layout
		var layout := DrawerLayout.new()
		main.add_child(layout)
		layout.bind(main)
		main.layout = layout
		old_layout.queue_free()
	main.state.combos.clear()
	main.state.players[main.foe_seat]["cards"] = [
		{"uid": 63, "def_id": "ditui", "locked": false},
		{"uid": 43, "def_id": "cash", "locked": false},
		{"uid": 44, "def_id": "cash", "locked": false},
		{"uid": 45, "def_id": "cash", "locked": false},
		{"uid": 64, "def_id": "yinqing996", "locked": false},
		{"uid": 65, "def_id": "shuabuting", "locked": false},
		{"uid": 66, "def_id": "user", "locked": false},
		{"uid": 67, "def_id": "liebian", "locked": false},
	]
	main._respawn_all()
	await settle()
	var core: CardEntity = main.entities[63]
	var need := int(CardDB.get_def("ditui")["recipe_n"])
	check(core.recipe_progress_text() == "0/%d" % need, "%s：闲置核心初始为0/N" % context)
	var result: Dictionary = main.state.create_combo(main.foe_seat, [63, 43, 44, 45])
	if not need(bool(result.get("ok", false)), "%s：录像地推+3现金组合合法" % context):
		main.queue_free()
		await process_frame
		return
	main._render_foe_combo(result)
	check(core.recipe_progress_text() == "3/%d" % need,
		"%s：对手编组显示入口立即把录像配方刷新为3/N（实际%s）" % [context, core.recipe_progress_text()])
	_check_completed(core, true, context + "：合法配方")
	await settle()
	main.layout._layout_bot_idle()
	check(core.recipe_progress_text() == "3/%d" % need,
		"%s：后续理牌不丢失已完成进度" % context)
	# 对手拆回尚未提交的牌摞：显示实际缺料，而不沿用上一组eval或只刷新合法组合。
	main.state.combos.clear()
	main.on_foe_piles({"piles": [{"uids": [63, 43, 64], "compact": true}]})
	check(core.recipe_progress_text() == "1/%d" % need,
		"%s：对手半成品收拢摞显示1/N" % context)
	_check_completed(core, false, context + "：半成品")
	check(core.effect_mult() == CardDB.buff_mult("output_x2"),
		"%s：半成品中996也同步更新产出倍数" % context)
	# 改为摊开同一摞，再补足配方。普通牌桌的另一条摆放路径也必须写数字。
	main.on_foe_piles({"piles": [{"uids": [63, 43, 44, 45, 64], "compact": false}]})
	main.board._set_hover_card(core)
	core._drag_visual_tween.pause()
	core._drag_visual_tween.custom_step(0.2)
	check(core._visual.position.is_equal_approx(Vector3.ZERO), "%s：真实对手摊开组合悬停不抬起单张卡" % context)
	main.board._set_hover_card(null)
	check(core.recipe_progress_text() == "3/%d" % need,
		"%s：对手摊开完整组合仍显示3/N" % context)
	_check_completed(core, true, context + "：补足配方")
	# 撤销摞让核心回到备牌区，旧进度与翻倍必须一起退回。
	main.on_foe_piles({"piles": []})
	check(core.recipe_progress_text() == "0/%d" % need,
		"%s：核心离组回到备牌区后进度归零" % context)
	check(core.effect_mult() == 1, "%s：核心离开996后产出倍数归一" % context)
	_check_completed(core, false, context + "：离组")
	# 裂变填配方和玩家侧共用规则，不能只按原料张数显示1/N。
	var user_core: CardEntity = main.entities[65]
	var user_need := int(CardDB.get_def("shuabuting")["recipe_n"])
	main.on_foe_piles({"piles": [{"uids": [65, 66, 67], "compact": true}]})
	check(user_core.recipe_progress_text() == "%d/%d" % [user_need, user_need],
		"%s：一张用户+裂变按真实规则显示完整配方" % context)
	_check_completed(user_core, true, context + "：裂变补满")
	main.on_foe_piles({"piles": [{"uids": [65, 67], "compact": true}]})
	check(user_core.recipe_progress_text() == "0/%d" % user_need,
		"%s：裂变没有用户底料时仍是0/N" % context)
	_check_completed(user_core, false, context + "：裂变缺底料")
	main.queue_free()
	await process_frame

func _check_completed(core: CardEntity, completed: bool, context: String) -> void:
	var ratio := core._recipe_blob.scale.x / core._recipe_blob_scale.x
	check(ratio > 1.0 if completed else is_equal_approx(ratio, 1.0),
		"%s的墨点完成态与配方一致" % context)
