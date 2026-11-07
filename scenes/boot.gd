# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node
const TABLE_SCENES := ["res://scenes/on_work_main.tscn", "res://scenes/off_work_main.tscn"]
const Slots = preload("res://engine/shift_slot.gd")

## 发行版禁用了命令行场景覆盖，使用应用自己的启动参数选择独立预览。
static func entry_scene(args: PackedStringArray) -> String:
	if args.has("--animation-preview"):
		return "res://scenes/animation_preview.tscn"
	return "res://scenes/shift_host.tscn"

func _enter_tree() -> void:
	if OS.get_name() != "macOS" or DisplayServer.get_name() == "headless": return
	var window := get_window()
	window.transparent_bg = true
	# The drawer chooses the actual display and geometry. An explicitly requested
	# plain table bypasses the drawer, so it must grow its own launch window.
	if (LaunchConfig.desktop_args().has("--table") or PlatformMode.force_mobile()) and window.size.x <= 64:
		window.size = Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"))
		window.move_to_center()

func _ready() -> void:
	var entry := entry_scene(OS.get_cmdline_user_args())
	if DisplayServer.get_name() != "headless" and entry == "res://scenes/shift_host.tscn":
		request_scene(TABLE_SCENES[maxi(0, starting_mode(LaunchConfig.desktop_args()))])
		request_scene(entry)
		var primer := preload("res://scenes/opening_materials.gd").new()
		get_tree().root.add_child.call_deferred(primer)
	var scene := await packed_scene(get_tree(), entry)
	if scene: get_tree().change_scene_to_packed.call_deferred(scene)

## A new profile uses the original table and the sign's first-use introduction.
static func starting_mode(args: PackedStringArray) -> int:
	if not remembers_mode(args):
		return 1 if args.has("--off-work-playtest") else 0
	var mode: Variant = Slots.load_slot("last_mode").get("mode")
	return int(mode) if mode in [0, 1] else -1

static func remembers_mode(args: PackedStringArray) -> bool:
	var flags := LaunchConfig.parse_flags(args)
	var explicit_keys := LaunchConfig.KEYS_SERVER + LaunchConfig.KEYS_ROOM + LaunchConfig.KEYS_HOST + LaunchConfig.KEYS_PORT
	explicit_keys += ["solo","table","cards-config","animation-preview","off-work-playtest"]
	for key in explicit_keys:
		if flags.has(key): return false
	return true

## Request resources off the render thread. Taking an in-progress request
## synchronously blocks the very frame in which the drawer or sign is moving.
static func request_scene(path: String) -> void:
	if not ResourceLoader.has_cached(path) and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_request(path, "PackedScene")

static func packed_scene(tree: SceneTree, path: String) -> PackedScene:
	if DisplayServer.get_name() == "headless":
		return load(path) as PackedScene
	request_scene(path)
	var status := ResourceLoader.load_threaded_get_status(path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await tree.process_frame
		status = ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path) as PackedScene
	return load(path) as PackedScene
