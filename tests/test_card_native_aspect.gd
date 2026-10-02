# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 程序化卡面、实体卡和碰撞必须使用同一比例，不能靠镜头俯角抵消几何变形。
## 可选可视检查：Godot -s tests/test_card_native_aspect.gd -- --render <输出png> [俯角] [镜头跨度]
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 卡牌原生比例与文字采样 ===")
	var world := Node3D.new()
	root.add_child(world)
	var cards: Array[CardEntity] = []
	for id in ["cash", "ditui", "liulianghe", "butie"]:
		var card := CardEntity.new()
		card.setup(97000 + cards.size(), id)
		card.freeze = true
		world.add_child(card)
		card.position = Vector3((float(cards.size()) - 1.5) * 1.45, 0.05, 0.0)
		cards.append(card)
		_check_card(card)
	check(CardEntity._raster() == 64, "3D 字形使用 64px 采样密度")
	check(is_equal_approx(CardEntity._text_scale(200) * float(CardEntity._raster()), 0.2),
		"200px 卡面文字仍占 0.2 世界单位，采样提升不放大字")

	var card := cards[2]
	var front_mesh: QuadMesh = card._plate.mesh
	card.set_face_down(true)
	var back: ShaderMaterial = card._plate.material_override
	var artwork: Texture2D = back.get_shader_parameter("artwork")
	check(artwork != null and bool(back.get_shader_parameter("has_artwork")), "翻面保留真实卡背插图")
	var back_size: Vector2 = back.get_shader_parameter("card_size")
	check(front_mesh.size.is_equal_approx(back_size) and is_equal_approx(back_size.x / back_size.y, 0.75),
		"程序化卡背轮廓与正面都是同一张3:4卡")
	card.set_face_down(false)
	var halves := card.tear_apart()
	check(halves.size() == 2, "原生比例卡仍能撕成两片")
	for half in halves:
		var mesh: MeshInstance3D = half.get_child(0)
		var quad: QuadMesh = mesh.mesh
		check(quad.size.is_equal_approx(Vector2(1.2, 1.6)), "撕片平面保持 1.2×1.6 原生卡面")
		var material: ShaderMaterial = mesh.material_override
		var icon_rect: Vector4 = material.get_shader_parameter("icon_rect")
		var icon_world_width := icon_rect.z * 2.0 * quad.size.x
		var icon_world_height := icon_rect.w * 2.0 * quad.size.y
		check(is_equal_approx(icon_world_width, icon_world_height), "撕开合成的方形图标保持正方形")

	# 截图用新的未撕卡替换测试卡，展示正常效果与已凑齐的配方数字。
	world.remove_child(card)
	card.free()
	card = CardEntity.new()
	card.setup(97100, "liulianghe")
	card.freeze = true
	world.add_child(card)
	card.position = Vector3(0.725, 0.05, 0.0)
	cards[2] = card
	card.set_effect_mult(CardDB.buff_mult("output_x2"))
	card.set_recipe_progress(int(CardDB.get_def(card.def_id)["recipe_n"]), true)
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "--render":
		await _render_closeup(world, args[1], float(args[2]) if args.size() > 2 else 90.0,
			float(args[3]) if args.size() > 3 else 3.0)
	world.queue_free()
	await process_frame
	finish()

