# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Cap = preload("res://engine/bot_capabilities.gd")
const Env = preload("res://engine/bot_environment.gd")
var fixture: Dictionary

func _initialize() -> void:
	CardDB.load_from("res://data/cards.json")
	var original := CardDB.CARDS.duplicate(true)
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_formations.json"))
	_test_replay_no_threat()
	_test_tie_order()
	_test_replay_defense()
	_test_future_purchase()
	_test_cross_resource_lock()
	_test_recorded_mixed_resources()
	_test_unpayable_and_payment_order()
	_test_modes()
	CardDB.CARDS = original
	finish()

func _profile(mode := 1) -> Dictionary:
	var p := BOTSearch.from_model("bot", 1.0).resolved_parameters()
	p["formation_mode"] = mode
	p["_context"] = BOTActions.Context.new()
	return p

func _full_roots(s: GameState) -> Array:
	var p := _profile()
	p["_work"] = [int(p.node_budget)]
	return BOTActions.generate(s,"bot",p)

func _recorded(step: String) -> GameState:
	var s := GameState.new()
	StateCodec.restore(s, fixture.snapshots[step].state)
	return s

func _core(s: GameState, id: String, who := "bot") -> Dictionary:
	for c in s.players[who].cards:
		if c.def_id == id and not c.get("locked", false): return c
	return {}

func _resource_count(s: GameState, ids: Array, resource: String) -> int:
	var n := 0
	for uid in ids:
		var d := CardDB.get_def(s.find_card("bot", int(uid)).get("def_id", ""))
		if d.get("kind") == CardDB.KIND_UNIT and d.get("res") == resource: n += 1
	return n

func _exact_recipe(s: GameState, ids: Array) -> bool:
	var cards: Array = []
	for uid in ids: cards.append(s.find_card("bot", int(uid)))
	var ev := ComboRules.evaluate(cards)
	if ev.type == "upgrade": return true
	var d := CardDB.get_def(ev.leader)
	return _resource_count(s, ids, d.recipe_res) == int(d.recipe_n) \
		and _resource_count(s, ids, "cash") + _resource_count(s, ids, "user") == int(d.recipe_n)

func _test_replay_no_threat() -> void:
	for step in ["68", "220"]:
		var s := _recorded(step)
		var before := StateCodec.state_hash(s)
		check(s.action_first() == "player", "录像%s：BOT后手，玩家已结束行动" % step)
		var pool := Env.copy(s).arm_attacks("player")
		check(int(pool.cash) == 0 and int(pool.user) == 0, "录像%s：真实装弹没有攻击点" % step)
		var p := _profile()
		var options := BOTActions._core_options(s, "bot", _core(s, "xinxijianfang" if step == "68" else "butie"), {}, p)
		var all_minimal := not options.is_empty()
		var minimal_ids: Array = []
		for option in options: all_minimal = all_minimal and _exact_recipe(s, option.uids)
		for option in options:
			if _exact_recipe(s,option.uids):
				minimal_ids = option.uids
				break
		check(all_minimal, "录像%s：formation1候选不塞无收益现金或用户" % step)
		if not minimal_ids.is_empty():
			var recorded := Env.copy(s)
			var compact := Env.copy(s)
			check(Env.replay(recorded,[fixture.snapshots[step].intent]) and Env.replay(compact,[Intent.create_combo("bot",minimal_ids)]),
				"录像%s：原混组及同核心精简配方都合法" % step)
			Env.settle(recorded,BOTTurnPlan.greedy_target)
			Env.settle(compact,BOTTurnPlan.greedy_target)
			check(Env.key(recorded) == Env.key(compact),"录像%s：去除冗余资源后真实结算的全部决策状态不变" % step)
		var roots := Cap.select(BOTActions._build({"state":s,"intents":[]}, "bot", p), 24, "bot", "rank", true, p)
		var pure := false
		for node in roots:
			if node.intents.is_empty(): continue
			var minimal := true
			for intent in node.intents: minimal = minimal and _exact_recipe(s, intent.uids)
			pure = pure or minimal
		check(pure, "录像%s：根24保留纯配方方案" % step)
		if step == "68":
			var full_roots := _full_roots(s)
			var pure_engine := false
			for node in full_roots:
				if node.intents.size() != 1 or node.intents[0].op != Intent.OP_COMBO: continue
				for combo in node.state.combos:
					if combo.owner == "bot" and combo.eval.type == "production" and combo.eval.leader == "xinxijianfang":
						pure_engine = pure_engine or _exact_recipe(node.state, combo.uids)
			check(pure_engine, "录像68：完整候选池保留不买卖、只编信息茧房+7用户的同策略精简版")
		check(StateCodec.state_hash(s) == before, "录像%s：候选生成不修改输入局面" % step)

