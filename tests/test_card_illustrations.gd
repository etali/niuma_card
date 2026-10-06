# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 插画接入需要跨翻面、撕裂、调色和同名卡详情验证，避免只在静态预览成立。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	for id in CardDB.all_cards():
		var texture := CardArt.illustration_texture(id)
		check((texture == null) == (CardDB.get_def(id).get("kind") == CardDB.KIND_UNIT),
			"%s：资源牌使用共享简笔符号，功能牌使用情景插画" % id)
		check(CardArt.icon_texture(id).resource_path == "res://assets/art/icon/icon_" + id + ".png"
				and (texture == null or texture == CardArt.icon_texture(id))
				and CardArt.icon_preserves_color(CardArt.icon_texture(id)),
			"%s：新版覆盖原图标路径，各入口共用原色素材" % id)
	await _shared_resource_icons()
	await _colors_and_tearing()
	await _hand_drawn_overlays()
	await _real_group_and_details()
	finish()

func _shared_resource_icons() -> void:
	var cards: Array[CardEntity] = []
	for id in ["cash", "user", "yunketang", "ditui"]:
		var card := CardEntity.new()
		card.setup(99300 + cards.size(), id)
		card.freeze = true
		root.add_child(card)
		cards.append(card)
	await process_frame
	for i in 2:
		var id := "cash" if i == 0 else "user"
		var texture := cards[i]._icon.texture
		check(texture == CardArt.res_icon_texture(id), "%s：资源牌主图与资源标记复用同一贴图" % id)
		for product in [cards[2], cards[3]]:
			check(product._badge_icons.any(func(icon): return icon.texture == texture),
				"%s：%s 的配方/产出使用资源牌同一图标" % [id, product.def_id])
	Palette.set_color("icon", "foreground", Color.MAGENTA)
	for card in cards:
		card.refresh_palette()
	check(cards[0]._icon.modulate == Color.WHITE and cards[1]._icon.modulate == Color.WHITE,
		"资源牌主图保留奶油色简笔画，不被图标配色染色")
	check(cards[2]._badge_icons.all(func(icon): return icon.modulate == Color.WHITE),
		"配方与产出保留与资源牌一致的简笔画原色")
	for i in 2:
		var resource_card := cards[i]
		check(resource_card._icon.position.z > cards[2]._icon.position.z,
			"%s：没有底部徽标的资源牌主图比功能牌下移" % resource_card.def_id)
		for half in resource_card.tear_apart():
			var material: ShaderMaterial = half.get_child(0).material_override
			var rect: Vector4 = material.get_shader_parameter("icon_rect")
			check(is_equal_approx(rect.y, resource_card._icon.position.z / CardEntity.CARD_SIZE.z + 0.5),
				"资源牌撕片保留下移后的主图位置")
			check(bool(material.get_shader_parameter("icon_full_color")) and material.get_shader_parameter("icon") == resource_card._icon.texture,
				"资源牌撕片保留共享图标与原色")
			half.queue_free()
	for card in cards:
		card.queue_free()
	Palette.restore_defaults()
	await process_frame

func _colors_and_tearing() -> void:
	var card := CardEntity.new()
	card.setup(99400, "baoyue")
	card.freeze = true
	root.add_child(card)
	await process_frame
	var texture := card._icon.texture
	Palette.set_color("icon", "foreground", Color.MAGENTA)
	card.refresh_palette()
	check(card._icon.modulate.is_equal_approx(Color.WHITE), "修改功能图标色不会把彩色漫画染成单色")
	check(card._badge_icons.all(func(icon): return icon.modulate.is_equal_approx(Color.WHITE)), "配方和结果的资源图标保留与资源牌相同的原色")
	card.set_face_down(true)
	check(not card._icon.visible and not card.label.visible, "翻面同时隐藏插画和卡名")
	card.set_face_down(false)
	check(card._icon.visible and card.label.visible and card._icon.texture == texture, "翻回保留原插画和卡名")
	var before := card.transform
	card.pulse_feedback("produce")
	var art_tween := card._art_tween
	art_tween.pause()
	art_tween.custom_step(0.06)
	check(not card._icon.scale.is_equal_approx(Vector3.ONE), "生产事件实际驱动插画动作")
	check(card.transform == before, "插画动作不移动卡体和拾取碰撞")
	card.reset_interaction_visual()
	check(not art_tween.is_valid() and card._icon.scale.is_equal_approx(Vector3.ONE), "取消动作恢复插画基线，不累计缩放")
	var halves := card.tear_apart()
	for half in halves:
		var material: ShaderMaterial = half.get_child(0).material_override
		check(bool(material.get_shader_parameter("icon_full_color")) and material.get_shader_parameter("icon") == texture,
			"撕片保留彩色插画纹理，而非退回单色轮廓")
		var rect: Vector4 = material.get_shader_parameter("icon_rect")
		check(is_equal_approx(rect.z * 2.0 * CardEntity.CARD_SIZE.x, card._icon.pixel_size * texture.get_width()),
			"撕片图像尺寸与原卡相同，撕开瞬间不会缩小")
	card.queue_free()
	Palette.restore_defaults()
	await process_frame

