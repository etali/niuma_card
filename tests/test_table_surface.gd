# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main := await boot_main()
	var slot_count: int = CardDB.game_rules()["market_size"]
	var before: Array = main.find_children("MarketSlot_*", "MeshInstance3D", true, false)
	check(before.size() == slot_count, "没有卡槽位图时公共市场仍保留全部槽位")
	if not need(not before.is_empty(), "存在可检查的市场槽位"):
		finish()
		return
	var first: Node3D = before[0]
	var first_pos := first.global_position
	var other_positions: Array = main.market_cards.slice(1).map(func(c): return c.global_position)
	var purchase: Dictionary = await main._try_buy(0)
	if need(purchase.get("ok", false), "真实购买第一张卡"):
		await settle()
		check(is_instance_valid(first) and first.global_position == first_pos,
			"成交后空槽留在原位，不跟着已购卡飞走")
		check(main.market_cards.size() == slot_count - 1 and main.market_price_labels.size() == slot_count - 1,
			"成交价签移除，其他卡和标价数量仍一致")
		check(main.market_cards.map(func(c): return c.global_position) == other_positions,
			"其余市场卡不填补缺口，空槽表达本回合已售出的位置")
		var picked: CardEntity = main.board._pick_card(main.board.camera.unproject_position(first_pos))
		check(picked == null, "空槽不会被当作可购买或可拖动的卡")

	var surface: MeshInstance3D = main.find_child("TableSurface_market", true, false)
	var material: ShaderMaterial = surface.material_override
	var old_color: Color = material.get_shader_parameter("fill_color")
	var old_mesh := surface.mesh
	Palette.set_color("world", "table_frame", Color("#EBCFA1"))
	var new_color: Color = material.get_shader_parameter("fill_color")
	check(not new_color.is_equal_approx(old_color), "改面板色时市场分区同步换色")
	check(surface.mesh == old_mesh and first.global_position == first_pos,
		"换色仅刷新绘制，不重建节点或移动卡槽")
	check(main._table_mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"台面按色板平涂，光照不再将底色推亮")
	finish()
