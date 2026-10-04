# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AITurnStrategy
extends "res://engine/ai_strategy.gd"


# 本机冻结局面标定的强度1.0基准；时间仅用于离线标定，运行只读取额度。
const BASE_COMPUTE_BUDGET := 3000000
const BASE_NODE_BUDGET := 2500000
const MIN_STRENGTH_COMPUTE := 6000

# 固定搜索阶梯终点。整数参数按阶段取值，计算比例单独连续映射。
const STRENGTH_TARGETS := {
	"future_reply_limit": 3,
	"rollout_step_budget": 512,
	"reply_generation_budget": 2048,
	"financing_choices": 8,
	"resale_mode": 1,
	"resale_budget": 512,
	"financing_mode": 2,
	"allocation_mode": 1,
	"formation_mode": 1,
	"candidate_dedup": 1,
	"attack_mode": 1,
	"attack_depth": 3,
	"reply_mode": 1,
	"rollout_capabilities": 1,
	"tactical_extension": 1,
	"financing_beam": 128,
	"allocation_budget": 128,
	"buy_beam": 20,
	"build_beam": 12,
	"plans": 16,
	"replies": 16,
	"finalists": 8,
	"future_rounds": 2,
	"samples": 3,
	"generation_budget": 4608,
	"node_budget": BASE_NODE_BUDGET,
	"target_trials": 36
}

func identifier() -> String:
	return "ai"

func display_name() -> String:
	return "AI"

func profile_version() -> String:
	return "5.2"

