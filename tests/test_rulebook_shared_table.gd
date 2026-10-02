# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Arena = preload("res://scenes/rulebook_arena.gd")
const DemoData = preload("res://scenes/rulebook_demo_data.gd")
const Content = preload("res://scenes/rulebook_content.gd")
const Regions = preload("res://scenes/table_regions.gd")
const Actions = preload("res://scenes/table_actions.gd")

class RecordedSound extends Sfx:
	var actions: Array[String] = []
	func play(action_name: String, _pitch := 1.0) -> void:
		# 真播放入口同样从配置解析；仅拦下扬声器输出，保留动作/音效可观察性。
		assert(not Sfx.action(action_name).is_empty())
		actions.append(action_name)

var _sound: RecordedSound

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	_sound = RecordedSound.new()
	root.add_child(_sound)
	_check_demo_catalog()
	_check_config_following()
	var main: Node = await boot_main()
	for example in [_example("purchase", "purchase"), _example("pawn", "pawn"),
		_example("combos", "upgrade", 1), _example("combos", "upgrade", 2),
		_example("combos", "production"), _example("attack", "attack")]:
		if not need(not example.is_empty(), "配置提供示例：%s" % example.get("mode", "缺失")):
			continue
		var arena := Arena.new()
		root.add_child(arena)
		arena.configure(example, _sound)
		check(arena._table_scene.get_script() == main._table_scene.get_script(), "演示和游玩共用TableScene桌面构造")
		check(arena._table_actions.get_script() == main._table_actions.get_script(), "演示和游玩共用TableActions交易与音效")
		check(arena.layout.get_script() == preload("res://scenes/drawer_table_layout.gd"), "演示资源堆沿用正式DrawerTableLayout")
		check(arena.sfx == _sound and arena.motions.sfx == _sound, "演示直接使用传入的音效服务，没有私自静音")
		_check_geometry(arena)
		await _finish_fixture_layout(arena)
		_sound.actions.clear()
		var before_cash := arena.state.resource_count(arena.my_seat, CardDB.RES_CASH)
		var before_cards: int = arena.state.players[arena.my_seat]["cards"].size()
		var prices_before: Array = arena.market_cards.map(func(card): return card.position)
		var facility_at: Vector3 = arena.get_node("MarketFacility").position
		arena.assemble()
		await create_timer(0.5).timeout
		var mode: String = example["mode"]
		if mode in ["purchase", "pawn"]:
			var at: Vector3 = arena._pawn_position() if mode == "pawn" else arena._market_slot(arena._purchase_index, arena.state.market.size())
			var card_at: Vector3 = arena._input_cards[0].position
			check(Vector2(card_at.x, card_at.z).distance_to(Vector2(at.x, at.z)) < 0.5, "%s实际移到正式货架/柜台再交易" % mode)
			check(card_at.y >= at.y + CardEntity.CARD_SIZE.y + CardEntity.FACE_SPAN_Y, "%s付款卡抬高越过商品卡面，图标不穿模" % mode)
		arena.elapsed = 2.2
		arena.resolve()
		if mode == "pawn":
			var pawn_card: CardEntity = arena._input_cards[0]
			check(pawn_card.has_meta("dest_pos") and pawn_card.get_meta("dest_pos") == facility_at + Vector3(0, 0.8, 0), "典当使用正式吸入柜台目标，不是飞出桌外")
			check(not pawn_card._face_down, "吸入典当不改成独立翻面动画")
			check(arena.state.resource_count(arena.my_seat, CardDB.RES_CASH) == before_cash + int(example["output"]["count"]), "典当金额与CardDB.pawn_value一致")
			check(_sound.actions.count("pawn") == 1, "典当播放与游玩同名pawn动作")
		elif mode == "purchase":
			check(arena.state.resource_count(arena.my_seat, CardDB.RES_CASH) == before_cash - int(example["price"]), "购买由真实裁决器扣除当前配置价格")
			check(arena.state.players[arena.my_seat]["cards"].size() == before_cards - int(example["price"]) + 1, "购买实体替换没有凭空加牌")
			check(_sound.actions.count("buy") == 1 and not arena.entities[arena.last_result["new_uid"]].is_market, "购买播放正式buy并把商品变为玩家牌")
			prices_before.remove_at(arena._purchase_index)
			check(arena.market_cards.map(func(card): return card.position) == prices_before and arena.get_node("MarketFacility").position == facility_at, "购买后其他商品和典当柜台不重新排位")
			var purchased: CardEntity = arena.entities[arena.last_result["new_uid"]]
			var purchase_origin := purchased.position
			await create_timer(preload("res://scenes/ui_motion.gd").TRANSFER * 0.5).timeout
			check(purchased.position.is_equal_approx(purchase_origin), "现金仍在付款时商品留在槽位，不抬起穿过现金图标")
		elif mode == "upgrade":
			check(arena.lanes.size() == example["variants"].size(), "普通升级及同档传说路线同时存在于一个牌桌")
			for lane in arena.lanes:
				var expected_ids: Array = []
				for input in lane["spec"]["inputs"]:
					for n in int(input["count"]):
						expected_ids.append(input["id"])
				check(lane["cards"].map(func(card): return card.def_id) == expected_ids,
					"动画实体按异名输入逐张生成，不偷换成同名材料")
				var produced: Dictionary = arena.state.find_card(arena.my_seat, int(lane["result_uid"]))
				check(produced.get("def_id") == lane["spec"]["target_id"], "同屏×%d合成真实对应产物" % lane["spec"]["count"])
			check(_sound.actions.count("upgrade") == 0, "材料尚在收束时不抢先播放升级完成声音")
		while arena.elapsed < arena.duration + 0.8:
			arena.advance_time(0.1)
			await create_timer(0.1).timeout
		if mode == "pawn":
			var record: Dictionary = arena.state.players[arena.my_seat]["cards"].back()
			var returned: CardEntity = arena.entities[record["uid"]]
			check(returned.position.is_equal_approx(arena.board.clamp_player_position(returned.position)), "典当返回的现金位于实际玩家牌区，不与柜台重叠（%s）" % returned.position)
		if mode == "production":
			check(_sound.actions.count("produce_land") == int(example["output"]["count"]), "每张产出使用与正式落牌一致的produce_land音效")
		if mode == "upgrade":
			check(_sound.actions.count("upgrade") == arena.lanes.size(), "新卡揭示时所有档位复用升级音效事件")
			for lane in arena.lanes:
				check(arena.entities.has(lane["result_uid"]), "每档合成结果都留在牌桌可对照")
		if mode == "attack":
			check(_sound.actions.has("attack") and _sound.actions.has("attack_tear"), "攻击和逐张撕牌复用正式音效动作")
		arena.queue_free()
		await process_frame
	main.queue_free()
	_sound.queue_free()
	await process_frame
	finish()

