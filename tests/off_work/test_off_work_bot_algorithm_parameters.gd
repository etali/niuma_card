# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Evaluator = preload("res://engine/off_work_bot_evaluator.gd")
const Config = preload("res://engine/off_work_config.gd")
class InterruptedSchedule extends Evaluator:
	var armed := false
	func _schedule(source: Array, first_action: float) -> Dictionary:
		if armed:
			_complete=false
			return {"events":[],"operations":{},"commands":{}}
		return super._schedule(source,first_action)
var evaluator := Evaluator.new()
func _initialize() -> void: run.call_deferred()
func world(groups: Array, cash := 0) -> OffWorkState:
	var config := Config.new()
	# Exact event fixtures retain their original clock across preset calibration.
	config.rules.bot.think_seconds = 2.8
	config.rules.initial.groups = groups
	config.rules.initial.money = cash
	# These are exact finite-resource service-clock tests. No later random
	# outsource supplier exists; wage reinvestment is covered separately with
	# the real default market and with already-owned tools.
	config.rules.conveyor.pool = {"employee":1}
	var result := OffWorkState.new(config)
	result.new_game(413)
	check(result.last_error.is_empty(), "测试局面按真实规则成功建立：" + result.last_error)
	result.offers.clear()
	return result
func value(game: OffWorkState, side := 1, next_actions: Array = []) -> Dictionary:
	var result := evaluator.evaluate(game, side, game.config.rules.bot, -1, next_actions)
	check(result.complete, "完整局面评价完成")
	return result
func first(game: OffWorkState, kind: String, side := 1) -> int:
	for id in game.cards:
		if game.cards[id].type == kind and int(game.cards[id].owner) == side: return int(id)
	return -1
