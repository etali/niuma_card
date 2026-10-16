# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 全游戏只有这一枚章（长方形双框办公章）：牌上的「到账 / 拉新 / 升级 / 传奇 / 作废」、
## 牌桌上的「上市 / 人去楼空 / 查封」、结果面板标题旁的「上市成功 / 已优化」都从这里搭。
## 朱红印泥直接盖在纸面上：不垫纸、不描边，印泥不匀、边缘毛糙，下面的插画从麻点里透出来；
## 字用最粗一档撑满框。样式处处相同，只有大小按场合不同（牌上 / 牌桌 / 结果面板）。
##
## 框与印泥纹理是 tools/gen_stamp_art.py 生成的两张贴图；字按 ui.json 的 fx.stamps 现排：
## 每个词第一次用到时在离屏视口里画一次白字，读回成带 mipmap 的贴图缓存起来，
## 之后框和字一起经同一个着色器压上印泥纹理。3D 用 build，结果面板用 canvas_material。
const Materials = preload("res://scenes/effect_materials.gd")
const FRAME_TEXTURE := "res://assets/art/overlay/stamp_frame.png"
const GRAIN_TEXTURE := "res://assets/art/overlay/stamp_grain.png"
## 章的高宽比（框贴图 1024×379）。
const ASPECT := 379.0 / 1024.0
## 各场合的章宽（世界单位）。1280×800 牌桌上一张牌约 69px：牌上的章约 1.45 张牌宽（约 100px），
## 牌桌上的终局章约 2 张牌宽（约 138px）。
const CARD_WIDTH := 1.75
const TABLE_WIDTH := 2.4
## 结果面板里的章宽取标题字号的这个倍数（32px 标题时约 150px）。
const PANEL_PER_TITLE := 4.75
## 字的排版框，占章宽、章高的比例（双框内侧再留一点边）。
const TEXT_BOX := Vector2(0.806, 0.524)
## 两三个字分格排开，字距最多这么多个字宽；四个字放不下时先横向压扁到 SQUEEZE_MIN，再不行才缩字号。
const MAX_GAP := 0.9
const SQUEEZE_MIN := 0.72
## 汉字墨迹的中心在基线上方这么多个字号（Noto Sans SC Black 实测）。
const INK_CENTER := 0.382
## 离屏排字的分辨率：章在屏上最宽约 150px，384 足够，缩小时靠 mipmap 不闪。
const TEXT_SIZE := Vector2i(384, 142)
## 手盖的章不会每次都正：在这个范围里随机歪一点（俯视下顺时针为正）。
const TILT_MIN := 7.0
const TILT_MAX := 13.0
## 一侧按得重、一侧按得轻的程度。
const WEAR := 0.7
const FALLBACK_INK := Color("#C43428")
## 砸下：从 SLAM_SCALE 倍、高出 SLAM_LIFT × 章宽处落到原位，落定一刻回调，再轻弹一下。
const SLAM_SCALE := 1.55
const SLAM_TIME := 0.10
const SLAM_LIFT := 0.08
const BOUNCE := 1.06

