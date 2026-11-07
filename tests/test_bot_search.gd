# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Registry = preload("res://engine/on_work_bot_strategy_registry.gd")
const Strategy = preload("res://engine/on_work_bot_strategy.gd")
const Env = preload("res://engine/on_work_bot_environment.gd")
const Eval = preload("res://engine/on_work_bot_evaluation.gd")

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
	func choose_plan(_state: OnWorkState, _who: String, config) -> Dictionary:
		return {"intents":[], "diagnostics":config.resolved_parameters()}
	func evaluate(_state: OnWorkState, _who: String, p: Dictionary) -> float:
		return float(p["temperature"])
	func target_picker(_config) -> Callable:
		return func(_s: OnWorkState, _w: String, targets: Array, _p: Dictionary) -> Dictionary:
			return targets[0] if not targets.is_empty() else {}

class BadStrategy extends TestStrategy:
	func identifier() -> String: return "bad-interface"
	func parameter_schema() -> Array:
		return [{"key":"oops","label":"无效","kind":"nonsense","default":1}]

func _initialize() -> void:
	OnWorkCardDB.ensure_loaded()
	_test_registration()
	_test_strength_and_types()
	_test_preferences()
	_test_real_search_parameters()
	_test_agent_replay()
	finish()

func _test_registration() -> void:
	check(OnWorkBOTSearch.models() == [{"id":"bot","label":"BOT"}], "只注册当前BOT，不保留旧策略入口")
	check(Registry.get_strategy("v1") == null and Registry.get_strategy("v2") == null,
		"旧模型不注册为策略或隐藏别名")
	check(Registry.register(TestStrategy.new()), "新增实现只注册接口即可接入")
	check(not Registry.register(TestStrategy.new()) and not Registry.register(BadStrategy.new()), "拒绝重复模型与无效schema")
	var cfg := OnWorkBOTSearch.from_model("interface-test",0.5)
	check(OnWorkBOTSearch.editable_knobs(cfg.model).size() == 4, "面板能发现新模型的四种参数，无需改面板代码")
	var s := OnWorkState.new()
	s.set_seed(18)
	s.new_game()
	check(cfg.apply_override("mode","wide") and cfg.apply_override("temperature",0.7), "新模型支持枚举与浮点覆盖")
	var plan := OnWorkBOTPlan.choose_plan(s, OnWorkState.BOT, cfg)
	check(plan["diagnostics"]["width"] == 5 and plan["diagnostics"]["mode"] == "wide", "通用搜索入口使用新模型及其最终参数")
	check(is_equal_approx(OnWorkBOTPlan.score(s, OnWorkState.BOT, cfg),0.7), "通用评估入口把覆盖传给实现")
	check(not OnWorkBOTPlan.target_picker(cfg).is_null(), "通用选靶入口来自实现接口")
	check(Registry.unregister("interface-test"), "测试模型可解除注册")

