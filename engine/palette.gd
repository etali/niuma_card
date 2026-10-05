# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Palette
extends RefCounted

## 全局配色表：配置文件 → 运行时颜色
##
## 卡牌填充、标题带、边框统一由程序 Shader 绘制，颜色仍由本表提供。
## 圆角与线宽由 CardArt 中的几何参数控制，不依赖任何底板位图。
## 语义槽位与配色结构保持兼容，玩家已有的配色无需迁移。
##
## 玩家配色 user://palette.json 覆盖 UIConfig 的 ui.json.palette。
## 出厂色板仅在 data/ui.json 保存一份，外置文件缺键也从那里补齐。

const USER_PATH := "user://palette.json"
const REPO_PATH := UIConfig.PATH

static var DEFAULTS: Dictionary:
	get:
		return UIConfig.builtin_section("palette")

## 变更广播。GDScript 不支持静态 signal，故挂在一个静态实例上：
## 面板里拖一下颜色，桌面上七十张卡要立刻跟着变，靠这个信号统一刷新
##
## RefCounted 而不是 Object：静态实例活到进程结束，`Object` 没人 free
## 就是退出时的 ObjectDB 泄漏警告（曾经在五个测试文件末尾各报一次
## 「3 ObjectDB instances were leaked」，来源就是这里）。
## 引用计数版由静态变量持着，同样活到进程结束，但退出时会自己收
class Bus extends RefCounted:
	signal changed(section: String, key: String)

static var _bus: Bus = null
static var _cfg: Dictionary = {}
static var _loaded := false

static func bus() -> Bus:
	if _bus == null:
		_bus = Bus.new()
	return _bus

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	# 仓库配置打底，玩家配置覆盖在上面
	_cfg = _merge(UIConfig.read_section("palette"), read_json(USER_PATH))

## 读一份 JSON 表，缺文件 / 打不开 / 解不出字典一律静默返回 {}。
##
## 公开的，因为 CardArt 读 art_manifest.json 也是这一套口径（缺素材就降级，
## 见 card_art.gd 顶部）。两边各写一份的话，其中一份哪天改成 push_error
## 就会让「素材没出齐也能开局」这条只在一半路径上成立。
## 不叫 CardDB.load_from 那种写法：缺 cards.json 是致命的，它得报错并返回 false
static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

## 两层深合并：section → key。够用了，配色表就两层
static func _merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for sec in over:
		var v: Variant = over[sec]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		if typeof(out.get(sec)) != TYPE_DICTIONARY:
			out[sec] = {}
		var dst: Dictionary = out[sec]
		for k in v:
			var vv: Variant = v[k]
			# plates 是三层（plates → 槽位 → face/band/...）
			if typeof(vv) == TYPE_DICTIONARY and typeof(dst.get(k)) == TYPE_DICTIONARY:
				var inner: Dictionary = dst[k]
				for kk in vv:
					inner[kk] = vv[kk]
			else:
				dst[k] = vv
	return out

## 取一个颜色。section 形如 "world"/"card"/"icon"，plates 用 plate_color()
static func get_color(section: String, key: String) -> Color:
	var s := get_string(section, key)
	return Color(s) if s != "" else Color.MAGENTA   # 洋红 = 配置漏了，肉眼可见

## HUD/交互语义色的便捷入口。统一从 semantic 槽位取色，避免场景里散落 Color(...)。
static func semantic(key: String, fallback: Color = Color.MAGENTA) -> Color:
	var s := get_string("semantic", key)
	return Color(s) if s != "" else fallback

## 消息颜色在浅色/深色面板上都可读；只调整明度，保留事件色的色相。
static func readable_ink(ink: Color, surface: Color) -> Color:
	var base := surface.srgb_to_linear().get_luminance()
	var black_ratio := (base + 0.05) / 0.05
	var white_ratio := 1.05 / (base + 0.05)
	var target := Color.BLACK if black_ratio >= white_ratio else Color.WHITE
	for step in range(21):
		var candidate := Color(ink, 1.0).lerp(target, float(step) / 20.0)
		var lum := candidate.srgb_to_linear().get_luminance()
		if (maxf(lum, base) + 0.05) / (minf(lum, base) + 0.05) >= 4.5:
			return candidate
	return target

## 取原始字符串（图标前景色的「空 = 跟随墨色」需要区分空与颜色）
static func get_string(section: String, key: String) -> String:
	_ensure_loaded()
	var sec: Variant = _cfg.get(section)
	if typeof(sec) == TYPE_DICTIONARY and (sec as Dictionary).has(key):
		return str((sec as Dictionary)[key])
	var d: Dictionary = DEFAULTS.get(section, {})
	return str(d.get(key, ""))

## 底板槽位色：slot 形如 "plate_cash"，key 为 face/band/accent/ink
static func plate_color(slot: String, key: String) -> Color:
	_ensure_loaded()
	var plates: Variant = _cfg.get("plates")
	if typeof(plates) == TYPE_DICTIONARY:
		var e: Variant = (plates as Dictionary).get(slot)
		if typeof(e) == TYPE_DICTIONARY and (e as Dictionary).has(key):
			return Color(str((e as Dictionary)[key]))
	var de: Variant = DEFAULTS["plates"].get(slot, {})
	if de is Dictionary and de.has(key):
		return Color(str(de[key]))
	return Color.MAGENTA