func run() -> void:
	var idle := world([{"work":20},{"employee":1}])
	var original := var_to_bytes([idle.cards,idle.groups,idle.tasks,idle.offers,idle._rng.state])
	var idle_result := value(idle)
	check(idle_result.detail.sides[1].current_rate == 0.0 and idle_result.detail.sides[1].idle_pending == 1, "闲置人员不计当前产能")
	check(var_to_bytes([idle.cards,idle.groups,idle.tasks,idle.offers,idle._rng.state]) == original, "评价只读，不改变牌桌、任务或随机状态")
	idle.move_cards([first(idle,"employee")], idle.cards[first(idle,"work")].group)
	var active_result := value(idle)
	check(active_result.score > 0.0 and active_result.detail.sides[1].eta < idle_result.detail.sides[1].eta, "实际派工优于同数量闲置人员")
	check(is_equal_approx(active_result.detail.sides[1].current_rate,0.1), "当前吞吐量来自真实工作周期")
	idle.advance(1.0); idle.offers.clear()
	var progress := value(idle)
	check(is_equal_approx(progress.detail.sides[1].eta,active_result.detail.sides[1].eta - 1.0), "批次进度按真实剩余时间兑现")

	var overtime := world([{"work":100,"employee":1,"overtime":4}])
	var four: float = value(overtime).detail.sides[1].eta
	overtime.add_card("overtime",1,overtime.cards[first(overtime,"work")].group)
	overtime._sync_schedule()
	var five := value(overtime)
	check(five.detail.sides[1].eta < four and is_equal_approx(five.detail.sides[1].current_rate,pow(1.2,5)/10.0), "第五张加班按真实倍率参与，不存在四张策略上限")

	var last := world([{"work":1,"employee":1}])
	last.advance(9.0); last.offers.clear()
	var finishing := value(last)
	check(is_equal_approx(finishing.detail.sides[1].eta,1.0), "最后一份工作按实际批次结束时点完成")
	for i in 20: last.add_card("employee",1)
	last._credit(1,100)
	var hoarding := value(last)
	check(is_equal_approx(hoarding.detail.sides[1].eta,1.0) and is_equal_approx(hoarding.score,finishing.score), "临近冲线时囤人囤钱不能优于完成工作")

	var coffee := world([{"work":20},{"employee":1,"coffee":1}])
	coffee.advance(4.999); coffee.offers.clear()
	var before_coffee: Dictionary = value(coffee,1,[5.6-coffee.time,5.6-coffee.time]).detail.sides[1]
	coffee.advance(0.001); coffee.offers.clear()
	var after_coffee: Dictionary = value(coffee,1,[5.6-coffee.time,5.6-coffee.time]).detail.sides[1]
	check(absf(float(before_coffee.eta)-float(after_coffee.eta)-0.001)<0.0001, "咖啡即将完成与刚完成都按升级后人员加派工延迟估价，无分数断崖")
	check(after_coffee.current_rate == 0.0 and after_coffee.idle_pending == 1, "升级完成仍需实际返岗，不凭空立即满产")

	var recruit := world([{"work":20},{"boss":1}],10)
	for side in 2: recruit.move_cards(recruit._owner_type(side,"money"),recruit.cards[first(recruit,"boss",side)].group)
	recruit.advance(9.999); recruit.offers.clear()
	var before_recruit: Dictionary = value(recruit,1,[11.2-recruit.time,11.2-recruit.time]).detail.sides[1]
	recruit.advance(0.001); recruit.offers.clear()
	var after_recruit: Dictionary = value(recruit,1,[11.2-recruit.time,11.2-recruit.time]).detail.sides[1]
	check(before_recruit.free_cash == 0.0 and after_recruit.free_cash == 0.0, "已保留招聘付款不能同时当作购买力")
	check(absf(float(before_recruit.eta)-float(after_recruit.eta)-0.001)<0.0001 and after_recruit.idle_pending == 2, "招聘完成前后同口径，两名新员工仍须派工")

	var outsourced := world([{"work":10,"outsource":1},{"employee":1}],5)
	for side in 2: outsourced.move_cards(outsourced._owner_type(side,"money"),outsourced.cards[first(outsourced,"outsource",side)].group)
	outsourced.advance(9.999); outsourced.offers.clear()
	var before_outsource: Dictionary = value(outsourced).detail.sides[1]
	outsourced.advance(0.001); outsourced.offers.clear()
	var after_outsource: Dictionary = value(outsourced).detail.sides[1]
	check(before_outsource.committed_work == 5 and after_outsource.committed_work == 0 and before_outsource.free_cash == 0.0, "外包在途工作与付款各计一次")
	check(absf(float(before_outsource.eta)-float(after_outsource.eta))<0.001, "部分外包结算不会丢失或重复计算其余工作")

	var paused := world([{"work":20,"employee":1}])
	var before_pause: float = value(paused).detail.sides[1].eta
	var strike := paused.add_card("strike",0)
	paused._apply_strike(strike,paused.cards[first(paused,"work")].group)
	var paused_value: Dictionary = value(paused).detail.sides[1]
	check(paused_value.current_rate == 0.0 and paused_value.eta >= before_pause + paused.config.rules.strike.duration_seconds, "罢工人员必须等恢复并返岗，暂停不算折扣满产")

	var cash := world([{"work":20,"employee":1}])
	var poor: float = value(cash).score
	cash._credit(1,1000)
	check(is_equal_approx(value(cash).score,poor), "没有公开可实现投资时，现金没有独立分数")
	cash.offers = [{},{},{},{},{},cash._make_offer("employee")]
	var rich := value(cash)
	check(not rich.detail.sides[1].public_investment.is_empty(), "可见且可负担的真实商品才产生购买力价值")
	var offer: Dictionary = cash.offers[5].duplicate()
	cash.buy(offer.id,1)
	var bought := value(cash)
	check(bought.detail.sides[1].eta <= rich.detail.sides[1].eta + 0.000001, "真实支付并买到人员后，不因现金消失而降低估值")
	check(bought.detail.sides[1].current_rate == rich.detail.sides[1].current_rate, "买到的人员在派工前仍不算当前产能")

	var no_credit := world([{"work":100,"employee":1}])
	no_credit.offers = [{},{},{},{},{},no_credit._make_offer("employee")]
	var without_income: Dictionary = value(no_credit).detail.sides[1]
	check(without_income.public_investment.is_empty(), "过期前不足购买价的未兑现收入不能提前借来购物")

	var terminal := world([{"work":20,"employee":1}])
	terminal.winner = 1
	check(value(terminal).score > 900000.0, "已获胜绝对优于所有非终局经济局面")
	terminal.winner = 0
	check(value(terminal).score < -900000.0, "已失败不能被人力或现金抵消")
	terminal.winner = 2
	check(value(terminal).score == 0.0, "规则平局保持中性")
	terminal.winner = -1
	var expired := evaluator.evaluate(terminal,1,terminal.config.rules.bot,Time.get_ticks_usec())
	check(not expired.complete and expired.score == 0.0, "截止时返回未完成，不能发布只扫描部分牌的偏分")
	_pending_attack_services()
	_long_and_short_queues()
	_action_clocks_and_commitments()
	_attack_funding_and_host_gates()
	_natural_meeting_restart()
	_failed_purchase_does_not_cancel_recovery()
	_future_funding_is_conserved()
	_schedule_deadline_propagates()
	_public_quotes_have_one_owner()
	_recipe_claims_are_atomic()
	_secondary_strike_queue_survives()
	_queued_coffee_is_continuous()
	_public_attack_continuations()
	_coupled_transfers()
	_public_four_cup_recipe()
	_mixed_recruitment_coffee_events()
	_exact_forecast_cache()
	_public_coffee_recipes()
	_large_tables_are_complete()
	finish()

