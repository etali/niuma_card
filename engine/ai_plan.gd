# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIPlan
extends RefCounted

## 调用方的通用入口。注册的实现提供搜索、目标选择和估值；这里没有旧策略回退。
static func choose_plan(state: GameState, who: String, cfg: AISearch = null) -> Dictionary:
	var profile := cfg if cfg != null else AISearch.default_config()
	return profile.implementation().choose_plan(state, who, profile)

static func target_picker(cfg: AISearch = null) -> Callable:
	var profile := cfg if cfg != null else AISearch.default_config()
	return profile.implementation().target_picker(profile)

static func score(state: GameState, who: String, cfg: AISearch = null) -> float:
	var profile := cfg if cfg != null else AISearch.default_config()
	return profile.implementation().evaluate(state, who, profile.resolved_parameters())
