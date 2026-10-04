# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 逐次搜索的可加统计；HTML进度和分片合并使用同一口径，不重复扫描历史对局。
const SUMS := ["elapsed_ms", "expanded_nodes", "evaluated_roots", "future_complete_layers",
	"future_depth", "future_samples", "current_incomplete", "current_unvisited",
	"generation_nodes", "current_nodes", "future_nodes", "current_coverage_limited"]

static func add(total: Dictionary, diagnostics: Dictionary) -> void:
	total["decisions"] = int(total.get("decisions",0))+1
	for key in SUMS: total[key] = float(total.get(key,0))+float(diagnostics.get(key,0))
	for key in ["selected_evaluation_complete", "budget_exhausted", "future_incomplete"]:
		total[key] = int(total.get(key,0))+int(bool(diagnostics.get(key,false)))
	total["max_elapsed_ms"] = maxf(float(total.get("max_elapsed_ms",0)),float(diagnostics.get("elapsed_ms",0)))

static func merge(total: Dictionary, part: Dictionary) -> void:
	for key in part:
		if key == "max_elapsed_ms": total[key] = maxf(float(total.get(key,0)),float(part[key]))
		else: total[key] = total.get(key,0)+part[key]