func _pending_attack_services() -> void:
	var game := world([{"work":20,"employee":1}])
	var baseline: float = value(game).detail.sides[1].eta
	var tool := game.add_card("strike",0)
	var target: int = game.cards[first(game,"work")].group
	check(game._activate_strike(tool,target), "真实发射形成公开在途攻击")
	var flying: Dictionary = value(game).detail.sides[1]
	check(flying.pending_strikes == 1 and flying.eta > baseline + 19.0, "已发射罢工在落点后停止生产并付恢复返岗时间")
	game.advance(1.199); game.offers.clear()
	var before: Dictionary = value(game,1,[2.8-game.time,2.8-game.time]).detail.sides[1]
	game.advance(0.001); game.offers.clear()
	var after: Dictionary = value(game,1,[2.8-game.time,2.8-game.time]).detail.sides[1]
	check(absf(float(before.eta)-float(after.eta)-0.001)<0.0001, "同一绝对行动时钟下，实际罢工落地前后服务曲线连续")
	check(after.current_rate == 0.0 and after.required_actions == 1, "落地后人员仍须实际返岗且整批返岗只需一动作")
	var protected := world([{"work":20,"employee":1}])
	tool = protected.add_card("strike",0)
	target = protected.cards[first(protected,"work")].group
	check(protected._activate_strike(tool,target), "防御回归先合法发射")
	protected.add_card("union",1,target); protected._sync_schedule()
	var blocked: Dictionary = value(protected).detail.sides[1]
	protected.pending_strikes.clear()
	var without: Dictionary = value(protected).detail.sides[1]
	check(blocked.pending_strikes == 0 and is_equal_approx(blocked.eta,without.eta), "到达前出现工会保护，在途打击不制造虚假停工")
	var finishing := world([{"work":1,"employee":1}])
	finishing.advance(9.5); finishing.offers.clear()
	tool = finishing.add_card("strike",0)
	check(finishing._activate_strike(tool,finishing.cards[first(finishing,"work")].group), "临近清空时攻击仍按真实规则可发射")
	var finish_value: Dictionary = value(finishing).detail.sides[1]
	check(is_equal_approx(finish_value.eta,0.5) and finish_value.required_actions == 0, "目标在飞行结束前完成，攻击和无用返岗不增加完工时间或命令数")

	var support := world([{"work":20},{"employee":1,"slack":1}])
	tool = support.add_card("strike",0)
	target = support.cards[first(support,"employee")].group
	check(support._activate_strike(tool,target), "真实摸鱼组也可成为已发射攻击目标")
	support.advance(1.199); support.offers.clear()
	var support_before: Dictionary = value(support,1,[2.8-support.time,2.8-support.time]).detail.sides[1]
	support.advance(0.001); support.offers.clear()
	var support_after: Dictionary = value(support,1,[2.8-support.time,2.8-support.time]).detail.sides[1]
	check(absf(float(support_before.eta)-float(support_after.eta)-0.001)<0.0001, "打击先于计划迁出摸鱼人员，派工必须推迟到实际恢复，落地前后连续")

func _long_and_short_queues() -> void:
	var game := world([{"employee":1,"work":2},{"work":40}])
	var estimated: Dictionary = value(game).detail.sides[1]
	check(is_equal_approx(estimated.eta,420.0) and estimated.required_actions == 1, "长散队列补入已开工短队列，批次进度保留且只计一次真实补料")
	var queue := world([{"employee":1,"work":2},{"employee":1,"work":40}])
	var projected: Dictionary = value(queue).detail.sides[1]
	check(projected.eta < 400.0 and projected.required_actions == 1, "短队列完成后人员可真实转入长队列，转岗有行动时隙")
	var heterogeneous := world([{"employee":1,"grinder":1,"work":4}])
	heterogeneous.config.cards.work.work_seconds = 20.0
	heterogeneous.config.roles.grinder.work_capacity = 2
	heterogeneous._sync_schedule()
	var exact: Dictionary = value(heterogeneous).detail.sides[1]
	check(is_equal_approx(exact.eta,40.0), "不同容量人员共用20秒周期，三份满批与一份尾批需两个真实周期")
	heterogeneous.advance(20.0)
	check(heterogeneous.work_count(1) == 1, "真实第一周期按员工与卷王容量完成三份，保留尾批")
	heterogeneous.advance(20.0)
	check(heterogeneous.work_count(1) == 0, "真实尾批完工时间与统一周期预测一致")
	var near := world([{"employee":1,"work":1},{"employee":10}])
	near.advance(9.0); near.offers.clear()
	check(value(near).detail.sides[1].required_actions == 0, "冲线之后才可执行的闲置派工不计必要命令")

