# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 手工探针：找「第 1 回合的行动阶段就被 cfg 改变」的种子。
##
## 为什么要它：`MatchSimulator.run_rounds` 里 cfgs 有两个落点 ——
## 它调 `action_phase` 那句，和它调 `Settle.run` 那句（后者是这轮为选靶加的）。
## 终局哈希分不清是哪一个接上了，
## 所以「cfgs 接到搜索上」那条判据被后者挖空了。
## `before_settle` 钩子在第 1 回合触发时，Settle 一次都还没跑过，
## 那个快照的差异只可能来自行动阶段 —— 这才是隔离的观察点

func _init() -> void:
	var hits: Array = []
	for sd in range(1, 61):
		var a := _first_snap(sd, {})
		var b := _first_snap(sd, {
			GameState.BOT: BOTSearch.from_strength(BOTSearch.PRESETS["mid"]),
		})
		var c := _first_snap(sd, {
			GameState.BOT: BOTSearch.from_strength(1.0),
		})
		if a != b or a != c:
			hits.append("种子 %d  默认低档=%s mid=%s 满档=%s" % [
				sd, a.substr(0, 8), b.substr(0, 8), c.substr(0, 8)])
	print("第 1 回合行动阶段就有差的种子（60 个里 %d 个）：" % hits.size())
	for h in hits:
		print("  ", h)
	quit()

## 第 1 回合 before_settle 那一刻的局面哈希
func _first_snap(sd: int, cfgs: Dictionary) -> String:
	var got := [""]
	var grab := func(st: GameState) -> void:
		if got[0] == "":
			got[0] = StateCodec.state_hash(st)
	MatchSimulator.run_rounds(3, sd, Callable(), grab, Callable(), cfgs)
	return got[0]
