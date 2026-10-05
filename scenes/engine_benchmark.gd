# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 仅由显式开发环境变量触发。相同局面与节点预算比较编译选项，不读写玩家偏好。
static func run() -> Dictionary:
	var cfg := BOTSearch.from_model("bot", 0.5)
	var cases: Array = []
	for seed_value in [9271, 552, 227]:
		var state := GameState.new()
		state.set_seed(seed_value)
		state.new_game()
		cases.append(state)
	# 预热全部局面，让首次脚本加载不混入正式计时。
	for state in cases:
		BOTPlan.choose_plan(state, state.action_first(), cfg)
	var samples: Array = []
	for repeat in 7:
		var elapsed := 0.0
		var expanded := 0
		var decisions: Array = []
		for state in cases:
			var started := Time.get_ticks_usec()
			var result := BOTPlan.choose_plan(state, state.action_first(), cfg)
			elapsed += float(Time.get_ticks_usec() - started) / 1000.0
			expanded += int(result["diagnostics"].get("expanded_nodes", 0))
			decisions.append(result["intents"])
		samples.append({"ms": elapsed, "nodes": expanded, "decisions": StateCodec.canon_hash(decisions)})
	var times: Array = samples.map(func(sample): return sample["ms"])
	times.sort()
	return {"version": Engine.get_version_info(), "profile": cfg.resolved_parameters(),
		"seeds": [9271, 552, 227], "samples": samples, "median_ms": times[times.size() / 2]}
