# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name HoverDelta
extends RefCounted

## NCHD v1：原尺寸 RGBA 关键帧 + 前一唯一帧的无损 XOR 差分。
## 只产生 CPU Image，可放到后台线程；ImageTexture 上传由 CardArt 在主线程分批进行。
## 帧率与动作说明仍在 data/ui.json，包内仅保存图像和复用帧的时间轴索引。
const MAGIC := "NCHD"
const VERSION := 1
const HEADER_BYTES := 24
const RECORD_HEADER_BYTES := 40
const MAX_DIMENSION := 2048
const MAX_FRAMES := 4096
const MAX_FILE_BYTES := 128 * 1024 * 1024
const MAX_DECODED_BYTES := 256 * 1024 * 1024

static func decode_file(path: String, generate_mipmaps := true) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("无法打开动画包：%s" % path)
	var length := file.get_length()
	if length < HEADER_BYTES or length > MAX_FILE_BYTES:
		return _failure("动画包大小无效：%d" % length)
	var data := file.get_buffer(length)
	if data.size() != length:
		return _failure("动画包读取不完整")
	return decode_bytes(data, generate_mipmaps)

static func decode_bytes(data: PackedByteArray, generate_mipmaps := true) -> Dictionary:
	if data.size() < HEADER_BYTES or data.size() > MAX_FILE_BYTES:
		return _failure("动画包大小无效")
	if data.slice(0, 4).get_string_from_ascii() != MAGIC:
		return _failure("不是 NCHD 动画包")
	if data.decode_u32(4) != VERSION:
		return _failure("不支持的动画包版本")
	var width := int(data.decode_u32(8))
	var height := int(data.decode_u32(12))
	var frame_count := int(data.decode_u32(16))
	var unique_count := int(data.decode_u32(20))
	if width < 1 or height < 1 or width > MAX_DIMENSION or height > MAX_DIMENSION:
		return _failure("动画尺寸无效")
	if frame_count < 1 or frame_count > MAX_FRAMES or unique_count < 1 or unique_count > frame_count:
		return _failure("动画帧数无效")
	var raw_size := width * height * 4
	var padded_size := (raw_size + 7) & ~7
	if raw_size * unique_count > MAX_DECODED_BYTES:
		return _failure("动画解码内存超出限制")
	var cursor := HEADER_BYTES
	if cursor + frame_count * 4 + unique_count * RECORD_HEADER_BYTES > data.size():
		return _failure("动画索引或帧记录不完整")
	var timeline := PackedInt32Array()
	timeline.resize(frame_count)
	for frame in frame_count:
		var index := int(data.decode_u32(cursor))
		cursor += 4
		if index >= unique_count:
			return _failure("动画时间轴引用越界")
		timeline[frame] = index
	if timeline[0] != 0:
		return _failure("动画首帧必须引用静止帧")
	var images: Array[Image] = []
	var previous := PackedByteArray()
	for frame in unique_count:
		if cursor + RECORD_HEADER_BYTES > data.size():
			return _failure("第 %d 帧记录不完整" % frame)
		var mode := int(data.decode_u32(cursor))
		var compressed_size := int(data.decode_u32(cursor + 4))
		var expected_hash := data.slice(cursor + 8, cursor + RECORD_HEADER_BYTES)
		cursor += RECORD_HEADER_BYTES
		if mode < 0 or mode > 1 or (frame == 0 and mode != 0):
			return _failure("第 %d 帧编码模式无效" % frame)
		if compressed_size < 1 or compressed_size > padded_size + 65536 or cursor + compressed_size > data.size():
			return _failure("第 %d 帧压缩数据大小无效" % frame)
		var pixels := data.slice(cursor, cursor + compressed_size).decompress(
			padded_size, FileAccess.COMPRESSION_DEFLATE)
		cursor += compressed_size
		if pixels.size() != padded_size:
			return _failure("第 %d 帧解压失败" % frame)
		if mode == 1:
			pixels = _xor_words(pixels, previous)
		# 补齐字节只为 64 位批量 XOR，不属于图像，也不得携带未验证的数据。
		for index in range(raw_size, padded_size):
			if pixels[index] != 0:
				return _failure("第 %d 帧补齐字节无效" % frame)
		var rgba := pixels.slice(0, raw_size)
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(rgba)
		if hash.finish() != expected_hash:
			return _failure("第 %d 帧像素校验失败" % frame)
		var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, rgba)
		if generate_mipmaps and image.generate_mipmaps() != OK:
			return _failure("第 %d 帧缩小采样图生成失败" % frame)
		images.append(image)
		previous = pixels
	if cursor != data.size():
		return _failure("动画包存在多余尾部数据")
	return {"images": images, "timeline": timeline, "width": width, "height": height, "error": ""}

static func _xor_words(left: PackedByteArray, right: PackedByteArray) -> PackedByteArray:
	# 每次处理 8 字节，避免在 GDScript 中逐字节遍历整张 RGBA 图。
	var words := left.to_int64_array()
	var previous := right.to_int64_array()
	for index in words.size():
		words[index] = words[index] ^ previous[index]
	return words.to_byte_array()

static func _failure(message: String) -> Dictionary:
	return {"images": [], "timeline": PackedInt32Array(), "width": 0, "height": 0, "error": message}
