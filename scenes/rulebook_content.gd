# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 规则书的展示模型。数值只读 CardDB，合成路线只问 ComboRules。
## 每次打开重新生成，外置卡表或运行时配置变化不会留下旧文案。
## sections -> [{id, title, kicker, summary, blocks}]
## blocks -> [{kind: text/flow/cards/callout, title, text, items}]

static func sections() -> Array:
	CardDB.ensure_loaded()
	return [
		_victory_section(),
		_purchase_section(),
		_combos_section(),
		_attack_section(),
		_pawn_section(),
		_buffs_section(),
	]


## 列出该生产卡可参加的合成路线：普通升级同名，传说合成同档即可。
## 张数和目标来自 ComboRules；same_name 区分两种材料要求。
static func upgrade_paths(def_id: String) -> Array:
	var paths: Array = []
	var kind: String = str(CardDB.get_def(def_id).get("kind", ""))
	if kind not in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND]:
		return paths
	for count in range(2, CardDB.max_upgrade_n() + 1):
		var target: String = ComboRules.upgrade_target(def_id, count)
		if target != "":
			paths.append({"source_id": def_id, "count": count, "target_id": target,
				"tier": int(CardDB.get_def(def_id).get("tier", 0)),
				"same_name": CardDB.get_def(target).get("kind", "") != CardDB.KIND_LEGEND})
	return paths


static func _victory_section() -> Dictionary:
	var rules: Dictionary = CardDB.game_rules()
	var cash: String = CardDB.res_label(CardDB.RES_CASH)
	var user: String = CardDB.res_label(CardDB.RES_USER)
	return _section("victory", "输赢条件", "先经营，再冲线",
		"满足任意一项即可获胜：把%s积累到 %d，或让对手的%s／%s归零。" % [cash, int(rules["win_cash"]), cash, user], [
		_block("cards", "获胜路径 · 满足任意一项", "这些是可分别达成的获胜条件。", [
			_card(CardDB.unit_id(CardDB.RES_CASH), "%s ≥ %d" % [cash, int(rules["win_cash"])], "生产积累，或把卡牌典当变现，达到胜利线。", "己方冲线"),
			_card(CardDB.unit_id(CardDB.RES_CASH), "对手%s归零" % cash, "用对应资源的攻击点移除对手的现金卡。", "清空对手资金"),
			_card(CardDB.unit_id(CardDB.RES_USER), "对手%s归零" % user, "用对应资源的攻击点移除对手的用户卡。", "清空对手用户"),
		]),
		_block("callout", "败北与判定时机",
			"自己的%s或%s归零，或对手达到%s胜利线，就会败北。攻击每移除目标后立即判胜，典当后也立即判胜；生产与合成在结算收尾时统一判胜。认输会立即结束本局。" % [cash, user, cash]),
		_block("cards", "开局资源", "资源总量按场上的资源卡数量计算；传说卡要先典当才计入资金。", [
			_card(CardDB.unit_id(CardDB.RES_CASH), "%s×%d" % [CardDB.card_label(CardDB.RES_CASH), int(rules["start_cash"])], "双方各自持有。购买、现金配方会消耗它；攻击也能将它移除。", "开局"),
			_card(CardDB.unit_id(CardDB.RES_USER), "%s×%d" % [CardDB.card_label(CardDB.RES_USER), int(rules["start_user"])], "双方各自持有。用户配方只占用席位，正常结算后仍在场上。", "开局"),
		]),
		_block("flow", "每回合如何推进", "先手每回合轮换。公共区每回合刷新 %d 个卡位，没有自动资源补给。" % int(rules["market_size"]), [
			{"title": "行动", "text": "先手买卡、典当、组卡并收手，再由后手行动。公共区由双方共享。"},
			{"title": "攻击", "text": "先手先攻，后手再攻；清零即结束，未发生的阶段跳过。"},
			{"title": "结算", "text": "先手先生产与合成，再轮到后手。各自先结不消耗现金的组，再结现金配方组。"},
			{"title": "新回合", "text": "结算收尾检查胜负。尚未结束时，交换先手并刷新公共区。"},
		]),
	])


