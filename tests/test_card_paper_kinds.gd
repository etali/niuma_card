# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 卡面上由代码画的那几样：纸的外形、卡身跟着外形裁切、墨团的空心与填实、传说牌的金框。
## 都不动插画；这里钉的是「哪类牌用哪种画法」和「撕开、翻面之后画法不丢」。
const CardMotion = preload("res://scenes/card_motion.gd")
const UIMotion = preload("res://scenes/ui_motion.gd")

func _initialize() -> void:
	call_deferred("_run")

func _card(world: Node3D, id: String, index: int) -> CardEntity:
	var card := CardEntity.new()
	card.setup(96000 + index, id)
	card.freeze = true
	world.add_child(card)
	card.position = Vector3(float(index) * 1.5, 0.05, 0.0)
	return card

func _run() -> void:
	print("=== 纸的外形、墨团与传说金框 ===")
	var world := Node3D.new()
	root.add_child(world)

	# ---- 哪类牌用哪种纸 ----
	check(CardArt.paper_kind("butie") == CardArt.PAPER_CUT, "攻击牌是切角纸")
	check(CardArt.paper_kind("yinqing996") == CardArt.PAPER_FOLD, "增益牌是折角纸")
	for id in ["cash", "user", "yunketang", "xinxijianfang", "shangshi", "geiwo", "idea"]:
		check(CardArt.paper_kind(id) == CardArt.PAPER_ROUND, "%s 保持圆角" % id)
	check(CardArt.is_legend("shangshi") and not CardArt.is_legend("yunketang") and not CardArt.is_legend("geiwo"),
		"只有传说牌是金框牌")

	var attack := _card(world, "butie", 0)
	var buff := _card(world, "yinqing996", 1)
	var product := _card(world, "yunketang", 2)
	var legend := _card(world, "shangshi", 3)
	for entry in [[attack, CardArt.PAPER_CUT, "攻击牌"], [buff, CardArt.PAPER_FOLD, "增益牌"], [product, CardArt.PAPER_ROUND, "生产牌"]]:
		var card: CardEntity = entry[0]
		var face := card._plate.material_override as ShaderMaterial
		check(int(face.get_shader_parameter("paper_kind")) == int(entry[1]), "%s卡面写入了自己的纸型" % entry[2])
		check(is_equal_approx(float(face.get_shader_parameter("kind_size")), CardArt.paper_size(int(entry[1]))),
			"%s卡面的切角/折角尺寸与纸型一致" % entry[2])

	# ---- 卡身跟着外形走：切掉、折掉的角下面不露出深色 ----
	for entry in [[attack, "攻击牌"], [buff, "增益牌"]]:
		var card: CardEntity = entry[0]
		var body := card.card_mesh.material_override as ShaderMaterial
		check(body != null and body.shader == load(CardEntity.BODY_SHADER), "%s的卡身按外形裁切" % entry[1])
		if body != null:
			var face := card._plate.material_override as ShaderMaterial
			check(int(body.get_shader_parameter("paper_kind")) == int(face.get_shader_parameter("paper_kind"))
				and is_equal_approx(float(body.get_shader_parameter("kind_size")), float(face.get_shader_parameter("kind_size"))),
				"%s的卡身与卡面是同一个外形" % entry[1])
			check(is_equal_approx(float(body.get_shader_parameter("body_inset")), CardEntity.PLATE_ART_INSET),
				"%s的卡身按内缩量裁切" % entry[1])
	for entry in [[product, "生产牌"], [legend, "传说牌"]]:
		check((entry[0] as CardEntity).card_mesh.material_override is StandardMaterial3D,
			"%s是圆角，卡身保持原来的平涂材质" % entry[1])

	# ---- 墨团：空心是原值，填实是凑满或翻倍 ----
	var open_texture := CardEntity._badge_texture("open")
	var solid_texture := CardEntity._badge_texture("solid")
	check(open_texture != solid_texture and open_texture == CardEntity._badge_texture("open"), "墨团底图按种类缓存，全桌共用")
	check(product._recipe_blob.texture == open_texture and product._recipe_blob.modulate == Color.WHITE
		and product._recipe_label.modulate.is_equal_approx(CardArt.frame_color()), "配方没凑满：空心圈、深色字")
	var rest_scale := product._recipe_blob.scale
	product.set_recipe_progress(product.recipe_need(), true)
	var accent := CardArt.accent_color("yunketang")
	check(product._recipe_blob.texture == solid_texture and product._recipe_blob.modulate == accent
		and product._recipe_label.modulate == Color.WHITE, "配方凑满：填成强调色、字变白")
	check(product._recipe_blob.scale.x > rest_scale.x, "配方凑满：墨团照旧放大")
	# 底图是白的，乘上强调色才真的显示成强调色（原来的黑色墨团乘完还是黑）。
	var centre := solid_texture.get_image().get_pixel(solid_texture.get_width() / 2, solid_texture.get_height() / 2)
	check(centre.r > 0.98 and centre.g > 0.98 and centre.b > 0.98, "填实用的底图中间是白的，乘色后看得出强调色")
	product.set_recipe_progress(0, false)
	check(product._recipe_blob.texture == open_texture and product._recipe_blob.modulate == Color.WHITE
		and product._recipe_label.modulate.is_equal_approx(CardArt.frame_color()) and product._recipe_blob.scale.is_equal_approx(rest_scale),
		"拆散后墨团回到空心")
	product.set_effect_mult(2)
	check(product._effect_blob.texture == solid_texture and product._effect_blob.modulate == accent
		and product._effect_label.modulate == Color.WHITE, "效果翻倍：产出墨团同样填实")
	product.set_effect_mult(1)
	check(product._effect_blob.texture == open_texture and product._effect_label.modulate.is_equal_approx(CardArt.frame_color()),
		"倍数撤掉后产出墨团回到空心")
	check(buff._plain_badges.size() == 1 and buff._plain_badges[0].blob.texture == open_texture, "卡种符号的墨团也是空心圈")

	# ---- 传说牌：金框、金印、反光 ----
	var legend_face := legend._plate.material_override as ShaderMaterial
	check(bool(legend_face.get_shader_parameter("legend_frame")), "传说牌卡面开了金框")
	check(not bool((product._plate.material_override as ShaderMaterial).get_shader_parameter("legend_frame")), "别的牌没有金框")
	check((legend_face.get_shader_parameter("foil_color") as Color).is_equal_approx(CardArt.foil_color()), "金框颜色取自配色")
	check(legend._plain_badges.size() == 1 and bool(legend._plain_badges[0].seal)
		and legend._plain_badges[0].blob.texture == CardEntity._badge_texture("seal"), "传说牌的星标是一枚金印")
	var seal_width: float = float(legend._plain_badges[0].blob.texture.get_width()) * legend._plain_badges[0].blob.pixel_size
	check(is_equal_approx(seal_width, CardEntity.CARD_SIZE.x * CardArt.BLOB_FRAC * CardEntity.SEAL_SCALE), "金印比普通墨团大一圈")
	var before: Array = get_processed_tweens()
	legend.sweep_foil()
	var sweep: Tween = null
	for tween: Tween in get_processed_tweens():
		if tween not in before and tween.is_valid():
			sweep = tween
	check(sweep != null, "传说牌的金框反光是一段补间")
	if sweep != null:
		sweep.pause()
		sweep.custom_step(CardEntity.FOIL_SWEEP * 0.5)
		var mid := float(legend_face.get_shader_parameter("foil_glint"))
		check(absf(mid - CardEntity.FOIL_REST) > 0.05 and absf(mid) < 1.0, "扫到一半时高光在牌面中间（%.2f）" % mid)
		sweep.custom_step(CardEntity.FOIL_SWEEP)
		check(is_equal_approx(float(legend_face.get_shader_parameter("foil_glint")), CardEntity.FOIL_REST), "扫完停回边角")
	before = get_processed_tweens()
	product.sweep_foil()
	check(get_processed_tweens().size() == before.size(), "不是传说牌就没有反光")

	# ---- 翻面、撕开之后外形和金框不丢 ----
	attack.set_face_down(true)
	var back := attack._plate.material_override as ShaderMaterial
	check(int(back.get_shader_parameter("paper_kind")) == CardArt.PAPER_CUT, "攻击牌翻到背面仍是切角")
	attack.set_face_down(false)
	var halves := attack.tear_apart()
	check(halves.size() == 2, "攻击牌撕成两片")
	for half in halves:
		var mesh := (half as Node3D).get_child(0) as MeshInstance3D
		var material := mesh.material_override as ShaderMaterial
		check(int(material.get_shader_parameter("paper_kind")) == CardArt.PAPER_CUT
			and is_equal_approx(float(material.get_shader_parameter("kind_size")), CardArt.PAPER_CUT_SIZE), "撕片保留切角")
		var quad := mesh.mesh as QuadMesh
		check(quad.subdivide_width >= 8 and quad.subdivide_depth >= 8, "撕片的网格细分过，才能揉成团")
		check(is_equal_approx(float(material.get_shader_parameter("ball")), 0.0), "刚撕开时还是平的")
	for half in legend.tear_apart():
		var material := ((half as Node3D).get_child(0) as MeshInstance3D).material_override as ShaderMaterial
		check(bool(material.get_shader_parameter("legend_frame")), "传说牌撕开后两片仍是金框")

	# ---- 撕开的四拍加起来正好是原来的时长 ----
	check(is_equal_approx(CardMotion.RIP_SNAP + CardMotion.RIP_FOLLOW + CardMotion.RIP_CRUMPLE + CardMotion.RIP_TOSS, CardMotion.TEAR_TIME)
		and CardMotion.RIP_TOSS > 0.1, "扯开、拖住、揉团、扔掉四拍合计等于撕牌时长")
	check(is_equal_approx(CardMotion.TEAR_TIME, UIMotion.TEAR), "撕牌时长仍取统一节拍")

	world.queue_free()
	await process_frame
	finish()
