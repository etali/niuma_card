# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name CardEntity
extends RigidBody3D

## 单卡实体：RigidBody3D 刚体卡牌
## 拖拽时冻结物理跟随鼠标，松手恢复刚体自然落定（Stacklands 手感）

## 卡牌尺寸与碰撞使用同一 3:4 比例；画布尺寸只用于换算文字和插画布局。
const CARD_ART_SIZE := Vector2(1200.0, 1600.0)
const CARD_SIZE := Vector3(CardArt.FRAME_SIZE.x, 0.03, CardArt.FRAME_SIZE.y)

## 卡身缩在圆角轮廓内，只露薄侧壁，不会从透明角落伸出黑色方块。
const PLATE_ART_INSET := 0.05
const PLATE_SHADER := "res://shaders/card_face.gdshader"
const TEAR_SHADER := "res://shaders/card_tear.gdshader"
const BACK_SHADER := "res://shaders/card_back.gdshader"

## 卡名的行盒占「实测标题带高」的比例（见 _fit_label_in_band）。
## 注意这个比例卡的是行盒（ascent+descent），不是肉眼看到的墨迹。实测 NotoSansSC
## 在光栅字号 28 下：ascent 33 + descent 9 = 行盒 42px，而中文墨迹只占第 9..36 行
## 共 27px —— 只有行盒的 0.643。所以 0.80 的行盒实际只让墨迹填满 0.51 条带高，
## 这就是「标题字太小」的原因：留白有一半是行盒自带的空气，不是给带沿的余量。
## 取 1.15：墨迹 0.643 × 1.15 ≈ 0.74 条带高，上下各留 13% 真余量。
## 全部 31 个卡名在这个比例下都是高度受限（宽度要到 1.20 才开始有 2 个卡名先撞宽），
## 故这一个常数就能等比放大所有标题
const BAND_TEXT_FILL := 1.15

## 中文墨迹在行盒里偏下的量，占行盒高的比例：墨迹心 (9+36)/2 = 22.5px，
## 行盒心 21px，低了 1.5px = 3.6%。Label3D 居中的是行盒，带越满这点偏移越明显，
## 定位时按此把标签往上提回来
const BAND_INK_OFFSET := 1.5 / 42.0

## 墨团数字的字高，单位是 1200×1600 底板画布上的像素（换算见 _text_scale）
const BADGE_FONT_PX := 150

## 墨团圆盘的可写直径，占墨团标称直径的比例。
## badge_base 实测是填满贴图 95% 的深色实心圆盘，再给手绘毛边留一点余量
const BLOB_DISC_FRAC := 0.95 * 0.93

## Label3D 会把字形光栅化成纹理再贴到卡面。大窗口与 Retina 需要足够的
## 字形采样密度；固定使用 64px 光栅，pixel_size 反向除以同一字号，
## 因而提高纹理清晰度不会放大卡上的字，也不会挤出标题带或墨团。
const RASTER_FONT_SIZE := 64

## 世界字高和光栅采样密度分开控制，字体真实字重由 Fonts.zh_bold 提供。
static func _raster() -> int:
	return RASTER_FONT_SIZE

## 画布像素字高 → (font_size, pixel_size)：世界字高 = px/1600 × 卡高
static func _text_scale(canvas_px: int) -> float:
	return canvas_px / CARD_ART_SIZE.y * CARD_SIZE.z / float(_raster())

## 文字超出 avail 宽度时按比例缩小字号。
## 宽度要用字体实测，不能拿「字数 × 字号」估：中文一字约一个 em 尚可近似，
## 但「Buff」这种拉丁串实测只有估值的三分之一，会被误缩到极小
static func _fit_label(label: Label3D, avail: float) -> void:
	var w: float = label.font.get_string_size(
		label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, _raster()).x * label.pixel_size
	if w > avail:
		label.pixel_size *= avail / w

## 把卡名塞进标题带：按字体实测行高定字号，不用「带高 × 猜的比例」。
## 之前按带高 0.72 倍设字号，画出来仍占满整条带、上下零余量，字贴在描边和分隔线上——
## 因为 pixel_size 缩放的是行盒（ascent+descent 约 1.35 个 em），不是 em 本身，
## 0.72 的 em 折算成行盒是 0.97 倍带高。改用 get_string_size().y 就没有这个换算误差
static func _fit_label_in_band(label: Label3D, band_h: float) -> void:
	var painted: float = label.font.get_string_size(
		label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, _raster()).y * label.pixel_size
	if painted > 0.0:
		label.pixel_size *= band_h * BAND_TEXT_FILL / painted

## 把文字缩进圆形墨团：文字盒的对角线要落在盘径内。
## 不能只按宽度卡一个固定比例——圆内可用宽度随字高变化，
## 「攻9」带数字比「产7」高，实测角上余量只剩 1.3px 最先贴边
static func _fit_label_in_disc(label: Label3D, disc_d: float) -> void:
	var sz: Vector2 = label.font.get_string_size(
		label.text, HORIZONTAL_ALIGNMENT_CENTER, -1, _raster())
	var diag: float = sz.length() * label.pixel_size
	var usable: float = disc_d * BLOB_DISC_FRAC
	if diag > usable:
		label.pixel_size *= usable / diag

const Y_PLATE := 0.018
const Y_ICON := 0.022
const Y_TEXT := 0.030
const Y_OVERLAY := 0.038

## 卡面元素在卡内的抬升跨度。叠牌的 y 间距必须大于它，否则上面那张卡的底板
## 低于下面那张卡的卡名，盖不住反被穿透。见 Board.STACK_GAP
const FACE_SPAN_Y := Y_OVERLAY - Y_PLATE

var def_id := ""
var uid := -1
var dragging := false
var highlighted := false
var draggable := true    # AI 的牌不可拖
var hover_stack_member := false
var is_market := false   # 公共区的牌：拖拽用于购买，不参与堆叠