func _hand_drawn_overlays() -> void:
	var card := CardEntity.new()
	card.setup(99401, "yunketang")
	card.freeze = true
	root.add_child(card)
	card.set_shield(true)
	card.set_void_stamp(true)
	check(card._shield is Sprite3D and card._shield.modulate == Color.WHITE,
		"手绘护盾保留原色，避免再次乘蓝色后墨线和纸色变暗")
	check(card._shield.position.z - CardEntity.CARD_SIZE.x * 0.12 > (CardArt.FRAME_BAND_HEIGHT - 0.5) * CardEntity.CARD_SIZE.z,
		"护盾位于标题带下方，不遮挡卡名")
	check(card._void_stamp.rotation.is_equal_approx(card._void_label.rotation),
		"作废章框与独立文字使用相同倾斜角度")
	Palette.set_color("semantic", "danger", Color("#8F3553"))
	card.refresh_palette()
	check(card._void_stamp.modulate.is_equal_approx(Color(Palette.semantic("danger"), 0.92))
			and card._void_stamp.modulate == card._void_label.modulate,
		"作废框和文字实时跟随现有危险语义色")
	card.set_face_down(true)
	check(not card._shield.visible and not card._void_stamp.visible and not card._void_label.visible,
		"翻面隐藏所有正面状态标记")
	card.set_face_down(false)
	check(card._shield.visible and card._void_stamp.visible and card._void_label.visible,
		"翻回恢复手绘护盾与作废章")
	card.set_shield(false)
	card.set_void_stamp(false)
	check(not card._shield.visible and not card._void_stamp.visible and not card._void_label.visible,
		"取消状态隐藏标记，不留下残影")
	card.queue_free()
	Palette.restore_defaults()
	await process_frame

func _real_group_and_details() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	await settle()
	_assert_booted(main)
	var card: CardEntity = main._spawn_entity(main.state.add_card(main.my_seat, "baoyue"), Vector3(0, 0.05, 3.5), true)
	var other: CardEntity = main._spawn_entity(main.state.add_card(main.my_seat, "baoyue"), Vector3(2, 0.05, 3.5), true)
	var cards: Array = [card]
	for i in int(CardDB.get_def("baoyue")["recipe_n"]):
		cards.append(main._spawn_entity(main.state.add_card(main.my_seat, "user"), Vector3(0, 0.05, 3.5), true))
	cards.append(main._spawn_entity(main.state.add_card(main.my_seat, "yinqing996"), Vector3(0, 0.05, 3.5), true))
	var group: Dictionary = main.board.make_group(cards, true, false)
	main.board.groups.append(group)
	var state_hash := StateCodec.state_hash(main.state)
	main.board.refresh_group(group)
	check(card.recipe_status_text().contains("可生产") and card.recipe_status_text().contains(str(int(CardDB.get_def("baoyue")["output_n"]) * CardDB.buff_mult("output_x2"))),
		"真实组合状态显示有效产出，并包含增强后的数值")
	check(card._recipe_label.position.x < card._effect_label.position.x, "桌面按条件在左、结果在右阅读")
	check(card._recipe_blob.modulate == CardArt.accent_color("baoyue"), "配方凑齐通过徽标强调色呈现")
	var detail: Node = main.drawer_presentation
	detail.show_card_detail(card, Vector2(400, 350))
	check(detail._detail_status.text.contains("可生产") and detail._detail_text.text.contains("用户保留"), "详情解释当前状态与用户保留规则")
	detail.show_card_detail(other, Vector2(400, 350))
	check(detail._detail_status.text.contains("还缺") and not detail._detail_status.text.contains("可生产"), "同名散牌不会沿用另一组的已配齐状态")
	check(detail._detail_facts.get_child_count() >= 4, "详情按配方与产出分栏，不再重复插画")
	root.size = Vector2i(900, 600)
	for i in 3:
		await process_frame
	detail.relayout()
	detail.show_card_detail(card, Vector2(850, 580))
	check(detail._detail.position.y + detail._detail.size.y <= detail._content.position.y + detail._content.size.y + 1,
		"窄窗的长卡说明保持在牌桌内，不盖住回合操作栏")
	detail.show_facility_detail(Vector2(400, 350))
	check(not detail._detail_flavor.visible and not detail._detail_status.visible, "典当行详情不残留前一张卡的状态")
	check(StateCodec.state_hash(main.state) == state_hash, "说明和动效不改对局规则状态")
	main.queue_free()
	await process_frame
