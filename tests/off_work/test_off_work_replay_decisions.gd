extends "res://tests/harness.gd"

const Replay = preload("res://engine/off_work_replay.gd")

class EvidenceBot extends RefCounted:
	var owner := 1
	var decision_serial := 0
	var last_decision := {}

class EvidenceBoard extends Node:
	var _origin_by_gid := {}
	var _compact_by_gid := {}
	var group_overrides := {}
	var _spawned_by_owner := {}
	var _opening_counts := {}

class EvidenceHost extends Node:
	var state: OffWorkState
	var bot: EvidenceBot
	var board: EvidenceBoard

func _initialize() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":20}, {"employee":1}]
	config.rules.initial.money = 0
	var host := EvidenceHost.new()
	host.state = OffWorkState.new(config)
	host.state.new_game(60237)
	host.bot = EvidenceBot.new()
	host.board = EvidenceBoard.new()
	host.add_child(host.board)
	var replay := Replay.new()
	replay.record(host)
	check(replay.frames.size() == 1 and not _decode(replay, host).has("bot_decision"), "开局无已提交决策时不伪造证据")
	var employee: int = host.state._owner_type(1, "employee")[0]
	var work: int = host.state._owner_type(1, "work")[0]
	var command := {"kind":"move", "ids":[employee], "group":int(host.state.cards[work].group),
		"intent":"assemble_work", "reason":"将闲置员工投入工作", "execution_continuation":true}
	var hypothetical := {"world":{"cards":{"future":true}}, "commands":[{"action":{"kind":"wait"}}]}
	var candidates: Array = []
	for index in 12:
		candidates.append({"kind":"move", "intent":"assemble_work", "score":32.5-index, "tie_score":2.0,
			"world":hypothetical, "commands":hypothetical.commands})
	host.bot.decision_serial = 1
	host.bot.last_decision = {"action":command.merged({"execution_step":hypothetical}), "reason":"比较双方预计清空工作的时间",
		"applied":true, "algorithm":"shared_continuation", "evaluation_layer":"economic", "search_depth":4,
		"search_nodes":18, "evaluated":9, "root_complete":true, "root_coverage_complete":false,
		"root_candidates":12, "completed_candidates":9, "root_unobserved":3,
		"budget_ms":700, "elapsed_us":612345, "selected_after_us":580000,
		"evaluation":{"terminal":false, "scale":"relative completion time", "projection_seconds":1800.0,
			"sides":[{"eta":310.0,"current_rate":1.5,"remaining":0,"work":200,"required_actions":2,
				"production_chain":hypothetical}, {"eta":210.0,"current_rate":2.5,"remaining":0,"work":150,
				"forecast_commands":hypothetical.commands}], "world":hypothetical},
		"candidates":candidates, "principal_variation":hypothetical.commands, "world":hypothetical}
	host.bot.last_decision["root_continuation"] = {"complete":true, "plans":4, "examined":7, "evaluated":4,
		"choices":2, "rounds":6, "sides_evaluated":[3,1], "world":hypothetical, "callback":Callable(self,"_decode"),
		"side_0":{"root_actions":12,"root_serviced":9,"max_depth":4,"nodes":18,"pending":true,
			"release_reserve_us":4200,"world":hypothetical,"callback":Callable(self,"_decode")},
		"side_1":{"root_actions":10,"root_serviced":5,"max_depth":3,"nodes":12,"pending":true,
			"release_reserve_us":3000,"commands":hypothetical.commands}}
	host.bot.last_decision["root_growth"] = host.bot.last_decision.root_continuation
	var unchanged_revision := host.state.revision
	replay.record(host)
	check(replay.frames.size() == 2 and host.state.revision == unchanged_revision, "新决策即使没有规则事件也独立记录")
	var recorded: Dictionary = _decode(replay, host).bot_decision
	check(recorded.serial == 1 and recorded.owner == 1 and recorded.game_time == host.state.time
		and recorded.action == command and recorded.execution_continuation, "保留真实命令参数及决策身份，剔除语义执行计划")
	check(recorded.reason == host.bot.last_decision.reason and recorded.budget_ms == 700 and recorded.elapsed_us == 612345
		and recorded.selected_after_us == 580000, "保留决策理由、预算和实际计时")
	check(recorded.algorithm == "shared_continuation" and recorded.evaluation_layer == "economic"
		and recorded.search_depth == 4 and recorded.root_candidates == 12 and not recorded.root_coverage_complete,
		"保留算法、搜索层、深度和候选覆盖情况")
	check(recorded.root_continuation.complete and not recorded.root_coverage_complete
		and recorded.root_continuation.plans == 4 and recorded.root_continuation.sides_evaluated == [3,1],
		"已完成前缀的比较结果与尚未覆盖的根候选分别保留，不混为搜索全部完成")
	check(recorded.root_continuation.side_0 == {"root_actions":12,"root_serviced":9,"max_depth":4,
		"nodes":18,"pending":true,"release_reserve_us":4200}
		and recorded.root_continuation.side_1.root_serviced == 5
		and not recorded.has("root_growth") and not str(recorded).contains("callback"),
		"长期规划按双方保留覆盖、深度和待处理统计，剔除回调与重复旧别名")
	check(recorded.evaluation.sides[0].eta == 310.0 and recorded.evaluation.sides[1].current_rate == 2.5
		and recorded.evaluation.sides[1].remaining == 0 and recorded.evaluation.sides[1].owner == 1,
		"保留双方完成时间、当前产能和剩余工作")
	check(recorded.candidates.size() == 8 and recorded.candidates[0].score == 32.5
		and recorded.candidates[0].kind == "move" and recorded.candidates[0].intent == "assemble_work",
		"最多保存八个候选的数值评分和动作意图")
	check(not str(recorded).contains("commands") and not str(recorded).contains("world")
		and not str(recorded).contains("production_chain") and var_to_bytes(recorded).size() < 8000,
		"证据不包含假想世界、长指令链或任意嵌套搜索数据")
	host.bot.last_decision.evaluation.sides[0].eta = 9999.0
	check(_decode(replay, host).bot_decision.evaluation.sides[0].eta == 310.0, "已保存证据不受后续报告修改影响")
	replay.record(host)
	check(replay.frames.size() == 2, "同一决策不会额外制造自然帧")
	replay.record(host, [], true)
	check(not _decode(replay, host).has("bot_decision"), "强制关键帧不重复上一决策证据")
	host.state.advance(0.5)
	replay.record(host, [{"kind":"natural_test"}])
	check(not _decode(replay, host).has("bot_decision"), "自然规则事件帧不重复上一决策证据")
	var count := replay.frames.size()
	host.bot.decision_serial = 2
	host.bot.last_decision = {"action":{"kind":"wait"}, "applied":true, "reason":"保留当前安排",
		"root_growth":{"complete":false,"plans":1,"examined":3,"evaluated":1,"choices":1,
			"rounds":2,"sides_evaluated":[1,0],"world":hypothetical}}
	replay.record(host)
	check(replay.frames.size() == count+1 and _decode(replay, host).bot_decision.action.kind == "wait",
		"真实等待决策也保存一次证据，不依赖工作状态发生变化")
	check(_decode(replay, host).bot_decision.root_growth == {"complete":false,"plans":1,"examined":3,
		"evaluated":1,"choices":1,"rounds":2,"sides_evaluated":[1,0]}, "只有旧root_growth报告时仍保存裁剪后的比较证据")
	var evidence_frames := replay.frames.size()
	replay.playing = true
	host.bot.decision_serial = 3
	replay.record(host, [], true)
	check(replay.frames.size() == evidence_frames, "录像播放期间不记录BOT证据或运行决策")
	replay.playing = false
	var previous := host.bot
	host.bot = EvidenceBot.new()
	host.bot.decision_serial = 2
	host.bot.last_decision = previous.last_decision
	replay.record(host)
	check(replay.frames.size() == evidence_frames+1 and _decode(replay, host).has("bot_decision"),
		"更换BOT实例后重复的本地序号不会吞掉新决策")
	# Version 1 frames have always had optional extra fields. Historical frames
	# without evidence still decode identically; no BOT is consulted by decoding.
	var legacy: Dictionary = _decode(replay, host)
	legacy.erase("bot_decision")
	var raw := var_to_bytes(legacy)
	var old_frame := {"t":host.state.time, "data":Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD)), "size":raw.size()}
	check(Replay.decode_frame(old_frame,host.state) == legacy, "旧version 1录像无需决策字段仍完整读取")
	replay.reset()
	replay.record(host)
	check(replay.frames.size() == 1 and _decode(replay, host).has("bot_decision"), "重置录像同时重置决策去重标记")
	host.free()
	finish()

func _decode(replay: RefCounted, host: EvidenceHost) -> Dictionary:
	return Replay.decode_frame(replay.frames.back(),host.state)
