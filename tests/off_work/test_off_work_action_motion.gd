# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST","1")
	root.size=Vector2i(1440,900)
	await _opening()
	await _local_owner()
	await _batch(false)
	await _batch(true)
	await _redirect_consume_reset()
	await _meeting_handoff()
	await _purchase()
	await _dispose()
	finish()

func _fixture(initial: Array, money := 8, employee_market := false) -> void:
	await _dispose()
	var config := OffWorkConfig.new()
	config.rules.initial.groups=initial
	config.rules.initial.money=money
	config.rules.bot.enabled=false
	if employee_market:config.rules.conveyor.pool={"employee":1}
	state=OffWorkState.new(config)
	state.new_game(20261111)
	OffWorkCardDB.configure(config)
	host=Node3D.new()
	root.add_child(host)
	board=OffWorkBoard.new(false)
	host.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position=Vector3(0,25,12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera,true)
	board.sync_state(state)
	_finish_layout()
	state.drain_events()
	check(state.cards.size()==board.by_uid.size() and board._action_motion!=null,
		"真实牌桌建立全部UID和独立动作动画模块")

func _dispose() -> void:
	if is_instance_valid(host):
		host.queue_free()
		await process_frame
	host=null
	board=null

func _owned(kind: String, owner := 1) -> Array:
	return state._owner_type(owner,kind)

func _work_group(owner := 1) -> int:
	return int(state.cards[_owned("work",owner)[0]].group)

func _fingerprint() -> PackedByteArray:
	var world := []
	for key in OffWorkState.WORLD_FIELDS:world.append(state.get(key))
	world.append(state._rng.state)
	return var_to_bytes(world)

func _finish_layout() -> void:
	for presenter in [board,board.enemy_board]:
		for item in presenter._move_tw.values():
			if item.tw!=null and item.tw.is_valid():
				item.tw.pause()
				item.tw.custom_step(0.2)

func _move(ids: Array, target: int) -> Array:
	check(state.move_cards(ids,target)>=0,"真实规则提交移牌命令")
	var events: Array=state.drain_events()
	check(events.any(func(event):return event.kind=="group_changed"),"规则产生可录像的group_changed事件")
	board.sync_state(state)
	for event in events:board.play_event(event)
	return events

func _advance(delta: float) -> void:
	board._action_motion.advance(delta)
	board._sync_stack_occlusion()

func _positions(ids: Array) -> Dictionary:
	var result := {}
	for uid in ids:result[uid]=board.by_uid[uid].global_position
	return result

func _visible_moved(ids: Array) -> int:
	var result := 0
	for uid in ids:
		if board._action_motion.motions.has(uid) and board.by_uid[uid]._visual.is_visible_in_tree():result+=1
	return result

