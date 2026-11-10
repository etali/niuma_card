# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Replay = preload("res://engine/off_work_replay.gd")

var game: Node

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST","1")
	root.size=Vector2i(1440,900)
	game=load("res://scenes/off_work_main.tscn").instantiate()
	game.set_process(false)
	root.add_child(game)
	await process_frame
	game.set_process(false)
	game.audio.muted=true
	game.sfx.user_muted=true
	game.state.config.rules.initial.groups=[{"work":800},{"employee":1},{"overtime":1}]
	if not need(await game._new_game(),"真实OffWorkMain重建800工作录像夹具"):
		finish();return
	game.board.set_process(false)
	game.state.drain_events()
	check(not game.bot.is_started(),"夹具不运行搜索线程，之后只提交实际规则命令")
	var worker: int=int(game.state._owner_type(1,"employee")[0])
	var overtime: int=int(game.state._owner_type(1,"overtime")[0])
	var target: int=int(game.state.cards[game.state._owner_type(1,"work")[0]].group)
	var ids := [worker,overtime]
	game._process(1.0)
	var command := {"kind":"move","ids":ids,"group":target,"person":-1,
		"intent":"assemble_work","reason":"真实移牌录像集成夹具"}
	if not need(game.bot.commit_action(command,{"kind":"move","reason":"真实移牌录像集成夹具"}),
		"实际BOT提交员工和加班同组命令，不注入决策日志"):
		finish();return
	game._process(0.0)
	var action_frame: Dictionary=Replay.decode_frame(game.replay.frames.back(),game.state)
	check(is_equal_approx(float(action_frame.world.time),1.0) \
		and action_frame.events.any(func(event):return event.kind=="group_changed" \
			and int(event.owner)==1 and event.ids.has(worker) and event.ids.has(overtime)),
		"主场景正常record保存真实动作后的世界及group_changed事件")
	check(ids.all(func(uid):return game.board._action_motion.motions.has(uid)),
		"同一真实事件在现场主场景已经启动两张实际牌的动作动画")
	# A later real frame lets seek target the interval after the action. It
	# also makes playback completion distinct from the action's own keyframe.
	game._process(2.0)
	var path: String=game.replay.save(game)
	if not need(not path.is_empty() and FileAccess.file_exists(path),"通过真实录像保存入口写入隔离测试目录"):
		finish();return
	var live: OffWorkState=game.state
	var live_bot: OffWorkBot=game.bot
	var live_world := _fingerprint(live)
	var live_report := var_to_bytes(live_bot.last_decision)
	var live_serial: int=live_bot.decision_serial
	var engine_speed := Engine.time_scale
	var loaded: Dictionary=game._load_replay(path)
	if not need(loaded.get("ok",false),"真实replay.begin读取刚保存的录像"):
		DirAccess.remove_absolute(path)
		finish();return
	check(game.replay.playing and game.state!=live and game.board._action_motion.motions.is_empty(),
		"读取录像暂存原局并从静态开局恢复，不重播暂存局的在途动画")
	game._process(1.0)
	check(is_equal_approx(game.replay.clock,1.0) and ids.all(func(uid):return game.board._action_motion.motions.has(uid)),
		"正常播放跨过记录动作帧时通过Main→Replay→Board启动可见移牌")
	check(ids.all(func(uid):return int(game.state.cards[uid].group)==target \
		and game.board.by_uid[uid]._visual.is_visible_in_tree()),"播放中的真实成员已到目标组，显示仍能看见同一UID正在移动")
	game.board._process(0.2)
	var at_pause := _motions()
	var clock_at_pause: float=game.replay.clock
	game.hud.set_manual_paused(true)
	game.set_process(true)
	game.board.set_process(true)
	await create_timer(0.08,true,false,true).timeout
	check(paused and is_equal_approx(game.replay.clock,clock_at_pause) and _motions()==at_pause,
		"真实树暂停同时冻结录像时钟和动作姿态/elapsed，已启用process也不会后台推进")
	game.set_process(false)
	game.board.set_process(false)
	game.hud.set_manual_paused(false)

	game.replay.seek(game,0.0)
	game.replay.set_speed(4.0)
	game._process(0.25)
	check(game.board._action_motion.playback_speed==4.0 and is_equal_approx(game.replay.clock,1.0) \
		and ids.all(func(uid):return game.board._action_motion.motions.has(uid)),
		"Main在4倍播放时同步设置动作速度，0.25秒跨过1秒真实动作帧")
	var playback_world := _fingerprint(game.state)
	game.board._process(0.1)
	check(ids.all(func(uid):return game.board._action_motion.motions.has(uid) \
		and is_equal_approx(float(game.board._action_motion.motions[uid].elapsed),0.4)),
		"Board真实process用录像倍率推进动作，而非测试直接改模块时钟")
	game.board._process(0.13)
	check(game.board._action_motion.motions.is_empty() and _fingerprint(game.state)==playback_world \
		and Engine.time_scale==engine_speed,"4倍动作按时落地，视觉过程不修改规则世界或全局速度")

	game.replay.seek(game,1.4)
	check(is_equal_approx(game.state.time,1.4) and game.board._action_motion.motions.is_empty() \
		and ids.all(func(uid):return int(game.state.cards[uid].group)==target \
			and not game.board.by_uid[uid].has_meta("off_work_action_motion")),
		"seek到动作后的帧间时刻静态恢复已完成成员，不从缺失旧牌位伪造起飞")
	var sought := _fingerprint(game.state)
	game.replay.seek(game,1.4)
	check(game.board._action_motion.motions.is_empty() and _fingerprint(game.state)==sought,
		"重复同一seek得到相同规则状态，不累积历史动作")

	game.replay.seek(game,0.0)
	game.replay.set_speed(1.0)
	game._process(1.0)
	check(not game.board._action_motion.motions.is_empty(),"退出测试确实发生在录像动作尚未落地时")
	game.stop_replay()
	check(not game.replay.playing and game.state==live and game.bot==live_bot \
		and _fingerprint(live)==live_world and live_bot.decision_serial==live_serial \
		and var_to_bytes(live_bot.last_decision)==live_report,
		"退出录像恢复同一原局和BOT，不重新决策或改写原世界/报告")
	check(game.board._action_motion.motions.is_empty() and game.board._action_motion.playback_speed==1.0 \
		and game.board.by_uid.values().all(func(card):return not card.has_meta("off_work_action_motion")),
		"退出清理在途录像动作，原局静态恢复且不残留速度与标记")
	check(game.replay.speed==1.0 and Engine.time_scale==engine_speed,"录像退出保留全局时间尺度并恢复默认播放倍速")
	DirAccess.remove_absolute(path)
	game.queue_free()
	await process_frame
	finish()

func _fingerprint(world: OffWorkState) -> PackedByteArray:
	var values := []
	for key in OffWorkState.WORLD_FIELDS:values.append(world.get(key))
	values.append(world._rng.state)
	return var_to_bytes(values)

func _motions() -> Dictionary:
	var result := {}
	for uid in game.board._action_motion.motions:
		var motion: Dictionary=game.board._action_motion.motions[uid]
		result[uid]=[motion.elapsed,motion.phase,game.board.by_uid[uid].global_position]
	return result
