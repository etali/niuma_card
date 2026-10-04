# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AITurnStrategy
extends "res://engine/ai_strategy.gd"


# 同一强度轴的数值终点。所有参数按0/0.5/1插值，再按schema量化为合法取值。
const STRENGTH_TARGETS := {
	"future_reply_limit": 2,
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
	"finalists": 4,
	"future_rounds": 2,
	"samples": 3,
	"generation_budget": 30000,
	"node_budget": 400000,
	"target_trials": 36
}

func identifier() -> String:
	return "ai"

func display_name() -> String:
	return "AI"

func profile_version() -> String:
	return "4.0"

func parameter_schema() -> Array:
	return [
		_int("financing_mode", "典当动作覆盖", "设计能力：动作空间", 0, 2, 0, 0, "0单张典当；1任意用户数量；2多种牌联合融资。可独立于强度滑块调整"),
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
		_int("generation_budget", "单次候选生成额度", "计算预算：新增能力", 0, 10000000, 0, 0, "0沿用总额度；正数限制每次候选生成，给对手回应和前推留下预算"),
		_int("financing_choices", "每个购牌组合融资数", "计算预算：新增能力", 1, 64, 2, 2, "对每个市场购买子集保留的不同融资方案数"),
		_int("financing_beam", "融资方案宽度", "计算预算：新增能力", 1, 512, 64, 64, "每轮融资保留数量；优先保留不同融资金额。仅典当覆盖非0时使用"),
		_int("allocation_budget", "单核心材料分配额度", "计算预算：新增能力", 1, 4096, 64, 64, "按卡种分组枚举的局部额度，同时受总展开额度限制"),
		_int("reply_generation_budget", "单根回应生成额度", "计算预算：对抗搜索", 1, 10000000, 256, 1024, "每个根方案使用相同局部额度；未完成的回应不作为安全结论"),
		_int("rollout_step_budget", "前推每步生成额度", "计算预算：前推", 1, 10000000, 128, 512, "未来每次行动生成的独立额度；只有完成共同比较层才更新选择"),
		_int("future_reply_limit", "前推不利回应数", "计算预算：前推", 1, 16, 1, 1, "从当前回合最不利的已完成回应中选择前推起点，在市场采样前固定"),
		_int("rollout_buy_beam", "前推购买宽度", "计算预算：前推", 1, 64, 3, 3, "默认3；对手当前回合回应仍使用回应数决定宽度"),
		_int("rollout_build_beam", "前推编组宽度", "计算预算：前推", 1, 32, 2, 2, "默认2"),
		_int("rollout_plans", "前推方案数", "计算预算：前推", 1, 64, 2, 2, "默认2"),
		_int("buy_beam", "购买候选宽度", "候选生成", 1, 64, 4, 12, "每个市场卡位保留的购买子集数"),
		_int("build_beam", "编组候选宽度", "候选生成", 1, 32, 3, 8, "每个核心扩展后保留的编组方案数"),
		_int("plans", "根方案数", "候选生成", 1, 64, 6, 16, "进入真实攻防与结算比较的候选数"),
		_int("replies", "对手回应数", "对抗搜索", 1, 16, 2, 5, "当前为先手时保留的对手回应数"),
		_int("sales", "战略典当候选数", "候选生成", 0, 8, 1, 2, "基础搜索的单卡变现名额；0关闭常规单卡候选，联合融资、战术补查和确定冲线另行控制"),
		_int("finalists", "深化方案数", "前推", 1, 16, 2, 4, "从当前回合排名靠前的方案中选择多少个前推"),
		_int("samples", "市场样本数", "前推", 1, 16, 1, 3, "每个深化方案的共享市场样本数"),
		_int("future_rounds", "未来回合数", "前推", 0, 6, 0, 2, "0只比较当前回合；正数继续按低预算策略前推"),
		_int("target_trials", "选靶试算额度", "对抗搜索", 0, 128, 12, 36, "整个攻击阶段共享的试算次数；0使用规则派生的目标排序"),
		_int("node_budget", "总展开额度", "计算预算", 1, 10000000, 3000, 30000, "整次行动搜索共享的展开次数上限；不是硬毫秒时限"),
		_float("engine_horizon", "未来产能权重", "局面评估", 0.0, 10.0, 3.0, "把保有牌的每回合净产能折算为多少期收益"),
		_float("upgrade_weight", "升级潜力权重", "局面评估", 0.0, 2.0, 0.65, "材料可升级价值超过其典当底价的增量权重"),
		_float("risk_weight", "用户安全权重", "局面评估", 0.0, 5.0, 1.0, "接近用户清零时的平滑风险权重"),
		_float("attack_discount", "攻击产能折扣", "局面评估", 0.0, 2.0, 0.75, "将可支付攻击张数折算成未来产能的系数"),
		_float("protection_bonus", "入组保护加成", "候选生成", 0.0, 1.0, 0.15, "防御 Buff 入组立即保护时的候选排序增量"),
		_float("spent_attack_discount", "已开火目标折扣", "对抗搜索", 0.0, 1.0, 0.25, "对方本回合已开火的攻击组，在续打排序中保留多少威胁价值"),
	]

func compile_parameters(strength: float, source: Dictionary) -> Dictionary:
	# 旧外置AI表的两端数组仍代表原最弱/默认端点；在同一解析器内归一到新强度轴。
	var normalized := source.duplicate(true)
	for spec in parameter_schema():
		var configured: Variant = source.get(spec["key"])
		if configured is Array and configured.size() == 2 and _number(configured[0]) and _number(configured[1]):
			normalized[spec["key"]] = [[0.0,configured[0]],[0.5,configured[1]],[1.0,STRENGTH_TARGETS.get(spec["key"],configured[1])]]
	return super.compile_parameters(strength,normalized)

func _int(key: String, label: String, group: String, lower: int, upper: int,
		weak: int, strong: int, hint: String) -> Dictionary:
	var spec := {"key":key,"label":label,"group":group,"kind":"int", "min":lower,"max":upper,
		"step":1,"default":strong,"strength_points":_strength_points(key,weak,strong),
		"strength_interpolation":"linear","hint":hint}
	if key == "generation_budget": spec["effective_zero_limit"] = "node_budget"
	return spec

func _float(key: String, label: String, group: String, lower: float, upper: float,
		value: float, hint: String) -> Dictionary:
	return {"key":key,"label":label,"group":group,"kind":"float", "min":lower,"max":upper,
		"step":0.01,"default":value,"strength_points":[[0.0,value],[0.5,value],[1.0,value]],
		"strength_interpolation":"linear","hint":hint}

func _strength_points(key: String, weak: int, standard: int) -> Array:
	return [[0.0,weak],[0.5,standard],[1.0,STRENGTH_TARGETS.get(key,standard)]]

# 延迟装载计算模块，避免注册元数据时形成 AISearch -> 策略 -> AISearch 的加载环。
func choose_plan(state: GameState, who: String, config) -> Dictionary:
	return load("res://engine/ai_turn_plan.gd").choose_plan(state, who, config)

func target_picker(config) -> Callable:
	return load("res://engine/ai_turn_plan.gd").target_picker(config)

func evaluate(state: GameState, who: String, parameters: Dictionary) -> float:
	return load("res://engine/ai_evaluation.gd").score(state, who, parameters)