var label: Label3D
var card_mesh: MeshInstance3D
var _shield: Node3D = null    # 防御 Buff 保护标记（护盾角标）
var _void_stamp: Node3D = null # 组合作废盖章
var _void_label: Label3D = null # 素材为空章框，文字由引擎绘制
var _dimmed := false          # 可选的强调态调暗；正常对手牌不使用，见 _apply_color
var _hl_color := Color(1.2, 1.2, 0.6)
var _plate: MeshInstance3D = null   # 程序化卡面，始终存在
var _icon: Sprite3D = null
var _ink := Color(0.13, 0.13, 0.13)
var _face_elems: Array[Node3D] = []   # 卡正面元素（翻到卡背时统一隐藏）
## 翻面时暂存正面材质；正背都用共享程序轮廓，背面仅复用原插画。
var _face_up_mat: ShaderMaterial = null
var _back_mat: ShaderMaterial = null
var _face_down := false
var _shield_on := false               # 盾牌自身的开关（与翻面独立，见 set_face_down）
var _void_on := false                 # 作废盖章自身的开关
var _void_tint_override: Variant = null
var _glow: Sprite3D = null            # Buff 生效光环
var _glow_on := false
static var _buff_glow_fallback: Texture2D = null
var _recipe_label: Label3D = null     # 配方位配方进度数字（无配方的卡为 null）
var _recipe_blob: Sprite3D = null
var _recipe_blob_scale := Vector3.ONE
## 效果位效果徽标（产出 +N / 攻击 −N）。组里带翻倍 Buff 时要改写这个数，
## 所以和 配方位一样留引用 + 记基准值。没有效果格的卡（单位/Buff/传说）全为 null
var _effect_label: Label3D = null
var _effect_blob: Sprite3D = null
var _effect_blob_scale := Vector3.ONE
## 基准 pixel_size：_fit_label_in_disc 是**就地缩小**的，写完「+28」再写回「+14」
## 时若不从基准起算，字号只会越缩越小（和 _recipe_blob_scale 记基准同一个道理）
var _effect_label_px := 0.0
var _effect_base_n := 0               # 卡面自己的效果值（不含任何 Buff）
var _effect_mark := ""                # "+" 产出 / "−" 攻击
var _effect_kind := ""                # 这张卡的效果取的是 output 还是 attack
var _effect_mult := 1                 # 当前生效倍数（1 = 没有翻倍 Buff）
## 墨团旁的资源图标（着墨色）。选色面板改图标前景色时要跟着刷，故留引用
var _badge_icons: Array[Sprite3D] = []
## 卡名 + 墨团内的文字，配色变更时一起刷墨色
var _badge_labels: Array[Label3D] = []
var _recipe_need := 0
var _recipe_have := 0
var _recipe_done := false
var _illustrated := false
var _art_tween: Tween
## 交互动效只移动卡面容器。刚体/碰撞保留原比例，且不读取补间中途的 scale 作基线。
var _visual: Node3D = null
var _drag_visual_tween: Tween = null
var _visual_dragging := false
var _visual_hovered := false
var _hover_lift_allowed := true
var _visual_retired := false
var _feedback_tween: Tween
var _handling_tween: Tween
var feedback_event := ""
const FeedbackMotion = preload("res://scenes/ui_motion.gd")
const HOVER_LIFT := 0.06
const DRAG_LIFT := 0.07

func _add_visual(node: Node3D) -> void:
	if _visual == null:
		_visual = Node3D.new()
		_visual.name = "CardVisual"
		add_child(_visual)
	_visual.add_child(node)

func _ready() -> void:
	# 物理材质：高摩擦、低弹性，纸牌感
	var pmat := PhysicsMaterial.new()
	pmat.friction = 0.9
	pmat.bounce = 0.05
	physics_material_override = pmat
	# 手感：落得更快更稳，不飘；薄卡防穿桌
	gravity_scale = 3.0
	linear_damp = 2.0
	angular_damp = 4.0
	continuous_cd = true
	# 三轴全部锁定：卡牌始终平放且朝向统一（碰撞也不会转）
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true

func setup(p_uid: int, p_def_id: String) -> void:
	uid = p_uid
	def_id = p_def_id
	var def: Dictionary = CardDB.get_def(def_id)
	_ink = CardArt.ink_color(def_id)

	card_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(CARD_SIZE.x - PLATE_ART_INSET * 2.0, CARD_SIZE.y,
		CARD_SIZE.z - PLATE_ART_INSET * 2.0)
	card_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Palette.get_color("card", "body")
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	card_mesh.material_override = mat
	_add_visual(card_mesh)

	_plate = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = CardArt.FRAME_SIZE
	_plate.mesh = quad
	_plate.material_override = _make_plate_material()
	_plate.position = Vector3(0, Y_PLATE, 0)
	_plate.rotation_degrees = Vector3(-90, 0, 0)
	_add_visual(_plate)

	# 中央插画保留原色；未登记插画时回退到随配色着色的功能图标。
	var icon_tex := CardArt.illustration_texture(def_id)
	_illustrated = icon_tex != null
	if icon_tex == null:
		icon_tex = CardArt.icon_texture(def_id)
	_illustrated = _illustrated or CardArt.icon_preserves_color(icon_tex)
	if icon_tex:
		_icon = Sprite3D.new()
		_icon.texture = icon_tex
		# 精灵主体外接框已归一化顶满画布，故 pixel_size 直接按图标框宽换算
		var icon_width := 0.86 if _illustrated else CardArt.ICON_FRAC
		if def_id == CardDB.RES_CASH:
			icon_width *= 0.90
		_icon.pixel_size = CARD_SIZE.x * icon_width / float(icon_tex.get_width())
		# 图标前景色：配置留空则跟随底板墨色（改造前的行为），填了就全卡统一
		_icon.modulate = Color.WHITE if _illustrated else Palette.icon_color(_ink)
		_icon.rotation_degrees = Vector3(-90, 0, 0)
		var icon_cy := CardArt.UNIT_ICON_CY if def.get("kind") == CardDB.KIND_UNIT else CardArt.ICON_CY
		_icon.position = Vector3(0, Y_ICON, _frac_to_z(icon_cy))
		_icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		# 不能用 ALPHA_CUT_DISCARD：图标在屏上只有约 60px，1024px 线稿降采样 17 倍后
		# 边缘是软 alpha，二值化会把粉笔线切成一串点。用 alpha 混合保住线条连续
		_icon.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		_add_visual(_icon)
		_face_elems.append(_icon)

	# 卡名（A 位）：底板墨色，落在标题带上
	label = Label3D.new()
	label.text = def.get("name", "?")
	label.font = Fonts.zh_bold()
	label.font_size = _raster()
	label.pixel_size = _text_scale(200)
	var band_h: float = CardArt.band_frac(def_id) * CARD_SIZE.z
	_fit_label_in_band(label, band_h)
	_fit_label(label, CARD_SIZE.x * (1112.0 / CARD_ART_SIZE.x))
	label.outline_size = 0
	label.modulate = _ink
	var ink_fix: float = band_h * BAND_TEXT_FILL * BAND_INK_OFFSET
	label.position = Vector3(0, Y_TEXT, _frac_to_z(CardArt.band_cy(def_id)) - ink_fix)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.rotation_degrees = Vector3(-90, 0, 0)
	_add_visual(label)
	_face_elems.append(label)

	# 底部右墨团：效果 = 资源图标 + ±数量
	_add_effect_badge(def, true)
	# 底部左墨团：配方进度，未成组时 0/N；无配方的卡不画
	_add_recipe_badge(def, true)
	if has_recipe_badge():
		_add_face_note("→", CardArt.BLOB_CY, 105)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	# 碰撞厚度与卡身一致，避免冻结牌摞的隐形厚盒把旁边散卡挤入桌面。
	box_shape.size = CARD_SIZE
	shape.shape = box_shape
	add_child(shape)

