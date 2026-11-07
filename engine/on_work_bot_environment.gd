# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name OnWorkBOTEnvironment
extends RefCounted

## 搜索适配器只复制状态和调用环境，不定义新的游戏规则。
static func copy(src: OnWorkState) -> OnWorkState:
	var dst := OnWorkState.new()
	dst.players = src.players.duplicate(true)
	dst.combos = src.combos.duplicate(true)
	dst.market = src.market.duplicate()
	dst.round_num = src.round_num
	dst.draw_first = src.draw_first
	dst.winner = src.winner
	dst.win_reason = src.win_reason
	dst.roles = src.roles.duplicate()
	dst.set_uid(src.peek_uid())
	dst.rng_restore(src.rng_snapshot())
	dst.stats = src.stats.duplicate(true)
	# 搜索不需要复制累积战报；运行时卡牌标记和组合次序完整保留。
	return dst

static func replay(state: OnWorkState, intents: Array) -> bool:
	var app := OnWorkIntentApply.new(state)
	for intent in intents:
		if state.winner != "":
			break
		if not bool(app.apply(intent).get("ok", false)):
			return false
	return true

static func key(state: OnWorkState) -> String:
	# 正确性优先：保留身份、数组次序和所有运行时属性，仅去掉日志/观测计数。
	return OnWorkStateCodec.canon({"players": state.players, "combos": state.combos,
		"market": state.market, "round": state.round_num, "first": state.draw_first,
		"winner": state.winner, "uid": state.peek_uid()})

static func settle(state: OnWorkState, picker: Callable) -> void:
	for who in state.action_order():
		if state.winner == "":
			OnWorkSettle.attack_phase(state, who, picker)
	if state.winner == "":
		OnWorkSettle.produce(state)
	OnWorkSettle.finalize(state)
