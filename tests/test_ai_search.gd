# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Registry = preload("res://engine/ai_strategy_registry.gd")
const Strategy = preload("res://engine/ai_strategy.gd")
const Env = preload("res://engine/ai_environment.gd")
const Eval = preload("res://engine/ai_evaluation.gd")

## 新实现只需提供接口；参数UI、校验、强度映射、保存和调度都不添加模型分支。
class TestStrategy extends Strategy:
	func identifier() -> String: return "interface-test"
	func display_name() -> String: return "测试接口"
	func parameter_schema() -> Array:
		return [
			{"key":"width","label":"宽度","kind":"int","min":1,"max":9,"step":1,"default":1,"strength_range":[1,9]},
			{"key":"temperature","label":"温度","kind":"float","min":0.0,"max":1.0,"step":0.1,"default":0.4},
			{"key":"enabled","label":"启用","kind":"bool","default":true},
			{"key":"mode","label":"模式","kind":"enum","default":"safe","options":[{"value":"safe","label":"稳健"},{"value":"wide","label":"扩展"}]},
		]
	func choose_plan(_state: GameState, _who: String, config) -> Dictionary:
		return {"intents":[], "diagnostics":config.resolved_parameters()}
	func evaluate(_state: GameState, _who: String, p: Dictionary) -> float:
		return float(p["temperature"])
	func target_picker(_config) -> Callable:
		return func(_s: GameState, _w: String, targets: Array, _p: Dictionary) -> Dictionary:
			return targets[0] if not targets.is_empty() else {}

class BadStrategy extends TestStrategy:
	func identifier() -> String: return "bad-interface"
	func parameter_schema() -> Array:
		return [{"key":"oops","label":"无效","kind":"nonsense","default":1}]

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_registration()
	_test_strength_and_types()
	_test_preferences()
	_test_real_search_parameters()
	_test_agent_replay()
	finish()

func _test_registration() -> void:
	check(AISearch.models() == [{"id":"ai","label":"AI"}], "只注册当前AI，不保留旧策略入口")
	check(Registry.get_strategy("v1") == null and Registry.get_strategy("v2") == null,
		"旧模型不注册为策略或隐藏别名")
	check(Registry.register(TestStrategy.new()), "新增实现只注册接口即可接入")
	check(not Registry.register(TestStrategy.new()) and not Registry.register(BadStrategy.new()), "拒绝重复模型与无效schema")
	var cfg := AISearch.from_model("interface-test",0.5)
	check(AISearch.editable_knobs(cfg.model).size() == 4, "面板能发现新模型的四种参数，无需改面板代码")
	var s := GameState.new()
	s.set_seed(18)
	s.new_game()
	check(cfg.apply_override("mode","wide") and cfg.apply_override("temperature",0.7), "新模型支持枚举与浮点覆盖")
	var plan := AIPlan.choose_plan(s, GameState.AI, cfg)
	check(plan["diagnostics"]["width"] == 5 and plan["diagnostics"]["mode"] == "wide", "通用搜索入口使用新模型及其最终参数")
	check(is_equal_approx(AIPlan.score(s, GameState.AI, cfg),0.7), "通用评估入口把覆盖传给实现")
	check(not AIPlan.target_picker(cfg).is_null(), "通用选靶入口来自实现接口")
	check(Registry.unregister("interface-test"), "测试模型可解除注册")

func _test_strength_and_types() -> void:
	var previous := AISearch.from_strength(0).resolved_parameters()
	for i in range(1,11):
		var current := AISearch.from_strength(i/10.0).resolved_parameters()
		var monotone := true
		for spec in AISearch.editable_knobs("ai"):
			if spec.has("strength_range"):
				monotone = monotone and float(current[spec["key"]]) >= float(previous[spec["key"]])
		check(monotone, "强度%.1f预算非递减" % (i/10.0))
		previous = current
	check(AISearch.from_strength(-9).strength == 0 and AISearch.from_strength(9).strength == 1, "强度夹取0~1")
	check(AISearch.from_tier("ai:mid").strength == AISearch.parse_strength("mid"), "模型和命名强度解析一致")
	var c := AISearch.from_strength(0)
	check(not c.apply_override("unknown",10) and not c.apply_override("node_budget","bad"), "未知参数或错误类型不进入profile")
	var numeric_enum := {"kind":"enum","options":[{"value":1,"label":"one"},{"value":2,"label":"two"}]}
	check(Strategy.validate_value(numeric_enum,2.0) == 2 and Strategy.validate_value(numeric_enum,"2") == null,
		"数值枚举支持JSON往返，字符串伪数字不冒充枚举")
	check(not c.apply_override("engine_horizon",NAN), "拒绝非有限参数，不能污染比较分数")
	check(c.apply_override("node_budget",-1) and c.get_knob("node_budget") == 1, "整数边界按schema夹取")
	check(c.apply_override("engine_horizon",99.0) and c.get_knob("engine_horizon") == 10.0, "浮点边界按schema夹取")
	var snapshot := c.resolved_parameters()
	snapshot["node_budget"] = 99
	check(c.get_knob("node_budget") == 1, "解析profile返回副本，调用方不会污染配置")

