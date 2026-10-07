# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree
## 由 pack_hover_animations.py 调用，使用与预览相同的 Godot cubic 缩放。

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("需要提供缩放任务 JSON")
		quit(1)
		return
	var job: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var limit := int(job.limit)
	var completed := 0
	for item in job.files:
		var image := Image.load_from_file(item.source)
		if image == null or image.is_empty():
			push_error("无法读取原图：%s" % item.source)
			quit(1)
			return
		image.convert(Image.FORMAT_RGBA8)
		# 对应原图导入处理；缩小后的 PNG 不再二次 fix_alpha_border。
		if bool(item.get("fix_alpha_border", true)):
			image.fix_alpha_edges()
		var size := image.get_size()
		var scale := minf(float(limit) / maxi(size.x, size.y), 1.0)
		image.resize(maxi(1, roundi(size.x * scale)), maxi(1, roundi(size.y * scale)), Image.INTERPOLATE_CUBIC)
		DirAccess.make_dir_recursive_absolute(str(item.target).get_base_dir())
		if image.save_png(item.target) != OK:
			push_error("无法保存缩小图：%s" % item.target)
			quit(1)
			return
		completed += 1
		if completed % 100 == 0:
			print("已缩放 %d / %d" % [completed, job.files.size()])
	print("缩放完成：%d 张，最长边 %d" % [completed, limit])
	quit()
