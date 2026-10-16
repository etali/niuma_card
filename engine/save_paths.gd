# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 玩家数据统一放在**家目录下的 `~/.niumapai_record`**（用户指定）：
##
##     ~/.niumapai_record/            录像（Tape.path_dir）
##     ~/.niumapai_record/settings/   学习进度、UI、配色、音效、卡牌配置、角色
##
## 不走 `user://`：那个前缀落在哪儿是引擎定的（macOS 上
## `~/Library/Application Support/Godot/app_userdata/牛马牌`），改不到家目录来 ——
## `use_custom_user_dir` 只能换掉最后那一层目录名，换不掉上面那几层；
## 玩家在那儿看到一个叫 Godot 的文件夹，也认不出是这个游戏的存档。
## 所以这里给的都是**绝对路径**，`FileAccess` / `DirAccess` 都直接吃。
## 引擎自己的日志和着色器缓存仍在 `user://`，它们不是存档。
##
## `~` 得自己展开：Godot 不展开它，照原样传下去会得到一个真叫 `~` 的目录
## （落在进程的工作目录底下，而那是仓库根 —— 存档存进仓库里去了，
## 而且这个坏法在屏幕上看不出来，路径照样报得出来）。见 `_home_dir()`
const DIR_NAME := ".niumapai_record"
const SETTINGS_DIR := "settings"
## 指向另一个玩家数据根目录（绝对路径）。测试 harness 与 runner 设置它，
## 由它们派生的游戏子进程继承环境，录像和设置都留在测试沙箱里，不碰玩家真实存档
const DATA_DIR_ENV := "CARD_DATA_DIR"

## 旧版放在 `user://` 根目录的存档。第一次取设置路径时搬进 settings/，搬成功才删旧文件；
## 新位置已经有同名文件时以新位置为准，旧文件原样留着不动。
## 已废弃的 bot_search.json 不搬，仍由 BOTSearch 在 `user://` 原地清理。
const LEGACY_FILES := ["tutorial_progress.json", "ui_preferences.json", "palette.json",
	"sound.json", "cards_config.json", "role.json"]

## 进程内覆盖设置目录；测试指向隔离的 `user://`，空串保持产品默认目录。
## 不读取或修改 HOME，也不持久化为玩家偏好。
static var settings_override := ""
static var _prepared_dir := ""

## 家目录。macOS/Linux 是 `HOME`，Windows 是 `USERPROFILE`。
## 两个都没有就返回空串，让调用方走 `user://` 退路
static func _home_dir() -> String:
	for key in ["HOME", "USERPROFILE"]:
		var v := OS.get_environment(key)
		if v != "":
			return v
	return ""

## 玩家数据根目录的绝对路径；拿不到可写家目录时返回空串，由调用方退回 `user://`。
## 手机只有沙盒内的 `user://`；网页只有 `user://` 落在浏览器持久存储里，家目录是内存盘，刷新即丢。
## 家目录拿不到说明环境变量被清过（沙箱、某些 CI），此时**宁可回 `user://`** 也不要撒在工作目录里
static func root() -> String:
	var custom := OS.get_environment(DATA_DIR_ENV)
	if custom.is_absolute_path():
		return custom.simplify_path()
	if OS.has_feature("android") or OS.has_feature("ios") or OS.has_feature("web"):
		return ""
	var home := _home_dir()
	if home == "":
		return ""
	return home.path_join(DIR_NAME)

## 设置与学习进度目录的绝对路径。每次解析覆盖值；换到一个新目录时先建目录、搬旧存档。
static func settings_dir() -> String:
	var dir := ""
	if not settings_override.is_empty():
		dir = ProjectSettings.globalize_path(settings_override)
	elif root() != "":
		dir = root().path_join(SETTINGS_DIR)
	else:
		dir = ProjectSettings.globalize_path("user://")
	dir = dir.simplify_path()
	if dir != _prepared_dir:
		_prepared_dir = dir
		DirAccess.make_dir_recursive_absolute(dir)
		_migrate_legacy(dir)
	return dir

static func settings_file(file_name: String) -> String:
	return settings_dir().path_join(file_name)

## 先复制成同目录临时文件再改名，复制失败或中途退出都不会留下半截存档，也不删旧文件。
static func _migrate_legacy(dir: String) -> void:
	for file_name in LEGACY_FILES:
		var legacy := ProjectSettings.globalize_path("user://" + file_name).simplify_path()
		var target := dir.path_join(file_name)
		if legacy == target or not FileAccess.file_exists(legacy) or FileAccess.file_exists(target):
			continue
		var temporary := target + "." + Crypto.new().generate_random_bytes(16).hex_encode() + ".tmp"
		if DirAccess.copy_absolute(legacy, temporary) == OK and not FileAccess.file_exists(target) \
				and DirAccess.rename_absolute(temporary, target) == OK:
			DirAccess.remove_absolute(legacy)
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(temporary)