func _action_clocks_and_commitments() -> void:
	var game := world([{"employee":1,"work":20},{"employee":2},{"overtime":2}])
	game.advance(2.0); game.offers.clear()
	var policy: Dictionary = game.config.rules.bot.duplicate(true)
	policy.think_seconds = 2.0
	var waiting := evaluator.evaluate(game,1,policy,-1,[0.0,1.0])
	var ids: Array = []
	var target: int = game.cards[first(game,"work")].group
	for id in game.cards:
		if int(game.cards[id].owner)==1 and int(game.cards[id].group)!=target and str(game.cards[id].type) in ["employee","overtime"]: ids.append(id)
	check(game.move_cards(ids,target), "联合派工在真实规则中单次完成")
	var working := evaluator.evaluate(game,1,policy,-1,[0.0,1.0])
	check(waiting.detail.sides[1].required_actions == 1 and working.detail.sides[1].required_actions == 0, "同槽多人和加班合并算一条必要命令，实际执行后归零")
	check(working.score >= waiting.score and working.tie_score > waiting.tie_score, "兑现生产不劣于无限许诺未来派工；相同清空时间用剩余实际命令作次级比较")
	var purchase := world([{"work":20},{"employee":1}],4)
	purchase.offers=[{},{},{},{},{},purchase._make_offer("employee")]
	var result := evaluator.evaluate(purchase,1,policy,-1,[1.0,0.0])
	var investment: Dictionary = result.detail.sides[1].public_investment
	check(not investment.is_empty() and investment.purchase_at==0.0 and investment.usable_at>=2.0 and result.detail.sides[1].required_actions==2,
		"有现金可先购买，再把新旧闲人一起合组；两次真实操作不能挤到同刻，也不强迫先返岗占掉采购机会")

func _large_tables_are_complete() -> void:
	var game := world([{"work":20},{"leader":1}])
	for i in 205: game.add_card("coffee",1)
	game.add_card("employee",1)
	game._sync_schedule()
	var result := value(game)
	check(result.detail.sides[1].idle_pending == 1 and result.detail.sides[1].eta < 300.0, "遍历超过旧192组限制的实际牌桌，最后一组人员仍参与估值")

func _public_coffee_recipes() -> void:
	var game := world([{"work":80,"grinder":1}],8)
	game.config.roles.grinder.work_capacity=2
	game.config.roles.workaholic.work_capacity=4
	game._sync_schedule()
	var before: Dictionary = value(game).detail.sides[1]
	game.add_card("coffee",1)
	var incomplete: Dictionary = value(game).detail.sides[1]
	check(is_equal_approx(before.eta,incomplete.eta) and incomplete.public_investment.is_empty(), "不完整且无公开补料的配方没有凭空升级收益")
	game.offers=[{},{},{},{},{},game._make_offer("coffee")]
	var possible: Dictionary = value(game).detail.sides[1]
	check(possible.eta < before.eta and possible.public_investment.get("source", "") == "visible_recipe", "唯一公开咖啡补齐真实两杯配方，扣购价并计算停工升级返岗")
	check(possible.required_actions == 3, "补齐配方严格需要购买、另组升级、升级后返岗三次真实动作")
	check(game.buy(game.offers[5].id,1), "回归真实执行补齐咖啡采购")
	var owned: Dictionary = value(game).detail.sides[1]
	check(owned.eta <= possible.eta and owned.required_actions == 2, "咖啡实际到手后完整配方只剩升级与返岗，不因现金减少跳降")
	var person := first(game,"grinder")
	var ingredients := game._owner_type(1,"coffee")
	ingredients.push_front(person)
	check(game.move_cards(ingredients,-1), "真实另组完整配方启动升级")
	var underway: Dictionary = value(game).detail.sides[1]
	check(underway.required_actions == 1 and underway.current_rate == 0.0, "升级在途只剩返岗命令，期间人员没有生产能力")

