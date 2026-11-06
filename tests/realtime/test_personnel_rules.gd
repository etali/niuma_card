extends SceneTree

const Config = preload("res://engine/work_config.gd")
const State = preload("res://engine/work_state.gd")
const Bot = preload("res://engine/work_bot.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_test_leader_cannot_work()
	_test_free_slack()
	_test_dismissal_validation()
	_test_dismissal_refunds()
	_test_dismissal_tasks()
	_test_dismiss_transfer()
	_test_bot_support()
	for message in failures: printerr("FAIL ", message)
	print("PERSONNEL_RULES ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _state(contents: Dictionary) -> RefCounted:
	var config := Config.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	var state := State.new(config)
	state.new_game(17)
	state.drain_events()
	return state

func _ids(state: RefCounted, kind: String, owner: int = 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == kind and int(state.cards[id].owner) == owner)

func _group(state: RefCounted, owner: int = 0) -> int:
	for group in state.groups:
		if int(state.groups[group].owner) == owner and not state.group_people(group).is_empty(): return int(group)
	return -1

func _snapshot(state: RefCounted) -> String:
	return JSON.stringify({"cards": state.cards, "groups": state.groups, "tasks": state.tasks, "meetings": state.meetings, "revision": state.revision}, "", true)

func _test_leader_cannot_work() -> void:
	var state := _state({"leader": 1, "work": 30})
	var group := _group(state)
	var leader: int = _ids(state, "leader")[0]
	var overtime: int = state.add_card("overtime", 0, group)
	var coffee: int = state.add_card("coffee", 0, group)
	_check(state.activate(overtime, group) and state.cards[overtime].status == "ready", "加班保持被动工具但不给领导工作能力")
	_check(not state.activate(coffee, group), "咖啡不能给空闲领导制造工作任务")
	state.advance(30.0)
	_check(state.work_count(0) == 30 and state.money(0) == 0 and state.tasks.is_empty(), "领导与工作加班咖啡共组仍不消工作不产钱")
	_check(state.cards[leader].activity == "idle" and is_zero_approx(state.cards[leader].rate_multiplier), "无工作能力领导保持空闲动画")
	# The following assertions isolate ordinary work, so remove both modifiers;
	# leaving coffee here would automatically upgrade the arriving employee.
	state.move_cards([overtime, coffee], -1)
	var employee: int = state.add_card("employee", 0, group)
	state.advance(4.0)
	_check(state.tasks.has(employee) and not state.tasks.has(leader), "同组员工独立获得工作任务")
	_check(is_equal_approx(float(state.cards[employee].rate_multiplier), 1.0), "同组领导不改变员工基础工作速度")
	state.advance(6.0)
	_check(state.work_count(0) == 29 and state.money(0) == 1, "员工按基础十秒完成一份")
	var transfer: int = state.add_card("transfer", 0, group)
	_check(state.activate(transfer, group) and state.tasks[leader].kind == "transfer", "领导仍可甩锅")
	state.advance(10.0)
	_check(state.work_count(0) == 26 and state.work_count(1) == 33, "领导和员工十秒统一转移三份工作")

func _test_free_slack() -> void:
	var state := _state({"employee": 1, "grinder": 1, "leader": 1, "work": 30})
	var group := _group(state)
	var slack: int = state.add_card("slack", 0, group)
	var people: Array = state.group_people(group)
	_check(state.money(0) == 0 and state.activate(slack, group), "零资金仍可开始摸鱼")
	for person in people:
		_check(state.tasks.has(person) and state.tasks[person].kind == "slack", "员工卷王领导都参与免费摸鱼")
	state.advance(state.config.number("slack", "seconds"))
	var coffees: Array = _ids(state, "coffee")
	_check(coffees.size() == 3 and state.money(0) == 0, "三人各产一杯咖啡且不扣钱")
	_check(state.work_count(0) == 30, "摸鱼占用三人而不处理工作")
	for coffee in coffees:
		_check(state.cards[coffee].status == "ready" and is_zero_approx(state.cards[coffee].remaining) and is_zero_approx(state.cards[coffee].total), "免费咖啡产出立即可用，无额外准备时间")
	_check(state.cards.has(slack) and state.cards[slack].status == "active" and state.group_slack_participants(group).size() == 3, "摸鱼牌保留且三人立即继续下一批")
	var employee: int = state.add_card("employee", 0)
	state.move_cards([coffees[0]], int(state.cards[employee].group), employee)
	_check(state.tasks[employee].kind == "coffee" and is_zero_approx(state.tasks[employee].progress), "新产咖啡立即开始员工升级进度")
	state.advance(state.config.number("coffee", "seconds"))
	_check(state.cards[employee].type == "grinder" and not state.cards.has(coffees[0]), "新产咖啡仍必须读满升级进度才消耗")

func _test_dismissal_validation() -> void:
	var state := State.new()
	state.new_game(71)
	state.drain_events()
	var person: int = _ids(state, "employee")[0]
	var enemy: int = _ids(state, "employee", 1)[0]
	var tool: int = _ids(state, "coffee")[0]
	var work: int = _ids(state, "work")[0]
	for payload in [[], [person, person], [person, enemy], [person, tool], [person, work], [person, -1], [str(person)], [float(person)]]:
		var before := _snapshot(state)
		_check(not state.dismiss_people(payload, 0), "非法拖入人员列表拒绝：%s" % str(payload))
		_check(before == _snapshot(state) and state.drain_events().is_empty(), "非法整批请求原子保留人员现金任务事件")
	_check(not state.dismiss_people([person], 4), "配置外 owner 不得出售")
	state.config.rules.fire.minimum_people = 1
	_check(not state.dismiss_people([person], 0) and state.cards.has(person), "最低人员限制从配置读取")
	state.config.rules.fire.minimum_people = 0
	_check(state.dismiss_people([person], 0) and state.people_count(0) == 0, "真实 JSON owner 配置支持出售最后一名员工")
	_check(not state.dismiss_people([person], 0), "同一人员不能重复退款")

func _test_dismissal_refunds() -> void:
	var state := _state({"employee": 1, "leader": 1, "grinder": 1, "work": 30, "overtime": 1})
	state.config.cards.employee.refund = 1
	state.config.cards.leader.refund = 2
	state.config.cards.grinder.refund = 3
	var group := _group(state)
	var people: Array = state.group_people(group)
	var kinds: Dictionary = {}
	var total := 0
	for person in people:
		kinds[person] = str(state.cards[person].type)
		total += int(state.config.cards[kinds[person]].refund)
	state.drain_events()
	_check(state.dismiss_people(people, 0), "一次拖入三种人员全部出售")
	_check(state.people_count(0) == 0 and state.money(0) == total, "退款逐角色读取配置且允许归零人员")
	_check(state.work_count(0) == 30 and _ids(state, "overtime").size() == 1, "出售仅移除人员保留工作工具")
	var events: Array = state.drain_events().filter(func(event): return event.kind == "fire")
	_check(events.size() == people.size(), "每个真实人员仅产生一个开除事件")
	var seen: Dictionary = {}
	var bank := -1
	for event in events:
		_check(people.has(event.source) and event.targets == [event.source] and event.group == group, "动画源为被售人员真实 UID 与原组")
		_check(state.cards.has(event.money_id) and event.money_ids.all(func(id): return not seen.has(id)), "每名人员退款包含独立且不重复现金 UID")
		for id in event.money_ids: seen[id] = true
		_check(event.amount == state.config.cards[kinds[event.source]].refund and event.money_ids.size() == event.amount and event.money_ids.all(func(id): return state.cards[id].amount == 1), "事件金额与单位现金张数和角色退款一致")
		if bank < 0: bank = int(event.money_group)
		_check(event.money_group == bank and bank != group, "逐人退款进入同一个独立现金堆")
	_check(state.group_cards(bank).all(func(id): return state.cards[id].type == "money"), "开除退款现金堆不混入工作工具")

func _test_dismissal_tasks() -> void:
	var state := _state({"employee": 3, "leader": 1, "work": 30})
	var group := _group(state)
	var meeting: int = state.add_card("meeting", 0, group)
	_check(state.activate(meeting, group), "领导主持会议用于开除清理验证")
	var host: int = state.meetings[meeting].host
	var targets: Array = state.meetings[meeting].targets.duplicate()
	_check(not state.dismiss_people([targets[0]], 1), "被强行拉走的人员不能出售逃脱")
	_check(state.meetings[meeting].targets.has(targets[0]) and state.cards[targets[0]].paused, "拒绝出售不解除会议控制")
	_check(state.dismiss_people([host], 0), "主持人可以出售")
	_check(not state.meetings.has(meeting) and state.cards[meeting].status == "recovering", "出售主持人结束会议且保留恢复工具")
	for person in targets.slice(1):
		_check(not state.cards[person].paused, "主持离职解除对方每个人控制")
	state.advance(1.0)
	for person in targets.slice(1):
		if state.config.can_work(str(state.cards[person].type)):
			_check(float(state.cards[person].progress) > 0.0, "散会后对方员工继续原任务")
	var slack: int = state.add_card("slack", 0, group)
	_check(state.activate(slack, group), "剩余员工能够开始摸鱼")
	_check(state.dismiss_people(state.group_people(group), 0), "活动批次中的全部人员可出售")
	_check(state.cards[slack].status == "active" and state.cards[slack].paused and state.groups[group].job == "slack" and state.group_slack_participants(group).is_empty(), "无人组合保留进度并暂停等待人员返场")
	state.advance(state.config.number("slack", "seconds"))
	_check(_ids(state, "coffee").is_empty(), "被出售人员不会延迟产咖啡")

func _test_dismiss_transfer() -> void:
	var state := _state({"leader": 1, "work": 30})
	var group := _group(state)
	var person: int = state.group_people(group)[0]
	var work: Array = state.group_work(group)
	var transfer: int = state.add_card("transfer", 0, group)
	_check(state.activate(transfer, group), "纯领导可开始交接工作")
	state.advance(2.0)
	_check(state.dismiss_people([person], 0), "交接中的领导可出售")
	_check(state.cards[transfer].status == "ready" and not state.tasks.has(person), "失去唯一交接人后工具待命且解除任务")
	_check(state.group_work(group) == work and state.work_count(1) == 30, "未完成交接的工作全部留在原组")
	state.advance(20.0)
	_check(state.group_work(group) == work and state.work_count(1) == 30, "已开除领导不再延迟移交工作")
	var finished := _state({"employee": 1, "work": 1})
	finished.advance(10.0)
	var before := _snapshot(finished)
	_check(not finished.dismiss_people(finished.group_people(_group(finished)), 0), "已结束对局拒绝开除")
	_check(before == _snapshot(finished), "结束对局人员现金状态锁定")

func _test_bot_support() -> void:
	var state := _state({"employee": 1, "work": 30})
	var leader: int = state.add_card("leader", 0)
	var bot := Bot.new(state, 0)
	state.config.rules.bot.buy_chance = 0.0
	var original: int = state.cards[leader].group
	bot.start()
	for _i in range(3):
		bot.advance(0.0)
		state.advance(state.config.number("bot", "think_seconds"))
	_check(state.cards[leader].group == original and not state.tasks.has(leader), "BOT 不反复把空闲领导塞到工作组")
	var slack: int = state.add_card("slack", 0)
	bot.advance(0.0)
	_check(state.cards[slack].status == "active" and state.tasks[leader].kind == "slack", "BOT 使用空闲领导免费摸鱼")
	_check(state.tasks[_ids(state, "employee")[0]].kind == "work", "BOT 留员工继续工作")
	var transferring := _state({"employee": 1, "work": 30})
	var support: int = transferring.add_card("leader", 0)
	var tool: int = transferring.add_card("transfer", 0)
	var transfer_bot := Bot.new(transferring, 0)
	transferring.config.rules.bot.buy_chance = 0.0
	transfer_bot.start()
	transfer_bot.advance(0.0)
	transferring.advance(transferring.config.number("bot", "think_seconds"))
	transfer_bot.advance(0.0)
	_check(transferring.cards[tool].status == "active" and transferring.tasks[support].kind == "transfer", "BOT 把领导安排到有效甩锅组")