## 图标前景色：配置留空则回退到该卡底板的墨色（改造前的行为）
static func icon_color(ink_fallback: Color) -> Color:
	var s := get_string("icon", "foreground")
	return Color(s) if s != "" else ink_fallback

## 改一个颜色并广播。面板拖动时实时调用，不落盘
static func set_color(section: String, key: String, c: Color) -> void:
	_ensure_loaded()
	if typeof(_cfg.get(section)) != TYPE_DICTIONARY:
		_cfg[section] = {}
	(_cfg[section] as Dictionary)[key] = "#" + c.to_html(false).to_upper()
	bus().changed.emit(section, key)

static func set_plate_color(slot: String, key: String, c: Color) -> void:
	_ensure_loaded()
	if typeof(_cfg.get("plates")) != TYPE_DICTIONARY:
		_cfg["plates"] = {}
	var plates: Dictionary = _cfg["plates"]
	if typeof(plates.get(slot)) != TYPE_DICTIONARY:
		plates[slot] = {}
	(plates[slot] as Dictionary)[key] = "#" + c.to_html(false).to_upper()
	bus().changed.emit("plates", slot)

## 存到 user://palette.json。res:// 在导出包里只读，故玩家改的存 user://
static func save() -> bool:
	_ensure_loaded()
	var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if f == null:
		return false
	var out := _cfg.duplicate(true)
	out["_说明"] = "游戏内选色面板保存的配色，覆盖 ui.json.palette"
	f.store_string(JSON.stringify(out, "  ", false))
	return true

## 恢复到当前 ui.json 的配色（删掉玩家改的那份）
static func restore_defaults() -> void:
	if FileAccess.file_exists(USER_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PATH))
	_cfg = UIConfig.read_section("palette")
	_loaded = true
	bus().changed.emit("", "")

## 面板用：列出所有可调项。返回 [{section, key, label, color, is_plate, slot}]
## 分组顺序即面板里的排列顺序
static func editable_groups() -> Array:
	return [
		{ "title": "HUD 读数", "items": [
			{ "section": "hud", "key": "player", "label": "我方公司" },
			{ "section": "hud", "key": "bot",     "label": "对手公司" },
		] },
		{ "title": "交互语义", "items": [
			{ "section": "semantic", "key": "surface", "label": "面板表面" },
			{ "section": "semantic", "key": "ink", "label": "正文墨色" },
			{ "section": "semantic", "key": "muted", "label": "次要文字" },
			{ "section": "semantic", "key": "primary", "label": "主要操作" },
			{ "section": "semantic", "key": "success", "label": "成功反馈" },
			{ "section": "semantic", "key": "warning", "label": "待确认警告" },
			{ "section": "semantic", "key": "danger", "label": "危险与错误" },
			{ "section": "semantic", "key": "info", "label": "信息与连接" },
			{ "section": "semantic", "key": "focus", "label": "键盘焦点" },
			{ "section": "semantic", "key": "disabled", "label": "不可操作" },
		] },
		{ "title": "世界", "items": [
			{ "section": "world", "key": "background", "label": "游戏背景" },
			{ "section": "world", "key": "table_felt", "label": "台面" },
			{ "section": "world", "key": "table_frame", "label": "桌框" },
			{ "section": "world", "key": "market_floor", "label": "购牌区" },
		] },
		{ "title": "卡牌通用", "items": [
			{ "section": "card", "key": "frame", "label": "卡牌框架" },
			{ "section": "card", "key": "body", "label": "卡牌侧壁" },
			{ "section": "icon", "key": "foreground", "label": "图标前景" },
		] },
		{ "title": "底板", "items": _plate_items() },
	]

const PLATE_LABELS := {
	"plate_cash": "现金",
	"plate_user": "用户",
	"plate_t1_money": "用户→现金",
	"plate_t1_growth": "现金→用户",
	"plate_t3": "传说",
	"plate_attack": "攻击",
	"plate_buff_up": "增强",
	"plate_buff_def": "防御",
}

static func _plate_items() -> Array:
	var out: Array = []
	# 按 DEFAULTS 里的顺序列，面板每次打开顺序一致
	for slot in DEFAULTS["plates"]:
		if str(slot).begins_with("_") or not DEFAULTS["plates"][slot] is Dictionary:
			continue
		# 旧紫色槽位仍可读取、保存，但已没有卡牌使用，故不再提供无效果的控件。
		if slot == "plate_t2":
			continue
		var name: String = PLATE_LABELS.get(slot, slot)
		for key in ["face", "band", "accent", "ink"]:
			out.append({
				"section": "plates", "key": key, "slot": slot, "is_plate": true,
				"label": "%s·%s" % [name, {
					"face": "卡面", "band": "标题带", "accent": "强调", "ink": "墨色",
				}[key]],
			})
	return out