func _opening() -> void:
	await _fixture([{"work":800},{"employee":1},{"overtime":1},{"coffee":1}])
	var ids: Array=[_owned("employee")[0],_owned("overtime")[0]]
	var before := _positions(ids)
	var identities := {}
	var collision := {}
	for uid in ids:
		var card: OffWorkCard=board.by_uid[uid]
		identities[uid]=card.get_instance_id()
		collision[uid]=[card.collision_layer,card.collision_mask,card.input_ray_pickable]
	var target := _work_group()
	var events := _move(ids,target)
	check(ids.all(func(uid):return board._action_motion.motions.has(uid)),"开局员工和加班都使用实际UID进入同一可见搬牌批次")
	check(ids.all(func(uid):return board.by_uid[uid].global_position.distance_to(before[uid])<0.001 \
		and board.by_uid[uid]._visual.is_visible_in_tree()),"首帧保留两张牌的原始位置，目标工作堆不会提前遮住它们")
	check(ids.all(func(uid):return int(state.cards[uid].group)==target and int(board.by_uid[uid].group_id)==target \
		and board.by_uid[uid].get_instance_id()==identities[uid]),"规则成员已提交，动画保持同一实体身份与归属")
	await _capture("opening-start")
	var logical := _fingerprint()
	_advance(0.06)
	check(ids.all(func(uid):return board.by_uid[uid].global_position.y>(before[uid] as Vector3).y \
		and board.by_uid[uid].has_meta("off_work_action_motion")),"拿起阶段从原牌位抬起真实卡片")
	_advance(0.31)
	var halfway := _positions(ids)
	var elapsed := {}
	for uid in ids:
		if board._action_motion.motions.has(uid):elapsed[uid]=board._action_motion.motions[uid].elapsed
	check(ids.all(func(uid):return board.by_uid[uid]._visual.is_visible_in_tree() \
		and board.by_uid[uid].global_position.distance_to(before[uid])>0.05 \
		and board.by_uid[uid].global_position.distance_to(board._presenter(1).rest_pos(board.by_uid[uid]))>0.05),
		"移动中间帧位于起点与落点之间且仍能看到员工和加班")
	check(ids.all(func(uid):return not board.by_uid[uid].draggable and not board.by_uid[uid].input_ray_pickable \
		and board.by_uid[uid].collision_layer==0 and board.by_uid[uid].collision_mask==0),"搬牌中的实体不抢玩家指针或参与碰撞")
	await _capture("opening-middle")
	for iteration in 3:board.sync_state(state)
	check(ids.all(func(uid):return board.by_uid[uid].global_position.distance_to(halfway[uid])<0.001 \
		and board._action_motion.motions.has(uid) and board._action_motion.motions[uid].elapsed==elapsed.get(uid,-1)),
		"重复周期sync不覆盖中间姿态、不重启或推进动画时钟")
	_advance(0.55)
	_finish_layout()
	check(board._action_motion.motions.is_empty(),"0.9秒完整拾取、移动、放下、停留后释放动作批次")
	check(ids.all(func(uid):
		var card: OffWorkCard=board.by_uid[uid]
		return card.get_instance_id()==identities[uid] and card.global_position.distance_to(board._presenter(1).rest_pos(card))<0.001 \
			and not card.has_meta("off_work_action_motion") and not card.has_meta("in_flight") and not card.has_meta("dest_pos") \
			and [card.collision_layer,card.collision_mask,card.input_ray_pickable]==collision[uid] and not card.draggable),
		"落地恢复原碰撞、敌方不可拖归属及准确最终牌位，不残留飞行标记")
	var visible_before := ids.map(func(uid):return board.by_uid[uid]._visual.visible)
	board.sync_state(state)
	check(visible_before==ids.map(func(uid):return board.by_uid[uid]._visual.visible) \
		and ids.all(func(uid):return board.by_uid[uid]._visual.visible==(not board._stack_occluded.has(uid)) \
			and not board.by_uid[uid]._material_collision.disabled),
		"落地立即恢复普通堆叠遮挡与碰撞形状，后续sync不再修补可见性")
	check(_fingerprint()==logical,"完整动画和周期同步不改真实牌、任务、余额、游戏时间或随机流")
	await _capture("opening-landed")
	board.reset_view()
	board.sync_state(state)
	for event in events:board.play_event(event)
	check(board._action_motion.motions.is_empty(),"seek等价的reset加快照恢复后，旧移牌事件不能伪造不存在的出发位置")
	check(_fingerprint()==logical and board.by_uid.size()==state.cards.size(),"seek视觉重建保留全部真实世界与UID")

func _local_owner() -> void:
	await _fixture([{"work":800},{"employee":1},{"overtime":1}])
	_move([_owned("employee",0)[0],_owned("overtime",0)[0]],_work_group(0))
	check(board._action_motion.motions.is_empty(),"玩家自身移牌不再被BOT动作模块重新播放一次")

func _batch(materials: bool) -> void:
	await _fixture([{"work":800},{"employee":1}] if materials else [{"work":800},{"employee":64}])
	var ids: Array=_owned("work") if materials else _owned("employee")
	var target: int=int(state.cards[_owned("employee")[0]].group) if materials else _work_group()
	var initial_count := state.cards.size()
	var faces_before: int=ids.filter(func(uid):return board.by_uid[uid]._plate!=null).size()
	_move(ids,target)
	var logical := _fingerprint()
	check(not board._action_motion.motions.is_empty() and board._action_motion.motions.size()<=12,
		"%d张真实牌只建立最多12个可见移动代表，不按全批创建动画"%ids.size())
	_advance(0.37)
	board.sync_state(state)
	check(_visible_moved(ids)>0 and _visible_moved(ids)<=12,"大批移动途中仍有可见代表，数量不超过12")
	if materials:
		check(ids.filter(func(uid):return board.by_uid[uid]._plate!=null).size()<=faces_before+12+Board.BOUNDED_COMPACT_LAYERS,
			"移动800工作只揭示动画代表与普通目标摞层，不把全部延迟牌面构建出来")
	_advance(0.55)
	_finish_layout()
	check(board._action_motion.motions.is_empty() and state.cards.size()==initial_count \
		and ids.all(func(uid):return int(state.cards[uid].group)==target and board.by_uid.has(uid)),
		"视觉上限不截断真实整批移动，所有UID最终属于合法目标")
	check(_fingerprint()==logical,"批量动作动画不改变已完成的规则结果")

