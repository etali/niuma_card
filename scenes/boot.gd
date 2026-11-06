# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node
## 发行版禁用了命令行场景覆盖，使用应用自己的启动参数选择独立预览。
static func entry_scene(args: PackedStringArray) -> String:
	if args.has("--animation-preview"):
		return "res://scenes/animation_preview.tscn"
	return "res://scenes/shift_host.tscn"

func _enter_tree() -> void:
	if OS.get_name() != "macOS" or DisplayServer.get_name() == "headless": return
	var window := get_window()
	window.transparent_bg = true
	# The drawer chooses the actual display and geometry. An explicitly requested
	# plain table bypasses the drawer, so it must grow its own launch window.
	if (LaunchConfig.desktop_args().has("--table") or PlatformMode.force_mobile()) and window.size.x <= 64:
		window.size = Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"))
		window.move_to_center()

func _ready() -> void:
	get_tree().change_scene_to_file.call_deferred(entry_scene(OS.get_cmdline_user_args()))
