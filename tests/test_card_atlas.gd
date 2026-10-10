# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Atlas = preload("res://scenes/card_atlas.gd")
const CardPreview = preload("res://scenes/card_preview.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 卡牌总览与真实升级关系图 ===")
	CardDB.load_default()
	_check_cards()
	_check_routes()
	_check_refresh()
	for viewport_size in [Vector2i(960, 600), Vector2i(320, 480)]:
		await _check_layout(viewport_size)
	finish()

func _check_cards() -> void:
	var entries: Array = Atlas.card_entries()
	check(entries.size() == 31 and entries.size() == CardDB.all_cards().size(), "总览包含当前卡表全部31张卡，不只列可购买卡")
	var ids: Array = []
	var values_match := true
	for entry: Dictionary in entries:
		ids.append(entry.def_id)
		values_match = values_match and int(entry.pawn) == CardDB.pawn_value(str(entry.def_id))
		values_match = values_match and int(entry.price) == int(CardDB.get_def(str(entry.def_id)).get("price", -1))
	check(ids.has("cash") and ids.has("user") and ids.has("jiaolv") and ids.has("shangshi"), "图鉴包括资源、合成业务和传说")
	check(values_match, "全部购价和典当价读取实际CardDB，不重复计算公式")

func _check_routes() -> void:
	var routes: Dictionary = Atlas.upgrade_routes()
	check(routes.ordinary.size() == 7, "图中只出现7条真实普通升级路线")
	var valid := true
	var sources: Array = []
	for route: Dictionary in routes.ordinary:
		sources.append(route.source_id)
		var ids: Array = []
		ids.resize(int(route.count))
		ids.fill(str(route.source_id))
		valid = valid and ComboRules.upgrade_target_for_ids(ids) == str(route.target_id)
		valid = valid and int(CardDB.get_def(str(route.source_id)).get("tier", 0)) == 1
		valid = valid and int(CardDB.get_def(str(route.target_id)).get("tier", 0)) == 2
	check(valid, "普通边逐条通过真实组合判定，来源T1、目标T2")
	check(not sources.has("chunwan") and routes.no_ordinary.has("chunwan"), "春晚冠名没有虚构的T2路线")
	check(routes.legends.size() == 3, "传说图按三种真实目标汇聚T1和T2两种路线")
	var counts := {1: [], 2: []}
	valid = true
	for route: Dictionary in routes.legends:
		valid = valid and route.sources.size() == 2 and int(route.pawn) == CardDB.pawn_value(str(route.target_id))
		for source: Dictionary in route.sources:
			counts[int(source.tier)].append(int(source.count))
			var ids: Array = []
			for index in int(source.count):
				ids.append(str(source.card_ids[index % source.card_ids.size()]))
			valid = valid and ComboRules.upgrade_target_for_ids(ids) == str(route.target_id)
			ids.append(str(source.card_ids[0]))
			valid = valid and ComboRules.upgrade_target_for_ids(ids) != str(route.target_id)
	check(valid, "两种传说材料均可异名，精确张数通过引擎，回收值与卡表一致")
	counts[1].sort()
	counts[2].sort()
	check(counts[1] == [4, 6, 8] and counts[2] == [2, 3, 4], "当前配置展示T1的4/6/8与T2的2/3/4张路线")
	check(ComboRules.upgrade_target_for_ids(["yunketang", "jiaolv"]) == "", "混档材料不会被升级图表示为合法材料")

