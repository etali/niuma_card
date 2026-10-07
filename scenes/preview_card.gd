# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only

extends CardEntity
## 正式卡牌的预览子类：动作仍由 CardEntity 播放，最后只替换显示用纹理。
var _preview_textures: Dictionary = {}

func _configured_hover_speed() -> float:
	# 独立预览沿用自身速度滑块和 ¼ 慢放，不叠乘游戏中的个人播放偏好。
	return 1.0

func set_preview_textures(mapping: Dictionary) -> void:
	_preview_textures = mapping
	if _icon == null:
		return
	if _visual_hovered and not _hover_frames.is_empty():
		seek_hover_animation(float(_hover_frame) / CardArt.hover_fps())
	else:
		_icon.texture = _hover_original
		_icon.pixel_size = _hover_pixel_size
		_apply_preview_texture()

func seek_hover_animation(seconds: float) -> void:
	super.seek_hover_animation(seconds)
	_apply_preview_texture()

func _stop_hover_animation() -> void:
	super._stop_hover_animation()
	_apply_preview_texture()

func _apply_preview_texture() -> void:
	if _icon == null or _icon.texture == null:
		return
	var source := _icon.texture
	var resized: Texture2D = _preview_textures.get(source)
	if resized == null:
		return
	# 首帧、动画帧和移开后的静止图都保持相同世界尺寸。
	_icon.pixel_size *= float(source.get_width()) / float(resized.get_width())
	_icon.texture = resized
