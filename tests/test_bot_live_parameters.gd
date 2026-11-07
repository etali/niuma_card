# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Strategy = preload("res://engine/on_work_bot_strategy.gd")
const Registry = preload("res://engine/on_work_bot_strategy_registry.gd")

class ProbeStrategy extends Strategy:
	var fail_plan := false
	func identifier() -> String: return "live-parameters-test"
	func display_name() -> String: return "即时设置测试"
	func parameter_schema() -> Array:
		return [{"key":"width", "label":"宽度", "kind":"int", "min":1, "max":9,
			"step":1, "default":1, "strength_range":[1,9]}]
	func choose_plan(_state: OnWorkState, who: String, config) -> Dictionary:
		# 故意无法执行的意图迫使驱动重规划，验证下一次搜索确实重新取设置。
		return {"intents":[OnWorkIntent.pawn(who, [-999])] if fail_plan else [],
			"diagnostics":config.resolved_parameters()}
	func target_picker(config) -> Callable:
		var width: int = config.get_knob("width")
		var calls := [0]
		return func(_state: OnWorkState, _who: String, _targets: Array, _pools: Dictionary) -> Dictionary:
			calls[0] += 1
			return {"width":width, "calls":calls[0]}

class ProbeMain extends "res://scenes/on_work_main.gd":
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
	OnWorkCardDB.ensure_loaded()
	var strategy := ProbeStrategy.new()
	check(Registry.register(strategy), "即时参数测试模型可注册")
	_test_search_snapshots()
	_test_explicit_configuration()
	_test_decision_recording()
	await _test_scene_replanning(strategy)
	await _test_live_target_picker()
	OnWorkBOTSearch.restore_defaults()
	Registry.unregister(strategy.identifier())
	finish()

func _transport() -> OnWorkLocalTransport:
	var state := OnWorkState.new()
	state.set_seed(20261003)
	state.new_game()
	return OnWorkLocalTransport.new(OnWorkIntentApply.new(state))

func _test_search_snapshots() -> void:
	var current := [OnWorkBOTSearch.from_model("live-parameters-test", 0.25)]
	var calls := [0]
	var agent := OnWorkBOTAgent.new(_transport(), OnWorkState.BOT, current[0])
	agent.config_provider = func() -> OnWorkBOTSearch:
		calls[0] += 1
		return current[0]
	var old_job := agent.plan_job()
	check(calls[0] == 1, "新搜索创建时就在驱动线程读取当前参数")
	current[0] = OnWorkBOTSearch.from_model("live-parameters-test", 1.0)
	var new_job := agent.plan_job()
	current[0].apply_override("width", 5)
	var old_result: Dictionary = old_job.call()
	var new_result: Dictionary = new_job.call()
	check(old_result["diagnostics"]["width"] == 3, "已创建搜索继续使用旧参数快照")
	check(new_result["diagnostics"]["width"] == 9, "下一次新搜索取得新参数且不受随后修改影响")
	check(calls[0] == 2, "执行已创建的搜索不再次读取可变玩家设置")

func _test_explicit_configuration() -> void:
	OnWorkBOTSearch.set_pref_model("live-parameters-test")
	OnWorkBOTSearch.set_pref_strength(0.75)
	var agent := OnWorkBOTAgent.new(_transport(), OnWorkState.BOT,
		OnWorkBOTSearch.from_model("live-parameters-test", 0.0))
	var result: Dictionary = agent.plan_job().call()
	check(result["diagnostics"]["width"] == 1,
		"模拟器显式配置不受本次运行的玩家参数影响")

func _test_decision_recording() -> void:
	var pipe := _transport()
	var tape := OnWorkTape.new()
	tape.start(pipe.applier())
	var cfg := OnWorkBOTSearch.from_model("live-parameters-test",0.75)
	var agent := OnWorkBOTAgent.new(pipe,OnWorkState.BOT,cfg)
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
	OnWorkBOTSearch.set_pref_model("live-parameters-test")
	OnWorkBOTSearch.set_pref_strength(0.25)
	strategy.fail_plan = true
	var main := ProbeMain.new()
	main.pipe = _transport()
	main.after_search = func(): OnWorkBOTSearch.set_override("width", 7)
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
	OnWorkBOTSearch.set_pref_model("live-parameters-test")
	OnWorkBOTSearch.set_pref_strength(0.25)
	var main := ProbeMain.new()
	var choose: Callable = main._live_bot_target_picker()
	var state := _transport().state()
	var first: Dictionary = await choose.call(state, OnWorkState.BOT, [], {})
	var second: Dictionary = await choose.call(state, OnWorkState.BOT, [], {})
	check(first == {"width":3, "calls":1} and second == {"width":3, "calls":2},
		"参数不变时选靶复用同一闭包，保留攻击阶段共享预算")
	OnWorkBOTSearch.set_override("width", 8)
	var manual: Dictionary = await choose.call(state, OnWorkState.BOT, [], {})
	check(manual == {"width":8, "calls":1}, "手调参数在同一攻击阶段的下一次选靶生效")
	OnWorkBOTSearch.set_pref_strength(0.75)
	var mapped: Dictionary = await choose.call(state, OnWorkState.BOT, [], {})
	check(mapped == {"width":7, "calls":1}, "拖动强度在下一次选靶生效并清除手动覆盖")
	main.free()