func _small_state(bot_cash := 10, bot_users := 6, player_cash := 10, player_users := 8) -> GameState:
	var s := GameState.new()
	s.set_seed(731)
	s.players = {"bot":{"cards":[]}, "player":{"cards":[]}}
	for spec in [["bot", bot_cash, bot_users], ["player", player_cash, player_users]]:
		for n in int(spec[1]): s.add_card(spec[0], "cash")
		for n in int(spec[2]): s.add_card(spec[0], "user")
	return s

func _units(s: GameState, who: String, resource: String) -> Array:
	var out: Array = []
	for c in s.players[who].cards:
		if not c.get("locked", false) and CardDB.get_def(c.def_id).get("res", "") == resource:
			out.append(c.uid)
	return out

func _formed(s: GameState, ids: Array) -> GameState:
	var next := Env.copy(s)
	check(Env.replay(next, [Intent.create_combo("bot", ids)]), "测试阵型通过真实编组校验")
	return next

func _test_tie_order() -> void:
	var s := _small_state()
	s.add_card("bot", "yunketang")
	var basic: Array = [_core(s, "yunketang").uid] + _units(s, "bot", "user").slice(0, 3)
	var lean := {"state":_formed(s, basic), "rank":4.0, "tag":"lean"}
	var padded := {"state":_formed(s, basic + _units(s, "bot", "cash").slice(0, 2)), "rank":4.0, "tag":"padded"}
	for nodes in [[padded, lean], [lean, padded]]:
		var chosen := Cap.select(nodes, 1, "bot", "rank", true, _profile())
		check(chosen[0].tag == "lean", "同分候选不依赖输入顺序，优先精简资源编组")

func _attack_focus(s: GameState, leader: String) -> void:
	Settle.attack_phase(s, "player", func(state: GameState, attacker: String, targets: Array, pools: Dictionary) -> Dictionary:
		for t in targets:
			if t.leader == leader and t.res == "user": return t
		for t in targets:
			if t.leader == leader: return t
		return BOTTurnPlan.greedy_target(state, attacker, targets, pools))

func _own_combo(s: GameState, leader: String) -> Dictionary:
	for c in s.combos:
		if c.owner == "bot" and c.eval.leader == leader and c.eval.type != "upgrade": return c
	return {}