func _check_geometry(arena: Node) -> void:
	var count := int(CardDB.game_rules()["market_size"])
	check(arena.market_cards.size() == count and arena.market_price_labels.size() == count, "商品和价格标签数量来自配置")
	var market: MeshInstance3D = arena.get_node("TableSurface_market")
	check(market.mesh.size == Regions.market_rect(count, true).size, "教学购牌栏和正式牌桌使用同一Rect")
	check(arena.get_node("PlayerZoneTray").mesh.size == Regions.zone_rect(true, true, count).size, "双方托盘复用正式几何")
	check(arena.get_node("MarketFacility").position == Regions.facility_position(count, true), "典当设施位置完全对齐正式牌桌")
	check(arena.get_node("MarketFacility/PawnshopFacilityCard").material_override.shader == load(CardEntity.PLATE_SHADER), "典当设施复用正式卡面材质")
	for i in count:
		check(arena.market_price_labels[i].text == "¥%d" % int(CardDB.get_def(arena.market_cards[i].def_id)["price"]), "价签只读当前卡牌价格")

func _check_demo_catalog() -> void:
	check(not DemoData.examples("purchase").is_empty(), "规则书有购买章节和示例")
	var seen := {}
	var mixed_tiers := {}
	var ordinary := false
	for example in DemoData.examples("combos"):
		if example["mode"] != "upgrade":
			continue
		var id: String = example["source_id"]
		check(not seen.has(id), "每个来源牌只有一个升级选择项：%s" % id)
		seen[id] = true
		var paths: Array = Content.upgrade_paths(id)
		check(example["variants"].size() == paths.size(), "升级对照包含引擎接受的全部档位")
		for variant in example["variants"]:
			var ids: Array = []
			for input in variant["inputs"]:
				for n in int(input["count"]):
					ids.append(input["id"])
			check(ids.size() == variant["count"] and ComboRules.upgrade_target_for_ids(ids) == variant["target_id"],
				"演示实际材料与真实规则给出同一目标，且张数精确")
			if CardDB.get_def(variant["target_id"]).get("kind") == CardDB.KIND_LEGEND:
				check(variant["inputs"].size() >= 2 and variant["inputs"][0]["id"] != variant["inputs"][1]["id"],
					"传说演示实际使用至少两种异名生产卡")
				mixed_tiers[int(CardDB.get_def(id)["tier"])] = true
			else:
				ordinary = true
				check(variant["inputs"].size() == 1 and variant["inputs"][0]["id"] == id, "普通T1→T2演示保留同名材料")
	check(mixed_tiers.has(1) and mixed_tiers.has(2) and ordinary, "同时演示T1异名传说、T2异名传说和普通同名升级")

