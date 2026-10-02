# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 正式对局和规则演示共用的牌桌构造。托盘、市场、典当设施、灯光及卡面只建这一份。
const TableSurface = preload("res://scenes/table_surface.gd")
const TableRegions = preload("res://scenes/table_regions.gd")
const TableLighting = preload("res://scenes/table_lighting.gd")
const DrawerLayout = preload("res://scenes/drawer_table_layout.gd")
const FullLayout = preload("res://scenes/settle_layout.gd")
var host: Node3D
var drawer_mode: bool
var camera: Camera3D
var _env: Environment
var _table_mat: StandardMaterial3D
var _table_frame_mat: StandardMaterial3D
var _table_felt_lit := false

func _init(parent: Node3D, drawer: bool) -> void:
	host = parent
	drawer_mode = drawer

func create_board() -> Board:
	var board := Board.new()
	board.camera = camera
	board.pawn_pos = _pawn_position()
	board.player_min_z = 0.0
	board.player_max_z = 5.2
	host.add_child(board)
	if drawer_mode:
		var lighting := TableLighting.new()
		host.add_child(lighting)
		lighting.bind(board)
	return board

func create_layout() -> Node:
	var layout := DrawerLayout.new() if drawer_mode else FullLayout.new()
	host.add_child(layout)
	layout.bind(host)
	return layout

func _market_slot(index: int, count: int) -> Vector3:
	return TableRegions.market_slot(index, count, drawer_mode)

func _pawn_position() -> Vector3:
	return TableRegions.facility_position(int(CardDB.game_rules()["market_size"]), drawer_mode)

func refresh_palette() -> void:
	if _env:
		_env.background_color = Palette.get_color("world", "background")
	if _table_mat:
		_table_mat.albedo_color = Palette.get_color("world", "table_felt_lit" if _table_felt_lit else "table_felt")
	if _table_frame_mat:
		_table_frame_mat.albedo_color = Palette.get_color("world", "table_frame")

func _setup_environment() -> void:
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 16, 5.5)
	cam.rotation_degrees = Vector3(-71, 0, 0)
	cam.fov = 50
	host.add_child(cam)
	camera = cam

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	light.shadow_enabled = true
	light.light_energy = 1.1
	light.light_color = Color(1.0, 0.96, 0.88)  # 暖阳
	host.add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Palette.get_color("world", "background")   # 桌外的暖灰绿
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.76, 0.68)
	e.ambient_light_energy = 0.9
	env.environment = e
	_env = e
	host.add_child(env)

func _setup_table() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 0.2, 60) if drawer_mode else Vector3(34, 0.2, 22)
	shape.shape = box
	shape.position.y = -0.1
	body.add_child(shape)
	host.add_child(body)

	var mesh_inst := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(60, 0.15, 60) if drawer_mode else Vector3(34, 0.15, 22)
	mesh_inst.mesh = plane
	mesh_inst.position.y = -0.1
	var mat := StandardMaterial3D.new()
	# 台面与手绘卡面使用相同的平涂色；接触阴影独立绘制，灯光不再将绿底推成荧光色。
	mat.albedo_color = Palette.get_color("world", "table_felt")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 0.9
	mesh_inst.material_override = mat
	_table_mat = mat
	host.add_child(mesh_inst)

	# 可选台面毛毡：贴图单独铺在顶面的平面上，避免同时贴到桌子侧壁。
	var felt_tex := CardArt.table_texture("table_felt")
	if felt_tex:
		mat.albedo_color = Palette.get_color("world", "table_felt_lit")  # 侧壁配合毛毡压暗
		_table_felt_lit = true
		var felt := MeshInstance3D.new()
		var fq := QuadMesh.new()
		fq.size = Vector2(60, 60) if drawer_mode else Vector2(34, 22)
		felt.mesh = fq
		var fmat := StandardMaterial3D.new()
		fmat.albedo_texture = felt_tex
		# 与卡面底板同理：手绘平涂素材一律不受光，否则环境光+方向光把颜色顶到过曝
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		felt.material_override = fmat
		felt.rotation_degrees = Vector3(-90, 0, 0)
		felt.position = Vector3(0, -0.024, 0)
		host.add_child(felt)

	_setup_table_decor()