## 卡面纵向比例（0=上边缘 1=下边缘）→ 卡牌本地 z 坐标
func _frac_to_z(frac: float) -> float:
	return -CARD_SIZE.z / 2.0 + frac * CARD_SIZE.z

func _add_face_note(text: String, cy: float, size_px: int, cx := 0.5) -> Label3D:
	var note := Label3D.new()
	note.text = text
	note.font = Fonts.zh_bold()
	note.font_size = _raster()
	note.pixel_size = _text_scale(size_px)
	note.outline_size = 0
	note.modulate = _ink
	note.rotation_degrees = Vector3(-90, 0, 0)
	note.position = Vector3((cx - 0.5) * CARD_SIZE.x, Y_TEXT, _frac_to_z(cy))
	_add_visual(note)
	_face_elems.append(note)
	_badge_labels.append(note)
	return note

## 墨团旁资源图标的宽度，占卡宽。定位表给的 112px（UNIT_ICON_FRAC 0.0933）是按
## 1200px 画布定的，可本作一张卡上屏只有约 113px 宽，112px 折算到屏上仅 10px——
## 线稿图标降采样到这个尺寸只剩几根断续的发丝，和旁边伪加粗的白色数字完全不匹配。
## 取 0.14（上屏约 15px，与放大后的标题字高相当）：够读出是钱袋还是人头，
## 又明显小于 0.215 的墨团，不会跟数字抢主次
const RES_ICON_FRAC := 0.14

## 资源图标与墨团边缘的间距，占卡宽。图标贴着墨团外沿放，
## 与墨团内的数字连读成「[用户] 4/7」。
## 底行一共要塞两个墨团 + 两枚图标（0.71 卡宽），只剩 0.29 分给三条缝，
## 而「图标离自己的墨团」必须明显近于「两枚图标彼此」，否则两枚图标先成一组、
## 数字和图标读不到一起去。故这条缝取小（0.02），中缝自然留到 0.10
const RES_ICON_GAP := 0.02

## 配方凑满或效果翻倍时，对应墨团换强调色并按此倍数放大。
const BADGE_DONE_SCALE := 1.12

## 资源图标中心 x：贴在墨团朝卡心那一侧的外沿。
## 不写死定位表的 UNIT_ICON_CX——那个值是按 112px 图标算的，图标一改大就会压进墨团
static func _res_icon_cx(blob_cx: float) -> float:
	var edge: float = CardArt.BLOB_FRAC / 2.0 + RES_ICON_GAP + RES_ICON_FRAC / 2.0
	return blob_cx - edge if blob_cx > 0.5 else blob_cx + edge

## 墨团徽标：墨团底 + 白字，可选在墨团外侧贴一枚资源图标。
## 返回 {blob, label}（贴图缺失时 blob 为 null），调用方需要改字或改色时留着引用
func _add_blob_badge(cx: float, text: String, textured: bool,
		res_icon: Texture2D = null, icon_cx := -1.0) -> Dictionary:
	var cy := CardArt.BLOB_CY if textured else 1.0 - 0.22 / CARD_SIZE.z
	var x := (cx - 0.5) * CARD_SIZE.x
	var z := _frac_to_z(cy)

	var badge_tex := CardArt.table_texture("badge_base") if textured else null
	var blob: Sprite3D = null
	if badge_tex:
		blob = Sprite3D.new()
		blob.texture = badge_tex
		blob.pixel_size = CARD_SIZE.x * CardArt.BLOB_FRAC / float(badge_tex.get_width())
		blob.rotation_degrees = Vector3(-90, 0, 0)
		blob.position = Vector3(x, Y_ICON, z)
		blob.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		blob.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		_add_visual(blob)
		_face_elems.append(blob)

	# 资源图标：和数字连读成「[用户] 4/7」，保留与资源牌主图相同的手绘色。
	if res_icon and textured and icon_cx >= 0.0:
		var ic := Sprite3D.new()
		ic.texture = res_icon
		ic.pixel_size = CARD_SIZE.x * RES_ICON_FRAC / float(res_icon.get_width())
		ic.modulate = CardArt.icon_tint(res_icon, _ink)
		ic.rotation_degrees = Vector3(-90, 0, 0)
		ic.position = Vector3((icon_cx - 0.5) * CARD_SIZE.x, Y_ICON, z)
		ic.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		ic.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		_add_visual(ic)
		_face_elems.append(ic)
		_badge_icons.append(ic)

	var badge := Label3D.new()
	badge.text = text
	badge.font = Fonts.zh()
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 墨团与白字都是 alpha 混合物体；斜俯视时按包围盒距离排序会把墨团
	# 画在白字之后，数字因此完全消失。白字明确晚于墨团绘制，同时保留
	# 深度测试，让前方实体卡面仍可正确遮住下面一张牌的数字。
	badge.render_priority = 1
	badge.no_depth_test = false
	badge.rotation_degrees = Vector3(-90, 0, 0)
	if badge_tex:
		# 墨团内白字：统一从 BADGE_FONT_PX 起，再实测缩进圆盘可写区。
		# 按字数分档（比如 150/118 两档）只是这件事的粗略近似，量下来「产12」仍占满
		# 标称直径 99%、「传说」124% 直接溢出圆盘
		badge.font = Fonts.zh_bold()   # 使用真实 Semibold，深墨团上的白字保持完整笔画
		badge.font_size = _raster()
		badge.pixel_size = _text_scale(BADGE_FONT_PX)
		badge.modulate = Color.WHITE
		badge.outline_size = 0
		_fit_label_in_disc(badge, CARD_SIZE.x * CardArt.BLOB_FRAC)
	else:
		badge.pixel_size = 0.0085
		badge.font_size = 34
		badge.outline_size = 8
		badge.outline_modulate = Color(1, 0.98, 0.92, 0.85)
		badge.modulate = Color(0.25, 0.18, 0.13)
	badge.position = Vector3(x, Y_TEXT, z)
	_add_visual(badge)
	_face_elems.append(badge)
	_badge_labels.append(badge)
	return { "blob": blob, "label": badge }