func _test_replay_defense() -> void:
	var s := _recorded("143")
	var before := StateCodec.state_hash(s)
	var pool := Env.copy(s).arm_attacks("player")
	check(int(pool.user) == 4 and int(pool.cash) == 0, "录像143：玩家真实可付费装出4点用户攻击")
	var p := _profile()
	var options := BOTActions._core_options(s, "bot", _core(s, "xinxijianfang"), {}, p)
	var defensive: Array = []
	var lean: Array = []
	for option in options:
		if _resource_count(s, option.uids, "user") >= 11 and _resource_count(s, option.uids, "cash") == 0:
			if defensive.is_empty() or option.uids.size() < defensive.size(): defensive = option.uids
		if _exact_recipe(s, option.uids): lean = option.uids
	check(not defensive.is_empty() and not lean.is_empty(), "录像143：信息茧房保留纯配方与至少11用户的抗4击候选")
	var roots := Cap.select(BOTActions._build({"state":s,"intents":[]}, "bot", p), 24, "bot", "rank", true, p)
	var protected_root := false
	for node in roots:
		var combo := _own_combo(node.state, "xinxijianfang")
		protected_root = protected_root or (not combo.is_empty() and _resource_count(node.state, combo.uids, "user") >= 11)
	check(protected_root, "录像143：信息茧房抗4击阵型进入根24")
	var full_roots := _full_roots(s)
	var full_defense := false
	for node in full_roots:
		var combo := _own_combo(node.state,"xinxijianfang")
		full_defense = full_defense or (not combo.is_empty() and _resource_count(node.state,combo.uids,"user") >= 11)
	check(full_defense, "录像143：含买卖的完整候选池仍保留信息茧房抗4击阵型")
	if not defensive.is_empty() and not lean.is_empty():
		var defended := _formed(s, defensive)
		var minimal := _formed(s, lean)
		var defended_leaf := Env.copy(defended)
		var minimal_leaf := Env.copy(minimal)
		_attack_focus(defended_leaf, "xinxijianfang")
		_attack_focus(minimal_leaf, "xinxijianfang")
		check(defended_leaf.combo_intact("bot", _own_combo(defended_leaf, "xinxijianfang")), "录像143：11用户真实承受4击后信息茧房仍完整")
		check(not minimal_leaf.combo_intact("bot", _own_combo(minimal_leaf, "xinxijianfang")), "录像143：7用户纯配方遭同样4击会被拆散")
		var cash := defended_leaf.resource_count("bot", "cash")
		Settle.produce(defended_leaf)
		Settle.produce(minimal_leaf)
		check(defended_leaf.resource_count("bot", "cash") == cash + 18 and minimal_leaf.resource_count("bot", "cash") == cash,
			"录像143：抗拆阵型实际多产18现金，非无收益填料")
		var scored := [{"state":minimal,"rank":BOTTurnPlan.settled_score(minimal_leaf,"bot",p),"tag":"lean"},
			{"state":defended,"rank":BOTTurnPlan.settled_score(defended_leaf,"bot",p),"tag":"defended"}]
		check(scored[1].rank > scored[0].rank and Cap.select(scored,1,"bot","rank",true,p)[0].tag == "defended",
			"更高真实结算收益的防御方案优先于简洁偏好")
	check(StateCodec.state_hash(s) == before, "录像143：生成、排序与试结算均不改原局面")

func _test_future_purchase() -> void:
	var s := _small_state(10, 6, 1, 8)
	s.draw_first = "bot"
	s.add_card("bot", "yunketang")
	s.market = ["heigongguan"]
	check(s.action_first() == "bot" and s.resource_count("player", "cash") < CardDB.get_def("heigongguan").price,
		"先手测试：对手当前现金买不起市场攻击卡")
	var financed := Env.copy(s)
	check(Env.replay(financed, [Intent.pawn("player", _units(financed,"player","user").slice(0,7)), Intent.buy("player",0)]),
		"对手可合法典当用户融资买入市场攻击卡")
	var attack: Array = [_core(financed,"heigongguan","player").uid] + _units(financed,"player","cash").slice(0,4)
	check(Env.replay(financed, [Intent.create_combo("player",attack)]) and int(financed.arm_attacks("player").user) == 2,
		"融资购买后有真实可支付的2点用户攻击")
	var options := BOTActions._core_options(s,"bot",_core(s,"yunketang"),{},_profile())
	var kept := false
	for option in options: kept = kept or _resource_count(s,option.uids,"user") >= 5
	check(kept, "BOT先手时保留针对对手未来购牌的防御阵型")
	var boosted := _small_state(4,12,30,3)
	boosted.draw_first = "bot"
	boosted.add_card("bot","yunketang")
	boosted.market = ["heigongguan","resou","resou"]
	var bought := Env.copy(boosted)
	check(Env.replay(bought,[Intent.buy("player",0),Intent.buy("player",0),Intent.buy("player",0)]),
		"先手威胁测试：对手可真实买入攻击牌及两张热搜")
	var ids: Array = [_core(bought,"heigongguan","player").uid] + _units(bought,"player","cash").slice(0,4)
	for c in bought.players.player.cards:
		if c.def_id == "resou": ids.append(c.uid)
	check(Env.replay(bought,[Intent.create_combo("player",ids)]) and int(bought.arm_attacks("player").user) == 8,
		"两张热搜叠加后真实装出8点用户攻击")
	var stacked_defense := false
	for option in BOTActions._core_options(boosted,"bot",_core(boosted,"yunketang"),{},_profile()):
		stacked_defense = stacked_defense or _resource_count(boosted,option.uids,"user") >= 11
	check(stacked_defense,"先手防御候选覆盖市场Buff叠加后的8击，而非只按裸攻击2击裁剪")

