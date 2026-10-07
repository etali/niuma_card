# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

## Godot --headless --path . --script tools/export_app_icon.gd
## 从用户小人 SVG 源稿导出两处使用的透明 PNG；随后运行 build_android_icons.py。
extends SceneTree

func _init() -> void:
	var image := Image.new()
	var error := image.load_svg_from_string(FileAccess.get_file_as_string("res://assets/art/app_icon.svg"))
	if error != OK:
		push_error("图标 SVG 栅格化失败")
		quit(1)
		return
	for path in ["res://assets/art/app_icon.png", "res://assets/app_icon.png"]:
		if image.save_png(path) != OK:
			push_error("无法保存应用图标：" + path)
			quit(1)
			return
	for id in ["cash", "user"]:
		var ui: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/ui.json"))
		if ui.get("art", {}).get("hover", {}).get("cards", {}).get(id, {}).get("codec", "") == "hdelta-v1":
			# 静止图与差分首帧必须成套更新，导出应用图标不单独覆盖它们。
			continue
		var resource_image := Image.new()
		if resource_image.load_svg_from_string(FileAccess.get_file_as_string("res://assets/art/icon/icon_" + id + ".svg"), 2.0) != OK \
				or resource_image.save_png("res://assets/art/icon/icon_" + id + ".png") != OK:
			push_error("无法导出共享资源图标：" + id)
			quit(1)
			return
	print("应用图标已从 SVG 导出：", image.get_size())
	quit()