static func _combos_section() -> Dictionary:
	var production_blocks: Array = [
		_block("flow", "组合如何生效", "", [
			{"title": "放入核心", "text": "生产或攻击组合各放一张核心卡；普通升级用同名材料，传说合成用同档生产卡，可异名。"},
			{"title": "满足配方", "text": "把卡面所需的资源放在同组，可再加入适用的 Buff；同张卡不能参与多个组合。"},
			{"title": "到时结算", "text": "攻击在攻击阶段开火，生产与合成在之后结算。每组只产生一种效果。"},
		]),
		_block("callout", "现金要支付，用户只驻场",
			"现金配方会消耗组内所需现金：攻击在装弹时支付，生产在该组结算时支付。用户配方正常结算不会消耗用户。核心卡与 Buff 会保留，可以再次使用；现金配方需要重新补料。"),
		_block("text", "配方不足与富余投料",
			"允许放入超过配方需求的资源。攻击移除材料后，剩余卡仍满足原组合条件时继续生效；否则整组作废。现金不足，或支付后会使己方资金归零时，该组本回合不生效，也不会支付配方。"),
	]
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		var items: Array = []
		for def_id in CardDB.all_cards():
			var def: Dictionary = CardDB.get_def(str(def_id))
			if def.get("kind", "") == CardDB.KIND_PRODUCT and def.get("output_res", "") == res:
				items.append(_production_card(str(def_id), def))
		if not items.is_empty():
			production_blocks.append(_block("cards", "%s产出配方" % CardDB.res_label(res), "下列是未加 Buff 的基础产出。", items))
	production_blocks.append(_block("callout", "合成：同名升级，同档传说",
		"普通升级必须使用路线指定的同名 T1 卡。合成传说可用同一档生产卡，同名或异名均可；T1 与 T2 不得混合。张数必须精确匹配，不能夹杂资源、Buff、攻击卡或传说卡。结算时消耗材料，获得对应的新卡，不额外消耗现金或用户；新卡下回合再用于组卡或典当。"))
	var upgrade_items: Array = []
	for def_id in CardDB.all_cards():
		var paths: Array = upgrade_paths(str(def_id))
		if paths.is_empty():
			continue
		var lines: PackedStringArray = []
		for path in paths:
			var material := "同名" if path["same_name"] else "同档T%d（可异名）" % int(path["tier"])
			lines.append("%s×%d → %s" % [material, int(path["count"]), CardDB.card_name(str(path["target_id"]))])
		upgrade_items.append(_card(str(def_id), CardDB.card_name(str(def_id)), "\n".join(lines), "合成路线"))
	production_blocks.append(_block("cards", "当前卡表的全部合成路线", "T1 是初级生产卡，T2 是升级生产卡。传说路线可搭配任意同档生产卡；只接受路线所列的精确张数，不多吃也不拆组。", upgrade_items))
	production_blocks.append(_block("text", "传说卡的用途",
		"传说卡不生产、不攻击、不增加资源总量，也不继续合成。它的用途是典当变现；获得传说卡本身不会直接获胜。"))
	return _section("combos", "组合、产出与合成", "把卡组成能运转的引擎",
		"生产依靠核心与配方；普通升级要求同名，传说合成要求同档生产卡。两种组合各按自己的条件成立。", production_blocks)


static func _attack_section() -> Dictionary:
	var per_card: int = int(CardDB.game_rules()["attack_cost_per_card"])
	var attack_cards: Array = []
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(str(def_id))
		if def.get("kind", "") != CardDB.KIND_ATTACK:
			continue
		var attack_res: String = str(def["attack_res"])
		var text: String = "%s → %s攻击 %d 点\n%s" % [
			_recipe_text(def), CardDB.card_label(attack_res), int(def["attack_n"]), _payment_text(def)]
		attack_cards.append(_card(str(def_id), CardDB.card_name(str(def_id)), text, _purchase_badge(def)))
	return _section("attack", "攻击规则", "先装弹，再选目标",
		"攻击点按目标资源分别累计。每移除一张资源卡，消耗对应攻击点 %d。" % per_card, [
		_block("flow", "一次攻击阶段", "", [
			{"title": "装弹", "text": "轮到自己攻击时，汇总仍成立的攻击组合。现金配方立即付款，付不起或付款会归零的组不开火。"},
			{"title": "分池", "text": "现金攻击点只能打现金卡，用户攻击点只能打用户卡；同类型攻击组合的点数相加。"},
			{"title": "选靶", "text": "点选对手的资源卡或组合，用对应点数移除可攻击的资源。已生效的防御会阻止相应目标被选中。"},
			{"title": "移除与判胜", "text": "每次移除立即检查胜负。没有可负担目标时，或主动结束攻击时，剩余点数作废。"},
		]),
		_block("callout", "选中组合后，先打完这一摞",
			"开始攻击某个组合后，只要该摞仍有当前点数打得起的目标，就须继续攻击该摞。打空或剩余目标都打不起后，余点可以转向其他目标。散卡堆不会触发这个锁定。"),
		_block("text", "什么可以被攻击",
			"只能移除现金卡和用户卡；生产核心、攻击核心、Buff、传说卡都不可直接攻击。组内、组外资源同价，均为每张 %d 点。富余材料被移除通常不影响配方；必要材料不足会使组合失效。先手可在后手装弹前拆掉其攻击配方。" % per_card),
		_block("cards", "攻击卡与基础点数", "点数是攻击预算，实际能移除多少张卡还取决于每卡成本与防御状态。", attack_cards),
	])


