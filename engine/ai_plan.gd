# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIPlan
extends RefCounted

## 调用方的通用入口。注册的实现提供搜索、目标选择和估值；这里没有旧策略回退。
const Work = preload("res://engine/ai_work_budget.gd")

## 设置变更不在同回合重新发放额度；下一回合建立新账本。
static func work_session(state: GameState, who: String, cfg: AISearch) -> RefCounted:
	var sessions := state.ai_work_sessions
	if not sessions.has(who) or int(sessions[who]["round"]) != state.round_num:
		sessions[who] = {"round":state.round_num,"meter":Work.new(AITurnPlan.effective_budget(cfg.resolved_parameters()))}
	return sessions[who]["meter"]

static func choose_plan(state: GameState, who: String, cfg: AISearch = null) -> Dictionary:
	var profile := cfg if cfg != null else AISearch.default_config()
	var previous := profile.work_session
	if previous == null: profile.work_session = work_session(state,who,profile)
	var result := profile.implementation().choose_plan(state, who, profile)
	profile.work_session = previous
	return result

static func target_picker(cfg: AISearch = null, state: GameState = null, who := "") -> Callable:
	var profile := cfg if cfg != null else AISearch.default_config()
	var previous := profile.work_session
	if state != null and who != "": profile.work_session = work_session(state,who,profile)
	var picker := profile.implementation().target_picker(profile)
	profile.work_session = previous
	return picker

static func score(state: GameState, who: String, cfg: AISearch = null) -> float:
	var profile := cfg if cfg != null else AISearch.default_config()
	return profile.implementation().evaluate(state, who, profile.resolved_parameters())