func parameter_schema() -> Array:
	return [
		_int("compute_budget", "每回合计算上限", "计算预算", 100, 1000000000, BASE_COMPUTE_BUDGET, BASE_COMPUTE_BUDGET, "强度1.0的本机约20秒计算量基准；按计算量停止，没有计时截止。可提高以突破基准算力，强度滑块保留此设置"),
		_float("search_fraction", "计算上限使用比例", "计算预算", 0.0, 1.0, 0.12675, "由强度按三次曲线自动推导，只读；强度0使用基准6000单位，强度1使用100%"),
		_int("financing_mode", "典当动作覆盖上限", "设计能力：动作空间", 0, 2, 0, 0, "0单张典当；1任意用户数量；2多种牌联合融资。可独立于强度滑块调整"),
		_int("resale_mode", "购入再典当", "设计能力：动作空间", 0, 1, 0, 0, "0只购买并保留；1补充买入再出售的市场阻断/周转路线"),
		_int("resale_budget", "交易周转展开额度", "计算预算：新增能力", 1, 20000, 512, 512, "交易序列的局部展开额度；同时受总额度限制"),
		_int("allocation_mode", "升级材料分配", "设计能力：动作空间", 0, 1, 0, 0, "0按出售价值或生产能力选择材料；1按卡种数量枚举合法材料分配（受分配额度限制）"),
		_int("formation_mode", "防御编组覆盖", "设计能力：动作空间", 0, 2, 0, 0, "0最低配方；1按现有/市场攻击与保护生成防御布局；2枚举全部富余数量布局（受分配额度限制）"),
		_int("candidate_dedup", "等价局面去重", "设计能力：候选保留", 0, 1, 0, 0, "0关闭；1合并仅卡牌编号不同的等价局面，并按材料数量保留不同路线"),
		_int("attack_mode", "攻击连续选靶", "设计能力：对抗搜索", 0, 1, 0, 0, "0单步试算后贪心续打；1递归比较连续攻击顺序，始终遵守同摞锁定规则"),
		_int("attack_depth", "连续选靶深度", "计算预算：新增能力", 1, 16, 3, 3, "仅连续选靶开启时使用，展开同时受选靶试算额度限制"),
		_int("reply_mode", "对手回应比较", "设计能力：对抗搜索", 0, 1, 0, 0, "0先按静态分压成一个回应；1分别推演保留的回应再取最不利结果"),
		_int("rollout_capabilities", "前推保留动作能力", "设计能力：对抗搜索", 0, 1, 0, 0, "0前推关闭常规融资、转卖、材料和防御扩展；1沿用这些能力。近端战术开关独立，宽度仍可单独限制"),
		_int("tactical_extension", "近端战术覆盖", "设计能力：候选与评估", 0, 1, 0, 0, "0关闭；1保留可支付攻击、在常规候选全败时补查单步买卖，并检查下一先行动者的合法典当必胜。攻击仍经真实回应判断"),
		_int("generation_budget", "候选生成启动额度", "计算预算：新增能力", 0, 10000000, 0, 0, "首次生成的节点数提示，按局面规模折算计算量；0自动。不足时在公平分配的计算份额内扩大重试，实际展开共享阶段节点上限"),
		_int("financing_choices", "每个购牌组合融资数", "计算预算：新增能力", 1, 64, 2, 2, "对每个市场购买子集保留的不同融资方案数"),
		_int("financing_beam", "融资方案宽度", "计算预算：新增能力", 1, 512, 64, 64, "每轮融资保留数量；优先保留不同融资金额。仅典当覆盖非0时使用"),
		_int("allocation_budget", "单核心材料分配额度", "计算预算：新增能力", 1, 4096, 64, 64, "按卡种分组枚举的局部额度，同时受总展开额度限制"),
		_int("reply_generation_budget", "回应生成启动额度", "计算预算：对抗搜索", 1, 10000000, 256, 1024, "首次回应生成的节点数提示；计算份额按候选数公平分配，生成至多用候选额度的一半，不足可扩大重试"),
		_int("rollout_step_budget", "前推生成启动额度", "计算预算：前推", 1, 10000000, 128, 512, "首次未来行动生成的节点数提示；额度随可用总预算分配，各回应与样本公平分配，完整共同层才更新选择"),
		_int("future_reply_limit", "前推不利回应数", "计算预算：前推", 1, 128, 1, 1, "按当前风险排序，精确去重后保留独立回应；市场采样前固定。有限回应池不是全部合法动作"),
		_int("rollout_buy_beam", "前推购买宽度", "计算预算：前推", 1, 64, 3, 3, "默认3；对手当前回合回应仍使用回应数决定宽度"),
		_int("rollout_build_beam", "前推编组宽度", "计算预算：前推", 1, 32, 2, 2, "默认2"),
		_int("rollout_plans", "前推方案数", "计算预算：前推", 1, 64, 2, 2, "默认2"),
		_int("buy_beam", "购买候选宽度", "候选生成", 1, 64, 4, 12, "每个市场卡位保留的购买子集数"),
		_int("build_beam", "编组候选宽度", "候选生成", 1, 32, 3, 8, "每个核心扩展后保留的编组方案数"),
		_int("plans", "根方案数", "候选生成", 1, 64, 6, 16, "进入真实攻防与结算比较的候选数"),
		_int("replies", "对手回应数", "对抗搜索", 1, 16, 2, 5, "当前为先手时保留的对手回应数"),
		_int("sales", "战略典当候选数", "候选生成", 0, 8, 1, 2, "基础搜索的单卡变现名额；0关闭常规单卡候选，联合融资、战术补查和确定冲线另行控制"),
		_int("finalists", "深化方案数", "前推", 1, 16, 2, 4, "共同前推的候选数，保留当前冠军、较低阶段代表与不同持牌路线"),
		_int("samples", "市场样本数", "前推", 1, 16, 1, 3, "每个深化方案的共享市场样本数"),
		_int("future_rounds", "未来回合数", "前推", 0, 6, 0, 2, "阶段0至3只看当前；阶段4开始一回合，阶段7开始两回合"),
		_int("target_trials", "选靶试算额度", "对抗搜索", 0, 128, 12, 36, "整个攻击阶段共享的试算次数；0使用规则派生的目标排序"),
		_int("node_budget", "单阶段节点上限", "计算预算", 1, 1000000000, BASE_NODE_BUDGET, BASE_NODE_BUDGET, "阶段候选展开上限，含回应、前推与重试；与计算基准一起等比放大25倍至250万，可提高以突破基准节点额度，强度滑块保留此设置"),
		_float("engine_horizon", "未来产能权重", "局面评估", 0.0, 10.0, 3.0, "把保有牌的每回合净产能折算为多少期收益"),
		_float("upgrade_weight", "升级潜力权重", "局面评估", 0.0, 2.0, 0.65, "材料可升级价值超过其典当底价的增量权重"),
		_float("risk_weight", "用户安全权重", "局面评估", 0.0, 5.0, 1.0, "接近用户清零时的平滑风险权重"),
		_float("attack_discount", "攻击产能折扣", "局面评估", 0.0, 2.0, 0.75, "将可支付攻击张数折算成未来产能的系数"),
		_float("protection_bonus", "入组保护加成", "候选生成", 0.0, 1.0, 0.15, "防御 Buff 入组立即保护时的候选排序增量"),
		_float("spent_attack_discount", "已开火目标折扣", "对抗搜索", 0.0, 1.0, 0.25, "对方本回合已开火的攻击组，在续打排序中保留多少威胁价值"),
	]