func _exact_forecast_cache() -> void:
	var game := world([{"work":20},{"employee":2}],4)
	var cached := Evaluator.new()
	var first_value := cached.evaluate(game,1,game.config.rules.bot,-1,[0.0,1.0])
	var first_bytes := var_to_bytes(first_value)
	var second_value := cached.evaluate(game,1,game.config.rules.bot,-1,[0.0,1.0])
	check(cached.cache_hits >= 2 and var_to_bytes(second_value)==first_bytes, "完全相同公开模型复用双方预测，分数和细节保持相同")
	second_value.detail.sides[1].eta = -123.0
	check(var_to_bytes(cached.evaluate(game,1,game.config.rules.bot,-1,[0.0,1.0]))==first_bytes, "返回结果为独立副本，调用者不能污染缓存")
	var phase := cached.evaluate(game,1,game.config.rules.bot,-1,[0.0,2.0])
	check(phase.detail.sides[1].eta > first_value.detail.sides[1].eta, "同牌面不同合法行动相位不能误中缓存")
	game.config.cards.work.work_seconds = 20.0
	game._sync_schedule()
	var changed := cached.evaluate(game,1,game.config.rules.bot,-1,[0.0,1.0])
	check(changed.detail.sides[1].eta > phase.detail.sides[1].eta, "同config对象的规则修改也使缓存失效")
	game.offers=[{},{},{},{},{},game._make_offer("employee")]
	var market := cached.evaluate(game,1,game.config.rules.bot,-1,[0.0,1.0])
	check(not market.detail.sides[0].public_investment.is_empty() and market.detail.sides[0].eta < changed.detail.sides[0].eta and market.detail.sides[1].public_investment.is_empty(), "公开市场变化按先付款者真实可购买力重算，不复用对方买走的报价")
	var misses := cached.cache_misses
	var expired := cached.evaluate(game,1,game.config.rules.bot,Time.get_ticks_usec(),[0.0,1.0])
	check(not expired.complete and cached.cache_misses == misses, "截止后不因命中缓存发布过期评价，也不写入不完整结果")

func _mixed_recruitment_coffee_events() -> void:
	var game := world([{"work":80,"employee":1},{"boss":1},{"coffee":1}],5)
	game.move_cards(game._owner_type(1,"money"),game.cards[first(game,"boss")].group)
	game.config.roles.grinder.work_capacity=2
	var result := value(game)
	check(not game.recruitment.is_empty() and result.complete, "招聘的字符串未来事件与人员整数UID同时存在时，咖啡投资仍可完整评价")

func _coupled_transfers() -> void:
	var game := world([{"work":30,"employee":2,"transfer":1}])
	var cyclic := value(game)
	check(cyclic.detail.sides[0].coupled_transfer and cyclic.detail.sides[0].stalled and cyclic.detail.sides[1].stalled, "双边等速互甩守恒，不能把来回移交预测为双方清空")
	check(cyclic.detail.sides[0].remaining+cyclic.detail.sides[1].remaining==60, "耦合服务中甩锅不消除任何工作")
	var pieces := game._owner_type(1,"employee")+game._owner_type(1,"work")
	check(game.move_cards(pieces,-1), "将真实人员与工作拆出甩锅组开始生产")
	var producing := value(game)
	check(not producing.detail.sides[1].stalled and producing.detail.sides[1].eta < cyclic.detail.sides[1].eta, "退出互甩并实际生产可清空，严格优于无限循环")
	check(producing.detail.sides[0].remaining+producing.detail.sides[1].remaining==0, "只有真实产出消除双边工作总量")

func _public_four_cup_recipe() -> void:
	var game := world([{"work":200,"workaholic":1}],40)
	game.config.roles.workaholic.work_capacity=4
	game.config.roles.work_emperor.work_capacity=8
	game.config.rules.conveyor.interval_seconds=10.0
	game._sync_schedule()
	game.offers=[]
	for i in 4: game.offers.append(game._make_offer("coffee"))
	var forecast: Dictionary = value(game,1,[1.0,0.0]).detail.sides[1]
	check(forecast.public_investment.get("source","")=="visible_recipe" and forecast.public_investment.purchases.size()==4, "零杯起步可按四个真实公开报价完成最终配方，无须看见隐藏未来商品")
	check(forecast.required_actions==6 and forecast.public_investment.price==16.0, "四次独立付款加组队升级返岗，六个真实操作均计入成本")
	check(forecast.public_investment.purchases.all(func(purchase):return purchase.at<purchase.expires), "全部公开咖啡均须赶上各自报价过期时间")
	game.offers.pop_back()
	var incomplete: Dictionary = value(game,1,[1.0,0.0]).detail.sides[1]
	check(incomplete.public_investment.is_empty(), "缺第四个公开报价时不虚构隐藏咖啡补完配方")

