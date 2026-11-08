# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Session = preload("res://engine/off_work_session.gd")
const Slots = preload("res://engine/shift_slot.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")
const Replay = preload("res://engine/off_work_replay.gd")

class RestoredTable extends Node:
	var state: OffWorkState
	var bot: OffWorkBot
	var replay := Replay.new()

func _initialize() -> void:
	var config := OffWorkConfig.new()
	config.rules.bot.think_seconds = 1.0
	config.rules.bot.decision_budget_ratio = .9
	config.rules.bot.search_root_width = 7
	config.bot_preferences.strength_curves.think_seconds[-1][1] = 1.0
	var state := OffWorkState.new(config)
	state.new_game(129)
	state.advance(1.25)
	var world := {}
	for key in Session.STATE_FIELDS: world[key] = state.get(key)
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key] = {}
	var saved := {"world":world, "layout":layout, "balance":config.balance_document(),
		"bot":{"bot":config.rules.bot, "preferences":config.bot_preferences},
		"rng":state._rng.state, "bot_rng":123, "bot_started":true, "bot_next":123.25,
		"paused":true, "replay_frames":[]}
	var original_policy: Dictionary = config.rules.bot.duplicate(true)
	var original_preferences: Dictionary = config.bot_preferences.duplicate(true)
	check(Slots.save(Slots.OFF_WORK, saved), "写入带旧v2最高档曲线的真实会话")
	var bytes := FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK))
	var host := RestoredTable.new()
	check(not Session.read_session(host).is_empty(), "旧v2策略会话可经真实恢复入口读取")
	check(host.state.config.rules.bot == original_policy and host.bot._policy == original_policy,
		"恢复保留旧1秒900毫秒和独立搜索参数，不暗中升级策略")
	check(host.state.time == 1.25 and host.bot._next_think == 123.25 and host.state._rng.state == state._rng.state,
		"恢复不移动游戏、行动或随机时钟")
	Preferences.bind(host.state, host.state.config.bot_preferences)
	check(Preferences.has_overrides() and Preferences.pref_strength() != 1.0,
		"旧最高参数不伪装为安装版最高档，显示自定义")
	check(Preferences.prefs().get_knob("think_seconds") == 1.0 and Preferences.prefs().get_knob("budget_readout") == "900 毫秒",
		"自定义标记旁的参数仍显示正在执行的旧时序")
	check(host.state.config.bot_preferences == original_preferences and config.bot_preferences == original_preferences,
		"控件安装曲线不覆写保存策略或传入文档")
	check(Preferences.strength_parameters(1.0, original_policy, original_preferences).think_seconds == 1.0,
		"历史实验明确指定旧曲线时仍按原映射解析")
	Preferences.set_pref_strength(1.0)
	check(host.bot._policy.think_seconds == 2.0 and OffWorkConfig.decision_budget_ms(host.bot._policy) == 1800,
		"主动选择最高档才切换到安装版2秒1800毫秒")
	check(host.bot._policy.search_root_width == 7 and not Preferences.has_overrides(),
		"选择整体档位保留独立搜索参数并清除时序覆盖")
	Preferences.restore_defaults()
	check(host.bot._policy == original_policy and Preferences.has_overrides(),
		"还原载入策略保留旧真实值，并仍标为自定义")
	check(FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK)) == bytes,
		"读取、绑定和控件操作均不改写原会话文件")
	host.free()
	finish()
