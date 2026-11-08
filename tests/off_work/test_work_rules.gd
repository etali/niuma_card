extends SceneTree

const Config = preload("res://engine/off_work_config.gd")
const State = preload("res://engine/off_work_state.gd")
const Bot = preload("res://engine/off_work_bot.gd")
var failed := 0
var checked := 0

func _initialize() -> void:
	_test_linear_and_time()
	_test_dynamic_groups()
	_test_coffee()
	_test_meeting()
	_test_transfer()
	_test_transfer_destination()
	_test_other_tools()
	_test_conveyor_and_win()
	_test_selected_payment()
	_test_bot_receives_work()
	print("work_rules: %d 通过 / %d 失败" % [checked - failed, failed])
	quit(1 if failed else 0)

func _state(people: int = 2, work: int = 20) -> RefCounted:
	var config := Config.new()
	# This fixture isolates settlement; flight-window timing has its own regression.
	config.rules.strike.flight_seconds = 0.0
	config.rules.initial.groups = [{"employee": people, "work": work}]
	config.rules.initial.money = 100
	var state := State.new(config)
	state.new_game(42)
	state.drain_events()
	return state

func _group(state: RefCounted, owner: int) -> int:
	for id in state.groups:
		if int(state.groups[id].owner) == owner and not state.group_people(int(id)).is_empty():
			return int(id)
	return -1

func _tool(state: RefCounted, kind: String, group: int, owner: int = 0) -> int:
	return state.add_card(kind, owner, group)

func _tool_group(state: RefCounted, kind: String, group: int, owner: int = 0) -> int:
	# Put the tool down first, then form its combination. Adding a tool to an
	# already working group intentionally does not replace that group's function.
	var tool: int = _tool(state, kind, -1, owner)
	var destination: int = state.cards[tool].group
	state.move_cards(state.group_cards(group), destination)
	return tool

func _check(ok: bool, name: String) -> void:
	checked += 1
	if not ok:
		failed += 1
		push_error(name)

func _test_linear_and_time() -> void:
	var state: RefCounted = _state()
	state.advance(9.0)
	_check(state.work_count(0) == 20, "十秒前不能提前完成")
	state.advance(1.0)
	_check(state.work_count(0) == 18 and state.money(0) == 102, "两人十秒完成两份并仅产两钱")
	var coarse: RefCounted = _state()
	var fine: RefCounted = _state()
	coarse.advance(47.0)
	for _i in range(470):
		fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0), "帧长不影响完成数")
	_check(coarse.offers == fine.offers, "帧长不影响供牌")
	for id in coarse.cards:
		if coarse.cards[id].type == "work":
			_check(is_equal_approx(float(coarse.cards[id].progress), float(fine.cards[id].progress)), "帧长不影响部分进度")

func _test_dynamic_groups() -> void:
	var state: RefCounted = _state(1)
	var group: int = _group(state, 0)
	state.advance(4.0)
	var work: int = int(state.group_work(group)[0])
	var inner: int = state.add_card("overtime", 0)
	state.move_cards([inner], group)
	_check(is_equal_approx(float(state.cards[work].progress), 0.4), "工具换组不重算原进度")
	_check(is_equal_approx(float(state.cards[state.group_people(group)[0]].rate_multiplier), 1.2), "动画倍率来自真实加班速度")
	state.advance(5.0)
	_check(not state.cards.has(work), "后续五秒按加班新速度完成")
	_check(state.work_count(0) == 19 and state.cards.has(inner), "加班不制造工作也不消耗")
	var second: int = state.add_card("employee", 0, group)
	var held_work: int = int(state.group_work(group)[0])
	state.advance(2.0)
	var old_progress: float = float(state.cards[held_work].progress)
	state.move_cards([second, held_work], -1)
	_check(is_equal_approx(float(state.cards[held_work].progress), old_progress), "带工作拆组不丢进度")
	_check(state.group_people(group).size() == 1, "人员只归属一个组")

