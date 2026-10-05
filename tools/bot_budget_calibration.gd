# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

## 只测冻结局面的计算吞吐，不用于运行时停止或棋力评估。
## 参数：录像路径 计算上限 节点上限 输出JSON [决策序号，-1全部]
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4:
		printerr("需要录像、计算上限、节点上限和输出路径")
		quit(2)
		return
	CardDB.ensure_loaded()
	BOTConfig._source = "res://data/bot.json"
	var loaded := Tape.load_from(args[0])
	if not loaded.get("ok",false):
		printerr(loaded)
		quit(2)
		return
	var tape: Tape = loaded["tape"]
	if tape.table != StateCodec.table_hash():
		printerr("标定录像卡表不一致")
		quit(2)
		return
	var cfg := BOTSearch.from_strength(1.0)
	cfg.apply_override("compute_budget",int(args[1]))
	cfg.apply_override("node_budget",int(args[2]))
	var rows: Array = []
	var decisions: Array = tape.meta.get("bot_decisions",[])
	for index in decisions.size():
		if args.size() > 4 and int(args[4]) >= 0 and index != int(args[4]): continue
		var decision: Dictionary = decisions[index]
		var replayed := Tape.replay(tape,int(decision["before_step"])-1)
		if not replayed["ok"] or StateCodec.state_hash(replayed["state"]) != decision["state_hash"]:
			printerr("标定局面无法准确恢复：",index)
			quit(2)
			return
		var state: GameState = replayed["state"]
		var before := StateCodec.state_hash(state)
		var result := BOTPlan.choose_plan(state,str(decision["seat"]),cfg)
		if StateCodec.state_hash(state) != before:
			printerr("标定搜索改变输入局面")
			quit(1)
			return
		var diag: Dictionary = result["diagnostics"]
		var row := {"decision":index,"round":state.round_num,"state_hash":before,"rng":state.rng_snapshot(),
			"parameters":cfg.resolved_parameters(),"diagnostics":diag}
		rows.append(row)
		print(JSON.stringify({"decision":index,"ms":diag["elapsed_ms"],"compute":diag["compute_used"],
			"nodes":diag["candidate_expansions"],"stages":diag["completed_search_tasks"],"stop":diag["search_stop_reason"]}))
		var file := FileAccess.open(args[3],FileAccess.WRITE)
		file.store_string(JSON.stringify({"schema":"bot-budget-calibration-v1","engine":Engine.get_version_info(),
			"at":Time.get_datetime_string_from_system(true),"replay":args[0],"rows":rows},"  ",true,true)+"\n")
		file.close()
	quit()
