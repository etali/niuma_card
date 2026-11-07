extends SceneTree

var checks := 0
var errors: Array[String] = []

func _initialize() -> void:
	_test_opening()
	_test_income_route()
	_test_multiple_destinations()
	_test_first_income_and_refund()
	for error in errors: printerr("FAIL ", error)
	print("START_AND_INCOME ", "PASS" if errors.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if errors.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)

func _owned(state: OffWorkState, kind: String, owner := 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == kind and state.cards[id].owner == owner)

func _test_opening() -> void:
	var state := OffWorkState.new()
	state.new_game(234)
	for owner in [0, 1]:
		var pile_sizes: Array = []
		for gid in state.groups:
			if state.groups[gid].owner != owner: continue
			if not state.group_work(gid).is_empty():
				pile_sizes.append(state.group_work(gid).size())
				_check(state.group_people(gid).is_empty(), "开局工作各自成摞，未配员工")
		_check(pile_sizes == [200] and state.work_count(owner) == 200, "每方 200 份工作集中在同一摞")
		for id in _owned(state, "employee", owner):
			_check(state.group_cards(state.cards[id].group).size() == 1, "开局每名员工独立")
		_check(state.people_count(owner) == 1, "正式开局只有一名员工")
		_check(_owned(state, "money", owner).size() == 8 and _owned(state, "money", owner).all(func(id): return state.cards[id].amount == 1), "开局八元就是八张独立金钱牌")
	_check(state.tasks.is_empty(), "未组合前没有自动工作任务")
	state.advance(10.0)
	_check(state.work_count(0) == 200 and state.work_count(1) == 200 and state.money(0) == 8, "未安排员工不会凭空开工或产钱")

func _test_income_route() -> void:
	var state := OffWorkState.new()
	state.new_game(17)
	# Parallel-output coverage uses an explicit fixture; the shipped opening
	# remains one employee on each side.
	state.add_card("employee", 0)
	var people := _owned(state, "employee")
	var work: int = _owned(state, "work")[0]
	var group: int = state.cards[work].group
	var initial_money: int = _owned(state, "money")[0]
	var bank: int = state.cards[initial_money].group
	state.move_cards([people[0], people[1]], group)
	state.drain_events()
	state.advance(10.0)
	var incomes := state.drain_events().filter(func(event): return event.kind == "work_complete")
	_check(incomes.size() == 1 and incomes[0].ids.size() == 2 and incomes[0].participants == people and state.money(0) == 10, "两名员工一批完成两份、一个收入事件恰好两块")
	var uids: Array = []
	for event in incomes:
		_check(state.cards.has(event.money_id) and state.cards[event.money_id].type == "money", "收入事件引用真实金钱牌")
		_check(event.money_group == bank and state.cards[event.money_id].group == bank, "收入合入既有纯现金堆")
		_check(event.group == group and event.source in people and event.amount == event.money_ids.size() and event.money_ids.all(func(id): return state.cards[id].amount == 1), "来源、目标、金额可驱动真实动画")
		uids.append_array(event.money_ids)
	_check(uids.size() == 2 and state.group_cards(bank).size() == 10, "整批同时产两张真实金钱牌，合入八张开局现金")
	_check(state.group_cards(group).all(func(id): return state.cards[id].type != "money"), "工作组不塞收入牌")
	# Player intentionally moves old cash into a working group. Future income
	# must choose a new independent cash pile rather than add to the mixed group.
	state.move_cards(state.group_cards(bank), group)
	state.drain_events()
	state.advance(10.0)
	incomes = state.drain_events().filter(func(event): return event.kind == "work_complete")
	var fresh_bank: int = incomes[0].money_group
	_check(fresh_bank != group and fresh_bank != bank, "原现金组混入工作后另建纯现金堆")
	_check(incomes.all(func(event): return event.money_group == fresh_bank), "同批收入复用新现金堆")
	_check(state.group_cards(fresh_bank).all(func(id): return state.cards[id].type == "money"), "新现金堆完全独立于人员和工作")
	var before := state.money(0)
	state.offers[0].price = before
	_check(state.buy(state.offers[0].id, 0) >= 0 and state.money(0) == 0, "全部现金可在到账同刻花掉且仅扣一次")
	state.drain_events()
	state.advance(10.0)
	incomes = state.drain_events().filter(func(event): return event.kind == "work_complete")
	_check(incomes.size() == 1 and incomes[0].amount == 2 and state.money(0) == 2, "花空后下一批收入继续正常")
	_check(incomes[0].money_group != fresh_bank and state.group_cards(incomes[0].money_group) == incomes[0].money_ids, "花空后建立新现金堆并放入整批收入")
	state.new_game(17)
	_check(state.money(0) == 8 and _owned(state, "money").size() == 8 and state.tasks.is_empty(), "重开清除收入牌与任务")

func _test_multiple_destinations() -> void:
	var state := OffWorkState.new()
	state.new_game(31)
	var initial: int = _owned(state, "money")[0]
	var older: int = state.cards[initial].group
	var second := state.add_card("money", 0)
	state.cards[second].amount = 5
	var newer: int = state.cards[second].group
	var group: int = state.cards[_owned(state, "work")[0]].group
	state.move_cards([_owned(state, "employee")[0]], group)
	state.drain_events()
	state.advance(10.0)
	var incomes := state.drain_events().filter(func(event): return event.kind == "work_complete")
	_check(incomes[0].money_group == older, "默认选择最早建立的现金堆")
	state.config.rules.income.destination_policy = "newest_cash_pile"
	state.advance(10.0)
	incomes = state.drain_events().filter(func(event): return event.kind == "work_complete")
	_check(incomes[0].money_group == newer, "配置可切换为最新纯现金堆")
	state.config.rules.income.destination_policy = "work_group"
	_check(not state.config.validate(), "配置拒绝旧工作组收入去向")

func _test_first_income_and_refund() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.money = 0
	config.rules.initial.groups = [{"employee": 2, "work": 10}]
	var state := OffWorkState.new(config)
	state.new_game(27)
	state.drain_events()
	state.advance(10.0)
	var incomes := state.drain_events().filter(func(event): return event.kind == "work_complete" and event.owner == 0)
	_check(incomes.size() == 1 and incomes[0].amount == 2 and state.group_cards(incomes[0].money_group) == incomes[0].money_ids, "零初始资金也能建立独立现金堆并整批入账")
	var group: int = state.cards[_owned(state, "employee")[0]].group
	var person: int = _owned(state, "employee")[0]
	_check(state.dismiss_people([person], 0), "开除仍按真实规则执行")
	var fired: Dictionary = state.drain_events().filter(func(event): return event.kind == "fire")[0]
	_check(fired.money_id >= 0 and fired.money_group == incomes[0].money_group, "开除返款也进入独立现金堆")
	_check(state.group_cards(group).all(func(id): return state.cards[id].type != "money"), "返款不混入工作组")
