# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 牌桌特效：结算墨团弹起、印章、封条、逃跑的小人、硬币、聚光与镜头震动。
## 只用牌桌上已有的东西：卡面墨团、和「作废」同一枚的章、用户牌与现金牌原图、纸。
## 不用辉光、渐变、模糊，也不画游戏别处没有的符号（冲击星、放射线、拟声字都已去掉）。
## 全部无碰撞、自行释放、不写规则状态；节点挂在调用方给的牌桌根上，
## 随牌桌一起暂停和释放。强度与文案只从 ui.json 的 fx 段读取。
const Motion = preload("res://scenes/ui_motion.gd")
const Materials = preload("res://scenes/effect_materials.gd")
const ConfigData = preload("res://engine/config_data.gd")
const InkStamp = preload("res://scenes/ink_stamp.gd")
## 特效浮在最高叠牌（约 1.3）之上。抬高时沿「镜头 → 目标牌」的视线挪上去，
## 而不是竖直往上：透视镜头下竖直抬 1.6，桌边的牌会和特效错开将近一张牌宽。
const LIFT := 1.6
## 目标点按桌面这个高度计；调用方传的是牌所在的桌面位置。
const GROUND_Y := 0.06
## 结算时右下效果墨团的副本弹起、变色、再落回的时长。
const BADGE_POP := 0.62
const STAMP_FADE := 0.25

## 普通一击的顿帧必须塞进原撕牌节拍（见 UIMotion.HITSTOP），只有终结一击可以更长。
const FINAL_HITSTOP_MAX := 0.4
const FALLBACK := {
	"shake": {"hit": 0.05, "hurt": 0.10, "big": 0.06, "final": 0.18},
	"hitstop": {"hit": 0.08, "final": 0.24},
	"big_output": 6,
	"stamps": {"cash": "到账", "user": "拉新", "upgrade": "升级", "legend": "传奇",
		"listing": "上市", "bankrupt": "查封", "exodus": "人去楼空", "lose": "已优化",
		"win_listing": "上市成功", "win_bankrupt": "对手破产", "win_exodus": "对手跑光", "win_resign": "对手认输"},
}

const TAPE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform vec4 paper : source_color;
uniform vec4 ink : source_color;
uniform vec4 accent : source_color;
uniform vec2 extent = vec2(3.6, 0.5);
uniform float reveal = 0.0;
uniform float opacity = 1.0;
uniform float seed = 0.0;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * extent;
	// 封条两端是手撕的毛边，贴上去时从一端拍到另一端。
	float ragged = 0.035 * sin(p.y * 40.0 + seed) + 0.02 * sin(p.y * 97.0 + seed * 3.0);
	float ends = extent.x * 0.5 - 0.06 - abs(ragged);
	float side = extent.y * 0.5 - 0.02 - 0.008 * sin(p.x * 13.0 + seed);
	float d = max(abs(p.x) - ends, abs(p.y) - side);
	float aa = max(fwidth(d), 0.002);
	float body = 1.0 - smoothstep(-aa, aa, d);
	float border = 1.0 - smoothstep(0.012 - aa, 0.012 + aa, abs(d + 0.012));
	float band = 1.0 - smoothstep(0.012 - aa, 0.012 + aa, abs(abs(p.y) - (extent.y * 0.5 - 0.10)));
	float shown = step(UV.x, reveal * 1.08);
	vec3 col = mix(paper.rgb, accent.rgb, band);
	col = mix(col, ink.rgb, border);
	ALBEDO = col;
	ALPHA = max(body, border) * shown * opacity;
}
"""

const SPOT_SHADER := """
shader_type spatial;
// 贴着桌面画、不做深度测试：聚光圈在屏幕上正好套住目标牌，高摞也一起压暗；
// 飘在上面的印章与集中线 render_priority 更高，不会被压暗。
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
uniform vec4 ink : source_color;
uniform vec2 extent = vec2(40.0, 40.0);
uniform vec2 focus = vec2(0.0);
uniform float radius = 1.6;
uniform float amount = 0.0;
void fragment() {
	vec2 p = (UV - vec2(0.5)) * extent - focus;
	// 聚光边缘按 12 fps 的手绘圈画，不做柔焦渐隐。
	float edge = radius + 0.05 * sin(atan(p.y, p.x) * 9.0);
	float d = length(p) - edge;
	float aa = max(fwidth(d), 0.002);
	float shade = smoothstep(-aa, aa, d);
	float rim = 1.0 - smoothstep(0.03 - aa, 0.03 + aa, abs(d));
	ALBEDO = ink.rgb;
	ALPHA = amount * max(shade * 0.42, rim * 0.9);
}
"""

## 墨团副本：badge_base 的形状，填成纯色（贴图本身是深墨色，直接乘颜色只会更黑）。
const BADGE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
uniform sampler2D badge : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color;
uniform float opacity = 1.0;
void fragment() {
	ALBEDO = tint.rgb;
	ALPHA = texture(badge, UV).a * opacity;
}
"""

