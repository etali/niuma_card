extends SceneTree

const Config = preload("res://engine/off_work_config.gd")
const State = preload("res://engine/off_work_state.gd")
const BotPreferences = preload("res://engine/off_work_bot_preferences.gd")
var failed := 0
var checked := 0

func _initialize() -> void:
	var config := Config.new()
	_check(config.errors.is_empty(), "配置完整")
	_check(config.cards.size() == 14 and not config.cards.has("involution") and not config.rules.has("involution"), "内卷牌和人数增益规则均已移除")
	_check(not config.can_purchase("involution") and not config.rules.conveyor.pool.has("involution"), "被移除卡不能购买或由传送带生成")
	for kind in ["employee", "grinder"]:
		_check(is_equal_approx(config.work_rate(kind, 0), 0.1), "基础十秒速度与角色收入倍率分开")
		for copies in range(1, 5):
			_check(is_equal_approx(config.work_rate(kind, copies), 0.1 * pow(1.2, copies)), "加班每张乘1.2，按配置叠乘")
	for count in [1, 2, 3, 5, 8]:
		var state := State.new(config)
		state.config.rules.initial.groups = [{"employee": count, "leader": 1, "work": 100}]
		state.new_game()
		var group: int = state.cards[state.cards.keys()[0]].group
		_check(is_equal_approx(state.group_work_rate(group), 0.1), "%d人组共享进度仍为十秒，领导不改变基础速率" % count)
		state.advance(10.0)
		_check(state.work_count(0) == 100 - count and state.money(0) == 8 + count, "增加人员线性增加同一批的处理份数与收入")
	config.rules.overtime.speed_multiplier = 1.5
	_check(is_equal_approx(config.work_rate("employee", 2), 0.225), "修改加班配置直接改变叠乘公式")
	_check(is_zero_approx(config.work_rate("leader", 4)), "领导不会因加班取得普通工作能力")
	_test_invalid_config()
	_test_decision_budget()
	print("work_rates: %d 通过 / %d 失败" % [checked - failed, failed])
	quit(1 if failed else 0)

func _test_invalid_config() -> void:
	for pair in [["outsource", "cost_per_work"], ["outsource", "seconds"], ["transfer", "seconds"], ["slack", "seconds"], ["conveyor", "employee_every"], ["conveyor", "interval_seconds"], ["meeting", "recovery_seconds"], ["bot", "think_seconds"]]:
		var config := Config.new()
		config.rules[pair[0]][pair[1]] = 0.0
		_check(not config.validate() and "\n".join(config.errors).contains(str(pair[0])), "零除数或零时长明确拒绝：%s.%s" % pair)
	var empty := Config.new()
	empty.rules.conveyor.pool = {}
	_check(not empty.validate(), "空供牌池被拒绝")
	var zero := Config.new()
	for kind in zero.rules.conveyor.pool:
		zero.rules.conveyor.pool[kind] = 0.0
	_check(not zero.validate(), "全零供牌权重被拒绝")
	var missing := Config.new()
	missing.rules.initial.groups = [{"employee": 1}]
	_check(not missing.validate(), "没有工作的开局被拒绝")
	var capability := Config.new()
	capability.roles.leader.can_work = 0
	_check(not capability.validate(), "角色工作能力必须显式布尔值")
	var missing_capability := Config.new()
	missing_capability.roles.leader.erase("can_work")
	_check(not missing_capability.validate(), "缺失工作能力配置明确拒绝")
	var role := Config.new()
	role.roles.employee.erase("work_seconds")
	_check(not role.validate(), "缺失角色字段明确拒绝")
	var malformed := Config.new()
	malformed.rules.coffee = []
	_check(not malformed.validate(), "错误配置对象类型不会引发读取异常")
	var invalid_category := Config.new()
	invalid_category.cards.coffee.category = "person"
	_check(not invalid_category.validate(), "咖啡材料类别不能改成人员")
	var overflowing := Config.new()
	overflowing.rules.overtime.speed_multiplier = 1e308
	overflowing.roles.employee.work_seconds = 0.1
	_check(not overflowing.validate(), "组合倍率溢出被拒绝")
	var state := State.new(zero)
	state.new_game()
	state.advance(10.0)
	_check(state.cards.is_empty() and state.time == 0.0 and not state.last_error.is_empty(), "错误配置阻止开局和模拟，不静默补默认值")
	zero.rules.conveyor.pool.employee = 1.0
	_check(zero.validate() and zero.errors.is_empty(), "修正后重新校验不会保留过期错误")
	var policy := Config.new()
	policy.rules.transfer.destination_policy = "unknown"
	_check(not policy.validate(), "未知甩锅落点策略明确拒绝")

func _check(ok: bool, name: String) -> void:
	checked += 1
	if not ok:
		failed += 1
		push_error(name)