## 框与字合成后压印泥纹理；3D 与 2D 共用同一段。
const STAMP_BODY := """
uniform sampler2D frame_tex : filter_linear_mipmap;
uniform sampler2D text_tex : filter_linear_mipmap;
uniform sampler2D grain_tex : filter_linear_mipmap, repeat_enable;
uniform vec4 ink : source_color = vec4(0.77, 0.2, 0.16, 1.0);
uniform float opacity = 1.0;
uniform vec2 grain_offset = vec2(0.0);
uniform vec2 press_dir = vec2(1.0, 0.0);
uniform float aspect = 0.37;
uniform float wear = 0.7;
uniform vec2 text_texel = vec2(0.0026, 0.007);
uniform vec2 text_size = vec2(384.0, 142.0);
float stamp_alpha(vec2 uv) {
	vec4 grain = texture(grain_tex, vec2(uv.x, uv.y * aspect) + grain_offset);
	vec4 frame = texture(frame_tex, uv);
	// 字：先略糊开，再按毛边噪声取阈值，边缘才像橡皮章那样不齐。
	float sharp = texture(text_tex, uv).a;
	float soft = 0.0;
	for (int i = -1; i <= 1; i++) {
		for (int j = -1; j <= 1; j++) {
			soft += texture(text_tex, uv + vec2(float(i), float(j)) * text_texel).a;
		}
	}
	soft /= 9.0;
	float threshold = 0.5 + (grain.g - 0.5) * 0.55;
	float rough = clamp((soft - threshold) / 0.12 + 0.5, 0.0, 1.0) * step(0.02, max(sharp, soft));
	// 章缩得很小时，一个屏幕像素盖住好几个字的纹素：再按像素取阈值会把细笔画啃断。
	// 这时直接用 mip 给出的覆盖率（等于大图做完毛边再缩小），放大或原大时才取毛边。
	float footprint = max(fwidth(uv.x) * text_size.x, fwidth(uv.y) * text_size.y);
	float text = mix(sharp, rough, clamp(2.2 - footprint, 0.0, 1.0));
	float shape = max(frame.a, text);
	// 贴边一圈积墨更浓（字用低一级 mip 当宽模糊）；整枚章一侧按得重、一侧按得轻。
	float wide = textureLod(text_tex, uv, 2.0).a;
	float rim = max(frame.r * frame.a, clamp(text - wide, 0.0, 1.0));
	float tilt = dot((uv - vec2(0.5)) * vec2(2.0, 2.0 * aspect), press_dir) * 0.5 + 0.5;
	float density = clamp(grain.r - 0.18 * wear * tilt + rim * 0.5, 0.0, 1.0);
	return shape * density * 0.94 * opacity;
}
"""
const SPATIAL_HEAD := """
shader_type spatial;
// 不做深度测试：盖在牌上时探出牌外的那截压在邻牌上，被同组后面的牌挡住一半就不像一枚章了。
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
"""
const SPATIAL_TAIL := """
void fragment() {
	ALBEDO = ink.rgb;
	ALPHA = stamp_alpha(UV);
}
"""
const CANVAS_HEAD := """
shader_type canvas_item;
"""
const CANVAS_TAIL := """
void fragment() {
	COLOR = vec4(ink.rgb, stamp_alpha(UV));
}
"""
static var _spatial_shader: Shader
static var _canvas_shader: Shader
## 词 → 白字贴图（带 mipmap）。贴图对象一建好就能用，离屏视口画完后原地更新内容。
static var _text_cache: Dictionary = {}

## 这枚章的印泥：ui.json 的 fx.stamp_ink（朱红）。所有场合同一盒印泥，靠字区分含义。
static func seal_ink() -> Color:
	var value := str(UIConfig.read_section("fx").get("stamp_ink", ""))
	return Color.from_string(value, FALLBACK_INK) if not value.is_empty() else FALLBACK_INK

static func spatial_shader() -> Shader:
	if _spatial_shader == null:
		_spatial_shader = Shader.new()
		_spatial_shader.code = SPATIAL_HEAD + STAMP_BODY + SPATIAL_TAIL
	return _spatial_shader

static func canvas_shader() -> Shader:
	if _canvas_shader == null:
		_canvas_shader = Shader.new()
		_canvas_shader.code = CANVAS_HEAD + STAMP_BODY + CANVAS_TAIL
	return _canvas_shader