static var _shaders: Dictionary = {}

static func rules() -> Dictionary:
	return ConfigData.overlay(FALLBACK, UIConfig.read_section("fx"))

static func stamp_text(key: String, config: Dictionary = {}) -> String:
	var table: Dictionary = (config if not config.is_empty() else rules()).get("stamps", {})
	var text := str(table.get(key, ""))
	return text if not text.is_empty() else str(FALLBACK["stamps"].get(key, key))

## 普通一击不得超过原撕牌节拍留出的余量；终结一击才允许拉长定格。
static func hitstop(kind: String, config: Dictionary = {}) -> float:
	var table: Dictionary = (config if not config.is_empty() else rules()).get("hitstop", {})
	var value := _number(table.get(kind), float(FALLBACK["hitstop"].get(kind, 0.0)))
	return clampf(value, 0.0, FINAL_HITSTOP_MAX if kind == "final" else Motion.HITSTOP)

static func shake_amount(kind: String, config: Dictionary = {}) -> float:
	var table: Dictionary = (config if not config.is_empty() else rules()).get("shake", {})
	return clampf(_number(table.get(kind), float(FALLBACK["shake"].get(kind, 0.0))), 0.0, 0.5)

static func big_output(config: Dictionary = {}) -> int:
	return maxi(1, int(_number((config if not config.is_empty() else rules()).get("big_output"), float(FALLBACK["big_output"]))))

static func _number(value: Variant, fallback: float) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else fallback

## 镜头震动只动 h/v_offset：适配、缩放与拖动都不碰这两个量，结束必归零。
## 新震动接管旧震动并取较大的幅度，连击不会叠出越来越大的偏移。
static func shake(camera: Camera3D, amplitude: float, duration := 0.30) -> Tween:
	if camera == null or not is_instance_valid(camera) or not camera.is_inside_tree():
		return null
	amplitude *= UIConfig.get_screen_shake()
	if amplitude <= 0.0005 or duration <= 0.0:
		return null
	var previous: Variant = camera.get_meta("fx_shake") if camera.has_meta("fx_shake") else null
	if previous is Tween and previous.is_valid():
		amplitude = maxf(amplitude, float(camera.get_meta("fx_shake_amplitude", 0.0)) * 0.6)
		previous.kill()
	camera.set_meta("fx_shake_amplitude", amplitude)
	var salt := Materials.rng().randf() * 100.0
	var tween := camera.create_tween()
	tween.tween_method(func(t: float) -> void:
		# 每 1/30 秒换一个方向，衰减按平方收，最后几帧几乎不动。
		var step := floorf(t * duration * 30.0)
		var decay := (1.0 - t) * (1.0 - t)
		camera.h_offset = (fposmod(sin(step * 12.9898 + salt) * 43758.5453, 1.0) * 2.0 - 1.0) * amplitude * decay
		camera.v_offset = (fposmod(sin(step * 78.233 + salt) * 24634.6345, 1.0) * 2.0 - 1.0) * amplitude * decay,
		0.0, 1.0, duration)
	tween.tween_callback(func() -> void:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
		camera.remove_meta("fx_shake_amplitude"))
	camera.set_meta("fx_shake", tween)
	return tween

## ---- 组合演出：正式牌桌、教学与动画预览共用，保证预览里看到的就是对局里的样子 ----

