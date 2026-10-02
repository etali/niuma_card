# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name CardArt
extends RefCounted

## 卡牌插画与配色登记表。边框/标题带由共享 Shader 绘制，不读取底板 PNG。
## manifest 只提供保留插画的元数据；缺少插画时卡面、文字和碰撞仍正常。

const ART_DIR := "res://assets/art/"
const MANIFEST := ART_DIR + "art_manifest.json"

## 卡牌配色槽位，对应 data/ui.json 的 palette.plates；卡框由 Shader 绘制。
const PLATE_CASH := "plate_cash"
const PLATE_USER := "plate_user"
const PLATE_T1_MONEY := "plate_t1_money"
const PLATE_T1_GROWTH := "plate_t1_growth"
const PLATE_T2 := "plate_t2"
const PLATE_T3 := "plate_t3"
const PLATE_ATTACK := "plate_attack"
const PLATE_BUFF_UP := "plate_buff_up"
const PLATE_BUFF_DEF := "plate_buff_def"

## 卡面元素定位：将 1200×1600 设计画布上的像素值换算为归一化比例。
## 换算成比例而不是写死像素，卡牌 mesh 尺寸变化时不用改这里
const ICON_CX := 0.5           # 图标框中心 x：(240+720/2)/1200
const ICON_CY := 0.488750      # 图标框中心 y：(422+720/2)/1600
const ICON_FRAC := 0.6         # 图标框宽占卡宽：720/1200
const BAND_CY := 0.106875      # 标题带中心 y：(46+250/2)/1600
const BAND_FRAC := 0.15625     # 标题带高占卡高：250/1600
const BLOB_L_CX := 0.180833    # 左墨团中心 x：217/1200
const BLOB_R_CX := 0.819167    # 右墨团中心 x：983/1200
const BLOB_CY := 0.85          # 墨团中心 y：1360/1600
const BLOB_FRAC := 0.215       # 墨团直径占卡宽：258/1200
const UNIT_ICON_CX := 0.646667 # 单位类型图标中心 x：776/1200
const UNIT_ICON_FRAC := 0.093333  # 单位类型图标宽占卡宽：112/1200

## 卡面四色（face/band/accent/ink）的兜底值不在这里，见 Palette.DEFAULTS ——
## 颜色由配置说话，几何由程序控制，这里保留插画贴图与尺寸。

static var _manifest: Dictionary = {}
static var _tex_cache: Dictionary = {}
static var _loaded := false

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	# 读表借 Palette 那份：两边都是「缺文件就静默降级成 {}」的同一套口径
	_manifest = Palette.read_json(MANIFEST)

## def_id → 配色槽位。按 cards.json 的类别、资源、档位、产出和 Buff 类型推导，
## 同类卡牌共用配色，无需为每张卡单独维护映射。
static func plate_slot(def_id: String) -> String:
	var def: Dictionary = CardDB.get_def(def_id)
	match def.get("kind", ""):
		CardDB.KIND_UNIT:
			return PLATE_CASH if def.get("res") == CardDB.RES_CASH else PLATE_USER
		CardDB.KIND_LEGEND:
			return PLATE_T3
		CardDB.KIND_ATTACK:
			return PLATE_ATTACK
		CardDB.KIND_BUFF:
			# 防御 Buff（protect_*）走低饱和底板，与增强 Buff 形成素/艳对比
			return PLATE_BUFF_DEF if str(def.get("buff_type", "")).begins_with("protect_") \
				else PLATE_BUFF_UP
		CardDB.KIND_PRODUCT:
			if int(def.get("tier", 1)) >= 2:
				return PLATE_T2
			# T1 分两条生产线：产出现金 = 变现线，产出用户 = 拉新线（balance.md §「T1 创业产品」）
			return PLATE_T1_MONEY if def.get("output_res") == CardDB.RES_CASH \
				else PLATE_T1_GROWTH
	return PLATE_T1_MONEY

## 程序化卡框几何（世界单位）；标题带高度为卡高占比。
const FRAME_SIZE := Vector2(1.2, 1.6)
const FRAME_RADIUS := 0.10
const FRAME_BORDER := 0.025
const FRAME_WOBBLE := 0.0075
const FRAME_PRESSURE := 0.18
const FRAME_BAND_HEIGHT := 0.18
const FRAME_PARAMETERS := ["card_size", "corner_radius", "border_width", "band_height", "stroke_wobble", "stroke_pressure"]

