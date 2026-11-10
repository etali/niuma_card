# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

## Cold reconstruction of recorded positions; never claims to recover the
## original decision's unrecorded scores. Runs ordinary installed budgets.
const Config = preload("res://engine/off_work_config.gd")
const Bot = preload("res://engine/off_work_bot.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var request_path := ""
	var output_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--request="): request_path=arg.trim_prefix("--request=")
		if arg.begins_with("--output="): output_path=arg.trim_prefix("--output=")
	var request: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(request_path))
	var tape: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(request.replay))
	var results := []
	for sample in request.samples:
		var config := Config.new(tape.cards)
		var policy := Config.merge_bot_policy(config.rules.bot,Preferences.strength_parameters(float(sample.strength),config.rules.bot,config.bot_preferences))
		config.rules.bot=policy
		var world := OffWorkState.new(config)
		var index := -1
		for i in tape.frames.size():
			if float(tape.frames[i].t)<=float(sample.time): index=i
		var frame: Dictionary=tape.frames[index]
		var entry: Dictionary=bytes_to_var(Marshalls.base64_to_raw(frame.data).decompress(int(frame.size),FileAccess.COMPRESSION_ZSTD))
		for key in OffWorkState.WORLD_FIELDS: world.set(key,entry.world[key])
		world._rng.state=entry.rng
		world._invalidate_group_index()
		world.advance(maxf(0.0,float(sample.time)-world.time))
		var bot := Bot.new(world,int(sample.get("owner",1)),policy,20261110)
		var action := bot.decide_action()
		var result := {"sample":sample,"frame":index,"restored_time":frame.t,"action":action,"report":bot.last_decision}
		results.append(result)
		print("PROBE ",JSON.stringify({"sample":sample,"action":action,"elapsed_us":bot.last_decision.elapsed_us,"overrun":bot.last_decision.overrun,"continuation":bot.last_decision.get("root_continuation",{})}))
	var file := FileAccess.open(output_path,FileAccess.WRITE)
	file.store_string(JSON.stringify({"assumption":"cold reconstructed controller; original scores unknown","results":results},"\t",false,true))
	file.close()
	quit()