## 效果徽标（效果位）：资源图标 + 「+N」产出 /「−N」攻击。
## 不写「产7」「攻3」这类中文——图标表示资源种类、正负号表示产出还是攻击，
## 换语言时卡面不用改。用 U+2212 减号而不是 ASCII 连字符，宽度与 + 对齐
func _add_effect_badge(def: Dictionary, textured: bool) -> void:
	var res := ""
	var n := 0
	var mark := ""
	match def.get("kind", ""):
		CardDB.KIND_PRODUCT:
			res = def.get("output_res", "")
			n = int(def.get("output_n", 0))
			mark = "+"
			_effect_kind = "output"
		CardDB.KIND_ATTACK:
			res = def.get("attack_res", "")
			n = int(def.get("attack_n", 0))
			mark = "−"
			_effect_kind = "attack"
	if n <= 0 or res == "":
		# 没有资源增减的卡（Buff / 传说 / 单位）退回卡种符号，别让 效果位空着——
		# 桌面上认卡靠的就是这一格
		_effect_kind = ""
		_add_kind_badge(def, textured)
		return
	_effect_base_n = n
	_effect_mark = mark
	var tex := CardArt.res_icon_texture(res)
	var made := _add_blob_badge(CardArt.BLOB_R_CX if textured else 0.5,
		mark + str(n), textured, tex, _res_icon_cx(CardArt.BLOB_R_CX))
	_effect_blob = made["blob"]
	_effect_label = made["label"]
	if _effect_label:
		_effect_label_px = _effect_label.pixel_size
	if _effect_blob:
		_effect_blob_scale = _effect_blob.scale

## 这张卡有没有效果徽标（产出/攻击卡才有）
func has_effect_badge() -> bool:
	return _effect_label != null and is_instance_valid(_effect_label)

## 效果位当前显示的效果文本（无效果格返回 ""）；给测试和调试读
func effect_text() -> String:
	return _effect_label.text if has_effect_badge() else ""

## 当前生效倍数；给测试读
func effect_mult() -> int:
	return _effect_mult

## 刷新 效果位效果值：组里带了翻倍 Buff 就把卡面的数一起翻。
## 由 Board 在成组/拆组后调用，倍数取自 ComboRules.effect_multipliers ——
## 卡面和结算读同一条规则，不各自数一遍（不然会「卡面 ×2、结算发一份」）。
##
## 为什么卡面要跟着组变：这一格回答的是「打出去会发生什么」。
## 996 贴在旁边而核心还写 +1，玩家没有任何地方能读到翻倍生效了 ——
## 战报要等结算才出，那时候已经来不及据此决策。
## 卡自己的定义没被改动，改的只是这一格的显示（离组即还原）
func set_effect_mult(mult: int) -> void:
	if not has_effect_badge() or _effect_kind == "":
		return
	var m: int = maxi(mult, 1)
	if m == _effect_mult:
		return
	_effect_mult = m
	_effect_label.text = _effect_mark + str(_effect_base_n * m)
	# 字号从基准重算：位数变多（+14 → +28、+7 → +14）要重新塞进圆盘，
	# 而 _fit_label_in_disc 只会缩不会放
	_effect_label.pixel_size = _effect_label_px
	if _effect_blob:
		_fit_label_in_disc(_effect_label, CARD_SIZE.x * CardArt.BLOB_FRAC)
	# 翻倍生效：墨团换强调色并略微放大，和 配方位凑满同一套语汇
	# （桌上「这一格不是原值」只靠这一点区分）
	if _effect_blob and is_instance_valid(_effect_blob):
		_effect_blob.modulate = CardArt.accent_color(def_id) if m > 1 else Color.WHITE
		_effect_blob.scale = _effect_blob_scale * (BADGE_DONE_SCALE if m > 1 else 1.0)

## Buff / 传说卡的 效果位：这两类没有固定的资源增减，用符号 + 资源图标表示，
## 不写「Buff」「传说」（同样为了多语言化）。
## 五种 buff_type 必须各自可辨——先前一律画「×2」，等于把「保护现金」和
## 「用户翻倍」画成同一张卡。约定沿用效果格：+ 是给自己加，− 是往对手身上减，
## ◇ 是保护，配合旁边的资源图标读成「◇[用户]」「+×2[用户]」
func _add_kind_badge(def: Dictionary, textured: bool) -> void:
	var mark := ""
	var res := ""
	match def.get("kind", ""):
		CardDB.KIND_BUFF:
			match def.get("buff_type", ""):
				"user_fill":
					# 「✓/N」而不是「满[用户]」：这一格的语法是「记号 + 资源图标」＝
					# 对那种资源做了什么（+ 给自己加、− 往对手减、◇ 保护）。裂变不动资源，
					# 它免掉的是配方的**计数**，配了 [用户] 图标就成了「用户满了」——
					# 指错了对象。斜杠呼应 配方位墨团的 have/need（那里就是配方进度的写法），
					# ✓ 说这一项已满足、N 说与配方量无关。故意不配资源图标
					mark = "✓/N"
				"output_x2":
					mark = "+×2"                              # 产出翻倍（不限资源，无图标）
				"attack_x2":
					mark = "−×2"                              # 攻击翻倍
				"protect_user":
					mark = "◇"; res = CardDB.RES_USER        # 保护用户
				"protect_cash":
					mark = "◇"; res = CardDB.RES_CASH        # 保护现金
				_:
					# 不认识的 buff_type 就**不画这一格**。原先兜底成「×2」，
					# 那不是缺信息而是给错信息：一张实际没生效的卡被标成「翻倍」。
					# 空着只是少一个记号（悬停说明同样会空），
					# 加载时 CardDB._check_buff_types 已经点名警告过了
					mark = ""
		CardDB.KIND_LEGEND:
			mark = "★"
	if mark == "":
		return
	var cx: float = CardArt.BLOB_L_CX if textured else 0.5
	var tex := CardArt.res_icon_texture(res) if res != "" else null
	_add_blob_badge(cx, mark, textured, tex, _res_icon_cx(cx))