func _check_config_following() -> void:
	var old_cards := CardDB.CARDS
	var old_game := CardDB.GAME
	var old_upgrade := CardDB.UPGRADE
	CardDB.CARDS = old_cards.duplicate(true)
	CardDB.GAME = old_game.duplicate(true)
	CardDB.UPGRADE = old_upgrade.duplicate(true)
	CardDB.CARDS["yunketang"]["price"] = 13
	CardDB.CARDS["dujiaoshou"]["upgrade_dup_n"] = 5
	CardDB.CARDS["dujiaoshou"]["pawn"] = 147
	CardDB.GAME["market_size"] = 6
	CardDB.GAME["pawn_rate"] = 3.0
	for route in CardDB.UPGRADE["routes"]:
		if route.get("kind") == CardDB.KIND_PRODUCT and route.get("tier") == 1 and route.get("key") == "dup_key":
			route["per"] = 3
	var bought := false
	for example in DemoData.examples("purchase"):
		if example["target_id"] == "yunketang":
			bought = example["price"] == 13 and example["inputs"][0]["count"] == 13
	check(bought, "改price后购牌金额和演示现金数量同时变化")
	var changed := false
	for example in DemoData.examples("combos"):
		if example["mode"] == "upgrade" and example["source_id"] == "yunketang":
			for variant in example["variants"]:
				if variant["target_id"] == "dujiaoshou":
					changed = variant["count"] == 15 and "147" in variant["description"]
	check(changed, "修改路线折算和产物定价后，同屏档位与效果说明同步变化")
	var arena := Arena.new()
	root.add_child(arena)
	arena.configure(DemoData.examples("purchase")[0], _sound)
	_check_geometry(arena)
	arena.free()
	CardDB.CARDS = old_cards
	CardDB.GAME = old_game
	CardDB.UPGRADE = old_upgrade

func _example(section: String, mode: String, tier := -1) -> Dictionary:
	for example in DemoData.examples(section):
		if example["mode"] == mode and (tier < 0 or int(CardDB.get_def(example.get("source_id", "")).get("tier", 0)) == tier):
			return example
	return {}

func _finish_fixture_layout(arena: Node) -> void:
	for i in 30:
		await process_frame
		if not arena.layout.ai_moving():
			break
	await create_timer(0.4).timeout
