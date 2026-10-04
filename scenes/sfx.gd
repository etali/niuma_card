# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Sfx
extends Node

## 音效池：轮转复用 AudioStreamPlayer，同音效快速连播不互相切断
##
## **响度和音高一个字面量都不在代码里。** 调用方只说做了什么动作
## （sfx.play("combo_complete")），用哪个 wav、多响、什么音高全在配置的
## ui.json 的 sfx 段上（见 data/ui.json 的 sfx._note）。
##
## 原先是另一套：音效名→文件的表写在这个文件里，而响度散在三十来处调用点上
## （光 deny 就有 -4.0 和 -6.0 两档、buy 有三档）。改一档音量得先把那几处找齐，
## 而漏掉一处不会报错 —— 同一个动作在两个地方响两种音量，谁都听不出是 bug

const POOL_SIZE := 10
const PREF_PATH := "user://sound.json"
const Store = preload("res://engine/json_store.gd")

signal user_muted_changed(value: bool)

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
## 普通动作的静音状态；完成提醒可穿过抽屉挂起，但仍遵循玩家声音开关。
var muted := false
## 玩家在界面里选择的声音开关；抽屉自动收起不会改这个值。
var user_muted := false
## 抽屉收起期间挂起普通动作音效，完成提醒由动作配置 notification 声明。
var drawer_suspended := false

func _ready() -> void:
	var stored := UIConfig.read_json(PREF_PATH)
	user_muted = stored.get("muted", false) if stored.get("muted", false) is bool else false
	_apply_mute_state()
	for key in sounds():
		_streams[key] = load(str(sounds()[key]))
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

## 音效名 → wav 路径（配置 ui.json.sfx.sounds）
static func sounds() -> Dictionary:
	return CardDB.sfx_rules().get("sounds", {})

## 游戏动作 → { sound, db, pitch }（配置 ui.json.sfx.actions）。
## 认不出的动作名报错而不是静默沉默：少响一声在 headless 下测不出来
## （play 找不到流就 return），在真机上也只是「这儿好像没声音」，
## 谁都不会怀疑到动作名拼错了
static func action(name: String) -> Dictionary:
	var actions: Dictionary = CardDB.sfx_rules().get("actions", {})
	var spec: Variant = actions.get(name)
	if typeof(spec) != TYPE_DICTIONARY:
		push_error(("Sfx: 配置 ui.json.sfx.actions 里没有动作「%s」。" % name)
			+ "这一声不会响，而且不会有别的报错")
		return {}
	return spec

## 播一个**动作**的声音。db/pitch 都从配置取，调用方不传数值。
##
## 只有一个可选参数 pitch_scale：逐张错开那种「同一动作连播、音高递变」的场合
## 才用得上，眼下没有调用方传它 —— 留着是因为那是演出参数，不是音量档位
func play(action_name: String, pitch_scale := 1.0) -> void:
	if user_muted:
		return
	var spec := action(action_name)
	if spec.is_empty():
		return
	if drawer_suspended and not bool(spec.get("notification", false)):
		return
	var key := str(spec.get("sound", ""))
	if not _streams.has(key) or _streams[key] == null:
		return
	var p := _players[_next]
	_next = (_next + 1) % POOL_SIZE
	p.stream = _streams[key]
	p.volume_db = float(spec.get("db", 0.0))
	# 微随机音高，重复不机械
	p.pitch_scale = float(spec.get("pitch", 1.0)) * pitch_scale \
		* randf_range(0.96, 1.04)
	p.play()

## 兼容旧调用方：直接设置用户声音偏好。新代码请使用 set_user_muted。
func set_muted(value: bool) -> void:
	set_user_muted(value)

func set_user_muted(value: bool) -> bool:
	var changed := user_muted != value
	user_muted = value
	_apply_mute_state()
	if changed:
		user_muted_changed.emit(value)
	return Store.save(PREF_PATH, {"muted": value})

func set_drawer_suspended(value: bool) -> void:
	drawer_suspended = value
	_apply_mute_state()

func _apply_mute_state() -> void:
	muted = user_muted or drawer_suspended
	if muted:
		for player in _players:
			player.stop()

## 离树先解除播放实例对音频资源的引用，退出/换场景不留下仍播放的声音。
func _exit_tree() -> void:
	for player in _players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_streams.clear()
