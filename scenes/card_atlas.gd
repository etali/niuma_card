# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends VBoxContainer

## 学习中心的卡牌总览与升级关系图。每次绑定/刷新都读取当前卡表；
## 文案从教程目录读取，升级边仅由真实 ComboRules 产生。
const Catalog = preload("res://engine/tutorial_catalog.gd")
const Content = preload("res://scenes/rulebook_content.gd")
const CardPreview = preload("res://scenes/card_preview.gd")

const TILE_HEIGHT := 250.0
const NODE_HEIGHT := 180.0
const CARD_ASPECT := CardEntity.CARD_SIZE.x / CardEntity.CARD_SIZE.z
const TILE_WIDTH := TILE_HEIGHT * CARD_ASPECT
const NODE_WIDTH := NODE_HEIGHT * CARD_ASPECT
const STACK_STEP := 0.20
const KIND_ORDER := {"unit": 0, "product": 1, "attack": 2, "buff": 3, "legend": 4}

var mode := "cards"
var entries: Array = []
var ordinary_routes: Array = []
var legend_routes: Array = []
var _presentation: Node
var _scroll: ScrollContainer
var _page: VBoxContainer
var _header: VBoxContainer
var _grid: GridContainer
var _map: VBoxContainer
var _ordinary_grid: GridContainer
var _legend_grid: GridContainer
var _filters: HFlowContainer
var _count: Label
var _empty: Label
var _kind_filter := ""
var _tiles: Dictionary = {}

## 只排列正式卡牌预览，不绘制卡面；每张露出卡名，张数直接可见。
class CardStack extends Container:
	func _notification(what: int) -> void:
		if what != NOTIFICATION_SORT_CHILDREN:
			return
		var index := 0
		for child: Control in get_children():
			var card_size := child.get_combined_minimum_size()
			fit_child_in_rect(child, Rect2(Vector2((size.x - card_size.x) * 0.5,
				index * card_size.y * STACK_STEP), card_size))
			index += 1

## 小屏保留卡面大小，由滚动容器承载完整关系。
class RouteArrow extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)
	func _draw() -> void:
		var ink := Palette.get_color("card", "body")
		var end := Vector2(size.x - 6.0, size.y * 0.5)
		draw_line(Vector2(3.0, end.y), end, ink, 2.0, true)
		draw_line(end, end + Vector2(-9.0, -6.0), ink, 2.0, true)
		draw_line(end, end + Vector2(-9.0, 6.0), ink, 2.0, true)


func bind(presentation: Node, display_mode := "cards") -> void:
	_presentation = presentation
	mode = display_mode
	name = "CardAtlas" if mode == "cards" else "UpgradeMap"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)
	refresh()


## 可显式刷新，在当前卡表热重载后重建卡面、分类与升级路线。
func refresh() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_tiles.clear()
	_kind_filter = ""
	entries = card_entries()
	var routes := upgrade_routes()
	ordinary_routes = routes.ordinary
	legend_routes = routes.legends
	_grid = null
	_map = null
	_ordinary_grid = null
	_legend_grid = null
	_filters = null
	_empty = null
	_scroll = ScrollContainer.new()
	_scroll.name = "AtlasScroll"
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.follow_focus = true
	add_child(_scroll)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 16)
	_scroll.add_child(_page)
	_header = VBoxContainer.new()
	_header.name = "AtlasHeader"
	_header.add_theme_constant_override("separation", 8)
	_page.add_child(_header)
	_header.add_child(_label(_ui("title" if mode == "cards" else "upgrade_title"), 19))
	_count = _label(_ui("card_count", {"count": entries.size()}) if mode == "cards" else _ui("upgrade_intro"), 14)
	_header.add_child(_count)
	if mode == "cards":
		_build_filters()
		_build_cards()
	else:
		_build_map()
	_theme(self)
	_scroll.resized.connect(_update_columns)
	call_deferred("_update_columns")


