# SPDX-License-Identifier: AGPL-3.0-only
extends "res://scenes/card_atlas.gd"

const CATEGORY_NAMES := {"person": "人员", "work": "工作", "money": "金钱", "tool": "工具", "ingredient": "咖啡"}

func _card_entries() -> Array:
	var result: Array = []
	for id in _presentation.state.config.cards:
		var definition: Dictionary = _presentation.state.config.cards[id]
		result.append({"def_id": id, "name": definition.name, "kind": definition.category})
	return result

func _upgrade_routes() -> Dictionary:
	var routes: Array = []
	var config: OffWorkConfig = _presentation.state.config
	for id in config.rules.coffee.upgrades:
		var recipe: Dictionary = config.coffee_upgrade(str(id))
		routes.append({"source_id": id, "target_id": recipe.to, "count": int(recipe.cost), "seconds": config.coffee_seconds(str(id))})
	return {"ordinary": routes, "legends": [], "no_ordinary": []}

func _build_map() -> void:
	_header.hide()
	_map = VBoxContainer.new()
	_map.name = "UpgradeRoutes"
	_map.add_theme_constant_override("separation", 14)
	_page.add_child(_map)
	var coffee := _label("人员与咖啡需单独成堆。含有工作时，只处理工作。", 14)
	coffee.name = "CoffeeCombination"
	_map.add_child(coffee)
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
		_ordinary_grid.add_child(row)
		row.add_child(_card_node(_entry(str(route.source_id)), true))
		var condition := VBoxContainer.new()
		condition.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(condition)
		var amount := _label("%d 杯咖啡" % int(route.count), 14)
		amount.name = "CoffeeCost"
		amount.autowrap_mode = TextServer.AUTOWRAP_OFF
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		condition.add_child(amount)
		condition.add_child(_arrow())
		var timing := _label("%s 秒" % String.num(float(route.seconds)), 14)
		timing.name = "CoffeeTime"
		timing.autowrap_mode = TextServer.AUTOWRAP_OFF
		timing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		condition.add_child(timing)
		row.add_child(_card_node(_entry(str(route.target_id)), true))
	var working := _label("人员＋工作处理待办，加班牌可以提效。喝咖啡提升卷度后，再把人员放回工作堆。", 14)
	working.name = "WorkCombination"
	_map.add_child(working)

func _preview(def_id: String, height: float) -> Control:
	if mode == "upgrades": height = minf(height, 160.0)
	var preview := CardPreview.new()
	preview.configure(def_id, _presentation, OffWorkCardDB, _make_card)
	preview.custom_minimum_size = Vector2(_px(height * CARD_ASPECT), _px(height))
	preview.set_meta("drawer_min_base", Vector2(height * CARD_ASPECT, height))
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return preview

func _make_card(id: String) -> CardEntity:
	var card := OffWorkCard.new()
	card.configure({"id": -1, "type": id, "owner": 0, "group": -1}, _presentation.state.config.cards[id])
	return card

func _ui(key: String, values: Dictionary = {}) -> String:
	if key.begins_with("kind."): return str(CATEGORY_NAMES.get(key.trim_prefix("kind."), key))
	if key == "title": return "下班卡牌总览"
	if key == "upgrade_title": return "咖啡提升卷度"
	if key == "upgrade_intro": return "咖啡用量和时长按当前卡表显示。"
	return super._ui(key, values)
