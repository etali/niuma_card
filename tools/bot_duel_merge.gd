# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

const Duel = preload("res://tools/bot_duel.gd")
const DecisionStats = preload("res://tools/bot_decision_stats.gd")

static func normalize(report: Dictionary) -> Dictionary:
	var out := report.duplicate(true)
	if out.get("schema") == "manual-bot-duel-v1":
		out["bot_config_sha256"] = out.get("bot_sha256","")
		out["max_rounds"] = out.get("options",{}).get("max_rounds",0)
	return out

## 同一实验分片合并，检查输入身份和完整种子对；区间在全部种子对上重新计算。
## godot --headless -s tools/bot_duel_merge.gd -- OUTPUT.json INPUT1.json INPUT2.json ...
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("用法：bot_duel_merge.gd -- 输出JSON 输入JSON...")
		quit(2)
		return
	var merged := {}
	var games: Array = []
	var seen := {}
	for i in range(1, args.size()):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[i]))
		if not parsed is Dictionary:
			printerr("输入报告不可读：", args[i])
			quit(2)
			return
		var report := normalize(parsed)
		if merged.is_empty():
			merged = report.duplicate(true)
		else:
			for key in ["a", "b", "protocol", "table_hash", "cards_sha256", "bot_config_sha256", "engine_source_hash", "max_rounds", "godot"]:
				if StateCodec.canon(merged.get(key)) != StateCodec.canon(report.get(key)):
					printerr("不能合并不同实验：", key)
					quit(2)
					return
		for game in report["games"]:
			var key := "%d/%s" % [int(game["seed"]), str(game["swap"])]
			if seen.has(key):
				printerr("重复对局：", key)
				quit(2)
				return
			seen[key] = true
			games.append(game)
	games.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["seed"]) < int(b["seed"]) if a["seed"] != b["seed"] else not bool(a["swap"]))
	var summary := Duel.summarize(games)
	if int(summary["completed_seed_pairs"]) * 2 != games.size():
		printerr("输入包含不完整种子对")
		quit(2)
		return
	var decisions := {"A":{},"B":{}}
	for game in games:
		for side in decisions:
			DecisionStats.merge(decisions[side],game.get("decisions",{}).get(side,{}))
	if not decisions["A"].is_empty(): summary["decisions"] = decisions
	merged["games"] = games
	merged["summary"] = summary
	merged["seed_start"] = int(games[0]["seed"])
	merged["seed_pairs"] = int(summary["completed_seed_pairs"])
	merged["games_count"] = games.size()
	merged.erase("elapsed_ms")
	merged.erase("elapsed_seconds")
	if merged.has("options"):
		merged["options"]["pairs"] = int(summary["completed_seed_pairs"])
		merged["options"]["seed_start"] = int(games[0]["seed"])
	merged["source_reports"] = Array(args).slice(1)
	merged["timing_note"] = "分片并行执行，整局耗时包含CPU争用；不能作为独立决策时延"
	if not Duel._save_report(args[0], merged):
		quit(3)
		return
	Duel._print_summary(summary)
	quit()