## 左下角配方进度徽标：资源图标 + 「have/need」。
## 未成组时显示 0/N；无配方的卡（单位 / Buff / 传说）不画这一格
func _add_recipe_badge(def: Dictionary, textured: bool) -> void:
	_recipe_need = int(def.get("recipe_n", 0))
	var res: String = def.get("recipe_res", "")
	if _recipe_need <= 0 or res == "":
		return
	var tex := CardArt.res_icon_texture(res)
	var made := _add_blob_badge(CardArt.BLOB_L_CX if textured else 0.5,
		"0/%d" % _recipe_need, textured, tex, _res_icon_cx(CardArt.BLOB_L_CX))
	_recipe_blob = made["blob"]
	_recipe_label = made["label"]
	if _recipe_blob:
		_recipe_blob_scale = _recipe_blob.scale

## 这张卡有没有配方进度格（单位 / Buff / 传说没有）
func has_recipe_badge() -> bool:
	return _recipe_label != null and is_instance_valid(_recipe_label)

## 配方位当前显示的进度文本（无配方格返回 ""）；给测试和调试读
func recipe_progress_text() -> String:
	return _recipe_label.text if has_recipe_badge() else ""

## 刷新配方进度。由 Board 在成组/拆组后调用，
## 与组上方的进度条读同一个 _group_progress，保证两处数字一致
func set_recipe_progress(have: int, done: bool) -> void:
	if _recipe_label == null or not is_instance_valid(_recipe_label):
		return
	_recipe_have = have
	_recipe_done = done
	_recipe_label.text = "%d/%d" % [have, _recipe_need]
	if _recipe_blob and is_instance_valid(_recipe_blob):
		# 凑满：墨团换强调色并略微放大
		_recipe_blob.modulate = CardArt.accent_color(def_id) if done else Color.WHITE
		_recipe_blob.scale = _recipe_blob_scale * (BADGE_DONE_SCALE if done else 1.0)

## 状态从 Board 的真实组合评估传入；不根据卡面数字另算一遍规则。
func recipe_status_text() -> String:
	if not has_recipe_badge():
		return ""
	if not _recipe_done:
		var resource := CardDB.card_label(str(CardDB.get_def(def_id).get("recipe_res", "")))
		return "还缺%d张%s" % [maxi(0, _recipe_need - _recipe_have), resource] if _recipe_have < _recipe_need else "组合无效，请检查材料"
	var def := CardDB.get_def(def_id)
	var n := _effect_base_n * _effect_mult
	return "可%s：%s%d%s" % ["攻击" if def.get("kind") == CardDB.KIND_ATTACK else "生产", _effect_mark, n,
		CardDB.res_label(str(def.get("attack_res" if def.get("kind") == CardDB.KIND_ATTACK else "output_res", "")))]

## 卡面材质不使用 mask/PNG；所有卡都走相同的圆角与标题分隔线。
func _make_plate_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(PLATE_SHADER)
	CardArt.configure_frame(material)
	material.set_shader_parameter("tint", Vector3.ONE)
	material.set_shader_parameter("handling_light", 0.0)
	material.set_shader_parameter("feedback_phase", 1.0)
	_push_plate_colors(material)
	return material

func _make_back_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(BACK_SHADER)
	CardArt.configure_frame(material)
	var art := CardArt.table_texture("card_back")
	material.set_shader_parameter("has_artwork", art != null)
	if art:
		material.set_shader_parameter("artwork", art)
	_push_back_colors(material)
	return material

func _push_back_colors(material: ShaderMaterial) -> void:
	material.set_shader_parameter("face_color", Palette.get_color("card", "back_face"))
	material.set_shader_parameter("ink_color", CardArt.frame_color())
	material.set_shader_parameter("artwork_ink", Palette.get_color("card", "back_ink"))

## 把当前配色写进底板材质。选色面板改一下颜色，桌上每张卡都会重走这里
func _push_plate_colors(pmat: ShaderMaterial) -> void:
	pmat.set_shader_parameter("face_color", CardArt.face_color(def_id))
	pmat.set_shader_parameter("band_color", CardArt.band_color(def_id))
	pmat.set_shader_parameter("ink_color", CardArt.frame_color())

## 墨团旁资源图标 + 墨团内文字的墨色刷新。
## 墨团内的字是白的（深色圆盘上），不跟墨色走；只有配方凑满的强调色要重取
func _refresh_badge_ink() -> void:
	for note in _badge_labels:
		if is_instance_valid(note) and note.text == "→":
			note.modulate = _ink
	for ic in _badge_icons:
		if is_instance_valid(ic):
			ic.modulate = CardArt.icon_tint(ic.texture, _ink)
	if _recipe_blob and is_instance_valid(_recipe_blob) \
		and _recipe_blob.modulate != Color.WHITE:
		_recipe_blob.modulate = CardArt.accent_color(def_id)

## 配色变更后刷新这张卡（选色面板实时预览用）
func refresh_palette() -> void:
	_ink = CardArt.ink_color(def_id)
	var front: ShaderMaterial = _face_up_mat if _face_down else (_plate.material_override as ShaderMaterial)
	if front:
		_push_plate_colors(front)
	if _back_mat:
		_push_back_colors(_back_mat)
	if card_mesh and card_mesh.material_override:
		(card_mesh.material_override as StandardMaterial3D).albedo_color = Palette.get_color("card", "body")
	if _icon:
		_icon.modulate = Color.WHITE if _illustrated else Palette.icon_color(_ink)
	if label:
		label.modulate = _ink
	_refresh_badge_ink()
	_refresh_overlay_colors()
	_apply_color()

func _refresh_overlay_colors() -> void:
	if is_instance_valid(_shield):
		_shield.modulate = Color.WHITE if _shield is Sprite3D else Palette.semantic("info")
	var tint: Color = _void_tint_override if _void_tint_override is Color else Color(Palette.semantic("danger"), 0.92)
	for overlay in [_void_stamp, _void_label]:
		if is_instance_valid(overlay):
			overlay.modulate = tint

