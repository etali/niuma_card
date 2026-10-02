# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name MatchSimulator
extends RefCounted

## 无头对局模拟器：不依赖场景树，双方都用 AI 策略打完整场
## 用于平衡性回归、逻辑验证、后续批量模拟：
##   godot --headless -s tests/test_simulator.gd
##
## 三个入口，按「要不要埋点」挑：
##   run_game()   一局，返回 { winner, win_reason, rounds, timeout, log } 摘要
##   run_rounds() 一局，返回终局 GameState，可传三个回合内钩子（平衡工具用）
##   action_phase() 单方行动，给自己写循环的调用方
##
## 「一回合是什么」只定义在 run_rounds 里；回合内的结算次序只定义在 Settle.run 里。
## 场景层（scenes/main.gd）不走这里 —— 它是等补间、等玩家点选的相位机，
## 每个阶段中间都有 await（_attack_turn 里有 6 处），驱动不了同步循环。
##
## 两边共用的是**规则层**，从上到下三段：
##   IntentApply    意图能不能落地（模拟器在 run_rounds 里也建一个，见那边的注释：
##                  谁往这里加一道判断，模拟器量的就得是同一个游戏）
##   Settle / GameState  状态怎么变。次序取自同一个 Settle.ordered_production_combos
##   ComboRules / 注册的AI实现  组合怎么算、AI 怎么决策
## 不共用的只有「谁来推进」：这边是 Settle.run 一把跑完，
## 场景层逐组过 IntentApply（produce 一组、演一组，最后 finalize），
## 好在每步中间插补间。所以别把 Settle.run 当成两边的公共入口 —— 它只在这边

## 回合上限取 data/ai.json 的 `simulation.max_rounds`（CardDB.sim_rules()）：
## 跑到那个回合还没分出胜负就判超时，tools/balance_report.gd 会报告未分胜负的局数和比例。
## 它只是模拟器的安全阀，不是游戏规则 —— 真人局（scenes/main.gd）不封顶，
## 所以在配置里单开 `_sim` 段，不混进 `_game`。
##
## 默认值只能是这个哨兵：GDScript 的默认参数在解析期求值，写不了 CardDB 调用。
## 传 <= 0 就是「按配置」，函数体里再取
const ROUNDS_FROM_CONFIG := -1

static func run_game(max_rounds := ROUNDS_FROM_CONFIG, rng_seed := 0,
		cfgs: Dictionary = {}, first := "") -> Dictionary:
	var state := run_rounds(max_rounds, rng_seed, Callable(), Callable(), Callable(), cfgs, first)
	return {
		"winner": state.winner,
		"win_reason": state.win_reason,
		"rounds": state.round_num,
		"timeout": state.winner == "",
		"log": state.log,
	}

## 打完一整局，返回终局状态。想在回合中间埋点的调用方走这里而不是照抄循环：
##
##   before_round.call(state)  每回合行动阶段之前（在这里量「买不起任何卡」：
##                             要的是上回合产出到账后、这回合买卡前那一刻）
##   before_settle.call(state) 双方行动完、结算之前（在这里量组合和闲置卡：
##                             Settle.finalize 会清空 state.combos，之后就数不到了）
##   after_settle.call(state)  结算完、推进下一回合之前（在这里量资金差）
##
## 三个点位不是随便切的，是「哪些数只在那一刻存在」定下来的，所以钩子在这三处。
## 平衡工具原先自己写了一遍这个循环（连 end_round/start_round 和回合上限一起），
## 于是「回合怎么推进」有两份定义。钩子都是可选的，不传就是纯模拟
## observers 是可选只读采集钩子：before_action / intent / settle；搜索副本不继承。
## first 指定开局抽卡先手，留空沿用 PLAYER。
## cfgs：`{座位: AISearch}`，缺的座位使用当前实现强度0。
## 两个座位各带一份是为了**档位对打** —— `ai.md` §「怎么判定搜索变强」：
## 每一方可以选择不同超参数，报表分别记录其解析后的profile。
## 不做成一个全局开关：全局开关只能让两边一起变强，而那量不出谁更强
static func run_rounds(max_rounds := ROUNDS_FROM_CONFIG, rng_seed := 0,
		before_round: Callable = Callable(),
		before_settle: Callable = Callable(),
		after_settle: Callable = Callable(),
		cfgs: Dictionary = {}, first := "", observers: Dictionary = {}) -> GameState:
	var state := GameState.new()
	if rng_seed != 0:
		state.set_seed(rng_seed)
	state.new_game(first)
	if max_rounds <= 0:
		max_rounds = int(CardDB.sim_rules()["max_rounds"])
	while state.winner == "" and state.round_num <= max_rounds:
		if not before_round.is_null():
			before_round.call(state)
		for who in state.action_order():
			if state.winner != "":
				break
			if observers.has("before_action"):
				observers["before_action"].call(state, who)
			action_phase(state, who, cfgs.get(who), observers.get("intent", Callable()))
		if not before_settle.is_null():
			before_settle.call(state)
		if state.winner == "":
			Settle.run(state, cfgs, observers.get("settle", Callable()))
		else:
			Settle.finalize(state)
		if not after_settle.is_null():
			after_settle.call(state)
		if state.winner == "":
			state.end_round()
			state.start_round()
	return state

