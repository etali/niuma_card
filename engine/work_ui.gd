class_name WorkUI
extends RefCounted

static var _data: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		_data = UIConfig.read_section("work")
	return _data

static func section(key: String) -> Dictionary:
	return data()[key]

static func number(section_name: String, key: String) -> float:
	return float(section(section_name)[key])

static func vector2(section_name: String, key: String) -> Vector2:
	var values: Array = section(section_name)[key]
	return Vector2(values[0], values[1])

static func vector3(section_name: String, key: String) -> Vector3:
	var values: Array = section(section_name)[key]
	return Vector3(values[0], values[1], values[2])

static func rect(section_name: String, key: String) -> Rect2:
	var values: Array = section(section_name)[key]
	return Rect2(values[0], values[1], values[2], values[3])