static func configure_frame(material: ShaderMaterial, scale_factor := 1.0) -> void:
	material.set_shader_parameter("card_size", FRAME_SIZE * scale_factor)
	material.set_shader_parameter("corner_radius", FRAME_RADIUS * scale_factor)
	material.set_shader_parameter("border_width", FRAME_BORDER * scale_factor)
	material.set_shader_parameter("band_height", FRAME_BAND_HEIGHT)
	material.set_shader_parameter("stroke_wobble", FRAME_WOBBLE * scale_factor)
	material.set_shader_parameter("stroke_pressure", FRAME_PRESSURE)

## 图标贴图（纯白线稿 + 透明底，用 modulate 着成墨色）；缺失返回 null
static func icon_texture(def_id: String) -> Texture2D:
	return _load_tex(ART_DIR + "icon/icon_" + def_id + ".png")

## 资源图标（cash / user）：卡面底部用它表示产出、攻击、配方需求的资源种类，
## 替掉「产7」「攻3」这类中文，便于多语言化。
## 现金卡和用户卡的 def_id 恰好就是资源名，故直接复用单位卡的图标
static func res_icon_texture(res: String) -> Texture2D:
	if res != CardDB.RES_CASH and res != CardDB.RES_USER:
		return null
	return icon_texture(res)

## 牌桌素材：table_felt / zone_tray / market_slot / pawnshop / card_back / log_panel / badge_base
## 先尝试支持透明度的 .png，再尝试用于不透明台面等素材的 .jpg。
static func table_texture(name: String) -> Texture2D:
	var tex := _load_tex(ART_DIR + "table/" + name + ".png")
	if tex == null:
		tex = _load_tex(ART_DIR + "table/" + name + ".jpg")
	return tex

## 覆盖标记：overlay_shield / overlay_void_stamp / overlay_buff_glow
static func overlay_texture(name: String) -> Texture2D:
	return _load_tex(ART_DIR + "overlay/" + name + ".png")

## 以下四色一律走 Palette（data/ui.json 的 palette 段 + 游戏内选色面板），不读 manifest：
## 卡面填充与轮廓都在 Shader 中绘制，插画不会改变配置色。

## 墨色：卡名/图标/数字的颜色
static func ink_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "ink")

## 卡面填充色
static func face_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "face")

## 标题带填充色
static func band_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "band")

## 强调色：用于配方凑满、效果翻倍时的墨团和产出反馈。
static func accent_color(def_id: String) -> Color:
	return Palette.plate_color(plate_slot(def_id), "accent")

## 程序边框与标题分隔线共用的墨色
static func frame_color() -> Color:
	return Palette.get_color("card", "frame")

## 标题文字按程序化标题带的内边界对齐，不依赖旧母版的测量文件。
static func band_cy(_def_id: String) -> float:
	var top := FRAME_BORDER / FRAME_SIZE.y
	var bottom := FRAME_BAND_HEIGHT - FRAME_BORDER * 0.5 / FRAME_SIZE.y
	return (top + bottom) * 0.5

static func band_frac(_def_id: String) -> float:
	return FRAME_BAND_HEIGHT - FRAME_BORDER * 1.5 / FRAME_SIZE.y

## 整卡素材（典当行等 misc 里的 1200×1600 图）的标题带位置
static func misc_band_cy(name: String) -> float:
	return _num(_misc_entry(name), "band_cy", BAND_CY)

static func misc_band_frac(name: String) -> float:
	return _num(_misc_entry(name), "band_frac", BAND_FRAC)

## 已有设施插画的配色元数据，不参与程序卡框几何。
static func misc_color(name: String, key: String, fallback: Color) -> Color:
	var value: Variant = _field(_misc_entry(name), key)
	return Color(str(value)) if value != null else fallback

## 整卡素材的墨色（实测卡面色决定用暗墨还是米白）
static func misc_ink_color(name: String, fallback := Color(0.13, 0.13, 0.13)) -> Color:
	var v: Variant = _field(_misc_entry(name), "ink")
	return Color(str(v)) if v != null else fallback

static func _misc_entry(name: String) -> Dictionary:
	_ensure_loaded()
	var misc: Dictionary = _manifest.get("misc", {})
	var entry: Variant = misc.get(name, {})
	return entry if typeof(entry) == TYPE_DICTIONARY else {}

static func _field(entry: Dictionary, key: String) -> Variant:
	return entry[key] if entry.has(key) else null

static func _num(entry: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = _field(entry, key)
	return float(v) if v != null else fallback

static func _load_tex(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			tex = res
	_tex_cache[path] = tex
	return tex