static func card_entries() -> Array:
	var out: Array = []
	for id in CardDB.all_cards():
		var def_id := str(id)
		var def := CardDB.get_def(def_id)
		var kind := str(def.get("kind", ""))
		var tier := int(def.get("tier", 0))
		var entry := {
			"def_id": def_id, "name": CardDB.card_name(def_id), "kind": kind, "tier": tier,
			"kind_label": Catalog.ui("atlas.kind." + kind),
			"recipe": Catalog.ui("atlas.no_recipe"), "effect": "",
			"price": int(def.get("price", -1)), "pawn": CardDB.pawn_value(def_id),
		}
		if def.has("recipe_res"):
			entry.recipe = Catalog.ui("atlas.recipe", {"resource": CardDB.card_label(str(def.recipe_res)), "count": int(def.get("recipe_n", 0))})
		match kind:
			CardDB.KIND_PRODUCT:
				entry.effect = Catalog.ui("atlas.production", {"resource": CardDB.res_label(str(def.get("output_res", ""))), "count": int(def.get("output_n", 0))})
			CardDB.KIND_ATTACK:
				entry.effect = Catalog.ui("atlas.attack", {"resource": CardDB.res_label(str(def.get("attack_res", ""))), "count": int(def.get("attack_n", 0))})
			CardDB.KIND_BUFF:
				var buff_type := str(def.get("buff_type", ""))
				entry.effect = Catalog.ui("atlas.buff." + buff_type, {"multiplier": CardDB.buff_mult(buff_type)})
			CardDB.KIND_UNIT:
				entry.effect = Catalog.ui("atlas.resource_note")
			CardDB.KIND_LEGEND:
				entry.effect = Catalog.ui("atlas.legend_pawn", {"count": entry.pawn})
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left := int(KIND_ORDER.get(a.kind, 5))
		var right := int(KIND_ORDER.get(b.kind, 5))
		return int(a.tier) < int(b.tier) if left == right else left < right)
	return out


## 普通边保留来源卡身份；传说按目标合并 T1/T2 两种选项，不复制 N→目标算法。
static func upgrade_routes() -> Dictionary:
	var ordinary: Array = []
	var legends: Array = []
	var legendary: Dictionary = {}
	var no_ordinary: Array = []
	for id in CardDB.all_cards():
		var def_id := str(id)
		var def := CardDB.get_def(def_id)
		if str(def.get("kind", "")) != CardDB.KIND_PRODUCT:
			continue
		var has_ordinary := false
		for route: Dictionary in Content.upgrade_paths(def_id):
			if bool(route.same_name):
				ordinary.append(route.duplicate(true))
				has_ordinary = true
		if int(def.get("tier", 0)) == 1 and not has_ordinary:
			no_ordinary.append(def_id)
	for tier in [1, 2]:
		var sources: Array = []
		for id in CardDB.all_cards():
			var def := CardDB.get_def(str(id))
			if str(def.get("kind", "")) == CardDB.KIND_PRODUCT and int(def.get("tier", 0)) == tier:
				sources.append(str(id))
		if sources.is_empty():
			continue
		for count in range(2, CardDB.max_upgrade_n() + 1):
			var target := ComboRules.legend_upgrade_target(tier, count)
			if target.is_empty():
				continue
			if not legendary.has(target):
				legendary[target] = {"target_id": target, "pawn": CardDB.pawn_value(target), "sources": []}
			legendary[target].sources.append({"tier": tier, "count": count, "card_ids": sources.duplicate()})
	for value in legendary.values():
		legends.append(value)
	legends.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.pawn) < int(b.pawn))
	return {"ordinary": ordinary, "legends": legends, "no_ordinary": no_ordinary}


func _build_filters() -> void:
	_filters = HFlowContainer.new()
	_filters.name = "CardFilters"
	_filters.add_theme_constant_override("h_separation", 6)
	_filters.add_theme_constant_override("v_separation", 6)
	_header.add_child(_filters)
	var group := ButtonGroup.new()
	var kinds: Array = [""]
	for entry: Dictionary in entries:
		if not kinds.has(str(entry.kind)):
			kinds.append(str(entry.kind))
	for kind: String in kinds:
		var button := _button(_ui("all" if kind.is_empty() else "kind." + kind), 14)
		button.toggle_mode = true
		button.button_group = group
		button.set_pressed_no_signal(kind.is_empty())
		button.pressed.connect(func():
			_kind_filter = kind
			_filter_cards())
		_filters.add_child(button)