func _add_market_slot_frames() -> void:
	var tex := CardArt.table_texture("market_slot")
	var n: int = CardDB.game_rules()["market_size"]
	for i in n:
		var frame := TableSurface.new()
		frame.configure(Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z), "slot", tex)
		frame.name = "MarketSlot_%d" % i
		frame.position = _market_slot(i, n)
		# 空槽与静止商品卡面采用同一投影平面。贴在桌布上会因透视让边缘卡错框。
		frame.position.y += CardEntity.Y_PLATE - 0.002
		host.add_child(frame)

func _add_zone_tray(mine: bool) -> void:
	var rect := TableRegions.zone_rect(mine, drawer_mode, int(CardDB.game_rules()["market_size"]))
	var tray := TableSurface.new()
	tray.configure(rect.size, "zone", CardArt.table_texture("zone_tray"))
	tray.name = "PlayerZoneTray" if mine else "FoeZoneTray"
	tray.position = Vector3(rect.get_center().x, 0.0, rect.get_center().y)
	host.add_child(tray)

func _add_market_tray() -> void:
	var rect := TableRegions.market_rect(int(CardDB.game_rules()["market_size"]), drawer_mode)
	var tray := TableSurface.new()
	tray.configure(rect.size, "market")
	tray.position = Vector3(rect.get_center().x, 0.006, rect.get_center().y)
	host.add_child(tray)

func _setup_table_decor() -> void:
	if drawer_mode:
		_add_zone_tray(false)
		_add_zone_tray(true)
		_add_market_tray()
		_add_market_slot_frames()
		_setup_pawnshop_card()
		return
	if not drawer_mode:
		# 奶油色桌框（Stacklands 的白色描边感）
		var frame_mat := StandardMaterial3D.new()
		frame_mat.albedo_color = Palette.get_color("world", "table_frame")
		frame_mat.roughness = 0.85
		_table_frame_mat = frame_mat
		var fw := 34.0
		var fd := 22.0
		var thick := 0.35
		for spec in [
			[Vector3(fw + thick * 2, 0.06, thick), Vector3(0, 0.03, -fd / 2 - thick / 2)],
			[Vector3(fw + thick * 2, 0.06, thick), Vector3(0, 0.03, fd / 2 + thick / 2)],
			[Vector3(thick, 0.06, fd), Vector3(-fw / 2 - thick / 2, 0.03, 0)],
			[Vector3(thick, 0.06, fd), Vector3(fw / 2 + thick / 2, 0.03, 0)],
		]:
			var f := MeshInstance3D.new()
			var fm := BoxMesh.new()
			fm.size = spec[0]
			f.mesh = fm
			f.material_override = frame_mat
			f.position = spec[1]
			host.add_child(f)

	_add_market_slot_frames()

	_add_zone_tray(false)
	_add_zone_tray(true)
	_add_market_tray()
	_setup_pawnshop_card()

func _setup_pawnshop_card() -> void:
	var facility := Node3D.new()
	facility.name = "MarketFacility"
	facility.position = _pawn_position()
	host.add_child(facility)
	var card := MeshInstance3D.new()
	card.name = "PawnshopFacilityCard"
	var quad := QuadMesh.new()
	quad.size = CardArt.FRAME_SIZE
	card.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = load(CardEntity.PLATE_SHADER)
	CardArt.configure_frame(mat)
	mat.set_shader_parameter("face_color", CardArt.misc_color("pawnshop", "face", Palette.get_color("world", "table_frame")))
	mat.set_shader_parameter("band_color", CardArt.misc_color("pawnshop", "band", Palette.get_color("world", "table_frame")))
	mat.set_shader_parameter("ink_color", CardArt.frame_color())
	var art := CardArt.table_texture("pawnshop")
	mat.set_shader_parameter("has_artwork", art != null)
	if art:
		mat.set_shader_parameter("artwork", art)
	card.material_override = mat
	card.rotation_degrees = Vector3(-90, 0, 0)
	card.position.y = CardEntity.Y_PLATE
	facility.add_child(card)

	var title := _facility_label("典当行", 200)
	title.name = "FacilityName"
	var band_h := CardArt.band_frac("pawnshop") * CardEntity.CARD_SIZE.z
	CardEntity._fit_label_in_band(title, band_h)
	title.position = Vector3(0, CardEntity.Y_TEXT,
		(CardArt.band_cy("pawnshop") - 0.5) * CardEntity.CARD_SIZE.z
		- band_h * CardEntity.BAND_TEXT_FILL * CardEntity.BAND_INK_OFFSET)
	facility.add_child(title)

	# 卡内的类别标记替代价格/产出数字；卡外只留同价签位置的一行操作提示。
	var badge := _facility_label("设施", 170)
	badge.name = "FacilityBadge"
	badge.position = Vector3(0, CardEntity.Y_TEXT, 0.61)
	facility.add_child(badge)
	var action := _facility_label("拖牌换现", 200)
	action.name = "FacilityAction"
	action.position = Vector3(0, 0.15, 1.10)
	action.modulate = Palette.get_color("card", "body")
	facility.add_child(action)

