# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name OnWorkBOTPlan
extends RefCounted

## 调用方的通用入口。注册的实现提供搜索、目标选择和估值；这里没有旧策略回退。
const Work = preload("res://engine/on_work_bot_work_budget.gd")

## 设置变更不在同回合重新发放额度；下一回合建立新账本。
static func work_session(state: OnWorkState, who: String, cfg: OnWorkBOTSearch) -> RefCounted:
	var sessions := state.bot_work_sessions
	if not sessions.has(who) or int(sessions[who]["round"]) != state.round_num:
		sessions[who] = {"round":state.round_num,"meter":Work.new(OnWorkBOTTurnPlan.effective_budget(cfg.resolved_parameters()))}
	return sessions[who]["meter"]

static func choose_plan(state: OnWorkState, who: String, cfg: OnWorkBOTSearch = null) -> Dictionary:
	var profile := cfg if cfg != null else OnWorkBOTSearch.default_config()
	var previous := profile.work_session
	if previous == null: profile.work_session = work_session(state,who,profile)
	var result := profile.implementation().choose_plan(state, who, profile)
	profile.work_session = previous
	return result

static func target_picker(cfg: OnWorkBOTSearch = null, state: OnWorkState = null, who := "") -> Callable:
	var profile := cfg if cfg != null else OnWorkBOTSearch.default_config()
	var previous := profile.work_session
	if state != null and who != "": profile.work_session = work_session(state,who,profile)
	var picker := profile.implementation().target_picker(profile)
	profile.work_session = previous
	return picker

static func score(state: OnWorkState, who: String, cfg: OnWorkBOTSearch = null) -> float:
	var profile := cfg if cfg != null else OnWorkBOTSearch.default_config()
	return profile.implementation().evaluate(state, who, profile.resolved_parameters())