func _public_attack_continuations() -> void:
	var game := world([{"work":80,"employee":8}])
	game._credit(1,7)
	game.offers=[{},{},{},{},{},game._make_offer("strike")]
	var policy: Dictionary = game.config.rules.bot.duplicate(true)
	policy.think_seconds=2.0
	var planned := evaluator.evaluate(game,1,policy,-1,[0.0,1.0])
	var attack: Dictionary = planned.detail.sides[1].get("forecast_attack",{})
	check(not attack.is_empty() and attack.kind=="strike" and attack.purchase_at==1.0 and attack.use_at>=3.0, "可见罢工须实际付款并等下一动作施放，不能把敌方未来有钱的较晚采购优先占走")
	check(planned.score>0.0 and planned.detail.sides[0].eta>planned.detail.sides[1].eta, "公开可购买罢工通过实际飞行停工延长敌方清空时间产生价值")
	var initial_cash := game.money(1)
	check(initial_cash==7 and game.pending_strikes.is_empty(), "威胁预测只读，不真实扣款或发动攻击")
	for side in 2:game.add_card("union",side,game.cards[first(game,"work",side)].group)
	game._sync_schedule()
	var protected := evaluator.evaluate(game,1,policy,-1,[0.0,1.0])
	check(not protected.detail.sides[1].has("forecast_attack") and protected.score==0.0, "工会使公开罢工无可实现收益，不因持牌或现金而加分")
	var meeting := world([{"work":80,"employee":8},{"leader":1}])
	meeting.add_card("meeting",1)
	var held := value(meeting)
	check(held.detail.sides[1].get("forecast_attack",{}).get("kind","")=="meeting", "手中现成会议按真实抽样对象与主持占用形成可行威胁")
	check(held.detail.sides[1].required_actions>=1 and held.score>0.0, "会议主持施放有真实动作成本，暂停目标才改善竞速评价")

func _queued_coffee_is_continuous() -> void:
	var game := world([{"work":80},{"employee":1,"coffee":3}])
	game.config.roles.grinder.work_capacity=2
	game.config.roles.workaholic.work_capacity=4
	game.advance(4.999);game.offers.clear()
	var before: Dictionary = value(game,1,[5.6-game.time,5.6-game.time]).detail.sides[1]
	game.advance(0.001);game.offers.clear()
	var after: Dictionary = value(game,1,[5.6-game.time,5.6-game.time]).detail.sides[1]
	check(absf(float(before.eta)-float(after.eta)-0.001)<0.0001, "已有三杯自动连升在阶段切换前后连续，不能只兑现当前一杯或把下一阶段免费变出")
	check(before.current_rate==0.0 and after.current_rate==0.0, "连续升级全过程保持停工，最终仍需要真实返岗动作")

func _secondary_strike_queue_survives() -> void:
	var game := world([{"work":100,"grinder":1,"overtime":1},{"work":10,"employee":2}])
	game.config.roles.grinder.work_capacity=4
	game._sync_schedule()
	var tool := game.add_card("strike",0)
	var target: int = game.cards[first(game,"employee")].group
	check(game._activate_strike(tool,target), "真实打击次要生产组形成在途攻击")
	game.advance(1.199);game.offers.clear()
	var before: Dictionary = value(game,1,[2.8-game.time,2.8-game.time]).detail.sides[1]
	game.advance(0.001);game.offers.clear()
	var after: Dictionary = value(game,1,[2.8-game.time,2.8-game.time]).detail.sides[1]
	check(not before.stalled and not after.stalled, "次要组受击后的遗留工作会实际补入生产，不能永久饿死成虚假威胁")
	check(absf(float(before.eta)-float(after.eta)-0.001)<0.0001 and before.required_actions==after.required_actions, "虚拟落地与真实落地重建模型保持清空时间和必要补料返岗成本一致")

func _attack_funding_and_host_gates() -> void:
	var game := world([{"work":100,"employee":8}])
	game.config.rules.conveyor.interval_seconds=10.0
	game.offers=[{},{},{},{},{},game._make_offer("strike")]
	game.add_card("strike",1)
	var policy: Dictionary = game.config.rules.bot.duplicate(true)
	policy.think_seconds=2.0
	var funded := evaluator.evaluate(game,0,policy,-1,[0.0,1.0])
	check(not funded.detail.sides[0].has("forecast_attack") and funded.detail.sides[1].get("forecast_attack",{}).get("kind","")=="strike", "较早真实打击使未来收入采购失败时，对应虚拟反击必须撤销")
	var host := world([{"work":100,"employee":8}])
	var meeting := host.add_card("meeting",0)
	host.cards[meeting].status="recovering"
	host.cards[meeting].remaining=5.0
	host.cards[meeting].total=24.0
	host.cards[meeting].meeting_repeat=true
	host.add_card("strike",1)
	var unavailable := evaluator.evaluate(host,0,policy,-1,[0.0,1.0])
	check(not unavailable.detail.sides[0].has("forecast_attack"), "计划施放前主持被打停时，不再注入无法实际开始的会议暂停")
	var no_meeting := world([{"work":100,"employee":8}])
	no_meeting.add_card("strike",1)
	var without := evaluator.evaluate(no_meeting,0,policy,-1,[0.0,1.0])
	check(is_equal_approx(unavailable.score,without.score), "无可用主持的冷却会议没有虚构的跨方效果或持牌价值")