func _test_decision_budget() -> void:
	var base := Config.new()
	_check(Config.decision_budget_ms(base.rules.bot) == 1400, "标准 2.8 游戏秒的 50% 为 1400 毫秒")
	BotPreferences.bind(State.new(base), base.bot_preferences)
	BotPreferences.set_override("think_seconds", 0.2)
	_check(Config.decision_budget_ms(base.rules.bot) == 100, "改变间隔立即换算预算")
	BotPreferences.set_pref_strength(1.0)
	_check(Config.decision_budget_ms(base.rules.bot) == 180 and base.rules.bot.think_seconds == 0.2, "最高强度只调整占比到 90%")
	BotPreferences.set_override("decision_budget_ratio", 0.01)
	_check(Config.decision_budget_ms(base.rules.bot) == 2 and BotPreferences.prefs().get_knob("budget_readout") == "2 毫秒", "派生数值与面板读数一致")
	_check(Config.decision_budget_ms({"think_seconds":0.0001,"decision_budget_ratio":0.01}) == 1, "不足一毫秒时仍有可用预算")
	_check(Config.decision_budget_ms({"think_seconds":2.8,"decision_budget_ratio":0.7}) == 1960, "整数边界消除浮点误差，70% 正好 1960 毫秒")
	_check(Config.decision_budget_ms({"think_seconds":0.219,"decision_budget_ratio":0.01}) == 2, "非整毫秒向下取整")
	BotPreferences.restore_defaults()
	var legacy := {"bot": base.rules.bot.duplicate(true), "preferences": base.bot_preferences.duplicate(true)}
	legacy.bot.erase("decision_budget_ratio")
	legacy.bot.think_seconds = 5.0
	legacy.bot.buy_chance = 0.23
	legacy.preferences.knobs = legacy.preferences.knobs.filter(func(k): return k.key != "decision_budget_ratio")
	var recovered := Config.new(base.balance_document(), legacy)
	_check(recovered.errors.is_empty() and Config.decision_budget_ms(recovered.rules.bot) == 12, "更早的无预算快照恢复为当时的固定 12 毫秒")
	_check(not legacy.bot.has("decision_budget_ms") and legacy.preferences.knobs.size() + 1 == recovered.bot_preferences.knobs.size(), "只为载入后的面板补占比选项，保留原快照")
	legacy.bot.decision_budget_ms = 7
	recovered = Config.new(base.balance_document(), legacy)
	BotPreferences.bind(State.new(recovered), recovered.bot_preferences)
	BotPreferences.set_override("think_seconds", 4.5)
	_check(Config.decision_budget_ms(recovered.rules.bot) == 7, "显式固定预算不因历史行动节奏变化而漂移")
	BotPreferences.set_pref_strength(1.0)
	_check(not recovered.rules.bot.has("decision_budget_ms") and Config.decision_budget_ms(recovered.rules.bot) == 4050 and recovered.rules.bot.buy_chance == 0.23, "主动更改强度切换到占比预算，保留行动间隔和购买倾向")
	_check(BotPreferences.has_overrides(), "修改档位后手调行动间隔仍标记为自定义")
	BotPreferences.restore_defaults()
	_check(recovered.rules.bot.think_seconds == 5.0 and not recovered.rules.bot.has("decision_budget_ratio") and Config.decision_budget_ms(recovered.rules.bot) == 7, "旧快照还原时恢复固定预算")
	for invalid in [0, -1, 12.1, 33, null, "12"]:
		recovered.rules.bot.decision_budget_ms = invalid
		_check(not recovered.validate() and "\n".join(recovered.errors).contains("bot.decision_budget_ms"), "明确拒绝无效旧预算：" + str(invalid))
	for invalid in [0, -1, 0.91, null, "0.5"]:
		base.rules.bot.decision_budget_ratio = invalid
		_check(not base.validate() and "\n".join(base.errors).contains("bot.decision_budget_ratio"), "明确拒绝无效占比：" + str(invalid))
	var fixed := Config.merge_bot_policy(legacy.bot, {"decision_budget_ratio":0.25})
	_check(not fixed.has("decision_budget_ms") and Config.decision_budget_ms(fixed) == 1250, "合并显式占比覆盖历史固定预算")
	base.rules.bot = Config.merge_bot_policy(fixed, {"decision_budget_ms":22})
	_check(base.validate() and Config.decision_budget_ms(base.rules.bot) == 22 and not base.rules.bot.has("decision_budget_ratio"), "新策略支持载入历史固定预算")
	base.rules.bot = Config.merge_bot_policy(base.rules.bot, {"decision_budget_ratio":0.1, "decision_budget_ms":15})
	_check(not base.validate() and "\n".join(base.errors).contains("只能使用一个"), "双模式同时显式指定时拒绝")
