# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Live = preload("res://engine/off_work_bot_live.gd")
const Main = preload("res://scenes/off_work_main.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")

func _initialize() -> void: _run.call_deferred()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"work":200}]
	config.rules.initial.money=0
	config.rules.conveyor.interval_seconds=1000.0
	config.rules.bot.first_action_seconds=1.0
	config.rules.bot.think_seconds=3.0
	var world := OffWorkState.new(config)
	world.new_game(515)
	world.offers.clear()
	return world

func _source(bot: OffWorkBot, label: String) -> Live.Search:
	var job := Live.Search.new()
	job.world=bot.state.fork_for_bot(516)
	job.worker=OffWorkBot.new(job.world,bot.owner,bot._policy.duplicate(true))
	job.bot_id=bot.get_instance_id()
	job.due=bot.next_action_time()
	job.policy_hash=hash(bot._policy)
	job.deadline=Time.get_ticks_usec()+5000000
	job.visible_offer_end=bot.state._next_offer
	job.visible_card_end=bot.state._next_card
	job.visible_group_end=bot.state._next_group
	job.publish({"kind":"wait"},{"source_tag":label})
	return job

func _run() -> void:
	# Exercise the real Main preference callback without rendering a table.
	var host := Main.new()
	host.state=_world()
	host.bot=OffWorkBot.new(host.state,1)
	host.bot.start()
	Preferences.bind(host.state,host.state.config.bot_preferences)
	Preferences.bus().changed.connect(host._on_bot_preferences_changed)
	var driver: RefCounted=host._live_bot
	var bot: OffWorkBot=host.bot
	var initial_policy: Dictionary=bot._policy.duplicate(true)
	initial_policy.erase("enabled")
	var due := bot.next_action_time()
	var ready := _source(bot,"queued_before_disable")
	driver._ready=ready
	driver._retained_source=ready
	driver._retained_packet=ready.latest()
	driver.needs_keyframe=true
	bot.import_decision_context({"execution_plan":{"steps":[{"action":{"kind":"wait"}}]},"growth_return":{"group":1}})
	var before := var_to_bytes([host.state.cards,host.state.groups,host.state.tasks,host.state.time,host.state._rng.state])
	Preferences.set_override("enabled",false)
	check(not bot._policy.enabled and not is_finite(bot.next_action_time()),"取消启用立即关闭BOT行动入口")
	check(driver._ready==null and driver._retained_source==null and driver._retained_packet.is_empty() and not driver.needs_keyframe,
		"无需下一帧就清除完成结果、备用结果和待拍快照请求")
	check(bot.export_decision_context().is_empty(),"禁用清除尚未执行的旧决策队列")
	check(before==var_to_bytes([host.state.cards,host.state.groups,host.state.tasks,host.state.time,host.state._rng.state]),
		"开关不回滚或修改已落地生产、卡牌及真实随机流")
	var work: int = host.state.work_count(1)
	host.state.advance(host.state.config.work_seconds()+1.0)
	driver.tick(bot,0.0)
	check(host.state.work_count(1)<work and bot.decision_serial==0,"关闭BOT时员工继续工作，BOT不会选择或提交动作")
	check(not bot.commit_action({"kind":"wait"},{"source_tag":"direct_disabled"}),"禁用时直接提交旧命令同样被拒绝")
	Preferences.set_override("enabled",true)
	var current_policy: Dictionary=bot._policy.duplicate(true)
	current_policy.erase("enabled")
	check(bot.next_action_time()==due and current_policy==initial_policy,"重新开启保留原行动机会和全部强度参数")
	driver.tick(bot,0.0)
	check(bot.decision_serial==1 and bot.last_decision.get("source_tag","")!="queued_before_disable",
		"重新开启从当前局面恢复，不执行禁用前已排队的结果")

	# Hold a real worker-pool task so cancellation cannot be confused with it
	# simply finishing before the toggle. No gameplay thread waits on this gate.
	bot._next_think=host.state.time+1.0
	var in_flight := _source(bot,"worker_before_disable")
	var gate := Semaphore.new()
	driver._search=in_flight
	driver._task=WorkerThreadPool.add_task(gate.wait)
	Preferences.set_override("enabled",false)
	check(in_flight.control.is_cancelled() and driver._task>=0,"菜单中禁用立即请求后台取消，不等待在途线程退出")
	Preferences.set_override("enabled",true)
	host.state.advance(1.0)
	driver.tick(bot,0.0)
	check(bot.decision_serial==2 and bot.last_decision.get("source_tag","")!="worker_before_disable",
		"快速关闭再开启也不能复用仍在线程中的旧发布结果")
	gate.post()
	var until := Time.get_ticks_usec()+2000000
	while driver._task>=0 and not WorkerThreadPool.is_task_completed(driver._task) and Time.get_ticks_usec()<until:
		await process_frame
	driver._collect()
	check(driver._task<0 and driver._ready==null,"被取消线程完成后正常回收，不重新加入待提交队列")

	var parked := _source(bot,"parked")
	driver._ready=parked
	bot.import_decision_context({"parked":true})
	var other := _world()
	Preferences.bind(other,other.config.bot_preferences)
	Preferences.set_override("enabled",false)
	check(bot._policy.enabled and driver._ready==parked and bot.export_decision_context()=={"parked":true},
		"其他练习或录像牌桌的开关不会取消停放对局的状态")
	Preferences.bus().changed.disconnect(host._on_bot_preferences_changed)
	driver.close(self)
	host.free()
	finish()
