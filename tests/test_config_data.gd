# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const ConfigData = preload("res://engine/config_data.gd")

func _initialize() -> void:
	var base := {"section": {"kept": 1, "nested": {"base": true}, "items": [1, 2]}, "replace": {"old": 1}}
	var over := {"section": {"nested": {"added": [3]}, "items": [4]}, "replace": null}
	var expected := {"section": {"kept": 1, "nested": {"base": true, "added": [3]}, "items": [4]}, "replace": null}
	var merged := ConfigData.overlay(base, over)
	check(merged == expected, "嵌套字典保留缺省键，数组与 null 整体覆盖")
	merged["section"]["nested"]["added"].append(9)
	merged["section"]["items"].append(9)
	merged["section"]["kept"] = 9
	check(base["section"]["kept"] == 1 and over["section"]["nested"]["added"] == [3]
		and over["section"]["items"] == [4], "合并结果中的嵌套容器不会反向污染任一来源")
	var copied := ConfigData.overlay(base, null)
	copied["section"]["items"].clear()
	check(base["section"]["items"] == [1, 2], "缺少覆盖段仍返回独立副本")
	var colors := {"world": {"color": "base", "layers": [1]}, "plates": {"cash": {"face": "base"}}}
	var edits := {"world": {"layers": [2]}, "plates": {"cash": {"band": [3]}}, "ignored": 42}
	var palette := Palette._merge(colors, edits)
	check(palette["world"]["color"] == "base" and palette["plates"]["cash"]["face"] == "base"
		and not palette.has("ignored"), "配色保留嵌套默认值并继续忽略非分区顶层字段")
	palette["world"]["layers"].append(9)
	palette["plates"]["cash"]["band"].append(9)
	check(edits["world"]["layers"] == [2] and edits["plates"]["cash"]["band"] == [3],
		"配色新字段不再与传入设置共享数组")
	var path := "user://config-data.json"
	for content in ['{"valid":{"items":[1]}}', '{"broken":', '[]', 'null']:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(content)
		file.close()
		var value := {"valid": {"items": [1.0]}} if content.begins_with('{"valid"') else {}
		check(UIConfig.read_json(path) == value and BOTConfig.read_json(path) == value
			and Palette.read_json(path) == value, "三种可选设置对有效、损坏或非字典 JSON 使用相同降级：%s" % content)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(ConfigData.read_dictionary(path).is_empty(), "不存在的可选设置正常回退")
	finish()