static func _pawn_section() -> Dictionary:
	var ordinary: Array = []
	var legends: Array = []
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(str(def_id))
		var value: int = CardDB.pawn_value(str(def_id))
		var badge: String = "回收 %s×%d" % [CardDB.card_label(CardDB.RES_CASH), value] if value > 0 else "不可典当"
		var text: String = _pawn_source_text(def)
		var item: Dictionary = _card(str(def_id), CardDB.card_name(str(def_id)), text, badge)
		if def.get("kind", "") == CardDB.KIND_LEGEND:
			legends.append(item)
		else:
			ordinary.append(item)
	return _section("pawn", "典当规则", "把卡牌换成可用现金",
		"在自己的行动阶段典当卡牌，回收所得立即成为可支配现金，也可以直接冲过资金胜利线。", [
		_block("flow", "典当流程", "", [
			{"title": "选择卡牌", "text": "可批量典当有回收价的己方卡牌。现金卡不可典当，也不允许把自己的用户全部当光。"},
			{"title": "按价回收", "text": "所选卡牌离场，按各卡当前回收价的合计获得现金卡。"},
			{"title": "立即使用", "text": "获得的现金可继续购买或组卡。典当完成后立即检查胜负，无须等回合结束。"},
		]),
		_block("text", "回收价如何计算",
			"用户卡：%s×%d。可购卡：标价 ÷ %s，四舍五入；由同名下级卡合成的卡：材料购牌价合计 ÷ %s，四舍五入。正价卡不会因折价而变成零回收。卡表有固定回收价时，使用该卡的定价。" % [
				CardDB.card_label(CardDB.RES_CASH), CardDB.pawn_user(), str(CardDB.pawn_rate()), str(CardDB.pawn_rate())]),
		_block("cards", "传说卡兑现", "传说卡本身不计入资金，典当后才成为现金；能否获胜取决于变现后的资金总量。", legends),
		_block("cards", "当前卡表的回收价", "按每张卡分别计算，再合计。", ordinary),
	])


static func _buffs_section() -> Dictionary:
	var buffs: Array = []
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(str(def_id))
		if def.get("kind", "") != CardDB.KIND_BUFF:
			continue
		var buff_type: String = str(def.get("buff_type", ""))
		buffs.append(_card(str(def_id), CardDB.card_name(str(def_id)), _buff_text(buff_type), _buff_badge(buff_type)))
	return _section("buffs", "BUFF 规则", "增强产出，守住配方",
		"Buff 放在生效的生产或攻击组合里才有作用。不同类型可以搭配，同类型重复放入不会叠加效果。", [
		_block("cards", "全部 Buff 效果", "倍率读取当前配置；效果只作用于所在组合。", buffs),
		_block("flow", "防御 Buff 的生效过程", "", [
			{"title": "首次入组", "text": "进入有效组合即刻保护配方额度内的对应资源，本回合就生效。"},
			{"title": "之后的回合", "text": "只要仍在有效组合中，就持续保护对应资源，不会随回合折旧。"},
			{"title": "移动与离组", "text": "移入另一个有效组合后立即保护新组；离组或组合不再成立时，原组失去保护。"},
		]),
		_block("callout", "保护有范围，富余投料仍可被打",
			"防御只覆盖配方所需额度内的对应资源，按组内顺序选择；超过配方需求的富余资源不受保护。不能把全部身家塞进同组来扩大护盾。防御只挡对手攻击，不免除自己的现金配方支付。"),
		_block("text", "裂变与防御可以配合",
			"裂变补满用户配方时，用户防御同样立即生效，保护额度只按实际占用的用户席位计算；额外用户属于富余投料。原有用户已满足完整配方时，按原配方计算保护额度。裂变不会增加真实用户总量，也不能补现金配方。"),
	])


