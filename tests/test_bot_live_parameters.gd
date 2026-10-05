# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Strategy = preload("res://engine/bot_strategy.gd")
const Registry = preload("res://engine/bot_strategy_registry.gd")

class ProbeStrategy extends Strategy:
	var fail_plan := false
	func identifier() -> String: return "live-parameters-test"
	func display_name() -> String: return "即时设置测试"
	func parameter_schema() -> Array:
		return [{"key":"width", "label":"宽度", "kind":"int", "min":1, "max":9,
			"step":1, "default":1, "strength_range":[1,9]}]
	func choose_plan(_state: GameState, who: String, config) -> Dictionary:
		# 故意无法执行的意图迫使驱动重规划，验证下一次搜索确实重新取设置。
		return {"intents":[Intent.pawn(who, [-999])] if fail_plan else [],
			"diagnostics":config.resolved_parameters()}
	func target_picker(config) -> Callable:
		var width: int = config.get_knob("width")
		var calls := [0]
		return func(_state: GameState, _who: String, _targets: Array, _pools: Dictionary) -> Dictionary:
			calls[0] += 1
			return {"width":width, "calls":calls[0]}

class ProbeMain extends "res://scenes/main.gd":
	var results: Array = []
	var after_search: Callable = Callable()
	func _think_off_thread(job: Callable) -> Variant:
		var result: Dictionary = job.call()
		results.append(result)
		if after_search.is_valid():
			after_search.call()
		return result
	func _session_current(_generation: int) -> bool: return true
	func _bot_beat(_step: String): return null

func _initialize() -> void:
	CardDB.ensure_loaded()
	var strategy := ProbeStrategy.new()
	check(Registry.register(strategy), "即时参数测试模型可注册")
	_test_search_snapshots()
	_test_explicit_configuration()
	_test_decision_recording()
	await _test_scene_replanning(strategy)
	await _test_live_target_picker()
	BOTSearch.restore_defaults()
	Registry.unregister(strategy.identifier())
	finish()

func _transport() -> LocalTransport:
	var state := GameState.new()
	state.set_seed(20261003)
	state.new_game()
	return LocalTransport.new(IntentApply.new(state))

func _test_search_snapshots() -> void:
	var current := [BOTSearch.from_model("live-parameters-test", 0.25)]
	var calls := [0]
	var agent := BOTAgent.new(_transport(), GameState.BOT, current[0])
	agent.config_provider = func() -> BOTSearch:
		calls[0] += 1
		return current[0]
	var old_job := agent.plan_job()
	check(calls[0] == 1, "新搜索创建时就在驱动线程读取当前参数")
	current[0] = BOTSearch.from_model("live-parameters-test", 1.0)
	var new_job := agent.plan_job()
	current[0].apply_override("width", 5)
	var old_result: Dictionary = old_job.call()
	var new_result: Dictionary = new_job.call()
	check(old_result["diagnostics"]["width"] == 3, "已创建搜索继续使用旧参数快照")
	check(new_result["diagnostics"]["width"] == 9, "下一次新搜索取得新参数且不受随后修改影响")
	check(calls[0] == 2, "执行已创建的搜索不再次读取可变玩家设置")

func _test_explicit_configuration() -> void:
	BOTSearch.set_pref_model("live-parameters-test")
	BOTSearch.set_pref_strength(0.75)
	var agent := BOTAgent.new(_transport(), GameState.BOT,
		BOTSearch.from_model("live-parameters-test", 0.0))
	var result: Dictionary = agent.plan_job().call()
	check(result["diagnostics"]["width"] == 1,
		"模拟器显式配置不受本次运行的玩家参数影响")

func _test_decision_recording() -> void:
	var pipe := _transport()
	var tape := Tape.new()
	tape.start(pipe.applier())
	var cfg := BOTSearch.from_model("live-parameters-test",0.75)
	var agent := BOTAgent.new(pipe,GameState.BOT,cfg)
	agent.decision_observer = tape.record_bot_decision
	agent.run_action_phase_sync()
	var decisions: Array = tape.meta.get("bot_decisions",[])
	check(tape.meta.rng == pipe.state().rng_snapshot() and tape.meta.rng.seed is String,
		"录像元信息保存精确字符串随机种子与当前位置")
	check(decisions[0].rng == pipe.state().rng_snapshot(),"每次BOT决策独立保存随机状态")
	check(decisions.size() == 1 and tape.steps.is_empty(), "空过决策也记录诊断，不增加录像规则步骤")
	check(decisions[0]["configuration"]["strength"] == 0.75
		and decisions[0]["configuration"]["parameters"]["width"] == 7
		and decisions[0]["before_step"] == 1,
		"录像保存本次决策真实参数和对应步骤，不借用开局设置")
	cfg.apply_override("width",1)
	check(decisions[0]["configuration"]["parameters"]["width"] == 7, "后续调参不改写历史决策")
	tape.stop()

func _test_scene_replanning(strategy: ProbeStrategy) -> void:
	BOTSearch.set_pref_model("live-parameters-test")
	BOTSearch.set_pref_strength(0.25)
	strategy.fail_plan = true
	var main := ProbeMain.new()
	main.pipe = _transport()
	main.after_search = func(): BOTSearch.set_override("width", 7)
	await main._drive_bot_action()
	check(main.results.size() == 4, "场景行动真实搜索并在非法意图后重规划")
	if main.results.size() == 4:
		check(main.results[0]["diagnostics"]["width"] == 3
			and main.results[1]["diagnostics"]["width"] == 7
			and main.results[2]["diagnostics"]["width"] == 7
			and main.results[3]["diagnostics"]["width"] == 7,
			"场景层读玩家偏好，重规划立即使用新参数")
	main.free()
	strategy.fail_plan = false

func _test_live_target_picker() -> void:
	BOTSearch.set_pref_model("live-parameters-test")
	BOTSearch.set_pref_strength(0.25)
	var main := ProbeMain.new()
	var choose: Callable = main._live_bot_target_picker()
	var state := _transport().state()
	var first: Dictionary = await choose.call(state, GameState.BOT, [], {})
	var second: Dictionary = await choose.call(state, GameState.BOT, [], {})
	check(first == {"width":3, "calls":1} and second == {"width":3, "calls":2},
		"参数不变时选靶复用同一闭包，保留攻击阶段共享预算")
	BOTSearch.set_override("width", 8)
	var manual: Dictionary = await choose.call(state, GameState.BOT, [], {})
	check(manual == {"width":8, "calls":1}, "手调参数在同一攻击阶段的下一次选靶生效")
	BOTSearch.set_pref_strength(0.75)
	var mapped: Dictionary = await choose.call(state, GameState.BOT, [], {})
	check(mapped == {"width":7, "calls":1}, "拖动强度在下一次选靶生效并清除手动覆盖")
	main.free()
