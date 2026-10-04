# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Registry = preload("res://engine/ai_strategy_registry.gd")
const Strategy = preload("res://engine/ai_strategy.gd")
const Env = preload("res://engine/ai_environment.gd")
const Eval = preload("res://engine/ai_evaluation.gd")

## 新实现只需提供接口；参数UI、校验、强度映射和调度都不添加模型分支。
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
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_strength_endpoints.json"))
	for endpoint in [[0.0,"weak"],[0.5,"standard"],[1.0,"strong"]]:
		var actual := AISearch.from_strength(endpoint[0]).resolved_parameters()
		actual.erase("profile_version")
		var expected: Dictionary = baseline[endpoint[1]].duplicate(true)
		expected.erase("profile_version")
		var exact := actual.size() == expected.size()
		for key in expected: exact = exact and actual.get(key) == expected[key]
		check(exact,"强度%s的参数逐项等于约定的%s锚点" % endpoint)
	var schema := AISearch.editable_knobs("ai")
	var mapped := true
	var valid := true
	var low_half_exact := true
	for spec in schema:
		mapped = mapped and spec.get("strength_points",[]).size() >= 3 and spec.get("strength_interpolation") == "linear"
	for i in range(101):
		var strength := i/100.0
		var current := AISearch.from_strength(strength).resolved_parameters()
		for spec in schema:
			var key: String = spec["key"]
			valid = valid and Strategy.validate_value(spec,current[key]) == current[key]
			valid = valid and (current[key] is int if spec["kind"] == "int" else current[key] is float)
			if strength <= 0.5:
				var old_value := lerpf(float(baseline.weak[key]),float(baseline.standard[key]),strength*2)
				low_half_exact = low_half_exact and current[key] == Strategy.validate_value(spec,old_value)
	check(mapped,"全部参数通过相邻锚点线性映射，能力没有独立配置开关表")
	check(valid,"0到1的101个采样强度全部参数类型、步长与边界合法")
	check(low_half_exact,"整个低半轴按0与0.5锚点逐项插值")
	var intermediate := AISearch.from_strength(0.75).resolved_parameters()
	var smooth := AISearch.from_strength(0.875).resolved_parameters()
	check(intermediate.future_reply_limit==2 and intermediate.finalists==4 and intermediate.node_budget==215000, "高段中间锚点由通用映射解析，保持原0.75数值")
	check(smooth.future_reply_limit==65 and smooth.finalists==6 and smooth.node_budget==1107500, "0.75至1按相邻锚点平滑线性插值并量化")
	for pair in [[0.624,0],[0.625,1],[0.874,1],[0.875,2]]:
		check(AISearch.from_strength(pair[0]).get_knob("financing_mode") == pair[1],"典当覆盖在%s按连续插值合法取整为%s" % pair)
	check(AISearch.from_strength(0.749).get_knob("attack_mode") == 0 and AISearch.from_strength(0.75).get_knob("attack_mode") == 1,
		"二值能力阈值来自0到1插值后取整")
	check(AISearch.from_strength(0.5).get_knob("generation_budget") == 0
		and AISearch.from_strength(0.500001).get_knob("generation_budget") == 30000
		and AISearch.from_strength(0.51).get_knob("generation_budget") == 30000
		and AISearch.from_strength(0.75).get_knob("generation_budget") == 30000,
		"候选生成共享额度哨兵按有效额度平滑过渡，不在0.5右侧骤降到几百节点")
	var invalid_reference := preload("res://engine/ai_turn_strategy.gd").new().compile_parameters(0.51,{"node_budget":"bad"})
	check(invalid_reference.node_budget == 30000 and invalid_reference.generation_budget == 30000,
		"有效额度引用遇到非法外置值时与编译总预算使用同一fallback")
	check(AISearch.from_preset("legacy").resolved_parameters() == AISearch.from_strength(0.5).resolved_parameters()
		and AISearch.from_preset("enhanced").resolved_parameters() == AISearch.from_strength(1.0).resolved_parameters(),
		"旧命令名只是统一强度轴的入口别名")
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
	var table_hash := StateCodec.table_hash()
	var expected := AISearch.from_strength(AISearch.default_strength()).resolved_parameters()
	Registry.register(TestStrategy.new())
	var previous_settings := [
		{"model":"v2","strength":0.7,"overrides":{"buy_beam":9,"engine_horizon":4.5}},
		{"model":"ai","strength":1.0,"format_version":3,"overrides":{"node_budget":1}},
		{"model":"interface-test","strength":0.8,"overrides":{"mode":"wide"}},
		{"model":"unknown-model","strength":0.9},
		{"strength":"bad"}, {},
	]
	# harness 将 user:// 指向独立目录；只清理旧 AI 文件，不碰其他用户配置。
	var unrelated_path := "user://unrelated-settings.json"
	var unrelated := FileAccess.open(unrelated_path,FileAccess.WRITE)
	unrelated.store_string("unrelated settings")
	unrelated.close()
	for stored in previous_settings:
		var f := FileAccess.open(AISearch.USER_PATH,FileAccess.WRITE)
		f.store_string(JSON.stringify(stored))
		f.close()
		AISearch._reset_pref_cache()
		check(AISearch.pref_model() == AISearch.default_model()
			and AISearch.pref_strength() == AISearch.default_strength()
			and AISearch.prefs().resolved_parameters() == expected and not AISearch.has_overrides(),
			"忽略旧模型、强度与逐项参数，本次启动使用默认值：%s" % str(stored))
		check(not FileAccess.file_exists(AISearch.USER_PATH),"启动时删除旧 AI 参数文件")
	var malformed := FileAccess.open(AISearch.USER_PATH,FileAccess.WRITE)
	malformed.store_string("{invalid json")
	malformed.close()
	AISearch._reset_pref_cache()
	check(AISearch.pref_strength() == AISearch.default_strength()
		and not FileAccess.file_exists(AISearch.USER_PATH),"旧 AI 文件直接删除，无需解析损坏内容")
	check(FileAccess.get_file_as_string(unrelated_path) == "unrelated settings",
		"旧 AI 参数清理不影响其他用户设置")

	AISearch.set_pref_strength(0.73)
	AISearch.set_override("buy_beam",9)
	AISearch.set_override("engine_horizon",4.5)
	var active := AISearch.prefs()
	check(active.strength == 0.73 and active.get_knob("buy_beam") == 9
		and active.get_knob("engine_horizon") == 4.5,"修改强度及逐项参数立即进入当前运行配置")
	check(AISearch.prefs().resolved_parameters() == active.resolved_parameters(),
		"再次读取运行配置保留本次调整")
	check(not FileAccess.file_exists(AISearch.USER_PATH),"运行中调整 AI 参数始终不落盘")
	AISearch._reset_pref_cache()
	check(AISearch.pref_strength() == AISearch.default_strength()
		and AISearch.prefs().resolved_parameters() == expected and not AISearch.has_overrides(),
		"重新启动恢复默认参数，不保留上次强度或逐项覆盖")

	AISearch.set_pref_model("interface-test")
	AISearch.set_pref_strength(0.8)
	AISearch.set_override("enabled",false)
	AISearch.set_override("mode","wide")
	check(AISearch.prefs().model == "interface-test" and AISearch.prefs().get_knob("enabled") == false
		and AISearch.prefs().get_knob("mode") == "wide","运行时新模型及布尔、枚举覆盖无需保存即生效")
	AISearch._reset_pref_cache()
	check(AISearch.pref_model() == AISearch.default_model() and not AISearch.has_overrides(),
		"新启动不继承上次运行选择的模型")
	Registry.unregister("interface-test")

	AISearch.set_override("buy_beam",9)
	AISearch.set_pref_strength(0.2)
	check(not AISearch.has_overrides(), "移动强度滑块恢复该强度的整套参数")
	check(StateCodec.table_hash() == table_hash, "AI超参数不修改环境规则指纹")
	AISearch.restore_defaults()
	check(not FileAccess.file_exists(AISearch.USER_PATH)
		and AISearch.prefs().resolved_parameters() == expected, "还原默认即时重置参数且不创建存档")

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