func _check_card(card: CardEntity) -> void:
	var id := card.def_id
	check(card.scale.is_equal_approx(Vector3.ONE) and card._visual.scale.is_equal_approx(Vector3.ONE),
		"%s 根节点与视觉节点均不补偿缩放" % id)
	var quad: QuadMesh = card._plate.mesh
	var material: ShaderMaterial = card._plate.material_override
	var frame_size: Vector2 = material.get_shader_parameter("card_size")
	check(is_equal_approx(frame_size.x / frame_size.y, 0.75), "%s 程序化轮廓是3:4" % id)
	check(quad.size.is_equal_approx(Vector2(1.2, 1.6)), "%s 正面网格为1.2×1.6" % id)
	check(quad.size.is_equal_approx(frame_size), "%s shader轮廓与网格使用相同世界尺寸" % id)
	var shape: BoxShape3D = null
	for child in card.get_children():
		if child is CollisionShape3D:
			shape = child.shape
	check(shape != null, "%s 保留碰撞体" % id)
	if shape:
		check(Vector2(shape.size.x, shape.size.z).is_equal_approx(quad.size), "%s 碰撞与视觉卡面边界一致" % id)
	var body_bounds := card.card_mesh.mesh.get_aabb()
	check(body_bounds.size.x < quad.size.x and body_bounds.size.z < quad.size.y,
		"%s 卡身内缩，不从程序化轮廓外露出方角" % id)
	var text_size := card.label.font.get_string_size(card.label.text, HORIZONTAL_ALIGNMENT_CENTER, -1,
		card.label.font_size) * card.label.pixel_size
	var inner_width := quad.size.x - 2.0 * float(material.get_shader_parameter("border_width"))
	check(text_size.x <= inner_width + 0.001, "%s 提升采样后卡名仍完整落入标题带" % id)
	for badge in [card._effect_label, card._recipe_label]:
		if badge == null:
			continue
		check(badge.modulate.is_equal_approx(Color.WHITE) and badge.visible,
			"%s 墨团数字保持可见白色" % id)
		var glyph_extent: Vector2 = badge.font.get_string_size(badge.text,
			HORIZONTAL_ALIGNMENT_CENTER, -1, badge.font_size) * badge.pixel_size
		check(glyph_extent.length() <= 1.2 * CardArt.BLOB_FRAC * CardEntity.BLOB_DISC_FRAC + 0.001,
			"%s 墨团数字完整落入圆盘" % id)
		check(badge.position.y > CardEntity.Y_ICON, "%s 墨团数字位于圆盘上方" % id)
		check(badge.render_priority > 0 and not badge.no_depth_test,
			"%s 白字后于墨团绘制，且仍受前方实体卡遮挡" % id)

func _render_closeup(world: Node3D, path: String, pitch := 90.0, span := 3.0) -> void:
	root.size = Vector2i(2000, 1000)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = span
	camera.position = Vector3(0, 8 * sin(deg_to_rad(pitch)), 8 * cos(deg_to_rad(pitch)))
	camera.rotation_degrees = Vector3(-pitch, 0, 0)
	world.add_child(camera)
	var environment := WorldEnvironment.new()
	var config := Environment.new()
	config.background_mode = Environment.BG_COLOR
	config.background_color = Palette.get_color("world", "table_felt")
	environment.environment = config
	world.add_child(environment)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	check(image.save_png(path) == OK, "四卡原生比例与文字截图已保存")
	print("CARD_NATIVE_ASPECT_SHOT -> ", path, " ", image.get_size())
	for child in world.get_children():
		if not (child is CardEntity):
			continue
		for badge in [child._effect_label, child._recipe_label]:
			if badge != null:
				check(_white_pixels(image, camera, badge.global_position) > 8,
					"%s 卡面数字在真实渲染中可见白色像素" % child.def_id)

	# 前面的现金实体盖住后方地推卡：后绘制的白字也必须遵守深度遮挡。
	var covered: CardEntity = null
	for child in world.get_children():
		if child is CardEntity and child.def_id == "ditui":
			covered = child
	var blocker := CardEntity.new()
	blocker.setup(97200, "cash")
	blocker.freeze = true
	world.add_child(blocker)
	blocker.position = covered.position + Vector3(0.0, 0.1, 0.0)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var stacked := root.get_texture().get_image()
	for badge in [covered._effect_label, covered._recipe_label]:
		check(_white_pixels(stacked, camera, badge.global_position) == 0,
			"前方实体卡会遮住下层白字，数字不穿透卡堆")
	stacked.save_png(path.get_basename() + "-stacked.png")

func _white_pixels(image: Image, camera: Camera3D, world_position: Vector3) -> int:
	var center := camera.unproject_position(world_position)
	var radius := 0.11 * float(image.get_height()) / camera.size
	var left := maxi(0, int(floor(center.x - radius)))
	var right := mini(image.get_width(), int(ceil(center.x + radius)))
	var top := maxi(0, int(floor(center.y - radius)))
	var bottom := mini(image.get_height(), int(ceil(center.y + radius)))
	var white := 0
	for y in range(top, bottom):
		for x in range(left, right):
			var color := image.get_pixel(x, y)
			if minf(color.r, minf(color.g, color.b)) > 0.8:
				white += 1
	return white