## 从一个**行动阶段刚做完**的局面接着打下去（`AIPlan.rollout_score` 的前推用）。
##
## `just_acted` 是刚行动完的那一方。它决定「这个回合还剩什么」：
##   - 它是先手 → 对手还没行动，先让对手走一遍再结算
##   - 它是后手 → 双方都行动完了，直接结算
## 判不对的话前推的第一个回合会凭空多一次或少一次行动，
## 而那正是要评估的那一步 —— 整个前推的读数会偏在最要紧的地方。
##
## `cfgs`（`{座位: AISearch}`）是前推里**想象出来的那两个人**。缺座位 = 贪心。
##
## cfgs 明确指定各座位的实现与超参数；缺省使用当前实现的最低强度。
## 搜索内部的低预算前推由具体AI实现负责，避免无意递归完整搜索。
##
## `max_rounds` 是**往前推几个回合**，不是绝对回合号 —— 前推是从半局中间起步的
static func continue_rounds(state: GameState, max_rounds: int, just_acted: String,
		cfgs: Dictionary = {}) -> GameState:
	if state.winner != "":
		return state
	var opp := GameState.opponent(just_acted)
	if just_acted == state.action_first():
		action_phase(state, opp, cfgs.get(opp))
	if state.winner == "":
		Settle.run(state, cfgs)
	return _loop_rounds(state, max_rounds - 1, cfgs)

## 从一个**攻击阶段正打到一半**的局面接着打下去（`AITurnPlan.target_picker` 的试算用）。
##
## 和 `continue_rounds` 的差别只在起点：那个从「行动阶段刚做完」起步，
## 这个从「我的点数池还剩几点」起步。所以它自己不装弹（`pools` 是调用方
## 手上那份，已经装好了），先把余点花完，再让对手打、再结算。
##
## 为什么要单独一个入口：选靶的试算必须能评估「点这一张之后整个结算变成什么样」，
## 而 `continue_rounds` 假设的是行动阶段刚结束 —— 拿它来推会凭空多跑一次行动阶段，
## 而那正好落在要评估的那一步上
static func continue_from_attack(state: GameState, who: String, pools: Dictionary,
		max_rounds: int, cfgs: Dictionary = {}) -> GameState:
	if state.winner != "":
		return state
	Settle.spend_pool(state, who, pools, AIPlan.target_picker(cfgs.get(who)))
	var opp := GameState.opponent(who)
	# 我是先手 → 对手的攻击阶段还没打；我是后手 → 他已经打过了
	if state.winner == "" and who == state.action_order()[0]:
		Settle.attack_phase(state, opp, AIPlan.target_picker(cfgs.get(opp)))
	if state.winner == "":
		Settle.produce(state)
	Settle.finalize(state)
	return _loop_rounds(state, max_rounds - 1, cfgs)

## 「整回合」那个循环，一份定义。两个 continue_* 的收尾都是它 ——
## 各写一遍的话，回合怎么推进就又有了两份（那正是 `run_rounds` 当年的病）
static func _loop_rounds(state: GameState, left: int, cfgs: Dictionary) -> GameState:
	while state.winner == "" and left > 0:
		state.end_round()
		state.start_round()
		for who in state.action_order():
			action_phase(state, who, cfgs.get(who))
			if state.winner != "":
				break
		if state.winner == "":
			Settle.run(state, cfgs)
		left -= 1
	return state

## 单方行动：典当（先冲线后救急）→ 连续买卡直到放弃 → 组卡。
## 公开的（原先叫 _action_phase，但 tools/balance_report.gd 一直从外面调它，
## 下划线是句谎话）。场景层不调这个 —— 它那份要在每步之间等演出节拍
## cfg：搜索强度（`engine/ai_search.gd`）。不传 = 当前实现强度0。
## 预算由传入profile决定；不读取屏幕偏好文件，便于离线复现。
static func action_phase(state: GameState, who: String, cfg: AISearch = null,
		on_intent: Callable = Callable()) -> void:
	# 一个 applier 贯穿这三步，不是每步各开一个。
	# 三步都走**同一条意图管道**（README.md §「3. 文件目录结构」）：典当、买卡、编组一律 app.apply(Intent.x)，
	# 不允许有哪一步退回去直接调 state.buy/state.pawn/state.create_combo。
	# 理由不是整齐 —— 模拟器是第三条执行路径（另两条是单机意图管道和联网房间），
	# 而平衡数字全是从这条路上量出来的。它绕开管道的话，
	# 以后谁在 IntentApply 里加一道买卡的判断，**模拟器量的就是另一个游戏**：
	# 报表照旧出数、一条错都不报，只是那些数不再描述玩家真正在玩的东西
	var app := IntentApply.new(state)
	if on_intent.is_valid():
		app.landed_intent.connect(func(intent: Dictionary, result: Dictionary, _from: String) -> void:
			on_intent.call(state, intent, result))
	AIAgent.new(LocalTransport.new(app), who, cfg).run_action_phase_sync()