func _build_cards() -> void:
	_grid = GridContainer.new()
	_grid.name = "CardGrid"
	_grid.columns = 1
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	_page.add_child(_grid)
	for entry: Dictionary in entries:
		var tile := _card_node(entry, false)
		tile.name = "Card_" + str(entry.def_id)
		tile.set_meta("def_id", entry.def_id)
		_tiles[entry.def_id] = tile
		_grid.add_child(tile)
	_empty = _label(_ui("empty"))
	_empty.hide()
	_page.add_child(_empty)


func _filter_cards() -> void:
	if _grid == null:
		return
	var visible_count := 0
	for entry: Dictionary in entries:
		var matches := _kind_filter.is_empty() or _kind_filter == str(entry.kind)
		_tiles[entry.def_id].visible = matches
		if matches:
			visible_count += 1
	_empty.visible = visible_count == 0
	_scroll.scroll_vertical = 0
	_update_columns()


func _update_columns() -> void:
	if not is_instance_valid(_scroll):
		return
	var width := maxf(0.0, _scroll.size.x - 18.0)
	if is_instance_valid(_grid):
		var gap := float(_grid.get_theme_constant("h_separation"))
		_grid.columns = maxi(1, int(floor((width + gap) / (_px(TILE_WIDTH) + gap))))
	if is_instance_valid(_ordinary_grid):
		var gap := float(_ordinary_grid.get_theme_constant("h_separation"))
		var route_width := _px(NODE_WIDTH * 2.0 + 44.0 + 16.0)
		_ordinary_grid.columns = maxi(1, int(floor((width + gap) / (route_width + gap))))
	if is_instance_valid(_legend_grid):
		var gap := float(_legend_grid.get_theme_constant("h_separation"))
		var route_width := _px(NODE_WIDTH * 3.0 + 44.0 + 50.0 + 32.0)
		_legend_grid.columns = maxi(1, int(floor((width + gap) / (route_width + gap))))


func _card_node(entry: Dictionary, compact: bool) -> Control:
	var holder := CenterContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.set_meta("card_id", entry.def_id)
	holder.add_child(_preview(str(entry.def_id), NODE_HEIGHT if compact else TILE_HEIGHT))
	return holder


func _card_stack(ids: Array) -> Control:
	var stack := CardStack.new()
	stack.name = "CardStack"
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stack.set_meta("card_ids", ids.duplicate())
	var height := NODE_HEIGHT * (1.0 + STACK_STEP * maxi(0, ids.size() - 1))
	stack.set_meta("drawer_min_base", Vector2(NODE_WIDTH, height))
	stack.custom_minimum_size = Vector2(_px(NODE_WIDTH), _px(height))
	for index in ids.size():
		var preview := _preview(str(ids[index]), NODE_HEIGHT)
		preview.name += "_%d" % index
		stack.add_child(preview)
	return stack


