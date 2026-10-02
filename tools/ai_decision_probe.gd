# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

const Env = preload("res://engine/ai_environment.gd")
const Duel = preload("res://tools/ai_duel.gd")

## 在独立顺序进程中计时，对同一组局面分别调用当前实现的低/高强度；不是对局胜率测量。
func _initialize() -> void:
	var command := OS.get_cmdline_user_args()
	if not command.is_empty() and command[0] == "fixed":
		_fixed(command)
		return
	CardDB.ensure_loaded()
	var positions: Array = []
	for seed_i in [41, 42, 43, 44]:
		MatchSimulator.run_rounds(3, seed_i,
			func(s: GameState) -> void:
				positions.append(Env.copy(s)), Callable(), Callable(),
			AISearch.duel_seats(AISearch.from_model("ai", 0), AISearch.from_model("ai",0), false))
	var report := {"kind":"serial-same-positions-action-only", "positions":positions.size(),
		"engine_hash":Duel._engine_source_hash(), "table_hash":StateCodec.table_hash(), "rows":[], "summary":{}}
	for model in ["ai:0", "ai:1"]:
		var timings: Array = []
		for i in positions.size():
			var state: GameState = positions[i]
			var config := AISearch.from_tier(model)
			var t := Time.get_ticks_usec()
			var selected := AIPlan.choose_plan(state,state.action_first(),config)
			var ms := (Time.get_ticks_usec()-t)/1000.0
			timings.append(ms)
			report["rows"].append({"model":model,"position":i,"round":state.round_num,
				"ms":ms,"diagnostics":selected.get("diagnostics",{})})
			print(model," position=",i," ms=",ms)
		report["summary"][model] = {"p50_ms":Duel._quantile(timings,0.5),"p95_ms":Duel._quantile(timings,0.95),"max_ms":timings.max()}
	var args := OS.get_cmdline_user_args()
	if args.size()>0:
		Duel._save_report(args[0],report)
	print(JSON.stringify(report["summary"]))
	quit()

## 在冻结基线产生的相同局面上测量；状态恢复、参数解析、重放与进程启动不计入决策耗时。
## 同一脚本可以用绝对路径在两个 --path 项目内执行，不改写冻结项目的任何既有源文件。
## godot --headless --path PROJECT -s /absolute/tools/ai_decision_probe.gd -- fixed INPUT.json OUTPUT.json
func _fixed(args: PackedStringArray) -> void:
	if args.size() != 3:
		printerr("用法：ai_decision_probe.gd -- fixed INPUT.json OUTPUT.json")
		quit(2)
		return
	var input: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	if not input is Dictionary or input.get("schema") != "ai-fixed-decisions-v1":
		printerr("无效的固定局面输入")
		quit(2)
		return
	CardDB.reset()
	AIConfig._source = "res://data/ai.json"
	if not CardDB.load_default():
		quit(2)
		return
	var payload: Array = []
	var timings: Array = []
	for fixture in input["positions"]:
		var cfg := AISearch.from_model("ai",float(fixture["strength"]))
		for key in fixture.get("overrides",{}):
			if not cfg.apply_override(key,fixture["overrides"][key]):
				printerr("无效固定局面AI参数：",key)
				quit(2)
				return
		var warmup_ms: Array = []
		var samples_ms: Array = []
		var outcomes: Array = []
		for repeat in range(-int(input.get("warmups",1)),int(input.get("repetitions",3))):
			var state := GameState.new()
			StateCodec.restore(state,fixture["snapshot"])
			state.stats = fixture["snapshot"].get("stats",state.stats).duplicate(true)
			var before := StateCodec.snapshot(state)
			var started := Time.get_ticks_usec()
			var selected := AIPlan.choose_plan(state,str(fixture["seat"]),cfg)
			var elapsed_ms := (Time.get_ticks_usec()-started)/1000.0
			if StateCodec.snapshot(state) != before:
				printerr("固定局面搜索修改原状态：",fixture["name"])
				quit(1)
				return
			selected.get("diagnostics",{}).erase("elapsed_ms")
			var replay := Env.copy(state)
			if not Env.replay(replay,selected["intents"]):
				printerr("固定局面搜索产生非法意图：",fixture["name"])
				quit(1)
				return
			outcomes.append({"selected":selected,"after":StateCodec.snapshot(replay),"stats":replay.stats})
			if repeat < 0: warmup_ms.append(elapsed_ms)
			else: samples_ms.append(elapsed_ms)
		if not outcomes.all(func(outcome): return outcome == outcomes[0]):
			printerr("固定局面多次决策不一致：",fixture["name"])
			quit(1)
			return
		payload.append({"name":fixture["name"],"seat":fixture["seat"],"parameters":cfg.resolved_parameters(),
			"outcome":outcomes[0]})
		timings.append({"name":fixture["name"],"strength":fixture["strength"],"warmup_ms":warmup_ms,
			"samples_ms":samples_ms,"median_ms":Duel._quantile(samples_ms,0.5),"max_ms":samples_ms.max()})
	var file := FileAccess.open(args[2],FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"schema":"ai-fixed-decisions-v1","payload":payload,"timings":timings},"  ",true,true)+"\n")
	file.close()
	print("fixed decisions=",payload.size())
	quit(0)