## 一次命中：被打的牌起折痕、撕口先裂开一道，镜头震一下；被打掉的用户跑出牌桌，
## 被打掉的现金撒成硬币。shake_kind 取 hit / hurt / final；flee 是用户逃跑的大致方向。
## 不画冲击星、放射线和拟声字：命中的感觉来自牌本身、顿帧、震动和声音。
static func hit(parent: Node3D, camera: Camera3D, cards: Array, at: Vector3, shake_kind: String,
		resource: String, flee := Vector3.ZERO, crack_time := Motion.HITSTOP) -> void:
	var config := rules()
	for card in cards:
		if is_instance_valid(card) and card is CardEntity:
			card.impact_damage(crack_time)
	shake(camera, shake_amount(shake_kind, config), 0.45 if shake_kind == "final" else 0.28)
	var count := maxi(1, cards.size())
	if resource == CardDB.RES_USER:
		runaway(parent, at, mini(count, 4), flee)
	elif resource == CardDB.RES_CASH:
		coin_spill(parent, at, mini(4 + count * 2, 14), Palette.semantic("cash"))

## 产出到账（方案 P）：核心牌右下的效果墨团「+N」弹起、换成产出资源的颜色，钱从它里面冒出来；
## 同时在核心牌上盖「到账 / 拉新」——和「作废」同一枚章。大额产出轻震一下。
## 返回墨团弹起的位置，调用方从这里撒金币 / 小人（正式牌桌要先问抽屉展开没有）。
static func production(parent: Node3D, camera: Camera3D, core: CardEntity, fallback: Vector3, cash: bool,
		amount: int, sfx: Node) -> Vector3:
	var config := rules()
	var res := CardDB.RES_CASH if cash else CardDB.RES_USER
	var color := Palette.plate_color("plate_cash" if cash else "plate_user", "accent")
	var anchor := fallback
	var text := "+%d" % amount
	if is_instance_valid(core):
		anchor = core.effect_badge_anchor()
		if core.effect_text() != "":
			text = core.effect_text()
	var pop := badge_pop(parent, anchor, text, res, color)
	if is_instance_valid(core):
		core.flash_stamp(stamp_text("cash" if cash else "user", config), 0.9, _stamp_sound(sfx))
	if amount >= big_output(config):
		shake(camera, shake_amount("big", config), 0.24)
	return pop.global_position

## 升级成型：新牌落定后在它身上盖「升级」，传说盖「传奇」并压暗牌桌、只给新牌一束光。
static func upgrade(parent: Node3D, camera: Camera3D, card: CardEntity, at: Vector3, legend: bool, sfx: Node) -> void:
	var config := rules()
	if is_instance_valid(card):
		at = card.global_position
		card.flash_stamp(stamp_text("legend" if legend else "upgrade", config), 1.1, _stamp_sound(sfx))
	if legend:
		spotlight(parent, at, 1.7, 1.0)
		shake(camera, shake_amount("big", config), 0.3)

static func _stamp_sound(sfx: Node) -> Callable:
	return func() -> void:
		if sfx != null and is_instance_valid(sfx):
			sfx.play("stamp")

## 终局在牌桌上补的一笔，按胜因：冲线在赢家现金堆上盖「上市」章，破产在输家现金堆上贴封条，
## 用户清零让输家的用户跑光。anchors 提供 winner_cash / loser_cash / loser_user 三个位置。
## 这些章与封条一直留着，由调用方在开下一局时连同 parent 一起清掉。
static func finale(parent: Node3D, camera: Camera3D, kind: String, anchors: Dictionary,
		loser_is_me: bool, sfx: Node) -> void:
	var config := rules()
	var red := Palette.semantic("danger")
	match kind:
		"listing":
			var at: Vector3 = anchors.get("winner_cash", Vector3.ZERO)
			stamp(parent, at, stamp_text("listing", config), 0.0, sfx, true, 0.25)
			shake(camera, shake_amount("big", config), 0.3)
		"bankrupt":
			# 纸条写事由，章写处置：「破产清算」+「查封」，两处不重复同一个词。
			seal(parent, anchors.get("loser_cash", Vector3.ZERO), "破产清算", stamp_text("bankrupt", config), red, sfx)
		"exodus":
			var at: Vector3 = anchors.get("loser_user", Vector3.ZERO)
			runaway(parent, at, 7, Vector3(1.0 if at.x >= 0.0 else -1.0, 0.0, 0.6 if loser_is_me else -0.6))
			stamp(parent, at, stamp_text("exodus", config), 0.0, sfx, true, 0.6)