func _redirect_consume_reset() -> void:
	await _fixture([{"work":800},{"employee":2},{"overtime":1}])
	var worker: int=int(_owned("employee")[0])
	var overtime: int=int(_owned("overtime")[0])
	_move([worker,overtime],_work_group())
	_advance(0.3)
	var redirected_from: Vector3=board.by_uid[worker].global_position
	_move([worker],-1)
	check(board._action_motion.motions.has(worker) \
		and (board._action_motion.motions[worker].from as Vector3).distance_to(redirected_from)<0.001 \
		and board._action_motion.motions[worker].group==state.cards[worker].group,
		"同一UID收到新命令时从当前姿态改向新组，不跳回第一次起点")
	_advance(0.1)
	check(state.dismiss_people([worker],1),"真实解雇可以消费正在显示搬运动画的员工")
	var events: Array=state.drain_events()
	board.sync_state(state)
	for event in events:board.play_event(event)
	check(not board._action_motion.motions.has(worker) and not board.by_uid.has(worker),
		"被真实规则消费的UID立即离开动作队列，不保留悬空运动")
	var after_dismiss := _fingerprint()
	_advance(1.0)
	check(not state.cards.has(worker) and not board.by_uid.has(worker) and _fingerprint()==after_dismiss,
		"旧动画到期不能复活已消费人员或再次支付退款")
	var remaining: int=int(_owned("employee")[0])
	_move([remaining],_work_group())
	check(board._action_motion.motions.has(remaining),"重置测试发生在另一张真实员工正在移动时")
	var old_instance: int=board.by_uid[remaining].get_instance_id()
	board.reset_view()
	board._action_motion.advance(2.0)
	check(board._action_motion.motions.is_empty() and board.by_uid.is_empty(),"reset清空所有动作运动，不让延迟回调重建旧牌")
	state.new_game(20261112)
	board.sync_state(state)
	check(board.by_uid.size()==state.cards.size() and board.by_uid[int(_owned("employee")[0])].get_instance_id()!=old_instance \
		and board.by_uid.values().all(func(card):return not card.has_meta("off_work_action_motion")),
		"新局复用相同UID也只绑定新节点，旧移动标记不会串局")

func _meeting_handoff() -> void:
	await _fixture([{"work":800},{"employee":1},{"overtime":1},{"meeting":1}])
	var worker: int=int(_owned("employee")[0])
	var overtime: int=int(_owned("overtime")[0])
	var target: int=int(state.cards[overtime].group)
	var meeting_host: int=int(_owned("employee",0)[0])
	var tool: int=int(_owned("meeting",0)[0])
	_move([worker],target)
	var card: OffWorkCard=board.by_uid[worker]
	var presenter: Board=board.enemy_board
	var group: Variant=presenter.group_of(card)
	var is_head: bool=group!=null and group.cards[0]==card and board._action_motion.motions.has(worker)
	check(is_head,"会议交接夹具由真实移牌形成员工为队首、加班留在后面的搬运中组合")
	if not is_head:return
	# Isolate handoff from the optional repacking of a smaller source pile.
	# Both native layout and the complete sync/event path still run normally.
	var layout_enabled: bool=bool(board._settings.opponent_layout.enabled)
	board._settings.opponent_layout.enabled=false
	var home: Vector3=presenter.rest_pos(card)
	var origin: Vector3=presenter.rest_origin(group)
	var instance_id := card.get_instance_id()
	_advance(0.3)
	var departure := card.global_position
	check(departure.y>home.y+0.1 and departure.distance_to(home)>0.1,
		"开会发生在队首员工真实悬空移动中，不能把当前姿态误作落点")
	_move([tool],int(state.cards[meeting_host].group))
	check(state.meetings.has(tool) and state.meetings[tool].targets==[worker],
		"真实玩家会议只拉走这名敌方员工，员工的原逻辑组和加班保留")
	check(board._meeting_visitors.has(worker) and not board._action_motion.motions.has(worker),
		"会议接管实际员工UID并释放原搬牌控制器")
	if not board._meeting_visitors.has(worker):
		board._settings.opponent_layout.enabled=layout_enabled
		return
	var visit: Dictionary=board._meeting_visitors[worker]
	check((visit.home as Vector3).distance_to(home)<0.001 \
		and (visit.from as Vector3).distance_to(departure)<0.001 \
		and card.global_position.distance_to(departure)<0.001,
		"会议保留真实返岗落点，从当前可见悬空姿态接续，不在交接帧跳落桌面")
	var remaining_group: Variant=presenter.group_of(board.by_uid[overtime])
	check(remaining_group!=null and presenter.rest_origin(remaining_group).distance_to(origin)<0.001 \
		and (board._origin_by_gid[target] as Vector3).distance_to(origin)<0.001,
		"drop_card读取搬运落点后才取消动作，剩余加班与源组起点不被悬空队首抬高或挪走")
	var during_meeting := _fingerprint()
	board._advance_meeting_visitors(0.3)
	var pulled := card.global_position
	board.sync_state(state)
	check(card.global_position.distance_to(pulled)<0.001 \
		and (board._meeting_visitors[worker].home as Vector3).distance_to(home)<0.001 \
		and _fingerprint()==during_meeting,
		"会议途中周期同步保留位置和返岗锚点，不改变真实任务、时钟或随机流")
	board._advance_meeting_visitors(1.0)
	_move([meeting_host],-1)
	check(state.meetings.is_empty() and board._meeting_visitors[worker].phase=="return",
		"真实移走主持人结束会议，原员工进入返岗阶段")
	var after_meeting := _fingerprint()
	board._advance_meeting_visitors(1.0)
	_finish_layout()
	board.sync_state(state)
	_finish_layout()
	var returned_group: Variant=presenter.group_of(card)
	check(card.get_instance_id()==instance_id and int(state.cards[worker].group)==target \
		and int(state.cards[worker].owner)==1 and card.global_position.distance_to(home)<0.001 \
		and returned_group!=null and presenter.rest_origin(returned_group).distance_to(origin)<0.001,
		"会议结束后同一真实员工返回原落点，源组起点和归属保持稳定")
	check(not board._meeting_visitors.has(worker) and not board._action_motion.motions.has(worker) \
		and not card.has_meta("off_work_action_motion") and not card.has_meta("meeting_visit") \
		and not card.has_meta("in_flight") and not card.has_meta("dest_pos") \
		and _fingerprint()==after_meeting,
		"会议交接及返岗完整释放两套动画标记，不重复规则动作或改变真实世界")
	board._settings.opponent_layout.enabled=layout_enabled

