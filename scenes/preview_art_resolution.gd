# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only

extends RefCounted
## 仅用于独立预览：每档从正式纹理缩小，不放大、不写回素材或共享缓存。
const LIMITS := [0, 1024, 768, 512, 384, 256]

static func option_label(source: Vector2i, limit: int) -> String:
	var edge := maxi(source.x, source.y)
	if limit == 0:
		return "正式原图（%d）" % edge if edge > 0 else "正式原图"
	if edge > 0 and limit > edge:
		return "%d（保持 %d）" % [limit, edge]
	return "%d 像素" % limit

static func target_size(source: Vector2i, limit: int) -> Vector2i:
	if limit <= 0 or maxi(source.x, source.y) <= limit:
		return source
	var ratio := float(limit) / float(maxi(source.x, source.y))
	return Vector2i(maxi(1, roundi(source.x * ratio)), maxi(1, roundi(source.y * ratio)))

static func resize_image(source: Image, limit: int) -> Image:
	var image := source.duplicate() as Image
	var size := target_size(image.get_size(), limit)
	if image.get_size() == size:
		return image
	image.clear_mipmaps()
	# 与 Godot 导入时的 Size Limit 一样采用 cubic，保持当前透明边缘和色彩。
	image.resize(size.x, size.y, Image.INTERPOLATE_CUBIC)
	image.generate_mipmaps()
	return image
