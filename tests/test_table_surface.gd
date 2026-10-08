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
	_check_paper_interaction(main)
	await _check_tag_ink_bounds(main)
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
	await _check_tag_resources(main)
	finish()

func _check_paper_interaction(main: Node) -> void:
	var card: CardEntity = main.market_cards[0]
	var tag: Node3D = main.market_price_labels[0]
	check(tag.text == str(int(CardDB.get_def(card.def_id)["price"]))
			and tag._coin.texture == CardArt.res_icon_texture(CardDB.RES_CASH),
		"纸价签使用真实价格数字和现金牌同一贴图")
	var rope: MeshInstance3D = tag._presentation.get_node("TagString")
	var front: PackedVector3Array = rope.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var back: PackedVector3Array = rope.mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	var corner := (front[0] + front[1]) * 0.5
	var hole := (front[-2] + front[-1]) * 0.5
	var expected_corner := card.global_position + Vector3(0.48, CardEntity.Y_PLATE + 0.004, 0.735)
	check(tag._presentation.to_global(corner).distance_to(expected_corner) < 0.001,
		"绳头穿进售卖卡右下角内侧纸面的孔心")
	check(hole.distance_to(tag._hanging.transform * Vector3(-0.325, 0.018, 0)) < 0.001
		and ((back[0] + back[1]) * 0.5).distance_to(hole) < 0.001
		and ((back[-2] + back[-1]) * 0.5).distance_to(corner) < 0.001,
		"两股挂绳穿过吊牌圆孔并回到卡面穿孔")
	# 从镜头投射卡角到吊牌平面，确保纸面不能再遮住实际连接点。
	var camera: Camera3D = main.board.camera
	var pixel := camera.unproject_position(expected_corner)
	var origin := camera.project_ray_origin(pixel)
	var ray := camera.project_ray_normal(pixel)
	var plane_y: float = tag._paper.global_position.y
	var projected: Vector3 = origin + ray * ((plane_y - origin.y) / ray.y)
	var local: Vector3 = tag._hanging.to_local(projected)
	var tag_distance := maxf(maxf(absf(local.z) - 0.265, local.x - 0.495),
		(-local.x - 0.495 + absf(local.z) * 0.85) / 1.3124)
	check(tag_distance > 0.03, "镜头下卡面穿孔与吊牌纸面分离，连接点清晰可见")
	var eyelet: MeshInstance3D = tag._presentation.get_node("CardStringHole")
	check(eyelet.global_position.distance_to(expected_corner) < 0.002,
		"可见穿孔与挂绳的实际连接点一致")
	if card._effect_blob:
		var blob: Sprite3D = card._effect_blob
		var radius := float(blob.texture.get_width()) * blob.pixel_size * card.BADGE_DONE_SCALE * 0.5
		var flat_gap := Vector2(eyelet.global_position.x - blob.global_position.x,
			eyelet.global_position.z - blob.global_position.z).length()
		check(flat_gap > radius + tag.CARD_HOLE_RADIUS + 0.015,
			"卡面穿孔与放大后的产出墨团保留间隔")
	var tag_position := tag.global_position
	var card_position := card.global_position
	card.set_hover_visual(true)
	tag._motion.pause()
	tag._motion.custom_step(0.15)
	check(tag._presentation.position.y > 0.0 and tag.global_position == tag_position
			and card.global_position == card_position,
		"悬停轻抬价签绘制层，不改变商品或价签锚点")
	card.set_hover_visual(false)
	var cash: Array[CardEntity] = []
	var user: CardEntity
	for entity in main.board.cards:
		if entity.draggable and entity.def_id == CardDB.RES_CASH:
			cash.append(entity)
		if entity.draggable and entity.def_id == CardDB.RES_USER:
			user = entity
	if not need(not cash.is_empty() and user != null, "存在可测试购买反馈的资源实体"):
		return
	var cash_position := cash[0].global_position
	var user_position := user.global_position
	main.board._drag_cards.assign(cash)
	cash[0].global_position = card.global_position
	tag._process(0.0)
	check(tag._paper._feedback_target == 1.0, "足额现金拖到商品上时价签提供有效目标反馈")
	var tray: Node3D = main.get_node("PlayerZoneTray")
	cash[0].global_position = cash_position
	tray._process(0.02)
	check(tray._feedback_target == 1.0, "拖到可落桌位置时理牌垫边缘亮起")
	main.board._drag_cards.assign([user])
	user.global_position = card.global_position
	tag._process(0.0)
	check(tag._paper._feedback_target == 0.0, "用户牌不能付款，不显示可购买反馈")
	user.global_position = user_position
	main.board._drag_cards.clear()
	tag._process(0.0)
	tray._process(0.02)
	check(tray._feedback_target == 0.0 and not tag._presented, "拖拽结束清除分区和价签反馈")
	var material := tag._paper.material_override as ShaderMaterial
	var old_paper: Color = material.get_shader_parameter("fill_color")
	Palette.set_color("world", "table_frame", Color("#E2D4B2"))
	check(not (material.get_shader_parameter("fill_color") as Color).is_equal_approx(old_paper),
		"吊牌纸色跟随公共配色实时更新")
	Palette.restore_defaults()