func _int(key: String, label: String, group: String, lower: int, upper: int,
		weak: int, strong: int, hint: String) -> Dictionary:
	var spec := {"key":key,"label":label,"group":group,"kind":"int", "min":lower,"max":upper,
		"step":1,"default":strong,"strength_points":_strength_points(key,weak,strong),
		"strength_interpolation":"step","hint":hint}
	return spec

func _float(key: String, label: String, group: String, lower: float, upper: float,
		value: float, hint: String) -> Dictionary:
	var spec := {"key":key,"label":label,"group":group,"kind":"float", "min":lower,"max":upper,
		"step":0.01,"default":value,"strength_points":[[0.0,value],[0.5,value],[1.0,value]],
		"strength_interpolation":"linear","hint":hint}
	if key == "search_fraction":
		var points: Array = []
		var minimum := float(MIN_STRENGTH_COMPUTE)/BASE_COMPUTE_BUDGET
		for index in range(101):
			var s := index/100.0
			points.append([s,minimum+(1.0-minimum)*s*s*s])
		spec["strength_points"] = points
		spec["step"] = 0.000001
		spec["read_only"] = true
	return spec

func _strength_points(key: String, weak: int, standard: int) -> Array:
	# 九个固定阶段形成同一搜索前缀。能力分别开启，避免同一阈值集中跳变。
	var switches := {"formation_mode":2,"financing_mode":3,"allocation_mode":4,
		"attack_mode":3,"reply_mode":4,"rollout_capabilities":5,"resale_mode":6}
	var values: Array = []
	for stage in range(9):
		var value := roundi(lerpf(weak,STRENGTH_TARGETS.get(key,standard),stage/8.0))
		if switches.has(key): value = 1 if stage >= int(switches[key]) else 0
		if key == "financing_mode" and stage >= 7: value = 2
		if key in ["candidate_dedup","tactical_extension"]: value = 1
		if key == "generation_budget": value = 512+stage*512
		if key == "future_reply_limit": value = 1+stage/3
		if key == "future_rounds": value = 0 if stage < 4 else (1 if stage < 7 else 2)
		if key == "node_budget": value = BASE_NODE_BUDGET
		values.append([stage/8.0,value])
	return values

# 延迟装载计算模块，避免注册元数据时形成 AISearch -> 策略 -> AISearch 的加载环。
func choose_plan(state: GameState, who: String, config) -> Dictionary:
	return load("res://engine/ai_turn_plan.gd").choose_plan(state, who, config)

func target_picker(config) -> Callable:
	return load("res://engine/ai_turn_plan.gd").target_picker(config)

func can_pick_target_inline(targets: Array) -> bool:
	return not targets.is_empty() and load("res://engine/ai_turn_plan.gd").distinct_targets(targets).size() == 1

func evaluate(state: GameState, who: String, parameters: Dictionary) -> float:
	return load("res://engine/ai_evaluation.gd").score(state, who, parameters)
