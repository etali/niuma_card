# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 直接检查真实场景的市场、设施与托盘。几何约束只管绘制层，
## 不把装饰托盘收窄成新的拖放边界，也不缩放卡牌来塞进小窗口。
const Regions = preload("res://scenes/table_regions.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 购牌区与双方牌区布局 ===")
	for drawer in [false, true]:
		var main: Node = await _boot(drawer)
		await _check_scene(main, drawer)
		await _check_projection_cases(main, drawer)
		if main.sfx:
			main.sfx.set_muted(true)
			main.sfx.free()
		main.queue_free()
		_booted = null
		await process_frame
		await process_frame
	finish()

func _boot(drawer: bool) -> Node:
	root.size = Vector2i(1920, 1200)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = drawer
	root.add_child(main)
	main.sfx.set_muted(true)
	_booted = main
	await settle()
	_assert_booted(main)
	return main

func _check_scene(main: Node, drawer: bool) -> void:
	var mode := "抽屉" if drawer else "横屏"
	var count: int = CardDB.game_rules()["market_size"]
	var market: MeshInstance3D = main.get_node_or_null("TableSurface_market")
	var foe: MeshInstance3D = main.get_node_or_null("FoeZoneTray")
	var player: MeshInstance3D = main.get_node_or_null("PlayerZoneTray")
	var facility: Node3D = main.get_node_or_null("MarketFacility")
	if not need(market != null and foe != null and player != null and facility != null,
		"%s建立独立命名的两侧托盘、市场托盘和设施" % mode):
		return
	var market_rect := _mesh_rect(market)
	var foe_rect := _mesh_rect(foe)
	var player_rect := _mesh_rect(player)
	# 仅验证开局自动摆好的牌堆。之后玩家仍能把牌拖到托盘外的可见桌面。
	for item in [[main.my_seat, player_rect, "己方"], [main.foe_seat, foe_rect, "对方"]]:
		var outside: Array[String] = []
		for record in main.state.players[item[0]]["cards"]:
			var entity: CardEntity = main.entities.get(int(record["uid"]))
			if not is_instance_valid(entity) or entity._plate == null:
				outside.append("缺失实体%d" % int(record["uid"]))
				continue
			var face := _mesh_rect(entity._plate)
			if not (item[1] as Rect2).grow(0.002).encloses(face):
				outside.append("%d %s" % [entity.uid, str(face)])
		check(outside.is_empty(), "%s%s开局牌堆的全部卡面完整位于托盘内%s" %
			[mode, item[2], "" if outside.is_empty() else "：" + ", ".join(outside)])
	var north_gap := market_rect.position.y - foe_rect.end.y
	var south_gap := player_rect.position.y - market_rect.end.y
	check(north_gap >= 0.5 and south_gap >= 0.5,
		"%s市场与双方区域都有清晰空带（%.3f/%.3f）" % [mode, north_gap, south_gap])
	check(absf(north_gap - south_gap) < 0.01, "%s市场到双方区域的留白一致" % mode)
	check(not foe_rect.intersects(market_rect) and not player_rect.intersects(market_rect),
		"%s双方托盘不会叠进市场" % mode)
	check(main.market_cards.size() == count and main.state.market.size() == count,
		"%s设施不增加可购买卡或规则市场数量" % mode)
	check(main.board.cards.filter(func(card): return card.is_market).size() == count,
		"%s设施不注册为可购买、可拖动卡" % mode)
	check(facility.find_children("*", "CollisionObject3D", true, false).is_empty(),
		"%s设施视觉节点不会遮挡已有典当拖放判定" % mode)
	check(foe.find_children("*", "CollisionObject3D", true, false).is_empty()
		and player.find_children("*", "CollisionObject3D", true, false).is_empty(),
		"%s双方托盘仍是无碰撞绘制层" % mode)
	var facility_card: MeshInstance3D = facility.get_node_or_null("PawnshopFacilityCard")
	if need(facility_card != null, "%s设施有独立卡面" % mode):
		var facility_rect := _mesh_rect(facility_card)
		check(facility_rect.size.is_equal_approx(Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z)),
			"%s设施使用与购牌相同的卡面尺寸" % mode)
		check(market_rect.grow(0.002).encloses(facility_rect), "%s设施完整属于购牌托盘" % mode)
		var last: CardEntity = main.market_cards.back()
		var last_rect := Rect2(Vector2(last.position.x, last.position.z) - Vector2(0.6, 0.8), Vector2(1.2, 1.6))
		check(facility_rect.position.x > last_rect.end.x, "%s末张购牌与设施不相叠" % mode)
		_check_facility_labels(facility, facility_rect, market_rect, mode)
	var slots: Array = main.find_children("MarketSlot_*", "MeshInstance3D", true, false)
	check(slots.size() == count, "%s仅可购卡有售出空槽" % mode)
	for index in main.market_cards.size():
		var card: CardEntity = main.market_cards[index]
		var card_rect := Rect2(Vector2(card.position.x, card.position.z) - Vector2(0.6, 0.8), Vector2(1.2, 1.6))
		check(market_rect.grow(0.002).encloses(card_rect), "%s购牌%d完整留在托盘内" % [mode, index])
		check(card.position.distance_to(Regions.market_slot(index, count, drawer)) < 0.03,
			"%s购牌%d使用统一卡位" % [mode, index])
	check(main._pawn_position().is_equal_approx(main.board.pawn_pos), "%s典当命中位置与显示设施同步" % mode)
	check(is_equal_approx(facility.position.x, main.board.pawn_pos.x)
		and is_equal_approx(facility.position.z, main.board.pawn_pos.z), "%s设施显示与典当命中区同心" % mode)
	var pointer: Vector2 = main.board.camera.unproject_position(facility.global_position + Vector3(0, CardEntity.Y_PLATE, 0))
	check(main.facility_contains_pointer(pointer), "%s设施卡面可以独立响应悬停" % mode)
	var market_pointer: Vector2 = main.board.camera.unproject_position(main.market_cards.back().global_position)
	check(not main.facility_contains_pointer(market_pointer), "%s设施悬停不覆盖相邻购牌" % mode)
	if drawer:
		main.drawer_presentation.show_facility_detail(pointer)
		check(main.drawer_presentation._detail.visible
			and "公共设施" in main.drawer_presentation._detail_title.text
			and "不需购买" in main.drawer_presentation._detail_text.text,
			"抽屉设施详情明确告知公共设施不需购买")
		main.drawer_presentation._detail.hide()

	var before_facility := facility.global_transform
	var before_slots: Array = slots.map(func(slot): return slot.global_transform)
	var remaining: Array = main.market_cards.slice(1).map(func(card): return card.position)
	var bought: Dictionary = await main._try_buy(0)
	if need(bought.get("ok", false), "%s真实购牌成功" % mode):
		await settle()
		check(facility.global_transform == before_facility, "%s购买后设施不向空位移动" % mode)
		check(slots.map(func(slot): return slot.global_transform) == before_slots,
			"%s购买后所有空槽仍留在本回合原位" % mode)
		check(main.market_cards.map(func(card): return card.position) == remaining,
			"%s购买后其余货架卡不重排" % mode)