## 高亮与调暗保存在正面材质上；翻到背面改状态后，再翻回也不会丢色。
func _apply_color() -> void:
	if _plate == null:
		return
	var tint := Color.WHITE
	if _dimmed:
		tint *= Color(0.72, 0.72, 0.78)
	if highlighted:
		tint *= _hl_color
	var front: ShaderMaterial = _face_up_mat if _face_down else (_plate.material_override as ShaderMaterial)
	if front:
		front.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))

func _stop_visual_tween() -> void:
	if _drag_visual_tween and _drag_visual_tween.is_valid():
		_drag_visual_tween.kill()
	_drag_visual_tween = null

func set_drag_visual(on: bool) -> void:
	if _visual == null or _visual_retired:
		return
	_visual_dragging = on
	_set_handling_light(1.0 if on else 0.0)
	_visual_hovered = false
	_stop_visual_tween()
	_drag_visual_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_drag_visual_tween.tween_property(_visual, "position", \
		Vector3(0, DRAG_LIFT if on else 0.0, 0), 0.12)
	if not on:
		_drag_visual_tween.tween_property(_visual, "rotation", Vector3.ZERO, 0.12)

## 位置仍由 Board 紧跟鼠标；只给卡面一个有上限且会回正的方向倾斜。
func update_drag_motion(velocity: Vector3, delta: float) -> void:
	if _visual == null or not _visual_dragging or _visual_retired:
		return
	var target := Vector3(clampf(velocity.z * 0.004, -0.045, 0.045), 0.0,
		clampf(-velocity.x * 0.004, -0.045, 0.045))
	_visual.rotation = _visual.rotation.lerp(target, 1.0 - exp(-14.0 * delta))

func set_hover_visual(on: bool, lift_allowed := true) -> void:
	if _visual == null or _visual_retired or _visual_dragging 			or (_visual_hovered == on and _hover_lift_allowed == lift_allowed):
		return
	_visual_hovered = on
	_hover_lift_allowed = lift_allowed
	_set_market_price_hover(on)
	_set_handling_light(0.35 if on else 0.0)
	_stop_visual_tween()
	_drag_visual_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_drag_visual_tween.tween_property(_visual, "position", \
		Vector3(0, HOVER_LIFT if on and lift_allowed else 0.0, 0), 0.12)
	_drag_visual_tween.tween_property(_visual, "rotation", Vector3.ZERO, 0.12)

func pulse_landed() -> void:
	if _visual == null or _visual_retired:
		return
	_visual_dragging = false
	_visual_hovered = false
	_set_handling_light(0.0)
	_stop_visual_tween()
	# 恒定回到原点；连续松手或中途又拎牌也不会积累放大/压扁。
	_drag_visual_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_drag_visual_tween.tween_property(_visual, "position", Vector3.ZERO, 0.07)
	_drag_visual_tween.parallel().tween_property(_visual, "rotation", Vector3.ZERO, 0.07)
	_drag_visual_tween.tween_property(_visual, "position:y", 0.025, 0.07)
	_drag_visual_tween.tween_property(_visual, "position:y", 0.0, 0.12)

## 飞走/撕开前清空交互通道。子元素位置始终是卡面局部坐标，撕片分配接口不变。
func reset_interaction_visual() -> void:
	_set_market_price_hover(false)
	_reset_art_motion()
	_stop_visual_tween()
	if _feedback_tween and _feedback_tween.is_valid():
		_feedback_tween.kill()
	_set_feedback_phase(1.0)
	if _handling_tween and _handling_tween.is_valid():
		_handling_tween.kill()
	var face := _feedback_material()
	if face:
		face.set_shader_parameter("handling_light", 0.0)
	_visual_dragging = false
	_visual_hovered = false
	if _visual:
		_visual.transform = Transform3D.IDENTITY

func set_highlight(on: bool, color := Color(1.2, 1.2, 0.6)) -> void:
	highlighted = on
	_hl_color = color
	_apply_color()

## 防御 Buff 保护标记：右上角护盾角标（防御卡在组合中即永久保护，on=false 时隐藏）
func set_shield(on: bool) -> void:
	var newly_protected := on and not _shield_on
	if on and _shield == null:
		var pos := Vector3(CARD_SIZE.x / 2 - 0.22, Y_OVERLAY, -CARD_SIZE.z / 2 + 0.44)
		var tex := CardArt.overlay_texture("overlay_shield")
		if tex:
			var sp := Sprite3D.new()
			sp.texture = tex
			sp.pixel_size = CARD_SIZE.x * 0.24 / float(tex.get_width())
			sp.modulate = Color.WHITE   # 简笔护盾保留自己的纸色、蓝色与墨线
			sp.rotation_degrees = Vector3(-90, 0, 0)
			sp.position = pos
			sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			sp.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
			_shield = sp
		else:
			var lb := Label3D.new()
			lb.font = Fonts.zh()
			lb.pixel_size = 0.010
			lb.font_size = 30
			lb.outline_size = 8
			lb.outline_modulate = Color(1, 0.98, 0.92, 0.9)
			lb.modulate = Palette.semantic("info")
			lb.rotation_degrees = Vector3(-90, 0, 0)
			lb.position = pos
			lb.text = "盾"
			_shield = lb
		_add_visual(_shield)
	_shield_on = on
	if _shield:
		_shield.visible = on and not _face_down
	if newly_protected:
		pulse_feedback("shield")

## Buff 卡挂进组合生效时，卡外围显示一圈着色光环。
## 素材出白环，引擎按 Buff 性质着色（增强金色、防御蓝色）。
## 素材缺失时用缓存的程序化白色圆角卡框，仍保留组内状态反馈。
func set_buff_glow(on: bool, tint := Color(1.0, 0.85, 0.35)) -> void:
	_glow_on = on
	if _glow == null:
		var tex := CardArt.overlay_texture("overlay_buff_glow")
		if tex == null and on:
			tex = _make_buff_glow_fallback()
		if tex:
			_glow = Sprite3D.new()
			_glow.texture = tex
			# 光环连晕边一起顶满画布，略放大到卡外一圈
			_glow.pixel_size = CARD_SIZE.x * 1.12 / float(tex.get_width())
			_glow.rotation_degrees = Vector3(-90, 0, 0)
			_glow.position = Vector3(0, Y_PLATE + 0.002, 0)
			_glow.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			_glow.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
			_add_visual(_glow)
	if _glow:
		_glow.modulate = tint
		_glow.visible = on and not _face_down