func _facility_label(text: String, size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font = Fonts.zh_bold()
	label.font_size = CardEntity._raster()
	label.pixel_size = CardEntity._text_scale(size)
	label.modulate = CardArt.misc_ink_color("pawnshop")
	label.outline_size = 0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.rotation_degrees = Vector3(-90, 0, 0)
	CardEntity._fit_label(label, CardEntity.CARD_SIZE.x - 0.12)
	return label

func spawn_market_card(board: Board, idx: int, def_id: String, slot: Vector3) -> Dictionary:
	var e := CardEntity.new()
	e.setup(-1000 - idx, def_id)
	e.is_market = true
	e.set_meta("market_slot", slot)
	e.draggable = false   # 货架上的卡不可拖动，只能放现金上去购买
	e.freeze = true      # 入场由Tween独占位置，物理帧不能把卡挤离固定槽位
	e.position = slot + Vector3(0, 1.0 if drawer_mode else 2.5, 0)
	host.add_child(e)
	board.register_card(e)
	# bind_node(e) 不能省：补间是 main 建的（create_tween 挂在**这个节点**上），
	# 于是它比它动画的那张卡活得久 —— 卡被 queue_free 了补间照样跑，
	# 0.3 秒后那个回调对着一个已释放的引用赋值。
	#
	# 启动参数直接进联网局那条路每次都撞上：单机 new_game 摆完货架，
	# 紧接着 begin_net_game → _respawn_all → _clear_table 把这些卡收掉，
	# 补间还没跑完。症状不是崩，是每张货架卡刷两条错。
	#
	# **在 lambda 里加 is_instance_valid 挡不住**：引擎在调用回调之前
	# 就把失效的捕获置空并自己打一条「Lambda capture at index 0 was freed」，
	# 那条与回调体做什么无关。要让它不打，就得让补间根本不跑 ——
	# 这正是 bind_node 的作用（绑的节点没了，补间跟着停）。
	# 实测：只加守卫的话 SCRIPT ERROR 没了、那 8 条 ERROR 一条不少
	var tw := host.create_tween().bind_node(e) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	e.set_meta("dest_pos", slot)
	e.set_meta("fly_tw", tw)
	tw.tween_property(e, "position", slot, 0.3)
	tw.tween_callback(func():
		e.freeze = true
		e.remove_meta("dest_pos"))

	# 标价画在牌外的浮动价签上，不占卡面墨团：卡面右下（D 位）现在是配方进度，
	# 左下（C 位）是产出/攻击——这两个买之后一直要看，标价只在货架上有意义。
	# 价签用「¥N」而不是「标价 N」，同样是为了不往卡桌上堆中文
	var def: Dictionary = CardDB.get_def(def_id)
	var lb := Label3D.new()
	lb.text = "¥%d" % def.get("price", 0)
	lb.font = Fonts.zh_bold()
	lb.pixel_size = 0.014
	lb.font_size = 36
	lb.outline_size = 4   # 见 _setup_pawnshop：描边超字号 12% 就成空心字
	lb.outline_modulate = Color(0, 0, 0, 0.9)
	lb.modulate = Color(0.95, 0.8, 0.4)
	lb.rotation_degrees = Vector3(-90 if drawer_mode else -65, 0, 0)
	lb.position = slot + Vector3(0, 0.15, 1.1)
	host.add_child(lb)
	return {"card": e, "price": lb}

func spawn_card(board: Board, record: Dictionary, at: Vector3, draggable: bool) -> CardEntity:
	var card := CardEntity.new()
	card.setup(int(record["uid"]), str(record["def_id"]))
	card.draggable = draggable
	card.position = at
	card.rotation_degrees.y = 0
	host.add_child(card)
	board.register_card(card)
	return card