func _purchase() -> void:
	await _fixture([{"work":800},{"employee":1}],20,true)
	var offer: Dictionary=state.offers[0].duplicate(true)
	var origin: Vector3=board.offers_by_id[int(offer.id)].global_position
	var cash_before := state.money(1)
	var bought := state.buy(int(offer.id),1)
	check(bought>=0,"BOT购买通过真实报价和支付规则生成新UID")
	var events: Array=state.drain_events()
	board.sync_state(state)
	for event in events:board.play_event(event)
	check(board._action_motion.motions.has(bought) and board.by_uid[bought].global_position.distance_to(origin)<0.001,
		"购买从刚才真实offer节点的位置出发，sync移除报价后仍保留准确起点")
	var logical := _fingerprint()
	_advance(0.37)
	check(board.by_uid[bought]._visual.is_visible_in_tree() and board.by_uid[bought].global_position.distance_to(origin)>0.05,
		"新购人员的同一真实牌在传送带与己方落点之间可见移动")
	_advance(0.55)
	_finish_layout()
	check(not board._action_motion.motions.has(bought) and int(state.cards[bought].owner)==1 \
		and state.money(1)==cash_before-int(offer.price) and _fingerprint()==logical,
		"购买动画不重复购买、不增减费用，最后保留真实新员工")
	for index in 100:board._action_motion.remember_offer(100000+index,Vector3(index,0,0))
	check(board._action_motion.offer_sources.size()<=maxi(12,state.offers.size()*2),
		"长期传送带补牌不让离场报价位置缓存无限增长")
	_move([bought],_work_group())
	check(board._action_motion.motions.has(bought),"录像倍速检查仍使用真实已购买员工的实际移牌事件")
	logical=_fingerprint()
	board._action_motion.playback_speed=4.0
	_advance(0.23)
	check(board._action_motion.motions.is_empty() and _fingerprint()==logical,
		"4倍录像中0.23秒展示时间完成0.9秒动作，不改真实状态或游戏时钟")
	board.reset_view()
	check(board._action_motion.playback_speed==1.0 and board._action_motion.offer_sources.is_empty(),
		"seek或退出录像的清理恢复默认动画速度并清除旧报价来源")

func _capture(stage: String) -> void:
	var path := OS.get_environment("OFF_WORK_ACTION_CAPTURE")
	if path.is_empty() or DisplayServer.get_name()=="headless":return
	DirAccess.make_dir_recursive_absolute(path)
	await process_frame
	RenderingServer.force_draw(false)
	check(root.get_texture().get_image().save_png(path.path_join(stage+".png"))==OK,
		"保存真实动作动画viewport截图："+stage)