static func _production_card(def_id: String, def: Dictionary) -> Dictionary:
	return _card(def_id, CardDB.card_name(def_id), "%s → %s+%d\n%s" % [
		_recipe_text(def), CardDB.res_label(str(def["output_res"])), int(def["output_n"]), _payment_text(def)], _purchase_badge(def))


static func _recipe_text(def: Dictionary) -> String:
	return "%s×%d" % [CardDB.card_label(str(def["recipe_res"])), int(def["recipe_n"])]


static func _payment_text(def: Dictionary) -> String:
	if def["recipe_res"] == CardDB.RES_CASH:
		return "每次生效支付配方现金；核心保留。"
	return "配方用户驻场，正常结算不消耗；核心保留。"


static func _purchase_badge(def: Dictionary) -> String:
	if int(def.get("price", -1)) >= 0:
		return "购买 %s×%d" % [CardDB.card_label(CardDB.RES_CASH), int(def["price"])]
	return "合成获得"


static func _pawn_source_text(def: Dictionary) -> String:
	if def.has("pawn"):
		return "使用该卡的固定回收价。"
	if def.get("kind", "") == CardDB.KIND_UNIT:
		return "用户回收价随当前规则配置。" if def.get("res", "") == CardDB.RES_USER else "现金是典当所得，不能再次典当。"
	if int(def.get("price", -1)) > 0:
		return "标价 %s×%d，按当前典当折价率回收。" % [CardDB.card_label(CardDB.RES_CASH), int(def["price"])]
	return "按同名下级材料的购牌价之和折算。"


static func _buff_text(buff_type: String) -> String:
	match buff_type:
		"user_fill":
			return "核心配方需要用户，且组内已有用户卡时，用户配方视为补满；真实用户卡不会增加。无用户时无法补满，也不补现金配方。"
		"output_x2":
			return "所在生产组合的资源产出 ×%d。只增加产出，不增加配方消耗，不增强攻击，也不复制合成的新卡。" % CardDB.buff_mult(buff_type)
		"attack_x2":
			return "所在攻击组合的攻击点数 ×%d。配方需求与现金支付不增加，不增强生产产出。" % CardDB.buff_mult(buff_type)
		"protect_user":
			return "入组立即保护所在有效组合配方额度内的用户卡，使其不可被攻击移除。富余用户不受保护。"
		"protect_cash":
			return "入组立即保护所在有效组合配方额度内的现金卡，使其不可被攻击移除。仍须照常支付现金配方，富余现金不受保护。"
	return "此 Buff 类型尚未被当前规则识别。"


static func _buff_badge(buff_type: String) -> String:
	match buff_type:
		"user_fill": return "补满用户配方"
		"output_x2": return "产出 ×%d" % CardDB.buff_mult(buff_type)
		"attack_x2": return "攻击 ×%d" % CardDB.buff_mult(buff_type)
		"protect_user", "protect_cash": return "入组立即保护"
	return "未识别效果"


static func _section(id: String, title: String, kicker: String, summary: String, blocks: Array) -> Dictionary:
	return {"id": id, "title": title, "kicker": kicker, "summary": summary, "blocks": blocks}


static func _block(kind: String, title: String, text: String, items: Array = []) -> Dictionary:
	return {"kind": kind, "title": title, "text": text, "items": items}


static func _card(def_id: String, title: String, text: String, badge: String) -> Dictionary:
	return {"def_id": def_id, "title": title, "text": text, "badge": badge}

static func _purchase_section() -> Dictionary:
	var count := int(CardDB.game_rules()["market_size"])
	return _section("purchase", "购买", "现金换取新的卡牌", "在自己的行动阶段，从公共购牌栏选择商品。", [
		_block("text", "购买", "市场每回合提供 %d 个商品位。把足够的现金拖到商品上支付价格；付款不能让现金归零。典当行是公共设施，不需要购买。" % count),
	])
