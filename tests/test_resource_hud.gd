# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 普通横屏 HUD 资源卡回归：数值、待付、在岗与危险状态必须分层可见，
## 同一份摘要 Label 仍能被抽屉首行收养。
func _initialize() -> void:
	print("=== 结构化资源 HUD ===")
	var main: Node = await boot_main()
	if not need(main != null, "主场景可启动"): 
		finish()
		return
	var player: ResourceHUD = main.hud_player_card
	var ai: ResourceHUD = main.hud_ai_card
	check(player != null and ai != null, "双方各有一张资源状态卡")
	check(player.summary == main.lbl_player_res and ai.summary == main.lbl_ai_res,
		"保留旧摘要 Label 引用供抽屉复用")
	check(player.cash_value != null and player.user_value != null,
		"资金与用户使用独立数值控件")
	check(player.due_value != null and player.warning != null,
		"待付与归零预警使用独立状态控件")
	check(Palette.semantic("danger") != Color.MAGENTA and Palette.semantic("pending") != Color.MAGENTA,
		"危险与待付语义色来自配置 token")
	main._update_hud()
	await process_frame
	check(main.table_hud_rect().size.y <= 132, "顶部资源栏保持紧凑高度（%.0f）" % main.table_hud_rect().size.y)
	check(main.table_hud_rect().position.x >= 16 and main.table_hud_rect().end.x <= main.get_viewport().get_visible_rect().size.x - 320, "顶部资源栏给右上工具留出独立空间")
	check(main.hud_status_panel.get_global_rect().position.y > main.get_viewport().get_visible_rect().size.y * 0.8, "常驻提示位于底部安全区")
	var safe: Rect2 = main.table_content_rect()
	var camera: Camera3D = main.board.camera
	check(safe.position.y > main.table_hud_rect().end.y, "牌桌可见内容从HUD底沿以下开始")
	for x in [-11.5, 11.5]:
		for z in [-8.3, 6.2]:
			for y in [0.0, 1.5]:
				check(safe.has_point(camera.unproject_position(Vector3(x, y, z))),
					"普通模式镜头容纳完整牌区与叠牌高度（%s,%s,%s）" % [x,y,z])
	var market: CardEntity = main.market_cards[0]
	check(safe.has_point(camera.unproject_position(market.position)), "购牌区处于HUD与底栏之间")
	check(safe.has_point(camera.unproject_position(main._pawn_position())), "典当行设施处于HUD与底栏之间")
	check(player.cash_value.text.is_valid_int() and player.user_value.text.is_valid_int(),
		"我方资金/用户显示为纯数值")
	check(ai.cash_value.text.is_valid_int() and ai.user_value.text.is_valid_int(),
		"对手资金/用户显示为纯数值")
	check(player.due_value.text.begins_with("待付"), "待付状态卡保留明确标签")
	check(player.deployment.text.contains("在岗") and player.deployment.text.contains("闲置"),
		"用户部署状态独立显示")
	player.set_resources(10, 12, 10, 7, 5, true, true)
	check(player.warning_frame.visible and player.warning.text.contains("付完归零"),
		"付完归零时出现独立预警徽章")
	check(player.cash_value.text == "10" and not player.cash_value.text.contains("归零"),
		"预警不挤进资金数值")
	player.set_resources(11, 12, 10, 7, 5, true, false)
	check(not player.warning_frame.visible, "资金仍有余量时移除预警")
	var saved: Color = Palette.semantic("surface")
	Palette.set_color("semantic", "surface", Color("#DDE6CF"))
	var themed := player.get_theme_stylebox("panel") as StyleBoxFlat
	check(themed.bg_color.is_equal_approx(Color("#DDE6CF")), "语义色变更立即刷新资源卡")
	Palette.set_color("semantic", "surface", saved)
	main.queue_free()
	finish()