func _test_coffee() -> void:
	var state: RefCounted = _state()
	var group: int = _group(state, 0)
	var person: int = state.group_people(group)[0]
	state.advance(2.0)
	var work: int = state.tasks[person].work_id
	var break_group: int = state.move_cards([person])
	var coffee: int = _tool(state, "coffee", break_group)
	_check(state.activate(coffee, break_group, person), "咖啡开始给指定员工读条升级")
	_check(state.cards[person].type == "employee" and state.cards.has(coffee), "读条开始不能提前升级或消耗咖啡")
	state.advance(state.config.number("coffee", "seconds"))
	_check(state.cards[person].type == "grinder" and state.work_count(0) == 20, "升级保留人员 UID 且不完成当前工作")
	_check(is_equal_approx(float(state.cards[work].progress), 0.7) and is_equal_approx(state.cards[person].progress, 0.0), "升级时原组同事继续推进，独立升级者保持空闲")
	_check(not state.cards.has(coffee), "升级恰好消耗这杯咖啡")
	_check(not state.activate(coffee, group, person), "已消耗咖啡不能重复升级")
	var second: int = _tool(state, "coffee", break_group)
	_check(not state.activate(second, break_group, person) and state.cards.has(second), "卷王升肝帝需要两杯，单杯不启动也不消耗")

func _test_meeting() -> void:
	var state: RefCounted = _state(3)
	var group: int = _group(state, 0)
	var enemy: int = _group(state, 1)
	state.move_cards(state.group_work(enemy))
	var meeting: int = _tool_group(state, "meeting", group)
	group = state.cards[meeting].group
	_check(state.meetings.has(meeting) and state.cards[meeting].status == "active", "组合完成后开会能发动")
	_check(state.meetings[meeting].targets.size() == 2, "普通主持只拖配置名额")
	state.advance(3.0)
	var paused := 0
	var moving := 0
	for person in state.group_people(enemy):
		if bool(state.cards[person].paused):
			paused += 1
		else:
			moving += 1
	_check(paused == 2 and moving == 1, "只暂停实际会议目标")
	_check(is_zero_approx(float(state.cards[state.meetings[meeting].targets[0]].rate_multiplier)), "被会议暂停的人物倍率为零")
	var working := 0
	for person in state.group_people(group):
		if state.cards[person].activity == "work" and float(state.cards[person].progress) > 0.0:
			working += 1
	_check(working == 0, "开会组合仅触发开会，其他同组人员不会同时工作")
	var coffee: int = _tool(state, "coffee", enemy, 1)
	var attendee: int = int(state.meetings[meeting].targets[0])
	_check(state.activate(coffee, enemy, attendee), "咖啡可以升级被暂停的指定员工")
	_check(state.meetings[meeting].targets.size() == 2 and state.cards[attendee].paused, "升级不解会、不新增或替换目标")
	var host: int = int(state.meetings[meeting].host)
	state.move_cards([host], -1)
	_check(not state.meetings.has(meeting) and state.cards[meeting].status == "recovering", "主持人离组立即散会")
	var leaders: RefCounted = _state(5)
	var lg: int = _group(leaders, 0)
	leaders.add_card("leader", 0, lg)
	var lm: int = _tool_group(leaders, "meeting", lg)
	lg = leaders.cards[lm].group
	leaders.activate(lm, lg)
	_check(leaders.meetings[lm].targets.size() == 4, "领导增加会议名额")

func _test_transfer() -> void:
	var state: RefCounted = _state(1)
	var group: int = _group(state, 0)
	state.add_card("leader", 0, group)
	var transfer: int = _tool_group(state, "transfer", group)
	group = state.cards[transfer].group
	_check(state.cards[transfer].status == "active" and state.tasks[state.group_people(group)[0]].kind == "transfer", "甩锅组启动")
	state.advance(2.0)
	var task_before: Dictionary = state.tasks.duplicate(true)
	var same_group: int = state.move_cards(state.group_cards(group), -1)
	_check(same_group == group and state.tasks == task_before, "整组移动不取消交接")
	state.advance(8.0)
	_check(state.work_count(0) == 17 and state.work_count(1) == 22, "员工和领导十秒统一交接三份，对方同期完成一份")
	_check(state.money(0) == 100 and state.cards.has(transfer), "甩锅不产钱，工具保留")
	_check(state.cards[transfer].status == "active" and is_zero_approx(state.group_transfer_progress(group)), "结算后立即开始下一批，不进入恢复")
	var paused: RefCounted = _state(1)
	var own: int = _group(paused, 0)
	var other: int = _group(paused, 1)
	var ptransfer: int = _tool_group(paused, "transfer", own)
	own = paused.cards[ptransfer].group
	paused.activate(ptransfer, own)
	var meeting: int = _tool_group(paused, "meeting", other, 1)
	other = paused.cards[meeting].group
	paused.activate(meeting, other)
	paused.advance(12.0)
	_check(paused.cards[ptransfer].status == "active", "交接被暂停时工具不会独立计时提前恢复")

