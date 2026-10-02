# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 真正检查 TextServer 使用的字体实例，不能只问 FontVariation 属性。
## 曾经用字符串 "wght" 设置 400/600，属性正确但两个 RID 都还是 Thin。
const WEIGHT_AXIS := 0x77676874

func _initialize() -> void:
	print("=== 中文字体真实字重 ===")
	if not need(ResourceLoader.exists(Fonts.BUNDLED_FONT), "项目内置中文字体资源存在"):
		finish()
		return
	var regular := Fonts.zh()
	var semibold := Fonts.zh_bold()
	_check_weight(regular, 400, "正文")
	_check_weight(semibold, 600, "标题与卡面")
	check(regular == Fonts.zh() and semibold == Fonts.zh_bold(), "重复使用共享字体实例，不逐帧重建字形缓存")
	check(regular.get_rids()[0] != semibold.get_rids()[0], "正文和标题分别解析成不同的真实字重实例")
	for sample in ["局域网对战", "半小时生活圈", "选项"]:
		var complete := true
		for codepoint in sample.to_utf32_buffer().to_int32_array():
			complete = complete and regular.has_char(codepoint) and semibold.has_char(codepoint)
		check(complete, "中文样本文字有真实字形：%s" % sample)
		var measured := semibold.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, 24)
		check(measured.x > 0 and measured.y > 0 and measured.is_finite(), "真实字重提供可用布局尺寸：%s" % sample)
	finish()

func _check_weight(font: Font, expected: int, purpose: String) -> void:
	if not need(font is FontVariation, "%s通过内置可变字体选择真实字重" % purpose):
		return
	var variation := font as FontVariation
	check(variation.base_font is FontFile, "%s变体绑定实际内置FontFile，不包装null或系统默认字体" % purpose)
	if variation.base_font is FontFile and FileAccess.file_exists(Fonts.BUNDLED_FONT):
		var settings := ConfigFile.new()
		if settings.load(Fonts.BUNDLED_FONT + ".import") == OK and settings.has_section_key("params", "hinting"):
			check(variation.base_font.hinting == TextServer.HINTING_LIGHT
				and variation.base_font.subpixel_positioning == TextServer.SUBPIXEL_POSITIONING_AUTO,
				"%s源字体按矢量导入语义使用Light hinting与Auto subpixel" % purpose)
	check(is_zero_approx(variation.variation_embolden), "%s不从Thin轮廓伪加粗" % purpose)
	check(is_equal_approx(float(variation.variation_opentype.get(WEIGHT_AXIS, 0.0)), float(expected)),
		"%s保存可识别的OpenType weight标签" % purpose)
	var rids := variation.get_rids()
	if not need(not rids.is_empty(), "%s生成真实渲染字体实例" % purpose):
		return
	var coordinates := TextServerManager.get_primary_interface().font_get_variation_coordinates(rids[0])
	check(is_equal_approx(float(coordinates.get(WEIGHT_AXIS, 0.0)), float(expected)),
		"%s底层TextServer实际渲染wght=%d" % [purpose, expected])
