# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 选色面板依赖的 Palette 行为自检：改色要发信号、要能读回、还原要回到仓库默认值。
## 用法：Godot --headless --script tools/probe_palette.gd --path .

var _got: Array = []


func _on_changed(section: String, key: String) -> void:
	_got.append("%s/%s" % [section, key])


func _init() -> void:
	Palette.bus().changed.connect(_on_changed)

	var d0 := Palette.get_color("world", "background")
	print("A_default_bg=", d0.to_html(false))

	Palette.set_color("world", "background", Color(0, 1, 0))
	print("B_after_set=", Palette.get_color("world", "background").to_html(false))
	print("B_signal=", ",".join(_got))

	_got.clear()
	Palette.set_plate_color("plate_cash", "face", Color(1, 0, 0))
	print("C_plate_after_set=", Palette.plate_color("plate_cash", "face").to_html(false))
	print("C_signal=", ",".join(_got))

	print("D_save=", Palette.save())
	print("D_userfile=", FileAccess.file_exists("user://palette.json"))

	Palette.restore_defaults()
	var r_bg := Palette.get_color("world", "background")
	var r_face := Palette.plate_color("plate_cash", "face")
	print("E_bg_restored=", r_bg.to_html(false), " match=", r_bg.is_equal_approx(d0))
	print("E_face_restored=", r_face.to_html(false))
	print("E_userfile_gone=", not FileAccess.file_exists("user://palette.json"))

	# 图标前景默认留空 → 跟随墨色，这是改造前的行为
	print("F_icon_cfg=[", Palette.get_string("icon", "foreground"), "]")
	print("F_icon_follows=", Palette.icon_color(Color(0.1, 0.2, 0.3)).to_html(false))

	print("PROBE_DONE")
	quit()
