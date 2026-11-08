extends "res://tests/harness.gd"
const Scripted = preload("res://tools/balance/off_work_scripted_baseline.gd")
const Scenarios = preload("res://tools/balance/off_work_benchmark_scenarios.gd")

func _initialize() -> void:
	_growth()
	_recovery()
	_outsource()
	_production_reference_policy()
	_capability_references()
	finish()

func _state(scenario: String) -> OffWorkState:
	var config := OffWorkConfig.new()
	check(Scenarios.configure(config, scenario), "压力开局遵守当前卡牌规则：" + scenario)
	var state := OffWorkState.new(config)
	state.new_game(613)
	check(Scenarios.prepare(state, scenario), "压力开局仅用真实操作建立：" + scenario)
	return state

func _bot(state: OffWorkState, mode: String) -> RefCounted:
	return Scripted.new(state, 0, {"mode":mode, "algorithm":"scripted_race_v1", "think_seconds":2.0, "first_action_seconds":0.0, "enabled":true})

func _apply(bot: RefCounted) -> Dictionary:
	var action: Dictionary = bot.decide_action()
	check(bot.commit_action(action, bot.last_decision), "强脚本执行真实合法动作：" + str(action.kind))
	return action

func _growth() -> void:
	var state := _state("growth")
	var bot := _bot(state, "growth")
	var action := _apply(bot)
	check(action.kind == "move" and action.ids.size() == 6, "扩张基线一次编入全部闲置员工")
	var group: int = state.cards[state._owner_type(0, "work")[0]].group
	check(state.group_work_participants(group).size() == 18, "生产基线实际使用超过十名人员")
	_apply(bot)
	check(state.group_tools(group).filter(func(id): return state.cards[id].type == "overtime").size() == 6,
		"基线实际安装超过四张加班")
	state.offers = [state._make_offer("employee")]
	action = _apply(bot)
	check(action.kind == "buy" and state.people_count(0) == 19, "十八人之后仍按收益继续购买人员")
	_apply(bot)
	state.offers = [state._make_offer("overtime")]
	action = _apply(bot)
	check(action.kind == "buy" and state._owner_type(0, "overtime").size() == 7, "六张加班之后仍按收益继续采购")

func _recovery() -> void:
	var state := _state("recovery")
	check(state.offers.is_empty(), "返岗能力夹具没有可替代首轮返岗的公开投资，正常输送规则仍保留")
	var ready: Array = state._owner_type(0, "employee")
	check(ready.size() == 18 and ready.all(func(id): return not state.is_striking(id) and not state.tasks.has(id)),
		"真实罢工结束后十八名人员分别闲置")
	var bot := _bot(state, "recovery")
	var action := _apply(bot)
	check(action.kind == "move" and action.ids.size() == 18, "一次真实合组让全体罢工人员返岗，不截到十六人")
	var gid: int = state.cards[ready[0]].group
	check(state.group_work_participants(gid).size() == 18, "返岗后全体参与下一批工作")

func _outsource() -> void:
	var state := _state("outsource")
	var bot := _bot(state, "outsource")
	var action := _apply(bot)
	check(action.kind == "move" and action.ids.size() > 16, "外包基线提交完整大额材料组合")
	check(state.outsourcing.size() == 1 and state.outsourcing.values()[0].work_ids.size() == 48,
		"真实规则开始四十八份外包，而非十六份")
	state.advance(state.config.number("outsource", "seconds"))
	check(state.work_count(0) == 0 and state.winner == 0, "大额外包按原读条完成并清空工作")

func _production_reference_policy() -> void:
	for mode in ["production", "growth"]:
		for work in [6, 7]:
			var config := OffWorkConfig.new()
			config.rules.initial.groups = [{"employee":3, "work":work}, {"employee":2}]
			config.rules.initial.money = 30
			var state := OffWorkState.new(config)
			state.new_game(614)
			state.offers = [{}, {}, {}, {}, {}, state._make_offer("employee")]
			var bot := _bot(state, mode)
			_apply(bot)
			state.advance(2.0)
			check(bot._production_purchase(bot._workplace()).is_empty() == (work == 7),
				"批量能力参考只为减少实际工作批次提出额外采购：%d份" % work)
			var action: Dictionary = bot.decide_action()
			check((action.kind == "buy") == (mode == "production" or work == 7),
				"独立参考按实际批量收益采购，不硬编码19人也不改变正常增长脚本：%s/%d" % [mode, work])

func _capability_references() -> void:
	var deadlines := {"production":4.0, "overtime":2.0, "recovery":0.0, "outsource":10.0}
	for scenario in deadlines:
		for owner in 2:
			var state := _state(scenario)
			if scenario == "production":
				check(state.people_count(owner) == 18 and state.work_count(owner) == 19,
					"生产能力夹具让第19名员工与一批完成19份工作的真实获胜目标一致")
			var bot := Scripted.new(state, owner, {"mode":scenario, "algorithm":"scripted_race_v1",
				"think_seconds":2.0, "first_action_seconds":0.0, "enabled":true})
			bot.start()
			var start := state.time
			var observed := Scenarios.observe(state, owner)
			while not Scenarios.achieved(scenario, observed) and state.time < start + 20.0 and state.winner < 0:
				bot._next_think = state.time + 2.0
				_apply(bot)
				observed = Scenarios.observe(state, owner, observed)
				if Scenarios.achieved(scenario, observed): break
				state.advance(2.0)
				observed = Scenarios.observe(state, owner, observed)
			check(Scenarios.achieved(scenario, observed), "独立能力目标实际达成：%s 座 %d" % [scenario, owner])
			check(is_equal_approx(state.time - start, deadlines[scenario]),
				"强脚本参考耗时来自真实动作间隔和读条：%s 座 %d" % [scenario, owner])
			if scenario == "production":
				state.advance(start + 9.999 - state.time)
				check(state.winner < 0 and state.work_count(owner) == 19,
					"19人合组不提前结算第一批工作：座 %d" % owner)
				state.advance(0.001)
				check(state.winner == owner and state.work_count(owner) == 0,
					"第19名员工让19份工作真实一批完工，批量编组无旧10人上限：座 %d" % owner)
