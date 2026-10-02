# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 独立目录复现：残留.import但缓存缺失，以及导出包只有导入资源而无源TTF。
## 不调用Godot导入，不修改项目字体或.godot缓存。
func _initialize() -> void:
	print("=== 字体源文件与导入映射生命周期 ===")
	var folder := "user://font-import-fixture-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(folder)
	var raw_path := folder + "/Source.ttf"
	var imported_path := folder + "/Imported.res"
	var exported_path := folder + "/Packed.ttf"
	if not need(DirAccess.copy_absolute(Fonts.BUNDLED_FONT, raw_path) == OK, "复制完整源字体到隔离夹具"):
		finish()
		return
	var config := ConfigFile.new()
	config.set_value("remap", "importer", "font_data_dynamic")
	config.set_value("remap", "type", "FontFile")
	config.set_value("remap", "path", folder + "/missing.fontdata")
	config.set_value("params", "hinting", 3)
	config.set_value("params", "subpixel_positioning", 4)
	config.set_value("params", "msdf_pixel_range", 8)
	config.save(raw_path + ".import")
	check(ResourceLoader.exists(raw_path) and not FileAccess.file_exists(folder + "/missing.fontdata"),
		"复现ResourceLoader.exists为真但导入目标已丢失")
	var source := Fonts._load_source_font(raw_path)
	if need(source is FontFile, "失效映射仍从真实TTF取得FontFile"):
		check(source.has_char("牛".unicode_at(0)), "直接TTF包含真实中文字形")
		check(source.hinting == TextServer.HINTING_LIGHT and source.subpixel_positioning == TextServer.SUBPIXEL_POSITIONING_AUTO and source.msdf_pixel_range == 8,
			"导入器Except Pixel选项转换为真实Light/Auto，MSDF参数保留")
		_check_weights(source, "失效映射")
		check(ResourceSaver.save(source, imported_path, ResourceSaver.FLAG_COMPRESS) == OK,
			"生成只读导入资源夹具")
		config.set_value("remap", "path", imported_path)
		config.save(exported_path + ".import")
		check(not FileAccess.file_exists(exported_path) and ResourceLoader.exists(exported_path),
			"模拟导出包仅有字体资源映射，没有源TTF")
		var packed := Fonts._load_source_font(exported_path)
		if need(packed is FontFile, "源TTF不存在时读取真正的导入字体"):
			_check_weights(packed, "导入资源")
	check(Fonts._load_source_font(folder + "/Nowhere.ttf") == null,
		"两个加载入口都缺失时明确返回null，不产生伪造字体")
	for path in [raw_path, raw_path + ".import", imported_path, exported_path + ".import"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)
	finish()

func _check_weights(source: Font, purpose: String) -> void:
	var old_source: Font = Fonts._source
	var old_regular: Font = Fonts._font
	var old_bold: Font = Fonts._bold
	Fonts._source = source
	Fonts._font = null
	Fonts._bold = null
	var regular := Fonts.zh()
	var semibold := Fonts.zh_bold()
	for pair in [[regular, 400], [semibold, 600]]:
		var font: FontVariation = pair[0]
		var rid: RID = font.get_rids()[0]
		var values := TextServerManager.get_primary_interface().font_get_variation_coordinates(rid)
		check(font.base_font == source, "%s变体绑定取得的真实源字体" % purpose)
		check(is_equal_approx(float(values.get(Fonts.WEIGHT_AXIS, 0)), float(pair[1])),
			"%s底层TextServer实际wght=%d" % [purpose, pair[1]])
	check(regular.get_rids()[0] != semibold.get_rids()[0], "%s正文和标题有独立真实字重实例" % purpose)
	Fonts._source = old_source
	Fonts._font = old_regular
	Fonts._bold = old_bold
