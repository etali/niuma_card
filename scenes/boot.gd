# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node
## 发行版禁用了命令行场景覆盖，使用应用自己的启动参数选择独立预览。
static func entry_scene(args: PackedStringArray) -> String:
	return "res://scenes/animation_preview.tscn" if args.has("--animation-preview") else "res://scenes/main.tscn"

func _ready() -> void:
	get_tree().change_scene_to_file.call_deferred(entry_scene(OS.get_cmdline_user_args()))