func _natural_meeting_restart() -> void:
	var game := world([{"work":196,"employee":8},{"leader":1}])
	var tool := game.add_card("meeting",1)
	check(game.move_cards([tool,first(game,"leader")],-1)>=0, "真实主持组队开始会议")
	game.advance(game.config.number("meeting","duration_seconds"));game.offers.clear()
	check(game.cards[tool].status=="recovering" and game.cards[tool].meeting_repeat, "真实会议结束进入自动重复冷却")
	var forecast: Dictionary = value(game).detail.sides[1]
	check(forecast.get("forecast_attack",{}).get("natural_restart",false) and is_equal_approx(forecast.forecast_attack.use_at,float(game.cards[tool].remaining)), "现有主持在冷却完成时只自然重启一次，不强行挪到下一手动行动时刻")
	check(forecast.required_actions==0, "自然重启不伪造主动施放命令或重复收费")
	game.advance(float(game.cards[tool].remaining)-0.001);game.offers.clear()
	var before: Dictionary = value(game).detail.sides[0]
	game.advance(0.001);game.offers.clear()
	var after: Dictionary = value(game).detail.sides[0]
	check(absf(float(before.eta)-float(after.eta)-0.001)<0.0001, "自然会议真实重启前后，目标侧清空服务曲线连续且不重复暂停")

func _failed_purchase_does_not_cancel_recovery() -> void:
	var game := world([{"work":20,"employee":1}])
	value(game)
	var model: Dictionary = evaluator._model(game,1,evaluator._index(game))
	var worker := first(game,"employee")
	for attack in ["meeting","strike"]:
		var candidate: Dictionary = model.duplicate(true)
		candidate.events.append({"at":0.0,"kind":"meeting_pause","meeting":"test","targets":[worker]} if attack=="meeting" else {"at":0.0,"kind":"strike","group":model.target,"flight":"test"})
		candidate.events.append({"at":2.8,"kind":"spend","amount":4.0,"action":true,"operation":"buy:test"})
		candidate.events.append({"at":5.6,"kind":"worker","group":model.target,"id":"unpaid","action":true,"after":"buy:test","lag":2.8,"unit":evaluator._unit("employee",1,false,false)})
		candidate.events.append({"at":12.0,"kind":"meeting_end","meeting":"test"} if attack=="meeting" else {"at":22.8,"kind":"strike_return","group":model.target,"flight":"test","action":true})
		var context: Dictionary = evaluator._context(candidate)
		for event in context.scheduled.events:
			evaluator._advance_context(context,float(event.at))
			evaluator._apply_forecast_event(context,event)
		check(context.failed.has("buy:test") and not context.failed.has(""), "失败采购只传播到明确依赖，不污染空操作键："+attack)
		check(context.groups[model.target].workers.has(worker) and not context.groups[model.target].workers.has("unpaid"), "买不到的人员不出现，自然恢复仍兑现："+attack)
		var projected: Dictionary = evaluator._forecast(candidate)
		check(not projected.stalled and projected.income==20.0 and projected.cash==20.0, "失败采购后仍正常清空工作，资金守恒："+attack)

func _future_funding_is_conserved() -> void:
	var game := world([{"work":20,"employee":1}],2)
	value(game)
	var model: Dictionary = evaluator._model(game,1,evaluator._index(game))
	var context: Dictionary = evaluator._context(model)
	evaluator._apply_forecast_event(context,{"kind":"fund_outsource","amount":8,"unit_cost":1,"batch":"future","operation":"fund:test"})
	check(context.funded.future==2 and context.pending==2 and context.spent==2.0 and context.groups[model.target].work==18, "外包按当时真实可用现金裁剪，不能预支被打断的工资")
	evaluator._apply_forecast_event(context,{"kind":"settle","amount":8,"batch":"future"})
	check(context.pending==0 and evaluator._remaining(context)==18, "外包结算只清除实际已付款的批次")
	evaluator._apply_forecast_event(context,{"kind":"settle","amount":8,"batch":"never_funded"})
	check(context.pending==0 and evaluator._remaining(context)==18, "未成功融资的批次不能免费结算或制造负在途工作")

