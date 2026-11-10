extends SceneTree

var checks := 0
var failures: Array[String]=[]

func _initialize() -> void: _run.call_deferred()

func _check(ok: bool, message: String) -> void:
	checks+=1
	if not ok:failures.append(message)

func _run() -> void:
	OS.set_environment("WORK_UI_TEST","1")
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":64,"work":2000}]
	config.rules.initial.money=500
	config.rules.bot.enabled=false
	var state := OffWorkState.new(config)
	state.new_game(20261110)
	OffWorkCardDB.configure(config)
	var board := OffWorkBoard.new(false)
	root.add_child(board);board.set_process(false)
	var camera := Camera3D.new();board.add_child(camera)
	camera.position=Vector3(0,25,12);camera.look_at(Vector3.ZERO);board.setup(camera,true)
	board.sync_state(state)
	state.drain_events()
	state.advance(config.work_seconds())
	var events: Array=state.drain_events().filter(func(event):return event.kind=="work_complete")
	board.sync_state(state)
	for event in events:board.play_event(event)
	var ids := []
	for event in events:ids.append_array(event.money_ids)
	_check(events.size()==2 and ids.size()==128 and board._cash_flights.size()==128,
		"两方各64名员工的真实结算保留全部128张现金及独立飞行")
	var omitted := []
	var collision := {}
	var deadlines := {}
	var motion: Dictionary=board._settings.income_motion
	for owner in [0,1]:
		var own: Array=ids.filter(func(uid):return int(state.cards[uid].owner)==owner)
		var rendered := 0
		var faces := 0
		for uid in own:
			var flight: Dictionary=board._cash_flights[uid]
			var card: OffWorkCard=board.by_uid[uid]
			rendered+=int(bool(flight.get("rendered",true)))+flight.samples.size()
			faces+=int(card._plate!=null)
			if not bool(flight.get("rendered",true)):omitted.append(uid)
			collision[uid]=[flight.collision_layer,flight.collision_mask,flight.input_ray_pickable]
			deadlines[uid]=float(flight.last_delay)+float(motion.travel_seconds)+float(motion.land_seconds)
		_check(rendered<=int(motion.max_visible_notes_per_owner) and faces<=int(motion.max_visible_notes_per_owner),
			"每方起飞只为既有24个视觉名额构建现金面，不限制真实金钱")
	_check(omitted.size()>=80 and omitted.all(func(uid):return board.by_uid[uid].face_deferred and board.by_uid[uid]._plate==null),
		"未呈现的80个以上真实UID保留延迟牌面，无私有完整现金面")
	_check(ids.all(func(uid):return not board.by_uid[uid].draggable and not board.by_uid[uid].input_ray_pickable \
		and board.by_uid[uid].collision_layer==0 and board.by_uid[uid].collision_mask==0),
		"可见与未呈现现金起飞时都持有相同交互锁")
	# At the real launch instant opacity is zero. Repeated zero-time passes
	# must not show a face and immediately hide it again just to recompute density.
	board._advance_cash_flights(0.0)
	var stable: Array=ids.filter(func(uid):
		var flight: Dictionary=board._cash_flights[uid]
		return bool(flight.get("rendered",true)) and is_zero_approx(float(flight.delay)) \
			and not board.by_uid[uid]._visual.visible)
	var changes := {"count":0}
	_check(not stable.is_empty(),"真实发射时刻有零透明度的渲染现金可检查稳定可见性")
	if not stable.is_empty():
		var visual: Node3D=board.by_uid[stable[0]]._visual
		visual.visibility_changed.connect(func():changes.count+=1)
		for iteration in 5:board._advance_cash_flights(0.0)
		_check(changes.count==0 and not visual.visible,"稳定density零的现金不反复触发show/hide可见性事件")
	var initial_fingerprint := [hash(state.cards),hash(state.groups),hash(state.tasks),state.time,state.revision]
	var elapsed := 0.0
	var timing_valid := true
	var first_timing_mismatch := {}
	var hidden_valid := true
	var locks_valid := true
	var step := 1.0/60.0
	var duration: float=float(deadlines.values().max())+step*2.0
	for frame in ceili(duration/step):
		elapsed+=step
		board._advance_cash_flights(step)
		if frame%6==0:board.sync_state(state)
		board._sync_stack_occlusion()
		for uid in ids:
			var active: bool=board._cash_flights.has(uid)
			# Sums of 1/60 and decimal duration settings can differ by an ULP
			# exactly at the boundary; allow that boundary, never another frame.
			var on_schedule: bool=elapsed<=float(deadlines[uid])+0.000001 if active else elapsed>=float(deadlines[uid])-0.000001
			if not on_schedule and first_timing_mismatch.is_empty():
				first_timing_mismatch={"uid":uid,"elapsed":elapsed,"deadline":deadlines[uid],"active":active,"flight_elapsed":board._cash_flights.get(uid,{}).get("elapsed",-1.0)}
			timing_valid=timing_valid and on_schedule
			if not active:continue
			var card: OffWorkCard=board.by_uid[uid]
			locks_valid=locks_valid and not card.draggable and not card.input_ray_pickable and card.collision_layer==0 and card.collision_mask==0
			if omitted.has(uid):hidden_valid=hidden_valid and not card._visual.visible and card.face_deferred
	if not timing_valid:print("INCOME_FLIGHT_TIMING ",JSON.stringify(first_timing_mismatch))
	_check(timing_valid,"所有未呈现UID仍按各自真实delay/travel/land时钟落地，不提前入账或拖尾")
	_check(hidden_valid,"周期sync与遮挡刷新不会提前揭示未呈现的在途现金")
	_check(locks_valid,"整个飞行期间所有现金都不能被拾取或碰撞")
	_check(initial_fingerprint==[hash(state.cards),hash(state.groups),hash(state.tasks),state.time,state.revision],
		"飞行动画不修改真实余额、UID、组、任务或游戏时钟")
	_check(state.money(0)==564 and state.money(1)==564 and state.work_count(0)==1936 and state.work_count(1)==1936,
		"双方实际工资与工作结算保持564金钱和1936工作")
	_check(board._cash_flights.is_empty() and ids.all(func(uid):return state.cards.has(uid) and board.by_uid.has(uid)) \
		and board.by_uid.size()==state.cards.size(),"全部128张产出都落地且保留原逻辑及牌桌身份")
	_check(ids.all(func(uid):
		var card: OffWorkCard=board.by_uid[uid]
		return not card.has_meta("in_flight") and not card.has_meta("income_flight") \
			and card.draggable==(int(state.cards[uid].owner)==0) and card.collision_layer==int(collision[uid][0]) \
			and card.collision_mask==int(collision[uid][1]) and card.input_ray_pickable==bool(collision[uid][2]) \
			and card._material_collision.disabled==(not card._visual.visible)),
		"落地恢复原归属、交互层与遮挡对应的碰撞形状")
	var mine: Array=omitted.filter(func(uid):return int(state.cards[uid].owner)==0)
	if not mine.is_empty():
		var uid: int=int(mine[0])
		var original: OffWorkCard=board.by_uid[uid]
		_check(state.move_cards([uid],-1),"曾省略视觉的真实现金仍可从钱包单独拆出")
		board.sync_state(state)
		_check(board.by_uid[uid]==original and original._visual.visible and not original.face_deferred \
			and original._plate!=null and not original._material_collision.disabled and original.draggable,
			"拆出的同一UID正常构建牌面并恢复可见、可拖的实体")
		_check(state.money(0)==564,"拆出隐藏产物不增减实际金钱")
	board.queue_free();await process_frame
	for failure in failures:printerr("FAIL ",failure)
	print("INCOME_RENDER_BUDGET %s (%d checks)"%["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)