func _check_facility_labels(facility: Node3D, card_rect: Rect2, market_rect: Rect2, mode: String) -> void:
	for label_name in ["FacilityName", "FacilityBadge", "FacilityAction"]:
		var label: Label3D = facility.get_node_or_null(label_name)
		if not need(label != null and not label.text.is_empty(), "%s设施%s标签存在" % [mode, label_name]):
			continue
		var label_rect := _node_aabb_rect(label)
		var allowed := market_rect if label_name == "FacilityAction" else card_rect
		check(allowed.grow(0.015).encloses(label_rect),
			"%s设施%s文字不溢出所属卡面或托盘" % [mode, label_name])

func _check_projection_cases(main: Node, drawer: bool) -> void:
	var facility: Node3D = main.get_node_or_null("MarketFacility")
	if facility == null:
		return
	var camera: Camera3D = main.board.camera
	var original_scale := facility.scale
	var cases := [
		[Vector2i(1280, 800), 1.0],
		[Vector2i(1920, 1200), 1.0],
		[Vector2i(2560, 1600), 2.0],
		[Vector2i(2800, 1100), 1.0],
	]
	for item in cases:
		root.size = item[0]
		await process_frame
		var pitches: Array = [45.0, 80.0] if drawer else [71.0]
		for pitch in pitches:
			var mode := "%s %dx%d @%.0fx pitch%.0f" % ["抽屉" if drawer else "横屏", root.size.x, root.size.y, item[1], pitch]
			var screen := Rect2(Vector2.ZERO, Vector2(root.size))
			if drawer:
				main.drawer_presentation._ui_scale = item[1]
				main.drawer_presentation.perspective_angle = pitch
				main.drawer_presentation.relayout()
				await process_frame
				screen = main.drawer_presentation.content_rect()
			var all_inside := true
			for child in facility.find_children("*", "GeometryInstance3D", true, false):
				for point in _aabb_corners(child):
					if not screen.grow(1.0).has_point(camera.unproject_position(point)):
						all_inside = false
			check(all_inside, "%s设施及全部文字完整可见" % mode)
			check(facility.scale.is_equal_approx(original_scale), "%s设施不通过缩放适配屏幕" % mode)
			check(main.market_cards.all(func(card): return card.scale.is_equal_approx(Vector3.ONE)),
				"%s卡牌保持原始比例和单位缩放" % mode)
			if drawer:
				var player: MeshInstance3D = main.get_node("PlayerZoneTray")
				var rect := _mesh_rect(player)
				check(main.board.player_bounds.size.x > rect.size.x,
					"%s两侧可见空地仍可放牌，不把装饰托盘当交互边界" % mode)
			else:
				check(main.board.player_bounds == Rect2() and is_equal_approx(main.board.player_max_z, 5.2),
					"%s保留原横屏拖放边界" % mode)

func _mesh_rect(node: MeshInstance3D) -> Rect2:
	return _node_aabb_rect(node)

func _node_aabb_rect(node: GeometryInstance3D) -> Rect2:
	var corners := _aabb_corners(node)
	var rect := Rect2(Vector2(corners[0].x, corners[0].z), Vector2.ZERO)
	for point in corners:
		rect = rect.expand(Vector2(point.x, point.z))
	return rect

func _aabb_corners(node: GeometryInstance3D) -> Array[Vector3]:
	var box: AABB = node.get_aabb()
	var out: Array[Vector3] = []
	for index in 8:
		out.append(node.to_global(box.get_endpoint(index)))
	return out
