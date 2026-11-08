# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Search = preload("res://engine/off_work_bot_search.gd")

func _initialize() -> void:
	_run.call_deferred()

func _world(cash := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":200,"employee":1}]
	config.rules.initial.money = cash
	var world := OffWorkState.new(config)
	world.new_game(317)
	world.offers.clear()
	world.dismiss_people(world._owner_type(0,"employee"),0)
	world._spend(0,config.cards.employee.refund)
	world._sync_schedule()
	return world

func _value(world: OffWorkState) -> Dictionary:
	return Evaluation.new().evaluate(world,0,world.config.rules.bot)

func _run() -> void:
	var evaluator := Evaluation.new()
	var producing := evaluator._race([{"eta":300.5},{"eta":191.0}],0)
	var liquidated := evaluator._race([{"eta":342.5},{"eta":212.0}],0)
	check(producing>liquidated,"落后时不能因双方完工速度都趋近零，就奖励让自身慢42秒而对方只慢21秒的裁员")
	check(is_equal_approx(producing,-evaluator._race([{"eta":300.5},{"eta":191.0}],1)),
		"双方交换观察座位时，同一完工差距的优势严格反向")
	var dead := _world()
	var result := _value(dead)
	check(result.complete and result.detail.sides[0].unreachable and not result.detail.sides[1].unreachable,
		"没有人员、资金或已付招聘的真实死局与仍能生产的一方区别处理")
	check(result.score<-300000.0 and is_finite(result.score),"不可恢复局面严格劣于有限可达局面且不生成无穷除无穷")
	var preserved: float = Evaluation.new().evaluate(dead,1,dead.config.rules.bot).score
	dead.add_card("overtime",1,dead.cards[dead._owner_type(1,"employee")[0]].group)
	check(Evaluation.new().evaluate(dead,1,dead.config.rules.bot).score>preserved,
		"对手已不可恢复时仍优先更快真实完工，不能把所有有资金方案都算成同样的胜势")
	var reachable := _world(4)
	check(not _value(reachable).detail.sides[0].unreachable,"仍有取得未来合法人员的资金不能宣布死局")
	reachable.config.cards.employee.price=10
	reachable.offers=[reachable._make_offer("employee")]
	reachable.offers[0].price=3
	check(not _value(reachable).detail.sides[0].unreachable,"现有公开人员的实际报价也能证明可恢复")
	var slow := _world()
	slow.add_card("employee",0,slow.cards[slow._owner_type(0,"work")[0]].group)
	slow.config.cards.work.work_seconds=1000
	slow.config.rules.bot.evaluation_max_seconds=30
	slow._sync_schedule()
	check(not _value(slow).detail.sides[0].unreachable,"超出估计窗口的慢生产不是资源死局")
	var staffed := _world()
	staffed.add_card("boss",0)
	check(not _value(staffed).detail.sides[0].unreachable,"可招聘或开除筹资的现成人员保守保留可恢复性")
	for full in [true,false]:
		var outsourced := _world()
		var group: int = outsourced.cards[outsourced._owner_type(0,"work")[0]].group
		outsourced.add_card("outsource",0,group)
		outsourced._credit(0,200 if full else 100)
		outsourced.move_cards(outsourced._owner_type(0,"money"),group)
		check(not outsourced.outsourcing.is_empty(),"外包判据使用真实已付款批次")
		check(_value(outsourced).detail.sides[0].unreachable != full,"完整已付外包可完工，部分外包且无人员资金仍不可恢复")
	var dying := _world(5)
	dying.config.rules.bot.think_seconds=1.0
	dying.config.rules.bot.decision_budget_ratio=0.9
	dying.config.rules.bot.search_max_depth=2
	dying.config.rules.conveyor.pool={"employee":1}
	dying.offers=[{},{},{},{},{},dying._make_offer("overtime")]
	dying.advance(1.0) # The second ply crosses the next unknown market arrival.
	var policy: Dictionary = dying.config.rules.bot
	var choice: Dictionary = Search.new().search(dying,0,policy,Time.get_ticks_usec()+3000000)
	check(choice.root_complete and choice.search_depth==2,"无生产但仍有购人资金的局面完成双方推演")
	check(choice.action.kind!="buy","不会为阻止对手加班烧掉自己最后的购人资金")
	var worker := dying.add_card("employee",0,dying.cards[dying._owner_type(0,"work")[0]].group)
	dying._spend(0,2)
	dying._sync_schedule()
	choice=Search.new().search(dying,0,policy,Time.get_ticks_usec()+3000000)
	check(not (choice.action.kind=="dismiss" and worker in choice.action.ids),
		"不能靠尚未公开的未来员工为开除最后一名员工提供确定性保证")
	dying.config.rules.conveyor.pool=OffWorkConfig.new().rules.conveyor.pool.duplicate()
	var before := var_to_bytes([dying.cards,dying.groups,dying.offers,dying._rng.state,dying.time])
	var a := dying.fork_for_bot(11)
	var b := dying.fork_for_bot(92319)
	var boundary := dying._next_offer
	var sampled := []
	for branch in [a,b]:
		branch.advance(4.0)
		sampled.append(branch.offers.duplicate(true))
		branch.mask_search_market(boundary)
		check(branch.offers.all(func(offer):return offer.is_empty() or int(offer.id)<boundary),
			"不同假想随机流的未来报价均遮蔽，牌槽和时钟正常保留")
	check(sampled[0]!=sampled[1],"对照确实产生不同的未知未来市场")
	check(a.offers==b.offers and a.time==b.time and a._conveyor_elapsed==b._conveyor_elapsed,
		"未知市场样本不会改变可用报价和到期时机")
	check(_value(a).score==_value(b).score,"无随机工具时，不同隐藏市场样本不会改变公开局面估值")
	check(before==var_to_bytes([dying.cards,dying.groups,dying.offers,dying._rng.state,dying.time]),"遮蔽仅修改搜索副本")
	finish()