func _test_cross_resource_lock() -> void:
	var s := _small_state(7,7)
	for id in ["yunketang","pinshaoshao"]: s.add_card("bot",id)
	for id in ["butie","zuokong"]: s.add_card("player",id)
	var attack_user: Array = [_core(s,"butie","player").uid] + _units(s,"player","cash").slice(0,6)
	var attack_cash: Array = [_core(s,"zuokong","player").uid] + _units(s,"player","user").slice(0,6)
	check(Env.replay(s,[Intent.create_combo("player",attack_user),Intent.create_combo("player",attack_cash)]), "双资源攻击测试合法编成4用户/3现金攻击")
	var p := _profile()
	var variants := BOTActions._core_options(s,"bot",_core(s,"yunketang"),{},p)
	var mixed: Array = []
	for option in variants:
		if _resource_count(s,option.uids,"user") == 3 and _resource_count(s,option.uids,"cash") == 3:
			mixed = option.uids
	check(not mixed.is_empty(), "双资源威胁下仍生成云课堂带3现金的混组")
	if mixed.is_empty(): return
	var mixed_state := _formed(s,mixed)
	var other: Array = []
	for option in BOTActions._core_options(mixed_state,"bot",_core(mixed_state,"pinshaoshao"),{},p):
		if _resource_count(mixed_state,option.uids,"cash") == 3 and _resource_count(mixed_state,option.uids,"user") == 4:
			other = option.uids
	check(not other.is_empty(), "第一组编成后，第二组仍生成拼少少带4用户的互相保护阵型")
	if other.is_empty(): return
	check(Env.replay(mixed_state,[Intent.create_combo("bot",other)]), "第二组使用独立配方通过真实编组校验")
	var lean: Array = [_core(s,"yunketang").uid] + _units(s,"bot","user").slice(0,3)
	var lean_state := _formed(s,lean)
	check(Env.replay(lean_state,[Intent.create_combo("bot",[_core(lean_state,"pinshaoshao").uid]+_units(lean_state,"bot","cash").slice(0,3))]),
		"对照局面两组只使用最少配方")
	# 两组互混使攻击先选哪组都有防御价值，而非依赖对手选了较差靶子。
	for first in ["yunketang","pinshaoshao"]:
		var defended := Env.copy(mixed_state)
		var minimal := Env.copy(lean_state)
		_attack_focus(defended,first)
		_attack_focus(minimal,first)
		var saved := "pinshaoshao" if first == "yunketang" else "yunketang"
		check(defended.combo_intact("bot",_own_combo(defended,saved)) and not minimal.combo_intact("bot",_own_combo(minimal,saved)),
			"先打%s时，同摞跨资源锁真实保住另一组%s" % [first,saved])
		var resource := "user" if saved == "pinshaoshao" else "cash"
		var before := defended.resource_count("bot",resource)
		var without := minimal.resource_count("bot",resource)
		Settle.produce(defended)
		Settle.produce(minimal)
		check(defended.resource_count("bot",resource) == before + 4 and minimal.resource_count("bot",resource) == without,
			"混组保住的%s真实产出4%s，纯配方无此收益" % [saved,resource])
	var roots := _full_roots(s)
	var useful_root := false
	for node in roots:
		var cloud := _own_combo(node.state,"yunketang")
		var shop := _own_combo(node.state,"pinshaoshao")
		if cloud.is_empty() or shop.is_empty(): continue
		if _resource_count(node.state,cloud.uids,"cash") == 0 and _resource_count(node.state,shop.uids,"user") == 0: continue
		# 不固定具体牌数：在两种攻击起点下都能留下真实净产出的任意混组路线均可。
		var survives_both := true
		for first in ["yunketang","pinshaoshao"]:
			var trial := Env.copy(node.state)
			_attack_focus(trial,first)
			var total := trial.resource_count("bot","cash") + trial.resource_count("bot","user")
			Settle.produce(trial)
			survives_both = survives_both and trial.resource_count("bot","cash") + trial.resource_count("bot","user") > total
		useful_root = useful_root or survives_both
	check(useful_root,"完整根24保留任一在两种攻击起点下都能留下真实净产出的跨资源混组")

