# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## BOT 实现对打，不采集卡表 Q 指标。每个种子交换座位各打一局。
## godot --headless -s tools/bot_duel.gd -- [种子对数=20] [A=bot:1] [B=bot:0] [首种子=1001] [JSON路径]
## 同一 seed 的两局作为一个统计单位，避免把换边局误当成独立样本。

const BOOTSTRAP_SAMPLES := 2000

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var pairs := 20 if args.size() < 1 else int(args[0])
	var a_label := "bot:1" if args.size() < 2 else str(args[1])
	var b_label := "bot:0" if args.size() < 3 else str(args[2])
	var first_seed := 1001 if args.size() < 4 else int(args[3])
	var output_path := "" if args.size() < 5 else str(args[4])
	if pairs <= 0 or first_seed <= 0 or not _valid_label(a_label) or not _valid_label(b_label):
		printerr("用法：bot_duel.gd -- 种子对数 A模型:强度 B模型:强度 首种子 [JSON路径]；模型须已注册（当前 bot），强度 0~1 或命名档")
		quit(2)
		return
	var a := BOTSearch.from_tier(a_label)
	var b := BOTSearch.from_tier(b_label)
	CardDB.ensure_loaded()
	var report := {
		"protocol": "paired-seed-seat-swap-v1",
		"a": _config(a_label, a), "b": _config(b_label, b),
		"seed_start": first_seed, "seed_pairs": pairs,
		"games_count": pairs * 2,
		"max_rounds": int(CardDB.sim_rules()["max_rounds"]),
		"table_hash": StateCodec.table_hash(),
		"cards_source": CardDB.loaded_from,
		"cards_sha256": FileAccess.get_sha256(CardDB.loaded_from),
		"bot_config_source": BOTConfig.source_path(),
		"bot_config_sha256": FileAccess.get_sha256(BOTConfig.source_path()),
		"engine_source_hash": _engine_source_hash(),
		"godot": Engine.get_version_info()["string"],
		"games": [],
	}
	print("BOT 对打：%d 个种子 × 交换座位 = %d 局，seed=%d..%d" % [
		pairs, pairs * 2, first_seed, first_seed + pairs - 1])
	print("A %s" % a.describe())
	print("B %s" % b.describe())
	print("卡表指纹：%s" % report["table_hash"])
	var started := Time.get_ticks_usec()
	for pair_i in range(pairs):
		var seed_i := first_seed + pair_i
		for swap in [false, true]:
			var game_started := Time.get_ticks_usec()
			var state := MatchSimulator.run_rounds(MatchSimulator.ROUNDS_FROM_CONFIG,
				seed_i, Callable(), Callable(), Callable(), BOTSearch.duel_seats(a, b, swap))
			var a_seat: String = GameState.BOT if swap else GameState.PLAYER
			var winner := "draw" if state.winner == "" else ("A" if state.winner == a_seat else "B")
			var game := {
				"seed": seed_i, "swap": swap, "a_seat": a_seat,
				"winner": winner, "win_reason": state.win_reason,
				"rounds": state.round_num,
				"duration_ms": (Time.get_ticks_usec() - game_started) / 1000.0,
			}
			report["games"].append(game)
			print("seed=%d A=%s winner=%s rounds=%d time=%.1fms" % [
				seed_i, a_seat, winner, state.round_num, game["duration_ms"]])
		report["summary"] = summarize(report["games"])
		report["elapsed_ms"] = (Time.get_ticks_usec() - started) / 1000.0
		# 每完成一对就保存，长实验中断后仍有完整成对结果；不把半对混进统计。
		if not output_path.is_empty() and not _save_report(output_path, report):
			quit(3)
			return
	_print_summary(report["summary"])
	if not output_path.is_empty():
		print("JSON 报告：%s" % ProjectSettings.globalize_path(output_path))
	quit(0)


static func _valid_label(label: String) -> bool:
	var parts := label.strip_edges().to_lower().split(":", false)
	if parts.size() != 2:
		return false
	var registered := false
	for item in BOTSearch.models():
		registered = registered or str(item["id"]) == str(parts[0])
	if not registered:
		return false
	var strength := str(parts[1])
	return strength in ["legacy","enhanced"] or BOTSearch.PRESETS.has(strength) or (strength.is_valid_float()
		and float(strength) >= 0.0 and float(strength) <= 1.0)


static func _config(label: String, cfg: BOTSearch) -> Dictionary:
	return {"label": label, "model": cfg.model, "strength": cfg.strength,
		"description": cfg.describe(), "parameters": cfg.resolved_parameters()}


