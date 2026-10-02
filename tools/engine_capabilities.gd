# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 仅查询当前编辑器的类继承与项目设置，不启动游戏，不写玩家配置。
func _initialize() -> void:
	var output := OS.get_environment("CARD_ENGINE_CAPABILITIES")
	if output == "":
		push_error("CARD_ENGINE_CAPABILITIES 未指定")
		quit(1)
		return
	var classes := {}
	for name in ClassDB.get_class_list():
		classes[str(name)] = str(ClassDB.get_parent_class(name))
	var result := {
		"version": Engine.get_version_info(),
		"classes": classes,
		"settings": {
			"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method", "gl_compatibility"),
			"physics_3d": ProjectSettings.get_setting("physics/3d/physics_engine", "GodotPhysics3D"),
		},
	}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("无法写入引擎能力清单")
		quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	quit()