## 在 parent 里 at 处搭一枚宽 width 的章，返回 {mesh, text}。章是 parent 的直接子节点：
## 牌上的章撕牌时要按位置分给上下片，不能套容器。priority 是绘制顺序。
static func build(parent: Node3D, at: Vector3, text: String, width: float, priority := 2) -> Dictionary:
	var mesh := MeshInstance3D.new()
	mesh.name = "InkStamp"
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(width, width * ASPECT)
	mesh.mesh = quad
	var material := ShaderMaterial.new()
	material.shader = spatial_shader()
	material.render_priority = priority
	_prime(material)
	mesh.material_override = material
	var tilt := Materials.rng().randf_range(TILT_MIN, TILT_MAX)
	mesh.rotation_degrees = Vector3(-90, -tilt, 0)
	mesh.position = at
	mesh.set_meta("stamp_rest", at)
	mesh.set_meta("stamp_tilt", tilt)
	parent.add_child(mesh)
	var parts := {"mesh": mesh, "text": ""}
	set_text(parts, text)
	return parts

## 结果面板用的材质：画的时候以 draw_texture_rect(frame) 铺满章的矩形即可。
static func canvas_material(text: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = canvas_shader()
	_prime(material)
	material.set_shader_parameter("text_tex", text_texture(text))
	return material

static func frame_texture() -> Texture2D:
	return load(FRAME_TEXTURE)

## 每枚章的印泥纹理位置、按压方向都随机一次，同一个词盖两次也不会一模一样。
static func _prime(material: ShaderMaterial) -> void:
	var rng := Materials.rng()
	material.set_shader_parameter("frame_tex", frame_texture())
	material.set_shader_parameter("grain_tex", load(GRAIN_TEXTURE))
	material.set_shader_parameter("ink", seal_ink())
	material.set_shader_parameter("grain_offset", Vector2(rng.randf(), rng.randf()))
	material.set_shader_parameter("press_dir", Vector2.RIGHT.rotated(rng.randf() * TAU))
	material.set_shader_parameter("aspect", ASPECT)
	material.set_shader_parameter("wear", WEAR)
	material.set_shader_parameter("text_texel", Vector2(1.1 / TEXT_SIZE.x, 1.1 / TEXT_SIZE.y))
	material.set_shader_parameter("text_size", Vector2(TEXT_SIZE))
	material.set_shader_parameter("opacity", 1.0)

static func material_of(parts: Dictionary) -> ShaderMaterial:
	var mesh: Variant = parts.get("mesh")
	return (mesh as MeshInstance3D).material_override as ShaderMaterial \
		if mesh is MeshInstance3D and is_instance_valid(mesh) else null

static func set_text(parts: Dictionary, text: String) -> void:
	parts["text"] = text
	var material := material_of(parts)
	if material != null:
		material.set_shader_parameter("text_tex", text_texture(text))

## 改印泥色（作废章允许调用方指定）；不传就回到这枚章的朱红。
static func paint(parts: Dictionary, ink_color := Color(0, 0, 0, 0)) -> void:
	var material := material_of(parts)
	if material != null:
		material.set_shader_parameter("ink", ink_color if ink_color.a > 0.0 else seal_ink())

static func set_alpha(parts: Dictionary, alpha: float) -> void:
	var material := material_of(parts)
	if material != null:
		material.set_shader_parameter("opacity", alpha)

## 砸下。owner 持有补间（随它暂停、释放）；delay 期间章不显示。返回补间，调用方可接着排停留与收起。
static func slam(owner: Node, parts: Dictionary, landed := Callable(), delay := 0.0) -> Tween:
	var mesh: MeshInstance3D = parts["mesh"]
	var rest: Vector3 = mesh.get_meta("stamp_rest")
	var width: float = (mesh.mesh as QuadMesh).size.x
	mesh.position = rest + Vector3.UP * SLAM_LIFT * width
	mesh.scale = Vector3.ONE * SLAM_SCALE
	set_alpha(parts, 0.0)
	var tween := owner.create_tween()
	if delay > 0.0:
		mesh.visible = false
		tween.tween_interval(delay)
		tween.tween_callback(func() -> void:
			if is_instance_valid(mesh):
				mesh.visible = true)
	tween.tween_property(mesh, "position", rest, SLAM_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(mesh, "scale", Vector3.ONE, SLAM_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_method(func(v: float) -> void: set_alpha(parts, v), 0.0, 1.0, SLAM_TIME * 0.6)
	if landed.is_valid():
		tween.tween_callback(landed)
	tween.tween_property(mesh, "scale", Vector3(BOUNCE, 1.0, BOUNCE), 0.04)
	tween.tween_property(mesh, "scale", Vector3.ONE, 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tween

## 提前把这些词排好（开局预热时调用），第一次盖章时字已经在了。
static func prewarm(words: Array) -> void:
	for word in words:
		text_texture(str(word))

## 词的白字贴图。第一次用到时先给一张空贴图（同尺寸、带 mipmap），离屏视口画完后原地更新。
static func text_texture(text: String) -> Texture2D:
	if _text_cache.has(text):
		return _text_cache[text]
	var blank := Image.create_empty(TEXT_SIZE.x, TEXT_SIZE.y, true, Image.FORMAT_RGBA8)
	var texture := ImageTexture.create_from_image(blank)
	_text_cache[text] = texture
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null or text.is_empty():
		return texture
	var baker := TextBaker.new()
	baker.texture = texture
	var writer := TextWriter.new()
	writer.text = text
	writer.size = Vector2(TEXT_SIZE)
	baker.add_child(writer)
	tree.root.add_child.call_deferred(baker)
	return texture

## 离屏排一个词：画一帧白字，读回成带 mipmap 的贴图，写进缓存里那张贴图，然后自己释放。
## 读回放在节点自己的 _process 里，不挂全局信号：场景提前清空时它随之释放，不留悬空回调。
class TextBaker extends SubViewport:
	var texture: ImageTexture
	var _frames := 0

	func _init() -> void:
		name = "InkStampText"
		size = TEXT_SIZE
		transparent_bg = true
		disable_3d = true
		render_target_update_mode = SubViewport.UPDATE_ONCE
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		# 进树那一帧末才画；再过一帧读回，保证读到的是画好的内容。
		_frames += 1
		if _frames < 2:
			return
		set_process(false)
		# 无头运行（测试、联网服务器）用的是哑渲染器：视口不会真的画，也读不回来。
		if DisplayServer.get_name() == "headless":
			queue_free()
			return
		var image := get_texture().get_image()
		if image != null and not image.is_empty() and image.get_size() == TEXT_SIZE:
			image.convert(Image.FORMAT_RGBA8)
			image.generate_mipmaps()
			texture.update(image)
		queue_free()

## 离屏排字：白字、最粗字重，字高撑满排版框；两三个字分格排开，四个字先横向压扁再缩字号。
class TextWriter extends Control:
	var text := ""

	func _draw() -> void:
		var font := Fonts.zh_black()
		var box := Vector2(size.x * TEXT_BOX.x, size.y * TEXT_BOX.y)
		var chars := text.split("")
		var count := chars.size()
		var em := box.y
		var advances := func(px: float) -> float:
			var total := 0.0
			for ch in chars:
				total += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(px)).x
			return total
		var natural: float = advances.call(em)
		var gap := 0.0
		if count > 1 and natural < box.x:
			gap = minf((box.x - natural) / float(count - 1), em * MAX_GAP)
		var width := natural + gap * float(count - 1)
		var squeeze := 1.0
		if width > box.x:
			squeeze = maxf(SQUEEZE_MIN, box.x / width)
			if width * squeeze > box.x:
				em *= box.x / (width * squeeze)
				natural = advances.call(em)
				width = natural
		var px := roundi(em)
		draw_set_transform(size * 0.5, 0.0, Vector2(squeeze, 1.0))
		var x := -width * 0.5
		for ch in chars:
			draw_string(font, Vector2(x, em * INK_CENTER), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color.WHITE)
			x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x + gap
		draw_set_transform(Vector2.ZERO)