func _check_tag_ink_bounds(main: Node) -> void:
	var tags: Array[Node3D] = []
	for price in [1, 10, 100, 1000]:
		var tag := preload("res://scenes/market_price_tag.gd").new()
		main.add_child(tag)
		tag.configure(price, main.market_cards[0], main.board)
		tag.position = Vector3(40, 0.15, 40)
		tags.append(tag)
	await process_frame
	await process_frame
	await process_frame
	var safe := Rect2(Vector2(-0.21, -0.21), Vector2(0.65, 0.42))
	for tag in tags:
		for item in [tag._label, tag._coin]:
			var bounds: AABB = item.get_aabb()
			var contained := bounds.size.x > 0.0 and bounds.size.y > 0.0
			for x in [bounds.position.x, bounds.end.x]:
				for y in [bounds.position.y, bounds.end.y]:
					var point: Vector3 = item.transform * Vector3(x, y, 0)
					contained = contained and safe.has_point(Vector2(point.x, point.z))
			check(contained, "%s 的%s完整位于吊牌留白范围内" % [tag.text, "数字" if item == tag._label else "金币"])
		tag.queue_free()

func _check_tag_resources(main: Node) -> void:
	var first: Node3D = main.market_price_labels[0]
	var second: Node3D = main.market_price_labels[1]
	check(first._hole_material.shader == second._hole_material.shader,
		"同批市场价签共享穿孔Shader，避免逐张重复编译")
	check(first._hole_material != second._hole_material and first._string_material != second._string_material,
		"穿孔和挂绳各有独立材质，颜色与透明度可分别更新")
	first._fade(0.25)
	# 未覆盖的参数在无头渲染器返回 null，使用 shader 中的默认 opacity=1。
	check(is_equal_approx(float(first._hole_material.get_shader_parameter("opacity")), 0.25)
		and second._hole_material.get_shader_parameter("opacity") in [null, 1.0]
		and is_equal_approx(second._string_material.albedo_color.a, 1.0),
		"一个价签淡出不影响相邻商品的穿孔或挂绳")
	check(first._string_material.cull_mode == BaseMaterial3D.CULL_DISABLED,
		"共享模板保留挂绳双面可见")
	var program: WeakRef = weakref(first._hole_material.shader)
	main._clear_market()
	await process_frame
	await process_frame
	check(program.get_ref() != null, "市场价签全部释放后穿孔Shader仍保留供补货复用")
	main._respawn_market()
	var refreshed: Node3D = main.market_price_labels[0]
	check(refreshed._hole_material.shader == program.get_ref()
		and refreshed._hole_material.get_shader_parameter("opacity") in [null, 1.0]
		and is_equal_approx(refreshed._string_material.albedo_color.a, 1.0),
		"补货价签沿用既有Shader，透明度从完整可见重新开始")