func _build_map() -> void:
	_map = VBoxContainer.new()
	_map.name = "UpgradeRoutes"
	_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map.add_theme_constant_override("separation", 14)
	_page.add_child(_map)
	_map.add_child(_label(_ui("ordinary_title"), 18))
	_ordinary_grid = GridContainer.new()
	_ordinary_grid.name = "OrdinaryRoutes"
	_ordinary_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ordinary_grid.add_theme_constant_override("h_separation", 18)
	_ordinary_grid.add_theme_constant_override("v_separation", 14)
	_map.add_child(_ordinary_grid)
	for route: Dictionary in ordinary_routes:
		var row := HBoxContainer.new()
		row.name = "Ordinary_" + str(route.source_id)
		row.set_meta("route", route)
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_ordinary_grid.add_child(row)
		var ids: Array = []
		ids.resize(int(route.count))
		ids.fill(str(route.source_id))
		row.add_child(_card_stack(ids))
		row.add_child(_arrow())
		row.add_child(_card_node(_entry(str(route.target_id)), true))
	var no_ordinary: Array = upgrade_routes().no_ordinary
	if not no_ordinary.is_empty():
		var names: PackedStringArray = []
		for id in no_ordinary:
			names.append(CardDB.card_name(str(id)))
		_map.add_child(_label(_ui("no_ordinary_route", {"names": _ui("join").join(names)}), 14))
	_map.add_child(HSeparator.new())
	_map.add_child(_label(_ui("legend_title"), 18))
	_map.add_child(_label(_ui("legend_rule"), 15))
	_legend_grid = GridContainer.new()
	_legend_grid.name = "LegendRoutes"
	_legend_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_legend_grid.add_theme_constant_override("h_separation", 18)
	_legend_grid.add_theme_constant_override("v_separation", 14)
	_map.add_child(_legend_grid)
	for route: Dictionary in legend_routes:
		var row := HBoxContainer.new()
		row.name = "Legend_" + str(route.target_id)
		row.set_meta("route", route)
		row.add_theme_constant_override("separation", 8)
		_legend_grid.add_child(row)
		var choices := HBoxContainer.new()
		choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choices.add_theme_constant_override("separation", 8)
		row.add_child(choices)
		for index in route.sources.size():
			var source: Dictionary = route.sources[index]
			var material := _material_node(source)
			choices.add_child(material)
			if index + 1 < route.sources.size():
				var separator := _label(_ui("or"), 13)
				separator.autowrap_mode = TextServer.AUTOWRAP_OFF
				separator.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				separator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				separator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				choices.add_child(separator)
		row.add_child(_arrow())
		row.add_child(_card_node(_entry(str(route.target_id)), true))
	if ordinary_routes.is_empty() and legend_routes.is_empty():
		_map.add_child(_label(_ui("no_upgrades")))


func _material_node(source: Dictionary) -> Control:
	var ids: Array = []
	for index in int(source.count):
		ids.append(str(source.card_ids[index % source.card_ids.size()]))
	return _card_stack(ids)


func _arrow() -> Control:
	var arrow := RouteArrow.new()
	arrow.name = "RouteArrow"
	arrow.custom_minimum_size = Vector2(_px(44), _px(60))
	arrow.set_meta("drawer_min_base", Vector2(44, 60))
	arrow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return arrow


func _entry(def_id: String) -> Dictionary:
	for entry: Dictionary in entries:
		if str(entry.def_id) == def_id:
			return entry
	return {}


func _preview(def_id: String, height: float) -> Control:
	var preview := CardPreview.new()
	preview.configure(def_id, _presentation)
	preview.custom_minimum_size = Vector2(_px(height * CARD_ASPECT), _px(height))
	preview.set_meta("drawer_min_base", Vector2(height * CARD_ASPECT, height))
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return preview


func _label(text: String, font_size := 16) -> Label:
	var label: Label = _presentation._label(text, font_size) if is_instance_valid(_presentation) else Label.new()
	label.text = text
	label.set_meta("drawer_font_base", font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not is_instance_valid(_presentation):
		label.add_theme_font_override("font", Fonts.zh())
		label.add_theme_font_size_override("font_size", font_size)
	return label


func _button(text: String, font_size := 16) -> Button:
	var button: Button = _presentation._button(text, font_size, true) if is_instance_valid(_presentation) else Button.new()
	button.text = text
	button.set_meta("drawer_font_base", font_size)
	if not is_instance_valid(_presentation):
		button.add_theme_font_override("font", Fonts.zh())
		button.add_theme_font_size_override("font_size", font_size)
	return button


func _ui(key: String, values: Dictionary = {}) -> String:
	return Catalog.ui("atlas." + key, values)


func _px(value: float) -> float:
	return float(_presentation._px(value)) if is_instance_valid(_presentation) else value


func _theme(control: Control) -> void:
	if is_instance_valid(_presentation):
		_presentation._apply_tree_theme(control)
