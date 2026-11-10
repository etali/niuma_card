# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Actions = preload("res://engine/off_work_bot_actions.gd")

# Observe the same engine event calls even though production BOT branches
# intentionally suppress replay event allocation. No transition is overridden.
class TracedState extends OffWorkState:
	var trace: Array = []
	func _emit(kind: String, data: Dictionary) -> void:
		trace.append({"kind":kind,"time":time,"data":data.duplicate(true)})
		super._emit(kind,data)

func _initialize() -> void:
	_clean_fork_and_wait()
	_mutation_boundaries()
	_action_sequences()
	finish()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":2,"work":800,"overtime":1}]
	config.rules.initial.money=50
	var world := OffWorkState.new(config)
	world.new_game(965)
	world._bot_branch=true
	world.advance(0.25)
	return world

func _traced(source: OffWorkState, search: bool) -> TracedState:
	var world := TracedState.new(source.config)
	for key in OffWorkState.WORLD_FIELDS:
		var value: Variant=source.get(key)
		world.set(key,value.duplicate(true) if value is Array or value is Dictionary else value)
	world._bot_branch=search
	world._rng.seed=source._rng.seed
	world._rng.state=source._rng.state
	world._membership_card_count=source._membership_card_count
	world._membership_group_count=source._membership_group_count
	world._schedule_dirty=source._schedule_dirty
	world._scheduled_config=source._scheduled_config
	world._active_groups=source._active_groups.duplicate(true)
	return world

func _equal(actual: OffWorkState, expected: OffWorkState, label: String) -> void:
	var differences := []
	for key in OffWorkState.WORLD_FIELDS:
		if actual.get(key)!=expected.get(key): differences.append(key)
	check(differences.is_empty(), label+" 全部权威状态一致："+str(differences))
	check(actual._rng.state==expected._rng.state, label+" 随机状态一致")
	if actual is TracedState and expected is TracedState:
		check(actual.trace==expected.trace, label+" 事件种类、顺序、时刻与全部载荷一致")

func _work(world: OffWorkState, owner := 0) -> int:
	return int(world.cards[world._owner_type(owner,"work")[0]].group)

func _employee(world: OffWorkState, owner := 0) -> int:
	return int(world._owner_type(owner,"employee")[0])

func _clean_fork_and_wait() -> void:
	var source := _world()
	var branch := source.fork_search_node()
	check(not branch._schedule_dirty and branch._scheduled_config==source._scheduled_config, "干净子分支继承已完成的真实调度")
	check(branch._membership_index.is_empty() and branch._owner_index.is_empty(), "分支不共享可变成员索引")
	check(not is_same(branch._active_groups,source._active_groups) and not is_same(branch._active_groups.work,source._active_groups.work), "活动组缓存独立复制")
	var person := _employee(branch)
	var task: Dictionary=branch.tasks[person]
	branch.activity_card_ids()
	check(not branch._schedule_dirty, "首次懒建成员索引不错误标脏已复制的调度")
	check(Actions.apply_search_action(branch,0,{"kind":"wait"}), "搜索等待动作合法")
	check(not branch._schedule_dirty, "搜索wait不制造无意义的整桌重调度")
	branch.advance_for_search(0.1,-1)
	check(is_same(task,branch.tasks[person]), "无事件时间推进保留原工作任务对象")
	var reference := source.fork_search_node()
	reference._invalidate_group_index()
	reference.advance_for_search(0.1,-1)
	_equal(branch,reference,"继承调度与强制重建")
	check(is_equal_approx(source.time,0.25), "搜索推进不修改源世界")

