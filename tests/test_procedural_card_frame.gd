# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 卡牌轮廓与状态不再由母版像素决定。默认检查运行时材质与几何；
## -- --render <png> 用真实GPU验证克制手绘起伏、封闭/无孤立噪点、时间稳定性、
## 正背/撕片一致性与叠牌遮挡。验收依据输出像素，不复写shader的扰动公式。
const LEGACY_PLATE := "res://assets/art/plate/plate_master.png"
const GEOMETRY := ["card_size", "corner_radius", "border_width", "band_height", "stroke_wobble", "stroke_pressure"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 程序化卡牌轮廓 ===")
	var old_cache: Dictionary = CardArt._tex_cache.duplicate()
	# 注入“无法取得旧母版”的资源结果，不动磁盘或导入缓存。
	CardArt._tex_cache[LEGACY_PLATE] = null
	var world := Node3D.new()
	root.add_child(world)
	var count := 0
	for id in CardDB.all_cards():
		var card := _card(world, str(id), 98000 + count)
		card.position.x = 10.0 + count * 2.0
		_check_face(card)
		count += 1
	check(count == CardDB.all_cards().size() and count > 0, "当前卡表所有卡种在旧母版缺失时都有卡面")
	_check_shared_geometry(world)
	_check_palette_and_face_state(world)
	_check_without_back_art(world)
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "--render":
		await _render_checks(world, args[1])
	CardArt._tex_cache = old_cache
	world.queue_free()
	await process_frame
	finish()

func _card(world: Node3D, id: String, uid: int) -> CardEntity:
	var card := CardEntity.new()
	card.setup(uid, id)
	card.freeze = true
	world.add_child(card)
	return card

func _material(card: CardEntity) -> ShaderMaterial:
	return card._plate.material_override as ShaderMaterial if card._plate != null else null

func _geometry(material: ShaderMaterial) -> Dictionary:
	var values := {}
	if material != null:
		for key in GEOMETRY:
			values[key] = material.get_shader_parameter(key)
	return values

func _check_face(card: CardEntity) -> void:
	var mat := _material(card)
	if not need(mat != null, "%s：无旧母版仍有完整程序卡面" % card.def_id):
		return
	var uniform_names: Array = []
	for uniform in mat.shader.get_shader_uniform_list():
		uniform_names.append(str(uniform["name"]))
	check(not uniform_names.has("mask") and not uniform_names.has("cutout"),
		"%s：卡面不再采样旧毛边mask或裁切阈值" % card.def_id)
	var size: Vector2 = mat.get_shader_parameter("card_size")
	var quad: QuadMesh = card._plate.mesh
	check(size.is_equal_approx(Vector2(1.2, 1.6)) and quad.size.is_equal_approx(size),
		"%s：绘制与实体保留1.2×1.6原生3:4" % card.def_id)
	var shape: BoxShape3D = null
	for child in card.get_children():
		if child is CollisionShape3D:
			shape = child.shape
	check(shape != null and Vector2(shape.size.x, shape.size.z).is_equal_approx(size),
		"%s：点击碰撞与卡面使用相同尺寸" % card.def_id)
	var radius := float(mat.get_shader_parameter("corner_radius"))
	var border := float(mat.get_shader_parameter("border_width"))
	check(radius > border and border > 0.0 and radius < size.x * 0.5,
		"%s：圆角与描边使用有效世界尺寸" % card.def_id)
	var wobble := float(mat.get_shader_parameter("stroke_wobble"))
	var pressure := float(mat.get_shader_parameter("stroke_pressure"))
	check(wobble > 0.0 and wobble <= size.x * 0.015 and pressure > 0.0 and pressure < 0.5,
		"%s：手绘起伏启用且受限，不把线宽扰动变成破洞" % card.def_id)
	for overlay in card.face_overlays():
		if overlay is Label3D or overlay is Sprite3D:
			check(not overlay.no_depth_test, "%s：卡面文字/徽标遵守前方卡牌遮挡" % card.def_id)

func _check_shared_geometry(world: Node3D) -> void:
	var card := _card(world, "ditui", 98500)
	card.position.x = 80.0
	var face := _material(card)
	var geometry := _geometry(face)
	var band_height := float(geometry["band_height"])
	var band_center := CardArt.band_cy(card.def_id)
	var text_band := CardArt.band_frac(card.def_id)
	var size: Vector2 = geometry["card_size"]
	var top_border := float(geometry["border_width"]) / size.y
	check(text_band > 0.0 and band_center - text_band * 0.5 >= top_border - 0.0001
		and band_center + text_band * 0.5 < band_height,
		"标题文字区域位于程序标题带内，不占用外框或分隔线")
	var old_manifest: Dictionary = CardArt._manifest.duplicate(true)
	var old_loaded: bool = CardArt._loaded
	CardArt._manifest = { "misc": { "plate_master": { "band_cy": 0.95, "band_frac": 0.90 } } }
	CardArt._loaded = true
	check(is_equal_approx(CardArt.band_cy(card.def_id), band_center)
		and is_equal_approx(CardArt.band_frac(card.def_id), text_band),
		"旧manifest母版测量值不再改变标题位置")
	CardArt._manifest = old_manifest
	CardArt._loaded = old_loaded
	card.set_face_down(true)
	var back := _material(card)
	check(card._face_down and back != face, "翻面切换程序化卡背材质")
	check(_geometry(back) == geometry, "正面和背面共享尺寸、圆角、描边、标题带与手绘参数")
	check(back.get_shader_parameter("artwork") is Texture2D and bool(back.get_shader_parameter("has_artwork")),
		"程序化卡背保留已有插图")
	card.set_face_down(false)
	check(_material(card) == face, "翻回时恢复同一正面材质")
	var halves := card.tear_apart()
	check(halves.size() == 2, "无母版仍能撕成两片")
	var sides: Array = []
	for half in halves:
		var mesh: MeshInstance3D = half.get_child(0)
		var mat: ShaderMaterial = mesh.material_override
		check(_geometry(mat) == geometry, "撕片沿用正背相同手绘参数，撕口不改变外边界")
		check((mesh.mesh as QuadMesh).size.is_equal_approx(Vector2(1.2, 1.6)), "撕片仍是完整3:4画布的半边")
		sides.append(float(mat.get_shader_parameter("side")))
	sides.sort()
	check(sides == [-1.0, 1.0], "两片分别保留上下部分，不重复同一半")

func _check_palette_and_face_state(world: Node3D) -> void:
	var card := _card(world, "cash", 98501)
	card.position.x = 85.0
	var original := Palette.plate_color("plate_cash", "face")
	var changed := Color("#498174")
	var face := _material(card)
	var geometry := _geometry(face)
	card.set_face_down(true)
	Palette.set_plate_color("plate_cash", "face", changed)
	card.refresh_palette()
	card.set_highlight(true, Color(1.2, 1.1, 0.6))
	card.set_face_down(false)
	var current: Color = _material(card).get_shader_parameter("face_color")
	check(current.is_equal_approx(changed), "背面期间换色，翻回立即显示新卡面颜色")
	check(_geometry(_material(card)) == geometry, "换色不改变圆角和边框尺寸")
	var tint: Vector3 = _material(card).get_shader_parameter("tint")
	check(tint.x > 1.0 and tint.y > 1.0, "翻回后保留期间改变的高亮")
	var halves := card.tear_apart()
	for half in halves:
		var mat: ShaderMaterial = half.get_child(0).material_override
		var torn_color: Color = mat.get_shader_parameter("face_color")
		check(torn_color.is_equal_approx(changed), "撕片继承即时换色后的卡面")
		check(mat.get_shader_parameter("tint") == tint, "撕片继承当前高亮状态")
	Palette.set_plate_color("plate_cash", "face", original)

func _check_without_back_art(world: Node3D) -> void:
	var cache: Dictionary = CardArt._tex_cache.duplicate()
	for suffix in ["png", "jpg"]:
		CardArt._tex_cache["res://assets/art/table/card_back." + suffix] = null
	var card := _card(world, "cash", 98502)
	card.position.x = 90.0
	card.set_face_down(true)
	check(card._face_down and _material(card) != null, "卡背插图缺失也能翻成程序卡背")
	check(not bool(_material(card).get_shader_parameter("has_artwork")), "缺卡背插图时明确使用程序填充")
	check(not card.label.visible, "缺插图卡背不泄漏正面卡名")
	card.set_face_down(false)
	check(card.label.visible and not card._face_down, "无插图翻回仍恢复卡名")
	CardArt._tex_cache = cache

func _render_checks(world: Node3D, path: String) -> void:
	root.size = Vector2i(600, 800)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 2.4
	camera.position = Vector3(0, 8, 0)
	camera.rotation_degrees = Vector3(-90, 0, 0)
	world.add_child(camera)
	camera.make_current()
	var environment := WorldEnvironment.new()
	var config := Environment.new()
	config.background_mode = Environment.BG_COLOR
	config.background_color = Color("#B01779")
	environment.environment = config
	world.add_child(environment)
	var card := _card(world, "ditui", 98600)
	card.position = Vector3(0, 0.05, 0)
	var front := await _image()
	front.save_png(path)
	var background := front.get_pixel(0, 0)
	var front_mask := _mask(front, background)
	var outline := _bounds(front_mask, front.get_width())
	if not need(outline.size.x > 100 and outline.size.y > 100, "GPU渲染得到可采样的完整卡面"):
		return
	check(absf(float(outline.size.x) / float(outline.size.y) - 0.75) < 0.006,
		"真实渲染卡面外接框保持3:4")
	var corner := camera.unproject_position(card.to_global(Vector3(-0.596, 0.02, -0.796)))
	check(_same_color(front.get_pixelv(Vector2i(corner)), background), "程序圆角外露出背景，不存在方底或毛边残片")
	_check_hand_drawn_sides(front_mask, front.get_width(), outline)
	check(_closed_surface(front_mask, front.get_width()), "手绘轮廓围成一块封闭卡面，无孔洞或孤立毛刺噪点")
	for delay in [0.25, 0.65]:
		await create_timer(delay).timeout
		var later := await _image()
		check(front.get_data() == later.get_data(),
			"静止卡牌间隔%.2f秒后像素完全稳定，手绘纹路不随时间抖动" % delay)
	card.set_face_down(true)
	var back := await _image()
	back.save_png(path.get_basename() + "-back.png")
	check(_mask_difference(front_mask, _mask(back, background)) < 0.003,
		"真实正面与背面手绘轮廓重合，翻面不跳边")
	card.set_face_down(false)
	card.set_highlight(true, Color(1.55, 1.3, 0.45))
	var highlighted := await _image()
	card.tear_apart()
	var torn := await _image()
	torn.save_png(path.get_basename() + "-torn.png")
	check(_mask_difference(front_mask, _mask(torn, background)) < 0.003,
		"上下撕片合起时与原卡手绘外轮廓重合")
	for uv in [Vector2(0.18, 0.3), Vector2(0.18, 0.7), Vector2(0.85, 0.25)]:
		var at := camera.unproject_position(card.to_global(Vector3((uv.x - 0.5) * CardEntity.CARD_SIZE.x, 0.02, (uv.y - 0.5) * CardEntity.CARD_SIZE.z)))
		check(_same_color(highlighted.get_pixelv(Vector2i(at)), torn.get_pixelv(Vector2i(at))),
			"高亮纸面撕开后仍保持相同颜色，不跳回旧染色")
	card.queue_free()
	await process_frame
	var lower := _card(world, "ditui", 98601)
	lower.position = Vector3(0, 0.05, 0)
	var before := await _image()
	for badge in [lower._effect_label, lower._recipe_label]:
		check(_white_pixels(before, camera, badge.global_position) > 8, "遮挡前下层卡牌白字真实可见")
	var upper := _card(world, "cash", 98602)
	upper.position = lower.position + Vector3(0, 0.1, 0)
	var after := await _image()
	after.save_png(path.get_basename() + "-stacked.png")
	for badge in [lower._effect_label, lower._recipe_label]:
		check(_white_pixels(after, camera, badge.global_position) == 0, "程序卡面挡住下层白字，文字不穿透卡堆")
	print("PROCEDURAL_FRAME_SHOT -> ", path)

func _image() -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _same_color(a: Color, b: Color) -> bool:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() < 0.04

func _mask(image: Image, background: Color) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(image.get_width() * image.get_height())
	for y in image.get_height():
		for x in image.get_width():
			out[y * image.get_width() + x] = 0 if _same_color(image.get_pixel(x, y), background) else 1
	return out

func _bounds(mask: PackedByteArray, width: int) -> Rect2i:
	var left := width
	var top := mask.size() / width
	var right := -1
	var bottom := -1
	for i in mask.size():
		if mask[i] != 0:
			left = mini(left, i % width)
			right = maxi(right, i % width)
			top = mini(top, i / width)
			bottom = maxi(bottom, i / width)
	return Rect2i(left, top, right - left + 1, bottom - top + 1)

func _mask_difference(a: PackedByteArray, b: PackedByteArray) -> float:
	var different := 0
	var filled := 0
	for i in a.size():
		if a[i] != b[i]:
			different += 1
		if a[i] != 0:
			filled += 1
	return float(different) / maxf(float(filled), 1.0)

func _check_hand_drawn_sides(mask: PackedByteArray, width: int, bounds: Rect2i) -> void:
	var varying_edges := 0
	var largest_span := 0
	for edge in ["left", "right", "top", "bottom"]:
		var samples := _edge_samples(mask, width, bounds, edge)
		if not need(not samples.is_empty(), "%s边有连续可测的轮廓" % edge):
			continue
		var minimum := samples[0]
		var maximum := samples[0]
		for coordinate in samples:
			minimum = mini(minimum, coordinate)
			maximum = maxi(maximum, coordinate)
		var span := maximum - minimum
		largest_span = maxi(largest_span, span)
		if span >= 1:
			varying_edges += 1
		var largest_step := 0
		for index in range(1, samples.size()):
			largest_step = maxi(largest_step, absi(samples[index] - samples[index - 1]))
		# 每边只取中间一半，排除圆角的正常曲率；稀疏采样忽略像素量化台阶。
		var stride := maxi(2, samples.size() / 32)
		var previous_direction := 0
		var turns := 0
		for index in range(stride, samples.size(), stride):
			var direction := signi(samples[index] - samples[index - stride])
			if direction == 0:
				continue
			if previous_direction != 0 and direction != previous_direction:
				turns += 1
			previous_direction = direction
		check(span <= float(bounds.size.x) * 0.015 and largest_step <= 2 and turns <= 8,
			"%s边缓慢且克制：峰谷%dpx（不超过卡宽1.5%%），逐像素跳变%dpx，转折%d次" % [edge, span, largest_step, turns])
	check(varying_edges >= 3 and largest_span >= 2,
		"至少三条直边有可见轻微起伏，最明显一边至少2px，避免退回机械直线（%d边／%dpx）" % [varying_edges, largest_span])

func _edge_samples(mask: PackedByteArray, width: int, bounds: Rect2i, edge: String) -> PackedInt32Array:
	var vertical := edge in ["left", "right"]
	var reverse := edge in ["right", "bottom"]
	var along_start: int = bounds.position.y if vertical else bounds.position.x
	var along_size: int = bounds.size.y if vertical else bounds.size.x
	var across_start: int = bounds.position.x if vertical else bounds.position.y
	var across_size: int = bounds.size.x if vertical else bounds.size.y
	var samples := PackedInt32Array()
	for along in range(along_start + along_size / 4, along_start + along_size * 3 / 4):
		for offset in across_size:
			var across := across_start + (across_size - 1 - offset if reverse else offset)
			var index := along * width + across if vertical else across * width + along
			if mask[index] != 0:
				samples.append(across)
				break
	return samples

func _closed_surface(mask: PackedByteArray, width: int) -> bool:
	# 连通域验证允许起伏边缘在某些扫描行形成多个相连于下一行的小山峰，
	# 但不允许游离墨点或封闭孔洞；不会把手绘波浪误判成破边。
	var first := -1
	var filled := 0
	for index in mask.size():
		if mask[index] != 0:
			filled += 1
			if first < 0:
				first = index
	if first < 0 or mask[0] != 0:
		return false
	return (_flood_size(mask, width, first) == filled
		and _flood_size(mask, width, 0) == mask.size() - filled)

func _flood_size(mask: PackedByteArray, width: int, start: int) -> int:
	var seen := PackedByteArray()
	seen.resize(mask.size())
	var queue := PackedInt32Array()
	queue.resize(mask.size())
	queue[0] = start
	seen[start] = 1
	var cursor := 0
	var length := 1
	var offsets := PackedInt32Array([-width, width, -1, 1])
	while cursor < length:
		var current := queue[cursor]
		cursor += 1
		for offset in offsets:
			var next := current + offset
			if next < 0 or next >= mask.size() or absi(next % width - current % width) > 1:
				continue
			if seen[next] != 0 or mask[next] != mask[start]:
				continue
			seen[next] = 1
			queue[length] = next
			length += 1
	return length

func _white_pixels(image: Image, camera: Camera3D, point: Vector3) -> int:
	var center := camera.unproject_position(point)
	var radius := 0.1 * float(image.get_height()) / camera.size
	var white := 0
	for y in range(maxi(0, int(center.y - radius)), mini(image.get_height(), int(center.y + radius))):
		for x in range(maxi(0, int(center.x - radius)), mini(image.get_width(), int(center.x + radius))):
			var color := image.get_pixel(x, y)
			if minf(color.r, minf(color.g, color.b)) > 0.8:
				white += 1
	return white