## ---- 基础元件 ----

## 效果墨团的副本：从牌面上弹起、放大、换成资源色，停一下再缩回去淡掉。
## 牌上原来那枚不动；副本抬到牌堆之上，被压在摞里的核心牌也看得见它弹起。
static func badge_pop(parent: Node3D, at: Vector3, text: String, res: String, color: Color) -> Node3D:
	var root := _root(parent, "BadgePop", "badge_pop", at, 0.9)
	var size := CardEntity.CARD_SIZE.x * CardArt.BLOB_FRAC
	var disc := _plane(root, Vector2.ONE * size, "badge", 12, {"badge": CardArt.table_texture("badge_base"),
		"tint": color, "opacity": 1.0})
	var label := Label3D.new()
	label.name = "BadgeText"
	label.text = text
	label.font = Fonts.zh_bold()
	label.font_size = 64
	label.pixel_size = size * 0.42 / 64.0
	label.modulate = Color.WHITE
	label.outline_size = 0
	label.rotation_degrees = Vector3(-90, 0, 0)
	label.position.y = 0.01
	label.no_depth_test = true
	label.render_priority = 13
	root.add_child(label)
	var icon := Sprite3D.new()
	icon.name = "BadgeIcon"
	icon.texture = CardArt.res_icon_texture(res)
	if icon.texture != null:
		icon.pixel_size = size * 0.62 / float(icon.texture.get_width())
	icon.rotation_degrees = Vector3(-90, 0, 0)
	icon.position = Vector3(-size * 0.88, 0.01, 0.0)
	icon.no_depth_test = true
	icon.render_priority = 13
	icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	icon.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	root.add_child(icon)
	var material := disc.material_override as ShaderMaterial
	var tween := root.create_tween()
	tween.tween_property(root, "scale", Vector3.ONE * 1.7, BADGE_POP * 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(BADGE_POP * 0.35)
	tween.tween_property(root, "scale", Vector3.ONE, BADGE_POP * 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_method(func(v: float) -> void:
		material.set_shader_parameter("opacity", v)
		label.modulate.a = v
		icon.modulate.a = v, 1.0, 0.0, BADGE_POP * 0.25)
	tween.tween_callback(root.queue_free)
	return root

## 印章：与牌上的「到账 / 作废」同一枚（ink_stamp.gd：同样大小、同一盒印泥），直接盖在牌桌上，不垫小票。
## 从上方砸下、落定一刻发声并轻弹；persist 的章留在桌上直到牌桌清场，否则停 hold 秒后淡掉。
static func stamp(parent: Node3D, at: Vector3, text: String, hold := 0.7, sfx: Node = null,
		persist := false, delay := 0.0) -> Node3D:
	var root := _root(parent, "Stamp", "stamp", at, LIFT + 0.05)
	var parts := InkStamp.build(root, Vector3.ZERO, text, InkStamp.TABLE_WIDTH, 9)
	root.set_meta("stamp_parts", parts)
	var tween := InkStamp.slam(root, parts, _stamp_sound(sfx), delay)
	if not persist:
		tween.tween_interval(hold)
		tween.tween_method(func(v: float) -> void: InkStamp.set_alpha(parts, v), 1.0, 0.0, STAMP_FADE)
		tween.tween_callback(root.queue_free)
	return root

## 封条：两条交叉的纸条依次拍上去，再在交叉处盖章；终局清场时随牌桌一起移除。
## 版面三件事各占各的地方：章压在交叉处，两行字写在两条纸靠下的那一臂上，离交叉处够远，
## 不被章盖住，两行字也不互相交叉。绘制顺序全部错开：纸条一 < 字一 < 纸条二 < 字二 < 章，
## 章的纸、框和字都比纸条高，排序不会因为离镜头远近而翻转。
const SEAL_TAPE := Vector2(5.6, 0.62)
const SEAL_ANGLE := 20.0
## 字中心离交叉处的距离：章宽 2.4（歪 7°～13° 后半宽约 1.27），字半宽约 0.45，再留一点空。
const SEAL_CAPTION_AT := 2.05

static func seal(parent: Node3D, at: Vector3, caption: String, stamp_word: String, color: Color,
		sfx: Node = null) -> Node3D:
	var root := _root(parent, "Seal", "seal", at, LIFT - 0.25)
	var font := Fonts.zh_bold()
	for i in 2:
		var strip := Node3D.new()
		strip.name = "SealStrip"
		strip.rotation_degrees.y = SEAL_ANGLE if i == 0 else -SEAL_ANGLE
		strip.position.y = 0.01 * i
		root.add_child(strip)
		var tape := _plane(strip, SEAL_TAPE, "tape", 4 + i * 2, {"paper": _paper(), "ink": _ink(),
			"accent": color, "extent": SEAL_TAPE, "seed": Materials.rng().randf() * 30.0, "reveal": 0.0, "opacity": 1.0})
		var text := Label3D.new()
		text.name = "SealCaption"
		text.text = caption
		text.font = font
		text.font_size = 64
		text.pixel_size = 0.0034
		text.outline_size = 0
		text.modulate = Color(_ink(), 0.0)
		text.rotation_degrees = Vector3(-90, 0, 0)
		# 纸条一（+20°）的 -x 臂、纸条二（-20°）的 +x 臂都朝屏幕下方：两行字成一个「V」托住章。
		text.position = Vector3(-SEAL_CAPTION_AT if i == 0 else SEAL_CAPTION_AT, 0.006, 0.0)
		text.render_priority = 5 + i * 2
		strip.add_child(text)
		var material := tape.material_override as ShaderMaterial
		var tween := strip.create_tween()
		tween.tween_interval(0.18 * i)
		tween.tween_method(func(v: float) -> void:
			material.set_shader_parameter("reveal", v)
			text.modulate.a = clampf(v * 1.6 - 0.6, 0.0, 1.0), 0.0, 1.0, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 章压在交叉处正中。印章与封条同属一次清场：挂在同一父节点下。
	stamp(parent, at, stamp_word, 0.0, sfx, true, 0.52)
	return root

## 用户被打掉 / 人去楼空：简笔小人带着速度线跑出牌桌，只跑一次，跑出画面后释放。
static func runaway(parent: Node3D, at: Vector3, count: int, away: Vector3 = Vector3.ZERO) -> Node3D:
	var root := _root(parent, "Runaway", "runaway", at, 0.7)
	var longest := 0.0
	for i in clampi(count, 1, 8):
		var heading := away
		heading.y = 0.0
		if heading.length() < 0.01:
			heading = Vector3.RIGHT.rotated(Vector3.UP, Materials.rng().randf() * TAU)
		heading = heading.normalized().rotated(Vector3.UP, Materials.rng().randf_range(-0.45, 0.45))
		var runner := MeshInstance3D.new()
		runner.name = "Runner"
		runner.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * 0.62
		runner.mesh = quad
		# 朝右跑与朝左跑分两份共享材质；屏幕右方是世界 +x。
		runner.material_override = Materials.particles("runner_r" if heading.x >= 0.0 else "runner_l")
		var start := Vector3(Materials.rng().randf_range(-0.35, 0.35), 0.0, Materials.rng().randf_range(-0.3, 0.3))
		runner.position = start
		root.add_child(runner)
		var distance := Materials.rng().randf_range(6.5, 8.5)
		var duration := Materials.rng().randf_range(0.95, 1.25)
		var delay := 0.07 * i
		longest = maxf(longest, delay + duration)
		var tween := runner.create_tween()
		if delay > 0.0:
			runner.visible = false
			tween.tween_interval(delay)
			tween.tween_callback(runner.show)
		var hops := Materials.rng().randf_range(5.0, 7.0)
		tween.tween_method(func(t: float) -> void:
			var eased := t * t * (1.6 - 0.6 * t)
			runner.position = start + heading * distance * eased \
				+ Vector3.UP * absf(sin(t * PI * hops)) * 0.22, 0.0, 1.0, duration)
	var cleanup := root.create_tween()
	cleanup.tween_interval(longest + 0.05)
	cleanup.tween_callback(root.queue_free)
	return root

## 现金被打掉：一把硬币从命中处撒开。粒子包在独立的父节点里，一批命中仍只算一朵爆花。
static func coin_spill(parent: Node3D, at: Vector3, count: int, color: Color) -> Node3D:
	var root := _root(parent, "CoinSpill", "coin_spill", at, 0.55)
	Motion.play(root, "production", Vector3.ZERO, color, clampi(count, 1, 16), "coin")
	var cleanup := root.create_tween()
	cleanup.tween_interval(Motion.POP_LIFETIME + Motion.SETTLE + 0.05)
	cleanup.tween_callback(root.queue_free)
	return root

## 传说牌登场的聚光：整张牌桌压暗，只留目标一圈；不改灯光，也不遮住飘在上面的特效。
static func spotlight(parent: Node3D, at: Vector3, radius := 1.6, hold := 0.9) -> Node3D:
	var extent := Vector2(48.0, 40.0)
	var root := _root(parent, "Spotlight", "spotlight", at, GROUND_Y)
	var material := _plane(root, extent, "spot", 4, {"ink": _ink(), "extent": extent,
		"focus": Vector2.ZERO, "radius": radius, "amount": 0.0}).material_override as ShaderMaterial
	var tween := root.create_tween()
	tween.tween_method(func(v: float) -> void: material.set_shader_parameter("amount", v), 0.0, 1.0, 0.18)
	tween.tween_interval(hold)
	tween.tween_method(func(v: float) -> void: material.set_shader_parameter("amount", v), 1.0, 0.0, 0.40)
	tween.tween_callback(root.queue_free)
	return root

static func _root(parent: Node3D, kind: String, event: String, at: Vector3, height: float) -> Node3D:
	var root := Node3D.new()
	root.name = kind
	root.set_meta("motion_event", event)
	root.set_meta("target", at)
	parent.add_child(root)
	if root.is_inside_tree():
		root.global_position = over(parent, at, height)
	else:
		root.position = Vector3(at.x, height, at.z)
	return root

## 桌面点 at 正上方 height 高处、在屏幕上与 at 重合的那一点：沿视线从桌面往镜头挪。
## 没有镜头（无头测试、离屏预热）或镜头近乎平视时退回竖直抬高。
static func over(node: Node, at: Vector3, height: float) -> Vector3:
	var ground := Vector3(at.x, GROUND_Y, at.z)
	var camera: Camera3D = node.get_viewport().get_camera_3d() if node.is_inside_tree() else null
	if camera == null or not camera.is_inside_tree():
		return Vector3(at.x, height, at.z)
	var toward := camera.global_basis.z if camera.projection == Camera3D.PROJECTION_ORTHOGONAL \
		else camera.global_position - ground
	if toward.y < 0.05 * toward.length():
		return Vector3(at.x, height, at.z)
	return ground + toward * ((height - ground.y) / toward.y)

static func _plane(parent: Node3D, extent: Vector2, shader_name: String, priority: int,
		params: Dictionary) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var plane := PlaneMesh.new()
	plane.size = extent
	mesh_instance.mesh = plane
	var material := ShaderMaterial.new()
	material.shader = _shader(shader_name)
	material.render_priority = priority
	for key in params:
		material.set_shader_parameter(key, params[key])
	mesh_instance.material_override = material
	parent.add_child(mesh_instance)
	return mesh_instance

static func _shader(shader_name: String) -> Shader:
	if not _shaders.has(shader_name):
		var shader := Shader.new()
		shader.code = {"badge": BADGE_SHADER, "tape": TAPE_SHADER, "spot": SPOT_SHADER}[shader_name]
		_shaders[shader_name] = shader
	return _shaders[shader_name]

static func _ink() -> Color:
	return Palette.get_color("card", "frame")

static func _paper() -> Color:
	return Palette.semantic("surface")