func _compact_touliu(nodes: Array) -> bool:
	for node in nodes:
		var combo := _own_combo(node.state,"touliu")
		if combo.is_empty(): continue
		if int(combo.eval.output_n) == 16 and _resource_count(node.state,combo.uids,"cash") == 11 \
			and _resource_count(node.state,combo.uids,"user") == 0: return true
	return false

func _test_recorded_mixed_resources() -> void:
	var after_trades := _recorded("mixed_40_35")
	var builds := BOTActions._build({"state":after_trades,"intents":[]},"bot",_profile())
	check(_compact_touliu(builds),"40步录像：原购牌后持牌的编组beam保留11现金、0用户的同策略精简版")
	for key in ["mixed_40_31","mixed_40_35"]:
		var s := _recorded(key)
		var before := StateCodec.state_hash(s)
		var roots := _full_roots(s)
		check(_compact_touliu(roots),"40步录像%s：完整根保留投流+996+11现金且不塞用户的有效防御" % key)
		check(StateCodec.state_hash(s) == before,"40步录像%s：搜索不修改原局面" % key)
	# 配方外现金有实际抗拆价值；同组两用户则既不提高产出，也挡不住用户清零。
	var compact: Array = [_core(after_trades,"touliu").uid,_core(after_trades,"yinqing996").uid] \
		+ _units(after_trades,"bot","cash").slice(0,11)
	for reply in ["cash6","user4"]:
		var outcomes := {}
		for shape in ["recorded","compact","short"]:
			var s := Env.copy(after_trades)
			var ids: Array = fixture.snapshots.mixed_40_35.intent.uids if shape == "recorded" else compact.slice(0,12 if shape == "short" else 13)
			check(Env.replay(s,[Intent.create_combo("bot",ids)]) and _mixed_40_reply(s,reply),
				"40步录像%s/%s：编组及对手融资购牌攻击均通过真实规则" % [reply,shape])
			var armed := Env.copy(s).arm_attacks("player")
			check((int(armed.cash) == 6 if reply == "cash6" else int(armed.user) == 4) \
				and Settle.check_action_completion(s,"player",s.combos.filter(func(c): return c.owner == "player")).ok,
				"40步录像%s/%s：真实装弹点数及付款护栏成立" % [reply,shape])
			Env.settle(s,func(state: GameState,who: String,targets: Array,pools: Dictionary) -> Dictionary:
				for t in targets:
					if t.leader == "touliu": return t
				return BOTTurnPlan.greedy_target(state,who,targets,pools))
			outcomes[shape] = {"state":s,"key":Env.key(s)}
		check(outcomes.recorded.key == outcomes.compact.key,"40步录像%s：移出2用户后真实结算全部决策状态不变" % reply)
		if reply == "cash6":
			check(outcomes.compact.state.resource_count("bot","user") == 18 and outcomes.short.state.resource_count("bot","user") == 2,
				"40步录像：11现金承受6击后仍产16用户，10现金会被拆散，不能误删有效现金防御")
		else:
			check(outcomes.compact.state.winner == "player" and outcomes.recorded.state.winner == "player",
				"40步录像：2用户放入投流也不能避免4用户攻击在生产前致胜")

func _mixed_40_reply(s: GameState, reply: String) -> bool:
	# 真实先后手：BOT已行动，对手可在后手行动时典当用户购买热搜或补贴。
	var user_attack := reply == "user4"
	var bought := "butie" if user_attack else "resou"
	if not Env.replay(s,[Intent.pawn("player",_units(s,"player","user").slice(0,4 if user_attack else 1))]): return false
	var index: int = s.market.find(bought)
	if index < 0 or not Env.replay(s,[Intent.buy("player",index)]): return false
	var ids: Array = [_core(s,"butie" if user_attack else "zuokong","player").uid] \
		+ _units(s,"player","cash" if user_attack else "user").slice(0,6)
	if not user_attack: ids.append(_core(s,"resou","player").uid)
	return Env.replay(s,[Intent.create_combo("player",ids)])