func _test_other_tools() -> void:
	var state: RefCounted = _state()
	var group: int = _group(state, 0)
	var enemy: int = _group(state, 1)
	var strike: int = _tool(state, "strike", group)
	state.advance(4.0)
	_check(state.activate(strike, enemy) and not state.cards.has(strike), "罢工成功一次性消耗")
	_check(state.group_people(enemy).is_empty() and is_equal_approx(state.group_work_progress(enemy), 0.4), "罢工弹出人员但保留原工作进度")
	state.advance(6.0)
	_check(state.money(0) == 102, "普通工作只按实际人员能力产钱")
	var outsourcing: int = _tool(state, "outsource", -1)
	var outsource_group: int = state.cards[outsourcing].group
	state.move_cards(state.group_work(group), outsource_group)
	_check(not state.activate(outsourcing, outsource_group), "外包不使用组外钱包，必须把现金叠入组合")
	var income: Dictionary = state.drain_events().filter(func(event): return event.kind == "work_complete" and event.owner == 0).back()
	state.move_cards(income.money_ids, outsource_group)
	_check(state.cards[outsourcing].status == "active" and state.work_count(0) == 18 and state.money(0) == 102, "外包读条开始不提前消耗工作或费用")
	state.advance(state.config.number("outsource", "seconds"))
	_check(state.work_count(0) == 16 and state.money(0) == 100, "外包读满按本组金额一比一清理且不产完成收入")
	state.dismiss_people([state.group_people(group).back()], 0)
	_check(state.people_count(0) == 1 and state.money(0) == 102, "开除自己员工退款")
	_check(state.cards.has(outsourcing), "开除保留所有工具")
	var slack_state: RefCounted = _state()
	var sg: int = _group(slack_state, 0)
	var slack: int = _tool_group(slack_state, "slack", sg)
	sg = slack_state.cards[slack].group
	var coffee: int = _tool(slack_state, "coffee", sg)
	slack_state.activate(slack, sg)
	_check(not slack_state.activate(coffee, sg), "正在摸鱼的人员不能同时喝咖啡升级")
	slack_state.advance(slack_state.config.number("slack", "seconds"))
	var fresh := 0
	for card in slack_state.cards.values():
		if card.type == "coffee" and int(card.owner) == 0 and int(card.group) != sg and card.status == "ready" and is_zero_approx(card.remaining):
			fresh += 1
	_check(fresh == 2, "摸鱼生成独立咖啡并立即可用")
	_check(slack_state.work_count(0) == 20 and slack_state.money(0) == 100, "摸鱼只占人不扣钱、不处理工作")
	_check(slack_state.cards.has(slack) and slack_state.cards.has(coffee), "摸鱼工具与无法使用的升级材料均保留")

