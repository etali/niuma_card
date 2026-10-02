# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Fonts
extends RefCounted

## 共享中文字体。项目内置 Noto Sans SC 是 wght 100–900 的可变字体，
## 文件的默认实例是 Thin（100），不能把直接 load 的结果当成 Regular。
## 使用字体设计的真实字重，让细笔画和字腔在小字号下仍然清楚。

static var _source: Font = null
static var _font: Font = null
static var _bold: Font = null

const BUNDLED_FONT := "res://assets/fonts/NotoSansSC.ttf"
const REGULAR_WEIGHT := 400
const SEMIBOLD_WEIGHT := 600
## OpenType 的 wght 标签。Godot 接受整数标签或友好名 "weight"，
## 但字符串 "wght" 在部分版本只会留在属性里，底层实际仍使用默认字重。
const WEIGHT_AXIS := 0x77676874
## 保留旧接口；真实字重不再叠加描边式伪加粗。
const EMBOLDEN := 0.0

static func zh() -> Font:
	if _font == null:
		_font = _weighted_font(REGULAR_WEIGHT)
	return _font

static func zh_bold() -> Font:
	if _bold == null:
		_bold = _weighted_font(SEMIBOLD_WEIGHT)
	return _bold

## 源目录可读 TTF 时直接交给 FontFile，避免残留 .import 指向已删除的缓存。
## 导出包通常只有 .fontdata，此时仍按 Godot 资源映射读取正式导入资源。
static func _load_source_font(path: String) -> Font:
	if FileAccess.file_exists(path):
		var file := FontFile.new()
		if file.load_dynamic_font(path) == OK:
			_apply_import_options(file, path)
			return file
	if ResourceLoader.exists(path):
		var imported: Resource = load(path)
		if imported is Font:
			return imported
	return null

## 直接读源字体也沿用导入器的绘制选项，避免开发环境与导出包字形采样不同。
static func _apply_import_options(font: FontFile, path: String) -> void:
	var settings := ConfigFile.new()
	if not FileAccess.file_exists(path + ".import") or settings.load(path + ".import") != OK:
		return
	for property in ["antialiasing", "generate_mipmaps", "disable_embedded_bitmaps",
		"multichannel_signed_distance_field", "msdf_pixel_range", "msdf_size",
		"allow_system_fallback", "force_autohinter", "modulate_color_glyphs",
		"keep_rounding_remainders", "oversampling"]:
		if settings.has_section_key("params", property):
			font.set(property, settings.get_value("params", property))
	# 导入器的“Except Pixel Fonts”是额外选项，不是FontFile枚举值。
	# Noto Sans SC为矢量可变字体，按同一导入器的非像素分支转换。
	if settings.has_section_key("params", "hinting"):
		var hinting: int = settings.get_value("params", "hinting")
		font.hinting = TextServer.HINTING_LIGHT if hinting == 3 else (TextServer.HINTING_NORMAL if hinting == 4 else hinting)
	if settings.has_section_key("params", "subpixel_positioning"):
		var subpixel: int = settings.get_value("params", "subpixel_positioning")
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO if subpixel == 4 else subpixel
	if settings.has_section_key("params", "opentype_features"):
		font.opentype_feature_overrides = settings.get_value("params", "opentype_features")

static func _weighted_font(weight: int) -> Font:
	if _source == null:
		_source = _load_source_font(BUNDLED_FONT)
	# ResourceLoader.exists 只证明路径有映射，不证明映射目标能加载。
	# 必须取得实际字体，才能建立 FontVariation；null 基底会静默退回默认字体。
	if _source != null:
		var variation := FontVariation.new()
		variation.base_font = _source
		variation.variation_opentype = {WEIGHT_AXIS: float(weight)}
		variation.variation_embolden = EMBOLDEN
		return variation
	# 开发环境素材缺失时仍可启动，并让系统字体选择相应的真实字重。
	var system := SystemFont.new()
	system.font_names = ["PingFang SC", "Hiragino Sans GB", "Heiti SC", "Arial Unicode MS"]
	system.font_weight = weight
	system.allow_system_fallback = true
	return system