func _check_refresh() -> void:
	var saved_cards := CardDB.CARDS
	var saved_upgrade := CardDB.UPGRADE
	var baseline: Array = Atlas.card_entries()
	CardDB.CARDS = saved_cards.duplicate(true)
	CardDB.UPGRADE = saved_upgrade.duplicate(true)
	CardDB.CARDS.yunketang.name = "新业务名称"
	CardDB.CARDS.yunketang.price = 19
	CardDB.CARDS.yunketang.recipe_n = 21
	CardDB.CARDS.dujiaoshou.pawn = 47
	for route: Dictionary in CardDB.UPGRADE.routes:
		if int(route.get("tier", 0)) == 1 and str(route.get("key", "")) == "dup_key":
			route.per = 3
	var updated: Array = Atlas.card_entries()
	var card := _find_entry(updated, "yunketang")
	check(card.name == "新业务名称" and int(card.price) == 19 and "21" in str(card.recipe), "变更卡名、价格和配方后总览内容即时更新")
	var graph: Dictionary = Atlas.upgrade_routes()
	var unicorn: Dictionary = {}
	for route: Dictionary in graph.legends:
		if route.target_id == "dujiaoshou":
			unicorn = route
	var new_count := false
	for source: Dictionary in unicorn.sources:
		if int(source.tier) == 1 and int(source.count) == 6:
			new_count = true
	check(new_count and int(unicorn.pawn) == 47, "改T1折算规则和传说典当值后关系图同步更新")
	CardDB.CARDS = saved_cards
	CardDB.UPGRADE = saved_upgrade
	check(Atlas.card_entries() == baseline, "恢复卡表后总览无旧配置残留")

