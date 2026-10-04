# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.
extends SceneTree

const Report = preload("res://tools/eval_report.gd")
const Duel = preload("res://tools/ai_duel.gd")
const Logic = preload("res://tools/balance/logic.gd")
const DecisionStats = preload("res://tools/ai_decision_stats.gd")
var request: Dictionary
var options: Dictionary
var counts := {"A":0,"B":0,"draw":0}
var seats := {"player":{"A":0,"B":0,"draw":0},"ai":{"A":0,"B":0,"draw":0}}
var completed := 0
var rounds_sum := 0
var started := 0
var decision_totals := {"A":{},"B":{}}
var decision_trace: FileAccess

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		quit(2)
		return
	request = Report._json(args[0])
	options = request.get("options", {})
	AIConfig._source = "res://data/ai.json"
	var configs: Array[AISearch] = []
	var errors: Array = Logic.validate(Report._json(str(request.get("cards_path", ""))), Report._json("res://data/cards.json"))
	for side in ["a","b"]:
		var spec: Dictionary = options.get(side,{})
		var checked := options.duplicate()
		checked.merge(spec,true)
		errors.append_array(Report.validate_options(checked))
		if not errors.is_empty(): break
		var cfg := AISearch.from_strength(float(spec["strength"]))
		for key in spec.get("ai_parameters",{}):
			if not cfg.apply_override(str(key),spec["ai_parameters"][key]): errors.append("无效参数："+str(key))
		configs.append(cfg)
	if not errors.is_empty():
		printerr(errors)
		quit(2)
		return
	CardDB.reset()
	if not CardDB.load_from(str(request["cards_path"])):
		quit(2)
		return
	started = Time.get_ticks_usec()
	if OS.get_environment("CARD_AI_DUEL_TRACE") == "1":
		decision_trace = FileAccess.open(str(request["output_path"]).get_base_dir().path_join("decisions.jsonl"),FileAccess.WRITE)
		if decision_trace == null:
			printerr("无法创建逐决策诊断记录")
			quit(3)
			return
	var games: Array = []
	for pair in int(options["pairs"]):
		var seed_i := int(options["seed_start"]) + pair
		for swap in [false,true]:
			var game_started := Time.get_ticks_usec()
			var a_seat: String = GameState.AI if swap else GameState.PLAYER
			var decisions := {"A":{},"B":{}}
			var state := MatchSimulator.run_rounds(int(options["max_rounds"]),seed_i,
				func(s: GameState) -> void: _progress(seed_i,s.round_num),Callable(),Callable(),
				AISearch.duel_seats(configs[0],configs[1],swap),"",{
				"decision":func(s: GameState,who: String,decision: Dictionary) -> void:
					var side := "A" if who == a_seat else "B"
					DecisionStats.add(decisions[side],decision["diagnostics"])
					DecisionStats.add(decision_totals[side],decision["diagnostics"])
					if decision_trace != null:
						# 仅诊断时逐条追加；快照不携带此前累积战报，不回扫历史对局。
						decision_trace.store_line(JSON.stringify({"seed":seed_i,"swap":swap,"seat":who,
							"state":StateCodec.snapshot(AIEnvironment.copy(s)),"decision":decision}))
						decision_trace.flush()})
			var winner := "draw" if state.winner.is_empty() else ("A" if state.winner == a_seat else "B")
			games.append({"seed":seed_i,"swap":swap,"a_seat":a_seat,"winner":winner,
				"win_reason":state.win_reason,"rounds":mini(state.round_num,int(options["max_rounds"])),
				"decisions":decisions,"duration_ms":(Time.get_ticks_usec()-game_started)/1000.0})
			counts[winner] += 1
			seats[a_seat][winner] += 1
			completed += 1
			rounds_sum += mini(state.round_num,int(options["max_rounds"]))
			_progress(seed_i,0)
	# Expensive paired bootstrap and quantiles are computed once, never per progress update.
	var summary := Duel.summarize(games)
	summary["mean_rounds"] = float(rounds_sum)/completed
	summary["decisions"] = decision_totals
	var result := {"schema":"manual-ai-duel-v1","status":"complete","protocol":"paired-seed-seat-swap-v1",
		"a":Duel._config("A",configs[0]),"b":Duel._config("B",configs[1]),"options":options,
		"summary":summary,"games":games,"table_hash":StateCodec.table_hash(),
		"cards_sha256":FileAccess.get_sha256(str(request["cards_path"])),
		"ai_sha256":FileAccess.get_sha256(AIConfig.source_path()),"engine_source_hash":Duel._engine_source_hash(),
		"godot":Engine.get_version_info()["string"],"elapsed_seconds":(Time.get_ticks_usec()-started)/1000000.0}
	if not Report._write(str(request["output_path"]),result):
		quit(3)
		return
	quit(0)

func _progress(seed_i: int, round_num: int) -> void:
	var decided: int = counts["A"]+counts["B"]
	var summary := {"completed_games":completed,"a_wins":counts["A"],"b_wins":counts["B"],"draws":counts["draw"],
		"a_decisive_win_rate":float(counts["A"])/decided if decided else null,
		"draw_rate":float(counts["draw"])/completed if completed else null,
		"a_score_rate":(float(counts["A"])+0.5*counts["draw"])/completed if completed else null,
		"mean_rounds":float(rounds_sum)/completed if completed else null,"by_a_seat":seats}
	if not Report._write(str(request["progress_path"]),{"completed":completed,"total":int(options["pairs"])*2,
		"seed":seed_i,"round":round_num,"summary":summary,"decisions":decision_totals}):
		quit(3)
