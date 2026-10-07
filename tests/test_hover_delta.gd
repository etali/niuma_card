extends "res://tests/harness.gd"

const Codec = preload("res://engine/hover_delta.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var first := PackedByteArray()
	first.resize(3 * 3 * 4)
	for index in first.size():
		first[index] = (index * 37 + 251) % 256
	var second := first.duplicate()
	second[0] = 0
	second[3] = 0
	second[8] = 255
	second[35] = 128
	var third := first.duplicate()
	third.fill(43)
	var source: Array[PackedByteArray] = [first, second, third]
	var timeline := PackedInt32Array([0, 0, 1, 1, 2, 1, 0])
	var encoded := _archive(source, timeline, [0, 1, 0])
	var decoded := Codec.decode_bytes(encoded, false)
	check(decoded.error == "", "RGBA 关键帧与 XOR 差分混合包可解码")
	if decoded.error != "":
		finish()
		return
	check(decoded.width == 3 and decoded.height == 3, "保留奇数边长，正确处理不足 8 字节的 RGBA 尾部")
	check(decoded.timeline == timeline and decoded.images.size() == 3, "重复和回放帧共享唯一帧索引")
	for index in source.size():
		check(decoded.images[index].get_data() == source[index], "第 %d 帧完整 RGBA 含透明像素逐字节相同" % index)
		check(not decoded.images[index].has_mipmaps(), "可关闭第 %d 帧缩小采样图" % index)
	var with_mips := Codec.decode_bytes(encoded)
	check(with_mips.error == "" and with_mips.images[0].has_mipmaps(), "默认在内存中生成缩小采样图")
	var base := with_mips.images[1].duplicate() as Image
	base.clear_mipmaps()
	check(base.get_data() == second, "生成缩小采样图不改变原尺寸 RGBA")
	var rectangle := Codec.decode_bytes(_archive([first.slice(0, 24)], PackedInt32Array([0]), [0], false, 3, 2))
	check(rectangle.error == "" and rectangle.width == 3 and rectangle.height == 2, "非方形图像保留宽高比")
	var worker := Thread.new()
	check(worker.start(func(): return Codec.decode_bytes(encoded)) == OK, "解码可在后台线程执行")
	var background: Dictionary = worker.wait_to_finish()
	check(background.error == "" and background.timeline == timeline, "后台纯 CPU 解码返回相同时间轴")
	var fixture_path := _test_data_dir.path_join("sample.hdelta")
	var file := FileAccess.open(fixture_path, FileAccess.WRITE)
	file.store_buffer(encoded)
	file.close()
	check(Codec.decode_file(fixture_path, false).images[1].get_data() == second, "文件入口与内存入口结果一致")
	check(not Codec.decode_file(_test_data_dir.path_join("missing.hdelta")).error.is_empty(), "缺失包返回错误而非创建空白纹理")
	_reject(PackedByteArray(), "空文件")
	_reject(encoded.slice(0, 23), "不完整头部")
	var changed := encoded.duplicate()
	changed[0] = 0
	_reject(changed, "错误标识")
	changed = encoded.duplicate()
	changed.encode_u32(4, 2)
	_reject(changed, "未知版本")
	changed = encoded.duplicate()
	changed.encode_u32(8, 0)
	_reject(changed, "零宽度")
	changed = encoded.duplicate()
	changed.encode_u32(12, Codec.MAX_DIMENSION + 1)
	_reject(changed, "过大尺寸")
	changed = encoded.duplicate()
	changed.encode_u32(16, Codec.MAX_FRAMES + 1)
	_reject(changed, "过大时间轴")
	changed = encoded.duplicate()
	changed.encode_u32(16, 0)
	_reject(changed, "空时间轴")
	changed = encoded.duplicate()
	changed.encode_u32(20, timeline.size() + 1)
	_reject(changed, "唯一帧超过时间轴")
	changed = encoded.duplicate()
	changed.encode_u32(8, 2048)
	changed.encode_u32(12, 2048)
	changed.encode_u32(16, 17)
	changed.encode_u32(20, 17)
	_reject(changed, "解码内存超出限制")
	changed = encoded.duplicate()
	changed.encode_u32(24, source.size())
	_reject(changed, "越界帧引用")
	changed = encoded.duplicate()
	changed.encode_u32(24, 1)
	_reject(changed, "首帧不引用静止帧")
	var record_start := 24 + timeline.size() * 4
	changed = encoded.duplicate()
	changed.encode_u32(record_start, 1)
	_reject(changed, "首帧为差分")
	changed = encoded.duplicate()
	changed.encode_u32(record_start, 2)
	_reject(changed, "未知帧编码模式")
	changed = encoded.duplicate()
	changed.encode_u32(record_start + 4, 0)
	_reject(changed, "零压缩长度")
	changed = encoded.duplicate()
	changed.encode_u32(record_start + 4, 0xffffffff)
	_reject(changed, "压缩长度溢出")
	changed = encoded.duplicate()
	changed[record_start + 8] = changed[record_start + 8] ^ 255
	_reject(changed, "像素校验不符")
	_reject(encoded.slice(0, encoded.size() - 1), "截断帧内容")
	changed = encoded.duplicate()
	changed.append(0)
	_reject(changed, "多余尾部数据")
	_reject(_archive(source, timeline, [0, 1, 0], true), "非零补齐字节")
	finish()

func _reject(data: PackedByteArray, reason: String) -> void:
	var result := Codec.decode_bytes(data, false)
	check(not result.error.is_empty() and result.images.is_empty(), "拒绝%s，且不暴露半段动画" % reason)

## 使用逐字节 XOR 构造独立小夹具，覆盖生产解码的 64 位运算及尾部补齐。
func _archive(frames: Array[PackedByteArray], timeline: PackedInt32Array,
		modes: Array, bad_padding := false, width := 3, height := 3) -> PackedByteArray:
	var output := "NCHD".to_ascii_buffer()
	for value in [1, width, height, timeline.size(), frames.size()]:
		_u32(output, value)
	for value in timeline:
		_u32(output, value)
	var previous := PackedByteArray()
	for frame in frames.size():
		var full := frames[frame].duplicate()
		full.resize((full.size() + 7) & ~7)
		if bad_padding and frame == 0:
			full[full.size() - 1] = 1
		var payload := full.duplicate()
		if modes[frame] == 1:
			for index in payload.size():
				payload[index] = payload[index] ^ previous[index]
		var compressed := payload.compress(FileAccess.COMPRESSION_DEFLATE)
		_u32(output, modes[frame])
		_u32(output, compressed.size())
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(frames[frame])
		output.append_array(hash.finish())
		output.append_array(compressed)
		previous = full
	return output

func _u32(data: PackedByteArray, value: int) -> void:
	var offset := data.size()
	data.resize(offset + 4)
	data.encode_u32(offset, value)
