# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const IMPORTED := "user://production_palette_cards.json"
const OTHER_SLOTS := {
	"cash": "plate_cash", "user": "plate_user",
	"dujiaoshou": "plate_t3", "guomin": "plate_t3", "shangshi": "plate_t3",
	"butie": "plate_attack", "heigongguan": "plate_attack", "zuokong": "plate_attack",
	"eryouxuan": "plate_attack", "chaping": "plate_attack", "shanzhai": "plate_attack",
	"liebian": "plate_buff_up", "yinqing996": "plate_buff_up", "resou": "plate_buff_up",
	"tuisong": "plate_buff_def", "jiangjia": "plate_buff_def",
}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 生产卡功能配色 ===")
	CardDB.load_default()
	Palette.restore_defaults()
	check(CardArt.plate_slot("yunketang") == "plate_t1_money"
			and CardArt.plate_slot("ditui") == "plate_t1_growth"
			and not CardArt.face_color("yunketang").is_equal_approx(CardArt.face_color("ditui")),
		"用户变现与现金拉新保留两种不同功能色")
	var world := Node3D.new()
	root.add_child(world)
	var counts := {"1:cash": 0, "1:user": 0, "2:cash": 0, "2:user": 0}
	var original_hash := StateCodec.table_hash()
	for id in CardDB.all_cards():
		var definition := CardDB.get_def(str(id))
		if definition.get("kind") != CardDB.KIND_PRODUCT:
			continue
		var output := str(definition["output_res"])
		var key := "%d:%s" % [int(definition["tier"]), output]
		counts[key] = int(counts.get(key, 0)) + 1
		var reference := "yunketang" if output == CardDB.RES_CASH else "ditui"
		check(definition["recipe_res"] != output,
			"%s 的真实配方与产出属于资源转换方向" % definition["name"])
		_check_same_colors(str(id), reference)
		var card := _card(world, str(id))
		var material := card._plate.material_override as ShaderMaterial
		check((material.get_shader_parameter("face_color") as Color).is_equal_approx(CardArt.face_color(reference))
				and (material.get_shader_parameter("band_color") as Color).is_equal_approx(CardArt.band_color(reference)),
			"%s 的实际卡面材质使用同方向功能色" % definition["name"])
	check(counts == {"1:cash": 3, "1:user": 5, "2:cash": 3, "2:user": 4},
		"逐一覆盖全部 15 张 T1/T2 生产卡和两个转换方向")
	for id in OTHER_SLOTS:
		check(CardArt.plate_slot(id) == OTHER_SLOTS[id], "%s 保留非生产卡原有类别配色" % id)
	_check_custom_colors(world)
	check(StateCodec.table_hash() == original_hash, "修改生产功能色不改变卡牌规则指纹")
	_check_imported_directions()
	world.queue_free()
	await process_frame
	Palette.restore_defaults()
	CardDB.load_default()
	finish()

func _check_same_colors(id: String, reference: String) -> void:
	check(CardArt.plate_slot(id) == CardArt.plate_slot(reference)
			and CardArt.face_color(id).is_equal_approx(CardArt.face_color(reference))
			and CardArt.band_color(id).is_equal_approx(CardArt.band_color(reference))
			and CardArt.accent_color(id).is_equal_approx(CardArt.accent_color(reference))
			and CardArt.ink_color(id).is_equal_approx(CardArt.ink_color(reference)),
		"%s 与 %s 的卡面、标题带、强调和墨色一致" % [id, reference])

func _card(world: Node3D, id: String) -> CardEntity:
	var card := CardEntity.new()
	card.setup(98000 + world.get_child_count(), id)
	card.freeze = true
	world.add_child(card)
	return card

func _check_custom_colors(world: Node3D) -> void:
	var cash_card := _card(world, "xinxijianfang")
	var user_card := _card(world, "baiyibutie")
	for key in ["face", "band", "accent", "ink"]:
		Palette.set_plate_color("plate_t1_money", key, Color("#357A91"))
		Palette.set_plate_color("plate_t1_growth", key, Color("#AC6837"))
		Palette.set_plate_color("plate_t2", key, Color("#D028CB"))
	check(Palette.save(), "用户自定义的方向色仍可用原格式保存")
	Palette._loaded = false
	Palette._cfg = {}
	check(Palette.plate_color("plate_t2", "face").is_equal_approx(Color("#D028CB")),
		"旧等级色槽位仍可原样读取，无需迁移用户配色")
	for pair in [["xinxijianfang", "yunketang"], ["jiaolv", "yunketang"],
			["xufei", "yunketang"], ["baiyibutie", "ditui"], ["banxiaoshi", "ditui"],
			["tuanzhang", "ditui"], ["liulianghe", "ditui"]]:
		_check_same_colors(pair[0], pair[1])
	for card in [cash_card, user_card]:
		card.refresh_palette()
		var expected := Color("#357A91") if card == cash_card else Color("#AC6837")
		var material := card._plate.material_override as ShaderMaterial
		check((material.get_shader_parameter("face_color") as Color).is_equal_approx(expected)
				and (material.get_shader_parameter("band_color") as Color).is_equal_approx(expected)
				and card.label.modulate.is_equal_approx(expected),
			"%s 已创建的卡牌换色后使用对应方向的用户配色" % card.def_id)
	var slots := []
	for item in Palette._plate_items():
		slots.append(item["slot"])
	check(not slots.has("plate_t2") and slots.has("plate_t1_money") and slots.has("plate_t1_growth"),
		"配色面板提供两条功能线，不显示已无作用的等级色控件")

func _check_imported_directions() -> void:
	var cards: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CardDB.BUILTIN_PATH))
	# 既有 ID 改方向、陌生 ID 复制高等级生产牌，均应按导入后的效果取色。
	cards["xinxijianfang"]["recipe_res"] = CardDB.RES_CASH
	cards["xinxijianfang"]["output_res"] = CardDB.RES_USER
	cards["imported_money"] = cards["jiaolv"].duplicate(true)
	cards["imported_money"]["name"] = "测试变现核心"
	cards["imported_growth"] = cards["liulianghe"].duplicate(true)
	cards["imported_growth"]["name"] = "测试拉新核心"
	var file := FileAccess.open(IMPORTED, FileAccess.WRITE)
	file.store_string(JSON.stringify(cards))
	file.close()
	check(CardDB.load_from(IMPORTED), "导入带新生产牌及修改方向的卡表")
	_check_same_colors("xinxijianfang", "ditui")
	_check_same_colors("imported_money", "yunketang")
	_check_same_colors("imported_growth", "ditui")