func _test_strength_and_types() -> void:
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_strength_endpoints.json"))
	for endpoint in [[0.0,"weak"],[0.5,"standard"],[1.0,"strong"]]:
		var actual := OnWorkBOTSearch.from_strength(endpoint[0]).resolved_parameters()
		actual.erase("profile_version")
		var expected: Dictionary = baseline[endpoint[1]].duplicate(true)
		expected.erase("profile_version")
		var exact := actual.size() == expected.size()
		for key in expected: exact = exact and actual.get(key) == expected[key]
		check(exact,"强度%s的参数逐项等于约定的%s锚点" % endpoint)
	var schema := OnWorkBOTSearch.editable_knobs("bot")
	var valid := true
	var monotone := true
	var previous := OnWorkBOTSearch.from_strength(0.0).resolved_parameters()
	for i in range(101):
		var current := OnWorkBOTSearch.from_strength(i/100.0).resolved_parameters()
		for spec in schema:
			var key: String = spec["key"]
			valid = valid and Strategy.validate_value(spec,current[key]) == current[key]
			valid = valid and (current[key] is int if spec["kind"] == "int" else current[key] is float)
			monotone = monotone and float(current[key]) >= float(previous[key])
		previous = current
	check(valid,"101个强度的参数类型、步长与边界合法")
	check(monotone,"计算比例与阶段覆盖上限随强度非递减")
	check(OnWorkBOTSearch.from_strength(0).get_knob("compute_budget") == OnWorkBOTSearch.from_strength(1).get_knob("compute_budget"),
		"所有强度共享独立计算上限")
	var low_spec := OnWorkBOTSearch.from_strength(0.0).resolved_parameters()
	var high_spec := OnWorkBOTSearch.from_strength(1.0).resolved_parameters()
	low_spec.erase("search_fraction")
	high_spec.erase("search_fraction")
	check(low_spec == high_spec,"所有强度共用搜索规格，只有预算比例改变")
	check(not OnWorkBOTSearch.from_strength(1).resolved_parameters().has("think_time_ms"),"时间不参与搜索停止条件")
	check(OnWorkBOTSearch.from_strength(-9).strength == 0 and OnWorkBOTSearch.from_strength(9).strength == 1, "强度夹取0~1")
	check(OnWorkBOTSearch.from_tier("bot:mid").strength == OnWorkBOTSearch.parse_strength("mid"), "模型和命名强度解析一致")
	var c := OnWorkBOTSearch.from_strength(0)
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
	var table_hash := OnWorkStateCodec.table_hash()
	var expected := OnWorkBOTSearch.from_strength(OnWorkBOTSearch.default_strength()).resolved_parameters()
	Registry.register(TestStrategy.new())
	var previous_settings := [
		{"model":"v2","strength":0.7,"overrides":{"buy_beam":9,"engine_horizon":4.5}},
		{"model":"bot","strength":1.0,"format_version":3,"overrides":{"node_budget":1}},
		{"model":"interface-test","strength":0.8,"overrides":{"mode":"wide"}},
		{"model":"unknown-model","strength":0.9},
		{"strength":"bad"}, {},
	]
	# harness 将 user:// 指向独立目录；只清理旧 BOT 文件，不碰其他用户配置。
	var unrelated_path := "user://unrelated-settings.json"
	var unrelated := FileAccess.open(unrelated_path,FileAccess.WRITE)
	unrelated.store_string("unrelated settings")
	unrelated.close()
	for stored in previous_settings:
		var f := FileAccess.open(OnWorkBOTSearch.USER_PATH,FileAccess.WRITE)
		f.store_string(JSON.stringify(stored))
		f.close()
		OnWorkBOTSearch._reset_pref_cache()
		check(OnWorkBOTSearch.pref_model() == OnWorkBOTSearch.default_model()
			and OnWorkBOTSearch.pref_strength() == OnWorkBOTSearch.default_strength()
			and OnWorkBOTSearch.prefs().resolved_parameters() == expected and not OnWorkBOTSearch.has_overrides(),
			"忽略旧模型、强度与逐项参数，本次启动使用默认值：%s" % str(stored))
		check(not FileAccess.file_exists(OnWorkBOTSearch.USER_PATH),"启动时删除旧 BOT 参数文件")
	var malformed := FileAccess.open(OnWorkBOTSearch.USER_PATH,FileAccess.WRITE)
	malformed.store_string("{invalid json")
	malformed.close()
	OnWorkBOTSearch._reset_pref_cache()
	check(OnWorkBOTSearch.pref_strength() == OnWorkBOTSearch.default_strength()
		and not FileAccess.file_exists(OnWorkBOTSearch.USER_PATH),"旧 BOT 文件直接删除，无需解析损坏内容")
	check(FileAccess.get_file_as_string(unrelated_path) == "unrelated settings",
		"旧 BOT 参数清理不影响其他用户设置")

	OnWorkBOTSearch.set_pref_strength(0.73)
	OnWorkBOTSearch.set_override("buy_beam",9)
	OnWorkBOTSearch.set_override("engine_horizon",4.5)
	var active := OnWorkBOTSearch.prefs()
	check(active.strength == 0.73 and active.get_knob("buy_beam") == 9
		and active.get_knob("engine_horizon") == 4.5,"修改强度及逐项参数立即进入当前运行配置")
	check(OnWorkBOTSearch.prefs().resolved_parameters() == active.resolved_parameters(),
		"再次读取运行配置保留本次调整")
	check(not FileAccess.file_exists(OnWorkBOTSearch.USER_PATH),"运行中调整 BOT 参数始终不落盘")
	OnWorkBOTSearch._reset_pref_cache()
	check(OnWorkBOTSearch.pref_strength() == OnWorkBOTSearch.default_strength()
		and OnWorkBOTSearch.prefs().resolved_parameters() == expected and not OnWorkBOTSearch.has_overrides(),
		"重新启动恢复默认参数，不保留上次强度或逐项覆盖")

	OnWorkBOTSearch.set_pref_model("interface-test")
	OnWorkBOTSearch.set_pref_strength(0.8)
	OnWorkBOTSearch.set_override("enabled",false)
	OnWorkBOTSearch.set_override("mode","wide")
	check(OnWorkBOTSearch.prefs().model == "interface-test" and OnWorkBOTSearch.prefs().get_knob("enabled") == false
		and OnWorkBOTSearch.prefs().get_knob("mode") == "wide","运行时新模型及布尔、枚举覆盖无需保存即生效")
	OnWorkBOTSearch._reset_pref_cache()
	check(OnWorkBOTSearch.pref_model() == OnWorkBOTSearch.default_model() and not OnWorkBOTSearch.has_overrides(),
		"新启动不继承上次运行选择的模型")
	Registry.unregister("interface-test")

	OnWorkBOTSearch.set_override("buy_beam",9)
	OnWorkBOTSearch.set_pref_strength(0.2)
	check(not OnWorkBOTSearch.has_overrides(), "移动强度滑块恢复该强度的整套参数")
	check(OnWorkStateCodec.table_hash() == table_hash, "BOT超参数不修改环境规则指纹")
	OnWorkBOTSearch.set_override("compute_budget",240000)
	OnWorkBOTSearch.set_pref_strength(1.0)
	check(OnWorkBOTSearch.prefs().get_knob("compute_budget") == 240000,"改变强度保留玩家计算上限")
	OnWorkBOTSearch.restore_defaults()
	check(not FileAccess.file_exists(OnWorkBOTSearch.USER_PATH)
		and OnWorkBOTSearch.prefs().resolved_parameters() == expected, "还原默认即时重置参数且不创建存档")