func _schedule_deadline_propagates() -> void:
	var game := world([{"work":20,"employee":1}],20)
	game.add_card("meeting",1)
	var interrupted := InterruptedSchedule.new()
	interrupted.evaluate(game,1,game.config.rules.bot)
	var index: Dictionary = interrupted._index(game)
	var own: Dictionary = interrupted._model(game,1,index)
	var other: Dictionary = interrupted._model(game,0,index)
	var plans: Dictionary = Evaluator.AttackPlans.plans(game,1)
	check(not plans.plans.is_empty(), "截止回归使用真实可施放会议候选")
	interrupted.armed=true
	var candidate: Dictionary = interrupted._attack_candidate(game,own,other,plans.plans[0])
	check(candidate.is_empty() and not interrupted._complete, "排程截止返回不完整状态，不能读取不存在的攻击操作")

func _public_quotes_have_one_owner() -> void:
	for kind in ["employee","overtime"]:
		var game := world([{"work":100,"employee":1}],40)
		game.offers=[{},{},{},{},{},game._make_offer(kind)]
		var offer := int(game.offers[5].id)
		var original := var_to_bytes([game.cards,game.groups,game.offers,game._rng.state])
		var later_zero := value(game,1,[1.0,0.0])
		check(later_zero.detail.sides[1].forecast_purchases.has(offer) and later_zero.detail.sides[0].forecast_purchases.is_empty(), "唯一公开报价只归真实较早付款的一方："+kind)
		check(later_zero.detail.sides[0].eta==1000.0 and later_zero.detail.sides[1].eta<1000.0, "抢购失败方没有重复创造员工或加班产能："+kind)
		var earlier_zero := value(game,1,[0.0,1.0])
		check(earlier_zero.detail.sides[0].forecast_purchases.has(offer) and earlier_zero.detail.sides[1].forecast_purchases.is_empty(), "改变行动相位会交换报价归属，不能误中旧 claim 缓存："+kind)
		var simultaneous := value(game,1,[0.0,0.0])
		check(simultaneous.detail.sides[0].forecast_purchases.has(offer) and simultaneous.detail.sides[1].forecast_purchases.is_empty(), "同刻付款按真实座位提交顺序归属："+kind)
		check(var_to_bytes([game.cards,game.groups,game.offers,game._rng.state])==original, "报价竞争只读，不修改真实市场或随机状态："+kind)
	var alternatives := world([{"work":100,"employee":1}],40)
	alternatives.offers=[{},{},{},{},alternatives._make_offer("employee"),alternatives._make_offer("overtime")]
	var result := value(alternatives,1,[0.0,1.0])
	check(result.detail.sides[0].public_investment.kind=="employee" and result.detail.sides[1].public_investment.kind=="overtime", "失去最优人员报价后重选仍可购买的加班，不直接放弃所有投资")
	for side in 2:
		check(result.detail.sides[side].forecast_purchases.size()==1 and result.detail.sides[side].cash>=0.0, "每方仅扣自己实际取得的报价款，资金不为负")
	alternatives.offers.append(alternatives._make_offer("strike"))
	var attacks := value(alternatives,1,[0.0,1.0])
	for offer in attacks.detail.sides[0].forecast_purchases:
		check(not attacks.detail.sides[1].forecast_purchases.has(offer), "经济续行与攻击续行共存时，所有实际采购仍无同报价双重归属")

func _recipe_claims_are_atomic() -> void:
	var game := world([{"work":200,"workaholic":1}],40)
	game.config.roles.workaholic.work_capacity=4
	game.config.roles.work_emperor.work_capacity=8
	game.config.rules.conveyor.interval_seconds=10.0
	game._sync_schedule()
	for i in 4: game.offers.append(game._make_offer("coffee"))
	game.offers.append(game._make_offer("employee"))
	var result := value(game,1,[0.0,1.0])
	check(result.detail.sides[0].public_investment.get("source","")=="visible_recipe" and result.detail.sides[0].forecast_purchases.size()==4, "同四杯竞争中较早方完成真实完整配方")
	check(result.detail.sides[1].public_investment.get("kind","")=="employee" and result.detail.sides[1].forecast_purchases.size()==1, "失败配方整体撤回并改选员工，不保留部分杯款或免费升级")
	check(result.detail.sides[1].income==40.0*(4.0*4.0+1.0), "替代人员方案每批四份工作狂加一份员工工资，没有沿用失败升帝的八倍工资")
	var worker := first(game,"workaholic",1)
	game.cards[worker].type="grinder"
	game.config.roles.grinder.work_capacity=2
	game._sync_schedule()
	var smaller := value(game,1,[1.0,0.0])
	check(smaller.detail.sides[1].public_investment.get("source","")=="visible_recipe" and smaller.detail.sides[1].forecast_purchases.size()==2, "较早两杯配方只占两份报价，不占用对方已撤销的四杯计划")
	check(smaller.detail.sides[0].public_investment.get("kind","")=="employee" and smaller.detail.sides[0].forecast_purchases.size()==1, "四杯配方缺必要报价时不预支残缺配方，改选完整可行投资")
