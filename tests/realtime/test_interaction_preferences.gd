extends SceneTree

const Preferences = preload("res://engine/work_interaction_preferences.gd")
const SavePaths = preload("res://engine/save_paths.gd")

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	# This test never writes to the player's actual preferences.
	OS.set_environment("WORK_DATA_DIR", "/tmp/work-interaction-preferences-%d" % OS.get_process_id())
	var spec: Dictionary = UIConfig.read_section("board").snapping
	var path := SavePaths.work_settings_file(str(spec.preferences_file))
	var prefs := Preferences.new(spec)
	_check(is_equal_approx(prefs.get_hit_fraction(), 0.75), "missing preferences use the configured seventy-five percent default")
	prefs.set_hit_fraction(0.5)
	_check(is_equal_approx(prefs.get_hit_fraction(), 0.5), "runtime change applies immediately")
	_check(is_equal_approx(Preferences.new(spec).get_hit_fraction(), 0.75), "unsaved edits do not leak to another instance")
	_check(prefs.save(), "save succeeds in isolated settings directory")
	_check(not FileAccess.file_exists(path + ".tmp"), "atomic save leaves no temporary file")
	var loaded := Preferences.new(spec)
	_check(is_equal_approx(loaded.get_hit_fraction(), 0.5), "new instance reloads saved value")
	loaded.set_hit_fraction(0.9)
	_check(is_equal_approx(prefs.get_hit_fraction(), 0.5), "instances do not share mutable preferences")
	_check(loaded.save() and is_equal_approx(Preferences.new(spec).get_hit_fraction(), 0.9), "saving replaces an existing preference atomically")
	loaded.set_hit_fraction(-10.0)
	_check(is_equal_approx(loaded.get_hit_fraction(), float(spec.min_hit_fraction)), "live value is bounded above zero")
	loaded.set_hit_fraction(10.0)
	_check(is_equal_approx(loaded.get_hit_fraction(), float(spec.max_hit_fraction)), "live value never exceeds the full card")
	loaded.set_hit_fraction(NAN)
	_check(is_equal_approx(loaded.get_hit_fraction(), float(spec.max_hit_fraction)), "non-finite runtime input is ignored")
	loaded.set_hit_fraction(0.734)
	_check(is_equal_approx(loaded.get_hit_fraction(), 0.75), "runtime value follows the configured step")
	_write(path, "{broken-json")
	_check(is_equal_approx(Preferences.new(spec).get_hit_fraction(), 0.75), "malformed saved file safely uses the default")
	for value in ["0.9", true, null, {}]:
		_write(path, JSON.stringify({"hit_fraction": value}))
		_check(is_equal_approx(Preferences.new(spec).get_hit_fraction(), 0.75), "invalid saved type safely uses the default: " + str(value))
	_write(path, JSON.stringify({"hit_fraction": -3.0}))
	_check(is_equal_approx(Preferences.new(spec).get_hit_fraction(), float(spec.min_hit_fraction)), "out-of-range saved value is clamped to safe geometry")
	_check(loaded.reset(), "reset is persisted successfully")
	_check(is_equal_approx(loaded.get_hit_fraction(), 0.75) and is_equal_approx(Preferences.new(spec).get_hit_fraction(), 0.75), "reset survives a new instance")
	var board := WorkBoard.new()
	_check(is_equal_approx(board.get_snap_hit_fraction(), 0.75), "board exposes the preference default")
	board.set_snap_hit_fraction(0.35)
	_check(is_equal_approx(board.get_snap_hit_fraction(), 0.35), "board's live setter exposes the same value used by snapping")
	_check(board.save_interaction_preferences(), "board save delegates to isolated persistence")
	var second_board := WorkBoard.new()
	_check(is_equal_approx(second_board.get_snap_hit_fraction(), 0.35), "a new board picks up the saved value")
	_check(board.reset_interaction_preferences(), "board reset reports persisted success")
	var third_board := WorkBoard.new()
	_check(is_equal_approx(third_board.get_snap_hit_fraction(), 0.75), "new boards read the reset default")
	var bad_spec := spec.duplicate(true)
	# Missing directories can be created by JsonStore. An existing directory
	# at the *file* path is a genuine write failure on every platform.
	bad_spec.preferences_file = "directory-instead-of-file.json"
	var blocked_path := SavePaths.work_settings_file(bad_spec.preferences_file)
	DirAccess.make_dir_absolute(blocked_path)
	var cannot_save := Preferences.new(bad_spec)
	_check(not cannot_save.save(), "storage failure is returned to the UI")
	DirAccess.remove_absolute(blocked_path)
	board.free()
	second_board.free()
	third_board.free()
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path.get_base_dir())
	DirAccess.remove_absolute(path.get_base_dir().get_base_dir())
	for failure in failures: push_error(failure)
	print("INTERACTION_PREFERENCES %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