func _check_layout(viewport_size: Vector2i) -> void:
	root.size = viewport_size
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var host := Control.new()
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var atlas := Atlas.new()
	host.add_child(atlas)
	atlas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	atlas.bind(null, "cards")
	for _frame in 4:
		await process_frame
	var context := "%dx%d" % [viewport_size.x, viewport_size.y]
	check(atlas._grid.get_child_count() == CardDB.all_cards().size(), context + "：所有卡牌实际存在于可滚动网格")
	check(atlas._grid.columns >= 1 and atlas._scroll.size.x <= float(viewport_size.x), context + "：图鉴不撑大外部窗口")
	check(atlas._grid.columns == 1 if viewport_size.x < 420 else atlas._grid.columns >= 3, context + "：网格随可用宽度折列，小屏仍保持字号")
	var initial_header_y: float = atlas._header.global_position.y
	atlas._scroll.scroll_vertical = 180
	for _frame in 2:
		await process_frame
	check(atlas._header.global_position.y < initial_header_y - 100.0, context + "：分类筛选随内容滚动，不占死小屏阅读区")
	var card_count := 0
	var descriptions := Board.new()
	var exact_card_script := load("res://scenes/card.gd")
	for tile: Control in atlas._grid.get_children():
		var previews := tile.find_children("CardPreview_*", "Control", true, false)
		if previews.size() == 1:
			var preview: Control = previews[0]
			var real_card: CardEntity = preview.card
			if real_card != null and real_card.get_script() == exact_card_script \
					and real_card.def_id == str(tile.get_meta("def_id")) \
					and real_card.label.text == CardDB.card_name(real_card.def_id) \
					and real_card._plate != null and real_card._icon != null \
					and real_card.freeze and not real_card.draggable \
					and real_card.collision_layer == 0 and real_card.collision_mask == 0:
				card_count += 1
	check(card_count == 31, context + "：全部卡片由冻结的正式CardEntity绘制完整卡面，不是另画的插画缩略图")
	var cloud: Control = atlas._tiles.yunketang.find_child("CardPreview_yunketang", true, false)
	check(cloud.tooltip_text == descriptions.hover_desc_text("yunketang"), context + "：独立图鉴的效果提醒复用Board原文")
	descriptions.free()
	check(cloud.viewport.own_world_3d and cloud.viewport.world_3d != root.world_3d \
		and cloud.camera.get_viewport() == cloud.viewport, context + "：预览的世界和相机与原桌完全隔离")
	cloud._set_hovered(true)
	check(cloud.card._visual_hovered, context + "：悬停直接触发正式卡牌插画动作")
	cloud._set_hovered(false)
	check(not cloud.card._visual_hovered, context + "：离开卡牌即停止悬停动作")
	await create_timer(0.25).timeout
	await process_frame
	check(cloud.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, context + "：静止卡面不持续重绘独立视口")
	for filter: Button in atlas._filters.get_children():
		if filter.text == TutorialCatalog.ui("atlas.kind.product"):
			filter.button_pressed = true
			filter.pressed.emit()
			break
	var visible_cards := 0
	var expected_products := 0
	var only_products := true
	for tile: Control in atlas._grid.get_children():
		var product := str(CardDB.get_def(str(tile.get_meta("def_id"))).get("kind", "")) == CardDB.KIND_PRODUCT
		if product:
			expected_products += 1
		if tile.visible:
			visible_cards += 1
			only_products = only_products and product
	check(visible_cards == expected_products and only_products, context + "：分类按钮筛选全部生产卡且不删除其他卡")
	check(atlas._grid.find_children("*", "Button", true, false).is_empty() \
		and atlas.find_child("CardDetail", true, false) == null and not atlas.has_method("show_card"),
		context + "：总览无查看详情按钮，也不构造点击展开的大卡详情")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	cloud.gui_input.emit(click)
	await process_frame
	check(atlas._grid.visible and atlas._grid.get_child_count() == 31 \
		and cloud.mouse_default_cursor_shape == Control.CURSOR_ARROW and not cloud.has_signal("activated"),
		context + "：点击卡片不切页、不展开详情，也没有可点击手型暗示")
	var old_card: WeakRef = weakref(cloud.card)
	var old_viewport: WeakRef = weakref(cloud.viewport)
	atlas.bind(null, "upgrades")
	for _frame in 4:
		await process_frame
	check(old_card.get_ref() == null and old_viewport.get_ref() == null, context + "：切换页面释放旧卡实体及其独立视口")
	check(atlas._map.find_children("Ordinary_*", "", true, false).size() == 7 and atlas._map.find_children("Legend_*", "", true, false).size() == 3, context + "：普通与传说路线均生成可视节点")
	check(atlas._map.find_children("RouteArrow", "Control", true, false).size() == 10, context + "：每条路线有真实连接箭头")
	var map_previews := atlas._map.find_children("CardPreview_*", "Control", true, false)
	var expected_previews := 0
	for route: Dictionary in atlas.ordinary_routes:
		expected_previews += int(route.count) + 1
	for route: Dictionary in atlas.legend_routes:
		expected_previews += 1
		for source: Dictionary in route.sources:
			expected_previews += int(source.count)
	var stacks_valid := true
	for stack: Control in atlas._map.find_children("CardStack", "Control", true, false):
		var row: Node = stack.get_parent()
		while row != null and not row.has_meta("route"):
			row = row.get_parent()
		var shown_ids: Array = []
		for preview: Control in stack.get_children():
			shown_ids.append(preview.card.def_id)
		var ids: Array = stack.get_meta("card_ids", [])
		stacks_valid = stacks_valid and row != null and ids == shown_ids
		if row != null:
			var route: Dictionary = row.get_meta("route")
			stacks_valid = stacks_valid and ComboRules.upgrade_target_for_ids(ids) == str(route.target_id)
	check(stacks_valid and map_previews.size() == expected_previews \
		and map_previews.all(func(preview: Control): return preview.card is CardEntity), \
		context + "：图中每摞实际卡牌与精确张数一致，经真实规则可合成箭头所指产物")
	check(atlas._scroll.size.x <= float(viewport_size.x), context + "：关系图保留可读宽度并在小屏内部横向滚动")
	if viewport_size.x < 420:
		check(atlas._scroll.get_h_scroll_bar().max_value > atlas._scroll.size.x, context + "：窄屏可以水平滚动看完整来源和目标")
	check(atlas._map.find_children("*", "Button", true, false).is_empty() \
		and atlas.find_child("CardDetail", true, false) == null,
		context + "：升级关系仅卡牌和连接关系，没有任何详情按钮或独立详情页")
	host.queue_free()
	await process_frame

func _find_entry(entries: Array, id: String) -> Dictionary:
	for entry: Dictionary in entries:
		if entry.def_id == id:
			return entry
	return {}
