# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree
## 从现有完整 SVG 源稿绘制资源牌的完整 PNG 帧；不产生独立部件或运行时变形。
## 输出在 build 下，核验通过后才复制到正式素材目录。

const OUTPUT := "res://build/art_generation/resource_hover/"
const RIGHT_ARM := "M304 315 L348 341"
const HEAD := "M248 52 C325 43 376 94 378 167 C383 238 331 285 258 283 C181 290 131 237 133 165 C127 96 179 49 248 52 Z"

func _initialize() -> void:
	var success := true
	for value in ["user", "cash"]:
		var id: String = value
		var source := FileAccess.get_file_as_string("res://assets/art/icon/icon_%s.svg" % id)
		var still_path := "res://assets/art/icon/icon_%s.png" % id
		var still := Image.load_from_file(still_path)
		var original := Image.new()
		if original.load_svg_from_string(source, 2.0) != OK:
			push_error("无法读取资源牌 SVG：%s" % id)
			success = false
			continue
		var ui: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/ui.json"))
		var compressed: bool = ui.get("art", {}).get("hover", {}).get("cards", {}).get(id, {}).get("codec", "") == "hdelta-v1"
		var reference := original.duplicate() as Image
		if compressed:
			reference.fix_alpha_edges()
			reference.resize(still.get_width(), still.get_height(), Image.INTERPOLATE_CUBIC)
		if reference.get_data() != still.get_data():
			push_error("%s SVG 源稿不能逐像素还原现有静止图，停止制作" % id)
			success = false
			continue
		still = original
		var count := 36 if id == "user" else 24
		var folder := OUTPUT + id + "/"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		for index in count:
			var time := float(index) / 12.0
			var pose := _user_pose(source, time) if id == "user" else _cash_pose(source, time)
			var destination := folder + "%03d.png" % index
			if pose == source:
				if still.save_png(destination) != OK:
					success = false
				continue
			var frame := Image.new()
			if frame.load_svg_from_string(pose, 2.0) != OK or frame.get_size() != still.get_size():
				push_error("%s 第 %s 帧绘制失败" % [id, index])
				success = false
				break
			if frame.save_png(destination) != OK:
				success = false
		print("%s: %s complete native frames at 12 fps" % [id, count])
	quit(0 if success else 1)

func _ease(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _user_pose(source: String, time: float) -> String:
	if time <= 0.25 or time >= 2.7:
		return source
	var progress := _ease((time - 0.25) / 0.75) if time < 1.0 else 1.0
	if time > 1.8:
		progress = 1.0 - _ease((time - 1.8) / 0.9)
	# 原短臂沿头部外侧接续到应用图标中的弯臂姿态；头、脸、左臂、身体和脚不动。
	var scratch := 0.0
	if time >= 1.0 and time <= 1.8:
		scratch = sin((time - 1.0) / 0.8 * TAU * 2.0) * 3.0
	var shoulder := Vector2(304, 315)
	var q1 := Vector2(311.333333, 319.333333).lerp(Vector2(374, 306), progress)
	var end1 := Vector2(318.666667, 323.666667).lerp(Vector2(411, 240), progress)
	var q2 := Vector2(326, 328).lerp(Vector2(420, 210), progress)
	var end2 := Vector2(333.333333, 332.333333).lerp(Vector2(398, 167), progress)
	var hand := Vector2(348, 341).lerp(Vector2(355 + scratch, 106 - scratch * 0.25), progress)
	# 抬手与放手走头部外侧的弧线，不能在中间姿势穿过脸颊。
	hand.x += sin(PI * progress) * 55.0
	var arm := "M%.6f %.6f Q%.6f %.6f %.6f %.6f Q%.6f %.6f %.6f %.6f L%.6f %.6f" % [
		shoulder.x, shoulder.y, q1.x, q1.y, end1.x, end1.y,
		q2.x, q2.y, end2.x, end2.y, hand.x, hand.y]
	var result := source.replace(RIGHT_ARM, arm)
	# 原有绘制顺序令手臂根部处在身体后面。接触头部的末端在原头轮廓内覆盖，
	# 两次仍绘制同一完整手臂路径，不裁取栅格部件，也不改变人物固定位置。
	var overlay := '<defs><clipPath id="head_contact"><path d="%s"/></clipPath></defs><path clip-path="url(#head_contact)" fill="none" d="%s"/>' % [HEAD, arm]
	return result.replace("  </g>", "    " + overlay + "\n  </g>")

func _cash_pose(source: String, time: float) -> String:
	if time <= 0.25 or time >= 1.8:
		return source
	var progress := _ease((time - 0.25) / 0.55) if time < 0.8 else 1.0
	if time > 1.1:
		progress = 1.0 - _ease((time - 1.1) / 0.7)
	# 位移与滚动角按相同半径计算；金币始终保持原有大小、正面形状和颜色。
	var offset := 18.0 * progress
	var angle := rad_to_deg(offset / 208.0)
	return source.replace("<g stroke=", '<g transform="translate(%.6f 0) rotate(%.6f 256 256)" stroke=' % [offset, angle])