func _mutation_boundaries() -> void:
	var source := _world()
	source.add_card("employee",0)
	var dirty := source.fork_search_node()
	check(dirty._schedule_dirty, "源真实增牌后的dirty状态原样传给子分支")
	var reference := source.fork_search_node()
	reference._invalidate_group_index()
	dirty.advance_for_search(3.0,-1)
	reference.advance_for_search(3.0,-1)
	_equal(dirty,reference,"源dirty边界")
	source=_world()
	source.config.roles.employee.work_capacity=3
	var changed := source.fork_search_node()
	reference=source.fork_search_node()
	reference._invalidate_group_index()
	changed.advance_for_search(10.0,-1)
	reference.advance_for_search(10.0,-1)
	_equal(changed,reference,"源配置变化边界")
	check(changed.work_count(0)==794, "配置变化仍按新容量实际结算六份工作")
	source=_world()
	var id := _employee(source)
	var group: int=source.cards[id].group
	# Public snapshot editors may replace records before reconciling. A shape
	# mismatch must not be disguised as a valid inherited schedule.
	source.groups[group].cards.erase(id)
	source.cards.erase(id)
	var edited := source.fork_search_node()
	check(edited._schedule_dirty, "尚未协调的直接形状变化不能继承干净标记")
	reference=source.fork_search_node()
	reference._invalidate_group_index()
	edited.advance_for_search(3.0,-1)
	reference.advance_for_search(3.0,-1)
	_equal(edited,reference,"直接形状编辑边界")

func _run_case(world: OffWorkState, action: Dictionary, label: String, deltas: Array) -> void:
	# The search branch comes from the production fork method, including its
	# copied dirty/config boundary. Tracing only observes emitted events.
	var search := _traced(world.fork_search_node(),true)
	var live := _traced(world,false)
	var applied := Actions.apply_action(live,0,action)
	check(applied and Actions.apply_search_action(search,0,action), label+" 两种入口执行同一合法动作")
	_equal(search,live,label+" 动作后")
	for delta in deltas:
		live.trace.clear()
		search.trace.clear()
		live.advance(float(delta))
		check(search.advance_for_search(float(delta),-1), label+" 搜索完整推进")
		_equal(search,live,label+" 连续推进 %.2f" % float(delta))

func _action_sequences() -> void:
	var world := _world()
	_run_case(world,{"kind":"wait"},"等待/传送带",[3.0,3.0,6.0])
	world=_world()
	var offer := {"id":world._next_offer,"type":"employee","price":int(world.config.cards.employee.price)}
	world._next_offer+=1
	world.offers[0]=offer
	_run_case(world,{"kind":"buy","offer":int(offer.id),"card_type":"employee"},"购买员工",[3.0,3.0,6.0])
	world=_world()
	var extra := world.add_card("employee",0)
	_run_case(world,{"kind":"move","ids":[extra],"group":_work(world),"person":-1},"移动部署",[3.0,3.0,6.0])
	world=_world()
	var coffee := world.add_card("coffee",0)
	_run_case(world,{"kind":"move","ids":[_employee(world),coffee],"group":-1,"person":_employee(world)},"咖啡升级",[3.0,3.0,6.0])
	world=_world()
	var overtime := world.add_card("overtime",0)
	_run_case(world,{"kind":"move","ids":[overtime],"group":_work(world),"person":-1},"加班部署",[3.0,3.0,6.0])
	world=_world()
	var strike := world.add_card("strike",0)
	_run_case(world,{"kind":"activate","tool":strike,"group":_work(world,1),"person":-1},"罢工飞行/命中/恢复",[1.2,3.0,17.0,1.0])
	world=_world()
	var boss := world.add_card("boss",0)
	_run_case(world,{"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1,"person":-1},"老板招聘",[3.0,3.0,6.0])
	world=_world()
	var outsource := world.add_card("outsource",0)
	_run_case(world,{"kind":"move","ids":[outsource]+world._owner_type(0,"money")+world.group_work(_work(world)).slice(0,20),"group":-1,"person":-1},"外包/恢复",[3.0,3.0,6.0,20.0])
	world=_world()
	var slack := world.add_card("slack",0)
	_run_case(world,{"kind":"move","ids":[slack,_employee(world)],"group":-1,"person":-1},"摸鱼产咖啡",[3.0,3.0,6.0,6.0])
	world=_world()
	var meeting := world.add_card("meeting",0)
	_run_case(world,{"kind":"move","ids":[meeting,_employee(world)],"group":-1,"person":-1},"开会/结束/重启",[3.0,3.0,6.0,24.0,12.0])