func _test_transfer_destination() -> void:
	var state: RefCounted = _state(2)
	var group: int = _group(state, 0)
	var enemy: int = _group(state, 1)
	var tied: int = state.create_group(1)
	for _i in range(20):
		state.add_card("work", 1, tied)
	state.add_card("leader", 0, group)
	state.advance(2.0)
	var existing: Dictionary = {}
	for person in state.group_people(enemy):
		existing[person] = state.tasks[person].duplicate(true)
	var transfer: int = _tool_group(state, "transfer", group)
	group = state.cards[transfer].group
	state.config.rules.transfer.seconds = 5.0
	state.activate(transfer, group)
	state.advance(5.0)
	var destination: int = int(state.cards[transfer].destination)
	_check(destination == enemy, "默认甩锅落在工作最多的现有组，同量取较小gid")
	for person in existing:
		_check(state.tasks[person].work_id == existing[person].work_id and is_equal_approx(float(state.cards[existing[person].work_id].progress), 0.7), "追加文件不取消现有任务或重置进度")
	var transferred := 0
	for event in state.drain_events():
		if event.kind == "transfer":
			transferred += event.ids.size()
			_check(int(event.target_group) == destination, "同批交接锁定落点，不因其他队列变大而改组")
			for id in event.ids:
				_check(state.cards[id].owner == 1 and int(state.cards[id].group) == destination, "甩锅归属及实际组与事件一致")
	_check(transferred == 4, "两名员工和一名领导在同批交接四份")
	var alternate: RefCounted = _state(1)
	alternate.config.rules.transfer.destination_policy = "new_group"
	var ag: int = _group(alternate, 0)
	var original_enemy: int = _group(alternate, 1)
	var tool: int = _tool_group(alternate, "transfer", ag)
	ag = alternate.cards[tool].group
	var drink: int = _tool(alternate, "coffee", ag)
	alternate.activate(tool, ag)
	alternate.activate(drink, ag)
	alternate.advance(alternate.config.number("transfer", "seconds"))
	_check(int(alternate.cards[tool].destination) != original_enemy, "配置可切换为新组落点用于对照")

func _test_conveyor_and_win() -> void:
	var state: RefCounted = _state()
	var first: int = int(state.offers[0].id)
	var id: int = state.buy(first, 0)
	_check(id >= 0 and state.offers[0].is_empty(), "购买留下空槽")
	_check(state.buy(first, 1) < 0, "同一报价不能买两次")
	state.advance(5.0)
	_check(int(state.config.rules.conveyor.slots) == 6 and state.offers.size() == 6 and not state.offers.back().is_empty(), "六槽传送带定时进一出一")
	var finished: RefCounted = _state(1, 1)
	finished.advance(30.0)
	_check(finished.winner == 2 and is_equal_approx(float(finished.time), 10.0), "同刻归零平局且不再处理更晚事件")
	var fast: RefCounted = _state(1, 1)
	fast.add_card("overtime", 0, _group(fast, 0))
	fast.advance(30.0)
	_check(fast.winner == 0 and is_equal_approx(float(fast.time), 10.0 / 1.2), "先归零立即胜利")
	fast.new_game(42)
	_check(fast.winner == -1 and is_zero_approx(float(fast.time)) and fast.meetings.is_empty(), "重开清空旧状态")

func _test_bot_receives_work() -> void:
	var state: RefCounted = _state(1, 20)
	var group: int = _group(state, 0)
	var person: int = int(state.group_people(group)[0])
	var work: Array = state.group_work(group)
	var destination: int = state.move_cards(work, -1)
	var bot := Bot.new(state, 0)
	bot.start()
	state.advance(state.config.number("bot", "first_action_seconds"))
	# A contested offer can be worth taking before staffing the new pile.
	# The original worker must still join it within this opening sequence.
	for _decision in 4:
		bot.advance(0.0)
		if int(state.cards[person].group) == destination and state.tasks.has(person): break
		state.advance(bot.next_action_time() - state.time)
	_check(int(state.cards[person].group) == destination and state.tasks.has(person), "仅剩无人员的来件组时BOT重新安排员工")

func _test_selected_payment() -> void:
	var state: RefCounted = _state()
	var cash: int = state.add_card("money", 0)
	state.cards[cash].amount = 2
	var offer: Dictionary = state.offers[0].duplicate()
	var total: int = state.money(0)
	_check(state.buy(int(offer.id), 0, [cash]) < 0, "指定现金不足时不暗取其他现金")
	_check(state.money(0) == total and state.cards[cash].amount == 2 and state.offers[0] == offer, "拒绝付款原子保留钱和商品")
	state.cards[cash].amount = int(offer.price) + 2
	var before: int = state.money(0)
	_check(state.buy(int(offer.id), 0, [cash]) >= 0, "一张高金额现金也能指定付款")
	_check(state.cards[cash].amount == 2 and state.money(0) == before - int(offer.price), "只扣指定现金并保留余款身份")
	var other: int = state.add_card("money", 1)
	state.cards[other].amount = 50
	var next: int = state.offers[1].id
	_check(state.buy(next, 0, [other]) < 0, "不能用对手现金付款")
	_check(state.buy(next, 0, [cash, cash]) < 0, "重复现金UID不重复计价")
