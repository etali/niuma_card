# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

const Paths = preload("res://engine/save_paths.gd")
const ON_WORK := "on_work"
const OFF_WORK := "off_work"

static func path(slot: String) -> String:
	return Paths.settings_dir().path_join("shift_sessions").path_join(slot + ".bin")

static func digest(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()

## Variant preserves integer keys, Vector3, 64-bit RNG state and infinity. Objects are
## disabled when decoding. The checksum also rejects truncated or damaged checkpoints.
static func save(slot: String, data: Dictionary) -> bool:
	var target := path(slot)
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK: return false
	var tmp := target + "." + Crypto.new().generate_random_bytes(8).hex_encode() + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null: return false
	var bytes := var_to_bytes({"version": 1, "slot": slot, "data": data})
	var ok := file.store_buffer(digest(bytes)) and file.store_buffer(bytes)
	file.flush()
	ok = ok and file.get_error() == OK
	file.close()
	if ok: ok = DirAccess.rename_absolute(tmp, target) == OK
	if not ok: DirAccess.remove_absolute(tmp)
	return ok

static func load_slot(slot: String) -> Dictionary:
	var target := path(slot)
	if not FileAccess.file_exists(target): return {}
	var bytes := FileAccess.get_file_as_bytes(target)
	if bytes.size() <= 32: return {}
	var payload := bytes.slice(32)
	if digest(payload) != bytes.slice(0,32): return {}
	var record: Variant = bytes_to_var(payload)
	if not record is Dictionary or record.get("version") != 1 or record.get("slot") != slot: return {}
	return record.data if record.get("data") is Dictionary else {}