static func _engine_source_hash() -> String:
	var names := DirAccess.get_files_at("res://engine")
	names.sort()
	var text := ""
	for name in names:
		if name.ends_with(".gd"):
			text += name + ":" + FileAccess.get_sha256("res://engine/" + name) + "\n"
	return text.sha256_text()


static func _save_report(path: String, report: Dictionary) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	var err := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if err != OK:
		printerr("不能创建报告目录：%s，错误 %s" % [absolute.get_base_dir(), err])
		return false
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		printerr("不能写入报告：%s" % absolute)
		return false
	file.store_string(JSON.stringify(report, "  ", false) + "\n")
	return true


static func summarize(games: Array) -> Dictionary:
	var wins := {"A": 0, "B": 0, "draw": 0}
	var seats := {}
	var pair_scores := {}
	var durations: Array = []
	var rounds: Array = []
	for game in games:
		var winner := str(game["winner"])
		wins[winner] += 1
		var seat := str(game["a_seat"])
		if not seats.has(seat):
			seats[seat] = {"A": 0, "B": 0, "draw": 0}
		seats[seat][winner] += 1
		var seed_i := int(game["seed"])
		if not pair_scores.has(seed_i):
			pair_scores[seed_i] = []
		pair_scores[seed_i].append(1.0 if winner == "A" else (0.0 if winner == "B" else 0.5))
		durations.append(float(game["duration_ms"]))
		rounds.append(int(game["rounds"]))
	var paired_means: Array = []
	for seed_i in pair_scores:
		var scores: Array = pair_scores[seed_i]
		if scores.size() == 2:
			paired_means.append((float(scores[0]) + float(scores[1])) / 2.0)
	var decided := int(wins["A"]) + int(wins["B"])
	var all_games := maxi(games.size(), 1)
	return {
		"completed_games": games.size(), "completed_seed_pairs": paired_means.size(),
		"a_wins": wins["A"], "b_wins": wins["B"], "draws": wins["draw"],
		"a_decisive_win_rate": float(wins["A"]) / decided if decided > 0 else null,
		"draw_rate": float(wins["draw"]) / all_games,
		"a_score_rate": (float(wins["A"]) + 0.5 * float(wins["draw"])) / all_games,
		"a_score_pair_bootstrap_95": _pair_bootstrap(paired_means),
		"by_a_seat": seats,
		"game_duration_ms_p50": _quantile(durations, 0.50),
		"game_duration_ms_p95": _quantile(durations, 0.95),
		"rounds_p50": _quantile(rounds, 0.50),
		"rounds_p95": _quantile(rounds, 0.95),
	}


## 对种子对做非参数 bootstrap；随机流只属于报告统计，不接触游戏 RNG。
## 少于两对不报告区间。区间用于独立保留种子上的对比，不代表跨卡表泛化保证。
static func _pair_bootstrap(values: Array) -> Array:
	if values.size() < 2:
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = 9172026
	var means: Array = []
	for _sample_i in range(BOOTSTRAP_SAMPLES):
		var total := 0.0
		for _draw_i in range(values.size()):
			total += float(values[rng.randi_range(0, values.size() - 1)])
		means.append(total / values.size())
	return [_quantile(means, 0.025), _quantile(means, 0.975)]


static func _quantile(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[clampi(int(round((sorted.size() - 1) * p)), 0, sorted.size() - 1)])


static func _print_summary(summary: Dictionary) -> void:
	print("\nA %d 胜 / B %d 胜 / 无结果 %d，共 %d 局（%d 个种子对）" % [
		summary["a_wins"], summary["b_wins"], summary["draws"],
		summary["completed_games"], summary["completed_seed_pairs"]])
	if summary["a_decisive_win_rate"] != null:
		print("A 分胜负胜率：%.1f%%；无结果率：%.1f%%" % [
			100.0 * float(summary["a_decisive_win_rate"]), 100.0 * float(summary["draw_rate"])])
	print("A 得分率（无结果计半分）：%.1f%%" % (100.0 * float(summary["a_score_rate"])))
	var interval: Array = summary["a_score_pair_bootstrap_95"]
	if not interval.is_empty():
		print("得分率 95%% 种子对 bootstrap 区间：[%.1f%%, %.1f%%]" % [
			100.0 * float(interval[0]), 100.0 * float(interval[1])])
	print("按 A 座位：%s" % JSON.stringify(summary["by_a_seat"]))
	print("整局耗时 P50 %.1fms / P95 %.1fms；回合数 P50 %.0f / P95 %.0f" % [
		summary["game_duration_ms_p50"], summary["game_duration_ms_p95"],
		summary["rounds_p50"], summary["rounds_p95"]])
	if int(summary["completed_seed_pairs"]) < 30:
		print("样本少于 30 个种子对，当前结果只宜作冒烟检查。")