func _test_real_search_parameters() -> void:
	var s := OnWorkState.new()
	s.set_seed(1)
	s.new_game()
	var cfg := OnWorkBOTSearch.from_strength(0)
	cfg.apply_override("compute_budget",100)
	cfg.apply_override("search_fraction",1.0)
	cfg.apply_override("plans",1)
	cfg.apply_override("engine_horizon",0.0)
	var before := OnWorkStateCodec.canon({"players":s.players,"snapshot":OnWorkStateCodec.snapshot(s)})
	var selected := OnWorkBOTPlan.choose_plan(s,OnWorkState.BOT,cfg)
	var d: Dictionary = selected["diagnostics"]
	check(d["profile"]["compute_budget"] == 100 and int(d["compute_used"]) <= 85, "计算覆盖控制实际工作量并为攻击预留额度")
	check(d["profile"]["plans"] == 1 and d["profile"]["engine_horizon"] == 0.0, "方案与估值覆盖进入搜索内部，不只改面板显示")
	check(before == OnWorkStateCodec.canon({"players":s.players,"snapshot":OnWorkStateCodec.snapshot(s)}), "超参数搜索仍保持只读")
	var card := ""
	for id in OnWorkCardDB.all_cards():
		var def := OnWorkCardDB.get_def(str(id))
		if def.get("recipe_res","") == OnWorkCardDB.RES_USER and def.get("output_res","") == OnWorkCardDB.RES_CASH:
			card = str(id)
			break
	s.add_card(OnWorkState.BOT,card)
	var no_engine := cfg.resolved_parameters()
	var with_engine := no_engine.duplicate()
	with_engine["engine_horizon"] = 5.0
	check(Eval.score(s,OnWorkState.BOT,with_engine) > Eval.score(s,OnWorkState.BOT,no_engine), "浮点评估权重改变真实局面分，而不是闲置接口")

func _test_agent_replay() -> void:
	var s := OnWorkState.new()
	s.set_seed(21)
	s.new_game()
	var cfg := OnWorkBOTSearch.default_config()
	var chosen := OnWorkBOTPlan.choose_plan(s,OnWorkState.PLAYER,cfg)
	var expected := Env.copy(s)
	check(Env.replay(expected,chosen["intents"]), "搜索计划通过环境验证")
	var manual := Env.copy(s)
	var agent := OnWorkBOTAgent.new(OnWorkLocalTransport.new(OnWorkIntentApply.new(manual)),OnWorkState.PLAYER,cfg)
	var steps := []
	for _i in range(100):
		var step := agent.next_step()
		steps.append(step)
		if step == OnWorkBOTAgent.STEP_DONE:
			break
	check(steps.has(OnWorkBOTAgent.STEP_THINK) and steps.back() == OnWorkBOTAgent.STEP_DONE, "手动步进可完成搜索及意图序列")
	check(Env.key(expected) == Env.key(manual), "手动步进和直接重放后继一致")
	var sync := Env.copy(s)
	OnWorkMatchSimulator.action_phase(sync,OnWorkState.PLAYER)
	check(Env.key(sync) == Env.key(expected), "默认无头路径使用同一个当前最低档实现")