func _test_preferences() -> void:
	var had := FileAccess.file_exists(AISearch.USER_PATH)
	var real := FileAccess.get_file_as_string(AISearch.USER_PATH) if had else ""
	var old_pref := AISearch._pref
	var old_model := AISearch._model_pref
	var old_overrides := AISearch._overrides.duplicate(true)
	var f := FileAccess.open(AISearch.USER_PATH,FileAccess.WRITE)
	f.store_string(JSON.stringify({"model":"v2","strength":0.7,
		"overrides":{"buy_beam":9,"engine_horizon":4.5,"buy_width":8}}))
	f.close()
	AISearch._reset_pref_cache()
	check(AISearch.pref_model() == "ai" and AISearch.pref_strength() == 0.7,
		"旧v2偏好迁移到AI，保留已设置强度")
	check(AISearch.prefs().get_knob("buy_beam") == 9 and AISearch.prefs().get_knob("engine_horizon") == 4.5
		and not AISearch._overrides.has("buy_width"), "迁移保留合法整数/浮点覆盖，剔除未知参数")
	var table_hash := StateCodec.table_hash()
	check(AISearch.save(), "可保存当前实现及覆盖")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(AISearch.USER_PATH))
	check(saved.get("model") == "ai" and saved.get("strength") == 0.7,
		"迁移后保存写入新模型名，保留原强度")
	AISearch._reset_pref_cache()
	check(AISearch.prefs().get_knob("buy_beam") == 9 and AISearch.prefs().get_knob("engine_horizon") == 4.5, "重读保存值不丢参数类型和精度")
	for legacy_model in ["v1", "unknown-model"]:
		f = FileAccess.open(AISearch.USER_PATH,FileAccess.WRITE)
		f.store_string(JSON.stringify({"model":legacy_model,"strength":0.7,
			"overrides":{"buy_beam":9,"engine_horizon":4.5}}))
		f.close()
		AISearch._reset_pref_cache()
		check(AISearch.pref_model() == "ai" and AISearch.pref_strength() == 0.7 and not AISearch.has_overrides(),
			"%s 偏好回当前模型、保留合法强度并清除旧覆盖" % legacy_model)
	AISearch.set_override("buy_beam",9)
	AISearch.set_pref_strength(0.2)
	check(not AISearch.has_overrides(), "移动强度滑块恢复该强度的整套参数")
	check(StateCodec.table_hash() == table_hash, "AI超参数不修改环境规则指纹")
	AISearch.restore_defaults()
	check(not FileAccess.file_exists(AISearch.USER_PATH) and AISearch.prefs().model == "ai", "恢复默认清除文件并使用当前AI")
	if had:
		f = FileAccess.open(AISearch.USER_PATH,FileAccess.WRITE)
		f.store_string(real)
		f.close()
	AISearch._pref = old_pref
	AISearch._model_pref = old_model
	AISearch._overrides = old_overrides

func _test_real_search_parameters() -> void:
	var s := GameState.new()
	s.set_seed(1)
	s.new_game()
	var cfg := AISearch.from_strength(0)
	cfg.apply_override("node_budget",5)
	cfg.apply_override("plans",1)
	cfg.apply_override("engine_horizon",0.0)
	var before := StateCodec.canon({"players":s.players,"snapshot":StateCodec.snapshot(s)})
	var selected := AIPlan.choose_plan(s,GameState.AI,cfg)
	var d: Dictionary = selected["diagnostics"]
	check(d["profile"]["node_budget"] == 5 and int(d["expanded_nodes"]) <= 5, "节点覆盖真正控制展开工作量")
	check(d["root_candidates"] <= 1 and d["profile"]["engine_horizon"] == 0.0, "方案与估值覆盖进入搜索内部，不只改面板显示")
	check(before == StateCodec.canon({"players":s.players,"snapshot":StateCodec.snapshot(s)}), "超参数搜索仍保持只读")
	var card := ""
	for id in CardDB.all_cards():
		var def := CardDB.get_def(str(id))
		if def.get("recipe_res","") == CardDB.RES_USER and def.get("output_res","") == CardDB.RES_CASH:
			card = str(id)
			break
	s.add_card(GameState.AI,card)
	var no_engine := cfg.resolved_parameters()
	var with_engine := no_engine.duplicate()
	with_engine["engine_horizon"] = 5.0
	check(Eval.score(s,GameState.AI,with_engine) > Eval.score(s,GameState.AI,no_engine), "浮点评估权重改变真实局面分，而不是闲置接口")

func _test_agent_replay() -> void:
	var s := GameState.new()
	s.set_seed(21)
	s.new_game()
	var cfg := AISearch.default_config()
	var chosen := AIPlan.choose_plan(s,GameState.PLAYER,cfg)
	var expected := Env.copy(s)
	check(Env.replay(expected,chosen["intents"]), "搜索计划通过环境验证")
	var manual := Env.copy(s)
	var agent := AIAgent.new(LocalTransport.new(IntentApply.new(manual)),GameState.PLAYER,cfg)
	var steps := []
	for _i in range(100):
		var step := agent.next_step()
		steps.append(step)
		if step == AIAgent.STEP_DONE:
			break
	check(steps.has(AIAgent.STEP_THINK) and steps.back() == AIAgent.STEP_DONE, "手动步进可完成搜索及意图序列")
	check(Env.key(expected) == Env.key(manual), "手动步进和直接重放后继一致")
	var sync := Env.copy(s)
	MatchSimulator.action_phase(sync,GameState.PLAYER)
	check(Env.key(sync) == Env.key(expected), "默认无头路径使用同一个当前最低档实现")