## O3 素材缺失时生成轻量的 3:4 圆角卡牌光环，保持 Buff 有明确反馈。
## 只生成并缓存一次 RGBA 贴图；有正式素材时完全优先使用 overlay_buff_glow.png。
static func _make_buff_glow_fallback() -> Texture2D:
	if _buff_glow_fallback:
		return _buff_glow_fallback
	const W := 240
	const H := 320
	const R := 20.0
	const BORDER := 3.0
	const HALO := 7.0
	var image := Image.create(W, H, false, Image.FORMAT_RGBA8)
	var cx := (W - 1) * 0.5
	var cy := (H - 1) * 0.5
	# Sprite 放大 1.12 倍后，框线在卡边外；内侧保持透明，不改变底板颜色。
	var half := Vector2(W * 0.5, H * 0.5) / 1.12 + Vector2(BORDER, BORDER)
	for y in H:
		for x in W:
			var p := Vector2(absf(float(x) - cx), absf(float(y) - cy))
			var q := p - (half - Vector2(R, R))
			var outside := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length()
			var inside := minf(maxf(q.x, q.y), 0.0)
			var d := outside + inside - R
			var ring := 1.0 - smoothstep(BORDER * 0.45, BORDER * 1.25, absf(d))
			var halo := (1.0 - smoothstep(BORDER, BORDER + HALO, d)) * 0.28 if d >= 0.0 else 0.0
			var alpha := clampf(maxf(ring, halo), 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	_buff_glow_fallback = ImageTexture.create_from_image(image)
	return _buff_glow_fallback


## 组合失效时在核心盖章。素材只含空框，“作废”保留为独立文字层。
func set_void_stamp(on: bool, tint: Variant = null) -> void:
	var newly_broken := on and not _void_on
	_void_on = on
	_void_tint_override = tint
	if newly_broken:
		pulse_feedback("broken")
	if on and _void_stamp == null:
		var pos := Vector3(0, Y_OVERLAY, 0.08)
		var tex := CardArt.overlay_texture("overlay_void_stamp")
		if tex:
			var sp := Sprite3D.new()
			sp.texture = tex
			sp.pixel_size = CARD_SIZE.x * 0.62 / float(tex.get_width())
			sp.rotation_degrees = Vector3(-90, -10, 0)
			sp.position = pos
			sp.render_priority = 3
			sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			sp.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
			_void_stamp = sp
			_add_visual(sp)
		var lb := Label3D.new()
		lb.text = "作废"
		lb.font = Fonts.zh_bold()
		lb.font_size = _raster()
		lb.pixel_size = _text_scale(170)
		lb.outline_size = 0
		lb.rotation_degrees = Vector3(-90, -10, 0)
		lb.position = pos
		lb.render_priority = 4
		_add_visual(lb)
		if tex:
			_void_label = lb
		else:
			_void_stamp = lb
	_refresh_overlay_colors()
	for overlay in [_void_stamp, _void_label]:
		if is_instance_valid(overlay):
			overlay.visible = on and not _face_down

## 横向撕成上下两片。外框/标题带使用共享程序轮廓，只有撕口保留锯齿纹理。
## 图标合成进撕片，文字等独立层由调用方按位置分派给各半片。
func tear_apart() -> Array:
	if _face_down:
		set_face_down(false)
	reset_interaction_visual()
	_visual_retired = true
	if _plate == null or not (_plate.material_override is ShaderMaterial):
		return []
	var src := _plate.material_override as ShaderMaterial
	var halves: Array = []
	for side in [-1.0, 1.0]:
		var piece := Node3D.new()
		piece.position = Vector3(0, Y_PLATE + 0.002, 0)
		var half := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(CARD_SIZE.x, CARD_SIZE.z)
		half.mesh = quad
		var mat := ShaderMaterial.new()
		mat.shader = load(TEAR_SHADER)
		# 正面与撕片携带同一份几何参数与配色。
		for key in CardArt.FRAME_PARAMETERS:
			mat.set_shader_parameter(key, src.get_shader_parameter(key))
		mat.set_shader_parameter("face_color", src.get_shader_parameter("face_color"))
		mat.set_shader_parameter("band_color", src.get_shader_parameter("band_color"))
		mat.set_shader_parameter("ink_color", src.get_shader_parameter("ink_color"))
		var t = src.get_shader_parameter("tint")
		mat.set_shader_parameter("tint", t if t != null else Color.WHITE)
		mat.set_shader_parameter("side", side)
		mat.set_shader_parameter("fade", 1.0)
		_feed_icon(mat)
		half.material_override = mat
		half.rotation_degrees = Vector3(-90, 0, 0)
		piece.add_child(half)
		add_child(piece)
		halves.append(piece)
	# 原底板、本体、图标一起藏掉：两片半卡已经把整张卡的样子接过去了。
	# 本体那圈侧壁留着会在撕口中间露出一条实心色；图标已经合进着色器，
	# 原来那张 Sprite3D 留着就成了「半张卡上飘着整个图标」
	_plate.visible = false
	if card_mesh:
		card_mesh.visible = false
	if _icon:
		_icon.visible = false
	return halves

## 把卡面图标喂给撕开着色器：贴图 + 它在卡面 UV 里占的矩形 + 颜色。
## 矩形从主图实际位置和显示尺寸换算，资源牌下移后撕片也保持相同位置。
## 高度要按贴图自己的长宽比折算成「占卡高」——卡不是正方形（1.2×1.6），
## 直接拿宽度那个比例当高度用，图标会被压扁
func _feed_icon(mat: ShaderMaterial) -> void:
	if _icon == null or _icon.texture == null:
		mat.set_shader_parameter("has_icon", 0.0)
		return
	var tex: Texture2D = _icon.texture
	var w_world: float = _icon.pixel_size * float(tex.get_width())
	var half_w: float = w_world / CARD_SIZE.x / 2.0
	var h_world: float = w_world * float(tex.get_height()) / float(tex.get_width())
	var half_h: float = (h_world / CARD_SIZE.z) / 2.0
	mat.set_shader_parameter("icon", tex)
	mat.set_shader_parameter("icon_rect",
		Vector4(_icon.position.x / CARD_SIZE.x + 0.5, _icon.position.z / CARD_SIZE.z + 0.5, half_w, half_h))
	mat.set_shader_parameter("icon_color", _icon.modulate)
	mat.set_shader_parameter("icon_full_color", _illustrated)
	mat.set_shader_parameter("has_icon", 1.0)

## 卡面上切不了的独立元素（卡名、墨团、角标等；图标不在内，它已合进着色器）。
## 撕开时由调用方按各自在卡上的位置分派给上片/下片带走（见 main._tear_out）
func face_overlays() -> Array:
	var out: Array = []
	for n in _face_elems:
		if is_instance_valid(n) and n != _icon:
			out.append(n)
	for extra in [label, _recipe_label, _recipe_blob, _shield, _glow, _void_stamp, _void_label]:
		if is_instance_valid(extra) and not out.has(extra):
			out.append(extra)
	for n in _badge_icons:
		if is_instance_valid(n) and not out.has(n):
			out.append(n)
	for n in _badge_labels:
		if is_instance_valid(n) and not out.has(n):
			out.append(n)
	return out

## 卡面元素在「卡面 UV.y」里的位置：0=标题带那头，1=另一头。
## 撕开时据此判断这个元素归上片还是下片（撕口在 0.5 附近）
func overlay_uv_y(n: Node3D) -> float:
	if not is_instance_valid(n):
		return 0.5
	var z: float = n.position.z
	return clampf((z + CARD_SIZE.z / 2.0) / CARD_SIZE.z, 0.0, 1.0)

## 调暗（用于区分 BOT 的牌）
func set_dimmed(on: bool) -> void:
	_dimmed = on
	_apply_color()

## 正背轮廓共用同一几何；无卡背插画时仍能翻成程序化卡背。
func set_face_down(on: bool) -> void:
	if _plate == null or _visual_retired or on == _face_down:
		return
	if on:
		reset_interaction_visual()
		_face_up_mat = _plate.material_override as ShaderMaterial
		if _back_mat == null:
			_back_mat = _make_back_material()
		_plate.material_override = _back_mat
	else:
		_plate.material_override = _face_up_mat
		_face_up_mat = null
	_face_down = on
	_apply_color()
	# 正面元素随之隐藏/恢复（盾牌也属正面）
	for n in _face_elems:
		if is_instance_valid(n):
			n.visible = not on
	if _shield:
		_shield.visible = _shield_on and not on
	if _glow:
		_glow.visible = _glow_on and not on
	for overlay in [_void_stamp, _void_label]:
		if is_instance_valid(overlay):
			overlay.visible = _void_on and not on

func _feedback_material() -> ShaderMaterial:
	if _plate == null:
		return null
	return _face_up_mat if _face_down else _plate.material_override as ShaderMaterial

func _set_feedback_phase(value: float) -> void:
	var face := _feedback_material()
	if face:
		face.set_shader_parameter("feedback_phase", value)

func _set_handling_light(amount: float) -> void:
	var face := _feedback_material()
	if face == null:
		return
	if _handling_tween and _handling_tween.is_valid():
		_handling_tween.kill()
	var current: float = face.get_shader_parameter("handling_light")
	_handling_tween = create_tween().bind_node(self)
	_handling_tween.tween_method(func(value: float): face.set_shader_parameter("handling_light", value), current, amount, FeedbackMotion.ANTICIPATE)

## 单独的材质通道，不抢拖拽/归位Tween；只由状态变化触发，不在每帧反复启动。
func pulse_feedback(event: String, tint: Color = Color.TRANSPARENT, delay := 0.0) -> void:
	if _visual_retired or _plate == null:
		return
	if _feedback_tween and _feedback_tween.is_valid():
		_feedback_tween.kill()
	feedback_event = event
	if tint == Color.TRANSPARENT:
		match event:
			"attack", "broken": tint = Palette.semantic("danger")
			"shield": tint = Palette.semantic("info")
			"produce": tint = CardArt.accent_color(def_id)
			_: tint = Palette.semantic("cash")
	var face := _feedback_material()
	face.set_shader_parameter("feedback_color", tint)
	_set_feedback_phase(1.0)
	_feedback_tween = create_tween().bind_node(self)
	if delay > 0.0:
		_feedback_tween.tween_interval(delay)
	_feedback_tween.tween_method(_set_feedback_phase, 0.0, 1.0, FeedbackMotion.ACT + FeedbackMotion.SETTLE)
	if _illustrated and event in ["produce", "attack", "upgrade", "ready"]:
		_play_art_motion(event, delay)

## 插画单独响应经营事件，不抢卡身拖拽、飞入或拾取通道。没有常驻摇摆。
func _reset_art_motion() -> void:
	if _art_tween and _art_tween.is_valid():
		_art_tween.kill()
	if _icon:
		_icon.scale = Vector3.ONE
		_icon.rotation_degrees = Vector3(-90, 0, 0)

func _play_art_motion(event: String, delay: float) -> void:
	if _icon == null or _face_down:
		return
	_reset_art_motion()
	_art_tween = create_tween().bind_node(self)
	if delay > 0.0:
		_art_tween.tween_interval(delay)
	var tilt := -0.065 if event == "attack" else 0.035
	_art_tween.tween_property(_icon, "rotation:z", tilt, FeedbackMotion.ANTICIPATE)
	_art_tween.parallel().tween_property(_icon, "scale", Vector3.ONE * 0.94, FeedbackMotion.ANTICIPATE)
	_art_tween.tween_property(_icon, "rotation:z", -tilt * 0.5, FeedbackMotion.ACT * 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_art_tween.parallel().tween_property(_icon, "scale", Vector3.ONE * 1.045, FeedbackMotion.ACT * 0.45)
	_art_tween.tween_property(_icon, "rotation:z", 0.0, FeedbackMotion.SETTLE)
	_art_tween.parallel().tween_property(_icon, "scale", Vector3.ONE, FeedbackMotion.SETTLE)

func _set_market_price_hover(on: bool) -> void:
	if not has_meta("price_tag"):
		return
	var tag_ref: Variant = get_meta("price_tag", null)
	if tag_ref is WeakRef:
		var tag: Variant = tag_ref.get_ref()
		if is_instance_valid(tag):
			tag.set_hovered(on)