func _test_unpayable_and_payment_order() -> void:
	for resource in ["cash","user"]:
		CardDB.CARDS["formation_attack_" + resource] = {"name":"装弹测试", "kind":"attack", "tier":9, "price":1,
			"recipe_res":"cash", "recipe_n":2, "attack_res":resource, "attack_n":1}
	var lone := _small_state(5,5,2,3)
	lone.add_card("bot","yunketang")
	lone.add_card("player","formation_attack_user")
	check(Env.replay(lone,[Intent.create_combo("player",[_core(lone,"formation_attack_user","player").uid]+_units(lone,"player","cash"))]),
		"构造已成型但装弹将现金归零的攻击组")
	check(int(Env.copy(lone).arm_attacks("player").user) == 0, "现金归零护栏使已成型攻击组无法装弹")
	var options := BOTActions._core_options(lone,"bot",_core(lone,"yunketang"),{},_profile())
	var minimal := true
	for option in options: minimal = minimal and _exact_recipe(lone,option.uids)
	check(minimal, "后手不为真实无法付款的攻击加入冗余用户")
	var ordered := _small_state(5,5,4,3)
	ordered.add_card("bot","yunketang")
	for resource in ["cash","user"]:
		var id: String = "formation_attack_" + resource
		ordered.add_card("player",id)
		check(Env.replay(ordered,[Intent.create_combo("player",[_core(ordered,id,"player").uid]+_units(ordered,"player","cash").slice(0,2))]),
			"顺序付款测试：两攻击组使用不相交的现金")
	var before := StateCodec.state_hash(ordered)
	var pools := Env.copy(ordered).arm_attacks("player")
	check(int(pools.cash) == 1 and int(pools.user) == 0, "顺序装弹：前组付费后后组资金归零拒付")
	options = BOTActions._core_options(ordered,"bot",_core(ordered,"yunketang"),{},_profile())
	var cash_variant := false
	var user_variant := false
	for option in options:
		cash_variant = cash_variant or _resource_count(ordered,option.uids,"cash") > 0
		user_variant = user_variant or _resource_count(ordered,option.uids,"user") > 3
	check(cash_variant and not user_variant, "后手防御按真实顺序装弹，不能把拒付的第二种攻击算作威胁")
	check(StateCodec.state_hash(ordered) == before, "威胁预演不消费真实现金或写开火标记")

func _test_modes() -> void:
	var s := _small_state(2,4,3,3)
	s.add_card("bot","yunketang")
	var core := _core(s,"yunketang")
	var none := BOTActions._core_options(s,"bot",core,{},_profile(0))
	var conditional := BOTActions._core_options(s,"bot",core,{},_profile(1))
	var exhaustive := BOTActions._core_options(s,"bot",core,{},_profile(2))
	check(none.size() == 1 and conditional.size() == 1, "mode0及无威胁mode1只有纯配方")
	var counts := {}
	for option in exhaustive:
		counts[str([_resource_count(s,option.uids,"cash"),_resource_count(s,option.uids,"user")])] = true
	check(counts.size() == 6 and exhaustive.size() == 6, "mode2在足够预算下全枚举2现金、1额外用户的6种数量组合")
	for cash in 3:
		for users in [3,4]: check(counts.has(str([cash,users])), "mode2包含现金%d/用户%d阵型" % [cash,users])
	var baseline := BOTSearch.from_model("bot",0.5).resolved_parameters()
	check(int(baseline.formation_mode) == 1 and StateCodec.canon(BOTActions._core_options(s,"bot",core,{},baseline)) == StateCodec.canon(none),
		"所有强度共用防御能力，无威胁时仍只生成纯配方")
	s.add_card("bot","tuisong")
	var protected_options := BOTActions._core_options(s,"bot",core,{},_profile())
	var no_padding := true
	for option in protected_options: no_padding = no_padding and _exact_recipe(s,option.uids)
	check(protected_options.size() > 1 and no_padding,"持有保护Buff但对手无攻击时，也不扩展无收益资源")
