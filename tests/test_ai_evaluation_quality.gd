# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only

extends "res://tests/harness.gd"

const Eval = preload("res://engine/ai_evaluation.gd")
const Context = preload("res://engine/ai_context.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_optional_cores()
	_test_cash_monotonicity()
	_test_resource_monotonicity()
	_test_user_financing()
	_test_shared_resources()
	_test_cash_order()
	_test_cache()
	finish()

func _state(cash := 10, users := 8) -> GameState:
	var s := GameState.new()
	s.players = {"ai":{"cards":[]},"player":{"cards":[]}}
	_add(s,"cash",cash)
	_add(s,"user",users)
	for id in ["cash","user"]:
		for _n in 20: s.add_card("player",id)
	return s

func _add(s: GameState, id: String, count := 1) -> Array:
	var ids := []
	for _n in count: ids.append(s.add_card("ai",id).uid)
	return ids

func _units(s: GameState, res: String) -> Array:
	var ids := []
	for c in s.players.ai.cards:
		if not c.locked and CardDB.get_def(c.def_id).get("res") == res: ids.append(c.uid)
	return ids

func _profile(strength := 1.0) -> Dictionary:
	return AISearch.from_model("ai",strength).resolved_parameters()

func _compile(s: GameState, groups: Array) -> bool:
	var app := IntentApply.new(s)
	for ids in groups:
		if not app.apply(Intent.create_combo("ai",ids)).get("ok",false): return false
	return true

func _test_optional_cores() -> void:
	for spec in [[8,"baoyue",2,"shuabuting",0,12],[7,"xinxijianfang",1,"xufei",2,72]]:
		var s := _state(10,int(spec[0]))
		var cores := _add(s,spec[1],spec[2])
		var buffs := _add(s,"yinqing996",spec[4])
		var before := Eval.features(s,"ai",_profile())
		_add(s,spec[3])
		var after := Eval.features(s,"ai",_profile())
		check(is_equal_approx(before.engine,float(spec[5])) and is_equal_approx(after.engine,before.engine),
			"免费增加%s可不用，不降低%s原有可达产能%d" % [spec[3],spec[1],spec[5]])
		check(after.total >= before.total,"免费增加%s不会降低整体评分" % spec[3])
		var users := _units(s,"user")
		var groups := []
		var need := int(CardDB.get_def(spec[1]).recipe_n)
		for i in cores.size(): groups.append([cores[i]]+users.slice(i*need,(i+1)*need)+(buffs if i == 0 else []))
		check(_compile(s,groups),"原%s方案经真实Intent仍能编组" % spec[1])
		Settle.produce(s)
		check(s.resource_count("ai","cash") == 10+int(spec[5]),"真实结算确认%s产出%d现金" % [spec[1],spec[5]])
	# 同库存输入顺序不影响最优分配；不能靠把一个反例的核心排在前面修补。
	var order := _state()
	_add(order,"baoyue",2)
	_add(order,"shuabuting")
	var capacity := Eval.capacity(order,"ai")
	order.players.ai.cards.reverse()
	check(Eval.capacity(order,"ai") == capacity,"资源分配不依赖手牌顺序")

func _test_cash_monotonicity() -> void:
	var s := _state(10,7)
	var group := _add(s,"xinxijianfang")+_add(s,"yinqing996",2)+_units(s,"user")
	for strength in [0.0,0.5,0.75,1.0]:
		var p := _profile(strength)
		var richer := AIEnvironment.copy(s)
		var before := Eval.score(richer,"ai",p)
		_add(richer,"cash")
		check(Eval.score(richer,"ai",p) > before,"强度%s：真实增加现金严格提高评分" % strength)
		var produced := AIEnvironment.copy(s)
		before = Eval.score(produced,"ai",p)
		check(_compile(produced,[group]),"强度%s产能单调夹具可真实编组" % strength)
		Settle.produce(produced)
		check(produced.resource_count("ai","cash") == 82 and Eval.score(produced,"ai",p) > before,
			"强度%s实际生产72现金不会被缩短时域抵消" % strength)
	var terminal := _state()
	terminal.winner = "ai"
	check(Eval.score(terminal,"ai") == Eval.TERMINAL_SCORE and Eval.score(terminal,"player") == -Eval.TERMINAL_SCORE,
		"实际胜负始终优先于经济估值")

func _threat(s: GameState) -> float:
	var p := _profile()
	p.engine_horizon = 0.0
	p.upgrade_weight = 0.0
	p.risk_weight = 1.0
	var f := Eval.features(s,"player",p)
	return float(f.asset)-float(f.risk)-float(f.total)

func _test_resource_monotonicity() -> void:
	var inventories := [["baoyue","baoyue","ditui"],
		["xinxijianfang","yinqing996","yinqing996","xufei","waimai"],
		["zuokong","chaping","resou","liebian","touliu"],
		["ditui","pinshaoshao","waimai","yinqing996","liebian"],
		["shuabuting","yunketang","baoyue","yinqing996"]]
	for strength in [0.0,0.5,1.0]:
		var p := _profile(strength)
		p["_context"] = Context.new()
		var failure := []
		var samples := 0
		for cash in [1,2,4,7,10,30]:
			for users in range(1,16):
				for inventory in inventories:
					var s := _state(cash,users)
					for id in inventory: _add(s,id)
					for id in ["zuokong","butie","resou"]: s.add_card("player",id)
					var before := Eval.features(s,"ai",p)
					for resource in ["cash","user"]:
						var richer := AIEnvironment.copy(s)
						_add(richer,resource)
						var after := Eval.features(richer,"ai",p)
						if failure.is_empty() and (after.engine < before.engine or after.total < before.total):
							failure = [cash,users,inventory,resource,before,after]
						samples += 1
		check(failure.is_empty(),"强度%s：%d组混合生产/攻击/Buff库存免费多现金或用户不降产能和总分" % [strength,samples])
		if not failure.is_empty(): printerr("单调性反例：",failure)

func _test_user_financing() -> void:
	for strength in [0.0,0.5,1.0]:
		var s := _state(10,7)
		for id in ["baoyue","baoyue","ditui"]: _add(s,id)
		var p := _profile(strength)
		var before := Eval.features(s,"ai",p)
		var sold := IntentApply.new(s).apply(Intent.pawn("ai",_units(s,"user").slice(0,1)))
		check(sold.get("ok",false),"强度%s单用户融资经真实Intent合法" % strength)
		var after := Eval.features(s,"ai",p)
		check(before.asset == after.asset and before.engine == 6.0 and after.engine == 6.0 and after.total <= before.total,
			"强度%s：同资产交换且未解锁付款路线，卖用户不能凭空抬高产能或总分" % strength)
	# 这不是禁止典当用户：新现金真实解除归零拒付时，应计入可执行收益。
	var financed := _state(2,2)
	var ids := _add(financed,"ditui")+_add(financed,"yinqing996")
	var before := Eval.capacity(financed,"ai")
	check(IntentApply.new(financed).apply(Intent.pawn("ai",_units(financed,"user").slice(0,1))).get("ok",false),
		"保留1用户的真实融资可使现金从2变3")
	var after := Eval.capacity(financed,"ai")
	check(_compile(financed,[ids+_units(financed,"cash").slice(0,2)]),"融资后的地推与996真实可编组")
	Settle.produce(financed)
	check(before == 0.0 and after == 2.0 and financed.resource_count("ai","cash") == 1 and financed.resource_count("ai","user") == 5,
		"解锁付款的融资实付2现金产4用户，产能只计真实净资产增量2")

func _test_shared_resources() -> void:
	var s := _state(1,6)
	var weapons := _add(s,"zuokong",3)
	check(_compile(s,[[weapons[0]]+_units(s,"user")]),"6用户供一组做空的真实编组合法")
	var pool := s.arm_attacks("ai")
	check(pool.cash == 3 and is_equal_approx(_threat(s),float(pool.cash)/20.0),
		"三张做空共享6用户，威胁与真实装弹3点一致，不重复算9点")
	s = _state(1,12)
	weapons = _add(s,"zuokong",2)
	var boost := _add(s,"resou")
	var users := _units(s,"user")
	check(_compile(s,[[weapons[0]]+users.slice(0,6)+boost,[weapons[1]]+users.slice(6,12)]),
		"两个攻击组共享一张热搜的真实编组合法")
	pool = s.arm_attacks("ai")
	check(pool.cash == 9 and is_equal_approx(_threat(s),float(pool.cash)/20.0),
		"单张攻击Buff不能同时翻倍两组，威胁等于真实9点")
	s = _state(12,1)
	weapons = _add(s,"butie",2)
	var cash := _units(s,"cash")
	check(_compile(s,[[weapons[0]]+cash.slice(0,6),[weapons[1]]+cash.slice(6,12)]),
		"两组补贴各6现金可编组")
	# 在装弹前估计；装弹将实际扣掉第一组现金。
	var estimated := _threat(s)
	pool = s.arm_attacks("ai")
	check(pool.user == 4 and is_equal_approx(estimated,float(pool.user)/20.0),
		"12现金只付得起一组补贴，后一组归零拒付与真实威胁一致")
	s = _state(10,2)
	var first := _add(s,"xinxijianfang")
	_add(s,"xufei")
	var fill := _add(s,"liebian")
	var buffs := _add(s,"yinqing996",2)
	check(Eval.capacity(s,"ai") == 72.0,"单张裂变只能补齐一个用户配方，两996可叠乘同一个核心")
	check(_compile(s,[first+fill+buffs+_units(s,"user").slice(0,1)]),"最优裂变和叠乘方案真实可编组")
	Settle.produce(s)
	check(s.resource_count("ai","cash") == 82,"真实结算验证裂变和两996的72现金产能")

func _test_cash_order() -> void:
	var s := _state(2,3)
	var product := _add(s,"yunketang")
	var recruit := _add(s,"ditui")
	var before := Eval.capacity(s,"ai")
	check(_compile(s,[recruit+_units(s,"cash"),product+_units(s,"user")]),"先进账再付款夹具按相反建组顺序也合法")
	Settle.produce(s)
	check(s.resource_count("ai","cash") == 4 and s.resource_count("ai","user") == 5 and before >= 4.0,
		"用户配方先生产，原有2现金席位之后可合法支付地推")
	s = _state(1,3)
	_add(s,"yunketang")
	_add(s,"ditui")
	_add(s,"yinqing996")
	check(Eval.capacity(s,"ai") == 8.0,"未来进账不能虚构当前缺少的现金配方席位")

func _test_cache() -> void:
	var s := _state(10,8)
	_add(s,"baoyue",2)
	_add(s,"shuabuting")
	var p := _profile()
	var context := Context.new()
	p["_context"] = context
	var before := StateCodec.state_hash(s)
	var value := Eval.capacity(s,"ai",p)
	var states := int(context.allocation_stats.get("states",0))
	s.players.ai.cards.reverse()
	for c in s.players.ai.cards: c.uid += 1000
	check(Eval.capacity(s,"ai",p) == value and context.allocation_stats.hits == 1
		and context.allocation_stats.states == states,"同库存换顺序/UID复用资源DP，不重做分配")
	var intact := AIEnvironment.copy(s)
	var snapshot := StateCodec.state_hash(intact)
	Eval.features(intact,"ai",p)
	check(StateCodec.state_hash(intact) == snapshot and before != snapshot,"评估缓存不修改输入牌局")
	print("ALLOCATION_CACHE ",context.allocation_stats," entries=",context.allocation_values.size())
