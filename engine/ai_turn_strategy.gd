# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AITurnStrategy
extends "res://engine/ai_strategy.gd"

func identifier() -> String:
	return "ai"

func display_name() -> String:
	return "AI"

func profile_version() -> String:
	return "2.4"

func parameter_schema() -> Array:
	return [
		_int("buy_beam", "购买候选宽度", "候选生成", 1, 64, 4, 12, "每个市场卡位保留的购买子集数"),
		_int("build_beam", "编组候选宽度", "候选生成", 1, 32, 3, 8, "每个核心扩展后保留的编组方案数"),
		_int("plans", "根方案数", "候选生成", 1, 64, 6, 16, "进入真实攻防与结算比较的候选数"),
		_int("replies", "对手回应数", "对抗搜索", 1, 16, 2, 5, "当前为先手时保留的对手回应数"),
		_int("sales", "战略典当候选数", "候选生成", 0, 8, 1, 2, "非必胜局面考虑的单卡变现候选；0关闭，确定冲线仍保留"),
		_int("finalists", "深化方案数", "前推", 1, 16, 2, 4, "从当前回合排名靠前的方案中选择多少个前推"),
		_int("samples", "市场样本数", "前推", 1, 16, 1, 3, "每个深化方案的共享市场样本数"),
		_int("future_rounds", "未来回合数", "前推", 0, 6, 0, 2, "0只比较当前回合；正数继续按低预算策略前推"),
		_int("target_trials", "选靶试算额度", "对抗搜索", 0, 128, 12, 36, "整个攻击阶段共享的试算次数；0使用规则派生的目标排序"),
		_int("node_budget", "总展开额度", "计算预算", 1, 100000, 3000, 30000, "整次行动搜索共享的展开次数上限；不是硬毫秒时限"),
		_float("engine_horizon", "未来产能权重", "局面评估", 0.0, 10.0, 3.0, "把保有牌的每回合净产能折算为多少期收益"),
		_float("upgrade_weight", "升级潜力权重", "局面评估", 0.0, 2.0, 0.65, "材料可升级价值超过其典当底价的增量权重"),
		_float("risk_weight", "用户安全权重", "局面评估", 0.0, 5.0, 1.0, "接近用户清零时的平滑风险权重"),
		_float("attack_discount", "攻击产能折扣", "局面评估", 0.0, 2.0, 0.75, "将可支付攻击张数折算成未来产能的系数"),
		_float("protection_bonus", "入组保护加成", "候选生成", 0.0, 1.0, 0.15, "防御 Buff 入组立即保护时的候选排序增量"),
		_float("spent_attack_discount", "已开火目标折扣", "对抗搜索", 0.0, 1.0, 0.25, "对方本回合已开火的攻击组，在续打排序中保留多少威胁价值"),
	]

func _int(key: String, label: String, group: String, lower: int, upper: int,
		weak: int, strong: int, hint: String) -> Dictionary:
	return {"key":key,"label":label,"group":group,"kind":"int", "min":lower,"max":upper,
		"step":1,"default":weak,"strength_range":[weak,strong],"hint":hint}

func _float(key: String, label: String, group: String, lower: float, upper: float,
		value: float, hint: String) -> Dictionary:
	return {"key":key,"label":label,"group":group,"kind":"float", "min":lower,"max":upper,
		"step":0.01,"default":value,"hint":hint}

# 延迟装载计算模块，避免注册元数据时形成 AISearch -> 策略 -> AISearch 的加载环。
func choose_plan(state: GameState, who: String, config) -> Dictionary:
	return load("res://engine/ai_turn_plan.gd").choose_plan(state, who, config)

func target_picker(config) -> Callable:
	return load("res://engine/ai_turn_plan.gd").target_picker(config)

func evaluate(state: GameState, who: String, parameters: Dictionary) -> float:
	return load("res://engine/ai_evaluation.gd").score(state, who, parameters)
